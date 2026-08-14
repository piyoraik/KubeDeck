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
            return String(localized: """
                kubectl が見つかりません。
                Homebrew なら `brew install kubectl` で入ります。
                すでに入っている場合は、/opt/homebrew/bin か /usr/local/bin から辿れるか確認してください。
                """)
        }
    }
}

/// kubectl を呼ぶ前に分かる、こちら側の間違い。
///
/// **黙って何もしないで返さない。** 効かない種別に `rollout` を投げる経路は
/// 画面側で塞いであるが、塞ぎ忘れたときに `return` で握りつぶすと
/// 「押しても何も起きない」だけになり、どこが悪いのか画面からは分からない。
enum KubectlError: LocalizedError {
    case unsupportedRollout(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedRollout(let kind):
            return String(localized: "\(kind) には rollout が効きません。")
        }
    }
}

/// 常駐 proxy 経由の取得が失敗したときに、**proxy が書き出した文言まで含めて**
/// 伝える型。
///
/// 帯は最初の段落を見出しにして残りを畳むので、**言い換えを先に置く**
/// （`RootView.splitError` と同じ約束）。
struct TransportError: LocalizedError {
    /// HTTP の応答から分かること（「N 秒待っても応答がありません」など）。
    let summary: String
    /// proxy が書き出した文言を `Kubectl.explain` に通したもの。
    let detail: String

    var errorDescription: String? {
        if detail.isEmpty { return summary }
        // **同じ文を 2 度出さない。** 言い換え（`Kubectl.explain`）は元の文言を
        // 末尾に残す作りなので、そのまま繋ぐと同じ段落が並ぶ。
        if summary.isEmpty || detail.contains(summary) { return detail }
        return "\(detail)\n\n\(summary)"
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

    /// 読み取りを常駐 proxy 経由の HTTP で行うか。書き込みは常に kubectl。
    private var usesAPIProxy = true
    /// proxy を立てられなかった理由。**黙って kubectl 経由へ流さないために持つ。**
    private var proxyFailure: String?

    func configure(timeoutSeconds: Int, executableOverride: String, usesAPIProxy: Bool = true) {
        let trimmed = executableOverride.trimmingCharacters(in: .whitespaces)
        // 場所が変わったら、覚えている解決結果を捨てる。
        if trimmed != self.executableOverride { cachedEnvironment = nil }
        self.timeoutSeconds = max(3, timeoutSeconds)
        self.executableOverride = trimmed
        if usesAPIProxy != self.usesAPIProxy {
            self.usesAPIProxy = usesAPIProxy
            proxyFailure = nil
            // 切ったなら常駐も畳む。入れ直したときは次の取得で立ち上がる。
            let stopping = !usesAPIProxy
            Task {
                if stopping {
                    await ClusterProxy.shared.stopAll()
                    await APIDiscovery.shared.invalidateAll()
                }
            }
        }
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

    /// `resetDiscoveryCache()` の結果。
    ///
    /// **「捨てた／捨てなかった」の 2 値にしない。** 捨てなかった理由には
    /// **意味の違う 2 つ**があり、混ぜると「確かめていないこと」を「確かめた」
    /// として使うことになる。実際そうなっていた ——`list(kinds:)` が一過性の
    /// 失敗で種別を恒久的に外し、core の種別が configmaps → secrets →
    /// persistentvolumeclaims と次々に消えていた（アプリの stderr で実測）。
    enum DiscoveryReset {
        /// 捨てた。呼び出し側は引き直して**確かめられる**。
        case cleared
        /// そもそも覚えていない。＝いま引いたものが最新なので、**確かめ済み**。
        case nothingCached
        /// 間隔を空けている最中か、捨てられなかった。**確かめていない。**
        case notChecked
    }

    /// 覚えている API の一覧を捨てる。
    ///
    /// **アプリ専用のキャッシュだから捨てられる。** ターミナルと共有していたら、
    /// こちらの都合で相手の一覧まで消すことになる。
    ///
    /// 並行して走っている別の kubectl が同じ場所を読んでいることはある
    /// （概要は 4 本まとめて投げる）。捨てられた側は自分で引き直すので、
    /// 失敗しても次の自動更新で戻る。**間隔を空けているのはこのためでもある。**
    private func resetDiscoveryCache() -> DiscoveryReset {
        // **覚えていないことを「捨てられなかった」と混ぜない。** 覚えていない
        // なら、いま失敗した呼び出しは discovery を引いたうえで失敗している。
        // つまりそれは確かめた結果であって、引き直す意味が無い。
        guard Self.hasDiscoveryCache(in: Self.cacheDirectory) else { return .nothingCached }
        if let lastDiscoveryReset,
           Date().timeIntervalSince(lastDiscoveryReset) < Self.discoveryResetCooldown {
            return .notChecked
        }
        guard Self.removeDiscoveryCache(in: Self.cacheDirectory) else { return .notChecked }
        lastDiscoveryReset = Date()
        return .cleared
    }

    private static func discoveryURL(in cacheDirectory: String) -> URL {
        URL(fileURLWithPath: cacheDirectory, isDirectory: true)
            .appendingPathComponent("discovery", isDirectory: true)
    }

    static func hasDiscoveryCache(in cacheDirectory: String) -> Bool {
        FileManager.default.fileExists(atPath: discoveryURL(in: cacheDirectory).path)
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
        let discovery = discoveryURL(in: cacheDirectory)
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
    func run(
        _ arguments: [String], context: String?, input: Data? = nil
    ) async throws -> CommandResult {
        do {
            return try await execute(arguments, context: context, input: input)
        } catch let error as CommandError
            where Self.mentionsMissingResourceType(error.rawStderr) {
            // **確かめられたかどうかを失敗に載せて返す。** 載せずに throw して
            // いたので、間隔を空けている最中の一過性の失敗が「サーバはその種別を
            // 知らない」という恒久の判断に化けていた（`DiscoveryReset`）。
            switch resetDiscoveryCache() {
            case .notChecked:
                // 確かめていない。**「無い」の材料に使わせない。**
                throw error
            case .nothingCached:
                // 覚えていないので、いまの失敗が引き直した結果そのもの。
                throw error.verifiedAgainstFreshDiscovery()
            case .cleared:
                do {
                    return try await execute(arguments, context: context, input: input)
                } catch let retried as CommandError {
                    // 捨てて引き直しても同じなら、それは本当に無い。
                    throw retried.verifiedAgainstFreshDiscovery()
                }
            }
        }
    }

    /// 読んだ結果が要求した種別と食い違ったら、覚えている API の一覧を
    /// **1 度だけ**捨てて引き直す。
    ///
    /// **`run` の網では受けられない。** あちらは stderr の
    /// `doesn't have a resource type` を見るが、種別が別グループへ流れる経路は
    /// **exit 0・stderr 空・valid JSON** なので文言が 1 つも出ない
    /// （`K8sObject.UnexpectedKind` と `ResourceKind.resourceName` の説明）。
    ///
    /// **捨てられたときだけ引き直す。** 覚えていないのに引き直しても同じところへ
    /// 流れるだけで、間隔を空けている最中なら結果は変わらない。
    private func recoveringUnexpectedKind<T>(
        _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let error as K8sObject.UnexpectedKind {
            guard case .cleared = resetDiscoveryCache() else { throw error }
            return try await body()
        }
    }

    private func execute(
        _ arguments: [String], context: String?, input: Data? = nil
    ) async throws -> CommandResult {
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
            timeout: TimeInterval(timeoutSeconds * 2 + 15),
            input: input)

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
                + "\n" + String(localized: """
                    （kubectl は \(seconds) 秒で返らなかったので打ち切っています。\
                    上は打ち切るまでに書き出されていた失敗です。）
                    """)
                + "\n\n" + condense(stderr)
        }

        // 段落の切れ目（`\n`）は文の一部なので鍵に含める。**訳す側で改行の
        // 位置を変えられるようにしておく** —— 英語では 1 文が短くなる。
        let head = String(localized: """
            kubectl が \(seconds) 秒のあいだ何も返さなかったので打ち切りました。
            待ち上限（`--request-timeout`）は API への要求しか縛りません。\
            kubeconfig の exec 認証プラグイン（`gke-gcloud-auth-plugin` など）が\
            返ってこない場合は、ここで打ち切るまで待つことになります。
            ターミナルで同じコンテキストに `kubectl cluster-info` を実行して、\
            そちらの言い分を確かめてください。設定の「接続」で待ち上限を延ばすと、\
            kubectl 自身の理由を最後まで受け取れることがあります。
            """)
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
            shown[key] = Self.hidesValue(name: key, value: value) ? Self.redacted : value
        }
        return shown
    }

    private static let redacted = String(localized: "（伏せています）")

    private static let secretHints = [
        "SECRET", "TOKEN", "PASSWORD", "PASSWD", "KEY", "CREDENTIAL", "AUTH", "SESSION",
    ]

    /// **名前そのものが「場所」を名乗っているもの。** ここに当たる名前だけ、
    /// 値の形を見て見せる側に倒す。`AWS_SHARED_CREDENTIALS_FILE` や
    /// `GOOGLE_APPLICATION_CREDENTIALS` は秘密を思わせる名前だが、入っているのは
    /// 指し先で、まさに確かめたい値。
    private static let locationHints = [
        "_FILE", "_PATH", "_DIR", "_SOCK", "_BUNDLE", "_CONFIG", "CREDENTIALS",
    ]

    static func hidesValue(name: String, value: String) -> Bool {
        // **名前に頼りきらない。** `DATABASE_URL=postgres://user:pass@host` のような
        // 値は、名前のどれにも当たらないのに認証情報を含む。この画面は設定画面で
        // あって、そのまま貼って共有されうる場所なので、形でも見る。
        if containsEmbeddedCredentials(value) { return true }

        let upper = name.uppercased()
        let hintsSecret = secretHints.contains { upper.contains($0) }
        // **値の形より名前を先に見る。** 以前は「`/` で始まれば場所」を先に
        // 判定しており、`AWS_SECRET_ACCESS_KEY` のような名前でも値が `/` で
        // 始まるだけで**そのまま表示していた**。base64 の資格情報は `/` を
        // 含む（AWS のシークレットキーは 40 文字の base64）ので、これは
        // 64 分の 1 の確率で起きる。名前が秘密を名乗っていて、かつ場所を
        // 名乗っていないなら、値が何に見えようと伏せる。
        if hintsSecret, !locationHints.contains(where: { upper.contains($0) }) { return true }
        // 場所を指しているなら見せる。CA や kubeconfig の指し先が合っているかを
        // 確かめる場所なので、伏せると診断にならない。
        if looksLikeFilePath(value) { return false }
        return hintsSecret
    }

    /// 値が「場所」に見えるか。
    ///
    /// **先頭が `/` なだけでは足りない。** 上と同じ理由で、base64 の資格情報が
    /// 場所に化ける。区切りの `/` か拡張子の `.` を、先頭より後ろに要求する
    /// （base64 の字種に `.` は無い）。
    private static func looksLikeFilePath(_ value: String) -> Bool {
        guard value.hasPrefix("/") || value.hasPrefix("~") else { return false }
        let rest = value.dropFirst()
        return rest.contains("/") || rest.contains(".")
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
        guard let hint = authenticationHint(for: stderr)
            ?? discoveryHint(for: stderr)
            ?? permissionHint(for: stderr)
        else {
            return stderr
        }
        return hint + "\n\n" + condense(stderr)
    }

    /// 権限で拒まれたときの言い換え。
    ///
    /// **認証の失敗と混ぜない。** 誰であるかは通っていて、その人にその操作が
    /// 許されていないだけ。`gcloud auth login` を何度やっても直らない。
    ///
    /// **押す前に調べる、という作りにしていない。** `kubectl auth can-i --list` は
    /// **JSON を出せず**（実測）、表には `*.*` `[*]` のようなワイルドカードが並ぶ。
    /// 突き合わせるには RBAC の評価器を書くことになり、ラベルセレクタや JSONPath を
    /// 実装しなかったのと同じ理由でここでは持たない。**代わりに、拒まれたときに
    /// 何をどうすれば通るのかが分かる文面を返す。**
    private static func permissionHint(for stderr: String) -> String? {
        guard stderr.contains("(Forbidden)") || stderr.contains("is forbidden") else {
            return nil
        }
        // 実測の書式:
        // Error from server (Forbidden): pods is forbidden: User "x" cannot list
        //   resource "pods" in API group "" in the namespace "y"
        let verb = stderr.firstMatch(of: #/cannot (\w+) resource "([^"]+)"/#)
        let subject = stderr.firstMatch(of: #/User "([^"]+)"/#)?.1
            ?? stderr.firstMatch(of: #/ServiceAccount "([^"]+)"/#)?.1

        var lines = [
            String(localized: "権限が足りません。認証は通っていて、その操作が許されていないだけです。")
        ]
        if let verb {
            lines.append(String(localized: "拒まれたのは `\(verb.1)` （対象は `\(verb.2)`）です。"))
        }
        if let subject {
            lines.append(String(localized: "いまの資格情報は `\(subject)` です。"))
        }
        lines.append(String(localized: """
            確かめるには `kubectl auth can-i <動詞> <種別> -n <Namespace>`、\
            許すには対象の Role / ClusterRole に規則を足して Binding で結びます\
            （アプリの「アクセス制御」から中身を見られます）。
            """))
        return lines.joined(separator: "\n")
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
        return String(localized: """
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
            """)
    }

    private static func authenticationHint(for stderr: String) -> String? {
        // TLS を覗く社内プロキシの下で、独自の CA が信頼されていない。
        // **認証の失敗と混ぜない。** 資格情報は正しく、検証で落ちているだけなので、
        // `gcloud auth login` をいくら実行しても直らない。
        if stderr.contains("CERTIFICATE_VERIFY_FAILED")
            || stderr.contains("self-signed certificate")
            || stderr.contains("certificate signed by unknown authority") {
            return String(localized: """
                サーバの証明書を検証できませんでした。認証情報ではなく TLS の問題です。
                TLS を覗くプロキシの下では、その CA を信頼させる環境変数\
                （`REQUESTS_CA_BUNDLE` や `SSL_CERT_FILE` など）が要ります。
                KubeDeck はログインシェルの環境をそのまま子プロセスへ渡すので、\
                シェルの設定ファイルでこれらを設定していれば効きます。\
                ターミナルでだけ通る場合は、その設定が対話シェルより後で\
                行われていないか確かめてください。
                """)
        }

        // kubeconfig が要求する exec 認証プラグインが PATH に無い。
        if let match = stderr.firstMatch(of: /executable (\S+) not found/) {
            let plugin = String(match.1)
            var lines = [
                String(localized: """
                    kubeconfig が exec 認証プラグイン `\(plugin)` を要求していますが、\
                    見つかりませんでした。
                    """)
            ]
            if plugin.contains("gke-gcloud-auth-plugin") {
                lines.append(String(localized: """
                    入っていなければ `gcloud components install gke-gcloud-auth-plugin` \
                    で入ります。
                    """))
            }
            lines.append(String(localized: """
                入っているのにここで見つからないときは、KubeDeck から見える PATH に \
                その場所がありません。設定の「接続」で、いま渡している PATH を確認できます。
                """))
            return lines.joined(separator: "\n")
        }

        // プラグインは動いたが、その先の gcloud が資格情報を出せなかった。
        // gcloud は access token を取り直すのに再ログインや再認証（2 段階認証）を
        // 求めることがあり、それは対話的な操作なので、ここからは代行できない。
        // **プラグインが見つからない話と混ぜない。** 対処がまったく違う。
        if stderr.contains("failure while executing gcloud")
            || stderr.contains("print credential failed") {
            var lines = [
                String(localized: """
                    exec 認証プラグインは動きましたが、その先の gcloud が\
                    アクセストークンを出せませんでした。
                    """)
            ]
            if stderr.contains("UNAUTHENTICATED") || stderr.contains("invalid authentication") {
                lines.append(String(localized: """
                    gcloud の資格情報が期限切れか、再認証を求められている状態です。\
                    ターミナルで `gcloud auth login` を実行してから、もう一度読み込んでください。
                    """))
            }
            // 認証プラグインは標準入力を持たない状態で動く（対話プロンプトが
            // 出ると待ち続けてしまうため、意図的にそうしてある）。
            lines.append(String(localized: """
                再認証は対話的な操作なので、KubeDeck からは代行できません。\
                下の元の文言にある gcloud のコマンドをターミナルでそのまま実行すると、\
                同じ失敗になるか確かめられます。
                """))
            return lines.joined(separator: "\n")
        }

        // kubectl 1.26 で in-tree の GCP 認証が消えている。kubeconfig が古い。
        if stderr.contains("gcp auth plugin has been removed") {
            return String(localized: """
                kubeconfig がこのクラスタを古い `auth-provider: gcp` 形式で持っています。\
                kubectl 1.26 以降はこの形式を読めません。
                `gcloud container clusters get-credentials <クラスタ名> \
                --region <リージョン>` で作り直してください。
                """)
        }

        // API サーバまで届いていない。**認証の失敗と混ぜない。**
        // 認証が通っているからこそ、ここまで来て接続で落ちている。
        // 上のどれにも当たらなかったときだけ見るので、いちばん最後に置く。
        if stderr.contains("Unable to connect to the server")
            || stderr.contains("context deadline exceeded")
            || stderr.contains("no such host")
            || stderr.contains("connection refused")
            || stderr.contains("i/o timeout") {
            var lines = [
                String(localized: "クラスタの API サーバに届きませんでした。認証ではなく経路の問題です。")
            ]
            if let match = stderr.firstMatch(of: /Get \\?"https?:\/\/([^\/"\\]+)/) {
                let host = String(match.1)
                lines.append(String(localized: """
                    宛先は `\(host)` です。\
                    プライベートなアドレスであれば、VPN や社内ネットワークからでないと届きません。
                    """))
            }
            lines.append(String(localized: """
                ターミナルで同じコンテキストに `kubectl cluster-info` を実行して、\
                そちらも届かないか確かめてください。届かないなら、\
                止まっているのは KubeDeck ではなく経路です。
                """))
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
        if let api = await api(for: context) {
            // `/version` は discovery を通らない素のパス。**ここは `--raw` を
            // 避ける理由（discovery を通らないと Connect Gateway で 404 になる）
            // に当たらない** —— あれは metrics API の話で、`/version` は
            // 集約 API サーバ越しではなく本体が答える。
            let startedAt = Date()
            do {
                let data = try await api.data(path: "version")
                let root = try JSONDecoder().decode(JSONValue.self, from: data)
                return root["gitVersion"]?.stringValue ?? String(localized: "不明")
            } catch {
                throw await explained(error, context: context, since: startedAt)
            }
        }
        let result = try await run(
            ["version", "-o", "json", "--request-timeout=\(requestTimeout)"],
            context: context)
        let root = try JSONDecoder().decode(JSONValue.self, from: result.stdout)
        return root.path("serverVersion.gitVersion")?.stringValue
            ?? String(localized: "不明")
    }

    // MARK: - 読み取りの経路

    /// いま読み取りに何を使っているか。
    ///
    /// **「使えないから黙って別の先へ流す」をしない。** 使えなかった理由を
    /// 持ち回して設定画面に出す（メトリクスの取得元を勝手に切り替えないのと
    /// 同じ判断）。
    enum ReadTransport: Sendable, Equatable {
        /// 常駐 proxy 経由の HTTP。
        case apiProxy
        /// kubectl を毎回起こす従来の経路。`reason` は proxy を使えない理由
        /// （nil なら設定で切ってある）。
        case kubectl(reason: String?)
    }

    func readTransport(for context: String) async -> ReadTransport {
        guard usesAPIProxy else { return .kubectl(reason: nil) }
        if await ClusterProxy.shared.diagnostics(for: context)?.isRunning == true {
            return .apiProxy
        }
        if let proxyFailure { return .kubectl(reason: proxyFailure) }
        let failure = await ClusterProxy.shared.failure(for: context)
        return .kubectl(reason: failure?.reason)
    }

    /// 設定画面に出す常駐 proxy の様子。
    func proxyDiagnostics(for context: String) async -> ClusterProxy.Diagnostics? {
        await ClusterProxy.shared.diagnostics(for: context)
    }

    /// コンテキストを切り替えたときに呼ぶ。要らなくなった proxy を畳み、
    /// 覚えた API の一覧も捨てる。
    /// - Parameter keeping: 残すコンテキスト。それ以外の常駐と、覚えた
    ///   API の一覧を畳む。
    ///
    /// **残すほうの表まで捨てない。** 以前は `invalidateAll()` を呼んで
    /// いたので、切り替え直後に走り出した**切り替え先の** discovery を
    /// 自分で打ち切っていた。打ち切られた側は `try?` で握られる経路
    /// （`metricsServerAvailable` / `customResourceTypes`）で
    /// **false や空**になり、「探している最中」を「入っていません」
    /// 「CRD が 1 つも無い」と断定していた。
    func releaseTransports(keeping context: String) async {
        let dropped = await ClusterProxy.shared.keepOnly(context)
        for other in dropped {
            await APIDiscovery.shared.invalidate(context: other)
        }
        proxyFailure = nil
    }

    /// 読み取り用の HTTP の口。使えないときは nil（＝ kubectl 経由に落ちる）。
    /// コンテキストごとに、最後に使った待ち受け先。
    ///
    /// **proxy が立て直されたら、覚えた API の一覧も捨てる。** kubeconfig が
    /// 書き換わって別のクラスタを指した場合、待ち受け先は同じでも中身は別物
    /// になる。古い表のままだとパスが合わず、**「クラスタに見つかりません」と
    /// 出る**（`APIDiscovery` の説明が約束していたのに、誰も捨てていなかった）。
    private var lastEndpoints: [String: URL] = [:]

    private func api(for context: String) async -> APIClient? {
        guard usesAPIProxy, !context.isEmpty else { return nil }
        do {
            let endpoint = try await ClusterProxy.shared.endpoint(for: context)
            // **1 回目は捨てない。** 捨てる相手がまだ無いのに `invalidate` を
            // 通すと、同時に走り出した別の読み手の discovery を巻き添えに
            // 打ち切る（起動直後の 1 周期だけ「取得できませんでした」が出る）。
            let previous = lastEndpoints[context]
            lastEndpoints[context] = endpoint.baseURL
            if let previous, previous != endpoint.baseURL {
                await APIDiscovery.shared.invalidate(context: context)
            }
            proxyFailure = nil
            return APIClient(endpoint: endpoint, timeout: TimeInterval(timeoutSeconds))
        } catch {
            proxyFailure = error.localizedDescription
            return nil
        }
    }

    /// 種別 1 つを HTTP で引く。
    ///
    /// **返ってきた `kind` を確かめる。** kubectl 経由では、縮退した discovery
    /// キャッシュのせいで `nodes` が NodeMetrics として返る事故があった
    /// （exit 0・stderr 空・valid JSON なので既存の網が 1 つも発火しない）。
    /// こちらはパスを自分で組むので同じ形では起きないが、**別の道で流れてきたら
    /// 気付く**という網は残す。List の `kind` は `PodList` のように付くので
    /// （実測。items 側には付かない）、そこで見る。
    /// - Parameter metadataOnly: 件数と metadata しか使わないとき。
    ///   `spec` / `status` が来なくなるので、**中身を見る経路では使わない。**
    private func httpObjects(
        _ api: APIClient, resourceName: String, context: String, namespace: String?,
        assuming kind: ResourceKind?, query: [URLQueryItem] = [],
        chunk: Int? = Kubectl.chunkSize, metadataOnly: Bool = false
    ) async throws -> [K8sObject] {
        // **ここでは包まない。** 失敗の種類（403 / 404）で種別ごとに振り分ける
        // のは `httpList` の仕事で、包むとその分類が効かなくなる（実際 403 が
        // 「拒否」ではなく「取得できませんでした」に化けた）。利用者に出る
        // 手前 —— 1 種別ぶんを投げる経路と、まとめ取りが全滅した経路 —— で
        // `explained` を通す。
        let resource = try await APIDiscovery.shared.resource(
            for: resourceName, context: context, client: api)
        let path = resource.listPath(namespace: namespace)
        let accept = metadataOnly ? APIClient.metadataOnlyAccept : nil
        let pages: [Data]
        if let chunk {
            pages = try await api.list(
                path: path, query: query, chunk: chunk, accept: accept)
        } else {
            pages = [try await api.data(path: path, query: query, accept: accept)]
        }
        var objects: [K8sObject] = []
        for page in pages {
            try Self.verifyListKind(
                page, resource: resource, requested: kind, metadataOnly: metadataOnly)
            objects += metadataOnly
                ? try K8sObject.metadataList(from: page, assuming: kind)
                : try K8sObject.list(from: page, assuming: kind)
        }
        return objects
    }

    /// List の `kind` が要求したものかを見る。
    ///
    /// **突き合わせる相手が無いときは見ない。** CRD のように discovery から
    /// 単数形が取れないことがあるので、そのときは通す（「取れていない」ことを
    /// 「食い違っている」にしない）。
    static func verifyListKind(
        _ data: Data, resource: APIResource, requested: ResourceKind?,
        metadataOnly: Bool = false
    ) throws {
        let expected = resource.kind.isEmpty ? (requested?.apiKind ?? "") : resource.kind
        guard !expected.isEmpty,
              let root = try? JSONDecoder().decode(JSONValue.self, from: data),
              let received = root["kind"]?.stringValue, !received.isEmpty
        else { return }
        // metadata だけを頼んだときは `PartialObjectMetadataList` が返る（実測）。
        // **頼んでいないときに通さない** —— 通すと、中身を使う経路に metadata
        // だけの応答が流れ込んでも気付けなくなる。
        if metadataOnly, received == "PartialObjectMetadataList" { return }
        guard received != "\(expected)List", received != expected else { return }
        throw K8sObject.UnexpectedKind(
            requested: requested.map { [$0] } ?? [], received: received)
    }

    /// HTTP の失敗に、proxy が書き出した文言を添えて言い換える。
    ///
    /// **元の文言を捨てない、をこの経路でも守る。** 認証プラグインが失敗した
    /// とき、HTTP の body に来るのは
    /// `getting credentials: exec: executable … failed with exit code 1` だけで、
    /// **プラグイン本人の文言は proxy の stderr にしか出ない**（実測）。
    /// そこを拾わないと、利用者に見えるのは「exit code 1」だけになり、
    /// しかも `explain(_:)` の言い換え（期限切れの再ログイン、CA の検証、
    /// 経路の問題）が**1 つも発火しない** —— kubectl 経由では出ていた説明が、
    /// 経路を変えたせいで消える。
    ///
    /// **種別ごとの拒否や NotFound には添えない。** あれは応答そのものが理由を
    /// 言っているので、proxy の古い行を足すとかえって読み違える。
    /// - Parameter since: この時刻より後に proxy が書いた行だけを添える。
    ///   **古い行を「いまの理由」として見出しに出さない。**
    private func explained(
        _ error: any Error, context: String, since: Date
    ) async -> any Error {
        // **包みは剥がして中身を見るが、返す値は包んだまま。**
        //
        // 一覧を引く途中の失敗は `APIDiscoveryError.unreachable` に包んである
        // （種別の話と混ぜないため）。中を見ないと、いちばん出したい経路 ——
        // 起動直後の認証失敗 —— でプラグインの文言を添えられない。
        // **かといって剥がして返すと、今度は `APIError.notFound` が素で出て、
        // 呼び出し側が「その種別は無い」と読む**（`/api` が 404 を返しただけで
        // 全種別が「クラスタに存在しない」になる）。1 度これで壊した。
        let inner: any Error
        if case APIDiscoveryError.unreachable(let wrapped) = error {
            inner = wrapped
        } else {
            inner = error
        }
        guard let apiError = inner as? APIError else { return error }
        switch apiError {
        case .forbidden(let status):
            // **拒まれたときの対処を落とさない。** kubectl 経由では
            // `explain(stderr)` が `permissionHint` を通して「拒まれた動詞と
            // 対象・いまの資格情報・`auth can-i` の打ち方・許し方」を出していた。
            // ここを素通りさせると、サーバの生の message だけになって
            // **対処が消える**（proxy の古い行は添えないが、言い換えは残す）。
            let hinted = Self.explain(status.message)
            return hinted == status.message
                ? error
                : TransportError(summary: status.message, detail: hinted)
        case .notFound, .conflict:
            return error
        case .unauthorized, .status, .timedOut, .unreachable, .malformed:
            break
        }
        let output = await ClusterProxy.shared.output(for: context, since: since)
        // proxy 自身の「中継に失敗した」行は body と同じことを言っているだけ、
        // 待ち受けを始めた行はそもそも失敗ではない。どちらも落とす。
        // **プラグインの行は残す。**
        let interesting = output.filter {
            !$0.contains("proxy_server.go") && ClusterProxy.Instance.parseAddress($0) == nil
        }
        guard !interesting.isEmpty else { return error }
        let stderr = Self.condense(interesting.joined(separator: "\n"))
        return TransportError(
            summary: error.localizedDescription, detail: Self.explain(stderr))
    }

    /// 一覧の `kind` が食い違ったら、覚えた API の一覧を捨てて 1 度だけ引き直す。
    ///
    /// kubectl 経由の `recoveringUnexpectedKind` と同じ役目。**こちらが捨てるのは
    /// ディスクではなくメモリの表**なので、他のプロセスを巻き込まない。
    private func recoveringDiscovery<T>(
        context: String, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let error as K8sObject.UnexpectedKind {
            await APIDiscovery.shared.invalidate(context: context)
            _ = error
            return try await body()
        }
    }

    // MARK: - 取得

    /// **一度に全部を要求しない。** `-o json` でも kubectl は `--chunk-size` で
    /// 分けて取り、こちらには 1 つにまとめて返す（実測）。数千 Pod のクラスタで
    /// API サーバに一撃で数十 MB を作らせるのを避けられる。
    /// **アプリ側の読み込み量は変わらない** —— そこは種別と Namespace を
    /// 絞ってもらう話で、この指定で直るのは取りに行き方だけ。
    static let chunkSize = 500

    /// イベントを刻む単位。**一覧より大きくする。**
    ///
    /// 欲しいのは新しい順の数十件だが、API は時刻順に返さないので全部引いて
    /// から並べ替えることになる（kubectl の `--sort-by` も同じ）。500 ずつだと
    /// 逐次の往復が積み上がるので、大きめに 1 度で取り切る側へ寄せる。
    static let eventChunkSize = 2_000

    func list(
        _ kind: ResourceKind, context: String, namespace: String?
    ) async throws -> [K8sObject] {
        if let api = await api(for: context) {
            let startedAt = Date()
            do {
                return try await recoveringDiscovery(context: context) {
                    try await httpObjects(
                        api, resourceName: kind.resourceName, context: context,
                        namespace: kind.isNamespaced ? namespace : nil, assuming: kind)
                }
            } catch {
                throw await explained(error, context: context, since: startedAt)
            }
        }
        var arguments = ["get", kind.resourceName, "-o", "json",
                         "--chunk-size=\(Self.chunkSize)",
                         "--request-timeout=\(requestTimeout)"]
        arguments += scope(for: kind, namespace: namespace)
        return try await recoveringUnexpectedKind {
            let result = try await run(arguments, context: context)
            return try K8sObject.list(from: result.stdout, assuming: kind)
        }
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
        /// 引きに行ったが失敗した種別（時間切れ・5xx など）。
        ///
        /// **種別ごとに引くようになって初めて必要になった。** kubectl に
        /// まとめて渡していたときは、失敗すれば呼び出し全体が投げるので
        /// 「一部だけ落ちる」が起こらなかった。HTTP は種別ごとに独立して
        /// 失敗するので、ここを持たないと**読めなかった種別が 0 件になる**
        /// （`counts` を 0 で埋める側が `uncounted` しか見ないため）。
        ///
        /// **拒否とも「知らない」とも混ぜない。** 権限の話でも、API に無い話でも
        /// なく、単に取れていない。次の周期で取れるかもしれない。
        var failed: [ResourceKind] = []

        var isDenied: Bool { !denied.isEmpty }
        /// 数に入れてはいけない種別。拒まれたもの・知られていないもの・
        /// 取れなかったもの。
        var uncounted: [ResourceKind] { denied + unknown + failed }
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
    /// - Parameter metadataOnly: **件数と metadata しか使わない種別。**
    ///   `spec` / `status` を運ばせない（Connect Gateway 越しの GKE で
    ///   secrets が 6.85MB・3 秒から 51KB・0.13 秒になった。実測）。
    ///   中身を見る種別を入れてはいけない —— 状態の集計が黙って空になる。
    ///
    ///   **kubectl 経由では効かない。** あちらに metadata だけを返す口が無いので、
    ///   この指定は無視される（速さは変わるが、返る中身は同じ）。
    func list(
        kinds: [ResourceKind], context: String, namespace: String?,
        metadataOnly: Set<ResourceKind> = []
    ) async throws -> PartialList {
        if let api = await api(for: context) {
            return try await recoveringDiscovery(context: context) {
                try await httpList(
                    api, kinds: kinds, context: context, namespace: namespace,
                    metadataOnly: metadataOnly)
            }
        }
        // **引き直しは外側で 1 度だけ。** 中の再帰（知らない種別を除いて
        // 引き直す経路）に掛けると、種別の数だけ捨てて引き直すことになる。
        return try await recoveringUnexpectedKind {
            try await list(kinds: kinds, context: context, namespace: namespace, unknown: [])
        }
    }

    /// 複数種別を HTTP で引く。**種別ごとに 1 本、並行に投げる。**
    ///
    /// kubectl 経由でまとめて 1 本にしていたのは、種別ごとに投げると
    /// **プロセスが 13 個立つ**からだった。HTTP ならプロセスは増えず、
    /// 1 本の TCP 接続に多重化される（往復の数は種別ぶんだが並行に走る）。
    ///
    /// **そして、種別ごとの結果が状態コードで分かる。** kubectl 経由では
    /// 「読めたぶんは標準出力・拒まれた種別は stderr の文言」から拾い分けて
    /// いた（書式に依存するので `KubectlTests` で固めてある）。ここでは
    /// 403 が拒否、404 が「サーバはその種別を知らない」。**どちらも 0 件とは
    /// 混ぜない**という規則はそのまま。
    ///
    /// **404 を「無い」と断定してよいのは、いま discovery を引いているから。**
    /// kubectl 経由では、ディスクのキャッシュが縮退しているだけでも
    /// 「知らない種別」と言われるので、捨てて引き直せたときだけ外す判断に
    /// 使っていた（`discoveryWasFresh`）。こちらは毎起動でサーバに聞いた
    /// 表なので、その一過性が入り込む余地がない。
    private func httpList(
        _ api: APIClient, kinds: [ResourceKind], context: String, namespace: String?,
        metadataOnly: Set<ResourceKind> = []
    ) async throws -> PartialList {
        guard !kinds.isEmpty else { return PartialList() }
        let startedAt = Date()

        enum Outcome: Sendable {
            case objects([K8sObject])
            case denied
            case unknown
            case failed(any Error)
        }

        let outcomes = await withTaskGroup(of: (ResourceKind, Outcome).self) { group in
            for kind in kinds {
                group.addTask {
                    do {
                        let objects = try await self.httpObjects(
                            api, resourceName: kind.resourceName, context: context,
                            namespace: kind.isNamespaced ? namespace : nil, assuming: kind,
                            metadataOnly: metadataOnly.contains(kind))
                        return (kind, .objects(objects))
                    } catch let error as APIError {
                        switch error {
                        case .forbidden: return (kind, .denied)
                        case .notFound: return (kind, .unknown)
                        default: return (kind, .failed(error))
                        }
                    } catch APIDiscoveryError.unknownResource {
                        // 表に無い＝サーバが知らない。**拒否とは分けて持つ。**
                        //
                        // **ここに来るのは「表は引けた。その中に無かった」
                        // ときだけ。** 表そのものを引けなかったとき
                        // （`APIDiscoveryError.unreachable` / `.empty`）は
                        // 下の `.failed` に落ちる —— そちらを混ぜると、
                        // `/api` が 404 を返しただけで**要求した全種別が
                        // 「クラスタに存在しない」**ことになる。
                        return (kind, .unknown)
                    } catch {
                        // **一過性の discovery 失敗を「無い」にしない。**
                        // `APIDiscoveryError.empty`（一覧そのものを引けなかった）
                        // をここに混ぜると、全種別が「クラスタに見つかりません
                        // でした。`kubectl api-resources` を確かめてください」に
                        // なる。kubectl 経由で `discoveryWasFresh` を足して守った
                        // のと同じ話（確かめていない失敗を、外す判断に使わない）。
                        if error is K8sObject.UnexpectedKind {
                            // 表が古い疑いがあるので、次の周期で引き直させる。
                            await APIDiscovery.shared.invalidate(context: context)
                        }
                        return (kind, .failed(error))
                    }
                }
            }
            var collected: [ResourceKind: Outcome] = [:]
            for await (kind, outcome) in group { collected[kind] = outcome }
            return collected
        }

        var result = PartialList()
        var failures: [ResourceKind: any Error] = [:]
        // **要求した順に並べる。** kubectl にまとめて渡したときも、返る items は
        // 種別を並べた順になる。並べ替えの既定（異常が上）や配置のタイルは
        // 手元の順序を土台にするので、経路で見え方が変わらないようにする。
        for kind in kinds {
            switch outcomes[kind] {
            case .objects(let objects): result.objects += objects
            case .denied: result.denied.append(kind)
            case .unknown: result.unknown.append(kind)
            case .failed(let error):
                // **失敗した種別を落とさない。** ここを捨てると、呼び出し側が
                // `uncounted` に無い種別を 0 で埋めるので、**引けなかった種別が
                // 「0 件」になる**（このアプリでいちばん避けたい取り違え）。
                result.failed.append(kind)
                failures[kind] = error
            case nil: break
            }
        }

        // **読めたぶんは捨てない**（kubectl 経由で `partialStdout` を拾い直して
        // いるのと同じ判断）。**全部が駄目だったときだけ投げる** —— そのときは
        // 呼び出し側が「取得できません」を出せるように、最初の失敗を渡す。
        //
        // **「読めた」を件数で判定しない。** `objects.isEmpty` で見ていると、
        // 読めた種別がたまたま全部 0 件だったときに**取得そのものが失敗した
        // ことになる**（0 件と取れていないを混ぜる、いつもの間違いの裏返し）。
        let readKinds = kinds.filter { kind in
            if case .objects = outcomes[kind] { return true }
            return false
        }
        if readKinds.isEmpty, result.denied.isEmpty, result.unknown.isEmpty,
           let first = kinds.compactMap({ failures[$0] }).first {
            throw await explained(first, context: context, since: startedAt)
        }
        return result
    }

    /// - Parameter unknown: ここまでに「サーバが知らない」と言われた種別。
    ///   除いて引き直すたびに積み上がる。
    private func list(
        kinds: [ResourceKind], context: String, namespace: String?, unknown: [ResourceKind]
    ) async throws -> PartialList {
        guard !kinds.isEmpty else { return PartialList(unknown: unknown) }
        let names = kinds.map(\.resourceName).joined(separator: ",")
        var arguments = ["get", names, "-o", "json",
                         "--chunk-size=\(Self.chunkSize)",
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
            //
            // **確かめていない失敗で外さない。** `run` が一覧を捨てて引き直せた
            // ときだけ `discoveryWasFresh` が立つ。立っていないのは
            // 「間隔を空けている最中の一過性の失敗」で、外すと**一過性を
            // 恒久の判断に化けさせる**（実測でそうなっていた。core の種別が
            // 次々に外れて件数が消えた）。ここは「取れていない」として投げる。
            let missing = Self.kindsToDrop(
                in: error.rawStderr, among: kinds,
                discoveryWasFresh: error.discoveryWasFresh)
            guard !missing.isEmpty else { throw error }
            return try await list(
                kinds: kinds.filter { !missing.contains($0) },
                context: context, namespace: namespace, unknown: unknown + missing)
        }
        guard !result.stdout.isEmpty else { return PartialList(unknown: unknown) }
        return PartialList(
            // **要求した種別だけを受け取る。** 縮退したキャッシュでは
            // `pods,nodes` が **PodMetrics 185 + NodeMetrics 3** で返る（実測）。
            // 素通しにすると、まとめ取得の振り分けが丸ごと狂ったまま画面に出る
            // （`kind` は `assuming:` で要求種別に化けるので消費側では気付けない）。
            objects: try K8sObject.list(from: result.stdout, expecting: kinds),
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

    /// 種別名から API グループを落とした複数形。
    ///
    /// **突き合わせる前に、両側を同じ形にする。** kubectl は文言によって
    /// グループを付けたり付けなかったりするが、こちらが要求する名前は
    /// `roles.rbac.authorization.k8s.io` のようにグループ付きで固定してある
    /// （短い名前は別グループと衝突するため）。**片側だけ切ると、グループ付きの
    /// 種別が 1 つも一致しなくなる。** 実際 `deniedKinds` がそうなっており、
    /// NetworkPolicy や RoleBinding が権限で拒まれても拒否の一覧に入らず、
    /// **サイドバーに「0 件」と出ていた**（「拒まれた」を「無い」にする、
    /// このアプリでいちばん避けたい間違い）。
    ///
    /// 突き合わせるのは**要求した種別の中だけ**なので、グループを落としても
    /// 別の種別を巻き込まない（`ResourceKind` の複数形はすべて相異なる）。
    private static func plural(of resourceName: String) -> String {
        resourceName.split(separator: ".").first.map(String.init) ?? resourceName
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
            denied.insert(plural(of: String(match.1)))
        }
        // **要求した側もグループを落としてから比べる**（`plural` の説明を参照）。
        return kinds.filter { denied.contains(plural(of: $0.resourceName)) }
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
    /// 一覧から**外してよい**種別。`unknownKinds` に「確かめたか」を掛けたもの。
    ///
    /// **外すのは「サーバはこれを知らない」と言うのと同じ。** だから確かめて
    /// いない失敗では 1 つも外さない（`CommandError.discoveryWasFresh`）。
    /// 「取れていない」を「無い」にしない、というこのアプリの規則を、
    /// ここでは**判断を保留する**という形で守る。
    static func kindsToDrop(
        in stderr: String, among kinds: [ResourceKind], discoveryWasFresh: Bool
    ) -> [ResourceKind] {
        guard discoveryWasFresh else { return [] }
        return unknownKinds(in: stderr, among: kinds)
    }

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
        return kinds.filter { missing.contains(plural(of: $0.resourceName)) }
    }

    /// クラスタに入っている CRD の種別。
    ///
    /// `api-resources` ではなく CRD そのものを読む。表示列
    /// （`additionalPrinterColumns`）が要るためで、これは CRD にしか無い。
    func customResourceTypes(context: String) async -> [CustomResourceType] {
        if let api = await api(for: context) {
            let objects = (try? await httpObjects(
                api, resourceName: "customresourcedefinitions.apiextensions.k8s.io",
                context: context, namespace: nil, assuming: nil)) ?? []
            return objects
                .compactMap(CustomResourceType.init(crd:))
                .sorted { lhs, rhs in
                    lhs.group == rhs.group ? lhs.kind < rhs.kind : lhs.group < rhs.group
                }
        }
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
        if let api = await api(for: context) {
            let startedAt = Date()
            do {
                return try await recoveringDiscovery(context: context) {
                    try await httpObjects(
                        api, resourceName: resource, context: context,
                        namespace: namespaced ? namespace : nil, assuming: kind)
                }
            } catch {
                throw await explained(error, context: context, since: startedAt)
            }
        }
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
        if let api = await api(for: context) {
            // **刻むが、細かくしない。** 500 件ずつだと直近 30 件が欲しい
            // だけなのに逐次の往復を何度もすることになる。かといって一撃で
            // 全件を要求すると、「API サーバに一度に大きな応答を作らせない」
            // という `--chunk-size` の方針がここだけ外れる。
            let objects = try await httpObjects(
                api, resourceName: ResourceKind.event.resourceName, context: context,
                namespace: namespace, assuming: .event, chunk: Self.eventChunkSize)
            // **並べ替えはこちらで持つ。** kubectl の `--sort-by=.lastTimestamp` も
            // クライアント側の並べ替えで、しかも `lastTimestamp` を持たず
            // `eventTime` だけのイベントを「時刻が無いもの」として扱う。
            // `lastSeen` は両方を見るので、そちらで並べたほうが正しい。
            return Array(Self.newestFirst(objects).prefix(limit))
        }
        var arguments = ["get", "events", "-o", "json",
                         "--sort-by=.lastTimestamp",
                         "--request-timeout=\(requestTimeout)"]
        arguments += scope(for: .event, namespace: namespace)
        let result = try await run(arguments, context: context)
        let objects = try K8sObject.list(from: result.stdout, assuming: .event)
        return Array(objects.reversed().prefix(limit))
    }

    /// 新しい順。`lastTimestamp` / `eventTime` / `creationTimestamp` の順に見る
    /// （`ResourceTable.lastSeen`）。
    static func newestFirst(_ objects: [K8sObject]) -> [K8sObject] {
        objects.sorted {
            (ResourceTable.lastSeen($0) ?? .distantPast)
                > (ResourceTable.lastSeen($1) ?? .distantPast)
        }
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

        let fieldSelector = selectors.joined(separator: ",")
        // Namespace を持たないもの（Node / PV）のイベントは default に載る。
        // 決め打ちせず全体から引く。
        let scopedNamespace = object.namespace?.isEmpty == false ? object.namespace : nil

        if let api = await api(for: context) {
            let objects = try await httpObjects(
                api, resourceName: ResourceKind.event.resourceName, context: context,
                namespace: scopedNamespace, assuming: .event,
                // **URL に手で組み込まない。** `URLQueryItem` に渡せば
                // `involvedObject.uid=…` の `=` も含めて正しく符号化される。
                query: [URLQueryItem(name: "fieldSelector", value: fieldSelector)],
                chunk: Self.eventChunkSize)
            return Array(Self.newestFirst(objects).prefix(limit))
        }

        var arguments = ["get", "events", "-o", "json",
                         "--field-selector=\(fieldSelector)",
                         "--request-timeout=\(requestTimeout)"]
        if let scopedNamespace {
            arguments += ["-n", scopedNamespace]
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

        if let api = await api(for: context) {
            return try await httpObjects(
                api, resourceName: ResourceKind.pod.resourceName, context: context,
                namespace: namespace.isEmpty ? nil : namespace, assuming: .pod,
                query: [URLQueryItem(name: "labelSelector", value: selector)])
        }

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
        let scoped = object.namespace?.isEmpty == false ? object.namespace : nil
        let all: [K8sObject]
        if let api = await api(for: context) {
            all = try await httpObjects(
                api, resourceName: ResourceKind.horizontalPodAutoscaler.resourceName,
                context: context, namespace: scoped, assuming: .horizontalPodAutoscaler)
        } else {
            var arguments = ["get", ResourceKind.horizontalPodAutoscaler.resourceName,
                             "-o", "json",
                             "--request-timeout=\(requestTimeout)",
                             "--ignore-not-found=true"]
            if let scoped { arguments += ["-n", scoped] }
            let result = try await run(arguments, context: context)
            all = try K8sObject.list(from: result.stdout, assuming: .horizontalPodAutoscaler)
        }
        return all.filter { hpa in
            guard let ref = hpa.spec?["scaleTargetRef"] else { return false }
            guard ref["name"]?.stringValue == object.name else { return false }
            // 種別まで見る。同じ名前の Deployment と StatefulSet は同居できる。
            guard let kind = ref["kind"]?.stringValue, !kind.isEmpty else { return true }
            return kind == object.rawKind
        }
    }

    /// 名前を指定して Role / ClusterRole を引く。
    ///
    /// **全件をまとめ取りに入れない。** ClusterRole は rules を持つぶん重く
    /// （実測 79 件で 264KB、実運用のクラスタでは MB 級）、配置画面は 10 秒
    /// ごとに引き直す。要るのは紐づいた数個だけなので、名前を指定して引く。
    ///
    /// **1 件ずつ引かない。** kubectl は名前を並べて渡せるので、Namespace ごとに
    /// 1 本で済む（まとめて削除するときと同じ考え方）。
    ///
    /// **`--ignore-not-found` を付ける。** Binding が指しているロールが実在
    /// しないことは実際にある（消したあとの Binding）。そこで失敗にすると、
    /// 引けた他のロールまで出せなくなる。
    func roles(
        named names: [String], namespace: String?, context: String
    ) async throws -> [K8sObject] {
        let unique = Array(Set(names)).sorted()
        guard !unique.isEmpty else { return [] }
        let kind: ResourceKind = namespace == nil ? .clusterRole : .role
        var arguments = ["get", kind.resourceName]
        // 名前は Binding の `roleRef` から来る＝サーバが返した値。位置引数に
        // 置くので、他と同じ規則で検める。
        //
        // **ここだけは投げずに落とす。** この画面は逆引きの補助情報なので、
        // 名前が 1 つ変でも**残りのロールは出せる**ほうがよい（`--ignore-not-found`
        // を付けてあるのと同じ判断）。操作系は投げて止める。
        let checked = unique.compactMap { try? Self.checkedName($0) }
        guard !checked.isEmpty else { return [] }
        arguments += checked
        arguments += ["-o", "json", "--request-timeout=\(requestTimeout)",
                      "--ignore-not-found=true"]
        if let namespace, !namespace.isEmpty { arguments += ["-n", namespace] }
        let result = try await run(arguments, context: context)
        return try K8sObject.list(from: result.stdout, assuming: kind)
    }

    /// resource は呼び出し側が持っている種別名を渡す。オブジェクトから
    /// 引くと、CRD のように組み込みの enum に無い種別が扱えない。
    func yaml(
        resource: String, object: K8sObject, context: String
    ) async throws -> String {
        var arguments = ["get", resource, try Self.checkedName(object.name), "-o", "yaml",
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
        if let api = await api(for: context) {
            // **ノードだけで判定しない**（管理されたクラスタはノードの指標を
            // 拒みつつ Pod の指標は通す）。1 つでも引けたら入っている。
            var paths: [(String, String?)] = [("nodes.metrics.k8s.io", nil),
                                              ("pods.metrics.k8s.io", nil)]
            if let namespace, !namespace.isEmpty {
                paths.append(("pods.metrics.k8s.io", namespace))
            }
            for (resource, scoped) in paths {
                // **確かめるだけなので 1 件でよい。** kubectl 経路は `-o name`
                // だったので名前しか運んでいなかった。全件引くと、数千 Pod の
                // クラスタでコンテキストを切り替えるたびに数 MB を運んで捨てる。
                if (try? await httpObjects(
                    api, resourceName: resource, context: context, namespace: scoped,
                    assuming: nil,
                    query: [URLQueryItem(name: "limit", value: "1")], chunk: nil)) != nil {
                    return true
                }
            }
            return false
        }
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
        let api = await api(for: context)

        if let data = await metricsData(
            api, resource: "nodes.metrics.k8s.io", context: context, namespace: nil),
           let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
            for item in root["items"]?.arrayValue ?? [] {
                guard let name = item.path("metadata.name")?.stringValue else { continue }
                snapshot.nodes[name] = Self.usage(from: item["usage"])
            }
        }

        if let data = await metricsData(
            api, resource: "pods.metrics.k8s.io", context: context, namespace: namespace),
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

    /// metrics API の生 JSON。
    ///
    /// **経路が違っても読む側は変えない。** 返る形は `kubectl get` の出力と
    /// 同じ List（`items[].usage` / `items[].containers[].usage`）で、
    /// これは `--raw` で引いたときと同じでもある。
    ///
    /// **`--chunk-size` を掛けない。** metrics API は `limit` / `continue` を
    /// 実装していないことがあり、掛けると空が返りうる。量も一覧より小さい。
    private func metricsData(
        _ api: APIClient?, resource: String, context: String, namespace: String?
    ) async -> Data? {
        if let api {
            guard let found = try? await APIDiscovery.shared.resource(
                for: resource, context: context, client: api) else { return nil }
            return try? await api.data(path: found.listPath(namespace: namespace))
        }
        var arguments = ["get", resource, "-o", "json",
                         "--request-timeout=\(requestTimeout)"]
        if resource.hasPrefix("pods") {
            if let namespace, !namespace.isEmpty {
                arguments += ["-n", namespace]
            } else {
                arguments.append("--all-namespaces")
            }
        }
        return try? await run(arguments, context: context).stdout
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

    // MARK: - サーバが返した名前を、位置引数に置く前に検める

    /// **`-` で始まる名前をそのまま kubectl に渡さない。**
    ///
    /// `Process.arguments` の配列渡しは**シェル**には安全だが、**kubectl 自身の
    /// フラグ解析は素通りする**。実測（kubectl v1.32.13、到達しない kubeconfig）:
    ///
    /// ```
    /// $ kubectl delete pods "--all" foo
    /// error: name cannot be provided when a selector is specified   ← フラグとして食われた
    /// ```
    ///
    /// つまり応答に `metadata.name: "--all"` を混ぜられるだけで、**1 件の削除が
    /// その Namespace ぜんぶの削除に化ける**。確認の文面には `--all` という名前が
    /// 出るだけなので、読み飛ばせば通る。同じ形が scale・patch・drain にもある。
    ///
    /// **`--` で切る手は使えない。** 実測で `--` より後ろは全部位置引数になるので、
    /// この実装が名前の**後ろ**に置いている `--wait=false` / `-n` /
    /// `--request-timeout` まで名前として食われる（`--request-timeout=1s` が効かず
    /// 既定の 32s になるのを確認した）。だから名前のほうを検める。
    ///
    /// **RFC 1123 で弾かない。** RBAC の名前には `:` が入る
    /// （`system:controller:deployment-controller`）ので、弾くと実在するクラスタで
    /// ClusterRole を操作できなくなる。Kubernetes 自身が一部の種別に使っている
    /// **path segment** の規則（空でない・`/` と `%` を含まない・`.` `..` でない）に、
    /// 「`-` で始まらない」と「制御文字を含まない」を足す。後者は、この名前が
    /// `ExecSheet` からターミナルへそのまま流れて OSC シーケンスとして解釈され
    /// うるため。
    ///
    /// **黙って直さない。** 落とすでも読み替えるでもなく、そういう名前だと言って
    /// 止める（「無い」と「取れていない」を混ぜないのと同じで、**変なものは変だと
    /// 言う**）。一覧に出すぶんには無害なので、止めるのは操作の手前だけ。
    static func checkedName(_ name: String) throws -> String {
        func reject() -> CommandError {
            CommandError(
                command: "kubectl",
                exitCode: -1,
                message: String(localized: """
                    サーバが返した名前が Kubernetes の名前として扱えないので、操作を中止しました: \(name)
                    """))
        }
        guard !name.isEmpty, name != ".", name != ".." else { throw reject() }
        guard !name.hasPrefix("-") else { throw reject() }
        guard !name.contains("/"), !name.contains("%") else { throw reject() }
        guard !name.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else { throw reject() }
        return name
    }

    // MARK: - 操作

    func delete(resource: String, object: K8sObject, context: String) async throws {
        var arguments = ["delete", resource, try Self.checkedName(object.name), "--wait=false"]
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
            do {
                var arguments = ["delete", resource]
                    + (try group.map { try Self.checkedName($0.name) }) + ["--wait=false"]
                if !namespace.isEmpty { arguments += ["-n", namespace] }
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
                    : String(localized: """
                        一部の Namespace で削除できませんでした。他は削除を要求済みです。
                        """)
                        + "\n\n" + failures.joined(separator: "\n\n"))
        }
    }

    func scale(_ object: K8sObject, to replicas: Int, context: String) async throws {
        guard let kind = object.kind, kind.isScalable else { return }
        var arguments = ["scale", kind.resourceName, try Self.checkedName(object.name),
                         "--replicas=\(replicas)"]
        if let namespace = object.namespace {
            arguments += ["-n", namespace]
        }
        try await run(arguments, context: context)
    }

    func rolloutRestart(_ object: K8sObject, context: String) async throws {
        try await rollout(["restart"], on: object, context: context)
    }

    /// 更新を止める / 再開する。
    ///
    /// **Deployment だけ。** 実測で StatefulSet と DaemonSet は
    /// `pausing is not supported` を返す（`supportsRolloutPause`）。
    func rolloutPause(_ object: K8sObject, paused: Bool, context: String) async throws {
        try await rollout([paused ? "pause" : "resume"], on: object, context: context)
    }

    // MARK: - 前の状態に戻す

    /// `kubectl rollout history` の 1 行。
    struct RolloutRevision: Identifiable, Hashable, Sendable {
        let revision: Int
        /// `kubernetes.io/change-cause` の中身。**`<none>` を空文字にしない** —
        /// 「書かれていない」ことが分かるように nil にする。
        let changeCause: String?

        var id: Int { revision }
    }

    /// 世代の一覧。新しい順ではなく **kubectl が出した順（古い順）** のまま返す。
    func rolloutHistory(_ object: K8sObject, context: String) async throws -> [RolloutRevision] {
        let result = try await rollout(["history"], on: object, context: context)
        return Self.parseRolloutHistory(result.stdoutText)
    }

    /// その世代の Pod テンプレート（`--revision=N`）。
    ///
    /// **自分で組み立てない。** 戻る先に何が入っているか（とくにイメージ）は
    /// kubectl が持っている ReplicaSet から出せるが、同じ整形を自前で書けば
    /// kubectl の答えとずれる余地を作るだけ。drain の dry-run と同じ扱いで、
    /// **返ってきた文面をそのまま見せる。**
    func rolloutRevisionDetail(
        _ object: K8sObject, revision: Int, context: String
    ) async throws -> String {
        let result = try await rollout(
            ["history", "--revision=\(revision)"], on: object, context: context)
        return result.stdoutText
    }

    /// 前の状態に戻す。`revision` が nil なら 1 つ前（kubectl の既定）。
    ///
    /// `dryRun` で聞くと、**押す前に止まる理由が分かる**。実測:
    /// - `deployment.apps/demo rolled back (server dry run)`
    /// - `deployment.apps/demo skipped rollback (current template already matches revision 2)`
    /// - `error: you cannot rollback a paused deployment; resume it first ...`
    /// - `error: unable to find specified revision 9 in history`
    @discardableResult
    func rolloutUndo(
        _ object: K8sObject, toRevision revision: Int?, dryRun: Bool, context: String
    ) async throws -> String {
        var arguments = ["undo"]
        if let revision { arguments.append("--to-revision=\(revision)") }
        if dryRun { arguments.append("--dry-run=server") }
        return try await rollout(arguments, on: object, context: context).stdoutText
    }

    /// `rollout` 系の共通部分。**種別と Namespace の付け方を 1 か所にする。**
    @discardableResult
    private func rollout(
        _ arguments: [String], on object: K8sObject, context: String
    ) async throws -> CommandResult {
        guard let kind = object.kind, kind.supportsRollout else {
            throw KubectlError.unsupportedRollout(
                object.kind?.displayName ?? String(localized: "この種別"))
        }
        // `種別/名前` の形なので先頭が `-` にはならないが、名前そのものは
        // 同じ規則で検める（`/` を含む名前をここで繋ぐと別の対象を指す）。
        let name = try Self.checkedName(object.name)
        var full = ["rollout"] + arguments + ["\(kind.resourceName)/\(name)"]
        if let namespace = object.namespace {
            full += ["-n", namespace]
        }
        full.append("--request-timeout=\(requestTimeout)")
        return try await run(full, context: context)
    }

    /// 実測した書式（private にしないのは、依存をテストで固めるため）:
    /// ```
    /// deployment.apps/demo
    /// REVISION  CHANGE-CAUSE
    /// 1         <none>
    /// 2         pause 3.10 に上げた
    /// ```
    /// **見出しの位置で切らない。** CHANGE-CAUSE には空白が入る（人が書く文）ので、
    /// 最初の空白までを世代番号、残りを理由として読む。番号として読めない行は
    /// 見出しや空行なので落とす。
    static func parseRolloutHistory(_ text: String) -> [RolloutRevision] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard let first = parts.first, let revision = Int(first) else { return nil }
            let cause = parts.count > 1
                ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            return RolloutRevision(
                revision: revision,
                changeCause: (cause.isEmpty || cause == "<none>") ? nil : cause)
        }
    }

    // MARK: - 編集した YAML を書き戻す

    /// **`apply` ではなく `replace`。**
    ///
    /// `apply` は `last-applied-configuration` との 3 方向マージなので、
    /// **画面から消した項目が消えないこと**がある（その注釈に無い項目は
    /// 「消した」と判断されない）。編集の入口としては「見えている YAML が
    /// そのまま新しい姿になる」ほうが読み違えようがない。
    ///
    /// `replace` は `resourceVersion` ごと送るので、**開いたあとに誰かが
    /// 変えていれば弾かれる**（実測: `Error from server (Conflict): ... the object
    /// has been modified`）。逆に `resourceVersion` を落とすと無条件に上書きする
    /// ので、**落とさない。**
    ///
    /// **種別も Namespace も引数で渡さない。** YAML 自身が持っているものを
    /// kubectl に読ませる。渡すと食い違ったときに弾かれるだけで、CRD にも
    /// そのまま効かなくなる。
    ///
    /// **一時ファイルに書かない**（標準入力に流す）。Secret を編集したときに
    /// 中身がディスクへ残る。
    @discardableResult
    func replace(yaml: String, dryRun: Bool, context: String) async throws -> String {
        var arguments = ["replace", "-f", "-", "--request-timeout=\(requestTimeout)"]
        if dryRun { arguments.append("--dry-run=server") }
        let result = try await run(
            arguments, context: context, input: Data(yaml.utf8))
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// strategic merge patch を当てる。
    ///
    /// **`set resources` のような専用のサブコマンドを使わない。** 実測で
    /// `set resources` は値を**外せない**（`--limits=cpu=0` は「0 という上限」を
    /// 書き込む）。patch なら `null` でキーが消え、コンテナは名前で合う。
    ///
    /// 種別は `--type` を指定しない既定（組み込みは strategic）に任せる。
    @discardableResult
    func patch(
        _ object: K8sObject, resource: String, patch: String, dryRun: Bool, context: String
    ) async throws -> String {
        var arguments = ["patch", resource, try Self.checkedName(object.name), "-p", patch,
                         "--request-timeout=\(requestTimeout)"]
        if let namespace = object.namespace {
            arguments += ["-n", namespace]
        }
        if dryRun { arguments.append("--dry-run=server") }
        let result = try await run(arguments, context: context)
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// ラベルで選んだ Pod の、コンテナごとの使用量。
    ///
    /// **全 Pod を引いてから絞らない。** 上限を決めるときに見たいのは
    /// そのワークロードの Pod だけで、サーバ側で絞れる（`kubectl top -l` と
    /// 同じ経路）。
    func containerUsage(
        selector: [String: String], namespace: String, context: String
    ) async throws -> [String: [ResourceUsage]] {
        guard !selector.isEmpty else { return [:] }
        let expression = selector.map { "\($0.key)=\($0.value)" }
            .sorted().joined(separator: ",")
        let data: Data
        if let api = await api(for: context),
           let found = try? await APIDiscovery.shared.resource(
            for: "pods.metrics.k8s.io", context: context, client: api) {
            data = try await api.data(
                path: found.listPath(namespace: namespace),
                query: [URLQueryItem(name: "labelSelector", value: expression)])
        } else {
            data = try await run(
                ["get", "pods.metrics.k8s.io", "-o", "json", "-n", namespace,
                 "-l", expression, "--request-timeout=\(requestTimeout)"],
                context: context).stdout
        }

        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { return [:] }
        var result: [String: [ResourceUsage]] = [:]
        for item in root["items"]?.arrayValue ?? [] {
            for container in item["containers"]?.arrayValue ?? [] {
                guard let name = container["name"]?.stringValue else { continue }
                result[name, default: []].append(Self.usage(from: container["usage"]))
            }
        }
        return result
    }

    /// 書き戻しが「他人の更新とぶつかった」ものかどうか。
    ///
    /// **他の失敗と混ぜない。** 綴り間違いや immutable なフィールドは直せば
    /// 通るが、こちらは**中身が古いだけ**で、直す先が違う（読み直す）。
    /// 実測した書式に依存しているのでテストで固めてある。
    static func isConflict(_ message: String) -> Bool {
        message.contains("(Conflict)") || message.contains("the object has been modified")
    }

    func cordon(_ node: K8sObject, unschedulable: Bool, context: String) async throws {
        try await run(
            [unschedulable ? "cordon" : "uncordon", try Self.checkedName(node.name)],
            context: context)
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
        var arguments = ["drain", try Self.checkedName(node.name),
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
        /// 読むコンテナ。nil なら Pod の既定（1 つのとき）か、
        /// `allContainers` が立っていれば全部。
        var container: String?
        var follow: Bool = true
        var tailLines: Int = 500
        var previous: Bool = false
        var timestamps: Bool = false
        /// コンテナを選んでいないときに全部読むか。まとめ読みの既定。
        var allContainers: Bool = false
        /// `--max-log-requests`。**kubectl の既定 5 のままにしない** ——
        /// 6 レプリカの Deployment を追いかけようとしただけで弾かれる。
        /// 上げても青天井にはしない（1 本の kubectl が張る同時接続の数なので、
        /// 数百 Pod の Service で全部に繋ぎに行かせても読めたものではない）。
        /// 超えたぶんは kubectl が文言で断る（stderr は本文に混ざる）。
        var maxLogRequests: Int = LogOptions.defaultMaxLogRequests

        /// 画面（「N 個中 M 個だけ」の断り）と引数で同じ値を使うための既定。
        static let defaultMaxLogRequests = 30
    }

    /// 何のログを読むか。
    ///
    /// **セレクタのときも kubectl 1 本で済ませる。** Pod ごとに
    /// `kubectl logs -f` を起こすと、Pod の数だけプロセスが立つ
    /// （1 本あたりスレッド 3 本、というのは取得系で一度踏んで直した話）。
    /// kubectl は `-l` で多重化して `--prefix` で出どころを書いてくれるので、
    /// 混ぜ方も並べ替えも向こうに任せる。
    enum LogTarget: Sendable, Equatable {
        case pod(String)
        case selector([String: String])
    }

    /// Pod オブジェクトではなく名前・セレクタで受ける。ログは別ウインドウで
    /// 開くので、一覧が読み直されてオブジェクトが差し替わっても影響を受けない
    /// ようにする。
    func logStream(
        namespace: String, target: LogTarget, options: LogOptions, context: String
    ) throws -> (lines: AsyncStream<[String]>, handle: ProcessHandle) {
        if case .selector(let labels) = target, labels.isEmpty {
            // **空のセレクタで引かない。** `-l` を付けずに投げたのと同じに
            // なり、Namespace の Pod を全部読む。ここまで来ないはずだが
            // （`PodLogRequest(group:)` が弾く）、届く道が残るなら塞ぐ。
            throw CommandError(
                command: "kubectl logs", exitCode: -1,
                message: String(localized: "セレクタが空です。掴んでいる Pod を決められません。"))
        }
        let environment = try environment()
        let arguments = Self.logArguments(
            namespace: namespace, target: target, options: options, context: context)

        return ProcessRunner.stream(
            executable: environment.executable,
            arguments: arguments,
            environment: environment.variables)
    }

    /// `kubectl logs` の引数。**純粋関数にしておく** —— プロセスを起こさずに
    /// 固められる唯一の部分で、ここが狂うと画面には「ログがありません」としか
    /// 出ない（＝間違っていることに気付けない）。
    static func logArguments(
        namespace: String, target: LogTarget, options: LogOptions, context: String
    ) -> [String] {
        // ここは `run` を通らないので、キャッシュの置き場所を自分で渡す
        // （置き場所が 2 つあると、片方だけ壊れたときに症状が食い違う）。
        var arguments = ["--cache-dir=\(cacheDirectory)", "--context", context, "logs"]

        switch target {
        case .pod(let name):
            // **ここも位置引数。** 純粋関数なので投げられないが、`pod/<名前>` の
            // 形にすれば先頭が `-` にならず、フラグには化けない（`kubectl logs`
            // は `種別/名前` を受け取る）。読み取り系なので止めるまではしない。
            arguments.append(name.hasPrefix("-") ? "pod/\(name)" : name)
        case .selector(let labels):
            arguments.append("--selector=" + labels
                .map { "\($0.key)=\($0.value)" }
                .sorted()
                .joined(separator: ","))
            arguments.append("--max-log-requests=\(options.maxLogRequests)")
        }

        if !namespace.isEmpty { arguments += ["-n", namespace] }

        if let container = options.container, !container.isEmpty {
            arguments += ["-c", container]
        } else if options.allContainers {
            arguments.append("--all-containers=true")
        }

        // **`--prefix` は自分で付ける。** `--all-containers` にも
        // 「Sets prefix to true」とヘルプに書いてあるが、暗黙に任せると
        // 版で変わったときに**剥がす側だけがずれる**（本文の先頭が黙って
        // 消えるか、prefix が本文に残る）。明示すれば同じことが 1 か所で決まる。
        if logsArePrefixed(target: target, options: options) {
            arguments.append("--prefix")
        }

        // **`--tail` は必ず明示する。** セレクタを付けたときの kubectl の既定は
        // 10 行（実測。`kubectl logs --help` の `--tail` の説明）。黙って
        // 落とすと、まとめ読みのときだけ 10 行しか出ない。
        arguments += ["--tail=\(options.tailLines)"]
        if options.follow { arguments.append("--follow") }
        if options.previous { arguments.append("--previous") }
        if options.timestamps { arguments.append("--timestamps") }
        return arguments
    }

    /// この指定で kubectl が行頭に出どころ（`[pod/<Pod>/<コンテナ>] `）を
    /// 書くか。
    ///
    /// **`logArguments` と別に判断しない。** 剥がす側（`LogLine`）と
    /// 食い違うと、本文の先頭が黙って消えるか、prefix が本文に残って
    /// 絞り込みと深刻度の判定を狂わせる。両方がこの 1 つを見る。
    ///
    /// - セレクタ: どの Pod の行かが分からないとまとめて読む意味が無いので必ず。
    /// - 全コンテナ: Pod 1 つでも、どのコンテナの行かが分からなくなる。
    static func logsArePrefixed(target: LogTarget, options: LogOptions) -> Bool {
        if case .selector = target { return true }
        return options.allContainers && (options.container ?? "").isEmpty
    }
}
