import SwiftUI

// 配置の 2 つの見方（ノード別・ワークロード別）で共通に使う部品。

/// 配置のカード。並べたとき、同じ行のカードと高さが揃うように広がる。
struct PlacementCard<Content: View>: View {
    var padding = EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14)
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.cardStroke, lineWidth: 1))
        // 影は 1 段だけ。段を重ねると画面がぼやける。
        .shadow(color: Palette.cardShadow, radius: 6, y: 2)
    }
}

/// 見出しの右に置く小さな札。件数のような添え物を、本文と同じ字面で並べないための入れ物。
struct CountPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Palette.insetFill))
            .fixedSize()
    }
}

// MARK: - Pod のチップ

/// チップに出す名前。
enum PodChipNaming {
    /// しるしだけ。名前は指したときに出す。
    case hidden
    case full
    /// Pod の id → ワークロードの中で区別に要る部分。
    case suffix([String: String])

    func label(for pod: K8sObject) -> String? {
        switch self {
        case .hidden: return nil
        case .full: return pod.name
        case .suffix(let labels): return labels[pod.id] ?? pod.name
        }
    }

    var showsName: Bool {
        if case .hidden = self { return false }
        return true
    }

    var showsFullName: Bool {
        if case .full = self { return true }
        return false
    }
}

/// Pod 1 つぶん。
///
/// **正常な Pod には色を付けない。** 色としるしと状態の語を出すのは、正常でないものだけ
/// （合格印で埋め尽くさない）。選択はアクセントの縁で示す。
struct PodChip: View {
    @Environment(ClusterStore.self) private var store
    let pod: K8sObject
    let label: String?

    static let height: CGFloat = 22

    private var isSelected: Bool { store.selectedObjectID == pod.id }

    var body: some View {
        let status = StatusResolver.health(for: pod)
        let pressure = store.metrics.pressure(
            of: pod, metric: Preferences.shared.placementMetric)
        let help = helpText(status)
        let shape = RoundedRectangle(cornerRadius: 6)

        Button {
            // 一覧の行と同じ入口を通す（操作の対象になる集合を取り残さない）。
            store.selectOnly(pod)
        } label: {
            content(status)
                .frame(height: Self.height)
                .background(fill(status.level))
                .overlay(alignment: .bottomLeading) { bar(pressure) }
                .clipShape(shape)
                .overlay(shape.stroke(Color.accentColor.opacity(isSelected ? 0.9 : 0), lineWidth: 1.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        // 名前を切って出しているので、読み上げにはここで全体を渡す。
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder
    private func content(_ status: ResourceStatus) -> some View {
        let isPlain = status.level == .good
        if let label {
            HStack(spacing: 5) {
                if !isPlain {
                    Image(systemName: status.level.symbol)
                        .font(.system(size: 10))
                }
                Text(label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !isPlain {
                    // 色だけで言わない。状態の語も書く。
                    Text(status.text)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
            .font(.subheadline)
            .foregroundStyle(ink(status.level))
            .padding(.horizontal, 7)
        } else {
            ZStack {
                if !isPlain {
                    Image(systemName: status.level.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(ink(status.level))
                }
            }
            .frame(width: Self.height)
        }
    }

    private func ink(_ level: StatusLevel) -> Color {
        switch level {
        case .good: return Color.primary.opacity(0.86)
        case .neutral: return .secondary
        case .warning, .serious, .critical: return Palette.textColor(for: level)
        }
    }

    private func fill(_ level: StatusLevel) -> Color {
        if isSelected { return Color.accentColor.opacity(0.22) }
        switch level {
        case .good, .neutral: return Palette.chipFill
        case .warning, .serious, .critical: return Palette.color(for: level).opacity(0.18)
        }
    }

    /// 使用量は下の縁に 1 本だけ。上限に迫ったときだけ色を付ける。
    @ViewBuilder
    private func bar(_ pressure: PodPressure?) -> some View {
        if let pressure, label != nil {
            Rectangle()
                .fill(pressure.level.map { Palette.color(for: $0) } ?? Palette.meterNeutral)
                .frame(height: 2)
                .scaleEffect(x: min(1, max(0.05, pressure.ratio)), y: 1, anchor: .leading)
        }
    }

    private func helpText(_ status: ResourceStatus) -> String {
        var text = "\(pod.namespace ?? "-")/\(pod.name) · \(status.text)"
        if let usage = store.metrics.usage(for: pod) {
            let cpu = Quantity.formatCPU(cores: usage.cpuCores)
            let memory = Quantity.formatMemory(bytes: usage.memoryBytes)
            text += " · CPU \(cpu) · " + String(localized: "メモリ \(memory)")
        }
        return text
    }
}

/// Pod のチップの並び。困っているものを先に出す。
struct PodChips: View {
    let pods: [K8sObject]
    let naming: PodChipNaming

    var body: some View {
        let gap: CGFloat = naming.showsName ? 5 : 4
        ChipFlow(spacing: gap, lineSpacing: gap) {
            ForEach(Self.sorted(pods)) { pod in
                PodChip(pod: pod, label: naming.label(for: pod))
            }
        }
    }

    /// 並びが毎回変わらないよう、同じ重みなら名前順。
    static func sorted(_ pods: [K8sObject]) -> [K8sObject] {
        let keyed = pods.map { (pod: $0, order: StatusResolver.health(for: $0).level.severityOrder) }
        return keyed.sorted {
            $0.order == $1.order ? $0.pod.name < $1.pod.name : $0.order < $1.order
        }.map(\.pod)
    }
}

/// 幅に収まらなくなったら折り返す並び。1 行より広い中身は、その幅に詰めて測り直す。
///
/// `ActionFlow` との違いはそこだけ: あちらは中身の大きさが決まっている前提で、
/// 行より広いもの（長い名前のチップ、中で折り返す入れ子の並び）をはみ出させる。
struct ChipFlow: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5
    /// これより狭い幅を提案されても、ここまでは取る（幅 0 で測られたときに潰さない）。
    var minimumWidth: CGFloat = 60

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let frames = arrange(width: bounds.width, subviews: subviews).frames
        for (subview, frame) in zip(subviews, frames) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                anchor: .topLeading, proposal: ProposedViewSize(frame.size))
        }
    }

    /// 幅の指定が無い・無限のときは 1 行に全部として答える（`Int(.infinity)` を作らない）。
    private func arrange(
        width: CGFloat?, subviews: Subviews
    ) -> (frames: [CGRect], size: CGSize) {
        let limit = width.flatMap { $0.isFinite ? max($0, minimumWidth) : nil }
        var frames: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            var size = subview.sizeThatFits(.unspecified)
            if let limit, size.width > limit {
                size = subview.sizeThatFits(ProposedViewSize(width: limit, height: nil))
                size.width = min(size.width, limit)
            }
            if let limit, x > 0, x + size.width > limit {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            widest = max(widest, x + size.width)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (frames, CGSize(width: widest, height: y + rowHeight))
    }
}

// MARK: - 使用量の計器

/// 計器 1 行ぶん。
struct PlacementMeterRow: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let used: String
    /// 分母。呼び名も、割合を出せない理由もここに書く（別の行にしない）。
    let base: String
    /// 分母が足りないときは nil。棒も割合も出さない（0% と描かない）。
    let ratio: Double?
    /// しきい値を超えたときの重み。要求比の割合には付けない。
    let level: StatusLevel?
    /// 指したときに出す補足。
    var help: String?
}

/// 使用量を 1 行ずつ。見出し・棒・実測値・割合。
///
/// **正常な割合には色を付けない。** 棒と割合に色が付くのは、しきい値を超えたときだけ。
struct PlacementMeters: View {
    let rows: [PlacementMeterRow]
    /// 棒の幅。nil なら棒が余りを取り、決めれば実測値の欄が余りを取る。
    var trackWidth: CGFloat?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 5) {
            ForEach(rows) { row in
                GridRow {
                    Text(row.title)
                        .foregroundStyle(.secondary)
                    track(row)
                    value(row)
                    Text(row.ratio.map(Quantity.formatPercent) ?? "")
                        .foregroundStyle(
                            row.level.map { Palette.textColor(for: $0) } ?? Color.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                        .gridColumnAlignment(.trailing)
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .lineLimit(1)
    }

    @ViewBuilder
    private func track(_ row: PlacementMeterRow) -> some View {
        let bar = Group {
            if let ratio = row.ratio {
                UsageBar(
                    ratio: ratio,
                    tint: row.level.map { Palette.color(for: $0) } ?? Palette.meterNeutral,
                    height: 6)
            } else {
                Color.clear.frame(height: 6)
            }
        }
        if let trackWidth {
            bar.frame(width: trackWidth)
        } else {
            bar.frame(minWidth: 36)
        }
    }

    @ViewBuilder
    private func value(_ row: PlacementMeterRow) -> some View {
        let full = row.base.isEmpty ? row.used : "\(row.used) / \(row.base)"
        let text = row.base.isEmpty
            ? Text(row.used)
            : Text(row.used) + Text(verbatim: " / \(row.base)").foregroundStyle(.secondary)
        if trackWidth == nil {
            text.fixedSize()
        } else {
            // 欄に入らなければ末尾が切れるので、指したときに全体を出す。
            text
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help([full, row.help].compactMap { $0 }.joined(separator: " · "))
        }
    }
}

// MARK: - カードの並び

/// カードを同じ幅の列に並べ、同じ行のカードは高さを揃える。
///
/// 列の数は幅で決まる（1 列が `minimumColumnWidth` を下回らないだけ）。カードが列より
/// 少なければ、そのぶん広げる。
struct CardGrid: Layout {
    var minimumColumnWidth: CGFloat = 300
    var spacing: CGFloat = 14
    /// 行のあいだ。nil なら列のあいだと同じ。
    var lineSpacing: CGFloat?

    private var rowGap: CGFloat { lineSpacing ?? spacing }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // 無限の幅で列を数えない（`Int(.infinity)` はトラップする）。
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? minimumColumnWidth
        let heights = solve(width: width, subviews: subviews).rowHeights
        let gaps = rowGap * CGFloat(max(0, heights.count - 1))
        return CGSize(width: width, height: heights.reduce(0, +) + gaps)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let solved = solve(width: bounds.width, subviews: subviews)
        var y = bounds.minY
        for (row, height) in solved.rowHeights.enumerated() {
            for column in 0..<solved.columns {
                let index = row * solved.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(
                        x: bounds.minX + CGFloat(column) * (solved.columnWidth + spacing), y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: solved.columnWidth, height: height))
            }
            y += height + rowGap
        }
    }

    private func solve(
        width: CGFloat, subviews: Subviews
    ) -> (columns: Int, columnWidth: CGFloat, rowHeights: [CGFloat]) {
        guard !subviews.isEmpty, width.isFinite, width > 0 else { return (1, max(0, width), []) }
        let fits = Int((width + spacing) / (minimumColumnWidth + spacing))
        let columns = max(1, min(subviews.count, fits))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)

        var heights: [CGFloat] = []
        for start in stride(from: 0, to: subviews.count, by: columns) {
            var height: CGFloat = 0
            for index in start..<min(start + columns, subviews.count) {
                height = max(
                    height,
                    subviews[index]
                        .sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height)
            }
            heights.append(height)
        }
        return (columns, columnWidth, heights)
    }
}
