import SwiftUI

/// 割合の棒だけを描く部品。
struct UsageBar: View {
    let ratio: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.subtleFill)
                Capsule()
                    .fill(Palette.color(for: ResourceTable.usageLevel(ratio) ?? .good))
                    // 1% でも使っていれば見える太さを残す。
                    .frame(width: max(3, proxy.size.width * min(1, max(0, ratio))))
            }
        }
        .frame(height: 6)
    }
}

/// 使用量の横棒に見出しと数値を添えたもの。詳細パネルで使う。
///
/// 割合を長さで、しきい値超えを色で示す。色だけに意味を持たせないよう、
/// 実測値と割合を必ず文字でも出す。
struct UsageMeter: View {
    let title: String
    let used: String
    let total: String
    /// 0...1。分母が取れないときは nil で、そのときは棒を出さない。
    let ratio: Double?

    private var level: StatusLevel {
        guard let ratio else { return .neutral }
        return ResourceTable.usageLevel(ratio) ?? .good
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(used)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if !total.isEmpty {
                    Text("/ \(total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let ratio {
                    Text(Quantity.formatPercent(ratio))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(Palette.textColor(for: level))
                        .frame(minWidth: 42, alignment: .trailing)
                }
            }

            if let ratio {
                UsageBar(ratio: ratio)
            }
        }
    }
}

/// 概要に出すクラスタ全体の使用量。
///
/// 瞬時値と推移を 1 枚にまとめる。別カードに分けると、同じ CPU とメモリの
/// 見出しが画面に 2 度出て、どちらを見ればよいのか分からなくなる。
struct ClusterUsageCard: View {
    @Environment(ClusterStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("リソース使用量")
                    .font(.headline)
                Spacer(minLength: 8)
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if let usage = store.clusterUsage {
                let allocatable = store.overview.allocatable
                metric(
                    title: "CPU",
                    used: Quantity.formatCPU(cores: usage.cpuCores),
                    total: allocatable.cpuCores > 0
                        ? "\(Quantity.formatCPU(cores: allocatable.cpuCores)) コア" : "",
                    ratio: Quantity.ratio(usage.cpuCores, of: allocatable.cpuCores),
                    series: store.clusterHistory.cpu,
                    tint: Palette.seriesCPU,
                    format: { Quantity.formatCPU(cores: $0) })
                metric(
                    title: "メモリ",
                    used: Quantity.formatMemory(bytes: usage.memoryBytes),
                    total: allocatable.memoryBytes > 0
                        ? Quantity.formatMemory(bytes: allocatable.memoryBytes) : "",
                    ratio: Quantity.ratio(usage.memoryBytes, of: allocatable.memoryBytes),
                    series: store.clusterHistory.memory,
                    tint: Palette.seriesMemory,
                    format: { Quantity.formatMemory(bytes: $0) })
            } else {
                unavailable
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.hairline, lineWidth: 1))
    }

    /// 1 つの指標。**棒と折れ線を同時に出さない。**
    /// どちらも「どれだけ使っているか」を描く図で、並べても情報が増えない。
    /// 推移が取れるならそちらを出し、無ければ割合の棒を出す。
    @ViewBuilder
    private func metric(
        title: String, used: String, total: String, ratio: Double?,
        series: TimeSeries, tint: Color, format: @escaping (Double) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(used)
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                if !total.isEmpty {
                    Text("/ \(total)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if let ratio {
                    Text(Quantity.formatPercent(ratio))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(
                            Palette.textColor(for: ResourceTable.usageLevel(ratio) ?? .good))
                        .frame(minWidth: 42, alignment: .trailing)
                }
            }

            if !series.isEmpty {
                Sparkline(series: series, tint: tint, format: format)
                    .frame(height: 40)
            } else if let ratio {
                UsageBar(ratio: ratio)
            }
        }
    }

    private var sourceLabel: String {
        if store.metricsServerAvailable == nil && store.prometheus == nil { return "確認中" }
        var parts: [String] = []
        if store.activeMetricsSource.isAvailable { parts.append(store.activeMetricsSource.label) }
        if store.prometheus != nil, !store.clusterHistory.cpu.isEmpty { parts.append("推移 30 分") }
        return parts.joined(separator: " · ")
    }

    private var unavailableReason: String {
        if let problem = store.metricsSourceProblem { return problem }
        if store.metricsServerAvailable == nil { return "取得元を確認しています。" }
        // **取得元が無いことにしない。** 取得元はあるのにノードの使用量だけ
        // 引けないことがある（GKE の Warden など、管理されたクラスタは
        // ノードの指標を拒みつつ Pod の指標は通す）。そこで「見つかりません」と
        // 書くと、入れれば直ると読めてしまう。
        if store.activeMetricsSource.isAvailable {
            return "取得元は \(store.activeMetricsSource.label) です。"
                + "ただしノードの使用量が引けないため、クラスタ全体の割合は出せません。"
                + "管理されたクラスタでは、ノードの指標だけ拒まれることがあります。"
                + "Pod ごとの使用量は一覧の列に出ます。"
        }
        return "このクラスタには metrics-server も Prometheus も見つかりません。どちらかを入れると CPU とメモリの使用量が出ます。"
    }

    /// 取れない理由を書く。空欄にすると、値が 0 なのか
    /// 取得できていないのか区別が付かない。
    private var unavailable: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("使用量を取得できません", systemImage: "questionmark.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(unavailableReason)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
