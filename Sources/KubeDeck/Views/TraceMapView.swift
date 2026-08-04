import SwiftUI

/// たどる。起点を 1 つ選んで、その周りだけを図にする。
///
/// **全部を一度に描かない。** 222 Pod を線でつないだ図は、線の数が多すぎて
/// どこから読めばいいのか分からなくなる。左で 1 つ選び、それだけを展開する。
///
/// **起点はワークロードだけではない。** 知りたいことは
/// 「この Ingress の先に何があるか」「この Service は何を掴んでいるか」
/// 「このノードに載っているものは何に繋がっているか」でも起きる。どれも
/// 同じ鎖（入口 → ワークロード → 世代 → Pod → ノード）の別の場所を掴んだだけ
/// なので、起点から Pod を解いて、あとは同じ図に流す（`PlacementTrace`）。
///
/// **図の中の器も押せる。** 一覧に戻って選び直させると、繋がりを辿るという
/// この画面の目的そのものが途切れる。押した器が次の起点になり、戻るで
/// 1 つ前に帰れる。
struct TraceMapView: View {
    @Environment(ClusterStore.self) private var store
    @State private var anchorKind: TraceAnchorKind = .workload
    @State private var focus: TraceAnchor?
    /// 押して辿った跡。**戻れないと押せない。** 押した先が外れだったとき、
    /// 一覧から選び直すことになる。
    @State private var history: [TraceAnchor] = []

    var body: some View {
        HStack(spacing: 0) {
            picker
            // **横並びの中に `Divider` を置かない。** 高さが定まらず、
            // `NavigationSplitView` と `.inspector` ですでに `NSSplitView` が
            // 入れ子になっているこの窓では、レイアウト中の例外の芽になる。
            // 見た目は同じなので、太さの決まった矩形にする。
            Rectangle()
                .fill(Palette.hairline)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
            detail
        }
        // **図の最小幅を外へ伝えない。** 段が 5 つ並ぶこの画面は、詰まった
        // ときの最小幅が詳細の欄より広くなることがある。そのまま伝えると
        // `NavigationSplitView` が列を押し広げ、**サイドバーの左端が切れる**
        // （1367pt 幅・詳細パネルを出した状態で実際に起きた。「ワークロード」が
        // 「ドロード」になり、下端のコンテキスト名も頭が消えた）。
        // 下限を 0 にして、足りないぶんは図の側で詰める。
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        // 詰めきれずにはみ出した場合も、隣の欄の上に描かせない。
        .clipped()
    }

    // MARK: - 起点の一覧

    private var inventory: PlacementInventory { store.placementInventory }

    /// **1 度だけ解く。** Service を起点にする一覧は「掴んでいる Pod の数」を
    /// 出すので、Service × Pod のラベル照合が要る。body の中で何度も呼ぶと、
    /// そのぶん繰り返すことになる。
    private var allAnchors: [TraceAnchor] {
        PlacementTrace.anchors(
            kind: anchorKind, inventory: inventory, controllers: store.controllerIndex)
    }

    /// 一覧だけを絞り込む。**図は絞り込まない** — 起点の先に何があるかを
    /// 見る画面なので、打ち込んだ文字で枝が欠けると別の絵になる。
    private func visible(_ anchors: [TraceAnchor]) -> [TraceAnchor] {
        let query = store.searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return anchors }
        return anchors.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || ($0.namespace ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    /// **`List` を使わない。** macOS の `List` は自前で最小幅を要求し、
    /// `NavigationSplitView` の詳細の中に横並びで置くと、列がまとめて窓より
    /// 広がる。**サイドバーの左端と詳細パネルの右端が切れた**（この画面だけ
    /// 起きるのはそのため）。自前の行にすれば幅はこちらが決められる。
    private var picker: some View {
        let anchors = allAnchors
        let visible = visible(anchors)

        return VStack(spacing: 0) {
            kindSelector
            Rectangle().fill(Palette.hairline).frame(height: 1)
            if visible.isEmpty {
                Text(anchors.isEmpty ? anchorKind.emptyMessage : "一致するものがありません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { anchor in
                            row(anchor)
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
        // **縮められる幅にする。** 決め打ちだと、この欄のぶんがそのまま
        // 図に使える幅を削る。狭い窓では先にこちらを詰めさせる（名前は
        // 真ん中を落として出る。図のほうが答えそのもの）。
        .frame(minWidth: 176, idealWidth: 236, maxWidth: 236)
        .background(Palette.insetFill.opacity(0.5))
        // **`onAppear` だけで初期化しない。** 読み込みが終わる前に開くと
        // 一覧が空で、選ばれないまま右が空で固まる（実際そうなった）。
        // 一覧が変わるたびに、選択が有効かを見直す。**絞り込みの結果ではなく
        // 全体で見る** — 打ち込んだ文字で起点が勝手に変わると図が飛ぶ。
        .onChange(of: anchors.map(\.id), initial: true) { _, ids in
            if let focus, ids.contains(focus.id) { return }
            focus = anchors.first
            // 起点が入れ替わったら跡も捨てる。無い場所へ戻れても仕方がない。
            history = []
        }
    }

    private var kindSelector: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("起点", selection: $anchorKind) {
                ForEach(TraceAnchorKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .labelsHidden()
            // **セグメントにしない。** 5 つを 236pt に詰めると記号だけになり、
            // どれが何なのか読めなくなる。
            .pickerStyle(.menu)
            Text(anchorKind.help)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private func row(_ anchor: TraceAnchor) -> some View {
        let isSelected = focus?.id == anchor.id

        return Button {
            select(anchor)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(anchor.displayName)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 同じ名前が別の Namespace に居ることがある。添えないと
                    // 選べない。種別も添える（同じ名前の Deployment と
                    // StatefulSet が並ぶ）。
                    if let subtitle = subtitle(anchor) {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                Text("\(anchor.podCount)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(anchor.podCount == 0 ? .tertiary : .secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.20) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(anchor.kindLabel) · \(anchor.podCount) Pod")
    }

    private func subtitle(_ anchor: TraceAnchor) -> String? {
        var parts: [String] = []
        if anchor.anchorKind == .workload && !anchor.isStandalone {
            parts.append(anchor.kindLabel)
        }
        if let namespace = anchor.namespace { parts.append(namespace) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - 図

    @ViewBuilder
    private var detail: some View {
        if let focus {
            let graph = PlacementTrace.graph(
                for: focus, inventory: inventory, controllers: store.controllerIndex)
            VStack(spacing: 0) {
                anchorHeader(graph)
                Rectangle().fill(Palette.hairline).frame(height: 1)
                ScrollView {
                    TraceGraphView(graph: graph, select: select(_:))
                        .padding(16)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView {
                Label(
                    "たどる対象を選んでください",
                    systemImage: "point.3.filled.connected.trianglepath.dotted")
            } description: {
                Text("左の一覧から 1 つ選ぶと、入口から Pod とノードまで図にします。")
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// いま何を起点にしているか。**図の中を見て推測させない** — 押して辿ると
    /// 起点が変わるので、どこに居るのかを常に上に書いておく。
    private func anchorHeader(_ graph: TraceGraph) -> some View {
        HStack(spacing: 10) {
            if !history.isEmpty {
                Button {
                    guard let previous = history.popLast() else { return }
                    anchorKind = previous.anchorKind
                    focus = previous
                } label: {
                    Label("戻る", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("1 つ前の起点に戻る")
            }

            ResourceGlyph(symbol: graph.anchor.symbol, size: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(graph.anchor.displayName)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(headerSubtitle(graph))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private func headerSubtitle(_ graph: TraceGraph) -> String {
        var parts: [String] = [graph.anchor.kindLabel]
        if let namespace = graph.anchor.namespace { parts.append(namespace) }
        parts.append("\(graph.podCount) Pod")
        // ワークロードを起点にしたときの「何ワークロード」は自明なので出さない
        // （同じ数字を 2 度出さない）。
        if graph.anchor.anchorKind != .workload && graph.branches.count > 1 {
            parts.append("\(graph.branches.count) ワークロード")
        }
        // ノードを起点にしているときの「1 ノード」は自分のことなので出さない。
        if graph.nodeCount > 0 && graph.anchor.anchorKind != .node {
            parts.append("\(graph.nodeCount) ノード")
        }
        return parts.joined(separator: " · ")
    }

    private func select(_ anchor: TraceAnchor) {
        guard anchor.id != focus?.id else { return }
        if let focus {
            history.append(focus)
            // 際限なく溜めない。ここは「1 つ前に戻る」ための跡で、
            // 履歴そのものを見る場所ではない。
            if history.count > 30 { history.removeFirst() }
        }
        anchorKind = anchor.anchorKind
        focus = anchor
    }
}

// MARK: - 図そのもの

/// 起点から解いた図。
///
/// **木ではなく図にする。** 木は階層を表せるが、「Namespace の中に Deployment が
/// あり、そこから Pod が出て、それぞれ別のノードに載っている」という**入れ子と
/// 行き先**が同時には見えない。七角形の器・囲みの箱・矢印で組む
/// （`Views/ResourceGlyph.swift`）。
///
/// **自動でレイアウトしない。** 段は「入口 → ワークロード → 世代 → Pod → ノード」で
/// 決まっているので、列に並べるだけでよい。線を自由に引く仕組みを持つと、
/// 図のためだけにレイアウトの実装を抱えることになる。
private struct TraceGraphView: View {
    let graph: TraceGraph
    let select: (TraceAnchor) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            notes
            // **枝ごとに囲む。** 起点が Service やノードのときは複数の
            // ワークロードにまたがるので、1 つの囲みに詰めると誰の Pod なのか
            // 分からなくなる。
            ForEach(graph.branches) { branch in
                TraceBranchView(branch: branch, anchor: graph.anchor, select: select)
            }
            storage
            if graph.isEmpty && graph.danglingServices.isEmpty
                && graph.missingServiceNames.isEmpty {
                Text("この起点から辿れる Pod はありません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **辿れなかったことを黙らない。** Ingress が指しているのに Service が
    /// 無い、Service が何も掴んでいない、はどちらも設定の誤りとしてよくある。
    /// 何も出さないと「先に何も無い」のか「壊れている」のかが分からない。
    @ViewBuilder
    private var notes: some View {
        if !graph.missingServiceNames.isEmpty {
            note(
                "指している Service がありません: "
                    + graph.missingServiceNames.joined(separator: ", "),
                level: .serious)
        }
        ForEach(graph.danglingServices, id: \.id) { service in
            note(
                "Service \(service.name) のセレクタに一致する Pod がありません。",
                level: .warning)
        }
    }

    private func note(_ text: String, level: StatusLevel) -> some View {
        Label(text, systemImage: level.symbol)
            .font(.caption)
            .foregroundStyle(Palette.textColor(for: level))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 使っているストレージ。**Pod の右に置かない。** 流れの先ではなく
    /// 付属物なので、図の下に別の帯として置く。
    @ViewBuilder
    private var storage: some View {
        if !graph.claims.isEmpty {
            HStack(alignment: .center, spacing: 10) {
                Text("使っているストレージ")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                ForEach(graph.claims) { claim in
                    TraceNodeLabel(
                        name: claim.name, kindLabel: ResourceKind.persistentVolumeClaim.displayName,
                        symbol: ResourceKind.persistentVolumeClaim.symbol, tint: .secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }
}

/// ワークロード 1 つぶんの枝。入口 → ワークロード → 世代 → Pod → ノード。
private struct TraceBranchView: View {
    let branch: TraceBranch
    let anchor: TraceAnchor
    let select: (TraceAnchor) -> Void

    var body: some View {
        DiagramBox(
            title: branch.namespace ?? "クラスタ", symbol: ResourceKind.namespace.symbol,
            tint: .secondary
        ) {
            HStack(alignment: .center, spacing: 0) {
                // 入口から順に。**無いものは出さない。** Service を持たない
                // ワークロードはふつうにあり、空の器を置くと「あるはずの
                // ものが欠けている」ように見える。
                if !branch.ingresses.isEmpty {
                    column(branch.ingresses, kind: .ingress)
                    DiagramArrow(length: 22)
                }
                if !branch.services.isEmpty {
                    column(branch.services, kind: .service)
                    DiagramArrow(length: 22)
                }
                workload
                DiagramArrow(length: 22)
                // **矢印の先を空にしない。** レプリカ 0 や、作られた直後で
                // まだ ReplicaSet が無いワークロードでは世代が 1 つも無い。
                // 何も置かないと、取れていないのか無いのかが分からない。
                if branch.generations.isEmpty {
                    Text("この時点で Pod はありません。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(minWidth: 140, alignment: .leading)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(branch.generations) { generation in
                            TraceGenerationView(
                                generation: generation, anchor: anchor, select: select)
                        }
                    }
                    // **潰すなら入口の側から。** 幅が足りないとき、SwiftUI は
                    // 伸び縮みする欄を等分に削るので、いちばん右の Pod 名から
                    // 先に読めなくなった（`web-...-58lkg`）。Pod とノードは
                    // この図の答えそのものなので、先に幅を取らせる。
                    .layoutPriority(1)
                }
            }
        }
    }

    private func column(_ objects: [K8sObject], kind: ResourceKind) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(objects) { object in
                let target = TraceAnchor(
                    anchorKind: kind == .ingress ? .ingress : .service,
                    resourceKind: kind, kindLabel: kind.apiKind,
                    namespace: object.namespace, name: object.name)
                TraceNodeLabel(
                    name: object.name, kindLabel: kind.displayName, symbol: kind.symbol,
                    isAnchor: target.id == anchor.id, select: { select(target) })
            }
        }
    }

    private var workload: some View {
        let target = branch.workload
        let isAnchor = target.id == anchor.id

        return VStack(spacing: 6) {
            ResourceGlyph(symbol: target.symbol, size: 40)
                .overlay(anchorRing(isAnchor, size: 40))
            Text(target.displayName)
                .font(.caption.weight(.medium))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 120)
                .lineLimit(2)
            Text(target.isStandalone ? "所有者なし" : target.kindLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 所有者の無い Pod の枠は起点にしても同じ絵になるので押させない。
            guard !target.isStandalone else { return }
            select(target)
        }
        .help(target.isStandalone ? "所有者のない Pod" : "\(target.kindLabel) を起点にする")
    }
}

/// ReplicaSet / Job 1 世代ぶん。**Pod が 0 の世代も囲みごと出す。**
/// 入れ替わりの途中や、古い世代が残っていることが分かる。
private struct TraceGenerationView: View {
    let generation: TraceGeneration
    let anchor: TraceAnchor
    let select: (TraceAnchor) -> Void

    var body: some View {
        // DaemonSet や StatefulSet には世代という段が無い。**囲みを二重に
        // 描かない** — 同じ名前の箱が入れ子になるだけで、何も増えない。
        if generation.isImplicit {
            pods
        } else {
            let target = generation.anchor
            DiagramBox(
                title: generation.name, symbol: generation.kind?.symbol,
                tint: tint,
                action: target.map { anchor in { select(anchor) } },
                help: "この世代だけを起点にする"
            ) {
                if generation.pods.isEmpty {
                    Text("Pod はありません（古い世代）")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(height: 34)
                } else {
                    pods
                }
            }
        }
    }

    /// 起点にしている世代は縁で示す。**古い世代は薄く。** 数の多い順に
    /// 並ぶので、色が同じだと今の世代がどれか分からない。
    private var tint: Color {
        if generation.anchor?.id == anchor.id { return Color.accentColor }
        return generation.pods.isEmpty ? .secondary : Palette.diagram
    }

    private var pods: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(generation.pods) { pod in
                TracePodRow(pod: pod, anchor: anchor, select: select)
            }
        }
    }
}

/// Pod 1 つと、その載っているノード。
private struct TracePodRow: View {
    @Environment(ClusterStore.self) private var store
    let pod: K8sObject
    let anchor: TraceAnchor
    let select: (TraceAnchor) -> Void

    private var isSelected: Bool { store.selectedObjectID == pod.id }

    var body: some View {
        let status = StatusResolver.health(for: pod)

        HStack(spacing: 8) {
            Button {
                store.selectedObjectID = pod.id
            } label: {
                HStack(spacing: 8) {
                    ResourceGlyph(
                        symbol: ResourceKind.pod.symbol, size: 30,
                        badge: status.level)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(pod.name)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(status.text)
                            .font(.caption2)
                            .foregroundStyle(Palette.textColor(for: status.level))
                    }
                    // **`width` で決め打ちしない。** 縮められない最小幅になり、
                    // 詳細の欄が窓より広がって、サイドバーとインスペクタの
                    // 両端が切れる（この画面だけ起きていた）。上限にする。
                    .frame(maxWidth: 210, alignment: .leading)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            Color.accentColor.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5))
            }
            .buttonStyle(.plain)
            // 名前は幅が足りないと真ん中を落とすので、全体はここで読めるようにする。
            .help("\(pod.namespace ?? "-")/\(pod.name) · \(status.text) · 押すと右のパネルに詳細")

            DiagramArrow(length: 20)

            // 行き先のノード。**Pod と同じ器にしない** — 種別が違う。
            node
        }
    }

    @ViewBuilder
    private var node: some View {
        if let name = PlacementTrace.nodeName(of: pod) {
            let target = TraceAnchor(
                anchorKind: .node, resourceKind: .node,
                kindLabel: ResourceKind.node.apiKind, namespace: nil, name: name)
            TraceNodeLabel(
                name: name, kindLabel: ResourceKind.node.displayName,
                symbol: ResourceKind.node.symbol, tint: .secondary, size: 26,
                // **行き先の欄は幅の下限を残す。** 無いと、伸び縮みする列の
                // 中でいちばん後ろのこの文字から先に潰れ、名前が消える。
                minWidth: 70, maxWidth: 170,
                isAnchor: target.id == anchor.id, select: { select(target) })
        } else {
            TraceNodeLabel(
                name: "未スケジュール", kindLabel: ResourceKind.node.displayName,
                symbol: "questionmark.square.dashed", tint: .secondary, size: 26,
                minWidth: 70, maxWidth: 170)
        }
    }
}

// MARK: - 図の中の 1 つ

/// 器と名前の組。押せるものは押すと起点になる。
private struct TraceNodeLabel: View {
    let name: String
    let kindLabel: String
    let symbol: String
    var tint: Color = Palette.diagram
    var size: CGFloat = 28
    var minWidth: CGFloat?
    var maxWidth: CGFloat = 150
    var isAnchor: Bool = false
    var select: (() -> Void)?

    var body: some View {
        let content = HStack(spacing: 7) {
            ResourceGlyph(symbol: symbol, size: size, tint: tint)
                .overlay(anchorRing(isAnchor, size: size))
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
        }

        if let select {
            Button(action: select) { content }
                .buttonStyle(.plain)
                .help("\(kindLabel) \(name) を起点にする")
        } else {
            content
        }
    }
}

/// いま起点にしている器の目印。
///
/// **状態の 4 色を使わない。** これは選択であって状態ではないので、
/// 一覧やタイルの選択と同じくアクセントに合わせる（OS の作法に従う場所）。
@ViewBuilder
private func anchorRing(_ isAnchor: Bool, size: CGFloat) -> some View {
    if isAnchor {
        Heptagon()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: size + 6, height: size + 6)
    }
}
