import SwiftUI

/// オブジェクトの中身を、キーと値の入れ子として出す。
///
/// **YAML の代わり。** 右のパネルは幅が狭く、YAML を出すと 1 行が収まらずに
/// 横スクロールが要る。折り返せば今度はインデントが崩れて構造が読めない。
/// 「どの項目に何が設定されているか」を見たいだけなら、木で出したほうが速い。
///
/// 種別を問わず同じ経路で描けるので、CRD でもそのまま使える。
struct SpecOutline: View {
    let object: K8sObject

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(sections, id: \.key) { section in
                    OutlineNode(key: section.key, value: section.value, depth: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .overlay {
            if sections.isEmpty {
                ContentUnavailableView(
                    "設定はありません",
                    systemImage: "doc.plaintext",
                    description: Text("この \(object.kind?.displayName ?? "リソース") は spec を持ちません。YAML を見てください。"))
            }
        }
    }

    /// 出す節。`metadata` は概要タブが受け持つので出さない。
    private var sections: [(key: String, value: JSONValue)] {
        var result: [(key: String, value: JSONValue)] = []
        for key in ["spec", "status", "data", "stringData", "rules", "subjects", "roleRef"] {
            guard let value = object.raw[key], !value.isEmptyContainer else { continue }
            result.append((key, value))
        }
        return result
    }
}

/// 1 ノード。入れ子なら開閉、葉ならキーと値の 1 行。
private struct OutlineNode: View {
    let key: String
    let value: JSONValue
    let depth: Int

    @State private var isExpanded: Bool?

    /// 既定で開くか。
    ///
    /// **畳んだまま出さない。** 開かないと「設定が無い」のか「畳まれている」のかが
    /// 区別できず、パネルが白いままになる。上 2 段は必ず開き、それより深いところは
    /// 中身が小さいときだけ開く（全部開くと今度は文字の壁になる）。
    private var startsExpanded: Bool {
        // Pod なら spec → containers → 各コンテナ、まで開く。ここが
        // 「何が設定されているか」の本体なので、畳んだままでは意味がない。
        depth <= 2 || value.leafCount <= 20
    }

    /// 字下げ。深いところで際限なく下げると、狭いパネルで値の幅が無くなる。
    private var indent: CGFloat { CGFloat(min(depth, 5)) * 10 }

    private var expanded: Bool { isExpanded ?? startsExpanded }

    var body: some View {
        if value.isContainer {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    isExpanded = !expanded
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                        Text(key)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(value.summary)
                            .fixedSize()
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, indent)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if expanded {
                    ForEach(value.children, id: \.key) { child in
                        OutlineNode(key: child.key, value: child.value, depth: depth + 1)
                    }
                }
            }
        } else {
            // 幅が足りるなら 1 行、足りなければ 2 行。1 行に押し込むと、
            // `app.kubernetes.io/name` のような長いキーが 1 文字ずつ折れる。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    keyLabel
                    Spacer(minLength: 8)
                    valueLabel.multilineTextAlignment(.trailing)
                }
                VStack(alignment: .leading, spacing: 1) {
                    keyLabel
                    valueLabel
                        .padding(.leading, indent + 13)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var keyLabel: some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.leading, indent + 13)
    }

    private var valueLabel: some View {
        Text(value.displayText.isEmpty ? "—" : value.displayText)
            .font(.caption)
            .textSelection(.enabled)
            .lineLimit(4)
    }
}

// MARK: - 木として見るための補助

extension JSONValue {
    var isContainer: Bool {
        switch self {
        case .object(let dictionary): return !dictionary.isEmpty
        case .array(let elements): return !elements.isEmpty
        default: return false
        }
    }

    var isEmptyContainer: Bool {
        switch self {
        case .object(let dictionary): return dictionary.isEmpty
        case .array(let elements): return elements.isEmpty
        case .null: return true
        default: return false
        }
    }

    /// 子。辞書はキー順、配列は名前があればそれを見出しにする。
    var children: [(key: String, value: JSONValue)] {
        switch self {
        case .object(let dictionary):
            return dictionary.keys.sorted().map { ($0, dictionary[$0]!) }
        case .array(let elements):
            return elements.enumerated().map { index, element in
                // コンテナやポートのように name を持つ要素は、番号より名前のほうが分かる。
                let label = element["name"]?.stringValue
                    ?? element["type"]?.stringValue
                    ?? "\(index)"
                return (label, element)
            }
        default:
            return []
        }
    }

    /// 畳んでいるときに出す要約。開かなくても規模が分かるようにする。
    var summary: String {
        switch self {
        case .object(let dictionary): return "\(dictionary.count) 項目"
        case .array(let elements): return "\(elements.count) 件"
        default: return ""
        }
    }

    /// 葉の数。最初から開くかどうかの判断に使う。
    var leafCount: Int {
        switch self {
        case .object(let dictionary): return dictionary.values.reduce(0) { $0 + $1.leafCount }
        case .array(let elements): return elements.reduce(0) { $0 + $1.leafCount }
        default: return 1
        }
    }
}
