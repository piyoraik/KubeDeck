import Foundation

/// kubectl の置き場所と、子プロセスに渡す環境変数。
struct KubectlEnvironment: Sendable {
    let executable: String
    let variables: [String: String]
}

enum KubectlSetupError: LocalizedError {
    case notFound

    var errorDescription: String? {
        switch self {
        case .notFound:
            return """
                kubectl が見つかりません。
                Homebrew なら `brew install kubectl` で入ります。
                すでに入っている場合は、/opt/homebrew/bin か /usr/local/bin から辿れるか確認してください。
                """
        }
    }
}

/// kubectl の呼び出し口。
///
/// API サーバを直接叩かず kubectl を経由するのは、認証のためだけ。
/// kubeconfig の exec プラグイン（EKS / GKE）、クライアント証明書、OIDC の
/// トークン更新、プロキシ設定を自前で持たずに済む。
actor Kubectl {
    static let shared = Kubectl()

    private var cachedEnvironment: KubectlEnvironment?
    /// ログインシェルから写した環境。取るのに 0.5〜1 秒かかるので、
    /// kubectl の場所を変えられたぐらいでは取り直さない（別に持つ）。
    private var cachedLoginShell: [String: String]?

    /// 一覧取得の待ち上限。到達できないクラスタを選んだときに
    /// UI が固まったままにならないようにする。設定から差し替えられる。
    private var timeoutSeconds = 20
    private var requestTimeout: String { "\(timeoutSeconds)s" }
    /// 設定で場所を指定されたとき用。空なら自動で探す。
    private var executableOverride = ""

    func configure(timeoutSeconds: Int, executableOverride: String) {
        let trimmed = executableOverride.trimmingCharacters(in: .whitespaces)
        // 場所が変わったら、覚えている解決結果を捨てる。
        if trimmed != self.executableOverride { cachedEnvironment = nil }
        self.timeoutSeconds = max(3, timeoutSeconds)
        self.executableOverride = trimmed
    }

    // MARK: - 実行環境の解決

    func environment() throws -> KubectlEnvironment {
        if let cachedEnvironment { return cachedEnvironment }

        let loginShell = loginShellEnvironment()
        let searchPath = Self.searchPath(loginShellPath: loginShell["PATH"])
        // 手で指定されていればそれを使う。実行できなければ自動探索に戻す
        // （消えたパスを覚えたまま「見つかりません」と言い続けない）。
        let executable: String
        if !executableOverride.isEmpty,
           FileManager.default.isExecutableFile(atPath: executableOverride) {
            executable = executableOverride
        } else if let found = Self.locateKubectl(in: searchPath) {
            executable = found
        } else {
            throw KubectlSetupError.notFound
        }

        // ログインシェルの環境をそのまま土台にする。
        //
        // **渡す変数を選ばない。** 一度は「認証プラグインが見るもの」だけを並べたが、
        // 追いつかなかった。プラグインの先で動く gcloud / aws が何を見るかは環境で
        // 違う。TLS を覗く社内プロキシの下では独自の CA を指す変数（`REQUESTS_CA_BUNDLE`
        // など）が要り、落とすと認証ではなく TLS の検証で落ちる。python を mise や
        // pyenv でしか入れていなければ `CLOUDSDK_PYTHON` が要る。**PATH と同じで、
        // 候補を並べても追いつかない。** ターミナルで通る組み合わせをそのまま渡す。
        var variables = loginShell
        // ターミナルから `.app` を起動して変数を指定したときは、そちらを採る。
        variables.merge(ProcessInfo.processInfo.environment) { _, own in own }
        // シェルの覚え書きは持ち込まない。子プロセスの実際の cwd と食い違う。
        for key in ["PWD", "OLDPWD", "SHLVL", "_"] { variables.removeValue(forKey: key) }

        variables["PATH"] = searchPath.joined(separator: ":")
        variables["HOME"] = NSHomeDirectory()
        // 認証プラグインが対話プロンプトを出すと待ち続けるので、非対話に倒す。
        variables["TERM"] = "dumb"

        let resolved = KubectlEnvironment(executable: executable, variables: variables)
        cachedEnvironment = resolved
        return resolved
    }

    /// ログインシェルの環境。1 度取ったら使い回す。
    private func loginShellEnvironment() -> [String: String] {
        if let cachedLoginShell { return cachedLoginShell }
        let harvested = LoginShell.environment()
        cachedLoginShell = harvested
        return harvested
    }

    /// Finder から起動したアプリの PATH は `/usr/bin:/bin:/usr/sbin:/sbin` しかない。
    /// kubectl 本体だけでなく、kubeconfig の exec プラグイン（aws,
    /// gke-gcloud-auth-plugin など）も PATH から引かれるので、ここで補う。
    ///
    /// **ログインシェルの PATH を先頭に置く。** 同じ名前の実行ファイルが複数ある
    /// とき、ターミナルで選ばれるものと同じものを選ぶため。決め打ちの一覧を先に
    /// 置くと、ターミナルでは通るのに `.app` では別の実体が動く。
    private static func searchPath(loginShellPath: String?) -> [String] {
        let home = NSHomeDirectory()
        var directories = loginShellPath?.split(separator: ":").map(String.init) ?? []
        directories += [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.krew/bin",
            "\(home)/bin",
            "\(home)/.local/bin",
            // gcloud SDK は展開先が決まっていない。ログインシェルが読めなかった
            // ときの最後の頼みとして、よくある置き場所だけ並べる。
            "\(home)/google-cloud-sdk/bin",
            "\(home)/Downloads/google-cloud-sdk/bin",
            "/usr/local/share/google-cloud-sdk/bin",
            "/opt/homebrew/share/google-cloud-sdk/bin",
            "/opt/homebrew/Caskroom/google-cloud-sdk/latest/google-cloud-sdk/bin",
            "/Applications/google-cloud-sdk/bin",
        ]
        if let inherited = ProcessInfo.processInfo.environment["PATH"] {
            directories += inherited.split(separator: ":").map(String.init)
        }

        var seen = Set<String>()
        return directories.filter { seen.insert($0).inserted }
    }

    private static func locateKubectl(in searchPath: [String]) -> String? {
        let fileManager = FileManager.default
        for directory in searchPath {
            let candidate = (directory as NSString).appendingPathComponent("kubectl")
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    // MARK: - 実行

    @discardableResult
    func run(_ arguments: [String], context: String?) async throws -> CommandResult {
        let environment = try environment()
        var fullArguments = arguments
        if let context, !context.isEmpty {
            fullArguments.insert(contentsOf: ["--context", context], at: 0)
        }

        // **プロセスごと上限を掛ける。** `--request-timeout` は API への要求しか
        // 縛らない。kubeconfig の exec 認証プラグインが返らないと（gcloud が
        // 再認証の入力を待つ、プロキシの向こうで詰まる）kubectl はいつまでも
        // 待ち、UI が読み込み中のまま固まる。実際にそうなった。
        //
        // **絞りすぎない。** ここは「終わらないもの」を切るためだけの網で、
        // ふつうの失敗は kubectl 自身の待ち上限が捌く。届かないクラスタでは
        // kubectl が API グループの一覧を数回引き直すので、待ち上限の 2 倍以上
        // かかる。そこで先に殺すと、kubectl の「届きません」を受け取り損ね、
        // 代わりにこちらが「返ってこない」と言うことになる。**理由を上書きしない。**
        let result = try await ProcessRunner.run(
            executable: environment.executable,
            arguments: fullArguments,
            environment: environment.variables,
            timeout: TimeInterval(timeoutSeconds * 2 + 15))

        guard !result.timedOut else {
            throw CommandError(
                command: "kubectl " + fullArguments.joined(separator: " "),
                exitCode: result.exitCode,
                message: Self.timeoutMessage(
                    seconds: timeoutSeconds * 2 + 15, stderr: result.stderr))
        }
        guard result.exitCode == 0 else {
            throw CommandError(
                command: "kubectl " + fullArguments.joined(separator: " "),
                exitCode: result.exitCode,
                message: Self.explain(result.stderr),
                // 失敗しても書き出されていたぶんは載せて渡す。捨てると、
                // 一部の種別だけ拒まれたときに読めたデータまで消える。
                partialStdout: result.stdout.isEmpty ? nil : result.stdout,
                rawStderr: result.stderr)
        }
        return result
    }

    /// 打ち切ったときの文言。**「取れなかった」と混ぜない。**
    /// 応答が無いのと、応答が失敗なのとでは見るところが違う。
    private static func timeoutMessage(seconds: Int, stderr: String) -> String {
        // **打ち切ったことを理由にしない。** 打ち切るまでに kubectl が何か
        // 書き出していれば、そちらのほうが確かな手がかり。届かないクラスタで
        // 「認証プラグインが返らない」と言うと、見る場所を間違えさせる。
        // **言い換えを先に置く。** 帯は最初の段落しか見出しに出さないので、
        // 打ち切った断りを先に書くと、肝心の理由が畳まれた側に入る（そうなった）。
        if let hint = authenticationHint(for: stderr) {
            return hint
                + "\n（kubectl は \(seconds) 秒で返らなかったので打ち切っています。"
                + "上は打ち切るまでに書き出されていた失敗です。）"
                + "\n\n" + condense(stderr)
        }

        let head = "kubectl が \(seconds) 秒のあいだ何も返さなかったので打ち切りました。\n"
            + "待ち上限（`--request-timeout`）は API への要求しか縛りません。"
            + "kubeconfig の exec 認証プラグイン（`gke-gcloud-auth-plugin` など）が"
            + "返ってこない場合は、ここで打ち切るまで待つことになります。\n"
            + "ターミナルで同じコンテキストに `kubectl cluster-info` を実行して、"
            + "そちらの言い分を確かめてください。設定の「接続」で待ち上限を延ばすと、"
            + "kubectl 自身の理由を最後まで受け取れることがあります。"
        return stderr.isEmpty ? head : head + "\n\n" + condense(stderr)
    }

    /// いま使っている kubectl の場所。設定画面に出す。
    func resolvedExecutablePath() -> String? {
        (try? environment())?.executable
    }

    /// 子プロセスに渡している PATH。認証プラグインが見つからないときの
    /// 切り分けに要るので、設定画面に出す。
    func resolvedSearchPath() -> String? {
        (try? environment())?.variables["PATH"]
    }

    /// 子プロセスに渡している環境。設定画面に出す。
    ///
    /// 「ターミナルでは通るのに `.app` では通らない」を追うとき、いちばん知りたいのが
    /// 「何が届いているか」だった。CA の指し先（`REQUESTS_CA_BUNDLE` など）が
    /// 渡っているかは、ここを見れば分かる。
    ///
    /// **値をそのまま並べない。** 環境をまるごと渡すようにしたので、鍵やトークンが
    /// 混ざりうる。ただしファイルの場所まで伏せると診断にならないので、伏せるのは
    /// 「秘密を思わせる名前」かつ「場所に見えない値」だけにする。
    /// PATH は別の行が持っているので、ここには出さない（同じものを 2 度出さない）。
    func resolvedVariables() -> [String: String] {
        guard let variables = (try? environment())?.variables else { return [:] }
        var shown: [String: String] = [:]
        for (key, value) in variables where key != "PATH" {
            shown[key] = Self.hidesValue(name: key, value: value) ? "（伏せています）" : value
        }
        return shown
    }

    private static let secretHints = [
        "SECRET", "TOKEN", "PASSWORD", "PASSWD", "KEY", "CREDENTIAL", "AUTH", "SESSION",
    ]

    static func hidesValue(name: String, value: String) -> Bool {
        // **名前に頼りきらない。** `DATABASE_URL=postgres://user:pass@host` のような
        // 値は、名前のどれにも当たらないのに認証情報を含む。この画面は設定画面で
        // あって、そのまま貼って共有されうる場所なので、形でも見る。
        if containsEmbeddedCredentials(value) { return true }
        // 場所を指しているなら見せる。CA や kubeconfig の指し先が合っているかを
        // 確かめる場所なので、伏せると診断にならない。
        if value.hasPrefix("/") || value.hasPrefix("~") { return false }
        let upper = name.uppercased()
        return secretHints.contains { upper.contains($0) }
    }

    /// `scheme://user:pass@host` の形。**`user@host` は伏せない** —
    /// 資格情報ではないうえ、プロキシの指し先として見たい値。
    private static func containsEmbeddedCredentials(_ value: String) -> Bool {
        guard let separator = value.range(of: "://") else { return false }
        let authority = value[separator.upperBound...].prefix { $0 != "/" }
        guard let at = authority.lastIndex(of: "@") else { return false }
        return authority[..<at].contains(":")
    }

    // MARK: - 失敗の言い換え

    /// 認証まわりの失敗は原因と対処が決まっているので、日本語の説明を頭に足す。
    ///
    /// **元の文言を捨てない。** 言い換えだけにすると、当てはまらなかったときに
    /// 何が起きたのか確かめる手段が無くなる。
    private static func explain(_ stderr: String) -> String {
        guard let hint = authenticationHint(for: stderr) else { return stderr }
        return hint + "\n\n" + condense(stderr)
    }

    private static func authenticationHint(for stderr: String) -> String? {
        // TLS を覗く社内プロキシの下で、独自の CA が信頼されていない。
        // **認証の失敗と混ぜない。** 資格情報は正しく、検証で落ちているだけなので、
        // `gcloud auth login` をいくら実行しても直らない。
        if stderr.contains("CERTIFICATE_VERIFY_FAILED")
            || stderr.contains("self-signed certificate")
            || stderr.contains("certificate signed by unknown authority") {
            return "サーバの証明書を検証できませんでした。認証情報ではなく TLS の問題です。\n"
                + "TLS を覗くプロキシの下では、その CA を信頼させる環境変数"
                + "（`REQUESTS_CA_BUNDLE` や `SSL_CERT_FILE` など）が要ります。\n"
                + "KubeDeck はログインシェルの環境をそのまま子プロセスへ渡すので、"
                + "シェルの設定ファイルでこれらを設定していれば効きます。"
                + "ターミナルでだけ通る場合は、その設定が対話シェルより後で"
                + "行われていないか確かめてください。"
        }

        // kubeconfig が要求する exec 認証プラグインが PATH に無い。
        if let match = stderr.firstMatch(of: /executable (\S+) not found/) {
            let plugin = String(match.1)
            var lines = [
                "kubeconfig が exec 認証プラグイン `\(plugin)` を要求していますが、"
                    + "見つかりませんでした。",
            ]
            if plugin.contains("gke-gcloud-auth-plugin") {
                lines.append("入っていなければ `gcloud components install gke-gcloud-auth-plugin` "
                    + "で入ります。")
            }
            lines.append("入っているのにここで見つからないときは、KubeDeck から見える PATH に "
                + "その場所がありません。設定の「接続」で、いま渡している PATH を確認できます。")
            return lines.joined(separator: "\n")
        }

        // プラグインは動いたが、その先の gcloud が資格情報を出せなかった。
        // gcloud は access token を取り直すのに再ログインや再認証（2 段階認証）を
        // 求めることがあり、それは対話的な操作なので、ここからは代行できない。
        // **プラグインが見つからない話と混ぜない。** 対処がまったく違う。
        if stderr.contains("failure while executing gcloud")
            || stderr.contains("print credential failed") {
            var lines = [
                "exec 認証プラグインは動きましたが、その先の gcloud が"
                    + "アクセストークンを出せませんでした。",
            ]
            if stderr.contains("UNAUTHENTICATED") || stderr.contains("invalid authentication") {
                lines.append("gcloud の資格情報が期限切れか、再認証を求められている状態です。"
                    + "ターミナルで `gcloud auth login` を実行してから、もう一度読み込んでください。")
            }
            // 認証プラグインは標準入力を持たない状態で動く（対話プロンプトが
            // 出ると待ち続けてしまうため、意図的にそうしてある）。
            lines.append("再認証は対話的な操作なので、KubeDeck からは代行できません。"
                + "下の元の文言にある gcloud のコマンドをターミナルでそのまま実行すると、"
                + "同じ失敗になるか確かめられます。")
            return lines.joined(separator: "\n")
        }

        // kubectl 1.26 で in-tree の GCP 認証が消えている。kubeconfig が古い。
        if stderr.contains("gcp auth plugin has been removed") {
            return "kubeconfig がこのクラスタを古い `auth-provider: gcp` 形式で持っています。"
                + "kubectl 1.26 以降はこの形式を読めません。\n"
                + "`gcloud container clusters get-credentials <クラスタ名> "
                + "--region <リージョン>` で作り直してください。"
        }

        // API サーバまで届いていない。**認証の失敗と混ぜない。**
        // 認証が通っているからこそ、ここまで来て接続で落ちている。
        // 上のどれにも当たらなかったときだけ見るので、いちばん最後に置く。
        if stderr.contains("Unable to connect to the server")
            || stderr.contains("context deadline exceeded")
            || stderr.contains("no such host")
            || stderr.contains("connection refused")
            || stderr.contains("i/o timeout") {
            var lines = ["クラスタの API サーバに届きませんでした。認証ではなく経路の問題です。"]
            if let match = stderr.firstMatch(of: /Get \\?"https?:\/\/([^\/"\\]+)/) {
                let host = String(match.1)
                lines.append("宛先は `\(host)` です。"
                    + "プライベートなアドレスであれば、VPN や社内ネットワークからでないと届きません。")
            }
            lines.append("ターミナルで同じコンテキストに `kubectl cluster-info` を実行して、"
                + "そちらも届かないか確かめてください。届かないなら、"
                + "止まっているのは KubeDeck ではなく経路です。")
            return lines.joined(separator: "\n")
        }

        return nil
    }

    /// kubectl は同じ失敗を何度も書き出す（API グループの一覧を引くたびに 1 回）。
    /// 同じ行を並べても読めないので、重複を落とす。
    private static func condense(_ stderr: String) -> String {
        var seen = Set<String>()
        return stderr
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || seen.insert(trimmed).inserted
            }
            .joined(separator: "\n")
    }

    // MARK: - kubeconfig

    struct Contexts: Sendable {
        let all: [String]
        let current: String?
    }

    func contexts() async throws -> Contexts {
        let listed = try await run(["config", "get-contexts", "-o", "name"], context: nil)
        let all = listed.stdoutText
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .sorted()

        // current-context は未設定だと終了コード 1 なので、失敗を握りつぶす。
        let current = try? await run(["config", "current-context"], context: nil)
            .stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)

        return Contexts(all: all, current: current?.isEmpty == false ? current : all.first)
    }

    func namespaces(context: String) async throws -> [String] {
        let objects = try await list(.namespace, context: context, namespace: nil)
        return objects.map(\.name).sorted()
    }

    /// 接続先のサーバ版。到達確認も兼ねる。
    func serverVersion(context: String) async throws -> String {
        let result = try await run(
            ["version", "-o", "json", "--request-timeout=\(requestTimeout)"],
            context: context)
        let root = try JSONDecoder().decode(JSONValue.self, from: result.stdout)
        return root.path("serverVersion.gitVersion")?.stringValue ?? "不明"
    }

    // MARK: - 取得

    func list(
        _ kind: ResourceKind, context: String, namespace: String?
    ) async throws -> [K8sObject] {
        var arguments = ["get", kind.resourceName, "-o", "json",
                         "--request-timeout=\(requestTimeout)"]
        arguments += scope(for: kind, namespace: namespace)
        let result = try await run(arguments, context: context)
        return try K8sObject.list(from: result.stdout, assuming: kind)
    }

    /// 複数種別をまとめて取った結果。
    ///
    /// **「読めた種別」と「拒まれた種別」を分けて返す。** 混ぜると、呼び出し側は
    /// 拒まれた種別を 0 件と数えることになる。
    struct PartialList: Sendable {
        var objects: [K8sObject] = []
        /// 権限が無くて読めなかった種別。**0 件と区別するために持つ。**
        var denied: [ResourceKind] = []

        var isDenied: Bool { !denied.isEmpty }
    }

    /// 複数種別を 1 回の kubectl で取る。概要画面が 10 個以上プロセスを
    /// 起動しないようにするため。まとめて get すると items に kind が入るので、
    /// 呼び出し側で振り分けられる。
    ///
    /// **一部が読めなくても、読めたぶんは捨てない。** `--ignore-not-found` が
    /// 握りつぶすのは NotFound だけで、**Forbidden はそのまま終了コード 1 になる**
    /// （実測。`kubectl get pods,secrets` で secrets だけ拒まれると exit 1）。
    /// にもかかわらず kubectl は**読めた種別を標準出力に書き出している**ので、
    /// 終了コードだけで投げると 200KB の正しい Pod を捨てて「取得できません」と
    /// 出すことになる。Secret だけ読めないクラスタで概要が丸ごと消えていた。
    func list(
        kinds: [ResourceKind], context: String, namespace: String?
    ) async throws -> PartialList {
        guard !kinds.isEmpty else { return PartialList() }
        let names = kinds.map(\.resourceName).joined(separator: ",")
        var arguments = ["get", names, "-o", "json",
                         "--request-timeout=\(requestTimeout)",
                         // 消えた種別（アドオンを外した直後の CRD など）を
                         // 落とす。**権限にはこれは効かない。**
                         "--ignore-not-found=true"]
        // 種別が混ざるので、Namespace 非依存のものが含まれていても
        // --all-namespaces / -n はそのまま通る。
        arguments += scope(for: kinds.contains { $0.isNamespaced } ? .pod : .node,
                           namespace: namespace)

        let result = try await runAllowingPartialFailure(arguments, context: context)
        guard !result.stdout.isEmpty else { return PartialList() }
        return PartialList(
            objects: try K8sObject.list(from: result.stdout),
            denied: Self.deniedKinds(in: result.stderr, among: kinds))
    }

    /// 終了コードが 0 でなくても、標準出力が読めるなら結果として受け取る。
    ///
    /// **どこまでを許すかを絞る。** 打ち切りは従来どおり投げる。読めた JSON が
    /// 1 つも無いときも投げる（認証で落ちていれば標準出力は空になるので、
    /// ここで本物の失敗を握りつぶすことはない）。
    private func runAllowingPartialFailure(
        _ arguments: [String], context: String?
    ) async throws -> CommandResult {
        do {
            return try await run(arguments, context: context)
        } catch let error as CommandError where error.partialStdout != nil {
            // `run` は失敗のときに標準出力を捨てるので、拾い直せるように
            // CommandError へ載せてある。
            return CommandResult(
                exitCode: error.exitCode, stdout: error.partialStdout ?? Data(),
                stderr: error.rawStderr)
        }
    }

    /// stderr から、権限で拒まれた種別を拾う。
    ///
    /// kubectl は `<resource> is forbidden: ...` という形で resource 名（複数形）を
    /// 書き出す。要求した種別のうち、そこに現れたものだけを拒まれた扱いにする
    /// （**当てはまらない失敗を「権限が無い」ことにしない**）。
    ///
    /// 実測した書式（グループ付きとグループ無しの両方が来る）:
    /// ```
    /// Error from server (Forbidden): secrets is forbidden: ...
    /// Error from server (Forbidden): deployments.apps is forbidden: ...
    /// Error from server (Forbidden): ingresses.networking.k8s.io is forbidden: ...
    /// ```
    /// private にしないのは、この書式に依存しているところをテストで固めるため。
    static func deniedKinds(
        in stderr: String, among kinds: [ResourceKind]
    ) -> [ResourceKind] {
        guard stderr.contains("forbidden") else { return [] }
        var denied = Set<String>()
        for match in stderr.matches(of: /(\S+?) is forbidden/) {
            // `pods.metrics.k8s.io` のようにグループが付くことがある。
            denied.insert(String(match.1).split(separator: ".").first.map(String.init) ?? "")
        }
        return kinds.filter { denied.contains($0.resourceName) }
    }

    /// クラスタに入っている CRD の種別。
    ///
    /// `api-resources` ではなく CRD そのものを読む。表示列
    /// （`additionalPrinterColumns`）が要るためで、これは CRD にしか無い。
    func customResourceTypes(context: String) async -> [CustomResourceType] {
        guard let result = try? await run(
            ["get", "customresourcedefinitions", "-o", "json",
             "--request-timeout=\(requestTimeout)", "--ignore-not-found=true"],
            context: context),
            !result.stdout.isEmpty,
            let objects = try? K8sObject.list(from: result.stdout)
        else { return [] }

        return objects
            .compactMap(CustomResourceType.init(crd:))
            .sorted { lhs, rhs in
                lhs.group == rhs.group ? lhs.kind < rhs.kind : lhs.group < rhs.group
            }
    }

    /// 任意の種別の一覧。組み込みでも CRD でも同じ経路で引く。
    func list(
        resource: String, namespaced: Bool, context: String, namespace: String?
    ) async throws -> [K8sObject] {
        var arguments = ["get", resource, "-o", "json",
                         "--request-timeout=\(requestTimeout)"]
        if namespaced {
            if let namespace, !namespace.isEmpty {
                arguments += ["-n", namespace]
            } else {
                arguments.append("--all-namespaces")
            }
        }
        let result = try await run(arguments, context: context)
        return try K8sObject.list(from: result.stdout)
    }

    /// イベントは新しい順に見たいので、取得時に並べ替える。
    func events(context: String, namespace: String?, limit: Int = 200) async throws -> [K8sObject] {
        var arguments = ["get", "events", "-o", "json",
                         "--sort-by=.lastTimestamp",
                         "--request-timeout=\(requestTimeout)"]
        arguments += scope(for: .event, namespace: namespace)
        let result = try await run(arguments, context: context)
        let objects = try K8sObject.list(from: result.stdout, assuming: .event)
        return Array(objects.reversed().prefix(limit))
    }

    /// 1 つのオブジェクトに紐づくイベント。
    ///
    /// **一覧のイベントを手元で絞って使わない。** イベントは既定で 1 時間ほどで
    /// 消え、こちらが持っているのは直近 200 件だけ。関係するイベントがその外に
    /// あると「イベントはありません」と出るが、無いのではなく引いていない。
    /// **対象を指定して引き直す**（`--field-selector` はサーバ側で絞るので、
    /// 200 件の窓に関係なく対象のぶんが返る）。
    ///
    /// **uid で引く。** 名前で引くと、同じ名前で作り直された前の世代の
    /// イベントが混ざる（Pod は再作成のたびに uid が変わる）。uid が無いのは
    /// 合成したオブジェクトぐらいなので、そのときだけ名前と種別に落とす。
    func events(
        for object: K8sObject, context: String, limit: Int = 100
    ) async throws -> [K8sObject] {
        var selectors: [String] = []
        if object.uid.isEmpty {
            selectors.append("involvedObject.name=\(object.name)")
            if !object.rawKind.isEmpty {
                selectors.append("involvedObject.kind=\(object.rawKind)")
            }
        } else {
            selectors.append("involvedObject.uid=\(object.uid)")
        }

        var arguments = ["get", "events", "-o", "json",
                         "--field-selector=\(selectors.joined(separator: ","))",
                         "--request-timeout=\(requestTimeout)"]
        // Namespace を持たないもの（Node / PV）のイベントは default に載る。
        // 決め打ちせず全体から引く。
        if let namespace = object.namespace, !namespace.isEmpty {
            arguments += ["-n", namespace]
        } else {
            arguments.append("--all-namespaces")
        }

        let result = try await run(arguments, context: context)
        let objects = try K8sObject.list(from: result.stdout, assuming: .event)
        // **`--sort-by=.lastTimestamp` に頼らない。** `lastTimestamp` を持たず
        // `eventTime` しか無いイベントが実在する（orbstack の k3s で `Scheduled`
        // がそうだった）。kubectl は落ちないが、そのイベントを**時刻が無いもの
        // として扱う**ので、実際にはさっき起きたのに最古の位置へ並ぶ。
        // `lastSeen` は `eventTime` と `deprecatedLastTimestamp` まで見るので、
        // 並べ替えはこちらで持つ。
        let sorted = objects.sorted {
            (ResourceTable.lastSeen($0) ?? .distantPast)
                > (ResourceTable.lastSeen($1) ?? .distantPast)
        }
        return Array(sorted.prefix(limit))
    }

    /// このオブジェクトを対象にしている HPA。
    ///
    /// **`kubectl scale` の前に見る。** HPA 管理下のワークロードにレプリカ数を
    /// 書き込んでも、次の調整周期（既定 15 秒）で HPA が戻す。断りが無いと
    /// 「効かなかった」としか見えず、原因がアプリの側にあるように読める。
    ///
    /// 対象は名前と種別で突き合わせる。`scaleTargetRef` は uid を持たない
    /// （HPA は「その名前のもの」を指す作りで、作り直しても追随する）。
    func autoscalers(for object: K8sObject, context: String) async throws -> [K8sObject] {
        var arguments = ["get", ResourceKind.horizontalPodAutoscaler.resourceName,
                         "-o", "json",
                         "--request-timeout=\(requestTimeout)",
                         "--ignore-not-found=true"]
        if let namespace = object.namespace, !namespace.isEmpty {
            arguments += ["-n", namespace]
        }
        let result = try await run(arguments, context: context)
        let all = try K8sObject.list(from: result.stdout, assuming: .horizontalPodAutoscaler)
        return all.filter { hpa in
            guard let ref = hpa.spec?["scaleTargetRef"] else { return false }
            guard ref["name"]?.stringValue == object.name else { return false }
            // 種別まで見る。同じ名前の Deployment と StatefulSet は同居できる。
            guard let kind = ref["kind"]?.stringValue, !kind.isEmpty else { return true }
            return kind == object.rawKind
        }
    }

    /// resource は呼び出し側が持っている種別名を渡す。オブジェクトから
    /// 引くと、CRD のように組み込みの enum に無い種別が扱えない。
    func yaml(
        resource: String, object: K8sObject, context: String
    ) async throws -> String {
        var arguments = ["get", resource, object.name, "-o", "yaml",
                         "--request-timeout=\(requestTimeout)"]
        if let namespace = object.namespace {
            arguments += ["-n", namespace]
        }
        return try await run(arguments, context: context).stdoutText
    }

    private func scope(for kind: ResourceKind, namespace: String?) -> [String] {
        guard kind.isNamespaced else { return [] }
        guard let namespace, !namespace.isEmpty else { return ["--all-namespaces"] }
        return ["-n", namespace]
    }

    // MARK: - メトリクス

    /// metrics-server が入っているか。
    ///
    /// APIService が登録されていても実体が落ちていれば取得は失敗するので、
    /// 登録の有無ではなく実際に一覧を引いて確かめる。
    ///
    /// **`--raw` で引かない。** `--raw` は discovery を通らない素の HTTP GET で、
    /// Connect Gateway 越しの GKE では `/apis/metrics.k8s.io/v1beta1/pods` が
    /// 404 になる（`kubectl top` は見えるのに、である）。`kubectl get <resource>`
    /// なら discovery を通るので `top` と同じ経路になり、そこで見えるものは必ず
    /// 引ける。返る JSON の形は `--raw` と同じなので、読む側は変わらない。
    ///
    /// **ノードだけで判定しない。** 管理されたクラスタはノードの指標を拒みつつ
    /// Pod の指標は通すことがある。**1 つでも引けたなら「入っている」。**
    func metricsServerAvailable(context: String, namespace: String? = nil) async -> Bool {
        var attempts: [[String]] = [
            ["get", "nodes.metrics.k8s.io", "-o", "name"],
            ["get", "pods.metrics.k8s.io", "-o", "name", "--all-namespaces"],
        ]
        if let namespace, !namespace.isEmpty {
            attempts.append(["get", "pods.metrics.k8s.io", "-o", "name", "-n", namespace])
        }

        for attempt in attempts {
            if (try? await run(
                attempt + ["--request-timeout=\(requestTimeout)"],
                context: context)) != nil {
                return true
            }
        }
        return false
    }

    /// Pod と Node の現在の使用量。
    ///
    /// 片方が取れなくてももう片方は返す。metrics-server が起動した直後は
    /// Pod 側だけ空、ということが起きるため。
    func metrics(context: String, namespace: String?) async -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()

        if let data = try? await run(
            ["get", "nodes.metrics.k8s.io", "-o", "json",
             "--request-timeout=\(requestTimeout)"],
            context: context).stdout,
           let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
            for item in root["items"]?.arrayValue ?? [] {
                guard let name = item.path("metadata.name")?.stringValue else { continue }
                snapshot.nodes[name] = Self.usage(from: item["usage"])
            }
        }

        var podArguments = ["get", "pods.metrics.k8s.io", "-o", "json",
                            "--request-timeout=\(requestTimeout)"]
        if let namespace, !namespace.isEmpty {
            podArguments += ["-n", namespace]
        } else {
            podArguments.append("--all-namespaces")
        }
        if let data = try? await run(podArguments, context: context).stdout,
           let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
            for item in root["items"]?.arrayValue ?? [] {
                guard let name = item.path("metadata.name")?.stringValue else { continue }
                let key = MetricsSnapshot.key(
                    namespace: item.path("metadata.namespace")?.stringValue, name: name)

                var total = ResourceUsage()
                var perContainer: [String: ResourceUsage] = [:]
                for container in item["containers"]?.arrayValue ?? [] {
                    let usage = Self.usage(from: container["usage"])
                    total = total + usage
                    if let containerName = container["name"]?.stringValue {
                        perContainer[containerName] = usage
                    }
                }
                snapshot.pods[key] = total
                snapshot.containers[key] = perContainer
            }
        }

        return snapshot
    }

    private static func usage(from value: JSONValue?) -> ResourceUsage {
        ResourceUsage(
            cpuCores: value?["cpu"]?.stringValue.flatMap(Quantity.parse) ?? 0,
            memoryBytes: value?["memory"]?.stringValue.flatMap(Quantity.parse) ?? 0)
    }

    /// API サーバへの生アクセス。メトリクスと Prometheus のプロキシで使う。
    func raw(_ path: String, context: String) async throws -> Data {
        try await run(
            ["get", "--raw", path, "--request-timeout=\(requestTimeout)"],
            context: context
        ).stdout
    }

    // MARK: - 操作

    func delete(resource: String, object: K8sObject, context: String) async throws {
        var arguments = ["delete", resource, object.name, "--wait=false"]
        if let namespace = object.namespace {
            arguments += ["-n", namespace]
        }
        try await run(arguments, context: context)
    }

    func scale(_ object: K8sObject, to replicas: Int, context: String) async throws {
        guard let kind = object.kind, kind.isScalable else { return }
        var arguments = ["scale", kind.resourceName, object.name, "--replicas=\(replicas)"]
        if let namespace = object.namespace {
            arguments += ["-n", namespace]
        }
        try await run(arguments, context: context)
    }

    func rolloutRestart(_ object: K8sObject, context: String) async throws {
        guard let kind = object.kind, kind.isRestartable else { return }
        var arguments = ["rollout", "restart", "\(kind.resourceName)/\(object.name)"]
        if let namespace = object.namespace {
            arguments += ["-n", namespace]
        }
        try await run(arguments, context: context)
    }

    func cordon(_ node: K8sObject, unschedulable: Bool, context: String) async throws {
        try await run([unschedulable ? "cordon" : "uncordon", node.name], context: context)
    }

    // MARK: - ログ

    struct LogOptions: Sendable {
        var container: String?
        var follow: Bool = true
        var tailLines: Int = 500
        var previous: Bool = false
        var timestamps: Bool = false
    }

    /// Pod オブジェクトではなく名前で受ける。ログは別ウインドウで開くので、
    /// 一覧が読み直されてオブジェクトが差し替わっても影響を受けないようにする。
    func logStream(
        namespace: String, pod: String, options: LogOptions, context: String
    ) throws -> (lines: AsyncStream<[String]>, handle: ProcessHandle) {
        let environment = try environment()
        var arguments = ["--context", context, "logs", pod]
        if !namespace.isEmpty { arguments += ["-n", namespace] }
        if let container = options.container { arguments += ["-c", container] }
        arguments += ["--tail=\(options.tailLines)"]
        if options.follow { arguments.append("--follow") }
        if options.previous { arguments.append("--previous") }
        if options.timestamps { arguments.append("--timestamps") }

        return ProcessRunner.stream(
            executable: environment.executable,
            arguments: arguments,
            environment: environment.variables)
    }
}
