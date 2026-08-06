import Testing
@testable import KubeDeck

/// 概要が「まだ数えていない」ことを 0 件と偽らないか。
///
/// ここが崩れると、読み込み中に 0 の並んだリングが出る（「無い」と
/// 「取れていない」を混ぜる、このアプリで最も繰り返し踏んだ間違い）。
@MainActor
@Suite("概要の読み込み中")
struct OverviewLoadingTests {

    @Test("サイドバーの件数だけでは「概要を読めた」ことにしない")
    func countsAloneAreNotOverviewData() {
        let store = ClusterStore()
        // `refreshSidebarCounts` が埋めるのは件数だけ。リングの内訳も
        // 使用量の分母も無いので、概要はまだ出せない。
        store.overview.counts = [.pod: 12, .node: 3]

        #expect(store.hasOverviewData == false)
    }

    @Test("集計まで済んだら概要を出せる")
    func talliedSnapshotIsOverviewData() {
        let store = ClusterStore()
        var snapshot = OverviewSnapshot()
        snapshot.isTallied = true
        snapshot.counts = [.pod: 12]
        store.overview = snapshot

        #expect(store.hasOverviewData)
    }

    @Test("概要を開き直したら、前の集計は捨てて読み込み中に戻す")
    func reopeningOverviewDiscardsTallies() {
        let store = ClusterStore()
        var snapshot = OverviewSnapshot()
        snapshot.isTallied = true
        snapshot.counts = [.pod: 12, .node: 3]
        snapshot.pods = StatusTally.make(from: [Fixture.pod(name: "p", namespace: "default")])
        snapshot.allocatable = ResourceUsage(cpuCores: 4, memoryBytes: 8_000_000_000)
        store.overview = snapshot

        store.selection = .kind(.pod)
        store.selection = .overview

        #expect(store.hasOverviewData == false)
        #expect(store.overview.pods.isEmpty)
        #expect(store.overview.allocatable.cpuCores == 0)
        // **件数はサイドバーの持ち場。** 概要の読み直しで消す理由が無い。
        #expect(store.overview.counts[.pod] == 12)
    }

    @Test("一覧を見ているあいだは概要の集計を捨てない")
    func leavingOverviewKeepsTallies() {
        let store = ClusterStore()
        var snapshot = OverviewSnapshot()
        snapshot.isTallied = true
        snapshot.pods = StatusTally.make(from: [Fixture.pod(name: "p", namespace: "default")])
        store.overview = snapshot

        store.selection = .kind(.pod)

        // 詳細パネルの「気になる状態」がここを読む。
        #expect(store.hasOverviewData)
    }

    /// `bootstrap()` は最初の `reload()` を待たずに読み込み中を立てる。
    /// そのぶん、起こす先が無いときに下ろす道が要る（無いと画面が
    /// 「読み込み中…」のまま留まる）。
    @Test("起こす先が無いときは読み込み中のまま留めない")
    func reloadWithoutContextClearsSpinner() {
        let store = ClusterStore()
        store.isLoading = true

        store.reload()

        #expect(store.isLoading == false)
    }

    @Test("Namespace を切り替えたら概要も別物として捨てる")
    func switchingNamespaceDiscardsOverview() {
        let store = ClusterStore()
        var snapshot = OverviewSnapshot()
        snapshot.isTallied = true
        snapshot.counts = [.pod: 12]
        store.overview = snapshot

        store.selectedNamespace = "kube-system"

        #expect(store.hasOverviewData == false)
        #expect(store.overview.counts.isEmpty)
    }
}
