import Foundation

/// コンテナ 1 つぶんの資源の設定。
struct ContainerResources: Identifiable, Hashable, Sendable {
    let name: String
    /// 初期化コンテナか。**同じ扱いにしない** — patch を当てる先の名前が違う。
    let isInit: Bool
    /// 原文のまま持つ（`100m` / `128Mi`）。**数値に直さない** —
    /// 直すと書き戻すときに `0.1` のような別の書き方になり、
    /// 変えていないはずの行が変わったように見える。
    let cpuRequest: String?
    let memoryRequest: String?
    let cpuLimit: String?
    let memoryLimit: String?

    var id: String { (isInit ? "init/" : "") + name }
}

/// requests / limits だけを書き換える patch を組み立てる。
///
/// **`kubectl set resources` を使わない。** 実測で、あれは**外せない** ——
/// `--limits=cpu=0` は「0 という上限」を書き込むだけで、`resources` から
/// キーが消えない。このアプリは「0」と「未設定」を別のものとして扱っている
/// （分母が無ければ棒を描かない、`上限 未設定（ノードの空きまで使えます）`）
/// のに、書き戻す側でそれを混ぜたら意味が無い。
///
/// strategic merge patch なら `null` でキーが消え、**コンテナは名前で
/// 合わせられる**（添字を数えなくてよい。実測で確認）。
enum ResourcePatch {

    /// Pod テンプレートの場所。**種別ごとに違う。**
    ///
    /// **Job と ReplicaSet と Pod は返さない。** Job の `spec.template` は
    /// immutable（実測。返ってくるのは spec 全体を貼り付けた長大なエラー）、
    /// ReplicaSet は直しても Deployment 側の世代が優先されるので意味が無く、
    /// Pod の resources は作り直せば消える。**押せば失敗すると分かっている
    /// ものを出さない。**
    static func templatePath(for kind: ResourceKind?) -> [String]? {
        switch kind {
        case .deployment, .statefulSet, .daemonSet:
            return ["spec", "template", "spec"]
        case .cronJob:
            return ["spec", "jobTemplate", "spec", "template", "spec"]
        default:
            return nil
        }
    }

    static func supports(_ kind: ResourceKind?) -> Bool { templatePath(for: kind) != nil }

    /// いま設定されている値。**初期化コンテナも出す**（設定を取りに行くのが
    /// init の仕事、という作りはふつうにあり、そこにも上限は要る）。
    static func containers(of object: K8sObject) -> [ContainerResources] {
        guard let path = templatePath(for: object.kind),
              let template = object.raw.path(path.joined(separator: "."))
        else { return [] }

        let normal = (template["containers"]?.arrayValue ?? []).map {
            resources(from: $0, isInit: false)
        }
        let initial = (template["initContainers"]?.arrayValue ?? []).map {
            resources(from: $0, isInit: true)
        }
        return normal + initial
    }

    private static func resources(from container: JSONValue, isInit: Bool) -> ContainerResources {
        // **空文字を「設定されている」にしない。** `displayText` は読めない値でも
        // 空文字を返すので、そのまま入れると「未設定」と区別が付かなくなる。
        func value(_ path: String) -> String? {
            let text = container.path("resources.\(path)")?.displayText ?? ""
            return text.isEmpty ? nil : text
        }
        return ContainerResources(
            name: container["name"]?.stringValue ?? "",
            isInit: isInit,
            cpuRequest: value("requests.cpu"),
            memoryRequest: value("requests.memory"),
            cpuLimit: value("limits.cpu"),
            memoryLimit: value("limits.memory"))
    }

    /// 変更 1 つ。**「未設定にする」を「空文字にする」と混ぜない。**
    struct Change: Equatable {
        enum Field: String {
            case cpuRequest
            case memoryRequest
            case cpuLimit
            case memoryLimit

            var label: String {
                switch self {
                case .cpuRequest: return "CPU 要求"
                case .memoryRequest: return "メモリ 要求"
                case .cpuLimit: return "CPU 上限"
                case .memoryLimit: return "メモリ 上限"
                }
            }

            var section: String { self == .cpuRequest || self == .memoryRequest ? "requests" : "limits" }
            var key: String { self == .cpuRequest || self == .cpuLimit ? "cpu" : "memory" }
        }

        let field: Field
        let before: String?
        /// nil は「外す」。
        let after: String?

        /// 画面に出す一行。**何がどうなるかを書く**（「変更あり」では読めない）。
        var summary: String {
            switch (before, after) {
            case (let before?, let after?): return "\(field.label): \(before) → \(after)"
            case (nil, let after?): return "\(field.label): 未設定 → \(after)"
            case (let before?, nil): return "\(field.label): \(before) → 未設定にする"
            case (nil, nil): return ""
            }
        }
    }

    /// 入力された値と、いまの値の差。
    ///
    /// **変えていないものを送らない。** 送っても結果は同じだが、確認の画面に
    /// 出す変更の一覧が「触ってもいない行」で埋まる。空白は前後を落として見る
    /// （`100m ` と `100m` を別の値にしない）。
    static func changes(
        from current: ContainerResources,
        cpuRequest: String, memoryRequest: String, cpuLimit: String, memoryLimit: String
    ) -> [Change] {
        let pairs: [(Change.Field, String?, String)] = [
            (.cpuRequest, current.cpuRequest, cpuRequest),
            (.memoryRequest, current.memoryRequest, memoryRequest),
            (.cpuLimit, current.cpuLimit, cpuLimit),
            (.memoryLimit, current.memoryLimit, memoryLimit),
        ]
        return pairs.compactMap { field, before, raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let after = trimmed.isEmpty ? nil : trimmed
            guard after != before else { return nil }
            return Change(field: field, before: before, after: after)
        }
    }

    /// `kubectl patch -p` に渡す strategic merge patch。
    ///
    /// **キーの順を固定する**（`sortedKeys`）。固定しないと、同じ変更でも
    /// 呼ぶたびに文字列が変わってテストで押さえられない。
    static func patch(
        kind: ResourceKind?, container: ContainerResources, changes: [Change]
    ) -> String? {
        guard !changes.isEmpty, let path = templatePath(for: kind) else { return nil }

        var resources: [String: Any] = [:]
        for change in changes {
            var section = resources[change.field.section] as? [String: Any] ?? [:]
            // **外すときは `null`。** 空文字を送ると「空という値」になる。
            section[change.field.key] = change.after ?? NSNull()
            resources[change.field.section] = section
        }

        let entry: [String: Any] = ["name": container.name, "resources": resources]
        var node: Any = [container.isInit ? "initContainers" : "containers": [entry]]
        for key in path.reversed() {
            node = [key: node]
        }

        guard let data = try? JSONSerialization.data(
            withJSONObject: node, options: [.sortedKeys])
        else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
