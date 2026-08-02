import Foundation

/// ログインシェルの環境を写し取る。
///
/// Finder から起動したアプリの `PATH` は `/usr/bin:/bin:/usr/sbin:/sbin` しかない。
/// kubectl 本体だけなら決まった場所を順に見れば足りるが、kubeconfig の exec 認証
/// プラグイン（GKE の `gke-gcloud-auth-plugin`、EKS の `aws`）はそうはいかない。
/// gcloud SDK は tarball を好きな場所へ展開して `path.zsh.inc` をシェルの設定から
/// 読ませる手順が公式に案内されており、置き場所がユーザごとに違う。
/// **候補の一覧を持つやり方では追いつかない。**
///
/// **`-l` だけでは足りない。** その `path.zsh.inc` を読む行は `.zshrc` に書かれる
/// （`.zprofile` ではない）ので、非対話のログインシェルには現れない。手元で確かめると
/// `-lc` では `.zshrc` で足した場所が丸ごと落ちた。対話ログインシェルで起こすこと。
///
/// **フラグはまとめて渡さない。** `-ilc` は zsh / bash では通るが fish では通らない。
/// `-i` `-l` `-c` と分けて渡せば 3 つとも同じ意味になる。
enum LoginShell {
    /// 設定ファイルが対話入力で止まったときに巻き添えを食わないよう、待ち上限を付ける。
    private static let timeout: TimeInterval = 5

    /// 目印。対話シェルは起動時に何か書き出すことがある（p10k の instant prompt など）
    /// ので、ここから後ろだけを環境変数として読む。
    private static let marker = "__KUBEDECK_ENV__"

    /// 呼ぶたびにシェルを起こす。rc を全部読むので 0.5〜1 秒かかる。
    /// **繰り返し呼ばない。** 結果は `Kubectl` が 1 度だけ取って持ち回る。
    static func environment() -> [String: String] {
        guard let shell = shell() else { return [:] }
        let command = "printf '%s' '\(marker)'; /usr/bin/env -0"
        guard let result = try? ProcessRunner.runBlocking(
            executable: shell,
            arguments: ["-i", "-l", "-c", command],
            environment: seed(),
            timeout: timeout),
            result.exitCode == 0
        else { return [:] }
        return parse(result.stdout)
    }

    private static func shell() -> String? {
        let path = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// シェルに渡す環境。アプリ自身の環境をそのまま渡さず、素性の分かる値だけ置く。
    /// `TERM=dumb` は、プロンプトの描画やページャが立ち上がるのを避けるため。
    private static func seed() -> [String: String] {
        var variables = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
        ]
        for key in ["USER", "LOGNAME", "SHELL", "LANG", "TMPDIR"] {
            if let value = ProcessInfo.processInfo.environment[key] { variables[key] = value }
        }
        return variables
    }

    /// `env -0` の出力（`KEY=VALUE` を NUL 区切りで並べたもの）を読む。
    /// 行区切りにしないのは、値に改行が入っていても壊れないようにするため。
    private static func parse(_ data: Data) -> [String: String] {
        guard let markerData = marker.data(using: .utf8),
              let range = data.range(of: markerData)
        else { return [:] }

        var variables: [String: String] = [:]
        for entry in data[range.upperBound...].split(separator: 0x00) {
            let text = String(decoding: entry, as: UTF8.self)
            guard let separator = text.firstIndex(of: "=") else { continue }
            variables[String(text[text.startIndex..<separator])] =
                String(text[text.index(after: separator)...])
        }
        return variables
    }
}
