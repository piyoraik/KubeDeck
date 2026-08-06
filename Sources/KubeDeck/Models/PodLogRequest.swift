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
        /// セレクタが掴む Pod を**まとめて**読む（Deployment / Service など）。
        ///
        /// **Job と同じ扱いにしない。** Job は「どの試行のログか」に意味が
        /// あるので Pod を選ばせる（`LogContent` の Picker）。こちらで探して
        /// いるのは**どのレプリカで起きたか分からない事象**なので、1 つ選ばせた
        /// 時点で用途を外す。混ぜて読むのが答え。
        ///
        /// `kind` は表示と `id` のために持つ。同じ名前の Deployment と Service は
        /// ふつうに同居するので、名前だけを鍵にすると別物が同じ取得になる。
        case group(kind: String, selector: [String: String])
    }

    var namespace: String
    /// `.pod` なら Pod 名、それ以外は掴んでいる側（Job / Deployment / Service …）の名前。
    var name: String
    /// コンテナ名。Pod テンプレートのもの（どの Pod でも同じ）。
    /// Service にはテンプレートが無いので空になる（そのときは全コンテナを読む）。
    var containers: [String]
    var source: Source

    /// **種別まで入れる。** 同じ名前の Job と Pod が同居しうるので、
    /// 名前だけを鍵にすると別物が同じ取得として扱われる。
    var id: String {
        switch source {
        case .pod: return "pod/\(namespace)/\(name)"
        case .job: return "job/\(namespace)/\(name)"
        case .group(let kind, _): return "\(kind.lowercased())/\(namespace)/\(name)"
        }
    }

    var isJob: Bool {
        if case .job = source { return true }
        return false
    }

    /// セレクタで複数の Pod をまとめて読むか。
    var isGroup: Bool {
        if case .group = source { return true }
        return false
    }

    /// 見出しに添える種別名。Pod のときは名前そのものが Pod なので不要。
    var kindLabel: String? {
        switch source {
        case .pod: return nil
        case .job: return "Job"
        case .group(let kind, _): return kind
        }
    }

    /// Pod を掴むセレクタ。Pod を直に指しているときは空。
    var selector: [String: String] {
        switch source {
        case .pod: return [:]
        case .job(let selector): return selector
        case .group(_, let selector): return selector
        }
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

    /// セレクタで掴む Pod をまとめて読む指定。掴めない種別には nil。
    ///
    /// **空のセレクタを通さない。** Service の `spec.selector` が空なのは
    /// 「すべてに一致」ではなく「まだ何も選んでいない」（`WorkloadRelations` と
    /// 同じ規則）。通すと Namespace の Pod を全部読むことになる。
    /// ラベルの無い外部 Service（`ExternalName` や手書き Endpoints）が
    /// まさにこれで、掴んでいる Pod は 1 つも無い。
    ///
    /// **CronJob は入れない。** セレクタを持たず Job を経由する 2 段になるので、
    /// ここで解けない。Job は Job で `.job` の経路がある。
    init?(group object: K8sObject) {
        let labels: [String: String]
        let containers: [String]

        switch object.kind {
        case .deployment, .statefulSet, .daemonSet, .replicaSet:
            // ワークロードは `matchLabels`。**世代で絞らない** —— ロールアウト中は
            // 新旧の Pod が並ぶが、そのときこそ両方のログが見たい
            // （ReplicaSet を起点にすれば世代 1 つに絞れる）。
            labels = object.spec?.path("selector.matchLabels")?.stringDictionary ?? [:]
            containers = (object.spec?.path("template.spec.containers")?.arrayValue ?? [])
                .compactMap { $0["name"]?.stringValue }
        case .service:
            // Service は `matchLabels` を挟まない素のラベル。
            labels = object.spec?["selector"]?.stringDictionary ?? [:]
            // テンプレートが無いので、どのコンテナが並ぶかは開くまで分からない。
            // 既定で全コンテナを読む。
            containers = []
        default:
            return nil
        }

        guard !labels.isEmpty else { return nil }

        self.namespace = object.namespace ?? ""
        self.name = object.name
        self.containers = containers
        self.source = .group(kind: object.rawKind, selector: labels)
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

    /// 開けるならどの形でも開く。**追従（`followLogsToSelection`）専用。**
    ///
    /// 操作の出し分けでは使わない —— あちらは「1 つを読む」と「まとめて読む」を
    /// 別のボタンとして出すので、どちらになるか分からない初期化子を通すと、
    /// 押した先が種別によって変わる。
    init?(opening object: K8sObject) {
        if let request = PodLogRequest(object: object) {
            self = request
        } else if let request = PodLogRequest(group: object) {
            self = request
        } else {
            return nil
        }
    }
}
