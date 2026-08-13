import Testing
@testable import KubeDeck

/// 使用量を「まだ引いていない」あいだに、取れなかったことにしないか。
///
/// ここが崩れると、取得元を探しているあいだじゅう「metrics-server も
/// Prometheus も見つかりません」と出たり、値が届く前のセルが `—`（＝
/// 取れなかった）になったりする。どちらも**確かめていないことの断定**で、
/// このリポジトリで最も繰り返し踏んだ間違いの 3 つ目の面。
@Suite("使用量の取得の進み具合")
struct MetricsPhaseTests {

    // MARK: - 判定そのもの

    @Test("1 度も調べていないうちは「無い」と決めない")
    func neverCheckedIsDetecting() {
        #expect(
            MetricsPhase.resolve(
                sourceAvailable: false, isDetecting: false,
                hasCheckedSource: false, hasLoaded: false) == .detecting)
    }

    @Test("metrics-server が無くても、Prometheus を探している最中は決めない")
    func stillDiscoveringIsDetecting() {
        // `metricsServerAvailable = false` は早々に決まるが、そのあと
        // 全 Service を順に叩く探索が続く。ここで `.unavailable` に倒すと、
        // 探している最中に「入っていません」と出る。
        #expect(
            MetricsPhase.resolve(
                sourceAvailable: false, isDetecting: true,
                hasCheckedSource: true, hasLoaded: false) == .detecting)
    }

    @Test("取得元が決まったら、探索の続きを待たずに値待ちへ移る")
    func sourceFoundWhileStillDiscovering() {
        // metrics-server が見つかったあとも Prometheus の探索は続くが、
        // 現在値はもう metrics-server から引ける。
        #expect(
            MetricsPhase.resolve(
                sourceAvailable: true, isDetecting: true,
                hasCheckedSource: true, hasLoaded: false) == .loading)
    }

    @Test("1 度引き終わったら、そこから先の空欄は「取れなかった」")
    func loadedIsReady() {
        #expect(
            MetricsPhase.resolve(
                sourceAvailable: true, isDetecting: false,
                hasCheckedSource: true, hasLoaded: true) == .ready)
    }

    @Test("調べ終えて取得元が無ければ、そこで初めて「無い」と言う")
    func checkedAndNothingFound() {
        #expect(
            MetricsPhase.resolve(
                sourceAvailable: false, isDetecting: false,
                hasCheckedSource: true, hasLoaded: false) == .unavailable)
    }

    @Test("待っているあいだだけ断定しない")
    func pendingCoversBothWaits() {
        #expect(MetricsPhase.detecting.isPending)
        #expect(MetricsPhase.loading.isPending)
        #expect(MetricsPhase.ready.isPending == false)
        #expect(MetricsPhase.unavailable.isPending == false)
    }

    // MARK: - ストアの状態から

    @MainActor
    @Test("開いた直後は「調べている」。取得元が無いことにしない")
    func freshStoreIsDetecting() {
        let store = ClusterStore()

        #expect(store.metricsPhase == .detecting)
    }

    @MainActor
    @Test("取得元は決まったが値がまだ、を「取れなかった」にしない")
    func sourceKnownButNoValuesYet() {
        let store = ClusterStore()
        store.metricsServerAvailable = true

        #expect(store.metricsPhase == .loading)
        #expect(store.hasLoadedMetrics == false)
    }

    @MainActor
    @Test("調べ終えて何も無ければ unavailable")
    func nothingAvailable() {
        let store = ClusterStore()
        store.metricsServerAvailable = false

        #expect(store.metricsPhase == .unavailable)
    }

    // MARK: - 一覧の列

    @MainActor
    @Test("値が届く前でも、取得元が決まっていれば使用量の列を出す")
    func columnsAppearWhilePending() {
        // **値が届いてから列を足さない。** 見ているあいだに列が増えると、
        // 一覧の横幅が動く。
        let columns = ResourceTable.columns(
            for: .pod, showNamespace: true, metrics: MetricsSnapshot(), metricsPending: true)

        let cpu = columns.first { $0.key == "CPU / 要求" }
        #expect(cpu != nil)

        let cell = cpu?.value(Fixture.pod(name: "web-0", namespace: "default"))
        // **`—` と書かない。** あれは「取れなかった」の印。
        #expect(cell?.text == ResourceTable.loadingUsage)
        #expect(cell?.text != "—")
    }

    @MainActor
    @Test("引き終わったあとに引けなかったセルは、これまでどおり `—`")
    func missingAfterLoadStaysDash() {
        var snapshot = MetricsSnapshot()
        snapshot.pods["default/other"] = ResourceUsage(cpuCores: 0.1, memoryBytes: 1_000_000)

        let columns = ResourceTable.columns(
            for: .pod, showNamespace: true, metrics: snapshot, metricsPending: false)
        let cell = columns.first { $0.key == "CPU / 要求" }?
            .value(Fixture.pod(name: "web-0", namespace: "default"))

        #expect(cell?.text == "—")
    }

    @MainActor
    @Test("取得元が無いクラスタでは列ごと出さない")
    func noColumnsWithoutSource() {
        let columns = ResourceTable.columns(
            for: .pod, showNamespace: true, metrics: MetricsSnapshot(), metricsPending: false)

        #expect(columns.contains { $0.key == "CPU / 要求" } == false)
    }

    @MainActor
    @Test("Namespace を切り替えたら、使用量も引き直しの扱いに戻す")
    func namespaceSwitchMarksMetricsPending() {
        let store = ClusterStore()
        store.metricsServerAvailable = true
        store.metrics.pods["default/web-0"] = ResourceUsage(cpuCores: 0.1, memoryBytes: 1)
        // 取り終えた状態を作る道が外に無いので、ここは切り替え前が
        // `.loading` であることだけを確かめる（`hasLoadedMetrics` は
        // `refreshMetrics` だけが立てる）。
        #expect(store.metricsPhase == .loading)

        store.selectedNamespace = "kube-system"

        // **前の Namespace のぶんを「取れた」ままにしない。** 新しい
        // Namespace の Pod は、まだ引いていないだけで `—` ではない。
        #expect(store.hasLoadedMetrics == false)
        #expect(store.metricsPhase == .loading)
    }
}
