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

    /// コンテキストに付ける札の色。
    ///
    /// **状態の 4 色を流用しない。** あちらはクラスタが返してきた事実で、
    /// こちらは人が付けた札。同じ赤でも意味が違うので、値も別に持つ
    /// （帯は必ずコンテキスト名の文字と一緒に出す。色だけに意味を持たせない）。
    static func color(for tint: ContextTint) -> Color? {
        switch tint {
        case .none: return nil
        case .red: return Color(hex: 0xC0_39_39)
        case .orange: return Color(hex: 0xD1_7A_1F)
        case .yellow: return Color(hex: 0xC9_A2_0C)
        case .green: return Color(hex: 0x2F_8F_46)
        case .blue: return Color(hex: 0x2E_6F_D6)
        case .purple: return Color(hex: 0x7B_4B_C4)
        case .gray: return Color(hex: 0x6E_6E_73)
        }
    }

    /// 時系列の線に使う色。**状態の 4 色を流用しない。**
    /// 流用すると、ただの CPU の線が「異常」の意味を帯びてしまう。
    /// 系列 1（青）と系列 2（橙）を CPU / メモリに割り当てる。
    static let seriesCPU = Color.adaptive(light: 0x2A_78_D6, dark: 0x39_87_E5)
    static let seriesMemory = Color.adaptive(light: 0xEB_68_34, dark: 0xD9_59_26)

    /// ログの出どころ（`pod/container`）を見分けるための色。
    ///
    /// **状態の 4 色と混ぜない。** 行の帯と下地は深刻度が持っている場所なので、
    /// 隣で同じ色系統が動くと、どちらが状態なのか分からなくなる（以前
    /// 「Pod ごとに色を塗らない」と決めたのはこの理由）。緑・黄・橙・赤を
    /// 1 つも使わない寒色だけで組み、**出どころの列の文字にだけ**掛ける
    /// （帯・下地・本文の色は深刻度のまま）。
    ///
    /// **色だけに意味を持たせない。** 色を付ける当の列に名前が出ているので、
    /// 色は見分けを速くするだけの添え物。
    ///
    /// **7 色で足りることにする。** これ以上増やしても隣り合う色の区別が
    /// 付かない。掴んでいる Pod が 7 を超えると色は一周するが、名前が
    /// 出ている以上それで別物になるわけではない。
    static let logSources: [Color] = [
        .adaptive(light: 0x2A_6F_D1, dark: 0x5F_A5_F2),  // 青
        .adaptive(light: 0x7A_4B_C4, dark: 0xB4_90_EC),  // 紫
        .adaptive(light: 0x0E_74_80, dark: 0x45_C0_CD),  // 青緑
        .adaptive(light: 0xB0_3F_7E, dark: 0xEC_82_B8),  // 桃
        .adaptive(light: 0x3F_4F_B5, dark: 0x93_9E_F2),  // 藍
        .adaptive(light: 0x5B_6B_7B, dark: 0xA6_B6_C6),  // 鈍色
        .adaptive(light: 0x8A_4F_9E, dark: 0xC9_92_DA),  // 藤
    ]

    /// 現れた順の番号から色を選ぶ。**名前のハッシュから決めない** ——
    /// 一周ぶんに満たない少数の Pod でも、隣り合う 2 つが似た色になりうる。
    static func logSource(at index: Int) -> Color {
        logSources[((index % logSources.count) + logSources.count) % logSources.count]
    }

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
