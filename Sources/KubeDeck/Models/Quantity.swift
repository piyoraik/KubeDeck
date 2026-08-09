import Foundation

/// Kubernetes の quantity（`100m`、`1Gi`、`81768992n` など）の解釈と整形。
///
/// metrics API は CPU をナノコア（`n`）、メモリを `Ki` で返す一方、Pod の
/// requests / limits は `100m` や `512Mi` で書かれる。同じ「CPU」でも桁が
/// 9 つ違うので、**必ず基本単位（CPU はコア、メモリはバイト）に直してから比べる**。
enum Quantity {
    /// 基本単位に直した値。CPU はコア数、メモリはバイト数。
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 末尾の単位を切り出す。2 文字（Ki, Mi …）を先に見る。
        let suffixes: [(String, Double)] = [
            ("Ki", 1024), ("Mi", 1_048_576), ("Gi", 1_073_741_824),
            ("Ti", 1_099_511_627_776), ("Pi", 1_125_899_906_842_624),
            ("Ei", 1_152_921_504_606_846_976),
            ("n", 1e-9), ("u", 1e-6), ("µ", 1e-6), ("m", 1e-3),
            ("k", 1e3), ("M", 1e6), ("G", 1e9),
            ("T", 1e12), ("P", 1e15), ("E", 1e18),
        ]

        for (suffix, multiplier) in suffixes where trimmed.hasSuffix(suffix) {
            let number = String(trimmed.dropLast(suffix.count))
            // `129e6` の `E`（指数）を単位の E と取り違えない。
            // 数値部が空、または指数の途中で切れていたら単位ではない。
            guard let value = Double(number), !number.isEmpty else { continue }
            return finite(value * multiplier)
        }

        return finite(Double(trimmed))
    }

    /// **有限でない値は「読めない」に倒す。**
    ///
    /// `Double(_:)` は `"Infinity"` も `"nan"` も受けるし、`resource.Quantity` は
    /// int64 に収まらない値を big-decimal で受け取るので **`cpu: "10E"`（1e19）は
    /// API サーバが通す正当な値**。ここを素通りさせると、整形の
    /// `Int(Double)` が trap して**アプリごと落ちる**（実測:
    /// `Fatal error: Double value cannot be converted to Int because the result
    /// would be greater than Int.max`）。しかも metrics-server が無い環境でも、
    /// その Pod の設定タブを開くだけで通る経路がある。
    ///
    /// nil にすれば、この型の既定の作法どおり `—`（取れていない）に落ちる。
    /// **0 にしない** —— 「無い」と「取れていない」を混ぜないのと同じ話。
    ///
    /// **落とすのは非有限だけ。** 一度は「int64 に収まらない値」も落としたが、
    /// それは**読めた値を「取れていない」ことにする**（＝このリポジトリが
    /// いちばん避けている取り違えの、こちら側）。`10Ei` は 1.15e19 で
    /// int64 を超えるが、こちらは正しく読めている。落とす理由は
    /// 「trap するから」だったので、**trap しないようにしたほうが筋**。
    /// 整形は `Int` を経由しないし、棒は `min(1, max(0, ratio))` で
    /// 抑えてある（`UsageBar`）。
    private static func finite(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    // MARK: - 整形

    /// CPU。`kubectl top` に合わせ、1 コア未満はミリコアで出す。
    static func formatCPU(cores: Double) -> String {
        // **`Int(Double)` を経由しない。** 整形は合計や割り算の結果にも掛かるので、
        // `parse` を通っていない値がここへ来る（`workloadUsage` の足し上げなど）。
        guard cores.isFinite else { return "—" }
        // 単位を落として "0" にしない。kubectl top も "0m" と出す。
        if cores <= 0 { return "0m" }
        if cores < 1 {
            let milli = cores * 1000
            // 1m 未満を 0m と出すと「使っていない」に見える。下限を 1m にする。
            return "\(max(1, Int(milli.rounded())))m"
        }
        // ちょうどのコア数（ノードの割り当て量など）は "8.00" ではなく "8" と出す。
        if abs(cores - cores.rounded()) < 0.005 {
            return String(format: "%.0f", cores.rounded())
        }
        return cores < 10
            ? String(format: "%.2f", cores)
            : String(format: "%.1f", cores)
    }

    /// メモリ。`kubectl top` に合わせて 2 進接頭辞で出す。
    static func formatMemory(bytes: Double) -> String {
        guard bytes.isFinite else { return "—" }
        guard bytes > 0 else { return "0" }
        let units: [(String, Double)] = [
            ("Ei", 1_152_921_504_606_846_976), ("Pi", 1_125_899_906_842_624),
            ("Ti", 1_099_511_627_776), ("Gi", 1_073_741_824),
            ("Mi", 1_048_576), ("Ki", 1024),
        ]
        for (unit, scale) in units where bytes >= scale {
            let value = bytes / scale
            return value < 10
                ? String(format: "%.1f%@", value, unit)
                : String(format: "%.0f%@", value.rounded(), unit)
        }
        return String(format: "%.0f", bytes.rounded())
    }

    /// 使用率。分母が 0 のときは nil（「0%」と出すと使い切っていないと読める）。
    static func ratio(_ used: Double, of total: Double) -> Double? {
        guard total > 0 else { return nil }
        return used / total
    }

    static func formatPercent(_ ratio: Double) -> String {
        guard ratio.isFinite else { return "—" }
        let percent = ratio * 100
        return percent < 10
            ? String(format: "%.1f%%", percent)
            : String(format: "%.0f%%", percent.rounded())
    }
}
