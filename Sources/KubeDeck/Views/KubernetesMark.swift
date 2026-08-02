import SwiftUI

/// Kubernetes 公式ロゴ。青い七角形の本体に白い舵輪。
///
/// 図形は `KubernetesLogo`（公式 SVG を正規化したもの）を共有する。
/// ツールバーの 17pt から App アイコンの 1024px まで同じ定義で描くので、
/// Dock と画面内で別の紋章が並ぶことがない。
struct KubernetesMark: View {
    var body: some View {
        ZStack {
            LogoPart(kind: .body)
                .fill(Color(cgColor: KubernetesLogo.brandBlue))
            LogoPart(kind: .wheel)
                .fill(.white)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

private struct LogoPart: Shape {
    enum Kind {
        case body
        case wheel
    }

    let kind: Kind

    func path(in rect: CGRect) -> Path {
        switch kind {
        case .body: return Path(KubernetesLogo.body(in: rect))
        case .wheel: return Path(KubernetesLogo.wheel(in: rect))
        }
    }
}

// MARK: - 回転

/// 舵輪の回し方。
enum ClusterActivity: Equatable {
    /// 取得中。速く回す。
    case busy
    /// 自動更新が生きている。ゆっくり回して「見ている」ことを示す。
    case live
    /// 止まっている。自動更新オフ、または接続できていない。
    case idle

    /// 毎秒の回転角（度）。正の値で右回り。
    var degreesPerSecond: Double {
        switch self {
        case .busy: return 190
        case .live: return 26
        case .idle: return 0
        }
    }

}

/// 稼働を回転で示す Kubernetes マーク。
///
/// ロゴは公式の配色のまま扱い、状態で塗り替えない。代わりに、正常でないときだけ
/// 隅に状態のしるしを重ねる。ふだんは公式ロゴがそのまま見え、異常があるときだけ
/// 目に付く。回転と色だけに意味を持たせないよう、呼び出し側で同じ内容を文字でも出す。
struct ClusterActivityIcon: View {
    var activity: ClusterActivity
    var level: StatusLevel
    var size: CGFloat = 18

    var body: some View {
        RotatingKubernetesMark(activity: activity, side: size)
            .frame(width: size, height: size)
            .overlay(alignment: .bottomTrailing) { badge }
            .accessibilityLabel(Text("クラスタの状態"))
            .accessibilityValue(Text(level.label))
    }

    /// 状態のしるし。正常と対象外のときは出さない。
    @ViewBuilder
    private var badge: some View {
        if level != .good && level != .neutral {
            Circle()
                .fill(Palette.color(for: level))
                .overlay(
                    // 回っているロゴの上でも輪郭が消えないよう縁取る。
                    Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: size * 0.06))
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(x: size * 0.06, y: size * 0.06)
        }
    }
}
