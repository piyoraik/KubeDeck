import Testing
@testable import KubeDeck

/// 絞り込みは全一覧に出る唯一の入力欄。**素の部分一致だけでは
/// 「この Deployment の Pod だけ」が出せない**ので、よく打つ形だけを読む。
/// ここで固めるのは、読まない形を黙って読んだことにしないこと。
@Suite("一覧の絞り込み")
struct SearchTests {

    private func pod(
        name: String = "web-0",
        namespace: String = "default",
        labels: [String: String] = [:],
        node: String? = "node-a",
        phase: String = "Running"
    ) -> K8sObject {
        Fixture.pod(name: name, namespace: namespace, phase: phase, labels: labels, node: node)
    }

    private func matches(_ object: K8sObject, _ query: String) -> Bool {
        ResourceTable.matches(object, target: .builtIn(.pod), query: query)
    }

    // MARK: - 読み取り

    @Test("ラベルは key=value で読む")
    func labelTerm() {
        #expect(SearchTerm.parse("app=nginx") == [.label(key: "app", value: "nginx")])
    }

    @Test("値の無いラベルは「持っているか」だけを見る")
    func labelPresence() {
        #expect(SearchTerm.parse("app=") == [.label(key: "app", value: nil)])
    }

    @Test("場所の指定は知っている語だけ")
    func fieldTerm() {
        #expect(SearchTerm.parse("ns:kube-system") == [.field(.namespace, "kube-system")])
        #expect(SearchTerm.parse("namespace:prod") == [.field(.namespace, "prod")])
        #expect(SearchTerm.parse("status:running") == [.field(.status, "running")])
        #expect(SearchTerm.parse("node:node-a") == [.field(.node, "node-a")])
    }

    @Test("知らない語の : は素の文字として扱う")
    func unknownFieldStaysFree() {
        // `nginx:1.21` はイメージのタグ。これを「nginx という場所」と
        // 読むと、打った文字がどこにも効かないまま 0 件になる。
        #expect(SearchTerm.parse("nginx:1.21") == [.free("nginx:1.21")])
    }

    @Test("空白で区切ると複数の項目になる")
    func multipleTerms() {
        #expect(
            SearchTerm.parse("app=web crash") == [.label(key: "app", value: "web"), .free("crash")])
    }

    // MARK: - 一致

    @Test("ラベルの値は完全一致で見る")
    func labelValueIsExact() {
        let prod = pod(labels: ["env": "prod"])
        let production = pod(name: "web-1", labels: ["env": "production"])

        #expect(matches(prod, "env=prod"))
        // **前方一致にしない。** 絞り込んだつもりで絞れていない状態になる。
        #expect(!matches(production, "env=prod"))
        #expect(matches(production, "env=production"))
    }

    @Test("値を書かなければラベルの有無だけを見る")
    func labelPresenceMatches() {
        #expect(matches(pod(labels: ["app": "web"]), "app="))
        #expect(matches(pod(labels: ["app": "api"]), "app="))
        #expect(!matches(pod(labels: ["tier": "front"]), "app="))
    }

    @Test("複数の項目はすべてに一致するものだけ残す")
    func termsAreAnded() {
        let target = pod(name: "web-0", labels: ["app": "web"])
        let otherLabel = pod(name: "web-1", labels: ["app": "api"])
        let otherName = pod(name: "cache-0", labels: ["app": "web"])

        #expect(matches(target, "app=web web-0"))
        #expect(!matches(otherLabel, "app=web web-0"))
        #expect(!matches(otherName, "app=web web-0"))
    }

    @Test("Namespace とノードで絞れる")
    func fieldMatches() {
        let object = pod(namespace: "kube-system", node: "node-b")

        #expect(matches(object, "ns:kube-system"))
        #expect(!matches(object, "ns:default"))
        #expect(matches(object, "node:node-b"))
        #expect(!matches(object, "node:node-a"))
    }

    @Test("状態で絞れる")
    func statusMatches() {
        let crashing = Fixture.pod(
            phase: "Running",
            containerStatuses:
                "[\(Fixture.containerStatus(ready: false, state: Fixture.waiting("CrashLoopBackOff")))]")

        // 一覧の STATUS 列と同じ判定を通す。phase は Running のままなので、
        // phase を見ていたらここは一致しない。
        #expect(matches(crashing, "status:crashloop"))
        #expect(!matches(pod(), "status:crashloop"))
    }

    @Test("素の文字はこれまでどおり名前で拾う")
    func freeTextStillWorks() {
        #expect(matches(pod(name: "web-0"), "web"))
        #expect(!matches(pod(name: "web-0"), "cache"))
    }

    @Test("空の問い合わせは何も絞らない")
    func emptyQueryKeepsEverything() {
        #expect(matches(pod(), ""))
        #expect(matches(pod(), "   "))
    }

    @Test("大文字小文字は区別しない")
    func caseInsensitive() {
        let object = pod(name: "Web-0", labels: ["App": "NGINX"])

        #expect(matches(object, "web"))
        #expect(matches(object, "app=nginx"))
    }
}
