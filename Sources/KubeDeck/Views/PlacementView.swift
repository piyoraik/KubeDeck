import SwiftUI

/// どの Pod がどのノードに載っているか。
///
/// 一覧の「ノード」列でも同じことは分かるが、**列の文字を目で数えないと偏りが
/// 見えない。** 箱とタイルにすると、どこに寄っているかが一目で分かる。
///
/// 箱は 2 通りある。**両方要る。**
/// - ノードを箱にすると「このノードに何が載っているか」（ノードの混み具合）
/// - ワークロードを箱にすると「この Deployment がどこに散っているか」（冗長性）
///
/// 件数と使用率は文字でも出す（形と色だけに意味を持たせない）。
struct PlacementView: View {
    @Environment(ClusterStore.self) private var store
    @State private var preferences = Preferences.shared

    var body: some View {
        if store.placementNodes.isEmpty && store.objects.isEmpty {
            // **読み込み中を失敗より先に見る。** `errorMessage` は前回の取得の
            // ものなので、Namespace を切り替えて引き直している最中にこれを先に
            // 見ると、まだ何も試していないのに失敗の画面が出たままになる。
            if store.isLoading {
                LoadingView(detail: store.currentContext)
            } else if store.errorMessage != nil {
                failureState
            } else {
                emptyState
            }
        } else {
            VStack(spacing: 0) {
                // **見方の切り替えを設定にしまわない。** 「どこに載っているか」と
                // 「どこに散っているか」は同じ画面で行き来しながら見るもので、
                // そのたびに設定を開くのでは使えない。設定に残すのは、いちど
                // 決めたら変えない類のもの（タイルの大きさなど）だけ。
                modeSwitcher
                Divider()
                if preferences.placementGrouping == .map {
                    TraceMapView()
                } else {
                    // 表の組み方を欄の幅で決めるので、スクロールの外側で測る。
                    GeometryReader { proxy in
                        ScrollView {
                            board(width: proxy.size.width)
                                .padding(16)
                        }
                    }
                }
            }
            // **絞り込み欄はここに置かない。** ツールバーの項目を画面ごとに
            // 出し入れすると、レイアウト中の `NSToolbar` の書き換えで落ちる。
            // `RootView` が 1 つだけ持ち、文言だけを切り替える（たどるでは
            // 絞る相手が図ではなく左の起点の一覧なので、そこも向こうで書き分け）。
        }
    }

    /// 表が 3 列（名前・ノード・使用量）で入る幅。下回ったら使用量をノードの下へ回す。
    private static let wideTableWidth: CGFloat = 1010

    private func board(width: CGFloat) -> some View {
        let naming = chipNaming

        return VStack(alignment: .leading, spacing: 14) {
            // Service が読めていないだけなのに「入口が無い」と
            // 読めてしまう。欠けは図ではなく文字で断る。
            if let notice = store.partialDataNotice {
                PartialDataNotice(text: notice)
            }
            if preferences.placementGrouping.isNodeFirst {
                // 名前をすべて出すチップは長いので、そのぶん列を広く取る。
                CardGrid(minimumColumnWidth: naming.showsFullName ? 400 : 300) {
                    ForEach(nodeGroups, id: \.id) { group in
                        NodeCard(group: group, naming: naming)
                    }
                }
            } else {
                WorkloadTable(
                    spreads: spreads, naming: naming,
                    nodePrefix: PlacementTrace.sharedNodePrefix(store.placementNodes.map(\.name)),
                    isCompact: width < Self.wideTableWidth)
            }
        }
    }

    /// チップに出す名前。**見出しにワークロード名が出ているときだけ切る** ——
    /// まとめていない並べ方で末尾だけにすると、何の Pod か分からなくなる。
    private var chipNaming: PodChipNaming {
        switch preferences.placementTileSize {
        case .small: return .hidden
        case .large: return .full
        case .medium:
            if preferences.placementGrouping.isNodeFirst, !preferences.placementGroupsByWorkload {
                return .full
            }
            // 絞り込みで世代が欠けても呼び名が変わらないよう、絞る前の Pod で決める。
            return .suffix(
                PlacementTrace.podSuffixes(for: store.objects, controllers: store.controllerIndex))
        }
    }

    private var modeSwitcher: some View {
        @Bindable var preferences = preferences

        return HStack(spacing: 14) {
            Picker("", selection: $preferences.placementGrouping) {
                ForEach(PlacementGrouping.allCases) { grouping in
                    Text(grouping.title).tag(grouping)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 400)

            // 添え書きは薄く小さく。選択肢と同じ重さで並べると、どちらを
            // 読めばいいのか分からなくなる。
            Text(preferences.placementGrouping.help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - ノードを箱にする

    /// ノード 1 つぶんの中身。
    struct Group: Identifiable {
        let id: String
        let node: K8sObject?
        let pods: [K8sObject]
        /// 見出しに出す名前。**`id` を見出しに流用しない** —— `id` は
        /// 突き合わせと並べ替えに使う値なので訳せず、未スケジュールの箱だけ
        /// 日本語のまま残ることになる。
        var title: String?

        var name: String { node?.name ?? title ?? id }
    }

    /// 未スケジュールの箱の `id`。**言語で変わらない値にする。**
    static let unscheduledID = "kubedeck.unscheduled"

    /// **Pod が 0 のノードも出す。** 空いているノードが見えないと、偏りの
    /// 片側（受け入れ先があるのに寄っている）が分からない。
    /// スケジュールされていない Pod は最後にまとめる。ノードの箱に混ぜると
    /// 「どこかに載っている」ように見える。
    private var nodeGroups: [Group] {
        var byNode: [String: [K8sObject]] = [:]
        var unscheduled: [K8sObject] = []

        for pod in store.filteredObjects {
            guard let node = Self.nodeName(of: pod) else {
                unscheduled.append(pod)
                continue
            }
            byNode[node, default: []].append(pod)
        }

        var groups = store.placementNodes.map { node in
            Group(id: node.name, node: node, pods: byNode.removeValue(forKey: node.name) ?? [])
        }
        if preferences.placementHidesEmptyNodes {
            groups.removeAll { $0.pods.isEmpty }
        }
        groups = sorted(groups)

        // ノードの一覧に無い名前が残ったら、それも出す（取得の隙間で
        // ノードだけ消えた、という状態を黙って捨てない）。
        for (name, pods) in byNode.sorted(by: { $0.key < $1.key }) {
            groups.append(Group(id: name, node: nil, pods: pods))
        }
        if !unscheduled.isEmpty {
            // **`id` は訳さない。** 並べ替えと突き合わせに使う値で、
            // 言語で変わると別の箱として扱われる。見出しは view の側が訳す。
            groups.append(
                Group(
                    id: Self.unscheduledID, node: nil, pods: unscheduled,
                    title: String(localized: "未スケジュール")))
        }
        return groups
    }

    /// **並べ替えるのはノードの箱だけ。** 出自の分からない箱と未スケジュールは
    /// 常に最後に置く（並びの中に紛れると、ノードの 1 つに見える）。
    private func sorted(_ groups: [Group]) -> [Group] {
        switch preferences.placementNodeOrder {
        case .name:
            return groups.sorted { $0.name < $1.name }
        case .podCount:
            return groups.sorted {
                $0.pods.count == $1.pods.count
                    ? $0.name < $1.name : $0.pods.count > $1.pods.count
            }
        case .usage:
            // 使用率が取れないノードは末尾へ。0 とみなして上に出すと、
            // 「使っていない」と「測れていない」が混ざる。
            return groups.sorted {
                let left = store.nodeUsageRatio($0.node)
                let right = store.nodeUsageRatio($1.node)
                if let left, let right { return left == right ? $0.name < $1.name : left > right }
                if left != nil { return true }
                if right != nil { return false }
                return $0.name < $1.name
            }
        }
    }

    // MARK: - ワークロードを箱にする

    /// ワークロード 1 つが、どのノードに何個載っているか。
    struct Spread: Identifiable {
        let name: String
        /// **名前だけで束ねない。** 別の Namespace に同じ名前の Deployment が
        /// あるのはふつうで、名前で束ねると無関係なものが 1 つに合体する
        /// （実際、2 つの Deployment が 1 つの箱に混ざった）。
        let namespace: String?
        /// 所有者の種別。**`id` にも見出しにも要る。**
        /// 束ねる鍵にだけ足すと、同じ Namespace の Deployment `web` と
        /// StatefulSet `web` は箱こそ分かれるのに **`id` が重なり**、
        /// `ForEach` が行を取り違える（並べ替えの同点崩しも `id` なので、
        /// どちらも `<` が成り立たず取得のたびに順番が入れ替わる）。
        /// 画面にも出さないと、同名のカードが 2 枚並ぶだけになる。
        let kind: String?
        /// ノード名ごとの Pod。多い順。
        let byNode: [(node: String, pods: [K8sObject])]

        var id: String { "\(namespace ?? "-")/\(kind ?? "-")/\(name)" }
        var podCount: Int { byNode.reduce(0) { $0 + $1.pods.count } }
        var nodeCount: Int { byNode.count }
        /// ノードをまたいだ全部。使用量の合計を出すときに使う。
        var pods: [K8sObject] { byNode.flatMap(\.pods) }

        /// 散らす先があり、どの Pod もノードに載っているか。
        let canSpread: Bool

        /// 2 つ以上あるのに 1 つのノードに固まっている状態。
        /// **これを見るための画面なので、文字で言う。**
        /// **散らしようが無いものは数えない**（`PlacementTrace.canSpread`）—— 直しようの
        /// 無い警告が先頭に並ぶと、本当に固まっているものが埋もれる。
        var isConcentrated: Bool { canSpread && podCount > 1 && nodeCount == 1 }
    }

    private var spreads: [Spread] {
        let index = store.controllerIndex
        let clusterNodeCount = store.placementNodes.count
        var byOwner: [String: [K8sObject]] = [:]
        // **鍵から名前を切り出さない。** 種別を鍵に足すと、切り出しの規則も
        // 一緒に複雑になる。表示に要るものは別に覚える。
        var owners: [String: (kind: String?, name: String)] = [:]
        for pod in store.filteredObjects {
            let owner = PlacementTrace.workloadOwner(of: pod, controllers: index)
            let name = owner?.name ?? String(localized: "単体の Pod")
            // **種別を落とさない。** Namespace は足したのに種別は落ちていたので、
            // 同じ Namespace の Deployment `web` と StatefulSet `web`（あるいは
            // DaemonSet と Deployment の `node-exporter`）が**1 つの箱に合体**し、
            // この画面を作った理由そのものである `isConcentrated` が、
            // 混ざった集合で計算されていた。`PlacementTrace.workloadAnchor` は
            // 最初から `id` に種別を含めている。
            let key = "\(pod.namespace ?? "-")/\(owner?.kind ?? "-")/\(name)"
            byOwner[key, default: []].append(pod)
            owners[key] = (kind: owner?.kind, name: name)
        }

        var result: [Spread] = []
        for (key, pods) in byOwner {
            let owner = owners[key]
            let name = owner?.name ?? key
            let namespace = pods.first?.namespace
            var byNode: [String: [K8sObject]] = [:]
            for pod in pods {
                let node = Self.nodeName(of: pod) ?? String(localized: "未スケジュール")
                byNode[node, default: []].append(pod)
            }
            var ordered: [(node: String, pods: [K8sObject])] = []
            for (node, pods) in byNode {
                ordered.append((node: node, pods: pods))
            }
            ordered.sort { left, right in
                left.pods.count == right.pods.count
                    ? left.node < right.node : left.pods.count > right.pods.count
            }
            // 未スケジュールの Pod は、まとめて 1 つの欄に入るだけで、ノードに載ってはいない。
            let isPlaced = pods.allSatisfy { Self.nodeName(of: $0) != nil }
            result.append(
                Spread(
                    name: name, namespace: namespace, kind: owner?.kind, byNode: ordered,
                    canSpread: isPlaced
                        && PlacementTrace.canSpread(
                            ownerKind: owner?.kind, clusterNodeCount: clusterNodeCount)))
        }
        // 固まっているものを先に。次に数の多い順。見たいものが上に来る。
        result.sort { lhs, rhs in
            if lhs.isConcentrated != rhs.isConcentrated { return lhs.isConcentrated }
            if lhs.podCount != rhs.podCount { return lhs.podCount > rhs.podCount }
            return lhs.id < rhs.id
        }
        return result
    }

    // MARK: - 所有者とノードの解決

    // **解き方を 2 つ持たない。** ノード名も所有者も、たどると同じ答えでないと
    // 「ワークロード別では 3 個なのに、たどると 2 個」のような食い違いが出る。
    static func nodeName(of pod: K8sObject) -> String? {
        PlacementTrace.nodeName(of: pod)
    }

    // MARK: - 中身が無いとき

    private var failureState: some View {
        ContentUnavailableView {
            Label("配置を取得できません", systemImage: StatusLevel.critical.symbol)
        } description: {
            Text("\(store.currentContext) から応答がありませんでした。")
        } actions: {
            Button("もう一度試す") { store.reload() }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("ノードがありません", systemImage: "tray")
        } description: {
            Text("このコンテキストではノードを読めませんでした。")
        }
    }
}

// MARK: - ノード 1 枚

private struct NodeCard: View {
    @Environment(ClusterStore.self) private var store
    @State private var preferences = Preferences.shared
    let group: PlacementView.Group
    let naming: PodChipNaming

    var body: some View {
        PlacementCard {
            header
            // **使用量を右のパネルに追い出さない。** 「このノードは混んでいるか」
            // は配置を見る目的そのもので、行を選ばないと分からないのでは遅い。
            if let node = group.node {
                // ノードが少ないとカードが欄いっぱいに広がる。棒まで引き伸ばさない。
                NodeMeters(node: node)
                    .frame(maxWidth: 440, alignment: .leading)
            }
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
            if group.pods.isEmpty {
                Text("このノードに Pod はありません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if preferences.placementGroupsByWorkload {
                // カードが広いとき（ノードが 1〜2 個のクラスタ）は、ワークロードも列に割る。
                // 1 列のままだと、名前と Namespace が端どうしに離れ、縦にだけ伸びる。
                CardGrid(minimumColumnWidth: 280, spacing: 24, lineSpacing: 10) {
                    ForEach(workloads) { workload in
                        // **チップを 1 つにまとめない。** まとめると個々の Pod を選べなくなり、
                        // 「1 つだけ落ちている」という、この画面でいちばん見たい状態が消える。
                        // まとめるのは見出しだけ。
                        VStack(alignment: .leading, spacing: 4) {
                            WorkloadHeading(workload: workload)
                            PodChips(pods: workload.pods, naming: naming)
                        }
                    }
                }
            } else {
                PodChips(pods: group.pods, naming: naming)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 8) {
            if group.node == nil {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(group.name)
                if let node = group.node {
                    NodeStatusText(status: StatusResolver.status(for: node))
                }
            }
            Spacer(minLength: 8)
            // 件数は必ず文字で出す。チップの数を目で数えさせない。
            CountPill(text: "\(group.pods.count) Pod")
        }
    }

    /// 所有者でまとめたもの。多い順に出す（偏りを見る画面なので）。
    private var workloads: [Workload] {
        let index = store.controllerIndex
        var byOwner: [String: [K8sObject]] = [:]
        var owners: [String: (kind: String?, name: String)] = [:]
        for pod in group.pods {
            let owner = PlacementTrace.workloadOwner(of: pod, controllers: index)
            let name = owner?.name ?? String(localized: "単体の Pod")
            // ノードの箱の中の集計。**ここでも種別を落とさない**
            // （`spreads` と同じ理由。解き方を 2 つ持たない）。
            let key = "\(pod.namespace ?? "-")/\(owner?.kind ?? "-")/\(name)"
            byOwner[key, default: []].append(pod)
            owners[key] = (kind: owner?.kind, name: name)
        }
        var result: [Workload] = []
        for (key, pods) in byOwner {
            let owner = owners[key]
            result.append(
                Workload(
                    name: owner?.name ?? key,
                    namespace: pods.first?.namespace,
                    kind: owner?.kind,
                    pods: pods))
        }
        result.sort {
            $0.pods.count == $1.pods.count
                ? $0.id < $1.id : $0.pods.count > $1.pods.count
        }
        return result
    }
}

/// ノードの状態。正常なら語だけ。そうでないときだけ色としるしを付ける。
private struct NodeStatusText: View {
    let status: ResourceStatus

    var body: some View {
        if status.level == .good {
            Text(status.text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        } else {
            Label(status.text, systemImage: status.level.symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Palette.textColor(for: status.level))
        }
    }
}

/// ノードの CPU とメモリ。取れないときは棒を出さず、その旨を書く。
private struct NodeMeters: View {
    @Environment(ClusterStore.self) private var store
    let node: K8sObject

    var body: some View {
        if let usage = store.metrics.nodes[node.name] {
            PlacementMeters(rows: rows(usage))
        } else if store.metricsPhase.isPending {
            // **「まだ引いていない」を「取得できません」と書かない。**
            // 箱ごとに出るので輪は回さない（文字だけで足りる）。
            MetricsPendingLabel(phase: store.metricsPhase, spins: false, font: .subheadline)
        } else {
            // 0% と描かない。「使っていない」と「測れていない」は別。
            Text("使用量を取得できません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func rows(_ usage: ResourceUsage) -> [PlacementMeterRow] {
        let allocatable = node.nodeAllocatable
        let metric = Preferences.shared.placementMetric
        var rows: [PlacementMeterRow] = []
        if metric.showsCPU {
            rows.append(
                row(
                    id: "cpu", title: "CPU", used: usage.cpuCores, base: allocatable.cpuCores,
                    format: { Quantity.formatCPU(cores: $0) }))
        }
        if metric.showsMemory {
            rows.append(
                row(
                    id: "memory", title: "メモリ", used: usage.memoryBytes,
                    base: allocatable.memoryBytes,
                    format: { Quantity.formatMemory(bytes: $0) }))
        }
        return rows
    }

    private func row(
        id: String, title: LocalizedStringResource, used: Double, base: Double,
        format: (Double) -> String
    ) -> PlacementMeterRow {
        let ratio = Quantity.ratio(used, of: base)
        return PlacementMeterRow(
            id: id, title: title, used: format(used), base: base > 0 ? format(base) : "",
            ratio: ratio, level: ratio.flatMap(ResourceTable.usageLevel))
    }
}

/// ノードの箱の中の、ワークロード 1 つぶんの見出し。
private struct WorkloadHeading: View {
    let workload: Workload

    var body: some View {
        // **同じ名前が並ぶことがある。** どの Namespace の、どの種別の
        // ものかを添えないと、見分けが付かない。
        let place = [workload.namespace, workload.kind].compactMap { $0 }.joined(separator: " · ")
        let tip = "\(place) · \(workload.name)"

        // 1 行に入らなければ、名前を切らずに Namespace と種別を下の行へ回す。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                name
                Spacer(minLength: 6)
                Text(place)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            VStack(alignment: .leading, spacing: 0) {
                name
                Text(place)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .help(tip)
    }

    private var name: some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(workload.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            if workload.pods.count > 1 {
                Text(verbatim: "×\(workload.pods.count)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - ワークロードの表（ノードへの散らばり）

/// ワークロードを 1 行ずつ。名前・載っているノード・使用量。
///
/// **1 件 1 カードにしない。** 枠と余白が中身（チップ数個）より大きくなり、16 件で
/// 3.6 画面ぶんの高さになっていた（実測）。
private struct WorkloadTable: View {
    let spreads: [PlacementView.Spread]
    let naming: PodChipNaming
    /// ノード名から省く頭。行ごとに繰り返す名前なので、全部に共通する部分は見出しで断って落とす。
    let nodePrefix: String
    /// 欄が狭いときは、使用量を載っているノードの下へ回す。
    let isCompact: Bool

    static let usageWidth: CGFloat = 360

    private var nameWidth: CGFloat { isCompact ? 190 : 232 }

    var body: some View {
        PlacementCard(
            padding: EdgeInsets(top: 2, leading: 16, bottom: 4, trailing: 16), spacing: 0
        ) {
            header
            if spreads.isEmpty {
                Rectangle().fill(Palette.hairline).frame(height: 1)
                Text("表示するものがありません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 12)
            }
            ForEach(spreads) { spread in
                Rectangle().fill(Palette.hairline).frame(height: 1)
                WorkloadRow(
                    spread: spread, naming: naming, nodePrefix: nodePrefix,
                    isCompact: isCompact, nameWidth: nameWidth)
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 22) {
            Text("ワークロード")
                .frame(width: nameWidth, alignment: .leading)
            HStack(spacing: 0) {
                Text("載っているノード")
                if !nodePrefix.isEmpty {
                    Text("（名前は「\(nodePrefix)」を省いて表示）")
                        .fontWeight(.regular)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isCompact {
                Text("使用量（Pod の合計）")
                    .frame(width: Self.usageWidth, alignment: .leading)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.vertical, 8)
    }
}

private struct WorkloadRow: View {
    let spread: PlacementView.Spread
    let naming: PodChipNaming
    let nodePrefix: String
    let isCompact: Bool
    let nameWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            name
                .frame(width: nameWidth, alignment: .leading)
            if isCompact {
                VStack(alignment: .leading, spacing: 8) {
                    placement
                    WorkloadMeters(pods: spread.pods)
                        .frame(maxWidth: WorkloadTable.usageWidth, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                placement
                    .frame(maxWidth: .infinity, alignment: .leading)
                WorkloadMeters(pods: spread.pods)
                    .frame(width: WorkloadTable.usageWidth, alignment: .leading)
                    .padding(.top, 5)
            }
        }
        .padding(.vertical, 8)
    }

    private var name: some View {
        // **種別を出す。** 同じ Namespace の Deployment `web` と StatefulSet `web` は
        // 別の行になるので、出さないと同名の行が 2 つ並ぶだけになる。
        let place = [spread.namespace, spread.kind].compactMap { $0 }.joined(separator: " · ")

        return VStack(alignment: .leading, spacing: 0) {
            Text(spread.name)
                .font(.callout.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(spread.name)
            Text(place)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            // **固まっていることを色だけで言わない。** 冗長性が無い状態は
            // この画面でいちばん見たいものなので、文字で書く。
            if spread.isConcentrated {
                Label(
                    "\(spread.podCount) 個すべてが 1 ノードに載っています",
                    systemImage: StatusLevel.warning.symbol)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textColor(for: .warning))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 3)
                    .help(
                        "\(spread.podCount) 個すべてが 1 つのノードに載っています。このノードが落ちると全部止まります。")
            }
        }
    }

    /// 載っているノード。まとまりの数が、そのまま散らばりの数になる。
    private var placement: some View {
        HStack(alignment: .top, spacing: 10) {
            count
                .frame(width: 104, height: PodChip.height + 4, alignment: .leading)
            ChipFlow(spacing: 8, lineSpacing: 6) {
                ForEach(spread.byNode, id: \.node) { entry in
                    NodeChipGroup(
                        node: entry.node, prefix: nodePrefix, pods: entry.pods, naming: naming)
                }
            }
        }
    }

    /// 件数は文字でも出す。散っている数は、固まっているときだけ色を付ける。
    private var count: some View {
        let nodes = Text("\(spread.nodeCount) ノード")
            .foregroundStyle(
                spread.isConcentrated ? Palette.textColor(for: .warning) : Color.secondary)

        return (Text(verbatim: "\(spread.podCount) Pod · ") + nodes)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// ノード 1 つぶんのまとまり。ノード名と、そこに載っている Pod。
private struct NodeChipGroup: View {
    let node: String
    let prefix: String
    let pods: [K8sObject]
    let naming: PodChipNaming

    var body: some View {
        let short = !prefix.isEmpty && node.hasPrefix(prefix)
            ? String(node.dropFirst(prefix.count)) : node

        ChipFlow(spacing: naming.showsName ? 5 : 4, lineSpacing: 4) {
            Text(short)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 136, alignment: .leading)
                .fixedSize(horizontal: true, vertical: false)
                .frame(height: PodChip.height)
                .padding(.trailing, 2)
                .help(node)
            ForEach(PodChips.sorted(pods)) { pod in
                PodChip(pod: pod, label: naming.label(for: pod))
            }
        }
        .padding(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 2))
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// ワークロードの合計。
///
/// **右のパネルに追い出さない。** ノードの使用量と同じ理由で、「このワークロードが
/// どれだけ食っているか」は配置を見る目的そのもの。行を選ばないと分からないのでは遅い。
private struct WorkloadMeters: View {
    @Environment(ClusterStore.self) private var store
    let pods: [K8sObject]

    var body: some View {
        let usage = store.metrics.workloadUsage(of: pods)

        if usage.isMeasured {
            VStack(alignment: .leading, spacing: 4) {
                PlacementMeters(rows: rows(usage), trackWidth: 56)
                // **何個ぶんの合計なのかを黙らない。** 引けていない Pod があると
                // 合計は小さく出るので、断りが無いと「そういう値」に読める。
                if usage.isPartial {
                    Text(
                        String(localized: """
                            \(usage.podCount) 個中 \(usage.measuredPods) 個ぶんの合計です\
                            （残りは使用量を引けていません）。
                            """))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if store.metricsPhase.isPending {
            MetricsPendingLabel(phase: store.metricsPhase, spins: false, font: .subheadline)
        } else {
            Text("使用量を取得できません。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    /// **出していない軸のことは書かない**（メモリを出していないのに「メモリの分母が…」と
    /// 書いても確かめようがない）。
    private func rows(_ usage: WorkloadUsage) -> [PlacementMeterRow] {
        let metric = Preferences.shared.placementMetric
        var rows: [PlacementMeterRow] = []
        if metric.showsCPU {
            rows.append(
                row(id: "cpu", title: "CPU", axis: usage.cpu) { Quantity.formatCPU(cores: $0) })
        }
        if metric.showsMemory {
            rows.append(
                row(id: "memory", title: "メモリ", axis: usage.memory) {
                    Quantity.formatMemory(bytes: $0)
                })
        }
        return rows
    }

    /// 分母は Pod ごとの上限（無ければ要求）の合計で、ノードの割り当て可能量とは別物なので
    /// 呼び名を添える。割合を出せない理由も、同じ場所に書く。
    private func row(
        id: String, title: LocalizedStringResource, axis: WorkloadUsage.Axis,
        format: (Double) -> String
    ) -> PlacementMeterRow {
        var base = String(localized: "上限・要求なし")
        var help: String?
        if axis.base > 0 {
            let amount = [axis.baseLabel, format(axis.base)].compactMap { $0 }
                .joined(separator: " ")
            base = axis.podsWithoutBase > 0 ? String(localized: "\(amount)（一部なし）") : amount
        }
        if axis.podsWithoutBase > 0 {
            help = String(localized: "上限も要求も書かれていない Pod があるので、割合は出しません。")
        }
        return PlacementMeterRow(
            id: id, title: title, used: format(axis.used), base: base, ratio: axis.ratio,
            // 要求の混ざった割合は、超えても異常ではないので色を付けない。
            level: axis.isAgainstLimit ? axis.ratio.flatMap(ResourceTable.usageLevel) : nil,
            help: help)
    }
}

/// ノードの箱の中の、ワークロード 1 つぶん。
struct Workload: Identifiable {
    let name: String
    /// 名前だけで束ねない。1 つのノードには複数の Namespace の Pod が載る。
    let namespace: String?
    /// 所有者の種別。`Spread.kind` と同じ理由（束ねる鍵と `id` を揃える）。
    let kind: String?
    let pods: [K8sObject]

    var id: String { "\(namespace ?? "-")/\(kind ?? "-")/\(name)" }
}
