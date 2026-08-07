import Foundation

/// コンテキスト 1 つぶんの覚え書き。
///
/// **どのクラスタを触っているのかを、名前の文字列だけに頼らせない。** この
/// アプリは削除・drain・patch・書き戻しができるようになった。それだけの力が
/// あるのに、prod と dev の見分けがツールバーの小さな文字だけ、という状態は
/// 事故の入口そのもの。色と別名を持たせ、**危険な操作の確認文にも出す。**
struct ContextProfile: Codable, Hashable, Sendable {
    var tint: ContextTint = .none
    /// 画面に出す名前。空ならコンテキスト名をそのまま使う。
    /// kubeconfig の名前が `gke_project_asia-northeast1_cluster` のように
    /// 長いことは普通で、そのままでは帯に収まらないし読み分けもできない。
    var alias: String = ""
    /// 変更をいっさい行わせない。
    ///
    /// **「気をつける」で守らない。** 見るだけのつもりのクラスタでも、いまは
    /// 全部の操作が押せる。押せないようにするのがいちばん確実。
    var isReadOnly: Bool = false

    var isEmpty: Bool { tint == .none && alias.isEmpty && !isReadOnly }
}

/// 帯の色。
///
/// **状態の 4 色（good / warning / serious / critical）と同じ意味にしない。**
/// あちらはクラスタが返してきた事実で、こちらは人が付けた札。混ざらないように、
/// 帯は**必ず名前の文字と一緒に**出す（色だけに意味を持たせない、といういつもの話）。
enum ContextTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return String(localized: "なし")
        case .red: return String(localized: "赤")
        case .orange: return String(localized: "橙")
        case .yellow: return String(localized: "黄")
        case .green: return String(localized: "緑")
        case .blue: return String(localized: "青")
        case .purple: return String(localized: "紫")
        case .gray: return String(localized: "灰")
        }
    }
}

/// コンテキスト名 → 覚え書き。`Preferences` が持つ。
typealias ContextProfiles = [String: ContextProfile]

/// 読み取り専用のクラスタで変更を頼まれたとき。
///
/// **黙って何もしないで返さない。** シートは結果を見て閉じるかどうかを決めるので、
/// 成功でも失敗でもない返事をすると「押したのに閉じない」だけになる。
struct ReadOnlyError: LocalizedError {
    let context: String

    var errorDescription: String? {
        String(localized: """
            \(context) は読み取り専用に設定されています。\
            設定の「コンテキスト」で解除できます。
            """)
    }
}
