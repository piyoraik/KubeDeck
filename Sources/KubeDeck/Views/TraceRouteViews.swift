import SwiftUI

/// 入口の列に並べる経路の器。作りは Ingress や Service の器と同じ（器と 2 行）。
struct TraceRouteColumn: View {
    let entries: [TraceRouteEntry]
    let anchor: TraceAnchor
    let select: (TraceAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entries) { entry in
                let target = entry.anchor
                Button {
                    select(target)
                } label: {
                    HStack(spacing: 8) {
                        ResourceGlyph(
                            symbol: TraceAnchorKind.route.symbol, size: 26, badge: entry.badge
                        )
                        .overlay(anchorRing(target.id == anchor.id, size: 26))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.route.name)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            HStack(spacing: 0) {
                                Text(entry.route.kindLabel)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                // 割合は切らせない（真ん中を落とすと「10〜100%」が「0〜100%」に読める。実測）。
                                Text(" · \(entry.shareText)")
                                    .fixedSize()
                                    .layoutPriority(1)
                            }
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 176, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)
                .help(entry.help)
            }
        }
    }
}

/// Service の器の下に並べる経路の札。押すと、その経路が起点になる。
struct TraceRouteTags: View {
    let tags: [TraceRouteTag]
    let anchor: TraceAnchor
    let select: (TraceAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(tags) { tag in
                let target = tag.anchor
                let isAnchor = target.id == anchor.id
                let parts = tag.parts
                // Service の器のボタンに入れ子にしない（内側の押下が外側に取られる）。兄弟として並べる。
                Button {
                    select(target)
                } label: {
                    HStack(spacing: 4) {
                        if let badge = tag.badge, badge != .good, badge != .neutral {
                            Image(systemName: badge.symbol)
                                .foregroundStyle(Palette.color(for: badge))
                        }
                        Image(systemName: TraceAnchorKind.route.symbol)
                        // 縮めるのは名前だけ。割合や「が振り分け」は切らせない。
                        HStack(spacing: 0) {
                            if !parts.lead.isEmpty {
                                Text(parts.lead).fixedSize().layoutPriority(1)
                            }
                            Text(tag.name)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if !parts.trail.isEmpty {
                                Text(parts.trail).fixedSize().layoutPriority(1)
                            }
                        }
                    }
                    .font(.subheadline)
                    .imageScale(.small)
                    .foregroundStyle(isAnchor ? .primary : .secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Palette.insetFill, in: Capsule())
                    .overlay {
                        if isAnchor {
                            Capsule().stroke(Color.accentColor, lineWidth: 1.5)
                        }
                    }
                    .contentShape(Capsule())
                    // 字下げしない。欄が下限まで詰まると、名前が丸ごと消えた（実画面）。
                    .frame(maxWidth: 26 + 8 + 176, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help(tag.help)
                .accessibilityLabel(tag.text)
            }
        }
    }
}

/// 経路を起点にしたときの「振り分け」の図。左の箱が呼び出し先、線が割合、右が宛先。
///
/// 割合の数字は線にだけ書く。箱の中の帯は、同じ割合を「全体を配り切っている」形で見せる。
struct TraceRouteSplitView: View {
    let split: TraceRouteSplit
    /// 下に枝が続くときだけ、その見出しも出す。
    let showsBranchHeading: Bool
    let select: (TraceAnchor) -> Void

    private static let panelWidth: CGFloat = 236
    private static let panelPadding: CGFloat = 16
    private static let lineWidth: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                heading("振り分け")
                figure
            }
            if showsBranchHeading {
                heading("宛先の先")
            }
        }
        .padding(.top, 6)
    }

    private func heading(_ title: LocalizedStringResource) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Rectangle()
                .fill(Palette.hairline)
                .frame(height: 1)
        }
        .frame(maxWidth: 920, alignment: .leading)
    }

    private var figure: some View {
        VStack(alignment: .leading, spacing: 0) {
            if split.showsRuleCaptions || split.rules.isEmpty {
                origin
                    .padding(.bottom, split.rules.isEmpty ? 12 : 0)
                    .frame(width: Self.panelWidth, alignment: .leading)
                ForEach(split.rules) { rule in
                    ruleRow(rule) { ruleCell(rule) }
                }
            } else {
                // 見出しの要らない規則 1 つなら、呼び出し先と帯を 1 つの枡にして宛先の横に置く。
                ForEach(split.rules) { rule in
                    ruleRow(rule) {
                        VStack(alignment: .leading, spacing: 0) {
                            origin
                            ruleCell(rule)
                        }
                    }
                }
            }
        }
        // 左の列だけを 1 つの箱に見せる。線は箱の縁から出る。
        .background(alignment: .leading) {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Palette.diagramFrame, lineWidth: 1)
                .frame(width: Self.panelWidth)
        }
    }

    private func ruleRow<Leading: View>(
        _ rule: TraceRouteSplit.Rule, @ViewBuilder leading: () -> Leading
    ) -> some View {
        HStack(alignment: .center, spacing: 0) {
            leading()
                .frame(width: Self.panelWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 10) {
                if rule.rows.isEmpty {
                    Text("宛先なし（リダイレクトなど）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                } else {
                    ForEach(rule.rows) { row in
                        self.row(row)
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    // MARK: - 呼び出し先

    private var origin: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(split.origins) { origin in
                let label = HStack(spacing: 8) {
                    ResourceGlyph(symbol: origin.symbol, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(origin.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(origin.kindLabel)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                if let target = origin.anchor {
                    Button {
                        select(target)
                    } label: {
                        label
                    }
                    .buttonStyle(.plain)
                    .help("\(origin.kindLabel) \(origin.name) を起点にする")
                } else {
                    label
                }
            }
            Text(split.originCaption)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Self.panelPadding)
        .padding(.top, 14)
        .padding(.bottom, 2)
    }

    private func ruleCell(_ rule: TraceRouteSplit.Rule) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if split.showsRuleCaptions {
                Text(rule.caption)
                    .font(.subheadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            bar(rule)
        }
        .padding(.horizontal, Self.panelPadding)
        .padding(.vertical, 12)
    }

    // MARK: - 帯

    /// 数字は書かない。割合の数字は線の上にだけ出す。
    private func bar(_ rule: TraceRouteSplit.Rule) -> some View {
        let width = Self.panelWidth - Self.panelPadding * 2
        let gap: CGFloat = 2
        let rows = rule.rows.filter { $0.fraction > 0 }
        let usable = width - gap * CGFloat(max(0, rows.count - 1))
        return HStack(spacing: gap) {
            ForEach(rows) { row in
                swatchFill(row)
                    .frame(width: max(2, usable * row.fraction))
            }
        }
        .frame(width: width, height: 10, alignment: .leading)
        .background(Palette.insetFill)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .accessibilityHidden(true)
    }

    /// 帯の区切りと、宛先の横の色見本で同じ塗りを使う。状態の色は、無い宛先にだけ使う。
    @ViewBuilder
    private func swatchFill(_ row: TraceRouteSplit.Row) -> some View {
        if let level = row.level {
            Palette.color(for: level).opacity(0.45)
                .overlay(Hatch().stroke(Palette.color(for: level), lineWidth: 1.2))
                .clipped()
        } else {
            Color.primary.opacity(Self.shades[row.shade % Self.shades.count])
        }
    }

    /// 隣どうしが見分けられるよう、明るさを交互に振る。
    private static let shades: [Double] = [0.62, 0.30, 0.46, 0.20, 0.54, 0.26]

    // MARK: - 宛先の行

    private func row(_ row: TraceRouteSplit.Row) -> some View {
        HStack(spacing: 8) {
            VStack(spacing: 1) {
                Text(row.percentText)
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(row.level.map { Palette.textColor(for: $0) } ?? .primary)
                line(row)
                // 線を、宛先の器の中心の高さに置く。
                Color.clear.frame(height: 15)
            }
            .frame(width: Self.lineWidth)

            swatchFill(row)
                .frame(width: 9, height: 9)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .accessibilityHidden(true)

            destination(row)
        }
    }

    @ViewBuilder
    private func line(_ row: TraceRouteSplit.Row) -> some View {
        if let level = row.level {
            // 届かない宛先は、破線と ✕（「通信」の図の、止まる通信と同じ描き方）。
            HStack(spacing: 2) {
                HorizontalLine()
                    .stroke(
                        Palette.color(for: level),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(height: 1.5)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Palette.color(for: level))
            }
        } else {
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Palette.diagramLine)
                    .frame(height: 1.5)
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(Palette.diagramLine)
                    .offset(x: -1)
            }
        }
    }

    @ViewBuilder
    private func destination(_ row: TraceRouteSplit.Row) -> some View {
        if let target = row.anchor {
            Button {
                select(target)
            } label: {
                HStack(spacing: 8) {
                    ResourceGlyph(symbol: ResourceKind.service.symbol, size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(row.name)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(row.detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: 200, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
            .help("\(row.kindLabel) \(row.name) を起点にする")
        } else {
            // 手元に無い宛先には器を置かない（あるように見える）。名前と理由を文字で出す。
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 4) {
                    if let level = row.level {
                        Image(systemName: level.symbol)
                            .imageScale(.small)
                    }
                    Text(row.detail)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
                .foregroundStyle(row.level.map { Palette.textColor(for: $0) } ?? .secondary)
            }
            .frame(maxWidth: 320, alignment: .leading)
        }
    }
}

private struct HorizontalLine: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// 斜線。無い宛先の区切りを、色だけに頼らず見分けるため。
private struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 4
        }
        return path
    }
}

extension TraceAnchorKind {
    /// 起点の一覧に出す種別。経路は、読めているときだけ出す（押しても空になるものを出さない）。
    static func offered(routes: MeshRouteAvailability) -> [TraceAnchorKind] {
        allCases.filter { $0 != .route || routes == .loaded }
    }
}
