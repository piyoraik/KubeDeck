import Foundation

/// Gateway API の経路（HTTPRoute など）1 件を、図に要る形へ読んだもの。判定はしない。
struct TrafficRoute: Identifiable, Sendable, Hashable {
    let kindLabel: String
    let namespace: String
    let name: String
    let parents: [Parent]
    let rules: [Rule]

    var id: String { "\(namespace)/\(kindLabel)/\(name)" }
}

// MARK: - 親と、コントローラが書いた状態

extension TrafficRoute {
    struct Parent: Sendable, Hashable {
        enum Kind: Sendable, Hashable {
            case gateway
            case service
            case other(String)
        }

        let kind: Kind
        let namespace: String
        let name: String
        let port: Int?
        let sectionName: String?
        /// 空は「受け付けた記録が無い」。False とは別（存在しない Gateway が親だと空になる。実測）。
        let reports: [Report]
    }

    struct Report: Sendable, Hashable {
        let controller: String
        let conditions: [Condition]
    }

    struct Condition: Sendable, Hashable {
        enum Status: Sendable, Hashable {
            case yes
            case no
            case unknown
        }

        let type: String
        let status: Status
        let reason: String
        let message: String
    }

    /// 親 1 つについて、画面に出すべきこと。reason と message はコントローラの文字のまま運ぶ。
    enum Finding: Sendable, Hashable {
        case notAccepted(reason: String, message: String)
        case unresolvedReferences(reason: String, message: String)
        case advisory(type: String, message: String)
        case undecided(type: String, message: String)
        case noRecord
    }

    /// 実装独自の条件が「問題なし」のときに書く決まり文句（Istio 1.32 で実測）。
    static let allClearMessages: Set<String> = ["All waypoints resolved"]
}

extension TrafficRoute.Parent {
    var findings: [TrafficRoute.Finding] {
        guard !reports.isEmpty else { return [.noRecord] }

        var result: [TrafficRoute.Finding] = []
        for report in reports {
            var advisories: [TrafficRoute.Finding] = []
            var isRejected = false
            for condition in report.conditions {
                switch (condition.type, condition.status) {
                case (_, .unknown):
                    result.append(.undecided(type: condition.type, message: condition.message))
                case ("Accepted", .no):
                    isRejected = true
                    result.append(
                        .notAccepted(reason: condition.reason, message: condition.message))
                case ("ResolvedRefs", .no):
                    result.append(
                        .unresolvedReferences(
                            reason: condition.reason, message: condition.message))
                case ("Accepted", .yes), ("ResolvedRefs", .yes):
                    continue
                default:
                    // 実装独自の条件は True / False を当てにしない（Istio の ResolvedWaypoints は「効かない」ときも True。実測）。
                    if !TrafficRoute.allClearMessages.contains(condition.message) {
                        advisories.append(
                            .advisory(type: condition.type, message: condition.message))
                    }
                }
            }
            // 付いていない親への補足は、付いていないことの言い直しになる（"parent not found"）。
            if !isRejected { result += advisories }
        }

        var seen = Set<TrafficRoute.Finding>()
        return result.filter { seen.insert($0).inserted }
    }
}

// MARK: - 規則と宛先

extension TrafficRoute {
    struct Backend: Sendable, Hashable {
        let group: String
        let kind: String
        let namespace: String
        let name: String
        let port: Int?
        let weight: Int

        var isService: Bool { group.isEmpty && kind == "Service" }
    }

    struct Rule: Sendable, Hashable {
        /// 1 始まりの並び順。優先順ではない（どの規則が当たるかは match の細かさで決まる）。
        let number: Int
        /// match の条件を文字にしたもの。評価はしない。空なら「すべてのリクエスト」。
        let matches: [String]
        let filters: [String]
        let backends: [Backend]

        var totalWeight: Int { backends.reduce(0) { $0 + $1.weight } }

        /// その宛先に流す割合（0...1）。重みは比で、合計が 100 とは限らない。
        func share(of backend: Backend) -> Double {
            let total = totalWeight
            guard total > 0 else { return 0 }
            return Double(backend.weight) / Double(total)
        }
    }

    struct Share: Sendable, Hashable {
        let rule: Int
        let fraction: Double
    }

    /// この経路がその Service に流す割合。規則ごとに違いうるので 1 つにまとめない。
    func shares(toService name: String, namespace: String) -> [Share] {
        rules.compactMap { rule in
            let matching = rule.backends.filter {
                $0.isService && $0.name == name && $0.namespace == namespace
            }
            guard !matching.isEmpty else { return nil }
            let total = rule.totalWeight
            guard total > 0 else { return Share(rule: rule.number, fraction: 0) }
            let weight = matching.reduce(0) { $0 + $1.weight }
            return Share(rule: rule.number, fraction: Double(weight) / Double(total))
        }
    }

    /// 割合の数字。「0」と「100」は本当にそうのときだけ書く。
    static func percentText(_ fraction: Double) -> String {
        let rounded = (fraction * 1000).rounded() / 10
        if rounded <= 0 { return fraction > 0 ? "<0.1" : "0" }
        if rounded >= 100 { return fraction < 1 ? ">99.9" : "100" }
        return rounded == rounded.rounded()
            ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    }
}

// MARK: - 宛先を手元の Service に解く

extension TrafficRoute {
    struct Destinations: Sendable {
        var services: [K8sObject] = []
        /// 取得した範囲の中にあるはずなのに無い。
        var missing: [Backend] = []
        /// 範囲の外か、Service を読めていない。「無い」とは言えない。
        var unverifiable: [Backend] = []
        /// Service 以外（ServiceImport など）。辿らない。
        var unsupported: [Backend] = []
    }

    /// `scope` は絞り込んでいる Namespace。nil なら全 Namespace を取得している。
    func destinations(
        among objects: [K8sObject], scope: String?, servicesReadable: Bool = true
    ) -> Destinations {
        var result = Destinations()
        var seen = Set<String>()

        for backend in rules.flatMap(\.backends) {
            let key = "\(backend.group)/\(backend.kind)/\(backend.namespace)/\(backend.name)"
            guard seen.insert(key).inserted else { continue }

            guard backend.isService else {
                result.unsupported.append(backend)
                continue
            }
            if let service = objects.first(where: {
                $0.kind == .service && $0.namespace == backend.namespace
                    && $0.name == backend.name
            }) {
                result.services.append(service)
            } else if !servicesReadable || (scope != nil && scope != backend.namespace) {
                result.unverifiable.append(backend)
            } else {
                result.missing.append(backend)
            }
        }
        return result
    }

    /// コントローラが、宛先を解決できていないと言っているか。
    var reportsUnresolvedBackends: Bool {
        parents.contains { parent in
            parent.reports.contains { report in
                report.conditions.contains { $0.type == "ResolvedRefs" && $0.status == .no }
            }
        }
    }

    /// 500 になる割合。手元で無いと分かり、コントローラも解決できていないと言うときだけ返す。
    func deadShares(_ destinations: Destinations) -> [Share] {
        guard reportsUnresolvedBackends else { return [] }

        let missing = Set(destinations.missing.map { "\($0.namespace)/\($0.name)" })
        return rules.compactMap { rule in
            let total = rule.totalWeight
            guard total > 0 else { return nil }
            let dead = rule.backends
                .filter { $0.isService && missing.contains("\($0.namespace)/\($0.name)") }
                .reduce(0) { $0 + $1.weight }
            guard dead > 0 else { return nil }
            return Share(rule: rule.number, fraction: Double(dead) / Double(total))
        }
    }
}

// MARK: - 読み取り

extension TrafficRoute {
    private static let gatewayGroup = "gateway.networking.k8s.io"

    /// 経路の一覧から読む。Namespace を持たないものは経路ではないので落とす。
    static func routes(from objects: [K8sObject]) -> [TrafficRoute] {
        objects.compactMap { TrafficRoute(object: $0) }
    }

    init?(object: K8sObject, assumingKind: String = "HTTPRoute") {
        guard let namespace = object.namespace, !namespace.isEmpty else { return nil }
        self.kindLabel = object.rawKind.isEmpty ? assumingKind : object.rawKind
        self.namespace = namespace
        self.name = object.name

        let references = (object.spec?["parentRefs"]?.arrayValue ?? []).compactMap {
            Reference($0, routeNamespace: namespace)
        }
        let reported: [(reference: Reference, report: Report)] =
            (object.status?["parents"]?.arrayValue ?? []).compactMap { entry in
                guard let raw = entry["parentRef"],
                      let reference = Reference(raw, routeNamespace: namespace)
                else { return nil }
                return (
                    reference,
                    Report(
                        controller: entry["controllerName"]?.stringValue ?? "",
                        conditions: (entry["conditions"]?.arrayValue ?? [])
                            .compactMap(Condition.init(raw:)))
                )
            }

        self.parents = references.map { reference in
            // 同じ相手を指す親が 1 つなら、port や sectionName の書き方が違っても同じものとして扱う。
            let isOnlyReference = references.filter { $0.target == reference.target }.count == 1
            let reports = reported
                .filter { entry in
                    entry.reference.target == reference.target
                        && (isOnlyReference || entry.reference == reference)
                }
                .map(\.report)
            return Parent(
                kind: reference.kind, namespace: reference.namespace, name: reference.name,
                port: reference.port, sectionName: reference.sectionName, reports: reports)
        }

        self.rules = (object.spec?["rules"]?.arrayValue ?? []).enumerated().map { index, rule in
            Rule(
                number: index + 1,
                matches: (rule["matches"]?.arrayValue ?? [])
                    .map(Self.describe(match:))
                    .filter { !$0.isEmpty },
                filters: (rule["filters"]?.arrayValue ?? [])
                    .compactMap { $0["type"]?.stringValue },
                backends: (rule["backendRefs"]?.arrayValue ?? []).compactMap { raw in
                    guard let name = raw["name"]?.stringValue else { return nil }
                    return Backend(
                        group: raw["group"]?.stringValue ?? "",
                        kind: raw["kind"]?.stringValue ?? "Service",
                        namespace: raw["namespace"]?.stringValue ?? namespace,
                        name: name,
                        port: raw["port"]?.intValue,
                        // 省略時は 1（API サーバが埋めない版に備える）。
                        weight: max(0, raw["weight"]?.intValue ?? 1))
                })
        }
    }

    /// 既定の「すべてのパス」（PathPrefix /）は条件として数えない。
    private static func describe(match: JSONValue) -> String {
        var parts: [String] = []
        if let path = match["path"] {
            let type = path["type"]?.stringValue ?? "PathPrefix"
            let value = path["value"]?.stringValue ?? "/"
            if !(type == "PathPrefix" && value == "/") {
                parts.append("\(type) \(value)")
            }
        }
        if let method = match["method"]?.stringValue {
            parts.append(method)
        }
        for header in match["headers"]?.arrayValue ?? [] {
            guard let name = header["name"]?.stringValue else { continue }
            let value = header["value"]?.stringValue ?? ""
            let isPattern = header["type"]?.stringValue == "RegularExpression"
            parts.append(isPattern ? "\(name) ~ \(value)" : "\(name): \(value)")
        }
        for query in match["queryParams"]?.arrayValue ?? [] {
            guard let name = query["name"]?.stringValue else { continue }
            let value = query["value"]?.stringValue ?? ""
            let isPattern = query["type"]?.stringValue == "RegularExpression"
            parts.append(isPattern ? "?\(name) ~ \(value)" : "?\(name)=\(value)")
        }
        return parts.joined(separator: ", ")
    }

    /// `parentRefs` と `status.parents[].parentRef` を同じ形に揃えたもの。省略された値は既定で埋める。
    private struct Reference: Hashable {
        struct Target: Hashable {
            let group: String
            let kind: String
            let namespace: String
            let name: String
        }

        let target: Target
        let port: Int?
        let sectionName: String?

        var namespace: String { target.namespace }
        var name: String { target.name }

        var kind: Parent.Kind {
            if target.group == TrafficRoute.gatewayGroup, target.kind == "Gateway" {
                return .gateway
            }
            if target.group.isEmpty, target.kind == "Service" { return .service }
            return .other(target.kind)
        }

        init?(_ raw: JSONValue, routeNamespace: String) {
            guard let name = raw["name"]?.stringValue else { return nil }
            self.target = Target(
                group: raw["group"]?.stringValue ?? TrafficRoute.gatewayGroup,
                kind: raw["kind"]?.stringValue ?? "Gateway",
                namespace: raw["namespace"]?.stringValue ?? routeNamespace,
                name: name)
            self.port = raw["port"]?.intValue
            self.sectionName = raw["sectionName"]?.stringValue
        }
    }
}

extension TrafficRoute.Condition {
    fileprivate init?(raw: JSONValue) {
        guard let type = raw["type"]?.stringValue else { return nil }
        self.type = type
        switch raw["status"]?.stringValue {
        case "True": self.status = .yes
        case "False": self.status = .no
        default: self.status = .unknown
        }
        self.reason = raw["reason"]?.stringValue ?? ""
        self.message = raw["message"]?.stringValue ?? ""
    }
}
