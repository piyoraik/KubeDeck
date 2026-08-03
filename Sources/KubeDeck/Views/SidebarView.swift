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
                        Label(type.displayName, systemImage: "puzzlepiece.extension")
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
    private var customGroups: [(name: String, types: [CustomResourceType])] {
        Dictionary(grouping: store.customTypes, by: \.group)
            .map { (name: $0.key.isEmpty ? "カスタムリソース" : $0.key, types: $0.value) }
            .sorted { $0.name < $1.name }
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
