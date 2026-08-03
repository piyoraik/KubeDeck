import Testing
@testable import KubeDeck

/// 配置とたどるの土台。**名前だけで束ねない**のと、**ReplicaSet で止めない**のが
/// ここでいちばん壊れやすい。
@Suite("配置の解き方")
struct PlacementTraceTests {

    private func index(_ controllers: [K8sObject]) -> [String: K8sObject] {
        var result: [String: K8sObject] = [:]
        for object in controllers {
            guard let kind = object.kind else { continue }
            result["\(object.namespace ?? "")/\(kind.apiKind)/\(object.name)"] = object
        }
        return result
    }

    // MARK: - 所有者

    /// **ReplicaSet 名で束ねない。** `<Deployment 名>-<ハッシュ>` なので、
    /// 更新のたびに別のまとまりに見える。
    @Test("Pod の所有者を ReplicaSet から Deployment まで辿る")
    func ownerThroughReplicaSet() throws {
        let replicaSet = Fixture.controller(
            kind: "ReplicaSet", name: "web-58f9c", owner: (kind: "Deployment", name: "web"))
        let pod = Fixture.pod(owner: (kind: "ReplicaSet", name: "web-58f9c"))

        let owner = try #require(
            PlacementTrace.workloadOwner(of: pod, controllers: index([replicaSet])))
        #expect(owner.kind == "Deployment")
        #expect(owner.name == "web")
    }

    @Test("Job から CronJob まで辿る（実行のたびに Job 名が変わる）")
    func ownerThroughJob() throws {
        let job = Fixture.controller(
            kind: "Job", name: "backup-29384", owner: (kind: "CronJob", name: "backup"))
        let pod = Fixture.pod(owner: (kind: "Job", name: "backup-29384"))

        let owner = try #require(PlacementTrace.workloadOwner(of: pod, controllers: index([job])))
        #expect(owner.name == "backup")
    }

    @Test("親が見つからなければ ReplicaSet で止まる（勝手に名前を作らない）")
    func ownerWithoutParent() throws {
        let orphan = Fixture.controller(kind: "ReplicaSet", name: "web-58f9c", owner: nil)
        let pod = Fixture.pod(owner: (kind: "ReplicaSet", name: "web-58f9c"))

        let owner = try #require(PlacementTrace.workloadOwner(of: pod, controllers: index([orphan])))
        #expect(owner.kind == "ReplicaSet")
    }

    @Test("所有者の無い Pod は単体として扱う")
    func standalonePod() {
        let pod = Fixture.pod(owner: nil)
        let anchor = PlacementTrace.workloadAnchor(of: pod, controllers: [:])

        #expect(anchor.isStandalone)
        #expect(anchor.displayName == "単体の Pod")
    }

    /// **索引は Namespace 込みで引く。** 別の Namespace に同じ名前の
    /// ReplicaSet があるのはふつう。
    @Test("Namespace が違う同名の ReplicaSet を掴まない")
    func ownerLookupIsNamespaced() throws {
        let other = Fixture.controller(
            kind: "ReplicaSet", name: "web-58f9c", namespace: "team-b",
            owner: (kind: "Deployment", name: "web"))
        let pod = Fixture.pod(namespace: "team-a", owner: (kind: "ReplicaSet", name: "web-58f9c"))

        let owner = try #require(
            PlacementTrace.workloadOwner(of: pod, controllers: index([other])))
        // team-a の ReplicaSet は索引に無いので、そこで止まる（team-b の
        // Deployment まで辿らない）。
        #expect(owner.kind == "ReplicaSet")
        #expect(owner.name == "web-58f9c")
    }

    @Test("支配者は controller: true のものを採る")
    func controllerReferenceUsesControllerFlag() throws {
        let pod = Fixture.object(
            """
            {"kind":"Pod","metadata":{"name":"p","namespace":"default","ownerReferences":[
              {"kind":"Custom","name":"side","controller":false},
              {"kind":"ReplicaSet","name":"web-1","controller":true}]},
             "spec":{},"status":{}}
            """, assuming: .pod)

        let reference = try #require(PlacementTrace.controllerReference(of: pod))
        #expect(reference.kind == "ReplicaSet")
        #expect(reference.name == "web-1")
    }

    // MARK: - 名前だけで束ねない

    /// **別の Namespace に同じ名前の Deployment があるのはふつう。**
    /// 名前を鍵にすると、無関係な 2 つが 1 つの箱に合体する。
    @Test("同名で別 Namespace のワークロードを 1 つにまとめない")
    func sameNameDifferentNamespace() {
        let inventory = PlacementInventory(
            pods: [
                Fixture.pod(name: "a-1", namespace: "team-a",
                            owner: (kind: "Deployment", name: "dup")),
                Fixture.pod(name: "b-1", namespace: "team-b",
                            owner: (kind: "Deployment", name: "dup")),
            ],
            workloads: [
                Fixture.controller(kind: "Deployment", name: "dup", namespace: "team-a", owner: nil),
                Fixture.controller(kind: "Deployment", name: "dup", namespace: "team-b", owner: nil),
            ])

        let anchors = PlacementTrace.anchors(
            kind: .workload, inventory: inventory, controllers: [:])

        #expect(anchors.count == 2)
        #expect(Set(anchors.map(\.id)).count == 2)
        #expect(anchors.allSatisfy { $0.podCount == 1 })
    }

    // MARK: - 起点

    /// **レプリカ 0 のワークロードは Pod 側からは見えない。**
    /// 実在するワークロードの一覧と合わせないと、起点に選べない。
    @Test("Pod が 1 つも無いワークロードも起点に出す")
    func zeroReplicaWorkloadIsStillAnAnchor() {
        let inventory = PlacementInventory(
            pods: [],
            workloads: [Fixture.controller(kind: "Deployment", name: "idle", owner: nil)])

        let anchors = PlacementTrace.anchors(
            kind: .workload, inventory: inventory, controllers: [:])

        #expect(anchors.map(\.name) == ["idle"])
        #expect(anchors.first?.podCount == 0)
    }

    @Test("Service を起点にすると掴んでいる Pod が数えられる")
    func serviceAnchorCountsPods() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        let inventory = PlacementInventory(
            pods: [
                Fixture.pod(name: "web-1", labels: ["app": "web"]),
                Fixture.pod(name: "web-2", labels: ["app": "web"]),
                Fixture.pod(name: "other", labels: ["app": "api"]),
            ],
            related: [service])

        let anchors = PlacementTrace.anchors(
            kind: .service, inventory: inventory, controllers: [:])
        #expect(anchors.first?.podCount == 2)
    }

    /// **黙って落とさない。** 「先に何も無い」と「掴んでいる Pod が無い」は別。
    @Test("何も掴んでいない Service は dangling として返す")
    func danglingService() {
        let service = Fixture.service(name: "web", selector: ["app": "gone"])
        let inventory = PlacementInventory(
            pods: [Fixture.pod(labels: ["app": "web"])], related: [service])

        let anchor = PlacementTrace.anchors(
            kind: .service, inventory: inventory, controllers: [:])[0]
        let graph = PlacementTrace.graph(for: anchor, inventory: inventory, controllers: [:])

        #expect(graph.podCount == 0)
        #expect(graph.danglingServices.map(\.name) == ["web"])
    }

    @Test("ノードを起点にすると、そのノードの Pod だけを解く")
    func nodeAnchor() {
        let inventory = PlacementInventory(
            pods: [
                Fixture.pod(name: "a", node: "node-a", owner: (kind: "Deployment", name: "web")),
                Fixture.pod(name: "b", node: "node-b", owner: (kind: "Deployment", name: "web")),
            ],
            nodes: [Fixture.node(name: "node-a"), Fixture.node(name: "node-b")])

        let anchors = PlacementTrace.anchors(kind: .node, inventory: inventory, controllers: [:])
        let nodeA = anchors.first { $0.name == "node-a" }!
        let graph = PlacementTrace.graph(for: nodeA, inventory: inventory, controllers: [:])

        #expect(graph.podCount == 1)
        #expect(graph.pods.map(\.name) == ["a"])
    }

    @Test("スケジュールされていない Pod のノード名は nil")
    func unscheduledPod() {
        #expect(PlacementTrace.nodeName(of: Fixture.pod(node: nil)) == nil)
        #expect(PlacementTrace.nodeName(of: Fixture.pod(node: "node-a")) == "node-a")
    }

    /// **Pod が 0 の世代も出す。** 入れ替わりの途中や、古い世代が残って
    /// いることが分かる。
    @Test("Pod が 0 の ReplicaSet も枝に残す")
    func emptyGenerationIsKept() {
        let old = Fixture.controller(
            kind: "ReplicaSet", name: "web-old", owner: (kind: "Deployment", name: "web"))
        let current = Fixture.controller(
            kind: "ReplicaSet", name: "web-new", owner: (kind: "Deployment", name: "web"))
        let pod = Fixture.pod(name: "web-x", owner: (kind: "ReplicaSet", name: "web-new"))

        let inventory = PlacementInventory(
            pods: [pod], generations: [old, current],
            workloads: [Fixture.controller(kind: "Deployment", name: "web", owner: nil)])
        let controllers = index([old, current])

        let anchor = PlacementTrace.anchors(
            kind: .workload, inventory: inventory, controllers: controllers)[0]
        let graph = PlacementTrace.graph(
            for: anchor, inventory: inventory, controllers: controllers)

        let names = graph.branches.flatMap(\.generations).map(\.name)
        #expect(Set(names) == ["web-new", "web-old"])
    }
}
