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
}
