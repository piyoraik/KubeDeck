import SwiftUI

struct ResourceListView: View {
    @Environment(ClusterStore.self) private var store
    let target: ResourceTarget

    @Environment(\.openWindow) private var openWindow

    /// 確認してから実行するもの。**押した瞬間に効かせない。**
    @State private var pending: PendingAction?
    @State private var scaleTarget: K8sObject?
    @State private var drainTarget: K8sObject?

    /// 組み込み種別のときだけ、種別ごとの特別扱い（ログ、スケールなど）が効く。
    private var kind: ResourceKind? { target.builtIn }

    var body: some View {
        // **列は body の先頭で 1 度だけ引く。** `store.currentColumns` は
        // 呼ぶたびに列定義（`ResourceColumn` のクロージャ）を丸ごと組み立て直す
        // 計算プロパティで、以前は計算プロパティ越しに `row(for:)` から
        // 参照していたため、**行の数だけ**作り直していた（500 行なら 1 描画で
        // 500 回）。ログの `visibleLines` と同じ話で、先に 1 度作って配る。
        let columns = store.currentColumns

        return table(columns: columns)
        .background(Color(nsColor: .windowBackgroundColor))
        // **絞り込み欄はここに置かない。** ツールバーの項目を画面ごとに
        // 出し入れすると、レイアウト中の `NSToolbar` の書き換えで落ちる。
        // `RootView` が 1 つだけ持ち、文言を切り替える。
        // **確認は 1 か所にまとめる。** 操作ごとに書くと、足したものだけ
        // 確認を付け忘れる（実際、再起動と cordon が素通りしていた）。
        .confirmationDialog(
            pending?.title ?? "",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }),
            presenting: pending
        ) { action in
            Button(action.confirmLabel, role: action.isDestructive ? .destructive : nil) {
                let action = action
                pending = nil
                Task { await action.run(store) }
            }
            Button("やめる", role: .cancel) { pending = nil }
        } message: { action in
            Text(action.message)
        }
        .sheet(item: $scaleTarget) { object in
            ScaleSheet(object: object)
        }
        .sheet(item: $drainTarget) { object in
            DrainSheet(node: object)
        }
    }

    // MARK: - 表

    /// 表は横にもスクロールする。
    ///
    /// ウインドウには最小幅を入れてあるので、窓を狭めると列は要求幅より
    /// 押し潰される。Node や PVC は列が多く、潰れると値が読めなくなる。
    /// 全部の列が読める幅を下限として確保し、足りないぶんは横スクロールへ逃がす。
    private func table(columns: [ResourceColumn]) -> some View {
        GeometryReader { proxy in
            let rows = store.filteredObjects
            let width = max(Self.intrinsicWidth(of: columns), proxy.size.width)

            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    headerRow(columns: columns)
                    Divider()

                    if rows.isEmpty {
                        // 「読み込み中」「取得に失敗」「本当に 0 件」を
                        // 同じ見た目にしない。
                        if store.isLoading {
                            LoadingView(detail: target.displayName)
                        } else if store.errorMessage != nil {
                            failureState
                        } else {
                            emptyState
                        }
                    } else {
                        // 選択をキーボードで動かせるようにすると、選んだ行が
                        // 画面の外にあることが起きる。動いた先まで送る。
                        ScrollViewReader { scroller in
                            ScrollView(.vertical) {
                                LazyVStack(spacing: 0) {
                                    ForEach(rows) { object in
                                        row(for: object, columns: columns)
                                        Divider().opacity(0.5)
                                    }
                                }
                            }
                            .onChange(of: store.selectedObjectID) { _, id in
                                guard let id else { return }
                                scroller.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
                .frame(width: width, height: proxy.size.height)
            }
            // 収まっているときに横方向へ跳ねないようにする。
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            // **見えている幅で切る。** `ScrollView` は safe area まで広がるので、
            // 表が幅より広いとき（metrics-server が入って CPU / メモリ列が
            // 増えたときなど）、はみ出した列が**詳細パネルの下に潜り込む**。
            // 向こうは半透明なので、読めない文字が透けて出るうえ、列がある
            // ことにも気付けない。`GeometryReader` が測っているのは見えている
            // 幅（safe area の内側）なので、そこで切れば横スクロールで届く。
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
            // **`List` を使っていないので、上下移動は付いてこない。** 一覧を
            // 見ながら 1 行ずつ確かめるのは基本の操作なので、自前で足す。
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                // `onMoveCommand` は修飾キーを教えてくれないので、タップと
                // 同じく押された時点の状態を聞く。shift で選択を伸ばす。
                let extending = NSEvent.modifierFlags.contains(.shift)
                switch direction {
                case .up: store.moveSelection(by: -1, extending: extending)
                case .down: store.moveSelection(by: 1, extending: extending)
                default: break
                }
            }
        }
    }

    /// 列がすべて読める最小の幅。列の間隔と左右の余白を足したもの。
    private static func intrinsicWidth(of columns: [ResourceColumn]) -> CGFloat {
        let widths = columns.reduce(into: CGFloat(0)) { total, column in
            switch column.width {
            case .fixed(let value): total += value
            case .flexible(let minimum): total += minimum
            }
        }
        return widths + CGFloat(max(0, columns.count - 1)) * 12 + 32
    }

    // MARK: - 行

    /// 見出しは押すと並べ替えになる。
    ///
    /// **矢印を「並べ替えられる」の合図にしない。** いま並べ替えている列にしか
    /// 出ないので、他の列は押せないように見える。押せることはカーソルと
    /// ツールチップが持ち、矢印は「いまどれで並んでいるか」だけを表す。
    private func headerRow(columns: [ResourceColumn]) -> some View {
        HStack(spacing: 12) {
            ForEach(columns) { column in
                let sort = store.sortDescriptor
                let isActive = sort?.columnTitle == column.title

                Button {
                    store.toggleSort(column: column.title)
                } label: {
                    HStack(spacing: 3) {
                        if column.trailing { Spacer(minLength: 0) }
                        Text(column.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(isActive ? Color.accentColor : .secondary)
                            .lineLimit(1)
                        if isActive, let sort {
                            Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(Color.accentColor)
                        }
                        if !column.trailing { Spacer(minLength: 0) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    isActive
                        ? "\(column.title) で並べ替え中。もう一度押すと逆順、"
                            + "3 度目で既定（異常が上）に戻る"
                        : "\(column.title) で並べ替える")
                .modifier(ColumnFrame(column: column))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Palette.subtleFill)
    }

    private func row(for object: K8sObject, columns: [ResourceColumn]) -> some View {
        let isSelected = store.selectedObjectIDs.contains(object.id)
        // 詳細パネルが映しているのはこれ。複数選んでいるときに、どれの話を
        // しているのかが分からなくなるので、少しだけ濃く出す。
        let isPrimary = store.selectedObjectID == object.id

        return HStack(spacing: 12) {
            ForEach(columns) { column in
                cell(column.value(object), selected: isSelected)
                    .modifier(ColumnFrame(column: column))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Preferences.shared.rowDensity.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected
                ? Color.accentColor.opacity(isPrimary ? 0.20 : 0.10)
                : .clear)
        .contentShape(Rectangle())
        .onTapGesture { handleTap(on: object) }
        .contextMenu {
            // **選んでいないものを右クリックしたら、まずそれを選ぶ。**
            // 選択と操作対象が食い違うと、見えている選択とは別のものが消える。
            menu(for: object)
                .onAppear {
                    if !store.selectedObjectIDs.contains(object.id) {
                        store.selectOnly(object)
                    }
                }
        }
        // 削除中のものは薄く出す。押しても消えない、という誤解を避ける。
        .opacity(object.isTerminating ? 0.55 : 1)
    }

    /// ⌘ で足し引き、shift で範囲、そのままなら 1 つだけ。
    ///
    /// **SwiftUI の `TapGesture().modifiers(_:)` を重ねない。** 修飾つきと
    /// 素のタップを `exclusively` で並べる書き方は、どちらが勝つかが状況で
    /// 変わって取りこぼす。押された時点の修飾キーを AppKit に聞くほうが確実。
    private func handleTap(on object: K8sObject) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            store.toggleSelection(of: object)
        } else if flags.contains(.shift) {
            store.extendSelection(to: object)
        } else {
            store.selectOnly(object)
        }
    }

    @ViewBuilder
    private func cell(_ cell: ResourceCell, selected: Bool) -> some View {
        HStack(spacing: 5) {
            if let level = cell.level, !cell.text.isEmpty {
                Image(systemName: level.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.color(for: level))
            }
            Text(cell.text)
                .font(font(for: cell.emphasis))
                .foregroundStyle(foreground(for: cell))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func font(for emphasis: ResourceCell.Emphasis) -> Font {
        let size = Preferences.shared.rowDensity.fontSize
        switch emphasis {
        case .primary, .secondary: return .system(size: size)
        case .mono: return .system(size: size).monospacedDigit()
        }
    }

    private func foreground(for cell: ResourceCell) -> Color {
        if let level = cell.level, level != .neutral {
            return Palette.textColor(for: level)
        }
        return cell.emphasis == .secondary ? .secondary : .primary
    }

    // MARK: - 操作

    @ViewBuilder
    private func menu(for object: K8sObject) -> some View {
        let selected = store.selectedObjects
        // **複数選んでいるときは、1 つ向けの操作を出さない。** 「ログを見る」が
        // どれのログなのか決まらないし、選択と操作対象が食い違う。
        if selected.count > 1 {
            bulkMenu(selected)
        } else {
            singleMenu(for: object)
        }
    }

    /// まとめてできることだけ。**件数を必ず書く。**
    @ViewBuilder
    private func bulkMenu(_ objects: [K8sObject]) -> some View {
        Text("\(objects.count) 件を選択中")

        Divider()

        Button("名前をコピー (\(objects.count) 件)") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                objects.map(\.name).joined(separator: "\n"), forType: .string)
        }
        Button("選択を解除") { store.clearSelection() }

        if kind != .event {
            Divider()
            Button("削除… (\(objects.count) 件)", role: .destructive) {
                pending = .deleteMany(objects, kindName: target.displayName)
            }
        }
    }

    @ViewBuilder
    private func singleMenu(for object: K8sObject) -> some View {
        Button("詳細を見る") { store.selectOnly(object) }

        // Pod だけでなく Job からも開ける。**Pod をここで解決しない** —
        // メニューを組み立てるたびに kubectl が走ることになる。
        if let logRequest = PodLogRequest(object: object) {
            Button("ログを見る") { store.showLogs(for: object) }
            Button("ログを別ウインドウで見る") {
                openWindow(id: LogWindow.id, value: logRequest)
            }
        }
        if kind?.isScalable == true {
            Button("レプリカ数を変える…") { scaleTarget = object }
        }
        if kind?.isRestartable == true {
            // 押した瞬間に Pod が入れ替わり始める。確認を挟む。
            Button("ローリング再起動…") {
                pending = .restart(object, kindName: target.displayName)
            }
        }
        if kind == .node {
            let unschedulable = object.spec?["unschedulable"]?.boolValue == true
            Button(unschedulable ? "スケジュールを許可 (uncordon)…" : "スケジュールを止める (cordon)…") {
                pending = .cordon(object, unschedulable: !unschedulable)
            }
            // drain は cordon の次にやる操作。片方だけだと導線が途切れる。
            Button("Pod を退避させる (drain)…") { drainTarget = object }
        }

        Divider()

        Button("名前をコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(object.name, forType: .string)
        }

        if kind != .event {
            Divider()
            Button("削除…", role: .destructive) {
                pending = .delete(object, kindName: target.displayName)
            }
        }
    }

    // MARK: - 空

    /// 取得に失敗したとき。**「ありません」と言わない。**
    /// 引けなかっただけで、無いことは確かめていない。
    private var failureState: some View {
        ContentUnavailableView {
            Label("\(target.displayName) を取得できません", systemImage: "exclamationmark.triangle")
        } description: {
            Text("クラスタから応答がありませんでした。件数は分かりません。")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var emptyState: some View {
        let filtering = !store.searchText.trimmingCharacters(in: .whitespaces).isEmpty
        ContentUnavailableView {
            Label(
                filtering ? "一致するものがありません" : "\(target.displayName) がありません",
                systemImage: target.symbol)
        } description: {
            if filtering {
                // **書き方はここで教える。** 絞り込みの語彙は、うまく絞れて
                // いないときにいちばん知りたい。欄の脇に常に出すと、ふだんは
                // ただの飾りになる。
                VStack(alignment: .leading, spacing: 8) {
                    Text("「\(store.searchText)」に一致する \(target.displayName) は見つかりませんでした。")
                    Text(Self.searchSyntaxHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if target.isNamespaced, let namespace = store.selectedNamespace {
                Text("Namespace 「\(namespace)」には \(target.displayName) がありません。")
            } else {
                Text("このクラスタには \(target.displayName) がありません。")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 絞り込みで打てる形。**本物のセレクタは実装していない**ので、
    /// できることだけを書く（`!key` や `in (a,b)` が効くと思わせない）。
    private static let searchSyntaxHint = """
        空白で区切るとすべてに一致するものだけが残ります。
        app=nginx（ラベルが一致）· app=（ラベルを持つ）
        ns:kube-system · status:CrashLoopBackOff · node:node-a
        """
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
    private let action: @MainActor (ClusterStore) async -> Void

    @MainActor
    func run(_ store: ClusterStore) async { await action(store) }

    static func delete(_ object: K8sObject, kindName: String) -> PendingAction {
        PendingAction(
            id: "delete-\(object.id)",
            title: "削除しますか？",
            message: "\(kindName) \(object.name) を削除します。取り消せません。",
            confirmLabel: "削除",
            isDestructive: true,
            action: { await $0.delete(object) })
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
                + shown + (rest > 0 ? "\n他 \(rest) 件" : ""),
            confirmLabel: "\(objects.count) 件を削除",
            isDestructive: true,
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

/// 列の幅指定をそのままビューの frame に落とす。
struct ColumnFrame: ViewModifier {
    let column: ResourceColumn

    func body(content: Content) -> some View {
        switch column.width {
        case .fixed(let width):
            content.frame(width: width, alignment: alignment)
        case .flexible(let minWidth):
            content.frame(minWidth: minWidth, maxWidth: .infinity, alignment: alignment)
        }
    }

    private var alignment: Alignment { column.trailing ? .trailing : .leading }
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
