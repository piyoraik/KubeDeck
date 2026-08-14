import Foundation

/// ハーネス専用のスタブ。**アプリのコードは 1 行も変えない。**
/// `Preferences.applyToUpdater()` が呼ぶだけなので、形だけ合わせる
/// （Sparkle を引きずり込むとハーネスが建たない）。
@MainActor
final class UpdateController {
    static let shared = UpdateController()
    func configure(
        checksAutomatically: Bool, downloadsAutomatically: Bool, checkIntervalSeconds: Double
    ) {}
}
