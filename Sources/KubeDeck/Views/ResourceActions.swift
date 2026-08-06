import SwiftUI

// MARK: - 何ができるか

/// 対象 1 つ（あるいは選択中のまとまり）に効く操作。
///
/// **出し分けを 2 か所に書かない。** 以前は一覧の右クリックメニューだけが
/// 操作を持ち、種別ごとの判定（scale が効くか、cordon できるか）もその場に
/// 直接書いてあった。詳細パネルにも同じ操作を置くにあたって別々に書くと、
/// `PodLogRequest` で一度踏んだのと同じ壊れ方 —— **片方からしか操作できない
/// 種別**ができ、しかも足したときには気付けない。メニューもボタンも
/// `ResourceActionSet.actions(for:target:openWindow:)` の返す配列から作る。
struct ResourceAction: Identifiable {
    /// 並べる場所。メニューでは区切り線、ボタンの列では出す・出さないになる。
    /// **危険度を段で分ける**という同じ話で、削除だけは別扱いにする。
    enum Group {
        /// クラスタが動くもの、とログ。
        case primary
        /// コピーや選択の解除。**クラスタは動かない。**
        case utility
        /// 消えるもの。
        case destructive
    }

    let id: String
    /// メニューに出す名前。横に広いので括弧付きの正式名まで書ける。
    let title: String
    /// ボタンに出す名前。詳細パネルは 300pt まで縮むので、ここは短く。
    /// **短くしても取り違えさせない** —— cordon と drain は kubectl の語を
    /// そのまま出す（「止める」「退避」と訳し分けても、押す側には区別が
    /// 付かない）。長い名前はツールチップに出る。
    let shortTitle: String
    let symbol: String
    let group: Group
    /// クラスタを動かすか。
    ///
    /// **`group` で代用しない。** ログは `.primary` だが何も変えないので、
    /// 読み取り専用のクラスタでも出してよい。逆に「変えるもの」を見落とすと、
    /// 読み取り専用が**穴のある約束**になる。
    var mutates = false
    let run: @MainActor (ResourceActionHost, ClusterStore) -> Void
}

enum ResourceActionSet {
    /// **1 件と複数で出すものを変える。** 複数選んでいるときに「ログを見る」を
    /// 出すと、どれのログなのか決まらない。まとめてできることだけを出し、
    /// **件数を必ず書く。**
    ///
    /// 窓を開くのは `OpenWindowAction` だが、**それを直に受け取らない** —
    /// 外から作れない型なので、受け取ると出し分けの判定ごとテストから
    /// 触れなくなる（ここは「どの種別に何が出るか」を決めている場所で、
    /// 黙ってずれると片方の入口からだけ操作できない種別ができる）。
    @MainActor
    static func actions(
        for objects: [K8sObject], target: ResourceTarget?,
        isReadOnly: Bool = false,
        openLogWindow: @escaping (PodLogRequest) -> Void
    ) -> [ResourceAction] {
        guard let object = objects.first else { return [] }
        let all = objects.count > 1
            ? bulk(objects, target: target)
            : single(object, target: target, openLogWindow: openLogWindow)
        // **読み取り専用なら、押せる形で残さない。** 灰色にして残すやり方も
        // あるが、押せないボタンが並ぶより、できることだけが並ぶほうが速い
        // （できない理由は帯とツールバーの札が言う）。
        return isReadOnly ? all.filter { !$0.mutates } : all
    }

    @MainActor
    private static func single(
        _ object: K8sObject, target: ResourceTarget?,
        openLogWindow: @escaping (PodLogRequest) -> Void
    ) -> [ResourceAction] {
        var actions: [ResourceAction] = []

        // 開ける種別かの判定は `PodLogRequest` だけが持つ（Pod と Job）。
        // ここで `object.kind` を並べ直すと、種別を足したときに片方だけ直す。
        if let request = PodLogRequest(object: object) {
            actions.append(
                ResourceAction(
                    id: "logs", title: "ログを見る", shortTitle: "ログ",
                    symbol: "text.alignleft", group: .primary
                ) { _, store in store.showLogs(for: object) })
            actions.append(
                ResourceAction(
                    id: "logs-window", title: "ログを別ウインドウで見る",
                    shortTitle: "ログ（別窓）", symbol: "macwindow.on.rectangle",
                    group: .utility
                ) { _, _ in openLogWindow(request) })
        }

        // **中に入る手段を置く。** 落ちた理由を追うとき、ログの次に必ず要る。
        // 無いあいだは、ここまで来てターミナルに戻ることになっていた。
        //
        // **読み取り専用では出さない。** 入ってしまえば中で何でもできるので、
        // 「読むだけ」の約束が守れない（`mutates` に入れる理由）。
        if object.kind == .pod {
            actions.append(
                ResourceAction(
                    id: "exec", title: "ターミナルで中に入る (exec)…",
                    shortTitle: "exec…", symbol: "terminal",
                    group: .primary, mutates: true
                ) { host, _ in host.execTarget = object })
        }

        // **種別名が決まらないときは、クラスタを動かす操作を出さない。**
        // kubectl に渡す名前は開いている一覧から取る
        // （`ClusterStore.currentResourceName`）ので、それが無いまま出すと
        // 「押しても何も起きないボタン」になる。
        if let target {
            let kind = target.builtIn
            let kindName = target.displayName

            if kind?.isScalable == true {
                actions.append(
                    ResourceAction(
                        id: "scale", title: "レプリカ数を変える…", shortTitle: "レプリカ数…",
                        symbol: "plusminus", group: .primary, mutates: true
                    ) { host, _ in host.scaleTarget = object })
            }
            if kind?.supportsRollout == true {
                actions.append(
                    ResourceAction(
                        id: "restart", title: "ローリング再起動…", shortTitle: "再起動…",
                        symbol: "arrow.triangle.2.circlepath", group: .primary,
                        mutates: true
                    ) { host, _ in
                        host.pending = .restart(object, kindName: kindName)
                    })
                // **戻す手段を置く。** 更新を掛けられて再起動もできるのに
                // 戻せないと、悪い版を出したときに打つ手がターミナルにしか
                // 無くなる（いちばん急いでいる場面で）。
                actions.append(
                    ResourceAction(
                        id: "rollback", title: "前の状態に戻す (rollout undo)…",
                        shortTitle: "ロールバック…", symbol: "arrow.uturn.backward",
                        group: .primary, mutates: true
                    ) { host, _ in host.rollbackTarget = object })
            }
            // **YAML の自由編集に任せない。** requests / limits はいちばん
            // 頻繁に触る値なのに、YAML ではいちばん危ない直し方になる。
            if ResourcePatch.supports(kind) {
                actions.append(
                    ResourceAction(
                        id: "resources", title: "資源の割り当てを変える…",
                        shortTitle: "資源…", symbol: "gauge.with.dots.needle.33percent",
                        group: .primary, mutates: true
                    ) { host, _ in host.resourcesTarget = object })
            }
            if kind?.supportsRolloutPause == true {
                let paused = object.spec?["paused"]?.boolValue == true
                actions.append(
                    ResourceAction(
                        id: "rollout-pause",
                        title: paused ? "更新を再開 (rollout resume)…" : "更新を止める (rollout pause)…",
                        shortTitle: paused ? "更新を再開…" : "更新を止める…",
                        symbol: paused ? "play.circle" : "pause.circle",
                        group: .primary, mutates: true
                    ) { host, _ in
                        host.pending = .rolloutPause(
                            object, kindName: kindName, paused: !paused)
                    })
            }
            if kind == .node {
                let unschedulable = object.spec?["unschedulable"]?.boolValue == true
                actions.append(
                    ResourceAction(
                        id: "cordon",
                        title: unschedulable
                            ? "スケジュールを許可 (uncordon)…" : "スケジュールを止める (cordon)…",
                        shortTitle: unschedulable ? "uncordon…" : "cordon…",
                        symbol: unschedulable ? "play.circle" : "pause.circle",
                        group: .primary, mutates: true
                    ) { host, _ in
                        host.pending = .cordon(object, unschedulable: !unschedulable)
                    })
                // drain は cordon の次にやる操作。片方だけだと導線が途切れる。
                actions.append(
                    ResourceAction(
                        id: "drain", title: "Pod を退避させる (drain)…", shortTitle: "drain…",
                        symbol: "arrow.up.forward.square", group: .primary,
                        mutates: true
                    ) { host, _ in host.drainTarget = object })
            }
        }

        // **種別で出し分けない。** 書き戻しは YAML そのものを送るので、
        // 組み込みでも CRD でも同じ 1 経路で効く（`kubectl replace -f -` は
        // 種別を YAML から読む）。ただし種別名が決まらないときは、そもそも
        // YAML を引く先が決まらないので出さない。
        if target != nil {
            actions.append(
                ResourceAction(
                    id: "edit-yaml", title: "YAML を編集…", shortTitle: "YAML を編集…",
                    symbol: "pencil", group: .primary, mutates: true
                ) { host, _ in host.editTarget = object })
        }

        actions.append(
            ResourceAction(
                id: "copy-name", title: "名前をコピー", shortTitle: "名前をコピー",
                symbol: "doc.on.doc", group: .utility
            ) { _, _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(object.name, forType: .string)
            })

        if let target, target.builtIn != .event {
            let kindName = target.displayName
            actions.append(
                ResourceAction(
                    id: "delete", title: "削除…", shortTitle: "削除…",
                    symbol: "trash", group: .destructive, mutates: true
                ) { host, _ in
                    host.pending = .delete(object, kindName: kindName)
                })
        }
        return actions
    }

    /// まとめてできることだけ。**件数を必ず書く。**
    @MainActor
    private static func bulk(
        _ objects: [K8sObject], target: ResourceTarget?
    ) -> [ResourceAction] {
        var actions: [ResourceAction] = [
            ResourceAction(
                id: "copy-names", title: "名前をコピー (\(objects.count) 件)",
                shortTitle: "名前をコピー", symbol: "doc.on.doc", group: .utility
            ) { _, _ in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(
                    objects.map(\.name).joined(separator: "\n"), forType: .string)
            },
            ResourceAction(
                id: "clear-selection", title: "選択を解除", shortTitle: "選択を解除",
                symbol: "xmark.circle", group: .utility
            ) { _, store in store.clearSelection() },
        ]

        if let target, target.builtIn != .event {
            let kindName = target.displayName
            actions.append(
                ResourceAction(
                    id: "delete-many", title: "削除… (\(objects.count) 件)",
                    shortTitle: "削除… (\(objects.count) 件)", symbol: "trash",
                    group: .destructive, mutates: true
                ) { host, _ in
                    host.pending = .deleteMany(objects, kindName: kindName)
                })
        }
        return actions
    }
}

// MARK: - 確認とシートの置き場所

/// 確認待ちの操作と、開いているシート。
///
/// **確認とシートを画面ごとに持たない。** 一覧と詳細パネルがそれぞれ
/// `confirmationDialog` を持つと、同じ操作の文面が 2 つになり、足したものだけ
/// 確認を付け忘れる余地が戻ってくる（実際、以前は再起動と cordon が素通り
/// していた）。ここに集めて `RootView` が 1 度だけ presenting する。
@MainActor
@Observable
final class ResourceActionHost {
    var pending: PendingAction?
    var scaleTarget: K8sObject?
    var drainTarget: K8sObject?
    var rollbackTarget: K8sObject?
    var editTarget: K8sObject?
    var resourcesTarget: K8sObject?
    var execTarget: K8sObject?
}

extension View {
    /// 確認とシートを 1 か所で出す。**`RootView` にだけ付ける。**
    func resourceActionPresenter(_ host: ResourceActionHost) -> some View {
        modifier(ResourceActionPresenter(host: host))
    }
}

private struct ResourceActionPresenter: ViewModifier {
    @Environment(ClusterStore.self) private var store
    @Bindable var host: ResourceActionHost

    func body(content: Content) -> some View {
        content
            // **打ち込ませるものは、確認のダイアログでは出せない**（文字を
            // 受け取れない）。同じ `PendingAction` のまま、出し方だけ分ける。
            .confirmationDialog(
                host.pending?.title ?? "",
                isPresented: Binding(
                    get: { host.pending?.requiredPhrase == nil && host.pending != nil },
                    set: { if !$0 { host.pending = nil } }),
                presenting: host.pending
            ) { action in
                Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                    let action = action
                    host.pending = nil
                    Task { await action.run(store) }
                }
                Button("やめる", role: .cancel) { host.pending = nil }
            } message: { action in
                // **どのクラスタに効くのかを、確認の文面に必ず入れる。**
                // 操作ごとに書くと足したものだけ書き忘れるので、ここで前に置く
                // （確認を 1 か所にまとめてあるのと同じ理由）。
                Text("クラスタ: \(store.contextDisplayName)\n\n" + action.message)
            }
            .sheet(item: Binding(
                get: { host.pending?.requiredPhrase == nil ? nil : host.pending },
                set: { if $0 == nil { host.pending = nil } })
            ) { action in
                TypedConfirmSheet(action: action) { host.pending = nil }
            }
            .sheet(item: $host.scaleTarget) { object in
                ScaleSheet(object: object)
            }
            .sheet(item: $host.drainTarget) { object in
                DrainSheet(node: object)
            }
            .sheet(item: $host.rollbackTarget) { object in
                RollbackSheet(object: object)
            }
            .sheet(item: $host.editTarget) { object in
                YAMLEditSheet(object: object)
            }
            .sheet(item: $host.resourcesTarget) { object in
                ResourcesSheet(object: object)
            }
            .sheet(item: $host.execTarget) { object in
                ExecSheet(pod: object)
            }
    }
}

/// 名前を打ち込ませてから実行する確認。
///
/// **「よろしいですか？」の強い版ではない。** ボタンをもう 1 つ増やしても、
/// 押す速さは変わらない。**手を止めさせる**ために、消すものの名前を写させる。
/// 使うのは Namespace の削除のような、戻せないうえに一覧の行がどれも同じ
/// 見た目のものだけ（何にでも求めると、読まずに写す作業になる）。
private struct TypedConfirmSheet: View {
    @Environment(ClusterStore.self) private var store
    let action: PendingAction
    let dismiss: () -> Void

    @State private var typed = ""

    private var phrase: String { action.requiredPhrase ?? "" }
    private var matches: Bool {
        typed.trimmingCharacters(in: .whitespaces) == phrase
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(action.title, systemImage: StatusLevel.critical.symbol)
                .font(.headline)
                .foregroundStyle(Palette.textColor(for: .critical))

            Text("クラスタ: \(store.contextDisplayName)")
                .font(.callout)
                .foregroundStyle(.secondary)

            Text(action.message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("続けるには「\(phrase)」と入力してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: $typed, prompt: Text(phrase))
                    .textFieldStyle(.roundedBorder)
                    // YAML の欄と同じ理由。勝手に置き換えられると別の文字になる。
                    .autocorrectionDisabled()
            }

            HStack {
                Spacer()
                Button("やめる", role: .cancel) { dismiss() }
                Button("削除する", role: .destructive) {
                    let action = action
                    dismiss()
                    Task { await action.run(store) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!matches)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}

// MARK: - メニュー

/// 右クリックのメニュー。**中身は `ResourceActionSet` から作る。**
struct ResourceActionMenu: View {
    @Environment(ClusterStore.self) private var store
    @Environment(ResourceActionHost.self) private var host
    @Environment(\.openWindow) private var openWindow

    let objects: [K8sObject]
    let target: ResourceTarget?

    var body: some View {
        let actions = ResourceActionSet.actions(
            for: objects, target: target, isReadOnly: store.isReadOnly,
            openLogWindow: { openWindow(id: LogWindow.id, value: $0) })
        let primary = actions.filter { $0.group == .primary }
        let utility = actions.filter { $0.group == .utility }
        let destructive = actions.filter { $0.group == .destructive }

        Group {
            // 何件に効くのかを先に書く。件数が出ていないと、見えている選択とは
            // 別のものが消えたときに気付けない。
            if objects.count > 1 {
                Text("\(objects.count) 件を選択中")
                Divider()
            }
            // **できない理由を、できないことより先に出す。** 何も無いメニューが
            // 出ると、壊れているのか権限が無いのか分からない。
            if store.isReadOnly {
                Text("\(store.contextDisplayName) は読み取り専用")
                Divider()
            }
            ForEach(primary) { item($0) }
            if !primary.isEmpty, !utility.isEmpty { Divider() }
            ForEach(utility) { item($0) }
            if !destructive.isEmpty { Divider() }
            ForEach(destructive) { item($0) }
        }
    }

    private func item(_ action: ResourceAction) -> some View {
        Button(action.title, role: action.group == .destructive ? .destructive : nil) {
            action.run(host, store)
        }
    }
}

// MARK: - ボタンの列

/// 詳細パネルに置く操作のボタン。
///
/// **メニューの中だけに操作を置かない。** 右クリックは「そこに何かある」ことが
/// 画面に出ていないので、drain も cordon もレプリカ数も、知っている人にしか
/// 使えない操作になっていた。詳細パネルは対象の名前が見出しに出ている場所
/// なので、そのすぐ下に並べれば何に効くのかが読める。
///
/// **出すのはクラスタが動くものとログだけ**（`utility` は出さない）。名前は
/// 見出しから選んでコピーできるし、ボタンが増えるほど肝心の操作が埋もれる。
struct ResourceActionBar: View {
    @Environment(ClusterStore.self) private var store
    @Environment(ResourceActionHost.self) private var host
    @Environment(\.openWindow) private var openWindow

    let objects: [K8sObject]
    let target: ResourceTarget?

    /// ボタンとして出す上限。
    ///
    /// **増えたぶんだけ並べない。** 操作を足していったら Deployment で 7 個に
    /// なり、300pt の欄では 3〜4 段に折り返して**タブと中身を下へ押し出した**
    /// （詳細を見に来たのに詳細が見えない）。よく使う手前の 3 つだけ出し、
    /// 残りは「…」に畳む。**畳んだものも必ずどこかから届く** —— 中身は
    /// 一覧の右クリックと同じ `ResourceActionSet` なので、抜け落ちはしない。
    private static let visibleCount = 3

    var body: some View {
        let actions = ResourceActionSet.actions(
            for: objects, target: target, isReadOnly: store.isReadOnly,
            openLogWindow: { openWindow(id: LogWindow.id, value: $0) })
        let shown = actions.filter { $0.group != .utility }
        let visible = Array(shown.prefix(Self.visibleCount))
        let overflow = Array(shown.dropFirst(Self.visibleCount)) + actions.filter {
            $0.group == .utility
        }

        if !visible.isEmpty {
            ActionFlow {
                ForEach(visible) { action in
                    button(action)
                }
                if !overflow.isEmpty {
                    Menu {
                        ForEach(overflow) { action in
                            Button(
                                action.title,
                                role: action.group == .destructive ? .destructive : nil
                            ) { action.run(host, store) }
                        }
                    } label: {
                        Label("その他", systemImage: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    .fixedSize()
                    .help("残りの操作")
                }
            }
        }
    }

    @ViewBuilder
    private func button(_ action: ResourceAction) -> some View {
        let button = Button {
            action.run(host, store)
        } label: {
            Label(action.shortTitle, systemImage: action.symbol)
                .lineLimit(1)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        // 短い名前で出しているので、正式な名前はここに残す。
        .help(action.title)

        if action.group == .destructive {
            // **全部を赤にしない。** 赤の意味が薄れる。
            button.tint(Palette.color(for: .critical))
        } else {
            button
        }
    }
}

/// 幅に収まらなくなったら折り返す横並び。
///
/// **`HStack` のままにしない。** 詳細パネルは 300pt まで縮むので、ボタンが
/// 3 つ並ぶだけで 1 つずつ潰れ、どれも読めなくなる（配置の帯で踏んだのと同じ）。
private struct ActionFlow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = rows(width: proposal.width, sizes: sizes)

        var width: CGFloat = 0
        var height: CGFloat = 0
        for row in rows {
            let widths = row.reduce(CGFloat(0)) { $0 + sizes[$1].width }
            width = max(width, widths + CGFloat(row.count - 1) * spacing)
            height += row.map { sizes[$0].height }.max() ?? 0
        }
        return CGSize(
            width: width, height: height + CGFloat(rows.count - 1) * lineSpacing)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        var y = bounds.minY
        for row in rows(width: bounds.width, sizes: sizes) {
            var x = bounds.minX
            let height = row.map { sizes[$0].height }.max() ?? 0
            for index in row {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index]))
                x += sizes[index].width + spacing
            }
            y += height + lineSpacing
        }
    }

    /// **幅が有限のときだけ折り返しを数える。** SwiftUI は「いちばん広いとき」を
    /// 訊くために `.infinity` を、幅の指定が無いときは `nil` を提案してくる。
    /// どちらも 1 行に全部として答える（`Int(.infinity)` を作らないこと。
    /// `SectionColumns` で実際に落ちた）。幅 0 の提案では 1 つずつ折り返るので、
    /// 伸び縮みしない子だとは判断されない。
    private func rows(width: CGFloat?, sizes: [CGSize]) -> [[Int]] {
        guard let width, width.isFinite else { return [Array(sizes.indices)] }

        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            let needed = current.isEmpty ? size.width : used + spacing + size.width
            if !current.isEmpty, needed > width {
                rows.append(current)
                current = [index]
                used = size.width
            } else {
                current.append(index)
                used = needed
            }
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - 確認してから実行するもの

/// 押した瞬間には効かない操作。
///
/// **「取り消せる操作」と「取り消せない操作」を同じ手触りにしない。** 選択や
/// 絞り込みはすぐ効いてよいが、削除・再起動・退避はクラスタが動く。とくに
/// **メニューは指が滑る場所**なので、ここを素通りにしない。
///
/// **文面に「何が起きるか」を書く。** 「よろしいですか？」だけの確認は、
/// 読まずに押す癖を作るだけで何も守らない。
struct PendingAction: Identifiable {
    let id: String
    let title: String
    let message: String
    let confirmLabel: String
    let isDestructive: Bool
    /// これを打ち込ませてから実行する。
    ///
    /// **数を絞る。** 何にでも要求すると、読まずに写す作業になって意味が消える。
    /// いまは Namespace の削除だけ —— クラスタでいちばん戻せない操作で、
    /// しかも**押し間違いが一瞬で終わる**（一覧の行はどれも同じ見た目）。
    var requiredPhrase: String?
    private let action: @MainActor (ClusterStore) async -> Void

    @MainActor
    func run(_ store: ClusterStore) async { await action(store) }

    static func delete(_ object: K8sObject, kindName: String) -> PendingAction {
        PendingAction(
            id: "delete-\(object.id)",
            title: "削除しますか？",
            message: "\(kindName) \(object.name) を削除します。取り消せません。\n\n"
                + cascade(for: object.kind),
            confirmLabel: "削除",
            isDestructive: true,
            requiredPhrase: object.kind == .namespace ? object.name : nil,
            action: { await $0.delete(object) })
    }

    /// 消したときに**何が道連れになるか**。
    ///
    /// **種別を問わず同じ文面にしない。** ConfigMap を 1 つ消すのと、Namespace を
    /// 消して中身を全部消すのと、PVC を消してデータごと消えるのとでは、
    /// 取り返しのつかなさがまるで違う。「取り消せません」だけでは、そのどれなのかが
    /// 読み取れない。
    ///
    /// **安心できることも書く。** 所有者のいる Pod は消えっぱなしにならない。
    /// そこを黙ると、確かめれば分かることを怖がらせるだけになる。
    static func cascade(for kind: ResourceKind?) -> String {
        switch kind {
        case .namespace:
            return "この Namespace の中にあるものが、すべて一緒に消えます"
                + "（Pod・Service・ConfigMap・Secret・PVC など）。"
                + "クラスタでいちばん戻せない操作です。"
        case .persistentVolumeClaim:
            return "つながっている PersistentVolume の扱いは StorageClass の"
                + "reclaim policy で決まります。Delete なら中のデータごと消えます。"
        case .persistentVolume:
            return "reclaim policy が Delete なら、実体（ディスク）ごと消えます。"
        case .deployment, .statefulSet, .daemonSet, .replicaSet, .job, .cronJob:
            return "管理下の Pod も一緒に消えます。動いている処理は中断されます。"
        case .pod:
            return "所有者（Deployment など）があれば、すぐに作り直されます。"
                + "そうでない Pod は消えたままになります。"
        case .service:
            return "この Service 宛の通信が届かなくなります"
                + "（Pod は動き続けます）。"
        case .node:
            return "クラスタからノードの登録を外すだけで、マシン自体は消えません。"
                + "載っている Pod は行き場を失います。"
                + "**先に drain してください**（退避せずに外すと、そのまま止まります）。"
        case .secret, .configMap:
            return "参照している Pod は、動いているあいだは止まりませんが、"
                + "次に作り直されるときに起動できなくなります。"
        case .clusterRoleBinding, .roleBinding, .clusterRole, .role, .serviceAccount:
            return "これに頼っている処理が、権限不足で動かなくなることがあります。"
        default:
            return "元に戻すには、同じものを作り直すことになります。"
        }
    }

    /// **件数と、中身の一部を出す。** 「3 件を削除します」だけだと、何を
    /// 選んでいたか確かめずに押すことになる。全部は入らないので頭だけ書く。
    static func deleteMany(_ objects: [K8sObject], kindName: String) -> PendingAction {
        let shown = objects.prefix(5).map(\.name).joined(separator: "\n")
        let rest = objects.count - min(5, objects.count)
        return PendingAction(
            id: "delete-many-\(objects.map(\.id).joined(separator: ","))",
            title: "\(objects.count) 件を削除しますか？",
            message: "次の \(kindName) を削除します。取り消せません。\n\n"
                + shown + (rest > 0 ? "\n他 \(rest) 件" : "")
                + "\n\n" + cascade(for: objects.first?.kind),
            confirmLabel: "\(objects.count) 件を削除",
            isDestructive: true,
            // まとめて消すときは 1 つでも Namespace が混ざっていたら打たせる。
            requiredPhrase: objects.contains { $0.kind == .namespace }
                ? "\(objects.count) 件を削除" : nil,
            action: { await $0.deleteSelected() })
    }

    static func restart(_ object: K8sObject, kindName: String) -> PendingAction {
        PendingAction(
            id: "restart-\(object.id)",
            title: "ローリング再起動しますか？",
            message: "\(kindName) \(object.name) の Pod を順に入れ替えます。"
                + "入れ替わっているあいだ、実行中の処理は中断されます。",
            confirmLabel: "再起動する",
            // 消えるわけではないので赤にはしない。**危険度を段で分ける。**
            isDestructive: false,
            action: { await $0.restart(object) })
    }

    /// 更新を止める / 再開する。
    ///
    /// **「止まる」だけを書かない。** 止めた Deployment は
    /// `kubectl get` では `3/3` のまま健全に見えるのに、spec を変えても
    /// Pod が入れ替わらない（HPA の `<unknown>` と同じ「数字が揃ったまま
    /// 何もしていない」状態）。しかも実測で**止めているあいだはロールバックも
    /// できない**（`you cannot rollback a paused deployment`）ので、
    /// 後で困る 2 つを先に書く。
    static func rolloutPause(
        _ object: K8sObject, kindName: String, paused: Bool
    ) -> PendingAction {
        PendingAction(
            id: "rollout-pause-\(object.id)-\(paused)",
            title: paused ? "更新を止めますか？" : "更新を再開しますか？",
            message: paused
                ? "\(kindName) \(object.name) の更新を止めます。"
                    + "設定を変えても Pod は入れ替わらなくなり、"
                    + "止めているあいだは前の状態にも戻せません。"
                    + "一覧の Ready の数は揃ったままなので、止めたことは表に出ません。"
                : "\(kindName) \(object.name) の更新を再開します。"
                    + "止めているあいだに変えた設定は、まとめて反映されます。",
            confirmLabel: paused ? "止める" : "再開する",
            isDestructive: false,
            action: { await $0.setRolloutPaused(object, paused: paused) })
    }

    static func cordon(_ node: K8sObject, unschedulable: Bool) -> PendingAction {
        PendingAction(
            id: "cordon-\(node.id)-\(unschedulable)",
            title: unschedulable ? "スケジュールを止めますか？" : "スケジュールを許可しますか？",
            message: unschedulable
                // いま載っている Pod は動かない、を明記する。cordon と drain を
                // 取り違えたまま押されると、期待した退避が起きない。
                ? "\(node.name) に新しい Pod が置かれなくなります。"
                    + "いま載っている Pod はそのまま動き続けます（退避は drain）。"
                : "\(node.name) に新しい Pod が置かれるようになります。",
            confirmLabel: unschedulable ? "止める" : "許可する",
            isDestructive: false,
            action: { await $0.setCordon(node, unschedulable: unschedulable) })
    }
}

// MARK: - シート

/// ノードから Pod を退避させる。
///
/// **確認の文面を自分で数えて作らない。** 退避できるかは PodDisruptionBudget や
/// DaemonSet の有無で決まる。こちらで「Pod が N 個あります」と書いても、kubectl が
/// 実際にやることとずれる。`--dry-run=server` に**同じ判断をさせて**、返ってきた
/// ものをそのまま見せる。
struct DrainSheet: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let node: K8sObject

    @State private var options = Kubectl.DrainOptions()
    @State private var preview: String?
    @State private var previewFailure: String?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pod を退避させる (drain)")
                    .font(.headline)
                Text(node.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            // 既定は「消えるもの」を選ばない。付けないと drain が止まる場面が
            // あるが、**止まるほうが黙って消すよりよい。**
            VStack(alignment: .leading, spacing: 8) {
                Toggle(isOn: $options.deleteEmptyDirData) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("emptyDir の中身を捨ててよい")
                        Text("そのノード上のディスクにしかないデータは失われます。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $options.force) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("管理されていない Pod も消す")
                        Text("ReplicaSet などに属さない Pod は、消すと作り直されません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .toggleStyle(.checkbox)

            Divider()

            previewSection

            HStack {
                Spacer()
                Button("やめる", role: .cancel) { dismiss() }
                Button("退避させる") {
                    let options = options
                    dismiss()
                    Task { await store.drain(node, options: options) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 470)
        // 選び直すたびに聞き直す。設定と食い違う見積もりを残さない。
        .task(id: options) { await check() }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("実行するとこうなります")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isChecking { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                if let count = evictionCount {
                    Text("退避する Pod \(count) 個")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            ScrollView {
                Text(previewText)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 130)
            .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 8))

            if previewFailure != nil {
                // **これを失敗として隠さない。** 止まった理由（`--force` が要る、
                // PodDisruptionBudget に弾かれた）は、まさに読みたいもの。
                Label(
                    "このままでは止まります。上の文面が理由です。",
                    systemImage: StatusLevel.warning.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .warning))
            }
        }
    }

    private var previewText: String {
        if let previewFailure { return previewFailure }
        if let preview {
            return preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                // 何も出ないのは「退避するものが無い」。空欄にすると
                // 「調べられなかった」と見分けが付かない。
                ? "退避する Pod はありません。"
                : preview
        }
        return "調べています…"
    }

    /// kubectl が退避すると言った Pod の数。数え方を自分で決めない。
    private var evictionCount: Int? {
        guard let preview else { return nil }
        return preview.split(separator: "\n").filter { $0.contains("evicting pod") }.count
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        switch await store.drainPreview(node, options: options) {
        case .success(let text):
            preview = text
            previewFailure = nil
        case .failure(let error):
            preview = nil
            previewFailure = error.localizedDescription
        }
    }
}

/// 前の状態に戻す（`kubectl rollout undo`）。
///
/// **「1 つ前に戻す」だけにしない。** 悪い版が何回か続いていることはふつうに
/// あり、そのとき 1 つ前は同じく悪い。世代を選べないと、押しては確かめるを
/// 繰り返すことになる。
///
/// **戻る先の中身も、戻したら何が起きるかも kubectl に答えさせる**（drain と
/// 同じ扱い）。こちらで「同じ版だから何も起きない」「止めているから戻せない」を
/// 判断すると、kubectl の判断とずれる余地を作るだけ。
struct RollbackSheet: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let object: K8sObject

    /// **「まだ引いていない」「引いたが 0 件」「引けなかった」を混ぜない。**
    @State private var revisions: [Kubectl.RolloutRevision]?
    @State private var historyFailure: String?
    @State private var selected: Int?
    @State private var detail: String?
    @State private var preview: String?
    @State private var previewFailure: String?
    @State private var isChecking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("前の状態に戻す (rollout undo)")
                    .font(.headline)
                Text(object.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            revisionPicker

            Divider()

            detailSection

            HStack {
                Spacer()
                Button("やめる", role: .cancel) { dismiss() }
                Button("戻す") {
                    let revision = selected
                    dismiss()
                    Task { await store.rollback(object, toRevision: revision) }
                }
                .keyboardShortcut(.defaultAction)
                // 世代が 1 つも読めていないときに押させない（何に戻すのか
                // 決まっていない）。
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await loadHistory() }
        .task(id: selected) { await loadSelection() }
    }

    @ViewBuilder
    private var revisionPicker: some View {
        if let historyFailure {
            // **「世代がありません」と言わない。** 引けなかっただけ。
            Label("世代の一覧を取得できません", systemImage: StatusLevel.warning.symbol)
                .font(.caption.weight(.medium))
                .foregroundStyle(Palette.textColor(for: .warning))
            Text(historyFailure)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if let revisions {
            if revisions.count < 2 {
                // 世代が 1 つしか無ければ戻る先が無い。**空の選択肢を出さない。**
                Label(
                    "この \(object.kind?.displayName ?? "ワークロード")には、"
                        + "まだ戻れる世代がありません。",
                    systemImage: StatusLevel.warning.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .warning))
            } else {
                Picker("戻す先", selection: $selected) {
                    // 新しい順に出す。戻したいのはたいてい直前。
                    ForEach(revisions.reversed()) { revision in
                        Text(label(for: revision)).tag(Int?.some(revision.revision))
                    }
                }
                .pickerStyle(.menu)
                Text("いま動いているのは第 \(revisions.last?.revision ?? 0) 世代です。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("世代を調べています…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// **理由（`change-cause`）まで出す。** 番号だけ並べても、どれに戻せば
    /// よいのかが決まらない。書かれていないときは「理由なし」と書く
    /// （空欄にすると、読み込めていないのか未記入なのか分からない）。
    private func label(for revision: Kubectl.RolloutRevision) -> String {
        let cause = revision.changeCause ?? "理由なし"
        return "第 \(revision.revision) 世代 — \(cause)"
    }

    @ViewBuilder
    private var detailSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("戻す先の中身")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isChecking { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
            }

            ScrollView {
                Text(detail ?? "選ぶと、その世代の中身が出ます。")
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 150)
            .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 8))

            // **止まる理由を隠さない。** 「同じ世代なので何も起きない」も
            // 「止めているあいだは戻せない」も、押す前に読みたい文面そのもの。
            if let previewFailure {
                Label(previewFailure, systemImage: StatusLevel.warning.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .warning))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let preview, preview.contains("skipped rollback") {
                Label(
                    "この世代はいま動いているものと同じです。押しても何も変わりません。",
                    systemImage: StatusLevel.warning.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .warning))
            }
        }
    }

    private func loadHistory() async {
        switch await store.rolloutHistory(for: object) {
        case .success(let found):
            revisions = found
            // 既定は 1 つ前（kubectl が `--to-revision` 無しでやることと同じ）。
            selected = found.count >= 2 ? found[found.count - 2].revision : nil
        case .failure(let error):
            historyFailure = error.localizedDescription
        }
    }

    private func loadSelection() async {
        guard let selected else { return }
        isChecking = true
        defer { isChecking = false }

        switch await store.revisionDetail(for: object, revision: selected) {
        case .success(let text): detail = text
        case .failure(let error): detail = error.localizedDescription
        }
        switch await store.rollbackPreview(object, toRevision: selected) {
        case .success(let text):
            preview = text
            previewFailure = nil
        case .failure(let error):
            preview = nil
            previewFailure = error.localizedDescription
        }
    }
}

/// レプリカ数の変更。
struct ScaleSheet: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let object: K8sObject

    @State private var replicas: Int = 0

    /// HPA が管理しているか。**「調べていない」「管理下にある」「管理下に
    /// ない」「調べられなかった」を 1 つにしない** — 特に最後の 2 つを
    /// 混ぜると、権限が無くて見えないだけなのに「HPA は無い」と断定する。
    private enum Autoscaler {
        case checking
        case managed([K8sObject])
        case none
        case unavailable
    }
    @State private var autoscaler: Autoscaler = .checking

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("レプリカ数を変える")
                .font(.headline)
            Text(object.name)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 12) {
                Stepper(value: $replicas, in: 0...200) {
                    Text("レプリカ数")
                }
                TextField("", value: $replicas, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
            }

            autoscalerNotice

            if replicas == 0 {
                Label("0 にすると Pod はすべて停止します。", systemImage: StatusLevel.warning.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .warning))
            }

            HStack {
                Spacer()
                Button("やめる", role: .cancel) { dismiss() }
                Button("適用") {
                    let target = replicas
                    dismiss()
                    Task { await store.scale(object, to: target) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
        .onAppear { replicas = object.spec?["replicas"]?.intValue ?? 0 }
        .task {
            switch await store.autoscalers(for: object) {
            case .success(let found):
                autoscaler = found.isEmpty ? .none : .managed(found)
            case .failure:
                autoscaler = .unavailable
            }
        }
    }

    /// **止めない。** HPA 管理下でも手で動かしたい場面はある（調整を待たずに
    /// 増やす、いったん 0 にする）。禁じるのではなく、戻されることを先に言う。
    @ViewBuilder
    private var autoscalerNotice: some View {
        switch autoscaler {
        case .checking, .none:
            // 管理下に無いことをわざわざ書かない。ふつうがそちらなので、
            // 毎回出すと読まれなくなる。
            EmptyView()

        case .managed(let hpas):
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "この \(object.kind?.displayName ?? "ワークロード")"
                        + "は HPA が管理しています。",
                    systemImage: StatusLevel.serious.symbol)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Palette.textColor(for: .serious))
                ForEach(hpas) { hpa in
                    Text("\(hpa.name)（最小 \(hpa.spec?["minReplicas"]?.intValue ?? 1)"
                         + " / 最大 \(hpa.spec?["maxReplicas"]?.intValue ?? 0)）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("ここで変えても、次の調整で HPA が戻します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .unavailable:
            // **「HPA はありません」と言わない。** 引けなかっただけ。
            Text("HPA が管理しているかは確認できませんでした。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
