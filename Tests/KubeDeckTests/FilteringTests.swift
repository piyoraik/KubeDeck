import Testing
@testable import KubeDeck

/// `filteredObjects` は計算プロパティをやめてキャッシュにした（1 描画のあいだに
/// 副題・一覧・詳細パネル・配置から読まれ、そのたびに全件 × 全列を舐めていた）。
///
/// キャッシュにすると壊れ方が変わる。**「重い」ではなく「古い」になる。**
/// 更新の取りこぼしは画面に出ている行が事実とずれるという形で出るので、
/// 組み直しの引き金をここで固めておく。
@MainActor
@Suite("一覧のキャッシュ")
struct FilteringTests {

    private func store(names: [String] = ["web-0", "web-1", "cache-0"]) -> ClusterStore {
        let store = ClusterStore()
        store.selection = .kind(.pod)
        store.objects = names.map { Fixture.pod(name: $0, namespace: "default") }
        return store
    }

    // MARK: - 組み直しの引き金

    @Test("行を入れ替えたら追従する")
    func objectsDrivesRows() {
        let store = self.store()
        #expect(store.filteredObjects.count == 3)

        store.objects = [Fixture.pod(name: "only-0", namespace: "default")]

        #expect(store.filteredObjects.map(\.name) == ["only-0"])
    }

    @Test("絞り込みの語を変えたら追従する")
    func searchTextDrivesRows() {
        let store = self.store()

        store.searchText = "web"
        #expect(store.filteredObjects.map(\.name) == ["web-0", "web-1"])

        store.searchText = "cache"
        #expect(store.filteredObjects.map(\.name) == ["cache-0"])
    }

    @Test("語を空に戻したら全件に戻る")
    func clearingSearchRestoresEverything() {
        let store = self.store()

        store.searchText = "web"
        store.searchText = ""

        #expect(store.filteredObjects.count == 3)
    }

    @Test("並べ替えの結果がそのまま行の並びになる")
    func sortIsReflected() {
        let store = self.store()

        store.sortDescriptor = ResourceSort(columnKey: "名前", ascending: true)
        #expect(store.filteredObjects.map(\.name) == ["cache-0", "web-0", "web-1"])

        store.sortDescriptor = ResourceSort(columnKey: "名前", ascending: false)
        #expect(store.filteredObjects.map(\.name) == ["web-1", "web-0", "cache-0"])
    }

    @Test("種別を移ったら持ち越さない")
    func changingSelectionDropsRows() {
        let store = self.store()

        store.selection = .kind(.deployment)

        // **見えていないものを選択や操作の対象に残さない。**
        #expect(store.filteredObjects.isEmpty)
    }

    @Test("概要には絞り込む相手がいない")
    func overviewHasNoRows() {
        let store = self.store()

        store.selection = .overview

        #expect(store.filteredObjects.isEmpty)
    }

    // MARK: - 選択中のものを引く

    /// `objects.first(where:)` の線形探索をやめて索引にした。索引は
    /// `objects` の didSet で組み直すので、こちらも取りこぼすと古いものを映す。
    @Test("選択中のものは id で引ける")
    func selectedObjectComesFromIndex() {
        let store = self.store()
        let target = store.filteredObjects[1]

        store.selectOnly(target)

        #expect(store.selectedObject?.name == "web-1")
    }

    @Test("選んでいたものが消えたら nil になる")
    func selectedObjectDisappears() {
        let store = self.store()
        store.selectOnly(store.filteredObjects[1])

        store.objects = [Fixture.pod(name: "web-0", namespace: "default")]

        #expect(store.selectedObject == nil)
    }

    @Test("入れ替わった同名のものは新しいほうを映す")
    func selectedObjectFollowsReplacement() {
        let store = ClusterStore()
        store.selection = .kind(.pod)
        store.objects = [Fixture.pod(name: "web-0", namespace: "default", phase: "Running")]
        store.selectOnly(store.filteredObjects[0])

        store.objects = [Fixture.pod(name: "web-0", namespace: "default", phase: "Failed")]

        #expect(store.selectedObject?.raw["status"]?["phase"]?.stringValue == "Failed")
    }
}
