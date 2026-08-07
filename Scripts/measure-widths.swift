// 訳が、決め打ちの幅に収まるかを測る。
//
//   swift Scripts/measure-widths.swift
//
// **撮って眺めるより測る。** 一覧の列は `.fixed(n)` で決めてあり、収まらなければ
// `.lineLimit(1)` で黙って切れる（切れたことが画面に出ない）。幅は日本語で決めた
// ものなので、語長の違う訳では溢れる。実際にこれで 3 件見つけ、そこから
// `希望 → Preferred`（正しくは Desired）のような**誤訳**も 6 件出た。
//
// **列の拾い方は正規表現なので脆い。** `ResourceColumn(title:width:)` の書き方を
// 変えたらここも直すこと。測った列数が減ったら、それは拾えていない印。
import AppKit
import Foundation

let root = FileManager.default.currentDirectoryPath
let source = try String(contentsOfFile: "\(root)/Sources/KubeDeck/Models/ResourceTable.swift")
let catalog = try JSONSerialization.jsonObject(
    with: Data(contentsOf: URL(fileURLWithPath: "\(root)/Resources/Localizable.xcstrings")))
    as! [String: Any]
let strings = catalog["strings"] as! [String: Any]

func english(_ key: String) -> String? {
    guard let entry = strings[key] as? [String: Any],
          let locs = entry["localizations"] as? [String: Any],
          let en = locs["en"] as? [String: Any],
          let unit = en["stringUnit"] as? [String: Any]
    else { return nil }
    return unit["value"] as? String
}

// 見出しは `.font(.caption.weight(.semibold))`。caption は 11pt 相当。
let headerFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
// `InfoRow` のラベル欄は `.font(.caption)` で幅 96pt 固定。
let bodyFont = NSFont.systemFont(ofSize: 11)

func width(_ text: String, _ font: NSFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
}

// MARK: - 一覧の列

// `ResourceColumn(title: "…", width: .fixed(n))` / `.flexible(min: n)` を拾う。
let pattern = try NSRegularExpression(
    pattern: #"ResourceColumn\(\s*(?:serverTitle|title):\s*"((?:[^"\\]|\\.)*)"\s*,\s*width:\s*\.(fixed|flexible)\((?:min:\s*)?([0-9.]+)\)"#,
    options: [.dotMatchesLineSeparators])

struct Finding {
    let key: String, en: String, limit: CGFloat, jaWidth: CGFloat, enWidth: CGFloat
}
var findings: [Finding] = []
var checked = 0

let ns = source as NSString
pattern.enumerateMatches(in: source, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
    guard let m else { return }
    let key = ns.substring(with: m.range(at: 1))
    let kind = ns.substring(with: m.range(at: 2))
    let value = CGFloat(Double(ns.substring(with: m.range(at: 3)))!)
    guard kind == "fixed" else { return }   // flexible は伸びるので溢れない
    guard let en = english(key) else { return }
    checked += 1
    // 見出しの欄には並べ替えの矢印（7pt）と間隔 3pt が入る。
    let limit = value - 10
    let jw = width(key, headerFont), ew = width(en, headerFont)
    if ew > limit {
        findings.append(Finding(key: key, en: en, limit: limit, jaWidth: jw, enWidth: ew))
    }
}

print("=== 一覧の列（固定幅）: \(checked) 列を測った ===")
if findings.isEmpty {
    print("  溢れなし")
}
for f in findings.sorted(by: { $0.enWidth - $0.limit > $1.enWidth - $1.limit }) {
    let over = Int((f.enWidth - f.limit).rounded())
    print(String(
        format: "  溢れ +%3dpt  上限 %5.0f  ja %5.1f  en %5.1f  「%@」→ 「%@」",
        over, f.limit, f.jaWidth, f.enWidth, f.key, f.en))
}

// MARK: - 詳細パネルの見出し欄（幅 96pt 固定）

// `InfoRow` のラベルに渡している鍵。基本 / クラスタの行で使うものだけ見る。
let infoLabels = [
    "種別", "Namespace", "作成", "経過", "UID", "ノード", "Pod IP", "ServiceAccount",
    "再起動", "種類", "ポート", "ランタイム", "アーキテクチャ", "内部 IP", "メモリ",
    "Pod 上限", "更新方式", "容量", "アクセス", "対象", "理由", "回数", "内容",
    "バージョン", "自動更新", "最終更新", "イメージ",
]
print("\n=== 詳細パネルの見出し欄（96pt 固定）: \(infoLabels.count) 件 ===")
var infoOver = 0
for key in infoLabels {
    guard let en = english(key) else { print("  訳が無い: \(key)"); continue }
    let ew = width(en, bodyFont)
    if ew > 96 {
        infoOver += 1
        print(String(format: "  溢れ +%3dpt  ja %5.1f  en %5.1f  「%@」→ 「%@」",
                     Int((ew - 96).rounded()), width(key, bodyFont), ew, key, en))
    }
}
if infoOver == 0 { print("  溢れなし") }
