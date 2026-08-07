import Foundation

/// ワークロードの周りにあるものを、取ってきたオブジェクトから解く。
///
/// **関係は API に無いので、こちら側で結ぶしかない。** Service は
/// `spec.selector` がラベルに一致する Pod を掴み、Ingress は backend の名前で
/// Service を指し、Pod は `volumes[].persistentVolumeClaim` で PVC を使う。
/// どれも「参照」ではなく「一致」なので、片方が消えても静かに外れるだけ。
///
/// **見つからないことを失敗にしない。** Service を持たないワークロードは
/// ふつうにあり、無いことは異常ではない。
enum WorkloadRelations {
    /// この Pod 群を掴んでいる Service。
    ///
    /// **セレクタが空の Service を一致させない。** 空は「すべてに一致」ではなく
    /// 「まだ何も選んでいない」であり、そのまま通すと全部の Service が
    /// どのワークロードにも付いてくる。
    static func services(for pods: [K8sObject], among all: [K8sObject]) -> [K8sObject] {
        guard !pods.isEmpty else { return [] }
        return all
            .filter { $0.kind == .service }
            .filter { service in
                guard let selector = service.spec?["selector"]?.stringDictionary,
                      !selector.isEmpty else { return false }
                return pods.contains { pod in
                    pod.namespace == service.namespace && matches(selector, pod.labels)
                }
            }
            .sorted { $0.name < $1.name }
    }

    /// その Service を指している Ingress。
    static func ingresses(for services: [K8sObject], among all: [K8sObject]) -> [K8sObject] {
        guard !services.isEmpty else { return [] }
        let names = Set(services.map { "\($0.namespace ?? "")/\($0.name)" })
        return all
            .filter { $0.kind == .ingress }
            .filter { ingress in
                backendServiceNames(of: ingress)
                    .contains { names.contains("\(ingress.namespace ?? "")/\($0)") }
            }
            .sorted { $0.name < $1.name }
    }

    /// そのラベルを掴む Service。**Pod が 1 つも無いとき用。**
    ///
    /// レプリカ 0 のワークロードには Pod が無いので、Pod 経由では入口が
    /// 引けない。だが Service は付いたままなので、テンプレートのラベルで
    /// 引き直す。**入口が消えるほうが誤解を生む**（外から繋がっていないように
    /// 見える）ため。
    static func services(
        matching labels: [String: String], namespace: String?, among all: [K8sObject]
    ) -> [K8sObject] {
        guard !labels.isEmpty else { return [] }
        return all
            .filter { $0.kind == .service && $0.namespace == namespace }
            .filter { service in
                guard let selector = service.spec?["selector"]?.stringDictionary,
                      !selector.isEmpty else { return false }
                return matches(selector, labels)
            }
            .sorted { $0.name < $1.name }
    }

    /// その Service が掴んでいる Pod。`services(for:among:)` の逆向き。
    ///
    /// **たどるの起点が Service のときに要る。** 起点から先を出すには
    /// 「この Service はどの Pod を掴んでいるか」を引けないといけない。
    /// 空のセレクタを一致させないのは順方向と同じ理由。
    static func pods(selectedBy service: K8sObject, among pods: [K8sObject]) -> [K8sObject] {
        guard let selector = service.spec?["selector"]?.stringDictionary,
              !selector.isEmpty else { return [] }
        return pods.filter { pod in
            pod.namespace == service.namespace && matches(selector, pod.labels)
        }
    }

    /// その Ingress が指している Service。`ingresses(for:among:)` の逆向き。
    ///
    /// **見つからなかった名前も返す。** Ingress が指しているのに Service が
    /// 無いのは設定の誤りとしてよくあるもので、黙って落とすと
    /// 「Ingress の先に何も無い」ようにしか見えない（無いのか、届いて
    /// いないのかが分からない）。
    static func services(
        of ingress: K8sObject, among all: [K8sObject]
    ) -> (found: [K8sObject], missing: [String]) {
        let namespace = ingress.namespace
        let wanted = backendServiceNames(of: ingress)
        var found: [K8sObject] = []
        var missing: [String] = []
        var seen = Set<String>()

        for name in wanted where seen.insert(name).inserted {
            if let service = all.first(where: {
                $0.kind == .service && $0.namespace == namespace && $0.name == name
            }) {
                found.append(service)
            } else {
                missing.append(name)
            }
        }
        return (found.sorted { $0.name < $1.name }, missing.sorted())
    }

    /// Pod が使っている PVC。
    static func claims(for pods: [K8sObject], among all: [K8sObject]) -> [K8sObject] {
        guard !pods.isEmpty else { return [] }
        var wanted = Set<String>()
        for pod in pods {
            for volume in pod.spec?["volumes"]?.arrayValue ?? [] {
                guard let name = volume.path("persistentVolumeClaim.claimName")?.stringValue
                else { continue }
                wanted.insert("\(pod.namespace ?? "")/\(name)")
            }
        }
        guard !wanted.isEmpty else { return [] }
        return all
            .filter { $0.kind == .persistentVolumeClaim }
            .filter { wanted.contains("\($0.namespace ?? "")/\($0.name)") }
            .sorted { $0.name < $1.name }
    }

    /// この PVC を使っている Pod。**逆引き。**
    ///
    /// `claims(for:)` は「この Pod 群が使っている PVC」を解くが、運用で出る問いは
    /// 逆のほうが多い —— 消してよいか、なぜ Pending なのか、この PV は誰のものか。
    ///
    /// **名前だけで突き合わせない。** PVC は Namespace ごとに別物で、同じ名前が
    /// 別の Namespace に居るのはふつう（StatefulSet が作る `data-web-0` のような
    /// 名前はとくに重なる）。**空の名前で引かない** —— `claimName` が空の
    /// ボリュームと当たって、無関係な Pod を掴む。
    static func pods(
        using claimName: String, namespace: String?, among pods: [K8sObject]
    ) -> [K8sObject] {
        guard !claimName.isEmpty else { return [] }
        return pods.filter { pod in
            guard pod.namespace == namespace else { return false }
            return (pod.spec?["volumes"]?.arrayValue ?? []).contains {
                $0.path("persistentVolumeClaim.claimName")?.stringValue == claimName
            }
        }
    }

    /// PV を掴んでいる PVC。
    ///
    /// **`claimRef` を先に見る。** どの PVC に束ねられたかを書くのはバインドした
    /// コントローラの側で、これが事実。PVC の `spec.volumeName` は人が先に書いて
    /// おくこともある（まだ束ねられていない指名）ので、`claimRef` が無いときだけ
    /// そちらから逆引きする。
    static func claim(boundTo volume: K8sObject, among all: [K8sObject]) -> K8sObject? {
        let claims = all.filter { $0.kind == .persistentVolumeClaim }
        if let reference = claimReference(of: volume) {
            // **見つからないことを「無い」にしない。** ここで volumeName 側の
            // 逆引きに落とすと、Namespace を絞って PVC が手元に無いだけのときに
            // 別の PVC を掴みうる。指している先が引けなかったことは、
            // 呼び出し側が `claimReference` と突き合わせて書き分ける。
            return claims.first {
                $0.namespace == reference.namespace && $0.name == reference.name
            }
        }
        return claims.first {
            let name = $0.spec?["volumeName"]?.stringValue
            return name == volume.name && !volume.name.isEmpty
        }
    }

    /// PV が指している PVC の名前。**実物が引けたかとは別**
    /// （Namespace を絞っていれば、在るのに手元に無いことがある）。
    static func claimReference(
        of volume: K8sObject
    ) -> (namespace: String?, name: String)? {
        guard let reference = volume.spec?["claimRef"],
              let name = reference["name"]?.stringValue, !name.isEmpty
        else { return nil }
        return (reference["namespace"]?.stringValue, name)
    }

    /// PVC と、それが束ねられている PV。
    ///
    /// **PVC の名前だけでは足りない。** 実体がどこにあるのか（容量・
    /// StorageClass）は PV 側にしか無い。
    ///
    /// **未バインドを「PV が無い」と書かない。** `spec.volumeName` が空なのは
    /// 「まだバインドされていない」で、Pod が起動しない原因そのもの。ここも
    /// 「無い」と「取れていない」を混ぜない話で、**3 つある** —
    /// バインド済み（PV あり）/ 未バインド / 束ねた先の PV を引けていない。
    static func storageLinks(for claims: [K8sObject], among all: [K8sObject]) -> [StorageLink] {
        let volumes = all.filter { $0.kind == .persistentVolume }
        return claims.map { claim in
            let name = claim.spec?["volumeName"]?.stringValue
            let volumeName = (name?.isEmpty ?? true) ? nil : name
            return StorageLink(
                claim: claim, volumeName: volumeName,
                volume: volumeName.flatMap { wanted in volumes.first { $0.name == wanted } })
        }
    }

    /// この Pod 群に効いている NetworkPolicy。
    ///
    /// **空のセレクタを Service と同じ扱いにしない。** Service の
    /// `spec.selector` が空なら何も掴まないが、NetworkPolicy の
    /// `spec.podSelector` が空なら**その Namespace のすべての Pod**。
    /// 同じ「空」で意味が正反対なので、ここで取り違えると
    /// **いちばん効きの強い設定を「効いていない」ことにする**。
    static func policies(for pods: [K8sObject], among all: [K8sObject]) -> [K8sObject] {
        guard !pods.isEmpty else { return [] }
        return all
            .filter { $0.kind == .networkPolicy }
            .filter { policy in
                let selector = ResourceTable.policySelector(policy)
                return pods.contains { pod in
                    guard pod.namespace == policy.namespace else { return false }
                    // 空は「すべて」。ここが Service との違い。
                    return selector.isEmpty || matches(selector, pod.labels)
                }
            }
            .sorted { $0.name < $1.name }
    }

    /// Pod が使っている ServiceAccount と、そこに付いている Binding。
    ///
    /// **Pod からは名前しか辿れない。** どの Role が付いているかは Binding の
    /// `subjects` にしか書いていないので、**逆引きになる**。
    ///
    /// **`serviceAccountName` が空でも「無い」にしない。** 省略時は `default`
    /// が使われる（空欄にすると、権限が無いように読める）。
    ///
    /// **グループ経由の付与は見ていない。** `system:serviceaccounts:<ns>` の
    /// ようなグループへの Binding まで拾うと、どの SA にも同じものが並ぶ。
    /// そのぶん、何も見つからないことを「権限が無い」と書かない
    /// （`AccessSummary.note` が断る）。
    ///
    /// **Binding はここで解かない。** `spec.serviceAccountName` は Pod が
    /// すでに持っているので、口座の一覧は kubectl を 1 本も増やさずに作れる。
    /// 逆引きに要る RoleBinding / ClusterRoleBinding は重い（実測で
    /// 併せて 10.4 秒・245KB）ので、**起点が変わったときだけ引く**
    /// （`bindings(for:among:)` / `ClusterStore.serviceAccountBindings`）。
    static func accessSummary(for pods: [K8sObject]) -> AccessSummary {
        guard !pods.isEmpty else { return AccessSummary(accounts: []) }

        var accounts: [AccessAccount] = []
        var seen = Set<String>()

        for pod in pods {
            let account = AccessAccount(
                name: serviceAccountName(of: pod), namespace: pod.namespace)
            guard seen.insert(account.id).inserted else { continue }
            accounts.append(account)
        }
        return AccessSummary(accounts: accounts.sorted { $0.name < $1.name })
    }

    /// 口座ごとに、付いている Binding を逆引きする。
    ///
    /// **鍵は口座の `id`（`Namespace/名前`）。** 同じ名前の ServiceAccount は
    /// Namespace ごとに別物なので、名前だけで束ねると別の SA の権限が付く。
    static func bindings(
        for accounts: [AccessAccount], among all: [K8sObject]
    ) -> [String: [AccessBinding]] {
        let candidates = all.filter {
            $0.kind == .roleBinding || $0.kind == .clusterRoleBinding
        }
        var result: [String: [AccessBinding]] = [:]
        for account in accounts {
            result[account.id] = candidates
                .filter { binds($0, toServiceAccount: account.name, in: account.namespace) }
                .map { AccessBinding(binding: $0) }
                .sorted { $0.binding.name < $1.binding.name }
        }
        return result
    }

    /// Pod が使う ServiceAccount 名。省略時は `default`。
    static func serviceAccountName(of pod: K8sObject) -> String {
        let name = pod.spec?["serviceAccountName"]?.stringValue
            // 古い綴り。いまも API が両方埋める。
            ?? pod.spec?["serviceAccount"]?.stringValue
        return (name?.isEmpty ?? true) ? "default" : name!
    }

    private static func binds(
        _ binding: K8sObject, toServiceAccount name: String, in namespace: String?
    ) -> Bool {
        (binding.raw["subjects"]?.arrayValue ?? []).contains { subject in
            guard subject["kind"]?.stringValue == "ServiceAccount" else { return false }
            guard subject["name"]?.stringValue == name else { return false }
            // **Namespace まで見る。** 同じ名前の ServiceAccount は
            // Namespace ごとに別物で、落とすとどれか決まらない。
            return subject["namespace"]?.stringValue == namespace
        }
    }

    /// Pod と Ingress が参照している ConfigMap / Secret。
    ///
    /// **実物を取りに行かない。** 参照している名前は Pod の spec に全部
    /// 書いてあるので、名前と付き方を出すだけなら kubectl は 1 本も増えない。
    /// 引きに行くのは「実在するか」を言いたいときだけで、そのときは
    /// **Secret が権限で読めない**ことが普通にある（「無い」と「取れていない」を
    /// 混ぜる危険がここで出る）。いまは名前と付き方までにしてある。
    ///
    /// **同じものを何度も出さない。** 8 レプリカは同じ ConfigMap を見るので、
    /// 名前で束ねて付き方だけ足す。
    ///
    /// **ServiceAccount のトークンは出さない。** 1.24 以降は投影ボリュームと
    /// して自動で付くので、どの Pod にも並ぶ。全部に出るものは何も言わない。
    /// API サーバの CA。`kube-api-access-*` の投影として全 Pod に自動で付く。
    private static let automaticRootCAName = "kube-root-ca.crt"

    static func configReferences(
        for pods: [K8sObject], ingresses: [K8sObject] = []
    ) -> [ConfigReference] {
        var found: [ConfigReference.ID: ConfigReference] = [:]
        var order: [ConfigReference.ID] = []

        func add(_ source: ConfigReference.Source, _ name: String?, _ how: ConfigReference.Attachment)
        {
            guard let name, !name.isEmpty else { return }
            let reference = ConfigReference(source: source, name: name, attachments: [how])
            if var existing = found[reference.id] {
                guard !existing.attachments.contains(how) else { return }
                existing.attachments.append(how)
                found[reference.id] = existing
            } else {
                found[reference.id] = reference
                order.append(reference.id)
            }
        }

        for pod in pods {
            for volume in pod.spec?["volumes"]?.arrayValue ?? [] {
                add(.configMap, volume.path("configMap.name")?.stringValue, .volume)
                add(.secret, volume.path("secret.secretName")?.stringValue, .volume)
                // 投影ボリューム。1 つのマウント先に複数を重ねられる。
                for projected in volume.path("projected.sources")?.arrayValue ?? [] {
                    let configMap = projected.path("configMap.name")?.stringValue
                    // **自動で付くものは出さない。** `kube-api-access-*` の中に
                    // ある `kube-root-ca.crt` は、どの Namespace でも
                    // どの Pod にも投影される。並べても何も言っていないうえ、
                    // 本当に参照している設定を帯の外へ押し出す。
                    // **名前だけで落とさない** — 自分でマウントしているなら
                    // それは意図した参照なので、投影の中にあるときだけ。
                    if configMap != Self.automaticRootCAName {
                        add(.configMap, configMap, .volume)
                    }
                    add(.secret, projected.path("secret.name")?.stringValue, .volume)
                }
            }
            // **初期化コンテナも見る。** 設定を取りに行くのは init の仕事という
            // 作りが普通にあり、落とすと参照が丸ごと消える。
            let containers = (pod.spec?["containers"]?.arrayValue ?? [])
                + (pod.spec?["initContainers"]?.arrayValue ?? [])
            for container in containers {
                for source in container["envFrom"]?.arrayValue ?? [] {
                    add(.configMap, source.path("configMapRef.name")?.stringValue, .environment)
                    add(.secret, source.path("secretRef.name")?.stringValue, .environment)
                }
                for variable in container["env"]?.arrayValue ?? [] {
                    add(
                        .configMap,
                        variable.path("valueFrom.configMapKeyRef.name")?.stringValue, .environment)
                    add(
                        .secret,
                        variable.path("valueFrom.secretKeyRef.name")?.stringValue, .environment)
                }
            }
            for pull in pod.spec?["imagePullSecrets"]?.arrayValue ?? [] {
                add(.secret, pull["name"]?.stringValue, .imagePull)
            }
        }

        // 入口の証明書。Pod ではなく Ingress に付くが、**同じ帯に出す** —
        // 見る側の問いは「この一式はどの設定に依っているか」の 1 つ。
        for ingress in ingresses {
            for tls in ingress.spec?["tls"]?.arrayValue ?? [] {
                add(.secret, tls["secretName"]?.stringValue, .ingressTLS)
            }
        }

        return order.compactMap { found[$0] }
            .sorted {
                $0.source == $1.source
                    ? $0.name.localizedStandardCompare($1.name) == .orderedAscending
                    : $0.source.order < $1.source.order
            }
    }

    // MARK: - 中身

    private static func matches(_ selector: [String: String], _ labels: [String: String]) -> Bool {
        selector.allSatisfy { labels[$0.key] == $0.value }
    }

    /// Ingress が指している Service の名前。既定の backend も見る。
    private static func backendServiceNames(of ingress: K8sObject) -> [String] {
        var names: [String] = []
        if let name = ingress.spec?.path("defaultBackend.service.name")?.stringValue {
            names.append(name)
        }
        for rule in ingress.spec?["rules"]?.arrayValue ?? [] {
            for path in rule.path("http.paths")?.arrayValue ?? [] {
                if let name = path.path("backend.service.name")?.stringValue {
                    names.append(name)
                }
            }
        }
        return names
    }
}

/// PVC と、その行き先の PV。
struct StorageLink: Identifiable, Sendable {
    let claim: K8sObject
    /// 束ねられている PV の名前。**nil は「まだバインドされていない」**。
    let volumeName: String?
    /// PV の実物。名前はあるのに nil なら「引けていない」で、無いのとは違う。
    let volume: K8sObject?

    var id: String { claim.id }

    /// PVC 側の見どころ。
    ///
    /// **PV と同じことを書かない。** 容量は PV 側が実物なので、こちらは
    /// 束ねる先が無いときだけ「要求」を出す（そのときは実容量がどこにも無い）。
    ///
    /// **状態は出す。** `Pending` は Pod が起動しない理由そのもので、`Lost` は
    /// 束ねていた PV が消えた状態。どちらも名前を見ただけでは分からない。
    var claimDetail: String {
        var parts = ["PVC"]
        if let phase = claim.status?["phase"]?.stringValue, !phase.isEmpty {
            parts.append(phase)
        }
        if volumeName == nil,
           let requested = claim.spec?.path("resources.requests.storage")?.stringValue,
           !requested.isEmpty {
            parts.append(String(localized: "要求 \(requested)"))
        }
        return parts.joined(separator: " · ")
    }

    /// PV 側の見どころ。容量と StorageClass はここにしか無い。
    ///
    /// **状態を落とさない。** `Released` の PV は、PVC を消したあとも実体と
    /// データが残っている状態で、実運用でいちばんよくある回収漏れ。容量だけ
    /// 出していると、それが分からない。
    var volumeDetail: String? {
        guard let volume else { return nil }
        let capacity = volume.status?.path("capacity.storage")?.stringValue
            ?? volume.spec?.path("capacity.storage")?.stringValue
        let parts = [
            "PV", volume.status?["phase"]?.stringValue, capacity,
            volume.spec?["storageClassName"]?.stringValue,
        ]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }
}

/// Pod が使っている ServiceAccount 1 つ。
///
/// **付いている Binding は持たない。** そちらは引き直して足すもの
/// （`AccessBindings`）。抱えさせると、自動更新のたびに Binding を引くか、
/// 引けていないものを「無い」として運ぶかのどちらかになる。
struct AccessAccount: Identifiable, Sendable, Hashable {
    let name: String
    let namespace: String?

    var id: String { "\(namespace ?? "")/\(name)" }
}

/// RoleBinding / ClusterRoleBinding 1 つと、それが指しているロール。
struct AccessBinding: Identifiable, Sendable {
    let binding: K8sObject

    var id: String { binding.id }
    var name: String { binding.name }
    var isClusterWide: Bool { binding.kind == .clusterRoleBinding }

    var roleKind: String { binding.raw.path("roleRef.kind")?.stringValue ?? "" }
    var roleName: String { binding.raw.path("roleRef.name")?.stringValue ?? "" }
    /// Role は Binding と同じ Namespace のものを指す（ClusterRole は無し）。
    var roleNamespace: String? { roleKind == "ClusterRole" ? nil : binding.namespace }

    /// 引き直した rules を突き合わせるための鍵。
    var roleID: String { "\(roleKind)/\(roleNamespace ?? "")/\(roleName)" }
    var roleLabel: String { roleKind.isEmpty ? roleName : "\(roleKind)/\(roleName)" }
}

/// 引き直したロールの中身。
///
/// **「まだ引いていない」と「規則が無い」と「引けなかった」を混ぜない。**
/// RBAC を読めないクラスタはふつうにあるので、失敗を空と同じ見た目にすると
/// **権限が無いだけなのに「何もできない ServiceAccount」に見える。**
struct AccessRules: Sendable {
    var roles: [String: K8sObject] = [:]
    /// 引けなかったもの（「kube-system の Role」など）。
    var failures: [String] = []
    var isLoaded = false
}

/// 引き直した Binding。**`AccessRules` と同じ 3 分け。**
///
/// **「まだ引いていない」を「Binding が無い」と書かない。** RoleBinding と
/// ClusterRoleBinding は重いので起点が変わったときだけ引く（自動更新に載せない）。
/// 引く前の空と、引いた結果の空を同じ見た目にすると、**読み込み中に
/// 「権限が付いていません」と断定する**ことになる。
struct AccessBindings: Sendable {
    /// 口座の `id` → 付いている Binding。
    var byAccount: [String: [AccessBinding]] = [:]
    /// 引けなかった種別（「RoleBinding」など）。
    var failures: [String] = []
    var isLoaded = false

    func bindings(for account: AccessAccount) -> [AccessBinding] {
        byAccount[account.id] ?? []
    }

    var all: [AccessBinding] { byAccount.values.flatMap { $0 } }
}

/// たどるで見せる「この一式は何の権限で動いているか」。
struct AccessSummary: Sendable {
    let accounts: [AccessAccount]

    var isEmpty: Bool { accounts.isEmpty }
}

/// Pod や Ingress が参照している ConfigMap / Secret 1 つぶん。
///
/// **中身は持たない。** Secret はキー名も値も出さない決まりで、ここで運ぶのは
/// 名前と「どう付いているか」だけ（`Models/SettingsDigest.swift` と同じ扱い）。
struct ConfigReference: Identifiable, Sendable, Hashable {
    enum Source: Sendable, Hashable {
        case configMap
        case secret

        var kind: ResourceKind { self == .configMap ? .configMap : .secret }
        /// ConfigMap を先に出す。Secret のほうが目を引くが、数が多いのは
        /// たいてい ConfigMap のほうで、種別が混ざると読み飛ばしにくい。
        var order: Int { self == .configMap ? 0 : 1 }
    }

    /// どう付いているか。**「参照している」で丸めない** — マウントが欠ければ
    /// Pod は起動できず、環境変数なら中身が変わっても再起動まで効かない。
    /// 見に行く場所が変わるので、付き方まで書く。
    enum Attachment: Sendable, Hashable {
        case volume
        case environment
        case imagePull
        case ingressTLS

        var title: String {
            switch self {
            case .volume: return String(localized: "マウント")
            case .environment: return String(localized: "環境変数")
            case .imagePull: return String(localized: "イメージ取得")
            case .ingressTLS: return String(localized: "Ingress の証明書")
            }
        }
    }

    let source: Source
    let name: String
    /// 1 つのものが複数の付き方をすることがある（マウントもされ、環境変数
    /// にも入っている）。**どちらかに決めない。**
    var attachments: [Attachment]

    var id: String { "\(source.kind.rawValue)/\(name)" }

    /// 「ConfigMap · マウント・環境変数」。
    var detail: String {
        ([source.kind.apiKind] + [attachments.map(\.title).joined(separator: "・")])
            .joined(separator: " · ")
    }
}
