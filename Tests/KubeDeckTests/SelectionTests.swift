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

    // MARK: - 右クリックの対象

    /// **選択の書き換えを待たずに対象を決める。**
    ///
    /// 一覧は `.onAppear` で「選んでいない行を右クリックしたら、まずそれを
    /// 選ぶ」を行うが、**メニューの中身はそれより先に評価される**。以前は
    /// メニューが `selectedObjects` を直に読んでいたので、3 件選んだ状態で
    /// 未選択の行を右クリックすると「3 件を削除」のメニューが出た（確認に
    /// 並ぶ名前と、実際に効く相手が食い違う）。
    @Test("選んでいない行を右クリックしたら、その 1 件だけが対象")
    func contextMenuOnUnselectedRow() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.toggleSelection(of: rows[1])
        store.toggleSelection(of: rows[2])
        #expect(store.selectedObjects.count == 3)

        // まだ選択は動いていない（`.onAppear` はこのあと走る）時点で訊く。
        let targets = store.contextMenuTargets(for: rows[4])
        #expect(targets.map(\.name) == ["pod-4"])
    }

    /// **選んでいる行を右クリックしたときは、選択そのものが対象。**
    /// ここを 1 件に落とすと、まとめて操作する道が無くなる。
    @Test("選んでいる行を右クリックしたら、選択している全部が対象")
    func contextMenuOnSelectedRow() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        store.toggleSelection(of: rows[1])

        let targets = store.contextMenuTargets(for: rows[1])
        #expect(Set(targets.map(\.name)) == ["pod-0", "pod-1"])
    }

    /// 1 件しか選んでいなければ、押した行が対象。
    @Test("1 件だけ選んでいるときは、押した行が対象")
    func contextMenuWithSingleSelection() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        #expect(store.contextMenuTargets(for: rows[0]).map(\.name) == ["pod-0"])
        #expect(store.contextMenuTargets(for: rows[3]).map(\.name) == ["pod-3"])
    }

    // MARK: - 畳んでいる詳細パネルを出す合図

    /// **`selectedObjectID != nil` から導かない。** 導くと種別を移った直後の
    /// 選び直しや自動更新でもパネルが出入りし、`.inspector` は現れるたびに
    /// ウインドウを広げるので、選ぶたびに窓の幅が変わる。ここが数えるのは
    /// 「人が押した」ことだけ。
    @Test("行を選ぶと、畳んでいる詳細パネルを出す合図が届く")
    func selectingRequestsInspector() {
        let store = self.store()
        let rows = rows(store)
        let before = store.inspectorRevealRequests

        store.selectOnly(rows[0])
        #expect(store.inspectorRevealRequests == before + 1)

        // **同じ行を押し直しても届く。** `selectedObjectID` の変化を見ていると、
        // いちど畳んでからもう 1 度押したときに何も起きない。
        store.selectOnly(rows[0])
        #expect(store.inspectorRevealRequests == before + 2)

        store.toggleSelection(of: rows[1])
        store.extendSelection(to: rows[3])
        #expect(store.inspectorRevealRequests == before + 4)
    }

    /// 右クリックの選び直しは「まず選ぶ」ためのもので、詳細を見に来たわけでは
    /// ない。出すとメニューが開いている最中にウインドウが広がる。
    @Test("右クリックの選び直しでは出さない")
    func contextMenuSelectionDoesNotReveal() {
        let store = self.store()
        let rows = rows(store)
        let before = store.inspectorRevealRequests

        store.selectOnly(rows[2], reveal: false)

        #expect(store.selectedObjectID == rows[2].id)
        #expect(store.inspectorRevealRequests == before)
    }

    /// 映すものが無いときに出さない。**選択を捨てる経路も同じ**（種別を移る、
    /// Namespace を切り替える、まとめて消した直後）。
    @Test("選択が空になるときは出さない")
    func clearingDoesNotReveal() {
        let store = self.store()
        let rows = rows(store)

        store.selectOnly(rows[0])
        let after = store.inspectorRevealRequests

        // 最後の 1 つを ⌘ クリックで外す。
        store.toggleSelection(of: rows[0])
        #expect(store.selectedObjectID == nil)
        #expect(store.inspectorRevealRequests == after)

        store.clearSelection()
        store.selection = .kind(.service)
        #expect(store.inspectorRevealRequests == after)
    }
}

/// 設定タブが出す値。
///
/// **同じことを 2 か所で別々に解かない。** ここで固めるのは、実際に
/// 片方だけ間違えていた組み合わせ。
@Suite("設定タブの値")
struct SettingsDigestValueTests {

    /// **名前を持つキーは種類ごとに違う。** `configMap` は `name` だが
    /// `secret` は `secretName`。落としていたので、Secret のボリュームだけ
    /// 名前が出ず「Secret」としか書けていなかった
    /// （`WorkloadRelations.configReferences` は正しく読んでいたので、
    /// 同じ Pod でも見る場所によって名前が出たり出なかったりしていた）。
    @Test("ボリュームは種類ごとに正しいキーから名前を拾う")
    func volumeNames() throws {
        let pod = Fixture.object("""
            {"kind":"Pod","metadata":{"name":"p","namespace":"d","uid":"u"},
             "spec":{"containers":[{"name":"app","image":"nginx"}],
              "volumes":[
                {"name":"certs","secret":{"secretName":"tls-cert"}},
                {"name":"conf","configMap":{"name":"app-conf"}},
                {"name":"data","persistentVolumeClaim":{"claimName":"data-pvc"}},
                {"name":"tmp","emptyDir":{}}
              ]}}
            """, assuming: .pod)

        let group = try #require(
            SettingsDigest.groups(for: pod).first { $0.title == "ボリューム" })
        func value(_ label: String) -> String? {
            group.rows.first { $0.label == label }?.value
        }

        #expect(value("certs") == "Secret（tls-cert）")
        #expect(value("conf") == "ConfigMap（app-conf）")
        #expect(value("data") == "PVC（data-pvc）")
        // 名前を持たない種類は種類だけ（「未設定」にしない）。
        #expect(value("tmp") == "一時領域")
    }

    /// たどるの帯と同じ答えになること。**解き方が 2 つあると食い違う。**
    @Test("たどるの帯と、設定タブが同じ Secret を指す")
    func agreesWithConfigReferences() throws {
        let pod = Fixture.object("""
            {"kind":"Pod","metadata":{"name":"p","namespace":"d","uid":"u"},
             "spec":{"containers":[{"name":"app","image":"nginx"}],
              "volumes":[{"name":"certs","secret":{"secretName":"tls-cert"}}]}}
            """, assuming: .pod)

        let references = WorkloadRelations.configReferences(for: [pod])
        #expect(references.contains { $0.source == .secret && $0.name == "tls-cert" })

        let group = try #require(
            SettingsDigest.groups(for: pod).first { $0.title == "ボリューム" })
        #expect(group.rows.first?.value.contains("tls-cert") == true)
    }
}
