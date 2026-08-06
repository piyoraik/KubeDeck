import Foundation
import Testing
@testable import KubeDeck

/// `--ignore-not-found` が握りつぶすのは NotFound だけで、**Forbidden は
/// そのまま終了コード 1 になる**。にもかかわらず kubectl は読めた種別を
/// 標準出力に書いているので、終了コードだけで投げると取れているデータを捨てる。
/// ここで固めるのは、その stderr の書式に依存している部分。
@Suite("kubectl の応答の読み取り")
struct KubectlTests {

    /// 実測した文言そのまま（orbstack + impersonation）。
    private let forbidden = """
        Error from server (Forbidden): secrets is forbidden: User \
        "system:serviceaccount:kube-system:endpoint-controller" cannot list resource \
        "secrets" in API group "" at the cluster scope
        Error from server (Forbidden): deployments.apps is forbidden: User \
        "system:serviceaccount:kube-system:endpoint-controller" cannot list resource \
        "deployments" in API group "apps" at the cluster scope
        Error from server (Forbidden): ingresses.networking.k8s.io is forbidden: User \
        "system:serviceaccount:kube-system:endpoint-controller" cannot list resource \
        "ingresses" in API group "networking.k8s.io" at the cluster scope
        """

    @Test("拒まれた種別を、API グループの有無にかかわらず拾う")
    func deniedKinds() {
        let denied = Kubectl.deniedKinds(
            in: forbidden, among: [.pod, .secret, .deployment, .ingress, .service])

        #expect(Set(denied) == [.secret, .deployment, .ingress])
    }

    /// **要求していない種別を拾わない。** 拒まれた一覧は「この呼び出しで
    /// 数えられなかったもの」なので、要求していないものが混ざると
    /// 断り書きが嘘になる。
    @Test("要求していない種別は拒まれた一覧に入れない")
    func onlyRequestedKinds() {
        let denied = Kubectl.deniedKinds(in: forbidden, among: [.pod, .secret])
        #expect(denied == [.secret])
    }

    /// **当てはまらない失敗を「権限が無い」ことにしない。**
    @Test("forbidden 以外の失敗では拒まれた種別を作らない")
    func otherFailuresAreNotDenials() {
        let unreachable = """
            Unable to connect to the server: dial tcp 10.0.0.1:443: i/o timeout
            """
        #expect(Kubectl.deniedKinds(in: unreachable, among: [.pod, .secret]).isEmpty)
        #expect(Kubectl.deniedKinds(in: "", among: [.pod]).isEmpty)
    }

    // MARK: - サーバが知らない種別

    /// **Forbidden と壊れ方が違う。** kubectl は要求を組み立てる段で諦めるので
    /// 標準出力は空になり、1 種別のせいでまとめ取得が丸ごと消える。
    /// 実測した文言そのまま（`kubectl get pods,hoges` は exit 1・stdout 0 バイト）。
    @Test("サーバが知らないと言われた種別を拾う")
    func unknownKinds() {
        let stderr = #"error: the server doesn't have a resource type "ingresses""#
        let unknown = Kubectl.unknownKinds(in: stderr, among: [.pod, .ingress, .service])

        #expect(unknown == [.ingress])
    }

    /// **グループが落ちる。** `roles.rbac.authorization.k8s.io` と頼んでも、
    /// kubectl は `"roles"` としか書かない。要求した側を切って突き合わせる。
    @Test("グループ付きで頼んだ種別も、グループ無しの文言から拾う")
    func unknownKindsIgnoreAPIGroup() {
        let stderr = #"error: the server doesn't have a resource type "roles""#
        let unknown = Kubectl.unknownKinds(in: stderr, among: [.pod, .role, .clusterRole])

        // ClusterRole は別の複数形なので巻き込まない。
        #expect(unknown == [.role])
    }

    /// **当てはまらない失敗を「サーバが知らない」ことにしない。**
    @Test("他の失敗では知らない種別を作らない")
    func otherFailuresAreNotUnknownKinds() {
        #expect(Kubectl.unknownKinds(in: forbidden, among: [.pod, .secret]).isEmpty)
        #expect(Kubectl.unknownKinds(in: "", among: [.pod]).isEmpty)
        // 要求していない種別は拾わない。
        let stderr = #"error: the server doesn't have a resource type "hoges""#
        #expect(Kubectl.unknownKinds(in: stderr, among: [.pod, .ingress]).isEmpty)
    }

    /// 縮退した discovery キャッシュから自力で復帰するための引き金。
    ///
    /// 覚えている API の一覧が壊れると、実在する `pods` にもこの文言が出る
    /// （コアグループの versions が null になり、v1 が解決できなくなる）。
    /// 文言からは「本当に無い」のか「一覧が欠けている」のかが決まらないので、
    /// **1 度だけ捨てて引き直して確かめる。** その引き金がこれ。
    @Test("実在する種別でも「知らない」と言われたら、引き直しの対象にする")
    func brokenDiscoveryIsRetried() {
        // 縮退したキャッシュで実測した文言。
        let stderr = #"error: the server doesn't have a resource type "pods""#
        #expect(Kubectl.mentionsMissingResourceType(stderr))
    }

    /// **当てはまらない失敗で引き直さない。** キャッシュを捨てるたびに
    /// kubectl は全 API グループを引き直すので、無関係な失敗で走らせない。
    @Test("他の失敗では引き直さない")
    func otherFailuresDoNotResetDiscovery() {
        #expect(!Kubectl.mentionsMissingResourceType(forbidden))
        #expect(!Kubectl.mentionsMissingResourceType(""))
        #expect(!Kubectl.mentionsMissingResourceType(
            "Unable to connect to the server: context deadline exceeded"))
    }

    /// 捨てる先を間違えると、消えていないのに引き直すことになり、
    /// **同じ失敗をもう 1 度取りに行くだけ**になる（黙って直らない）。
    @Test("覚えている API の一覧だけを捨てる")
    func removesDiscoveryCacheOnly() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let discovery = root.appendingPathComponent("discovery/example.com_443",
                                                    isDirectory: true)
        let http = root.appendingPathComponent("http", isDirectory: true)
        try FileManager.default.createDirectory(at: discovery, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: http, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: discovery.appendingPathComponent("servergroups.json"))
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(Kubectl.removeDiscoveryCache(in: root.path))
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent("discovery").path))
        // 巻き込まない。キャッシュの置き場所ごと消すわけではない。
        #expect(FileManager.default.fileExists(atPath: http.path))
    }

    /// **消せなかったときに「捨てた」と言わない。** 呼び出し側はこれを見て
    /// 引き直すかどうかを決める。
    @Test("覚えていないときは捨てたことにしない")
    func noDiscoveryCacheToRemove() {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        #expect(!Kubectl.removeDiscoveryCache(in: missing.path))
    }

    /// **ターミナルの kubectl と共有しない。** 共有していると、どちらかが
    /// 壊した一覧をもう一方も読む（実際にそれで全種別が消えた）。
    @Test("キャッシュの置き場所は ~/.kube/cache ではない")
    func cacheDirectoryIsPrivate() {
        #expect(!Kubectl.cacheDirectory.hasSuffix("/.kube/cache"))
        #expect(Kubectl.cacheDirectory.contains("/Caches/"))
    }

    /// 失敗しても標準出力を捨てないための受け皿。
    @Test("CommandError は書き出されていた標準出力を持ち回る")
    func commandErrorCarriesPartialOutput() throws {
        let payload = Data(#"{"items":[]}"#.utf8)
        let error = CommandError(
            command: "kubectl get pods,secrets", exitCode: 1, message: "…",
            partialStdout: payload, rawStderr: forbidden)

        #expect(error.partialStdout == payload)
        #expect(error.rawStderr.contains("secrets is forbidden"))
    }

    // MARK: - 設定画面に出す環境変数

    /// **場所は見せる。** CA や kubeconfig の指し先が合っているかを確かめる
    /// 場所なので、伏せると診断にならない。
    @Test("ファイルの場所は伏せない", arguments: [
        ("REQUESTS_CA_BUNDLE", "/etc/ssl/corp.pem"),
        ("KUBECONFIG", "~/.kube/config"),
        ("SSL_CERT_FILE", "/usr/local/share/ca.pem"),
    ])
    func pathsAreShown(name: String, value: String) {
        #expect(!Kubectl.hidesValue(name: name, value: value))
    }

    @Test("秘密を思わせる名前は伏せる", arguments: [
        ("AWS_SECRET_ACCESS_KEY", "abc123"),
        ("GITHUB_TOKEN", "ghp_xxx"),
        ("MY_PASSWORD", "hunter2"),
    ])
    func secretNamesAreHidden(name: String, value: String) {
        #expect(Kubectl.hidesValue(name: name, value: value))
    }

    /// **名前に頼りきらない。** どの目印にも当たらないのに認証情報を含む値がある。
    @Test("URL に埋まった認証情報は、名前が無害でも伏せる")
    func embeddedCredentialsAreHidden() {
        #expect(Kubectl.hidesValue(name: "DATABASE_URL", value: "postgres://u:p@db:5432/app"))
        #expect(Kubectl.hidesValue(name: "HTTPS_PROXY", value: "http://user:pass@proxy:3128"))
    }

    /// **伏せすぎない。** 資格情報を含まない URL は、プロキシの指し先として
    /// まさに見たい値。
    @Test("認証情報を含まない URL は見せる")
    func plainURLsAreShown() {
        #expect(!Kubectl.hidesValue(name: "HTTPS_PROXY", value: "http://proxy.corp:3128"))
        #expect(!Kubectl.hidesValue(name: "NO_PROXY", value: "localhost,127.0.0.1"))
        // user@host は資格情報ではない。
        #expect(!Kubectl.hidesValue(name: "GIT_REMOTE", value: "ssh://git@github.com/x/y"))
    }

    /// 一部が拒まれた応答は、**読めた種別だけを含む正しい JSON** として返る。
    @Test("読めた種別だけが入った List をそのまま解ける")
    func partialListParses() throws {
        let json = """
            {"apiVersion":"v1","kind":"List","items":[
              {"kind":"Pod","metadata":{"name":"a","namespace":"default","uid":"1"},
               "spec":{},"status":{"phase":"Running"}}
            ]}
            """
        let objects = try K8sObject.list(from: Data(json.utf8))

        #expect(objects.count == 1)
        #expect(objects[0].kind == .pod)
    }

    // MARK: - rollout history

    /// 実測した書式（`kubectl rollout history deployment/demo`）。
    /// **見出しの位置で切らない** — CHANGE-CAUSE は人が書く文なので空白が入る。
    @Test("世代と理由を読む。空白を含む理由も落とさない")
    func rolloutHistory() {
        let text = """
            deployment.apps/demo 
            REVISION  CHANGE-CAUSE
            1         <none>
            2         pause 3.10 に上げた
            """
        let revisions = Kubectl.parseRolloutHistory(text)
        #expect(revisions.map(\.revision) == [1, 2])
        // **`<none>` を理由にしない。** 「書かれていない」ことが分かるように nil。
        #expect(revisions[0].changeCause == nil)
        #expect(revisions[1].changeCause == "pause 3.10 に上げた")
    }

    @Test("見出しや空行を世代として読まない")
    func rolloutHistoryIgnoresNoise() {
        #expect(Kubectl.parseRolloutHistory("").isEmpty)
        #expect(Kubectl.parseRolloutHistory("deployment.apps/demo\nREVISION  CHANGE-CAUSE\n").isEmpty)
    }

    // MARK: - 書き戻しの失敗の見分け

    /// **他人の更新とのぶつかりを、他の失敗と混ぜない。** 綴り間違いは直せば
    /// 通るが、こちらは中身が古いだけで、直す先が違う（読み直す）。
    /// 実測した書式に依存しているので固めておく。
    @Test("Conflict は書き直しではなく読み直しの合図")
    func conflictDetection() {
        let conflict = """
            Error from server (Conflict): error when replacing "STDIN": \
            Operation cannot be fulfilled on deployments.apps "demo": \
            the object has been modified; please apply your changes to the latest version and try again
            """
        #expect(Kubectl.isConflict(conflict))
    }

    @Test("綴り間違いや immutable は Conflict にしない")
    func otherFailuresAreNotConflicts() {
        let typo = """
            Error from server (BadRequest): error when replacing "STDIN": \
            Deployment in version "v1" cannot be handled as a Deployment: \
            strict decoding error: unknown field "spec.replicasss"
            """
        let immutable = """
            The Service "svc-demo" is invalid: spec.clusterIPs[0]: \
            Invalid value: ["10.43.99.99"]: may not change once set
            """
        #expect(!Kubectl.isConflict(typo))
        #expect(!Kubectl.isConflict(immutable))
    }
}
