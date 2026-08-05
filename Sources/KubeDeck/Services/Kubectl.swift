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

    // MARK: - API の一覧（discovery）のキャッシュ

    /// kubectl が API の一覧を覚えておく場所。`--cache-dir` で必ず指定する。
    ///
    /// **既定（`~/.kube/cache`）を使わない。** そこはターミナルの kubectl と
    /// 共有の置き場所で、**どちらかが壊した一覧をもう一方も読む。**
    ///
    /// 実際に踏んだ壊れ方: `discovery/<サーバ>/servergroups.json` が、本来 63
    /// グループあるところ 1 グループだけの状態で残っていた。
    ///
    /// ```json
    /// {"kind":"APIGroupList","groups":[{"name":"","versions":null,
    ///  "preferredVersion":{"groupVersion":"","version":""}}]}
    /// ```
    ///
    /// コアグループ（`name: ""`）の `versions` が null なので、kubectl は
    /// 「v1 というバージョンが存在しない」と読み、`pods` も `services` も
    /// `configmaps` も解決できなくなる。出る文言は
    /// `the server doesn't have a resource type "pods"` で、アプリ側では
    /// **全種別が一斉に「知らない種別」になり、概要も配置も一覧も丸ごと消える。**
    /// クラスタにも認証にも異常が無いので、原因を kubectl 側に探しに行けない
    /// （ターミナルの kubectl も同じファイルを読むので、そちらでも同じ症状が出る）。
    ///
    /// **書き込みが途中で切れたわけではない。** 残っていたのは valid な JSON で、
    /// 縮退した応答をそのまま覚えている。**誰が壊したかに関わらず起こりうる**ので、
    /// 「壊さない」ではなく「巻き込まない」「自力で捨てて引き直す」で受ける
    /// （`resetDiscoveryCache`）。
    static let cacheDirectory: String = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.piyoraik.KubeDeck",
                                    isDirectory: true)
            .appendingPathComponent("kube", isDirectory: true)
            .path
    }()

    /// 最後に discovery のキャッシュを捨てた時刻。設定の「接続」に出す。
    private(set) var lastDiscoveryReset: Date?

    /// 捨て直しの間隔。**毎回捨てない。**
    ///
    /// 本当に存在しない種別（外した CRD など）を毎周期たずねる画面があると、
    /// そのたびに全 API グループを引き直すことになる。知らない種別を 1 回 get
    /// するだけで kubectl は覚えている一覧を丸ごと捨てて引き直すので、遅い
    /// クラスタではそれ自体が discovery を失敗しやすくする。
    private static let discoveryResetCooldown: TimeInterval = 60

    /// 覚えている API の一覧を捨てる。捨てたときだけ true。
    ///
    /// **アプリ専用のキャッシュだから捨てられる。** ターミナルと共有していたら、
    /// こちらの都合で相手の一覧まで消すことになる。
    ///
    /// 並行して走っている別の kubectl が同じ場所を読んでいることはある
    /// （概要は 4 本まとめて投げる）。捨てられた側は自分で引き直すので、
    /// 失敗しても次の自動更新で戻る。**間隔を空けているのはこのためでもある。**
    private func resetDiscoveryCache() -> Bool {
        if let lastDiscoveryReset,
           Date().timeIntervalSince(lastDiscoveryReset) < Self.discoveryResetCooldown {
            return false
        }
        guard Self.removeDiscoveryCache(in: Self.cacheDirectory) else { return false }
        lastDiscoveryReset = Date()
        return true
    }

    /// `<キャッシュ>/discovery` を消す。消したときだけ true。
    ///
    /// **消せなかったときに true を返さない。** 呼び出し側はこれを見て
    /// 引き直すかどうかを決めるので、消えていないのに引き直すと、同じ失敗を
    /// もう 1 度取りに行くだけになる。
    ///
    /// 場所を引数で受けるのは、テストで本物のキャッシュを消さないため。
    /// **消す先を間違えると黙って直らなくなる**（消えていないのに引き直す）ので、
    /// ここは `KubectlTests` で固めてある。
    static func removeDiscoveryCache(in cacheDirectory: String) -> Bool {
        let discovery = URL(fileURLWithPath: cacheDirectory, isDirectory: true)
            .appendingPathComponent("discovery", isDirectory: true)
        guard FileManager.default.fileExists(atPath: discovery.path) else { return false }
        return (try? FileManager.default.removeItem(at: discovery)) != nil
    }

    /// 「その種別を知らない」と言われたか。
    ///
    /// **これだけでは、キャッシュが壊れているのか本当に無いのかは決まらない。**
    /// 決められないからこそ、1 度だけ捨てて引き直して**確かめる**。
    /// 書式に依存しているので、`unknownKinds` と同じくテストで固めてある。
    static func mentionsMissingResourceType(_ stderr: String) -> Bool {
        stderr.contains("doesn't have a resource type")
    }

    // MARK: - 実行

    /// kubectl を 1 度呼ぶ。
    ///
    /// **「種別が無い」で終わらせない。** 覚えている API の一覧が縮退していると、
    /// 実在する `pods` すら `the server doesn't have a resource type "pods"` に
    /// なる（`cacheDirectory` の説明を参照）。文言からは「本当に無い」のか
    /// 「一覧が欠けている」のかが決まらないので、**1 度だけ一覧を捨てて引き直し、
    /// どちらだったかを確かめる。** 引き直しても同じなら、それは本当に無い。
    ///
    /// **捨てられなかったときは引き直さない。** 間隔を空けている最中か、
    /// そもそも覚えていない（＝キャッシュのせいではない）ということなので、
    /// もう 1 度同じことをしても結果は変わらない。
    @discardableResult
    func run(_ arguments: [String], context: String?) async throws -> CommandResult {
        do {
            return try await execute(arguments, context: context)
        } catch let error as CommandError
            where Self.mentionsMissingResourceType(error.rawStderr) {
            guard resetDiscoveryCache() else { throw error }
            return try await execute(arguments, context: context)
        }
    }

    private func execute(_ arguments: [String], context: String?) async throws -> CommandResult {
        let environment = try environment()
        var fullArguments = arguments
        // **必ず付ける。** 付けないと `~/.kube/cache` をターミナルと共有する。
        fullArguments.insert("--cache-dir=\(Self.cacheDirectory)", at: 0)
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

    /// API の一覧を覚えている場所と、最後に捨てた時刻。設定画面に出す。
    ///
    /// **黙って直さない。** 自力で捨てて引き直すのは正しいが、それが何度も
    /// 起きているなら見に行く先がある（縮退した応答を返しているゲートウェイなど）。
    /// 復帰のたびに帯を出すほどではないので、確かめられる場所にだけ置く。
    func resolvedCacheDirectory() -> (path: String, lastReset: Date?) {
        (Self.cacheDirectory, lastDiscoveryReset)
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
        guard let hint = authenticationHint(for: stderr) ?? discoveryHint(for: stderr) else {
            return stderr
        }
        return hint + "\n\n" + condense(stderr)
    }

    /// 「サーバがその種別を知らない」の言い換え。
    ///
    /// **認証や経路の失敗と混ぜない。** ここまで来ている時点で API サーバとは
    /// 話せている。**「無い」と断定もしない** — 本当に無いのか、kubectl の
    /// discovery に出てこないだけなのかは、この文言からは決まらない。
    /// 見分け方のほうを書く。
    ///
    /// `authenticationHint` の後に見る。届いていないときは kubectl が
    /// discovery を引けず、この形の失敗も一緒に書き出すことがある。
    private static func discoveryHint(for stderr: String) -> String? {
        guard let match = stderr.firstMatch(
            of: #/doesn't have a resource type "([^"]+)"/#) else { return nil }
        return """
            クラスタに `\(match.1)` という種別が見つかりませんでした。認証や経路ではなく、\
            kubectl がこの種別を解決できていません。
            考えられるのは 2 つで、対処が違います。
            ・本当に無い（CRD やアドオンを外した、その API グループを持たないクラスタ）。
            ・API の一覧（discovery）のほうが欠けている。集約 API サーバ（APIService）が\
            応答しないと、そのグループが丸ごと一覧から落ちます。
            KubeDeck はこの文言を受けると、覚えている一覧を捨てて 1 度だけ引き直します\
            （捨て直しは 1 分に 1 回まで）。それでも同じなので、覚えている一覧が古いだけ、\
            という線は薄いです。
            ターミナルで `kubectl api-resources` に出るか、`kubectl get apiservices` に\
            AVAILABLE=False が無いかを確かめてください。KubeDeck の一覧は\
            ターミナルとは別に持っているので（設定の「接続」に置き場所を出しています）、\
            片方だけで起きることもあります。
            """
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
        /// サーバがその名前の種別を知らなかったもの。
        ///
        /// **拒まれたのとは別に持つ。** 見る場所が違う。拒まれたのは権限の話で、
        /// こちらは「そもそも API に無い」か「kubectl の discovery に出てこない」
        /// 話。**0 件とも混ぜない** — 数えられていないだけ。
        var unknown: [ResourceKind] = []

        var isDenied: Bool { !denied.isEmpty }
        /// 数に入れてはいけない種別。拒まれたものと知られていないもの。
        var uncounted: [ResourceKind] { denied + unknown }
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
        try await list(kinds: kinds, context: context, namespace: namespace, unknown: [])
    }

    /// - Parameter unknown: ここまでに「サーバが知らない」と言われた種別。
    ///   除いて引き直すたびに積み上がる。
    private func list(
        kinds: [ResourceKind], context: String, namespace: String?, unknown: [ResourceKind]
    ) async throws -> PartialList {
        guard !kinds.isEmpty else { return PartialList(unknown: unknown) }
        let names = kinds.map(\.resourceName).joined(separator: ",")
        var arguments = ["get", names, "-o", "json",
                         "--request-timeout=\(requestTimeout)",
                         // **これは NotFound にしか効かない。** 権限にも、
                         // 知らない種別にも効かないので、どちらも別に始末する。
                         "--ignore-not-found=true"]
        // 種別が混ざるので、Namespace 非依存のものが含まれていても
        // --all-namespaces / -n はそのまま通る。
        arguments += scope(for: kinds.contains { $0.isNamespaced } ? .pod : .node,
                           namespace: namespace)

        let result: CommandResult
        do {
            result = try await runAllowingPartialFailure(arguments, context: context)
        } catch let error as CommandError {
            // **知らない種別 1 つで全部を捨てない。** ここは Forbidden とは
            // 壊れ方が違う。kubectl は要求を組み立てる段で諦めるので、
            // **標準出力には 1 バイトも来ない**（実測。`get pods,hoges` は
            // exit 1・stdout 0 バイト）。つまり Pod も Service も読めていたのに
            // 画面はまるごと「取得できません」になる。実際そうなっていた。
            //
            // **1 回の引き直しで済ませない。** kubectl が名前を出すのは
            // **最初の 1 つだけ**なので（`get pods,hoges,fugas` でも `hoges` しか
            // 出ない）、残った種別で引き直しては除く、を繰り返す。
            let missing = Self.unknownKinds(in: error.rawStderr, among: kinds)
            guard !missing.isEmpty else { throw error }
            return try await list(
                kinds: kinds.filter { !missing.contains($0) },
                context: context, namespace: namespace, unknown: unknown + missing)
        }
        guard !result.stdout.isEmpty else { return PartialList(unknown: unknown) }
        return PartialList(
            objects: try K8sObject.list(from: result.stdout),
            denied: Self.deniedKinds(in: result.stderr, among: kinds),
            unknown: unknown)
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

    /// stderr から、サーバが知らないと言われた種別を拾う。
    ///
    /// ```
    /// error: the server doesn't have a resource type "hoges"
    /// ```
    ///
    /// **書式に 2 つ依存している。** どちらも実測で確かめてある。
    /// - **グループが落ちる。** `hoges.example.com` と頼んでも `"hoges"` としか
    ///   書かれない。だから要求した種別のほうを最初の `.` で切って突き合わせる。
    /// - **1 つしか書かれない。** 知らない種別が複数あっても、最初に当たった
    ///   1 つで諦める。呼び出し側が引き直しを繰り返すのはこのため。
    static func unknownKinds(
        in stderr: String, among kinds: [ResourceKind]
    ) -> [ResourceKind] {
        guard stderr.contains("doesn't have a resource type") else { return [] }
        var missing = Set<String>()
        for match in stderr.matches(of: #/doesn't have a resource type "([^"]+)"/#) {
            missing.insert(String(match.1))
        }
        // **要求した種別に当たったものだけ。** 当てはまらない失敗を
        // 「サーバが知らない」ことにしない。
        return kinds.filter { kind in
            missing.contains(kind.resourceName.split(separator: ".").first.map(String.init) ?? "")
        }
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
    ///
    /// **要求した種別を `assuming:` で補う。** 単一種別の `get -o json` は
    /// items に `kind` を入れてこない版があり、そうなると `K8sObject.kind` が
    /// nil になる。一覧の表示には効かないので気付きにくいが、種別で分岐する
    /// ところ（詳細パネルの「ログ」、`PodLogRequest(object:)`）が黙って
    /// 消える。CRD には対応する値が無いので、そのときだけ nil を渡す。
    func list(
        resource: String, namespaced: Bool, context: String, namespace: String?,
        assuming kind: ResourceKind? = nil
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
        return try K8sObject.list(from: result.stdout, assuming: kind)
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

    /// ラベルで絞った Pod。Job が掴んでいる Pod を引くのに使う。
    ///
    /// **サーバ側で絞る。** Namespace の Pod を全部引いて手元で
    /// `ownerReferences` を見ることもできるが、Pod が数百ある Namespace では
    /// ログを 1 つ開くたびに全件を運ぶことになる。
    ///
    /// **`--ignore-not-found` を付けても「0 件」と「引けなかった」は混ざらない。**
    /// 権限やネットワークで落ちたときは従来どおり投げる（`run` が投げる）ので、
    /// 空の配列が返るのは本当に 1 件も無いときだけ。
    func pods(
        matchingLabels labels: [String: String], namespace: String, context: String
    ) async throws -> [K8sObject] {
        guard !labels.isEmpty else { return [] }
        let selector = labels
            .map { "\($0.key)=\($0.value)" }
            .sorted()
            .joined(separator: ",")

        var arguments = ["get", ResourceKind.pod.resourceName, "-o", "json",
                         "--selector=\(selector)",
                         "--request-timeout=\(requestTimeout)",
                         "--ignore-not-found=true"]
        if !namespace.isEmpty { arguments += ["-n", namespace] }

        let result = try await run(arguments, context: context)
        guard !result.stdout.isEmpty else { return [] }
        return try K8sObject.list(from: result.stdout, assuming: .pod)
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

    /// まとめて消す。
    ///
    /// **1 つずつ起こさない。** 選んだ数だけ kubectl が立ち上がる。`-n` は
    /// 1 つしか渡せないので、Namespace ごとに 1 回にまとめる。
    ///
    /// **途中で止めない。** 1 つの Namespace が権限で拒まれても、残りは
    /// 消せる。ここで抜けると「どこまで消えたのか」が分からなくなる。
    /// 最後まで試して、失敗したぶんだけをまとめて投げる。
    func delete(resource: String, objects: [K8sObject], context: String) async throws {
        let groups = Dictionary(grouping: objects) { $0.namespace ?? "" }
        var failures: [String] = []

        for (namespace, group) in groups.sorted(by: { $0.key < $1.key }) {
            var arguments = ["delete", resource] + group.map(\.name) + ["--wait=false"]
            if !namespace.isEmpty { arguments += ["-n", namespace] }
            do {
                try await run(arguments, context: context)
            } catch {
                failures.append(
                    namespace.isEmpty
                        ? error.localizedDescription
                        : "\(namespace): \(error.localizedDescription)")
            }
        }

        guard failures.isEmpty else {
            throw CommandError(
                command: "kubectl delete \(resource)",
                exitCode: 1,
                message: failures.count == groups.count
                    ? failures.joined(separator: "\n\n")
                    // **一部だけ消えたことを黙らない。** 全部失敗したのと
                    // 見分けが付かないと、残っている行の意味が読めない。
                    : "一部の Namespace で削除できませんでした。"
                        + "他は削除を要求済みです。\n\n"
                        + failures.joined(separator: "\n\n"))
        }
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

    struct DrainOptions: Sendable, Equatable {
        /// emptyDir の中身は退避すると**消える**。付けないと drain は止まる。
        var deleteEmptyDirData = false
        /// ReplicaSet などに管理されていない Pod も消す。**作り直されない。**
        var force = false
        /// 実際には動かさず、何が起きるかだけを返す。
        var dryRun = false
    }

    /// ノードから Pod を退避させる。
    ///
    /// **`--force` と `--delete-emptydir-data` を既定にしない。** 前者は
    /// 管理下にない Pod（消したら二度と作られない）を消し、後者は emptyDir の
    /// 中身を捨てる。どちらも戻せないので、押した人に選ばせる。
    ///
    /// **`--ignore-daemonsets` は既定で付ける。** DaemonSet の Pod はそもそも
    /// 退避できず（消しても同じノードに作り直される）、付けないと drain は
    /// 必ず止まる。ここを選ばせても、選べる答えが 1 つしかない。
    ///
    /// **`--timeout` を必ず付ける。** 既定は 0（無制限）で、退避できない Pod が
    /// 1 つあると待ち続ける。`run` のプロセス上限で殺すこともできるが、それだと
    /// 「こちらが殺した」になり、kubectl 自身の理由（PodDisruptionBudget で
    /// 弾かれた、など）が残らない。
    @discardableResult
    func drain(
        _ node: K8sObject, options: DrainOptions, context: String
    ) async throws -> String {
        // `requestTimeout` は "15s" のように単位まで含む。ここで `s` を足さない。
        var arguments = ["drain", node.name,
                         "--ignore-daemonsets",
                         "--timeout=\(requestTimeout)",
                         "--request-timeout=\(requestTimeout)"]
        if options.deleteEmptyDirData { arguments.append("--delete-emptydir-data") }
        if options.force { arguments.append("--force") }
        if options.dryRun { arguments.append("--dry-run=server") }
        return try await run(arguments, context: context).stdoutText
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
        // ここは `run` を通らないので、キャッシュの置き場所を自分で渡す
        // （置き場所が 2 つあると、片方だけ壊れたときに症状が食い違う）。
        var arguments = ["--cache-dir=\(Self.cacheDirectory)", "--context", context, "logs", pod]
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
