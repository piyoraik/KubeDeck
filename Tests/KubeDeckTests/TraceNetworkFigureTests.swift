import Testing
@testable import KubeDeck

/// 通信の図は、判定の結果を「相手の居る場所」と「線」に読み替える。
/// 読み替えを誤ると、止めている側と反対に ✕ を置く。
@Suite("通信の図への読み替え")
struct TraceNetworkFigureTests {

    private func row(
        _ name: String, namespace: String = "shop",
        _ outcome: FlowPeerGroup.Outcome = .allowed, ports: [PolicyPort]? = nil
    ) -> TraceFlowRow {
        let peer = TracePeer(
            name: name, kindLabel: "Deployment", namespace: namespace, symbol: "square",
            anchor: nil)
        return TraceFlowRow(
            id: "\(namespace)/\(name)", subject: .workload(peer, outcome, podCount: 1),
            ports: ports, policies: ["p"])
    }

    @Test("✕ は止めている側に置く。入る線と出る線で左右が入れ替わる")
    func stopSideFollowsDirection() {
        #expect(PlacementTrace.stop([.egress], direction: .ingress) == .peer)
        #expect(PlacementTrace.stop([.ingress], direction: .ingress) == .origin)
        #expect(PlacementTrace.stop([.ingress], direction: .egress) == .peer)
        #expect(PlacementTrace.stop([.egress], direction: .egress) == .origin)
        #expect(PlacementTrace.stop([.egress, .ingress], direction: .ingress) == .both)
        #expect(PlacementTrace.stop([.ports], direction: .egress) == .ports)
    }

    @Test("同じ Namespace の相手は 1 つの箱にまとまり、止まる相手の箱が先に来る")
    func groupsByPlaceKeepingStoppedFirst() {
        let column = TraceFlowColumn(rows: [
            row("batch", .blocked([.egress])),
            row("prometheus", namespace: "ops"),
            row("api"),
        ])
        let groups = PlacementTrace.lanes(column, direction: .ingress)

        #expect(groups.map(\.place) == [.namespace("shop"), .namespace("ops")])
        #expect(groups[0].lanes.map(\.name) == ["batch", "api"])
        #expect(groups[0].lanes[0].line == .stopped(.peer))
        #expect(groups[0].lanes[1].line == .open)
    }

    @Test("場所を持たない行は、まとめずに 1 行ずつ置く")
    func placelessRowsStaySeparate() {
        let column = TraceFlowColumn(rows: [
            TraceFlowRow(id: "unrestricted", subject: .unrestricted(count: 3), ports: nil, policies: []),
            TraceFlowRow(id: "anywhere", subject: .anywhere, ports: nil, policies: ["p"]),
        ])
        let groups = PlacementTrace.lanes(column, direction: .egress)

        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.place == .nowhere })
        #expect(Set(groups.map(\.id)).count == 2)
    }

    /// 箱にまとめたあとで切ると、止まる通信が「通る相手の多い箱」の後ろへ回って消える。
    @Test("行の上限は箱にまとめる前に掛ける。止まる通信は畳まれない")
    func limitAppliesBeforeGrouping() {
        var rows = [
            row("a", namespace: "one", .blocked([.egress])),
            row("b", namespace: "two", .blocked([.egress])),
        ]
        rows += (0..<9).map { row("ok-\($0)", namespace: "one") }

        let groups = PlacementTrace.lanes(TraceFlowColumn(rows: rows), direction: .ingress, limit: 4)
        let names = groups.flatMap { $0.lanes.map(\.name) }

        #expect(names.count == 4)
        #expect(names.contains("a"))
        #expect(names.contains("b"))
    }

    @Test("線に書くポートは 3 つまで。残りは数で言う")
    func portsAreCapped() {
        let ports = (1...5).map { PolicyPort(target: .number(8000 + $0)) }

        #expect(PlacementTrace.laneLabel(Array(ports.prefix(3))) == "TCP 8001, TCP 8002, TCP 8003")
        #expect(PlacementTrace.laneLabel(ports) == "TCP 8001, TCP 8002, TCP 8003 他 2")
    }

    /// 取得していない Namespace の相手は、通るとも止まるとも言えない。線は引くが、相手側は未確認と断る。
    @Test("中の Pod を取得していない Namespace は、箱に入れて未確認と断る")
    func unloadedNamespaceIsNotDecided() {
        let lane = PlacementTrace.lane(
            TraceFlowRow(
                id: "ns|ops|", subject: .namespace("ops", pods: "app=prometheus"),
                ports: [PolicyPort(target: .named("http"))], policies: ["p"]),
            direction: .ingress)

        #expect(lane.place == .namespace("ops"))
        #expect(lane.name == "app=prometheus")
        #expect(lane.line == .open)
        #expect(lane.note != nil)
        #expect(lane.isResolved == false)
    }

    @Test("数える: 制限なしは相手に数えず、許可が 1 つも無ければ「すべて拒否」")
    func tally() {
        let unrestricted = TraceFlowColumn(rows: [
            TraceFlowRow(id: "u", subject: .unrestricted(count: nil), ports: nil, policies: []),
        ])
        #expect(unrestricted.tally == .unrestricted)

        let denied = TraceFlowColumn(rows: [
            TraceFlowRow(id: "d", subject: .denyAll, ports: nil, policies: ["p"]),
        ])
        #expect(denied.tally == .denied)
        #expect(denied.tally.stopped == 1)

        let mixed = TraceFlowColumn(rows: [
            TraceFlowRow(id: "u", subject: .unrestricted(count: 2), ports: nil, policies: []),
            row("batch", .blocked([.egress])),
            row("api"),
            row("maybe", .undetermined),
            TraceFlowRow(id: "ns", subject: .namespace("ops", pods: nil), ports: nil, policies: ["p"]),
        ])
        #expect(mixed.tally == .peers(count: 4, stopped: 1, unsettled: 1))
    }

    // MARK: - 複数のワークロードにまたがる起点

    private func pod(_ name: String, app: String, node: String) -> K8sObject {
        Fixture.pod(
            name: name, namespace: "shop", labels: ["app": app], node: node,
            owner: (kind: "StatefulSet", name: app))
    }

    /// まとめて判定すると相手の一覧が 1 つになり、どの相手がどのワークロードに届くのかが消える。
    @Test("ノードを起点にしたら、ワークロードごとに判定する。止まる通信のあるものが先")
    func branchNetworksAreSolvedPerWorkload() {
        let policies = [
            Fixture.networkPolicy(name: "db", namespace: "shop", spec: """
                {"podSelector":{"matchLabels":{"app":"db"}},"policyTypes":["Ingress"],
                 "ingress":[{"from":[{"podSelector":{"matchExpressions":[
                   {"key":"app","operator":"In","values":["api","batch"]}]}}]}]}
                """),
            Fixture.networkPolicy(name: "batch-no-egress", namespace: "shop", spec: """
                {"podSelector":{"matchLabels":{"app":"batch"}},"policyTypes":["Egress"]}
                """),
        ]
        let inventory = PlacementInventory(
            pods: [
                pod("web-0", app: "web", node: "node-a"),
                pod("db-0", app: "db", node: "node-a"),
                pod("api-0", app: "api", node: "node-b"),
                pod("batch-0", app: "batch", node: "node-b"),
            ],
            nodes: [Fixture.node(name: "node-a"), Fixture.node(name: "node-b")],
            related: policies)
        let anchor = PlacementTrace.anchors(kind: .node, inventory: inventory, controllers: [:])
            .first { $0.name == "node-a" }!
        let graph = PlacementTrace.graph(for: anchor, inventory: inventory, controllers: [:])

        let branches = PlacementTrace.branchNetworks(
            for: graph, inventory: inventory, controllers: [:], scope: nil,
            namespaceLabels: ["shop": [:]])

        #expect(branches.map(\.workload.name) == ["db", "web"])
        #expect(branches.map(\.isRestricted) == [true, false])
        #expect(branches[0].network.policies == ["db"])
        #expect(branches[0].network.ingress.tally == .peers(count: 2, stopped: 1, unsettled: 0))
        #expect(branches[0].network.egress.tally == .unrestricted)
        // web 自身は制限されていないが、batch の出口で止まる。一覧の分類は自分の policy で決める。
        #expect(branches[1].network.ingress.tally == .peers(count: 1, stopped: 1, unsettled: 0))
    }
}
