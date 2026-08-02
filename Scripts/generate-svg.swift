import CoreGraphics
import Foundation

// KubeDeck のマークを SVG で書き出す。
//
// 図形の定義は Scripts/KubeDeckLogo.swift の `unitPrimitives`
// にあり、このスクリプトはそれと一緒にコンパイルされる。**座標をここへ写さない。**
// 写した時点で SVG と Dock と画面内がずれ始める。
//
// 中心線を SVG の stroke でそのまま出す（輪郭を焼き固めない）。数値が少なくて
// 人が読めるうえ、丸端の意味は CoreGraphics の .round と同じなので図形も一致する。

/// 見て分かる長さに丸める。末尾の 0 は落とす。
func fmt(_ value: CGFloat) -> String {
    var text = String(format: "%.3f", value)
    if text.contains(".") {
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
    }
    return text == "-0" ? "0" : text
}

struct SVGBuilder {
    /// キャンバスの 1 辺（px）。
    let canvas: CGFloat
    /// 舵輪の直径のキャンバス比。
    let wheelScale: CGFloat

    private var scale: CGFloat { canvas * wheelScale }
    private var origin: CGFloat { (canvas - scale) / 2 }

    private func x(_ value: CGFloat) -> CGFloat { origin + value * scale }
    private func length(_ value: CGFloat) -> CGFloat { value * scale }

    /// 舵輪を SVG の要素にする。太さの同じ直線は 1 本の `<path>` にまとめ、
    /// 輪と中央のハブは `<circle>` にする（`A` で 360° を書くと始点と終点が
    /// 重なって描かれないため）。
    func wheelElements(color: String) -> [String] {
        var strokes: [(width: CGFloat, segments: [String])] = []
        var rings: [String] = []
        var discs: [String] = []

        func append(width: CGFloat, segment: String) {
            if let index = strokes.firstIndex(where: { $0.width == width }) {
                strokes[index].segments.append(segment)
            } else {
                strokes.append((width, [segment]))
            }
        }

        for primitive in KubeDeckLogo.unitPrimitives {
            switch primitive {
            case .disc(let center, let radius):
                discs.append(
                    "<circle cx=\"\(fmt(x(center.x)))\" cy=\"\(fmt(x(center.y)))\""
                        + " r=\"\(fmt(length(radius)))\" fill=\"\(color)\"/>")

            case .ring(let center, let radius, let width):
                rings.append(
                    "<circle cx=\"\(fmt(x(center.x)))\" cy=\"\(fmt(x(center.y)))\""
                        + " r=\"\(fmt(length(radius)))\" stroke-width=\"\(fmt(length(width)))\"/>")

            case .bar(let from, let to, let width):
                append(
                    width: width,
                    segment: "M\(fmt(x(from.x))) \(fmt(x(from.y)))"
                        + "L\(fmt(x(to.x))) \(fmt(x(to.y)))")
            }
        }

        let paths = strokes.map { stroke in
            "<path d=\"\(stroke.segments.joined())\" stroke-width=\"\(fmt(length(stroke.width)))\"/>"
        }
        let group =
            ["<g fill=\"none\" stroke=\"\(color)\" stroke-linecap=\"round\" stroke-linejoin=\"round\">"]
            + (rings + paths).map { "  " + $0 } + ["</g>"]
        return group + discs
    }

    func document(title: String, body: [String], defs: [String] = []) -> String {
        var lines = [
            "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(fmt(canvas)) \(fmt(canvas))\""
                + " width=\"\(fmt(canvas))\" height=\"\(fmt(canvas))\""
                + " role=\"img\" aria-label=\"\(title)\">",
            "  <title>\(title)</title>",
        ]
        if !defs.isEmpty {
            lines.append("  <defs>")
            lines.append(contentsOf: defs.map { "    " + $0 })
            lines.append("  </defs>")
        }
        lines.append(contentsOf: body.map { "  " + $0 })
        lines.append("</svg>")
        return lines.joined(separator: "\n") + "\n"
    }
}

// 複数ファイルでコンパイルするので、入口は main.swift のトップレベルではなく @main。
@main
struct SVGGenerator {
    static func main() throws {
        let destination = CommandLine.arguments[1]
        let canvas: CGFloat = 1024

        // 1. App アイコン。角丸の下地に白い舵輪。
        let icon = SVGBuilder(canvas: canvas, wheelScale: KubeDeckLogo.wheelScale)
        let inset = canvas * KubeDeckLogo.tileInset
        let tileSide = canvas - inset * 2
        let tile =
            "<rect x=\"\(fmt(inset))\" y=\"\(fmt(inset))\" width=\"\(fmt(tileSide))\""
            + " height=\"\(fmt(tileSide))\""
            + " rx=\"\(fmt(canvas * KubeDeckLogo.tileCornerRadius))\" fill=\"url(#kd-tile)\"/>"
        let gradient = [
            "<linearGradient id=\"kd-tile\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\">",
            "  <stop offset=\"0\" stop-color=\"\(KubeDeckLogo.hexString(KubeDeckLogo.tileTopHex))\"/>",
            "  <stop offset=\"1\" stop-color=\"\(KubeDeckLogo.hexString(KubeDeckLogo.tileBottomHex))\"/>",
            "</linearGradient>",
        ]
        try write(
            icon.document(
                title: "KubeDeck",
                body: [tile] + icon.wheelElements(color: KubeDeckLogo.hexString(KubeDeckLogo.inkHex)),
                defs: gradient),
            to: "\(destination)/kubedeck-icon.svg")

        // 2. マーク単体。下地なし・青一色。README や資料に置く用。
        //    舵輪を縁いっぱいまで使うので wheelScale は 1。
        let mark = SVGBuilder(canvas: canvas, wheelScale: 1)
        try write(
            mark.document(
                title: "KubeDeck",
                body: mark.wheelElements(color: KubeDeckLogo.hexString(KubeDeckLogo.brandBlueHex))),
            to: "\(destination)/kubedeck-mark.svg")

        // 3. 単色版。色は置き先の文字色に従わせる（メニューバーや本文中に混ぜる用）。
        try write(
            mark.document(title: "KubeDeck", body: mark.wheelElements(color: "currentColor")),
            to: "\(destination)/kubedeck-mark-mono.svg")

        print("generated \(destination)")
    }

    private static func write(_ text: String, to path: String) throws {
        try text.write(to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
    }
}
