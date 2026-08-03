import Testing
@testable import KubeDeck

/// Service・Ingress・PVC とワークロードのつながりは API に無いので、取ってきた
/// オブジェクトどうしを突き合わせる。**「一致」であって「参照」ではない**ので、
/// 一致の条件を緩めると無関係なものまで繋がる。
@Suite("関係の突き合わせ")
struct WorkloadRelationsTests {

    // MARK: - Service → Pod

    /// **空のセレクタを一致させない。** 空は「すべてに一致」ではなく
    /// 「まだ何も選んでいない」。通すと全部の Service がどのワークロードにも付く。
    @Test("セレクタが空の Service は何も掴まない")
    func emptySelectorMatchesNothing() {
        let pod = Fixture.pod(labels: ["app": "web"])
        let empty = Fixture.service(name: "unset", selector: [:])

        #expect(WorkloadRelations.pods(selectedBy: empty, among: [pod]).isEmpty)
        #expect(WorkloadRelations.services(for: [pod], among: [empty]).isEmpty)
    }

    @Test("セレクタは部分集合として一致する（Pod は余分なラベルを持てる）")
    func selectorIsSubset() {
        let pod = Fixture.pod(labels: ["app": "web", "pod-template-hash": "abc123"])
        let service = Fixture.service(name: "web", selector: ["app": "web"])

        #expect(WorkloadRelations.pods(selectedBy: service, among: [pod]).count == 1)
    }

    @Test("セレクタの一部でも合わなければ掴まない")
    func selectorNeedsEveryKey() {
        let pod = Fixture.pod(labels: ["app": "web"])
        let service = Fixture.service(name: "web", selector: ["app": "web", "tier": "front"])

        #expect(WorkloadRelations.pods(selectedBy: service, among: [pod]).isEmpty)
    }

    /// **Namespace をまたいで掴ませない。** 別の Namespace に同じラベルの
    /// Pod があるのはふつう。
    @Test("Namespace が違えば一致しない")
    func namespaceIsPartOfTheMatch() {
        let pod = Fixture.pod(namespace: "team-a", labels: ["app": "web"])
        let service = Fixture.service(name: "web", namespace: "team-b", selector: ["app": "web"])

        #expect(WorkloadRelations.pods(selectedBy: service, among: [pod]).isEmpty)
    }

    @Test("Pod が無いときはテンプレートのラベルで引ける")
    func matchByTemplateLabels() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        let found = WorkloadRelations.services(
            matching: ["app": "web"], namespace: "default", among: [service])

        #expect(found.map(\.name) == ["web"])
    }

    // MARK: - Ingress → Service

    /// **見つからなかった名前も返す。** 黙って落とすと「Ingress の先に何も無い」
    /// のか「壊れている」のかが分からない。
    @Test("Ingress が指しているのに実在しない Service を黙って落とさない")
    func missingBackendIsReported() {
        let existing = Fixture.service(name: "web", selector: ["app": "web"])
        let ingress = Fixture.ingress(name: "public", backends: ["web", "typo-api"])

        let resolved = WorkloadRelations.services(of: ingress, among: [existing, ingress])
        #expect(resolved.found.map(\.name) == ["web"])
        #expect(resolved.missing == ["typo-api"])
    }

    @Test("同じ Service を 2 度返さない（複数のパスが同じ backend を指す）")
    func duplicateBackends() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        let ingress = Fixture.ingress(name: "public", backends: ["web", "web"])

        #expect(WorkloadRelations.services(of: ingress, among: [service, ingress]).found.count == 1)
    }

    @Test("Service から Ingress を引く逆向きも通る")
    func ingressesForServices() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        let ingress = Fixture.ingress(name: "public", backends: ["web"])

        let found = WorkloadRelations.ingresses(for: [service], among: [service, ingress])
        #expect(found.map(\.name) == ["public"])
    }

    // MARK: - Pod → PVC

    @Test("Pod が使っている PVC だけを拾う")
    func claims() {
        let pod = Fixture.pod(
            volumes: #"[{"name":"data","persistentVolumeClaim":{"claimName":"data-0"}}]"#)
        let used = Fixture.claim(name: "data-0")
        let unused = Fixture.claim(name: "other")

        let found = WorkloadRelations.claims(for: [pod], among: [used, unused])
        #expect(found.map(\.name) == ["data-0"])
    }

    @Test("PVC を使っていない Pod では空を返す（無いことは異常ではない）")
    func noClaims() {
        let pod = Fixture.pod(volumes: #"[{"name":"tmp","emptyDir":{}}]"#)
        #expect(WorkloadRelations.claims(for: [pod], among: [Fixture.claim(name: "data-0")]).isEmpty)
    }
}
