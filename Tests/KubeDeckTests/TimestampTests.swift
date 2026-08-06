import Foundation
import Testing
@testable import KubeDeck

/// 時刻の読み取り。
///
/// **ここが黙って壊れると、間違いに見えない形で出る。** 読めなかった時刻は
/// nil になり、呼び出し側の別のフィールドに落ちるので、画面には「それらしい
/// 別の時刻」が並ぶ。実際 `eventTime` が 1 度も読めておらず、イベントの
/// 「経過」と並び順が最終発生ではなく作成時刻を指していた。
@Suite("時刻の読み取り")
struct TimestampTests {

    /// `metav1.Time`。`creationTimestamp` などほとんどのフィールドがこの形。
    @Test("小数秒の無い形を読める")
    func plainTimestamp() throws {
        let date = try #require(K8sObject.date(.string("2026-08-06T04:12:33Z")))
        #expect(date.timeIntervalSince1970 == 1_785_989_553)
    }

    /// `metav1.MicroTime`。イベントの `eventTime` はこちらで、**必ず小数秒が付く**。
    ///
    /// `ISO8601DateFormatter` は `.withFractionalSeconds` の有無で読める形が
    /// **排他**になるので、formatter を 1 つしか持っていないと片方が必ず落ちる。
    @Test("小数秒の付いた形も読める", arguments: [
        "2026-08-06T04:12:33.1Z",
        "2026-08-06T04:12:33.123Z",
        "2026-08-06T04:12:33.123456Z",
        "2026-08-06T04:12:33.123456789Z",
    ])
    func fractionalTimestamp(text: String) throws {
        let date = try #require(K8sObject.date(.string(text)))
        // 秒までは一致していること（小数部の丸めは問わない）。
        #expect(Int(date.timeIntervalSince1970) == 1_785_989_553)
    }

    @Test("読めないものは nil のまま")
    func rejectsGarbage() {
        #expect(K8sObject.date(nil) == nil)
        #expect(K8sObject.date(.string("")) == nil)
        #expect(K8sObject.date(.string("いつか")) == nil)
        // 文字列でないものを時刻として読まない。
        #expect(K8sObject.date(.int(0)) == nil)
    }

    // MARK: - イベントの「最後に起きた時刻」

    /// **`eventTime` しか持たないイベントが実在する**（orbstack の k3s で
    /// `Scheduled` がそうだった）。`lastSeen` はそれを読むために
    /// `eventTime` の段を持っているのに、小数秒を解析できず常に nil を返して
    /// **`creationTimestamp` に落ちていた**。
    @Test("lastTimestamp が無ければ eventTime を採る")
    func lastSeenPrefersEventTime() throws {
        let event = Fixture.object("""
            {"kind":"Event","metadata":{"name":"e1","namespace":"d","uid":"u1",
             "creationTimestamp":"2026-08-06T00:00:00Z"},
             "eventTime":"2026-08-06T04:12:33.123456Z",
             "reason":"Scheduled","type":"Normal"}
            """, assuming: .event)

        let seen = try #require(ResourceTable.lastSeen(event))
        #expect(Int(seen.timeIntervalSince1970) == 1_785_989_553)
        #expect(seen != event.creationTimestamp)
    }

    /// 順序は `lastTimestamp` → `deprecatedLastTimestamp` → `eventTime` →
    /// `creationTimestamp`。**あるものを飛ばさない。**
    @Test("lastTimestamp があればそちらを採る")
    func lastSeenPrefersLastTimestamp() throws {
        let event = Fixture.object("""
            {"kind":"Event","metadata":{"name":"e1","namespace":"d","uid":"u1",
             "creationTimestamp":"2026-08-06T00:00:00Z"},
             "lastTimestamp":"2026-08-06T02:00:00Z",
             "eventTime":"2026-08-06T04:12:33.123456Z",
             "reason":"Scheduled","type":"Normal"}
            """, assuming: .event)

        let seen = try #require(ResourceTable.lastSeen(event))
        #expect(Int(seen.timeIntervalSince1970) == 1_785_981_600)
    }

    /// **どれも無いときに「時刻ゼロ」にしない。** creationTimestamp まで
    /// 落ちる（そこまで無ければ nil）。
    @Test("時刻を 1 つも持たないイベントは nil")
    func lastSeenWithoutAnyTimestamp() {
        let event = Fixture.object("""
            {"kind":"Event","metadata":{"name":"e1","namespace":"d","uid":"u1"},
             "reason":"Scheduled","type":"Normal"}
            """, assuming: .event)

        #expect(ResourceTable.lastSeen(event) == nil)
    }
}
