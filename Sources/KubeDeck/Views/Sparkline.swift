import Charts
import SwiftUI

/// 時系列の小さな折れ線。
///
/// 目盛りも凡例も置かない。読み取るのは「いま幾つか」と「上がっているか」の
/// 2 つだけなので、現在値は数字で直に添え、最大値だけを影として示す。
/// 系列が 1 本なので凡例は要らない（見出しが系列名を兼ねる）。
struct Sparkline: View {
    let series: TimeSeries
    let tint: Color
    /// 値を人が読む形にする（CPU ならミリコア、メモリなら Mi）。
    let format: (Double) -> String

    var body: some View {
        Chart(series.points, id: \.date) { point in
            AreaMark(
                x: .value("時刻", point.date),
                y: .value("値", point.value))
                .foregroundStyle(
                    .linearGradient(
                        colors: [tint.opacity(0.28), tint.opacity(0.02)],
                        startPoint: .top, endPoint: .bottom))
            LineMark(
                x: .value("時刻", point.date),
                y: .value("値", point.value))
                .lineStyle(StrokeStyle(lineWidth: 2, lineJoin: .round))
                .foregroundStyle(tint)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        // 0 を底に固定する。自動だと僅かな揺れが山に見える。
        .chartYScale(domain: 0...max(series.maximum * 1.15, .leastNonzeroMagnitude))
        .chartLegend(.hidden)
        .accessibilityLabel(Text("時系列"))
        .accessibilityValue(
                Text(series.latest.map(format) ?? String(localized: "データなし")))
    }
}

/// スパークライン 1 枚分。見出し・現在値・折れ線をまとめる。
struct MetricsHistoryRow: View {
    let title: LocalizedStringResource
    let series: TimeSeries
    let tint: Color
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                if let latest = series.latest {
                    Text(format(latest))
                        .font(.callout.weight(.medium))
                        .monospacedDigit()
                }
                if series.maximum > 0 {
                    Text("最大 \(format(series.maximum))")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }

            if series.isEmpty {
                // 「点が 1 つしかない」と「取れていない」を同じ空欄にしない。
                Text(series.points.isEmpty ? "履歴がありません。" : "点が足りません（収集直後）。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(height: 44, alignment: .leading)
            } else {
                Sparkline(series: series, tint: tint, format: format)
                    .frame(height: 44)
            }
        }
    }
}
