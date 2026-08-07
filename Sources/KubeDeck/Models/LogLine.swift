import Foundation

/// ログ 1 行。表示に必要な解析結果まで持たせる。
///
/// 解析は取り込み時に 1 度だけ行う。描画のたびに走らせると、追従中は
/// 毎フレーム全行を舐めることになる。
struct LogLine: Identifiable, Sendable, Hashable {
    let id: Int
    let text: String
    let level: LogLevel
    /// `--timestamps` が付けた行頭の時刻。付けていない行では nil。
    let timestamp: LogTimestamp?
    /// `kubectl logs --prefix` が付けた出どころ（`pod/container`）。
    /// 1 つの Pod を 1 コンテナだけ読んでいるときは nil。
    let source: String?
    /// 直前の行から現地の日付が変わったか。**日付をまたぐときだけ**列に
    /// 日付を出すための印（毎行に `MM-dd` を並べると、12 文字の時刻に
    /// 6 文字が常時足されて本文の幅を食う）。
    let startsNewDay: Bool

    /// - Parameters:
    ///   - strippingPrefix: `--prefix` を付けて取得したか。
    ///     **付けていないときは絶対に剥がさない** —— `[ERROR] ...` のような
    ///     本文を出どころと読み違える。
    ///   - previousDayKey: 直前の行の `LogTimestamp.dayKey`。日付が変わった
    ///     行を見つけるためだけに使う。
    init(
        id: Int, text raw: String, strippingPrefix: Bool = false,
        previousDayKey: Int? = nil
    ) {
        let (source, afterPrefix) = strippingPrefix
            ? LogLine.splitPrefix(raw)
            : (nil, raw)

        // **時刻も本文から剥がす。** 出どころと同じ扱い —— 残したままだと
        // 行の絞り込みが時刻にも当たるし、深刻度の判定も行頭が時刻になって
        // ずれる（klog の `E0802` は行頭にしか現れないので、`--timestamps` を
        // 付けているあいだ判定が丸ごと効かなかった）。
        let parsed = LogTimestamp.parse(afterPrefix)

        self.id = id
        self.text = parsed.map { String(afterPrefix[$0.bodyStart...]) } ?? afterPrefix
        self.level = LogLevel(detecting: self.text)
        self.timestamp = parsed?.stamp
        self.source = source
        self.startsNewDay = {
            guard let key = parsed?.stamp.dayKey, let previousDayKey else { return false }
            return key != previousDayKey
        }()
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

    /// 出どころのコンテナ名（いちばん後ろの段）。
    ///
    /// 1 つの Pod を全コンテナで読んでいるときは、どの行も Pod 名が同じ
    /// なので**コンテナ名だけを列に出す**（同じ値を全行に並べても、
    /// 狭い列でコンテナ名が削れるだけ）。
    var sourceContainer: String? {
        guard let source else { return nil }
        return source.split(separator: "/").last.map(String.init)
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

}

/// `--timestamps` が付けた行頭の時刻。
///
/// **本文に残さない。** 出どころ（`--prefix`）と同じ扱いで剥がして列に出す。
/// 残すと絞り込みが時刻にも当たり、深刻度の判定も行頭でずれる。
struct LogTimestamp: Sendable, Hashable {
    /// kubectl が出した原文（RFC3339・UTC）。
    ///
    /// **捨てない。** 現地時刻に直したものだけを残すと、貼った先で他の
    /// ログや相手のクラスタと突き合わせられなくなる。コピーとツールチップ
    /// はこちらを使う（「元の文言を捨てない」と同じ話）。
    let raw: String
    /// 現地時刻の `HH:mm:ss.SSS`。
    ///
    /// **取り込みのときに作る。** 描画のたびに整形すると、追従中は毎フレーム
    /// 全行を舐めることになる（深刻度の判定を取り込み時に 1 度だけ行うのと
    /// 同じ理由）。
    let time: String
    /// 現地の `MM-dd`。日付をまたいだ行にだけ出す。
    let day: String
    /// 現地時刻での通し日数。日付が変わった行を見つけるためだけの鍵。
    let dayKey: Int

    /// 行頭の RFC3339 を読む。読めなければ nil（本文はそのまま）。
    ///
    /// **`ISO8601DateFormatter` を通さない。** 小数秒の有無で読める形が排他に
    /// なるうえ（`K8sObject.date` で踏んだ）、1 行ごとに通すには重い。
    /// **`DateFormatter` でも整形しない** —— 既定のカレンダーが和暦の環境で
    /// 月日が変わる。桁を数えて整数で計算する。
    ///
    /// - Parameter offsetFromUTC: 現地時刻の差。nil ならこのマシンの設定。
    ///   テストから固定するためだけの口。
    static func parse(_ text: String, offsetFromUTC: Int? = nil)
        -> (stamp: LogTimestamp, bodyStart: String.Index)?
    {
        // Pod 名 253 + コンテナ名 253 を剥がしたあとの行頭。時刻は最長でも
        // `2026-08-07T04:12:33.123456789+09:00` の 35 文字。
        let head = Array(text.prefix(40))
        guard head.count >= 20,
              head[4] == "-", head[7] == "-", head[10] == "T",
              head[13] == ":", head[16] == ":",
              let year = number(head, 0, 4),
              let month = number(head, 5, 7),
              let day = number(head, 8, 10),
              let hour = number(head, 11, 13),
              let minute = number(head, 14, 16),
              let second = number(head, 17, 19),
              (1...12).contains(month), (1...31).contains(day),
              hour < 24, minute < 60, second <= 60
        else { return nil }

        // 小数秒。桁数は環境で違う（kubelet は 9 桁、9 桁未満で来る版もある）。
        var cursor = 19
        var milliseconds = 0
        if cursor < head.count, head[cursor] == "." {
            cursor += 1
            var digits = 0
            var scale = 100
            while cursor < head.count, head[cursor].isASCII, head[cursor].isNumber,
                  let value = head[cursor].wholeNumberValue
            {
                if digits < 3 {
                    milliseconds += value * scale
                    scale /= 10
                }
                digits += 1
                cursor += 1
            }
            // `.` のあとに数字が無いものは時刻ではない。
            guard digits > 0 else { return nil }
        }

        // 時間帯。kubectl は UTC の `Z` で出すが、他所から来た行も通す。
        var zoneOffset = 0
        guard cursor < head.count else { return nil }
        switch head[cursor] {
        case "Z", "z":
            cursor += 1
        case "+", "-":
            let sign = head[cursor] == "-" ? -1 : 1
            guard head.count >= cursor + 6, head[cursor + 3] == ":",
                  let zoneHour = number(head, cursor + 1, cursor + 3),
                  let zoneMinute = number(head, cursor + 4, cursor + 6)
            else { return nil }
            zoneOffset = sign * (zoneHour * 3600 + zoneMinute * 60)
            cursor += 6
        default:
            return nil
        }

        // 時刻のあとは空白 1 つ。無ければ本文の一部を食っている。
        guard cursor < head.count, head[cursor] == " " else { return nil }

        let utcSeconds =
            daysFromCivil(year, month, day) * 86_400
            + hour * 3_600 + minute * 60 + second
            - zoneOffset
        let localOffset = offsetFromUTC
            ?? TimeZone.current.secondsFromGMT(
                for: Date(timeIntervalSince1970: Double(utcSeconds)))
        let local = utcSeconds + localOffset
        let dayKey = floorDivide(local, 86_400)
        let secondsOfDay = local - dayKey * 86_400
        let civil = civilFromDays(dayKey)

        let stamp = LogTimestamp(
            raw: String(head[0..<cursor]),
            time: "\(pad2(secondsOfDay / 3_600)):\(pad2(secondsOfDay % 3_600 / 60))"
                + ":\(pad2(secondsOfDay % 60)).\(pad3(milliseconds))",
            day: "\(pad2(civil.month))-\(pad2(civil.day))",
            dayKey: dayKey)
        return (stamp, text.index(text.startIndex, offsetBy: cursor + 1))
    }

    /// 半開区間の桁を 10 進で読む。数字以外が混じれば nil。
    private static func number(_ head: [Character], _ from: Int, _ to: Int) -> Int? {
        guard from >= 0, to <= head.count, from < to else { return nil }
        var value = 0
        for index in from..<to {
            guard head[index].isASCII, let digit = head[index].wholeNumberValue,
                  head[index].isNumber
            else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func pad2(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func pad3(_ value: Int) -> String {
        value < 10 ? "00\(value)" : (value < 100 ? "0\(value)" : "\(value)")
    }

    /// 負の側でも下へ丸める割り算。`Int` の `/` は 0 方向に丸めるので、
    /// 1970 年より前の行で日付が 1 日ずれる。
    private static func floorDivide(_ dividend: Int, _ divisor: Int) -> Int {
        let quotient = dividend / divisor
        return (dividend % divisor != 0 && (dividend < 0) != (divisor < 0))
            ? quotient - 1 : quotient
    }

    /// 暦の日付 → 1970-01-01 からの通し日数（Howard Hinnant の days_from_civil）。
    private static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let shifted = year - (month <= 2 ? 1 : 0)
        let era = floorDivide(shifted, 400)
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra =
            yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    /// 上の逆。
    private static func civilFromDays(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = floorDivide(shifted, 146_097)
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthPrime = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthPrime + 2) / 5 + 1
        let month = monthPrime + (monthPrime < 10 ? 3 : -9)
        return (year + (month <= 2 ? 1 : 0), month, day)
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
