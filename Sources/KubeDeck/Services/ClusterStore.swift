import Foundation
import Observation

/// 画面全体の状態。kubectl の呼び出しはすべてここを経由する。
@MainActor
@Observable
final class ClusterStore {
    enum Selection: Hashable, Sendable {
        case overview
        /// どの Pod がどのノードに載っているか。
        case placement
        case resource(ResourceTarget)

        static func kind(_ kind: ResourceKind) -> Selection { .resource(.builtIn(kind)) }

        /// UserDefaults に入れるための表現。
        var storageKey: String {
            switch self {
            case .overview: return "overview"
            case .placement: return "placement"
            case .resource(.builtIn(let kind)): return kind.rawValue
            case .resource(.custom(let type)): return "crd:\(type.resourceName)"
            }
        }

        /// 保存値から戻す。CRD はクラスタを見ないと組み立てられないので、
        /// 見つかった種別の一覧を渡してもらう。読めなければ概要に落ちる。
        init(storageKey: String, customTypes: [CustomResourceType]) {
            if storageKey == "placement" {
                self = .placement
                return
            }
            if storageKey.hasPrefix("crd:") {
                let name = String(storageKey.dropFirst(4))
                if let type = customTypes.first(where: { $0.resourceName == name }) {
                    self = .resource(.custom(type))
                    return
                }
            } else if let kind = ResourceKind(rawValue: storageKey) {
                self = .resource(.builtIn(kind))
                return
            }
            self = .overview
        }
    }

    // MARK: - 状態

    var contexts: [String] = []
    var currentContext: String = "" {
        didSet {
            guard currentContext != oldValue else { return }
            Defaults.context = currentContext
            guard !isBootstrapping else { return }
            // クラスタが変われば Namespace 一覧も選択も無効になる。
            namespaces = []
            selectedNamespace = nil
            serverVersion = ""
            // 取得元はクラスタごとに違う。持ち越すと別クラスタの値を出す。
            metrics = MetricsSnapshot()
            metricsServerAvailable = nil
            prometheus = nil
            customTypes = []
            deniedKinds = []
            overview = OverviewSnapshot()
            // **クラスタごとの調べものにも世代番号を通す。** ここを素の Task で
            // 投げていたら、A → B と続けて切り替えたときに A 向けの結果が B に
            // 書き込まれた。とくに Prometheus の探索は全 Service を順に叩くので
            // いちばん遅れて返り、**A で見つけた場所を B のものとして
            // `UserDefaults` に永続化していた**（B に同名の Service が無ければ、
            // 以後ずっと推移が出ないまま黙る）。
            refreshClusterInfo()
            reload()
        }
    }

    var namespaces: [String] = []
    /// nil は「すべての Namespace」。
    var selectedNamespace: String? {
        didSet {
            guard selectedNamespace != oldValue else { return }
            Defaults.namespace = selectedNamespace
            guard !isBootstrapping else { return }
            // **前の Namespace の中身を出したまま読み直さない。** 行も件数も
            // 別の Namespace のものなので、これは「古い」ではなく「別物」。
            // 残すと切り替えたのに前の一覧が出たままになり、いつ入れ替わったのか
            // 分からない（新しいほうが件数が少なければ、消えるまでは多く見える）。
            // 捨てておけば `isLoading` と合わさって読み込み中の表示になる。
            discardLoadedResources()
            reload()
        }
    }

    /// 画面に出ている取得済みの中身を捨て、読み込み中の表示に戻す。
    ///
    /// **選択も一緒に捨てる** — 一覧から消えたものを選んだままにすると、
    /// 見えていないものが「まとめて削除」の対象になる（種別を移るときと同じ話）。
    private func discardLoadedResources() {
        objects = []
        placementNodes = []
        placementControllers = []
        placementWorkloads = []
        placementRelated = []
        // **概要の集計も捨てる。** 残っていると `hasOverviewData` が真のままで、
        // 概要は前の Namespace の数字を出したまま読み直すことになる
        // （「古い」ではなく「別物」）。
        overview = OverviewSnapshot()
        deniedKinds = []
        unknownKinds = []
        clearSelection()
    }

    var selection: Selection = .overview {
        didSet {
            guard selection != oldValue else { return }
            Defaults.selection = selection.storageKey
            // 別の種別へ移るときは複数選択も捨てる。持ち越すと、見えていない
            // ものを選んだまま「まとめて削除」を押せてしまう。
            clearSelection()
            searchText = ""
            objects = []
            deniedKinds = []
            // 列は種別ごとに違うので、見出しを持ち越しても指す先が無い。
            sortDescriptor = nil
            // 別の種別を開いたのに前の Pod のログが下に残ると、
            // どれを見ているのか分からなくなる。
            logRequest = nil
            // **概要を開き直すときも、一覧と同じく前の中身を捨てる。**
            // 一覧は `objects` を捨てるので読み込み中の表示になるのに、概要だけは
            // 前に開いたときの集計が残り、読み直しているあいだ**古い数字を
            // 「いまの状態」として**出していた（更新中だと画面に出ていない）。
            // **件数は捨てない** — サイドバーの持ち場で、こちらの読み直しとは
            // 関係が無い（`discardTallies`）。
            if case .overview = selection { overview.discardTallies() }
            guard !isBootstrapping else { return }
            reload()
        }
    }

    var objects: [K8sObject] = [] {
        didSet {
            objectIndex = Dictionary(
                objects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            updateFilteredObjects()
        }
    }

    /// id から 1 つ引くための索引。**`first(where:)` で舐めない** —
    /// 詳細パネルは毎フレーム選択中のものを引くので、行数ぶんの線形探索になる。
    private var objectIndex: [K8sObject.ID: K8sObject] = [:]

    /// 配置画面のノード。Pod のほうは `objects` に入れる（検索と選択を
    /// 一覧と同じ経路に載せるため）。
    var placementNodes: [K8sObject] = []
    /// ReplicaSet と Job。Pod の所有者を Deployment / CronJob まで辿るために持つ。
    /// **ReplicaSet 名で束ねない。** `<Deployment 名>-<ハッシュ>` なので、
    /// 更新のたびに別のまとまりに見える。
    var placementControllers: [K8sObject] = [] {
        didSet { controllerIndex = Self.makeControllerIndex(placementControllers) }
    }
    /// Deployment / StatefulSet / DaemonSet / CronJob。
    /// **Pod から名前を起こすだけでは足りない。** レプリカ 0 のワークロードは
    /// Pod が 1 つも無く、Pod 側からは存在すら見えない（たどるの起点に
    /// 選べないうえ、「無い」のか「止めてある」のかも分からない）。
    var placementWorkloads: [K8sObject] = []
    /// 図に添えるもの（Service・Ingress・PVC）。関係は API に無いので、
    /// 取ってきたものどうしを突き合わせて結ぶ（`WorkloadRelations`）。
    var placementRelated: [K8sObject] = []

    /// いま開いている画面で、権限が無くて読めなかった種別。
    ///
    /// **「無い」と混ぜないために持つ。** Service が読めていないだけなのに
    /// 図から入口が消えると、繋がっていないように見える。読めたぶんは出した
    /// うえで、欠けていることを画面に書く。
    var deniedKinds: [ResourceKind] = []

    /// いま開いている画面で、サーバが名前を知らなかった種別。
    ///
    /// **権限と混ぜない。** 対処が違ううえ、こちらは「本当に無い」場合と
    /// 「kubectl の一覧が欠けている」場合の両方がありうる。
    var unknownKinds: [ResourceKind] = []

    /// 欠けている種別の断り書き。読めているなら nil。
    ///
    /// **2 つの欠け方を 1 文にまとめない。** 権限が無いのと、サーバが種別を
    /// 知らないのとでは見る場所が違う。どちらも「0 件ではない」ことだけが同じ。
    var partialDataNotice: String? {
        let denied = deniedKinds.isEmpty ? overview.deniedKinds : deniedKinds
        let unknown = unknownKinds.isEmpty ? overview.unknownKinds : unknownKinds
        var lines: [String] = []
        if !denied.isEmpty {
            let names = denied.map(\.displayName).joined(separator: "・")
            lines.append("\(names) を読む権限がありません。この画面にはこれらが出ていません"
                + "（0 件という意味ではありません）。")
        }
        if !unknown.isEmpty {
            let names = unknown.map(\.displayName).joined(separator: "・")
            lines.append("\(names) はクラスタに見つかりませんでした（`kubectl` がこの種別を"
                + "解決できていません）。読めたぶんだけ出しています。"
                + "`kubectl api-resources` に出るかを確かめてください。")
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// たどるが解く材料。**画面から都度組み立てない** — 同じ 1 回の kubectl で
    /// 取ったものだけを渡すことを、この型で担保する。
    var placementInventory: PlacementInventory {
        PlacementInventory(
            pods: objects, nodes: placementNodes, generations: placementControllers,
            workloads: placementWorkloads, related: placementRelated)
    }
    var overview = OverviewSnapshot()
    var serverVersion: String = ""

    var searchText: String = "" {
        didSet {
            guard searchText != oldValue else { return }
            updateFilteredObjects()
        }
    }

    /// 一覧の並べ替え。nil なら既定（異常が上、次に Namespace と名前）。
    ///
    /// **列の位置ではなく見出しで覚える。** 使用量の列は metrics-server が
    /// 見つかるまで出ないので、位置で持つと途中で列がずれて別の列を指す。
    var sortDescriptor: ResourceSort? {
        didSet {
            guard sortDescriptor != oldValue else { return }
            objects = sortedForDisplay(objects)
        }
    }
    var selectedObjectID: K8sObject.ID? {
        didSet {
            guard selectedObjectID != oldValue else { return }
            // 前の対象の線を残さない。残すと別の Pod の履歴に見える。
            selectedHistory = MetricsHistory()
            Task { await self.refreshSelectedHistory() }
            followLogsToSelection()
        }
    }

    /// 現在の使用量。取得元が無いクラスタでは空のまま。
    var metrics = MetricsSnapshot()
    /// metrics-server が使えるか。判定が済むまで nil。
    var metricsServerAvailable: Bool?
    /// どこから取るかの設定。
    var metricsPreference: MetricsSourcePreference = Preferences.shared.metricsPreference {
        didSet {
            guard metricsPreference != oldValue else { return }
            Preferences.shared.metricsPreference = metricsPreference
            // 取得元が変われば数字の出どころも変わる。持ち越さない。
            metrics = MetricsSnapshot()
            Task { await self.refreshMetrics() }
        }
    }
    /// 見つかった Prometheus。無ければ nil。
    var prometheus: PrometheusEndpoint?
    /// クラスタに入っている CRD の種別。サイドバーに並べる。
    var customTypes: [CustomResourceType] = []
    /// 選択中のオブジェクトの履歴。
    var selectedHistory = MetricsHistory()
    /// クラスタ全体の履歴（概要用）。
    var clusterHistory = MetricsHistory()

    /// 下部パネルに出しているログ。nil なら閉じている。
    var logRequest: PodLogRequest?

    /// ログのパネルを**開いているあいだ**、Pod を選んだら行き先も切り替えるか。
    ///
    /// 既定は有効。閉じているパネルをこれで開くことはない
    /// （開けるのは「ログを見る」を押したときだけ）。
    var followsSelectionForLogs: Bool = Preferences.shared.followsSelectionForLogs {
        didSet { Preferences.shared.followsSelectionForLogs = followsSelectionForLogs }
    }

    var isLoading = false

    /// 操作が通ったことの短い知らせ。数秒で自分から消える。
    ///
    /// **エラーと同じ持ち場にしない。** あちらは読んで対処するもので、
    /// こちらは「効いた」と分かればよいもの。残し続けると画面を塞ぐ。
    var actionNotice: String?
    private var noticeTask: Task<Void, Never>?

    var errorMessage: String?
    var setupErrorMessage: String?
    var lastUpdated: Date?

    var autoRefresh: Bool = Preferences.shared.autoRefresh {
        didSet { Preferences.shared.autoRefresh = autoRefresh }
    }
    var refreshInterval: TimeInterval = Preferences.shared.refreshInterval {
        didSet { Preferences.shared.refreshInterval = refreshInterval }
    }

    /// 起動時の復元中は、プロパティの didSet から連鎖する再読み込みを止める。
    /// 止めないと `currentContext` の didSet が `selectedNamespace` を nil に
    /// 落とし、その didSet が保存値を上書きするので、前回の Namespace が
    /// 読み出す前に消える。
    private var isBootstrapping = false
    private var loadTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    /// 遅れて返ってきた古い結果で新しい表示を上書きしないための世代番号。
    private var generation = 0

    /// コンテキストに紐づく調べもの（Namespace 一覧・CRD・メトリクスの取得元）の世代。
    ///
    /// **一覧の `generation` と分ける。** 種別や Namespace を変えただけでは
    /// クラスタの事実は変わらないので、一覧の再読み込みで無効にする必要はない。
    /// 逆に、コンテキストが変われば全部が別のクラスタの話になる。
    private var contextGeneration = 0
    private var clusterInfoTask: Task<Void, Never>?

    private let kubectl = Kubectl.shared

    // MARK: - 派生

    /// いま開いている一覧の対象。概要のときは nil。
    var currentTarget: ResourceTarget? {
        if case .resource(let target) = selection { return target }
        return nil
    }

    /// 組み込み種別のときだけ返す。種別ごとの特別扱いの判定に使う。
    var currentKind: ResourceKind? { currentTarget?.builtIn }

    /// 操作と絞り込みの相手。
    ///
    /// **配置画面を蚊帳の外にしない。** あそこは一覧ではないので
    /// `currentTarget` は nil だが、並べて選べるのは Pod なので、`objects` に
    /// 入っているものの種別は決まっている。ここが nil のままだと、選んだ Pod の
    /// ログも削除も YAML も**配置画面からだけ黙って効かない**（`ResourceActionSet`
    /// は種別名が決まらないときは操作を出さないので、押せないほうに倒れる）。
    /// 絞り込みが以前からこの既定で動いているので、同じ判断に揃える。
    var actionTarget: ResourceTarget? {
        currentTarget ?? (selection == .placement ? .builtIn(.pod) : nil)
    }

    /// Namespace 列を出すのは「すべて」を見ているときだけ。
    var showsNamespaceColumn: Bool { selectedNamespace == nil }

    /// いま画面に出ている行。
    ///
    /// **計算プロパティにしない。** 1 描画のあいだに副題・一覧・詳細パネルの
    /// 内訳・配置の 2 か所から読まれるので、素直に計算すると同じ絞り込みが
    /// 5〜6 回走る。中身は全件 × 全列を舐めるので、そのぶんがそのまま重なる。
    /// `objects` と `searchText` が変わったときだけ組み直す。
    private(set) var filteredObjects: [K8sObject] = []

    private func updateFilteredObjects() {
        // 配置画面も Pod を並べているので、一覧と同じ絞り込みに載せる。
        guard let target = actionTarget else {
            filteredObjects = []
            return
        }
        // **絞り込みは 1 度だけ組み立てる。** 語の解析も列の構築も、
        // 問い合わせと対象が同じなら結果は同じ（`ResourceSearch`）。
        let search = ResourceSearch(query: searchText, target: target)
        filteredObjects = search.isEmpty ? objects : objects.filter(search.matches)
    }

    var selectedObject: K8sObject? {
        guard let selectedObjectID else { return nil }
        return objectIndex[selectedObjectID]
    }

    /// いま開いている一覧の列。**画面と store で 2 つ持たない** —
    /// 並べ替えは列の値をそのまま鍵にするので、定義がずれると
    /// 見えている文字と並び順が食い違う。
    var currentColumns: [ResourceColumn] {
        switch currentTarget {
        case .builtIn(let kind):
            return ResourceTable.columns(
                for: kind, showNamespace: showsNamespaceColumn, metrics: metrics)
        case .custom(let type):
            return ResourceTable.columns(for: type, showNamespace: showsNamespaceColumn)
        case nil:
            return []
        }
    }

    /// 見出しを押したときの並べ替え。同じ見出しをもう一度押すと逆順、
    /// 3 度目で既定（異常が上）に戻す。**戻れないと、既定の並びを取り戻すのに
    /// 種別を開き直すことになる。**
    func toggleSort(column title: String) {
        switch sortDescriptor {
        case let current? where current.columnTitle == title && current.ascending:
            sortDescriptor = ResourceSort(columnTitle: title, ascending: false)
        case let current? where current.columnTitle == title:
            sortDescriptor = nil
        default:
            sortDescriptor = ResourceSort(columnTitle: title, ascending: true)
        }
    }

    /// キーボードで選択を動かす。一覧は自前の行なので、`List` のような
    /// 上下移動が付いてこない。
    func moveSelection(by offset: Int, extending: Bool = false) {
        let rows = filteredObjects
        guard !rows.isEmpty else { return }
        guard let current = selectedObjectID,
              let index = rows.firstIndex(where: { $0.id == current })
        else {
            selectOnly(rows[0])
            return
        }
        let next = min(max(0, index + offset), rows.count - 1)
        if extending {
            extendSelection(to: rows[next])
        } else {
            selectOnly(rows[next])
        }
    }

    // MARK: - 複数選択

    /// いま選ばれているもの全部。
    ///
    /// **主役（`selectedObjectID`）は常にこの中に居る。** 詳細パネル・ログ・
    /// 履歴は主役だけを見るので、そちらの経路は 1 つのままでよい。ここが
    /// 増えるのは「まとめて何かする」ときだけ。
    private(set) var selectedObjectIDs: Set<K8sObject.ID> = []

    /// 範囲選択の起点。**主役とは別に持つ。** 主役は shift を押すたびに動くので、
    /// それを起点にすると選択範囲が引きずられて伸び続ける。
    private var selectionAnchorID: K8sObject.ID?

    /// 選ばれているものを**一覧の並びのまま**返す。操作の順序が画面と
    /// 食い違わないようにする。
    var selectedObjects: [K8sObject] {
        filteredObjects.filter { selectedObjectIDs.contains($0.id) }
    }

    /// 畳んでいる詳細パネルを出してほしい、という合図。
    ///
    /// **`selectedObjectID != nil` から導かない。** 導くと、種別を移った直後の
    /// 選び直しや自動更新でもパネルが出入りすることになり、`.inspector` は
    /// 現れるたびにウインドウを広げるので、選ぶたびに窓の幅が変わる。ここは
    /// 「人が行やタイルを押した」ことだけを数えて渡し、**出す方向にしか
    /// 効かせない**（畳むのは今までどおりツールバーのボタンだけが決める）。
    private(set) var inspectorRevealRequests = 0

    /// 人が選んだ。**プログラムの選び直しからは呼ばない。**
    private func requestInspectorReveal() {
        guard selectedObjectID != nil else { return }
        inspectorRevealRequests += 1
    }

    /// - Parameter reveal: 畳んでいる詳細パネルを出すか。既定は出す。
    ///   **例外は右クリックの選び直しだけ** —— あれは「まず選ぶ」ための
    ///   選択で、詳細を見に来たわけではない（メニューが開いている最中に
    ///   ウインドウが広がることになる）。
    func selectOnly(_ object: K8sObject, reveal: Bool = true) {
        selectedObjectIDs = [object.id]
        selectionAnchorID = object.id
        selectedObjectID = object.id
        if reveal { requestInspectorReveal() }
    }

    /// ⌘ クリック。入っていれば外し、無ければ足す。
    func toggleSelection(of object: K8sObject) {
        if selectedObjectIDs.contains(object.id) {
            selectedObjectIDs.remove(object.id)
            // 主役を外したら、残っているものの中から選び直す。
            // **空のまま主役だけ残さない** — 詳細パネルが、選ばれていない
            // ものを映し続けることになる。
            if selectedObjectID == object.id {
                selectedObjectID = filteredObjects
                    .last { selectedObjectIDs.contains($0.id) }?.id
            }
        } else {
            selectedObjectIDs.insert(object.id)
            selectedObjectID = object.id
        }
        selectionAnchorID = selectedObjectID
        // 主役を外して空になったときは出さない（映すものが無い）。
        requestInspectorReveal()
    }

    /// shift クリック。起点からそこまでをまとめて選ぶ。
    func extendSelection(to object: K8sObject) {
        let rows = filteredObjects
        guard let target = rows.firstIndex(where: { $0.id == object.id }) else { return }
        guard let anchorID = selectionAnchorID ?? selectedObjectID,
              let anchor = rows.firstIndex(where: { $0.id == anchorID })
        else {
            selectOnly(object)
            return
        }
        let range = anchor <= target ? anchor...target : target...anchor
        selectedObjectIDs = Set(rows[range].map(\.id))
        // 起点は動かさない。動かすと次の shift クリックで範囲がずれる。
        selectedObjectID = object.id
        requestInspectorReveal()
    }

    func clearSelection() {
        selectedObjectIDs = []
        selectionAnchorID = nil
        selectedObjectID = nil
    }

    /// 表示用の並び。既定は `sorted(_:kind:)`、見出しを押していればその列。
    ///
    /// **比較のたびにセルを組み立てない。** `value` は毎回 JSON を辿るので、
    /// 素朴に比較関数の中で呼ぶと O(n log n) 回になる。先に 1 度だけ引く。
    private func sortedForDisplay(_ objects: [K8sObject]) -> [K8sObject] {
        guard let sort = sortDescriptor,
              let column = currentColumns.first(where: { $0.title == sort.columnTitle })
        else { return objects }

        let keyed = objects.map { (key: column.value($0).text, object: $0) }
        return keyed.sorted { lhs, rhs in
            // **「取れていない」を先頭に集めない。** 空欄や `—` は値ではないので、
            // 昇順でも降順でも末尾に置く。
            let leftMissing = Self.isMissing(lhs.key)
            let rightMissing = Self.isMissing(rhs.key)
            if leftMissing != rightMissing { return rightMissing }
            if leftMissing { return lhs.object.name < rhs.object.name }

            // 数字を含む文字列は数として比べる（`pod-10` が `pod-2` の後、
            // 再起動 `12` が `5` の後になる）。
            let order = lhs.key.localizedStandardCompare(rhs.key)
            if order != .orderedSame {
                return sort.ascending ? order == .orderedAscending : order == .orderedDescending
            }
            return lhs.object.name < rhs.object.name
        }.map(\.object)
    }

    private nonisolated static func isMissing(_ text: String) -> Bool {
        text.isEmpty || text == "—"
    }

    var namespaceLabel: String { selectedNamespace ?? "すべての Namespace" }

    /// ノードの詰まり具合。CPU とメモリのうち高いほう。並べ替えに使う。
    /// 取れないときは nil（0 とみなすと「測れていない」が「空いている」になる）。
    func nodeUsageRatio(_ node: K8sObject?) -> Double? {
        guard let node, let usage = metrics.nodes[node.name] else { return nil }
        let allocatable = node.nodeAllocatable
        let cpu = Quantity.ratio(usage.cpuCores, of: allocatable.cpuCores)
        let memory = Quantity.ratio(usage.memoryBytes, of: allocatable.memoryBytes)
        return [cpu, memory].compactMap { $0 }.max()
    }

    /// 配置画面が所有者を辿るための索引。`Namespace/種別/名前` で引く。
    /// 毎回 `first(where:)` で舐めると Pod の数だけ線形探索になる。
    ///
    /// **計算プロパティにしない。** 索引を作るための索引が、読むたびに
    /// 全 ReplicaSet / Job を舐め直していた。しかも配置画面はノードの箱ごとに
    /// これを読むので、1 描画あたり `ノード数 × 世代数` の挿入になっていた
    /// （ノード 20・世代 500 で 1 万回）。取得のたびに 1 度だけ組み立てる。
    private(set) var controllerIndex: [String: K8sObject] = [:]

    private nonisolated static func makeControllerIndex(
        _ controllers: [K8sObject]
    ) -> [String: K8sObject] {
        var index: [String: K8sObject] = [:]
        index.reserveCapacity(controllers.count)
        for object in controllers {
            guard let kind = object.kind else { continue }
            index["\(object.namespace ?? "")/\(kind.apiKind)/\(object.name)"] = object
        }
        return index
    }

    /// 概要をいまのクラスタ・Namespace で読めているか。
    /// 読めていない件数を 0 と偽らないための判定。
    var hasOverviewData: Bool { overview.isTallied }

    /// クラスタ全体の重み。舵輪の色になる。
    /// 概要で数えた Pod / ワークロード / ノードのうち、いちばん重いものを採る。
    var clusterHealth: StatusLevel {
        if setupErrorMessage != nil || errorMessage != nil { return .critical }
        let levels = [overview.nodes, overview.pods, overview.workloads]
            .flatMap(\.buckets)
            .map(\.level)
        // severityOrder は critical が 0。最小値がいちばん重い。
        return levels.min { $0.severityOrder < $1.severityOrder } ?? .neutral
    }

    /// 実際に現在値を取っている先。設定とクラスタの状況の両方で決まる。
    var activeMetricsSource: MetricsSource {
        switch metricsPreference {
        case .metricsServer:
            return metricsServerAvailable == true ? .metricsServer : .none
        case .prometheus:
            return prometheus.map { .prometheus($0) } ?? .none
        case .automatic:
            // 現在値は metrics-server を優先する。呼び出しが 2 本で済み、
            // rate() の窓に引きずられないぶん「いま」の値として素直。
            if metricsServerAvailable == true { return .metricsServer }
            return prometheus.map { .prometheus($0) } ?? .none
        }
    }

    /// 設定で選んだ先が使えないときの説明。空なら問題なし。
    var metricsSourceProblem: String? {
        switch metricsPreference {
        case .metricsServer where metricsServerAvailable == false:
            return "metrics-server を選んでいますが、このクラスタには入っていません。"
        case .prometheus where prometheus == nil:
            return "Prometheus を選んでいますが、このクラスタでは見つかりませんでした。"
        default:
            return nil
        }
    }

    /// 全ノードの使用量の合計。取得元が無ければ nil。
    var clusterUsage: ResourceUsage? {
        guard activeMetricsSource.isAvailable, !metrics.nodes.isEmpty else { return nil }
        return metrics.nodes.values.reduce(into: ResourceUsage()) { $0 = $0 + $1 }
    }

    /// 舵輪の回り方。取得中は速く、自動更新が生きているあいだはゆっくり回す。
    var activity: ClusterActivity {
        if setupErrorMessage != nil { return .idle }
        if isLoading { return .busy }
        return autoRefresh ? .live : .idle
    }

    // MARK: - 起動

    func bootstrap() async {
        // didSet に触られる前に読む。
        let savedNamespace = Defaults.namespace
        isBootstrapping = true
        defer { isBootstrapping = false }

        // **最初の `reload()` を待たずに読み込み中にする。** ここから下は
        // コンテキストの一覧・CRD・Namespace 一覧と、遅いクラスタなら数秒かかる
        // 問い合わせが続く。そのあいだ `isLoading` が偽のままだと、画面は
        // 「まだ何も引いていない」を**取得の結果として**出す —— 概要は
        // 対象なしのリングと「イベントを取得できませんでした」、一覧は「0 件」。
        // 実測（Connect Gateway 越しの GKE）で、起動から数秒はこの姿だった。
        isLoading = true

        do {
            let listed = try await kubectl.contexts()
            contexts = listed.all
            setupErrorMessage = nil
            // ターミナルに渡すときに要る。ここで 1 度引けば、以後は覚えている
            // （場所を変えたら `applyToKubectl` が解決結果ごと捨てる）。
            await refreshKubectlPath()

            // 前回のコンテキストを復元する。消えていたら kubeconfig の現在値に落とす。
            let restored = Defaults.context
            currentContext = (restored.flatMap { listed.all.contains($0) ? $0 : nil })
                ?? listed.current
                ?? listed.all.first
                ?? ""

            // 選択の復元より先に CRD を読む。保存値が CRD だった場合、
            // 種別の一覧が無いと組み立てられない。
            customTypes = await kubectl.customResourceTypes(context: currentContext)
            // 起動時に開く画面。前回の続きか、常に概要か。
            if Preferences.shared.startupScreen == .lastViewed,
               let stored = Defaults.selection {
                selection = Selection(storageKey: stored, customTypes: customTypes)
            } else {
                selection = .overview
            }

            await loadNamespaces()
            // サイドバー下部に出すので、概要を開かなくても分かるようにする。
            serverVersion = (try? await kubectl.serverVersion(context: currentContext)) ?? ""
            // 復元先の Namespace がもう無いなら「すべて」に戻す。
            // 残すと、空の一覧を見て「取れていない」と読めてしまう。
            selectedNamespace = savedNamespace.flatMap {
                namespaces.contains($0) ? $0 : nil
            }

            isBootstrapping = false
            reload()
            // **調べものは 1 か所から投げる。** 以前は `detectMetricsSources` を
            // ここで直接 await しつつ、`reload` の完了が
            // `recoverClusterInfoIfNeeded` 経由でもう 1 度呼んでいたので、
            // 起動のたびに Prometheus の探索（全 Service を順に叩く）が
            // 二重に走っていた。
            await refreshClusterInfo(includingFacts: false).value
        } catch {
            setupErrorMessage = error.localizedDescription
            // 起こす先が無いので `reload()` は走らない。ここで下ろさないと
            // 副題が「読み込み中…」のまま留まる。
            isLoading = false
        }
        startTicker()
    }

    /// 窓が見えているか。**見えていないあいだは自動更新を止める。**
    ///
    /// 止めないと、しまってあるノート PC でも 10 秒ごとに kubectl が
    /// 何本も立ち上がり続ける（一覧・メトリクス・履歴で 4〜8 本）。電池と
    /// API サーバの両方を無駄に食う。
    ///
    /// **「非アクティブ」で止めない。** 他のアプリを触っているあいだも、
    /// ロールアウトを横目で見ていることはふつうにある。止めるのは
    /// **隠れている**とき（しまった・完全に覆われた）だけ。
    var isWindowVisible = true {
        didSet {
            guard isWindowVisible, !oldValue else { return }
            // **戻ってきたら 1 回引く。** 止めているあいだに進んだぶんを
            // 次の周期まで古いまま出すと、見えている数字が事実とずれる。
            if autoRefresh, !isFetching { reload(showsSpinner: false) }
        }
    }

    /// いま取得が走っているか。
    ///
    /// **`isLoading` で代用しない。** あちらは「まだ出せる中身が無い」の意味で、
    /// スピナーの出し分けがそれに乗っている（更新のたびに画面が消えて点滅する
    /// のを避けるため、自動更新では立てない）。重なりの判定にそれを使うと
    /// **自動更新のときだけ素通りする。**
    ///
    /// 実測（Connect Gateway 越しの GKE・15 種別で 2.4MB）で 1 回の取得に
    /// 9.7〜15.2 秒かかり、更新間隔 10 秒がそれを追い越していた。`reload` は
    /// `loadTask?.cancel()` で**子プロセスまで殺す**ので、10 秒ごとに走っている
    /// 取得を捨ててゼロから引き直す状態になっていた（子 kubectl の pid が
    /// 経過 10 秒を超えず入れ替わり続ける、という形で観測できる）。
    private var isFetching = false

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.refreshInterval ?? 10
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                // **走っている取得を追い越さない。** 見送るのは自動更新だけで、
                // 人が押した更新や種別・Namespace の切り替えはこれまでどおり
                // 打ち切る（見ているものが変わったのに前の取得を待つ意味は無い）。
                guard self.autoRefresh, self.isWindowVisible, !self.isFetching else { continue }
                self.reload(showsSpinner: false)
            }
        }
    }

    // MARK: - 読み込み

    func reload(showsSpinner: Bool = true) {
        // 起こす先が無いなら読み込み中でもない。**黙って return しない** ——
        // `bootstrap()` が先に立てた印がそのまま残り、いつまでも
        // 「読み込み中…」の画面になる（コンテキストが 1 つも無いとき）。
        guard !currentContext.isEmpty else {
            isLoading = false
            return
        }
        generation += 1
        let token = generation
        let context = currentContext
        let namespace = selectedNamespace
        let selection = selection

        loadTask?.cancel()
        if showsSpinner { isLoading = true }
        // **取得の開始は同期で印を立てる。** Task の中で立てると、走り出す前に
        // 次の周期が来たときに素通りする。
        isFetching = true

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch selection {
                case .overview:
                    let snapshot = try await Self.loadOverview(
                        kubectl: self.kubectl, context: context, namespace: namespace)
                    guard token == self.generation else { return }
                    self.overview = snapshot
                    self.serverVersion = snapshot.serverVersion
                case .placement:
                    // Pod・ノード・所有者を 1 回の kubectl でまとめて取る。
                    // 別々に投げるとプロセスがそのぶん増え、片方だけ新しい
                    // 状態が混ざる（同じ時点の絵にならない）。
                    let listed = try await self.kubectl.list(
                        kinds: [.pod, .node, .replicaSet, .job,
                                .deployment, .statefulSet, .daemonSet, .cronJob,
                                .service, .ingress, .persistentVolumeClaim,
                                // PV は PVC の行き先。**PVC の名前だけでは
                                // 足りない** — どこに置かれているのか
                                // （容量・StorageClass）はこちらにしか無い。
                                .persistentVolume,
                                // NetworkPolicy は Service と同じくラベルで
                                // Pod を選ぶ。入口の話なので同じ図に載る。
                                .networkPolicy],
                                // **RBAC はここに入れない。** 逆引きに要るのは
                                // RoleBinding / ClusterRoleBinding だが、実測
                                // （Connect Gateway 越しの GKE）で
                                // `clusterrolebindings` 単独 6.54 秒 / 224KB、
                                // `rolebindings` 単独 3.87 秒。**種別を 1 つ
                                // 足すぶんだけ往復が増える**ので、10 秒ごとの
                                // 取得に載せると全 15 種別で 9.7〜15.2 秒かかり、
                                // 更新間隔を追い越していた。要るのは「たどる」の
                                // 権限の帯だけなので、起点が変わったときに引く
                                // （`serviceAccountBindings`。ClusterRole の
                                // rules を名前指定で引くのと同じ扱い）。
                        context: context, namespace: namespace)
                    guard token == self.generation else { return }
                    let loaded = listed.objects
                    self.objects = Self.sorted(
                        loaded.filter { $0.kind == .pod }, kind: .pod)
                    self.placementNodes = loaded
                        .filter { $0.kind == .node }
                        .sorted { $0.name < $1.name }
                    self.placementControllers = loaded.filter {
                        $0.kind == .replicaSet || $0.kind == .job
                    }
                    self.placementWorkloads = loaded.filter {
                        $0.kind == .deployment || $0.kind == .statefulSet
                            || $0.kind == .daemonSet || $0.kind == .cronJob
                    }
                    self.placementRelated = loaded.filter {
                        $0.kind == .service || $0.kind == .ingress
                            || $0.kind == .persistentVolumeClaim
                            || $0.kind == .persistentVolume
                            || $0.kind == .networkPolicy
                    }
                    // **図に欠けがあることを黙らない。** Service が読めていない
                    // だけなのに「入口が無い」と読めてしまう。
                    self.deniedKinds = listed.denied
                    self.unknownKinds = listed.unknown
                case .resource(let target):
                    let loaded: [K8sObject]
                    if target.builtIn == .event {
                        loaded = try await self.kubectl.events(
                            context: context, namespace: namespace)
                    } else {
                        loaded = try await self.kubectl.list(
                            resource: target.resourceName,
                            namespaced: target.isNamespaced,
                            context: context, namespace: namespace,
                            assuming: target.builtIn)
                    }
                    guard token == self.generation else { return }
                    // 既定の並びに落としてから、見出しを押していればその列で並べ直す。
                    self.objects = self.sortedForDisplay(
                        Self.sorted(loaded, kind: target.builtIn))
                }
                // 直前まで失敗していたか。取れるようになった瞬間を拾うため、
                // 消す前に見ておく。
                let wasFailing = self.errorMessage != nil
                self.errorMessage = nil
                self.lastUpdated = Date()
                await self.refreshMetrics()
                if showsSpinner || wasFailing {
                    await self.recoverClusterInfoIfNeeded()
                }
            } catch is CancellationError {
                // **印を下ろさない。** 打ち切られたときは、打ち切った側が
                // すでに次の取得を始めている（`reload` が同期で立て直す）。
                return
            } catch {
                guard token == self.generation else { return }
                self.errorMessage = error.localizedDescription
            }
            if token == self.generation {
                self.isLoading = false
                self.isFetching = false
            }
        }
    }

    /// 概要は 1 回の kubectl でまとめて取る。種別ごとに投げると
    /// プロセスが 10 個以上立ち上がり、そのぶん待たされる。
    private nonisolated static func loadOverview(
        kubectl: Kubectl, context: String, namespace: String?
    ) async throws -> OverviewSnapshot {
        let kinds: [ResourceKind] = [
            .pod, .deployment, .replicaSet, .statefulSet, .daemonSet, .job, .cronJob,
            .service, .ingress, .configMap, .secret, .persistentVolumeClaim,
            .persistentVolume, .namespace,
        ]

        async let resources = kubectl.list(kinds: kinds, context: context, namespace: namespace)
        async let nodes = kubectl.list(.node, context: context, namespace: nil)
        async let events = kubectl.events(context: context, namespace: namespace, limit: 30)
        async let version = kubectl.serverVersion(context: context)

        let listed = try await resources
        let all = listed.objects
        // ノードは別に引いているので、拒まれても概要そのものは出せる。
        // **0 台と書かない** — 数えられなかっただけなので、件数ごと落とす。
        let readNodes = try? await nodes
        let nodeObjects = readNodes ?? []
        // イベントとバージョンは取れなくても概要は出せるので、画面全体は
        // 失敗にしない。**ただしイベントは `[]` に潰さない** — 引けなかったのに
        // 「イベントはありません。」と書くのは、確かめていないことの断定になる
        // （nil のまま渡し、画面が言い分ける）。
        let eventObjects = try? await events
        let serverVersion = (try? await version) ?? "不明"

        var snapshot = OverviewSnapshot()
        // ここまで来たものだけが「概要を読めた」。**サイドバーの件数を数える
        // 経路（`refreshSidebarCounts`）で立てない** — あれは件数だけで、
        // リングも使用量の分母も持っていない。
        snapshot.isTallied = true
        snapshot.serverVersion = serverVersion

        var counts: [ResourceKind: Int] = [:]
        var byKind: [ResourceKind: [K8sObject]] = [:]
        // **要求した種別は 0 で埋めておく。** 1 件も無い種別は items に現れない
        // ので、埋めないと「0 件」と「まだ数えていない」が同じ nil になる。
        // **サーバが知らなかった種別も外す。** ここを 0 で埋めると、
        // 「解決できなかった」が「1 件も無い」になる。
        for kind in kinds where !listed.uncounted.contains(kind) { counts[kind] = 0 }
        for object in all {
            guard let kind = object.kind else { continue }
            counts[kind, default: 0] += 1
            byKind[kind, default: []].append(object)
        }
        // **拒まれた種別は入れない。** 0 と書くと「無い」ことにしてしまう。
        if let readNodes { counts[.node] = readNodes.count }
        snapshot.counts = counts
        snapshot.deniedKinds = listed.denied + (readNodes == nil ? [.node] : [])
        snapshot.unknownKinds = listed.unknown

        snapshot.pods = StatusTally.make(from: byKind[.pod] ?? [])
        snapshot.nodes = StatusTally.make(from: nodeObjects)
        snapshot.workloads = StatusTally.make(
            from: (byKind[.deployment] ?? []) + (byKind[.statefulSet] ?? [])
                + (byKind[.daemonSet] ?? []))
        snapshot.recentEvents = eventObjects
        snapshot.allocatable = nodeObjects.reduce(into: ResourceUsage()) { total, node in
            total = total + node.nodeAllocatable
        }
        return snapshot
    }

    /// コンテキストに紐づく調べものを取り直す。前のコンテキストのぶんは捨てる。
    ///
    /// **3 つを素の `Task` で投げない。** 世代番号もキャンセルも無いと、
    /// 遅れて返った前のクラスタの結果が新しいクラスタの状態を上書きする。
    /// - Parameter includingFacts: CRD・バージョン・Namespace 一覧も取り直すか。
    ///   起動時はこれらを順番に読む必要があってすでに手元にあるので、
    ///   **同じものをもう 1 度引かない**（kubectl のプロセスがそのぶん増える）。
    @discardableResult
    private func refreshClusterInfo(includingFacts: Bool = true) -> Task<Void, Never> {
        contextGeneration += 1
        let token = contextGeneration
        clusterInfoTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            // 直列にすると切り替えの体感が遅くなる。並べて投げ、
            // 書き込む直前に世代を見る。
            async let facts: Void = includingFacts
                ? self.loadClusterFacts(token: token)
                : self.refreshSidebarCounts(token: token)
            async let namespaces: Void = includingFacts
                ? self.loadNamespaces(token: token) : ()
            async let sources: Void = self.detectMetricsSources(token: token)
            _ = await (facts, namespaces, sources)
        }
        clusterInfoTask = task
        return task
    }

    /// 開いたときに調べ損ねたものを拾い直す。
    ///
    /// Namespace の一覧とメトリクスの有無は「クラスタを開いたときに 1 度だけ」
    /// 調べている。そのとき届かないと、**取れなかったのか無いのかを区別しないまま
    /// 空で固定される**。絞り込みのメニューが使えないまま、メトリクスの列が
    /// 出ないまま、アプリを建て直すまで直らない。実際にそうなった。
    ///
    /// **毎回調べ直さない。** 取れていないものがあるときだけ、しかも
    /// 「取れるようになった瞬間」か「人が更新を押したとき」に限る。自動更新の
    /// たびに走らせると、10 秒ごとに kubectl が 2〜3 本増える。
    private func recoverClusterInfoIfNeeded() async {
        // すでに調べている最中なら重ねない。Prometheus の探索は全 Service を
        // 順に叩くので、2 本走らせると kubectl がそのぶん増える。
        if let clusterInfoTask, !clusterInfoTask.isCancelled {
            await clusterInfoTask.value
        }
        if namespaces.isEmpty { await loadNamespaces() }
        if metricsServerAvailable != true, prometheus == nil {
            await detectMetricsSources()
        }
    }

    /// 使えるメトリクスの取得元を調べる。クラスタを開いたときに一度だけ。
    ///
    /// **書き込む直前に世代を見る。** ここは全 Service を順に叩くのでいちばん
    /// 遅く返る。守らないと、切り替え前のクラスタで見つけた場所を、いま開いて
    /// いるクラスタのものとして `UserDefaults` にまで書き込む。
    private func detectMetricsSources(token: Int? = nil) async {
        let context = currentContext
        guard !context.isEmpty else { return }
        let token = token ?? contextGeneration

        let available = await kubectl.metricsServerAvailable(
            context: context, namespace: selectedNamespace)
        guard token == contextGeneration else { return }
        metricsServerAvailable = available

        // Prometheus の探索は Service を全部見て順に叩くので時間がかかる。
        // 保存してある場所があればそれを先に確かめ、駄目なときだけ探し直す。
        // **覚えるのはコンテキストごと**（別のクラスタの場所を持ち越さない）。
        if let saved = Defaults.prometheus(for: context),
           await PrometheusClient.shared.probe(saved, context: context) {
            guard token == contextGeneration else { return }
            prometheus = saved
        } else {
            let found = await PrometheusClient.shared.discover(
                context: context, namespace: selectedNamespace)
            guard token == contextGeneration else { return }
            prometheus = found
            Defaults.setPrometheus(found, for: context)
        }
        await refreshMetrics()
    }

    /// 設定画面から取得元を探し直す。
    func rediscoverMetricsSources() async {
        Defaults.setPrometheus(nil, for: currentContext)
        prometheus = nil
        metricsServerAvailable = nil
        await detectMetricsSources()
    }

    /// 設定画面で手で指定された Prometheus を確かめて採用する。
    /// 応答しない場所を保存すると、以後ずっと空のグラフが出続ける。
    func useManualPrometheus(_ endpoint: PrometheusEndpoint) async -> Bool {
        guard await PrometheusClient.shared.probe(endpoint, context: currentContext) else {
            return false
        }
        prometheus = endpoint
        Defaults.setPrometheus(endpoint, for: currentContext)
        await refreshMetrics()
        return true
    }

    /// 一覧の再読み込みに合わせて使用量も取り直す。
    ///
    /// ここも書き込む直前に世代を見る。別のクラスタの使用量が混ざると、
    /// ノード名が一致した場合に**別クラスタの数字がそのまま棒になる**。
    private func refreshMetrics() async {
        let context = currentContext
        guard !context.isEmpty else { return }
        let token = contextGeneration

        let loaded: MetricsSnapshot
        switch activeMetricsSource {
        case .metricsServer:
            loaded = await kubectl.metrics(context: context, namespace: selectedNamespace)
        case .prometheus(let endpoint):
            loaded = await PrometheusClient.shared.snapshot(
                endpoint: endpoint, context: context, namespace: selectedNamespace)
        case .none:
            loaded = MetricsSnapshot()
        }
        guard token == contextGeneration else { return }
        metrics = loaded
        await refreshHistories()
    }

    /// 推移の範囲は設定から。刻みは点が 60 個前後に収まる値を選ぶ
    /// （範囲を広げても点が増えすぎないように）。
    private var historyWindow: TimeInterval {
        TimeInterval(Preferences.shared.historyWindowMinutes) * 60
    }
    private var historyStep: TimeInterval { max(15, (historyWindow / 60).rounded()) }

    /// 履歴は一覧より粗い間隔で取り直す。
    ///
    /// 範囲クエリは 1 回につき kubectl を 1 本起こす。自動更新（既定 10 秒）に
    /// 合わせて毎回投げると CPU とメモリで 2 本、選択中があればさらに 2 本増える。
    /// 30 分幅のグラフが 10 秒ごとに動く必要はないので、間隔を空ける。
    private var historyRefreshInterval: TimeInterval {
        TimeInterval(Preferences.shared.historyRefreshSeconds)
    }
    private var lastHistoryRefresh: Date?

    private func refreshHistories(force: Bool = false) async {
        guard prometheus != nil else { return }
        if !force, let last = lastHistoryRefresh,
           Date().timeIntervalSince(last) < historyRefreshInterval {
            return
        }
        lastHistoryRefresh = Date()

        if case .overview = selection {
            await refreshClusterHistory()
        }
        await refreshSelectedHistory()
    }

    private func refreshClusterHistory() async {
        guard let endpoint = prometheus else { return }
        let context = currentContext
        async let cpu = PrometheusClient.shared.queryRange(
            PrometheusClient.Query.clusterCPU(), endpoint: endpoint, context: context,
            duration: historyWindow, step: historyStep)
        async let memory = PrometheusClient.shared.queryRange(
            PrometheusClient.Query.clusterMemory(), endpoint: endpoint, context: context,
            duration: historyWindow, step: historyStep)
        clusterHistory = MetricsHistory(
            subject: "cluster", cpu: await cpu, memory: await memory)
    }

    private func refreshSelectedHistory() async {
        guard let endpoint = prometheus, let object = selectedObject else { return }
        let context = currentContext

        let queries: (cpu: String, memory: String)
        switch object.kind {
        case .pod:
            guard let namespace = object.namespace else { return }
            queries = (
                PrometheusClient.Query.podCPU(namespace: namespace, pod: object.name),
                PrometheusClient.Query.podMemory(namespace: namespace, pod: object.name))
        case .node:
            queries = (
                PrometheusClient.Query.nodeCPU(node: object.name),
                PrometheusClient.Query.nodeMemory(node: object.name))
        default:
            return
        }

        async let cpu = PrometheusClient.shared.queryRange(
            queries.cpu, endpoint: endpoint, context: context,
            duration: historyWindow, step: historyStep)
        async let memory = PrometheusClient.shared.queryRange(
            queries.memory, endpoint: endpoint, context: context,
            duration: historyWindow, step: historyStep)
        let loaded = MetricsHistory(subject: object.id, cpu: await cpu, memory: await memory)

        // 待っているあいだに選択が変わっていたら捨てる。
        guard selectedObjectID == object.id else { return }
        selectedHistory = loaded
    }

    /// コンテキストを切り替えたときに取り直すもの。
    private func loadClusterFacts(token: Int? = nil) async {
        let context = currentContext
        guard !context.isEmpty else { return }
        let token = token ?? contextGeneration

        let types = await kubectl.customResourceTypes(context: context)
        guard token == contextGeneration else { return }
        customTypes = types

        let version = (try? await kubectl.serverVersion(context: context)) ?? ""
        guard token == contextGeneration else { return }
        serverVersion = version

        await refreshSidebarCounts(token: token)
    }

    /// サイドバーに出す件数。
    ///
    /// 概要を開いたときは `loadOverview` が数えるが、一覧から起動すると
    /// 誰も数えないままサイドバーの数字が空になる。件数の持ち場を
    /// サイドバーに決めた以上、そこが空では意味がないので一度だけ数える。
    private func refreshSidebarCounts(token: Int? = nil) async {
        let context = currentContext
        guard case .resource = selection, !context.isEmpty else { return }
        let token = token ?? contextGeneration
        guard let listed = try? await kubectl.list(
            kinds: Self.countedKinds, context: context, namespace: selectedNamespace)
        else { return }
        guard token == contextGeneration else { return }

        // 拒まれた種別と、サーバが知らなかった種別は数に入れない
        // （`nil` のままにして「まだ分からない」を保つ）。
        var counts: [ResourceKind: Int] = [:]
        for kind in Self.countedKinds where !listed.uncounted.contains(kind) { counts[kind] = 0 }
        for object in listed.objects {
            guard let kind = object.kind else { continue }
            counts[kind, default: 0] += 1
        }
        // **`isTallied` は立てない。** ここで分かるのは件数だけで、リングの
        // 内訳も使用量の分母（allocatable）も無い。立てると、一覧から概要へ
        // 移ったときに読み込み中ではなく 0 の並んだリングが出る。
        overview.counts = counts
        overview.deniedKinds = listed.denied
        overview.unknownKinds = listed.unknown
    }

    /// まとめて数える種別。Node も含めるので、概要の別取得とは別に持つ。
    private static let countedKinds: [ResourceKind] = [
        .pod, .deployment, .replicaSet, .statefulSet, .daemonSet, .job, .cronJob,
        .service, .ingress, .networkPolicy, .configMap, .secret, .persistentVolumeClaim,
        .persistentVolume, .node, .namespace,
    ]

    private func loadNamespaces(token: Int? = nil) async {
        let context = currentContext
        guard !context.isEmpty else { return }
        let token = token ?? contextGeneration

        // Namespace の一覧権限が無いクラスタもある。絞り込みが使えないだけなので、
        // 画面全体をエラーにはしない。
        let listed = (try? await kubectl.namespaces(context: context)) ?? []
        guard token == contextGeneration else { return }
        namespaces = listed
    }

    /// 一覧の既定の並び。問題のあるものを上に出す。
    private nonisolated static func sorted(
        _ objects: [K8sObject], kind: ResourceKind?
    ) -> [K8sObject] {
        if kind == .event {
            // すでに新しい順。並べ直さない。
            return objects
        }
        return objects.sorted { lhs, rhs in
            let lhsLevel = StatusResolver.health(for: lhs).level.severityOrder
            let rhsLevel = StatusResolver.health(for: rhs).level.severityOrder
            if lhsLevel != rhsLevel { return lhsLevel < rhsLevel }
            if lhs.namespace != rhs.namespace {
                return (lhs.namespace ?? "") < (rhs.namespace ?? "")
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: - 操作

    /// 操作に使う種別名。オブジェクトからではなく、いま開いている一覧から取る。
    /// CRD は組み込みの enum に無く、オブジェクト側からは引けない。
    private var currentResourceName: String? { actionTarget?.resourceName }

    // MARK: - どのクラスタを触っているか

    /// いまのコンテキストの覚え書き（色・別名・読み取り専用）。
    var contextProfile: ContextProfile { Preferences.shared.profile(for: currentContext) }

    /// 画面に出す名前。別名を付けていればそちら。
    ///
    /// **kubeconfig の名前をそのまま信じない。**
    /// `gke_my-project_asia-northeast1_prod` のような名前は帯に収まらず、
    /// 読み分けにも使えない。
    var contextDisplayName: String {
        let alias = contextProfile.alias.trimmingCharacters(in: .whitespaces)
        return alias.isEmpty ? currentContext : alias
    }

    var isReadOnly: Bool { contextProfile.isReadOnly }

    /// 絞り込み欄へ移りたい、という合図。
    ///
    /// **メニューから画面の `@FocusState` を触れない**（コマンドはウインドウの
    /// 外側にいる）ので、数を 1 つ増やして知らせる。数にするのは、同じ要求が
    /// 続いたときにも変化として届くようにするため。
    private(set) var searchFocusRequests = 0

    func requestSearchFocus() { searchFocusRequests += 1 }

    /// アプリが使っている kubectl の実体。**ターミナルに渡すときも同じものを指す。**
    /// ここだけ別の実体になると、アプリでは通るのにターミナルでは通らない
    /// （あるいはその逆）が起きて、切り分けができなくなる。
    private(set) var kubectlPath: String?

    func refreshKubectlPath() async {
        kubectlPath = await kubectl.resolvedExecutablePath()
    }

    /// 変更を行う経路の入口で必ず通す関門。
    ///
    /// **画面で隠すだけにしない。** 読み取り専用のときは操作のボタンごと
    /// 出さないが、メニューの取りこぼしや、開いたままのシートから届く道が
    /// 残りうる。**実際に kubectl を起こす手前で止める**のがいちばん確実。
    private func refuseIfReadOnly(_ what: String) -> Bool {
        guard isReadOnly else { return false }
        actionNotice = nil
        noticeTask?.cancel()
        errorMessage = "\(contextDisplayName) は読み取り専用に設定されています。"
            + "\(what)は行いませんでした。変更するには設定の「コンテキスト」で解除してください。"
        return true
    }

    func yaml(for object: K8sObject) async -> Result<String, Error> {
        guard let resource = currentResourceName else {
            return .success("")
        }
        do {
            return .success(
                try await kubectl.yaml(
                    resource: resource, object: object, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    /// 選択中のオブジェクトに紐づくイベント。
    ///
    /// **自動更新に載せない。** 開いているあいだ 10 秒ごとに引き直すと、
    /// 見ている最中に行が入れ替わるうえ、選択のあるかぎり kubectl が 1 本
    /// 増え続ける。取り直しは詳細パネルの「再読み込み」が明示的に行う。
    func events(for object: K8sObject) async -> Result<[K8sObject], Error> {
        do {
            return .success(
                try await kubectl.events(for: object, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    /// ServiceAccount に付いている Binding。**逆引きなので一覧が要る。**
    ///
    /// `--field-selector` は `subjects` を絞れないので、RoleBinding と
    /// ClusterRoleBinding を引いて手元で突き合わせるしかない。**だから
    /// 自動更新に載せない** —— 実測（Connect Gateway 越しの GKE）で
    /// `clusterrolebindings` 6.54 秒 / 224KB、`rolebindings` 3.87 秒で、
    /// 10 秒ごとの取得に載せると更新間隔を追い越す（`roleRules` と同じ判断を
    /// もう 1 段手前にも適用する）。
    ///
    /// **Namespace は口座から決める。** すべて同じ Namespace なら `-n` で絞り、
    /// ノードを起点にしたときのように跨っていれば全 Namespace を引く。
    ///
    /// **引けなかったことを「Binding が無い」にしない。** RBAC を読めない
    /// クラスタはふつうにあるので、拒まれた種別は種別名で返す。
    func serviceAccountBindings(for accounts: [AccessAccount]) async -> AccessBindings {
        guard !accounts.isEmpty else { return AccessBindings(isLoaded: true) }

        let namespaces = Set(accounts.map { $0.namespace ?? "" })
        let namespace = namespaces.count == 1 ? namespaces.first.flatMap {
            $0.isEmpty ? nil : $0
        } : nil
        let kinds: [ResourceKind] = [.roleBinding, .clusterRoleBinding]

        do {
            let listed = try await kubectl.list(
                kinds: kinds, context: currentContext, namespace: namespace)
            var result = AccessBindings(isLoaded: true)
            result.byAccount = WorkloadRelations.bindings(
                for: accounts, among: listed.objects)
            // **一部だけ読めたことを黙らない。** ClusterRoleBinding だけ拒まれる
            // のはふつうにあり、そのとき出ているのは RoleBinding だけになる。
            result.failures = listed.uncounted.map(\.displayName)
            return result
        } catch {
            return AccessBindings(
                failures: kinds.map(\.displayName), isLoaded: true)
        }
    }

    /// Binding が指しているロールの中身。
    ///
    /// **自動更新に載せない。** ClusterRole は rules を持つぶん重く（実測
    /// 264KB）、配置画面は 10 秒ごとに引き直す。起点が変わったときだけ、
    /// **紐づいている数個を名前指定で**引く（イベントと同じ考え方）。
    ///
    /// **引けなかったことを「規則が無い」にしない。** RBAC を読めない
    /// クラスタはふつうにあるので、失敗は失敗として返す。
    func roleRules(for bindings: [AccessBinding]) async -> AccessRules {
        var wanted: [String?: Set<String>] = [:]
        for binding in bindings where !binding.roleName.isEmpty {
            wanted[binding.roleNamespace, default: []].insert(binding.roleName)
        }
        guard !wanted.isEmpty else { return AccessRules(isLoaded: true) }

        var result = AccessRules(isLoaded: true)
        let context = currentContext
        for (namespace, names) in wanted {
            do {
                let roles = try await kubectl.roles(
                    named: Array(names), namespace: namespace, context: context)
                for role in roles {
                    let kind = namespace == nil ? "ClusterRole" : "Role"
                    result.roles["\(kind)/\(namespace ?? "")/\(role.name)"] = role
                }
            } catch {
                // **どちらが引けなかったかを言う。** 「読めません」だけだと、
                // 出ている規則のほうまで疑うことになる。
                let label = namespace.map { "\($0) の Role" } ?? "ClusterRole"
                result.failures.append(label)
            }
        }
        return result
    }

    /// このオブジェクトを管理している HPA。レプリカ数を変える前に見る。
    func autoscalers(for object: K8sObject) async -> Result<[K8sObject], Error> {
        do {
            return .success(
                try await kubectl.autoscalers(for: object, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    func delete(_ object: K8sObject) async {
        guard let resource = currentResourceName else { return }
        // **「削除しました」と言わない。** `--wait=false` で投げているので、
        // 戻ってきた時点ではまだ消えていない。行もしばらく残る（Terminating）。
        await perform("\(object.name) の削除を要求しました。消えるまで少しかかります") {
            try await self.kubectl.delete(
                resource: resource, object: object, context: self.currentContext)
        }
    }

    /// 選んでいるものをまとめて消す。
    func deleteSelected() async {
        await delete(selectedObjects)
    }

    /// 渡されたものをまとめて消す。
    ///
    /// **確認に出したものを、そのまま消す。** 以前は確認の側が
    /// `deleteSelected()` を呼んでおり、**文面に名前を並べた対象と、押した
    /// 時点の `selectedObjects` が食い違いうる**状態だった（右クリックで選択が
    /// 動く経路がある）。捕まえた配列をそのまま持ち回れば、確認に出した
    /// ものと消えるものが必ず一致する。
    func delete(_ objects: [K8sObject]) async {
        guard let resource = currentResourceName else { return }
        guard !objects.isEmpty else { return }
        if objects.count == 1 {
            await delete(objects[0])
            return
        }
        await perform("\(objects.count) 件の削除を要求しました。消えるまで少しかかります") {
            try await self.kubectl.delete(
                resource: resource, objects: objects, context: self.currentContext)
        }
    }

    /// 右クリックの操作対象。
    ///
    /// **選択の書き換えを待たずに決める。** 一覧は `.onAppear` で選び直して
    /// いるが、メニューの中身はそれより**先に**評価される。以前は
    /// `selectedObjects` を直に読んでいたので、3 件選んだ状態で未選択の行を
    /// 右クリックすると「3 件を削除」のメニューが出た。ここで純粋に決めれば、
    /// いつ選択が動いても対象はぶれない（選び直しは見た目を合わせるだけになる）。
    func contextMenuTargets(for object: K8sObject) -> [K8sObject] {
        let selected = selectedObjects
        return selected.count > 1 && selectedObjectIDs.contains(object.id)
            ? selected : [object]
    }

    func scale(_ object: K8sObject, to replicas: Int) async {
        await perform("\(object.name) のレプリカ数を \(replicas) にしました") {
            try await self.kubectl.scale(object, to: replicas, context: self.currentContext)
        }
    }

    func restart(_ object: K8sObject) async {
        // 入れ替わるのはこれから。「再起動しました」は言い過ぎ。
        await perform("\(object.name) のローリング再起動を始めました") {
            try await self.kubectl.rolloutRestart(object, context: self.currentContext)
        }
    }

    // MARK: - 資源の割り当てを変える

    /// 上限を決める前に、いま実際にどれだけ使っているかを引く。
    ///
    /// **「取れていない」と「metrics-server が無い」を混ぜない。** 取得元が
    /// 無いときは nil を返し、画面は使用量の欄ごと出さない（列の扱いと同じ）。
    func containerUsage(for object: K8sObject) async -> [String: [ResourceUsage]]? {
        guard activeMetricsSource != .none,
              let namespace = object.namespace,
              let selector = object.raw.path("spec.selector.matchLabels")?.stringDictionary,
              !selector.isEmpty
        else { return nil }
        // **引けなかったことを「取得元が無い」にしない。** nil は「そもそも
        // 見に行く先が無い」で画面は欄ごと出さないが、引きに行って駄目だった
        // ときは空を返し、画面は `—` を出す（値が 0 なのではない）。
        return (try? await kubectl.containerUsage(
            selector: selector, namespace: namespace, context: currentContext)) ?? [:]
    }

    /// 資源の割り当てだけを書き換える。dry-run で先に聞ける。
    func patchResources(
        _ object: K8sObject, patch: String, dryRun: Bool
    ) async -> Result<String, Error> {
        guard let resource = actionTarget?.resourceName else {
            return .failure(KubectlError.unsupportedRollout(object.kind?.displayName ?? ""))
        }
        if !dryRun, refuseIfReadOnly("資源の割り当ての変更") {
            return .failure(ReadOnlyError(context: contextDisplayName))
        }
        do {
            let message = try await kubectl.patch(
                object, resource: resource, patch: patch,
                dryRun: dryRun, context: currentContext)
            if !dryRun {
                errorMessage = nil
                showNotice("\(object.name) の資源の割り当てを変えました")
                try? await Task.sleep(for: .milliseconds(400))
                reload(showsSpinner: false)
            }
            return .success(message)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 編集した YAML を書き戻す

    /// 書き戻したら何が起きるかを、実際には書かずに聞く（drain / undo と同じ）。
    ///
    /// **こちらで検証しない。** 綴り間違い（`unknown field "spec.replicasss"`）も、
    /// 変えられないフィールド（`may not change once set`）も、他人の更新との
    /// ぶつかり（`Conflict`）も、`--dry-run=server` が admission webhook まで
    /// 通したうえで答える。自前で条件を書けば、その分だけ本番とずれる。
    func validateYAML(_ yaml: String) async -> Result<String, Error> {
        do {
            return .success(
                try await kubectl.replace(yaml: yaml, dryRun: true, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    /// **失敗を握りつぶさない。** シートは開いたままにしたいので、
    /// `perform` と違って結果を返す（閉じるかどうかは呼び出し側が決める）。
    func applyYAML(_ yaml: String, to object: K8sObject) async -> Result<Void, Error> {
        if refuseIfReadOnly("書き戻し") { return .failure(ReadOnlyError(context: contextDisplayName)) }
        do {
            try await kubectl.replace(yaml: yaml, dryRun: false, context: currentContext)
            errorMessage = nil
            showNotice("\(object.name) の YAML を書き戻しました")
            try? await Task.sleep(for: .milliseconds(400))
            reload(showsSpinner: false)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    // MARK: - 前の状態に戻す

    /// 世代の一覧。**自動更新に載せない** — シートを開いたときだけ引く
    /// （イベントや RBAC の規則と同じ考え方）。
    func rolloutHistory(for object: K8sObject) async -> Result<[Kubectl.RolloutRevision], Error> {
        do {
            return .success(try await kubectl.rolloutHistory(object, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    /// その世代の中身。戻る先に何が入っているかを見るためのもの。
    func revisionDetail(
        for object: K8sObject, revision: Int
    ) async -> Result<String, Error> {
        do {
            return .success(
                try await kubectl.rolloutRevisionDetail(
                    object, revision: revision, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    /// 戻したら何が起きるかを、実際には動かさずに聞く（drain と同じ扱い）。
    ///
    /// **こちらで判断しない。** 「いま動いているものと同じ世代だから何も
    /// 起きない」も「止めているあいだは戻せない」も kubectl が知っていて、
    /// そのまま文面で返ってくる。自前で条件を書くと、kubectl の判断とずれる。
    func rollbackPreview(
        _ object: K8sObject, toRevision revision: Int?
    ) async -> Result<String, Error> {
        do {
            return .success(
                try await kubectl.rolloutUndo(
                    object, toRevision: revision, dryRun: true, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    func rollback(_ object: K8sObject, toRevision revision: Int?) async {
        let target = revision.map { "第 \($0) 世代" } ?? "1 つ前の世代"
        // 入れ替わるのはこれから。「戻しました」は言い過ぎ。
        await perform("\(object.name) を \(target) に戻す要求をしました") {
            try await self.kubectl.rolloutUndo(
                object, toRevision: revision, dryRun: false, context: self.currentContext)
        }
    }

    func setRolloutPaused(_ object: K8sObject, paused: Bool) async {
        let notice = paused
            ? "\(object.name) の更新を止めました"
            : "\(object.name) の更新を再開しました"
        await perform(notice) {
            try await self.kubectl.rolloutPause(
                object, paused: paused, context: self.currentContext)
        }
    }

    func setCordon(_ node: K8sObject, unschedulable: Bool) async {
        let notice = unschedulable
            ? "\(node.name) への新しい Pod の配置を止めました"
            : "\(node.name) への配置を許可しました"
        await perform(notice) {
            try await self.kubectl.cordon(
                node, unschedulable: unschedulable, context: self.currentContext)
        }
    }

    /// drain したら何が起きるかを、実際には動かさずに聞く。
    ///
    /// **確認の文面を自分で組み立てない。** 退避できるかどうかは
    /// PodDisruptionBudget や DaemonSet の有無で決まり、こちらで数えた
    /// 「Pod が N 個あります」は kubectl が実際にやることとずれる。
    /// `--dry-run=server` に答えさせれば、出るのは本番と同じ判断。
    func drainPreview(
        _ node: K8sObject, options: Kubectl.DrainOptions
    ) async -> Result<String, Error> {
        var options = options
        options.dryRun = true
        do {
            return .success(
                try await kubectl.drain(node, options: options, context: currentContext))
        } catch {
            return .failure(error)
        }
    }

    func drain(_ node: K8sObject, options: Kubectl.DrainOptions) async {
        await perform("\(node.name) からの退避を要求しました") {
            try await self.kubectl.drain(
                node, options: options, context: self.currentContext)
        }
    }

    /// 操作を実行し、**通ったことを必ず知らせる**。
    ///
    /// **黙って成功しない。** 以前は失敗のときだけ帯を出していた。削除は
    /// `--wait=false` なので押しても行が残り、再起動は見た目が何も変わらない。
    /// 合図が無いと**押せていないように見える**ので、もう一度押すことになる。
    ///
    /// **やったことより多く言わない。** 要求を投げただけのものは「要求しました」。
    /// ここで「削除しました」と書くと、残っている行のほうが間違いに見える。
    private func perform(
        _ notice: String, _ action: @escaping () async throws -> Void,
        describedAs what: String = "この操作"
    ) async {
        guard !refuseIfReadOnly(what) else { return }
        do {
            try await action()
            errorMessage = nil
            showNotice(notice)
            // 変更の結果が反映されるまで一拍置く。即座に読み直すと
            // 変更前の状態が返ってきて、失敗したように見える。
            try? await Task.sleep(for: .milliseconds(400))
            reload(showsSpinner: false)
        } catch {
            // 失敗したときに前の成功が残っていると、どちらの話か分からない。
            actionNotice = nil
            noticeTask?.cancel()
            errorMessage = error.localizedDescription
        }
    }

    /// 数秒で自分から消える。**閉じる操作を持たせない** — 消えるものに
    /// ✕ を付けると、押す前に消えて押し損ねる。
    private func showNotice(_ message: String) {
        actionNotice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.actionNotice = nil
        }
    }

    // MARK: - ログ

    /// 選択に合わせてログを切り替える。ログを開けない種別のときは何もしない。
    ///
    /// **閉じているパネルをここで開かない。** 行を選んだだけで
    /// `kubectl logs -f` が走るのは、見るつもりのない Pod にも取得を掛けること
    /// になる。開けるのは「ログを見る」を押したときだけ（`showLogs`）で、
    /// ここが受け持つのは**すでに開いているパネルの行き先を差し替える**ことだけ。
    private func followLogsToSelection() {
        guard logRequest != nil,
              followsSelectionForLogs,
              let object = selectedObject,
              // **開ける形なら何でも追う。** Pod / Job は 1 つを、
              // Deployment / Service はまとめて。ここだけ Pod と Job に
              // 限ると、まとめ読みを開いたまま Deployment を選び直しても
              // 前の対象が残り、どれを見ているのか分からなくなる。
              let request = PodLogRequest(opening: object)
        else { return }
        logRequest = request
    }

    /// 明示的にログを開く。パネルが開くのはここだけ。
    ///
    /// **指定はここで組み立てない。** 「1 つを読む」と「まとめて読む」の
    /// どちらを開くかは押したボタンが決めていて（`ResourceActionSet`）、
    /// ここで種別から導き直すと出し分けが 2 か所になる。
    ///
    /// Pod をここで解決しないのも同じ話 — 解決には kubectl が要り、しかも
    /// 「1 つも無い」「引けなかった」が起こる。それを言える場所
    /// （`LogContent`）まで指定のまま持っていく。
    func showLogs(_ request: PodLogRequest) {
        logRequest = request
    }

    /// セレクタが掴んでいる Pod。新しい順に返す。
    ///
    /// **「1 つも無い」と「引けなかった」を分ける。** 完了した Job の Pod は
    /// `ttlSecondsAfterFinished` や Pod のガベージコレクションで消え、ログも
    /// 一緒に消える。引けなかっただけのときに「もう残っていません」と書くと、
    /// 確かめていないことを断定することになる。
    func pods(matchingSelector selector: [String: String], namespace: String)
        async -> Result<[K8sObject], Error>
    {
        do {
            let pods = try await kubectl.pods(
                matchingLabels: selector, namespace: namespace, context: currentContext)
            // 再試行で作り直された Pod が並ぶので、新しいものを先に。
            return .success(pods.sorted {
                ($0.creationTimestamp ?? .distantPast) > ($1.creationTimestamp ?? .distantPast)
            })
        } catch {
            return .failure(error)
        }
    }

    /// パネルを閉じる。
    func closeLogs() {
        logRequest = nil
    }

    /// ログの取得。**行の塊で返す。** 1 行ずつ渡すと、受け手は行の数だけ
    /// 画面を作り直すことになる（`ProcessRunner.stream`）。
    func logStream(
        namespace: String, target: Kubectl.LogTarget, options: Kubectl.LogOptions
    ) async -> Result<(AsyncStream<[String]>, ProcessHandle), Error> {
        do {
            let stream = try await kubectl.logStream(
                namespace: namespace, target: target, options: options,
                context: currentContext)
            return .success((stream.lines, stream.handle))
        } catch {
            return .failure(error)
        }
    }
}

// MARK: - 保存する設定

private enum Defaults {
    // UserDefaults 自体はスレッド安全だが、型としては Sendable でない。
    private nonisolated(unsafe) static let store = UserDefaults.standard

    static var context: String? {
        get { store.string(forKey: "selectedContext") }
        set { store.set(newValue, forKey: "selectedContext") }
    }

    static var namespace: String? {
        get { store.string(forKey: "selectedNamespace") }
        set { store.set(newValue, forKey: "selectedNamespace") }
    }

    static var selection: String? {
        get { store.string(forKey: "selection") }
        set { store.set(newValue, forKey: "selection") }
    }

    /// 見つけた Prometheus。探索が重いので覚えておく。
    ///
    /// **コンテキストごとに持つ。** 1 つのキーに 1 つだけ入れていたので、
    /// A → B と切り替えるたびに B の結果（見つからなければ nil）で上書きされ、
    /// A に戻るとまた全 Service を順に叩く探索からやり直しになっていた。
    /// 覚えている意味が半分無くなっていた形。
    ///
    /// 保存キーを変えてあるので、古い 1 つぶんの値は読まれずに残る。**移行しない**
    /// —— これはただのキャッシュで、次の探索で入り直る（`probe` で必ず確かめる
    /// ので、古い値を信じて誤った先に繋ぐこともない）。
    static func prometheus(for context: String) -> PrometheusEndpoint? {
        prometheusByContext[context]
    }

    static func setPrometheus(_ endpoint: PrometheusEndpoint?, for context: String) {
        guard !context.isEmpty else { return }
        var all = prometheusByContext
        // 見つからなかったことを覚えない（次に開いたときは探し直す）。
        if let endpoint { all[context] = endpoint } else { all.removeValue(forKey: context) }
        prometheusByContext = all
    }

    private static var prometheusByContext: [String: PrometheusEndpoint] {
        get {
            guard let data = store.data(forKey: "prometheusEndpoints") else { return [:] }
            return (try? JSONDecoder().decode(
                [String: PrometheusEndpoint].self, from: data)) ?? [:]
        }
        set {
            store.set(
                (try? JSONEncoder().encode(newValue)) ?? Data(),
                forKey: "prometheusEndpoints")
        }
    }
}
