import SwiftUI
import AppKit

/// Pod の中に入る。
///
/// **端末はアプリの中に持たない。** `kubectl exec -it` には擬似端末が要り、
/// まともに動かすには VT100 の解釈（カーソル移動・色・画面消去・リサイズ通知）を
/// 抱えることになる。ログを読むのとは桁違いの重さで、**このアプリの持ち場では
/// ない**。同じ判断を JSONPath の絞り込みやラベルセレクタでもしている。
///
/// 代わりに**ターミナルに渡す。** 使う人はすでに端末を持っていて、そこでは
/// 補完も色も履歴もコピーも動く。ここが受け持つのは「どの Pod のどのコンテナに、
/// 何で入るか」を決めて渡すところまで。
///
/// **AppleScript で Terminal を操らない。** Apple Events の許可が要り、
/// 断られると理由の分かりにくい失敗になる。実行できる `.command` を書いて
/// `open` すれば、許可は要らない。
struct ExecSheet: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let pod: K8sObject

    @State private var container = ""
    @State private var command = ExecSheet.defaultCommand
    @State private var failure: String?

    /// bash があれば bash、無ければ sh。**どちらかに決め打ちしない** ——
    /// 軽量なイメージには bash が無く、逆に bash 前提の人は sh だと不便。
    static let defaultCommand =
        "sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'"

    private var containers: [(name: String, isInit: Bool)] {
        let normal = (pod.spec?["containers"]?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }.map { (name: $0, isInit: false) }
        // 初期化コンテナは終わっていれば入れない。並べておいて、選べば
        // kubectl が「そんなコンテナは動いていない」と言う（こちらで断定しない）。
        let initial = (pod.spec?["initContainers"]?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }.map { (name: $0, isInit: true) }
        return normal + initial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("ターミナルで中に入る (kubectl exec)")
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(pod.name)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let namespace = pod.namespace {
                        Text(namespace).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }

            if containers.count > 1 {
                Picker("コンテナ", selection: $container) {
                    ForEach(containers, id: \.name) { entry in
                        Text(entry.isInit ? "\(entry.name)（初期化）" : entry.name)
                            .tag(entry.name)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                TextField("コマンド", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    // YAML の欄と同じ理由。勝手に置き換えられると別のコマンドになる。
                    .autocorrectionDisabled()
                Text("そのままなら bash（無ければ sh）で入ります。"
                     + "`psql` や `sh -c 'ls /etc'` のように書き換えても構いません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // **ここで何が起きるかを言う。** 別のアプリが開くので、黙っていると
            // 「押したのに何も起きない」と読める（背面で開くこともある）。
            Label(
                "ターミナルが開き、この Pod に繋がります。閉じれば接続も終わります。",
                systemImage: "terminal")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let failure {
                Label(failure, systemImage: StatusLevel.critical.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .critical))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                // 端末を自分で開きたい人のために、そのまま貼れる形も渡す。
                Button("コマンドをコピー") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(shellCommand(), forType: .string)
                }
                Spacer()
                Button("やめる", role: .cancel) { dismiss() }
                Button("ターミナルで開く") { open() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            if container.isEmpty { container = containers.first?.name ?? "" }
        }
    }

    /// ターミナルに渡す 1 行。
    ///
    /// **アプリが使っているのと同じ kubectl を指す。** ここだけ別の実体を
    /// 使うと、アプリでは通るのにターミナルでは通らない（あるいはその逆）が
    /// 起きる。`--context` と `--cache-dir` も揃える。
    private func shellCommand() -> String {
        let kubectl = store.kubectlPath ?? "kubectl"
        var parts = [
            quoted(kubectl),
            "--cache-dir=\(quoted(Kubectl.cacheDirectory))",
            "--context", quoted(store.currentContext),
            "exec", "-it", quoted(pod.name),
        ]
        if let namespace = pod.namespace, !namespace.isEmpty {
            parts += ["-n", quoted(namespace)]
        }
        if !container.isEmpty, containers.count > 1 {
            parts += ["-c", quoted(container)]
        }
        parts += ["--", command]
        return parts.joined(separator: " ")
    }

    private func quoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func open() {
        do {
            let url = try ExecScript.write(
                command: shellCommand(),
                title: "\(pod.namespace ?? "")/\(pod.name)")
            NSWorkspace.shared.open(url)
            dismiss()
        } catch {
            failure = "ターミナルに渡せませんでした: \(error.localizedDescription)"
        }
    }
}

/// ターミナルに渡す使い捨ての実行ファイル。
enum ExecScript {
    /// **アプリのキャッシュに置く。** `/tmp` は他人も読める。
    private static var directory: URL {
        URL(fileURLWithPath: Kubectl.cacheDirectory, isDirectory: true)
            .deletingLastPathComponent()
            .appendingPathComponent("exec", isDirectory: true)
    }

    static func write(command: String, title: String) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        purge()

        let url = directory.appendingPathComponent("\(UUID().uuidString).command")
        // `exec` で置き換えるので、抜けた時点でシェルごと終わる（残らない）。
        let script = """
            #!/bin/sh
            # KubeDeck が作った使い捨ての起動用ファイルです。消して構いません。
            printf '\\033]0;%s\\007' \(shellQuoted(title))
            exec \(command)

            """
        try script.write(to: url, atomically: true, encoding: .utf8)
        // **他人に読ませない。** 中身にはクラスタ名と Pod 名が入る。
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// **置きっぱなしにしない。** 開くたびに 1 つ増えるので、古いものを捨てる。
    /// 消す基準は時間（開いたばかりのものを消すと、ターミナルが読む前に消える）。
    private static func purge(olderThan seconds: TimeInterval = 3_600) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let limit = Date().addingTimeInterval(-seconds)
        for url in contents {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            if let modified, modified < limit {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
