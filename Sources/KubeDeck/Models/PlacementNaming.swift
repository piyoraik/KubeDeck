import Foundation

// 配置の画面で、名前のうち区別に要る部分だけを出すための切り出し。

extension PlacementTrace {
    /// これより短い残りは名前として読めないので、切り出さない（`cache-0` の `0`）。
    static let shortestPodSuffix = 3

    /// Pod の id → ワークロードの中で区別に要る部分。切り出せない Pod は名前のまま返す。
    static func podSuffixes(
        for pods: [K8sObject], controllers index: [String: K8sObject]
    ) -> [String: String] {
        var owners: [String: (kind: String, name: String)] = [:]
        var members: [String: [K8sObject]] = [:]
        var result: [String: String] = [:]

        for pod in pods {
            guard let owner = workloadOwner(of: pod, controllers: index) else {
                result[pod.id] = pod.name
                continue
            }
            let key = "\(pod.namespace ?? "-")/\(owner.kind)/\(owner.name)"
            owners[key] = owner
            members[key, default: []].append(pod)
        }

        for (key, pods) in members {
            guard let owner = owners[key] else { continue }
            // 世代が 2 つあるあいだは、世代の名前（ReplicaSet のハッシュ）も残す。
            let generations = Set(pods.compactMap { controllerReference(of: $0)?.name })
            let generation = generations.count == 1 ? generations.first : nil
            let labels = pods.map { suffix(of: $0.name, owner: owner, generation: generation) }
            let isDistinct = Set(labels).count == labels.count
            for (pod, label) in zip(pods, labels) {
                result[pod.id] = isDistinct ? label : pod.name
            }
        }
        return result
    }

    private static func suffix(
        of name: String, owner: (kind: String, name: String), generation: String?
    ) -> String {
        var rest: Substring?
        if owner.kind == "Node", name.hasSuffix("-" + owner.name) {
            // kubelet が直に起こす Pod は `<名前>-<ノード名>` で、区別に要るのは頭のほう。
            rest = name.dropLast(owner.name.count + 1)
        } else if let generation, name.hasPrefix(generation + "-") {
            rest = name.dropFirst(generation.count + 1)
        } else if name.hasPrefix(owner.name + "-") {
            rest = name.dropFirst(owner.name.count + 1)
        }
        guard let rest, rest.count >= shortestPodSuffix else { return name }
        return String(rest)
    }

    /// 散らす先があるか。無いのに「1 ノードに固まっている」と警告しない。
    static func canSpread(ownerKind: String?, clusterNodeCount: Int) -> Bool {
        // kubelet が直に起こす Pod はそのノードにしか居られない。0 は「読めていない」なので警告を残す。
        ownerKind != "Node" && clusterNodeCount != 1
    }

    /// ノード名ぜんぶに共通する頭（`-` か `.` の区切りまで）。省けないときは空。
    static func sharedNodePrefix(_ names: [String]) -> String {
        guard names.count > 1, var prefix = names.first else { return "" }
        for name in names {
            while !name.hasPrefix(prefix) { prefix.removeLast() }
        }
        guard let cut = prefix.lastIndex(where: { $0 == "-" || $0 == "." }) else { return "" }
        prefix = String(prefix[...cut])
        // 短い頭を省いても読みやすくならず、何も残らない名前は省けない。
        guard prefix.count >= 4, names.allSatisfy({ $0.count > prefix.count }) else { return "" }
        return prefix
    }
}

/// Pod のチップに引く棒 1 本ぶん。
struct PodPressure: Sendable, Hashable {
    let ratio: Double
    /// 分母が上限か。要求に落ちた割合は、超えても異常ではないので色を付けない。
    let isAgainstLimit: Bool

    var level: StatusLevel? {
        isAgainstLimit ? ResourceTable.usageLevel(ratio) : nil
    }
}

extension MetricsSnapshot {
    /// 上限に迫っている軸があればそれを、無ければ割合のいちばん高い軸を返す。
    func pressure(of pod: K8sObject, metric: PlacementMetric) -> PodPressure? {
        guard let used = usage(for: pod) else { return nil }
        let limits = pod.containerResourceTotal("limits")
        let requests = pod.containerResourceTotal("requests")

        var axes: [PodPressure] = []
        func add(_ used: Double, limit: Double, request: Double) {
            if let ratio = Quantity.ratio(used, of: limit) {
                axes.append(PodPressure(ratio: ratio, isAgainstLimit: true))
            } else if let ratio = Quantity.ratio(used, of: request) {
                axes.append(PodPressure(ratio: ratio, isAgainstLimit: false))
            }
        }
        if metric.showsCPU {
            add(used.cpuCores, limit: limits.cpuCores, request: requests.cpuCores)
        }
        if metric.showsMemory {
            add(used.memoryBytes, limit: limits.memoryBytes, request: requests.memoryBytes)
        }
        // 要求比のほうが大きいだけで、上限に迫っている軸を隠さない。
        let pressing = axes.filter { $0.level != nil }
        return (pressing.isEmpty ? axes : pressing).max { $0.ratio < $1.ratio }
    }
}
