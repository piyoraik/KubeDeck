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

    /// `kubectl get ... -o json` の List を展開する。
    /// 単一オブジェクトを返してきた場合（items が無い）もそのまま 1 件として扱う。
    static func list(from data: Data, assuming fallbackKind: ResourceKind? = nil) throws -> [K8sObject] {
        let root = try JSONDecoder().decode(JSONValue.self, from: data)
        guard let items = root["items"] else {
            return [K8sObject(raw: root, assuming: fallbackKind)].compactMap { $0 }
        }
        return items.arrayValue.compactMap { K8sObject(raw: $0, assuming: fallbackKind) }
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
