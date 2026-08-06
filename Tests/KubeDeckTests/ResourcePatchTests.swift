import Testing
@testable import KubeDeck

/// requests / limits の書き換え。
///
/// **ここは「0」と「未設定」を取り違えると黙って壊れる。** 外したつもりが
/// `cpu: "0"` として書き込まれると、一覧では「設定済み」に見えるのに
/// スケジューラの扱いはまるで違う。patch の形を固めておく。
@Suite("資源の割り当ての書き換え")
struct ResourcePatchTests {

    private func deployment(
        containers: String = """
            [{"name":"web","resources":{"requests":{"cpu":"100m","memory":"128Mi"},
              "limits":{"cpu":"200m","memory":"256Mi"}}}]
            """,
        initContainers: String = "[]"
    ) -> K8sObject {
        Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"web","namespace":"default"},
             "spec":{"template":{"spec":{"containers":\(containers),
              "initContainers":\(initContainers)}}}}
            """)
    }

    // MARK: - 効く種別

    /// **押せば失敗すると分かっているものを出さない。** Job の
    /// `spec.template` は immutable（実測）、ReplicaSet は直しても Deployment の
    /// 世代が優先され、Pod は作り直せば消える。
    @Test("Pod テンプレートを持ち、変えられる種別だけ")
    func supportedKinds() {
        #expect(ResourcePatch.supports(.deployment))
        #expect(ResourcePatch.supports(.statefulSet))
        #expect(ResourcePatch.supports(.daemonSet))
        #expect(ResourcePatch.supports(.cronJob))
        #expect(!ResourcePatch.supports(.job))
        #expect(!ResourcePatch.supports(.replicaSet))
        #expect(!ResourcePatch.supports(.pod))
        #expect(!ResourcePatch.supports(nil))
    }

    /// CronJob だけテンプレートの場所が 1 段深い。
    @Test("CronJob の patch は jobTemplate の下に入る")
    func cronJobPath() {
        let cronJob = Fixture.object(
            """
            {"kind":"CronJob","metadata":{"name":"cj","namespace":"default"},
             "spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":
              [{"name":"cj"}]}}}}}}
            """)
        let containers = ResourcePatch.containers(of: cronJob)
        #expect(containers.map(\.name) == ["cj"])

        let changes = ResourcePatch.changes(
            from: containers[0], cpuRequest: "50m", memoryRequest: "",
            cpuLimit: "", memoryLimit: "")
        let patch = ResourcePatch.patch(
            kind: .cronJob, container: containers[0], changes: changes)
        #expect(patch == """
            {"spec":{"jobTemplate":{"spec":{"template":{"spec":{"containers":\
            [{"name":"cj","resources":{"requests":{"cpu":"50m"}}}]}}}}}}
            """)
    }

    // MARK: - いまの値

    @Test("設定されていない項目は nil（空文字にしない）")
    func missingValuesAreNil() {
        let object = deployment(containers: """
            [{"name":"web","resources":{"requests":{"cpu":"100m"}}}]
            """)
        let container = ResourcePatch.containers(of: object)[0]
        #expect(container.cpuRequest == "100m")
        #expect(container.memoryRequest == nil)
        #expect(container.cpuLimit == nil)
        #expect(container.memoryLimit == nil)
    }

    /// **初期化コンテナも出す。** 設定を取りに行くのが init の仕事、という
    /// 作りはふつうにあり、そこにも上限は要る。
    @Test("初期化コンテナも並ぶ。ただし別のものとして扱う")
    func initContainers() {
        let object = deployment(initContainers: """
            [{"name":"setup","resources":{"limits":{"cpu":"50m"}}}]
            """)
        let containers = ResourcePatch.containers(of: object)
        #expect(containers.map(\.name) == ["web", "setup"])
        #expect(containers[1].isInit)
        // patch の当たる先が違う。
        let changes = ResourcePatch.changes(
            from: containers[1], cpuRequest: "", memoryRequest: "",
            cpuLimit: "80m", memoryLimit: "")
        let patch = ResourcePatch.patch(
            kind: .deployment, container: containers[1], changes: changes)
        #expect(patch?.contains("\"initContainers\"") == true)
        #expect(patch?.contains("\"containers\"") == false)
    }

    // MARK: - 差分

    @Test("変えていない項目は patch に入れない")
    func unchangedFieldsAreOmitted() {
        let container = ResourcePatch.containers(of: deployment())[0]
        let changes = ResourcePatch.changes(
            from: container, cpuRequest: "100m", memoryRequest: "128Mi",
            cpuLimit: "500m", memoryLimit: "256Mi")
        #expect(changes.map(\.field) == [.cpuLimit])

        let patch = ResourcePatch.patch(
            kind: .deployment, container: container, changes: changes)
        #expect(patch == """
            {"spec":{"template":{"spec":{"containers":\
            [{"name":"web","resources":{"limits":{"cpu":"500m"}}}]}}}}
            """)
    }

    @Test("前後の空白で「変わった」ことにしない")
    func whitespaceIsNotAChange() {
        let container = ResourcePatch.containers(of: deployment())[0]
        let changes = ResourcePatch.changes(
            from: container, cpuRequest: " 100m ", memoryRequest: "128Mi",
            cpuLimit: "200m", memoryLimit: "256Mi")
        #expect(changes.isEmpty)
        #expect(ResourcePatch.patch(
            kind: .deployment, container: container, changes: changes) == nil)
    }

    /// **外すのは `null`。** `kubectl set resources` では外せず（`--limits=cpu=0`
    /// は「0 という上限」を書き込む・実測）、0 と未設定はこのアプリでは
    /// はっきり別のもの。
    @Test("空にしたら null を送る（0 を送らない）")
    func clearingSendsNull() {
        let container = ResourcePatch.containers(of: deployment())[0]
        let changes = ResourcePatch.changes(
            from: container, cpuRequest: "100m", memoryRequest: "128Mi",
            cpuLimit: "", memoryLimit: "256Mi")
        #expect(changes == [
            ResourcePatch.Change(field: .cpuLimit, before: "200m", after: nil)
        ])

        let patch = ResourcePatch.patch(
            kind: .deployment, container: container, changes: changes)
        #expect(patch?.contains("\"cpu\":null") == true)
        #expect(patch?.contains("\"0\"") == false)
    }

    @Test("要求と上限を同時に変えると、両方が 1 つの patch に入る")
    func requestsAndLimitsTogether() {
        let container = ResourcePatch.containers(of: deployment())[0]
        let changes = ResourcePatch.changes(
            from: container, cpuRequest: "150m", memoryRequest: "128Mi",
            cpuLimit: "300m", memoryLimit: "256Mi")
        let patch = ResourcePatch.patch(
            kind: .deployment, container: container, changes: changes)
        #expect(patch == """
            {"spec":{"template":{"spec":{"containers":\
            [{"name":"web","resources":{"limits":{"cpu":"300m"},\
            "requests":{"cpu":"150m"}}}]}}}}
            """)
    }

    // MARK: - 文言

    /// **「変更あり」で済ませない。** 何がどうなるかを書く。
    @Test("変更の説明に、未設定への出入りが出る")
    func changeSummaries() {
        #expect(ResourcePatch.Change(field: .cpuLimit, before: "200m", after: "500m")
            .summary == "CPU 上限: 200m → 500m")
        #expect(ResourcePatch.Change(field: .memoryRequest, before: nil, after: "128Mi")
            .summary == "メモリ 要求: 未設定 → 128Mi")
        #expect(ResourcePatch.Change(field: .memoryLimit, before: "256Mi", after: nil)
            .summary == "メモリ 上限: 256Mi → 未設定にする")
    }
}
