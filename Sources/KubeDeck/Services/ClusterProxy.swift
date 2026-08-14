import Foundation

/// `kubectl proxy` をコンテキストごとに 1 本常駐させ、その待ち受け先を配る。
///
/// **方針は変えていない。認証は kubectl に委ねたまま。** 変えるのは委ね方だけで、
/// 「取得のたびに 1 プロセス起こす」のを「1 本を常駐させる」にする。中で動くのは
/// client-go なので、exec 認証プラグイン（GKE の `gke-gcloud-auth-plugin`、EKS の
/// `aws`）・クライアント証明書・OIDC のトークン更新・プロキシ設定は、これまでと
/// 同じように kubectl が肩代わりする。
///
/// **期限切れをまたいでも動き続ける（実測）。** 40 秒で切れるトークンを返す
/// exec プラグインを kind に向けて仕込み、常駐 proxy に 10 秒ごとに引かせた結果、
/// 142 秒間ずっと HTTP 200 で、プラグインは 40 秒ごとにきちんと呼び直されていた
/// （17:02:26 → 17:03:06 → 17:03:47 → 17:04:28）。`provideClusterInfo: true` の
/// `KUBERNETES_EXEC_INFO` も渡っている。**常駐にすると認証が切れる、はしない。**
///
/// **待ち受けは loopback ＋ ランダムな URL prefix。**
/// `kubectl proxy` には認証の仕組みが無いので、prefix を知らない相手には
/// 404 を返させることで札の代わりにする（Freelens が同じ手を使っている）。実測:
///
/// ```
/// $ kubectl proxy --port=0 --api-prefix=/<16桁hex>/
/// Starting to serve on 127.0.0.1:64073      ← 127.0.0.1 のみ LISTEN
/// $ curl .../<正しい prefix>/api/v1/nodes → 200
/// $ curl .../api/v1/nodes                 → 404
/// ```
///
/// **prefix は資格情報として扱う。** ログにも画面にも出さない。`URLError` の
/// `localizedDescription` には失敗した URL がそのまま入るので、外へ出す文言は
/// 必ず `redacting(_:)` を通す。
///
/// **`ps` からは他ユーザに見えない（実測）。** prefix は引数に載るが、macOS の
/// `KERN_PROCARGS2` は他ユーザのプロセスに対して EINVAL を返す（root の pid 1 で
/// 確認。自分のプロセスでは 0）。同じユーザなら見えるが、その相手は
/// `~/.kube/config` を直接読めるので、この proxy が増やす露出ではない。
///
/// **unix ソケットにしない。** 0700 で塞げる（実測 `srwx------`）代わりに、
/// `sun_path` の 104 バイト制限に当たる —— 実際のコンテキスト名を混ぜたパスは
/// 147 バイトで `bind: invalid argument` になった。URLSession は unix ソケットを
/// 喋れないので、そこを取るなら HTTP クライアントを別に抱えることになる。
actor ClusterProxy {
    static let shared = ClusterProxy()

    /// 立ち上がるまでの待ち上限。実測では kind で 1.20〜1.50 秒だが、
    /// exec プラグインが gcloud を起こす経路はもっとかかる。
    private static let startupTimeout: TimeInterval = 25
    /// 立て直しの間隔。**失敗し続ける相手に毎回起こしに行かない。**
    private static let retryCooldown: TimeInterval = 10

    private var instances: [String: Instance] = [:]
    /// 走っている起動。**同時に何本も立てないために持つ。**
    ///
    /// アクターは 1 度に 1 つの呼び出ししか通さないが、`await` で中断している
    /// あいだは別の呼び出しが入る（再入）。起動には環境の解決と待ち受けの待ちで
    /// 数秒かかるので、その隙に他の読み手が「まだ無い」と判断して**自分の
    /// proxy を立てる**。実測でこれを踏み、1 回の立て直しで**3 本**同時に
    /// 立った（pid 90803 / 90804 / 90805。しかもアプリが落ちたあと 3 本とも
    /// 孤児として残った）。`APIDiscovery` の `loading` と同じ手当てをする。
    private var starting: [String: Task<Instance, Error>] = [:]
    /// 直近の失敗。**黙って kubectl 経由へ流さないための材料。**
    private var failures: [String: Failure] = [:]
    private var reapedStalePIDs = false

    struct Failure: Sendable {
        var at: Date
        var reason: String
    }

    /// 待ち受け先。prefix まで含んだ URL を持つ。
    struct Endpoint: Sendable {
        let baseURL: URL
        /// 画面と文言のための伏せる対象。
        let secret: String

        func url(path: String, query: [URLQueryItem]) -> URL? {
            guard var components = URLComponents(
                url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
            else { return nil }
            components.queryItems = query.isEmpty ? nil : query
            return components.url
        }

        /// 外へ出す文言から prefix を落とす。
        func redacting(_ text: String) -> String {
            guard !secret.isEmpty else { return text }
            return text.replacingOccurrences(of: secret, with: "…")
        }
    }

    /// 画面に出す状態。**prefix は入れない。**
    struct Diagnostics: Sendable {
        var context: String
        var address: String
        var pid: Int32
        var startedAt: Date
        var isRunning: Bool
        /// proxy 自身が書き出した直近の文言。
        ///
        /// **これを捨てない。** 認証プラグインが失敗したとき、HTTP の body には
        /// `getting credentials: exec: executable … failed with exit code 1` しか
        /// 来ず、**プラグイン本人の文言はここにしか出ない**（実測。素の
        /// `kubectl proxy` でも client-go を自分で埋めた版でも同じだった）。
        var recentOutput: [String]
    }

    // MARK: - 配る

    /// そのコンテキストの待ち受け先。無ければ立ち上げる。
    func endpoint(for context: String) async throws -> Endpoint {
        reapStalePIDsIfNeeded()

        if let instance = instances[context],
           instance.isRunning, instance.matchesKubeconfig() {
            return instance.endpoint
        }

        // **走っている起動があれば、それに乗る。** ここを見ずに立てると、
        // 概要の 13 種別が同時に読みに来るだけで proxy が 13 本立つ。
        if let task = starting[context] {
            let instance = try await task.value
            // **相乗りした側も、畳まれていないかを見る。** 待っているあいだに
            // コンテキストが切り替わると `drainStarts` がこの起動を引き取って
            // 終わらせている。立てた本人だけが確かめる作りにしていたので、
            // 相乗り側には**すでに死んだ proxy の待ち受け先**が配られていた
            // （症状は「立ち上げ直後だけ接続を拒まれる」）。
            //
            // **「まだ登録されていない」を「畳まれた」と読まない。** 起動が
            // 終わると待っていた全員が動き出せるようになるが、登録するのは
            // 立てた本人だけ。`instances` だけを見ると、本人より先に動いた
            // 相乗り側が**必ず**弾かれる（実測でそうなった）。畳まれたかどうかは
            // 「この起動がまだ現役か」で見る —— `drainStarts` は引き取るときに
            // `starting` から外す。
            guard starting[context] == task || instances[context]?.pid == instance.pid,
                  instance.isRunning
            else {
                throw ClusterProxyError.unavailable(
                    String(localized: "立ち上げの途中で畳まれました。"))
            }
            return instance.endpoint
        }

        if let failure = failures[context],
           Date().timeIntervalSince(failure.at) < Self.retryCooldown {
            throw ClusterProxyError.unavailable(failure.reason)
        }

        // 死んだもの、kubeconfig が変わったものは片付けてから立て直す。
        //
        // **kubeconfig を見張る理由。** 取得ごとに kubectl を起こしていたときは
        // 呼び出しのたびに読み直されていたので、「到達できない `server:` を
        // 直したら勝手に復帰する」が成り立っていた。常駐は起動時に 1 度読む
        // だけなので、こちらで見張らないとその性質が失われる。
        if let instance = instances.removeValue(forKey: context) {
            instance.terminate()
            removePIDFile(pid: instance.pid)
        }

        let task = Task { try await self.start(context: context) }
        starting[context] = task
        defer { if starting[context] == task { starting[context] = nil } }
        do {
            let instance = try await task.value
            // **畳まれていたら登録し直さない。** 待っているあいだに
            // `keepOnly` / `stopAll`（コンテキスト切り替え・設定の切り替え・
            // 終了）が走ると、`drainStarts` がこの起動を引き取って**すでに
            // 終わらせている**。それを生きているものとして覚えると、死んだ
            // proxy の待ち受け先を配り、しかも `failures` を消すので理由も
            // 残らない。
            guard starting[context] == task else {
                throw ClusterProxyError.unavailable(
                    String(localized: "立ち上げの途中で畳まれました。"))
            }
            instances[context] = instance
            failures[context] = nil
            return instance.endpoint
        } catch {
            let reason = error.localizedDescription
            failures[context] = Failure(at: Date(), reason: reason)
            throw error
        }
    }

    /// 立てられなかった理由。設定画面が「いま何経由か」を書くために読む。
    func failure(for context: String) -> Failure? { failures[context] }

    func diagnostics(for context: String) -> Diagnostics? {
        instances[context]?.diagnostics(context: context)
    }

    // MARK: - 起こす / 止める

    private func start(context: String) async throws -> Instance {
        let environment = try await Kubectl.shared.environment()
        let secret = Self.makeSecret()
        let prefix = "/\(secret)/"
        // **`--append-server-path` を必ず付ける。**
        //
        // Connect Gateway 越しの GKE は、kubeconfig の `server:` に**パスが入る**
        // （`https://connectgateway.googleapis.com/v1/projects/<番号>/locations/
        // global/memberships/<名前>`）。`kubectl proxy` は既定でそのパスを
        // 付け直さないので、`/api/v1/nodes` はホスト直下へ飛んで **404** になる
        // （実測。付ければ 200 で 0.2〜0.6 秒）。kubectl 自身も起動時に
        // `use --append-server-path to automatically append the path` と警告する。
        //
        // **パスの無いクラスタでも害が無い**（付け足すものが無いだけ。kind と
        // docker-desktop で実測）。だから条件を見て出し入れせず、常に付ける ——
        // 出し入れすると「あの環境だけ 404」という、いちばん切り分けにくい
        // 壊れ方の余地を残す。
        var arguments = ["proxy", "--port=0", "--api-prefix=\(prefix)",
                         "--append-server-path"]
        // 覚えている API の一覧はターミナルの kubectl と共有しない
        // （縮退したファイルを互いに読まないようにするため）。
        arguments.append("--cache-dir=\(Kubectl.cacheDirectory)")
        if !context.isEmpty {
            arguments += ["--context", context]
        }
        // **読み取りしか通さない。** アプリは書き込みを kubectl の子プロセスで
        // 行うので、この口に POST / PUT / PATCH / DELETE が通る必要はない。
        // 既定の `--reject-methods` は `^$`（何も拒まない）なので、常駐している
        // あいだ**書き込みできる口が loopback に開いたまま**になる。読み取り専用の
        // 札（`ContextProfile.isReadOnly`）は画面と `ClusterStore` で守っているが、
        // 「画面で隠すだけにしない」に倣ってここでも塞ぐ。
        arguments.append("--reject-methods=^(POST|PUT|PATCH|DELETE)$")
        // **`--request-timeout` を渡さない。** 全要求に上限が掛かると watch が
        // 切られる。待ち上限は呼び出し側（URLSession）で持つ。
        // **`--reject-paths` は既定のまま。** exec / attach を 403 で塞ぐ
        // （実測）。アプリはターミナルに任せているので、開ける必要が無い。

        let instance = try await Instance.spawn(
            executable: environment.executable,
            arguments: arguments,
            environment: environment.variables,
            secret: secret,
            timeout: Self.startupTimeout,
            // **proxy に渡した環境の `KUBECONFIG` を見張る。**
            // アプリ自身の環境を見ていたら、`.zshrc` で `KUBECONFIG` を
            // 立てている人の**別のファイルを見張ることになる**（Finder から
            // 起動した `.app` の環境にはそれが無いので `~/.kube/config` に
            // 落ちる）。実際に proxy が読んでいるのはログインシェルの環境の
            // ほうなので、そちらと揃える。
            kubeconfig: environment.variables["KUBECONFIG"])
        writePIDFile(pid: instance.pid)
        return instance
    }

    func stop(context: String) async {
        guard let instance = instances.removeValue(forKey: context) else { return }
        instance.terminate()
        removePIDFile(pid: instance.pid)
    }

    /// 選んでいないコンテキストの proxy は畳む。
    ///
    /// **開いたぶんだけ常駐させない。** 1 本あたり RSS 31MB・10 スレッド（実測）
    /// なので、切り替えて回るだけで積み上がる。
    func keepOnly(_ context: String) async {
        await drainStarts(except: context)
        for key in instances.keys where key != context {
            await stop(context: key)
        }
    }

    func stopAll() async {
        await drainStarts(except: nil)
        for key in instances.keys {
            await stop(context: key)
        }
    }

    /// 立ち上がりかけている proxy を待って畳む。
    ///
    /// **走っている起動を無視して畳まない。** `Task.cancel()` では `Process` は
    /// 止まらないので、そのまま終わると**待ち受けたまま残る**。畳む前に
    /// 出来上がりを待って、その場で終わらせる。
    private func drainStarts(except keep: String?) async {
        let pending = starting.filter { $0.key != keep }
        for (context, task) in pending {
            starting[context] = nil
            guard let instance = try? await task.value else { continue }
            if instances[context]?.pid == instance.pid {
                instances[context] = nil
            }
            instance.terminate()
            removePIDFile(pid: instance.pid)
        }
    }

    // MARK: - 置き忘れの後始末

    /// 前回の起動で落ちたときに残った proxy を殺す。
    ///
    /// **アプリが落ちても proxy は生き残る**（`kubectl proxy` は親の死を見ない）。
    /// 残ると、次の起動で新しい prefix の proxy が別に立ち、古いほうは誰にも
    /// 使われないまま待ち受け続ける。pid を控えておいて、起動時に始末する。
    ///
    /// **pid だけで殺さない。** 使い回された pid が別のプロセスに当たっている
    /// ことがあるので、引数に `kubectl` と `proxy` が入っているかを確かめる。
    private func reapStalePIDsIfNeeded() {
        guard !reapedStalePIDs else { return }
        reapedStalePIDs = true
        let directory = Self.pidDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return }
        let live = Set(instances.values.map(\.pid))
        for file in files where file.hasSuffix(".pid") {
            let url = directory.appendingPathComponent(file)
            defer { try? FileManager.default.removeItem(at: url) }
            // **ファイル名から読む。** 中身が壊れていても pid は分かる。
            let named = Int32(file.replacingOccurrences(of: ".pid", with: ""))
            let stored = (try? String(contentsOf: url, encoding: .utf8))
                .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard let pid = named ?? stored, pid > 1, !live.contains(pid) else { continue }
            // **pid だけで殺さない。** 使い回された pid が別のプロセスに当たって
            // いることがあるので、引数に kubectl と proxy が入っているかを見る。
            guard Self.looksLikeOurProxy(pid: pid) else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// その pid が `kubectl proxy` かどうか。**同じユーザのプロセスしか見えない**
    /// ので、他人のプロセスを覗くことにはならない。
    static func looksLikeOurProxy(pid: Int32) -> Bool {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return false }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return false }
        // 先頭 4 バイトは argc。以降は NUL 区切りの実行パスと引数。
        let bytes = buffer.dropFirst(4).map { UInt8(bitPattern: $0) }
        let text = String(decoding: bytes.map { $0 == 0 ? UInt8(ascii: " ") : $0 }, as: UTF8.self)
        return text.contains("kubectl") && text.contains("proxy")
    }

    private static var pidDirectory: URL {
        let url = URL(fileURLWithPath: Kubectl.cacheDirectory, isDirectory: true)
            .appendingPathComponent("proxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// **pid ごとに 1 ファイルにする。** コンテキストごとの 1 ファイルにして
    /// いたら、立て直しが重なったときに**最後の書き込みか削除だけが残り、
    /// 残りの pid が記録から消えた**（実測。3 本のうち控えられていたのは
    /// 1 本だけで、残り 2 本は次の起動でも片付かなかった）。
    static func pidFile(pid: Int32) -> URL {
        pidDirectory.appendingPathComponent("\(pid).pid")
    }

    private func writePIDFile(pid: Int32) {
        try? "\(pid)".write(to: Self.pidFile(pid: pid), atomically: true, encoding: .utf8)
    }

    private func removePIDFile(pid: Int32) {
        try? FileManager.default.removeItem(at: Self.pidFile(pid: pid))
    }

    // MARK: - 終了時の後始末

    /// 走っている proxy の pid。**アクターの外から同期で殺すために持つ。**
    ///
    /// `NSApplication.willTerminateNotification` を待って `await stopAll()` を
    /// 呼ぶ形にしていたら、**アプリが先に終わって proxy が残った**（実測。
    /// ⌘Q と同じ経路で終了させても 1 本残る）。AppKit は終了を非同期の後始末の
    /// ために待ってくれないので、ここは待ち合わせ無しで殺せる形にしておく。
    private static let livePIDs = LivePIDs()

    final class LivePIDs: @unchecked Sendable {
        private let lock = NSLock()
        private var pids: Set<Int32> = []

        func add(_ pid: Int32) {
            lock.lock(); defer { lock.unlock() }
            pids.insert(pid)
        }

        func remove(_ pid: Int32) {
            lock.lock(); defer { lock.unlock() }
            pids.remove(pid)
        }

        func drain() -> [Int32] {
            lock.lock(); defer { lock.unlock() }
            let all = Array(pids)
            pids.removeAll()
            return all
        }
    }

    /// アプリが終わるときに呼ぶ。**同期で殺す。**
    ///
    /// `SIGTERM` で足りる（kubectl proxy は Go なので既定で終わる）。控えた
    /// pid ファイルも消す。
    nonisolated static func terminateAllNow() {
        for pid in livePIDs.drain() {
            kill(pid, SIGTERM)
            try? FileManager.default.removeItem(at: pidFile(pid: pid))
        }
    }

    /// 推測されないだけの長さを取る。16 桁の 16 進＝64 ビット。
    private static func makeSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%016llx", UInt64.random(in: UInt64.min...UInt64.max, using: &generator))
    }
}

// MARK: - 失敗

enum ClusterProxyError: LocalizedError {
    /// 立て直しの間隔を空けている最中。
    case unavailable(String)
    /// 立ち上がらなかった。
    case startupFailed(String)
    /// 待っても待ち受け先を言わなかった。
    case startupTimedOut(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason), .startupFailed(let reason):
            return String(localized: "kubectl proxy を立ち上げられませんでした。\(reason)")
        case .startupTimedOut(let output):
            let tail = output.isEmpty
                ? String(localized: "（proxy は何も書き出していません）") : output
            return String(localized: """
                kubectl proxy が待ち受けを始めませんでした。
                \(tail)
                """)
        }
    }
}

// MARK: - 1 本ぶん

extension ClusterProxy {
    /// 走っている proxy 1 本。`Process` をアクター境界に持ち出さないため、
    /// 鍵を持った最終クラスに閉じ込める（`ProcessHandle` と同じ作り）。
    final class Instance: @unchecked Sendable {
        let endpoint: Endpoint
        let pid: Int32
        let startedAt: Date

        private let lock = NSLock()
        private let process: Process
        private let output: OutputBuffer
        private let kubeconfigFingerprint: String

        /// 見張っている kubeconfig（`KUBECONFIG` の中身。nil なら既定の場所）。
        private let kubeconfig: String?

        private init(
            process: Process, endpoint: Endpoint, output: OutputBuffer, fingerprint: String,
            kubeconfig: String?
        ) {
            self.kubeconfig = kubeconfig
            self.process = process
            self.endpoint = endpoint
            self.pid = process.processIdentifier
            self.startedAt = Date()
            self.output = output
            self.kubeconfigFingerprint = fingerprint
        }

        var isRunning: Bool {
            lock.lock()
            defer { lock.unlock() }
            return process.isRunning
        }

        /// 起動したときと同じ kubeconfig か。
        func matchesKubeconfig() -> Bool {
            kubeconfigFingerprint == Instance.fingerprintKubeconfig(kubeconfig)
        }

        func diagnostics(context: String) -> Diagnostics {
            Diagnostics(
                context: context,
                address: endpoint.baseURL.host.map { host in
                    endpoint.baseURL.port.map { "\(host):\($0)" } ?? host
                } ?? "-",
                pid: pid,
                startedAt: startedAt,
                isRunning: isRunning,
                recentOutput: output.lines().map { endpoint.redacting($0) })
        }

        /// **待たずに殺す。** ここはアクター（`ClusterProxy`）から呼ばれるので、
        /// 中で 2 秒眠ると**その間すべての取得が止まる**（コンテキストを
        /// 切り替えるたびに起きる）。SIGTERM を送って、止めを刺す役は別の
        /// スレッドに預ける。
        func terminate() {
            ClusterProxy.livePIDs.remove(pid)
            lock.lock()
            let target = process
            lock.unlock()
            guard target.isRunning else { return }
            target.terminate()
            let thread = Thread {
                let deadline = Date().addingTimeInterval(2)
                while target.isRunning, Date() < deadline {
                    usleep(50_000)
                }
                if target.isRunning {
                    kill(target.processIdentifier, SIGKILL)
                }
            }
            thread.stackSize = 128 << 10
            thread.start()
        }

        /// 起こして、待ち受け先を言うまで待つ。
        ///
        /// **待ち受けを始めたことは、認証が通ったことを意味しない**（実測。
        /// 失敗するプラグインでも `Starting to serve on …` は出る）。だから
        /// ここでは疎通を確かめない —— 確かめるのは実際の要求のほうで、
        /// そちらの失敗として言い換える。
        static func spawn(
            executable: String,
            arguments: [String],
            environment: [String: String],
            secret: String,
            timeout: TimeInterval,
            kubeconfig: String?
        ) async throws -> Instance {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            let output = OutputBuffer()
            let address = AddressWaiter()

            do {
                try process.run()
            } catch {
                throw ClusterProxyError.startupFailed(error.localizedDescription)
            }
            // **立ち上がりを待つ前に控える。** 待ち上限まで返ってこない相手
            // （返事をしない exec 認証プラグイン）は、まさにこの経路で捨てられる。
            // 控えていないと `terminateAllNow()` にも次回起動の回収にも引っ掛か
            // らず、待ち受けたまま残る。
            ClusterProxy.livePIDs.add(process.processIdentifier)
            try? "\(process.processIdentifier)".write(
                to: ClusterProxy.pidFile(pid: process.processIdentifier),
                atomically: true, encoding: .utf8)

            // **読み手は専用スレッドで走らせる。GCD のプールに載せない。**
            // 常駐なので走り続ける。しかも **stderr を汲まないと詰まる** ——
            // パイプが埋まった時点で proxy 自身が書き込みで止まる。
            detach { [weak output, weak address] in
                readLines(from: stdout.fileHandleForReading) { line in
                    output?.append(line)
                    if let found = parseAddress(line) { address?.resolve(found) }
                }
                // **待ち受けを言わずに終わったら、そこで諦める。**
                // ここを待ち上限だけに任せていると、**即死しても 25 秒黙る**
                // （実測: 存在しないコンテキストを渡した kubectl proxy は
                // `error: context … does not exist` を出して 0.12 秒で終わる）。
                // すると最初の取得が 25 秒固まり、しかも立て直しの間隔は
                // 10 秒なので、35 秒ごとに 25 秒固まり続ける。
                address?.giveUp()
            }
            detach { [weak output] in
                readLines(from: stderr.fileHandleForReading) { line in
                    output?.append(line)
                }
            }

            guard let resolved = await address.wait(timeout: timeout) else {
                abandon(process)
                throw ClusterProxyError.startupTimedOut(output.lines().joined(separator: "\n"))
            }
            guard let url = URL(string: "http://\(resolved)/\(secret)") else {
                abandon(process)
                throw ClusterProxyError.startupFailed(
                    String(localized: "待ち受け先を読み取れませんでした。"))
            }

            let instance = Instance(
                process: process,
                endpoint: Endpoint(baseURL: url, secret: secret),
                output: output,
                fingerprint: fingerprintKubeconfig(kubeconfig),
                kubeconfig: kubeconfig)
            return instance
        }

        /// `Starting to serve on 127.0.0.1:64073` から待ち受け先を取る。
        ///
        /// **大文字小文字を決め打ちしない。** 手元の v1.32.13 と v1.36.2 はどちらも
        /// `Starting` だったが、ここが変わっても止まらないようにしておく
        /// （Freelens も正規表現に `i` を付けている）。unix ソケットのときは
        /// パスが来るので、`:` を含む＝ホストとポートのときだけ受ける。
        static func parseAddress(_ line: String) -> String? {
            let marker = "starting to serve on"
            let lowered = line.lowercased()
            guard let range = lowered.range(of: marker) else { return nil }
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !tail.isEmpty, tail.contains(":") else { return nil }
            return tail
        }

        /// kubeconfig の指紋。`KUBECONFIG` が複数を並べる形にも合わせる。
        ///
        /// - Parameter value: proxy に渡した環境の `KUBECONFIG`。
        ///   **アプリ自身の環境を見ない**（上の `kubeconfig` の説明を参照）。
        static func fingerprintKubeconfig(_ value: String?) -> String {
            let paths: [String]
            if let value, !value.isEmpty {
                paths = value.split(separator: ":").map(String.init)
            } else {
                paths = [NSHomeDirectory() + "/.kube/config"]
            }
            return paths.map { path -> String in
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let date = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
                let size = (attributes?[.size] as? Int) ?? 0
                return "\(path):\(Int(date)):\(size)"
            }.joined(separator: "|")
        }

        /// 立ち上がりに失敗したプロセスを始末する。**SIGTERM で終わらない相手が
        /// いる**（返事をしない認証プラグインを抱えたまま止まっている）ので、
        /// 止めを刺すところまで面倒を見る。
        private static func abandon(_ process: Process) {
            ClusterProxy.livePIDs.remove(process.processIdentifier)
            try? FileManager.default.removeItem(
                at: ClusterProxy.pidFile(pid: process.processIdentifier))
            guard process.isRunning else { return }
            process.terminate()
            let thread = Thread {
                let deadline = Date().addingTimeInterval(2)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            thread.stackSize = 128 << 10
            thread.start()
        }

        private static func detach(_ work: @escaping @Sendable () -> Void) {
            let thread = Thread(block: work)
            thread.stackSize = 512 << 10
            thread.start()
        }

        /// パイプを行で読む。**塊で来たぶんをまとめて割る**（1 行ずつ
        /// `availableData` を呼ぶと、行の途中で切れた塊を落とす）。
        private static func readLines(
            from handle: FileHandle, _ each: @escaping (String) -> Void
        ) {
            var pending = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let index = pending.firstIndex(of: 0x0A) {
                    let line = pending[pending.startIndex..<index]
                    pending.removeSubrange(pending.startIndex...index)
                    if let text = String(data: line, encoding: .utf8), !text.isEmpty {
                        each(text)
                    }
                }
            }
            if !pending.isEmpty, let text = String(data: pending, encoding: .utf8) {
                each(text)
            }
        }
    }

    /// proxy が書き出した行を、直近ぶんだけ持つ。
    final class OutputBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: [String] = []
        /// **際限なく溜めない。** 届かないクラスタでは 1 要求ごとに数行書く。
        private let limit = 40

        func append(_ line: String) {
            lock.lock()
            defer { lock.unlock() }
            buffer.append(line)
            if buffer.count > limit {
                buffer.removeFirst(buffer.count - limit)
            }
        }

        func lines() -> [String] {
            lock.lock()
            defer { lock.unlock() }
            return buffer
        }
    }

    /// 待ち受け先が分かるまで待つ。
    private final class AddressWaiter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        /// proxy が待ち受けを言わずに終わった。
        private var gaveUp = false
        private var continuations: [CheckedContinuation<String?, Never>] = []

        func resolve(_ address: String) {
            lock.lock()
            guard value == nil, !gaveUp else { lock.unlock(); return }
            value = address
            let waiting = continuations
            continuations = []
            lock.unlock()
            for continuation in waiting { continuation.resume(returning: address) }
        }

        /// もう待ち受けは来ない（proxy が終わった）。
        func giveUp() {
            lock.lock()
            guard value == nil, !gaveUp else { lock.unlock(); return }
            gaveUp = true
            let waiting = continuations
            continuations = []
            lock.unlock()
            for continuation in waiting { continuation.resume(returning: nil) }
        }

        func wait(timeout: TimeInterval) async -> String? {
            let sleeper = Task {
                try? await Task.sleep(for: .seconds(timeout))
                self.timeout()
            }
            defer { sleeper.cancel() }
            return await withCheckedContinuation { continuation in
                lock.lock()
                if let value {
                    lock.unlock()
                    continuation.resume(returning: value)
                    return
                }
                if gaveUp {
                    lock.unlock()
                    continuation.resume(returning: nil)
                    return
                }
                continuations.append(continuation)
                lock.unlock()
            }
        }

        private func timeout() {
            lock.lock()
            let waiting = continuations
            continuations = []
            lock.unlock()
            for continuation in waiting { continuation.resume(returning: nil) }
        }
    }
}
