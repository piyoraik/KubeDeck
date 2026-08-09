import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: String
    /// 待ち上限で打ち切ったか。終了コードだけでは、相手が自分で失敗したのか
    /// こちらが殺したのかが区別できない。
    var timedOut = false

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

struct CommandError: LocalizedError, Sendable {
    let command: String
    let exitCode: Int32
    let message: String
    /// 失敗したときに、それでも書き出されていた標準出力。
    ///
    /// **捨てない。** kubectl は複数種別をまとめて get したとき、権限で拒まれた
    /// 種別があっても**読めた種別は標準出力に書いてから終了コード 1 で終わる**。
    /// ここに載せておかないと、呼び出し側は取れているデータを見ることすらできない。
    var partialStdout: Data?
    /// 言い換える前の stderr。種別ごとの失敗を拾い直すために持つ。
    var rawStderr: String = ""
    /// この失敗が、**引き直したあとの** API の一覧に照らしたものか。
    ///
    /// **「取れなかった」と「無いと確かめた」を分けるための印。** kubectl の
    /// `the server doesn't have a resource type` は、覚えている一覧が縮退して
    /// いるだけでも出る（`Kubectl.cacheDirectory` の説明を参照）。だから文言だけでは
    /// 「本当に無い」と決められず、**一覧を捨てて引き直して確かめた**ときだけ
    /// ここが立つ。立っていない失敗を「その種別は無い」の材料に使わない。
    ///
    /// 既定を false にしてあるのは、**確かめていないほうが安全側**だから。
    var discoveryWasFresh: Bool = false

    /// 引き直したあとの一覧に照らした失敗として印を付ける。
    func verifiedAgainstFreshDiscovery() -> CommandError {
        var copy = self
        copy.discoveryWasFresh = true
        return copy
    }

    var errorDescription: String? {
        message.isEmpty
            ? String(localized: "\(command) が終了コード \(exitCode) で失敗しました。")
            : message
    }
}

/// 実行中の子プロセスへの参照。ログの追従を止めるためだけに使う。
final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var finished = false

    func attach(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        // 起動前に terminate() を呼ばれていたら、そのまま殺す。
        if finished {
            if process.isRunning { process.terminate() }
            return
        }
        self.process = process
    }

    func terminate() {
        lock.lock()
        let target = process
        process = nil
        finished = true
        lock.unlock()
        if let target, target.isRunning { target.terminate() }
    }
}

/// `Process` を Swift Concurrency から使うための最小のラッパ。
///
/// 起動から待ち合わせまでを専用のキュー上で完結させ、Sendable でない
/// `Process` をアクター境界に持ち出さない。
enum ProcessRunner {
    private static let queue = DispatchQueue(
        label: "com.piyoraik.KubeDeck.process", attributes: .concurrent)

    /// 読み手・書き手は**専用のスレッドで走らせる。GCD のプールに載せない。**
    ///
    /// `run` は `queue` の上で 1 本スレッドを掴んだまま `group.wait()` で止まり、
    /// **自分が待っている読み手を GCD に投げる**。スレッド上限（64）に当たると
    /// 読み手が起動できず、待ち側は必ず時間切れになる。そうなるとアプリ側は
    /// `timedOut` → `terminate()` → `SIGKILL` → 標準出力空、の経路に入るので、
    /// **クラスタは正常なのに「返ってこない」系の表示が一斉に出る**。
    ///
    /// **別の `DispatchQueue` に分けても直らない。** 上限は root queue 単位で、
    /// どの concurrent queue に投げても同じ予算を食う。一度
    /// `ioQueue` を足して済ませかけたが、実測すると**数字が 1 つも動かなかった**
    /// （同時 80 本で時間切れ 64 件、128 本で 128 件。旧実装と完全に同じ）。
    /// 危うく、`release.sh` の appcast 署名と同じ「**無い保護を有ると書く**」を
    /// やるところだった。
    ///
    /// 専用スレッドは上限の外なので、実測で 80 本・128 本とも**時間切れ 0 件**
    /// （10.29 秒 → 2.22 秒）。本数は走っている kubectl の数で頭打ちになる。
    private static func detach(
        in group: DispatchGroup, _ work: @escaping @Sendable () -> Void
    ) {
        group.enter()
        let thread = Thread {
            work()
            group.leave()
        }
        thread.stackSize = 512 << 10
        thread.start()
    }

    /// `input` を渡すと標準入力に流す（`kubectl replace -f -` 用）。
    ///
    /// **一時ファイルを経由しない。** 送るのは編集した YAML そのもので、
    /// Secret ならその中身が入っている。ディスクに置くと、消し忘れれば残るし、
    /// 消しても消えたことを確かめる手立てが無い。
    ///
    /// **キャンセルされたら子プロセスも殺す。** `Task` を取り消しても
    /// `Process` は勝手には止まらない。以前はここに手当てが無かったので、
    /// コンテキストや種別を続けて切り替えると `loadTask?.cancel()` のあとも
    /// 前の kubectl が最後まで走り、**1 本あたりスレッドを 3 本（待ち 1 +
    /// 読み 2）掴んだまま積み上がっていた**（概要は 4 本同時に投げる）。
    /// 結果は世代番号で捨てられるので、走らせ続ける意味がそもそも無い。
    /// ログの追従が `ProcessHandle` で止められるのと同じ仕組みを、取得系にも通す。
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval? = nil,
        input: Data? = nil
    ) async throws -> CommandResult {
        let handle = ProcessHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let result = try runSynchronously(
                            executable: executable, arguments: arguments,
                            environment: environment, timeout: timeout, input: input,
                            handle: handle)
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // 起動前に来ても取りこぼさない（`ProcessHandle.attach` が
            // 「もう終わっている」ことを覚えていて、その場で殺す）。
            handle.terminate()
        }
    }

    /// **標準入力に書くなら SIGPIPE を無視する。** 相手が読み切る前に終わると
    /// （引数が悪くて kubectl がすぐ落ちたときなど）書き込み側に SIGPIPE が
    /// 飛び、既定の動作は**プロセスの終了**——つまりアプリごと落ちる。無視して
    /// おけば `write` が EPIPE を投げるだけになり、こちらで扱える。
    private static let ignoreBrokenPipe: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()

    /// 呼び出したスレッドを止めて待つ。`LoginShell` が同期の文脈から使う。
    /// **待ち上限を必ず渡すこと。** 相手はユーザの設定ファイルを読むシェルで、
    /// 対話入力を求めて止まることがある。
    static func runBlocking(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> CommandResult {
        try runSynchronously(
            executable: executable, arguments: arguments,
            environment: environment, timeout: timeout)
    }

    /// **鍵を持たせる。** 打ち切りの経路では、読み手がまだ `readToEnd()` で
    /// 止まっているうちに待ち側が結果を組み立てる（2 度目の `group.wait` が
    /// 時間切れになった場合。孫プロセスがパイプを掴んだまま残ると実際に起きる）。
    /// 素の `var data` だと、**参照カウント付きの `Data` を同期なしで読み書き**
    /// することになる。
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()

        func set(_ data: Data) {
            lock.lock()
            defer { lock.unlock() }
            storage = data
        }

        func value() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    /// - Parameter handle: 外から止められるようにするための取っ手。
    ///   渡すと、起動した `Process` をここに預ける（`run` がキャンセル時に使う）。
    private static func runSynchronously(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval? = nil,
        input: Data? = nil,
        handle: ProcessHandle? = nil
    ) throws -> CommandResult {
        _ = ignoreBrokenPipe

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = input.map { _ in Pipe() }
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        try process.run()
        // **起動したらすぐ預ける。** ここより前にキャンセルが来ていた場合、
        // `attach` がその場で殺す（取りこぼしを作らない）。
        handle?.attach(process)

        // stdout と stderr は同時に読む。片方だけ読んでいると、もう片方の
        // パイプバッファが埋まった時点で kubectl が書き込みで止まる。
        let outputBox = DataBox()
        let errorBox = DataBox()
        let group = DispatchGroup()
        detach(in: group) {
            errorBox.set((try? errorPipe.fileHandleForReading.readToEnd()) ?? Data())
        }
        detach(in: group) {
            outputBox.set((try? outputPipe.fileHandleForReading.readToEnd()) ?? Data())
        }
        if let input, let inputPipe {
            // **書き込みも別の実行単位にする。** パイプのバッファ（64KB 程度）
            // より大きい入力を呼び出し側のまま書くと、相手が読み始める前に
            // 埋まってこちらが止まる。**閉じるまでが一組** — 閉じないと
            // kubectl は標準入力の終わりを待ち続ける。
            detach(in: group) {
                try? inputPipe.fileHandleForWriting.write(contentsOf: input)
                try? inputPipe.fileHandleForWriting.close()
            }
        }

        var timedOut = false
        if let timeout {
            if group.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                // 殺せばパイプが閉じ、読み手が EOF で戻る。それを待たずに抜けると
                // 読みかけの Data を掴んだまま結果を組み立てることになる。
                process.terminate()
                if group.wait(timeout: .now() + 2) == .timedOut {
                    // terminate を無視するものは殺すしかない。認証プラグインが
                    // 孫プロセスとしてパイプを掴んだまま残ることがある。
                    kill(process.processIdentifier, SIGKILL)
                    _ = group.wait(timeout: .now() + 2)
                }
            }
        } else {
            group.wait()
        }
        process.waitUntilExit()

        let stderr = String(decoding: errorBox.value(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(
            exitCode: process.terminationStatus, stdout: outputBox.value(), stderr: stderr,
            timedOut: timedOut)
    }

    // MARK: - 逐次読み出し

    private final class LineBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var pending = Data()

        /// 受け取ったチャンクを行に切り出す。改行で終わっていない末尾は次に持ち越す。
        func take(_ chunk: Data) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            pending.append(chunk)
            var lines: [String] = []
            // **再スライスで済ませない。** `pending = pending[i...]` は同じ
            // backing storage の範囲をずらすだけで、消費済みの前半を解放しない。
            // `kubectl logs -f` が流した**全量**を掴み続けることになり、実測
            // （`phys_footprint`）で 50MB 流すと +52.6MB。捨てれば +0.0MB。
            // 表示側が 5,000 行で切っていても、こちらには効かない。
            //
            // **ただし 1 行ごとに捨てない。** `removeSubrange` は残りを詰めるので
            // O(残り) が行数ぶん掛かる。実測で 64KB・547 行の塊が
            // **1.1 秒 → 5.2 秒（113 → 24 MB/s）**に落ちた。改行を先に全部
            // 走査して切り出し、**詰め直しは塊につき 1 回**にすれば、
            // メモリも速度も両立する（実測 1.155 秒 / 108 MB/s）。
            var cursor = pending.startIndex
            while let index = pending[cursor...].firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[cursor..<index], as: UTF8.self))
                cursor = pending.index(after: index)
            }
            if cursor > pending.startIndex {
                pending.removeSubrange(pending.startIndex..<cursor)
            }
            return lines
        }

        func flush() -> String? {
            lock.lock()
            defer { lock.unlock() }
            guard !pending.isEmpty else { return nil }
            let line = String(decoding: pending, as: UTF8.self)
            pending = Data()
            return line
        }
    }

    /// 標準出力を**読めた塊ごと**に流す。`kubectl logs -f` 用。
    /// 返り値のハンドルを `terminate()` すると追従が止まる。
    ///
    /// **1 行ずつ yield しない。** パイプから 1 度に読めたぶんはもともと塊で
    /// 届いており、それをわざわざ 1 行ずつにばらすと、受け手は行の数だけ
    /// 画面を作り直すことになる（毎秒数百行を出す Pod で UI が張り付いた）。
    /// 塊のまま渡せば、受け手は 1 度の更新で済む。**溜め込みではないので、
    /// 静かな Pod でも最後の 1 行が遅れて出ることはない**（読めた時点で流す）。
    static func stream(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) -> (lines: AsyncStream<[String]>, handle: ProcessHandle) {
        let handle = ProcessHandle()
        let stream = AsyncStream<[String]> { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment

            let pipe = Pipe()
            process.standardOutput = pipe
            // stderr も同じ流れに混ぜる。`kubectl logs` の失敗理由が
            // ログ本文と同じ場所に出たほうが追いやすい。
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice

            let buffer = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { fileHandle in
                let chunk = fileHandle.availableData
                guard !chunk.isEmpty else { return }
                let lines = buffer.take(chunk)
                guard !lines.isEmpty else { return }
                continuation.yield(lines)
            }

            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let tail = buffer.flush() { continuation.yield([tail]) }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                handle.terminate()
            }

            do {
                try process.run()
                handle.attach(process)
            } catch {
                // 起動できなかったときは読み手が付かないので、後始末を自分でする。
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.yield(
                    [String(localized: "プロセスを起動できませんでした: \(error.localizedDescription)")])
                continuation.finish()
            }
        }
        return (stream, handle)
    }
}
