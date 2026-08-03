import Testing
@testable import KubeDeck

/// `usageLevel` は critical から先に見るので、注意が異常を追い越すと
/// **警告色が一度も出なくなる**。設定はそれを作れないようにしてある。
@Suite("使用率のしきい値")
@MainActor
struct ThresholdTests {

    /// 判定そのもの。**「無い」を色にしない** ので、下回るときは nil を返す。
    @Test("しきい値を下回るときは色を付けない")
    func belowThreshold() {
        Preferences.usageThresholds = (warning: 0.8, critical: 0.9)

        #expect(ResourceTable.usageLevel(0.5) == nil)
        #expect(ResourceTable.usageLevel(0.85) == .warning)
        #expect(ResourceTable.usageLevel(0.95) == .critical)
        // 境目はそのしきい値に入る。
        #expect(ResourceTable.usageLevel(0.8) == .warning)
        #expect(ResourceTable.usageLevel(0.9) == .critical)
    }

    @Test("注意を異常より上に上げると、異常も押し上げられる")
    func warningPushesCritical() {
        let preferences = Preferences.shared
        let savedWarning = preferences.usageWarningPercent
        let savedCritical = preferences.usageCriticalPercent
        defer {
            preferences.usageCriticalPercent = savedCritical
            preferences.usageWarningPercent = savedWarning
        }

        preferences.usageWarningPercent = 60
        preferences.usageCriticalPercent = 80
        preferences.usageWarningPercent = 90

        #expect(preferences.usageCriticalPercent >= preferences.usageWarningPercent)
        // 逆転していないので、注意の色が出る余地が残っている。
        Preferences.usageThresholds = (
            warning: Double(preferences.usageWarningPercent) / 100,
            critical: Double(preferences.usageCriticalPercent) / 100)
        #expect(ResourceTable.usageLevel(0.91) != nil)
    }

    @Test("異常を注意より下に下げると、注意も引き下げられる")
    func criticalPullsWarning() {
        let preferences = Preferences.shared
        let savedWarning = preferences.usageWarningPercent
        let savedCritical = preferences.usageCriticalPercent
        defer {
            preferences.usageCriticalPercent = savedCritical
            preferences.usageWarningPercent = savedWarning
        }

        preferences.usageWarningPercent = 90
        preferences.usageCriticalPercent = 80

        #expect(preferences.usageWarningPercent <= preferences.usageCriticalPercent)
    }
}

/// 並べ替えの鍵の作り方。**「取れていない」を先頭に集めない。**
@Suite("一覧の並べ替え")
struct ResourceSortTests {

    @Test("見出しで覚える（列の位置は使用量の列で途中からずれる）")
    func sortIsKeyedByTitle() {
        let sort = ResourceSort(columnTitle: "再起動", ascending: true)
        #expect(sort.columnTitle == "再起動")
        #expect(sort != ResourceSort(columnTitle: "再起動", ascending: false))
    }

    /// 表示している文字をそのまま鍵にするので、数字を含む名前は
    /// `localizedStandardCompare` で人が読む順になる。
    @Test("数字を含む名前を辞書順にしない")
    func numericAwareOrdering() {
        let names = ["web-10", "web-2", "web-1"]
        let sorted = names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        #expect(sorted == ["web-1", "web-2", "web-10"])
    }
}

/// 見出しを押したときの並べ替えを、store の経路そのままで確かめる。
@Suite("一覧の並べ替え（store 経由）")
@MainActor
struct ListSortingTests {

    private func store(with pods: [K8sObject]) -> ClusterStore {
        let store = ClusterStore()
        store.selection = .kind(.pod)
        store.objects = pods
        return store
    }

    @Test("見出しを押すと昇順、もう一度で降順、3 度目で既定に戻る")
    func toggleCycle() {
        let store = store(with: [
            Fixture.pod(name: "web-2"), Fixture.pod(name: "web-10"), Fixture.pod(name: "web-1"),
        ])

        store.toggleSort(column: "名前")
        #expect(store.objects.map(\.name) == ["web-1", "web-2", "web-10"])

        store.toggleSort(column: "名前")
        #expect(store.objects.map(\.name) == ["web-10", "web-2", "web-1"])

        store.toggleSort(column: "名前")
        #expect(store.sortDescriptor == nil)
    }

    /// **「取れていない」を先頭に集めない。** 空欄や `—` は値ではないので、
    /// 昇順でも降順でも末尾に置く。
    @Test("値が引けていない行は、昇順でも降順でも末尾へ")
    func missingValuesGoLast() {
        let store = store(with: [
            Fixture.pod(name: "a", node: nil),
            Fixture.pod(name: "b", node: "node-9"),
            Fixture.pod(name: "c", node: "node-1"),
        ])

        store.toggleSort(column: "ノード")
        #expect(store.objects.map(\.name) == ["c", "b", "a"])

        store.toggleSort(column: "ノード")
        #expect(store.objects.map(\.name) == ["b", "c", "a"])
    }

    /// 列は種別ごとに違うので、見出しを持ち越しても指す先が無い。
    @Test("種別を変えたら並べ替えを捨てる")
    func sortResetsWithSelection() {
        let store = store(with: [Fixture.pod(name: "a")])
        store.toggleSort(column: "名前")
        #expect(store.sortDescriptor != nil)

        store.selection = .kind(.deployment)
        #expect(store.sortDescriptor == nil)
    }

    @Test("上下キーで選択が動き、端で止まる")
    func keyboardMovesSelection() {
        let pods = [Fixture.pod(name: "a"), Fixture.pod(name: "b"), Fixture.pod(name: "c")]
        let store = store(with: pods)

        // 何も選んでいなければ先頭から。
        store.moveSelection(by: 1)
        #expect(store.selectedObject?.name == "a")

        store.moveSelection(by: 1)
        #expect(store.selectedObject?.name == "b")

        // 端を越えない。
        store.moveSelection(by: -5)
        #expect(store.selectedObject?.name == "a")
        store.moveSelection(by: 99)
        #expect(store.selectedObject?.name == "c")
    }
}
