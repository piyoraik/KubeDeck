import SwiftUI

/// 節を縦に積む。ただし**幅が余っているときだけ段に割る。**
///
/// 詳細パネルを下に置くと、欄は横に長く縦が短い。1 列のまま伸ばすと、
/// 見出しと値が画面の端どうしに離れて対応が読めなくなるうえ、縦は足りないので
/// 何を見るにもスクロールすることになる（短い帯でいちばん困る形）。
///
/// **右に置いたときの見え方は変えない。** 段が増えるのは 1 段の幅が
/// `minimumColumnWidth` を満たすときだけで、右の欄（300〜560pt）では
/// これまでどおり 1 列になる。**置き場所を見て分岐しない** — 幅で決まるので、
/// パネルの幅を掴んで変えたときも同じ規則で動く。
///
/// 高さの揃え方は「いちばん低い段へ置く」だけ。節の高さは中身でまちまちなので、
/// 順に折り返すと右の段だけが伸びて、下が大きく空く。
struct SectionColumns: Layout {
    /// これを下回るなら段を増やさない。狭い段に折り返すと、値のほうが
    /// 1 文字ずつ折れて読めなくなる。
    var minimumColumnWidth: CGFloat = 320
    var columnSpacing: CGFloat = 22
    var rowSpacing: CGFloat = 18
    /// **際限なく増やさない。** 3 段を超えると、目が横へ往復する距離のほうが
    /// スクロールより長くなる。
    var maximumColumns = 3

    /// **無限の幅で数を割らない。** SwiftUI は「いちばん広いとき / 狭いとき」を
    /// 訊くために `.infinity` を提案してくる（`ScrollView` の中で実際に来る）。
    /// `Int(.infinity)` は Swift では**トラップして落ちる**ので、有限でないときは
    /// 1 段ぶんの幅で答える。
    ///
    /// **`replacingUnspecifiedDimensions()` で埋めない。** あれが nil を埋める
    /// 既定値は `minimumColumnWidth` ではなく **10**。有限なのでそのまま通り、
    /// 幅 10pt で全節を測ることになっていた（無限のほうだけ守れていた）。
    /// nil も無限も「幅が決まっていない」なので、同じく 1 段ぶんで答える。
    func sizeThatFits(
        proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumColumnWidth
        let solved = solve(width: width, subviews: subviews)
        return CGSize(width: width, height: solved.height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let solved = solve(width: bounds.width, subviews: subviews)
        for (index, spot) in solved.spots.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + spot.x, y: bounds.minY + spot.y),
                proposal: ProposedViewSize(width: solved.columnWidth, height: spot.height))
        }
    }

    private struct Spot {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }

    /// 段の数・幅と、各節の置き場所。**測ると置くで同じ計算を使う** —
    /// 別々に持つと、片方だけ直したときに高さと配置が食い違う。
    private func solve(
        width: CGFloat, subviews: Subviews
    ) -> (spots: [Spot], columnWidth: CGFloat, height: CGFloat) {
        guard width.isFinite, width > 0 else { return ([], max(width, 0), 0) }
        let fits = Int((width + columnSpacing) / (minimumColumnWidth + columnSpacing))
        let columns = max(1, min(maximumColumns, fits))
        let columnWidth =
            (width - columnSpacing * CGFloat(columns - 1)) / CGFloat(columns)

        var bottoms = [CGFloat](repeating: 0, count: columns)
        var spots: [Spot] = []
        for subview in subviews {
            let height = subview
                .sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            // 同じ高さなら左から埋める（`min(by:)` は最初の最小を返す）。
            // 順序を保てるところは保っておかないと、更新のたびに節が飛ぶ。
            let column = bottoms.enumerated().min { $0.element < $1.element }?.offset ?? 0
            spots.append(
                Spot(
                    x: CGFloat(column) * (columnWidth + columnSpacing),
                    y: bottoms[column],
                    height: height))
            bottoms[column] += height + rowSpacing
        }
        let height = max(0, (bottoms.max() ?? rowSpacing) - rowSpacing)
        return (spots, columnWidth, height)
    }
}
