import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(nsColor: NSColor(hex: hex))
    }

    /// 外観に追従する色。`NSColor` の dynamic provider を通すので、
    /// ライト / ダークの切り替えに再描画なしで付いていく。
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(
            nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    ? NSColor(hex: dark) : NSColor(hex: light)
            })
    }
}

/// 画面の色。
///
/// 状態の 4 色は系列色とは別枠で、ライト / ダークで振らずに固定する
/// （同じ「異常」が明るさで違う色に見えないようにするため）。ライト背景では
/// warning と serious が 3:1 に届かないので、状態色は必ずアイコンかラベルと
/// 一緒に出す。色だけで意味を運ばせない。
enum Palette {
    static func color(for level: StatusLevel) -> Color {
        switch level {
        case .good: return Color(hex: 0x0C_A3_0C)
        case .warning: return Color(hex: 0xFA_B2_19)
        case .serious: return Color(hex: 0xEC_83_5A)
        case .critical: return Color(hex: 0xD0_3B_3B)
        case .neutral: return Color(hex: 0x89_87_81)
        }
    }

    /// 一覧やカードの中の文字色。状態色をそのまま文字に使うと
    /// 細い字で読めなくなるので、暗いほうへ寄せた版を使う。
    static func textColor(for level: StatusLevel) -> Color {
        switch level {
        case .good: return .adaptive(light: 0x00_63_00, dark: 0x0C_A3_0C)
        case .warning: return .adaptive(light: 0x8A_5D_00, dark: 0xFA_B2_19)
        case .serious: return .adaptive(light: 0xA3_4A_22, dark: 0xEC_83_5A)
        case .critical: return .adaptive(light: 0xB0_2A_2A, dark: 0xE8_6B_6B)
        case .neutral: return .secondary
        }
    }

    /// 時系列の線に使う色。**状態の 4 色を流用しない。**
    /// 流用すると、ただの CPU の線が「異常」の意味を帯びてしまう。
    /// 系列 1（青）と系列 2（橙）を CPU / メモリに割り当てる。
    static let seriesCPU = Color.adaptive(light: 0x2A_78_D6, dark: 0x39_87_E5)
    static let seriesMemory = Color.adaptive(light: 0xEB_68_34, dark: 0xD9_59_26)

    /// 図の器と囲みの色（Kubernetes の構成図でおなじみの青）。
    ///
    /// **`Color.accentColor` に預けない。** SwiftUI の accent は窓が前面に
    /// 無いあいだ灰色に落ちるので、図が焦点の有無で色を失う（別の環境で
    /// 撮った画面では七角形も囲みも全部灰色になっていた）。アクセントカラーに
    /// グラファイトを選んでいる人の環境でも同じことが起きる。図の色は
    /// 「これは Kubernetes の構成図だ」というしるしなので、状態の 4 色と
    /// 同じく外の設定で振らせない。
    ///
    /// **状態には使わない。** 器の色は種別のためのもので、異常は右上の
    /// しるしが持つ（`ResourceGlyph`）。
    static let diagram = Color.adaptive(light: 0x32_6C_E5, dark: 0x4B_86_EA)

    /// カードの面。ウインドウ背景から一段持ち上げる。
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let hairline = Color(nsColor: .separatorColor)
    static let mutedInk = Color(nsColor: .tertiaryLabelColor)
    /// 一覧のヘッダ行や、値が無いセルの下地。
    static let subtleFill = Color.primary.opacity(0.04)

    /// カードの中でもう一段沈める面（見出しの帯、入れ子の箱）。
    /// **不透明な色を足さない。** 外観設定とアクセントカラーの組み合わせで
    /// 浮くので、下の面に対する薄い重ねにする。
    static let insetFill = Color.primary.opacity(0.05)
    /// カードの縁。`hairline` は一覧の区切り用で、面の縁にはやや弱い。
    static let cardStroke = Color.primary.opacity(0.09)
    /// カードの影。**濃くしない。** 影で浮かせるのは 1 段だけで、
    /// 段を重ねると画面がぼやける。
    static let cardShadow = Color.black.opacity(0.18)
}
