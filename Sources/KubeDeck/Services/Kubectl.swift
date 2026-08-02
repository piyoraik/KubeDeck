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

        let searchPath = Self.searchPath()
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

        var variables = [
            "PATH": searchPath.joined(separator: ":"),
            "HOME": NSHomeDirectory(),
            // 認証プラグインが対話プロンプトを出すと待ち続けるので、非対話に倒す。
            "TERM": "dumb",
        ]
        // kubeconfig の場所をユーザが変えている場合はそれに従う。
        for key in ["KUBECONFIG", "AWS_PROFILE", "AWS_REGION", "GOOGLE_APPLICATION_CREDENTIALS",
                    "CLOUDSDK_CONFIG", "SSL_CERT_FILE", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"] {
            if let value = ProcessInfo.processInfo.environment[key] {
                variables[key] = value
            }
        }

        let resolved = KubectlEnvironment(executable: executable, variables: variables)
        cachedEnvironment = resolved
        return resolved
    }

    /// Finder から起動したアプリの PATH は `/usr/bin:/bin:/usr/sbin:/sbin` しかない。
    /// kubectl 本体だけでなく、kubeconfig の exec プラグイン（aws,
    /// gke-gcloud-auth-plugin など）も PATH から引かれるので、ここで補う。
    private static func searchPath() -> [String] {
        let home = NSHomeDirectory()
        var directories = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/local/sbin",
            "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.krew/bin",
            "\(home)/bin",
            "\(home)/.local/bin",
            "\(home)/google-cloud-sdk/bin",
            "/usr/local/share/google-cloud-sdk/bin",
            "/opt/homebrew/share/google-cloud-sdk/bin",
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

        let result = try await ProcessRunner.run(
            executable: environment.executable,
            arguments: fullArguments,
            environment: environment.variables)

        guard result.exitCode == 0 else {
            throw CommandError(
                command: "kubectl " + fullArguments.joined(separator: " "),
                exitCode: result.exitCode,
                message: result.stderr)
        }
        return result
    }

    /// いま使っている kubectl の場所。設定画面に出す。
    func resolvedExecutablePath() -> String? {
        (try? environment())?.executable
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

    /// 複数種別を 1 回の kubectl で取る。概要画面が 10 個以上プロセスを
    /// 起動しないようにするため。まとめて get すると items に kind が入るので、
    /// 呼び出し側で振り分けられる。
    func list(
        kinds: [ResourceKind], context: String, namespace: String?
    ) async throws -> [K8sObject] {
        guard !kinds.isEmpty else { return [] }
        let names = kinds.map(\.resourceName).joined(separator: ",")
        var arguments = ["get", names, "-o", "json",
                         "--request-timeout=\(requestTimeout)",
                         // 権限の無い種別が 1 つあるだけで全部落ちるのを避ける。
                         "--ignore-not-found=true"]
        // 種別が混ざるので、Namespace 非依存のものが含まれていても
        // --all-namespaces / -n はそのまま通る。
        arguments += scope(for: kinds.contains { $0.isNamespaced } ? .pod : .node,
                           namespace: namespace)
        let result = try await run(arguments, context: context)
        guard !result.stdout.isEmpty else { return [] }
        return try K8sObject.list(from: result.stdout)
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
    func metricsServerAvailable(context: String) async -> Bool {
        do {
            _ = try await run(
                ["get", "--raw", "/apis/metrics.k8s.io/v1beta1/nodes",
                 "--request-timeout=\(requestTimeout)"],
                context: context)
            return true
        } catch {
            return false
        }
    }

    /// Pod と Node の現在の使用量。
    ///
    /// 片方が取れなくてももう片方は返す。metrics-server が起動した直後は
    /// Pod 側だけ空、ということが起きるため。
    func metrics(context: String, namespace: String?) async -> MetricsSnapshot {
        var snapshot = MetricsSnapshot()

        if let data = try? await raw("/apis/metrics.k8s.io/v1beta1/nodes", context: context),
           let root = try? JSONDecoder().decode(JSONValue.self, from: data) {
            for item in root["items"]?.arrayValue ?? [] {
                guard let name = item.path("metadata.name")?.stringValue else { continue }
                snapshot.nodes[name] = Self.usage(from: item["usage"])
            }
        }

        let podsPath = namespace.map { "/apis/metrics.k8s.io/v1beta1/namespaces/\($0)/pods" }
            ?? "/apis/metrics.k8s.io/v1beta1/pods"
        if let data = try? await raw(podsPath, context: context),
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
    ) throws -> (lines: AsyncStream<String>, handle: ProcessHandle) {
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
