import AppKit
import CoreGraphics
import Foundation

// App アイコンの PNG を作る。
// 図形の定義は Scripts/KubeDeckLogo.swift（角丸の下地と、単位正方形に置いた舵輪）に
// あり、このスクリプトはそれと一緒にコンパイルされる。**幾何をここに書き写さない。**
// 写した時点で PNG と SVG がずれ始める。同じ定義から SVG も出る（generate-svg.sh）。
//
// 画面内のマーク（Views/KubernetesLogo.swift）とは別物。画面内は「Kubernetes を
// 指している」ので公式ロゴ、App アイコンは「この製品」なので独自マーク。

// 複数ファイルでコンパイルするので、入口は main.swift のトップレベルではなく @main。
@main
struct IconGenerator {
    static func main() throws {
        let destination = CommandLine.arguments[1]
        for size in [16, 32, 64, 128, 256, 512, 1024] {
            guard let image = KubeDeckLogo.iconImage(side: CGFloat(size)),
                  let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
            else { throw CocoaError(.fileWriteUnknown) }
            try data.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size).png"))
        }
        print("generated \(destination)")
    }
}
