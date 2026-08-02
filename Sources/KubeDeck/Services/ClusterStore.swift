import Foundation
import Observation

/// 画面全体の状態。kubectl の呼び出しはすべてここを経由する。
@MainActor
@Observable
final class ClusterStore {
    enum Selection: Hashable, Sendable {
        case overview
        case resource(ResourceTarget)

        static func kind(_ kind: ResourceKind) -> Selection { .resource(.builtIn(kind)) }

        /// UserDefaults に入れるための表現。
        var storageKey: String {
            switch self {
            case .overview: return "overview"
            case .resource(.builtIn(let kind)): return kind.rawValue
            case .resource(.custom(let type)): return "crd:\(type.resourceName)"
            }
        }

        /// 保存値から戻す。CRD はクラスタを見ないと組み立てられないので、
        /// 見つかった種別の一覧を渡してもらう。読めなければ概要に落ちる。
        init(storageKey: String, customTypes: [CustomResourceType]) {
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
            Task { await self.loadClusterFacts() }
            Task { await self.detectMetricsSources() }
            Task { await self.loadNamespaces() }
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
            reload()
        }
    }

    var selection: Selection = .overview {
        didSet {
            guard selection != oldValue else { return }
            Defaults.selection = selection.storageKey
            selectedObjectID = nil
            searchText = ""
            objects = []
            // 別の種別を開いたのに前の Pod のログが下に残ると、
            // どれを見ているのか分からなくなる。
            logRequest = nil
            guard !isBootstrapping else { return }
            reload()
        }
    }

    var objects: [K8sObject] = []
    var overview = OverviewSnapshot()
    var serverVersion: String = ""

    var searchText: String = ""
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

    /// Pod を選んだらログも切り替えるか。
    ///
    /// 既定は有効。パネルの ✕ で無効になり、以後は行を選んでも勝手に開かない
    /// （閉じたのに選ぶたび開き直すと、✕ が効かないものに見える）。
    /// もう一度ログを開けば追従が戻る。
    var followsSelectionForLogs: Bool = Preferences.shared.followsSelectionForLogs {
        didSet { Preferences.shared.followsSelectionForLogs = followsSelectionForLogs }
    }

    var isLoading = false
    var errorMessage: String?
    var setupErrorMessage: String?
    var lastUpdated: Date?

    var autoRefresh: Bool = Preferences.shared.autoRefresh {
        didSet { Preferences.shared.autoRefresh = autoRefresh }
    }
    var refreshInterval: TimeInterval = Preferences.shared.refreshInterval {
        didSet { Preferences.shared.refreshInterval = refreshInterval }
    }

    /// 概要を読めた印。件数を「未取得」と「0 件」で区別するために持つ。
    private var loadedOverviewCounts: [ResourceKind: Int] = [:]

    /// 起動時の復元中は、プロパティの didSet から連鎖する再読み込みを止める。
    /// 止めないと `currentContext` の didSet が `selectedNamespace` を nil に
    /// 落とし、その didSet が保存値を上書きするので、前回の Namespace が
    /// 読み出す前に消える。
    private var isBootstrapping = false
    private var loadTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    /// 遅れて返ってきた古い結果で新しい表示を上書きしないための世代番号。
    private var generation = 0

    private let kubectl = Kubectl.shared

    // MARK: - 派生

    /// いま開いている一覧の対象。概要のときは nil。
    var currentTarget: ResourceTarget? {
        if case .resource(let target) = selection { return target }
        return nil
    }

    /// 組み込み種別のときだけ返す。種別ごとの特別扱いの判定に使う。
    var currentKind: ResourceKind? { currentTarget?.builtIn }

    /// Namespace 列を出すのは「すべて」を見ているときだけ。
    var showsNamespaceColumn: Bool { selectedNamespace == nil }

    var filteredObjects: [K8sObject] {
        guard let target = currentTarget else { return [] }
        guard !searchText.trimmingCharacters(in: .whitespaces).isEmpty else { return objects }
        return objects.filter { ResourceTable.matches($0, target: target, query: searchText) }
    }

    var selectedObject: K8sObject? {
        guard let selectedObjectID else { return nil }
        return objects.first { $0.id == selectedObjectID }
    }

    var namespaceLabel: String { selectedNamespace ?? "すべての Namespace" }

    /// 概要を一度でも読めたか。読めていない件数を 0 と偽らないための判定。
    var hasOverviewData: Bool { !loadedOverviewCounts.isEmpty }

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

        do {
            let listed = try await kubectl.contexts()
            contexts = listed.all
            setupErrorMessage = nil

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
            await refreshSidebarCounts()
            await detectMetricsSources()
        } catch {
            setupErrorMessage = error.localizedDescription
        }
        startTicker()
    }

    private func startTicker() {
        tickerTask?.cancel()
        tickerTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.refreshInterval ?? 10
                try? await Task.sleep(for: .seconds(interval))
                guard let self, !Task.isCancelled else { return }
                guard self.autoRefresh, !self.isLoading else { continue }
                self.reload(showsSpinner: false)
            }
        }
    }

    // MARK: - 読み込み

    func reload(showsSpinner: Bool = true) {
        guard !currentContext.isEmpty else { return }
        generation += 1
        let token = generation
        let context = currentContext
        let namespace = selectedNamespace
        let selection = selection

        loadTask?.cancel()
        if showsSpinner { isLoading = true }

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                switch selection {
                case .overview:
                    let snapshot = try await Self.loadOverview(
                        kubectl: self.kubectl, context: context, namespace: namespace)
                    guard token == self.generation else { return }
                    self.overview = snapshot
                    self.loadedOverviewCounts = snapshot.counts
                    self.serverVersion = snapshot.serverVersion
                case .resource(let target):
                    let loaded: [K8sObject]
                    if target.builtIn == .event {
                        loaded = try await self.kubectl.events(
                            context: context, namespace: namespace)
                    } else {
                        loaded = try await self.kubectl.list(
                            resource: target.resourceName,
                            namespaced: target.isNamespaced,
                            context: context, namespace: namespace)
                    }
                    guard token == self.generation else { return }
                    self.objects = Self.sorted(loaded, kind: target.builtIn)
                }
                self.errorMessage = nil
                self.lastUpdated = Date()
                await self.refreshMetrics()
            } catch is CancellationError {
                return
            } catch {
                guard token == self.generation else { return }
                self.errorMessage = error.localizedDescription
            }
            if token == self.generation { self.isLoading = false }
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

        let all = try await resources
        let nodeObjects = try await nodes
        // イベントとバージョンは取れなくても概要は出せるので、失敗を握りつぶす。
        let eventObjects = (try? await events) ?? []
        let serverVersion = (try? await version) ?? "不明"

        var snapshot = OverviewSnapshot()
        snapshot.serverVersion = serverVersion

        var counts: [ResourceKind: Int] = [:]
        var byKind: [ResourceKind: [K8sObject]] = [:]
        for object in all {
            guard let kind = object.kind else { continue }
            counts[kind, default: 0] += 1
            byKind[kind, default: []].append(object)
        }
        counts[.node] = nodeObjects.count
        snapshot.counts = counts

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

    /// 使えるメトリクスの取得元を調べる。クラスタを開いたときに一度だけ。
    private func detectMetricsSources() async {
        let context = currentContext
        guard !context.isEmpty else { return }

        metricsServerAvailable = await kubectl.metricsServerAvailable(context: context)

        // Prometheus の探索は Service を全部見て順に叩くので時間がかかる。
        // 保存してある場所があればそれを先に確かめ、駄目なときだけ探し直す。
        if let saved = Defaults.prometheus,
           await PrometheusClient.shared.probe(saved, context: context) {
            prometheus = saved
        } else {
            let found = await PrometheusClient.shared.discover(context: context)
            prometheus = found
            Defaults.prometheus = found
        }
        await refreshMetrics()
    }

    /// 設定画面から取得元を探し直す。
    func rediscoverMetricsSources() async {
        Defaults.prometheus = nil
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
        Defaults.prometheus = endpoint
        await refreshMetrics()
        return true
    }

    /// 一覧の再読み込みに合わせて使用量も取り直す。
    private func refreshMetrics() async {
        guard !currentContext.isEmpty else { return }
        switch activeMetricsSource {
        case .metricsServer:
            metrics = await kubectl.metrics(
                context: currentContext, namespace: selectedNamespace)
        case .prometheus(let endpoint):
            metrics = await PrometheusClient.shared.snapshot(
                endpoint: endpoint, context: currentContext, namespace: selectedNamespace)
        case .none:
            metrics = MetricsSnapshot()
        }
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
    private func loadClusterFacts() async {
        guard !currentContext.isEmpty else { return }
        customTypes = await kubectl.customResourceTypes(context: currentContext)
        serverVersion = (try? await kubectl.serverVersion(context: currentContext)) ?? ""
        await refreshSidebarCounts()
    }

    /// サイドバーに出す件数。
    ///
    /// 概要を開いたときは `loadOverview` が数えるが、一覧から起動すると
    /// 誰も数えないままサイドバーの数字が空になる。件数の持ち場を
    /// サイドバーに決めた以上、そこが空では意味がないので一度だけ数える。
    private func refreshSidebarCounts() async {
        guard case .resource = selection, !currentContext.isEmpty else { return }
        guard let objects = try? await kubectl.list(
            kinds: Self.countedKinds, context: currentContext, namespace: selectedNamespace)
        else { return }

        var counts: [ResourceKind: Int] = [:]
        for object in objects {
            guard let kind = object.kind else { continue }
            counts[kind, default: 0] += 1
        }
        overview.counts = counts
        loadedOverviewCounts = counts
    }

    /// まとめて数える種別。Node も含めるので、概要の別取得とは別に持つ。
    private static let countedKinds: [ResourceKind] = [
        .pod, .deployment, .replicaSet, .statefulSet, .daemonSet, .job, .cronJob,
        .service, .ingress, .configMap, .secret, .persistentVolumeClaim,
        .persistentVolume, .node, .namespace,
    ]

    private func loadNamespaces() async {
        guard !currentContext.isEmpty else { return }
        do {
            namespaces = try await kubectl.namespaces(context: currentContext)
        } catch {
            // Namespace の一覧権限が無いクラスタもある。絞り込みが
            // 使えないだけなので、画面全体をエラーにはしない。
            namespaces = []
        }
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
    private var currentResourceName: String? { currentTarget?.resourceName }

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

    func delete(_ object: K8sObject) async {
        guard let resource = currentResourceName else { return }
        await perform {
            try await self.kubectl.delete(
                resource: resource, object: object, context: self.currentContext)
        }
    }

    func scale(_ object: K8sObject, to replicas: Int) async {
        await perform {
            try await self.kubectl.scale(object, to: replicas, context: self.currentContext)
        }
    }

    func restart(_ object: K8sObject) async {
        await perform {
            try await self.kubectl.rolloutRestart(object, context: self.currentContext)
        }
    }

    func setCordon(_ node: K8sObject, unschedulable: Bool) async {
        await perform {
            try await self.kubectl.cordon(
                node, unschedulable: unschedulable, context: self.currentContext)
        }
    }

    private func perform(_ action: @escaping () async throws -> Void) async {
        do {
            try await action()
            errorMessage = nil
            // 変更の結果が反映されるまで一拍置く。即座に読み直すと
            // 変更前の状態が返ってきて、失敗したように見える。
            try? await Task.sleep(for: .milliseconds(400))
            reload(showsSpinner: false)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - ログ

    /// 選択に合わせてログを切り替える。Pod 以外を選んだときは何もしない。
    private func followLogsToSelection() {
        guard followsSelectionForLogs,
              let object = selectedObject,
              object.kind == .pod
        else { return }
        logRequest = PodLogRequest(pod: object)
    }

    /// 明示的にログを開く。追従も有効に戻す。
    func showLogs(for pod: K8sObject) {
        followsSelectionForLogs = true
        logRequest = PodLogRequest(pod: pod)
    }

    /// パネルを閉じる。以後は選んでも開かない。
    func closeLogs() {
        logRequest = nil
        followsSelectionForLogs = false
    }

    func logStream(
        namespace: String, pod: String, options: Kubectl.LogOptions
    ) async -> Result<(AsyncStream<String>, ProcessHandle), Error> {
        do {
            let stream = try await kubectl.logStream(
                namespace: namespace, pod: pod, options: options, context: currentContext)
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
    static var prometheus: PrometheusEndpoint? {
        get {
            guard let data = store.data(forKey: "prometheusEndpoint") else { return nil }
            return try? JSONDecoder().decode(PrometheusEndpoint.self, from: data)
        }
        set {
            store.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: "prometheusEndpoint")
        }
    }

}
