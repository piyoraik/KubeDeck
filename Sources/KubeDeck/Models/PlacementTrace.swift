import Foundation

/// 配置画面が 1 回の kubectl で取ってくるもの。
///
/// **別々に投げない。** 片方だけ新しい状態が混ざると、同じ時点の絵にならない。
struct PlacementInventory: Sendable {
    var pods: [K8sObject] = []
    var nodes: [K8sObject] = []
    /// ReplicaSet / Job。Pod の直接の所有者＝世代。
    var generations: [K8sObject] = []
    /// Deployment / StatefulSet / DaemonSet / CronJob。
    /// **Pod から名前を起こすだけでは足りない。** レプリカ 0 のワークロードは
    /// Pod が 1 つも無く、Pod 側からは存在すら見えない。
    var workloads: [K8sObject] = []
    /// Service / Ingress / PVC。
    var related: [K8sObject] = []
}

/// たどるの起点にできる種別。
///
/// **どれも「同じ鎖の別の場所」。** 図の流れは
/// 入口 → ワークロード → 世代 → Pod → ノード で固定してあり、起点が変わるのは
/// 鎖のどこを掴むかだけ。掴んだところから Pod を解いて、あとは同じ図に流す。
enum TraceAnchorKind: String, CaseIterable, Identifiable, Sendable {
    case workload
    case generation
    case service
    case ingress
    case node

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workload: return "ワークロード"
        case .generation: return "ReplicaSet / Job"
        case .service: return "Service"
        case .ingress: return "Ingress"
        case .node: return "ノード"
        }
    }

    var symbol: String {
        switch self {
        case .workload: return ResourceKind.deployment.symbol
        case .generation: return ResourceKind.replicaSet.symbol
        case .service: return ResourceKind.service.symbol
        case .ingress: return ResourceKind.ingress.symbol
        case .node: return ResourceKind.node.symbol
        }
    }

    /// 何が分かる起点なのか。一覧の上に添える。
    var help: String {
        switch self {
        case .workload: return "このワークロードがどこへ散っているか"
        case .generation: return "この世代の Pod がどこに居るか"
        case .service: return "この Service が掴んでいるのは何か"
        case .ingress: return "この入口の先に何があるか"
        case .node: return "このノードに載っているものは何に繋がっているか"
        }
    }

    /// 1 件も無いときの言い方。**「取れていない」と混ぜない** ので、
    /// ここは「このクラスタには無い」と言い切れる場合の文言。
    var emptyMessage: String {
        switch self {
        case .workload: return "ワークロードがありません。"
        case .generation: return "ReplicaSet も Job もありません。"
        case .service: return "Service がありません。"
        case .ingress: return "Ingress がありません。"
        case .node: return "ノードがありません。"
        }
    }
}

/// たどるの起点 1 つ。
///
/// **オブジェクトそのものを持たない。** 起点は選択の状態として持ち回るもので、
/// 自動更新のたびに中身が入れ替わる `K8sObject` を抱えると、同じものを選んで
/// いるのに別物として扱われる。名前で持ち、必要なときに引き直す。
struct TraceAnchor: Identifiable, Hashable, Sendable {
    let anchorKind: TraceAnchorKind
    /// 図の器に使う種別。所有者が CRD のワークロードでは nil。
    let resourceKind: ResourceKind?
    /// 表示に使う種別名。`Rollout` のような CRD もそのまま出す。
    let kindLabel: String
    let namespace: String?
    let name: String
    /// 所有者の無い Pod をまとめた枠。実在するオブジェクトではない。
    var isStandalone: Bool = false
    /// 一覧の行に出す Pod の数。
    var podCount: Int = 0

    var id: String {
        "\(anchorKind.rawValue)|\(namespace ?? "-")|\(kindLabel)|\(name)"
    }

    var displayName: String { isStandalone ? "単体の Pod" : name }

    var symbol: String {
        if isStandalone { return ResourceKind.pod.symbol }
        return resourceKind?.symbol ?? anchorKind.symbol
    }

    static func == (lhs: TraceAnchor, rhs: TraceAnchor) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// 世代（ReplicaSet / Job）1 つと、そこから出ている Pod。
struct TraceGeneration: Identifiable, Sendable {
    let namespace: String?
    let kind: ResourceKind?
    let kindLabel: String
    let name: String
    let pods: [K8sObject]
    /// ワークロード自身が直接の所有者のとき（DaemonSet / StatefulSet）。
    /// **囲みを二重に描かない** ための印で、この場合は世代という段が無い。
    let isImplicit: Bool

    var id: String { "\(namespace ?? "-")/\(kindLabel)/\(name)" }

    var anchor: TraceAnchor? {
        guard !isImplicit, kind == .replicaSet || kind == .job else { return nil }
        return TraceAnchor(
            anchorKind: .generation, resourceKind: kind, kindLabel: kindLabel,
            namespace: namespace, name: name, podCount: pods.count)
    }
}

/// ワークロード 1 つぶんの枝。入口からノードまでの 1 本。
struct TraceBranch: Identifiable, Sendable {
    let workload: TraceAnchor
    let ingresses: [K8sObject]
    let services: [K8sObject]
    let generations: [TraceGeneration]

    var id: String { workload.id }
    var namespace: String? { workload.namespace }
    var podCount: Int { generations.reduce(0) { $0 + $1.pods.count } }
    var pods: [K8sObject] { generations.flatMap(\.pods) }
}

/// 起点から解いた図ぜんぶ。
struct TraceGraph: Sendable {
    let anchor: TraceAnchor
    let branches: [TraceBranch]
    /// 起点から辿れたが Pod に届かなかった Service。
    /// **黙って落とさない** — 「先に何も無い」と「掴んでいる Pod が無い」は別。
    let danglingServices: [K8sObject]
    /// Ingress が指しているのに実在しない Service の名前。
    let missingServiceNames: [String]
    let claims: [K8sObject]

    var pods: [K8sObject] { branches.flatMap(\.pods) }
    var podCount: Int { branches.reduce(0) { $0 + $1.podCount } }
    var nodeCount: Int {
        Set(pods.compactMap { PlacementTrace.nodeName(of: $0) }).count
    }
    var isEmpty: Bool { branches.isEmpty }
}

/// 起点を選び、そこから図を解く。
///
/// **画面から計算を追い出す。** 起点が 5 種類あるので、どこから解いても
/// 同じ形（枝の並び）に落としてから描く。描く側に分岐を持たせると、
/// 起点を 1 つ足すたびに view が枝分かれする。
enum PlacementTrace {
    // MARK: - 起点の一覧

    static func anchors(
        kind: TraceAnchorKind, inventory: PlacementInventory,
        controllers index: [String: K8sObject]
    ) -> [TraceAnchor] {
        switch kind {
        case .workload: return workloadAnchors(inventory: inventory, controllers: index)
        case .generation: return generationAnchors(inventory: inventory)
        case .service: return serviceAnchors(inventory: inventory)
        case .ingress: return ingressAnchors(inventory: inventory)
        case .node: return nodeAnchors(inventory: inventory)
        }
    }

    /// **Pod から起こした名前と、実在するワークロードを合わせる。**
    /// 片方だけだと、レプリカ 0 のものが消える（実在するのに見えない）か、
    /// CRD が所有者の Pod が消える（Deployment ではないので一覧に無い）。
    private static func workloadAnchors(
        inventory: PlacementInventory, controllers index: [String: K8sObject]
    ) -> [TraceAnchor] {
        var podsByKey: [String: [K8sObject]] = [:]
        var identityByKey: [String: TraceAnchor] = [:]

        for pod in inventory.pods {
            let anchor = workloadAnchor(of: pod, controllers: index)
            podsByKey[anchor.id, default: []].append(pod)
            identityByKey[anchor.id] = anchor
        }

        var result: [TraceAnchor] = []
        for workload in inventory.workloads {
            guard let kind = workload.kind else { continue }
            var anchor = TraceAnchor(
                anchorKind: .workload, resourceKind: kind, kindLabel: kind.apiKind,
                namespace: workload.namespace, name: workload.name)
            anchor.podCount = podsByKey.removeValue(forKey: anchor.id)?.count ?? 0
            identityByKey.removeValue(forKey: anchor.id)
            result.append(anchor)
        }
        // 実在するワークロードに紐づかなかったもの（CRD が所有者、単体の Pod）。
        for (key, pods) in podsByKey {
            guard var anchor = identityByKey[key] else { continue }
            anchor.podCount = pods.count
            result.append(anchor)
        }
        return sortedByCount(result)
    }

    private static func generationAnchors(inventory: PlacementInventory) -> [TraceAnchor] {
        var counts: [String: Int] = [:]
        for pod in inventory.pods {
            guard let reference = controllerReference(of: pod) else { continue }
            counts["\(pod.namespace ?? "-")/\(reference.kind)/\(reference.name)", default: 0] += 1
        }
        return inventory.generations.compactMap { object -> TraceAnchor? in
            guard let kind = object.kind else { return nil }
            let key = "\(object.namespace ?? "-")/\(kind.apiKind)/\(object.name)"
            return TraceAnchor(
                anchorKind: .generation, resourceKind: kind, kindLabel: kind.apiKind,
                namespace: object.namespace, name: object.name,
                podCount: counts[key] ?? 0)
        }
        // 世代は名前順。同じワークロードの世代が並ぶので、数の多い順にすると
        // 新旧が入り混じって「どれが今の世代か」が読み取れない。
        .sorted { lhs, rhs in
            lhs.name == rhs.name
                ? (lhs.namespace ?? "") < (rhs.namespace ?? "") : lhs.name < rhs.name
        }
    }

    private static func serviceAnchors(inventory: PlacementInventory) -> [TraceAnchor] {
        inventory.related
            .filter { $0.kind == .service }
            .map { service in
                TraceAnchor(
                    anchorKind: .service, resourceKind: .service,
                    kindLabel: ResourceKind.service.apiKind,
                    namespace: service.namespace, name: service.name,
                    podCount: WorkloadRelations
                        .pods(selectedBy: service, among: inventory.pods).count)
            }
            .sorted(by: byName)
    }

    private static func ingressAnchors(inventory: PlacementInventory) -> [TraceAnchor] {
        inventory.related
            .filter { $0.kind == .ingress }
            .map { ingress in
                let services = WorkloadRelations
                    .services(of: ingress, among: inventory.related).found
                let pods = services.flatMap {
                    WorkloadRelations.pods(selectedBy: $0, among: inventory.pods)
                }
                return TraceAnchor(
                    anchorKind: .ingress, resourceKind: .ingress,
                    kindLabel: ResourceKind.ingress.apiKind,
                    namespace: ingress.namespace, name: ingress.name,
                    podCount: Set(pods.map(\.id)).count)
            }
            .sorted(by: byName)
    }

    private static func nodeAnchors(inventory: PlacementInventory) -> [TraceAnchor] {
        var counts: [String: Int] = [:]
        for pod in inventory.pods {
            guard let node = nodeName(of: pod) else { continue }
            counts[node, default: 0] += 1
        }
        return inventory.nodes
            .map { node in
                TraceAnchor(
                    anchorKind: .node, resourceKind: .node,
                    kindLabel: ResourceKind.node.apiKind, namespace: nil,
                    name: node.name, podCount: counts[node.name] ?? 0)
            }
            .sorted(by: byName)
    }

    private static func byName(_ lhs: TraceAnchor, _ rhs: TraceAnchor) -> Bool {
        lhs.name == rhs.name
            ? (lhs.namespace ?? "") < (rhs.namespace ?? "") : lhs.name < rhs.name
    }

    /// 数の多い順。**探しているのはたいてい大きいもの。** 同数なら名前順に
    /// して、更新のたびに並びが揺れないようにする。
    private static func sortedByCount(_ anchors: [TraceAnchor]) -> [TraceAnchor] {
        anchors.sorted { lhs, rhs in
            lhs.podCount == rhs.podCount ? byName(lhs, rhs) : lhs.podCount > rhs.podCount
        }
    }

    // MARK: - 起点から図を解く

    static func graph(
        for anchor: TraceAnchor, inventory: PlacementInventory,
        controllers index: [String: K8sObject]
    ) -> TraceGraph {
        let pods = self.pods(for: anchor, inventory: inventory, controllers: index)

        var branches = self.branches(
            for: anchor, pods: pods, inventory: inventory, controllers: index)
        // レプリカ 0 のワークロードや、Pod がまだ出ていない世代でも枝を出す。
        // 出さないと「取れていない」のか「0 なのか」が区別できない。
        if branches.isEmpty, let empty = emptyBranch(
            for: anchor, inventory: inventory, controllers: index) {
            branches = [empty]
        }
        branches.sort { lhs, rhs in
            lhs.podCount == rhs.podCount
                ? lhs.workload.id < rhs.workload.id : lhs.podCount > rhs.podCount
        }

        var dangling: [K8sObject] = []
        var missing: [String] = []
        switch anchor.anchorKind {
        case .ingress:
            if let ingress = object(for: anchor, in: inventory) {
                let resolved = WorkloadRelations.services(of: ingress, among: inventory.related)
                missing = resolved.missing
                dangling = resolved.found.filter {
                    WorkloadRelations.pods(selectedBy: $0, among: inventory.pods).isEmpty
                }
            }
        case .service:
            if pods.isEmpty, let service = object(for: anchor, in: inventory) {
                dangling = [service]
            }
        default:
            break
        }

        return TraceGraph(
            anchor: anchor, branches: branches, danglingServices: dangling,
            missingServiceNames: missing,
            claims: WorkloadRelations.claims(for: pods, among: inventory.related))
    }

    /// 起点が掴んでいる Pod。ここだけが起点ごとに違う。
    private static func pods(
        for anchor: TraceAnchor, inventory: PlacementInventory,
        controllers index: [String: K8sObject]
    ) -> [K8sObject] {
        switch anchor.anchorKind {
        case .workload:
            return inventory.pods.filter {
                workloadAnchor(of: $0, controllers: index).id == anchor.id
            }
        case .generation:
            return inventory.pods.filter { pod in
                guard pod.namespace == anchor.namespace,
                      let reference = controllerReference(of: pod) else { return false }
                return reference.kind == anchor.kindLabel && reference.name == anchor.name
            }
        case .service:
            guard let service = object(for: anchor, in: inventory) else { return [] }
            return WorkloadRelations.pods(selectedBy: service, among: inventory.pods)
        case .ingress:
            guard let ingress = object(for: anchor, in: inventory) else { return [] }
            let services = WorkloadRelations.services(of: ingress, among: inventory.related).found
            var seen = Set<String>()
            var result: [K8sObject] = []
            for service in services {
                for pod in WorkloadRelations.pods(selectedBy: service, among: inventory.pods)
                where seen.insert(pod.id).inserted {
                    result.append(pod)
                }
            }
            return result
        case .node:
            return inventory.pods.filter { nodeName(of: $0) == anchor.name }
        }
    }

    private static func branches(
        for anchor: TraceAnchor, pods: [K8sObject], inventory: PlacementInventory,
        controllers index: [String: K8sObject]
    ) -> [TraceBranch] {
        var podsByWorkload: [String: [K8sObject]] = [:]
        var workloadByKey: [String: TraceAnchor] = [:]
        for pod in pods {
            let workload = workloadAnchor(of: pod, controllers: index)
            podsByWorkload[workload.id, default: []].append(pod)
            workloadByKey[workload.id] = workload
        }

        return podsByWorkload.compactMap { key, pods in
            guard var workload = workloadByKey[key] else { return nil }
            workload.podCount = pods.count
            // **世代は起点で絞る。** ノードや Service から辿ったときに、
            // ここに載っていない Pod まで足すと「起点の先」ではなくなる。
            let addsEmptyGenerations = anchor.anchorKind == .workload
            return branch(
                workload: workload, pods: pods, inventory: inventory,
                addsEmptyGenerations: addsEmptyGenerations)
        }
    }

    /// Pod が 1 つも無い起点のための枝。
    private static func emptyBranch(
        for anchor: TraceAnchor, inventory: PlacementInventory,
        controllers index: [String: K8sObject]
    ) -> TraceBranch? {
        switch anchor.anchorKind {
        case .workload:
            return branch(
                workload: anchor, pods: [], inventory: inventory, addsEmptyGenerations: true)
        case .generation:
            // 世代そのものを起点にしたときは、親のワークロードを枠にする。
            guard let object = object(for: anchor, in: inventory) else { return nil }
            let parent = parentAnchor(of: object) ?? anchor
            return TraceBranch(
                workload: parent,
                ingresses: [], services: [],
                generations: [
                    TraceGeneration(
                        namespace: anchor.namespace, kind: anchor.resourceKind,
                        kindLabel: anchor.kindLabel, name: anchor.name, pods: [],
                        isImplicit: false)
                ])
        default:
            return nil
        }
    }

    private static func branch(
        workload: TraceAnchor, pods: [K8sObject], inventory: PlacementInventory,
        addsEmptyGenerations: Bool
    ) -> TraceBranch {
        var podsByGeneration: [String: [K8sObject]] = [:]
        var metaByKey: [String: TraceGeneration] = [:]
        var order: [String] = []

        for pod in pods {
            let reference = controllerReference(of: pod)
            let kindLabel = reference?.kind ?? ""
            let name = reference?.name ?? pod.name
            let isImplicit = reference == nil
                || (kindLabel == workload.kindLabel && name == workload.name)
            let key = isImplicit ? "-" : "\(kindLabel)/\(name)"
            if podsByGeneration[key] == nil {
                order.append(key)
                metaByKey[key] = TraceGeneration(
                    namespace: pod.namespace,
                    kind: isImplicit ? nil : ResourceKind(apiKind: kindLabel),
                    kindLabel: isImplicit ? "" : kindLabel,
                    name: isImplicit ? "" : name, pods: [], isImplicit: isImplicit)
            }
            podsByGeneration[key, default: []].append(pod)
        }

        // **Pod が 0 の世代も出す。** 入れ替わりの途中や、古い世代が残って
        // いることが分かる。ここでは世代が見たいので、名前はハッシュ付きのまま。
        if addsEmptyGenerations {
            for object in inventory.generations {
                guard object.namespace == workload.namespace,
                      let kind = object.kind,
                      let parent = controllerReference(of: object),
                      parent.kind == workload.kindLabel, parent.name == workload.name
                else { continue }
                let key = "\(kind.apiKind)/\(object.name)"
                guard podsByGeneration[key] == nil else { continue }
                order.append(key)
                podsByGeneration[key] = []
                metaByKey[key] = TraceGeneration(
                    namespace: object.namespace, kind: kind, kindLabel: kind.apiKind,
                    name: object.name, pods: [], isImplicit: false)
            }
        }

        var generations: [TraceGeneration] = []
        for key in order {
            guard let meta = metaByKey[key] else { continue }
            generations.append(
                TraceGeneration(
                    namespace: meta.namespace, kind: meta.kind, kindLabel: meta.kindLabel,
                    name: meta.name, pods: podsByGeneration[key] ?? [],
                    isImplicit: meta.isImplicit))
        }
        generations.sort { lhs, rhs in
            lhs.pods.count == rhs.pods.count
                ? lhs.name < rhs.name : lhs.pods.count > rhs.pods.count
        }

        // 入口は Pod のラベルから解く。Pod が 1 つも無いときだけ、
        // ワークロードのテンプレートのラベルで代わりに引く（レプリカ 0 でも
        // Service は付いたままで、**入口が消えるほうが誤解を生む**）。
        var services = WorkloadRelations.services(for: pods, among: inventory.related)
        if services.isEmpty, pods.isEmpty,
           let object = inventory.workloads.first(where: {
               $0.namespace == workload.namespace && $0.name == workload.name
                   && $0.kind?.apiKind == workload.kindLabel
           }),
           let labels = object.spec?.path("template.metadata.labels")?.stringDictionary {
            services = WorkloadRelations.services(
                matching: labels, namespace: workload.namespace, among: inventory.related)
        }
        let ingresses = WorkloadRelations.ingresses(for: services, among: inventory.related)

        return TraceBranch(
            workload: workload, ingresses: ingresses, services: services,
            generations: generations)
    }

    // MARK: - 所有者とノード

    static func nodeName(of pod: K8sObject) -> String? {
        guard let name = pod.spec?["nodeName"]?.stringValue, !name.isEmpty else { return nil }
        return name
    }

    /// 支配している所有者。`controller: true` のものを採る。
    /// 無ければ先頭（`ownerReferences` は複数持てるが、支配者は 1 つだけ）。
    static func controllerReference(of object: K8sObject) -> (kind: String, name: String)? {
        let references = object.raw.path("metadata.ownerReferences")?.arrayValue ?? []
        let controller = references.first { $0["controller"]?.boolValue == true }
            ?? references.first
        guard let controller,
              let kind = controller["kind"]?.stringValue,
              let name = controller["name"]?.stringValue
        else { return nil }
        return (kind, name)
    }

    /// Pod の持ち主のワークロード。
    ///
    /// **ReplicaSet と Job で止めない。** ReplicaSet 名は
    /// `<Deployment 名>-<ハッシュ>` で、更新のたびに別のまとまりに見える。
    /// Job も CronJob から作られたものは実行のたびに名前が変わる。
    static func workloadOwner(
        of pod: K8sObject, controllers index: [String: K8sObject]
    ) -> (kind: String, name: String)? {
        guard let reference = controllerReference(of: pod) else { return nil }
        if reference.kind == "ReplicaSet" || reference.kind == "Job" {
            let key = "\(pod.namespace ?? "")/\(reference.kind)/\(reference.name)"
            if let parent = index[key], let grandparent = controllerReference(of: parent) {
                return grandparent
            }
        }
        return reference
    }

    static func workloadAnchor(
        of pod: K8sObject, controllers index: [String: K8sObject]
    ) -> TraceAnchor {
        guard let owner = workloadOwner(of: pod, controllers: index) else {
            return TraceAnchor(
                anchorKind: .workload, resourceKind: .pod, kindLabel: "Pod",
                namespace: pod.namespace, name: "", isStandalone: true)
        }
        return TraceAnchor(
            anchorKind: .workload, resourceKind: ResourceKind(apiKind: owner.kind),
            kindLabel: owner.kind, namespace: pod.namespace, name: owner.name)
    }

    private static func parentAnchor(of object: K8sObject) -> TraceAnchor? {
        guard let parent = controllerReference(of: object) else { return nil }
        return TraceAnchor(
            anchorKind: .workload, resourceKind: ResourceKind(apiKind: parent.kind),
            kindLabel: parent.kind, namespace: object.namespace, name: parent.name)
    }

    /// 起点に対応する実物。**起点は名前で持ち回る**ので、使うときに引き直す。
    static func object(for anchor: TraceAnchor, in inventory: PlacementInventory) -> K8sObject? {
        let pool: [K8sObject]
        switch anchor.anchorKind {
        case .node: pool = inventory.nodes
        case .generation: pool = inventory.generations
        case .service, .ingress: pool = inventory.related
        case .workload: pool = inventory.workloads
        }
        return pool.first {
            $0.namespace == anchor.namespace && $0.name == anchor.name
                && $0.kind?.apiKind == anchor.kindLabel
        }
    }
}
