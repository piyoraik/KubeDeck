import SwiftUI

// たどるの「通信」と「権限」を構成図として描く。矢印は行の中で左から右へ引くだけ。

/// 通信の図。相手は居る場所の箱に入れ、線にポートと可否を持たせる。
struct TraceNetworkDiagram: View {
    let network: TraceNetwork
    let anchor: TraceAnchor
    let select: (TraceAnchor) -> Void

    var body: some View {
        let stopped = network.ingress.tally.stopped + network.egress.tally.stopped

        VStack(alignment: .leading, spacing: 10) {
            // 横に入らなければ上下に積む（横スクロールにすると Spacer が無限に伸びて図が消える）。
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    FlowSide(direction: .ingress, column: network.ingress, select: select)
                    origin
                    FlowSide(direction: .egress, column: network.egress, select: select)
                }
                .fixedSize()

                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 0) {
                        FlowSide(direction: .ingress, column: network.ingress, select: select)
                        origin
                    }
                    .fixedSize()
                    HStack(alignment: .top, spacing: 0) {
                        origin
                        FlowSide(direction: .egress, column: network.egress, select: select)
                    }
                    .fixedSize()
                }
            }
            if stopped > 0 {
                Text("実線は通る通信、破線は止まる通信です。✕ は止めている側に置いています。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var origin: some View {
        let names = network.policies.joined(separator: ", ")

        return DiagramBox(
            title: anchor.namespace ?? String(localized: "クラスタ"),
            symbol: ResourceKind.namespace.symbol, tint: Palette.diagram
        ) {
            VStack(spacing: 4) {
                ResourceGlyph(symbol: anchor.symbol, size: 38)
                    .overlay(anchorRing(true, size: 38))
                Text(anchor.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 150)
                    .padding(.top, 4)
                Text(anchor.kindLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !names.isEmpty {
                    Label(names, systemImage: ResourceKind.networkPolicy.symbol)
                        .font(.subheadline)
                        .lineLimit(1)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 3)
                        .background(Palette.insetFill, in: Capsule())
                        .padding(.top, 6)
                        .help("効いている NetworkPolicy: \(names)")
                }
            }
            .frame(minWidth: 104, maxHeight: .infinity)
        }
        .padding(.top, FlowSide.captionHeight)
    }
}

/// 片側（入る相手、または出る先）。
private struct FlowSide: View {
    let direction: FlowDirection
    let column: TraceFlowColumn
    let select: (TraceAnchor) -> Void
    @State private var showsAll = false

    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 6
    static let captionHeight: CGFloat = 24

    private var inbound: Bool { direction == .ingress }

    var body: some View {
        let groups = PlacementTrace.lanes(
            column, direction: direction, limit: showsAll ? nil : PlacementTrace.laneLimit)
        let hidden = showsAll ? 0 : max(0, column.rows.count - PlacementTrace.laneLimit)

        VStack(alignment: inbound ? .leading : .trailing, spacing: 0) {
            Text(inbound ? String(localized: "入ってこられる相手") : String(localized: "出ていける先"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(height: Self.captionHeight, alignment: .top)
            Spacer(minLength: 0)
            LaneColumns(rowSpacing: 14) {
                ForEach(groups) { group in
                    if inbound {
                        place(group)
                        edges(group)
                    } else {
                        edges(group)
                        place(group)
                    }
                }
            }
            if hidden > 0 {
                Button(String(localized: "ほか \(hidden) 件を出す")) { showsAll = true }
                    .buttonStyle(.link)
                    .font(.subheadline)
                    .padding(.top, 8)
            }
            ForEach(column.notes, id: \.self) { note in
                Label(note, systemImage: StatusLevel.warning.symbol)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textColor(for: .warning))
                    .frame(width: 300, alignment: .leading)
                    .padding(.top, 8)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func place(_ group: FlowLaneGroup) -> some View {
        let peers = VStack(alignment: .leading, spacing: Self.rowSpacing) {
            ForEach(group.lanes) { lane in
                peer(lane).frame(height: Self.rowHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        switch group.place {
        case .namespace(let name):
            DiagramBox(
                title: name, symbol: ResourceKind.namespace.symbol, tint: .secondary,
                stroke: Palette.diagramFrame
            ) {
                peers
            }
        case .external:
            DiagramBox(
                title: String(localized: "クラスタの外として扱う"), symbol: "globe",
                tint: .secondary, isDashed: true, stroke: Color.primary.opacity(0.3)
            ) {
                peers
            }
        case .nowhere:
            peers.padding(inbound ? .trailing : .leading, 10)
        }
    }

    private func edges(_ group: FlowLaneGroup) -> some View {
        VStack(spacing: Self.rowSpacing) {
            ForEach(group.lanes) { lane in
                FlowEdge(lane: lane, inbound: inbound).frame(height: Self.rowHeight)
            }
        }
        // 箱の中の行と線の高さを合わせる。
        .padding(.top, group.place == .nowhere ? 0 : DiagramMetrics.boxTopInset)
    }

    @ViewBuilder
    private func peer(_ lane: FlowLane) -> some View {
        let content = FigureNode(
            name: lane.name, detail: lane.detail, symbol: lane.symbol,
            tint: lane.isResolved ? Palette.diagram : .secondary, size: 26,
            detailLevel: lane.detailLevel, maxWidth: 230)

        if let target = lane.anchor {
            Button { select(target) } label: { content }
                .buttonStyle(.plain)
                .help("\(lane.detail) \(lane.name) を起点にする")
        } else if let explanation = lane.explanation {
            content.help(explanation)
        } else {
            content
        }
    }
}

/// 2 列の表。列の幅はいちばん広い中身で決め、狭い枡をその幅まで広げる。
///
/// `Grid` は使えない: 伸びる枡があると列を等分し、`gridCellUnsizedAxes` を全部の枡に付けると中身より狭く置く。
private struct LaneColumns: Layout {
    var rowSpacing: CGFloat = 14

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = columnWidths(subviews)
        let heights = rowHeights(subviews, widths: widths)
        let spacing = CGFloat(max(0, heights.count - 1)) * rowSpacing
        return CGSize(width: widths.0 + widths.1, height: heights.reduce(0, +) + spacing)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let widths = columnWidths(subviews)
        var y = bounds.minY
        for (row, height) in rowHeights(subviews, widths: widths).enumerated() {
            let first = row * 2
            subviews[first].place(
                at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: ProposedViewSize(width: widths.0, height: nil))
            if first + 1 < subviews.count {
                subviews[first + 1].place(
                    at: CGPoint(x: bounds.minX + widths.0, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: widths.1, height: nil))
            }
            y += height + rowSpacing
        }
    }

    private func columnWidths(_ subviews: Subviews) -> (CGFloat, CGFloat) {
        var widths: (CGFloat, CGFloat) = (0, 0)
        for (index, subview) in subviews.enumerated() {
            let width = subview.sizeThatFits(.unspecified).width
            if index.isMultiple(of: 2) {
                widths.0 = max(widths.0, width)
            } else {
                widths.1 = max(widths.1, width)
            }
        }
        return widths
    }

    private func rowHeights(_ subviews: Subviews, widths: (CGFloat, CGFloat)) -> [CGFloat] {
        stride(from: 0, to: subviews.count, by: 2).map { first in
            var height = subviews[first]
                .sizeThatFits(ProposedViewSize(width: widths.0, height: nil)).height
            if first + 1 < subviews.count {
                height = max(
                    height,
                    subviews[first + 1]
                        .sizeThatFits(ProposedViewSize(width: widths.1, height: nil)).height)
            }
            return height
        }
    }
}

/// 器と 2 行の文字。
private struct FigureNode: View {
    let name: String
    let detail: String
    let symbol: String
    var tint: Color = Palette.diagram
    var size: CGFloat = 26
    var detailLevel: StatusLevel?
    var maxWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 8) {
            ResourceGlyph(symbol: symbol, size: size, tint: tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(detailLevel.map { Palette.textColor(for: $0) } ?? Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            // 上限までは中身の幅で止める（`maxWidth` だけだと、余りがあるぶん上限まで広がる）。
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
        }
    }
}

/// 相手 1 つへの線。上にポート、下に止まる理由。
private struct FlowEdge: View {
    let lane: FlowLane
    let inbound: Bool

    var body: some View {
        VStack(spacing: 0) {
            Text(lane.label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
                .frame(height: 14)
            FlowLine(line: lane.line, inbound: inbound)
                .frame(height: 10)
            Text(lane.note ?? "")
                .font(.caption2)
                .foregroundStyle(noteColor)
                .lineLimit(1)
                .padding(.horizontal, 8)
                .frame(height: 12)
        }
        .frame(minWidth: 72, maxWidth: .infinity)
        .help(help)
    }

    private var help: String {
        var parts = [lane.explanation ?? lane.label].filter { !$0.isEmpty }
        // 起点の側の policy であって、止めている側とは限らない（止める側の名前は判定が運んでいない）。
        if !lane.policies.isEmpty {
            let names = lane.policies.joined(separator: ", ")
            parts.append(String(localized: "起点の側の NetworkPolicy: \(names)"))
        }
        return parts.joined(separator: " · ")
    }

    private var noteColor: Color {
        switch lane.line {
        case .open: return .secondary
        case .stopped: return Palette.textColor(for: .serious)
        case .unsettled: return Palette.textColor(for: .warning)
        }
    }
}

/// 左から右への線。止まる通信は破線にして、止めている側に ✕ を置く。
private struct FlowLine: View {
    let line: FlowLane.Line
    var inbound = true

    var body: some View {
        HStack(spacing: 0) {
            HorizontalRule()
                .stroke(style: StrokeStyle(lineWidth: 1.5, dash: line == .open ? [] : [5, 4]))
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 7))
                .offset(x: -1)
        }
        .foregroundStyle(color)
        .overlay(alignment: .leading) {
            if marks.contains(.leading) { mark.padding(.leading, 8) }
        }
        .overlay(alignment: .center) {
            if marks.contains(.center) { mark }
        }
        .overlay(alignment: .trailing) {
            if marks.contains(.trailing) { mark.padding(.trailing, 13) }
        }
    }

    private var color: Color {
        switch line {
        case .open: return Palette.diagramLine
        case .stopped: return Palette.color(for: .serious)
        case .unsettled: return Palette.color(for: .warning)
        }
    }

    private enum Spot { case leading, center, trailing }

    /// 相手は、入る線では根元、出る線では矢の先に居る。
    private var marks: Set<Spot> {
        let peer: Spot = inbound ? .leading : .trailing
        let origin: Spot = inbound ? .trailing : .leading
        switch line {
        case .open: return []
        case .unsettled, .stopped(.ports): return [.center]
        case .stopped(.peer): return [peer]
        case .stopped(.origin): return [origin]
        case .stopped(.both): return [peer, origin]
        }
    }

    private var mark: some View {
        Image(systemName: line == .unsettled ? "questionmark" : "xmark")
            .font(.system(size: 7, weight: .heavy))
            .foregroundStyle(color)
            .frame(width: 13, height: 13)
            .background(Color(nsColor: .windowBackgroundColor), in: Circle())
    }
}

private struct HorizontalRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

/// 複数のワークロードにまたがる起点の通信。1 つの図にまとめず、ワークロードごとに 1 行。
struct TraceNetworkIndex: View {
    let branches: [BranchNetwork]
    let select: (TraceAnchor) -> Void

    var body: some View {
        let restricted = branches.filter(\.isRestricted)
        let free = branches.filter { !$0.isRestricted }
        let total = branches.reduce(0) { $0 + $1.podCount }
        let covered = restricted.reduce(0) { $0 + $1.podCount }
        let freePods = total - covered

        VStack(alignment: .leading, spacing: 10) {
            Group {
                if restricted.isEmpty {
                    Text("どのワークロードにも NetworkPolicy は効いていません。")
                } else {
                    Text("""
                        Pod \(total) 個のうち、NetworkPolicy が効いているのは \(covered) 個です。\
                        押すと、そのワークロードの図を開きます。
                        """)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !restricted.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(restricted) { branch in
                        row(branch)
                    }
                }
            }
            if !free.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("制限なし（\(freePods) Pod）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    ActionFlow(spacing: 5, lineSpacing: 5) {
                        ForEach(free) { branch in
                            chip(branch)
                        }
                    }
                }
            }
        }
    }

    private func row(_ branch: BranchNetwork) -> some View {
        let ingress = branch.network.ingress.tally
        let egress = branch.network.egress.tally
        let workload = branch.workload
        let place = [workload.kindLabel, workload.namespace].compactMap { $0 }.joined(separator: " · ")
        let policies = branch.network.policies.joined(separator: ", ")

        return Button {
            select(workload)
        } label: {
            HStack(spacing: 8) {
                tally(ingress, inbound: true)
                    .frame(width: 150, alignment: .trailing)
                FlowLine(line: line(for: ingress))
                    .frame(width: 48, height: 10)
                FigureNode(
                    name: workload.displayName, detail: "\(place) · \(branch.podCount) Pod",
                    symbol: workload.symbol, maxWidth: 250)
                    .frame(minWidth: 150, maxWidth: 260, alignment: .leading)
                Label(policies, systemImage: ResourceKind.networkPolicy.symbol)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Palette.insetFill, in: Capsule())
                    .frame(width: 110, alignment: .leading)
                FlowLine(line: line(for: egress))
                    .frame(width: 48, height: 10)
                tally(egress, inbound: false)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: 860, alignment: .leading)
            .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(workload.kindLabel) \(workload.displayName) を起点にする")
    }

    private func line(for tally: FlowTally) -> FlowLane.Line {
        if tally.stopped > 0 { return .stopped(.ports) }
        return tally.unsettled > 0 ? .unsettled : .open
    }

    private func tally(_ tally: FlowTally, inbound: Bool) -> some View {
        HStack(spacing: 5) {
            switch tally {
            case .unrestricted:
                Text("制限なし")
            case .denied:
                Text("すべて拒否")
                    .foregroundStyle(Palette.textColor(for: .serious))
            case .peers(let count, let stopped, let unsettled):
                Text(inbound ? String(localized: "\(count) 相手") : String(localized: "\(count) 宛先"))
                if stopped > 0 {
                    Text("\(stopped) つ止まる")
                        .foregroundStyle(Palette.textColor(for: .serious))
                }
                if unsettled > 0 {
                    Text("\(unsettled) つ未確定")
                        .foregroundStyle(Palette.textColor(for: .warning))
                }
            }
        }
        .font(.subheadline)
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Palette.insetFill, in: Capsule())
    }

    @ViewBuilder
    private func chip(_ branch: BranchNetwork) -> some View {
        let workload = branch.workload
        let label = Text(
            branch.podCount > 1 ? "\(workload.displayName) ×\(branch.podCount)" : workload.displayName)
            .font(.subheadline)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 6))

        // 所有者の無い Pod の枠は、起点にしても同じ絵になるので押させない。
        if workload.isStandalone {
            label
        } else {
            Button { select(workload) } label: { label }
                .buttonStyle(.plain)
                .help("\(workload.kindLabel) \(workload.displayName) を起点にする")
        }
    }
}

/// 権限の鎖。ServiceAccount → Binding → ロール。効く範囲を箱で示す。
struct TraceAccessChain: View {
    @Environment(ClusterStore.self) private var store
    let accounts: [AccessAccount]
    let bindings: AccessBindings
    let rules: AccessRules

    private struct Scope: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let bindings: [AccessBinding]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(accounts) { account in
                row(account)
            }
        }
    }

    private func row(_ account: AccessAccount) -> some View {
        let bound = bindings.bindings(for: account)
        let kind = ResourceKind.serviceAccount.displayName
        let detail = account.namespace.map { "\(kind) · \($0)" } ?? kind

        return HStack(alignment: .center, spacing: 10) {
            inspectable {
                Task {
                    await store.inspect(
                        .serviceAccount, name: account.name, namespace: account.namespace)
                }
            } label: {
                FigureNode(
                    name: account.name, detail: detail,
                    symbol: ResourceKind.serviceAccount.symbol, tint: .secondary, size: 28)
            }
            if !bindings.isLoaded {
                Text("付いている Binding を調べています…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if bound.isEmpty {
                Text("直接付いている Binding はありません（グループ経由の付与は見ていません）")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLine(line: .open)
                    .frame(width: 30, height: 10)
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(scopes(bound)) { scope in
                        DiagramBox(
                            title: scope.title, symbol: scope.symbol, tint: .secondary,
                            stroke: Palette.diagramFrame
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(scope.bindings) { binding in
                                    grant(binding)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// クラスタ全体に効くものを先に置く。
    private func scopes(_ bound: [AccessBinding]) -> [Scope] {
        var cluster: [AccessBinding] = []
        var byNamespace: [String: [AccessBinding]] = [:]
        for binding in bound {
            if binding.isClusterWide {
                cluster.append(binding)
            } else {
                byNamespace[binding.binding.namespace ?? "", default: []].append(binding)
            }
        }
        var result: [Scope] = []
        if !cluster.isEmpty {
            result.append(Scope(
                id: "cluster", title: String(localized: "クラスタ全体"), symbol: "globe",
                bindings: cluster))
        }
        for namespace in byNamespace.keys.sorted() {
            result.append(Scope(
                id: "namespace|\(namespace)", title: namespace,
                symbol: ResourceKind.namespace.symbol, bindings: byNamespace[namespace] ?? []))
        }
        return result
    }

    private func grant(_ binding: AccessBinding) -> some View {
        let role = rules.roles[binding.roleID]
        let summary = role.map { ResourceTable.ruleSummary($0) }
        let bindingKind: ResourceKind = binding.isClusterWide ? .clusterRoleBinding : .roleBinding
        let roleKind: ResourceKind = binding.roleKind == "ClusterRole" ? .clusterRole : .role
        let kindName = bindingKind.displayName

        return HStack(alignment: .center, spacing: 10) {
            inspectable { store.inspect(binding.binding) } label: {
                FigureNode(
                    name: binding.name, detail: kindName, symbol: bindingKind.symbol,
                    tint: .secondary, size: 24, maxWidth: 200)
            }
            FlowLine(line: .open)
                .frame(width: 28, height: 10)
            // 指しているロールが引けていないときは、押した先で何も出せない。
            inspectable(role.map { role in { store.inspect(role) } }) {
                FigureNode(
                    name: binding.roleName, detail: binding.roleKind, symbol: roleKind.symbol,
                    size: 24, maxWidth: 200)
            }
            if let summary, !summary.text.isEmpty {
                Text(summary.text)
                    .font(.subheadline)
                    .foregroundStyle(
                        summary.isWildcard ? Palette.textColor(for: .warning) : Color.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360, alignment: .leading)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Palette.hairline).frame(width: 1)
                    }
            } else if rules.isLoaded && role == nil {
                Text("指しているロールがありません")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textColor(for: .serious))
                    .lineLimit(1)
            }
        }
        .help("\(kindName) \(binding.name) → \(binding.roleLabel)")
    }

    @ViewBuilder
    private func inspectable<Label: View>(
        _ action: (() -> Void)?, @ViewBuilder label: () -> Label
    ) -> some View {
        if let action {
            Button(action: action) { label() }
                .buttonStyle(.plain)
                .help("押すと右のパネルに詳細")
        } else {
            label()
        }
    }
}
