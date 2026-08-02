import Foundation

/// 見つかった Prometheus の場所。
struct PrometheusEndpoint: Sendable, Hashable, Codable {
    var namespace: String
    var service: String
    var port: Int

    var display: String { "\(namespace)/\(service):\(port)" }

    /// API サーバのプロキシ経由の URL。
    ///
    /// port-forward を張らず、kubectl の `--raw` でプロキシを通す。
    /// こうすると認証・TLS・プロキシ設定をすべて kubectl に任せられ、
    /// 待ち受けポートの管理もアプリが抱えずに済む。
    func path(_ apiPath: String, query: [URLQueryItem]) -> String {
        var components = URLComponents()
        components.queryItems = query
        let encoded = components.percentEncodedQuery ?? ""
        return "/api/v1/namespaces/\(namespace)/services/\(service):\(port)"
            + "/proxy/api/v1/\(apiPath)?\(encoded)"
    }
}

/// 時系列の 1 本。
struct TimeSeries: Sendable, Hashable {
    struct Point: Sendable, Hashable {
        var date: Date
        var value: Double
    }

    var points: [Point] = []

    var isEmpty: Bool { points.count < 2 }
    var latest: Double? { points.last?.value }
    var maximum: Double { points.map(\.value).max() ?? 0 }
}

/// CPU とメモリの履歴 1 組。
struct MetricsHistory: Sendable {
    /// 何に対する系列か。取り違えを防ぐために持つ。
    var subject: String = ""
    var cpu = TimeSeries()
    var memory = TimeSeries()

    var isEmpty: Bool { cpu.points.isEmpty && memory.points.isEmpty }
}

/// Prometheus（および互換の Thanos / VictoriaMetrics）への問い合わせ。
actor PrometheusClient {
    static let shared = PrometheusClient()

    private let kubectl = Kubectl.shared

    // MARK: - 探索

    /// よくある Service 名と待ち受けポート。名前で当たりを付けてから実際に応答を確かめる。
    private static let candidateNames = [
        "prometheus-operated", "prometheus-k8s", "prometheus-server", "prometheus",
        "kube-prometheus-stack-prometheus", "thanos-query", "thanos-querier",
        "victoria-metrics-single-server", "vmsingle", "mimir-query-frontend",
    ]
    private static let candidatePorts = [9090, 8428, 9091, 10902, 8080]

    /// クラスタから Prometheus を探す。見つからなければ nil。
    ///
    /// 名前が一致しただけでは決めない。`/api/v1/query` に実際に投げて
    /// Prometheus 互換の応答が返るところだけを採用する。別物が同じ名前で
    /// 立っていることがあるため。
    func discover(context: String) async -> PrometheusEndpoint? {
        guard let services = try? await kubectl.list(.service, context: context, namespace: nil)
        else { return nil }

        var candidates: [PrometheusEndpoint] = []
        for service in services {
            guard let namespace = service.namespace else { continue }
            let name = service.name
            let looksRight = Self.candidateNames.contains(name)
                || name.lowercased().contains("prometheus")
                || service.labels["app.kubernetes.io/name"]?.contains("prometheus") == true

            for port in service.spec?["ports"]?.arrayValue ?? [] {
                guard let number = port["port"]?.intValue else { continue }
                let portLooksRight = Self.candidatePorts.contains(number)
                guard looksRight || portLooksRight else { continue }
                candidates.append(
                    PrometheusEndpoint(namespace: namespace, service: name, port: number))
            }
        }

        // 名前も番号も合うものを先に試す。
        candidates.sort { lhs, rhs in
            let lhsScore = (Self.candidateNames.contains(lhs.service) ? 2 : 0)
                + (Self.candidatePorts.contains(lhs.port) ? 1 : 0)
            let rhsScore = (Self.candidateNames.contains(rhs.service) ? 2 : 0)
                + (Self.candidatePorts.contains(rhs.port) ? 1 : 0)
            return lhsScore > rhsScore
        }

        for candidate in candidates.prefix(8) where await probe(candidate, context: context) {
            return candidate
        }
        return nil
    }

    /// 実際に問い合わせて Prometheus 互換かどうかを見る。
    func probe(_ endpoint: PrometheusEndpoint, context: String) async -> Bool {
        let path = endpoint.path("query", query: [URLQueryItem(name: "query", value: "1")])
        guard let data = try? await kubectl.raw(path, context: context),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data)
        else { return false }
        return root["status"]?.stringValue == "success"
    }

    // MARK: - 問い合わせ

    /// 範囲クエリ。スパークラインの元になる。
    func queryRange(
        _ promQL: String,
        endpoint: PrometheusEndpoint,
        context: String,
        duration: TimeInterval,
        step: TimeInterval
    ) async -> TimeSeries {
        let end = Date()
        let start = end.addingTimeInterval(-duration)
        let path = endpoint.path("query_range", query: [
            URLQueryItem(name: "query", value: promQL),
            URLQueryItem(name: "start", value: "\(Int(start.timeIntervalSince1970))"),
            URLQueryItem(name: "end", value: "\(Int(end.timeIntervalSince1970))"),
            URLQueryItem(name: "step", value: "\(Int(step))s"),
        ])

        guard let data = try? await kubectl.raw(path, context: context),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              root["status"]?.stringValue == "success"
        else { return TimeSeries() }

        // 複数系列が返ったら足し合わせる。同じ時刻に揃っている前提で、
        // 時刻をキーにまとめる（step を指定しているので揃う）。
        var totals: [Double: Double] = [:]
        for series in root.path("data.result")?.arrayValue ?? [] {
            for sample in series["values"]?.arrayValue ?? [] {
                guard let timestamp = sample[0]?.doubleValue,
                      let value = sample[1]?.stringValue.flatMap(Double.init)
                else { continue }
                totals[timestamp, default: 0] += value
            }
        }

        let points = totals
            .map { TimeSeries.Point(date: Date(timeIntervalSince1970: $0.key), value: $0.value) }
            .sorted { $0.date < $1.date }
        return TimeSeries(points: points)
    }

    /// 瞬時クエリ。取得元として Prometheus を選んだときに一覧の列を埋める。
    private func queryVector(
        _ promQL: String, endpoint: PrometheusEndpoint, context: String
    ) async -> [(labels: [String: String], value: Double)] {
        let path = endpoint.path("query", query: [URLQueryItem(name: "query", value: promQL)])
        guard let data = try? await kubectl.raw(path, context: context),
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              root["status"]?.stringValue == "success"
        else { return [] }

        return (root.path("data.result")?.arrayValue ?? []).compactMap { item in
            guard let value = item["value"]?[1]?.stringValue.flatMap(Double.init) else {
                return nil
            }
            return (item["metric"]?.stringDictionary ?? [:], value)
        }
    }

    /// metrics-server の代わりに Prometheus から現在値を作る。
    ///
    /// 4 本のクエリで済ませる。Pod ごとに問い合わせると Pod の数だけ
    /// kubectl が立ち上がるので、`by` で一度にまとめて取る。
    func snapshot(
        endpoint: PrometheusEndpoint, context: String, namespace: String?
    ) async -> MetricsSnapshot {
        let filter = namespace.map { #"namespace="\#($0)","# } ?? ""
        let base = #"\#(filter)container!="",container!="POD""#

        async let containerCPU = queryVector(
            #"sum by (namespace, pod, container) (rate(container_cpu_usage_seconds_total{\#(base)}[2m]))"#,
            endpoint: endpoint, context: context)
        async let containerMemory = queryVector(
            #"sum by (namespace, pod, container) (container_memory_working_set_bytes{\#(base)})"#,
            endpoint: endpoint, context: context)
        async let nodeCPU = queryVector(
            #"sum by (node) (rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[2m]))"#,
            endpoint: endpoint, context: context)
        async let nodeMemory = queryVector(
            #"sum by (node) (container_memory_working_set_bytes{container!="",container!="POD"})"#,
            endpoint: endpoint, context: context)

        var snapshot = MetricsSnapshot()

        for (labels, value) in await containerCPU {
            guard let key = Self.podKey(labels), let container = labels["container"] else {
                continue
            }
            snapshot.containers[key, default: [:]][container, default: ResourceUsage()]
                .cpuCores = value
        }
        for (labels, value) in await containerMemory {
            guard let key = Self.podKey(labels), let container = labels["container"] else {
                continue
            }
            snapshot.containers[key, default: [:]][container, default: ResourceUsage()]
                .memoryBytes = value
        }
        for (key, containers) in snapshot.containers {
            snapshot.pods[key] = containers.values.reduce(into: ResourceUsage()) { $0 = $0 + $1 }
        }

        for (labels, value) in await nodeCPU {
            guard let node = labels["node"] else { continue }
            snapshot.nodes[node, default: ResourceUsage()].cpuCores = value
        }
        for (labels, value) in await nodeMemory {
            guard let node = labels["node"] else { continue }
            snapshot.nodes[node, default: ResourceUsage()].memoryBytes = value
        }

        return snapshot
    }

    private static func podKey(_ labels: [String: String]) -> String? {
        guard let pod = labels["pod"] else { return nil }
        return MetricsSnapshot.key(namespace: labels["namespace"], name: pod)
    }

    // MARK: - 問い合わせ文

    /// cAdvisor 由来の指標を使う。kubelet が出しているので、Prometheus が
    /// kubelet を拾ってさえいれば node-exporter が無くても取れる。
    enum Query {
        static func podCPU(namespace: String, pod: String, window: String = "2m") -> String {
            // container="" は Pod 全体の集計値で、コンテナ別と二重に数えてしまう。
            #"sum(rate(container_cpu_usage_seconds_total{namespace="\#(namespace)",pod="\#(pod)",container!="",container!="POD"}[\#(window)]))"#
        }

        static func podMemory(namespace: String, pod: String) -> String {
            #"sum(container_memory_working_set_bytes{namespace="\#(namespace)",pod="\#(pod)",container!="",container!="POD"})"#
        }

        static func nodeCPU(node: String, window: String = "2m") -> String {
            #"sum(rate(container_cpu_usage_seconds_total{node="\#(node)",container!="",container!="POD"}[\#(window)]))"#
        }

        static func nodeMemory(node: String) -> String {
            #"sum(container_memory_working_set_bytes{node="\#(node)",container!="",container!="POD"})"#
        }

        static func clusterCPU(window: String = "2m") -> String {
            #"sum(rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[\#(window)]))"#
        }

        static func clusterMemory() -> String {
            #"sum(container_memory_working_set_bytes{container!="",container!="POD"})"#
        }
    }
}

extension JSONValue {
    /// Prometheus の値は `[<unix秒>, "<値>"]` の形で、時刻が数値、値が文字列。
    var doubleValue: Double? {
        switch self {
        case .int(let value): return Double(value)
        case .double(let value): return value
        case .string(let value): return Double(value)
        default: return nil
        }
    }
}
