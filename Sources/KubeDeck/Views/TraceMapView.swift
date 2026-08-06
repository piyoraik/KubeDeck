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
    @Environment(ClusterStore.self) private var store
    let graph: TraceGraph
    let select: (TraceAnchor) -> Void
    /// 引き直したロールの中身。**自動更新に載せない** — 起点が変わった
    /// ときだけ引く（イベントタブと同じ考え方）。
    @State private var rules = AccessRules()

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
            configs
            policies
            access
            if graph.isEmpty && graph.danglingServices.isEmpty
                && graph.missingServiceNames.isEmpty {
                Text("この起点から辿れる Pod はありません。")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // **鍵は「引く相手」だけにする。** 起点が同じなら引き直さない
        // （`graph` そのものを鍵にすると、10 秒ごとの取得で Pod の中身が
        // 変わるたびに ClusterRole を引き直すことになる）。
        .task(id: graph.access.bindings.map(\.id).joined(separator: ",")) {
            let bindings = graph.access.bindings
            guard !bindings.isEmpty else {
                rules = AccessRules(isLoaded: true)
                return
            }
            rules = await store.roleRules(for: bindings)
        }
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
    ///
    /// **PVC で止めない。** 容量も StorageClass も PV 側にしか無いので、
    /// PVC だけ出すと「どこに置かれているのか」が分からない。
    ///
    /// **未バインドを「PV が無い」と書かない。** `spec.volumeName` が空なのは
    /// 「まだバインドされていない」で、Pod が起動しない原因そのもの。
    @ViewBuilder
    private var storage: some View {
        if !graph.storage.isEmpty {
            band("使っているストレージ") {
                tiles(minimumWidth: 200, maximumWidth: 420) {
                    ForEach(graph.storage) { link in
                        HStack(spacing: 8) {
                            TraceNodeLabel(
                                name: link.claim.name,
                                kindLabel: ResourceKind.persistentVolumeClaim.displayName,
                                symbol: ResourceKind.persistentVolumeClaim.symbol,
                                tint: .secondary, maxWidth: 160)
                            DiagramArrow(length: 16)
                            volume(link)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func volume(_ link: StorageLink) -> some View {
        if let name = link.volumeName {
            TraceNodeLabel(
                name: name,
                // 実物が引けていれば容量と StorageClass まで。引けていなければ
                // 種別だけ書く（**「無い」と言わない**）。
                kindLabel: link.volumeDetail ?? ResourceKind.persistentVolume.displayName,
                symbol: ResourceKind.persistentVolume.symbol, tint: .secondary,
                minWidth: 90, maxWidth: 200)
        } else {
            Text("まだバインドされていません")
                .font(.caption2)
                .foregroundStyle(Palette.textColor(for: .warning))
                .frame(minWidth: 90, maxWidth: 200, alignment: .leading)
        }
    }

    /// 効いている NetworkPolicy。
    ///
    /// **無いことを「制限なし」と断らない。** 1 つも無ければ通信は素通りだが、
    /// それは**この画面が引けている範囲での話**で、CNI が入っていなければ
    /// NetworkPolicy 自体が効かない（policy はあるのに効いていない、も起きる）。
    /// ここでは効いている policy を並べるだけにする。
    @ViewBuilder
    private var policies: some View {
        if !graph.policies.isEmpty {
            band("効いている通信制限") {
                tiles(minimumWidth: 170, maximumWidth: 300) {
                    ForEach(graph.policies) { policy in
                        TraceNodeLabel(
                            name: policy.name,
                            kindLabel: ResourceTable.policyDirections(policy),
                            symbol: ResourceKind.networkPolicy.symbol, tint: .secondary,
                            maxWidth: 240)
                    }
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
                tiles(maximumWidth: 240) {
                    ForEach(graph.configs) { reference in
                        TraceNodeLabel(
                            name: reference.name, kindLabel: reference.detail,
                            symbol: reference.source.kind.symbol, tint: .secondary,
                            maxWidth: 190)
                    }
                }
            }
        }
    }

    /// 動いている権限。ServiceAccount → Binding → ロールの中身。
    ///
    /// **名前だけ並べない。** どの Role が強いのかが分からず、結局 1 つずつ
    /// 開くことになる（「アクセス制御」の一覧と同じ判断）。rules は重いので
    /// **紐づいたぶんだけ引き直す**（`ClusterStore.roleRules`）。
    @ViewBuilder
    private var access: some View {
        if !graph.access.isEmpty {
            band("動いている権限") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(graph.access.accounts) { account in
                        accountRow(account)
                    }
                    if !rules.failures.isEmpty {
                        // **「権限が無い」と書かない。** 読めなかっただけ。
                        Label(
                            "\(rules.failures.joined(separator: "・")) を読めませんでした。"
                                + "付いている規則がこれで全部とは限りません。",
                            systemImage: StatusLevel.warning.symbol)
                            .font(.caption2)
                            .foregroundStyle(Palette.textColor(for: .warning))
                    }
                }
            }
        }
    }

    private func accountRow(_ account: AccessAccount) -> some View {
        HStack(alignment: .center, spacing: 8) {
            TraceNodeLabel(
                name: account.name, kindLabel: ResourceKind.serviceAccount.displayName,
                symbol: ResourceKind.serviceAccount.symbol, tint: .secondary,
                minWidth: 110, maxWidth: 170)
            if account.bindings.isEmpty {
                // **「権限がありません」と断定しない。** グループ経由の付与
                // （`system:serviceaccounts:*`）は見ていない。
                Text("直接付いている Binding はありません（グループ経由の付与は見ていません）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                DiagramArrow(length: 16)
                tiles(minimumWidth: 200, maximumWidth: 340) {
                    ForEach(account.bindings) { binding in
                        bindingTile(binding)
                    }
                }
            }
        }
    }

    private func bindingTile(_ binding: AccessBinding) -> some View {
        let role = rules.roles[binding.roleID]
        let summary = role.map { ResourceTable.ruleSummary($0) }

        return HStack(spacing: 7) {
            ResourceGlyph(
                symbol: (binding.isClusterWide ? ResourceKind.clusterRoleBinding
                    : ResourceKind.roleBinding).symbol,
                size: 26, tint: .secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(binding.name)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(binding.roleLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let summary, !summary.text.isEmpty {
                    // **`*` はいちばん見つけたいもの。** ここだけ色を付ける
                    // （一覧の「できること」列と同じ扱い）。
                    Text(summary.text)
                        .font(.caption2)
                        .foregroundStyle(
                            summary.isWildcard
                                ? Palette.textColor(for: .warning) : .secondary)
                        .lineLimit(2)
                } else if rules.isLoaded && role == nil {
                    // 引けたのに実物が無い＝Binding が指す先が消えている。
                    Text("指しているロールがありません")
                        .font(.caption2)
                        .foregroundStyle(Palette.textColor(for: .serious))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(
            "\(binding.binding.kind?.displayName ?? "") \(binding.name) → \(binding.roleLabel)")
    }

    /// 付属物の帯。見出しの幅を揃えるのは、帯が何本も並ぶため
    /// （ばらばらだと段に見えない）。
    private func band<Content: View>(
        _ title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(minWidth: 104, alignment: .leading)
                .padding(.top, 8)
            content()
            // **`Spacer` で押さない。** タイルの側も伸び縮みするので、
            // どちらが余りを取るかが決まらず 1 列に潰れることがある。
            // 左寄せは外側の frame で決める。
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// **横に並べきれないときは折り返す。** `HStack` のままだと数が増えた
    /// ときに 1 つずつ潰れ、どれも名前が読めなくなる。
    private func tiles<Content: View>(
        minimumWidth: CGFloat = 140, maximumWidth: CGFloat = 240,
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
                    // **ここに `layoutPriority(1)` を戻さない。** かつては
                    // 「幅が足りないと Pod 名から先に潰れる」ので先に幅を
                    // 取らせていた。いまは Pod がタイルになり、`WrappingTiles`
                    // が名前ぶんの幅（下限 150pt）を最小として申告するので、
                    // 潰れようがない。優先度を戻すと、こんどはタイルが
                    // 「1 行に全部」を要求して**左の入口の列を押しのける**。
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
                    // **入口の列にも下限を残す。** 右の Pod の列は幅を
                    // いくらでも使える（1 行に全部並べるのが最大）ので、
                    // 下限が無いとこちらが先に潰れて名前が消える。
                    minWidth: 92,
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
                .frame(minWidth: 88, maxWidth: 120)
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
        HStack(alignment: .center, spacing: 8) {
            WrappingTiles(spacing: 8, lineSpacing: 6) {
                ForEach(group.pods) { pod in
                    TracePodTile(pod: pod, node: group.node)
                }
            }

            DiagramArrow(length: 20)
            node
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
                symbol: ResourceKind.node.symbol, tint: .secondary, size: 26,
                // **行き先の欄は幅の下限を残す。** 無いと、伸び縮みする列の
                // 中でいちばん後ろのこの文字から先に潰れ、名前が消える。
                minWidth: 70, maxWidth: 170,
                isAnchor: target.id == anchor.id, select: { select(target) })
        } else {
            TraceNodeLabel(
                name: "未スケジュール", kindLabel: count,
                symbol: "questionmark.square.dashed", tint: .secondary, size: 26,
                minWidth: 70, maxWidth: 170)
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

        Button {
            // 配置のタイルと同じ入口を通す（`selectedObjectID` を直に
            // 書くと、操作の対象になる集合が空のまま取り残される）。
            store.selectOnly(pod)
        } label: {
            HStack(spacing: 8) {
                ResourceGlyph(symbol: ResourceKind.pod.symbol, size: 30, badge: status.level)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pod.name)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(status.text)
                        .font(.caption2)
                        .foregroundStyle(Palette.textColor(for: status.level))
                }
                // **幅を決め打ちしない。** 210pt に固定していたので、短い
                // 名前でも枠を取り、長い名前は余っているのに中央を落として
                // いた。幅は `WrappingTiles` が名前の長さから決めて段で揃える。
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.accentColor.opacity(0.16) : .clear))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        // 名前は幅が足りないと真ん中を落とすので、全体はここで読めるようにする。
        .help(
            "\(pod.namespace ?? "-")/\(pod.name) · \(status.text) · "
                + "\(node ?? "未スケジュール") · 押すと右のパネルに詳細")
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
    var minimumWidth: CGFloat = 150
    /// 名前が長くてもこれ以上は広げない。あとは中央を落として読ませる。
    var maximumWidth: CGFloat = 280

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let item = itemSize(subviews)
        let columns = columnCount(for: proposal.width, item: item, count: subviews.count)
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
        let item = itemSize(subviews)
        let columns = columnCount(for: bounds.width, item: item, count: subviews.count)
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
