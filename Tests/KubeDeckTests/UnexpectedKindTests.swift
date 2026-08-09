import Foundation
import Testing

@testable import KubeDeck

/// 覚えている API の一覧が縮退していると、kubectl は core の複数形を**同じ
/// 複数形を持つ別グループ**へ黙って流す。実測（Connect Gateway 越しの GKE、
/// kubectl v1.32.13、コアグループが `{"name":"","versions":null}` の状態）:
///
/// ```
/// $ kubectl get nodes -o json          → exit=0  items = NodeMetrics 3
/// $ kubectl get pods,nodes -o json     → exit=0  items = PodMetrics 185 + NodeMetrics 3
/// $ kubectl get nodes.v1. -o json      → exit=0  items = Node 3
/// ```
///
/// **exit 0・stderr 空・valid JSON** なので、`doesn't have a resource type` を
/// 見ている既存の網は 1 つも発火しない。NodeMetrics は `status.conditions` も
/// `status.allocatable` も持たないので、Node として読むと**全ノードが
/// `Unknown`（橙）になり、割り当て可能量が 0 になって使用量が消える。**
///
/// ここで固めるのは 2 つ。**種別名に版とグループを付けること**（そもそも
/// 流れないようにする）と、**流れてきたら投げること**（次に別の道で流れても
/// 「取れていない」として出す）。
@Suite("要求した種別と食い違う応答")
struct UnexpectedKindTests {

    // MARK: - 種別名

    /// 実際に別グループへ流れた 3 つ。`metrics.k8s.io` に `pods` と `nodes`、
    /// `events.k8s.io` に `events` が居る。
    @Test("同じ複数形が別グループにも居る core の種別は、版まで固定する")
    func collidingCoreKindsArePinned() {
        #expect(ResourceKind.node.resourceName == "nodes.v1.")
        #expect(ResourceKind.pod.resourceName == "pods.v1.")
        #expect(ResourceKind.event.resourceName == "events.v1.")
    }

    /// **1 つだけ直して済ませない。** 流れる条件は「同じ複数形が別グループにも
    /// ある」ことだけで、それは CRD やアドオンが入るたびに増える。core は
    /// v1 しか無いので、版まで書いても環境で別のものを引く余地は無い。
    @Test("core グループの種別はすべてグループを明示する")
    func everyCoreKindCarriesItsGroup() {
        let core: [ResourceKind] = [
            .pod, .service, .configMap, .secret, .persistentVolumeClaim,
            .serviceAccount, .resourceQuota, .limitRange, .persistentVolume,
            .node, .namespace, .event,
        ]
        for kind in core {
            #expect(kind.resourceName.hasSuffix(".v1."),
                    "\(kind.resourceName) に core グループの明示が無い")
        }
    }

    /// **付けても突き合わせは壊れない。** `deniedKinds` / `unknownKinds` は
    /// stderr と要求側の**両方から**グループを落としてから比べる。実測で
    /// kubectl は `get hoges.v1.` に対しても `"hoges"` としか書かない
    /// （版もグループも落ちる）。
    @Test("グループを明示しても、拒まれた種別を拾えなくならない")
    func pinnedNamesStillMatchStderr() {
        let stderr = """
            Error from server (Forbidden): secrets is forbidden: User "u" cannot list \
            resource "secrets" in API group "" at the cluster scope
            Error from server (Forbidden): nodes.metrics.k8s.io is forbidden: ...
            """
        let denied = Kubectl.deniedKinds(in: stderr, among: [.secret, .node, .pod])
        #expect(Set(denied) == Set([.secret, .node]))
    }

    @Test("グループを明示しても、知らない種別を拾えなくならない")
    func pinnedNamesStillMatchUnknown() {
        let stderr = #"error: the server doesn't have a resource type "pods""#
        #expect(Kubectl.unknownKinds(in: stderr, among: [.pod, .node]) == [.pod])
    }

    // MARK: - 応答の検証

    /// 実際に返っていた NodeMetrics（`status` も `spec` も無い）。
    private func nodeMetricsList() -> Data {
        Data("""
            {"apiVersion":"v1","kind":"List","items":[
              {"apiVersion":"metrics.k8s.io/v1beta1","kind":"NodeMetrics",
               "metadata":{"name":"node-a"},
               "timestamp":"2026-08-07T07:00:23Z","window":"20s",
               "usage":{"cpu":"81768992n","memory":"4194304Ki"}}
            ]}
            """.utf8)
    }

    @Test("NodeMetrics を Node として受け取らない")
    func nodeMetricsIsRejected() {
        #expect(throws: K8sObject.UnexpectedKind.self) {
            try K8sObject.list(from: nodeMetricsList(), assuming: .node)
        }
    }

    /// **`kind` ではなく `rawKind` を見ていること。** `K8sObject.kind` は
    /// `ResourceKind(apiKind:) ?? fallbackKind` なので、enum に無い
    /// `NodeMetrics` は**要求した `.node` に化けている**。化けたあとを見ると
    /// この検証は 1 度も発火しない（`assuming:` の穴そのもの）。
    @Test("化けた kind ではなく、返ってきた生の kind で判定する")
    func verificationUsesRawKind() throws {
        let objects = try K8sObject.list(from: nodeMetricsList())
        #expect(objects[0].rawKind == "NodeMetrics")
        // 検証しなければ .node に化ける、というのが元の壊れ方。
        #expect(ResourceKind(apiKind: "NodeMetrics") == nil)
    }

    /// **空の `kind` は通す。** 単一種別の `get -o json` は items に kind を
    /// 入れてこない版がある。そこを弾くと、ふつうの取得が全部落ちる。
    @Test("kind が空の応答は、要求した種別として受け取る")
    func missingKindStillFallsBack() throws {
        let json = """
            {"apiVersion":"v1","kind":"List","items":[
              {"metadata":{"name":"node-a","uid":"1"},
               "status":{"conditions":[{"type":"Ready","status":"True"}]}}
            ]}
            """
        let objects = try K8sObject.list(from: Data(json.utf8), assuming: .node)
        #expect(objects.count == 1)
        #expect(objects[0].kind == .node)
        #expect(StatusResolver.status(for: objects[0]).level == .good)
    }

    @Test("正しい種別はそのまま通る")
    func matchingKindPasses() throws {
        let json = """
            {"apiVersion":"v1","kind":"List","items":[
              {"kind":"Node","metadata":{"name":"node-a","uid":"1"},
               "status":{"conditions":[{"type":"Ready","status":"True"}]}}
            ]}
            """
        let objects = try K8sObject.list(from: Data(json.utf8), assuming: .node)
        #expect(objects.map(\.kind) == [.node])
    }

    /// まとめ取得は kind で振り分けるので、ここが狂うと全部が狂う。
    @Test("まとめ取得に要求していない種別が混ざっていたら投げる")
    func bundledListRejectsForeignKinds() {
        let json = """
            {"apiVersion":"v1","kind":"List","items":[
              {"apiVersion":"metrics.k8s.io/v1beta1","kind":"PodMetrics",
               "metadata":{"name":"p","namespace":"default"}},
              {"apiVersion":"metrics.k8s.io/v1beta1","kind":"NodeMetrics",
               "metadata":{"name":"n"}}
            ]}
            """
        #expect(throws: K8sObject.UnexpectedKind.self) {
            try K8sObject.list(from: Data(json.utf8), expecting: [.pod, .node])
        }
    }

    @Test("まとめ取得は、要求した種別が混ざっているぶんは通す")
    func bundledListAcceptsRequestedKinds() throws {
        let json = """
            {"apiVersion":"v1","kind":"List","items":[
              {"kind":"Pod","metadata":{"name":"p","namespace":"default","uid":"1"},
               "status":{"phase":"Running"}},
              {"kind":"Node","metadata":{"name":"n","uid":"2"}}
            ]}
            """
        let objects = try K8sObject.list(from: Data(json.utf8), expecting: [.pod, .node])
        #expect(objects.map(\.kind) == [.pod, .node])
    }

    /// **CRD は突き合わせる相手がいない。** 組み込みの enum に無い種別なので、
    /// ここで弾くと CRD の一覧が丸ごと引けなくなる。
    @Test("要求した種別が分からないときは検証しない")
    func customResourcesAreNotVerified() throws {
        let json = """
            {"apiVersion":"v1","kind":"List","items":[
              {"apiVersion":"argoproj.io/v1alpha1","kind":"Application",
               "metadata":{"name":"app","namespace":"argocd","uid":"1"}}
            ]}
            """
        let objects = try K8sObject.list(from: Data(json.utf8))
        #expect(objects.count == 1)
        #expect(objects[0].rawKind == "Application")
        #expect(objects[0].kind == nil)
    }

    /// items を持たない応答（単一オブジェクトの get）も同じ規則で見る。
    @Test("単一オブジェクトの応答も検証する")
    func singleObjectIsVerified() {
        let json = """
            {"apiVersion":"metrics.k8s.io/v1beta1","kind":"NodeMetrics",
             "metadata":{"name":"node-a"}}
            """
        #expect(throws: K8sObject.UnexpectedKind.self) {
            try K8sObject.list(from: Data(json.utf8), assuming: .node)
        }
    }

    /// **黙って空にしない。** 帯に出るのはこの文言なので、何が起きたのかと
    /// 次に見る場所が読めること。
    @Test("食い違いは、取得できていないものとして説明する")
    func errorExplainsItself() throws {
        let error = K8sObject.UnexpectedKind(requested: [.node], received: "NodeMetrics")
        let message = try #require(error.errorDescription)
        #expect(message.contains("NodeMetrics"))
        #expect(message.contains("Node"))
        #expect(message.contains("取得できていない"))
        // 見に行く場所を書く。
        #expect(message.contains("api-resources"))
    }
}
