import SwiftUI

struct SidebarView: View {
    @Environment(ClusterStore.self) private var store

    var body: some View {
        @Bindable var store = store

        List(selection: $store.selection) {
            Section {
                Label("概要", systemImage: "square.grid.2x2")
                    .tag(ClusterStore.Selection.overview)
                // 種別の一覧ではないので、クラスタの節には入れず概要の隣に置く。
                Label("配置", systemImage: "rectangle.3.group")
                    .tag(ClusterStore.Selection.placement)
            }

            ForEach(ResourceCategory.allCases) { category in
                let kinds = visibleKinds(in: category)
                if !kinds.isEmpty {
                    Section(category.title) {
                        ForEach(kinds) { kind in
                            row(for: kind)
                                .tag(ClusterStore.Selection.kind(kind))
                        }
                    }
                }
            }

            // CRD は API グループごとにまとめる。クラスタによっては
            // 数十種あり、平らに並べると組み込みの種別が埋もれる。
            ForEach(Preferences.shared.showsCustomResources ? customGroups : [], id: \.name) { group in
                Section(group.name) {
                    ForEach(group.types) { type in
                        row(for: type)
                            .tag(ClusterStore.Selection.resource(.custom(type)))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // safeAreaInset だと下端がリストの最後の行に重なる。
        // 一段の枠として積み、重なりを作らない。
        .overlay(alignment: .bottom) { footer }
    }

    /// 出す種別。設定で隠したものと、望まれれば件数 0 のものを落とす。
    ///
    /// **件数が分からないものは隠さない。** 概要を読む前は件数が無く、
    /// 未取得を 0 とみなすと種別そのものが消えたように見える。
    private func visibleKinds(in category: ResourceCategory) -> [ResourceKind] {
        ResourceKind.kinds(in: category).filter { kind in
            guard Preferences.shared.isVisible(kind) else { return false }
            guard Preferences.shared.hidesEmptyKinds else { return true }
            guard let count = store.overview.counts[kind] else { return true }
            // いま開いているものは、0 件でも消さない。
            return count > 0 || store.currentKind == kind
        }
    }

    /// API グループごとにまとめた CRD。グループ名の昇順。
    ///
    /// **押しても空振りする種別を、既定で並べない。** 実測（Connect Gateway
    /// 越しの GKE）で、並んでいた 188 種別のうち中身があるのは **71 だけ**で、
    /// 残り 117（62%）は押すと「ありません」しか出なかった。
    ///
    /// **`hidesEmptyKinds` に相乗りさせない**（`hidesUnusedCustomResources`）。
    /// 一度そうしたが、あちらは既定 off なので**既定のままでは 1 つも畳まれず、
    /// 当の問題が直っていなかった**（画面を撮って気付いた。Namespace を絞って
    /// いると件数も伏せるので、見た目が変更前と完全に同じだった）。
    ///
    /// **件数が分からないものは隠さない**（組み込みと同じ規則）。数えていない
    /// のに隠すと「まだ分からない」が「使われていない」になる —— kubectl 経路
    /// では 1 つも数えないので、そこでは全部そのまま出る。
    ///
    /// **Namespace を絞っても隠す判断は変えない。** 数えてあるのは全 Namespace の
    /// 件数だが、**全 Namespace で 0 件ならどの Namespace でも 0 件**なので、
    /// この値のままで正しい。
    private var customGroups: [(name: String, types: [CustomResourceType])] {
        Dictionary(grouping: store.customTypes.filter(isVisible), by: \.group)
            .map {
                (name: $0.key.isEmpty
                    ? String(localized: "カスタムリソース") : $0.key,
                 types: $0.value)
            }
            .sorted { $0.name < $1.name }
    }

    private func isVisible(_ type: CustomResourceType) -> Bool {
        guard Preferences.shared.hidesUnusedCustomResources else { return true }
        guard let count = store.customCounts[type.resourceName] else { return true }
        // いま開いているものは、0 件でも消さない。
        return count > 0 || store.currentTarget?.customType == type
    }

    private func row(for type: CustomResourceType) -> some View {
        HStack {
            Label(type.displayName, systemImage: "puzzlepiece.extension")
            Spacer(minLength: 4)
            if Preferences.shared.showsSidebarCounts,
               let count = store.customCounts[type.resourceName], count > 0 {
                countLabel(count)
            }
        }
    }

    /// CRD の件数。
    ///
    /// **Namespace を絞っていても出す。** 一度は伏せていた（数えてあるのは
    /// 全 Namespace の件数なので、絞りに追従する組み込みの数字と意味が違う）が、
    /// **絞って使う人には件数が 1 つも出ないことになり**、そのほうが害が
    /// 大きかった（実測の画面で、kube-system を選んでいると CRD の列が
    /// まるごと数字なしだった）。
    ///
    /// **そのかわり黙らない。** 絞っているときだけツールチップで断る
    /// （絞っていなければ組み込みと同じ意味なので、断りは要らない）。
    @ViewBuilder
    private func countLabel(_ count: Int) -> some View {
        let label = Text("\(count)")
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        if store.selectedNamespace == nil {
            label
        } else {
            label.help("クラスタ全体の件数です（Namespace で絞っても変わりません）")
        }
    }

    private func row(for kind: ResourceKind) -> some View {
        HStack {
            Label(kind.displayName, systemImage: kind.symbol)
            Spacer(minLength: 4)
            // 概要を一度でも読めていれば件数が分かる。Namespace を絞ると
            // その範囲の件数になるので、サイドバーだけ見て規模が掴める。
            if Preferences.shared.showsSidebarCounts,
               let count = store.overview.counts[kind], count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if !store.currentContext.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                Text(
                    store.serverVersion.isEmpty
                        ? store.currentContext
                        // serverVersion は "v1.34.8+orb1" のように v から始まる。
                        // ここで v を足すと "vv1.34.8" になる。
                        : "\(store.currentContext) · \(store.serverVersion)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
            .background(.bar)
        }
    }
}
