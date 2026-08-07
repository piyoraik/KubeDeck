import Foundation
import Observation

/// アプリの設定。**保存する値はすべてここに集める。**
///
/// 以前は `ClusterStore` の中の private enum に散らしていたが、項目を足すたびに
/// ストアを触ることになり、どこに何があるのか追えなくなった。定義・既定値・
/// 保存キーを 1 か所に置き、画面はここを読む。
///
/// 項目を足すときは、この 3 つを揃えるだけでよい。
/// 1. `Key` に保存キーを足す
/// 2. 既定値付きの格納プロパティを足し、`didSet` で書き戻す
/// 3. `SettingsView` に行を足す
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let store = UserDefaults.standard

    private enum Key {
        static let startupScreen = "startupScreen"
        static let showsSidebarCounts = "showsSidebarCounts"
        static let rowDensity = "rowDensity"
        static let inspectorPlacement = "inspectorPlacement"
        static let opensInspectorOnSelection = "opensInspectorOnSelection"
        static let hiddenKinds = "hiddenKinds"
        static let showsCustomResources = "showsCustomResources"
        static let hidesEmptyKinds = "hidesEmptyKinds"

        static let placementTileSize = "placementTileSize"
        static let placementNodeOrder = "placementNodeOrder"
        static let placementHidesEmptyNodes = "placementHidesEmptyNodes"
        static let placementGrouping = "placementGrouping"
        static let placementMetric = "placementMetric"
        static let placementGroupsByWorkload = "placementGroupsByWorkload"

        static let logTailLines = "logTailLines"
        static let logBufferLines = "logBufferLines"
        static let logFollowsByDefault = "logFollowsByDefault"
        static let logWrapsByDefault = "logWrapsByDefault"
        static let logShowsTimestamps = "logShowsTimestamps"
        static let logColorsSources = "logColorsSources"
        static let followsSelectionForLogs = "followsSelectionForLogs"

        static let metricsPreference = "metricsPreference"
        static let historyWindowMinutes = "historyWindowMinutes"
        static let historyRefreshSeconds = "historyRefreshSeconds"
        static let usageWarningPercent = "usageWarningPercent"
        static let usageCriticalPercent = "usageCriticalPercent"

        static let autoRefresh = "autoRefresh"
        static let refreshInterval = "refreshInterval"
        static let requestTimeoutSeconds = "requestTimeoutSeconds"
        static let kubectlPathOverride = "kubectlPathOverride"
        static let contextProfiles = "contextProfiles"

        static let checksForUpdates = "checksForUpdates"
        static let downloadsUpdatesAutomatically = "downloadsUpdatesAutomatically"
        static let updateCheckIntervalHours = "updateCheckIntervalHours"
    }

    // MARK: - 一般

    /// 起動したときに開く画面。
    var startupScreen: StartupScreen {
        didSet { store.set(startupScreen.rawValue, forKey: Key.startupScreen) }
    }

    /// サイドバーの行末に件数を出すか。
    var showsSidebarCounts: Bool {
        didSet { store.set(showsSidebarCounts, forKey: Key.showsSidebarCounts) }
    }

    /// 一覧の行の詰め方。
    var rowDensity: RowDensity {
        didSet { store.set(rowDensity.rawValue, forKey: Key.rowDensity) }
    }

    /// 詳細パネルを右に置くか、下に置くか。
    ///
    /// 縦に長い一覧を見るときは右、列の多い一覧を見るときは下のほうが読める。
    /// **下に置いたときはログと同じ帯に横並びで入れる**（`RootView.dockBody`）。
    /// 上下に積むと 2 本の仕切りができ、どちらも本文が数行しか残らない。
    var inspectorPlacement: InspectorPlacement = .trailing {
        didSet { store.set(inspectorPlacement.rawValue, forKey: Key.inspectorPlacement) }
    }

    /// 畳んでいるとき、行やタイルを押したら詳細パネルを出すか。
    ///
    /// **出す方向にしか効かない。** 畳むのはツールバーのボタンだけで、
    /// 選択が無くなっても勝手には閉じない（`RootView`）。列を広く見たくて
    /// 畳んでいる人には、押すたびに出てくるのは邪魔なので切れるようにしてある。
    var opensInspectorOnSelection: Bool {
        didSet { store.set(opensInspectorOnSelection, forKey: Key.opensInspectorOnSelection) }
    }

    /// サイドバーに出さない種別。
    var hiddenKinds: Set<String> {
        didSet { store.set(Array(hiddenKinds), forKey: Key.hiddenKinds) }
    }

    /// CRD の節を出すか。
    var showsCustomResources: Bool {
        didSet { store.set(showsCustomResources, forKey: Key.showsCustomResources) }
    }

    /// 件数 0 の種別を隠すか。**件数が分かっているものだけを対象にする。**
    /// 未取得を 0 とみなして隠すと、種別そのものが消えたように見える。
    var hidesEmptyKinds: Bool {
        didSet { store.set(hidesEmptyKinds, forKey: Key.hidesEmptyKinds) }
    }

    // MARK: - 配置

    /// タイルの大きさ。Pod が数百ある環境では名前を落としたほうが見渡せる。
    var placementTileSize: PlacementTileSize = .medium {
        didSet { store.set(placementTileSize.rawValue, forKey: Key.placementTileSize) }
    }

    /// ノードの並び。偏りを探すときは Pod 数や使用率の順が要る。
    var placementNodeOrder: PlacementNodeOrder = .name {
        didSet { store.set(placementNodeOrder.rawValue, forKey: Key.placementNodeOrder) }
    }

    /// Pod が 0 のノードを隠すか。**既定は出す。** 空いているノードが見えないと
    /// 偏りの片側が分からない。数が多くて邪魔なときだけ切る。
    var placementHidesEmptyNodes = false {
        didSet { store.set(placementHidesEmptyNodes, forKey: Key.placementHidesEmptyNodes) }
    }

    /// 何を箱にするか。ノードを箱にすると「どこに載っているか」、
    /// ワークロードを箱にすると「どこに散っているか」が見える。
    var placementGrouping: PlacementGrouping = .node {
        didSet { store.set(placementGrouping.rawValue, forKey: Key.placementGrouping) }
    }

    /// 配置の棒が何を表すか。CPU で詰まる環境とメモリで詰まる環境があり、
    /// 片方しか見ないなら並べても場所を食うだけ。
    var placementMetric: PlacementMetric = .both {
        didSet { store.set(placementMetric.rawValue, forKey: Key.placementMetric) }
    }

    /// ノード別のとき、Pod を所有者（Deployment など）でまとめるか。
    /// **既定はまとめる。** レプリカが並ぶだけの Pod 名を数百並べても読めない。
    /// Pod が少ないクラスタでは、まとめるほうが縦に伸びるので切れるようにする。
    var placementGroupsByWorkload = true {
        didSet { store.set(placementGroupsByWorkload, forKey: Key.placementGroupsByWorkload) }
    }

    func isVisible(_ kind: ResourceKind) -> Bool { !hiddenKinds.contains(kind.rawValue) }

    func setVisible(_ kind: ResourceKind, _ visible: Bool) {
        if visible { hiddenKinds.remove(kind.rawValue) } else { hiddenKinds.insert(kind.rawValue) }
    }

    // MARK: - ログ

    /// 開いたときに遡って読む行数（`kubectl logs --tail`）。
    var logTailLines: Int {
        didSet { store.set(logTailLines, forKey: Key.logTailLines) }
    }

    /// 画面に保持する上限。超えたぶんは古いほうから捨てる。
    var logBufferLines: Int {
        didSet { store.set(logBufferLines, forKey: Key.logBufferLines) }
    }

    var logFollowsByDefault: Bool {
        didSet { store.set(logFollowsByDefault, forKey: Key.logFollowsByDefault) }
    }

    var logWrapsByDefault: Bool {
        didSet { store.set(logWrapsByDefault, forKey: Key.logWrapsByDefault) }
    }

    var logShowsTimestamps: Bool {
        didSet { store.set(logShowsTimestamps, forKey: Key.logShowsTimestamps) }
    }

    /// 混ぜて読んでいるときに、出どころ（`pod/container`）を色で分けるか。
    ///
    /// **色が付くのは出どころの列だけ。** 帯・下地・本文は深刻度のまま
    /// （`Palette.logSources`）。切れるようにしてあるのは、色が増えること
    /// 自体を嫌う場面があるため。
    var logColorsSources: Bool {
        didSet { store.set(logColorsSources, forKey: Key.logColorsSources) }
    }

    /// Pod を選んだらログも切り替えるか。
    var followsSelectionForLogs: Bool {
        didSet { store.set(followsSelectionForLogs, forKey: Key.followsSelectionForLogs) }
    }

    // MARK: - メトリクス

    var metricsPreference: MetricsSourcePreference {
        didSet { store.set(metricsPreference.rawValue, forKey: Key.metricsPreference) }
    }

    /// 推移グラフの範囲（分）。
    var historyWindowMinutes: Int {
        didSet { store.set(historyWindowMinutes, forKey: Key.historyWindowMinutes) }
    }

    /// 範囲を人が読む形にしたもの（`30 分` / `3 時間`）。
    ///
    /// **画面に「30 分」と直に書かない。** 範囲は設定で 15〜180 分から選べるのに、
    /// 概要のカードと詳細パネルの見出しが 30 分固定になっており、変えても
    /// ラベルだけ嘘のままだった。書式を 1 か所に持って、設定画面の選択肢とも揃える。
    var historyWindowLabel: String { Self.windowLabel(minutes: historyWindowMinutes) }

    static func windowLabel(minutes: Int) -> String {
        minutes < 60
            ? String(localized: "\(minutes) 分")
            : String(localized: "\(minutes / 60) 時間")
    }

    /// 推移を取り直す間隔（秒）。範囲クエリは 1 回につき kubectl を 1 本起こすので、
    /// 一覧の更新間隔とは別に持つ。
    var historyRefreshSeconds: Int {
        didSet { store.set(historyRefreshSeconds, forKey: Key.historyRefreshSeconds) }
    }

    /// 使用率がこれを超えると「処理中」の色になる。
    ///
    /// **「異常」を追い越させない。** `usageLevel` は critical から先に見るので、
    /// 注意 90 / 異常 80 のような組み合わせを許すと**警告色が一度も出なくなり**、
    /// 80% 超がいきなり赤になる。壊れはしないが黙って意味が変わるので、
    /// 片方を動かしたらもう片方を押し出す。
    var usageWarningPercent: Int {
        didSet {
            store.set(usageWarningPercent, forKey: Key.usageWarningPercent)
            if usageCriticalPercent < usageWarningPercent {
                usageCriticalPercent = usageWarningPercent
            }
            publishThresholds()
        }
    }

    /// 使用率がこれを超えると「異常」の色になる。
    var usageCriticalPercent: Int {
        didSet {
            store.set(usageCriticalPercent, forKey: Key.usageCriticalPercent)
            if usageWarningPercent > usageCriticalPercent {
                usageWarningPercent = usageCriticalPercent
            }
            publishThresholds()
        }
    }

    /// 一覧のセルを組み立てる閉包は MainActor の外で走るので、設定を直接
    /// 読ませられない。変更のたびにここへ写しを置き、そちらを読ませる。
    nonisolated(unsafe) static var usageThresholds: (warning: Double, critical: Double) =
        (0.8, 0.9)

    private func publishThresholds() {
        Self.usageThresholds = (
            warning: Double(usageWarningPercent) / 100,
            critical: Double(usageCriticalPercent) / 100)
    }

    // MARK: - 接続

    var autoRefresh: Bool {
        didSet { store.set(autoRefresh, forKey: Key.autoRefresh) }
    }

    var refreshInterval: TimeInterval {
        didSet { store.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    /// kubectl の待ち上限（秒）。到達できないクラスタで固まらないための値。
    var requestTimeoutSeconds: Int {
        didSet {
            store.set(requestTimeoutSeconds, forKey: Key.requestTimeoutSeconds)
            applyToKubectl()
        }
    }

    /// kubectl の場所を手で指定する。空なら自動で探す。
    var kubectlPathOverride: String {
        didSet {
            store.set(kubectlPathOverride, forKey: Key.kubectlPathOverride)
            applyToKubectl()
        }
    }

    // MARK: - コンテキストごとの覚え書き

    /// コンテキスト名 → 色・別名・読み取り専用。
    ///
    /// **辞書ごと入れ替える。** 中身だけ書き換えても `didSet` は走らない
    /// （値型の入れ子を直接触ると保存し損ねる）ので、更新は必ず
    /// `setProfile(_:for:)` を通す。
    var contextProfiles: ContextProfiles {
        didSet {
            store.set(
                (try? JSONEncoder().encode(contextProfiles)) ?? Data(),
                forKey: Key.contextProfiles)
        }
    }

    func profile(for context: String) -> ContextProfile {
        contextProfiles[context] ?? ContextProfile()
    }

    /// コンテキストの札をすべて消す。
    ///
    /// **`resetAll()` から切り離してある。** 読み取り専用が外れるのは
    /// 取り返しの付く話ではないので、それだけを名指しで消せる口を別に置く
    /// （押す場所も「コンテキスト」タブに限る）。
    func clearContextProfiles() {
        contextProfiles = [:]
    }

    func setProfile(_ profile: ContextProfile, for context: String) {
        var profiles = contextProfiles
        // **既定のままのものを覚えない。** 覚えると、コンテキストを触るたびに
        // 中身の無い項目が増えていく。
        if profile.isEmpty {
            profiles.removeValue(forKey: context)
        } else {
            profiles[context] = profile
        }
        contextProfiles = profiles
    }

    // MARK: - 更新

    /// 新しい版が出ていないか自分で確認しにいくか。
    ///
    /// **Sparkle 側の設定と二重に持たない。** `Info.plist` に
    /// `SUEnableAutomaticChecks` を置いて Sparkle 自身の問い合わせを止めてあり、
    /// 実際に効く値はここから `applyToUpdater()` で渡す。両方を生かすと、
    /// 設定画面のスイッチと Sparkle のダイアログのどちらが効いているのか分からなくなる。
    var checksForUpdates: Bool {
        didSet {
            store.set(checksForUpdates, forKey: Key.checksForUpdates)
            applyToUpdater()
        }
    }

    /// 見つけた更新を、尋ねる前に落としておくか。落とすだけで、入れ替えは尋ねる。
    var downloadsUpdatesAutomatically: Bool {
        didSet {
            store.set(downloadsUpdatesAutomatically, forKey: Key.downloadsUpdatesAutomatically)
            applyToUpdater()
        }
    }

    /// 確認しにいく間隔（時間）。
    var updateCheckIntervalHours: Int {
        didSet {
            store.set(updateCheckIntervalHours, forKey: Key.updateCheckIntervalHours)
            applyToUpdater()
        }
    }

    // MARK: - 読み出し

    private init() {
        startupScreen = StartupScreen(rawValue: store.string(forKey: Key.startupScreen) ?? "")
            ?? .lastViewed
        showsSidebarCounts = store.object(forKey: Key.showsSidebarCounts) as? Bool ?? true
        rowDensity = RowDensity(rawValue: store.string(forKey: Key.rowDensity) ?? "") ?? .standard
        inspectorPlacement =
            InspectorPlacement(rawValue: store.string(forKey: Key.inspectorPlacement) ?? "")
            ?? .trailing
        opensInspectorOnSelection =
            store.object(forKey: Key.opensInspectorOnSelection) as? Bool ?? true
        hiddenKinds = Set(store.stringArray(forKey: Key.hiddenKinds) ?? [])
        showsCustomResources = store.object(forKey: Key.showsCustomResources) as? Bool ?? true
        hidesEmptyKinds = store.object(forKey: Key.hidesEmptyKinds) as? Bool ?? false

        placementTileSize =
            PlacementTileSize(rawValue: store.string(forKey: Key.placementTileSize) ?? "")
            ?? .medium
        placementNodeOrder =
            PlacementNodeOrder(rawValue: store.string(forKey: Key.placementNodeOrder) ?? "")
            ?? .name
        placementHidesEmptyNodes =
            store.object(forKey: Key.placementHidesEmptyNodes) as? Bool ?? false
        placementGrouping =
            PlacementGrouping(rawValue: store.string(forKey: Key.placementGrouping) ?? "")
            ?? .node
        placementMetric =
            PlacementMetric(rawValue: store.string(forKey: Key.placementMetric) ?? "") ?? .both
        placementGroupsByWorkload =
            store.object(forKey: Key.placementGroupsByWorkload) as? Bool ?? true

        logTailLines = store.object(forKey: Key.logTailLines) as? Int ?? 500
        logBufferLines = store.object(forKey: Key.logBufferLines) as? Int ?? 5_000
        logFollowsByDefault = store.object(forKey: Key.logFollowsByDefault) as? Bool ?? true
        logWrapsByDefault = store.object(forKey: Key.logWrapsByDefault) as? Bool ?? true
        logShowsTimestamps = store.object(forKey: Key.logShowsTimestamps) as? Bool ?? false
        logColorsSources = store.object(forKey: Key.logColorsSources) as? Bool ?? true
        followsSelectionForLogs =
            store.object(forKey: Key.followsSelectionForLogs) as? Bool ?? true

        metricsPreference =
            MetricsSourcePreference(rawValue: store.string(forKey: Key.metricsPreference) ?? "")
            ?? .automatic
        historyWindowMinutes = store.object(forKey: Key.historyWindowMinutes) as? Int ?? 30
        historyRefreshSeconds = store.object(forKey: Key.historyRefreshSeconds) as? Int ?? 60
        usageWarningPercent = store.object(forKey: Key.usageWarningPercent) as? Int ?? 80
        usageCriticalPercent = store.object(forKey: Key.usageCriticalPercent) as? Int ?? 90

        autoRefresh = store.object(forKey: Key.autoRefresh) as? Bool ?? true
        refreshInterval = store.object(forKey: Key.refreshInterval) as? TimeInterval ?? 10
        requestTimeoutSeconds = store.object(forKey: Key.requestTimeoutSeconds) as? Int ?? 20
        kubectlPathOverride = store.string(forKey: Key.kubectlPathOverride) ?? ""
        contextProfiles = store.data(forKey: Key.contextProfiles)
            .flatMap { try? JSONDecoder().decode(ContextProfiles.self, from: $0) } ?? [:]

        checksForUpdates = store.object(forKey: Key.checksForUpdates) as? Bool ?? true
        downloadsUpdatesAutomatically =
            store.object(forKey: Key.downloadsUpdatesAutomatically) as? Bool ?? false
        updateCheckIntervalHours = store.object(forKey: Key.updateCheckIntervalHours) as? Int ?? 24

        applyToKubectl()
        publishThresholds()
        applyToUpdater()
    }

    /// Sparkle 側にも渡す。`SPUUpdater` は `@Observable` ではないので、
    /// 設定はここが持ち、変わるたびに投げ込む（kubectl と同じやり方）。
    private func applyToUpdater() {
        UpdateController.shared.configure(
            checksAutomatically: checksForUpdates,
            downloadsAutomatically: downloadsUpdatesAutomatically,
            checkIntervalSeconds: TimeInterval(updateCheckIntervalHours) * 3_600)
    }

    /// kubectl 側にも渡す。アクターなので値を投げ込む形にする。
    private func applyToKubectl() {
        let timeout = requestTimeoutSeconds
        let path = kubectlPathOverride
        Task { await Kubectl.shared.configure(timeoutSeconds: timeout, executableOverride: path) }
    }

    /// すべて既定値に戻す。
    ///
    /// **`contextProfiles` は消さない。** ここに含めていたので、一般タブの
    /// ボタン 1 つで**読み取り専用の指定が黙って外れていた**（確認の文面も
    /// 「接続先のコンテキスト…は残ります」で、消えることに触れていなかった）。
    /// あれは「見た目や既定値の設定」ではなく**そのクラスタに付けた札**で、
    /// このアプリで唯一「壊せなくする」仕組み。巻き添えにしてよいものではない。
    /// 消したいときは設定の「コンテキスト」から明示的に消す（`clearContextProfiles`）。
    func resetAll() {
        startupScreen = .lastViewed
        showsSidebarCounts = true
        rowDensity = .standard
        inspectorPlacement = .trailing
        opensInspectorOnSelection = true
        hiddenKinds = []
        showsCustomResources = true
        hidesEmptyKinds = false
        placementTileSize = .medium
        placementNodeOrder = .name
        placementHidesEmptyNodes = false
        placementGrouping = .node
        placementMetric = .both
        placementGroupsByWorkload = true
        logTailLines = 500
        logBufferLines = 5_000
        logFollowsByDefault = true
        logWrapsByDefault = true
        logShowsTimestamps = false
        logColorsSources = true
        followsSelectionForLogs = true
        metricsPreference = .automatic
        historyWindowMinutes = 30
        historyRefreshSeconds = 60
        usageWarningPercent = 80
        usageCriticalPercent = 90
        autoRefresh = true
        refreshInterval = 10
        requestTimeoutSeconds = 20
        kubectlPathOverride = ""
        checksForUpdates = true
        downloadsUpdatesAutomatically = false
        updateCheckIntervalHours = 24
    }
}

/// 起動時に開く画面。
enum StartupScreen: String, CaseIterable, Identifiable, Sendable {
    case lastViewed
    case overview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lastViewed: return String(localized: "前回の続き")
        case .overview: return String(localized: "概要")
        }
    }
}

/// 一覧の行の詰め方。
enum RowDensity: String, CaseIterable, Identifiable, Sendable {
    case comfortable
    case standard
    case compact

    var id: String { rawValue }

    var title: String {
        switch self {
        case .comfortable: return String(localized: "ゆったり")
        case .standard: return String(localized: "標準")
        case .compact: return String(localized: "詰める")
        }
    }

    /// 行の上下の余白。
    var verticalPadding: CGFloat {
        switch self {
        case .comfortable: return 10
        case .standard: return 7
        case .compact: return 4
        }
    }

    var fontSize: CGFloat {
        switch self {
        case .comfortable: return 13
        case .standard: return 12
        case .compact: return 11
        }
    }
}


/// 詳細パネルの置き場所。
///
/// **「出す／畳む」と混ぜない。** そちらはツールバーのボタンが持つ一時的な状態で、
/// こちらは「いちど決めたら変えない」類のものなので設定に残す。
enum InspectorPlacement: String, CaseIterable, Identifiable, Sendable {
    case trailing
    case bottom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trailing: return String(localized: "右")
        case .bottom: return String(localized: "下")
        }
    }

    var symbol: String {
        switch self {
        case .trailing: return "sidebar.trailing"
        case .bottom: return "rectangle.bottomthird.inset.filled"
        }
    }
}

/// 配置画面のタイルの大きさ。
enum PlacementTileSize: String, CaseIterable, Identifiable, Sendable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var title: String {
        switch self {
        case .small: return String(localized: "小")
        case .medium: return String(localized: "中")
        case .large: return String(localized: "大")
        }
    }

    /// 折り返しの下限幅。小さいほど 1 行に多く並ぶ。
    var minimumWidth: Double {
        switch self {
        case .small: return 22
        case .medium: return 150
        case .large: return 240
        }
    }

    var maximumWidth: Double {
        switch self {
        case .small: return 22
        case .medium: return 260
        case .large: return 380
        }
    }

    /// 名前を出すか。**小は出さない。** 数百の Pod を名前つきで並べると、
    /// 縦に伸びて「どこに寄っているか」という肝心の絵が見えなくなる。
    var showsName: Bool { self != .small }
}

/// 配置画面のノードの並び。
enum PlacementNodeOrder: String, CaseIterable, Identifiable, Sendable {
    case name
    case podCount
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return String(localized: "名前順")
        case .podCount: return String(localized: "Pod が多い順")
        case .usage: return String(localized: "使用率が高い順")
        }
    }
}


/// 配置画面で何を箱にするか。
/// 配置画面で何を箱にするか。
///
/// **「まとめる／まとめない」をここに入れない。** 箱も答える問いも同じで、
/// 中の並べ方が違うだけ。見方が 1 つ増えたように見えて、選ぶときに迷う。
/// 表示の詰め方は設定（`placementGroupsByWorkload`）が持つ。
enum PlacementGrouping: String, CaseIterable, Identifiable, Sendable {
    case node
    case workload
    case map

    var id: String { rawValue }

    var title: String {
        switch self {
        case .node: return String(localized: "ノード別")
        case .workload: return String(localized: "ワークロード別")
        case .map: return String(localized: "たどる")
        }
    }

    var help: String {
        switch self {
        case .node: return String(localized: "ノードごとに、載っている Pod を並べます。")
        case .workload:
            return String(localized: "ワークロードごとに、どのノードへ何個ずつ載っているかを出します。")
        case .map:
            return String(localized: "Ingress・Service・ワークロード・ノードのどれかから、繋がりを辿ります。")
        }
    }

    /// 箱がノードかどうか。
    var isNodeFirst: Bool { self == .node }
}


/// 配置の棒が表すもの。
enum PlacementMetric: String, CaseIterable, Identifiable, Sendable {
    case both
    case cpu
    case memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .both: return String(localized: "CPU とメモリ")
        case .cpu: return "CPU"
        case .memory: return String(localized: "メモリ")
        }
    }

    var showsCPU: Bool { self != .memory }
    var showsMemory: Bool { self != .cpu }
}
