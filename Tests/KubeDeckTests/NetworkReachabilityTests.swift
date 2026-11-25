import Testing
@testable import KubeDeck

/// NetworkPolicy は**許可の和集合**で、**送る側の出口と受ける側の入口の両方**が
/// 許して初めて通る。どちらかを取り違えると「通る」と嘘を描く。
@Suite("NetworkPolicy の到達判定")
struct NetworkReachabilityTests {

    // MARK: - 材料

    private static let tcp = "TCP"

    private func pod(
        _ name: String, namespace: String = "default", labels: [String: String],
        ports: String = "[]", ip: String? = nil
    ) -> K8sObject {
        Fixture.pod(
            name: name, namespace: namespace, labels: labels,
            containers: #"[{"name":"app","ports":\#(ports)}]"#, podIP: ip)
    }

    private func policy(_ name: String, namespace: String = "default", _ spec: String) -> K8sObject {
        Fixture.networkPolicy(name: name, namespace: namespace, spec: spec)
    }

    /// 既定は、Pod のいる Namespace をラベル無しで「読めた」ことにする。
    private func inventory(
        _ pods: [K8sObject], _ policies: [K8sObject], scope: String? = nil,
        namespaces: [String: [String: String]]?? = .some(nil)
    ) -> NetworkInventory {
        let labels: [String: [String: String]]?
        switch namespaces {
        case .some(.some(let given)): labels = given
        case .some(.none):
            labels = Dictionary(uniqueKeysWithValues:
                Set(pods.compactMap(\.namespace)).map { ($0, [String: String]()) })
        case .none: labels = nil
        }
        return NetworkInventory(pods: pods, policies: policies, scope: scope, namespaceLabels: labels)
    }

    private func outcome(
        _ source: K8sObject, _ destination: K8sObject, _ inventory: NetworkInventory
    ) -> ConnectionVerdict.Outcome {
        NetworkReachability.connection(from: source, to: destination, in: inventory).outcome
    }

    // MARK: - ラベルセレクタ

    /// `NotIn` は「そのキーを持たない」も含む。`In` の否定ではない。
    @Test("NotIn はキーを持たない Pod にも当たる")
    func notInMatchesMissingKey() {
        let selector = LabelSelector(requirements: [.init(key: "env", op: "NotIn", values: ["prod"])])
        #expect(selector.evaluate([:]) == true)
        #expect(selector.evaluate(["env": "dev"]) == true)
        #expect(selector.evaluate(["env": "prod"]) == false)
    }

    @Test("In / Exists / DoesNotExist と matchLabels は AND で効く")
    func expressionsAreConjunctive() {
        let selector = LabelSelector(
            matchLabels: ["app": "web"],
            requirements: [
                .init(key: "tier", op: "In", values: ["front", "edge"]),
                .init(key: "canary", op: "DoesNotExist", values: []),
                .init(key: "team", op: "Exists", values: []),
            ])
        #expect(selector.evaluate(["app": "web", "tier": "edge", "team": "a"]) == true)
        #expect(selector.evaluate(["app": "web", "tier": "edge"]) == false)
        #expect(selector.evaluate(["app": "web", "tier": "edge", "team": "a", "canary": "1"]) == false)
        #expect(selector.evaluate(["app": "api", "tier": "edge", "team": "a"]) == false)
        #expect(LabelSelector().evaluate(["any": "thing"]) == true)
    }

    /// **知らないことを「当たらない」にしない。** そう書くと、効いている設定を消す。
    @Test("知らない演算子と、分からないキーでは決めない")
    func undeterminedInsteadOfFalse() {
        let unknownOp = LabelSelector(requirements: [.init(key: "a", op: "Gt", values: ["1"])])
        #expect(unknownOp.evaluate(["a": "2"]) == nil)

        let partial = LabelSelector(matchLabels: ["team": "ops"])
        #expect(partial.evaluate(["kubernetes.io/metadata.name": "x"], complete: false) == nil)
        // 分かっているキーで外れるなら、分からないキーがあっても外れる。
        let both = LabelSelector(matchLabels: ["kubernetes.io/metadata.name": "y", "team": "ops"])
        #expect(both.evaluate(["kubernetes.io/metadata.name": "x"], complete: false) == false)
    }

    // MARK: - 片側ずつ

    @Test("どの policy にも選ばれていなければ、すべてのポートで通る")
    func noPolicyMeansOpen() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        #expect(outcome(web, db, inventory([web, db], [])) == .allowed(.all))
    }

    /// `ingress` を書かない（規則ゼロ）は「未設定」ではなく**すべて拒否**。
    @Test("規則の無い Ingress の policy は、入口をすべて閉じる。出口は閉じない")
    func denyAllIngress() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        let deny = policy("deny-all", #"{"podSelector":{},"policyTypes":["Ingress"]}"#)
        let inv = inventory([web, db], [deny])

        #expect(outcome(web, db, inv) == .blocked([.ingress]))
        let verdict = NetworkReachability.connection(from: web, to: db, in: inv)
        #expect(verdict.egress == .unrestricted)
    }

    /// `from` を書かない規則は**どこからでも**。いちばん緩い。
    @Test("相手の指定が無い規則は、どこからでも通す")
    func ruleWithoutPeersAllowsAll() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        let open = policy("db", #"{"podSelector":{"matchLabels":{"app":"db"}},"ingress":[{}]}"#)
        #expect(outcome(web, db, inventory([web, db], [open])) == .allowed(.all))
    }

    /// 受ける側の policy だけを見ると「通る」と描いてしまう。
    @Test("受ける側が許しても、送る側の出口で止まる")
    func bothSidesMustAllow() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"web"}}}]}]}
            """)
        let egressDeny = policy("web-egress", """
            {"podSelector":{"matchLabels":{"app":"web"}},"policyTypes":["Egress"]}
            """)
        let verdict = NetworkReachability.connection(
            from: web, to: db, in: inventory([web, db], [allow, egressDeny]))

        #expect(verdict.outcome == .blocked([.egress]))
        #expect(verdict.ingress == .allowed(policies: ["default/db"], ports: .all))
    }

    @Test("複数の policy は和集合で効く")
    func policiesUnion() {
        let web = pod("web", labels: ["app": "web"])
        let api = pod("api", labels: ["app": "api"])
        let db = pod("db", labels: ["app": "db"])
        let fromWeb = policy("from-web", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"web"}}}]}]}
            """)
        let fromAPI = policy("from-api", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"api"}}}]}]}
            """)
        let inv = inventory([web, api, db], [fromWeb, fromAPI])
        #expect(outcome(web, db, inv) == .allowed(.all))
        #expect(outcome(api, db, inv) == .allowed(.all))
    }

    // MARK: - 相手の解き方

    /// Namespace が違えば、同じラベルでも別物。
    @Test("podSelector だけの相手は、policy の Namespace の中に限る")
    func podSelectorStaysInNamespace() {
        let local = pod("web", labels: ["app": "web"])
        let foreign = pod("web", namespace: "other", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"web"}}}]}]}
            """)
        let inv = inventory([local, foreign, db], [allow])
        #expect(outcome(local, db, inv) == .allowed(.all))
        #expect(outcome(foreign, db, inv) == .blocked([.ingress]))
    }

    /// **YAML の `-` 1 つで意味が変わる**、いちばん読み違えやすいところ。
    @Test("1 つの相手に書いた 2 つのセレクタは AND、分けて書くと OR")
    func peerSelectorsAndVersusOr() {
        let prom = pod("prom", namespace: "monitoring", labels: ["app": "prom"])
        let other = pod("other", namespace: "monitoring", labels: ["app": "other"])
        let localProm = pod("prom", labels: ["app": "prom"])
        let db = pod("db", labels: ["app": "db"])
        let pods = [prom, other, localProm, db]
        let namespaces = ["monitoring": ["team": "ops"], "default": [:]]

        let and = policy("and", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"team":"ops"}},
                                  "podSelector":{"matchLabels":{"app":"prom"}}}]}]}
            """)
        let andInv = inventory(pods, [and], namespaces: namespaces)
        #expect(outcome(prom, db, andInv) == .allowed(.all))
        #expect(outcome(other, db, andInv) == .blocked([.ingress]))
        #expect(outcome(localProm, db, andInv) == .blocked([.ingress]))

        let or = policy("or", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"team":"ops"}}},
                                 {"podSelector":{"matchLabels":{"app":"prom"}}}]}]}
            """)
        let orInv = inventory(pods, [or], namespaces: namespaces)
        #expect(outcome(prom, db, orInv) == .allowed(.all))
        #expect(outcome(other, db, orInv) == .allowed(.all))
        #expect(outcome(localProm, db, orInv) == .allowed(.all))
    }

    /// Namespace を list できない権限はふつうにある。名前だけは自動ラベルで分かる。
    @Test("Namespace が読めなくても、名前の自動ラベルなら決まる。他のラベルでは決めない")
    func namespaceLabelsUnreadable() {
        let prom = pod("prom", namespace: "monitoring", labels: ["app": "prom"])
        let db = pod("db", labels: ["app": "db"])
        let byName = policy("by-name", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"namespaceSelector":{"matchLabels":
                {"kubernetes.io/metadata.name":"monitoring"}}}]}]}
            """)
        let byTeam = policy("by-team", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"team":"ops"}}}]}]}
            """)

        #expect(outcome(prom, db, inventory([prom, db], [byName], namespaces: .none)) == .allowed(.all))
        #expect(outcome(prom, db, inventory([prom, db], [byTeam], namespaces: .none)) == .undetermined)
    }

    /// Pod の IP に ipBlock を当てるかは CNI 次第。範囲内を「通る」とも「止まる」とも書かない。
    @Test("ipBlock は範囲外の Pod には当たらず、範囲内なら決めない")
    func ipBlockAgainstPods() {
        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"ipBlock":{"cidr":"10.0.0.0/8","except":["10.1.0.0/16"]}}]}]}
            """)
        func from(_ ip: String) -> ConnectionVerdict.Outcome {
            let source = pod("src", labels: ["app": "src"], ip: ip)
            return outcome(source, db, inventory([source, db], [allow]))
        }
        #expect(from("192.168.1.5") == .blocked([.ingress]))
        #expect(from("10.1.2.3") == .blocked([.ingress]))
        #expect(from("10.2.3.4") == .undetermined)
        #expect(CIDR.contains("fd00::/8", "fd00::1") == true)
        #expect(CIDR.contains("fd00::/8", "fe80::1") == false)
    }

    /// 空の cidr は API の検証を通らないが、壊れた応答で落ちない。読めないなら決めない。
    @Test("読めない cidr では決めず、落ちない")
    func malformedCIDR() {
        #expect(CIDR.contains("", "10.0.0.1") == nil)
        #expect(CIDR.contains("not-a-cidr", "10.0.0.1") == nil)

        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"ipBlock":{"cidr":"10.0.0.0/8","except":[""]}}]}]}
            """)
        let source = pod("src", labels: ["app": "src"], ip: "10.2.3.4")
        #expect(outcome(source, db, inventory([source, db], [allow])) == .undetermined)
    }

    /// dual-stack の Pod は `podIP` に片方の系しか持たない。もう片方を見ずに「当たらない」にしない。
    @Test("ipBlock は status.podIPs のすべてで当てる")
    func ipBlockDualStack() {
        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"ipBlock":{"cidr":"fd00:10::/64"}}]}]}
            """)
        let source = Fixture.object(#"""
            {"kind":"Pod","metadata":{"name":"src","namespace":"default","labels":{"app":"src"}},
             "spec":{"containers":[{"name":"app"}]},
             "status":{"phase":"Running","podIP":"10.0.0.5",
                       "podIPs":[{"ip":"10.0.0.5"},{"ip":"fd00:10::5"}]}}
            """#)
        #expect(outcome(source, db, inventory([source, db], [allow])) == .undetermined)
    }

    // MARK: - ポート

    @Test("名前付きのポートは宛先のコンテナで解き、無ければ当たらない")
    func namedPortResolvesOnDestination() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"], ports: #"[{"name":"pg","containerPort":5432}]"#)
        let bare = pod("db-bare", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},"ingress":[{"ports":[{"port":"pg"}]}]}
            """)
        let inv = inventory([web, db, bare], [allow])

        #expect(outcome(web, db, inv)
            == .allowed(.only([PortRange(proto: Self.tcp, lower: 5432, upper: 5432)])))
        #expect(outcome(web, bare, inv) == .blocked([.ingress]))
    }

    /// 両側とも「許可」なのに通らない。片側ずつ見ていると気付けない。
    @Test("両側が許すポートが重ならなければ止まる")
    func disjointPortsBlock() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        let egress = policy("web", """
            {"podSelector":{"matchLabels":{"app":"web"}},"policyTypes":["Egress"],
             "egress":[{"to":[{"podSelector":{"matchLabels":{"app":"db"}}}],"ports":[{"port":80}]}]}
            """)
        let ingress = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"web"}}}],
                         "ports":[{"port":5432}]}]}
            """)
        #expect(outcome(web, db, inventory([web, db], [egress, ingress])) == .blocked([.ports]))
    }

    /// 決まった規則のポートだけで「重ならない」と言うと、決まらない規則が許しているかもしれない
    /// ポートを捨てることになる。
    @Test("一部の規則が決まらないときは、ポートが重ならないと断定しない")
    func partialPortsStayUndetermined() {
        let api = pod("api", labels: ["app": "api"])
        let db = pod("db", labels: ["app": "db"])
        let ingress = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"api"}}}],
                         "ports":[{"port":5432}]},
                        {"from":[{"namespaceSelector":{"matchLabels":{"team":"platform"}}}]}]}
            """)
        let egress = policy("api", """
            {"podSelector":{"matchLabels":{"app":"api"}},"policyTypes":["Egress"],
             "egress":[{"to":[{"podSelector":{"matchLabels":{"app":"db"}}}],"ports":[{"port":6432}]}]}
            """)
        let unreadable = inventory([api, db], [ingress, egress], namespaces: .none)
        #expect(outcome(api, db, unreadable) == .undetermined)

        // 重なるポートがあれば、決まっているぶんは通ると言える。
        let overlapping = policy("api", """
            {"podSelector":{"matchLabels":{"app":"api"}},"policyTypes":["Egress"],
             "egress":[{"to":[{"podSelector":{"matchLabels":{"app":"db"}}}],"ports":[{"port":5432}]}]}
            """)
        #expect(outcome(api, db, inventory([api, db], [ingress, overlapping], namespaces: .none))
            == .allowed(.only([PortRange(proto: Self.tcp, lower: 5432, upper: 5432)])))
    }

    @Test("endPort は範囲として扱い、プロトコルは既定で TCP")
    func endPortRange() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"ports":[{"port":8000,"endPort":8100},{"protocol":"UDP","port":53}]}]}
            """)
        #expect(outcome(web, db, inventory([web, db], [allow])) == .allowed(.only([
            PortRange(proto: "TCP", lower: 8000, upper: 8100),
            PortRange(proto: "UDP", lower: 53, upper: 53),
        ])))
    }

    // MARK: - policyTypes の補い方

    /// API サーバは `len(egress) != 0` のときだけ Egress を足す。`egress: []` では足さない。
    @Test("policyTypes を省略したとき、egress: [] だけでは Egress を制限しない")
    func impliedPolicyTypes() {
        #expect(NetworkPolicySpec.policyTypes(of: Fixture.networkPolicy(
            name: "a", spec: #"{"podSelector":{},"egress":[]}"#).spec) == ["Ingress"])
        #expect(NetworkPolicySpec.policyTypes(of: Fixture.networkPolicy(
            name: "b", spec: #"{"podSelector":{},"egress":[{}]}"#).spec) == ["Ingress", "Egress"])
        #expect(NetworkPolicySpec.policyTypes(of: Fixture.networkPolicy(
            name: "c", spec: #"{"podSelector":{},"policyTypes":["Egress"]}"#).spec) == ["Egress"])
    }

    // MARK: - 起点から見た一覧

    @Test("制限されていなければ、許可の一覧を作らない")
    func summaryUnrestricted() {
        let db = pod("db", labels: ["app": "db"])
        let summary = NetworkReachability.summary(.ingress, of: [db], in: inventory([db], []))
        #expect(summary.isUnrestricted)
        #expect(summary.grants.isEmpty)
        #expect(summary.unrestrictedCount == 1)
    }

    /// 「なぜ繋がらないか」はここで出る。受ける側が許しているのに相手の出口で止まる。
    @Test("当たった Pod を束ね、相手側の出口で止まるものを書き分ける")
    func summaryGroupsPeers() {
        let db0 = pod("db-0", labels: ["app": "db"])
        let db1 = pod("db-1", labels: ["app": "db"])
        let webA = pod("web-a", labels: ["app": "web"])
        let webB = pod("web-b", labels: ["app": "web"])
        let api = pod("api-0", labels: ["app": "api"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchExpressions":
                [{"key":"app","operator":"In","values":["web","api"]}]}}]}]}
            """)
        let webEgress = policy("web-egress", """
            {"podSelector":{"matchLabels":{"app":"web"}},"policyTypes":["Egress"]}
            """)
        let summary = NetworkReachability.summary(
            .ingress, of: [db0, db1],
            in: inventory([db0, db1, webA, webB, api], [allow, webEgress]),
            groupKey: { $0.labels["app"] ?? "" })

        #expect(summary.restrictingPolicies == ["default/db"])
        #expect(summary.unrestrictedCount == 0)
        let groups = summary.grants.flatMap(\.groups)
        #expect(groups.map(\.key) == ["api", "web"])
        #expect(groups.first { $0.key == "api" }?.outcome == .allowed)
        #expect(groups.first { $0.key == "web" }?.outcome == .blocked([.egress]))
        #expect(groups.first { $0.key == "web" }?.pods.count == 2)
    }

    /// 通る組が 1 つも無いのに「通るものと止まるものがある」と言わない。
    @Test("止まる組と決まらない組だけなら、Pod によって違うとは言わない")
    func mixedNeedsAllowedAndBlocked() {
        let db0 = pod("db-0", labels: ["app": "db"], ip: "10.0.1.5")
        let db1 = pod("db-1", labels: ["app": "db"], ip: "10.1.0.7")
        let web = pod("web", labels: ["app": "web"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"web"}}}]}]}
            """)
        let webEgress = policy("web", """
            {"podSelector":{"matchLabels":{"app":"web"}},"policyTypes":["Egress"],
             "egress":[{"to":[{"ipBlock":{"cidr":"10.0.0.0/16"}}]}]}
            """)
        let summary = NetworkReachability.summary(
            .ingress, of: [db0, db1], in: inventory([db0, db1, web], [allow, webEgress]),
            groupKey: { $0.labels["app"] ?? "" })
        #expect(summary.grants.flatMap(\.groups).first { $0.key == "web" }?.outcome == .undetermined)
    }

    @Test("相手の指定が無い規則は、Pod を並べずに 1 行にする")
    func summaryAnywhere() {
        let db = pod("db", labels: ["app": "db"])
        let web = pod("web", labels: ["app": "web"])
        let open = policy("db", #"{"podSelector":{"matchLabels":{"app":"db"}},"ingress":[{}]}"#)
        let summary = NetworkReachability.summary(.ingress, of: [db], in: inventory([db, web], [open]))
        #expect(summary.grants.count == 1)
        #expect(summary.grants.first?.peer == nil)
        #expect(summary.grants.first?.groups.isEmpty == true)
    }

    /// 絞って取得しているとき、他の Namespace の Pod と policy は手元に無い。
    @Test("取得していない Namespace は、当たることだけを名前で挙げる")
    func summaryOutOfScope() {
        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"team":"ops"}}}]}]}
            """)
        let summary = NetworkReachability.summary(
            .ingress, of: [db],
            in: inventory([db], [allow], scope: "default",
                          namespaces: ["default": [:], "monitoring": ["team": "ops"]]))
        #expect(summary.grants.first?.outOfScopeNamespaces == ["monitoring"])
        #expect(summary.grants.first?.gaps.isEmpty == true)
    }

    @Test("Namespace が読めないときは、挙げきれないと断る")
    func summaryNamespacesUnreadable() {
        let db = pod("db", labels: ["app": "db"])
        let allow = policy("db", """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"team":"ops"}}}]}]}
            """)
        let summary = NetworkReachability.summary(
            .ingress, of: [db], in: inventory([db], [allow], scope: "default", namespaces: .none))
        let gaps = summary.grants.first?.gaps ?? []
        #expect(gaps.contains(.namespacesUnreadable))
        #expect(gaps.contains(.undeterminedNamespaces(["default"])))
    }

    @Test("出口の向きでも同じように解く")
    func summaryEgress() {
        let web = pod("web", labels: ["app": "web"])
        let db = pod("db", labels: ["app": "db"])
        let cache = pod("cache", labels: ["app": "cache"])
        let egress = policy("web", """
            {"podSelector":{"matchLabels":{"app":"web"}},"policyTypes":["Egress"],
             "egress":[{"to":[{"podSelector":{}}]}]}
            """)
        let cacheDeny = policy("cache", #"{"podSelector":{"matchLabels":{"app":"cache"}}}"#)
        let summary = NetworkReachability.summary(
            .egress, of: [web], in: inventory([web, db, cache], [egress, cacheDeny]),
            groupKey: { $0.labels["app"] ?? "" })
        let groups = summary.grants.flatMap(\.groups)
        #expect(groups.map(\.key) == ["cache", "db"])
        #expect(groups.first { $0.key == "cache" }?.outcome == .blocked([.ingress]))
        #expect(groups.first { $0.key == "db" }?.outcome == .allowed)
    }
}

/// 判定を図の行に畳むところ。行が重なったり消えたりすると、図が別の話になる。
@Suite("たどるの通信の段")
struct TraceNetworkTests {
    private func pod(_ name: String, app: String, owner: String? = nil, namespace: String = "default") -> K8sObject {
        Fixture.pod(
            name: name, namespace: namespace, labels: ["app": app],
            owner: owner.map { (kind: "StatefulSet", name: $0) })
    }

    private func network(
        anchor: [K8sObject], pods: [K8sObject], policies: [K8sObject], scope: String? = nil,
        namespaces: [String: [String: String]]? = ["default": [:]]
    ) -> TraceNetwork {
        PlacementTrace.network(
            for: anchor, inventory: PlacementInventory(pods: pods, related: policies),
            controllers: [:], scope: scope, namespaceLabels: namespaces)
    }

    @Test("どちらの向きも制限が無ければ、1 行だけ")
    func unrestrictedIsOneRow() {
        let db = pod("db-0", app: "db")
        let result = network(anchor: [db], pods: [db], policies: [])
        #expect(result.ingress.rows.map(\.id) == ["unrestricted"])
        #expect(result.egress.rows.map(\.id) == ["unrestricted"])
    }

    @Test("許可の規則が無ければ、すべて拒否と制限している policy を書く")
    func denyAllNamesPolicy() {
        let db = pod("db-0", app: "db")
        let deny = Fixture.networkPolicy(
            name: "lockdown", spec: #"{"podSelector":{},"policyTypes":["Ingress"]}"#)
        let rows = network(anchor: [db], pods: [db], policies: [deny]).ingress.rows
        #expect(rows.map(\.id) == ["deny"])
        #expect(rows.first?.policies == ["lockdown"])
    }

    /// 同じ相手が 2 つの policy から許されていても、行は 1 つ。止まるものを先に。
    @Test("同じ相手は 1 行にまとめ、止まるものを先に並べる")
    func mergesAndOrders() {
        let db = pod("db-0", app: "db", owner: "db")
        let api = pod("api-0", app: "api")
        let batch = pod("batch-0", app: "batch")
        let first = Fixture.networkPolicy(name: "a", spec: """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"api"}}},
                                 {"podSelector":{"matchLabels":{"app":"batch"}}}],
                         "ports":[{"port":6379}]}]}
            """)
        let second = Fixture.networkPolicy(name: "b", spec: """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"podSelector":{"matchLabels":{"app":"api"}}}],
                         "ports":[{"port":9121}]}]}
            """)
        let batchEgress = Fixture.networkPolicy(name: "batch", spec: """
            {"podSelector":{"matchLabels":{"app":"batch"}},"policyTypes":["Egress"]}
            """)
        let rows = network(
            anchor: [db], pods: [db, api, batch], policies: [first, second, batchEgress]
        ).ingress.rows

        #expect(rows.count == 2)
        guard case .workload(let blocked, .blocked, _) = rows[0].subject else {
            Issue.record("止まる相手が先に来ていない")
            return
        }
        #expect(blocked.name == "batch-0")
        #expect(rows[1].policies == ["a", "b"])
        #expect(rows[1].ports?.count == 2)
    }

    @Test("取得していない Namespace の行は、Pod の絞りも持つ")
    func outOfScopeKeepsPodSelector() {
        let db = pod("db-0", app: "db")
        let allow = Fixture.networkPolicy(name: "db", spec: """
            {"podSelector":{"matchLabels":{"app":"db"}},
             "ingress":[{"from":[{"namespaceSelector":{"matchLabels":{"team":"ops"}},
                                  "podSelector":{"matchLabels":{"app":"prom"}}}]}]}
            """)
        let rows = network(
            anchor: [db], pods: [db], policies: [allow], scope: "default",
            namespaces: ["default": [:], "ops": ["team": "ops"]]
        ).ingress.rows
        guard case .namespace(let name, let pods) = rows.first?.subject else {
            Issue.record("Namespace の行が無い")
            return
        }
        #expect(name == "ops")
        #expect(pods == "app=prom")
    }
}
