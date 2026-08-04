import Foundation

/// ログを開くための指定。
///
/// `K8sObject` をそのまま渡さない。ウインドウは一覧より長く生きるうえ、
/// `WindowGroup(for:)` に載せる値は Codable である必要がある。
struct PodLogRequest: Codable, Hashable, Identifiable {
    /// 何を指して開いたか。
    ///
    /// **Job をここで Pod に潰さない。** Job の Pod は再試行や `completions` で
    /// 複数になり、完了したあとに消えることもある。潰してしまうと「どの試行の
    /// ログを見ているのか」も「そもそも Pod が残っているのか」も画面で言えなく
    /// なるので、Job のまま持ち回って開いたあとに解決する（`LogContent`）。
    enum Source: Codable, Hashable {
        case pod
        /// Job。掴んでいる Pod は Job 自身のセレクタで引く
        /// （`kubectl logs job/...` が中でやっているのと同じ引き方）。
        case job(selector: [String: String])
    }

    var namespace: String
    /// `.pod` なら Pod 名、`.job` なら Job 名。
    var name: String
    /// コンテナ名。Job のときは Pod テンプレートのもの（どの Pod でも同じ）。
    var containers: [String]
    var source: Source

    /// **種別まで入れる。** 同じ名前の Job と Pod が同居しうるので、
    /// 名前だけを鍵にすると別物が同じ取得として扱われる。
    var id: String {
        switch source {
        case .pod: return "pod/\(namespace)/\(name)"
        case .job: return "job/\(namespace)/\(name)"
        }
    }

    var isJob: Bool {
        if case .job = source { return true }
        return false
    }

    init(namespace: String, name: String, containers: [String], source: Source = .pod) {
        self.namespace = namespace
        self.name = name
        self.containers = containers
        self.source = source
    }

    init(pod: K8sObject) {
        self.namespace = pod.namespace ?? ""
        self.name = pod.name
        self.containers = (pod.spec?["containers"]?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }
        self.source = .pod
    }

    init(job: K8sObject) {
        self.namespace = job.namespace ?? ""
        self.name = job.name
        self.containers = (job.spec?.path("template.spec.containers")?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }

        // **セレクタは Job 自身の `spec.selector` を使う。** `job-name=` のような
        // ラベルは版で変わる（1.27 で `batch.kubernetes.io/job-name` が足され、
        // 古い `job-name` はいずれ消える）。`spec.selector` は指定しなくても
        // API サーバが必ず埋めるうえ、Job コントローラが自分の Pod を数えるのに
        // 使っているものそのものなので、ここが食い違うことはない。
        var selector = job.spec?["selector"]?["matchLabels"]?.stringDictionary ?? [:]
        if selector.isEmpty {
            // 手書きの Job で `matchExpressions` しか無いときの最後の頼み。
            // 引けなければ「Pod が見つからない」として画面に出る（黙って
            // 別の Job の Pod を掴むことはない）。
            selector = ["job-name": job.name]
        }
        self.source = .job(selector: selector)
    }

    /// ログを開ける種別なら指定を作る。開けないものには nil。
    ///
    /// **判定を 1 か所にする。** 一覧のメニューと詳細パネルで別々に書くと、
    /// 片方からしか開けない種別ができる（実際、以前は Job がどちらからも
    /// 開けなかった）。
    init?(object: K8sObject) {
        switch object.kind {
        case .pod: self.init(pod: object)
        case .job: self.init(job: object)
        default: return nil
        }
    }
}
