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
                    WorkloadMap(spreads: spreads)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
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
            // 並べているのは Pod なので、一覧と同じ絞り込みを付ける。
            .searchable(
                text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
                placement: .toolbar,
                prompt: "Pod を絞り込む")
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
        /// ノード名ごとの Pod。多い順。
        let byNode: [(node: String, pods: [K8sObject])]

        var id: String { name }
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
            byOwner[Self.owner(of: pod, controllers: index) ?? "単体の Pod", default: []]
                .append(pod)
        }

        var result: [Spread] = []
        for (name, pods) in byOwner {
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
            result.append(Spread(name: name, byNode: ordered))
        }
        // 固まっているものを先に。次に数の多い順。見たいものが上に来る。
        result.sort { lhs, rhs in
            if lhs.isConcentrated != rhs.isConcentrated { return lhs.isConcentrated }
            if lhs.podCount != rhs.podCount { return lhs.podCount > rhs.podCount }
            return lhs.name < rhs.name
        }
        return result
    }

    // MARK: - 所有者とノードの解決

    static func nodeName(of pod: K8sObject) -> String? {
        guard let name = pod.spec?["nodeName"]?.stringValue, !name.isEmpty else { return nil }
        return name
    }

    /// Pod の所有者の名前。
    ///
    /// **ReplicaSet と Job で止めない。** ReplicaSet 名は
    /// `<Deployment 名>-<ハッシュ>` で、更新のたびに別のまとまりに見える。
    /// Job も CronJob から作られたものは実行のたびに名前が変わる。
    /// もう一段辿って Deployment / CronJob の名前にする。
    static func owner(of pod: K8sObject, controllers: [String: K8sObject]) -> String? {
        guard let reference = controllerReference(of: pod) else { return nil }
        if reference.kind == "ReplicaSet" || reference.kind == "Job" {
            let key = "\(pod.namespace ?? "")/\(reference.kind)/\(reference.name)"
            if let parent = controllers[key],
               let grandparent = controllerReference(of: parent) {
                return grandparent.name
            }
        }
        return reference.name
    }

    /// 支配している所有者。`controller: true` のものを採る。
    /// 無ければ先頭（`ownerReferences` は複数持てるが、支配者は 1 つだけ）。
    private static func controllerReference(
        of object: K8sObject
    ) -> (kind: String, name: String)? {
        let references = object.raw.path("metadata.ownerReferences")?.arrayValue ?? []
        let controller = references.first { $0["controller"]?.boolValue == true }
            ?? references.first
        guard let controller,
              let kind = controller["kind"]?.stringValue,
              let name = controller["name"]?.stringValue
        else { return nil }
        return (kind, name)
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
            } else if preferences.placementGrouping == .nodeByWorkload {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(workloads, id: \.name) { workload in
                        LabeledTiles(label: workload.name, count: workload.pods.count) {
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
            byOwner[PlacementView.owner(of: pod, controllers: index) ?? "単体の Pod", default: []]
                .append(pod)
        }
        return byOwner
            .map { Workload(name: $0.key, pods: $0.value) }
            .sorted {
                $0.pods.count == $1.pods.count
                    ? $0.name < $1.name : $0.pods.count > $1.pods.count
            }
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
    let pods: [K8sObject]

    var id: String { name }
}

/// 左に名前と件数、右にタイル。
///
/// **タイルを 1 つにまとめない。** まとめると個々の Pod を選べなくなり、
/// 「1 つだけ落ちている」という、この画面でいちばん見たい状態が消える。
/// まとめるのは見出しだけ。
private struct LabeledTiles<Content: View>: View {
    let label: String
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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

// MARK: - たどる（1 つを枝で展開）

/// ワークロードを 1 つ選んで、ReplicaSet から Pod、ノードまで枝で辿る。
///
/// **全部を一度に描かない。** 222 Pod を線でつないだ図は、線の数が多すぎて
/// どこから読めばいいのか分からなくなる。選んだ 1 つだけを展開する。
///
/// 枝は罫線の文字で描く。**座標を計算して線を引かない** — 折り返しや
/// スクロールのたびに位置を計算し直すことになり、図のためだけに
/// レイアウトの仕組みを持つことになる。
private struct WorkloadMap: View {
    @Environment(ClusterStore.self) private var store
    let spreads: [PlacementView.Spread]
    @State private var focus: String?

    var body: some View {
        HStack(spacing: 0) {
            picker
            Divider()
            if let branch = branch {
                ScrollView {
                    BranchTree(branch: branch)
                        .padding(16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ContentUnavailableView {
                    Label("たどる対象を選んでください", systemImage: "point.3.filled.connected.trianglepath.dotted")
                } description: {
                    Text("左の一覧から 1 つ選ぶと、Pod とノードまで枝で出します。")
                }
            }
        }
    }

    /// 左の一覧。**多い順のまま出す。** 探しているのはたいてい大きいもの。
    private var picker: some View {
        List(selection: Binding(get: { focus }, set: { focus = $0 })) {
            ForEach(spreads, id: \.id) { spread in
                HStack(spacing: 6) {
                    Text(spread.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Text("\(spread.podCount)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .tag(spread.name)
            }
        }
        .frame(width: 240)
        .onAppear { if focus == nil { focus = spreads.first?.name } }
        // 選んでいたものが消えたら先頭へ。空のまま固まらせない。
        .onChange(of: spreads.map(\.name)) { _, names in
            if let focus, !names.contains(focus) { self.focus = names.first }
        }
    }

    private var branch: Branch? {
        guard let focus, let spread = spreads.first(where: { $0.name == focus }) else { return nil }
        let pods = spread.byNode.flatMap(\.pods)

        // 直接の所有者（ReplicaSet / Job）ごとに割る。世代が分かる。
        var byController: [String: [K8sObject]] = [:]
        for pod in pods {
            byController[Self.directOwner(of: pod) ?? "（所有者なし）", default: []].append(pod)
        }

        // Pod が 0 の ReplicaSet も出す。入れ替わりの途中や、古い世代が
        // 残っていることが分かる。
        for controller in store.placementControllers {
            guard Self.ownerName(of: controller) == focus else { continue }
            if byController[controller.name] == nil {
                byController[controller.name] = []
            }
        }

        var groups: [Branch.Controller] = []
        for (name, pods) in byController {
            groups.append(Branch.Controller(name: name, pods: pods))
        }
        groups.sort { left, right in
            left.pods.count == right.pods.count
                ? left.name < right.name : left.pods.count > right.pods.count
        }
        return Branch(name: focus, controllers: groups)
    }

    private static func directOwner(of pod: K8sObject) -> String? {
        ownerName(of: pod)
    }

    private static func ownerName(of object: K8sObject) -> String? {
        let references = object.raw.path("metadata.ownerReferences")?.arrayValue ?? []
        let controller = references.first { $0["controller"]?.boolValue == true }
            ?? references.first
        return controller?["name"]?.stringValue
    }
}

private struct Branch {
    struct Controller: Identifiable {
        let name: String
        let pods: [K8sObject]
        var id: String { name }
    }

    let name: String
    let controllers: [Controller]
}

/// ワークロードを図にする。
///
/// 参考にしているのは Kubernetes の構成図（七角形の器・範囲の囲み・矢印）。
/// **罫線の木ではなく図にする。** 木は階層は表せるが「Namespace の中に
/// Deployment があり、そこから Pod が出て、それぞれ別のノードに載っている」
/// という**入れ子と行き先**が同時には見えない。
///
/// **自動でレイアウトしない。** 段は「ワークロード → 世代 → Pod → ノード」で
/// 決まっているので、列に並べるだけでよい。線を自由に引く仕組みを持つと、
/// 図のためだけにレイアウトの実装を抱えることになる。
private struct BranchTree: View {
    let branch: Branch

    var body: some View {
        DiagramBox(
            title: namespaceTitle, symbol: ResourceKind.namespace.symbol,
            tint: .secondary
        ) {
            HStack(alignment: .center, spacing: 0) {
                owner
                // ここから各世代へ枝分かれする。
                DiagramArrow(length: 22)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(branch.controllers) { controller in
                        generation(controller)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var namespaceTitle: String {
        let namespaces = Set(branch.controllers.flatMap { $0.pods.compactMap(\.namespace) })
        guard namespaces.count == 1, let only = namespaces.first else { return "Namespace" }
        return only
    }

    private var owner: some View {
        VStack(spacing: 6) {
            ResourceGlyph(symbol: ResourceKind.deployment.symbol, size: 40)
            Text(branch.name)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(width: 120)
                .lineLimit(2)
        }
    }

    /// ReplicaSet / Job 1 世代ぶん。**Pod が 0 の世代も囲みごと出す。**
    /// 入れ替わりの途中や、古い世代が残っていることが分かる。
    private func generation(_ controller: Branch.Controller) -> some View {
        DiagramBox(
            title: controller.name, symbol: ResourceKind.replicaSet.symbol,
            tint: controller.pods.isEmpty ? .secondary : .accentColor
        ) {
            if controller.pods.isEmpty {
                Text("Pod はありません（古い世代）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(height: 34)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(controller.pods) { pod in
                        PodBranchRow(pod: pod)
                    }
                }
            }
        }
    }
}

/// Pod 1 つと、その載っているノード。
private struct PodBranchRow: View {
    @Environment(ClusterStore.self) private var store
    let pod: K8sObject

    private var isSelected: Bool { store.selectedObjectID == pod.id }

    var body: some View {
        let status = StatusResolver.health(for: pod)

        HStack(spacing: 8) {
            Button {
                store.selectedObjectID = pod.id
            } label: {
                HStack(spacing: 8) {
                    ResourceGlyph(
                        symbol: ResourceKind.pod.symbol, size: 30,
                        badge: status.level)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pod.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(status.text)
                            .font(.caption2)
                            .foregroundStyle(Palette.textColor(for: status.level))
                    }
                    .frame(width: 190, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            Color.accentColor.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5))
            }
            .buttonStyle(.plain)

            DiagramArrow(length: 20)

            // 行き先のノード。**Pod と同じ器にしない** — 種別が違う。
            HStack(spacing: 6) {
                ResourceGlyph(
                    symbol: ResourceKind.node.symbol, size: 26, tint: .secondary)
                Text(PlacementView.nodeName(of: pod) ?? "未スケジュール")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
