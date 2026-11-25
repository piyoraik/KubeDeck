import Foundation

// 判断の理由は CLAUDE.md「NetworkPolicy は許可の宣言を解く」を参照。

// MARK: - ラベルセレクタ

/// `metav1.LabelSelector`。`matchExpressions` まで評価する。
struct LabelSelector: Sendable, Hashable {
    struct Requirement: Sendable, Hashable {
        let key: String
        let op: String
        let values: [String]
    }

    let matchLabels: [String: String]
    let requirements: [Requirement]

    init(matchLabels: [String: String] = [:], requirements: [Requirement] = []) {
        self.matchLabels = matchLabels
        self.requirements = requirements
    }

    init(_ value: JSONValue) {
        matchLabels = (value["matchLabels"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
        requirements = (value["matchExpressions"]?.arrayValue ?? []).compactMap { expression in
            guard let key = expression["key"]?.stringValue else { return nil }
            return Requirement(
                key: key, op: expression["operator"]?.stringValue ?? "",
                values: (expression["values"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
    }

    var isEmpty: Bool { matchLabels.isEmpty && requirements.isEmpty }

    /// nil は「決まらない」。`complete` が偽なら、`labels` に無いキーは無いのではなく分からない。
    func evaluate(_ labels: [String: String], complete: Bool = true) -> Bool? {
        var undetermined = false
        for (key, value) in matchLabels {
            if let actual = labels[key] {
                if actual != value { return false }
            } else if complete {
                return false
            } else {
                undetermined = true
            }
        }
        for requirement in requirements {
            let actual = labels[requirement.key]
            if actual == nil && !complete {
                undetermined = true
                continue
            }
            switch requirement.op {
            case "In":
                guard let actual, requirement.values.contains(actual) else { return false }
            case "NotIn":
                if let actual, requirement.values.contains(actual) { return false }
            case "Exists":
                if actual == nil { return false }
            case "DoesNotExist":
                if actual != nil { return false }
            default:
                undetermined = true
            }
        }
        return undetermined ? nil : true
    }

    /// `kubernetes.io/metadata.name` で名前を指していれば、その名前。
    var pinnedNamespaceNames: Set<String>? {
        let key = NetworkInventory.namespaceNameLabel
        if let name = matchLabels[key] { return [name] }
        if let requirement = requirements.first(where: { $0.key == key && $0.op == "In" }) {
            return Set(requirement.values)
        }
        return nil
    }
}

// MARK: - ポート

struct PortRange: Sendable, Hashable {
    let proto: String
    let lower: Int
    let upper: Int

    func overlap(_ other: PortRange) -> PortRange? {
        guard proto == other.proto else { return nil }
        let lower = max(self.lower, other.lower)
        let upper = min(self.upper, other.upper)
        return lower <= upper ? PortRange(proto: proto, lower: lower, upper: upper) : nil
    }
}

/// 通るポート。`.only([])` は何も通らない。
enum PortSet: Sendable, Hashable {
    case all
    case only([PortRange])

    static let none = PortSet.only([])

    var isEmpty: Bool {
        if case .only(let ranges) = self { return ranges.isEmpty }
        return false
    }

    func union(_ other: PortSet) -> PortSet {
        switch (self, other) {
        case (.all, _), (_, .all): return .all
        case (.only(let lhs), .only(let rhs)): return .only(Self.unique(lhs + rhs))
        }
    }

    func intersection(_ other: PortSet) -> PortSet {
        switch (self, other) {
        case (.all, let set), (let set, .all): return set
        case (.only(let lhs), .only(let rhs)):
            return .only(Self.unique(lhs.flatMap { left in rhs.compactMap { left.overlap($0) } }))
        }
    }

    private static func unique(_ ranges: [PortRange]) -> [PortRange] {
        var seen = Set<PortRange>()
        return ranges.filter { seen.insert($0).inserted }
    }
}

/// `NetworkPolicyPort`。
struct PolicyPort: Sendable, Hashable {
    enum Target: Sendable, Hashable {
        case any
        case number(Int)
        case named(String)
    }

    let proto: String
    let target: Target
    let endPort: Int?

    init(proto: String = "TCP", target: Target, endPort: Int? = nil) {
        self.proto = proto
        self.target = target
        self.endPort = endPort
    }

    init(_ value: JSONValue) {
        proto = value["protocol"]?.stringValue ?? "TCP"
        if let text = value["port"]?.stringValue {
            target = Int(text).map(Target.number) ?? .named(text)
        } else if let number = value["port"]?.intValue {
            target = .number(number)
        } else {
            target = .any
        }
        endPort = value["endPort"]?.intValue
    }

    /// 名前付きのポートは、宛先の Pod のコンテナで解く（無ければ何にも当たらない）。
    func ranges(on destination: K8sObject) -> [PortRange] {
        switch target {
        case .any:
            return [PortRange(proto: proto, lower: 1, upper: 65535)]
        case .number(let port):
            return [PortRange(proto: proto, lower: port, upper: max(port, endPort ?? port))]
        case .named(let name):
            return Self.containerPorts(of: destination)
                .filter { $0.name == name && $0.proto == proto }
                .map { PortRange(proto: proto, lower: $0.port, upper: $0.port) }
        }
    }

    private static func containerPorts(of pod: K8sObject) -> [(name: String, proto: String, port: Int)] {
        let containers = (pod.spec?["containers"]?.arrayValue ?? [])
            + (pod.spec?["initContainers"]?.arrayValue ?? [])
        return containers.flatMap { container in
            (container["ports"]?.arrayValue ?? []).compactMap { port in
                guard let name = port["name"]?.stringValue,
                      let number = port["containerPort"]?.intValue else { return nil }
                return (name, port["protocol"]?.stringValue ?? "TCP", number)
            }
        }
    }
}

// MARK: - NetworkPolicy

enum FlowDirection: Sendable, Hashable {
    case ingress
    case egress
}

/// NetworkPolicy の spec を、判定に使う形に読んだもの。
struct NetworkPolicySpec: Sendable, Identifiable {
    enum Peer: Sendable, Hashable {
        /// どちらも nil にはならない（API サーバの検証が弾く）。
        case pods(podSelector: LabelSelector?, namespaceSelector: LabelSelector?)
        case ipBlock(cidr: String, except: [String])
    }

    struct Rule: Sendable {
        /// 空は「相手を問わない」。
        let peers: [Peer]
        /// 空は「すべてのポート」。
        let ports: [PolicyPort]

        func portSet(on destination: K8sObject) -> PortSet {
            ports.isEmpty ? .all : .only(ports.flatMap { $0.ranges(on: destination) })
        }
    }

    let name: String
    let namespace: String
    let podSelector: LabelSelector
    let restrictsIngress: Bool
    let restrictsEgress: Bool
    let ingress: [Rule]
    let egress: [Rule]

    var id: String { "\(namespace)/\(name)" }

    init?(_ object: K8sObject) {
        guard object.kind == .networkPolicy, let namespace = object.namespace else { return nil }
        let spec = object.spec
        name = object.name
        self.namespace = namespace
        podSelector = spec?["podSelector"].map(LabelSelector.init) ?? LabelSelector()
        let types = Self.policyTypes(of: spec)
        restrictsIngress = types.contains("Ingress")
        restrictsEgress = types.contains("Egress")
        ingress = Self.rules(spec?["ingress"], peerKey: "from")
        egress = Self.rules(spec?["egress"], peerKey: "to")
    }

    func restricts(_ direction: FlowDirection) -> Bool {
        direction == .ingress ? restrictsIngress : restrictsEgress
    }

    func rules(_ direction: FlowDirection) -> [Rule] {
        direction == .ingress ? ingress : egress
    }

    /// 省略時は API サーバの既定値と同じに補う（Ingress は必ず、Egress は規則が 1 つ以上あるとき）。
    static func policyTypes(of spec: JSONValue?) -> [String] {
        let declared = (spec?["policyTypes"]?.arrayValue ?? []).compactMap(\.stringValue)
        guard declared.isEmpty else { return declared }
        let hasEgressRules = !(spec?["egress"]?.arrayValue ?? []).isEmpty
        return hasEgressRules ? ["Ingress", "Egress"] : ["Ingress"]
    }

    private static func rules(_ value: JSONValue?, peerKey: String) -> [Rule] {
        (value?.arrayValue ?? []).map { rule in
            Rule(
                peers: (rule[peerKey]?.arrayValue ?? []).compactMap(peer),
                ports: (rule["ports"]?.arrayValue ?? []).map(PolicyPort.init))
        }
    }

    private static func peer(_ value: JSONValue) -> Peer? {
        if let block = value["ipBlock"], let cidr = block["cidr"]?.stringValue {
            return .ipBlock(
                cidr: cidr, except: (block["except"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        let pods = value["podSelector"].map(LabelSelector.init)
        let namespaces = value["namespaceSelector"].map(LabelSelector.init)
        guard pods != nil || namespaces != nil else { return nil }
        return .pods(podSelector: pods, namespaceSelector: namespaces)
    }
}

// MARK: - 判定の結果

/// 片側（送る側の出口、または受ける側の入口）の判断。
enum SideVerdict: Sendable, Hashable {
    /// この向きを制限する policy に選ばれていない。
    case unrestricted
    /// `partial` は、決まらない規則も残っている（`ports` より多く通しているかもしれない）。
    case allowed(policies: [String], ports: PortSet, partial: Bool = false)
    /// 制限されていて、どの規則にも当たらない。
    case denied(policies: [String])
    /// ラベルが読めないなどで決まらない。
    case undetermined(policies: [String])

    var ports: PortSet? {
        switch self {
        case .unrestricted: return .all
        case .allowed(_, let ports, _): return ports
        case .denied, .undetermined: return nil
        }
    }

    var isPartial: Bool {
        if case .allowed(_, _, true) = self { return true }
        return false
    }
}

/// 止めているところ。
enum FlowBlocker: Sendable, Hashable, Comparable {
    /// 送る側の出口（Egress）。
    case egress
    /// 受ける側の入口（Ingress）。
    case ingress
    /// 両側とも許しているが、通すポートが重ならない。
    case ports
}

struct ConnectionVerdict: Sendable, Hashable {
    enum Outcome: Sendable, Hashable {
        case allowed(PortSet)
        case blocked([FlowBlocker])
        case undetermined
    }

    let outcome: Outcome
    let egress: SideVerdict
    let ingress: SideVerdict
}

// MARK: - 手元の材料

/// 判定に使うもの一式。`scope` は Pod と policy を取得した Namespace（nil は全 Namespace）。
struct NetworkInventory: Sendable {
    static let namespaceNameLabel = "kubernetes.io/metadata.name"

    let pods: [K8sObject]
    let policies: [NetworkPolicySpec]
    let scope: String?
    /// nil は Namespace を読めていない。
    let namespaceLabels: [String: [String: String]]?
    private let policiesByNamespace: [String: [NetworkPolicySpec]]

    init(
        pods: [K8sObject], policies: [K8sObject], scope: String?,
        namespaceLabels: [String: [String: String]]?
    ) {
        self.pods = pods
        self.policies = policies.compactMap(NetworkPolicySpec.init)
        self.scope = scope
        self.namespaceLabels = namespaceLabels
        policiesByNamespace = Dictionary(grouping: self.policies, by: \.namespace)
    }

    /// 読めていなくても、名前の自動ラベルだけは分かる。
    func labels(ofNamespace name: String) -> (labels: [String: String], complete: Bool) {
        guard let known = namespaceLabels?[name] else {
            return ([Self.namespaceNameLabel: name], false)
        }
        return (known.merging([Self.namespaceNameLabel: name]) { current, _ in current }, true)
    }

    func isInScope(_ namespace: String) -> Bool {
        scope.map { $0 == namespace } ?? true
    }

    func policies(in namespace: String?) -> [NetworkPolicySpec] {
        policiesByNamespace[namespace ?? ""] ?? []
    }
}

// MARK: - 判定

enum NetworkReachability {
    /// `source` から `destination` へ通るか。両側の policy が許して初めて通る。
    static func connection(
        from source: K8sObject, to destination: K8sObject, in inventory: NetworkInventory
    ) -> ConnectionVerdict {
        let egress = side(
            .egress, subject: source, peer: destination, destination: destination, in: inventory)
        let ingress = side(
            .ingress, subject: destination, peer: source, destination: destination, in: inventory)

        var blockers: [FlowBlocker] = []
        if case .denied = egress { blockers.append(.egress) }
        if case .denied = ingress { blockers.append(.ingress) }
        guard blockers.isEmpty else {
            return ConnectionVerdict(outcome: .blocked(blockers), egress: egress, ingress: ingress)
        }
        guard let outbound = egress.ports, let inbound = ingress.ports else {
            return ConnectionVerdict(outcome: .undetermined, egress: egress, ingress: ingress)
        }
        let ports = outbound.intersection(inbound)
        // 決まらない規則が残っている側があれば、重ならないとは言えない。
        if ports.isEmpty, egress.isPartial || ingress.isPartial {
            return ConnectionVerdict(outcome: .undetermined, egress: egress, ingress: ingress)
        }
        return ConnectionVerdict(
            outcome: ports.isEmpty ? .blocked([.ports]) : .allowed(ports),
            egress: egress, ingress: ingress)
    }

    /// `subject` に効く `direction` 向きの policy が、`peer` との通信を許すか。
    static func side(
        _ direction: FlowDirection, subject: K8sObject, peer: K8sObject,
        destination: K8sObject, in inventory: NetworkInventory
    ) -> SideVerdict {
        var restricting: [String] = []
        var granting: [String] = []
        var ports = PortSet.none
        var undetermined = false

        for policy in inventory.policies(in: subject.namespace) where policy.restricts(direction) {
            switch policy.podSelector.evaluate(subject.labels) {
            case false?: continue
            case nil:
                undetermined = true
                continue
            case true?:
                restricting.append(policy.id)
            }
            for rule in policy.rules(direction) {
                let hit = rule.peers.isEmpty
                    ? true
                    : anyOf(rule.peers.map {
                        matches($0, pod: peer, policyNamespace: policy.namespace, in: inventory)
                    })
                guard hit != false else { continue }
                let rulePorts = rule.portSet(on: destination)
                guard !rulePorts.isEmpty else { continue }
                if hit == true {
                    ports = ports.union(rulePorts)
                    if !granting.contains(policy.id) { granting.append(policy.id) }
                } else {
                    undetermined = true
                }
            }
        }

        if restricting.isEmpty {
            return undetermined ? .undetermined(policies: []) : .unrestricted
        }
        if !ports.isEmpty {
            return .allowed(policies: granting, ports: ports, partial: undetermined)
        }
        return undetermined ? .undetermined(policies: restricting) : .denied(policies: restricting)
    }

    private static func addresses(of pod: K8sObject) -> [String] {
        var result = (pod.status?["podIPs"]?.arrayValue ?? []).compactMap { $0["ip"]?.stringValue }
        if let ip = pod.status?["podIP"]?.stringValue, !result.contains(ip) { result.insert(ip, at: 0) }
        return result
    }

    /// 規則の相手 1 つが、この Pod に当たるか。
    static func matches(
        _ peer: NetworkPolicySpec.Peer, pod: K8sObject, policyNamespace: String,
        in inventory: NetworkInventory
    ) -> Bool? {
        switch peer {
        case .ipBlock(let cidr, let except):
            // Pod の IP に ipBlock を当てるかは CNI 次第なので、範囲に入るなら決めない。
            // dual-stack の `podIP` は片方の系だけなので `podIPs` も見る。読めない cidr でも決めない。
            var unreadable = false
            for ip in addresses(of: pod) {
                switch CIDR.contains(cidr, ip) {
                case true?:
                    if !except.contains(where: { CIDR.contains($0, ip) == true }) { return nil }
                case nil: unreadable = true
                case false?: continue
                }
            }
            return unreadable ? nil : false
        case .pods(let podSelector, let namespaceSelector):
            let namespace = pod.namespace ?? ""
            let namespaceHit: Bool?
            if let namespaceSelector {
                let known = inventory.labels(ofNamespace: namespace)
                namespaceHit = namespaceSelector.evaluate(known.labels, complete: known.complete)
            } else {
                namespaceHit = namespace == policyNamespace
            }
            let podHit = podSelector?.evaluate(pod.labels) ?? true
            return allOf([namespaceHit, podHit])
        }
    }

    private static func anyOf(_ values: [Bool?]) -> Bool? {
        if values.contains(true) { return true }
        return values.contains(nil) ? nil : false
    }

    private static func allOf(_ values: [Bool?]) -> Bool? {
        if values.contains(false) { return false }
        return values.contains(nil) ? nil : true
    }
}

// MARK: - 起点から見た通信（たどるの「通信」の段）

/// 当たった相手のまとまり（ふつうはワークロード）。
struct FlowPeerGroup: Identifiable, Sendable {
    enum Outcome: Sendable, Hashable {
        case allowed
        case blocked([FlowBlocker])
        /// Pod の組み合わせで結果が割れている。
        case mixed
        case undetermined
    }

    let key: String
    let pods: [K8sObject]
    let outcome: Outcome

    var id: String { key }
}

/// 当たる先を数え切れない理由。
enum FlowGap: Sendable, Hashable {
    /// Namespace の一覧が読めず、namespaceSelector に当たる先を挙げきれない。
    case namespacesUnreadable
    /// ラベルが読めず、当たるかどうか決まらない Namespace。
    case undeterminedNamespaces([String])
}

/// 1 つの規則の、1 つの相手。
struct FlowGrant: Identifiable, Sendable {
    let policy: String
    let ruleIndex: Int
    /// nil は規則に相手の指定が無い（どこからでも／どこへでも）。
    let peer: NetworkPolicySpec.Peer?
    let peerIndex: Int
    let ports: [PolicyPort]
    /// 手元の Pod で当たったもの。
    let groups: [FlowPeerGroup]
    /// 当たるが、中の Pod を取得していない Namespace。相手側の policy は分からない。
    let outOfScopeNamespaces: [String]
    let gaps: [FlowGap]

    var id: String { "\(policy)#\(ruleIndex).\(peerIndex)" }
}

struct FlowSummary: Sendable {
    let direction: FlowDirection
    /// 起点の Pod のどれかを、この向きで制限している policy。
    let restrictingPolicies: [String]
    /// 制限されていない起点の Pod の数。
    let unrestrictedCount: Int
    let totalCount: Int
    let grants: [FlowGrant]

    var isUnrestricted: Bool { restrictingPolicies.isEmpty }
}

extension NetworkReachability {
    /// 起点の Pod に入ってこられる相手（ingress）、または出ていける先（egress）。
    static func summary(
        _ direction: FlowDirection, of targets: [K8sObject], in inventory: NetworkInventory,
        groupKey: (K8sObject) -> String = { "\($0.namespace ?? "")/\($0.name)" }
    ) -> FlowSummary {
        var restricting: [String] = []
        var restrictedTargets = Set<String>()
        var grants: [FlowGrant] = []

        let namespaces = Set(targets.compactMap(\.namespace)).sorted()
        for policy in namespaces.flatMap({ inventory.policies(in: $0) })
        where policy.restricts(direction) {
            let selected = targets.filter {
                $0.namespace == policy.namespace && policy.podSelector.evaluate($0.labels) != false
            }
            guard !selected.isEmpty else { continue }
            restricting.append(policy.id)
            restrictedTargets.formUnion(selected.map(\.id))

            for (ruleIndex, rule) in policy.rules(direction).enumerated() {
                guard !rule.peers.isEmpty else {
                    grants.append(FlowGrant(
                        policy: policy.id, ruleIndex: ruleIndex, peer: nil, peerIndex: 0,
                        ports: rule.ports, groups: [], outOfScopeNamespaces: [], gaps: []))
                    continue
                }
                for (peerIndex, peer) in rule.peers.enumerated() {
                    grants.append(grant(
                        direction, policy: policy, ruleIndex: ruleIndex, rule: rule,
                        peer: peer, peerIndex: peerIndex, targets: selected,
                        inventory: inventory, groupKey: groupKey))
                }
            }
        }

        return FlowSummary(
            direction: direction, restrictingPolicies: restricting,
            unrestrictedCount: targets.count - restrictedTargets.count,
            totalCount: targets.count, grants: grants)
    }

    private static func grant(
        _ direction: FlowDirection, policy: NetworkPolicySpec, ruleIndex: Int,
        rule: NetworkPolicySpec.Rule, peer: NetworkPolicySpec.Peer, peerIndex: Int,
        targets: [K8sObject], inventory: NetworkInventory, groupKey: (K8sObject) -> String
    ) -> FlowGrant {
        guard case .pods(_, let namespaceSelector) = peer else {
            return FlowGrant(
                policy: policy.id, ruleIndex: ruleIndex, peer: peer, peerIndex: peerIndex,
                ports: rule.ports, groups: [], outOfScopeNamespaces: [], gaps: [])
        }

        let matched = inventory.pods.filter {
            matches(peer, pod: $0, policyNamespace: policy.namespace, in: inventory) == true
        }
        let groups = Dictionary(grouping: matched, by: groupKey)
            .compactMap { key, pods in
                groupOutcome(direction, peers: pods, targets: targets, inventory: inventory)
                    .map { FlowPeerGroup(key: key, pods: pods, outcome: $0) }
            }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }

        var outOfScope: [String] = []
        var gaps: [FlowGap] = []
        if let namespaceSelector {
            let pinned = namespaceSelector.pinnedNamespaceNames
            if inventory.namespaceLabels == nil && pinned == nil {
                gaps.append(.namespacesUnreadable)
            }
            var candidates = Set(inventory.pods.compactMap(\.namespace))
            if let labels = inventory.namespaceLabels { candidates.formUnion(labels.keys) }
            if let pinned { candidates.formUnion(pinned) }

            var undetermined: [String] = []
            for name in candidates.sorted() {
                let known = inventory.labels(ofNamespace: name)
                switch namespaceSelector.evaluate(known.labels, complete: known.complete) {
                case true?: if !inventory.isInScope(name) { outOfScope.append(name) }
                case nil: undetermined.append(name)
                case false?: break
                }
            }
            if !undetermined.isEmpty { gaps.append(.undeterminedNamespaces(undetermined)) }
        }

        return FlowGrant(
            policy: policy.id, ruleIndex: ruleIndex, peer: peer, peerIndex: peerIndex,
            ports: rule.ports, groups: groups, outOfScopeNamespaces: outOfScope, gaps: gaps)
    }

    /// 相手のまとまりと起点の Pod の、すべての組み合わせ。自分自身との組は数えない（nil は組が無い）。
    private static func groupOutcome(
        _ direction: FlowDirection, peers: [K8sObject], targets: [K8sObject],
        inventory: NetworkInventory
    ) -> FlowPeerGroup.Outcome? {
        var outcomes: [ConnectionVerdict.Outcome] = []
        for peer in peers {
            for target in targets where target.id != peer.id {
                let verdict = direction == .ingress
                    ? connection(from: peer, to: target, in: inventory)
                    : connection(from: target, to: peer, in: inventory)
                outcomes.append(verdict.outcome)
            }
        }
        guard !outcomes.isEmpty else { return nil }

        var allowed = 0
        var blocked = 0
        var blockers = Set<FlowBlocker>()
        for outcome in outcomes {
            switch outcome {
            case .allowed: allowed += 1
            case .undetermined: break
            case .blocked(let reasons):
                blocked += 1
                blockers.formUnion(reasons)
            }
        }
        if allowed == outcomes.count { return .allowed }
        if blocked == outcomes.count { return .blocked(blockers.sorted()) }
        // 「通るものと止まるものがある」は、両方が実際にあるときだけ。
        return allowed > 0 && blocked > 0 ? .mixed : .undetermined
    }
}

// MARK: - CIDR

enum CIDR {
    /// nil は書式が読めない。
    static func contains(_ cidr: String, _ address: String) -> Bool? {
        let parts = cidr.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let network = bytes(first),
              let host = bytes(address) else { return nil }
        // 系が違えば（IPv6 の範囲に IPv4 のアドレス）、範囲には入らない。
        guard network.count == host.count else { return false }
        let prefix = parts.count == 2 ? Int(parts[1]) : network.count * 8
        guard let prefix, (0...network.count * 8).contains(prefix) else { return nil }

        for bit in 0..<prefix {
            let index = bit / 8
            let mask = UInt8(0x80) >> UInt8(bit % 8)
            if network[index] & mask != host[index] & mask { return false }
        }
        return true
    }

    private static func bytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
