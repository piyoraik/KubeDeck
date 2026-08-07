import Foundation

/// ある時点の使用量。CPU はコア、メモリはバイト。
struct ResourceUsage: Sendable, Hashable {
    var cpuCores: Double = 0
    var memoryBytes: Double = 0

    static func + (lhs: ResourceUsage, rhs: ResourceUsage) -> ResourceUsage {
        ResourceUsage(
            cpuCores: lhs.cpuCores + rhs.cpuCores,
            memoryBytes: lhs.memoryBytes + rhs.memoryBytes)
    }

    var isZero: Bool { cpuCores == 0 && memoryBytes == 0 }
}

/// metrics-server から取った一時点のスナップショット。
struct MetricsSnapshot: Sendable {
    /// ノード名 → 使用量。
    var nodes: [String: ResourceUsage] = [:]
    /// `"namespace/name"` → Pod 全体の使用量。
    var pods: [String: ResourceUsage] = [:]
    /// `"namespace/name"` → コンテナ名 → 使用量。
    var containers: [String: [String: ResourceUsage]] = [:]

    var isEmpty: Bool { nodes.isEmpty && pods.isEmpty }

    /// 一覧のセルから引くためのキー。Namespace を持たないものは名前だけ。
    static func key(namespace: String?, name: String) -> String {
        guard let namespace, !namespace.isEmpty else { return name }
        return "\(namespace)/\(name)"
    }

    func usage(for object: K8sObject) -> ResourceUsage? {
        switch object.kind {
        case .node: return nodes[object.name]
        case .pod: return pods[Self.key(namespace: object.namespace, name: object.name)]
        default: return nil
        }
    }
}

// MARK: - ワークロード単位の合計

/// ワークロード 1 つぶんの使用量。Pod ごとの値を足し上げたもの。
///
/// **合計と割合の対象を揃える。** 使用量を引けなかった Pod は、分子にも分母にも
/// 入れない。分母にだけ入れると、引けていないぶん割合が低く出て「まだ余裕が
/// ある」と読める（`0` を並べないのと同じ話）。引けなかったことは数で持ち回り、
/// 画面が文字で断る。
struct WorkloadUsage: Sendable, Hashable {
    /// CPU かメモリ、どちらか 1 本ぶん。**軸ごとに別に見る** — メモリにだけ
    /// 上限があって CPU には無い、という書き方はふつうにある。
    struct Axis: Sendable, Hashable {
        var used: Double = 0
        var base: Double = 0
        /// 上限も要求も書かれていない Pod の数。
        var podsWithoutBase = 0
        /// 分母に上限を使った Pod の数と、要求に落ちた Pod の数。
        var limitPods = 0
        var requestPods = 0

        /// **分母を持たない Pod が 1 つでもあれば割合を出さない。**
        /// その Pod のぶんだけ分母が小さいので、割合が実際より高く出る
        /// （しかも高いほうへ外すので、余裕があるのに赤く見える）。
        var ratio: Double? {
            guard podsWithoutBase == 0 else { return nil }
            return Quantity.ratio(used, of: base)
        }

        /// 分母が何なのか。**書かないと要求と上限のどちらを見ているのか
        /// 分からない。** Pod ごとに違いうるので、混ざったら混ざったと書く。
        var baseLabel: String? {
            switch (limitPods, requestPods) {
            case (0, 0): return nil
            case (_, 0): return String(localized: "上限")
            case (0, _): return String(localized: "要求")
            default: return String(localized: "上限・要求")
            }
        }
    }

    var cpu = Axis()
    var memory = Axis()
    /// 対象の Pod の数と、そのうち使用量を引けた数。
    var podCount = 0
    var measuredPods = 0

    /// 1 つでも引けたか。**引けていないことを 0 と書かない**ための分かれ目。
    var isMeasured: Bool { measuredPods > 0 }
    /// 引けた Pod と、対象の Pod の数が食い違っているか。
    var isPartial: Bool { measuredPods < podCount }
}

extension MetricsSnapshot {
    /// Pod の集まりを 1 つのワークロードとして足し上げる。
    ///
    /// 分母は Pod 単体と同じ規則（上限、無ければ要求）。**初期化コンテナは
    /// 足さない** — 同時に動かないので、`containerResourceTotal` と揃える
    /// （ずれると 2 か所で違う数字が出る）。
    func workloadUsage(of pods: [K8sObject]) -> WorkloadUsage {
        var result = WorkloadUsage()
        result.podCount = pods.count
        for pod in pods {
            guard let used = usage(for: pod) else { continue }
            result.measuredPods += 1
            let requests = pod.containerResourceTotal("requests")
            let limits = pod.containerResourceTotal("limits")
            Self.accumulate(
                &result.cpu, used: used.cpuCores,
                limit: limits.cpuCores, request: requests.cpuCores)
            Self.accumulate(
                &result.memory, used: used.memoryBytes,
                limit: limits.memoryBytes, request: requests.memoryBytes)
        }
        return result
    }

    private static func accumulate(
        _ axis: inout WorkloadUsage.Axis, used: Double, limit: Double, request: Double
    ) {
        axis.used += used
        if limit > 0 {
            axis.base += limit
            axis.limitPods += 1
        } else if request > 0 {
            axis.base += request
            axis.requestPods += 1
        } else {
            axis.podsWithoutBase += 1
        }
    }
}

/// 何を使うかの設定。
enum MetricsSourcePreference: String, CaseIterable, Identifiable, Sendable {
    /// 使えるものから選ぶ。metrics-server を優先する。
    case automatic
    case metricsServer
    case prometheus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return String(localized: "自動")
        case .metricsServer: return "metrics-server"
        case .prometheus: return "Prometheus"
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            
                return String(localized: "使えるものを自動で選ぶ。現在値は metrics-server を優先し、無ければ Prometheus を使う。推移は Prometheus があるときだけ出る。")
        case .metricsServer:
            
                return String(localized: "現在値だけを metrics-server から取る。呼び出しが軽く、いまの値が最も正確。推移は Prometheus があれば別途出る。")
        case .prometheus:
            
                return String(localized: "現在値も Prometheus から取る。metrics-server が入っていないクラスタや、scrape 済みの値と表示を揃えたいときに使う。")
        }
    }
}

/// 実際に使っている取得元。設定と、クラスタで使えるものの両方で決まる。
enum MetricsSource: Sendable, Hashable {
    case metricsServer
    case prometheus(PrometheusEndpoint)
    case none

    var label: String {
        switch self {
        case .metricsServer: return "metrics-server"
        case .prometheus(let endpoint): return "Prometheus (\(endpoint.display))"
        case .none: return ""
        }
    }

    var isAvailable: Bool { self != .none }
}

// MARK: - 割り当てとの比較

extension K8sObject {
    /// Pod の requests / limits の合計。使用率の分母に使う。
    /// 初期化コンテナは同時に動かないので足さない。
    func containerResourceTotal(_ field: String) -> ResourceUsage {
        (spec?["containers"]?.arrayValue ?? []).reduce(into: ResourceUsage()) { total, container in
            guard let values = container.path("resources.\(field)") else { return }
            if let cpu = values["cpu"]?.stringValue.flatMap(Quantity.parse) {
                total.cpuCores += cpu
            }
            if let memory = values["memory"]?.stringValue.flatMap(Quantity.parse) {
                total.memoryBytes += memory
            }
        }
    }

    /// ノードの割り当て可能量。capacity ではなく allocatable を使う。
    /// capacity にはシステム予約が含まれており、Pod が使える量ではない。
    var nodeAllocatable: ResourceUsage {
        guard let allocatable = status?["allocatable"] else { return ResourceUsage() }
        return ResourceUsage(
            cpuCores: allocatable["cpu"]?.stringValue.flatMap(Quantity.parse) ?? 0,
            memoryBytes: allocatable["memory"]?.stringValue.flatMap(Quantity.parse) ?? 0)
    }
}
