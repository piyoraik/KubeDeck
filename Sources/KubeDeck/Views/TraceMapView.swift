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
    @State private var anchorKind: TraceAnchorKind = TraceLaunch.kind ?? .workload
    @State private var focus: TraceAnchor?
    /// 押して辿った跡。**戻れないと押せない。** 押した先が外れだったとき、
    /// 一覧から選び直すことになる。
    @State private var history: [TraceAnchor] = []

    /// 起点の一覧の幅。図に `figureWidth` を残せないときは、一覧のほうを先に詰める。
    private static let pickerWidths: ClosedRange<CGFloat> = 196...264
    private static let figureWidth: CGFloat = 600

    var body: some View {
        // `HStack` に任せると、一覧はいつも上限まで取り、狭い窓では図のほうが切れる。
        GeometryReader { proxy in
            let room = proxy.size.width - Self.figureWidth
            content(
                pickerWidth: min(
                    Self.pickerWidths.upperBound, max(Self.pickerWidths.lowerBound, room)))
        }
    }

    private func content(pickerWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            picker
                .frame(width: pickerWidth)
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
                Text(anchors.isEmpty
                        ? anchorKind.emptyMessage
                        : String(localized: "一致するものがありません。"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(visible) { anchor in
                            row(anchor)
                        }
                    }
                    .padding(6)
                }
            }
        }
        // **幅はここで決めない。** 決め打ちだと、この欄のぶんがそのまま
        // 図に使える幅を削る。狭い窓では先にこちらを詰めさせる（名前は
        // 真ん中を落として出る。図のほうが答えそのもの）。`body` が窓の幅から決める。
        .frame(maxWidth: .infinity)
        .background(Palette.insetFill.opacity(0.5))
        // **`onAppear` だけで初期化しない。** 読み込みが終わる前に開くと
        // 一覧が空で、選ばれないまま右が空で固まる（実際そうなった）。
        // 一覧が変わるたびに、選択が有効かを見直す。**絞り込みの結果ではなく
        // 全体で見る** — 打ち込んだ文字で起点が勝手に変わると図が飛ぶ。
        .onChange(of: anchors.map(\.id), initial: true) { _, ids in
            if let focus, ids.contains(focus.id) { return }
            focus = anchors.first { $0.id == TraceLaunch.anchorID } ?? anchors.first
            // 起点が入れ替わったら跡も捨てる。無い場所へ戻れても仕方がない。
            history = []
        }
    }

    private var kindSelector: some View {
        VStack(alignment: .leading, spacing: 3) {
            Picker("起点", selection: $anchorKind) {
                ForEach(TraceAnchorKind.offered(routes: store.routeAvailability)) { kind in
                    Label(kind.title, systemImage: kind.symbol).tag(kind)
                }
            }
            .labelsHidden()
            // 経路を引かなくなったら選んだままにしない（選択肢に無い値が残る）。
            .onChange(of: store.routeAvailability) { _, availability in
                if anchorKind == .route, availability != .loaded { anchorKind = .workload }
            }
            // **セグメントにしない。** 7 つを 236pt に詰めると記号だけになり、
            // どれが何なのか読めなくなる。
            .pickerStyle(.menu)
            Text(anchorKind.help)
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 同じ名前が別の Namespace に居ることがある。添えないと
                    // 選べない。種別も添える（同じ名前の Deployment と
                    // StatefulSet が並ぶ）。
                    if let subtitle = subtitle(anchor) {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 6)
                Text("\(anchor.podCount)")
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(anchor.podCount == 0 ? .tertiary : .secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? Color.accentColor.opacity(0.24) : .clear,
                in: RoundedRectangle(cornerRadius: 6))
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
        // **状態を一覧の行に出す。** `Released` の PV や `Pending` の PVC は
        // ここでいちばん見つけたいものなので、1 つずつ押させない。
        if let detail = anchor.detail, !detail.isEmpty { parts.append(detail) }
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
                        .padding(.horizontal, 16)
                        .padding(.vertical, 18)
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
                    .font(.subheadline)
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
            parts.append(String(localized: "\(graph.branches.count) ワークロード"))
        }
        // ノードを起点にしているときの「1 ノード」は自分のことなので出さない。
        if graph.nodeCount > 0 && graph.anchor.anchorKind != .node {
            parts.append(String(localized: "\(graph.nodeCount) ノード"))
        }
        return parts.joined(separator: " · ")
    }

    /// 起点を移し、詳細も出す（枝が 1 つの図では起点が移っても絵がほぼ変わらない）。
    private func select(_ anchor: TraceAnchor) {
        if let object = PlacementTrace.object(for: anchor, in: inventory) {
            store.inspect(object)
        }
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
    @Environment(ClusterStore.self) private var store
    let graph: TraceGraph
    let select: (TraceAnchor) -> Void
    /// ServiceAccount に付いている Binding。**自動更新に載せない** —— 逆引きに
    /// 一覧が要るので重い（実測で RoleBinding + ClusterRoleBinding が 10.4 秒）。
    @State private var bindings = AccessBindings()
    /// 引き直したロールの中身。**自動更新に載せない** — 起点が変わった
    /// ときだけ引く（イベントタブと同じ考え方）。
    @State private var rules = AccessRules()
    /// 通信の段。Namespace のラベルを引いてから解くので、描画の外で 1 度だけ組む。
    @State private var network: TraceNetwork?
    /// 起点が複数のワークロードにまたがるときの、ワークロードごとの通信。
    @State private var branchNetworks: [BranchNetwork] = []
    /// 解いた結果がどの起点のものか。前の起点の図を、押せる形で出したままにしない。
    @State private var networkAnchorID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            notes
            if let split = graph.routeSplit {
                TraceRouteSplitView(
                    split: split, showsBranchHeading: !graph.branches.isEmpty, select: select)
            }
            // **枝ごとに囲む。** 起点が Service やノードのときは複数の
            // ワークロードにまたがるので、1 つの囲みに詰めると誰の Pod なのか
            // 分からなくなる。
            ForEach(graph.branches) { branch in
                WidthCap {
                    TraceBranchView(branch: branch, anchor: graph.anchor, select: select)
                }
            }
            storage
            configs
            networkBand
            access
            // **断りを二重に出さない。** PVC / PV の起点は、なぜ辿れないのかを
            // `anchorNotes` がすでに書いている（そちらのほうが具体的）。
            if graph.isEmpty && graph.danglingServices.isEmpty
                && graph.missingServiceNames.isEmpty && graph.anchorNotes.isEmpty {
                Text("この起点から辿れる Pod はありません。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **鍵は「引く相手」だけにする。** 起点が同じなら引き直さない
        // （`graph` そのものを鍵にすると、10 秒ごとの取得で Pod の中身が
        // 変わるたびに Binding と ClusterRole を引き直すことになる）。
        //
        // 鍵は ServiceAccount の一覧。**Binding にしない** —— それ自身が
        // これから引くものなので、鍵にすると引けた瞬間に鍵が変わる。
        .task(id: graph.access.accounts.map(\.id).joined(separator: ",")) {
            let accounts = graph.access.accounts
            guard !accounts.isEmpty else {
                bindings = AccessBindings(isLoaded: true)
                rules = AccessRules(isLoaded: true)
                return
            }
            // **2 段で引く。** どのロールを引けばよいかは Binding の
            // `roleRef` にしか書いていないので、順番は入れ替えられない。
            let loaded = await store.serviceAccountBindings(for: accounts)
            bindings = loaded
            let all = loaded.all
            guard !all.isEmpty else {
                rules = AccessRules(isLoaded: true)
                return
            }
            rules = await store.roleRules(for: all)
        }
        .task(id: networkKey) {
            guard !graph.pods.isEmpty, !policiesUnreadable else {
                network = nil
                branchNetworks = []
                return
            }
            let labels = await store.namespaceLabels()
            // 複数のワークロードにまたがる起点は、まとめて判定せずワークロードごとに解く。
            if graph.branches.count > 1 {
                branchNetworks = PlacementTrace.branchNetworks(
                    for: graph, inventory: store.placementInventory,
                    controllers: store.controllerIndex, scope: store.selectedNamespace,
                    namespaceLabels: labels)
                network = nil
            } else {
                network = PlacementTrace.network(
                    for: graph.pods, inventory: store.placementInventory,
                    controllers: store.controllerIndex, scope: store.selectedNamespace,
                    namespaceLabels: labels)
                branchNetworks = []
            }
            networkAnchorID = graph.anchor.id
        }
    }

    /// 起点か取得が変わったときだけ解き直す。
    private var networkKey: String {
        let loaded = store.lastUpdated?.timeIntervalSince1970 ?? 0
        return "\(graph.anchor.id)|\(graph.podCount)|\(loaded)|\(policiesUnreadable)"
    }

    /// NetworkPolicy を読めていないのに「制限なし」と描かない。
    private var policiesUnreadable: Bool {
        store.deniedKinds.contains(.networkPolicy) || store.failedKinds.contains(.networkPolicy)
            || store.unknownKinds.contains(.networkPolicy)
    }

    /// **辿れなかったことを黙らない。** Ingress が指しているのに Service が
    /// 無い、Service が何も掴んでいない、はどちらも設定の誤りとしてよくある。
    /// 何も出さないと「先に何も無い」のか「壊れている」のかが分からない。
    @ViewBuilder
    private var notes: some View {
        // 起点そのものについての断りを先に置く。**帯の下ではなく上** ——
        // なぜ図が空なのかを、空の図を見てから探させない。
        ForEach(graph.anchorNotes) { anchorNote in
            note(anchorNote.text, level: anchorNote.level)
        }
        if !graph.missingServiceNames.isEmpty {
            let names = graph.missingServiceNames.joined(separator: ", ")
            note(
                String(localized: "指している Service がありません: \(names)"),
                level: .serious)
        }
        ForEach(graph.danglingServices, id: \.id) { service in
            note(
                String(
                    localized: "Service \(service.name) のセレクタに一致する Pod がありません。"),
                level: .warning)
        }
    }

    private func note(_ text: String, level: StatusLevel) -> some View {
        Label(text, systemImage: level.symbol)
            .font(.callout)
            .foregroundStyle(Palette.textColor(for: level))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 使っているストレージ。**Pod の右に置かない。** 流れの先ではなく
    /// 付属物なので、図の下に別の帯として置く。
    ///
    /// **PVC で止めない。** 容量も StorageClass も PV 側にしか無いので、
    /// PVC だけ出すと「どこに置かれているのか」が分からない。
    ///
    /// **未バインドを「PV が無い」と書かない。** `spec.volumeName` が空なのは
    /// 「まだバインドされていない」で、Pod が起動しない原因そのもの。
    @ViewBuilder
    private var storage: some View {
        if !graph.storage.isEmpty {
            // 起点が PVC / PV のときは「使っている」ではない（起点そのもの）。
            band(isStorageAnchor ? "ストレージ" : "使っているストレージ") {
                tiles(minimumWidth: 236, maximumWidth: 496) {
                    ForEach(graph.storage) { link in
                        HStack(spacing: 8) {
                            claim(link)
                            DiagramArrow(length: 18)
                            volume(link)
                        }
                    }
                }
            }
        }
    }

    private var isStorageAnchor: Bool {
        graph.anchor.anchorKind == .claim || graph.anchor.anchorKind == .volume
    }

    /// **ここも押せる。** 「この PVC を使っているのは何か」は帯を見ている
    /// まさにその場で起きる問いなので、一覧に戻って選び直させない
    /// （図の中の器を押せるようにしてあるのと同じ判断）。
    private func claim(_ link: StorageLink) -> some View {
        let target = TraceAnchor(
            anchorKind: .claim, resourceKind: .persistentVolumeClaim,
            kindLabel: ResourceKind.persistentVolumeClaim.apiKind,
            namespace: link.claim.namespace, name: link.claim.name)

        return TraceNodeLabel(
            name: link.claim.name, kindLabel: link.claimDetail,
            symbol: ResourceKind.persistentVolumeClaim.symbol,
            tint: .secondary, maxWidth: 190,
            isAnchor: target.id == graph.anchor.id, select: { select(target) })
    }

    @ViewBuilder
    private func volume(_ link: StorageLink) -> some View {
        if let name = link.volumeName {
            // **引けていないことを「無い」と書かない。** 名前は分かっている
            // ので、中身が来ていないことだけを言う。
            let target = TraceAnchor(
                anchorKind: .volume, resourceKind: .persistentVolume,
                kindLabel: ResourceKind.persistentVolume.apiKind,
                namespace: nil, name: name)
            TraceNodeLabel(
                name: name,
                // 実物が引けていれば状態・容量・StorageClass まで。
                kindLabel: link.volumeDetail ?? String(localized: "PV · 中身を引けていません"),
                symbol: ResourceKind.persistentVolume.symbol, tint: .secondary,
                minWidth: 106, maxWidth: 236,
                isAnchor: target.id == graph.anchor.id,
                // 実物が無いものを起点にすると、押した先で何も出せない。
                select: link.volume == nil ? nil : { select(target) })
        } else {
            Text("まだバインドされていません")
                .font(.subheadline)
                .foregroundStyle(Palette.textColor(for: .warning))
                .frame(minWidth: 106, maxWidth: 236, alignment: .leading)
        }
    }

    /// 通信。入ってこられる相手 → 起点 → 出ていける先。
    ///
    /// **宣言上の許可であって、実際の通信ではない。** CNI が強制していなければ
    /// 効かず、CNI 独自の policy も見ていない。毎回そう断る。
    @ViewBuilder
    private var networkBand: some View {
        if !graph.pods.isEmpty {
            band("通信") {
                VStack(alignment: .leading, spacing: 10) {
                    if policiesUnreadable {
                        failureNote("""
                            NetworkPolicy を読めないため、通信を判定できません\
                            （制限が無いという意味ではありません）。
                            """)
                    } else if networkAnchorID == graph.anchor.id, !branchNetworks.isEmpty {
                        TraceNetworkIndex(branches: branchNetworks, select: select)
                    } else if networkAnchorID == graph.anchor.id, let network {
                        TraceNetworkDiagram(network: network, anchor: graph.anchor, select: select)
                    } else {
                        Text("NetworkPolicy を解いています…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("""
                        NetworkPolicy の宣言から解いた許可です。実際の通信ではありません。\
                        CNI が NetworkPolicy を強制していない環境では効かず、\
                        CNI 独自の policy（Cilium・Calico など）は見ていません。
                        """)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 参照している ConfigMap / Secret。ストレージと同じ持ち場（付属物）で、
    /// **段には入れない** — 流れの先ではない。
    ///
    /// **Secret の中身は出さない。** 名前と付き方まで。
    ///
    /// **「ありません」と書かない。** 設定を 1 つも使わない Pod はふつうに
    /// あり、無いことは異常ではない（空の器も置かない）。
    @ViewBuilder
    private var configs: some View {
        if !graph.configs.isEmpty {
            band("使っている設定") {
                tiles(maximumWidth: 284) {
                    ForEach(graph.configs) { reference in
                        TraceNodeLabel(
                            name: reference.name, kindLabel: reference.detail,
                            symbol: reference.source.kind.symbol, tint: .secondary,
                            maxWidth: 224,
                            select: configNamespace.map { namespace in
                                {
                                    Task {
                                        await store.inspect(
                                            reference.source.kind, name: reference.name,
                                            namespace: namespace)
                                    }
                                }
                            },
                            help: String(localized: "押すと右のパネルに詳細"))
                    }
                }
            }
        }
    }

    /// 参照は名前しか持たないので、引く先の Namespace が 1 つに決まるときだけ押せる。
    private var configNamespace: String? {
        let namespaces = Set(graph.pods.compactMap(\.namespace))
        return namespaces.count == 1 ? namespaces.first : nil
    }

    /// 動いている権限。ServiceAccount → Binding → ロールの中身。
    ///
    /// **名前だけ並べない。** どの Role が強いのかが分からず、結局 1 つずつ
    /// 開くことになる（「アクセス制御」の一覧と同じ判断）。Binding も rules も
    /// 重いので**起点が変わったときだけ引き直す**
    /// （`ClusterStore.serviceAccountBindings` / `roleRules`）。
    @ViewBuilder
    private var access: some View {
        if !graph.access.isEmpty {
            band("動いている権限") {
                VStack(alignment: .leading, spacing: 8) {
                    TraceAccessChain(
                        accounts: graph.access.accounts, bindings: bindings, rules: rules)
                    // **「権限が無い」と書かない。** 読めなかっただけ。
                    // Binding が読めなかったのと、Binding は読めたが指している
                    // ロールが読めなかったのは**見る場所が違う**ので分けて出す。
                    // **添字や引数を鍵の中で組まない。** 補間の中に `"` が入ると
                    // 文言としての切れ目が読めなくなる。先に組んでおく。
                    if !bindings.failures.isEmpty {
                        let names = bindings.failures.joined(separator: "・")
                        failureNote("""
                            \(names) を読めませんでした。\
                            付いている Binding がこれで全部とは限りません。
                            """)
                    }
                    if !rules.failures.isEmpty {
                        let names = rules.failures.joined(separator: "・")
                        failureNote("""
                            \(names) を読めませんでした。\
                            付いている規則がこれで全部とは限りません。
                            """)
                    }
                }
            }
        }
    }

    private func failureNote(_ text: String) -> some View {
        Label(text, systemImage: StatusLevel.warning.symbol)
            .font(.subheadline)
            .foregroundStyle(Palette.textColor(for: .warning))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 付属物の帯。見出しは中身の上に置き、どの帯も図と同じ左端から始める。
    private func band<Content: View>(
        _ title: LocalizedStringResource, @ViewBuilder content: () -> Content
    ) -> some View {
        WidthCap {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    Rectangle()
                        .fill(Palette.hairline)
                        .frame(height: 1)
                }
                content()
            }
            .frame(maxWidth: 920, alignment: .leading)
        }
        .padding(.top, 6)
    }

    /// **横に並べきれないときは折り返す。** `HStack` のままだと数が増えた
    /// ときに 1 つずつ潰れ、どれも名前が読めなくなる。
    private func tiles<Content: View>(
        minimumWidth: CGFloat = 166, maximumWidth: CGFloat = 284,
        @ViewBuilder content: () -> Content
    ) -> some View {
        WrappingTiles(
            spacing: 8, lineSpacing: 6,
            minimumWidth: minimumWidth, maximumWidth: maximumWidth
        ) {
            content()
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
            title: branch.namespace ?? String(localized: "クラスタ"),
                symbol: ResourceKind.namespace.symbol,
            tint: .secondary, stroke: Palette.diagramFrame
        ) {
            FigureRow(spacing: 8) {
                // 入口から順に。**無いものは出さない。** Service を持たない
                // ワークロードはふつうにあり、空の器を置くと「あるはずの
                // ものが欠けている」ように見える。
                if !branch.ingresses.isEmpty || !branch.routes.isEmpty {
                    // Ingress と経路はどちらも入口なので、同じ列に並べる。
                    VStack(alignment: .leading, spacing: 8) {
                        if !branch.ingresses.isEmpty {
                            column(branch.ingresses, kind: .ingress)
                        }
                        if !branch.routes.isEmpty {
                            TraceRouteColumn(
                                entries: branch.routes, anchor: anchor, select: select)
                        }
                    }
                    .layoutValue(key: FigureRow.MinimumWidth.self, value: 26 + 8 + 108)
                    DiagramArrow(length: 20)
                }
                if !branch.services.isEmpty {
                    column(branch.services, kind: .service)
                    DiagramArrow(length: 20)
                }
                workload
                    .layoutValue(key: FigureRow.MinimumWidth.self, value: 38 + 10 + 64)
                DiagramArrow(length: 20)
                // **矢印の先を空にしない。** レプリカ 0 や、作られた直後で
                // まだ ReplicaSet が無いワークロードでは世代が 1 つも無い。
                // 何も置かないと、取れていないのか無いのかが分からない。
                if branch.generations.isEmpty {
                    Text("この時点で Pod はありません。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 166, alignment: .leading)
                        .layoutValue(key: FigureRow.IsBody.self, value: true)
                } else {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(branch.generations) { generation in
                            TraceGenerationView(
                                generation: generation, anchor: anchor, select: select)
                        }
                    }
                    // **余りを取るのはこの列だけ**（`FigureRow`）。入口とワークロードは
                    // 名前の幅で止まり、Pod の並びが下限（タイル 1 列）でも入らないとき
                    // だけ縮む。`layoutPriority(1)` で先に幅を取らせると、タイルが
                    // 「1 行に全部」を要求して**左の入口の列を押しのける**。
                    .layoutValue(key: FigureRow.IsBody.self, value: true)
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
                let tags = kind == .service ? branch.tags(on: object) : []
                VStack(alignment: .leading, spacing: 3) {
                    TraceNodeLabel(
                        name: object.name, kindLabel: kind.displayName, symbol: kind.symbol,
                        isAnchor: target.id == anchor.id, select: { select(target) })
                    if !tags.isEmpty {
                        TraceRouteTags(tags: tags, anchor: anchor, select: select)
                    }
                }
            }
        }
        // **入口の列にも下限を残す。** 右の Pod の列は幅をいくらでも使える
        // （1 行に全部並べるのが最大）ので、下限が無いとこちらが先に潰れて名前が消える。
        .layoutValue(key: FigureRow.MinimumWidth.self, value: 26 + 8 + 108)
    }

    private var workload: some View {
        let target = branch.workload
        let isAnchor = target.id == anchor.id

        // 図のほかの器と同じ「器と 2 行」。主役であることは、大きさと太字で示す。
        return HStack(spacing: 10) {
            ResourceGlyph(symbol: target.symbol, size: 38)
                .overlay(anchorRing(isAnchor, size: 38))
            VStack(alignment: .leading, spacing: 0) {
                Text(target.displayName)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(target.isStandalone
                        ? String(localized: "所有者なし") : target.kindLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 64, maxWidth: 200, alignment: .leading)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            // 所有者の無い Pod の枠は起点にしても同じ絵になるので押させない。
            guard !target.isStandalone else { return }
            select(target)
        }
        .help(
            target.isStandalone
                ? "所有者のない Pod" : "\(target.kindLabel) \(target.displayName) を起点にする")
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
                help: String(localized: "この世代だけを起点にする")
            ) {
                if generation.pods.isEmpty {
                    Text("Pod はありません（古い世代）")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
            ForEach(PlacementTrace.podsByNode(generation.pods)) { group in
                TraceNodeGroupRow(group: group, anchor: anchor, select: select)
            }
        }
    }
}

/// 同じノードに載っている Pod と、その行き先のノード。
///
/// **ノードの器を Pod の数だけ描かない。** 以前は Pod 1 つにつき
/// 「Pod → 矢印 → ノード」の行を引いており、8 レプリカが 1 ノードに載って
/// いるだけで同じノード名が 8 回出た。1 行 500pt が 8 段に伸びるので、
/// **横が 348pt 空いたまま縦にだけ伸びる**（実測）。まとめて横に流す。
///
/// **矢印の向きは変えない。** 図ぜんぶが「入口 → … → Pod → ノード」の
/// 左から右なので、ここだけノードを左に置くと読む向きが折り返す。
private struct TraceNodeGroupRow: View {
    let group: TraceNodeGroup
    let anchor: TraceAnchor
    let select: (TraceAnchor) -> Void

    var body: some View {
        FigureRow(spacing: 8) {
            WrappingTiles(spacing: 8, lineSpacing: 6) {
                ForEach(group.pods) { pod in
                    TracePodTile(pod: pod, node: group.node)
                }
            }
            .layoutValue(key: FigureRow.IsBody.self, value: true)

            DiagramArrow(length: 24)
            node
                // **行き先の欄は幅の下限を残す。** 無いと、いちばん後ろの
                // この文字から先に潰れ、名前が消える。
                .layoutValue(key: FigureRow.MinimumWidth.self, value: 24 + 8 + 84)
        }
    }

    /// 行き先のノード。**Pod と同じ器にしない** — 種別が違う。
    /// **件数は文字でも出す** — タイルの数を目で数えさせない（配置画面と同じ）。
    @ViewBuilder
    private var node: some View {
        let count = "\(group.pods.count) Pod"
        if let name = group.node {
            let target = TraceAnchor(
                anchorKind: .node, resourceKind: .node,
                kindLabel: ResourceKind.node.apiKind, namespace: nil, name: name)
            TraceNodeLabel(
                name: name, kindLabel: "\(ResourceKind.node.displayName) · \(count)",
                symbol: ResourceKind.node.symbol, tint: .secondary, size: 24,
                minWidth: 84, maxWidth: 200,
                isAnchor: target.id == anchor.id, select: { select(target) })
        } else {
            TraceNodeLabel(
                name: String(localized: "未スケジュール"), kindLabel: count,
                symbol: "questionmark.square.dashed", tint: .secondary, size: 24,
                minWidth: 84, maxWidth: 200)
        }
    }
}

/// Pod 1 つぶんのタイル。
private struct TracePodTile: View {
    @Environment(ClusterStore.self) private var store
    let pod: K8sObject
    /// 載っているノード。まとまりの見出しに出ているので画面には出さないが、
    /// 指したときの説明には要る（タイルだけを見ている人が居る）。
    let node: String?

    private var isSelected: Bool { store.selectedObjectID == pod.id }

    var body: some View {
        let status = StatusResolver.health(for: pod)
        // **`??` を鍵の中に書かない。** 補間の中の `"` で文言の切れ目が
        // 読めなくなる（この画面で実際に壊した）。先に決めておく。
        let place = node ?? String(localized: "未スケジュール")

        return Button {
            // 配置のタイルと同じ入口を通す（`selectedObjectID` を直に
            // 書くと、操作の対象になる集合が空のまま取り残される）。
            store.selectOnly(pod)
        } label: {
            HStack(spacing: 8) {
                ResourceGlyph(symbol: ResourceKind.pod.symbol, size: 26, badge: status.level)
                VStack(alignment: .leading, spacing: 0) {
                    Text(pod.name)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // 正常な Pod の状態には色を付けない。色としるしは、正常でないときだけ。
                    Text(status.text)
                        .font(.subheadline)
                        .foregroundStyle(
                            status.level == .good
                                ? Color.secondary : Palette.textColor(for: status.level))
                }
                // **幅を決め打ちしない。** 210pt に固定していたので、短い
                // 名前でも枠を取り、長い名前は余っているのに中央を落として
                // いた。幅は `WrappingTiles` が名前の長さから決めて段で揃える。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        // 名前は幅が足りないと真ん中を落とすので、全体はここで読めるようにする。
        .help("""
            \(pod.namespace ?? "-")/\(pod.name) · \(status.text) · \
            \(place) · 押すと右のパネルに詳細
            """)
    }
}

/// 同じ大きさのタイルを、与えられた幅で折り返して並べる。
///
/// **`LazyVGrid` を使わない。** あちらは提案された幅をそのまま取るので、
/// Pod が 1 つでも囲みが欄いっぱいに伸び、中の空きがかえって目立つ。
/// ここは「入るだけ横に並べ、余ったぶんは要らない」場所。
///
/// **提案された幅を有限だと思わない。** SwiftUI は「いちばん広いとき」を
/// 訊くために `.infinity` を提案してくる。`Int(.infinity)` はトラップする
/// （`SectionColumns` で実際に落ちた）。幅が無いときは `idealColumns` に落とす
/// — ここで全部を 1 行に並べた大きさを返すと、`layoutPriority` で先に幅を
/// 取るこの列が、左の入口の列を潰してしまう。
private struct WrappingTiles: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 6
    var idealColumns = 3
    /// 名前が短くてもこれ以下にはしない（器と状態で埋まる）。
    var minimumWidth: CGFloat = 168
    /// 名前が長くてもこれ以上は広げない。あとは中央を落として読ませる。
    var maximumWidth: CGFloat = 330

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let (item, columns) = arrangement(for: proposal.width, subviews: subviews)
        let rows = (subviews.count + columns - 1) / columns
        let used = min(subviews.count, columns)
        return CGSize(
            width: CGFloat(used) * item.width + CGFloat(used - 1) * spacing,
            height: CGFloat(rows) * item.height + CGFloat(rows - 1) * lineSpacing)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        guard !subviews.isEmpty else { return }
        let (item, columns) = arrangement(for: bounds.width, subviews: subviews)
        for (index, subview) in subviews.enumerated() {
            let row = index / columns
            let column = index % columns
            subview.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(column) * (item.width + spacing),
                    y: bounds.minY + CGFloat(row) * (item.height + lineSpacing)),
                proposal: ProposedViewSize(item))
        }
    }

    /// 1 列でも入らない幅なら、下限まではタイルを狭める（名前は中央を落として出る）。
    /// そうしないと、いちばん長い名前がこの並びの最小幅になり、図ごと欄からはみ出す。
    private func arrangement(
        for width: CGFloat?, subviews: Subviews
    ) -> (item: CGSize, columns: Int) {
        var item = itemSize(subviews)
        let columns = columnCount(for: width, item: item, count: subviews.count)
        if columns == 1, let width, width.isFinite {
            item.width = max(minimumWidth, min(item.width, width))
        }
        return (item, columns)
    }

    /// **段の中で幅を揃える。** ばらばらの幅で流すと、行ごとに切れ目の
    /// 位置が変わって数が読めなくなる。いちばん長い名前に合わせる。
    private func itemSize(_ subviews: Subviews) -> CGSize {
        var width: CGFloat = 0
        var height: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            width = max(width, size.width)
            height = max(height, size.height)
        }
        return CGSize(width: min(max(width, minimumWidth), maximumWidth), height: height)
    }

    /// **最小・ふつう・最大を取り違えない。** SwiftUI の `HStack` は、幅 0 と
    /// `.infinity` を提案して子の伸び縮みの幅を測る。ここで両方に同じ値
    /// （「ふつう」の 3 列）を返していたため、**伸び縮みしない子だと判断されて
    /// 幅を等分され**、8 個の Pod が 1 列に縦積みのままだった（実測で提案
    /// 217.67pt・1 列 8 行）。最小は 1 列、最大は 1 行に全部、と返す。
    private func columnCount(for width: CGFloat?, item: CGSize, count: Int) -> Int {
        // 幅の指定が無い＝「ふつうの大きさ」を訊かれている。ここで全部を
        // 1 行に並べた幅を返すと、左の入口の列を押しのける。
        guard let width else { return max(1, min(count, idealColumns)) }
        // `Int(.infinity)` はトラップする（`SectionColumns` で実際に落ちた）。
        guard width.isFinite else { return count }
        let fits = Int((width + spacing) / (item.width + spacing))
        return max(1, min(count, fits))
    }
}

/// 図の 1 行。余りを取る子（Pod の並びなど）を 1 つだけ置き、ほかは中身の幅で止める。
///
/// **`HStack` に任せない。** あちらは伸び縮みの小さい子から順に幅を配るので、
/// 余っていれば名前の欄を上限まで広げ、足りなくなると最後の子をはみ出させる
/// （実測: Ingress と Service を持つ枝で、入口の列が空白を抱えたままノード名が切れた）。
private struct FigureRow: Layout {
    var spacing: CGFloat = 0

    /// 余りを取る子。1 行に 1 つ。
    struct IsBody: LayoutValueKey {
        static let defaultValue = false
    }

    /// ここまでは縮めてよい幅。付けない子は縮めない。
    struct MinimumWidth: LayoutValueKey {
        static let defaultValue: CGFloat? = nil
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(for: proposal.width, subviews: subviews)
        var height: CGFloat = 0
        for (subview, width) in zip(subviews, widths) {
            height = max(
                height, subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
        }
        return CGSize(width: widths.reduce(0, +) + gaps(subviews), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(for: bounds.width, subviews: subviews)) {
            subview.place(
                at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                proposal: ProposedViewSize(width: width, height: nil))
            x += width + spacing
        }
    }

    private func gaps(_ subviews: Subviews) -> CGFloat {
        spacing * CGFloat(max(0, subviews.count - 1))
    }

    private func widths(for width: CGFloat?, subviews: Subviews) -> [CGFloat] {
        var widths = subviews.map { $0.sizeThatFits(.unspecified).width }
        guard let width, width.isFinite,
              let body = subviews.firstIndex(where: { $0[IsBody.self] })
        else { return widths }

        let minimum = subviews[body].sizeThatFits(ProposedViewSize(width: 0, height: nil)).width
        func room() -> CGFloat {
            width - gaps(subviews) - widths.indices.reduce(0) { $0 + ($1 == body ? 0 : widths[$1]) }
        }
        // 余りを取る子が下限でも入らないときだけ、ほかを同じ割合で下限へ寄せる。
        let slack = subviews.indices.map { index -> CGFloat in
            guard index != body, let floor = subviews[index][MinimumWidth.self] else { return 0 }
            return max(0, widths[index] - floor)
        }
        let total = slack.reduce(0, +)
        if room() < minimum, total > 0 {
            let cut = min(1, (minimum - room()) / total)
            for index in subviews.indices { widths[index] -= slack[index] * cut }
        }
        let offered = max(minimum, room())
        widths[body] = subviews[body]
            .sizeThatFits(ProposedViewSize(width: offered, height: nil)).width
        return widths
    }
}

/// 提案より広い大きさを、親へ伝えない枠。
///
/// 入りきらない枝が 1 つあると、`VStack` はその幅を自分の幅にして、ほかの枝にも同じ幅を
/// 提案する。すると**入るはずの枝まで縮まずに欄からはみ出す**（実測: Ingress と Service を
/// 持つ枝が 1 つあるだけで、ノードを起点にした図のすべての行でノード名が切れた）。
private struct WidthCap: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        var size = subview.sizeThatFits(proposal)
        if let width = proposal.width, width.isFinite {
            size.width = min(size.width, width)
        }
        return size
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: proposal)
    }
}

// MARK: - 図の中の 1 つ

/// 器と名前の組。押せるものは押すと起点になる。
private struct TraceNodeLabel: View {
    let name: String
    let kindLabel: String
    let symbol: String
    var tint: Color = Palette.diagram
    var size: CGFloat = 26
    var minWidth: CGFloat?
    var maxWidth: CGFloat = 176
    var isAnchor: Bool = false
    var select: (() -> Void)?
    /// 起点にならない器（詳細だけを出す）の説明。
    var help: String?

    var body: some View {
        let content = HStack(spacing: 8) {
            ResourceGlyph(symbol: symbol, size: size, tint: tint)
                .overlay(anchorRing(isAnchor, size: size))
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(kindLabel)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(minWidth: minWidth, maxWidth: maxWidth, alignment: .leading)
        }

        if let select, let help {
            Button(action: select) { content }
                .buttonStyle(.plain)
                .help(help)
        } else if let select {
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
func anchorRing(_ isAnchor: Bool, size: CGFloat) -> some View {
    if isAnchor {
        Heptagon()
            .stroke(Color.accentColor, lineWidth: 2)
            .frame(width: size + 6, height: size + 6)
    }
}

/// 撮影用。`-traceAnchor <起点の id>` で起こすと、その起点で開く（保存はしない）。
private enum TraceLaunch {
    static let anchorID = UserDefaults.standard.string(forKey: "traceAnchor")

    static var kind: TraceAnchorKind? {
        anchorID.flatMap { TraceAnchorKind(rawValue: String($0.prefix { $0 != "|" })) }
    }
}
