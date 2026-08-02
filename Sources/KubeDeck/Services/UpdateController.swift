import Foundation
import Observation
import Sparkle

/// 更新の確認が最後にどうなったか。
///
/// **時刻だけを持たない。** Sparkle は取得に失敗しても `lastUpdateCheckDate` を
/// 進めるので、時刻だけを出すと「確認できた」ように見える。ここが
/// 「まだ確認していない」「最新だった」「更新がある」「確認できなかった」を
/// 区別する。
enum UpdateCheckOutcome: Sendable, Equatable {
    case never
    case upToDate(Date)
    case updateAvailable(Date, version: String)
    case failed(Date, reason: String)

    var date: Date? {
        switch self {
        case .never: return nil
        case .upToDate(let date), .failed(let date, _): return date
        case .updateAvailable(let date, _): return date
        }
    }
}

/// アプリ内更新（Sparkle）。
///
/// **配信元は GitHub Releases。** `Info.plist` の `SUFeedURL` が
/// `releases/latest/download/appcast.xml` を指しており、リリースごとに
/// 1 項目だけの appcast を資産として上げている。`latest` は常に最新の
/// 「プレリリースでない」リリースを指すので、版を出すたびに URL を書き換えなくてよい。
///
/// **署名は EdDSA だけで足りる。** 配布物は ad-hoc 署名なので cdhash が版ごとに
/// 変わり、Apple のコード署名どうしを突き合わせる検証は通らない。Sparkle は
/// 新旧の `SUPublicEDKey` が一致して EdDSA 署名が有効なら、署名 identity の変化を
/// 許す（`SUUpdateValidator`）。**この鍵を差し替えると、既存の利用者は更新を
/// 受け取れなくなる。**
///
/// **`SPUUpdater` を直に画面へ渡さない。** Sparkle の API は Objective-C の
/// 素のオブジェクトで `@Observable` ではないので、値が変わっても画面が追従しない。
/// 画面が読む値はこのクラスの格納プロパティに写す。
@MainActor
@Observable
final class UpdateController {
    static let shared = UpdateController()

    /// 手で入れ替えたい人向けの置き場。設定画面から開く。
    static let releasesURL = URL(string: "https://github.com/piyoraik/KubeDeck/releases")!

    /// 「アップデートを確認…」を押せるか。確認中は落ちる。
    private(set) var canCheckForUpdates = false

    /// 最後の確認がどうなったか。
    private(set) var lastOutcome: UpdateCheckOutcome = .never

    /// いま動いているアプリの版（`CFBundleShortVersionString`）。
    let currentVersion: String

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    // SPUStandardUpdaterController はデリゲートを弱く持つので、こちらで抱える。
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        currentVersion =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "不明"

        // startingUpdater: true で、Preferences が入れた設定のまま走り出す。
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: nil)

        // canCheckForUpdates は Sparkle 側が KVO で流してくるので、写しを持つ。
        // **クロージャの中で updater を読まない。** `SPUUpdater` は MainActor 隔離で、
        // KVO の呼び出しは Sendable な文脈なので警告になる。変更後の値だけを受け取る。
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
            [weak self] _, change in
            guard let value = change.newValue else { return }
            Task { @MainActor in self?.canCheckForUpdates = value }
        }
    }

    /// 利用者が明示的に確認したとき。**更新が無くてもその旨のダイアログが出る**
    /// （黙って何も起きないと、確認できたのか失敗したのか分からない）。
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// `Preferences` から呼ぶ。設定の持ち場はあちらで、ここは受け取るだけ。
    func configure(
        checksAutomatically: Bool,
        downloadsAutomatically: Bool,
        checkIntervalSeconds: TimeInterval
    ) {
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = checksAutomatically
        updater.automaticallyDownloadsUpdates = downloadsAutomatically
        updater.updateCheckInterval = checkIntervalSeconds
    }

    fileprivate func record(_ outcome: UpdateCheckOutcome) {
        lastOutcome = outcome
    }
}

/// Sparkle からの報告を受ける口。
///
/// **`@objc` のプロトコルなので isolation を書けない。** 呼び出しは main で来るが、
/// それに頼らず、渡された値を Sendable な形へ写してから MainActor へ渡している。
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            UpdateController.shared.record(.updateAvailable(Date(), version: version))
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        let nsError = error as NSError
        // 「更新が無かった」も NSError で来る。これは失敗ではない。
        let outcome: UpdateCheckOutcome =
            nsError.code == SUError.noUpdateError.rawValue
            ? .upToDate(Date())
            : .failed(Date(), reason: nsError.localizedDescription)
        Task { @MainActor in UpdateController.shared.record(outcome) }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        // 取得そのものに失敗した場合（繋がらない・appcast が壊れている）は
        // ここにだけ来る。updaterDidNotFindUpdate が拾った分は上書きしない。
        guard let error = error as NSError? else { return }
        guard error.code != SUError.noUpdateError.rawValue else { return }
        let reason = error.localizedDescription
        Task { @MainActor in UpdateController.shared.record(.failed(Date(), reason: reason)) }
    }
}
