import SwiftUI

/// 割合の棒だけを描く部品。
struct UsageBar: View {
    let ratio: Double
    /// 目盛りの位置（0...1）。上限を分母にしたとき、要求がどこかを示す。
    ///
    /// **要求のためにもう 1 本棒を出さない。** 同じ量を 2 度描くことになるうえ、
    /// どちらの分母を見ているのか分からなくなる。1 本の上に印を置く。
    var marker: Double?
    /// 系列の色。**同じ系列を違う色で描かない。** 概要の使用量は、履歴が
    /// 取れるクラスタでは折れ線（CPU は青、メモリは橙）、取れないクラスタでは
    /// この棒になる。棒だけ状態の色にしていたので、環境によって同じカードが
    /// 別物に見えた。しきい値超えは割合の文字の色が持つ。
    /// nil なら状態の色（Pod や Node の使用率など、しきい値が主役のところ）。
    var tint: Color?

    init(ratio: Double, marker: Double? = nil, tint: Color? = nil) {
        self.ratio = ratio
        self.marker = marker
        self.tint = tint
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.subtleFill)
                Capsule()
                    .fill(tint ?? Palette.color(for: ResourceTable.usageLevel(ratio) ?? .good))
                    // 1% でも使っていれば見える太さを残す。
                    .frame(width: max(3, proxy.size.width * min(1, max(0, ratio))))
                if let marker, marker > 0, marker < 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.65))
                        .frame(width: 2)
                        .offset(x: proxy.size.width * marker - 1)
                }
            }
        }
        // 目盛りが読める太さが要る。6pt では 2pt の印が潰れて見えなかった。
        .frame(height: 8)
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
    /// 棒の下に 1 行だけ添える補足（上限の値など）。
    ///
    /// **上限を 2 本目の棒にしない。** 上限は要求より大きいのがふつうで、
    /// 要求を基準にした棒には収まらない。割合を 2 つ並べても、どちらの
    /// 分母を見ているのか分からなくなるだけ。数字で 1 行足す。
    var note: String?
    /// 補足を目立たせるか（上限を超えているときなど）。
    var noteLevel: StatusLevel?
    /// 棒に置く目盛りの位置（0...1）。
    var marker: Double?

    init(
        title: String, used: String, total: String, ratio: Double?,
        note: String? = nil, noteLevel: StatusLevel? = nil, marker: Double? = nil
    ) {
        self.title = title
        self.used = used
        self.total = total
        self.ratio = ratio
        self.note = note
        self.noteLevel = noteLevel
        self.marker = marker
    }

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

            // **補足を自分の棒に寄せる。** 上下を同じ間隔で並べたら、CPU の
            // 「上限 …」がメモリの見出しと等距離になり、どちらのものか分から
            // なかった。中を詰めて、計器どうしのあいだを空ける。
            VStack(alignment: .leading, spacing: 3) {
                if let ratio {
                    UsageBar(ratio: ratio, marker: marker)
                }
                if let note {
                    Text(note)
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(
                            noteLevel.map { Palette.textColor(for: $0) } ?? Color.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.bottom, note == nil ? 0 : 7)
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
                    .help(sourceHelp)
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
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.cardStroke, lineWidth: 1))
        .shadow(color: Palette.cardShadow, radius: 6, y: 2)
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
                // 折れ線と同じ系列色にする。取得元の違いで見た目が変わらないように。
                UsageBar(ratio: ratio, tint: tint)
            }
        }
    }

    private var sourceLabel: String {
        if store.metricsServerAvailable == nil && store.prometheus == nil { return "確認中" }
        var parts: [String] = []
        if store.activeMetricsSource.isAvailable { parts.append(store.activeMetricsSource.label) }
        if store.prometheus != nil, !store.clusterHistory.cpu.isEmpty {
            parts.append("推移 30 分")
        } else if store.activeMetricsSource.isAvailable {
            // **見せ方が変わる理由を黙らない。** 履歴が取れるクラスタでは
            // 折れ線、取れないクラスタでは割合の棒になる（同じことを描く図を
            // 2 つ並べないため）。断りが無いと、環境ごとに作りが違うように見える。
            parts.append("現在値のみ")
        }
        return parts.joined(separator: " · ")
    }

    /// 添え書きの補足。折れ線が出ない理由をここで言う。
    private var sourceHelp: String {
        store.prometheus == nil
            ? "推移（折れ線）は Prometheus からしか出せません。見つからないクラスタでは、いまの割合を棒で出します。"
            : "推移は Prometheus から、いまの値は \(store.activeMetricsSource.label) から取っています。"
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
