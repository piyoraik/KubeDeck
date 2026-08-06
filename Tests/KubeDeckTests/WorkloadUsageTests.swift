import Testing
@testable import KubeDeck

/// ワークロード 1 つぶんの合計と割合。
///
/// ここで固めているのは「足し算が合っているか」ではなく、**混ぜてはいけない
/// ものを混ぜていないか**のほう。引けなかった Pod を 0 として数えないこと、
/// 分母を持たない Pod があるときに割合を出さないこと。
@Suite("ワークロード単位の使用率")
struct WorkloadUsageTests {
    /// `MetricsSnapshot` の鍵は `namespace/name`。
    private func snapshot(
        _ entries: [(name: String, cpu: Double, memory: Double)],
        namespace: String = "default"
    ) -> MetricsSnapshot {
        var pods: [String: ResourceUsage] = [:]
        for entry in entries {
            pods[MetricsSnapshot.key(namespace: namespace, name: entry.name)] =
                ResourceUsage(cpuCores: entry.cpu, memoryBytes: entry.memory)
        }
        return MetricsSnapshot(pods: pods)
    }

    private func pod(
        _ name: String, cpuRequest: String? = nil, memoryRequest: String? = nil,
        cpuLimit: String? = nil, memoryLimit: String? = nil,
        initContainer: String? = nil
    ) -> K8sObject {
        Fixture.pod(
            name: name,
            containers: "[\(Fixture.container(cpuRequest: cpuRequest, memoryRequest: memoryRequest, cpuLimit: cpuLimit, memoryLimit: memoryLimit))]",
            initContainers: initContainer.map { "[\($0)]" } ?? "[]")
    }

    @Test("Pod ぶんを足し上げ、上限を分母にする")
    func sumsPods() {
        let pods = [
            pod("web-0", cpuRequest: "100m", memoryRequest: "64Mi",
                cpuLimit: "500m", memoryLimit: "256Mi"),
            pod("web-1", cpuRequest: "100m", memoryRequest: "64Mi",
                cpuLimit: "500m", memoryLimit: "256Mi"),
        ]
        let usage = snapshot([
            (name: "web-0", cpu: 0.1, memory: 100 * 1024 * 1024),
            (name: "web-1", cpu: 0.3, memory: 156 * 1024 * 1024),
        ]).workloadUsage(of: pods)

        #expect(usage.podCount == 2)
        #expect(usage.measuredPods == 2)
        #expect(!usage.isPartial)
        #expect(abs(usage.cpu.used - 0.4) < 0.0001)
        #expect(abs(usage.cpu.base - 1.0) < 0.0001)
        #expect(usage.cpu.baseLabel == "上限")
        // 0.4 / 1.0
        #expect(abs((usage.cpu.ratio ?? 0) - 0.4) < 0.0001)
        #expect(abs((usage.memory.ratio ?? 0) - 0.5) < 0.0001)
    }

    /// **引けなかった Pod を 0 として数えない。** 分子にも分母にも入れず、
    /// 「何個ぶんの合計なのか」を持ち回る。
    @Test("使用量を引けない Pod は分子にも分母にも入れない")
    func skipsUnmeasuredPods() {
        let pods = [
            pod("web-0", cpuRequest: "100m", cpuLimit: "500m"),
            pod("web-1", cpuRequest: "100m", cpuLimit: "500m"),
        ]
        let usage = snapshot([(name: "web-0", cpu: 0.25, memory: 0)])
            .workloadUsage(of: pods)

        #expect(usage.podCount == 2)
        #expect(usage.measuredPods == 1)
        #expect(usage.isPartial)
        #expect(abs(usage.cpu.used - 0.25) < 0.0001)
        // 分母も引けた 1 個ぶんだけ。2 個ぶんにすると割合が半分に出る。
        #expect(abs(usage.cpu.base - 0.5) < 0.0001)
        #expect(abs((usage.cpu.ratio ?? 0) - 0.5) < 0.0001)
    }

    @Test("1 つも引けなければ、割合どころか合計も出さない")
    func nothingMeasured() {
        let usage = MetricsSnapshot()
            .workloadUsage(of: [pod("web-0", cpuLimit: "500m")])
        #expect(!usage.isMeasured)
        #expect(usage.cpu.ratio == nil)
    }

    /// **分母を持たない Pod が混ざったら割合を出さない。** そのぶん分母が
    /// 小さいので、割合は必ず高いほうへ外れる（余裕があるのに赤く見える）。
    @Test("上限も要求も無い Pod が混ざると割合を出さない")
    func withoutBase() {
        let pods = [
            pod("web-0", cpuRequest: "100m", cpuLimit: "500m"),
            pod("web-1"),
        ]
        let usage = snapshot([
            (name: "web-0", cpu: 0.25, memory: 0),
            (name: "web-1", cpu: 0.25, memory: 0),
        ]).workloadUsage(of: pods)

        #expect(usage.cpu.podsWithoutBase == 1)
        #expect(usage.cpu.ratio == nil)
        // 合計そのものは出せる。割合だけを諦める。
        #expect(abs(usage.cpu.used - 0.5) < 0.0001)
        #expect(usage.measuredPods == 2)
    }

    /// 上限が無い Pod は要求に落とす（Pod 単体・一覧・詳細と同じ順序）。
    /// **落ちたことを黙らない** — 分母の呼び名で分かるようにする。
    @Test("上限が無ければ要求に落とし、混ざったら混ざったと書く")
    func fallsBackToRequests() {
        let pods = [
            pod("web-0", cpuRequest: "100m", cpuLimit: "500m"),
            pod("web-1", cpuRequest: "200m"),
        ]
        let usage = snapshot([
            (name: "web-0", cpu: 0.1, memory: 0),
            (name: "web-1", cpu: 0.1, memory: 0),
        ]).workloadUsage(of: pods)

        #expect(usage.cpu.limitPods == 1)
        #expect(usage.cpu.requestPods == 1)
        #expect(usage.cpu.baseLabel == "上限・要求")
        #expect(abs(usage.cpu.base - 0.7) < 0.0001)

        let onlyRequests = snapshot([(name: "web-1", cpu: 0.1, memory: 0)])
            .workloadUsage(of: [pods[1]])
        #expect(onlyRequests.cpu.baseLabel == "要求")
    }

    /// **軸ごとに別に見る。** メモリにだけ上限があって CPU には無い、という
    /// 書き方はふつうにある。片方の欠けでもう片方の割合まで消さない。
    @Test("CPU とメモリで別に判定する")
    func axesAreIndependent() {
        let pods = [pod("web-0", memoryRequest: "64Mi", memoryLimit: "256Mi")]
        let usage = snapshot([(name: "web-0", cpu: 0.1, memory: 128 * 1024 * 1024)])
            .workloadUsage(of: pods)

        #expect(usage.cpu.ratio == nil)
        #expect(usage.cpu.podsWithoutBase == 1)
        #expect(abs((usage.memory.ratio ?? 0) - 0.5) < 0.0001)
        #expect(usage.memory.baseLabel == "上限")
    }

    /// 初期化コンテナは同時に動かないので分母に足さない。
    /// **`containerResourceTotal` と揃える** — ずれると 2 か所で違う数字が出る。
    @Test("初期化コンテナは分母に足さない")
    func ignoresInitContainers() {
        let pods = [
            pod("web-0", cpuRequest: "100m", cpuLimit: "500m",
                initContainer: Fixture.container(name: "setup", cpuLimit: "2"))
        ]
        let usage = snapshot([(name: "web-0", cpu: 0.1, memory: 0)])
            .workloadUsage(of: pods)
        #expect(abs(usage.cpu.base - 0.5) < 0.0001)
    }
}
