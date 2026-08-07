import SwiftUI

struct RootView: View {
    @Environment(ClusterStore.self) private var store
    /// 絞り込み欄の文言だけが設定を見る（配置の「たどる」では相手が変わる）。
    @State private var preferences = Preferences.shared
    @State private var showsInspector = true
    /// 下の帯の高さ。仕切りのドラッグで変わる。**ログと詳細で 1 つ。**
    @State private var dockHeight: CGFloat = 280
    /// 下の帯を分け合うとき、詳細に割く幅。
    @State private var dockInspectorWidth: CGFloat = 380
    /// エラーの元の文言を開いているか。既定は畳んでおく。
    @State private var showsErrorDetail = false
    /// 確認待ちの操作と、開いているシート。**一覧・詳細パネル・メニューバーで 1 つ。**
    /// 持ち主はアプリ（`KubeDeckApp`）—— コマンドはウインドウの外側にいるので、
    /// ここで `@State` にするとメニューから手が届かない。
    @Environment(ResourceActionHost.self) private var actions

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            detailWithSearch
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                // 詳細パネルの表示を選択の**有無**に連動させない。連動させると、
                // 左で種別を選んだ瞬間や自動更新の選び直しでもパネルが出入りし、
                // AppKit がその列を作るためにウインドウごと広げる（選ぶたびに
                // 窓の幅が変わる）。畳むのはツールバーのボタンだけが決める。
                //
                // **出す方向は、人が押したときだけ効かせる。** 畳んだまま行を
                // 選ぶと詳細が見られない、という行き止まりになるので、
                // `inspectorRevealRequests`（人が行やタイルを押した回数）を
                // 見て出す。片方向なので ✕ が効かなくなることはない
                // （次に押すまで畳んだまま）。邪魔なら設定で切れる。
                //
                // **下に置いているときも `.inspector` は外さない。** ここは
                // `NSSplitView` そのもので、付け外しはビュー階層から split view が
                // 消えることになる（`VSplitView` の件と同じ危うさ）。畳んだ状態に
                // するだけにして、中身だけを止める。
                .inspector(isPresented: Binding(
                    get: { showsInspector && preferences.inspectorPlacement == .trailing },
                    set: { showsInspector = $0 })
                ) {
                    Group {
                        // 畳んでいるあいだも中身を作らない。作ると詳細パネルが
                        // 2 つ生き、イベントの取得が両方から走る。
                        if preferences.inspectorPlacement == .trailing {
                            InspectorView()
                        }
                    }
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
                }
        }
        // **人が選んだときだけ出す。** 数を見るので、同じものを選び直しても
        // 押した回数として届く（`selectedObjectID` の変化を見ると、同じ行を
        // 押し直したときに何も起きない）。**閉じる側には連動させない。**
        .onChange(of: store.inspectorRevealRequests) { _, _ in
            guard preferences.opensInspectorOnSelection else { return }
            showsInspector = true
        }
        // 操作を始める場所は 3 つ（一覧の右クリック・詳細パネルのボタン・
        // メニューバー）だが、確認とシートを出すのはここ 1 か所だけ。
        .resourceActionPresenter(actions)
        // **隠れているあいだは自動更新を止める。** `scenePhase` では足りない
        // —— 他のアプリを触っているだけで `.inactive` になるが、そのときも
        // ロールアウトを横目で見ていることはふつうにある。止めたいのは
        // 「しまった・完全に覆われた」ときだけなので、occlusion を見る。
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeOcclusionStateNotification)
        ) { _ in
            store.isWindowVisible = NSApp.occlusionState.contains(.visible)
        }
        .overlay(alignment: .bottom) { errorBar }
        // 知らせは帯より上に積む。両方が出るのは、成功の直後に自動更新が
        // 失敗したときぐらいだが、そのとき重なると読めない。
        .overlay(alignment: .bottom) { noticeBar }
        // **消える側に付けても効かない。** 出入りを animate させるには、
        // 残っているほう（この親）に置く必要がある。
        .animation(.easeOut(duration: 0.18), value: store.actionNotice)
    }

    /// 絞り込み欄へカーソルを移す。
    ///
    /// **ツールバーの項目から辿らない。** SwiftUI が載せた項目の `view` は
    /// nil のことがある。窓の themeFrame（`contentView` の親）から下を素直に
    /// 探すほうが、ツールバーに置いても本体に置いても見つかる。
    ///
    /// **見つからなくても何もしない。** 概要のように欄が無い画面でも呼ばれる。
    private static func focusSearchField() {
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let root = window.contentView?.superview ?? window.contentView
        else { return }

        var stack = [root]
        while let view = stack.popLast() {
            if let field = view as? NSSearchField {
                window.makeFirstResponder(field)
                return
            }
            stack.append(contentsOf: view.subviews)
        }
    }

    /// どのクラスタを触っているかの帯。
    ///
    /// **色だけで言わない。** 名前を必ず書く（状態の 4 色と紛れないように、
    /// 色は札の色として別に持つ）。読み取り専用もここに出す —— できないことを
    /// 押してから知るのでは遅い。
    ///
    /// **印を付けていないコンテキストでは出さない。** 常に帯があると、
    /// 目立たせたいところで目立たなくなる。
    @ViewBuilder
    private var contextBanner: some View {
        let profile = store.contextProfile
        if let color = Palette.color(for: profile.tint) {
            HStack(spacing: 8) {
                Image(systemName: profile.isReadOnly ? "lock.fill" : "circle.fill")
                    .font(.system(size: profile.isReadOnly ? 10 : 7))
                Text(store.contextDisplayName)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if profile.isReadOnly {
                    Text("読み取り専用")
                        .font(.caption)
                        .opacity(0.9)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(color)
        } else if profile.isReadOnly {
            // 色を付けていなくても、読めるだけであることは言う。
            HStack(spacing: 8) {
                Image(systemName: "lock.fill").font(.system(size: 10))
                Text("\(store.contextDisplayName) は読み取り専用")
                    .font(.caption)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity)
            .background(Palette.subtleFill)
        }
    }

    // MARK: - 本体

    /// 絞り込み欄を持つのはここ 1 か所だけ。
    ///
    /// **画面ごとに `.searchable` を付け外ししない。** 以前は
    /// `ResourceListView` と `PlacementView` がそれぞれ持っており、両者は
    /// `detail` の switch の枝なので、概要 → 一覧では項目が足され、
    /// 配置 → 一覧では外して足す、とツールバーの項目集合が動いていた。
    /// この更新は `NSHostingView.layout` の最中に `ToolbarBridge` 経由で走るため、
    /// `-[NSToolbar _insertNewItemWithItemIdentifier:atIndex:]` が例外を投げて
    /// **アプリごと落ちる**（クラッシュログ 11 件中 9 件がこれ）。ここに集めると
    /// 項目集合は静的になり、変わるのは文言と有効・無効だけになる。
    ///
    /// **`.disabled` を本体に掛けない。** 概要には絞り込む相手がいないので欄は
    /// 無効にしたいが、素直に重ねると `detailWithDock` ごと無効になり、
    /// 取得に失敗したときの「もう一度試す」まで押せなくなる。ZStack の兄弟に
    /// 分けておけば、無効になるのは欄だけで済む（`.toolbar` も外側なので、
    /// コンテキストや再読み込みは概要でも生きる）。
    private var detailWithSearch: some View {
        ZStack {
            detailWithDock
                // **どのクラスタを触っているのかを、常に画面に出す。** 削除も
                // drain もできる道具になったので、prod と dev の見分けが
                // ツールバーの小さな文字だけ、という状態のままにしない。
                //
                // **窓ぜんぶに差し込まない。** `NavigationSplitView` の外側に
                // 付けると、帯がツールバーの下に潜り込んだうえ**サイドバーの
                // 先頭の行（概要）を隠した**（実測）。詳細側だけに掛ければ、
                // 左の列にも上のツールバーにも触らない。
                .safeAreaInset(edge: .top, spacing: 0) { contextBanner }
            Color.clear
                .allowsHitTesting(false)
                .searchable(
                    text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
                    placement: .toolbar,
                    prompt: searchPrompt)
                .disabled(store.selection == .overview)
                // ⌘F で欄へ移る。**`searchFocused(_:)` は使えない** ——
                // macOS 15 以降の API で、ここは 14 以降を対象にしている。
                // 欄そのものを探して first responder にする。
                .onChange(of: store.searchFocusRequests) { _, _ in
                    Self.focusSearchField()
                }
        }
    }

    /// 一覧の下の帯。ログと、下に置いた詳細パネルが入る。掴んで高さを変えられる。
    ///
    /// **`VSplitView` を使わない。** `NavigationSplitView` と `.inspector` で
    /// すでに 2 つの `NSSplitView` が入れ子になっており、そこへ 3 つ目を足して
    /// 出し入れすると、レイアウト中に AppKit が例外を投げて落ちる
    /// （`-[NSView _layoutSubtreeWithOldSize:]` → `_crashOnException:`）。
    /// 高さは自分で持ち、仕切りは自前のドラッグにする。
    private var detailWithDock: some View {
        // **上限を決め打ちにしない。** 窓より高い帯を掴めてしまうと、上の一覧が
        // 潰れきったあとも掴んだ値だけが伸び続け、戻すときに動かない区間ができる。
        //
        // **ただし、測る場所を帯の内側に置かない。** `safeAreaInset` を付けた側で
        // `GeometryReader` に訊くと、返るのは安全領域を除いた高さ——つまり
        // **帯のぶんだけ縮んだ値**（実測: 外 960 / 内 680 / 帯 280）。これを上限の
        // 元にすると、帯を広げるたびに上限が下がって掴んだ値を押し戻す、を毎
        // フレーム繰り返して**掴んだところでグラグラする**。外側の
        // `GeometryReader` は帯を動かしても変わらない。
        GeometryReader { proxy in
            let cap = Self.dockHeightCap(in: proxy.size.height)
            detail
                // `GeometryReader` は子を左上に寄せるので、伸びない中身
                // （`ContentUnavailableView` など）が隅に張り付く。広がる枠に
                // 入れて、包む前と同じく真ん中に置く。
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if store.logRequest != nil || showsBottomInspector {
                        VStack(spacing: 0) {
                            PanelResizeHandle(
                                axis: .height, value: $dockHeight, range: 120...cap,
                                label: "下の帯の高さを変える")
                            dockBody
                        }
                        .frame(height: min(dockHeight, cap))
                    }
                }
        }
    }

    /// 帯を広げてよい上限。上の一覧が数行は残るところで止める。
    /// まだ測れていないあいだ（0）は決め打ちに落とす。
    private static func dockHeightCap(in containerHeight: CGFloat) -> CGFloat {
        guard containerHeight > 0 else { return 900 }
        return max(200, containerHeight - 160)
    }

    private var showsBottomInspector: Bool {
        showsInspector && preferences.inspectorPlacement == .bottom
    }

    /// 帯の中身。**ログと詳細を上下に積まない。** 積むと仕切りが 2 本になり、
    /// 帯を 2 倍に広げないとどちらも数行しか残らない（狭い画面ではそれもできない）。
    /// 横に並べれば高さは 1 つで済み、片方だけのときはそのまま横いっぱいを使う。
    ///
    /// 詳細を右端に置くのは、右に置いていたものを下ろしたときに左右の関係が
    /// 変わらないため。ログは行が長いので、伸び縮みするのはそちら。
    ///
    /// **`GeometryReader` で包む。** `frame(width:)` は縮められない最小幅になる
    /// ので、そのまま置くと窓が狭いときに詳細パネルの幅が外へ伝わり、
    /// サイドバーの左端が切れる（`TraceMapView` で踏んだのと同じ）。
    /// `GeometryReader` は提案された大きさをそのまま受けるので、中で決めた幅は
    /// 外へ出ない。測った幅で上限も掛けられる。
    private var dockBody: some View {
        GeometryReader { proxy in
            let sharing = store.logRequest != nil && showsBottomInspector
            // **見た目だけ止めない。** 掴める上限もここで決める。表示のときだけ
            // 詰めると、掴んだ値は画面の外へ伸び続け、戻すとき伸ばしたぶんだけ
            // 動かない区間ができる（掴んでいるのに反応しない、という壊れ方）。
            let widthCap = max(240, proxy.size.width * 0.6)
            HStack(spacing: 0) {
                if let request = store.logRequest {
                    LogPanel(request: request)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showsBottomInspector {
                    if sharing {
                        PanelResizeHandle(
                            axis: .width, value: $dockInspectorWidth, range: 240...widthCap,
                            label: "詳細パネルの幅を変える")
                    }
                    DockedInspector(
                        moveToTrailing: { preferences.inspectorPlacement = .trailing },
                        close: { showsInspector = false })
                        .frame(width: sharing ? min(dockInspectorWidth, widthCap) : nil)
                        .frame(maxWidth: sharing ? nil : .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let message = store.setupErrorMessage {
            SetupErrorView(message: message)
        } else {
            switch store.selection {
            case .overview:
                OverviewView()
            case .placement:
                PlacementView()
            case .resource(let target):
                ResourceListView(target: target)
            }
        }
    }

    private var title: String {
        switch store.selection {
        case .overview: return String(localized: "概要")
        case .placement: return String(localized: "配置")
        case .resource(let target): return target.displayName
        }
    }

    /// 副題にはコンテキストと Namespace を書かない。ツールバーのメニューが
    /// 同じことを言っており、二重に出すとどちらが操作対象か紛れる。
    ///
    /// 取得中の合図もここに出す。**ツールバーには置かない。** 独立した項目に
    /// すると隠しても枠が縦棒として残り、Menu のラベルに `ProgressView` を
    /// 入れてもツールバーでは描画されず、アイコンが空のボタンになる。
    private var subtitle: String {
        if store.isLoading { return String(localized: "読み込み中…") }
        // 失敗しているときに「0 件」と出さない。数えられていない。
        if store.selection == .placement {
            if store.errorMessage != nil, store.objects.isEmpty {
                return String(localized: "取得できません")
            }
            return String(localized: """
                \(store.placementNodes.count) ノード · \(store.filteredObjects.count) Pod
                """)
        }
        guard case .resource = store.selection else { return "" }
        if store.errorMessage != nil, store.objects.isEmpty {
            return String(localized: "取得できません")
        }
        let shown = store.filteredObjects.count
        let total = store.objects.count
        let counts = shown == total
            ? String(localized: "\(total) 件")
            : String(localized: "\(shown) / \(total) 件")
        // **選んでいる数はここに出す。** 件数の持ち場は副題（同じ数字を
        // 2 か所に置かない）。1 件のときは書かない — ふつうがそちらなので、
        // 常に出すと件数が読みにくくなるだけ。
        let selected = store.selectedObjectIDs.count
        return selected > 1
            ? String(localized: "\(counts) · \(selected) 件選択中")
            : counts
    }

    /// 絞り込み欄の文言。**画面ごとに相手が違う。** 配置の「たどる」で絞るのは
    /// 左の起点の一覧であって図ではないので、そこだけ書き分ける。
    private var searchPrompt: String {
        switch store.selection {
        case .overview:
            return String(localized: "絞り込み")
        case .placement:
            return preferences.placementGrouping == .map
                ? String(localized: "たどる起点を絞り込む")
            : String(localized: "Pod を絞り込む")
        case .resource(let target):
            return String(localized: "\(target.displayName) を絞り込む")
        }
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { contextMenu }
        ToolbarItem(placement: .navigation) { namespaceMenu }
        ToolbarItem { refreshControl }
        ToolbarItem { inspectorControl }
    }

    /// 押すと出し入れ、長押し（▾）で置き場所。**項目を 2 つに割らない** —
    /// ツールバーの項目集合は静的に保つ（画面ごとに変えると落ちる件と同じ理由で、
    /// 数が動く経路は増やさない）。
    private var inspectorControl: some View {
        Menu {
            Picker("置き場所", selection: Binding(
                get: { preferences.inspectorPlacement },
                set: { placement in
                    preferences.inspectorPlacement = placement
                    // 置き場所を選ぶのは見たいときなので、畳んだままにしない
                    // （選んでも何も起きないと、効かなかったように見える）。
                    showsInspector = true
                })
            ) {
                ForEach(InspectorPlacement.allCases) { placement in
                    Label(placement.title, systemImage: placement.symbol).tag(placement)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label("詳細", systemImage: preferences.inspectorPlacement.symbol)
        } primaryAction: {
            showsInspector.toggle()
        }
        .help("詳細パネルの表示を切り替える（▾ で右／下を選ぶ）")
    }

    private var contextMenu: some View {
        Menu {
            Picker("コンテキスト", selection: Binding(
                get: { store.currentContext },
                set: { store.currentContext = $0 })
            ) {
                ForEach(store.contexts, id: \.self) { context in
                    Text(context).tag(context)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label {
                Text(store.currentContext.isEmpty
                ? String(localized: "コンテキスト") : store.currentContext)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "cube.transparent")
            }
        }
        // アイコンだけだと何のメニューか分からない。接続先は取り違えると
        // 影響が大きいので、名前を常に見えるところに出す。
        .labelStyle(.titleAndIcon)
        .help("接続先のクラスタ（kubeconfig のコンテキスト）")
    }

    private var namespaceMenu: some View {
        Menu {
            Button {
                store.selectedNamespace = nil
            } label: {
                if store.selectedNamespace == nil {
                    Label("すべての Namespace", systemImage: "checkmark")
                } else {
                    Text("すべての Namespace")
                }
            }
            Divider()
            ForEach(store.namespaces, id: \.self) { namespace in
                Button {
                    store.selectedNamespace = namespace
                } label: {
                    if store.selectedNamespace == namespace {
                        Label(namespace, systemImage: "checkmark")
                    } else {
                        Text(namespace)
                    }
                }
            }
        } label: {
            Label {
                Text(store.namespaceLabel).lineLimit(1)
            } icon: {
                Image(systemName: "square.stack.3d.down.right")
            }
        }
        .labelStyle(.titleAndIcon)
        .help("Namespace の絞り込み")
        .disabled(store.namespaces.isEmpty)
    }

    private var refreshControl: some View {
        Menu {
            Toggle("自動更新", isOn: Binding(
                get: { store.autoRefresh },
                set: { store.autoRefresh = $0 }))
            Picker("間隔", selection: Binding(
                get: { store.refreshInterval },
                set: { store.refreshInterval = $0 })
            ) {
                Text("5 秒").tag(TimeInterval(5))
                Text("10 秒").tag(TimeInterval(10))
                Text("30 秒").tag(TimeInterval(30))
                Text("60 秒").tag(TimeInterval(60))
            }
            if let lastUpdated = store.lastUpdated {
                Divider()
                Text("最終更新 \(lastUpdated.formatted(date: .omitted, time: .standard))")
            }
        } label: {
            Label("再読み込み", systemImage: "arrow.clockwise")
        } primaryAction: {
            store.reload()
        }
        .help("いま表示しているものを読み直す（⌘R）")
    }


    // MARK: - 操作が通ったことの知らせ

    /// **エラー帯と同じ見た目にしない。** あちらは赤い縁で留まり続けるもの、
    /// こちらは数秒で消えるもの。同じ形だと「また何か起きた」と身構える。
    @ViewBuilder
    private var noticeBar: some View {
        if let notice = store.actionNotice {
            HStack(spacing: 8) {
                Image(systemName: StatusLevel.good.symbol)
                    .foregroundStyle(Palette.color(for: .good))
                Text(notice)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(Palette.cardStroke, lineWidth: 1))
            // エラー帯が出ているときはその上に載せる。
            .padding(.bottom, store.errorMessage == nil ? 16 : 96)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            // 押せるものではないので、下の一覧の操作を邪魔しない。
            .allowsHitTesting(false)
            .accessibilityLabel(Text(notice))
        }
    }

    // MARK: - エラー表示

    @ViewBuilder
    private var errorBar: some View {
        if let message = store.errorMessage {
            let parts = Self.splitError(message)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: StatusLevel.critical.symbol)
                    .foregroundStyle(Palette.color(for: .critical))
                VStack(alignment: .leading, spacing: 6) {
                    Text(parts.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(4)
                    // 元の文言は畳んでおく。開いておくと帯が画面の半分を占める。
                    // **切り捨てない。** 切り捨てると、原因の手がかりが末尾に
                    // ある種の失敗（exec プラグインが出す TLS のエラーなど）を
                    // アプリの中では追えなくなる。
                    if let detail = parts.detail {
                        DisclosureGroup(isExpanded: $showsErrorDetail) {
                            ScrollView {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        } label: {
                            Text("元の文言").font(.caption)
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    // 貼って共有できないと、結局ターミナルで再現する羽目になる。
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                    .buttonStyle(.link)
                    Button("閉じる") { store.errorMessage = nil }
                        .buttonStyle(.link)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Palette.color(for: .critical).opacity(0.35), lineWidth: 1))
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 帯の見出しと、畳んでおく残り。
    ///
    /// `Kubectl.explain(_:)` が言い換えを足したものは、空行で言い換えと元の文言が
    /// 分かれている。**同じ文言を 2 度出さない** ので、残りは見出しに入らなかった
    /// 分だけにする。空行が無いものは 4 行目で切る（帯が出す行数と揃える）。
    static func splitError(_ message: String) -> (summary: String, detail: String?) {
        if let separator = message.range(of: "\n\n") {
            let tail = String(message[separator.upperBound...])
            return (String(message[..<separator.lowerBound]), tail.isEmpty ? nil : tail)
        }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 4 else { return (message, nil) }
        return (lines.prefix(4).joined(separator: "\n"),
                lines.dropFirst(4).joined(separator: "\n"))
    }
}

/// kubectl そのものが見つからない場合。一覧の読み込み失敗とは扱いを分ける。
struct SetupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("クラスタに接続できません", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        }
    }
}


/// 下の帯の仕切り。掴んで動かすと高さ（上の縁）か幅（左の縁）が変わる。
///
/// **`VSplitView` / `HSplitView` を使わない。** すでに `NSSplitView` が 2 つ
/// 入れ子になっており、3 つ目を出し入れするとレイアウト中に AppKit が例外を
/// 投げて落ちる。掴める場所は自前で持つ。
private struct PanelResizeHandle: View {
    enum Axis {
        /// 下の帯の上の縁。上へ引くと高くなる。
        case height
        /// 帯の中の縦の仕切り。左へ引くと右の欄が広くなる。
        case width
    }

    let axis: Axis
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let label: LocalizedStringResource

    /// ドラッグ開始時の値。translation は開始点からの差分なので、
    /// 毎回の変化量として足すと動きが加速してしまう。
    @State private var start: CGFloat?
    /// カーソルを積んだかどうか。**push と pop の数を必ず合わせる。**
    @State private var pushedCursor = false
    @State private var hovering = false
    /// ドラッグ中か。`@GestureState` なので、取り消されても必ず false に戻る
    /// （`onEnded` は取り消しでは呼ばれないので、`@State` では戻らない）。
    @GestureState private var dragging = false

    private static let thickness: CGFloat = 7

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(
                    width: axis == .width ? 1 : nil,
                    height: axis == .height ? 1 : nil)
            Color.clear
                .contentShape(Rectangle())
        }
        .frame(
            width: axis == .width ? Self.thickness : nil,
            height: axis == .height ? Self.thickness : nil)
        .onHover { inside in
            hovering = inside
            syncCursor()
        }
        .gesture(
            // **`.global` で測る。** 既定の `.local` はこの仕切り自身の座標系で、
            // 仕切りは値を変えたぶんだけ動く。上へ 10pt 引けば帯が 10pt 高くなり、
            // 仕切りも 10pt 上がるので、カーソルは自分の座標系では動いていない
            // ことになる（translation が 0 に戻る）。値が base に引き戻され、
            // すると仕切りが下がってまた差が出る、を繰り返して**掴んだところで
            // 震える**。窓の座標系で測れば、仕切りが動いても差分は動かない。
            DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { drag in
                    // 起点は「いま画面に出ている大きさ」に合わせる。窓を狭めたあとは
                    // 表示だけが上限で止まっているので、覚えている値から動かすと
                    // 画面の外から動き始め、最初のひと押しが効かない。
                    // **覚えている値のほうは詰めない** — 起動直後に一過性の小さな
                    // 大きさが来ることがあり（実測で 1 度だけ 168pt）、そこで詰めると
                    // 誰も触っていないのに帯が縮んだままになる。
                    let base = min(max(start ?? value, range.lowerBound), range.upperBound)
                    if start == nil { start = base }
                    // どちらも「引いた向きと逆に伸びる」縁に付くので符号は負。
                    let delta = axis == .height ? -drag.translation.height : -drag.translation.width
                    value = min(range.upperBound, max(range.lowerBound, base + delta))
                }
                .onEnded { _ in start = nil })
        // 取り消しでは `onEnded` が来ないので、起点はこちらでも捨てる。
        // 残すと、次に掴んだときに前回の値を基点にして飛ぶ。
        .onChange(of: dragging) { _, isDragging in
            if !isDragging { start = nil }
            syncCursor(dragging: isDragging)
        }
        // 掴んだまま欄の外へ出ても、カーソルは仕切りのものを保つ。
        // 消えるときは必ず戻す（戻さないと、押した形のまま画面ぜんぶに残る）。
        .onDisappear {
            hovering = false
            syncCursor(dragging: false)
        }
        .accessibilityLabel(Text(label))
    }

    private func syncCursor(dragging isDragging: Bool? = nil) {
        let active = hovering || (isDragging ?? dragging)
        guard active != pushedCursor else { return }
        if active {
            (axis == .height ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
        } else {
            NSCursor.pop()
        }
        pushedCursor = active
    }
}

/// 下に置いたときの詳細パネル。
///
/// **中身は右に置くときと同じ `InspectorView`。** 置き場所ごとに別の画面を
/// 作ると、タブを 1 つ足すたびに 2 か所を直すことになる。変わるのは上の 1 行
/// （ログパネルと同じ作りの見出し）だけ。
private struct DockedInspector: View {
    let moveToTrailing: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            InspectorView()
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// **名前を書かない。** すぐ下の `InspectorView` の見出しが対象の名前を
    /// 出しており、並べると同じ名前が 2 行続く。ここが持つのは行き先だけ。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sidebar.squares.trailing")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("詳細")
                .font(.subheadline.weight(.medium))

            Spacer(minLength: 8)

            Button(action: moveToTrailing) {
                Label("右に戻す", systemImage: "sidebar.trailing")
            }
            .help("詳細パネルを右の欄に戻す")

            Button(action: close) {
                Label("閉じる", systemImage: "xmark")
            }
            .help("詳細パネルを閉じる。もう一度出すにはツールバーの「詳細」")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}
