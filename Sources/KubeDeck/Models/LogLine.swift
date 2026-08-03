import Foundation

/// ログ 1 行。表示に必要な解析結果まで持たせる。
///
/// 解析は取り込み時に 1 度だけ行う。描画のたびに走らせると、追従中は
/// 毎フレーム全行を舐めることになる。
struct LogLine: Identifiable, Sendable, Hashable {
    let id: Int
    let text: String
    let level: LogLevel
    /// `--timestamps` を付けたときの先頭の時刻の長さ。無ければ 0。
    let timestampLength: Int

    init(id: Int, text: String) {
        self.id = id
        self.text = text
        self.level = LogLevel(detecting: text)
        self.timestampLength = LogLine.timestampPrefixLength(text)
    }

    /// kubectl の `--timestamps` は RFC3339 + 空白を先頭に足す。
    /// 日付らしい形で始まるときだけ、最初の空白までを時刻とみなす。
    private static func timestampPrefixLength(_ text: String) -> Int {
        let head = Array(text.prefix(40))
        guard head.count > 20,
              head[4] == "-", head[7] == "-", head[10] == "T",
              head[0].isNumber, head[1].isNumber
        else { return 0 }
        guard let space = head.firstIndex(of: " ") else { return 0 }
        return space
    }
}

/// ログの深刻度。書式はプロジェクトごとに違うので、よくある書き方を順に見る。
enum LogLevel: Sendable, Hashable {
    case error
    case warning
    case info
    case debug
    /// 判定できなかったもの。色を付けない。
    case plain

    /// 状態の 4 色に対応付ける。系列色ではなく状態色を使うのは、
    /// ログのレベルがまさに状態だから。
    var statusLevel: StatusLevel? {
        switch self {
        case .error: return .critical
        case .warning: return .warning
        case .info, .debug, .plain: return nil
        }
    }

    init(detecting text: String) {
        // 行頭の 200 文字だけ見る。長い JSON 全体を毎回小文字化しない。
        let head = String(text.prefix(200))

        // klog / glog: `E0802 01:23:45.678901` のように severity 1 文字 + 日付で始まる。
        if let first = head.first, "EWIF".contains(first) {
            let rest = head.dropFirst().prefix(4)
            if rest.count == 4, rest.allSatisfy(\.isNumber) {
                switch first {
                case "E", "F": self = .error
                case "W": self = .warning
                default: self = .info
                }
                return
            }
        }

        let lowered = head.lowercased()
        // JSON（"level":"error"）と logfmt（level=error）と括弧（[ERROR]）をまとめて見る。
        for (needles, level) in [
            (["\"error\"", "=error", "[error]", "\"fatal\"", "=fatal", "[fatal]",
              "\"panic\"", " error ", " fatal "], LogLevel.error),
            (["\"warn\"", "\"warning\"", "=warn", "=warning", "[warn]", "[warning]",
              " warn ", " warning "], LogLevel.warning),
            (["\"debug\"", "=debug", "[debug]", " debug "], LogLevel.debug),
            (["\"info\"", "=info", "[info]", " info "], LogLevel.info),
        ] {
            if needles.contains(where: { Self.containsToken(lowered, $0) }) {
                self = level
                return
            }
        }

        self = .plain
    }

    /// 目印が**語として**含まれているかを見る。
    ///
    /// **前方一致で済ませない。** `=error` をそのまま `contains` すると
    /// `handler=errorMiddleware` や `metric=error_rate` まで error になる。
    /// 目印の直後が英数字や `_` `-` なら、それは別の語の頭でしかない。
    ///
    /// 見るのは目印が英数字で終わるとき（`=error` など）だけ。`"error"` や
    /// `[error]` や `" error "` は目印そのものが区切りで終わっているので、
    /// ここで後ろを見ると逆に落としてしまう（`" error "` の次は本文の 1 文字目）。
    private static func containsToken(_ haystack: String, _ needle: String) -> Bool {
        guard let last = needle.last, isWordCharacter(last) else {
            return haystack.contains(needle)
        }
        var searchRange = haystack.startIndex..<haystack.endIndex
        while let found = haystack.range(of: needle, range: searchRange) {
            if found.upperBound == haystack.endIndex
                || !isWordCharacter(haystack[found.upperBound]) {
                return true
            }
            guard found.lowerBound < haystack.endIndex else { return false }
            searchRange = haystack.index(after: found.lowerBound)..<haystack.endIndex
        }
        return false
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "-"
    }
}
