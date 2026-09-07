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
    /// **押しても空振りする種別を、既定で並べ続けない。** 実測（Connect Gateway
    /// 越しの GKE）で、並んでいた 188 種別のうち中身があるのは **71 だけ**で、
    /// 残り 117（62%）は押すと「ありません」しか出なかった。組み込みの種別は
    /// `hidesEmptyKinds` で畳めるのに、ここは件数を見ていなかったので**設定が
    /// 効いていなかった**（そもそも誰も CRD を数えていなかった）。
    ///
    /// **件数が分からないものは隠さない**（組み込みと同じ規則）。数えていない
    /// のに隠すと「まだ分からない」が「使われていない」になる —— kubectl 経路
    /// では 1 つも数えないので、そこでは全部そのまま出る。
    ///
    /// **Namespace を絞っても隠す判断は変えない。** 数えてあるのは全 Namespace の
    /// 件数だが、**全 Namespace で 0 件ならどの Namespace でも 0 件**なので、
    /// この値のままで正しい（件数の表示のほうは `row(for:)` で伏せる）。
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
        guard Preferences.shared.hidesEmptyKinds else { return true }
        guard let count = store.customCounts[type.resourceName] else { return true }
        // いま開いているものは、0 件でも消さない。
        return count > 0 || store.currentTarget?.customType == type
    }

    private func row(for type: CustomResourceType) -> some View {
        HStack {
            Label(type.displayName, systemImage: "puzzlepiece.extension")
            Spacer(minLength: 4)
            // **Namespace を絞っているあいだは出さない。** 数えてあるのは
            // 全 Namespace の件数で（絞るたびに 188 往復を掛け直さないため）、
            // 隣に並ぶ組み込みの数字は絞りに追従する。混ぜると、同じ列に
            // 意味の違う数字が並ぶ。
            if Preferences.shared.showsSidebarCounts, store.selectedNamespace == nil,
               let count = store.customCounts[type.resourceName], count > 0 {
                Text("\(count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
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
