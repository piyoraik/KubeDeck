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
