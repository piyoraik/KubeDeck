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

    var errorDescription: String? {
        message.isEmpty
            ? "\(command) が終了コード \(exitCode) で失敗しました。"
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

    private final class DataBox: @unchecked Sendable {
        var data = Data()
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
        queue.async(group: group) {
            errorBox.data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        queue.async(group: group) {
            outputBox.data = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        if let input, let inputPipe {
            // **書き込みも別の実行単位にする。** パイプのバッファ（64KB 程度）
            // より大きい入力を呼び出し側のまま書くと、相手が読み始める前に
            // 埋まってこちらが止まる。**閉じるまでが一組** — 閉じないと
            // kubectl は標準入力の終わりを待ち続ける。
            queue.async(group: group) {
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

        let stderr = String(decoding: errorBox.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(
            exitCode: process.terminationStatus, stdout: outputBox.data, stderr: stderr,
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
            while let index = pending.firstIndex(of: 0x0A) {
                let line = pending[pending.startIndex..<index]
                lines.append(String(decoding: line, as: UTF8.self))
                pending = pending[pending.index(after: index)...]
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
                    ["プロセスを起動できませんでした: \(error.localizedDescription)"])
                continuation.finish()
            }
        }
        return (stream, handle)
    }
}
