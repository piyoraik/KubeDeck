import Foundation
import Testing
@testable import KubeDeck

/// 標準入力に流す口（`kubectl replace -f -` が使う）。
///
/// **ここは黙って壊れる。** 書き込みを呼び出し側のまま行うと、パイプの
/// バッファ（64KB 程度）を超えた時点で**相手が読む前に埋まって止まる**。
/// 症状は「大きい YAML のときだけ固まる」で、小さい YAML で試している
/// あいだは一度も出ない。だから**バッファより大きい入力で**確かめる。
///
/// クラスタには触らない（`/bin/cat` と `/usr/bin/wc` で足りる）。
@Suite("子プロセスの標準入力")
struct ProcessInputTests {

    @Test("流した中身がそのまま返る")
    func roundTrip() async throws {
        let result = try await ProcessRunner.run(
            executable: "/bin/cat", arguments: [], environment: [:],
            timeout: 10, input: Data("hello\nworld\n".utf8))
        #expect(result.exitCode == 0)
        #expect(result.stdoutText == "hello\nworld\n")
    }

    @Test("パイプのバッファより大きくても詰まらない")
    func largeInput() async throws {
        // 64KB を明確に超える大きさ。ClusterRole や CRD の YAML はこの桁になる。
        let text = String(repeating: "0123456789abcdef\n", count: 40_000)
        let result = try await ProcessRunner.run(
            executable: "/bin/cat", arguments: [], environment: [:],
            timeout: 30, input: Data(text.utf8))
        #expect(result.exitCode == 0)
        #expect(result.stdout.count == Data(text.utf8).count)
    }

    /// **相手が読み切らずに終わってもアプリを落とさない。** 書き込み側には
    /// SIGPIPE が飛び、既定の動作はプロセスの終了（＝アプリごと落ちる）。
    /// 無視してあれば、ここは単に失敗した結果が返るだけになる。
    @Test("読まずに終わる相手に流しても落ちない")
    func brokenPipe() async throws {
        let text = String(repeating: "x\n", count: 200_000)
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/true", arguments: [], environment: [:],
            timeout: 10, input: Data(text.utf8))
        #expect(result.exitCode == 0)
    }

    @Test("入力を渡さないときは、標準入力の終わりがすぐ来る")
    func noInput() async throws {
        // 渡さないのに開いたままだと、読む側（kubectl も含む）が待ち続ける。
        let result = try await ProcessRunner.run(
            executable: "/bin/cat", arguments: [], environment: [:], timeout: 10)
        #expect(result.exitCode == 0)
        #expect(result.stdout.isEmpty)
    }
}
