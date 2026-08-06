import Testing
@testable import KubeDeck

/// ログを開く指定の組み立て。
///
/// **固めているのは、壊れても気付きにくいところだけ。** Job の Pod を掴む
/// セレクタが狂うと、画面には「Pod が残っていません」と出る（＝ Job が
/// 終わって消えたときと同じ見た目になる）ので、間違っていることに気付けない。
struct PodLogRequestTests {
    private func job(
        name: String = "batch",
        namespace: String = "default",
        selector: String = #"{"matchLabels":{"batch.kubernetes.io/controller-uid":"uid-1"}}"#,
        containers: String = #"[{"name":"worker"}]"#
    ) -> K8sObject {
        Fixture.object(
            """
            {
              "kind": "Job",
              "metadata": { "name": "\(name)", "namespace": "\(namespace)", "uid": "uid-1" },
              "spec": {
                "selector": \(selector),
                "template": { "spec": { "containers": \(containers) } }
              }
            }
            """, assuming: .job)
    }

    /// セレクタとテンプレートを持つワークロード。`Fixture.controller` は
    /// `spec` が空なので、まとめ読みの検証には使えない。
    private func workload(
        kind: String = "Deployment",
        name: String = "web",
        namespace: String = "default",
        selector: String = #"{"matchLabels":{"app":"web"}}"#,
        containers: String = #"[{"name":"app"}]"#
    ) -> K8sObject {
        Fixture.object(
            """
            {
              "kind": "\(kind)",
              "metadata": { "name": "\(name)", "namespace": "\(namespace)",
                            "uid": "\(namespace)-\(kind)-\(name)" },
              "spec": {
                "selector": \(selector),
                "template": { "spec": { "containers": \(containers) } }
              }
            }
            """)
    }

    // MARK: - 種別の振り分け

    /// `init?(object:)` は**1 つを読む**入口。まとめ読みは別の入口
    /// （`init?(group:)`）なので、ここが Deployment を通し始めたら
    /// 「ログを見る」と「まとめてログを見る」が同じ種別に 2 つ並ぶ。
    @Test func ひとつを読む入口はPodとJobだけ() {
        #expect(PodLogRequest(object: Fixture.pod()) != nil)
        #expect(PodLogRequest(object: job()) != nil)
        #expect(PodLogRequest(object: workload()) == nil)
        #expect(PodLogRequest(object: Fixture.service(name: "web", selector: ["app": "web"])) == nil)
    }

    /// 逆向き。Pod と Job はまとめ読みの入口を通らない
    /// （Job には「どの試行か」を選ばせる経路がある）。
    @Test func まとめ読みの入口はPodとJobを通さない() {
        #expect(PodLogRequest(group: Fixture.pod()) == nil)
        #expect(PodLogRequest(group: job()) == nil)
        // CronJob はセレクタを持たず Job を経由する 2 段なので、ここでは解けない。
        #expect(PodLogRequest(group: workload(kind: "CronJob")) == nil)
    }

    // MARK: - まとめ読みのセレクタ

    @Test(
        "ワークロードは matchLabels、Service は素のラベル",
        arguments: ["Deployment", "StatefulSet", "DaemonSet", "ReplicaSet"])
    func ワークロードはmatchLabelsから掴む(_ kind: String) {
        let request = PodLogRequest(group: workload(kind: kind))
        #expect(request?.isGroup == true)
        #expect(request?.source == .group(kind: kind, selector: ["app": "web"]))
        #expect(request?.kindLabel == kind)
        // コンテナはテンプレートから。どの Pod でも同じなので Picker に出せる。
        #expect(request?.containers == ["app"])
    }

    @Test func ServiceはmatchLabelsを挟まない() {
        let service = Fixture.service(name: "web", selector: ["app": "web", "tier": "front"])
        let request = PodLogRequest(group: service)
        #expect(request?.source == .group(kind: "Service", selector: ["app": "web", "tier": "front"]))
        // Service にテンプレートは無い。空のまま持たせて、全コンテナを読む。
        #expect(request?.containers == [])
    }

    /// **空のセレクタで開かない。** Service の空セレクタは「すべてに一致」では
    /// なく「まだ何も選んでいない」（`WorkloadRelations` と同じ規則）。通すと
    /// `kubectl logs -l` が Namespace の Pod を全部読むことになる。
    @Test func 空のセレクタは開けない() {
        #expect(PodLogRequest(group: Fixture.service(name: "ext", selector: [:])) == nil)
        #expect(PodLogRequest(group: workload(selector: #"{"matchExpressions":[]}"#)) == nil)
    }

    /// `id` は取得の鍵（`LogContent.reloadKey`）。同じ名前の Deployment と
    /// Service はふつうに同居するので、ここが重なると切り替えても取り直さない。
    @Test func 同じ名前のDeploymentとServiceは別の取得() {
        let deployment = PodLogRequest(group: workload(name: "web"))
        let service = PodLogRequest(group: Fixture.service(name: "web", selector: ["app": "web"]))
        #expect(deployment?.id != service?.id)
    }

    /// 追従（`followLogsToSelection`）はどちらの形でも開く。ここが 1 つを
    /// 読む入口だけを見ていると、まとめ読みを開いたまま Deployment を
    /// 選び直しても前の対象が残る。
    @Test func 追従はどちらの形でも開く() {
        #expect(PodLogRequest(opening: Fixture.pod())?.isGroup == false)
        #expect(PodLogRequest(opening: workload())?.isGroup == true)
        #expect(PodLogRequest(opening: Fixture.object(#"{"kind":"ConfigMap","metadata":{"name":"c"}}"#)) == nil)
    }

    @Test func 同じ名前のJobとPodは別の取得として扱う() {
        let pod = PodLogRequest(pod: Fixture.pod(name: "batch"))
        let job = PodLogRequest(job: job(name: "batch"))
        // `id` は取得の鍵（`LogContent.reloadKey`）に入る。ここが重なると、
        // Job から Pod へ切り替えても取り直されない。
        #expect(pod.id != job.id)
    }

    // MARK: - Job のセレクタ

    @Test func Jobは自身のspecSelectorでPodを掴む() {
        let request = PodLogRequest(job: job())
        #expect(request.isJob)
        #expect(request.source == .job(selector: ["batch.kubernetes.io/controller-uid": "uid-1"]))
    }

    @Test func Jobのコンテナはテンプレートから取る() {
        let request = PodLogRequest(
            job: job(containers: #"[{"name":"worker"},{"name":"sidecar"}]"#))
        #expect(request.containers == ["worker", "sidecar"])
    }

    /// `matchLabels` が無い Job（手書きで `matchExpressions` だけ書いたもの）。
    /// **空のセレクタで引かない** — ラベル無しで get すると Namespace の
    /// Pod が全部返り、無関係な Pod のログを Job のものとして出すことになる。
    @Test func matchLabelsが無ければjobNameに落とす() {
        let request = PodLogRequest(job: job(selector: #"{"matchExpressions":[]}"#))
        #expect(request.source == .job(selector: ["job-name": "batch"]))
    }

    // MARK: - Pod

    @Test func Podはspecのコンテナをそのまま持つ() {
        let request = PodLogRequest(
            pod: Fixture.pod(containers: #"[{"name":"app"},{"name":"proxy"}]"#))
        #expect(request.isJob == false)
        #expect(request.name == "web-0")
        #expect(request.containers == ["app", "proxy"])
    }
}
