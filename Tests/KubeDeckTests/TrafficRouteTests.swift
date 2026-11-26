import Foundation
import Testing
@testable import KubeDeck

/// 経路（HTTPRoute）の読み取り。状態の JSON は Istio 1.32.0（ambient）が実際に書いたもの。
@Suite("経路の読み取り")
struct TrafficRouteTests {

    // MARK: - 割合

    @Test("重みは比として読む（実物: 90 と 10）")
    func weightsAreRatios() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.web))

        #expect(route.kindLabel == "HTTPRoute")
        #expect(route.shares(toService: "web-v1", namespace: "kubedeck-mesh")
            == [TrafficRoute.Share(rule: 1, fraction: 0.9)])
        #expect(route.shares(toService: "web-v2", namespace: "kubedeck-mesh")
            == [TrafficRoute.Share(rule: 1, fraction: 0.1)])
        #expect(route.shares(toService: "web", namespace: "kubedeck-mesh").isEmpty)
    }

    @Test("重みの省略は 1。合計が 100 でなくても割合になる")
    func omittedWeightIsOne() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"rules":[{"backendRefs":[
               {"name":"a","port":80},{"name":"b","port":80},{"name":"c","port":80,"weight":2}]}]}}
            """)))

        #expect(route.rules[0].backends.map(\.weight) == [1, 1, 2])
        #expect(route.shares(toService: "c", namespace: "shop").first?.fraction == 0.5)
    }

    @Test("重み 0 は 0。合計が 0 でも 0 で割らない")
    func zeroWeights() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"rules":[
               {"backendRefs":[{"name":"a","weight":100},{"name":"b","weight":0}]},
               {"backendRefs":[{"name":"a","weight":0},{"name":"b","weight":0}]}]}}
            """)))

        #expect(route.shares(toService: "b", namespace: "shop")
            == [TrafficRoute.Share(rule: 1, fraction: 0), TrafficRoute.Share(rule: 2, fraction: 0)])
        #expect(route.shares(toService: "a", namespace: "shop").map(\.fraction) == [1, 0])
    }

    @Test("割合は規則ごとに持つ。1 つの数字にまとめない（実物）")
    func sharesArePerRule() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.canary))

        #expect(route.rules.map(\.number) == [1, 2, 3])
        #expect(route.shares(toService: "web-v2", namespace: "kubedeck-mesh")
            == [TrafficRoute.Share(rule: 1, fraction: 1), TrafficRoute.Share(rule: 3, fraction: 0.1)])
        #expect(route.shares(toService: "web-v1", namespace: "kubedeck-mesh")
            == [TrafficRoute.Share(rule: 3, fraction: 0.9)])
    }

    @Test("match は文字にするだけ。既定の「すべてのパス」は条件に数えない（実物）")
    func matchesAreDescribedNotEvaluated() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.canary))

        #expect(route.rules[0].matches == ["x-canary: true"])
        #expect(route.rules[1].matches == ["PathPrefix /old"])
        #expect(route.rules[2].matches.isEmpty)
    }

    /// match は OR。1 つでも「すべてのパス」があれば、その規則はすべてのリクエストに当たる。
    @Test("match に「すべてのパス」が 1 つでもあれば、条件なしとして読む")
    func catchAllMatchMakesRuleUnconditional() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"rules":[{"matches":[{"path":{"type":"PathPrefix","value":"/"}},
                                          {"headers":[{"name":"x-canary","value":"true"}]}],
                               "backendRefs":[{"name":"web-v2","port":8080}]}]}}
            """)))
        #expect(route.rules[0].matches.isEmpty)
    }

    @Test("宛先を持たない規則（リダイレクト）は、宛先なしとして読む（実物）")
    func redirectRuleHasNoBackends() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.canary))

        #expect(route.rules[1].backends.isEmpty)
        #expect(route.rules[1].filters == ["RequestRedirect"])
    }

    @Test("別の Namespace の宛先は、その Namespace の Service として読む（実物）")
    func backendNamespaceIsRespected() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.crossNamespace))

        #expect(route.shares(toService: "other", namespace: "kubedeck-mesh-b").first?.fraction == 0.5)
        #expect(route.shares(toService: "other", namespace: "kubedeck-mesh").isEmpty)
    }

    @Test(
        "割合の数字: 0 と 100 は本当にそうのときだけ",
        arguments: [
            (0.1, "10"), (1.0 / 3.0, "33.3"), (0.905, "90.5"), (0.0, "0"), (1.0, "100"),
            (0.0001, "<0.1"), (0.9999, ">99.9"), (0.07, "7"),
        ])
    func percentText(fraction: Double, expected: String) {
        #expect(TrafficRoute.percentText(fraction) == expected)
    }

    // MARK: - 親

    @Test("Service が親の経路（実物）")
    func serviceParent() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.web))
        let parent = try #require(route.parents.first)

        #expect(parent.kind == .service)
        #expect(parent.namespace == "kubedeck-mesh")
        #expect(parent.name == "web")
        #expect(parent.port == 8080)
        #expect(parent.reports.map(\.controller) == ["istio.io/gateway-controller"])
    }

    @Test("別の Namespace の Gateway が親（実物）")
    func gatewayParentInAnotherNamespace() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.edgeFromOtherNamespace))
        let parent = try #require(route.parents.first)

        #expect(parent.kind == .gateway)
        #expect(parent.namespace == "kubedeck-mesh")
        #expect(route.namespace == "kubedeck-mesh-b")
    }

    @Test("省略された group / kind / namespace は既定で埋めて、状態と突き合わせる")
    func parentDefaults() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"parentRefs":[{"name":"edge"}]},
             "status":{"parents":[{"controllerName":"example.com/controller",
               "parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","namespace":"shop","name":"edge"},
               "conditions":[{"type":"Accepted","status":"True","reason":"Accepted","message":""}]}]}}
            """)))
        let parent = try #require(route.parents.first)

        #expect(parent.kind == .gateway)
        #expect(parent.namespace == "shop")
        #expect(parent.reports.count == 1)
        #expect(parent.findings.isEmpty)
    }

    @Test("同じ相手を指す親が 1 つなら、port の書き方が違っても記録を取りこぼさない")
    func loneParentMatchesRegardlessOfPort() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"parentRefs":[{"group":"","kind":"Service","name":"web","port":8080}]},
             "status":{"parents":[{"controllerName":"c",
               "parentRef":{"group":"","kind":"Service","name":"web"},
               "conditions":[{"type":"Accepted","status":"True","reason":"Accepted","message":""}]}]}}
            """)))

        #expect(route.parents.first?.findings == [])
    }

    @Test("同じ相手を複数の sectionName で指しているときは、それぞれの記録を取り違えない")
    func sectionNamesAreKeptApart() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"parentRefs":[{"name":"edge","sectionName":"http"},{"name":"edge","sectionName":"https"}]},
             "status":{"parents":[{"controllerName":"c",
               "parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge","sectionName":"https"},
               "conditions":[{"type":"Accepted","status":"False","reason":"NotAllowedByListeners","message":"m"}]}]}}
            """)))

        #expect(route.parents[0].findings == [.noRecord])
        #expect(route.parents[1].findings
            == [.notAccepted(reason: "NotAllowedByListeners", message: "m")])
    }

    // MARK: - コントローラが書いた状態

    @Test("受け付けられていれば、何も言わない（実物）")
    func acceptedRouteHasNoFindings() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.web))
        #expect(route.parents.first?.findings == [])
    }

    @Test("存在しない Gateway が親だと記録そのものが無い。False とは別に扱う（実物）")
    func missingGatewayLeavesNoRecord() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.ghostGateway))
        #expect(route.parents.first?.findings == [.noRecord])
    }

    @Test("ホスト名がリスナーと合わない: reason と message をそのまま運ぶ（実物）")
    func hostnameMismatch() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.edgeMismatch))
        #expect(route.parents.first?.findings == [
            .notAccepted(
                reason: "NoMatchingListenerHostname",
                message: #"no hostnames matched parent hostname "*.example.com""#),
        ])
    }

    @Test("別の Namespace からは許されていない（実物）")
    func namespaceNotAllowed() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.edgeFromOtherNamespace))
        #expect(route.parents.first?.findings == [
            .notAccepted(
                reason: "NotAllowedByListeners",
                message: """
                    hostnames matched parent hostname "*.example.com", \
                    but namespace "kubedeck-mesh-b" is not allowed by the parent
                    """),
        ])
    }

    @Test("宛先を解決できていない（実物）")
    func backendNotFound() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.broken))
        #expect(route.parents.first?.findings == [
            .unresolvedReferences(
                reason: "BackendNotFound",
                message: "backend(nosuch.kubedeck-mesh.svc.cluster.local) not found"),
        ])
    }

    /// Istio の `ResolvedWaypoints` は、経路が効かないときも `True` のまま文言だけを変える（実測）。
    @Test("実装独自の条件は True でも、決まり文句でなければ拾う（実物）")
    func advisoryOnTrueCondition() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.noWaypoint))
        #expect(route.parents.first?.findings == [
            .advisory(
                type: "ResolvedWaypoints",
                message: """
                    istio.io/use-waypoint label missing from parent and parent namespace; \
                    in ambient mode, route will not be respected
                    """),
        ])
    }

    @Test("付いていない親への補足は重ねて出さない（実物: parent not found）")
    func rejectedParentSuppressesAdvisories() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.ghostService))
        #expect(route.parents.first?.findings == [
            .notAccepted(reason: "NoMatchingParent", message: #"parent service: "nosuchsvc" not found"#),
        ])
    }

    @Test("Unknown は False に寄せない")
    func unknownIsNotFalse() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"parentRefs":[{"name":"edge"}]},
             "status":{"parents":[{"controllerName":"c",
               "parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge"},
               "conditions":[{"type":"Accepted","status":"Unknown","reason":"Pending","message":"waiting"}]}]}}
            """)))

        #expect(route.parents.first?.findings == [.undecided(type: "Accepted", message: "waiting")])
    }

    /// spec を直した直後は、前の版についての判定が status に残る。いまの判定として出さない。
    @Test("observedGeneration が spec の世代より古い条件は、前の版の判定として扱う")
    func outdatedConditionsAreNotCurrent() throws {
        func route(observed: String) throws -> TrafficRoute {
            try #require(TrafficRoute(object: RouteFixture.object("""
                {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop","generation":2},
                 "spec":{"parentRefs":[{"name":"edge"}],
                         "rules":[{"backendRefs":[{"name":"web-v2","port":8080}]}]},
                 "status":{"parents":[{"controllerName":"c",
                   "parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge"},
                   "conditions":[{"type":"Accepted","status":"True","reason":"Accepted",
                                  "message":"ok"\(observed)},
                                 {"type":"ResolvedRefs","status":"False","reason":"BackendNotFound",
                                  "message":"backend(web-v3) not found"\(observed)}]}]}}
                """)))
        }

        let stale = try route(observed: #","observedGeneration":1"#)
        #expect(stale.parents.first?.findings == [.outdated(type: "Accepted"), .outdated(type: "ResolvedRefs")])
        #expect(!stale.reportsUnresolvedBackends)

        let current = try route(observed: #","observedGeneration":2"#)
        #expect(current.reportsUnresolvedBackends)

        // 書かない実装もあるので、無いだけで前の版とはみなさない。
        let unstamped = try route(observed: "")
        #expect(unstamped.reportsUnresolvedBackends)
    }

    // MARK: - 宛先を手元の Service に解く

    @Test("全 Namespace を取得していれば、別の Namespace の宛先も解ける")
    func resolvesAcrossNamespaces() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.crossNamespace))
        let services = [
            RouteFixture.service("web-v1", namespace: "kubedeck-mesh"),
            RouteFixture.service("other", namespace: "kubedeck-mesh-b"),
            // 同じ名前でも別の Namespace のものは掴まない。
            RouteFixture.service("other", namespace: "kubedeck-mesh"),
        ]

        let destinations = route.destinations(among: services, scope: nil)

        #expect(destinations.services.map { "\($0.namespace ?? "")/\($0.name)" }
            == ["kubedeck-mesh/web-v1", "kubedeck-mesh-b/other"])
        #expect(destinations.missing.isEmpty)
        #expect(destinations.unverifiable.isEmpty)
    }

    /// Istio は ReferenceGrant が無くても別の Namespace へ流した（実測 44/100）。「届かない」とは言えない。
    @Test("絞り込みの外にある宛先は「無い」ではなく「確かめられない」")
    func outOfScopeIsNotMissing() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.crossNamespace))
        let services = [RouteFixture.service("web-v1", namespace: "kubedeck-mesh")]

        let destinations = route.destinations(among: services, scope: "kubedeck-mesh")

        #expect(destinations.missing.isEmpty)
        #expect(destinations.unverifiable.map(\.name) == ["other"])
    }

    @Test("取得した範囲の中に無ければ「無い」")
    func missingInsideScope() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.broken))
        let services = [RouteFixture.service("web-v1", namespace: "kubedeck-mesh")]

        #expect(route.destinations(among: services, scope: nil).missing.map(\.name) == ["nosuch"])
        #expect(route.destinations(among: services, scope: "kubedeck-mesh").missing.map(\.name)
            == ["nosuch"])
    }

    @Test("Service を読めていないなら「無い」と言わない")
    func unreadableServicesAreNotMissing() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.broken))

        let destinations = route.destinations(among: [], scope: nil, servicesReadable: false)

        #expect(destinations.missing.isEmpty)
        #expect(destinations.unverifiable.map(\.name) == ["web-v1", "nosuch"])
    }

    @Test("Service 以外の宛先は辿らない")
    func nonServiceBackends() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object("""
            {"kind":"HTTPRoute","metadata":{"name":"r","namespace":"shop"},
             "spec":{"rules":[{"backendRefs":[
               {"group":"multicluster.x-k8s.io","kind":"ServiceImport","name":"web","port":80}]}]}}
            """)))

        let destinations = route.destinations(
            among: [RouteFixture.service("web", namespace: "shop")], scope: nil)

        #expect(destinations.services.isEmpty)
        #expect(destinations.unsupported.map(\.kind) == ["ServiceImport"])
        #expect(route.shares(toService: "web", namespace: "shop").isEmpty)
    }

    // MARK: - 500 になる割合

    /// 実測: 重み 50:50 で片方が存在しないとき、100 回のうち 48 回が 500 だった。
    @Test("無い宛先のぶんを 500 と言うのは、コントローラも解決できていないと言うときだけ（実物）")
    func deadShareNeedsBothSignals() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.broken))
        let services = [RouteFixture.service("web-v1", namespace: "kubedeck-mesh")]

        let dead = route.deadShares(route.destinations(among: services, scope: nil))

        #expect(dead == [TrafficRoute.Share(rule: 1, fraction: 0.5)])
    }

    @Test("コントローラが解決できたと言うなら、手元に無くても 500 とは言わない")
    func deadShareIsSilentWhenControllerResolved() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.crossNamespace))
        let services = [RouteFixture.service("web-v1", namespace: "kubedeck-mesh")]

        // Service の一覧に欠けがあって「無い」に見えても、状態は True。
        let dead = route.deadShares(route.destinations(among: services, scope: nil))

        #expect(dead.isEmpty)
    }

    @Test("範囲の外の宛先は 500 に数えない")
    func deadShareIgnoresUnverifiable() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.broken))

        let dead = route.deadShares(
            route.destinations(among: [], scope: nil, servicesReadable: false))

        #expect(dead.isEmpty)
    }

    // MARK: - 読めないもの

    @Test("Namespace を持たないものは経路として読まない")
    func needsNamespace() {
        let object = RouteFixture.object(#"{"kind":"HTTPRoute","metadata":{"name":"r"},"spec":{}}"#)
        #expect(TrafficRoute(object: object) == nil)
        #expect(TrafficRoute.routes(from: [object, RouteFixture.web]).map(\.name) == ["web"])
    }

    @Test("spec も status も無くても落ちない")
    func emptyRoute() throws {
        let route = try #require(TrafficRoute(object: RouteFixture.object(
            #"{"metadata":{"name":"r","namespace":"shop"}}"#)))

        #expect(route.kindLabel == "HTTPRoute")
        #expect(route.parents.isEmpty)
        #expect(route.rules.isEmpty)
        #expect(route.id == "shop/HTTPRoute/r")
    }
}

/// `cluster-dev`（Istio 1.32.0 ambient、Gateway API v1.6.1）から 2026-11-25 に取った実物。
/// `metadata` の一部（managedFields など）だけ落としてある。
private enum RouteFixture {
    static func object(_ json: String) -> K8sObject {
        let value = try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return K8sObject(raw: value)!
    }

    static func service(_ name: String, namespace: String) -> K8sObject {
        object("""
            {"kind":"Service","metadata":{"name":"\(name)","namespace":"\(namespace)"},
             "spec":{"selector":{"app":"\(name)"}}}
            """)
    }

    static let web = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"web","namespace":"kubedeck-mesh","uid":"bab523f0-db47-48d0-9465-727f8f44cbb3","generation":1},"spec":{"parentRefs":[{"group":"","kind":"Service","name":"web","port":8080}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"web-v1","port":8080,"weight":90},{"group":"","kind":"Service","name":"web-v2","port":8080,"weight":10}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:02:37Z","message":"Route was valid","observedGeneration":1,"reason":"Accepted","status":"True","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:02:37Z","message":"All references resolved","observedGeneration":1,"reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:02:37Z","message":"All waypoints resolved","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"","kind":"Service","name":"web","port":8080}}]}}
        """#)

    /// waypoint を付けていない Service が親。このとき振り分けは実際に起きなかった（40:20 のまま）。
    static let noWaypoint = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"plain","namespace":"kubedeck-mesh-c","uid":"565fbba3-e6ff-42c7-8830-9769669d5f8a","generation":1},"spec":{"parentRefs":[{"group":"","kind":"Service","name":"plain","port":8080}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"plain-v1","port":8080,"weight":1}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"Route was valid","observedGeneration":1,"reason":"Accepted","status":"True","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All references resolved","observedGeneration":1,"reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"istio.io/use-waypoint label missing from parent and parent namespace; in ambient mode, route will not be respected","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"","kind":"Service","name":"plain","port":8080}}]}}
        """#)

    static let broken = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"broken","namespace":"kubedeck-mesh","uid":"37c145c2-07f8-4db3-8fe5-2c16fee2ab19","generation":1},"spec":{"parentRefs":[{"group":"","kind":"Service","name":"broken","port":8080}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"web-v1","port":8080,"weight":50},{"group":"","kind":"Service","name":"nosuch","port":8080,"weight":50}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"Route was valid","observedGeneration":1,"reason":"Accepted","status":"True","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"backend(nosuch.kubedeck-mesh.svc.cluster.local) not found","observedGeneration":1,"reason":"BackendNotFound","status":"False","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All waypoints resolved","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"","kind":"Service","name":"broken","port":8080}}]}}
        """#)

    static let crossNamespace = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"crossns","namespace":"kubedeck-mesh","uid":"bd0ea350-4756-4426-9046-6162d8b3a541","generation":1},"spec":{"parentRefs":[{"group":"","kind":"Service","name":"crossns","port":8080}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"web-v1","port":8080,"weight":50},{"group":"","kind":"Service","name":"other","namespace":"kubedeck-mesh-b","port":8080,"weight":50}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"Route was valid","observedGeneration":1,"reason":"Accepted","status":"True","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All references resolved","observedGeneration":1,"reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All waypoints resolved","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"","kind":"Service","name":"crossns","port":8080}}]}}
        """#)

    static let canary = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"canary","namespace":"kubedeck-mesh","uid":"fe16353e-2fcb-494f-8b22-9b4fc3f61e6d","generation":1},"spec":{"parentRefs":[{"group":"","kind":"Service","name":"canary","port":8080}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"web-v2","port":8080,"weight":1}],"matches":[{"headers":[{"name":"x-canary","type":"Exact","value":"true"}],"path":{"type":"PathPrefix","value":"/"}}]},{"filters":[{"requestRedirect":{"path":{"replacePrefixMatch":"/new","type":"ReplacePrefixMatch"},"statusCode":302},"type":"RequestRedirect"}],"matches":[{"path":{"type":"PathPrefix","value":"/old"}}]},{"backendRefs":[{"group":"","kind":"Service","name":"web-v1","port":8080,"weight":90},{"group":"","kind":"Service","name":"web-v2","port":8080,"weight":10}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"Route was valid","observedGeneration":1,"reason":"Accepted","status":"True","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All references resolved","observedGeneration":1,"reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All waypoints resolved","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"","kind":"Service","name":"canary","port":8080}}]}}
        """#)

    static let edgeMismatch = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"edge-mismatch","namespace":"kubedeck-mesh","uid":"3fb15d1d-29ed-4e8e-9113-7d768ae9467f","generation":1},"spec":{"hostnames":["foo.other.test"],"parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge"}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"web-v1","port":8080,"weight":1}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"no hostnames matched parent hostname \"*.example.com\"","observedGeneration":1,"reason":"NoMatchingListenerHostname","status":"False","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All references resolved","observedGeneration":1,"reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All waypoints resolved","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge"}}]}}
        """#)

    static let edgeFromOtherNamespace = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"edge-from-b","namespace":"kubedeck-mesh-b","uid":"d87447b6-e4fb-4b59-9c34-47e3597381a9","generation":1},"spec":{"hostnames":["b.example.com"],"parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge","namespace":"kubedeck-mesh"}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"other","port":8080,"weight":1}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"hostnames matched parent hostname \"*.example.com\", but namespace \"kubedeck-mesh-b\" is not allowed by the parent","observedGeneration":1,"reason":"NotAllowedByListeners","status":"False","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All references resolved","observedGeneration":1,"reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All waypoints resolved","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"edge","namespace":"kubedeck-mesh"}}]}}
        """#)

    static let ghostGateway = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"ghost-gateway","namespace":"kubedeck-mesh","uid":"7f1a84b4-4345-4eb6-ae24-098ef6deb25f","generation":1},"spec":{"parentRefs":[{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"ghost"}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"web-v1","port":8080,"weight":1}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[]}}
        """#)

    static let ghostService = object(#"""
        {"apiVersion":"gateway.networking.k8s.io/v1","kind":"HTTPRoute","metadata":{"name":"ghost-service","namespace":"kubedeck-mesh","uid":"cde45968-4c69-435d-b1bf-e09c4e631b01","generation":1},"spec":{"parentRefs":[{"group":"","kind":"Service","name":"nosuchsvc","port":8080}],"rules":[{"backendRefs":[{"group":"","kind":"Service","name":"web-v1","port":8080,"weight":1}],"matches":[{"path":{"type":"PathPrefix","value":"/"}}]}]},"status":{"parents":[{"conditions":[{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"parent service: \"nosuchsvc\" not found","observedGeneration":1,"reason":"NoMatchingParent","status":"False","type":"Accepted"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"All references resolved","observedGeneration":1,"reason":"ResolvedRefs","status":"True","type":"ResolvedRefs"},{"lastTransitionTime":"2026-11-25T03:06:43Z","message":"parent not found","observedGeneration":1,"reason":"ResolvedWaypoints","status":"True","type":"ResolvedWaypoints"}],"controllerName":"istio.io/gateway-controller","parentRef":{"group":"","kind":"Service","name":"nosuchsvc","port":8080}}]}}
        """#)
}
