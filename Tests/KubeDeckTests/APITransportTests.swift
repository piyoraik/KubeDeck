import Foundation
import Testing

@testable import KubeDeck

/// 読み取りを常駐 proxy 経由の HTTP に寄せたときに、**壊れても気付きにくい**
/// ところだけを固める。
///
/// - 種別名 → パスの解き方（`pods.v1.` のような kubectl 独特の書式）
/// - グループを指定した種別が、別グループへ流れないこと
/// - 状態コードの読み分け（403 は拒否、404 は「知らない」。**0 件と混ぜない**）
/// - `managedFields` を落としても、ほかの中身が変わらないこと
/// - 待ち受け先の読み取りと、**prefix を文言に載せないこと**
struct APITransportTests {
    // MARK: - 種別名を解く

    @Test func parsesCoreResourceName() {
        let query = APIDiscovery.parse("pods.v1.")
        #expect(query.plural == "pods")
        #expect(query.version == "v1")
        // 末尾の空要素は core（グループ無し）を意味する。
        #expect(query.group == "")
    }

    @Test func parsesBarePlural() {
        let query = APIDiscovery.parse("deployments")
        #expect(query.plural == "deployments")
        #expect(query.version == nil)
        // グループの指定が無い＝サーバに聞いて決める。**core と決め打ちしない。**
        #expect(query.group == nil)
    }

    @Test func parsesGroupedResourceName() {
        let query = APIDiscovery.parse("poddisruptionbudgets.policy")
        #expect(query.plural == "poddisruptionbudgets")
        #expect(query.version == nil)
        #expect(query.group == "policy")
    }

    @Test func parsesCustomResourceName() {
        let query = APIDiscovery.parse("applications.argoproj.io")
        #expect(query.plural == "applications")
        #expect(query.group == "argoproj.io")
        #expect(query.version == nil)
    }

    /// **バージョンらしい形だけをバージョンと読む。** `v1.example.com` のような
    /// グループ名を版と読むと、組み立てたパスが崩れる。
    @Test func tellsVersionFromGroupName() {
        #expect(APIDiscovery.isVersion("v1"))
        #expect(APIDiscovery.isVersion("v2"))
        #expect(APIDiscovery.isVersion("v1beta1"))
        #expect(APIDiscovery.isVersion("v2alpha3"))
        #expect(!APIDiscovery.isVersion("v1beta"))
        #expect(!APIDiscovery.isVersion("volumes"))
        #expect(!APIDiscovery.isVersion("v"))
        #expect(!APIDiscovery.isVersion("argoproj"))

        // `metrics.k8s.io` を「v… 始まり」と取り違えないこと。
        let query = APIDiscovery.parse("nodes.metrics.k8s.io")
        #expect(query.plural == "nodes")
        #expect(query.version == nil)
        #expect(query.group == "metrics.k8s.io")
    }

    // MARK: - パスの組み立て

    @Test func buildsCorePaths() {
        let pods = APIResource(
            group: "", version: "v1", plural: "pods", kind: "Pod", namespaced: true)
        #expect(pods.basePath == "api/v1")
        #expect(pods.listPath(namespace: nil) == "api/v1/pods")
        #expect(pods.listPath(namespace: "kube-system")
                == "api/v1/namespaces/kube-system/pods")
        // 空文字は「すべての Namespace」として扱う（`-n ""` を渡さないのと同じ）。
        #expect(pods.listPath(namespace: "") == "api/v1/pods")
    }

    @Test func buildsGroupedPaths() {
        let deployments = APIResource(
            group: "apps", version: "v1", plural: "deployments",
            kind: "Deployment", namespaced: true)
        #expect(deployments.listPath(namespace: "default")
                == "apis/apps/v1/namespaces/default/deployments")
    }

    /// **Namespace を持たない種別に `/namespaces/…` を付けない。** 付けると 404 に
    /// なる（kubectl に `-n` を渡さないのと同じ判断）。
    @Test func ignoresNamespaceForClusterScoped() {
        let nodes = APIResource(
            group: "", version: "v1", plural: "nodes", kind: "Node", namespaced: false)
        #expect(nodes.listPath(namespace: "kube-system") == "api/v1/nodes")
    }

    // MARK: - 表から選ぶ

    private var table: [APIResource] {
        [
            APIResource(group: "", version: "v1", plural: "pods", kind: "Pod", namespaced: true),
            APIResource(group: "", version: "v1", plural: "nodes", kind: "Node", namespaced: false),
            APIResource(group: "", version: "v1", plural: "events", kind: "Event", namespaced: true),
            APIResource(group: "events.k8s.io", version: "v1", plural: "events",
                        kind: "Event", namespaced: true),
            APIResource(group: "apps", version: "v1", plural: "deployments",
                        kind: "Deployment", namespaced: true),
            APIResource(group: "networking.k8s.io", version: "v1", plural: "networkpolicies",
                        kind: "NetworkPolicy", namespaced: true),
            APIResource(group: "crd.projectcalico.org", version: "v1", plural: "networkpolicies",
                        kind: "NetworkPolicy", namespaced: true),
            APIResource(group: "metrics.k8s.io", version: "v1beta1", plural: "nodes",
                        kind: "NodeMetrics", namespaced: false),
            APIResource(group: "autoscaling", version: "v2", plural: "horizontalpodautoscalers",
                        kind: "HorizontalPodAutoscaler", namespaced: true),
        ]
    }

    /// **グループを書いた種別は、そのグループ以外へ流さない。** 同じ複数形が
    /// 別グループにも居る（Calico の `networkpolicies`）ので、ここを緩めると
    /// まさにそこで取り違える。
    @Test func respectsGroupWhenGiven() {
        let found = APIDiscovery.match(
            APIDiscovery.parse("networkpolicies.networking.k8s.io"), in: table)
        #expect(found?.group == "networking.k8s.io")
    }

    /// **core を優先する。** `nodes` は metrics.k8s.io にも居るので、素の
    /// `nodes` が NodeMetrics に流れると全ノードが Unknown になる（kubectl 経由で
    /// 実際に起きた壊れ方）。
    @Test func prefersCoreForBarePlural() {
        let nodes = APIDiscovery.match(APIDiscovery.parse("nodes"), in: table)
        #expect(nodes?.group == "")
        #expect(nodes?.kind == "Node")

        let events = APIDiscovery.match(APIDiscovery.parse("events"), in: table)
        #expect(events?.group == "")
    }

    @Test func honorsExplicitVersion() {
        let metrics = APIDiscovery.match(APIDiscovery.parse("nodes.metrics.k8s.io"), in: table)
        #expect(metrics?.version == "v1beta1")
        #expect(metrics?.kind == "NodeMetrics")

        // 版まで書いた core の種別。
        let pods = APIDiscovery.match(APIDiscovery.parse("pods.v1."), in: table)
        #expect(pods?.group == "")
        #expect(pods?.version == "v1")
    }

    @Test func returnsNilForUnknownPlural() {
        #expect(APIDiscovery.match(APIDiscovery.parse("hoges"), in: table) == nil)
        // グループが食い違えば見つからない扱い（別グループで代用しない）。
        #expect(APIDiscovery.match(APIDiscovery.parse("pods.apps"), in: table) == nil)
    }

    // MARK: - discovery の応答を読む

    /// 集約 discovery（1.30 以降。実測で `/apis` 1 本に 21 グループ入る）。
    @Test func parsesAggregatedDiscovery() throws {
        let json = """
            {"kind":"APIGroupDiscoveryList","items":[
              {"metadata":{"name":"apps"},"versions":[
                {"version":"v1","resources":[
                  {"resource":"deployments","responseKind":{"kind":"Deployment"},
                   "scope":"Namespaced"},
                  {"resource":"controllerrevisions","responseKind":{"kind":"ControllerRevision"},
                   "scope":"Namespaced"}]}]}]}
            """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value["kind"]?.stringValue == "APIGroupDiscoveryList")
        let group = value["items"]?.arrayValue.first
        #expect(group?.path("metadata.name")?.stringValue == "apps")
    }

    /// 従来の形（`APIResourceList`）。**サブリソースは入れない。**
    @Test func parsesLegacyResourceList() throws {
        let json = """
            {"kind":"APIResourceList","groupVersion":"apps/v1","resources":[
              {"name":"deployments","kind":"Deployment","namespaced":true},
              {"name":"deployments/status","kind":"Deployment","namespaced":true},
              {"name":"deployments/scale","kind":"Scale","namespaced":true}]}
            """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let entries = APIDiscovery.parseResourceList(value, groupVersion: "apps/v1")
        #expect(entries.count == 1)
        #expect(entries.first?.group == "apps")
        #expect(entries.first?.version == "v1")
        #expect(entries.first?.plural == "deployments")
        #expect(entries.first?.namespaced == true)
    }

    @Test func parsesLegacyCoreResourceList() throws {
        let json = """
            {"kind":"APIResourceList","groupVersion":"v1","resources":[
              {"name":"nodes","kind":"Node","namespaced":false}]}
            """
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let entries = APIDiscovery.parseResourceList(value, groupVersion: "v1")
        #expect(entries.first?.group == "")
        #expect(entries.first?.version == "v1")
        #expect(entries.first?.namespaced == false)
    }

    // MARK: - 状態コードの読み分け

    /// **403 を「0 件」にしない。** 拒まれたことを数に混ぜると、権限が無いだけの
    /// 種別が「無い」ことになる（このアプリでいちばん避けたい取り違え）。
    @Test func readsForbiddenStatus() {
        let body = Data("""
            {"kind":"Status","apiVersion":"v1","status":"Failure",
             "message":"secrets is forbidden: User \\"x\\" cannot list resource \\"secrets\\"",
             "reason":"Forbidden","code":403}
            """.utf8)
        let error = APIClient.error(code: 403, body: body)
        guard case .forbidden(let status) = error else {
            Issue.record("403 が forbidden として読めていない")
            return
        }
        #expect(status.reason == "Forbidden")
        #expect(status.message.contains("secrets is forbidden"))
    }

    /// 知っているグループの知らない種別 → `Status` が返る（実測）。
    @Test func readsNotFoundStatus() {
        let body = Data("""
            {"kind":"Status","status":"Failure",
             "message":"the server could not find the requested resource",
             "reason":"NotFound","code":404}
            """.utf8)
        guard case .notFound(let status) = APIClient.error(code: 404, body: body) else {
            Issue.record("404 が notFound として読めていない")
            return
        }
        #expect(status.code == 404)
    }

    /// **知らない API グループでは JSON が来ない**（実測。素のテキストで
    /// `404 page not found`）。ここで投げると、種別 1 つのせいで全部を捨てる。
    @Test func readsPlainTextNotFound() {
        guard case .notFound(let status) = APIClient.error(
            code: 404, body: Data("404 page not found\n".utf8)) else {
            Issue.record("テキストの 404 が読めていない")
            return
        }
        #expect(status.code == 404)
        #expect(status.message == "404 page not found")
        #expect(status.reason.isEmpty)
    }

    @Test func readsConflictAndUnauthorized() {
        guard case .conflict = APIClient.error(code: 409, body: Data()) else {
            Issue.record("409 が conflict として読めていない")
            return
        }
        guard case .unauthorized = APIClient.error(code: 401, body: Data()) else {
            Issue.record("401 が unauthorized として読めていない")
            return
        }
        // 500 番台はどれにも当てはめない（言い換えずに素のまま出す）。
        guard case .status(let status) = APIClient.error(code: 503, body: Data()) else {
            Issue.record("503 が status として読めていない")
            return
        }
        #expect(status.code == 503)
    }

    // MARK: - managedFields を落とす

    /// **落とすのは大きさのためではなく復号の費用のため。** 実測（Pod 39 件、
    /// `K8sObject.list` まで）で 270ms → 135ms。バイト数は 273KB のままでも、
    /// `JSONValue` は節の数だけ `try?` の連鎖を通るので効く。
    @Test func prunesManagedFieldsOnly() throws {
        let json = """
            {"kind":"PodList","apiVersion":"v1","metadata":{"resourceVersion":"9"},
             "items":[
              {"metadata":{"name":"a","namespace":"x","managedFields":[{"manager":"kubelet"}],
                "labels":{"app":"web"}},
               "spec":{"nodeName":"node-a"},"status":{"phase":"Running"}}]}
            """
        let pruned = APIClient.pruned(Data(json.utf8))
        let value = try JSONDecoder().decode(JSONValue.self, from: pruned)
        let item = value["items"]?.arrayValue.first
        #expect(item?.path("metadata.managedFields") == nil)
        // **ほかは 1 つも変えない。**
        #expect(item?.path("metadata.name")?.stringValue == "a")
        #expect(item?.path("metadata.namespace")?.stringValue == "x")
        #expect(item?.path("metadata.labels.app")?.stringValue == "web")
        #expect(item?.path("spec.nodeName")?.stringValue == "node-a")
        #expect(item?.path("status.phase")?.stringValue == "Running")
        #expect(value.path("metadata.resourceVersion")?.stringValue == "9")

        // 落としたあとも K8sObject として読める。
        let objects = try K8sObject.list(from: pruned, assuming: .pod)
        #expect(objects.count == 1)
        #expect(objects.first?.name == "a")
    }

    /// 単体取得（items が無い形）でも落とす。
    @Test func prunesSingleObject() throws {
        let json = """
            {"kind":"Pod","metadata":{"name":"a","managedFields":[{"manager":"x"}]}}
            """
        let value = try JSONDecoder().decode(
            JSONValue.self, from: APIClient.pruned(Data(json.utf8)))
        #expect(value.path("metadata.managedFields") == nil)
        #expect(value.path("metadata.name")?.stringValue == "a")
    }

    /// **読めなかったら元のまま返す。** ここで投げると「取れているのに取れて
    /// いないことにする」になる。
    @Test func keepsUnparsableBodyIntact() {
        let broken = Data("これは JSON ではない".utf8)
        #expect(APIClient.pruned(broken) == broken)
        let list = Data("[1,2,3]".utf8)
        #expect(APIClient.pruned(list) == list)
    }

    // MARK: - 一覧の kind を確かめる

    /// **別の道で流れてきたら気付く。** kubectl 経由では縮退した discovery が
    /// `nodes` を NodeMetrics で返した（exit 0・stderr 空・valid JSON なので
    /// 既存の網が 1 つも発火しなかった）。HTTP でもパス以外の経路で食い違ったら
    /// 「取れていない」として扱う。
    @Test func rejectsUnexpectedListKind() {
        let nodes = APIResource(
            group: "", version: "v1", plural: "nodes", kind: "Node", namespaced: false)
        let wrong = Data(#"{"kind":"NodeMetricsList","items":[]}"#.utf8)
        #expect(throws: K8sObject.UnexpectedKind.self) {
            try Kubectl.verifyListKind(wrong, resource: nodes, requested: .node)
        }
        let right = Data(#"{"kind":"NodeList","items":[]}"#.utf8)
        #expect(throws: Never.self) {
            try Kubectl.verifyListKind(right, resource: nodes, requested: .node)
        }
    }

    /// **突き合わせる相手が無いときは見ない。** CRD は discovery から単数形が
    /// 取れないことがあり、そこで投げると「取れていない」に化ける。
    @Test func skipsVerificationWithoutExpectedKind() {
        let unknown = APIResource(
            group: "argoproj.io", version: "v1alpha1", plural: "applications",
            kind: "", namespaced: true)
        #expect(throws: Never.self) {
            try Kubectl.verifyListKind(
                Data(#"{"kind":"ApplicationList","items":[]}"#.utf8),
                resource: unknown, requested: nil)
        }
        // kind が空の応答も通す（単体取得で kind を入れてこない版がある）。
        let pods = APIResource(
            group: "", version: "v1", plural: "pods", kind: "Pod", namespaced: true)
        #expect(throws: Never.self) {
            try Kubectl.verifyListKind(
                Data(#"{"items":[]}"#.utf8), resource: pods, requested: .pod)
        }
    }

    // MARK: - metadata だけの応答

    /// **踏んだバグ。** metadata だけで引くと items の `kind` は
    /// `PartialObjectMetadata` になるので、要求種別と 1 件ずつ突き合わせると
    /// 全部弾かれる。概要とサイドバーで、metadata だけ引いた 10 種別の件数が
    /// **そろって空欄になった**（画面は失敗にならないので、黙って消える）。
    @Test func readsPartialObjectMetadataList() throws {
        // 実物の形（Connect Gateway 越しの GKE で撮ったもの）。
        let json = """
            {"kind":"PartialObjectMetadataList","apiVersion":"meta.k8s.io/v1",
             "metadata":{"resourceVersion":"872"},
             "items":[
               {"kind":"PartialObjectMetadata","apiVersion":"meta.k8s.io/v1",
                "metadata":{"name":"a","namespace":"x","uid":"u1",
                            "creationTimestamp":"2026-08-13T00:00:00Z",
                            "managedFields":[{"manager":"kubelet"}]}},
               {"kind":"PartialObjectMetadata","apiVersion":"meta.k8s.io/v1",
                "metadata":{"name":"b","namespace":"y","uid":"u2",
                            "creationTimestamp":"2026-08-13T00:00:00Z"}}]}
            """
        let objects = try K8sObject.metadataList(
            from: APIClient.pruned(Data(json.utf8)), assuming: .secret)
        #expect(objects.count == 2)
        // **数えられること**がこの経路の目的。`assuming:` で要求種別に補われる。
        #expect(objects.allSatisfy { $0.kind == .secret })
        #expect(objects.map(\.name) == ["a", "b"])
        #expect(objects.first?.namespace == "x")
        // 中身は無い。**それでよい経路にだけ使う。**
        #expect(objects.first?.spec == nil)
        #expect(objects.first?.status == nil)

        // 素の `list` は（これまでどおり）食い違いとして弾く。
        #expect(throws: K8sObject.UnexpectedKind.self) {
            try K8sObject.list(from: Data(json.utf8), assuming: .secret)
        }
    }

    /// List の `kind` の確かめは、**頼んだときだけ**通す。
    @Test func acceptsPartialListOnlyWhenAsked() {
        let secrets = APIResource(
            group: "", version: "v1", plural: "secrets", kind: "Secret", namespaced: true)
        let body = Data(#"{"kind":"PartialObjectMetadataList","items":[]}"#.utf8)
        #expect(throws: Never.self) {
            try Kubectl.verifyListKind(
                body, resource: secrets, requested: .secret, metadataOnly: true)
        }
        // 頼んでいないのに来たら、これまでどおり「取れていない」として扱う。
        #expect(throws: K8sObject.UnexpectedKind.self) {
            try Kubectl.verifyListKind(
                body, resource: secrets, requested: .secret, metadataOnly: false)
        }
    }

    // MARK: - 取れなかった種別

    /// **「取れなかった」を「0 件」にしない。**
    ///
    /// 種別ごとに引くようになって初めて起きる形。kubectl にまとめて渡していた
    /// ときは、失敗すれば呼び出し全体が投げるので「一部だけ落ちる」が無かった。
    /// HTTP は種別ごとに独立して失敗するので、`failed` に入れておかないと
    /// 呼び出し側が `uncounted` に無い種別を 0 で埋めてしまう。
    @Test func failedKindsAreNotCounted() {
        var list = Kubectl.PartialList()
        list.objects = []
        list.denied = [.secret]
        list.unknown = [.ingress]
        list.failed = [.pod]
        // 数えてはいけない種別に、3 つとも入ること。
        #expect(Set(list.uncounted) == Set([.secret, .ingress, .pod]))
        // 拒否とは別に持つこと（見に行く場所が違う）。
        #expect(list.isDenied)
        #expect(!list.failed.contains(.secret))
    }

    // MARK: - ページ送り

    /// **続きの目印が進まない相手に、無限に問い続けない。**
    /// ただし「41 ページで黙って切る」もしない —— 2 万件を超えるクラスタで
    /// 一覧を途中まで出して全部だと言うことになる。
    @Test func stopsWhenContinueTokenDoesNotAdvance() {
        let page = Data(#"{"kind":"PodList","metadata":{"continue":"same"},"items":[]}"#.utf8)
        #expect(APIClient.continueToken(in: page) == "same")
        // 空の目印は「終わり」として読む（`""` を続きと解釈しない）。
        let last = Data(#"{"kind":"PodList","metadata":{"continue":""},"items":[]}"#.utf8)
        #expect(APIClient.continueToken(in: last) == nil)
        // JSON でない応答でも落ちない。
        #expect(APIClient.continueToken(in: Data("404 page not found".utf8)) == nil)
    }

    // MARK: - 失敗の読み分け

    /// **一過性の discovery 失敗を「その種別は無い」にしない。**
    ///
    /// `unknownResource` は「表に無い」＝サーバが知らない。`empty` は
    /// 「一覧そのものを引けなかった」で、次の周期では取れるかもしれない。
    /// 混ぜると、届かなかっただけで全種別に
    /// 「クラスタに見つかりませんでした」と書くことになる。
    @Test func tellsUnknownResourceFromEmptyDiscovery() {
        let unknown = APIDiscoveryError.unknownResource("hoges.example.com")
        let empty = APIDiscoveryError.empty
        #expect(unknown.errorDescription?.contains("api-resources") == true)
        #expect(empty.errorDescription?.contains("api-resources") != true)
        // 型として別に受けられること（`catch APIDiscoveryError.unknownResource`）。
        switch unknown {
        case .unknownResource: break
        case .empty, .unreachable:
            Issue.record("unknownResource が別のものとして読まれた")
        }
    }

    /// 通信の失敗には proxy の文言を添える。**403 / 404 には添えない**
    /// （応答そのものが理由を言っているので、古い行を足すと読み違える）。
    @Test func composesTransportErrorMessage() {
        let composed = TransportError(
            summary: "8 秒待っても API サーバから応答がありませんでした。",
            detail: "gke-gcloud-auth-plugin: ERROR: …")
        let text = composed.errorDescription ?? ""
        // **言い換えを先に置く**（帯は最初の段落しか見出しに出さない）。
        #expect(text.hasPrefix("gke-gcloud-auth-plugin"))
        #expect(text.contains("8 秒待っても"))
        // 添えるものが無ければ、元の文言だけ。
        #expect(TransportError(summary: "そのまま", detail: "").errorDescription == "そのまま")
    }

    // MARK: - 失敗の文言

    /// **同じ段落を 2 度出さない。** 言い換え（`Kubectl.explain`）は元の文言を
    /// 末尾に残す作りなので、そのまま繋ぐと同じ文が並ぶ（403 の対処を
    /// 添えたときに実際そうなった）。
    @Test func doesNotRepeatTheOriginalMessage() {
        let original = "secrets is forbidden: User \"x\" cannot list resource \"secrets\""
        let hinted = "権限が足りません。…\n\n\(original)"
        let composed = TransportError(summary: original, detail: hinted)
        #expect(composed.errorDescription == hinted)

        // 含まれていなければ、これまでどおり続けて出す。
        let separate = TransportError(summary: "8 秒待っても…", detail: "gke-…: ERROR")
        #expect(separate.errorDescription == "gke-…: ERROR\n\n8 秒待っても…")

        // 添えるものが無ければ元の文言だけ。
        #expect(TransportError(summary: "そのまま", detail: "").errorDescription == "そのまま")
    }

    /// 立て直しの間隔中に覚えている理由は、**整形済みなので包み直さない**。
    @Test func doesNotDoublePrefixRememberedFailures() {
        let remembered = ClusterProxyError.remembered("kubectl proxy を立ち上げられませんでした。exec: …")
        #expect(remembered.errorDescription == "kubectl proxy を立ち上げられませんでした。exec: …")

        // これから整形するほうは、前置きが付く。
        let fresh = ClusterProxyError.unavailable("畳まれました。")
        #expect(fresh.errorDescription?.contains("kubectl proxy を立ち上げられませんでした") == true)
    }

    // MARK: - List の kind の検め

    /// **CRD の List 名を `<単数形>List` と決め打ちしない。**
    ///
    /// `names.listKind` は自由に付けられる（`kind: Widget` に
    /// `listKind: WidgetCollection` は正当）。決め打ちで弾くと、そういう CRD の
    /// 一覧が丸ごと「取得できていない」に化けて**1 件も出ない** —— 取れて
    /// いるものを取れていないことにする、いちばん避けたい間違い。
    @Test func acceptsCustomListKindForCRDs() throws {
        let widget = APIResource(group: "kubedeck.test", version: "v1alpha1",
                                 plural: "widgets", kind: "Widget", namespaced: true)
        // `listKind` は自由に付けられる。**`List` で終わる必要すら無い。**
        for kind in ["WidgetCollection", "WidgetList", "Widgets"] {
            #expect(throws: Never.self) {
                try Kubectl.verifyListKind(
                    Data(#"{"kind":"\#(kind)","items":[]}"#.utf8),
                    resource: widget, requested: nil)
            }
        }
    }

    /// 組み込み種別は**厳密なまま**。`nodes` が NodeMetrics に流れたのを
    /// 捕まえるのがこの網の役目なので、そこを緩めない。
    @Test func staysStrictForBuiltinKinds() {
        let node = APIResource(group: "", version: "v1", plural: "nodes",
                               kind: "Node", namespaced: false)
        #expect(throws: Never.self) {
            try Kubectl.verifyListKind(
                Data(#"{"kind":"NodeList","items":[]}"#.utf8),
                resource: node, requested: .node)
        }
        // `*List` で終わっていても、要求と違えば弾く。
        #expect(throws: (any Error).self) {
            try Kubectl.verifyListKind(
                Data(#"{"kind":"NodeMetricsList","items":[]}"#.utf8),
                resource: node, requested: .node)
        }
    }

    // MARK: - 引けなかったグループ

    /// **引けなかったグループの種別を「無い」と言わない。**
    ///
    /// 集約 API サーバが 1 つ落ちている（`AVAILABLE=False`）のは運用中ふつうに
    /// 起きる。そのグループの種別を `unknownResource` にすると、画面は
    /// 「クラスタに見つかりませんでした。`kubectl api-resources` に出るかを
    /// 確かめてください」と**断定**する。
    @Test func keepsMissingGroupsOutOfUnknown() {
        let table = APIDiscovery.Table(
            entries: [
                APIResource(group: "", version: "v1", plural: "pods",
                            kind: "Pod", namespaced: true),
            ],
            isComplete: false,
            missingGroups: ["metrics.k8s.io"])
        // 引けたものは引ける。
        #expect(APIDiscovery.match(APIDiscovery.parse("pods.v1."), in: table.entries) != nil)
        // 引けなかったグループの種別は、表に無い。
        #expect(APIDiscovery.match(
            APIDiscovery.parse("nodes.metrics.k8s.io"), in: table.entries) == nil)
        // **その「無い」を種別の話にしない**のが `resource(...)` の役目
        // （欠けたグループに属するなら `empty`、そうでなければ
        // `unknownResource`）。ここでは印が立っていることだけを見る。
        #expect(table.missingGroups.contains("metrics.k8s.io"))
        #expect(!table.isComplete)
    }

    /// **欠けた表も覚える。ただし短く。**
    ///
    /// 「欠けているから覚えない」にすると、`metrics.k8s.io` の APIService が
    /// 登録されたまま metrics-server が落ちている（ふつうに起きる）あいだ
    /// **一度も覚えられない** —— 従来 discovery はグループごとに 1 本引くので、
    /// 10 秒ごとの自動更新のたびに 25 往復することになる。しかも
    /// `tables[context]` が空のままなので「引き直して確かめる」が
    /// **一度も働かない**（`loadedAt` が無い）。
    @Test func shortensLifetimeInsteadOfRefusingToCache() {
        let whole = APIDiscovery.Table(entries: [], isComplete: true)
        let partial = APIDiscovery.Table(entries: [], isComplete: false,
                                         missingGroups: ["metrics.k8s.io"])
        #expect(whole.lifetime == 10 * 60)
        #expect(partial.lifetime == 60)
        // **0 にしない**（＝毎回引き直す、が「覚えない」の実体）。
        #expect(partial.lifetime > 0)
        #expect(partial.lifetime < whole.lifetime)
    }

    /// **集約 discovery の `freshness` を読み飛ばさない。**
    ///
    /// 集約 API サーバが応答しなかったグループは、落ちるのではなく
    /// `freshness: "Stale"` が付いて返る（KEP-3352）。読み飛ばすと、そこの
    /// 種別は「表に無い」＝ `unknownResource` になり、画面は
    /// 「クラスタに見つかりませんでした」と断定する。しかも集約は
    /// k8s 1.30 以降の**主たる経路**。
    @Test func marksStaleAggregatedGroups() throws {
        let json = """
        {"kind":"APIGroupDiscoveryList","items":[
          {"metadata":{"name":"apps"},"versions":[{"version":"v1","freshness":"Current",
            "resources":[{"resource":"deployments","responseKind":{"kind":"Deployment"},
                          "scope":"Namespaced"}]}]},
          {"metadata":{"name":"metrics.k8s.io"},"versions":[{"version":"v1beta1",
            "freshness":"Stale","resources":[]}]}
        ]}
        """
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let parsed = APIDiscovery.parseAggregated(root)
        #expect(parsed.entries.count == 1)
        #expect(parsed.entries.first?.plural == "deployments")
        // 落ちているグループには印が立ち、健全なほうには立たない。
        #expect(parsed.stale == ["metrics.k8s.io"])
    }

    /// **`freshness` を書いていない版で、印を立てない。** この形を返す最初期の
    /// サーバには項目そのものが無い。無いことを「古い」と読むと、健全な
    /// クラスタで表がずっと「欠けている」扱いになる。
    @Test func treatsAbsentFreshnessAsCurrent() throws {
        let json = """
        {"kind":"APIGroupDiscoveryList","items":[
          {"metadata":{"name":""},"versions":[{"version":"v1",
            "resources":[{"resource":"pods","responseKind":{"kind":"Pod"},
                          "scope":"Namespaced"}]}]}
        ]}
        """
        let root = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let parsed = APIDiscovery.parseAggregated(root)
        #expect(parsed.entries.count == 1)
        #expect(parsed.stale.isEmpty)
    }

    // MARK: - 待ち受け先の読み取り

    /// `kubectl proxy` の 1 行目から待ち受け先を取る。手元の v1.32.13 と v1.36.2 は
    /// どちらも `Starting to serve on 127.0.0.1:64073`（実測）。
    @Test func parsesListenAddress() {
        #expect(ClusterProxy.Instance.parseAddress("Starting to serve on 127.0.0.1:64073")
                == "127.0.0.1:64073")
        // 大文字小文字を決め打ちしない。
        #expect(ClusterProxy.Instance.parseAddress("starting to serve on 127.0.0.1:1")
                == "127.0.0.1:1")
        // unix ソケットのときはポートが無いので受けない（URLSession では喋れない）。
        #expect(ClusterProxy.Instance.parseAddress("Starting to serve on ./p.sock") == nil)
        #expect(ClusterProxy.Instance.parseAddress("Error while proxying request: …") == nil)
        #expect(ClusterProxy.Instance.parseAddress("Starting to serve on ") == nil)
    }

    /// **prefix を外へ出さない。** `URLError.localizedDescription` には失敗した
    /// URL がそのまま入る（実測）ので、文言に載せる前に落とす。
    @Test func redactsSecretFromMessages() {
        let endpoint = ClusterProxy.Endpoint(
            baseURL: URL(string: "http://127.0.0.1:5000/deadbeefdeadbeef")!,
            secret: "deadbeefdeadbeef")
        let raw = """
            could not connect to http://127.0.0.1:5000/deadbeefdeadbeef/api/v1/pods
            """
        let redacted = endpoint.redacting(raw)
        #expect(!redacted.contains("deadbeefdeadbeef"))
        #expect(redacted.contains("http://127.0.0.1:5000/…/api/v1/pods"))
    }

    @Test func buildsURLWithEncodedQuery() {
        let endpoint = ClusterProxy.Endpoint(
            baseURL: URL(string: "http://127.0.0.1:5000/abc")!, secret: "abc")
        let url = endpoint.url(
            path: "api/v1/namespaces/kube-system/events",
            query: [URLQueryItem(name: "fieldSelector",
                                 value: "involvedObject.uid=1234-5678")])
        // `=` は値の中に残るが、`&` や空白が混ざっても壊れない形で組む。
        #expect(url?.absoluteString
                == "http://127.0.0.1:5000/abc/api/v1/namespaces/kube-system/events"
                + "?fieldSelector=involvedObject.uid%3D1234-5678")
    }

    /// `continue` を読み落とすと、2 ページ目以降が黙って消える。
    @Test func readsContinueToken() {
        let page = Data(#"{"kind":"PodList","metadata":{"continue":"abc","resourceVersion":"1"}}"#.utf8)
        #expect(APIClient.continueToken(in: page) == "abc")
        let last = Data(#"{"kind":"PodList","metadata":{"resourceVersion":"1"}}"#.utf8)
        #expect(APIClient.continueToken(in: last) == nil)
    }
}
