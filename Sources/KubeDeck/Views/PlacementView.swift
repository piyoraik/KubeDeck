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
            if store.errorMessage != nil {
                failureState
            } else if store.isLoading {
                LoadingView(detail: store.currentContext)
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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            // Service が読めていないだけなのに「入口が無い」と
                            // 読めてしまう。欠けは図ではなく文字で断る。
                            if let notice = store.deniedKindsNotice {
                                PartialDataNotice(text: notice)
                            }
                            if preferences.placementGrouping.isNodeFirst {
                                ForEach(nodeGroups, id: \.id) { group in
                                    NodeCard(group: group)
                                }
                            } else {
                                ForEach(spreads, id: \.id) { spread in
                                    WorkloadCard(spread: spread)
                                }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            // **絞り込み欄はここに置かない。** ツールバーの項目を画面ごとに
            // 出し入れすると、レイアウト中の `NSToolbar` の書き換えで落ちる。
            // `RootView` が 1 つだけ持ち、文言だけを切り替える（たどるでは
            // 絞る相手が図ではなく左の起点の一覧なので、そこも向こうで書き分け）。
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

        var name: String { node?.name ?? id }
    }

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
            groups.append(Group(id: "未スケジュール", node: nil, pods: unscheduled))
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
        /// ノード名ごとの Pod。多い順。
        let byNode: [(node: String, pods: [K8sObject])]

        var id: String { "\(namespace ?? "-")/\(name)" }
        var podCount: Int { byNode.reduce(0) { $0 + $1.pods.count } }
        var nodeCount: Int { byNode.count }

        /// 2 つ以上あるのに 1 つのノードに固まっている状態。
        /// **これを見るための画面なので、文字で言う。**
        var isConcentrated: Bool { podCount > 1 && nodeCount == 1 }
    }

    private var spreads: [Spread] {
        let index = store.controllerIndex
        var byOwner: [String: [K8sObject]] = [:]
        for pod in store.filteredObjects {
            let owner = Self.owner(of: pod, controllers: index) ?? "単体の Pod"
            byOwner["\(pod.namespace ?? "-")/\(owner)", default: []].append(pod)
        }

        var result: [Spread] = []
        for (key, pods) in byOwner {
            let name = String(key.drop(while: { $0 != "/" }).dropFirst())
            let namespace = pods.first?.namespace
            var byNode: [String: [K8sObject]] = [:]
            for pod in pods {
                let node = Self.nodeName(of: pod) ?? "未スケジュール"
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
            result.append(Spread(name: name, namespace: namespace, byNode: ordered))
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

    /// Pod の所有者の名前。ReplicaSet / Job で止めず、Deployment / CronJob まで辿る。
    static func owner(of pod: K8sObject, controllers: [String: K8sObject]) -> String? {
        PlacementTrace.workloadOwner(of: pod, controllers: controllers)?.name
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

// MARK: - 箱の共通の見た目

private struct PlacementCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.cardStroke, lineWidth: 1))
        // 影は 1 段だけ。段を重ねると画面がぼやける。
        .shadow(color: Palette.cardShadow, radius: 6, y: 2)
    }
}

/// 見出しの右に置く小さな札。件数のような添え物を、本文と同じ字面で
/// 並べないための入れ物。
private struct CountPill: View {
    let text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(tint?.opacity(0.14) ?? Palette.insetFill))
    }
}

// MARK: - ノード 1 枚

private struct NodeCard: View {
    @Environment(ClusterStore.self) private var store
    @State private var preferences = Preferences.shared
    let group: PlacementView.Group

    var body: some View {
        PlacementCard {
            header
            // **使用量を右のパネルに追い出さない。** 「このノードは混んでいるか」
            // は配置を見る目的そのもので、行を選ばないと分からないのでは遅い。
            if let node = group.node {
                NodeUsageBars(node: node)
            }
            Divider().opacity(0.5)
            if group.pods.isEmpty {
                Text("このノードに Pod はありません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else if preferences.placementGroupsByWorkload {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workloads) { workload in
                        LabeledTiles(
                            label: workload.name, namespace: workload.namespace,
                            count: workload.pods.count
                        ) {
                            PodTileGrid(pods: workload.pods)
                        }
                    }
                }
            } else {
                PodTileGrid(pods: group.pods)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            // 種別のしるしは面に載せる。文字の列に混ぜると、名前の頭が
            // 揃わずカードごとにずれて見える。
            Image(systemName: group.node == nil ? "questionmark.square.dashed" : "server.rack")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 7))

            Text(group.name)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            if let node = group.node {
                StatusBadge(status: StatusResolver.status(for: node))
            }

            Spacer(minLength: 8)
            // 件数は必ず文字で出す。タイルの数を目で数えさせない。
            CountPill(text: "\(group.pods.count) Pod")
        }
    }

    /// 所有者でまとめたもの。多い順に出す（偏りを見る画面なので）。
    private var workloads: [Workload] {
        let index = store.controllerIndex
        var byOwner: [String: [K8sObject]] = [:]
        for pod in group.pods {
            let owner = PlacementView.owner(of: pod, controllers: index) ?? "単体の Pod"
            byOwner["\(pod.namespace ?? "-")/\(owner)", default: []].append(pod)
        }
        var result: [Workload] = []
        for (key, pods) in byOwner {
            result.append(
                Workload(
                    name: String(key.drop(while: { $0 != "/" }).dropFirst()),
                    namespace: pods.first?.namespace,
                    pods: pods))
        }
        result.sort {
            $0.pods.count == $1.pods.count
                ? $0.id < $1.id : $0.pods.count > $1.pods.count
        }
        return result
    }
}

/// ノードの CPU とメモリ。取れないときは棒を出さず、その旨を書く。
private struct NodeUsageBars: View {
    @Environment(ClusterStore.self) private var store
    let node: K8sObject

    var body: some View {
        if let usage = store.metrics.nodes[node.name] {
            let allocatable = node.nodeAllocatable
            let metric = Preferences.shared.placementMetric
            HStack(alignment: .top, spacing: 20) {
                if metric.showsCPU {
                    bar(
                        "CPU", used: usage.cpuCores, of: allocatable.cpuCores,
                        format: { Quantity.formatCPU(cores: $0) })
                }
                if metric.showsMemory {
                    bar(
                        "メモリ", used: usage.memoryBytes, of: allocatable.memoryBytes,
                        format: { Quantity.formatMemory(bytes: $0) })
                }
            }
        } else {
            // 0% と描かない。「使っていない」と「測れていない」は別。
            Text("使用量を取得できません。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    /// ノードは状態の色のまま。ここは「割り当て可能に対してどれだけ近いか」が
    /// 主役で、系列という考え方が無い。
    private func bar(
        _ title: String, used: Double, of base: Double, format: (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(format(used))
                    .font(.caption)
                    .monospacedDigit()
                if base > 0 {
                    Text("/ \(format(base))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let ratio = Quantity.ratio(used, of: base) {
                    Text(Quantity.formatPercent(ratio))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            Palette.textColor(for: ResourceTable.usageLevel(ratio) ?? .good))
                        .frame(minWidth: 40, alignment: .trailing)
                }
            }
            if let ratio = Quantity.ratio(used, of: base) {
                UsageBar(ratio: ratio)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - ワークロード 1 枚（ノードへの散らばり）

private struct WorkloadCard: View {
    let spread: PlacementView.Spread

    var body: some View {
        PlacementCard {
            HStack(spacing: 10) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 7))
                Text(spread.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                CountPill(text: "\(spread.podCount) Pod")
                // 散っている数は、固まっているときだけ色を付ける。
                CountPill(
                    text: "\(spread.nodeCount) ノード",
                    tint: spread.isConcentrated ? Palette.color(for: .warning) : nil)
            }

            // **固まっていることを色だけで言わない。** 冗長性が無い状態は
            // この画面でいちばん見たいものなので、文字で書く。
            if spread.isConcentrated {
                Label(
                    "\(spread.podCount) 個すべてが 1 つのノードに載っています。"
                        + "このノードが落ちると全部止まります。",
                    systemImage: StatusLevel.warning.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .warning))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().opacity(0.5)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(spread.byNode, id: \.node) { entry in
                    LabeledTiles(label: entry.node, count: entry.pods.count) {
                        PodTileGrid(pods: entry.pods)
                    }
                }
            }
        }
    }
}

// MARK: - 見出しつきのタイルの並び

struct Workload: Identifiable {
    let name: String
    /// 名前だけで束ねない。1 つのノードには複数の Namespace の Pod が載る。
    let namespace: String?
    let pods: [K8sObject]

    var id: String { "\(namespace ?? "-")/\(name)" }
}

/// 左に名前と件数、右にタイル。
///
/// **タイルを 1 つにまとめない。** まとめると個々の Pod を選べなくなり、
/// 「1 つだけ落ちている」という、この画面でいちばん見たい状態が消える。
/// まとめるのは見出しだけ。
private struct LabeledTiles<Content: View>: View {
    let label: String
    var namespace: String?
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    Text(label)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("×\(count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // **同じ名前が並ぶことがある。** どの Namespace のものか
                // 添えないと、見分けが付かない。
                if let namespace {
                    Text(namespace)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .frame(width: 200, alignment: .leading)

            content
        }
    }
}

// MARK: - Pod のタイル

private struct PodTileGrid: View {
    let pods: [K8sObject]
    @State private var preferences = Preferences.shared

    var body: some View {
        let size = preferences.placementTileSize
        // 幅に合わせて折り返す。Pod は 200 を超えることがあるので、
        // 1 行に固定すると横スクロールになる。
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: size.minimumWidth, maximum: size.maximumWidth),
                    spacing: size.showsName ? 6 : 4)
            ],
            alignment: .leading, spacing: size.showsName ? 6 : 4
        ) {
            ForEach(sorted) { pod in
                PodTile(pod: pod, size: size)
            }
        }
    }

    /// 困っているものを先に出す。並びが毎回変わらないよう、同じ重みなら名前順。
    private var sorted: [K8sObject] {
        pods.sorted { lhs, rhs in
            let left = StatusResolver.health(for: lhs).level
            let right = StatusResolver.health(for: rhs).level
            if left.severityOrder != right.severityOrder {
                return left.severityOrder < right.severityOrder
            }
            return lhs.name < rhs.name
        }
    }
}

private struct PodTile: View {
    @Environment(ClusterStore.self) private var store
    let pod: K8sObject
    let size: PlacementTileSize

    private var isSelected: Bool { store.selectedObjectID == pod.id }

    var body: some View {
        let status = StatusResolver.health(for: pod)

        Button {
            store.selectedObjectID = pod.id
        } label: {
            tileBody(status)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Palette.color(for: status.level).opacity(isSelected ? 0.30 : 0.12)))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        Palette.color(for: status.level).opacity(isSelected ? 0.9 : 0),
                        lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .help(helpText(status))
    }

    /// **小のときも色だけにしない。** 名前が入らないぶん、指したときに
    /// 名前と状態と使用量が出るようにしてある。
    @ViewBuilder
    private func tileBody(_ status: ResourceStatus) -> some View {
        if size.showsName {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    // 色だけに意味を持たせない。同じ色のしるしを添える。
                    Image(systemName: status.level.symbol)
                        .font(.system(size: 8))
                        .foregroundStyle(Palette.color(for: status.level))
                    Text(pod.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                // Pod ごとの使用量も、行を選ばずに見えるようにする。
                // 分母が取れないものは棒を出さない（0% と描かない）。
                if let ratio = usageRatio {
                    UsageBar(ratio: ratio)
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        } else {
            Color.clear.frame(width: 22, height: 22)
        }
    }

    /// 上限に対する割合。上限が無ければ要求に落とす（一覧や詳細と同じ順序）。
    ///
    /// **タイルの棒は 1 本だけ。** 2 本並べると、この大きさでは読めない。
    /// 何を出すかは設定で選ぶ。「CPU とメモリ」のときは詰まっているほう。
    private var usageRatio: Double? {
        guard let usage = store.metrics.usage(for: pod) else { return nil }
        let limits = pod.containerResourceTotal("limits")
        let requests = pod.containerResourceTotal("requests")
        let metric = Preferences.shared.placementMetric

        var ratios: [Double] = []
        if metric.showsCPU,
           let cpu = Quantity.ratio(usage.cpuCores, of: limits.cpuCores)
            ?? Quantity.ratio(usage.cpuCores, of: requests.cpuCores) {
            ratios.append(cpu)
        }
        if metric.showsMemory,
           let memory = Quantity.ratio(usage.memoryBytes, of: limits.memoryBytes)
            ?? Quantity.ratio(usage.memoryBytes, of: requests.memoryBytes) {
            ratios.append(memory)
        }
        return ratios.max()
    }

    private func helpText(_ status: ResourceStatus) -> String {
        var text = "\(pod.namespace ?? "-")/\(pod.name) · \(status.text)"
        if let usage = store.metrics.usage(for: pod) {
            text += " · CPU \(Quantity.formatCPU(cores: usage.cpuCores))"
                + " · メモリ \(Quantity.formatMemory(bytes: usage.memoryBytes))"
        }
        return text
    }
}
