import Foundation

/// 設定の 1 行。
struct SettingRow: Identifiable, Sendable {
    let label: String
    let value: String
    /// 値が未設定のときに立てる。表示側が薄く出す。
    var isUnset = false
    var level: StatusLevel?

    var id: String { label }

    /// 未設定を「—」で表す。空文字をそのまま出すと、値が空なのか
    /// 項目が無いのか区別が付かない。
    init(_ label: String, _ value: String?, level: StatusLevel? = nil) {
        self.label = label
        let text = value?.trimmingCharacters(in: .whitespaces) ?? ""
        self.value = text.isEmpty ? "未設定" : text
        self.isUnset = text.isEmpty
        self.level = text.isEmpty ? nil : level
    }
}

/// 設定のひとかたまり。
struct SettingGroup: Identifiable, Sendable {
    let title: String
    let rows: [SettingRow]
    /// コンテナのように、同じ形が複数並ぶものの副題。
    var subtitle: String?

    var id: String { title + (subtitle ?? "") }
}

/// オブジェクトから「人が読む設定」を組み立てる。
///
/// **API のフィールド名をそのまま並べない。** `preferredDuringScheduling...` の
/// ような語は読むためのものではない。種別ごとに見るべき項目を選び、日本語の
/// 見出しと整形した値にする。原文が要るときは YAML タブがある。
///
/// スキーマの分からない CRD だけは選びようがないので、木のまま出す。
enum SettingsDigest {
    static func groups(for object: K8sObject) -> [SettingGroup] {
        switch object.kind {
        case .pod: return podGroups(object)
        case .deployment, .statefulSet, .daemonSet, .replicaSet: return workloadGroups(object)
        case .job: return jobGroups(object)
        case .cronJob: return cronJobGroups(object)
        case .horizontalPodAutoscaler: return autoscalerGroups(object)
        case .serviceAccount: return serviceAccountGroups(object)
        case .role, .clusterRole: return roleGroups(object)
        case .roleBinding, .clusterRoleBinding: return bindingGroups(object)
        case .service: return serviceGroups(object)
        case .ingress: return ingressGroups(object)
        case .networkPolicy: return networkPolicyGroups(object)
        case .configMap, .secret: return dataGroups(object)
        case .persistentVolumeClaim: return claimGroups(object)
        case .persistentVolume: return volumeGroups(object)
        case .node: return nodeGroups(object)
        case .namespace: return namespaceGroups(object)
        // **選べる項目が決まっていないものは、木に落とす。** 種別を足すたびに
        // 空の設定タブが増えるより、`SpecOutline` で spec がそのまま見えるほうが
        // まだ役に立つ（CRD と同じ扱い）。
        case .event, .none: return []
        default: return []
        }
    }

    // MARK: - Pod

    private static func podGroups(_ pod: K8sObject) -> [SettingGroup] {
        var groups: [SettingGroup] = []
        let spec = pod.spec

        groups.append(
            SettingGroup(
                title: "配置",
                rows: [
                    SettingRow("ノード", spec?["nodeName"]?.stringValue),
                    SettingRow("ノードの条件", pairs(spec?["nodeSelector"])),
                    SettingRow("優先度クラス", spec?["priorityClassName"]?.stringValue),
                    SettingRow("再起動の方針", restartPolicy(spec?["restartPolicy"]?.stringValue)),
                    SettingRow("許容する汚れ", tolerationSummary(spec)),
                    SettingRow("配置の希望", affinitySummary(spec)),
                ]))

        groups.append(
            SettingGroup(
                title: "ネットワーク",
                rows: [
                    SettingRow("Pod IP", pod.status?["podIP"]?.stringValue),
                    SettingRow("ホストのネットワークを使う", yesNo(spec?["hostNetwork"]?.boolValue)),
                    SettingRow("DNS の方針", spec?["dnsPolicy"]?.stringValue),
                    SettingRow("ホスト名", spec?["hostname"]?.stringValue),
                ]))

        let security = spec?["securityContext"]
        groups.append(
            SettingGroup(
                title: "権限",
                rows: [
                    SettingRow("ServiceAccount", spec?["serviceAccountName"]?.stringValue),
                    SettingRow(
                        "トークンを自動で渡す",
                        yesNo(spec?["automountServiceAccountToken"]?.boolValue ?? true)),
                    SettingRow("実行ユーザー", security?["runAsUser"]?.intValue.map(String.init)),
                    SettingRow("root を禁止", yesNo(security?["runAsNonRoot"]?.boolValue)),
                    SettingRow("fsGroup", security?["fsGroup"]?.intValue.map(String.init)),
                ]))

        // **足し算を読み手にさせない。** スケジューラが見るのも、上限に当たるかを
        // 決めるのも Pod 単位の合計で、コンテナごとの値だけを並べると、複数
        // コンテナの Pod では自分で足すことになる。
        // 初期化コンテナは同時に動かないので合計に入れない（`containerResourceTotal`
        // と同じ扱い。ここでずれると 2 か所で違う数字が出る）。
        //
        // **先頭に置く。** いちばん探される項目で、下に置くと配置や権限を
        // かき分けることになる。
        groups.insert(resourceGroup(pod), at: 0)

        for container in spec?["containers"]?.arrayValue ?? [] {
            groups.append(containerGroup(container, status: pod.status))
        }
        for container in spec?["initContainers"]?.arrayValue ?? [] {
            var group = containerGroup(container, status: pod.status)
            group = SettingGroup(
                title: "初期化コンテナ", rows: group.rows, subtitle: group.subtitle)
            groups.append(group)
        }

        let volumes = spec?["volumes"]?.arrayValue ?? []
        if !volumes.isEmpty {
            groups.append(
                SettingGroup(
                    title: "ボリューム",
                    rows: volumes.map { volume in
                        SettingRow(
                            volume["name"]?.stringValue ?? "?", volumeKind(volume))
                    }))
        }

        return groups
    }

    /// Pod 全体の要求と上限。
    ///
    /// **未設定を空欄にしない。** requests が無ければスケジューラは置き場所を
    /// 決める根拠を持たず、limits が無ければノードの空きまで伸びられる。
    /// どちらも「設定されているが 0」とは意味が違うので、そう書く。
    private static func resourceGroup(_ pod: K8sObject) -> SettingGroup {
        let requests = pod.containerResourceTotal("requests")
        let limits = pod.containerResourceTotal("limits")

        func cpu(_ value: Double) -> String? {
            value > 0 ? Quantity.formatCPU(cores: value) : nil
        }
        func memory(_ value: Double) -> String? {
            value > 0 ? Quantity.formatMemory(bytes: value) : nil
        }

        var subtitle: String?
        if requests.cpuCores == 0 && requests.memoryBytes == 0 {
            subtitle = "requests が未設定です"
        } else if limits.cpuCores == 0 && limits.memoryBytes == 0 {
            subtitle = "limits が未設定です"
        }

        return SettingGroup(
            title: "資源（Pod 合計）",
            rows: [
                SettingRow("CPU 要求", cpu(requests.cpuCores)),
                SettingRow("CPU 上限", cpu(limits.cpuCores)),
                SettingRow("メモリ要求", memory(requests.memoryBytes)),
                SettingRow("メモリ上限", memory(limits.memoryBytes)),
            ],
            subtitle: subtitle)
    }

    private static func containerGroup(_ container: JSONValue, status: JSONValue?) -> SettingGroup {
        let name = container["name"]?.stringValue ?? "?"
        let requests = container.path("resources.requests")
        let limits = container.path("resources.limits")

        var rows: [SettingRow] = [
            SettingRow("イメージ", container["image"]?.stringValue),
            SettingRow("取得の方針", container["imagePullPolicy"]?.stringValue),
            SettingRow("コマンド", joined(container["command"])),
            SettingRow("引数", joined(container["args"])),
            SettingRow("ポート", portList(container["ports"])),
            SettingRow("CPU 要求", requests?["cpu"]?.displayText),
            SettingRow("CPU 上限", limits?["cpu"]?.displayText),
            SettingRow("メモリ要求", requests?["memory"]?.displayText),
            SettingRow("メモリ上限", limits?["memory"]?.displayText),
        ]

        let envCount = (container["env"]?.arrayValue.count ?? 0)
            + (container["envFrom"]?.arrayValue.count ?? 0)
        rows.append(SettingRow("環境変数", envCount > 0 ? "\(envCount) 件" : nil))

        let mounts = container["volumeMounts"]?.arrayValue ?? []
        rows.append(
            SettingRow(
                "マウント",
                mounts.isEmpty
                    ? nil
                    : mounts.compactMap { $0["mountPath"]?.stringValue }.joined(separator: ", ")))

        for (key, label) in [
            ("livenessProbe", "生存確認"), ("readinessProbe", "受付確認"),
            ("startupProbe", "起動確認"),
        ] {
            rows.append(SettingRow(label, probeSummary(container[key])))
        }

        // 実行中の状態も同じ表に混ぜる。設定と実際を行き来しなくて済む。
        if let containerStatus = (status?["containerStatuses"]?.arrayValue ?? [])
            .first(where: { $0["name"]?.stringValue == name })
        {
            let restarts = containerStatus["restartCount"]?.intValue ?? 0
            rows.append(
                SettingRow(
                    "再起動", "\(restarts) 回",
                    level: restarts == 0 ? nil : (restarts >= 5 ? .critical : .warning)))
        }

        return SettingGroup(title: "コンテナ", rows: rows, subtitle: name)
    }

    // MARK: - ワークロード

    private static func workloadGroups(_ object: K8sObject) -> [SettingGroup] {
        let spec = object.spec
        var groups: [SettingGroup] = []

        var rows: [SettingRow] = [
            SettingRow("希望するレプリカ数", spec?["replicas"]?.intValue.map(String.init)),
            SettingRow("対象の条件", pairs(spec?.path("selector.matchLabels"))),
        ]
        if let strategy = spec?["strategy"] ?? spec?["updateStrategy"] {
            rows.append(SettingRow("更新方式", strategy["type"]?.stringValue))
            let rolling = strategy["rollingUpdate"]
            rows.append(SettingRow("同時に増やせる数", rolling?["maxSurge"]?.displayText))
            rows.append(SettingRow("同時に落とせる数", rolling?["maxUnavailable"]?.displayText))
        }
        rows.append(
            SettingRow(
                "準備完了とみなす秒数", spec?["minReadySeconds"]?.intValue.map { "\($0) 秒" }))
        rows.append(
            SettingRow("残す履歴の数", spec?["revisionHistoryLimit"]?.intValue.map(String.init)))
        groups.append(SettingGroup(title: "配備", rows: rows))

        for container in spec?.path("template.spec.containers")?.arrayValue ?? [] {
            groups.append(containerGroup(container, status: nil))
        }
        return groups
    }

    private static func jobGroups(_ job: K8sObject) -> [SettingGroup] {
        let spec = job.spec
        var groups = [
            SettingGroup(
                title: "実行",
                rows: [
                    SettingRow("完了に必要な数", spec?["completions"]?.intValue.map(String.init)),
                    SettingRow("同時に走らせる数", spec?["parallelism"]?.intValue.map(String.init)),
                    SettingRow("再試行の上限", spec?["backoffLimit"]?.intValue.map(String.init)),
                    SettingRow(
                        "打ち切りまでの秒数",
                        spec?["activeDeadlineSeconds"]?.intValue.map { "\($0) 秒" }),
                    SettingRow(
                        "完了後に消すまで",
                        spec?["ttlSecondsAfterFinished"]?.intValue.map { "\($0) 秒" }),
                ])
        ]
        for container in spec?.path("template.spec.containers")?.arrayValue ?? [] {
            groups.append(containerGroup(container, status: nil))
        }
        return groups
    }

    private static func cronJobGroups(_ cronJob: K8sObject) -> [SettingGroup] {
        let spec = cronJob.spec
        var groups = [
            SettingGroup(
                title: "スケジュール",
                rows: [
                    SettingRow("実行の予定", spec?["schedule"]?.stringValue),
                    SettingRow("タイムゾーン", spec?["timeZone"]?.stringValue),
                    SettingRow("停止中", yesNo(spec?["suspend"]?.boolValue)),
                    SettingRow("重なったときの扱い", spec?["concurrencyPolicy"]?.stringValue),
                    SettingRow(
                        "成功の履歴",
                        spec?["successfulJobsHistoryLimit"]?.intValue.map { "\($0) 件" }),
                    SettingRow(
                        "失敗の履歴",
                        spec?["failedJobsHistoryLimit"]?.intValue.map { "\($0) 件" }),
                ])
        ]
        for container in spec?.path("jobTemplate.spec.template.spec.containers")?.arrayValue ?? [] {
            groups.append(containerGroup(container, status: nil))
        }
        return groups
    }

    // MARK: - RBAC

    private static func serviceAccountGroups(_ account: K8sObject) -> [SettingGroup] {
        [
            SettingGroup(
                title: "シークレット",
                rows: [
                    SettingRow("紐づくシークレット", names(account.raw["secrets"])),
                    SettingRow("イメージ取得用", names(account.raw["imagePullSecrets"])),
                    SettingRow(
                        "トークンを自動で入れる",
                        yesNo(account.raw["automountServiceAccountToken"]?.boolValue)),
                ])
        ]
    }

    /// **規則は 1 つずつ出す。** まとめると「どの動詞がどの資源に効くのか」が
    /// 混ざる。`get` できるのは Pod だけなのに Secret にも効くように読めてしまう。
    private static func roleGroups(_ role: K8sObject) -> [SettingGroup] {
        let rules = role.raw["rules"]?.arrayValue ?? []
        guard !rules.isEmpty else {
            // **空欄にしない。** 規則の無い Role は「何もできない」ので、
            // それ自体が言うべきこと。
            return [SettingGroup(title: "できること", rows: [SettingRow("規則", nil)])]
        }

        return rules.enumerated().map { index, rule in
            SettingGroup(
                title: "規則 \(index + 1)",
                rows: [
                    SettingRow("できること", list(rule["verbs"])),
                    SettingRow("対象", list(rule["resources"])),
                    // 空文字の API グループは core（Pod や Service）。
                    // そのまま出すと空欄に見えるので言い換える。
                    SettingRow("API グループ", apiGroups(rule["apiGroups"])),
                    SettingRow("名前を限定", list(rule["resourceNames"])),
                    SettingRow("URL", list(rule["nonResourceURLs"])),
                ])
        }
    }

    private static func bindingGroups(_ binding: K8sObject) -> [SettingGroup] {
        var groups = [
            SettingGroup(
                title: "与える権限",
                rows: [SettingRow("参照するロール", ResourceTable.roleRef(binding))])
        ]

        let subjects = binding.raw["subjects"]?.arrayValue ?? []
        guard !subjects.isEmpty else {
            // 誰にも効いていない Binding は設定の誤りとしてよくある。
            groups.append(
                SettingGroup(title: "誰に", rows: [SettingRow("対象", nil)]))
            return groups
        }

        for (index, subject) in subjects.enumerated() {
            groups.append(
                SettingGroup(
                    title: "対象 \(index + 1)",
                    rows: [
                        SettingRow("種別", subject["kind"]?.stringValue),
                        SettingRow("名前", subject["name"]?.stringValue),
                        SettingRow("Namespace", subject["namespace"]?.stringValue),
                    ]))
        }
        return groups
    }

    /// 文字列の配列をそのまま並べる。空なら nil（＝「未設定」と出る）。
    private static func list(_ value: JSONValue?) -> String? {
        let values = value?.arrayValue.compactMap { $0.stringValue } ?? []
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    private static func apiGroups(_ value: JSONValue?) -> String? {
        let values = value?.arrayValue.compactMap { $0.stringValue } ?? []
        guard !values.isEmpty else { return nil }
        return values.map { $0.isEmpty ? "core" : $0 }.joined(separator: ", ")
    }

    /// `secrets` や `imagePullSecrets` は `{name: ...}` の配列。
    private static func names(_ value: JSONValue?) -> String? {
        let values = value?.arrayValue.compactMap { $0["name"]?.stringValue } ?? []
        return values.isEmpty ? nil : values.joined(separator: ", ")
    }

    // MARK: - HPA

    /// **「いま何レプリカか」より「どう決まるか」を出す。** 現在値は一覧の列に
    /// あり、ここで見たいのは範囲・指標・調整の癖のほう。
    private static func autoscalerGroups(_ hpa: K8sObject) -> [SettingGroup] {
        let spec = hpa.spec
        var groups = [
            SettingGroup(
                title: "調整の範囲",
                rows: [
                    SettingRow("対象", ResourceTable.hpaReference(hpa)),
                    // 省略できて既定は 1。未設定と書くと「下限なし」に読める。
                    SettingRow("最小", "\(spec?["minReplicas"]?.intValue ?? 1)"),
                    SettingRow("最大", spec?["maxReplicas"]?.intValue.map { "\($0)" }),
                    SettingRow("いまの目標", hpa.status?["desiredReplicas"]?.intValue.map { "\($0)" }),
                ])
        ]

        let targets = ResourceTable.hpaTargets(hpa)
        groups.append(
            SettingGroup(
                title: "指標",
                rows: [SettingRow("使用率 / 目標", targets.text.isEmpty ? nil : targets.text)],
                // 取れていない指標があることを、この画面でも言う。
                subtitle: targets.hasUnknown ? "取得できていない指標があります" : nil))

        if let behavior = spec?["behavior"] {
            groups.append(
                SettingGroup(
                    title: "調整の癖",
                    rows: [
                        SettingRow(
                            "増やすときの待ち",
                            behavior.path("scaleUp.stabilizationWindowSeconds")?
                                .intValue.map { "\($0) 秒" }),
                        SettingRow(
                            "減らすときの待ち",
                            behavior.path("scaleDown.stabilizationWindowSeconds")?
                                .intValue.map { "\($0) 秒" }),
                    ]))
        }

        return groups
    }

    // MARK: - ネットワーク

    private static func serviceGroups(_ service: K8sObject) -> [SettingGroup] {
        let spec = service.spec
        var groups = [
            SettingGroup(
                title: "公開",
                rows: [
                    SettingRow("種類", spec?["type"]?.stringValue ?? "ClusterIP"),
                    SettingRow("Cluster IP", spec?["clusterIP"]?.stringValue),
                    SettingRow("外部 IP", ResourceTable.externalIPs(service)),
                    SettingRow("外部への経路", spec?["externalTrafficPolicy"]?.stringValue),
                    SettingRow("接続の固定", spec?["sessionAffinity"]?.stringValue),
                    SettingRow("対象の条件", pairs(spec?["selector"])),
                ])
        ]

        let ports = spec?["ports"]?.arrayValue ?? []
        if !ports.isEmpty {
            groups.append(
                SettingGroup(
                    title: "ポート",
                    rows: ports.map { port in
                        let name = port["name"]?.stringValue
                            ?? "\(port["port"]?.intValue ?? 0)"
                        var parts = ["\(port["port"]?.intValue ?? 0)/\(port["protocol"]?.stringValue ?? "TCP")"]
                        if let target = port["targetPort"]?.displayText, !target.isEmpty {
                            parts.append("→ \(target)")
                        }
                        if let nodePort = port["nodePort"]?.intValue {
                            parts.append("ノード \(nodePort)")
                        }
                        return SettingRow(name, parts.joined(separator: " "))
                    }))
        }
        return groups
    }

    private static func ingressGroups(_ ingress: K8sObject) -> [SettingGroup] {
        let spec = ingress.spec
        var groups = [
            SettingGroup(
                title: "受け口",
                rows: [
                    SettingRow("クラス", spec?["ingressClassName"]?.stringValue),
                    SettingRow("アドレス", ResourceTable.loadBalancerAddresses(ingress)),
                    SettingRow(
                        "TLS",
                        (spec?["tls"]?.arrayValue ?? [])
                            .flatMap { ($0["hosts"]?.arrayValue ?? []).compactMap(\.stringValue) }
                            .joined(separator: ", ")),
                ])
        ]

        var rules: [SettingRow] = []
        for rule in spec?["rules"]?.arrayValue ?? [] {
            let host = rule["host"]?.stringValue ?? "*"
            for path in rule.path("http.paths")?.arrayValue ?? [] {
                let route = path["path"]?.stringValue ?? "/"
                let service = path.path("backend.service")
                let target = [
                    service?["name"]?.stringValue,
                    service?.path("port.number")?.intValue.map(String.init)
                        ?? service?.path("port.name")?.stringValue,
                ]
                .compactMap { $0 }.joined(separator: ":")
                rules.append(SettingRow("\(host)\(route)", target))
            }
        }
        if !rules.isEmpty { groups.append(SettingGroup(title: "振り分け", rows: rules)) }
        return groups
    }

    /// NetworkPolicy。
    ///
    /// **規則を 1 行にまとめない。** 「どこから来てよいか」は from の 1 つずつが
    /// 別の許可で、混ぜると `namespaceSelector` の範囲と `ipBlock` の範囲が
    /// 同じものに読める（RBAC の規則を 1 つずつ出すのと同じ理由）。
    ///
    /// **規則が 0 のときに空欄にしない。** `ingress: []` は「未設定」ではなく
    /// **すべて拒否**で、この種別でいちばん効きの強い状態。
    private static func networkPolicyGroups(_ policy: K8sObject) -> [SettingGroup] {
        let spec = policy.spec
        var groups = [
            SettingGroup(
                title: "対象",
                rows: [
                    SettingRow("この Pod に効く", ResourceTable.policyTargets(policy)),
                    SettingRow("制限する向き", ResourceTable.policyDirections(policy)),
                ])
        ]

        for direction in ["ingress", "egress"] {
            guard let rules = spec?[direction]?.arrayValue else { continue }
            let title = direction == "ingress" ? "入ってよい先" : "出てよい先"
            guard !rules.isEmpty else {
                groups.append(
                    SettingGroup(
                        title: title,
                        rows: [
                            SettingRow("規則", "1 つもありません（すべて拒否）", level: .warning)
                        ]))
                continue
            }
            var rows: [SettingRow] = []
            for (index, rule) in rules.enumerated() {
                let peers = (rule[direction == "ingress" ? "from" : "to"]?.arrayValue ?? [])
                    .map(peerDescription)
                let ports = (rule["ports"]?.arrayValue ?? []).map { port -> String in
                    let number = port["port"]?.intValue.map(String.init)
                        ?? port["port"]?.stringValue ?? ""
                    let proto = port["protocol"]?.stringValue ?? "TCP"
                    return number.isEmpty ? proto : "\(proto)/\(number)"
                }
                // **相手が空のときに空欄にしない。** `from` が無い規則は
                // 「どこからでも」で、いちばん緩い。
                rows.append(
                    SettingRow(
                        "規則 \(index + 1)",
                        peers.isEmpty ? "どこからでも" : peers.joined(separator: ", ")))
                if !ports.isEmpty {
                    rows.append(SettingRow("　ポート", ports.joined(separator: ", ")))
                }
            }
            groups.append(SettingGroup(title: title, rows: rows))
        }
        return groups
    }

    /// NetworkPolicy の `from` / `to` の 1 つ。
    private static func peerDescription(_ peer: JSONValue) -> String {
        if let cidr = peer.path("ipBlock.cidr")?.stringValue {
            let except = (peer.path("ipBlock.except")?.arrayValue ?? [])
                .compactMap(\.stringValue)
            return except.isEmpty ? cidr : "\(cidr)（除く \(except.joined(separator: ", "))）"
        }
        var parts: [String] = []
        // **空のセレクタの意味が入れ子で変わる。** `namespaceSelector: {}` は
        // 「すべての Namespace」、`podSelector: {}` は「その中のすべての Pod」。
        if let namespace = peer["namespaceSelector"] {
            let labels = labelText(namespace)
            parts.append(labels.isEmpty ? "すべての Namespace" : "Namespace \(labels)")
        }
        if let pod = peer["podSelector"] {
            let labels = labelText(pod)
            parts.append(labels.isEmpty ? "すべての Pod" : "Pod \(labels)")
        }
        return parts.isEmpty ? "どこからでも" : parts.joined(separator: " の ")
    }

    private static func labelText(_ selector: JSONValue) -> String {
        (selector.path("matchLabels")?.objectValue ?? [:])
            .compactMap { key, value in value.stringValue.map { "\(key)=\($0)" } }
            .sorted()
            .joined(separator: ",")
    }

    // MARK: - 設定と保存

    private static func dataGroups(_ object: K8sObject) -> [SettingGroup] {
        var groups: [SettingGroup] = []
        if object.kind == .secret {
            groups.append(
                SettingGroup(
                    title: "種類",
                    rows: [SettingRow("type", object.raw["type"]?.stringValue)]))
        }

        let data = object.raw["data"]?.objectValue ?? [:]
        groups.append(
            SettingGroup(
                title: "キー",
                rows: data.isEmpty
                    ? [SettingRow("キー", nil)]
                    : data.keys.sorted().map { key in
                        // Secret の中身は出さない。大きさだけ出す。
                        let size = data[key]?.stringValue?.count ?? 0
                        return SettingRow(key, object.kind == .secret ? "\(size) 文字" : "設定あり")
                    }))
        return groups
    }

    private static func claimGroups(_ claim: K8sObject) -> [SettingGroup] {
        [
            SettingGroup(
                title: "要求",
                rows: [
                    SettingRow("状態", claim.status?["phase"]?.stringValue),
                    SettingRow("容量", claim.status?.path("capacity.storage")?.displayText),
                    SettingRow("要求した容量", claim.spec?.path("resources.requests.storage")?.displayText),
                    SettingRow("アクセス", ResourceTable.accessModes(claim)),
                    SettingRow("StorageClass", claim.spec?["storageClassName"]?.stringValue),
                    SettingRow("結び付いたボリューム", claim.spec?["volumeName"]?.stringValue),
                ])
        ]
    }

    private static func volumeGroups(_ volume: K8sObject) -> [SettingGroup] {
        [
            SettingGroup(
                title: "ボリューム",
                rows: [
                    SettingRow("状態", volume.status?["phase"]?.stringValue),
                    SettingRow("容量", volume.spec?.path("capacity.storage")?.displayText),
                    SettingRow("アクセス", ResourceTable.accessModes(volume)),
                    SettingRow("回収の方針", volume.spec?["persistentVolumeReclaimPolicy"]?.stringValue),
                    SettingRow("StorageClass", volume.spec?["storageClassName"]?.stringValue),
                    SettingRow("使っている要求", ResourceTable.claimReference(volume)),
                    SettingRow("実体", volumeKind(volume.spec ?? .null)),
                ])
        ]
    }

    // MARK: - クラスタ

    private static func nodeGroups(_ node: K8sObject) -> [SettingGroup] {
        let info = node.status?["nodeInfo"]
        var groups = [
            SettingGroup(
                title: "ノード",
                rows: [
                    SettingRow("ロール", StatusResolver.nodeRoles(node)),
                    SettingRow("内部 IP", StatusResolver.nodeInternalIP(node)),
                    SettingRow("kubelet", info?["kubeletVersion"]?.stringValue),
                    SettingRow("OS", info?["osImage"]?.stringValue),
                    SettingRow("ランタイム", info?["containerRuntimeVersion"]?.stringValue),
                    SettingRow("アーキテクチャ", info?["architecture"]?.stringValue),
                    SettingRow(
                        "スケジュール停止",
                        yesNo(node.spec?["unschedulable"]?.boolValue),
                        level: node.spec?["unschedulable"]?.boolValue == true ? .serious : nil),
                ]),
            SettingGroup(
                title: "容量",
                rows: [
                    SettingRow("CPU（割り当て可能）", node.status?.path("allocatable.cpu")?.displayText),
                    SettingRow("メモリ（割り当て可能）", node.status?.path("allocatable.memory")?.displayText),
                    SettingRow("Pod 上限", node.status?.path("allocatable.pods")?.displayText),
                ]),
        ]

        let taints = node.spec?["taints"]?.arrayValue ?? []
        if !taints.isEmpty {
            groups.append(
                SettingGroup(
                    title: "汚れ",
                    rows: taints.map { taint in
                        let key = taint["key"]?.stringValue ?? "?"
                        let value = taint["value"]?.stringValue
                        let effect = taint["effect"]?.stringValue ?? ""
                        return SettingRow(
                            value.map { "\(key)=\($0)" } ?? key, effect)
                    }))
        }
        return groups
    }

    private static func namespaceGroups(_ namespace: K8sObject) -> [SettingGroup] {
        [
            SettingGroup(
                title: "Namespace",
                rows: [
                    SettingRow("状態", namespace.status?["phase"]?.stringValue),
                    SettingRow(
                        "終了時に消すもの",
                        joined(namespace.spec?["finalizers"])),
                ])
        ]
    }

    // MARK: - 値の整形

    private static func yesNo(_ value: Bool?) -> String? {
        value.map { $0 ? "はい" : "いいえ" }
    }

    private static func joined(_ value: JSONValue?) -> String? {
        let items = (value?.arrayValue ?? []).map(\.displayText).filter { !$0.isEmpty }
        return items.isEmpty ? nil : items.joined(separator: " ")
    }

    private static func pairs(_ value: JSONValue?) -> String? {
        let dictionary = value?.stringDictionary ?? [:]
        guard !dictionary.isEmpty else { return nil }
        return dictionary.keys.sorted().map { "\($0)=\(dictionary[$0]!)" }.joined(separator: ", ")
    }

    private static func portList(_ value: JSONValue?) -> String? {
        let ports = (value?.arrayValue ?? []).compactMap { port -> String? in
            guard let number = port["containerPort"]?.intValue else { return nil }
            return "\(number)/\(port["protocol"]?.stringValue ?? "TCP")"
        }
        return ports.isEmpty ? nil : ports.joined(separator: ", ")
    }

    private static func restartPolicy(_ value: String?) -> String? {
        switch value {
        case "Always": return "常に再起動"
        case "OnFailure": return "失敗したときだけ"
        case "Never": return "再起動しない"
        default: return value
        }
    }

    private static func tolerationSummary(_ spec: JSONValue?) -> String? {
        let tolerations = spec?["tolerations"]?.arrayValue ?? []
        guard !tolerations.isEmpty else { return nil }
        let keys = tolerations.compactMap { $0["key"]?.stringValue }
        return keys.isEmpty ? "\(tolerations.count) 件" : keys.joined(separator: ", ")
    }

    /// affinity は入れ子が深く、そのまま出しても読めない。
    /// どの種類の希望が幾つ入っているかだけを言う。
    private static func affinitySummary(_ spec: JSONValue?) -> String? {
        guard let affinity = spec?["affinity"] else { return nil }
        var parts: [String] = []
        for (key, label) in [
            ("nodeAffinity", "ノード"), ("podAffinity", "同居"), ("podAntiAffinity", "分散"),
        ] {
            guard let entry = affinity[key] else { continue }
            let required = entry["requiredDuringSchedulingIgnoredDuringExecution"] != nil
            parts.append("\(label)\(required ? "（必須）" : "（希望）")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private static func probeSummary(_ probe: JSONValue?) -> String? {
        guard let probe else { return nil }
        var target = "?"
        if let http = probe["httpGet"] {
            let path = http["path"]?.stringValue ?? "/"
            let port = http["port"]?.displayText ?? ""
            target = "HTTP \(path):\(port)"
        } else if let tcp = probe["tcpSocket"] {
            target = "TCP \(tcp["port"]?.displayText ?? "")"
        } else if let exec = probe["exec"] {
            target = "実行 " + ((exec["command"]?.arrayValue ?? []).compactMap(\.stringValue)
                .joined(separator: " "))
        }
        let period = probe["periodSeconds"]?.intValue ?? 10
        return "\(target) · \(period) 秒ごと"
    }

    /// ボリュームの実体。`configMap` などのキー名がそのまま種類になる。
    private static func volumeKind(_ volume: JSONValue) -> String? {
        let known: [(String, String)] = [
            ("configMap", "ConfigMap"), ("secret", "Secret"), ("emptyDir", "一時領域"),
            ("persistentVolumeClaim", "PVC"), ("hostPath", "ホストのパス"),
            ("projected", "まとめたもの"), ("downwardAPI", "Pod の情報"),
            ("nfs", "NFS"), ("csi", "CSI"),
        ]
        for (key, label) in known where volume[key] != nil {
            // **名前を持つキーは種類ごとに違う。** `configMap` は `name` だが、
            // `secret` は **`secretName`**、PVC は `claimName`、hostPath は `path`。
            // `secretName` を落としていたので、Secret のボリュームだけ名前が
            // 出ず「Secret」としか書けていなかった。
            //
            // **`WorkloadRelations.configReferences` と揃えること。** あちらは
            // 正しく `secret.secretName` を見ており、同じ解決を 2 か所に持って
            // 片方だけ間違えていた（いちばん避けたい形の食い違い）。
            let source = volume[key]
            let name = source?["name"]?.stringValue
                ?? source?["secretName"]?.stringValue
                ?? source?["claimName"]?.stringValue
                ?? source?["path"]?.stringValue
            return name.map { "\(label)（\($0)）" } ?? label
        }
        return nil
    }
}
