import CoreGraphics
import Foundation

/// KubeDeck のマーク（舵輪）。App アイコンの図形。
///
/// Kubernetes 公式ロゴとは別物で、公式の図形は 1 つも使っていない。7 スポークという
/// 着想だけ引き継ぎ、輪郭・比率・配色は独自に引き直したもの。CNCF の商標に触れずに済み、
/// 他の Kubernetes ツールと Dock で見分けが付く。
///
/// **アプリの実行時コードではない。** 画面内のマークは公式ロゴのまま
/// （`Sources/KubeDeck/Views/KubernetesLogo.swift`）で、そちらは「Kubernetes を
/// 指している」しるし。ここは配布物のアイコンを焼くためだけにあるので、
/// アプリのターゲットには入れず `Scripts` に置いてある。
///
/// **図形は「単位正方形に置いた線の集まり」（`unitPrimitives`）として持つ。**
/// PNG（`generate-icon.swift`）も SVG（`generate-svg.swift`）もこの 1 つの配列から作る。
/// 座標を書き写した時点で PNG と SVG と README がずれ始めるので、描き先を足すときも
/// 配列を読む側として足すこと。
///
/// 塗りは `nonzero`。線を太らせた輪郭どうしが重なっても、巻き方向が揃っていれば
/// 和集合になる（`evenOdd` にすると重なりが穴になる）。
enum KubeDeckLogo {

    // MARK: - 色

    /// 舵輪 1 色で出すときの青。単色でライト / ダークどちらの下地にも置ける濃さ。
    static let brandBlueHex: UInt32 = 0x2E_6F_E0
    /// App アイコンの下地。上を明るく、下を深くする。
    static let tileTopHex: UInt32 = 0x4A_8A_F7
    static let tileBottomHex: UInt32 = 0x12_38_8F
    /// 下地に載せる舵輪の色。
    static let inkHex: UInt32 = 0xFF_FF_FF

    static let brandBlue = color(brandBlueHex)
    static let tileTop = color(tileTopHex)
    static let tileBottom = color(tileBottomHex)
    static let ink = color(inkHex)

    static func color(_ hex: UInt32) -> CGColor {
        CGColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
    }

    /// `#RRGGBB`。SVG に書き出すときの表記。
    static func hexString(_ hex: UInt32) -> String {
        String(format: "#%06X", hex)
    }

    // MARK: - 寸法（単位正方形。1.0 = 図形を収める正方形の 1 辺）

    /// 7 回対称。回転の向きを実測で確かめるときの周期は 360 / 7 = 51.43°。
    static let spokeCount = 7

    /// 最初のスポークを真上に向ける（画面座標なので Y は下向き）。
    static let phaseDegrees: CGFloat = -90

    /// 輪の中心線の半径と太さ。
    ///
    /// **輪は 1 本の連続した円にする。** スポークのあいだで弧に割ってみたが、
    /// 弧が太さに対して短くなり、舵輪ではなく雪の結晶に見えた（隙間 18〜30° の
    /// どれでもそうなった）。舵輪は輪が形を決める図形なので、割らない。
    static let rimRadius: CGFloat = 0.365
    static let rimWidth: CGFloat = 0.105

    /// **輪よりスポークを細くする。** 同じ太さにすると輪が主役にならず、
    /// やはり結晶に見える。
    static let spokeWidth: CGFloat = 0.052

    /// 握り。丸端の半径ぶん外へ伸びて、ちょうど半径 0.5（＝正方形の縁）に届く。
    /// 内側は輪より深く差し込み、輪と地続きに見せる。
    static let handleWidth: CGFloat = 0.075
    static let handleInner: CGFloat = 0.340
    static let handleOuter: CGFloat = 0.4625

    static let hubRadius: CGFloat = 0.100

    // MARK: - App アイコンの割り付け（キャンバスに対する比）

    /// macOS の App アイコンは 1024 のキャンバスに 824 の下地を置く慣習に合わせる
    /// （100 / 1024）。この余白があるので Dock で他のアイコンと大きさが揃う。
    static let tileInset: CGFloat = 100.0 / 1024
    /// 角丸の半径。キャンバス比（185.4 / 1024。824 の下地に対しては 22.5%）。
    static let tileCornerRadius: CGFloat = 185.4 / 1024
    /// 下地の上に載せる舵輪の直径。キャンバス比（下地 824 に対して 72%）。
    /// 小さいほど 16px でスポークが潰れる。0.52 では 16px で団子になった。
    static let wheelScale: CGFloat = 0.58

    // MARK: - 図形の定義

    /// 線 1 本ぶんの指示。丸端・丸継ぎで太らせる前提の中心線を持つ。
    enum Primitive {
        /// 直線。`width` の丸端で太らせる。
        case bar(from: CGPoint, to: CGPoint, width: CGFloat)
        /// 円。`width` で太らせた輪にする。
        case ring(center: CGPoint, radius: CGFloat, width: CGFloat)
        /// 塗り潰した円。
        case disc(center: CGPoint, radius: CGFloat)
    }

    static let unitCenter = CGPoint(x: 0.5, y: 0.5)

    /// 単位正方形に置いた舵輪。**ここが図形の唯一の定義。**
    static let unitPrimitives: [Primitive] = {
        var result: [Primitive] = [
            .ring(center: unitCenter, radius: rimRadius, width: rimWidth),
            .disc(center: unitCenter, radius: hubRadius),
        ]
        let step = 360 / CGFloat(spokeCount)

        for index in 0..<spokeCount {
            let angle = phaseDegrees + step * CGFloat(index)
            // スポークは中心から輪の中心線まで。根元は中央のハブに隠れる。
            result.append(
                .bar(from: unitCenter, to: point(angle: angle, radius: rimRadius), width: spokeWidth))
            result.append(
                .bar(
                    from: point(angle: angle, radius: handleInner),
                    to: point(angle: angle, radius: handleOuter), width: handleWidth))
        }
        return result
    }()

    /// 角度（度）と半径から単位正方形の中の点を出す。Y は下向き。
    static func point(angle: CGFloat, radius: CGFloat) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(
            x: unitCenter.x + radius * cos(radians),
            y: unitCenter.y + radius * sin(radians))
    }

    // MARK: - CGPath

    // 線を太らせる処理は安くない。舵輪は回転のたびにビットマップへ焼き直される
    // ことがあるので、単位正方形のぶんは 1 度だけ作って持つ。
    // CGPath は作った後は変えないため Sendable 扱いにしてよい。
    private nonisolated(unsafe) static let unitWheel: CGPath = buildWheel()

    /// 舵輪を rect に収まる正方形いっぱいに描いたパス。
    static func wheel(in rect: CGRect) -> CGPath { scaled(unitWheel, to: rect, ratio: 1) }

    /// App アイコンの割り付けで、下地の上に載る大きさの舵輪。
    static func wheelOnTile(in rect: CGRect) -> CGPath {
        scaled(unitWheel, to: rect, ratio: wheelScale)
    }

    /// App アイコンの下地（角丸の正方形）。
    static func tile(in rect: CGRect) -> CGPath {
        let side = min(rect.width, rect.height)
        let inset = side * tileInset
        let box = CGRect(
            x: rect.midX - side / 2 + inset, y: rect.midY - side / 2 + inset,
            width: side - inset * 2, height: side - inset * 2)
        let radius = side * tileCornerRadius
        return CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// 単位正方形のパスを、rect に収まる正方形の `ratio` 倍へ拡大して中央に置く。
    private static func scaled(_ unit: CGPath, to rect: CGRect, ratio: CGFloat) -> CGPath {
        let side = min(rect.width, rect.height) * ratio
        var transform = CGAffineTransform(
            translationX: rect.midX - side / 2, y: rect.midY - side / 2
        ).scaledBy(x: side, y: side)
        return unit.copy(using: &transform) ?? unit
    }

    /// 線を太らせるときに使う座標系の 1 辺。
    ///
    /// **単位正方形（1 辺 1.0）のまま `copy(strokingWithWidth:)` を呼ばない。**
    /// 曲線の平坦化の許容誤差は座標の絶対値で効くので、1 辺 1.0 では丸端も円弧も
    /// 直線に潰れる（実際、輪が弦になり端が角になった）。1024 倍の座標で太らせて
    /// から縮める。
    private static let strokeSpace: CGFloat = 1024

    private static func buildWheel() -> CGPath {
        let big = CGMutablePath()
        let scale = strokeSpace
        // 太さごとにまとめて 1 回で太らせる。線ごとに copy(stroking:) を呼ぶと
        // 21 本ぶん輪郭生成が走る。
        var centerlines: [CGFloat: CGMutablePath] = [:]

        func scaled(_ point: CGPoint) -> CGPoint {
            CGPoint(x: point.x * scale, y: point.y * scale)
        }

        for primitive in unitPrimitives {
            switch primitive {
            case .disc(let center, let radius):
                // 円はスポークと重なる。巻き方向が線の輪郭と逆だと、nonzero で
                // 重なったところが穴になってハブが花びらに割れる（実際そうなった）。
                // CoreGraphics が線を太らせたときの外周と同じ向き＝時計回りで閉じる。
                big.addArc(
                    center: scaled(center), radius: radius * scale,
                    startAngle: 0, endAngle: 2 * .pi, clockwise: true)
                big.closeSubpath()

            case .bar(let from, let to, let width):
                let line = centerlines[width] ?? CGMutablePath()
                line.move(to: scaled(from))
                line.addLine(to: scaled(to))
                centerlines[width] = line

            case .ring(let center, let radius, let width):
                let line = centerlines[width] ?? CGMutablePath()
                // **move してから弧を足す。** 現在点があると addArc はそこから弧の
                // 始点まで線を引いてしまう。
                line.move(to: scaled(CGPoint(x: center.x + radius, y: center.y)))
                line.addArc(
                    center: scaled(center), radius: radius * scale,
                    startAngle: 0, endAngle: 2 * .pi, clockwise: false)
                centerlines[width] = line
            }
        }

        for (width, line) in centerlines.sorted(by: { $0.key < $1.key }) {
            big.addPath(
                line.copy(
                    strokingWithWidth: width * scale, lineCap: .round, lineJoin: .round,
                    miterLimit: 0))
        }

        var shrink = CGAffineTransform(scaleX: 1 / scale, y: 1 / scale)
        return big.copy(using: &shrink) ?? big
    }

    // MARK: - ビットマップ

    /// App アイコン 1 枚ぶん。下地の縦のグラデーションに舵輪を載せる。
    static func iconImage(side: CGFloat, scale: CGFloat = 1) -> CGImage? {
        guard let context = makeContext(side: side, scale: scale) else { return nil }
        let size = CGFloat(context.width)
        let frame = CGRect(x: 0, y: 0, width: size, height: size)

        context.saveGState()
        context.addPath(tile(in: frame))
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [tileTop, tileBottom] as CFArray,
            locations: [0, 1]) {
            // パスは Y 下向きの座標系で描いているので、始点が画面の上になる。
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: size), options: [])
        }
        context.restoreGState()

        context.addPath(wheelOnTile(in: frame))
        context.setFillColor(ink)
        context.fillPath()
        return context.makeImage()
    }

    /// Y を下向きに揃えた描画先。パスは SVG と同じ向き（Y 下向き）で作ってあり、
    /// CGContext の原点は左下で Y が上向きなので、ここで一度だけ入れ替える。
    private static func makeContext(side: CGFloat, scale: CGFloat) -> CGContext? {
        let pixels = Int((side * scale).rounded())
        guard pixels > 0,
              let context = CGContext(
                data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        return context
    }
}
