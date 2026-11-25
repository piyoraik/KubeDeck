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
    /// nil なら、しきい値を超えたときだけ状態の色（Pod や Node の使用率）。
    /// **超えるまでは無彩色** —— 正常な棒を緑で塗ると、健全なほど画面が緑で埋まる。
    var tint: Color?
    /// 目盛りを置くなら 8pt 要る（6pt では 2pt の印が潰れて見えなかった）。
    var height: CGFloat

    init(ratio: Double, marker: Double? = nil, tint: Color? = nil, height: CGFloat = 8) {
        self.ratio = ratio
        self.marker = marker
        self.tint = tint
        self.height = height
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.subtleFill)
                Capsule()
                    .fill(
                        tint ?? ResourceTable.usageLevel(ratio).map { Palette.color(for: $0) }
                            ?? Palette.meterNeutral)
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
        .frame(height: height)
    }
}

/// 使用量の横棒に見出しと数値を添えたもの。詳細パネルで使う。
///
/// 割合を長さで、しきい値超えを色で示す。色だけに意味を持たせないよう、
/// 実測値と割合を必ず文字でも出す。
struct UsageMeter: View {
    let title: LocalizedStringResource
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
    /// しきい値を超えたら色を付けるか。**分母が要求のときは付けない** —— 要求は
    /// 置き場所を決めるための申告で、超えること自体は異常ではない。
    var colorsByThreshold: Bool

    init(
        title: LocalizedStringResource, used: String, total: String, ratio: Double?,
        note: String? = nil, noteLevel: StatusLevel? = nil, marker: Double? = nil,
        colorsByThreshold: Bool = true
    ) {
        self.title = title
        self.used = used
        self.total = total
        self.ratio = ratio
        self.note = note
        self.noteLevel = noteLevel
        self.marker = marker
        self.colorsByThreshold = colorsByThreshold
    }

    /// しきい値を超えたときの重み。超えていなければ nil（色を付けない）。
    private var level: StatusLevel? {
        guard colorsByThreshold, let ratio else { return nil }
        return ResourceTable.usageLevel(ratio)
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
                        .foregroundStyle(level.map { Palette.textColor(for: $0) } ?? Color.secondary)
                        .frame(minWidth: 42, alignment: .trailing)
                }
            }

            // **補足を自分の棒に寄せる。** 上下を同じ間隔で並べたら、CPU の
            // 「上限 …」がメモリの見出しと等距離になり、どちらのものか分から
            // なかった。中を詰めて、計器どうしのあいだを空ける。
            VStack(alignment: .leading, spacing: 3) {
                if let ratio {
                    UsageBar(
                        ratio: ratio, marker: marker,
                        tint: level.map { Palette.color(for: $0) } ?? Palette.meterNeutral)
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

/// 使用量をまだ引いている最中であることを 1 行で言う。
///
/// **「取得できません」と同じ見た目にしない。** あちらは結果で、こちらは
/// 途中経過（`MetricsPhase`）。同じ文面にすると、**待てば出るものを
/// 「出ない」と読ませる**（そして人はもう一度探しに行く）。
struct MetricsPendingLabel: View {
    let phase: MetricsPhase
    /// 回る印を付けるか。**並べる場所では付けない** —— 配置画面はノードの箱
    /// ごとにこれを出すので、20 個の輪が同時に回ることになる（舵輪を Core
    /// Animation に逃がしたのと同じ話で、待っているだけの絵に CPU を使わない）。
    var spins = true
    var font: Font = .caption

    var body: some View {
        HStack(spacing: 6) {
            if spins {
                ProgressView().controlSize(.small)
            }
            // **「取得元を探している」と「値を待っている」を分ける。** 前者は
            // 入っているかどうかがまだ分からない段で、後者はもう待つだけ。
            if phase == .detecting {
                Text("使用量の取得元を確認しています…")
            } else {
                Text("使用量を取得しています…")
            }
        }
        .font(font)
        .foregroundStyle(.secondary)
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
                        ? String(
                            localized: "\(Quantity.formatCPU(cores: allocatable.cpuCores)) コア")
                        : "",
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
            } else if store.metricsPhase.isPending {
                // **まだ引いていないことを「取得できません」と書かない。**
                // 取得元の探索と最初の取得で、遅い経路では十数秒かかる。
                MetricsPendingLabel(phase: store.metricsPhase)
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
        title: LocalizedStringResource, used: String, total: String, ratio: Double?,
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
        switch store.metricsPhase {
        case .detecting:
            return String(localized: "確認中")
        case .loading:
            // **取得元の名前も出す。** どこから取ろうとしているのかは、
            // 待っているあいだにいちばん知りたいこと。
            return [store.activeMetricsSource.label, String(localized: "取得中")]
                .joined(separator: " · ")
        case .ready, .unavailable:
            break
        }
        var parts: [String] = []
        if store.activeMetricsSource.isAvailable { parts.append(store.activeMetricsSource.label) }
        if store.prometheus != nil, !store.clusterHistory.cpu.isEmpty {
            // **「30 分」と直に書かない。** 範囲は設定で変えられる。
            parts.append(String(localized: "推移 \(Preferences.shared.historyWindowLabel)"))
        } else if store.activeMetricsSource.isAvailable {
            // **見せ方が変わる理由を黙らない。** 履歴が取れるクラスタでは
            // 折れ線、取れないクラスタでは割合の棒になる（同じことを描く図を
            // 2 つ並べないため）。断りが無いと、環境ごとに作りが違うように見える。
            parts.append(String(localized: "現在値のみ"))
        }
        return parts.joined(separator: " · ")
    }

    /// 添え書きの補足。折れ線が出ない理由をここで言う。
    private var sourceHelp: String {
        store.prometheus == nil
            ? String(localized: """
                推移（折れ線）は Prometheus からしか出せません。\
                見つからないクラスタでは、いまの割合を棒で出します。
                """)
            : String(localized: """
                推移は Prometheus から、いまの値は \
                \(store.activeMetricsSource.label) から取っています。
                """)
    }

    private var unavailableReason: String {
        if let problem = store.metricsSourceProblem { return problem }
        // **ここに「確認しています」を持たない。** 調べている最中は
        // `MetricsPendingLabel` が出る側で、この文面は**調べ終えた結果**だけを
        // 言う（2 か所が同じことを言うと、片方だけ直したときに食い違う）。
        // **取得元が無いことにしない。** 取得元はあるのにノードの使用量だけ
        // 引けないことがある（GKE の Warden など、管理されたクラスタは
        // ノードの指標を拒みつつ Pod の指標は通す）。そこで「見つかりません」と
        // 書くと、入れれば直ると読めてしまう。
        if store.activeMetricsSource.isAvailable {
            // **`+` で継ぎ足さない。** 後半は `String(localized:)` を通って
            // いなかったので抽出の対象にすらならず、カタログに鍵が無い。
            // つまり**英語の画面で後半だけ日本語のまま出ていた**（前半の
            // `取得元は %@ です。` は訳が入っている）。しかもこの文面は
            // 「取得元が無い」と「ノードの指標だけ拒まれた」を書き分けるために
            // 足したもので、いちばん訳されていてほしいところだった。
            // 1 つの文に 1 つの鍵を当て、行は複数行リテラルの `\` で折る。
            return String(localized: """
                取得元は \(store.activeMetricsSource.label) です。\
                ただしノードの使用量が引けないため、クラスタ全体の割合は出せません。\
                管理されたクラスタでは、ノードの指標だけ拒まれることがあります。\
                Pod ごとの使用量は一覧の列に出ます。
                """)
        }

        return String(localized: """
            このクラスタには metrics-server も Prometheus も見つかりません。\
            どちらかを入れると CPU とメモリの使用量が出ます。
            """)
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
