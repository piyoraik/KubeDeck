import Foundation

struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: Data
    let stderr: String

    var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
}

struct CommandError: LocalizedError, Sendable {
    let command: String
    let exitCode: Int32
    let message: String

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

    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let result = try runSynchronously(
                        executable: executable, arguments: arguments, environment: environment)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }

    private static func runSynchronously(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        try process.run()

        // stdout と stderr は同時に読む。片方だけ読んでいると、もう片方の
        // パイプバッファが埋まった時点で kubectl が書き込みで止まる。
        let errorBox = DataBox()
        let group = DispatchGroup()
        queue.async(group: group) {
            errorBox.data = (try? errorPipe.fileHandleForReading.readToEnd()) ?? Data()
        }
        let outputData = (try? outputPipe.fileHandleForReading.readToEnd()) ?? Data()
        group.wait()
        process.waitUntilExit()

        let stderr = String(decoding: errorBox.data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CommandResult(
            exitCode: process.terminationStatus, stdout: outputData, stderr: stderr)
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

    /// 標準出力を 1 行ずつ流す。`kubectl logs -f` 用。
    /// 返り値のハンドルを `terminate()` すると追従が止まる。
    static func stream(
        executable: String,
        arguments: [String],
        environment: [String: String]
    ) -> (lines: AsyncStream<String>, handle: ProcessHandle) {
        let handle = ProcessHandle()
        let stream = AsyncStream<String> { continuation in
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
                for line in buffer.take(chunk) {
                    continuation.yield(line)
                }
            }

            process.terminationHandler = { _ in
                pipe.fileHandleForReading.readabilityHandler = nil
                if let tail = buffer.flush() { continuation.yield(tail) }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                handle.terminate()
            }

            do {
                try process.run()
                handle.attach(process)
            } catch {
                continuation.yield("プロセスを起動できませんでした: \(error.localizedDescription)")
                continuation.finish()
            }
        }
        return (stream, handle)
    }
}
