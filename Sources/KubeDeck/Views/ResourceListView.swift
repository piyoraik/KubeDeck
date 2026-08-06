import SwiftUI

struct ResourceListView: View {
    @Environment(ClusterStore.self) private var store
    let target: ResourceTarget

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
        //
        // **確認とシートもここに置かない。** 操作は一覧の右クリックと詳細
        // パネルの両方から始まるので、画面ごとに `confirmationDialog` を
        // 持つと同じ操作の文面が 2 つになる。`ResourceActionHost` に集めて
        // `RootView` が 1 度だけ presenting する。
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

    /// **操作の中身をここに書かない。** 同じものを詳細パネルのボタンでも出すので、
    /// 種別ごとの出し分けは `ResourceActionSet` の 1 か所が持つ。ここに残すのは
    /// 一覧の中の移動（「詳細を見る」）だけ。
    @ViewBuilder
    private func menu(for object: K8sObject) -> some View {
        let selected = store.selectedObjects
        // **複数選んでいるときは、1 つ向けの操作を出さない。** 「ログを見る」が
        // どれのログなのか決まらないし、選択と操作対象が食い違う。
        if selected.count <= 1 {
            Button("詳細を見る") { store.selectOnly(object) }
            Divider()
        }
        ResourceActionMenu(
            objects: selected.count > 1 ? selected : [object], target: target)
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
