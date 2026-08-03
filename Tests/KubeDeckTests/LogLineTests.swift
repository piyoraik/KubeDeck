import Testing
@testable import KubeDeck

/// ログの深刻度は書式がプロジェクトごとに違うので、よくある書き方を順に見る。
/// **誤爆に注意** — `no errors expected` や `/api/errors` を error にしない。
@Suite("ログの深刻度")
struct LogLineTests {

    @Test("klog の severity 1 文字 + 日付")
    func klog() {
        #expect(LogLine(id: 0, text: "E0802 01:23:45.678901 leader lost").level == .error)
        #expect(LogLine(id: 0, text: "W0802 01:23:45.678901 retrying").level == .warning)
        #expect(LogLine(id: 0, text: "I0802 01:23:45.678901 started").level == .info)
        #expect(LogLine(id: 0, text: "F0802 01:23:45.678901 fatal").level == .error)
    }

    @Test("JSON の level フィールド")
    func json() {
        #expect(LogLine(id: 0, text: #"{"level":"error","msg":"boom"}"#).level == .error)
        #expect(LogLine(id: 0, text: #"{"level":"warn","msg":"slow"}"#).level == .warning)
        #expect(LogLine(id: 0, text: #"{"level":"info","msg":"ok"}"#).level == .info)
    }

    @Test("logfmt の level=")
    func logfmt() {
        #expect(LogLine(id: 0, text: "ts=... level=error msg=boom").level == .error)
        #expect(LogLine(id: 0, text: "ts=... level=warning msg=slow").level == .warning)
    }

    @Test("括弧の [ERROR]")
    func brackets() {
        #expect(LogLine(id: 0, text: "2026-08-02 [ERROR] failed").level == .error)
        #expect(LogLine(id: 0, text: "2026-08-02 [WARN] slow").level == .warning)
    }

    /// **ここが本題。** 語の前後に空白か記号を要求しているので、
    /// 語の一部に含まれるだけでは深刻度にならない。
    @Test("error を含むだけの行を error にしない", arguments: [
        "GET /api/errors 200 OK",
        "no errors expected in this run",
        "errorRate=0",
        "handler=errorMiddleware ready",
    ])
    func falsePositives(text: String) {
        #expect(LogLine(id: 0, text: text).level != .error)
    }

    @Test("判定できない行には色を付けない")
    func plain() {
        let line = LogLine(id: 0, text: "listening on :8080")
        #expect(line.level == .plain)
        #expect(line.level.statusLevel == nil)
    }

    // MARK: - 時刻の先頭

    /// `--timestamps` は RFC3339 + 空白を先頭に足す。
    /// **日付らしい形のときだけ**時刻とみなす（本文を食わない）。
    @Test("--timestamps の時刻だけを先頭として測る")
    func timestampPrefix() {
        let stamped = LogLine(id: 0, text: "2026-08-02T01:23:45.123456789Z hello world")
        #expect(stamped.timestampLength == 30)

        let plain = LogLine(id: 0, text: "hello world")
        #expect(plain.timestampLength == 0)
    }

    @Test("日付に見えない行の先頭を時刻と誤認しない")
    func notATimestamp() {
        // 数字で始まるが日付の形ではない。
        #expect(LogLine(id: 0, text: "12345 request accepted here").timestampLength == 0)
        #expect(LogLine(id: 0, text: "2026/08/02 01:23:45 hello").timestampLength == 0)
    }
}
