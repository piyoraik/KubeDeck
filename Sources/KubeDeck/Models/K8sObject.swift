import Foundation

/// クラスタ上の 1 オブジェクト。`metadata` だけ型を付け、残りは生の JSON で持つ。
struct K8sObject: Identifiable, Sendable, Hashable {
    let raw: JSONValue
    /// 種別。単一種別の `kubectl get -o json` は items に kind を入れてこないので、
    /// 要求した種別を外から渡して補う（`K8sObject.list(from:assuming:)`）。
    let kind: ResourceKind?
    let rawKind: String
    let name: String
    let namespace: String?
    let uid: String
    let creationTimestamp: Date?
    let deletionTimestamp: Date?
    let labels: [String: String]
    let annotations: [String: String]

    var id: String {
        uid.isEmpty ? "\(namespace ?? "-")/\(rawKind)/\(name)" : uid
    }

    var spec: JSONValue? { raw["spec"] }
    var status: JSONValue? { raw["status"] }
    var isTerminating: Bool { deletionTimestamp != nil }

    init?(raw: JSONValue, assuming fallbackKind: ResourceKind? = nil) {
        guard let metadata = raw["metadata"], let name = metadata["name"]?.stringValue else {
            return nil
        }
        self.raw = raw
        let rawKind = raw["kind"]?.stringValue ?? fallbackKind?.apiKind ?? ""
        self.rawKind = rawKind
        self.kind = ResourceKind(apiKind: rawKind) ?? fallbackKind
        self.name = name
        self.namespace = metadata["namespace"]?.stringValue
        self.uid = metadata["uid"]?.stringValue ?? ""
        self.creationTimestamp = Self.date(metadata["creationTimestamp"])
        self.deletionTimestamp = Self.date(metadata["deletionTimestamp"])
        self.labels = metadata["labels"]?.stringDictionary ?? [:]
        self.annotations = metadata["annotations"]?.stringDictionary ?? [:]
    }

    /// **小数秒付きも読む。**
    ///
    /// `creationTimestamp` は `metav1.Time`（秒まで）だが、イベントの
    /// `eventTime` は `metav1.MicroTime` で**必ず小数秒が付く**
    /// （`2026-08-06T04:12:33.123456Z`）。`ISO8601DateFormatter` は
    /// `.withFractionalSeconds` の有無で読める形が**排他**になるので、
    /// 1 つでは両方を扱えない（実測。小数秒無しは付きの formatter で nil、
    /// 小数秒付きは無しの formatter で nil）。
    ///
    /// 片方しか持っていなかったせいで `ResourceTable.lastSeen` の `eventTime` の
    /// 段が常に nil を返し、**「`lastTimestamp` を持たないイベントの時刻を拾う」
    /// という当の対処が 1 度も効いていなかった**（`creationTimestamp` に落ちて
    /// いたので気付きにくい。並び順と「経過」列が最終発生ではなく作成時刻を指す）。
    ///
    /// 小数秒無しを先に試すのは、そちらが圧倒的に多いため。
    static func date(_ value: JSONValue?) -> Date? {
        guard let text = value?.stringValue else { return nil }
        return isoFormatter.date(from: text) ?? isoFractionalFormatter.date(from: text)
    }

    // 生成が安くないので使い回す。ISO8601DateFormatter は解析を並行に
    // 呼んでも安全だが、型としては Sendable でないので明示する。
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// `metav1.MicroTime`（`eventTime` など）用。
    private nonisolated(unsafe) static let isoFractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// 取れたものが要求した種別と食い違った。
    ///
    /// **「無い」でも「その種別だった」でもなく、「取れていない」。** この 3 つを
    /// 混ぜないのがこのアプリの一貫した規則で、ここはその 3 番目にあたる。
    ///
    /// 実際に起きたのは、覚えている API の一覧のコアグループが縮退していて
    /// `nodes` が `metrics.k8s.io` へ流れ、**NodeMetrics が Node として**
    /// 読まれたこと（`ResourceKind.resourceName` の説明を参照）。`assuming:` は
    /// 「kind が空の版を補う」ためのものなのに、**埋まっている別の kind まで
    /// 黙って上書きしていた**のが穴だった。
    struct UnexpectedKind: LocalizedError, Sendable {
        /// 要求した種別。
        let requested: [ResourceKind]
        /// 実際に返ってきた `kind`。
        let received: String

        var errorDescription: String? {
            let names = requested.map(\.apiKind).joined(separator: " / ")
            return String(localized: """
                要求した種別（\(names)）ではなく \(received) が返りました。\
                取得できていないものとして扱います。

                kubectl が覚えている API の一覧が縮退していると、同じ複数形を持つ\
                別の API グループへ黙って流れることがあります\
                （`nodes` が `metrics.k8s.io` の NodeMetrics になる、など）。\
                一覧を捨てて引き直しても直らない場合は、\
                `kubectl api-resources` に要求した種別が出るかを確かめてください。
                """)
        }
    }

    /// `kubectl get ... -o json` の List を展開する。
    /// 単一オブジェクトを返してきた場合（items が無い）もそのまま 1 件として扱う。
    ///
    /// 要求した種別が分かっているなら、それと食い違うものが返っていないかを
    /// 確かめる（`UnexpectedKind`）。
    static func list(
        from data: Data, assuming fallbackKind: ResourceKind? = nil
    ) throws -> [K8sObject] {
        try list(from: data, assuming: fallbackKind,
                 expecting: fallbackKind.map { [$0] } ?? [])
    }

    /// 複数種別をまとめて get したとき用。**要求していない種別が混ざっていたら
    /// 投げる。** まとめ取得は kind で振り分けるので、ここが狂うと全部が狂う。
    static func list(from data: Data, expecting expected: [ResourceKind]) throws -> [K8sObject] {
        try list(from: data, assuming: nil, expecting: expected)
    }

    /// metadata だけを頼んで引いた一覧（`PartialObjectMetadataList`）。
    ///
    /// **items の `kind` は `PartialObjectMetadata` で返る**（実測）ので、
    /// 要求した種別と突き合わせると**全部弾かれる**。実際これを踏み、概要と
    /// サイドバーで metadata だけ引いた 10 種別の件数が**そろって空欄になった**
    /// （数字が出ていたのは中身まで引く 4 種別だけ。しかも他の種別は読めて
    /// いるので画面は失敗にならず、**黙って件数が消える**）。
    ///
    /// 種別の確かめは **List の `kind`** のほうで済ませてある
    /// （`Kubectl.verifyListKind` が `PartialObjectMetadataList` を、
    /// **頼んだときだけ**通す）ので、ここでは 1 件ずつ突き合わせない。
    static func metadataList(
        from data: Data, assuming fallbackKind: ResourceKind?
    ) throws -> [K8sObject] {
        try list(from: data, assuming: fallbackKind, expecting: [])
    }

    private static func list(
        from data: Data, assuming fallbackKind: ResourceKind?, expecting expected: [ResourceKind]
    ) throws -> [K8sObject] {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        let objects: [K8sObject]
        if let items = root["items"] {
            objects = items.arrayValue.compactMap { K8sObject(raw: $0, assuming: fallbackKind) }
        } else {
            objects = [K8sObject(raw: root, assuming: fallbackKind)].compactMap { $0 }
        }
        try verify(objects, expecting: expected)
        return objects
    }

    /// **`kind` ではなく `rawKind` を見る。** `kind` は
    /// `ResourceKind(apiKind:) ?? fallbackKind` なので、`NodeMetrics` のように
    /// enum に無い名前は**要求した種別に化けている**。化けたあとを見ると、
    /// この検証は 1 度も発火しない。
    ///
    /// **空の `rawKind` は通す。** 単一種別の `get -o json` は items に kind を
    /// 入れてこない版があり、そこを弾くと**ふつうの取得が全部落ちる**。空を
    /// 補うのが `assuming:` の本来の仕事。
    ///
    /// **要求した種別が無いときは何も見ない。** CRD は組み込みの enum に無いので
    /// 突き合わせる相手がいない。
    private static func verify(_ objects: [K8sObject], expecting expected: [ResourceKind]) throws {
        guard !expected.isEmpty else { return }
        let allowed = Set(expected.map(\.apiKind))
        for object in objects where !object.rawKind.isEmpty {
            guard allowed.contains(object.rawKind) else {
                throw UnexpectedKind(requested: expected, received: object.rawKind)
            }
        }
    }
}

// MARK: - 経過時間

extension K8sObject {
    /// kubectl の AGE 列と同じ見た目（`2d`, `5h`, `13m`, `45s`）。
    var age: String {
        guard let creationTimestamp else { return "" }
        return Self.age(since: creationTimestamp)
    }

    static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "\(seconds)s"
        case ..<3600: return "\(seconds / 60)m"
        case ..<86_400:
            let hours = seconds / 3600
            let minutes = (seconds % 3600) / 60
            return hours < 10 && minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h"
        default:
            let days = seconds / 86_400
            let hours = (seconds % 86_400) / 3600
            return days < 10 && hours > 0 ? "\(days)d\(hours)h" : "\(days)d"
        }
    }
}
