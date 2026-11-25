import Foundation

/// たどるの「通信」の段。`NetworkReachability.summary` を、図の行に畳んだもの。

/// 相手として出すワークロード（または単体の Pod）。
struct TracePeer: Sendable, Hashable {
    let name: String
    let kindLabel: String
    let namespace: String?
    let symbol: String
    /// 押すと起点にできるもの。単体の Pod は nil。
    let anchor: TraceAnchor?
}

struct TraceFlowRow: Identifiable, Sendable {
    enum Subject: Sendable {
        /// 制限されていない。`count` が nil なら起点の Pod すべて。
        case unrestricted(count: Int?)
        /// 制限されていて、許可の規則が 1 つも無い。
        case denyAll
        /// 規則に相手の指定が無い。
        case anywhere
        case workload(TracePeer, FlowPeerGroup.Outcome, podCount: Int)
        /// 当たるが、中の Pod を取得していない Namespace。`pods` は Pod の絞り（nil はすべて）。
        case namespace(String, pods: String?)
        case ipBlock(cidr: String, except: [String])
        /// 規則はあるが、手元の Pod に 1 つも当たらない。
        case unmatched(String)
    }

    let id: String
    let subject: Subject
    /// nil はすべてのポート。
    var ports: [PolicyPort]?
    /// 許可している（`denyAll` なら制限している）policy の名前。
    var policies: [String]
}

struct TraceFlowColumn: Sendable {
    var rows: [TraceFlowRow] = []
    var notes: [String] = []
}

struct TraceNetwork: Sendable {
    let ingress: TraceFlowColumn
    let egress: TraceFlowColumn
    /// 起点の Pod に効いている policy の名前（どちらかの向きを制限しているもの）。
    let policies: [String]
}

extension PlacementTrace {
    static func network(
        for pods: [K8sObject], inventory: PlacementInventory,
        controllers index: [String: K8sObject], scope: String?,
        namespaceLabels: [String: [String: String]]?
    ) -> TraceNetwork {
        let network = NetworkInventory(
            pods: inventory.pods,
            policies: inventory.related.filter { $0.kind == .networkPolicy },
            scope: scope, namespaceLabels: namespaceLabels)

        var peers: [String: TracePeer] = [:]
        let key: (K8sObject) -> String = { pod in
            let anchor = workloadAnchor(of: pod, controllers: index)
            let key = anchor.isStandalone ? "pod|\(pod.id)" : anchor.id
            if peers[key] == nil {
                peers[key] = anchor.isStandalone
                    ? TracePeer(
                        name: pod.name, kindLabel: ResourceKind.pod.apiKind,
                        namespace: pod.namespace, symbol: ResourceKind.pod.symbol, anchor: nil)
                    : TracePeer(
                        name: anchor.name, kindLabel: anchor.kindLabel,
                        namespace: anchor.namespace, symbol: anchor.symbol, anchor: anchor)
            }
            return key
        }

        let ingress = NetworkReachability.summary(.ingress, of: pods, in: network, groupKey: key)
        let egress = NetworkReachability.summary(.egress, of: pods, in: network, groupKey: key)
        var policies: [String] = []
        for id in ingress.restrictingPolicies + egress.restrictingPolicies
        where !policies.contains(policyName(id)) {
            policies.append(policyName(id))
        }
        return TraceNetwork(
            ingress: column(ingress, network: network, peers: peers),
            egress: column(egress, network: network, peers: peers),
            policies: policies)
    }

    static func column(
        _ summary: FlowSummary, network: NetworkInventory, peers: [String: TracePeer]
    ) -> TraceFlowColumn {
        guard summary.totalCount > 0 else { return TraceFlowColumn() }
        guard !summary.isUnrestricted else {
            return TraceFlowColumn(
                rows: [TraceFlowRow(
                    id: "unrestricted", subject: .unrestricted(count: nil), ports: nil,
                    policies: [])])
        }

        var column = TraceFlowColumn()
        if summary.unrestrictedCount > 0 {
            column.rows.append(TraceFlowRow(
                id: "unrestricted", subject: .unrestricted(count: summary.unrestrictedCount),
                ports: nil, policies: []))
        }
        guard !summary.grants.isEmpty else {
            column.rows.append(TraceFlowRow(
                id: "deny", subject: .denyAll, ports: nil,
                policies: summary.restrictingPolicies.map(policyName)))
            return column
        }

        var rows: [TraceFlowRow] = []
        func add(_ id: String, _ subject: TraceFlowRow.Subject, _ grant: FlowGrant) {
            let ports = grant.ports.isEmpty ? nil : grant.ports
            let policy = policyName(grant.policy)
            if let index = rows.firstIndex(where: { $0.id == id }) {
                if let existing = rows[index].ports, let ports {
                    rows[index].ports = existing + ports.filter { !existing.contains($0) }
                } else {
                    rows[index].ports = nil
                }
                if !rows[index].policies.contains(policy) { rows[index].policies.append(policy) }
            } else {
                rows.append(TraceFlowRow(id: id, subject: subject, ports: ports, policies: [policy]))
            }
        }

        for grant in summary.grants {
            switch grant.peer {
            case nil:
                add("anywhere", .anywhere, grant)
            case .ipBlock(let cidr, let except)?:
                add("ip|\(cidr)|\(except.joined(separator: ","))",
                    .ipBlock(cidr: cidr, except: except), grant)
            case .pods(let podSelector, _)?:
                for group in grant.groups {
                    guard let peer = peers[group.key] else { continue }
                    add(group.key, .workload(peer, group.outcome, podCount: group.pods.count), grant)
                }
                let pods = podSelector.map(selectorText).flatMap { $0.isEmpty ? nil : $0 }
                for name in grant.outOfScopeNamespaces {
                    add("ns|\(name)|\(pods ?? "")", .namespace(name, pods: pods), grant)
                }
                if grant.groups.isEmpty && grant.outOfScopeNamespaces.isEmpty
                    && grant.gaps.isEmpty, let peer = grant.peer,
                   let policy = network.policies.first(where: { $0.id == grant.policy }) {
                    add("unmatched|\(grant.id)",
                        .unmatched(describe(peer, policyNamespace: policy.namespace)), grant)
                }
            }
            for gap in grant.gaps {
                let text = note(for: gap)
                if !column.notes.contains(text) { column.notes.append(text) }
            }
        }

        column.rows += rows.sorted { order(of: $0) < order(of: $1) }
        return column
    }

    /// 止まっているものを先に。「なぜ繋がらないか」を探しに来た人が最初に見る。
    private static func order(of row: TraceFlowRow) -> (Int, String) {
        switch row.subject {
        case .unrestricted, .denyAll: return (0, row.id)
        case .workload(let peer, let outcome, _):
            let rank: Int
            switch outcome {
            case .blocked: rank = 1
            case .mixed: rank = 2
            case .undetermined: rank = 3
            case .allowed: rank = 4
            }
            return (rank, "\(peer.namespace ?? "")/\(peer.name)")
        case .namespace(let name, _): return (5, name)
        case .anywhere: return (6, row.id)
        case .ipBlock(let cidr, _): return (7, cidr)
        case .unmatched: return (8, row.id)
        }
    }

    private static func policyName(_ id: String) -> String {
        id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id
    }

    private static func note(for gap: FlowGap) -> String {
        switch gap {
        case .namespacesUnreadable:
            return String(localized: """
                Namespace の一覧を読めないため、namespaceSelector に当たる Namespace を\
                挙げきれていません。
                """)
        case .undeterminedNamespaces(let names):
            let joined = names.joined(separator: ", ")
            return String(localized: """
                \(joined) はラベルを読めないため、当たるかどうか決まりません。
                """)
        }
    }

    // MARK: - 相手の書き方

    static func describe(_ peer: NetworkPolicySpec.Peer, policyNamespace: String) -> String {
        switch peer {
        case .ipBlock(let cidr, let except):
            return except.isEmpty ? cidr : "\(cidr) − \(except.joined(separator: ", "))"
        case .pods(let podSelector, let namespaceSelector):
            let pods = podSelector.map(selectorText).flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "すべての Pod")
            guard let namespaceSelector else {
                return String(localized: "Namespace \(policyNamespace) の \(pods)")
            }
            let namespaces = namespaceSelector.isEmpty
                ? String(localized: "すべての Namespace")
                : String(localized: "Namespace \(selectorText(namespaceSelector))")
            return String(localized: "\(namespaces) の \(pods)")
        }
    }

    static func selectorText(_ selector: LabelSelector) -> String {
        let labels = selector.matchLabels.keys.sorted().map { "\($0)=\(selector.matchLabels[$0]!)" }
        let expressions = selector.requirements.map { requirement -> String in
            let values = requirement.values.joined(separator: ", ")
            switch requirement.op {
            case "In": return "\(requirement.key) in (\(values))"
            case "NotIn": return "\(requirement.key) notin (\(values))"
            case "Exists": return requirement.key
            case "DoesNotExist": return "!\(requirement.key)"
            default: return "\(requirement.key) \(requirement.op) (\(values))"
            }
        }
        return (labels + expressions).joined(separator: ", ")
    }

    /// `TCP 80` / `TCP 8000–8100` / `http`。空はすべてのポート。
    static func portsText(_ ports: [PolicyPort]?) -> String {
        guard let ports, !ports.isEmpty else { return String(localized: "すべてのポート") }
        return ports.map { port -> String in
            switch port.target {
            case .any: return port.proto
            case .number(let number):
                if let end = port.endPort, end != number { return "\(port.proto) \(number)–\(end)" }
                return "\(port.proto) \(number)"
            case .named(let name): return port.proto == "TCP" ? name : "\(port.proto) \(name)"
            }
        }
        .joined(separator: ", ")
    }
}
