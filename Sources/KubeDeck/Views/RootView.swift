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
                // 詳細パネルの出し入れを選択に連動させない。連動させると、
                // 左で種別を選んだ瞬間にパネルが現れ、AppKit がその列を作るために
                // ウインドウごと広げる（選ぶたびに窓の幅が変わる）。出す / 畳むは
                // ツールバーのボタンだけが決める。
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
        .overlay(alignment: .bottom) { errorBar }
        // 知らせは帯より上に積む。両方が出るのは、成功の直後に自動更新が
        // 失敗したときぐらいだが、そのとき重なると読めない。
        .overlay(alignment: .bottom) { noticeBar }
        // **消える側に付けても効かない。** 出入りを animate させるには、
        // 残っているほう（この親）に置く必要がある。
        .animation(.easeOut(duration: 0.18), value: store.actionNotice)
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
            Color.clear
                .allowsHitTesting(false)
                .searchable(
                    text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
                    placement: .toolbar,
                    prompt: searchPrompt)
                .disabled(store.selection == .overview)
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
        detail
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if store.logRequest != nil || showsBottomInspector {
                    VStack(spacing: 0) {
                        PanelResizeHandle(
                            axis: .height, value: $dockHeight, range: 120...900,
                            label: "下の帯の高さを変える")
                        dockBody
                    }
                    .frame(height: dockHeight)
                }
            }
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
            HStack(spacing: 0) {
                if let request = store.logRequest {
                    LogPanel(request: request)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if showsBottomInspector {
                    if sharing {
                        PanelResizeHandle(
                            axis: .width, value: $dockInspectorWidth, range: 240...760,
                            label: "詳細パネルの幅を変える")
                    }
                    DockedInspector(
                        moveToTrailing: { preferences.inspectorPlacement = .trailing },
                        close: { showsInspector = false })
                        .frame(width: sharing ? inspectorWidth(in: proxy.size.width) : nil)
                        .frame(maxWidth: sharing ? nil : .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// 掴んだ幅を、いま使える幅に収める。ログ側が消えるところまで詰めさせない。
    private func inspectorWidth(in available: CGFloat) -> CGFloat {
        min(dockInspectorWidth, max(240, available * 0.6))
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
        case .overview: return "概要"
        case .placement: return "配置"
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
        if store.isLoading { return "読み込み中…" }
        // 失敗しているときに「0 件」と出さない。数えられていない。
        if store.selection == .placement {
            if store.errorMessage != nil, store.objects.isEmpty { return "取得できません" }
            return "\(store.placementNodes.count) ノード · "
                + "\(store.filteredObjects.count) Pod"
        }
        guard case .resource = store.selection else { return "" }
        if store.errorMessage != nil, store.objects.isEmpty { return "取得できません" }
        let shown = store.filteredObjects.count
        let total = store.objects.count
        let counts = shown == total ? "\(total) 件" : "\(shown) / \(total) 件"
        // **選んでいる数はここに出す。** 件数の持ち場は副題（同じ数字を
        // 2 か所に置かない）。1 件のときは書かない — ふつうがそちらなので、
        // 常に出すと件数が読みにくくなるだけ。
        let selected = store.selectedObjectIDs.count
        return selected > 1 ? "\(counts) · \(selected) 件選択中" : counts
    }

    /// 絞り込み欄の文言。**画面ごとに相手が違う。** 配置の「たどる」で絞るのは
    /// 左の起点の一覧であって図ではないので、そこだけ書き分ける。
    private var searchPrompt: String {
        switch store.selection {
        case .overview:
            return "絞り込み"
        case .placement:
            return preferences.placementGrouping == .map
                ? "たどる起点を絞り込む" : "Pod を絞り込む"
        case .resource(let target):
            return "\(target.displayName) を絞り込む"
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
                Text(store.currentContext.isEmpty ? "コンテキスト" : store.currentContext)
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
    let label: String

    /// ドラッグ開始時の値。translation は開始点からの差分なので、
    /// 毎回の変化量として足すと動きが加速してしまう。
    @State private var start: CGFloat?

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
            if inside {
                (axis == .height ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    let base = start ?? value
                    if start == nil { start = base }
                    // どちらも「引いた向きと逆に伸びる」縁に付くので符号は負。
                    let delta = axis == .height ? -drag.translation.height : -drag.translation.width
                    value = min(range.upperBound, max(range.lowerBound, base + delta))
                }
                .onEnded { _ in start = nil })
        .accessibilityLabel(Text(label))
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
