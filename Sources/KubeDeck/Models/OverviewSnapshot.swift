import Foundation

struct StatusBucket: Identifiable, Sendable, Hashable {
    let level: StatusLevel
    let count: Int

    var id: Int { level.rawValue }
    var label: String { level.label }
}

struct ReasonCount: Identifiable, Sendable, Hashable {
    let reason: String
    let level: StatusLevel
    let count: Int

    var id: String { reason }
}

/// ドーナツ 1 つ分の集計。状態の重みごとの件数と、内訳の理由。
struct StatusTally: Sendable, Hashable {
    var buckets: [StatusBucket] = []
    var reasons: [ReasonCount] = []

    var total: Int { buckets.reduce(0) { $0 + $1.count } }
    var healthy: Int { buckets.first { $0.level == .good }?.count ?? 0 }
    var isEmpty: Bool { total == 0 }

    /// 正常でないものの件数。見出しの添え書きに使う。
    var unhealthy: Int {
        buckets.filter { $0.level == .critical || $0.level == .serious }
            .reduce(0) { $0 + $1.count }
    }

    static func make(from objects: [K8sObject]) -> StatusTally {
        var perLevel: [StatusLevel: Int] = [:]
        var perReason: [String: (StatusLevel, Int)] = [:]

        for object in objects {
            let status = StatusResolver.health(for: object)
            perLevel[status.level, default: 0] += 1
            let key = status.text.isEmpty ? status.level.label : status.text
            perReason[key, default: (status.level, 0)].1 += 1
        }

        let buckets = StatusLevel.allCases.compactMap { level -> StatusBucket? in
            guard let count = perLevel[level], count > 0 else { return nil }
            return StatusBucket(level: level, count: count)
        }
        // 重い状態を先に、同じ重さなら件数の多い順。困っているものが上に来る。
        let reasons = perReason
            .map { ReasonCount(reason: $0.key, level: $0.value.0, count: $0.value.1) }
            .sorted { lhs, rhs in
                if lhs.level.severityOrder != rhs.level.severityOrder {
                    return lhs.level.severityOrder < rhs.level.severityOrder
                }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.reason < rhs.reason
            }

        return StatusTally(buckets: buckets, reasons: reasons)
    }
}

struct OverviewSnapshot: Sendable {
    var serverVersion: String = ""
    var counts: [ResourceKind: Int] = [:]
    var pods = StatusTally()
    var workloads = StatusTally()
    var nodes = StatusTally()
    var recentEvents: [K8sObject] = []
    /// 全ノードの割り当て可能量の合計。使用率の分母。
    var allocatable = ResourceUsage()

    func count(_ kind: ResourceKind) -> Int { counts[kind] ?? 0 }
}
