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
    /// `kubectl logs --prefix` が付けた出どころ（`pod/container`）。
    /// 1 つの Pod を読んでいるときは nil。
    let source: String?

    /// - Parameter strippingPrefix: `--prefix` を付けて取得したか。
    ///   **付けていないときは絶対に剥がさない** —— `[ERROR] ...` のような
    ///   本文を出どころと読み違える。
    init(id: Int, text raw: String, strippingPrefix: Bool = false) {
        let (source, text) = strippingPrefix
            ? LogLine.splitPrefix(raw)
            : (nil, raw)
        self.id = id
        self.text = text
        self.level = LogLevel(detecting: text)
        self.timestampLength = LogLine.timestampPrefixLength(text)
        self.source = source
    }

    /// 出どころの Pod 名。
    ///
    /// **先頭の段を取らない。** 実測（kubectl v1.32.13、GKE）で prefix は
    /// **3 段**の `[pod/<Pod 名>/<コンテナ名>] ` だった。先頭を取ると全行が
    /// `pod` になり、絞り込みの候補に `pod` という偽の項目が 1 つ増えるだけで、
    /// **どの Pod を選んでも 1 行も一致しない**（実際そうなった）。
    ///
    /// **段の数は数えない。** いちばん後ろがコンテナ名、その 1 つ前が Pod 名、
    /// という並びだけに寄りかかる。2 段（`<Pod>/<コンテナ>`）で来る版があっても
    /// 同じ答えになる。
    var sourcePod: String? {
        guard let source else { return nil }
        let parts = source.split(separator: "/")
        guard parts.count >= 2 else { return parts.first.map { String($0) } }
        return String(parts[parts.count - 2])
    }

    /// 列に出す文字。**種別の段は落とす。** 詳細パネルの列は 104pt しかなく、
    /// `pod/` の 4 文字ぶん Pod 名が削れる（どれも同じ値なので情報も無い）。
    var sourceLabel: String? {
        guard let source else { return nil }
        let parts = source.split(separator: "/")
        guard parts.count > 2 else { return source }
        return parts.suffix(2).joined(separator: "/")
    }

    /// `[pod/container] 本文` を 2 つに分ける。当てはまらなければそのまま返す。
    ///
    /// **本文から取り除く。** 残したままだと、行の絞り込みが出どころにも
    /// 当たる（`nginx` で絞ったつもりが Pod 名で全行一致する）し、
    /// 深刻度の判定も先頭が prefix になってずれる。列として別に出す。
    ///
    /// **書式に寄りかからない。** 実測（kubectl v1.32.13、GKE）では
    /// `[pod/<Pod 名>/<コンテナ名>] ` の **3 段**だったが、段の数は数えず
    /// 「囲みの中身」をそのまま出どころとして扱う（読み方は `sourcePod` /
    /// `sourceLabel` が**後ろから**数える）。
    ///
    /// 誤爆を避けるための条件は 3 つ。
    /// - `/` を含むこと —— kubectl の prefix は必ずコンテナ名まで入る。
    ///   これで `[ERROR]` や `[main]` は落ちる。
    /// - 空白を含まないこと —— `[2026-08-06 01:02:03]` のような時刻を弾く。
    /// - Kubernetes の名前に使える字だけであること（小文字・数字・`-._/`）。
    ///   大文字を含む `[INFO/Server]` のような本文が通らない。
    static func splitPrefix(_ raw: String) -> (source: String?, text: String) {
        guard raw.first == "[" else { return (nil, raw) }
        // Pod 名 253 + コンテナ名 253 + 記号。これを超える囲みは本文とみなす。
        let head = raw.prefix(520)
        guard let close = head.firstIndex(of: "]"),
              head.index(after: close) < head.endIndex,
              head[head.index(after: close)] == " "
        else { return (nil, raw) }

        let inside = head[head.index(after: head.startIndex)..<close]
        guard inside.contains("/"),
              inside.allSatisfy({
                  $0.isLowercase && $0.isLetter
                      || $0.isNumber
                      || $0 == "-" || $0 == "." || $0 == "_" || $0 == "/"
              })
        else { return (nil, raw) }

        // 囲みと、そのあとの空白 1 つを落とす。
        let bodyStart = raw.index(close, offsetBy: 2)
        return (String(inside), String(raw[bodyStart...]))
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
