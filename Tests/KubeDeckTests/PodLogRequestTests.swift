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

    // MARK: - 種別の振り分け

    @Test func podとJobだけがログを開ける() {
        #expect(PodLogRequest(object: Fixture.pod()) != nil)
        #expect(PodLogRequest(object: job()) != nil)
        // Deployment を開けるようにすると、どの世代の Pod を出すのかが
        // 決まらない。開けない種別は nil のまま。
        let deployment = Fixture.controller(kind: "Deployment", name: "web", owner: nil)
        #expect(PodLogRequest(object: deployment) == nil)
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
