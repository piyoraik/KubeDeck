import SwiftUI

/// Kubernetes の図でおなじみの七角形。
///
/// **舵輪（`KubernetesLogo`）と混ぜない。** あちらは「これは Kubernetes を
/// 見ている」というしるしで、公式ロゴそのもの。こちらは図の中で種別を表す
/// 器で、中に入れる記号のほうが意味を持つ。
struct Heptagon: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        var path = Path()
        for index in 0..<7 {
            // 頂点を上に置く。k8s の図はどれもこの向き。
            let angle = -Double.pi / 2 + Double(index) * 2 * .pi / 7
            let point = CGPoint(
                x: center.x + radius * cos(angle),
                y: center.y + radius * sin(angle))
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// 図の中の 1 つの器。七角形に種別の記号を入れる。
///
/// **色だけで種別を表さない。** 記号を入れ、必要なら名前を添える。
/// 状態は器の色ではなく、右上の小さなしるしで示す（種別と状態は別の話で、
/// 器の色を状態に使うと種別が読めなくなる）。
struct ResourceGlyph: View {
    let symbol: String
    var size: CGFloat = 34
    var tint: Color = .accentColor
    /// 異常などを示すしるし。正常なら付けない（合格印で埋め尽くさない）。
    var badge: StatusLevel?

    var body: some View {
        Heptagon()
            .fill(tint.gradient)
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white))
            .frame(width: size, height: size)
            .overlay(alignment: .topTrailing) {
                if let badge, badge != .good, badge != .neutral {
                    Image(systemName: badge.symbol)
                        .font(.system(size: size * 0.28))
                        .foregroundStyle(Palette.color(for: badge))
                        .background(
                            Circle()
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: size * 0.34, height: size * 0.34))
                        .offset(x: size * 0.08, y: -size * 0.04)
                }
            }
    }
}

/// 図の囲み。Namespace や ReplicaSet のような「範囲」を表す。
///
/// **見出しを枠の中に入れない。** 参考にした図と同じく、枠の左上に重ねて
/// 置く。中に入れると、囲まれているものの 1 つに見える。
struct DiagramBox<Content: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = .accentColor
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.init(top: 18, leading: 14, bottom: 14, trailing: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(tint.opacity(0.55), lineWidth: 1))
            .overlay(alignment: .topLeading) {
                HStack(spacing: 4) {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: 8))
                    }
                    Text(title)
                        .font(.caption2.weight(.medium))
                }
                .foregroundStyle(tint)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color(nsColor: .windowBackgroundColor))
                .offset(x: 10, y: -7)
            }
    }
}

/// 図の矢印。1 行の中で左から右へ引く。
///
/// **座標を計算しない。** 参考にした図のような自由な線ではなく、行の中の
/// 決まった向きだけを引く。自由な線にすると、折り返しやスクロールのたびに
/// 位置を計算し直すことになり、図のためだけにレイアウトの仕組みを持つ。
struct DiagramArrow: View {
    var length: CGFloat = 26
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint.opacity(0.5))
                .frame(width: length, height: 1)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 6))
                .foregroundStyle(tint.opacity(0.5))
                .offset(x: -1)
        }
    }
}
