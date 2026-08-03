import SwiftUI

struct ResourceListView: View {
    @Environment(ClusterStore.self) private var store
    let target: ResourceTarget

    @Environment(\.openWindow) private var openWindow

    @State private var pendingDeletion: K8sObject?
    @State private var scaleTarget: K8sObject?

    /// 組み込み種別のときだけ、種別ごとの特別扱い（ログ、スケールなど）が効く。
    private var kind: ResourceKind? { target.builtIn }

    /// 列の定義は store が持つ。**2 つ持たない** — 並べ替えは列の値を
    /// そのまま鍵にするので、定義がずれると見えている文字と並びが食い違う。
    private var columns: [ResourceColumn] { store.currentColumns }

    var body: some View {
        table
        .background(Color(nsColor: .windowBackgroundColor))
        // 検索は一覧にだけ付ける。概要に置いても絞り込む相手がおらず、
        // 打ち込めるのに何も起きない入力欄になる。
        .searchable(
            text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
            placement: .toolbar,
            prompt: "\(target.displayName) を絞り込む")
        .confirmationDialog(
            "削除しますか？",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }),
            presenting: pendingDeletion
        ) { object in
            Button("削除", role: .destructive) {
                let target = object
                pendingDeletion = nil
                Task { await store.delete(target) }
            }
            Button("やめる", role: .cancel) { pendingDeletion = nil }
        } message: { object in
            Text("\(target.displayName) \(object.name) を削除します。取り消せません。")
        }
        .sheet(item: $scaleTarget) { object in
            ScaleSheet(object: object)
        }
    }

    // MARK: - 表

    /// 表は横にもスクロールする。
    ///
    /// ウインドウには最小幅を入れてあるので、窓を狭めると列は要求幅より
    /// 押し潰される。Node や PVC は列が多く、潰れると値が読めなくなる。
    /// 全部の列が読める幅を下限として確保し、足りないぶんは横スクロールへ逃がす。
    private var table: some View {
        GeometryReader { proxy in
            let rows = store.filteredObjects
            let width = max(intrinsicWidth, proxy.size.width)

            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                    headerRow
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
                                        row(for: object)
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
            // **`List` を使っていないので、上下移動は付いてこない。** 一覧を
            // 見ながら 1 行ずつ確かめるのは基本の操作なので、自前で足す。
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: store.moveSelection(by: -1)
                case .down: store.moveSelection(by: 1)
                default: break
                }
            }
        }
    }

    /// 列がすべて読める最小の幅。列の間隔と左右の余白を足したもの。
    private var intrinsicWidth: CGFloat {
        let columns = self.columns
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
    private var headerRow: some View {
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

    private func row(for object: K8sObject) -> some View {
        let isSelected = store.selectedObjectID == object.id

        return HStack(spacing: 12) {
            ForEach(columns) { column in
                cell(column.value(object), selected: isSelected)
                    .modifier(ColumnFrame(column: column))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, Preferences.shared.rowDensity.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor.opacity(0.16) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedObjectID = object.id }
        .contextMenu { menu(for: object) }
        // 削除中のものは薄く出す。押しても消えない、という誤解を避ける。
        .opacity(object.isTerminating ? 0.55 : 1)
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
        Button("詳細を見る") { store.selectedObjectID = object.id }

        if kind == .pod {
            Button("ログを見る") { store.showLogs(for: object) }
            Button("ログを別ウインドウで見る") {
                openWindow(id: LogWindow.id, value: PodLogRequest(pod: object))
            }
        }
        if kind?.isScalable == true {
            Button("レプリカ数を変える…") { scaleTarget = object }
        }
        if kind?.isRestartable == true {
            Button("ローリング再起動") {
                Task { await store.restart(object) }
            }
        }
        if kind == .node {
            let unschedulable = object.spec?["unschedulable"]?.boolValue == true
            Button(unschedulable ? "スケジュールを許可 (uncordon)" : "スケジュールを止める (cordon)") {
                Task { await store.setCordon(object, unschedulable: !unschedulable) }
            }
        }

        Divider()

        Button("名前をコピー") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(object.name, forType: .string)
        }

        if kind != .event {
            Divider()
            Button("削除…", role: .destructive) { pendingDeletion = object }
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
                Text("「\(store.searchText)」に一致する \(target.displayName) は見つかりませんでした。")
            } else if target.isNamespaced, let namespace = store.selectedNamespace {
                Text("Namespace 「\(namespace)」には \(target.displayName) がありません。")
            } else {
                Text("このクラスタには \(target.displayName) がありません。")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
