import Testing
@testable import KubeDeck

/// 複数選択の肝は「見えている選択」と「操作する対象」を食い違わせないこと。
/// ここがずれると、選んだつもりのないものが消える。
@MainActor
@Suite("複数選択")
struct SelectionTests {

    /// 一覧に 5 件並んでいる状態を作る。
    private func store(count: Int = 5) -> ClusterStore {
        let store = ClusterStore()
        store.objects = (0..<count).map {
            Fixture.pod(name: "pod-\($0)", namespace: "default")
        }
        store.selection = .kind(.pod)
        // `selection` の didSet は選択を捨てるので、行を入れ直す。
        store.objects = (0..<count).map {
            Fixture.pod(name: "pod-\($0)", namespace: "default")
        }
        return store
    }

    private func rows(_ store: ClusterStore) -> [K8sObject] { store.filteredObjects }

    @Test("ふつうのクリックは 1 つだけ選ぶ")
    func selectOnly() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.selectOnly(rows[2])

        #expect(store.selectedObjectIDs == [rows[2].id])
        #expect(store.selectedObjectID == rows[2].id)
    }

    @Test("⌘ クリックで足し引きできる")
    func toggle() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.toggleSelection(of: rows[2])
        #expect(store.selectedObjectIDs == [rows[0].id, rows[2].id])

        store.toggleSelection(of: rows[2])
        #expect(store.selectedObjectIDs == [rows[0].id])
    }

    @Test("主役を外したら、残っているものから選び直す")
    func removingPrimaryPicksAnother() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.toggleSelection(of: rows[1])
        // いま主役は rows[1]。それを外す。
        store.toggleSelection(of: rows[1])

        // **選ばれていないものを詳細パネルが映し続けない。**
        #expect(store.selectedObjectIDs == [rows[0].id])
        #expect(store.selectedObjectID == rows[0].id)
    }

    @Test("最後の 1 つを外したら主役も居なくなる")
    func removingLastClearsPrimary() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.toggleSelection(of: rows[0])

        #expect(store.selectedObjectIDs.isEmpty)
        #expect(store.selectedObjectID == nil)
    }

    @Test("shift クリックは起点からそこまでを選ぶ")
    func extend() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[1])
        store.extendSelection(to: rows[3])

        #expect(store.selectedObjectIDs == Set(rows[1...3].map(\.id)))
    }

    @Test("上に向かって伸ばしても選べる")
    func extendUpwards() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[3])
        store.extendSelection(to: rows[1])

        #expect(store.selectedObjectIDs == Set(rows[1...3].map(\.id)))
    }

    @Test("起点は shift のたびに動かない")
    func anchorStaysPut() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[1])
        store.extendSelection(to: rows[3])
        // 起点が rows[3] に移っていると、ここで 3...4 になってしまう。
        store.extendSelection(to: rows[4])

        #expect(store.selectedObjectIDs == Set(rows[1...4].map(\.id)))
    }

    @Test("選んだものは一覧の並びのまま返す")
    func selectedObjectsKeepListOrder() {
        let store = self.store()
        let rows = rows(store)

        // 選んだ順序はばらばらでも、返るのは画面の並び。
        store.selectOnly(rows[3])
        store.toggleSelection(of: rows[0])
        store.toggleSelection(of: rows[2])

        #expect(store.selectedObjects.map(\.name) == ["pod-0", "pod-2", "pod-3"])
    }

    @Test("↑↓ は選択を 1 つに戻す")
    func moveCollapsesSelection() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.extendSelection(to: rows[3])
        store.moveSelection(by: 1)

        #expect(store.selectedObjectIDs.count == 1)
    }

    @Test("shift ＋ ↑↓ は選択を伸ばす")
    func moveExtends() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.moveSelection(by: 1, extending: true)
        store.moveSelection(by: 1, extending: true)

        #expect(store.selectedObjectIDs == Set(rows[0...2].map(\.id)))
    }

    @Test("種別を移ると選択は捨てる")
    func changingKindClearsSelection() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.toggleSelection(of: rows[1])
        store.selection = .kind(.service)

        // **持ち越さない。** 見えていないものを選んだまま
        // 「まとめて削除」を押せてしまう。
        #expect(store.selectedObjectIDs.isEmpty)
        #expect(store.selectedObjectID == nil)
    }

    @Test("絞り込みの外にあるものは操作対象に入らない")
    func filteredOutRowsAreNotActedOn() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.toggleSelection(of: rows[1])
        store.searchText = "pod-1"

        // 画面から消えたものを消してしまわない。
        #expect(store.selectedObjects.map(\.name) == ["pod-1"])
    }
}
