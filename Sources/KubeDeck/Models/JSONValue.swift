import Foundation

/// kubectl が返す JSON をスキーマ非依存で保持する木構造。
///
/// 対応するリソースは 15 種あり、しかも同じ種別でも API バージョンや
/// アドオンの有無でフィールドが増減する。全部に Codable の struct を
/// 起こすと、フィールドが 1 つ欠けただけで一覧が丸ごと落ちる作りになる。
/// 型を付けるのは `metadata` だけにして（`K8sObject`）、`spec` / `status`
/// はこの木のままキーパスで引く。欠けていれば nil が返るだけで済む。
enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            // Int を先に試す。Double 経由にすると replicas が "3.0" になる。
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "解釈できない JSON の値です。")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

// MARK: - 取り出し

extension JSONValue {
    subscript(key: String) -> JSONValue? {
        guard case .object(let dictionary) = self else { return nil }
        return dictionary[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case .array(let elements) = self, elements.indices.contains(index) else { return nil }
        return elements[index]
    }

    /// `"status.containerStatuses"` のようなドット区切りで潜る。
    func path(_ keyPath: String) -> JSONValue? {
        keyPath.split(separator: ".").reduce(self as JSONValue?) { current, key in
            current?[String(key)]
        }
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var intValue: Int? {
        switch self {
        case .int(let value): return value
        case .double(let value): return Int(value)
        // kubectl は quantity 系（`spec.replicas` を patch した直後など）を
        // 文字列で返すことがある。
        case .string(let value): return Int(value)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let value): return value
        case .string(let value): return Bool(value)
        default: return nil
        }
    }

    var arrayValue: [JSONValue] {
        if case .array(let elements) = self { return elements }
        return []
    }

    var objectValue: [String: JSONValue] {
        if case .object(let dictionary) = self { return dictionary }
        return [:]
    }

    /// 表示用の 1 行文字列。数値・真偽値も潰して文字列にする。
    var displayText: String {
        switch self {
        case .null: return ""
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .array(let elements): return elements.map(\.displayText).joined(separator: ", ")
        case .object: return ""
        }
    }

    /// `[String: String]` として読める部分だけを取り出す（labels / annotations 用）。
    var stringDictionary: [String: String] {
        objectValue.compactMapValues(\.stringValue)
    }
}
