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
///
/// **既定色を `Color.accentColor` にしない。** 窓が前面でないあいだ SwiftUI が
/// accent を灰色に落とすので、図が焦点の有無で色を失う。`Palette.diagram` を使う。
struct ResourceGlyph: View {
    let symbol: String
    var size: CGFloat = 34
    var tint: Color = Palette.diagram
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

enum DiagramMetrics {
    /// 囲みの上の余白。箱の外に並べる行の高さを、中の行と合わせるのに使う。
    static let boxTopInset: CGFloat = 20
}

/// 図の囲み。Namespace や ReplicaSet のような「範囲」を表す。
///
/// **見出しを枠の中に入れない。** 参考にした図と同じく、枠の左上に重ねて
/// 置く。中に入れると、囲まれているものの 1 つに見える。
struct DiagramBox<Content: View>: View {
    let title: String
    var symbol: String?
    var tint: Color = Palette.diagram
    /// 見出しを押せるようにする。**押す先を囲みの中に置かない** — 中に
    /// ボタンを足すと、囲まれているものの 1 つに見える。囲みそのものを
    /// 指す操作なので、見出しがその場所。
    var action: (() -> Void)?
    var help: String?
    var isDashed = false
    /// 枠の色。**範囲を表す囲みは薄くする**（`Palette.diagramFrame`）—— 枠がいちばん強く、
    /// 関係を示す矢印がいちばん弱く出ていた。nil なら見出しと同じ色。
    var stroke: Color?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 箱を見出しより狭くしない（狭いと、線の上に置いた見出しが折り返す）。
            titleText
                .fixedSize()
                .frame(height: 0)
                .hidden()
            content
        }
        .padding(.init(top: DiagramMetrics.boxTopInset, leading: 16, bottom: 14, trailing: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    stroke ?? tint.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: isDashed ? [4, 3] : [])))
        .overlay(alignment: .topLeading) {
            label
                .offset(x: 10, y: -8)
        }
    }

    @ViewBuilder
    private var label: some View {
        if let action {
            Button(action: action) { titleText }
                .buttonStyle(.plain)
                .help(help ?? title)
        } else {
            titleText
        }
    }

    private var titleText: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9))
            }
            Text(title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// 図の矢印。1 行の中で左から右へ引く。
///
/// **座標を計算しない。** 参考にした図のような自由な線ではなく、行の中の
/// 決まった向きだけを引く。自由な線にすると、折り返しやスクロールのたびに
/// 位置を計算し直すことになり、図のためだけにレイアウトの仕組みを持つ。
struct DiagramArrow: View {
    var length: CGFloat = 26
    var tint: Color = Palette.diagramLine

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(tint)
                .frame(width: length, height: 1.5)
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 7))
                .foregroundStyle(tint)
                .offset(x: -1)
        }
    }
}
