import SwiftUI

/// 設定タブ。項目と値の表を並べる。
///
/// **API のフィールド名を並べない。** 組み込みの種別は `SettingsDigest` が
/// 見るべき項目を選び、日本語の見出しと整形した値にしている。原文が要るときは
/// YAML タブがある。スキーマの分からない CRD だけは選びようがないので木で出す。
struct SettingsDigestView: View {
    let object: K8sObject

    var body: some View {
        let groups = SettingsDigest.groups(for: object)

        if groups.isEmpty {
            // CRD は項目を選べないので、そのままの構造を出す。
            SpecOutline(object: object)
        } else {
            ScrollView {
                // 下に置いた詳細パネルでは幅が余るので段に割る（`SectionColumns`）。
                // 右の欄では 1 列のまま。
                SectionColumns(rowSpacing: 16) {
                    ForEach(groups) { group in
                        SettingTable(group: group)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct SettingTable: View {
    let group: SettingGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(group.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if let subtitle = group.subtitle {
                    Text(subtitle)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 6)

            VStack(spacing: 0) {
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    SettingRowView(row: row)
                }
            }
            .background(Palette.subtleFill, in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

private struct SettingRowView: View {
    let row: SettingRow

    var body: some View {
        // 幅が足りるなら 1 行、足りなければ 2 行。狭いパネルで押し込むと
        // 長い値が 1 文字ずつ折れて読めなくなる。
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                label
                Spacer(minLength: 8)
                value.multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                label
                value
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
    }

    private var label: some View {
        Text(row.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var value: some View {
        HStack(spacing: 5) {
            if let level = row.level {
                Image(systemName: level.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.color(for: level))
            }
            Text(row.value)
                .font(.caption)
                // 未設定は薄くする。設定してある値と同じ濃さで並ぶと、
                // 全部が設定済みに見える。
                .foregroundStyle(row.isUnset ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .lineLimit(4)
            if let encoded = row.secretData {
                SecretCopyButton(plaintext: SecretPlaintext.decode(encoded))
            }
        }
    }
}

/// Secret の値を復号してコピーする。**画面には平文を出さない**（共有されうる画面なので）。
private struct SecretCopyButton: View {
    let plaintext: SecretPlaintext
    @State private var copied = false

    var body: some View {
        Button {
            guard case .text(let text) = plaintext else { return }
            Self.copy(text)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 10))
                .frame(width: 12)
        }
        .buttonStyle(.borderless)
        .disabled(!isText)
        .help(help)
    }

    private var isText: Bool {
        if case .text = plaintext { return true }
        return false
    }

    private var help: String {
        switch plaintext {
        case .text: String(localized: "復号した値をコピー")
        case .binary: String(localized: "バイナリなので文字列としてコピーできません")
        case .invalid: String(localized: "base64 として読めないのでコピーできません")
        }
    }

    /// クリップボード履歴のアプリに残させない目印（nspasteboard.org の慣習。1Password などと同じ）。
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: concealed)
    }
}
