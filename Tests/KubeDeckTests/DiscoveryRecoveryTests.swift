import Foundation
import Testing

@testable import KubeDeck

/// 覚えている API の一覧が縮退したときの、外す／外さないの判断。
///
/// **踏んだ壊れ方。** 縮退したもとでは kubectl が実在する種別にも
/// `the server doesn't have a resource type` を返す。`list(kinds:)` はそれを
/// 「サーバはその種別を知らない」と読んで**種別を外して引き直す**ので、
/// 一過性の失敗が恒久の判断に化けていた。アプリの stderr で実測した並び:
///
/// ```
/// get pods.v1.,…,configmaps.v1.,…  → doesn't have a resource type "configmaps"
/// get services.v1.                 → doesn't have a resource type "services"
/// get …,secrets.v1.,…              → doesn't have a resource type "secrets"
/// get …,persistentvolumeclaims.v1. → doesn't have a resource type "persistentvolumeclaims"
/// ```
///
/// core の種別が 1 つずつ外れ、そのぶんサイドバーの件数が消え、外すたびに
/// discovery を捨てるので全 API グループを引き直す（この経路では 1 本 3 秒級）。
/// これが「取得が不安定」の中身だった。
@Suite("縮退した API 一覧からの復帰")
struct DiscoveryRecoveryTests {

    // MARK: - 外してよいかの判断

    private let stderr = #"error: the server doesn't have a resource type "configmaps""#

    /// **確かめたときだけ外す。**
    @Test("引き直して確かめた失敗なら、その種別を外す")
    func dropsWhenVerified() {
        let dropped = Kubectl.kindsToDrop(
            in: stderr, among: [.configMap, .secret], discoveryWasFresh: true)
        #expect(dropped == [.configMap])
    }

    /// **確かめていない失敗では 1 つも外さない。** 外すのは「サーバはこれを
    /// 知らない」と言うのと同じで、それは確かめてからでないと言えない。
    @Test("確かめていない失敗では、1 つも外さない")
    func dropsNothingWhenUnverified() {
        let dropped = Kubectl.kindsToDrop(
            in: stderr, among: [.configMap, .secret], discoveryWasFresh: false)
        #expect(dropped.isEmpty)
    }

    /// 判断を分けても、拾う側の書式依存は変わっていないこと。
    @Test("確かめた失敗の拾い方は unknownKinds と同じ")
    func matchesUnknownKinds() {
        #expect(Kubectl.kindsToDrop(in: stderr, among: [.configMap], discoveryWasFresh: true)
                == Kubectl.unknownKinds(in: stderr, among: [.configMap]))
    }

    @Test("他の失敗では、確かめていても外さない")
    func otherFailuresDropNothing() {
        let forbidden = "Error from server (Forbidden): secrets is forbidden: ..."
        #expect(Kubectl.kindsToDrop(
            in: forbidden, among: [.secret], discoveryWasFresh: true).isEmpty)
    }

    // MARK: - 失敗に載る印

    /// **既定は「確かめていない」。** 安全側は判断を保留するほう。
    @Test("CommandError の既定は、確かめていない")
    func defaultsToUnverified() {
        let error = CommandError(command: "kubectl get", exitCode: 1, message: "x")
        #expect(!error.discoveryWasFresh)
        #expect(error.verifiedAgainstFreshDiscovery().discoveryWasFresh)
    }

    /// 印を付けても、他の持ち物を落とさない（部分的な標準出力は命）。
    @Test("印を付けても、読めていた標準出力を捨てない")
    func keepsPartialStdout() {
        let error = CommandError(
            command: "kubectl get", exitCode: 1, message: "x",
            partialStdout: Data("{}".utf8), rawStderr: "raw")
        let marked = error.verifiedAgainstFreshDiscovery()
        #expect(marked.partialStdout == Data("{}".utf8))
        #expect(marked.rawStderr == "raw")
        #expect(marked.exitCode == 1)
    }
}
