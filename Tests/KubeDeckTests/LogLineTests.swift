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
    /// **本文から剥がして列に出す** —— 残すと絞り込みが時刻にも当たり、
    /// 深刻度の判定も行頭でずれる（出どころの prefix と同じ扱い）。
    @Test("--timestamps の時刻を本文から剥がす")
    func timestampPrefix() {
        let stamped = LogLine(id: 0, text: "2026-08-02T01:23:45.123456789Z hello world")
        #expect(stamped.timestamp?.raw == "2026-08-02T01:23:45.123456789Z")
        #expect(stamped.text == "hello world")

        let plain = LogLine(id: 0, text: "hello world")
        #expect(plain.timestamp == nil)
        #expect(plain.text == "hello world")
    }

    @Test("日付に見えない行の先頭を時刻と誤認しない")
    func notATimestamp() {
        // 数字で始まるが日付の形ではない。**本文を食わないこと。**
        for text in [
            "12345 request accepted here",
            "2026/08/02 01:23:45 hello",
            // 時刻の形だが、そのあとが空白でない（本文の一部）。
            "2026-08-02T01:23:45.123Zhello",
            // 小数点のあとに数字が無い。
            "2026-08-02T01:23:45. hello",
            // 時間帯が無い。
            "2026-08-02T01:23:45 hello",
        ] {
            let line = LogLine(id: 0, text: text)
            #expect(line.timestamp == nil, "\(text)")
            #expect(line.text == text, "\(text)")
        }
    }

    /// **時刻を剥がしたあとの本文で深刻度を見る。** 剥がす前は行頭が日付に
    /// なるので、klog の判定（`E0802`）が `--timestamps` を付けているあいだ
    /// 丸ごと効かなかった。
    @Test("時刻を剥がしたあとで klog の深刻度が効く")
    func levelAfterTimestamp() {
        let line = LogLine(id: 0, text: "2026-08-02T01:23:45.123456789Z E0802 01:23:45 lost")
        #expect(line.level == .error)
    }

    /// 現地時刻に直して列に出す。**原文は捨てない**（コピーとツールチップ）。
    @Test("現地時刻の列と原文の両方を持つ")
    func localTime() {
        // JST（UTC+9）で固定して確かめる。
        let parsed = LogTimestamp.parse(
            "2026-08-02T01:23:45.123456789Z body", offsetFromUTC: 9 * 3_600)
        #expect(parsed?.stamp.time == "10:23:45.123")
        #expect(parsed?.stamp.day == "08-02")
        #expect(parsed?.stamp.raw == "2026-08-02T01:23:45.123456789Z")
    }

    /// **小数秒の桁数に寄りかからない。** kubelet は 9 桁で出すが、
    /// 桁が少ない版も、小数秒そのものが無い行もある
    /// （`ISO8601DateFormatter` は有無で読める形が排他になる。`K8sObject.date`
    /// で踏んだのと同じ話）。
    @Test(
        "小数秒は桁数を問わない",
        arguments: [
            ("2026-08-02T01:23:45Z x", "10:23:45.000"),
            ("2026-08-02T01:23:45.1Z x", "10:23:45.100"),
            ("2026-08-02T01:23:45.12Z x", "10:23:45.120"),
            ("2026-08-02T01:23:45.123Z x", "10:23:45.123"),
            ("2026-08-02T01:23:45.123456789Z x", "10:23:45.123"),
        ])
    func fractionalSeconds(_ text: String, _ time: String) {
        #expect(LogTimestamp.parse(text, offsetFromUTC: 9 * 3_600)?.stamp.time == time)
    }

    /// 時間帯付きで来た行も読む（kubectl は `Z` で出すが、他所から
    /// 流れ込む行もある）。
    @Test("Z 以外の時間帯も読む")
    func explicitZone() {
        // +09:00 の 10:23:45 は UTC の 01:23:45。JST に直すと元に戻る。
        let parsed = LogTimestamp.parse(
            "2026-08-02T10:23:45.000+09:00 x", offsetFromUTC: 9 * 3_600)
        #expect(parsed?.stamp.time == "10:23:45.000")
        #expect(parsed?.stamp.day == "08-02")
    }

    /// **日付をまたぐ行を見つけられること。** ここが狂うと、列の日付が
    /// 出ないか、毎行に出る。
    @Test("現地の日付が変わると dayKey が動く")
    func dayBoundary() {
        let offset = 9 * 3_600
        // UTC 14:59:59 は JST 23:59:59、UTC 15:00:00 は翌日の 00:00:00。
        let before = LogTimestamp.parse("2026-08-02T14:59:59.000Z x", offsetFromUTC: offset)
        let after = LogTimestamp.parse("2026-08-02T15:00:00.000Z x", offsetFromUTC: offset)
        #expect(before?.stamp.time == "23:59:59.000")
        #expect(after?.stamp.time == "00:00:00.000")
        #expect(after?.stamp.day == "08-03")
        #expect(before!.stamp.dayKey + 1 == after!.stamp.dayKey)

        // 印は直前の行と比べて立てる。
        //
        // **時間帯をマシンに任せない。** ここが見ているのは「現地の日付が
        // 変わったか」なので、渡さないと走らせた場所の設定で結果が変わる。
        // 実際、JST の手元では通って **UTC の CI ランナーでだけ落ちた**
        // （`14:59:59Z` と `15:00:00Z` は JST では日をまたぐが UTC では同じ日）。
        let head = LogLine(
            id: 0, text: "2026-08-02T14:59:59.000Z x", offsetFromUTC: offset)
        let next = LogLine(
            id: 1, text: "2026-08-02T15:00:00.000Z y",
            previousDayKey: head.timestamp?.dayKey, offsetFromUTC: offset)
        let same = LogLine(
            id: 2, text: "2026-08-02T15:00:01.000Z z",
            previousDayKey: next.timestamp?.dayKey, offsetFromUTC: offset)
        #expect(head.startsNewDay == false)
        #expect(next.startsNewDay)
        #expect(same.startsNewDay == false)
    }

    /// 出どころを剥がしたあとに時刻を読む。kubectl は
    /// `[pod/<Pod>/<コンテナ>] <時刻> <本文>` の順で書く。
    @Test("prefix の内側の時刻も剥がす")
    func timestampInsidePrefix() {
        let line = LogLine(
            id: 0, text: "[pod/web-7d9f/app] 2026-08-02T01:23:45.123456789Z hello",
            strippingPrefix: true)
        #expect(line.source == "pod/web-7d9f/app")
        #expect(line.timestamp?.raw == "2026-08-02T01:23:45.123456789Z")
        #expect(line.text == "hello")
    }

    /// 列に出すのはコンテナ名（1 つの Pod を全コンテナで読むとき）。
    @Test("出どころのコンテナ名はいちばん後ろの段")
    func containerFromSource() {
        let line = LogLine(id: 0, text: "[pod/web-7d9f/istio-proxy] x", strippingPrefix: true)
        #expect(line.sourceContainer == "istio-proxy")
        #expect(LogLine(id: 0, text: "plain").sourceContainer == nil)
    }

    // MARK: - まとめ読みの出どころ（--prefix）

    /// `kubectl logs -l ... --prefix` は行頭に出どころを足す。**本文から
    /// 剥がして列に出す** —— 残すと行の絞り込みが Pod 名に当たり、深刻度の
    /// 判定も先頭が prefix になってずれる。
    ///
    /// 段の数は数えず、囲みの中身をそのまま出どころとして扱う。
    /// 2 段でも 3 段でも同じ経路で通ること。
    @Test("囲みの中身を出どころとして剥がす")
    func stripsPrefix() {
        let two = LogLine(id: 0, text: "[web-7d9f/app] hello", strippingPrefix: true)
        #expect(two.source == "web-7d9f/app")
        #expect(two.text == "hello")

        let three = LogLine(id: 0, text: "[pod/web-7d9f/app] hello", strippingPrefix: true)
        #expect(three.source == "pod/web-7d9f/app")
        #expect(three.text == "hello")
    }

    /// **実測（kubectl v1.32.13、GKE）で prefix は 3 段だった。**
    /// `[pod/<Pod 名>/<コンテナ名>] `。
    ///
    /// 先頭の段を Pod 名として読んでいたので、**全行の Pod 名が `pod` になり**、
    /// 絞り込みの候補に `pod` という偽の項目が 1 つ増えたうえ、どの Pod を
    /// 選んでも 1 行も一致しなかった（実際そうなった）。**後ろから数える** ——
    /// いちばん後ろがコンテナ名、その 1 つ前が Pod 名。
    @Test(
        "Pod 名は後ろから 2 番目の段",
        arguments: [
            ("[pod/web-7d9f-abcde/app] x", "web-7d9f-abcde", "web-7d9f-abcde/app"),
            ("[web-7d9f-abcde/app] x", "web-7d9f-abcde", "web-7d9f-abcde/app"),
        ])
    func podNameComesFromTheEnd(_ text: String, _ pod: String, _ label: String) {
        let line = LogLine(id: 0, text: text, strippingPrefix: true)
        #expect(line.sourcePod == pod)
        // 列に出すときは種別の段を落とす（104pt しかないので Pod 名が削れる）。
        #expect(line.sourceLabel == label)
    }

    /// 出どころが付いていない行（kubectl 自身の文言）を Pod 扱いしない。
    @Test("出どころが無ければ Pod 名も無い")
    func noSourceNoPod() {
        let line = LogLine(id: 0, text: "error: you are attempting to follow 8 log streams")
        #expect(line.sourcePod == nil)
        #expect(line.sourceLabel == nil)
    }

    /// 剥がしたあとの本文で深刻度を見る。**prefix ごと判定に掛けない** ——
    /// 行頭が `[` になるので klog の判定が効かなくなる。
    @Test("深刻度と時刻は、剥がしたあとの本文で測る")
    func levelAfterStripping() {
        let line = LogLine(
            id: 0, text: "[web-7d9f/app] E0802 01:23:45.678901 leader lost",
            strippingPrefix: true)
        #expect(line.level == .error)

        let stamped = LogLine(
            id: 0, text: "[web-7d9f/app] 2026-08-02T01:23:45.123456789Z hello",
            strippingPrefix: true)
        #expect(stamped.timestamp?.raw == "2026-08-02T01:23:45.123456789Z")
        #expect(stamped.text == "hello")
    }

    /// **`--prefix` を付けていない行から剥がさない。** これを忘れると
    /// `[ERROR] ...` の `[ERROR]` を出どころとして食う。
    @Test("剥がすと言われなければ触らない")
    func neverStripsWhenNotAsked() {
        let line = LogLine(id: 0, text: "[web-7d9f/app] hello")
        #expect(line.source == nil)
        #expect(line.text == "[web-7d9f/app] hello")
    }

    /// 剥がすと言われていても、prefix に見えないものは本文のまま残す。
    /// ここが緩いと、まとめ読みのときだけ本文の先頭が黙って消える。
    @Test(
        "本文の囲みを出どころと読み違えない",
        arguments: [
            // `/` が無い。kubectl の prefix は必ずコンテナ名まで入る。
            "[ERROR] something went wrong",
            "[main] starting up",
            // 大文字を含む。Kubernetes の名前には使えない。
            "[INFO/Server] ready",
            // 空白を含む。
            "[2026-08-02 01:23:45] hello",
            // 閉じ括弧のあとが空白でない。
            "[a/b]hello",
            // 閉じ括弧が無い。
            "[a/b hello",
        ])
    func keepsBody(_ text: String) {
        let line = LogLine(id: 0, text: text, strippingPrefix: true)
        #expect(line.source == nil)
        #expect(line.text == text)
    }

    /// 本文の側に囲みが続いていても、剥がすのは先頭の 1 つだけ。
    @Test("剥がすのは先頭の 1 つだけ")
    func stripsOnlyTheHead() {
        let line = LogLine(
            id: 0, text: "[web-7d9f/app] [db/conn] connected", strippingPrefix: true)
        #expect(line.source == "web-7d9f/app")
        #expect(line.text == "[db/conn] connected")
    }
}
