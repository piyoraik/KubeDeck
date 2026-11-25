import Testing
@testable import KubeDeck

/// 配置のチップは名前の末尾だけを出す。切り方を誤ると、**別の Pod が同じ名前で並ぶ**。
/// 棒の色は「上限に迫っているか」だけで決める。誤ると、迫っている Pod の色が黙って消える。
@Suite("配置の名前の切り出しと棒の色")
struct PlacementNamingTests {

    private func index(_ controllers: [K8sObject]) -> [String: K8sObject] {
        var result: [String: K8sObject] = [:]
        for object in controllers {
            guard let kind = object.kind else { continue }
            result["\(object.namespace ?? "")/\(kind.apiKind)/\(object.name)"] = object
        }
        return result
    }

    private func replicaSet(_ name: String, of deployment: String, namespace: String = "default")
        -> K8sObject
    {
        Fixture.controller(
            kind: "ReplicaSet", name: name, namespace: namespace,
            owner: (kind: "Deployment", name: deployment))
    }

    private func pod(_ name: String, replicaSet: String, namespace: String = "default")
        -> K8sObject
    {
        Fixture.pod(name: name, namespace: namespace, owner: (kind: "ReplicaSet", name: replicaSet))
    }

    // MARK: - Pod の名前

    @Test("世代が 1 つなら、ReplicaSet のハッシュも落として末尾だけにする")
    func singleGenerationDropsHash() {
        let pods = [pod("web-5576d4bc7c-4b2rt", replicaSet: "web-5576d4bc7c"),
                    pod("web-5576d4bc7c-vhvjh", replicaSet: "web-5576d4bc7c")]
        let labels = PlacementTrace.podSuffixes(
            for: pods, controllers: index([replicaSet("web-5576d4bc7c", of: "web")]))

        #expect(pods.map { labels[$0.id] } == ["4b2rt", "vhvjh"])
    }

    /// 末尾の 5 文字は世代の中でしか一意でない。入れ替わりの途中は 2 世代が並ぶ。
    @Test("世代が 2 つあるあいだは、ハッシュを残す")
    func twoGenerationsKeepHash() {
        let pods = [pod("web-5576d4bc7c-4b2rt", replicaSet: "web-5576d4bc7c"),
                    pod("web-7f9c6d5b8d-4b2rt", replicaSet: "web-7f9c6d5b8d")]
        let labels = PlacementTrace.podSuffixes(
            for: pods,
            controllers: index([
                replicaSet("web-5576d4bc7c", of: "web"), replicaSet("web-7f9c6d5b8d", of: "web"),
            ]))

        #expect(pods.map { labels[$0.id] } == ["5576d4bc7c-4b2rt", "7f9c6d5b8d-4b2rt"])
    }

    /// 束ねる鍵から Namespace を落とすと、別々の `web` が「2 世代」に見えてハッシュが残る。
    @Test("別の Namespace の同名のワークロードを、世代の数に混ぜない")
    func namespacesAreSeparate() {
        let pods = [pod("web-aaaaaaaaaa-11111", replicaSet: "web-aaaaaaaaaa", namespace: "one"),
                    pod("web-bbbbbbbbbb-22222", replicaSet: "web-bbbbbbbbbb", namespace: "two")]
        let labels = PlacementTrace.podSuffixes(
            for: pods,
            controllers: index([
                replicaSet("web-aaaaaaaaaa", of: "web", namespace: "one"),
                replicaSet("web-bbbbbbbbbb", of: "web", namespace: "two"),
            ]))

        #expect(pods.map { labels[$0.id] } == ["11111", "22222"])
    }

    @Test("kubelet が直に起こす Pod は、ノード名のほうを落とす")
    func staticPodsDropNodeName() {
        let pods = ["etcd-node-a", "kube-apiserver-node-a"].map {
            Fixture.pod(name: $0, namespace: "kube-system", owner: (kind: "Node", name: "node-a"))
        }
        let labels = PlacementTrace.podSuffixes(for: pods, controllers: [:])

        #expect(pods.map { labels[$0.id] } == ["etcd", "kube-apiserver"])
    }

    @Test("切ると読めなくなる名前・切れない名前は、そのまま出す")
    func keepsWhatCannotBeCut() {
        let ordinal = Fixture.pod(name: "cache-0", owner: (kind: "StatefulSet", name: "cache"))
        let daemon = Fixture.pod(name: "kindnet-44tbc", owner: (kind: "DaemonSet", name: "kindnet"))
        // 長い名前は API サーバが頭を詰めるので、所有者の名前で始まらないことがある。
        let clipped = Fixture.pod(name: "very-long-na-x7k2p", owner: (kind: "DaemonSet", name: "very-long-name"))
        let bare = Fixture.pod(name: "debug", owner: nil)
        let pods = [ordinal, daemon, clipped, bare]
        let labels = PlacementTrace.podSuffixes(for: pods, controllers: [:])

        #expect(pods.map { labels[$0.id] } == ["cache-0", "44tbc", "very-long-na-x7k2p", "debug"])
    }

    // MARK: - ノードの名前

    @Test("ノード名に共通する頭を、区切りまでで切る。省けないときは空")
    func sharedNodePrefix() {
        #expect(
            PlacementTrace.sharedNodePrefix([
                "kubedeck-demo-control-plane", "kubedeck-demo-worker", "kubedeck-demo-worker2",
            ]) == "kubedeck-demo-")
        #expect(PlacementTrace.sharedNodePrefix(["node-1", "node-10", "node-11"]) == "node-")
        // 区切りの無い共通部分は切らない（`worker` と `worker2` を `` と `2` にしない）。
        #expect(PlacementTrace.sharedNodePrefix(["worker", "worker2"]) == "")
        #expect(PlacementTrace.sharedNodePrefix(["a-1", "a-2"]) == "")
        #expect(PlacementTrace.sharedNodePrefix(["only-node"]) == "")
        #expect(PlacementTrace.sharedNodePrefix([]) == "")
    }

    // MARK: - 固まっている、と言ってよいか

    /// 直しようの無い警告が先頭に並ぶと、本当に固まっているものが埋もれる。
    @Test("散らす先が無いものは、1 ノードに固まっている扱いにしない")
    func canSpread() {
        #expect(PlacementTrace.canSpread(ownerKind: "Deployment", clusterNodeCount: 4))
        // kubelet が直に起こす Pod は、そのノードにしか居られない。
        #expect(!PlacementTrace.canSpread(ownerKind: "Node", clusterNodeCount: 4))
        #expect(!PlacementTrace.canSpread(ownerKind: "Deployment", clusterNodeCount: 1))
        // ノードの一覧を読めていないだけのときに、警告を消さない。
        #expect(PlacementTrace.canSpread(ownerKind: "Deployment", clusterNodeCount: 0))
    }

    // MARK: - 棒の色

    private func snapshot(_ name: String, cpu: Double, memory: Double) -> MetricsSnapshot {
        MetricsSnapshot(pods: [
            MetricsSnapshot.key(namespace: "default", name: name):
                ResourceUsage(cpuCores: cpu, memoryBytes: memory),
        ])
    }

    private func pod(
        _ name: String, cpuRequest: String? = nil, memoryRequest: String? = nil,
        cpuLimit: String? = nil, memoryLimit: String? = nil
    ) -> K8sObject {
        Fixture.pod(
            name: name,
            containers: "[\(Fixture.container(cpuRequest: cpuRequest, memoryRequest: memoryRequest, cpuLimit: cpuLimit, memoryLimit: memoryLimit))]")
    }

    /// 割合の大きいほうを選ぶだけだと、要求比 134% のメモリが、上限比 99% の CPU を隠す。
    @Test("上限に迫っている軸を、要求比の大きい軸で隠さない")
    func pressingLimitWins() throws {
        let target = pod("web-0", cpuRequest: "100m", memoryRequest: "50Mi", cpuLimit: "200m")
        let pressure = try #require(
            snapshot("web-0", cpu: 0.198, memory: 67 * 1024 * 1024)
                .pressure(of: target, metric: .both))

        #expect(pressure.isAgainstLimit)
        #expect(abs(pressure.ratio - 0.99) < 0.0001)
        #expect(pressure.level != nil)
    }

    /// 要求は置き場所を決めるための申告で、超えること自体は異常ではない。
    @Test("要求しか無い Pod は、要求を超えていても色を付けない")
    func requestOnlyIsNeverColored() throws {
        let target = pod("kindnet-0", cpuRequest: "100m", memoryRequest: "50Mi")
        let pressure = try #require(
            snapshot("kindnet-0", cpu: 0.001, memory: 67 * 1024 * 1024)
                .pressure(of: target, metric: .both))

        #expect(!pressure.isAgainstLimit)
        #expect(pressure.ratio > 1)
        #expect(pressure.level == nil)
    }

    @Test("出していない軸は見ない。使用量を引けていない Pod には棒を出さない")
    func respectsMetricAndMissingUsage() throws {
        let target = pod("web-0", cpuLimit: "200m", memoryLimit: "100Mi")
        let metrics = snapshot("web-0", cpu: 0.198, memory: 10 * 1024 * 1024)

        let memory = try #require(metrics.pressure(of: target, metric: .memory))
        #expect(abs(memory.ratio - 0.1) < 0.0001)
        #expect(MetricsSnapshot().pressure(of: target, metric: .both) == nil)
    }

    @Test("ワークロードの割合は、分母がすべて上限のときだけ色を付けられる")
    func workloadAxisAgainstLimit() {
        let limited = pod("web-0", cpuLimit: "200m")
        let requested = pod("web-1", cpuRequest: "100m")
        var pods: [String: ResourceUsage] = [:]
        for name in ["web-0", "web-1"] {
            pods[MetricsSnapshot.key(namespace: "default", name: name)] =
                ResourceUsage(cpuCores: 0.1, memoryBytes: 0)
        }
        let metrics = MetricsSnapshot(pods: pods)

        #expect(metrics.workloadUsage(of: [limited]).cpu.isAgainstLimit)
        #expect(!metrics.workloadUsage(of: [limited, requested]).cpu.isAgainstLimit)
        #expect(!metrics.workloadUsage(of: [requested]).cpu.isAgainstLimit)
    }
}
