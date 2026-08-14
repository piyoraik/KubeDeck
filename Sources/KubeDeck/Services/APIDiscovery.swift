import Foundation

/// API サーバが知っている 1 種別。
struct APIResource: Sendable, Hashable {
    /// core は空。
    var group: String
    var version: String
    /// `pods` のような複数形。
    var plural: String
    /// `Pod` のような単数形。
    var kind: String
    var namespaced: Bool

    /// `api/v1` か `apis/apps/v1`。
    var basePath: String {
        group.isEmpty ? "api/\(version)" : "apis/\(group)/\(version)"
    }

    /// 一覧を引くパス。
    ///
    /// **Namespace を絞るのは、種別が Namespace を持つときだけ。** 持たない種別に
    /// `/namespaces/x/` を付けると 404 になる（kubectl に `-n` を渡すかどうかを
    /// `ResourceKind.isNamespaced` で分けていたのと同じ判断）。
    func listPath(namespace: String?) -> String {
        guard namespaced, let namespace, !namespace.isEmpty else {
            return "\(basePath)/\(plural)"
        }
        return "\(basePath)/namespaces/\(namespace)/\(plural)"
    }
}

/// アプリが持っている種別名（`pods.v1.` / `deployments` /
/// `poddisruptionbudgets.policy`）を、API のパスに直す。
///
/// **kubectl の discovery キャッシュを当てにしない。** あちらはディスクに持つので、
/// 縮退したファイルが残ると「全種別が見つからない」「Node が NodeMetrics として
/// 返る」という壊れ方をする（CLAUDE.md の未解決の節）。ここでは毎起動ごとに
/// サーバへ聞いて、コンテキストごとにメモリにだけ持つ。**ディスクに書かない。**
actor APIDiscovery {
    static let shared = APIDiscovery()

    /// 集約 discovery（`APIGroupDiscoveryList`）を要求する Accept。
    ///
    /// **効けば 2 本で全部揃う**（実測: `/apis` 18.6KB ＋ `/api` 7.1KB で
    /// 21 グループ・53 リソース。`scope` も入っている）。k8s 1.30 以降。
    /// 古いクラスタは従来の形を返すので、そのときはグループごとに引き直す。
    private static let aggregatedAccept =
        "application/json;g=apidiscovery.k8s.io;v=v2;as=APIGroupDiscoveryList"

    /// 覚えた表と、いつ引いたか。
    ///
    /// **いつまでも覚えない。** クラスタは動く —— metrics-server を後から入れる、
    /// 集約 API サーバが遅れて上がる、CRD を足す。永久に覚えていると
    /// 「その種別は無い」が**そのコンテキストを離れるまで直らない**（実際、
    /// 起動後に metrics-server を入れると `metricsServerAvailable` が false の
    /// まま戻らなくなる）。kubectl の discovery キャッシュも 10 分で切れる。
    private static let tableLifetime: TimeInterval = 10 * 60

    struct Table {
        var entries: [APIResource]
        /// 覚えてよいか。**欠けている表は覚えない**（次の周期で引き直す）。
        var cacheable = true
        /// 引けなかったグループ（`apps/v1` の形）。
        ///
        /// **ここに属する種別を「サーバが知らない」と言わない。** 引けなかった
        /// だけなので、`unknownResource` ではなく `unreachable` として返す。
        var missingGroups: Set<String> = []
        var loadedAt = Date()
    }

    private var tables: [String: Table] = [:]
    private var loading: [String: Task<Table, Error>] = [:]
    /// 捨てた回数。**引いている最中に捨てられたら、その結果を採らない。**
    private var generations: [String: Int] = [:]

    /// 種別名を解いた結果。
    struct Query: Sendable, Equatable {
        var plural: String
        /// `pods.v1.` のように明示されたとき。
        var version: String?
        /// `poddisruptionbudgets.policy` の `policy`。core は空文字、
        /// 指定が無ければ nil（どのグループでも良い）。
        var group: String?
    }

    /// `kubectl` に渡している名前と同じ書式を解く（`resource.version.group`）。
    ///
    /// - `pods.v1.` → 複数形 `pods` / バージョン `v1` / グループ core
    /// - `deployments` → 複数形だけ。グループはサーバに聞いて決める
    /// - `poddisruptionbudgets.policy` → グループ `policy`
    /// - `applications.argoproj.io` → グループ `argoproj.io`（CRD）
    static func parse(_ resourceName: String) -> Query {
        let parts = resourceName.split(separator: ".", omittingEmptySubsequences: false)
            .map(String.init)
        guard let plural = parts.first, !plural.isEmpty else {
            return Query(plural: resourceName, version: nil, group: nil)
        }
        var rest = Array(parts.dropFirst())
        guard !rest.isEmpty else {
            return Query(plural: plural, version: nil, group: nil)
        }
        var version: String?
        if let first = rest.first, isVersion(first) {
            version = first
            rest = Array(rest.dropFirst())
        }
        // `pods.v1.` の末尾の空要素は core を意味する。
        let group = rest.joined(separator: ".")
        return Query(plural: plural, version: version, group: group)
    }

    /// `v1` / `v2beta1` / `v1alpha2` の形。
    ///
    /// **グループ名と取り違えないため、形を決めて見る。** `v1` で始まる
    /// グループ名（`v1.example.com` のような）を版と読むと、パスが崩れる。
    static func isVersion(_ text: String) -> Bool {
        guard text.hasPrefix("v") else { return false }
        var rest = Substring(text.dropFirst())
        let major = rest.prefix { $0.isNumber }
        guard !major.isEmpty else { return false }
        rest = rest.dropFirst(major.count)
        if rest.isEmpty { return true }
        for stage in ["alpha", "beta"] where rest.hasPrefix(stage) {
            let minor = rest.dropFirst(stage.count)
            return !minor.isEmpty && minor.allSatisfy(\.isNumber)
        }
        return false
    }

    // MARK: - 解く

    func resource(
        for resourceName: String, context: String, client: APIClient
    ) async throws -> APIResource {
        let table: [APIResource]
        let missing: Set<String>
        do {
            let loaded = try await self.loadedTable(for: context, client: client)
            table = loaded.entries
            missing = loaded.missingGroups
        } catch let error as APIDiscoveryError {
            throw error
        } catch {
            // **一覧を引けなかったことを、種別の話にしない。**
            throw APIDiscoveryError.unreachable(error)
        }
        let query = Self.parse(resourceName)
        guard let found = Self.match(query, in: table) else {
            throw APIDiscoveryError.unknownResource(resourceName)
        }
        return found
    }

    /// 表から 1 つ選ぶ。
    ///
    /// **グループを指定されたら、それ以外を返さない。** アプリが
    /// `networkpolicies.networking.k8s.io` のようにグループまで書いているのは、
    /// 同じ複数形が別グループにも居るから（Calico の `networkpolicies` など）。
    /// 指定を無視して拾うと、まさにそこで取り違える。
    static func match(_ query: Query, in table: [APIResource]) -> APIResource? {
        var candidates = table.filter { $0.plural == query.plural }
        if let group = query.group {
            candidates = candidates.filter { $0.group == group }
        }
        if let version = query.version {
            candidates = candidates.filter { $0.version == version }
        }
        guard !candidates.isEmpty else { return nil }
        // グループを書いていない名前（`deployments` など）は core を優先し、
        // その次は discovery が並べた順（＝サーバの優先順）に従う。
        if let core = candidates.first(where: { $0.group.isEmpty }) { return core }
        return candidates.first
    }

    /// コンテキストごとの表。**同時に 2 本引かない。**
    func table(for context: String, client: APIClient) async throws -> [APIResource] {
        try await loadedTable(for: context, client: client).entries
    }

    func loadedTable(for context: String, client: APIClient) async throws -> Table {
        if let table = tables[context],
           Date().timeIntervalSince(table.loadedAt) < Self.tableLifetime {
            return table
        }
        if let task = loading[context] { return try await task.value }
        let generation = generations[context] ?? 0
        let task = Task { try await Self.load(client: client) }
        loading[context] = task
        do {
            let table = try await task.value
            if loading[context] == task { loading[context] = nil }
            guard table.cacheable else { return table }
            // **捨てられていたら覚え直さない。** 引いている最中に
            // `invalidate` が走っていたら、この結果はもう古い相手のもの
            // （コンテキストを切り替えた直後にこの窓を踏む）。
            guard generations[context] ?? 0 == generation else { return table }
            tables[context] = table
            return table
        } catch {
            if loading[context] == task { loading[context] = nil }
            // **古い表を落ち先に使う。** 10 分を過ぎて引き直しに失敗しただけで
            // 全種別を「取得できませんでした」にすると、直前まで使えていた表が
            // 手元にあるのに画面が空になる。**捨てるのは「別のクラスタを指した」
            // ときだけ**（`invalidate` が呼ばれたとき）で、期限切れは
            // 「引き直したい」であって「もう信用できない」ではない。
            if let stale = tables[context] { return stale }
            throw error
        }
    }

    /// クラスタを切り替えたら捨てる。
    ///
    /// **他のコンテキストのぶんを残さない理由は無い**が、切り替えのたびに
    /// 引き直すのも無駄なので、コンテキストごとに持つ。kubeconfig を書き換えて
    /// proxy を立て直したときは、こちらも捨てる。
    func invalidate(context: String) {
        tables[context] = nil
        generations[context, default: 0] += 1
        // **走っている取得も止める。** 放っておくと、捨てたはずの表が
        // 完了と同時に覚え直される（世代でも弾くが、無駄に引かせない）。
        loading[context]?.cancel()
        loading[context] = nil
    }

    func invalidateAll() {
        for context in tables.keys { generations[context, default: 0] += 1 }
        for (context, task) in loading {
            task.cancel()
            generations[context, default: 0] += 1
        }
        tables.removeAll()
        loading.removeAll()
    }

    // MARK: - 引いて表を作る

    private static func load(client: APIClient) async throws -> Table {
        // 集約が効くなら 2 本で済む。
        async let core = aggregated(path: "api", client: client)
        async let grouped = aggregated(path: "apis", client: client)
        // **届かないクラスタで段を下りない。** ここを「引けなければ従来の形」
        // として扱っていたら、待ち上限 × 3（集約 2 本 → 従来 2 本）を黙って
        // 待つことになる（実測。8 秒設定で 25.7 秒かかった）。**取れなかったのと、
        // 古い形だったのは別**なので、通信の失敗はそのまま投げる。
        let coreEntries = try await core
        let groupEntries = try await grouped
        // **片方だけで済ませない。** `/api` は集約で読めたのに `/apis` が
        // 従来の形だった、という食い違いをそのまま採ると core しか無い表になり、
        // 「Deployment という種別が無い」に化ける。両方揃ったときだけ使う。
        if !coreEntries.isEmpty, !groupEntries.isEmpty {
            return Table(entries: coreEntries + groupEntries)
        }
        return try await legacy(client: client)
    }

    /// 集約 discovery の形を読む。**従来の形なら空を返し、引けなければ投げる。**
    private static func aggregated(
        path: String, client: APIClient
    ) async throws -> [APIResource] {
        let data = try await client.data(path: path, accept: aggregatedAccept)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [] }
        guard root["kind"]?.stringValue == "APIGroupDiscoveryList" else { return [] }
        var result: [APIResource] = []
        for group in root["items"]?.arrayValue ?? [] {
            let name = group.path("metadata.name")?.stringValue ?? ""
            for version in group["versions"]?.arrayValue ?? [] {
                guard let versionName = version["version"]?.stringValue else { continue }
                for resource in version["resources"]?.arrayValue ?? [] {
                    guard let plural = resource["resource"]?.stringValue else { continue }
                    result.append(APIResource(
                        group: name,
                        version: versionName,
                        plural: plural,
                        kind: resource.path("responseKind.kind")?.stringValue ?? "",
                        namespaced: resource["scope"]?.stringValue == "Namespaced"))
                }
            }
        }
        return result
    }

    /// 従来の discovery（グループごとに 1 本）。
    ///
    /// **優先バージョンだけ引く。** 全バージョンを引くと、`autoscaling` の
    /// v1 と v2 のように併存するぶんだけ往復が増える。アプリが明示している
    /// バージョン（`pods.v1.`）は core なので、これで足りる。
    private static func legacy(client: APIClient) async throws -> Table {
        var groupVersions: [String] = []
        // **引けなかったら投げる。`try?` で流さない。**
        // ここを握りつぶすと、core が引けなかっただけで表から `pods` や
        // `services` が丸ごと落ち、呼び出し側は「サーバがその種別を知らない」
        // と読む（しかも 10 分覚える）。**「取れなかった」を「無い」にしない。**
        let core = try await client.data(path: "api")
        // **復号の失敗も流さない。** 200 で壊れた JSON（縮退したゲートウェイの
        // 応答）を握りつぶすと、`v1` が版一覧に入らないまま先へ進み、
        // **core 抜きの表**ができる（`pods` も `services` も `nodes` も
        // 「サーバが知らない」になる）。
        let coreVersions = try JSONDecoder().decode(JSONValue.self, from: core)
        for version in coreVersions["versions"]?.arrayValue ?? [] {
            if let name = version.stringValue { groupVersions.append(name) }
        }
        let groups = try await client.data(path: "apis")
        let root = try JSONDecoder().decode(JSONValue.self, from: groups)
        for group in root["groups"]?.arrayValue ?? [] {
            if let preferred = group.path("preferredVersion.groupVersion")?.stringValue {
                groupVersions.append(preferred)
            }
        }

        var result: [APIResource] = []
        var failed: [String] = []
        await withTaskGroup(of: (String, [APIResource]?).self) { tasks in
            for groupVersion in groupVersions {
                tasks.addTask {
                    let path = groupVersion.contains("/")
                        ? "apis/\(groupVersion)" : "api/\(groupVersion)"
                    guard let data = try? await client.data(path: path),
                          let list = try? JSONDecoder().decode(JSONValue.self, from: data)
                    else { return (groupVersion, nil) }
                    return (groupVersion, parseResourceList(list, groupVersion: groupVersion))
                }
            }
            for await (groupVersion, entries) in tasks {
                if let entries { result += entries } else { failed.append(groupVersion) }
            }
        }
        guard !result.isEmpty else { throw APIDiscoveryError.empty }
        // **core が欠けた表は使わない。**
        //
        // 「読めたぶんは使う」は、周辺のグループ（metrics.k8s.io の
        // APIService が落ちている、など）を想定した緩和。**core が落ちたら
        // 話が違う** —— Pod も Service も ConfigMap も Secret も Node も
        // 一度に「サーバが知らない」ことになり、画面は断定を出す。
        // そこは緩和せず、表ごと引き直す。
        if failed.contains(where: { !$0.contains("/") }) {
            throw APIDiscoveryError.empty
        }
        // **欠けたまま覚えない。ただし読めたぶんは捨てない。**
        //
        // 集約 API サーバが 1 つ落ちている（`kubectl get apiservices` に
        // AVAILABLE=False がある）のは運用中ふつうに起きる。そこで表ごと
        // 失敗にすると、**画面全部が「取得できません」になる** —— kubectl 経由
        // ではそのグループが欠けるだけだったので、経路を変えたことによる回帰。
        // 逆に欠けた表を 10 分覚えると「その種別は存在しない」と言い続ける。
        // だから**今回限りの表として返し、覚えない。**
        return Table(
            entries: result, cacheable: failed.isEmpty,
            missingGroups: Set(failed.map { $0.contains("/") ? String($0.split(separator: "/")[0]) : "" }))
    }

    static func parseResourceList(_ list: JSONValue, groupVersion: String) -> [APIResource] {
        let parts = groupVersion.split(separator: "/").map(String.init)
        let group = parts.count == 2 ? parts[0] : ""
        let version = parts.last ?? ""
        return (list["resources"]?.arrayValue ?? []).compactMap { resource in
            guard let plural = resource["name"]?.stringValue else { return nil }
            // **サブリソースは入れない**（`pods/log` など）。一覧としては引けない。
            guard !plural.contains("/") else { return nil }
            return APIResource(
                group: group,
                version: version,
                plural: plural,
                kind: resource["kind"]?.stringValue ?? "",
                namespaced: resource["namespaced"]?.boolValue ?? true)
        }
    }
}

enum APIDiscoveryError: LocalizedError {
    case unknownResource(String)
    case empty
    /// 一覧を引く途中の通信の失敗。**種別の話と混ぜない。**
    ///
    /// これを `APIError.notFound` のまま返すと、呼び出し側が
    /// 「サーバがその種別を知らない」と読む（`/api` が 404 を返しただけで、
    /// 要求した種別すべてが「存在しない」ことになる）。
    case unreachable(any Error)

    var errorDescription: String? {
        switch self {
        case .unknownResource(let name):
            // **「無い」と断定しない。** 見分け方のほうを書く（kubectl 経由の
            // `discoveryHint` と同じ判断）。
            return String(localized: """
                \(name) は、このクラスタの API 一覧に見つかりませんでした。
                `kubectl api-resources` に出るか確認してください。
                出るのに見つからない場合は、集約 API サーバ（`kubectl get apiservices` の
                AVAILABLE=False）を確認してください。
                """)
        case .empty:
            return String(localized: "API の一覧を引けませんでした。")
        case .unreachable(let error):
            return error.localizedDescription
        }
    }
}
