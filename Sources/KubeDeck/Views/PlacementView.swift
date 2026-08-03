import SwiftUI

/// どの Pod がどのノードに載っているか。
///
/// 一覧の「ノード」列でも同じことは分かるが、**列の文字を目で数えないと偏りが
/// 見えない。** ノードを箱にして Pod をタイルで並べると、どこに寄っているかが
/// 一目で分かる。件数と使用率は見出しに文字でも出す（形と色だけに意味を
/// 持たせない）。
struct PlacementView: View {
    @Environment(ClusterStore.self) private var store

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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.id) { group in
                        NodeCard(group: group)
                    }
                }
                .padding(16)
            }
            // 並べているのは Pod なので、一覧と同じ絞り込みを付ける。
            .searchable(
                text: Binding(get: { store.searchText }, set: { store.searchText = $0 }),
                placement: .toolbar,
                prompt: "Pod を絞り込む")
        }
    }

    // MARK: - 集計

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
    private var groups: [Group] {
        let pods = store.filteredObjects
        var byNode: [String: [K8sObject]] = [:]
        var unscheduled: [K8sObject] = []

        for pod in pods {
            guard let node = pod.spec?["nodeName"]?.stringValue, !node.isEmpty else {
                unscheduled.append(pod)
                continue
            }
            byNode[node, default: []].append(pod)
        }

        var groups = store.placementNodes.map { node in
            Group(id: node.name, node: node, pods: byNode.removeValue(forKey: node.name) ?? [])
        }
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
    let group: PlacementView.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if group.pods.isEmpty {
                Text("このノードに Pod はありません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                PodTileGrid(pods: group.pods)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.hairline, lineWidth: 1))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let node = group.node {
                let status = StatusResolver.status(for: node)
                Image(systemName: status.level.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.color(for: status.level))
                Text(node.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(status.text)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: status.level))
            } else {
                Image(systemName: StatusLevel.neutral.symbol)
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.color(for: .neutral))
                Text(group.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            // 件数は必ず文字で出す。タイルの数を目で数えさせない。
            Text("\(group.pods.count) Pod")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if let usage = usageText {
                Text(usage)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// ノードの使用率。取れないときは行ごと出さない（`0%` と書かない）。
    private var usageText: String? {
        guard let node = group.node,
              let usage = store.metrics.nodes[node.name] else { return nil }
        let allocatable = node.nodeAllocatable
        guard let cpu = Quantity.ratio(usage.cpuCores, of: allocatable.cpuCores),
              let memory = Quantity.ratio(usage.memoryBytes, of: allocatable.memoryBytes)
        else { return nil }
        return "CPU \(Quantity.formatPercent(cpu)) · メモリ \(Quantity.formatPercent(memory))"
    }
}

// MARK: - Pod のタイル

private struct PodTileGrid: View {
    let pods: [K8sObject]

    var body: some View {
        // 幅に合わせて折り返す。Pod は 200 を超えることがあるので、
        // 1 行に固定すると横スクロールになる。
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 6)],
            alignment: .leading, spacing: 6
        ) {
            ForEach(sorted) { pod in
                PodTile(pod: pod)
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

    private var isSelected: Bool { store.selectedObjectID == pod.id }

    var body: some View {
        let status = StatusResolver.health(for: pod)

        Button {
            store.selectedObjectID = pod.id
        } label: {
            HStack(spacing: 6) {
                // 色だけに意味を持たせない。左の帯と同じ色のしるしを添える。
                Image(systemName: status.level.symbol)
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.color(for: status.level))
                Text(pod.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
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
        .help("\(pod.namespace ?? "-")/\(pod.name) · \(status.text)")
    }
}
