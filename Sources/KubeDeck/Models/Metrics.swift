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

/// 何を使うかの設定。
enum MetricsSourcePreference: String, CaseIterable, Identifiable, Sendable {
    /// 使えるものから選ぶ。metrics-server を優先する。
    case automatic
    case metricsServer
    case prometheus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: return "自動"
        case .metricsServer: return "metrics-server"
        case .prometheus: return "Prometheus"
        }
    }

    var explanation: String {
        switch self {
        case .automatic:
            return "使えるものを自動で選ぶ。現在値は metrics-server を優先し、無ければ Prometheus を使う。推移は Prometheus があるときだけ出る。"
        case .metricsServer:
            return "現在値だけを metrics-server から取る。呼び出しが軽く、いまの値が最も正確。推移は Prometheus があれば別途出る。"
        case .prometheus:
            return "現在値も Prometheus から取る。metrics-server が入っていないクラスタや、scrape 済みの値と表示を揃えたいときに使う。"
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
