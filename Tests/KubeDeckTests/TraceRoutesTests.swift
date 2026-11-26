import Foundation
import Testing
@testable import KubeDeck

/// たどるに載せる経路。状態の読み方そのものは `TrafficRouteTests` が実物で固めてある。
@Suite("たどるの経路")
struct TraceRoutesTests {

    // v1 は 2 Pod、v2 は 1 Pod。Service `web` は両方を、`web-v1` / `web-v2` は片方ずつ掴む。
    private let pods = [
        Fixture.pod(
            name: "web-v1-a", namespace: "shop", labels: ["app": "web", "version": "v1"],
            owner: (kind: "ReplicaSet", name: "web-v1-rs")),
        Fixture.pod(
            name: "web-v1-b", namespace: "shop", labels: ["app": "web", "version": "v1"],
            node: "node-b", owner: (kind: "ReplicaSet", name: "web-v1-rs")),
        Fixture.pod(
            name: "web-v2-a", namespace: "shop", labels: ["app": "web", "version": "v2"],
            owner: (kind: "ReplicaSet", name: "web-v2-rs")),
    ]
    private let controllers = [
        Fixture.controller(
            kind: "ReplicaSet", name: "web-v1-rs", namespace: "shop",
            owner: (kind: "Deployment", name: "web-v1")),
        Fixture.controller(
            kind: "ReplicaSet", name: "web-v2-rs", namespace: "shop",
            owner: (kind: "Deployment", name: "web-v2")),
    ]
    private let services = [
        Fixture.service(name: "web", namespace: "shop", selector: ["app": "web"]),
        Fixture.service(
            name: "web-v1", namespace: "shop", selector: ["app": "web", "version": "v1"]),
        Fixture.service(
            name: "web-v2", namespace: "shop", selector: ["app": "web", "version": "v2"]),
    ]
    /// どの経路にも出てこないが、同じ Pod を掴んでいる Service。
    private let bystander = Fixture.service(
        name: "bystander", namespace: "shop", selector: ["app": "web"])

    private var index: [String: K8sObject] {
        var result: [String: K8sObject] = [:]
        for object in controllers {
            guard let kind = object.kind else { continue }
            result["\(object.namespace ?? "")/\(kind.apiKind)/\(object.name)"] = object
        }
        return result
    }

    private func inventory(
        routes: [TrafficRoute], scope: String? = nil, problem: String? = nil,
        extra: [K8sObject] = []
    ) -> PlacementInventory {
        PlacementInventory(
            pods: pods, generations: controllers, related: services + extra,
            routes: routes, routeProblem: problem, scope: scope)
    }

    private static let accepted = """
        [{"type":"Accepted","status":"True","reason":"Accepted","message":"Route was valid"},
         {"type":"ResolvedRefs","status":"True","reason":"ResolvedRefs","message":"All references resolved"},
         {"type":"ResolvedWaypoints","status":"True","reason":"ResolvedWaypoints","message":"All waypoints resolved"}]
        """
    private static let unresolved = """
        [{"type":"Accepted","status":"True","reason":"Accepted","message":"Route was valid"},
         {"type":"ResolvedRefs","status":"False","reason":"BackendNotFound","message":"backend(nosuch) not found"}]
        """
    private static let rejected = """
        [{"type":"Accepted","status":"False","reason":"NoMatchingParent","message":"not found"}]
        """

    /// メッシュの中の振り分け（GAMMA）。親は Service。
    private static let serviceParent = #"{"group":"","kind":"Service","name":"web","port":8080}"#
    /// 外からの入口。親は Gateway。
    private static let gatewayParent =
        #"{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge"}"#

    private func route(
        _ name: String, parent: String = TraceRoutesTests.serviceParent, rules: String,
        conditions: String = TraceRoutesTests.accepted
    ) -> TrafficRoute {
        TrafficRoute(object: Fixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"\(name)","namespace":"shop"},
             "spec":{"parentRefs":[\(parent)],"rules":\(rules)},
             "status":{"parents":[{"controllerName":"istio.io/gateway-controller",
               "parentRef":\(parent),"conditions":\(conditions)}]}}
            """))!
    }

    private static let splitRules = """
        [{"backendRefs":[{"name":"web-v1","port":8080,"weight":90},
                         {"name":"web-v2","port":8080,"weight":10}]}]
        """
    private static let canaryRules = """
        [{"matches":[{"headers":[{"name":"x-canary","type":"Exact","value":"true"}]}],
          "backendRefs":[{"name":"web-v2","port":8080}]},
         {"backendRefs":[{"name":"web-v1","port":8080,"weight":90},
                         {"name":"web-v2","port":8080,"weight":10}]}]
        """
    private static let brokenRules = """
        [{"backendRefs":[{"name":"web-v1","port":8080,"weight":50},
                         {"name":"nosuch","port":8080,"weight":50}]}]
        """

    private var split: TrafficRoute { route("web", rules: Self.splitRules) }
    private var edge: TrafficRoute {
        route("edge", parent: Self.gatewayParent, rules: Self.splitRules)
    }

    private func workloadAnchor(_ name: String) -> TraceAnchor {
        TraceAnchor(
            anchorKind: .workload, resourceKind: .deployment, kindLabel: "Deployment",
            namespace: "shop", name: name)
    }

    private func routeGraph(_ name: String, in inventory: PlacementInventory) throws -> TraceGraph {
        let anchor = try #require(
            PlacementTrace.anchors(kind: .route, inventory: inventory, controllers: index)
                .first { $0.name == name })
        return PlacementTrace.graph(for: anchor, inventory: inventory, controllers: index)
    }

    private func tagTexts(_ branch: TraceBranch) -> [String: [String]] {
        Dictionary(grouping: branch.routeTags, by: \.serviceName).mapValues { $0.map(\.text) }
    }

    private func rows(_ rule: TraceRouteSplit.Rule) -> [String] {
        rule.rows.map { "\($0.name) \($0.percentText)" }
    }

    // MARK: - 置き場所（経路以外が起点のとき）

    /// 入口の列に置くと「経路 → 親の Service」と描くことになり、実際の順（親宛て → 経路 → 宛先）と逆になる。
    @Test("親が Service の経路は入口の列に置かず、Service に札で付ける")
    func meshRouteBecomesTags() throws {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [split]),
            controllers: index)
        let branch = try #require(graph.branches.first)

        #expect(branch.routes.isEmpty)
        #expect(tagTexts(branch) == ["web": ["web が振り分け"], "web-v2": ["web から 10%"]])
        #expect(branch.routeTags.allSatisfy { $0.badge == nil })
        #expect(graph.routeSplit == nil)
    }

    /// どこにも付いていない経路は何も振り分けない。効いている振り分けのように札で出さない。
    @Test("親の無い経路は、札にも入口にも出さない")
    func parentlessRouteIsNotTagged() throws {
        let orphan = try #require(TrafficRoute(object: Fixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"orphan","namespace":"shop"},
             "spec":{"rules":\(Self.splitRules)}}
            """)))
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [orphan]),
            controllers: index)
        let branch = try #require(graph.branches.first)
        #expect(branch.routeTags.isEmpty)
        #expect(branch.routes.isEmpty)
    }

    /// 浮動小数のまま足すと 3/7 + 2/7 + 2/7 が 1 に届かず「>99.9%」と出る（足す順にもよる）。
    @Test("枝の Service ぶんの割合は、重みを足してから割る")
    func entrySharesSumWeights() throws {
        let rules = """
            [{"backendRefs":[{"name":"web","port":8080,"weight":3},
                             {"name":"web-v1","port":8080,"weight":2},
                             {"name":"bystander","port":8080,"weight":2}]}]
            """
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v1"),
            inventory: inventory(
                routes: [route("edge", parent: Self.gatewayParent, rules: rules)],
                extra: [bystander]),
            controllers: index)
        let branch = try #require(graph.branches.first)
        #expect(branch.routes.map(\.subtitle) == ["HTTPRoute · 100%"])
    }

    /// 同じ名前の経路は Namespace ごとにある。断りは文で重複を除くので、Namespace が無いと潰れる。
    @Test("経路の断りには Namespace を添える")
    func findingNotesNameNamespace() {
        let notes = PlacementTrace.findingNotes(
            route("web", rules: Self.splitRules, conditions: Self.rejected))
        #expect(notes.first?.text.contains("shop/web") == true)
    }

    /// 宛先と同じく、手元に無い呼び出し先を手元にあるように描かない。
    @Test("手元に無い呼び出し先は、理由と受け付けの結果を器に添える")
    func missingParentIsMarked() throws {
        let missing = #"{"group":"","kind":"Service","name":"web-old","port":8080}"#
        let rejected = route("web", parent: missing, rules: Self.splitRules, conditions: Self.rejected)
        let origin = try #require(
            try routeGraph("web", in: inventory(routes: [rejected])).routeSplit?.origins.first)
        #expect(origin.detail == "取得した一覧にありません")
        #expect(origin.level == .serious)
        #expect(!origin.isPresent)

        let elsewhere = #"{"group":"","kind":"Service","name":"web","namespace":"edge","port":8080}"#
        let scoped = route("web", parent: elsewhere, rules: Self.splitRules)
        let outside = try #require(
            try routeGraph("web", in: inventory(routes: [scoped], scope: "shop")).routeSplit?.origins.first)
        #expect(outside.detail == "いまの取得範囲の外です")

        let present = try #require(
            try routeGraph("web", in: inventory(routes: [split])).routeSplit?.origins.first)
        #expect(present.detail == nil)
        #expect(present.level == nil)
        #expect(present.isPresent)
    }

    /// 別の Namespace（ゲートウェイ用など）に経路を置く運用だと、何も描かれないのと見分けが付かない。
    @Test("経路を引いていて絞っていれば、経路が描かれていない図でも取得範囲の外を断る")
    func scopeNoteWithoutRoutes() {
        let note = "ほかの Namespace に置かれた経路は、いまの取得範囲の外です。"
        var loaded = inventory(routes: [], scope: "shop")
        loaded.routesLoaded = true
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: loaded, controllers: index)
        #expect(graph.anchorNotes.contains { $0.text == note })

        let off = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [], scope: "shop"),
            controllers: index)
        #expect(!off.anchorNotes.contains { $0.text == note })
    }

    @Test("親が Gateway の経路は、入口の列に器で出す")
    func gatewayRouteStaysAtEntrance() throws {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [edge]),
            controllers: index)
        let branch = try #require(graph.branches.first)

        #expect(branch.routes.map(\.subtitle) == ["HTTPRoute · 10%"])
        #expect(branch.routes.first?.serviceNames == ["web-v2"])
        #expect(branch.routeTags.isEmpty)
    }

    /// 1 枚にまとめて「親 · 90%」と書くと、親に割合が残るように読めた。
    @Test("振り分け元と宛先を兼ねる Service には、札を 2 枚付ける")
    func parentAndDestinationGetTwoTags() throws {
        let stable = route("web", rules: """
            [{"backendRefs":[{"name":"web","port":8080,"weight":90},
                             {"name":"web-v2","port":8080,"weight":10}]}]
            """)
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [stable]),
            controllers: index)
        let branch = try #require(graph.branches.first)

        #expect(tagTexts(branch) == [
            "web": ["web が振り分け", "web から 90%"], "web-v2": ["web から 10%"],
        ])
    }

    /// 親の Service から Pod への線は描いたままなので、振り分けられていることは札で言う。
    @Test("この枝へ流さない経路でも、振り分け元の Service には札を付ける。図の上では触れない")
    func parentTagWithoutShareHere() throws {
        let onlyV1 = route(
            "only-v1", rules: #"[{"backendRefs":[{"name":"web-v1","port":8080}]}]"#,
            conditions: Self.rejected)
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [onlyV1]),
            controllers: index)
        let branch = try #require(graph.branches.first)

        #expect(tagTexts(branch) == ["web": ["only-v1 が振り分け"]])
        #expect(branch.routeTags.first?.badge == .serious)
        #expect(graph.anchorNotes.isEmpty)
    }

    @Test("振り分け元の札の説明には、振り分け先をぜんぶ書く")
    func parentTagExplainsTheSplit() throws {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [split]),
            controllers: index)
        let tag = try #require(graph.branches.first?.routeTags.first { $0.role == .parent })

        #expect(tag.help.contains("親: Service web"))
        #expect(tag.help.contains("この Service 宛ての呼び出しを、この経路が振り分けます。"))
        #expect(tag.help.contains("規則 1: web-v1 90%, web-v2 10%"))
    }

    /// 欄が詰まったときに縮めるのは名前だけ。割合まで切ると「10〜100%」が「0〜100%」に読めた。
    @Test("札の文字は、名前とその前後に分けられる")
    func tagTextSplitsAroundTheName() throws {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [split]),
            controllers: index)
        let tags = try #require(graph.branches.first?.routeTags)
        let parent = try #require(tags.first { $0.role == .parent })
        let destination = try #require(tags.first { $0.role == .destination })

        #expect(parent.parts.lead + parent.name + parent.parts.trail == parent.text)
        #expect(parent.parts.trail == " が振り分け")
        #expect(destination.parts.trail == " から 10%")
    }

    @Test("経路を引いていなければ、図は何も変わらない")
    func nothingWithoutRoutes() throws {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: []), controllers: index)

        #expect(graph.branches.first?.routes.isEmpty == true)
        #expect(graph.branches.first?.routeTags.isEmpty == true)
        #expect(graph.anchorNotes.isEmpty)
        #expect(graph.routeSplit == nil)
    }

    @Test("規則ごとに割合が違うときは範囲で書く")
    func rangeAcrossRules() throws {
        let canary = route("canary", rules: Self.canaryRules)
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [canary]),
            controllers: index)
        let tag = try #require(graph.branches.first?.routeTags.first { $0.role == .destination })

        #expect(tag.text == "canary から 10〜100%")
        #expect(tag.help.contains("規則 1（x-canary: true）: 100%"))
        #expect(tag.help.contains("規則 2: 10%"))
    }

    @Test("ワークロードが起点なら絞らない。同じ Pod を掴む Service はぜんぶ出す")
    func workloadAnchorKeepsEverything() throws {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"),
            inventory: inventory(routes: [split, edge], extra: [bystander]), controllers: index)
        let branch = try #require(graph.branches.first)

        #expect(branch.services.map(\.name).sorted() == ["bystander", "web", "web-v2"])
        #expect(branch.routes.map(\.route.name) == ["edge"])
        #expect(tagTexts(branch) == ["web": ["web が振り分け"], "web-v2": ["web から 10%"]])
    }

    /// 食い違うと、押した起点が一覧に無い扱いになって先頭へ飛ぶ。
    @Test("図の中の経路（器と札）を押した先が、起点の一覧に居る")
    func drawnRouteAnchorsAreListed() throws {
        let inventory = inventory(routes: [split, edge])
        let listed = PlacementTrace.anchors(kind: .route, inventory: inventory, controllers: index)
            .map(\.id)
        let branch = try #require(
            PlacementTrace.graph(
                for: workloadAnchor("web-v1"), inventory: inventory, controllers: index
            ).branches.first)

        #expect(!branch.routes.isEmpty && !branch.routeTags.isEmpty)
        #expect(branch.routes.allSatisfy { listed.contains($0.anchor.id) })
        #expect(branch.routeTags.allSatisfy { listed.contains($0.anchor.id) })
    }

    // MARK: - 経路を起点にする（振り分けの図）

    /// 札で「親」「子 90%」と並べたら、残りの 10% が親に行くように読まれた。
    @Test("経路を起点にすると、呼び出し先から宛先へ、割合つきで分かれる図になる")
    func routeAnchorDrawsTheSplit() throws {
        let inventory = inventory(routes: [split])
        let anchor = try #require(
            PlacementTrace.anchors(kind: .route, inventory: inventory, controllers: index).first)

        #expect(anchor.id == "route|shop|HTTPRoute|web")
        #expect(anchor.podCount == 3)
        #expect(anchor.detail == "Service web")

        let graph = PlacementTrace.graph(for: anchor, inventory: inventory, controllers: index)
        let split = try #require(graph.routeSplit)

        #expect(split.origins.map(\.id) == ["Service/web"])
        #expect(split.originCaption == "ここ宛ての呼び出しの行き先")
        #expect(split.rules.map(rows) == [["web-v1 90%", "web-v2 10%"]])
        #expect(!split.showsRuleCaptions)
        #expect(split.rules[0].rows.allSatisfy { $0.target == .service && $0.level == nil })
    }

    /// 割合と呼び出し先は図が持つので、枝に同じものを重ねない。
    @Test("経路を起点にしたら、枝は宛先の Service から先だけ。札も入口の器も出さない")
    func routeAnchorBranchesStartAtDestinations() throws {
        let other = route(
            "other", rules: #"[{"backendRefs":[{"name":"web-v2","port":8080}]}]"#,
            conditions: Self.rejected)
        let graph = try routeGraph(
            "web", in: inventory(routes: [split, other, edge], extra: [bystander]))
        let services = Dictionary(
            uniqueKeysWithValues: graph.branches.map { ($0.workload.name, $0.services.map(\.name)) })

        #expect(services == ["web-v1": ["web-v1"], "web-v2": ["web-v2"]])
        #expect(graph.branches.allSatisfy { $0.routes.isEmpty && $0.routeTags.isEmpty })
        #expect(!graph.anchorNotes.contains { $0.text.contains("HTTPRoute other") })
    }

    @Test("入口の経路を起点にすると、呼び出し先は Gateway になる")
    func entranceAnchorStartsAtTheGateway() throws {
        let graph = try routeGraph("edge", in: inventory(routes: [split, edge]))
        let split = try #require(graph.routeSplit)

        #expect(split.origins.map(\.id) == ["Gateway/edge"])
        #expect(split.origins.first?.anchor == nil)
        #expect(split.originCaption == "ここに来た呼び出しの行き先")
        #expect(split.rules.map(rows) == [["web-v1 90%", "web-v2 10%"]])
        #expect(graph.branches.allSatisfy { $0.routes.isEmpty && $0.routeTags.isEmpty })
    }

    @Test("規則が複数あれば見出しを出す。同じ宛先は、規則をまたいでも同じ濃淡にする")
    func rulesKeepTheirShades() throws {
        let graph = try routeGraph(
            "canary", in: inventory(routes: [route("canary", rules: Self.canaryRules)]))
        let split = try #require(graph.routeSplit)

        #expect(split.showsRuleCaptions)
        #expect(split.rules.map(\.caption) == ["規則 1（x-canary: true）", "規則 2（条件なし）"])
        #expect(split.rules.map(rows) == [["web-v2 100%"], ["web-v1 90%", "web-v2 10%"]])
        let v2 = split.rules.flatMap(\.rows).filter { $0.name == "web-v2" }.map(\.shade)
        let v1 = split.rules.flatMap(\.rows).filter { $0.name == "web-v1" }.map(\.shade)
        #expect(Set(v2).count == 1 && Set(v1).count == 1 && v1.first != v2.first)
    }

    @Test("同じ宛先を 2 度書いた規則は、1 行にまとめる")
    func duplicateBackendsMerge() throws {
        let doubled = route("web", rules: """
            [{"backendRefs":[{"name":"web-v1","port":8080,"weight":30},
                             {"name":"web-v2","port":8080,"weight":40},
                             {"name":"web-v1","port":8080,"weight":30}]}]
            """)
        let split = try #require(try routeGraph("web", in: inventory(routes: [doubled])).routeSplit)

        #expect(split.rules.map(rows) == [["web-v1 60%", "web-v2 40%"]])
    }

    /// 食い違うと、押した起点が一覧に無い扱いになって先頭へ飛ぶ。
    @Test("振り分けの図の器を押した先が、Service の起点の一覧に居る")
    func splitAnchorsAreListed() throws {
        let inventory = inventory(routes: [split])
        let listed = PlacementTrace.anchors(
            kind: .service, inventory: inventory, controllers: index
        ).map(\.id)
        let split = try #require(try routeGraph("web", in: inventory).routeSplit)
        let anchors = split.origins.compactMap(\.anchor) + split.rules.flatMap(\.rows).compactMap(\.anchor)

        #expect(anchors.count == 3)
        #expect(anchors.allSatisfy { listed.contains($0.id) })
    }

    // MARK: - 届かない宛先

    @Test("宛先が無いぶんを 500 と書くのは、コントローラもそう言うときだけ")
    func deadDestination() throws {
        let graph = try routeGraph(
            "web",
            in: inventory(routes: [route("web", rules: Self.brokenRules, conditions: Self.unresolved)]))
        let row = try #require(
            graph.routeSplit?.rules.first?.rows.first { $0.name == "nosuch" })

        #expect(row.target == .missing(dead: true))
        #expect(row.level == .serious)
        #expect(row.anchor == nil)
        #expect(row.detail == "Service がありません。この 50% は 500 を返します")
        #expect(graph.anchorNotes.contains { $0.text.contains("BackendNotFound") })
    }

    @Test("手元に無くても、コントローラが解決できたと言っているなら 500 とは書かない")
    func missingButResolvedDestination() throws {
        let graph = try routeGraph(
            "web", in: inventory(routes: [route("web", rules: Self.brokenRules)]))
        let row = try #require(
            graph.routeSplit?.rules.first?.rows.first { $0.name == "nosuch" })

        #expect(row.target == .missing(dead: false))
        #expect(row.level == .warning)
        #expect(row.detail == "取得した一覧にありません")
    }

    @Test("絞り込みの外にある宛先は「ありません」と書かない")
    func outOfScopeDestination() throws {
        let crossing = route("web", rules: """
            [{"backendRefs":[{"name":"web-v1","port":8080,"weight":50},
                             {"name":"other","namespace":"elsewhere","port":8080,"weight":50}]}]
            """)
        let graph = try routeGraph("web", in: inventory(routes: [crossing], scope: "shop"))
        let row = try #require(
            graph.routeSplit?.rules.first?.rows.first { $0.name == "elsewhere/other" })

        #expect(row.target == .outOfScope)
        #expect(row.level == nil)
        #expect(row.detail == "いまの取得範囲の外です")
    }

    // MARK: - 断り

    @Test("割合を出した図には、宣言であって流量ではないと断る")
    func disclaimerAlwaysShown() throws {
        let workload = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [split]),
            controllers: index)
        let anchored = try routeGraph("web", in: inventory(routes: [split]))

        for graph in [workload, anchored] {
            #expect(graph.anchorNotes.map(\.level) == [.neutral])
            #expect(graph.anchorNotes.first?.text.contains("割合は宣言です") == true)
        }
    }

    @Test("Namespace を絞っているときは、ほかの Namespace の経路が見えていないと断る")
    func scopeNote() {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [split], scope: "shop"),
            controllers: index)

        #expect(graph.anchorNotes.contains { $0.text.contains("いまの取得範囲の外です") })
    }

    @Test("受け付けられていない経路には、しるしと文字の両方を出す")
    func rejectedRouteHasBadgeAndNote() throws {
        let rejected = route(
            "web", rules: #"[{"backendRefs":[{"name":"web-v2","port":8080}]}]"#,
            conditions: Self.rejected)
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [rejected]),
            controllers: index)

        #expect(graph.branches.first?.routeTags.first { $0.role == .destination }?.badge == .serious)
        let note = try #require(graph.anchorNotes.first)
        #expect(note.level == .serious)
        #expect(note.text == "HTTPRoute shop/web は Service web に付いていません（NoMatchingParent）: not found")
    }

    /// 実測: Istio の `ResolvedWaypoints` は、経路が効かないときも True のまま文言だけを変える。
    @Test("実装独自の条件が何か言っていれば、True でも文字のまま出す")
    func advisoryIsShownVerbatim() throws {
        let message = "istio.io/use-waypoint label missing from parent and parent namespace; in ambient mode, route will not be respected"
        let unbound = route(
            "web", rules: #"[{"backendRefs":[{"name":"web-v2","port":8080}]}]"#,
            conditions: """
                [{"type":"Accepted","status":"True","reason":"Accepted","message":"Route was valid"},
                 {"type":"ResolvedWaypoints","status":"True","reason":"ResolvedWaypoints","message":"\(message)"}]
                """)
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"), inventory: inventory(routes: [unbound]),
            controllers: index)

        #expect(graph.branches.first?.routeTags.first { $0.role == .destination }?.badge == .warning)
        #expect(graph.anchorNotes.first?.text == "HTTPRoute shop/web（ResolvedWaypoints）: \(message)")
    }

    @Test("読めなかったら、経路が無いのではなく読めないと書く")
    func unreadableRoutes() {
        let graph = PlacementTrace.graph(
            for: workloadAnchor("web-v2"),
            inventory: inventory(routes: [], problem: "httproutes is forbidden\n対処の説明"),
            controllers: index)

        #expect(graph.anchorNotes.map(\.level) == [.warning])
        #expect(graph.anchorNotes.first?.text
            == "HTTPRoute を読めないので、経路は描いていません: httproutes is forbidden")
    }

    // MARK: - 出すかどうか

    /// 一時的に読めないだけで種別を消すと、選んでいた経路の起点が 1 回の失敗で外れる。
    @Test("起点の種別に経路を出すのは、入れていて種別があるとき。一時的に読めなくても残す")
    func routeKindIsOfferedOnlyWhenLoaded() {
        #expect(TraceAnchorKind.offered(routes: .loaded).contains(.route))
        #expect(!TraceAnchorKind.offered(routes: .off).contains(.route))
        #expect(!TraceAnchorKind.offered(routes: .absent).contains(.route))
        #expect(TraceAnchorKind.offered(routes: .unreadable("x")).contains(.route))
        #expect(TraceAnchorKind.offered(routes: .off).count == TraceAnchorKind.allCases.count - 1)
    }

    @Test("「その種別は無い」と言うのは、API の一覧に照らして確かめられたときだけ")
    func unknownKindNeedsFreshDiscovery() {
        #expect(MeshRouteLoader.isUnknownKind(APIDiscoveryError.unknownResource("httproutes")))
        #expect(!MeshRouteLoader.isUnknownKind(APIDiscoveryError.empty))
        #expect(!MeshRouteLoader.isUnknownKind(APIError.timedOut(seconds: 20)))
    }
}
