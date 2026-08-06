import Foundation

struct ResourceCell: Sendable {
    enum Emphasis: Sendable {
        case primary
        case secondary
        case mono
    }

    let text: String
    var emphasis: Emphasis = .primary
    /// nil なら状態表示ではない（色を付けない）。
    var level: StatusLevel?
}

/// 一覧の並べ替え。
///
/// **列の位置ではなく見出しで持つ。** 使用量の列は metrics-server が
/// 見つかってから増えるので、位置で覚えると途中で別の列を指す。
struct ResourceSort: Equatable, Sendable {
    let columnTitle: String
    var ascending: Bool = true
}

struct ResourceColumn: Identifiable, Sendable {
    enum Width: Sendable {
        case flexible(min: CGFloat)
        case fixed(CGFloat)
    }

    var id: Int = 0
    let title: String
    var width: Width = .fixed(110)
    var trailing: Bool = false
    let value: @Sendable (K8sObject) -> ResourceCell
}

/// 種別ごとの一覧の列定義。列とセルを 1 つの定義から作るので、
/// 片方だけ足して列数がずれる、という壊れ方をしない。
enum ResourceTable {
    /// `metrics` は metrics-server が入っているクラスタでだけ渡ってくる。
    /// 入っていないクラスタで空の列を並べても意味が無いので、そのときは列ごと出さない。
    static func columns(
        for kind: ResourceKind, showNamespace: Bool, metrics: MetricsSnapshot? = nil
    ) -> [ResourceColumn] {
        var columns: [ResourceColumn] = []

        if kind != .event {
            columns.append(
                ResourceColumn(title: "名前", width: .flexible(min: 170)) {
                    ResourceCell(text: $0.name)
                })
        }
        if showNamespace, kind.isNamespaced {
            columns.append(
                ResourceColumn(title: "Namespace", width: .fixed(130)) {
                    ResourceCell(text: $0.namespace ?? "", emphasis: .secondary)
                })
        }

        columns += specific(for: kind)
        if let metrics, !metrics.isEmpty {
            columns += usageColumns(for: kind, metrics: metrics)
        }

        columns.append(
            ResourceColumn(title: "経過", width: .fixed(78), trailing: true) { object in
                ResourceCell(text: age(of: object, kind: kind), emphasis: .secondary)
            })

        return columns.enumerated().map { index, column in
            var copy = column
            copy.id = index
            return copy
        }
    }

    /// CRD で定義された種別の列。CRD 自身が宣言している表示列をそのまま使う。
    ///
    /// **priority が 1 以上の列は既定で出さない。** kubectl が `-o wide` の
    /// ときだけ出す扱いにしている列で、既定で並べると横に長くなりすぎる。
    static func columns(
        for type: CustomResourceType, showNamespace: Bool
    ) -> [ResourceColumn] {
        var columns: [ResourceColumn] = [
            ResourceColumn(title: "名前", width: .flexible(min: 200)) {
                ResourceCell(text: $0.name)
            }
        ]
        if showNamespace, type.namespaced {
            columns.append(
                ResourceColumn(title: "Namespace", width: .fixed(130)) {
                    ResourceCell(text: $0.namespace ?? "", emphasis: .secondary)
                })
        }

        for column in type.printerColumns where column.priority == 0 {
            let path = column.jsonPath
            let colorize = Self.looksLikeStatus(column.name)
            columns.append(
                ResourceColumn(title: column.name, width: .flexible(min: 110)) { object in
                    let text = object.raw.jsonPath(path)?.displayText ?? ""
                    // 状態らしい列だけ色を付ける。任意の文字列を色分けすると、
                    // ただの名前が「異常」に見えることがある。
                    let level = colorize && !text.isEmpty
                        ? StatusLevel.classify(text) : nil
                    return ResourceCell(
                        text: text,
                        emphasis: .secondary,
                        level: level == .neutral ? nil : level)
                })
        }

        columns.append(
            ResourceColumn(title: "経過", width: .fixed(78), trailing: true) {
                ResourceCell(text: $0.age, emphasis: .secondary)
            })

        return columns.enumerated().map { index, column in
            var copy = column
            copy.id = index
            return copy
        }
    }

    /// 状態を表していそうな列名。CRD ごとに語彙が違うので、名前で当たりを付ける。
    private static func looksLikeStatus(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return ["status", "health", "phase", "state", "ready", "sync"]
            .contains { lowered.contains($0) }
    }

    static func age(of object: K8sObject, kind: ResourceKind) -> String {
        // イベントは作成時刻より「最後に起きた時刻」のほうが意味を持つ。
        if kind == .event, let last = lastSeen(object) {
            return K8sObject.age(since: last)
        }
        return object.age
    }

    // MARK: - 種別ごとの列

    private static func specific(for kind: ResourceKind) -> [ResourceColumn] {
        switch kind {
        case .pod:
            return [
                ResourceColumn(title: "Ready", width: .fixed(70)) { pod in
                    let counts = StatusResolver.podReady(pod)
                    return ResourceCell(
                        text: "\(counts.ready)/\(counts.total)",
                        emphasis: .mono,
                        level: StatusResolver.replicaLevel(
                            ready: counts.ready, desired: counts.total
                        ).level)
                },
                statusColumn(width: 150),
                ResourceColumn(title: "再起動", width: .fixed(70), trailing: true) { pod in
                    let count = StatusResolver.podRestarts(pod)
                    return ResourceCell(
                        text: "\(count)", emphasis: .mono,
                        level: count == 0 ? nil : (count >= 5 ? .critical : .warning))
                },
                ResourceColumn(title: "ノード", width: .fixed(135)) {
                    ResourceCell(
                        text: $0.spec?["nodeName"]?.stringValue ?? "", emphasis: .secondary)
                },
            ]

        case .deployment:
            return [
                readyColumn(),
                ResourceColumn(title: "最新", width: .fixed(60), trailing: true) {
                    ResourceCell(
                        text: "\($0.status?["updatedReplicas"]?.intValue ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "利用可能", width: .fixed(76), trailing: true) {
                    ResourceCell(
                        text: "\($0.status?["availableReplicas"]?.intValue ?? 0)", emphasis: .mono)
                },
                imagesColumn(),
            ]

        case .replicaSet:
            return [
                ResourceColumn(title: "希望", width: .fixed(60), trailing: true) {
                    ResourceCell(text: "\($0.spec?["replicas"]?.intValue ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "現在", width: .fixed(60), trailing: true) {
                    ResourceCell(text: "\($0.status?["replicas"]?.intValue ?? 0)", emphasis: .mono)
                },
                readyColumn(title: "Ready"),
                imagesColumn(),
            ]

        case .statefulSet:
            return [readyColumn(), imagesColumn()]

        case .daemonSet:
            return [
                readyColumn(),
                ResourceColumn(title: "配置先", width: .fixed(70), trailing: true) {
                    ResourceCell(
                        text: "\($0.status?["desiredNumberScheduled"]?.intValue ?? 0)",
                        emphasis: .mono)
                },
                ResourceColumn(title: "最新", width: .fixed(60), trailing: true) {
                    ResourceCell(
                        text: "\($0.status?["updatedNumberScheduled"]?.intValue ?? 0)",
                        emphasis: .mono)
                },
                imagesColumn(),
            ]

        case .job:
            return [
                statusColumn(width: 110),
                ResourceColumn(title: "完了", width: .fixed(80), trailing: true) { job in
                    let succeeded = job.status?["succeeded"]?.intValue ?? 0
                    let completions = job.spec?["completions"]?.intValue ?? 1
                    return ResourceCell(text: "\(succeeded)/\(completions)", emphasis: .mono)
                },
                ResourceColumn(title: "所要", width: .fixed(80), trailing: true) { job in
                    ResourceCell(text: jobDuration(job), emphasis: .mono)
                },
            ]

        case .cronJob:
            return [
                ResourceColumn(title: "スケジュール", width: .fixed(130)) {
                    ResourceCell(text: $0.spec?["schedule"]?.stringValue ?? "", emphasis: .mono)
                },
                statusColumn(width: 100),
                ResourceColumn(title: "実行中", width: .fixed(70), trailing: true) {
                    ResourceCell(
                        text: "\($0.status?["active"]?.arrayValue.count ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "最終実行", width: .fixed(90), trailing: true) { cronJob in
                    guard let date = K8sObject.date(cronJob.status?["lastScheduleTime"]) else {
                        return ResourceCell(text: "<none>", emphasis: .secondary)
                    }
                    return ResourceCell(text: K8sObject.age(since: date), emphasis: .secondary)
                },
            ]

        case .horizontalPodAutoscaler:
            return [
                ResourceColumn(title: "対象", width: .fixed(180)) {
                    ResourceCell(text: hpaReference($0), emphasis: .secondary)
                },
                ResourceColumn(title: "指標", width: .flexible(min: 140)) { hpa in
                    let targets = hpaTargets(hpa)
                    // **引けていない指標を黙って通さない。** 数字が揃って
                    // 見える HPA が実は何もしていない、がここでしか分からない。
                    return ResourceCell(
                        text: targets.text, emphasis: .mono,
                        level: targets.hasUnknown ? .warning : nil)
                },
                statusColumn(width: 150),
                ResourceColumn(title: "現在", width: .fixed(60), trailing: true) {
                    ResourceCell(
                        text: "\($0.status?["currentReplicas"]?.intValue ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "最小", width: .fixed(56), trailing: true) {
                    // minReplicas は省略できて、既定は 1。空欄にすると
                    // 「下限なし」に見える。
                    ResourceCell(
                        text: "\($0.spec?["minReplicas"]?.intValue ?? 1)", emphasis: .mono)
                },
                ResourceColumn(title: "最大", width: .fixed(56), trailing: true) {
                    ResourceCell(
                        text: "\($0.spec?["maxReplicas"]?.intValue ?? 0)", emphasis: .mono)
                },
            ]

        case .serviceAccount:
            return [
                ResourceColumn(title: "シークレット", width: .fixed(100), trailing: true) {
                    ResourceCell(
                        text: "\($0.raw["secrets"]?.arrayValue.count ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "取得用シークレット", width: .fixed(130), trailing: true) {
                    ResourceCell(
                        text: "\($0.raw["imagePullSecrets"]?.arrayValue.count ?? 0)",
                        emphasis: .mono)
                },
            ]

        case .role, .clusterRole:
            return [
                ResourceColumn(title: "規則", width: .fixed(56), trailing: true) {
                    ResourceCell(text: "\($0.raw["rules"]?.arrayValue.count ?? 0)", emphasis: .mono)
                },
                // **一覧で中身まで見せる。** 名前だけ並べても、どの Role が
                // 強いのかが分からない。YAML を開かずに危ないものが目に入る。
                ResourceColumn(title: "できること", width: .flexible(min: 260)) { role in
                    let summary = ruleSummary(role)
                    return ResourceCell(
                        text: summary.text, emphasis: .secondary,
                        // `*` は「なんでもできる」。ここだけは色を付ける。
                        level: summary.isWildcard ? .warning : nil)
                },
            ]

        case .roleBinding, .clusterRoleBinding:
            return [
                ResourceColumn(title: "参照するロール", width: .fixed(220)) {
                    ResourceCell(text: roleRef($0), emphasis: .secondary)
                },
                ResourceColumn(title: "誰に", width: .flexible(min: 220)) {
                    ResourceCell(text: subjectSummary($0), emphasis: .secondary)
                },
            ]

        case .service:
            return [
                ResourceColumn(title: "種類", width: .fixed(120)) {
                    ResourceCell(text: $0.spec?["type"]?.stringValue ?? "ClusterIP")
                },
                ResourceColumn(title: "Cluster IP", width: .fixed(130)) {
                    ResourceCell(
                        text: $0.spec?["clusterIP"]?.stringValue ?? "", emphasis: .mono)
                },
                ResourceColumn(title: "External IP", width: .fixed(140)) {
                    ResourceCell(text: externalIPs($0), emphasis: .mono)
                },
                ResourceColumn(title: "ポート", width: .flexible(min: 130)) {
                    ResourceCell(text: servicePorts($0), emphasis: .mono)
                },
            ]

        case .ingress:
            return [
                ResourceColumn(title: "クラス", width: .fixed(110)) {
                    ResourceCell(text: $0.spec?["ingressClassName"]?.stringValue ?? "<none>")
                },
                ResourceColumn(title: "ホスト", width: .flexible(min: 160)) {
                    ResourceCell(text: ingressHosts($0), emphasis: .mono)
                },
                ResourceColumn(title: "アドレス", width: .fixed(150)) {
                    ResourceCell(text: loadBalancerAddresses($0), emphasis: .mono)
                },
            ]

        case .networkPolicy:
            return [
                // **空のセレクタを空欄にしない。** NetworkPolicy の
                // `podSelector: {}` は「まだ選んでいない」ではなく
                // **「この Namespace のすべての Pod」**（Service とは逆）。
                // 空欄にすると、いちばん効きの強い設定が何も書いていない
                // ように見える。
                ResourceColumn(title: "対象", width: .flexible(min: 180)) {
                    ResourceCell(text: policyTargets($0), emphasis: .secondary)
                },
                ResourceColumn(title: "向き", width: .fixed(140)) {
                    ResourceCell(text: policyDirections($0))
                },
                ResourceColumn(title: "規則", width: .fixed(90), trailing: true) {
                    ResourceCell(text: policyRuleCounts($0), emphasis: .mono)
                },
            ]

        case .configMap:
            return [
                ResourceColumn(title: "データ", width: .fixed(70), trailing: true) {
                    ResourceCell(
                        text: "\($0.raw["data"]?.objectValue.count ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "キー", width: .flexible(min: 160)) {
                    ResourceCell(
                        text: ($0.raw["data"]?.objectValue.keys.sorted() ?? []).joined(
                            separator: ", "), emphasis: .secondary)
                },
            ]

        case .secret:
            return [
                ResourceColumn(title: "種類", width: .fixed(200)) {
                    ResourceCell(text: $0.raw["type"]?.stringValue ?? "Opaque", emphasis: .secondary)
                },
                ResourceColumn(title: "データ", width: .fixed(70), trailing: true) {
                    ResourceCell(
                        text: "\($0.raw["data"]?.objectValue.count ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "キー", width: .flexible(min: 140)) {
                    ResourceCell(
                        text: ($0.raw["data"]?.objectValue.keys.sorted() ?? []).joined(
                            separator: ", "), emphasis: .secondary)
                },
            ]

        case .persistentVolumeClaim:
            return [
                statusColumn(width: 100),
                ResourceColumn(title: "容量", width: .fixed(80), trailing: true) {
                    ResourceCell(
                        text: $0.status?.path("capacity.storage")?.displayText ?? "",
                        emphasis: .mono)
                },
                ResourceColumn(title: "アクセス", width: .fixed(90)) {
                    ResourceCell(text: accessModes($0), emphasis: .mono)
                },
                ResourceColumn(title: "StorageClass", width: .fixed(140)) {
                    ResourceCell(
                        text: $0.spec?["storageClassName"]?.stringValue ?? "", emphasis: .secondary)
                },
                ResourceColumn(title: "ボリューム", width: .flexible(min: 140)) {
                    ResourceCell(
                        text: $0.spec?["volumeName"]?.stringValue ?? "", emphasis: .secondary)
                },
            ]

        case .node:
            return [
                statusColumn(width: 170),
                ResourceColumn(title: "ロール", width: .fixed(140)) {
                    ResourceCell(text: StatusResolver.nodeRoles($0), emphasis: .secondary)
                },
                ResourceColumn(title: "バージョン", width: .fixed(110)) {
                    ResourceCell(
                        text: $0.status?.path("nodeInfo.kubeletVersion")?.stringValue ?? "",
                        emphasis: .mono)
                },
                ResourceColumn(title: "内部 IP", width: .fixed(130)) {
                    ResourceCell(text: StatusResolver.nodeInternalIP($0), emphasis: .mono)
                },
                ResourceColumn(title: "OS イメージ", width: .flexible(min: 160)) {
                    ResourceCell(
                        text: $0.status?.path("nodeInfo.osImage")?.stringValue ?? "",
                        emphasis: .secondary)
                },
            ]

        case .persistentVolume:
            return [
                ResourceColumn(title: "容量", width: .fixed(80), trailing: true) {
                    ResourceCell(
                        text: $0.spec?.path("capacity.storage")?.displayText ?? "",
                        emphasis: .mono)
                },
                ResourceColumn(title: "アクセス", width: .fixed(90)) {
                    ResourceCell(text: accessModes($0), emphasis: .mono)
                },
                ResourceColumn(title: "回収ポリシー", width: .fixed(110)) {
                    ResourceCell(
                        text: $0.spec?["persistentVolumeReclaimPolicy"]?.stringValue ?? "",
                        emphasis: .secondary)
                },
                statusColumn(width: 100),
                ResourceColumn(title: "要求", width: .flexible(min: 160)) {
                    ResourceCell(text: claimReference($0), emphasis: .secondary)
                },
                ResourceColumn(title: "StorageClass", width: .fixed(140)) {
                    ResourceCell(
                        text: $0.spec?["storageClassName"]?.stringValue ?? "",
                        emphasis: .secondary)
                },
            ]

        case .namespace:
            return [statusColumn(width: 120)]

        case .event:
            return [
                statusColumn(width: 90),
                ResourceColumn(title: "理由", width: .fixed(160)) {
                    ResourceCell(text: $0.raw["reason"]?.stringValue ?? "")
                },
                ResourceColumn(title: "対象", width: .fixed(220)) {
                    ResourceCell(text: eventTarget($0), emphasis: .secondary)
                },
                ResourceColumn(title: "内容", width: .flexible(min: 260)) {
                    ResourceCell(text: eventMessage($0), emphasis: .secondary)
                },
                ResourceColumn(title: "回数", width: .fixed(60), trailing: true) {
                    ResourceCell(text: "\($0.raw["count"]?.intValue ?? 1)", emphasis: .mono)
                },
            ]

        case .podDisruptionBudget:
            return [
                ResourceColumn(title: "最小/最大", width: .fixed(110)) {
                    ResourceCell(text: budgetTarget($0), emphasis: .mono)
                },
                ResourceColumn(title: "対象", width: .flexible(min: 160)) {
                    ResourceCell(text: policySelectorText($0), emphasis: .secondary)
                },
                // **これが 0 だと drain が止まる。** この一覧を足した理由そのもの
                // なので、色を付けて先に見えるようにする。
                ResourceColumn(title: "退避できる数", width: .fixed(110), trailing: true) {
                    let allowed = $0.status?["disruptionsAllowed"]?.intValue
                    return ResourceCell(
                        text: allowed.map(String.init) ?? "—",
                        emphasis: .mono,
                        level: allowed == 0 ? .warning : nil)
                },
                ResourceColumn(title: "健全", width: .fixed(90), trailing: true) {
                    let current = $0.status?["currentHealthy"]?.intValue ?? 0
                    let desired = $0.status?["desiredHealthy"]?.intValue ?? 0
                    return ResourceCell(
                        text: "\(current)/\(desired)", emphasis: .mono,
                        level: current < desired ? .serious : nil)
                },
            ]

        case .endpointSlice:
            return [
                ResourceColumn(title: "Service", width: .flexible(min: 140)) {
                    ResourceCell(
                        text: $0.labels["kubernetes.io/service-name"] ?? "",
                        emphasis: .secondary)
                },
                ResourceColumn(title: "種類", width: .fixed(80)) {
                    ResourceCell(text: $0.raw["addressType"]?.stringValue ?? "")
                },
                // **0 を空欄にしない。** 「繋がっていない」ことがこの一覧の値打ち。
                ResourceColumn(title: "宛先", width: .fixed(80), trailing: true) {
                    let endpoints = $0.raw["endpoints"]?.arrayValue ?? []
                    return ResourceCell(
                        text: "\(endpoints.count)", emphasis: .mono,
                        level: endpoints.isEmpty ? .warning : nil)
                },
                ResourceColumn(title: "準備できている", width: .fixed(120), trailing: true) {
                    let ready = ($0.raw["endpoints"]?.arrayValue ?? []).filter {
                        $0.path("conditions.ready")?.boolValue != false
                    }
                    return ResourceCell(text: "\(ready.count)", emphasis: .mono)
                },
            ]

        case .resourceQuota:
            return [
                // **使用量と上限を並べる。** 片方だけでは、あとどれだけ作れるのか
                // 分からない（それがこの一覧を見に来る理由）。
                ResourceColumn(title: "使用 / 上限", width: .flexible(min: 260)) {
                    ResourceCell(text: quotaSummary($0), emphasis: .mono)
                },
            ]

        case .limitRange:
            return [
                ResourceColumn(title: "既定と範囲", width: .flexible(min: 300)) {
                    ResourceCell(text: limitRangeSummary($0), emphasis: .mono)
                },
            ]

        case .storageClass:
            return [
                // **既定かどうかを最初に出す。** PVC が Pending になる理由の
                // 大半がこれ（既定が無い / 2 つある）。
                ResourceColumn(title: "既定", width: .fixed(60)) {
                    let isDefault = $0.annotations[
                        "storageclass.kubernetes.io/is-default-class"] == "true"
                    return ResourceCell(text: isDefault ? "既定" : "", level: isDefault ? .good : nil)
                },
                ResourceColumn(title: "プロビジョナ", width: .flexible(min: 200)) {
                    ResourceCell(text: $0.raw["provisioner"]?.stringValue ?? "", emphasis: .secondary)
                },
                ResourceColumn(title: "回収", width: .fixed(100)) {
                    ResourceCell(text: $0.raw["reclaimPolicy"]?.stringValue ?? "Delete")
                },
                ResourceColumn(title: "束縛", width: .fixed(140)) {
                    ResourceCell(text: $0.raw["volumeBindingMode"]?.stringValue ?? "Immediate")
                },
                ResourceColumn(title: "拡張", width: .fixed(70)) {
                    ResourceCell(
                        text: $0.raw["allowVolumeExpansion"]?.boolValue == true ? "可" : "不可",
                        emphasis: .secondary)
                },
            ]

        case .priorityClass:
            return [
                ResourceColumn(title: "値", width: .fixed(110), trailing: true) {
                    ResourceCell(text: "\($0.raw["value"]?.intValue ?? 0)", emphasis: .mono)
                },
                ResourceColumn(title: "既定", width: .fixed(60)) {
                    let isDefault = $0.raw["globalDefault"]?.boolValue == true
                    return ResourceCell(text: isDefault ? "既定" : "", level: isDefault ? .good : nil)
                },
                // **追い出す側かどうかを出す。** 同じ優先度でも、ここが
                // `Never` なら他を蹴らない。
                ResourceColumn(title: "横取り", width: .fixed(140)) {
                    ResourceCell(
                        text: $0.raw["preemptionPolicy"]?.stringValue ?? "PreemptLowerPriority",
                        emphasis: .secondary)
                },
            ]

        case .validatingWebhookConfiguration, .mutatingWebhookConfiguration:
            return [
                ResourceColumn(title: "webhook", width: .fixed(90), trailing: true) {
                    ResourceCell(
                        text: "\(($0.raw["webhooks"]?.arrayValue ?? []).count)", emphasis: .mono)
                },
                // **失敗したときにどうなるかを出す。** `Fail` なら、この webhook が
                // 落ちているあいだ**対象の作成がすべて止まる**。
                ResourceColumn(title: "失敗時", width: .fixed(100)) {
                    let policies = Set(($0.raw["webhooks"]?.arrayValue ?? []).compactMap {
                        $0["failurePolicy"]?.stringValue
                    })
                    let text = policies.sorted().joined(separator: ", ")
                    return ResourceCell(
                        text: text.isEmpty ? "Fail" : text,
                        level: text.contains("Fail") || text.isEmpty ? .warning : nil)
                },
                ResourceColumn(title: "対象", width: .flexible(min: 200)) {
                    ResourceCell(text: webhookTargets($0), emphasis: .secondary)
                },
            ]

        case .apiService:
            return [
                // **これが False のグループは、種別ごと一覧から消える。**
                // `discoveryHint` が見に行けと言っている当の値。
                ResourceColumn(title: "利用可能", width: .fixed(100)) {
                    let condition = ($0.status?["conditions"]?.arrayValue ?? []).first {
                        $0["type"]?.stringValue == "Available"
                    }
                    let status = condition?["status"]?.stringValue ?? ""
                    return ResourceCell(
                        text: status.isEmpty ? "—" : status,
                        level: status == "True" ? .good : (status.isEmpty ? nil : .critical))
                },
                ResourceColumn(title: "実体", width: .flexible(min: 200)) {
                    guard let service = $0.spec?["service"] else {
                        return ResourceCell(text: "ローカル（集約なし）", emphasis: .secondary)
                    }
                    let namespace = service["namespace"]?.stringValue ?? ""
                    let name = service["name"]?.stringValue ?? ""
                    return ResourceCell(text: "\(namespace)/\(name)", emphasis: .secondary)
                },
                ResourceColumn(title: "理由", width: .flexible(min: 160)) {
                    let condition = ($0.status?["conditions"]?.arrayValue ?? []).first {
                        $0["type"]?.stringValue == "Available"
                    }
                    return ResourceCell(
                        text: condition?["reason"]?.stringValue ?? "", emphasis: .secondary)
                },
            ]
        }
    }

    // MARK: - 新しい種別のセル

    /// PDB の最小/最大。**どちらか一方しか設定できない**ので、書いてあるほうを出す。
    static func budgetTarget(_ budget: K8sObject) -> String {
        if let min = budget.spec?["minAvailable"] {
            return "min \(min.displayText)"
        }
        if let max = budget.spec?["maxUnavailable"] {
            return "max \(max.displayText)"
        }
        return "—"
    }

    /// `spec.selector.matchLabels` を読む。**空を「すべて」と書かない** ——
    /// PDB の空セレクタは NetworkPolicy と違って「すべての Pod」だが、
    /// 省略（nil）なら何も選ばない。ここは実際の値をそのまま出す。
    static func policySelectorText(_ object: K8sObject) -> String {
        guard let selector = object.spec?["selector"] else { return "—" }
        let labels = selector["matchLabels"]?.stringDictionary ?? [:]
        if labels.isEmpty {
            return selector.objectValue.isEmpty ? "すべての Pod" : "式で指定"
        }
        return labels.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    /// ResourceQuota の「使ったぶん / 上限」。
    /// **上限だけを出さない。** あとどれだけ作れるのかが分からない。
    static func quotaSummary(_ quota: K8sObject) -> String {
        let hard = quota.status?["hard"]?.objectValue ?? quota.spec?["hard"]?.objectValue ?? [:]
        let used = quota.status?["used"]?.objectValue ?? [:]
        guard !hard.isEmpty else { return "—" }
        return hard.keys.sorted().prefix(4).map { key in
            "\(key) \(used[key]?.displayText ?? "0")/\(hard[key]?.displayText ?? "")"
        }.joined(separator: "  ")
            + (hard.count > 4 ? "  他 \(hard.count - 4)" : "")
    }

    /// LimitRange の中身。**種類（Container / Pod / PVC）まで書く** ——
    /// 同じ数字でも掛かる相手が違う。
    static func limitRangeSummary(_ range: K8sObject) -> String {
        let limits = range.spec?["limits"]?.arrayValue ?? []
        guard !limits.isEmpty else { return "—" }
        return limits.prefix(3).map { limit in
            let type = limit["type"]?.stringValue ?? "?"
            let parts = [
                ("既定", limit["default"]),
                ("既定要求", limit["defaultRequest"]),
                ("最小", limit["min"]),
                ("最大", limit["max"]),
            ].compactMap { label, value -> String? in
                guard let value, !value.objectValue.isEmpty else { return nil }
                let inner = value.objectValue.keys.sorted()
                    .map { "\($0)=\(value[$0]?.displayText ?? "")" }
                    .joined(separator: ",")
                return "\(label) \(inner)"
            }
            return "\(type): " + (parts.isEmpty ? "—" : parts.joined(separator: " / "))
        }.joined(separator: "  ")
    }

    /// webhook が捕まえる対象。
    static func webhookTargets(_ configuration: K8sObject) -> String {
        let rules = (configuration.raw["webhooks"]?.arrayValue ?? []).flatMap {
            $0["rules"]?.arrayValue ?? []
        }
        let resources = rules.flatMap { $0["resources"]?.arrayValue ?? [] }
            .compactMap { $0.stringValue }
        guard !resources.isEmpty else { return "—" }
        let unique = Array(Set(resources)).sorted()
        return unique.prefix(4).joined(separator: ", ")
            + (unique.count > 4 ? " 他 \(unique.count - 4)" : "")
    }

    // MARK: - 使用量の列

    /// CPU とメモリ。Node は割り当て可能量に対する割合も出す。
    private static func usageColumns(
        for kind: ResourceKind, metrics: MetricsSnapshot
    ) -> [ResourceColumn] {
        guard kind == .pod || kind == .node else { return [] }
        let snapshot = metrics

        // Pod は requests、Node は allocatable が分母。**分母は必ず一緒に出す。**
        // 使用量だけでは、それが多いのか少ないのか判断できない。
        return [
            ResourceColumn(
                title: kind == .node ? "CPU" : "CPU / 要求",
                width: .fixed(kind == .node ? 110 : 118), trailing: true
            ) { object in
                usageCell(
                    kind: kind,
                    used: snapshot.usage(for: object)?.cpuCores,
                    base: kind == .node
                        ? object.nodeAllocatable.cpuCores
                        : object.containerResourceTotal("requests").cpuCores,
                    limit: object.containerResourceTotal("limits").cpuCores,
                    format: { Quantity.formatCPU(cores: $0) })
            },
            ResourceColumn(
                title: kind == .node ? "メモリ" : "メモリ / 要求",
                width: .fixed(kind == .node ? 120 : 132), trailing: true
            ) { object in
                usageCell(
                    kind: kind,
                    used: snapshot.usage(for: object)?.memoryBytes,
                    base: kind == .node
                        ? object.nodeAllocatable.memoryBytes
                        : object.containerResourceTotal("requests").memoryBytes,
                    limit: object.containerResourceTotal("limits").memoryBytes,
                    format: { Quantity.formatMemory(bytes: $0) })
            },
        ]
    }

    /// 使用量のセル。
    ///
    /// **「取れていない」と「未設定」を混ぜない。** 使用量が引けないときは `—`、
    /// 使用量はあるが分母（requests）が無いときは `156m / 未設定`。前者は
    /// metrics-server の話で、後者は Pod の書き方の話なので、見る場所が違う。
    ///
    /// **色は上限で決める。** 要求を超えていること自体は異常ではない（要求は
    /// 置き場所を決めるための申告であって上限ではない）。要求比で色を付けていた
    /// ときは、要求控えめ・上限広めというごく普通の設定が軒並み赤くなり、
    /// **健全な Pod が一覧で異常に見えた。** 上限が無い Pod は超える先が無いので
    /// 色を付けない（ノードの空きの話になり、それは Node の行が持っている）。
    private static func usageCell(
        kind: ResourceKind, used: Double?, base: Double, limit: Double,
        format: (Double) -> String
    ) -> ResourceCell {
        guard let used else {
            // 取れていないものを 0 と書かない。集計直後の Pod はまだ値が無く、
            // それは「使っていない」ではない。
            return ResourceCell(text: "—", emphasis: .secondary)
        }
        let text = format(used)
        let level = kind == .node
            ? Quantity.ratio(used, of: base).flatMap(usageLevel)
            : Quantity.ratio(used, of: limit).flatMap(usageLevel)

        guard kind != .node else {
            guard let ratio = Quantity.ratio(used, of: base) else {
                return ResourceCell(text: text, emphasis: .mono)
            }
            return ResourceCell(
                text: "\(text) (\(Quantity.formatPercent(ratio)))",
                emphasis: .mono, level: level)
        }
        return ResourceCell(
            text: base > 0 ? "\(text) / \(format(base))" : "\(text) / 未設定",
            emphasis: .mono, level: level)
    }

    /// 使用率の色分け。しきい値は設定から（既定は運用でよく使う 80% / 90%）。
    static func usageLevel(_ ratio: Double) -> StatusLevel? {
        let thresholds = Preferences.usageThresholds
        if ratio >= thresholds.critical { return .critical }
        if ratio >= thresholds.warning { return .warning }
        return nil
    }

    // MARK: - 共通の列

    private static func statusColumn(width: CGFloat) -> ResourceColumn {
        ResourceColumn(title: "状態", width: .fixed(width)) { object in
            let status = StatusResolver.status(for: object)
            return ResourceCell(text: status.text, level: status.level)
        }
    }

    private static func readyColumn(title: String = "Ready") -> ResourceColumn {
        ResourceColumn(title: title, width: .fixed(78)) { object in
            let status = StatusResolver.status(for: object)
            return ResourceCell(text: status.text, emphasis: .mono, level: status.level)
        }
    }

    private static func imagesColumn() -> ResourceColumn {
        ResourceColumn(title: "イメージ", width: .flexible(min: 200)) { object in
            ResourceCell(text: images(of: object), emphasis: .secondary)
        }
    }

    // MARK: - 値の取り出し

    static func images(of object: K8sObject) -> String {
        let containers = object.spec?.path("template.spec.containers")?.arrayValue
            ?? object.spec?["containers"]?.arrayValue
            ?? []
        return containers.compactMap { $0["image"]?.stringValue }.joined(separator: ", ")
    }

    static func servicePorts(_ service: K8sObject) -> String {
        (service.spec?["ports"]?.arrayValue ?? []).map { port in
            let number = port["port"]?.intValue ?? 0
            let proto = port["protocol"]?.stringValue ?? "TCP"
            if let nodePort = port["nodePort"]?.intValue {
                return "\(number):\(nodePort)/\(proto)"
            }
            return "\(number)/\(proto)"
        }.joined(separator: ",")
    }

    static func externalIPs(_ service: K8sObject) -> String {
        if let externalName = service.spec?["externalName"]?.stringValue {
            return externalName
        }
        let fromSpec = (service.spec?["externalIPs"]?.arrayValue ?? []).compactMap(\.stringValue)
        let fromStatus = loadBalancerAddressList(service)
        let all = fromSpec + fromStatus
        if all.isEmpty {
            return service.spec?["type"]?.stringValue == "LoadBalancer" ? "<pending>" : "<none>"
        }
        return all.joined(separator: ",")
    }

    static func loadBalancerAddresses(_ object: K8sObject) -> String {
        let addresses = loadBalancerAddressList(object)
        return addresses.isEmpty ? "" : addresses.joined(separator: ",")
    }

    private static func loadBalancerAddressList(_ object: K8sObject) -> [String] {
        (object.status?.path("loadBalancer.ingress")?.arrayValue ?? []).compactMap {
            $0["ip"]?.stringValue ?? $0["hostname"]?.stringValue
        }
    }

    static func ingressHosts(_ ingress: K8sObject) -> String {
        let hosts = (ingress.spec?["rules"]?.arrayValue ?? []).compactMap {
            $0["host"]?.stringValue
        }
        return hosts.isEmpty ? "*" : hosts.joined(separator: ",")
    }

    /// PV を掴んでいる PVC。空なら誰も使っていない。
    static func claimReference(_ volume: K8sObject) -> String {
        guard let claim = volume.spec?["claimRef"] else { return "" }
        let namespace = claim["namespace"]?.stringValue ?? ""
        let name = claim["name"]?.stringValue ?? ""
        guard !name.isEmpty else { return "" }
        return namespace.isEmpty ? name : "\(namespace)/\(name)"
    }

    static func accessModes(_ claim: K8sObject) -> String {
        let short = [
            "ReadWriteOnce": "RWO", "ReadOnlyMany": "ROX",
            "ReadWriteMany": "RWX", "ReadWriteOncePod": "RWOP",
        ]
        let modes = (claim.spec?["accessModes"]?.arrayValue ?? []).compactMap(\.stringValue)
        return modes.map { short[$0] ?? $0 }.joined(separator: ",")
    }

    static func jobDuration(_ job: K8sObject) -> String {
        guard let start = K8sObject.date(job.status?["startTime"]) else { return "" }
        let end = K8sObject.date(job.status?["completionTime"]) ?? Date()
        let seconds = max(0, Int(end.timeIntervalSince(start)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m\(seconds % 60)s" }
        return "\(seconds / 3600)h\((seconds % 3600) / 60)m"
    }

    // MARK: - イベント

    /// core/v1 と events.k8s.io/v1 でフィールド名が違うので両方見る。
    // MARK: - RBAC

    /// Role / ClusterRole の `rules` を 1 行にまとめる。
    ///
    /// **全部は書けないので、強いものから書く。** 見たいのは「何ができるか」で、
    /// とくに `*`（なんでも）が入っているかどうか。先頭に出す。
    static func ruleSummary(_ role: K8sObject) -> (text: String, isWildcard: Bool) {
        let rules = role.raw["rules"]?.arrayValue ?? []
        guard !rules.isEmpty else { return ("", false) }

        var verbs = Set<String>()
        var resources = Set<String>()
        for rule in rules {
            for verb in rule["verbs"]?.arrayValue ?? [] {
                if let value = verb.stringValue { verbs.insert(value) }
            }
            for resource in rule["resources"]?.arrayValue ?? [] {
                if let value = resource.stringValue { resources.insert(value) }
            }
            // `nonResourceURLs` しか持たない規則もある（/healthz など）。
            for url in rule["nonResourceURLs"]?.arrayValue ?? [] {
                if let value = url.stringValue { resources.insert(value) }
            }
        }

        let isWildcard = verbs.contains("*") || resources.contains("*")
        // `*` は必ず見えるところへ。並び順で沈ませない。
        func ordered(_ set: Set<String>) -> [String] {
            set.sorted { lhs, rhs in
                if (lhs == "*") != (rhs == "*") { return lhs == "*" }
                return lhs < rhs
            }
        }
        let verbText = joined(ordered(verbs), limit: 4)
        let resourceText = joined(ordered(resources), limit: 4)
        guard !verbText.isEmpty || !resourceText.isEmpty else { return ("", isWildcard) }
        return ("\(verbText) → \(resourceText)", isWildcard)
    }

    /// 長い一覧は頭だけ出して「他 N」。**黙って切らない。**
    private static func joined(_ values: [String], limit: Int) -> String {
        guard values.count > limit else { return values.joined(separator: ",") }
        return values.prefix(limit).joined(separator: ",") + " 他 \(values.count - limit)"
    }

    /// RoleBinding / ClusterRoleBinding が指しているロール。
    static func roleRef(_ binding: K8sObject) -> String {
        guard let ref = binding.raw["roleRef"] else { return "" }
        let kind = ref["kind"]?.stringValue ?? ""
        let name = ref["name"]?.stringValue ?? ""
        return kind.isEmpty ? name : "\(kind)/\(name)"
    }

    /// 誰に効いているか。**種別を落とさない** — 同じ名前の User と
    /// ServiceAccount は別物で、混ぜると誰に効いているのか分からない。
    static func subjectSummary(_ binding: K8sObject) -> String {
        let subjects = binding.raw["subjects"]?.arrayValue ?? []
        let names = subjects.map { subject -> String in
            let kind = subject["kind"]?.stringValue ?? ""
            let name = subject["name"]?.stringValue ?? ""
            // ServiceAccount は Namespace まで書かないと、どれか決まらない。
            if kind == "ServiceAccount", let namespace = subject["namespace"]?.stringValue {
                return "\(kind)/\(namespace)/\(name)"
            }
            return kind.isEmpty ? name : "\(kind)/\(name)"
        }
        return joined(names, limit: 3)
    }

    // MARK: - NetworkPolicy

    /// 誰に効いているか。
    ///
    /// **空のセレクタを「一致しない」にしない。** Service の
    /// `spec.selector` は空なら何も掴まないが、NetworkPolicy の
    /// `spec.podSelector` が空なら**その Namespace のすべての Pod**。
    /// 同じ「空」でも意味が正反対で、取り違えると**いちばん効きの強い
    /// 設定を「何も効いていない」と表示する**。
    static func policyTargets(_ policy: K8sObject) -> String {
        let selector = policySelector(policy)
        guard !selector.isEmpty else { return "すべての Pod" }
        return joined(selector.map { "\($0.key)=\($0.value)" }.sorted(), limit: 3)
    }

    static func policySelector(_ policy: K8sObject) -> [String: String] {
        (policy.spec?.path("podSelector.matchLabels")?.objectValue ?? [:])
            .compactMapValues { $0.stringValue }
    }

    /// どちらの向きを制限しているか。
    ///
    /// **`policyTypes` が無いときに空欄にしない。** 省略されたときは
    /// 「`ingress` を書いていれば Ingress、`egress` を書いていれば Egress」と
    /// いう既定があり（省略時は必ず Ingress を含む）、空欄だと「何も
    /// 制限していない」と読める。
    static func policyDirections(_ policy: K8sObject) -> String {
        let declared = (policy.spec?["policyTypes"]?.arrayValue ?? [])
            .compactMap { $0.stringValue }
        let types = declared.isEmpty ? impliedPolicyTypes(policy) : declared
        return types.map { $0 == "Egress" ? "Egress（出）" : "Ingress（入）" }
            .joined(separator: " · ")
    }

    private static func impliedPolicyTypes(_ policy: K8sObject) -> [String] {
        var types = ["Ingress"]
        if policy.spec?["egress"] != nil { types.append("Egress") }
        return types
    }

    /// 入と出の規則の数。
    ///
    /// **0 を「制限なし」と読ませない。** `ingress: []`（規則ゼロ）は
    /// **すべて拒否**で、規則が 1 つあるより強い。数だけでは向きが分からない
    /// ので「向き」列と並べて読む。
    static func policyRuleCounts(_ policy: K8sObject) -> String {
        let ingress = policy.spec?["ingress"]?.arrayValue.count
        let egress = policy.spec?["egress"]?.arrayValue.count
        var parts: [String] = []
        if let ingress { parts.append("入 \(ingress)") }
        if let egress { parts.append("出 \(egress)") }
        return parts.isEmpty ? "—" : parts.joined(separator: " / ")
    }

    // MARK: - HPA

    /// `kubectl get hpa` の REFERENCE 列。
    static func hpaReference(_ hpa: K8sObject) -> String {
        guard let ref = hpa.spec?["scaleTargetRef"] else { return "" }
        let kind = ref["kind"]?.stringValue ?? ""
        let name = ref["name"]?.stringValue ?? ""
        return kind.isEmpty ? name : "\(kind)/\(name)"
    }

    /// `kubectl get hpa` の TARGETS 列（`cpu 42%/80%`）。
    ///
    /// **引けていない指標を 0% と書かない。** kubectl が `<unknown>` と出す
    /// ところで、これは「使用率が 0」ではなく「指標が取れていない」。0 と
    /// 書くと**いちばん見つけたい壊れ方（HPA が動いていない）が「余裕が
    /// ある」に見える**。取れていないことは `—` と、呼び出し側が付ける
    /// しるしで示す。
    static func hpaTargets(_ hpa: K8sObject) -> (text: String, hasUnknown: Bool) {
        let specMetrics = hpa.spec?["metrics"]?.arrayValue ?? []
        let currentMetrics = hpa.status?["currentMetrics"]?.arrayValue ?? []

        // `autoscaling/v1` は CPU 使用率ひとつを別の場所に持つ。
        guard !specMetrics.isEmpty else {
            guard let target = hpa.spec?["targetCPUUtilizationPercentage"]?.intValue else {
                return ("", false)
            }
            let current = hpa.status?["currentCPUUtilizationPercentage"]?.intValue
            return ("cpu \(current.map { "\($0)%" } ?? "—")/\(target)%", current == nil)
        }

        var hasUnknown = false
        let parts = specMetrics.map { metric -> String in
            guard let resource = metric["resource"] else {
                // Pods / Object / External は種類だけ出す。値まで追うと
                // 指標の型ごとに別の形を読むことになり、列 1 つのために
                // 背負う重さではない。
                return metric["type"]?.stringValue ?? ""
            }
            let name = resource["name"]?.stringValue ?? ""
            let current = currentMetrics.first {
                $0["resource"]?["name"]?.stringValue == name
            }?["resource"]?["current"]

            if let target = resource["target"]?["averageUtilization"]?.intValue {
                let now = current?["averageUtilization"]?.intValue
                if now == nil { hasUnknown = true }
                return "\(name) \(now.map { "\($0)%" } ?? "—")/\(target)%"
            }
            if let target = resource["target"]?["averageValue"]?.stringValue {
                let now = current?["averageValue"]?.stringValue
                if now == nil { hasUnknown = true }
                return "\(name) \(now ?? "—")/\(target)"
            }
            return name
        }
        return (parts.filter { !$0.isEmpty }.joined(separator: ", "), hasUnknown)
    }

    static func eventMessage(_ event: K8sObject) -> String {
        event.raw["message"]?.stringValue ?? event.raw["note"]?.stringValue ?? ""
    }

    static func eventTarget(_ event: K8sObject) -> String {
        let target = event.raw["involvedObject"] ?? event.raw["regarding"]
        guard let target else { return "" }
        let kind = target["kind"]?.stringValue ?? ""
        let name = target["name"]?.stringValue ?? ""
        return kind.isEmpty ? name : "\(kind)/\(name)"
    }

    static func lastSeen(_ event: K8sObject) -> Date? {
        K8sObject.date(event.raw["lastTimestamp"])
            ?? K8sObject.date(event.raw["deprecatedLastTimestamp"])
            ?? K8sObject.date(event.raw["eventTime"])
            ?? event.creationTimestamp
    }

    // MARK: - 検索

    /// 1 件だけを見るとき用。**一覧を絞るのにこれを使わない** —
    /// 呼ぶたびに `ResourceSearch` を組み立て直すことになる（`ResourceSearch` の
    /// 説明を参照）。絞り込みは `ResourceSearch` を 1 つ作って回す。
    static func matches(_ object: K8sObject, target: ResourceTarget, query: String) -> Bool {
        ResourceSearch(query: query, target: target).matches(object)
    }
}

// MARK: - 組み立て済みの絞り込み

/// 一覧の検索ボックス。名前とラベル、それに各セルの表示文字列を対象にする。
///
/// **オブジェクトごとに組み立て直さない。** 以前は 1 件ごとに
/// `SearchTerm.parse` と列定義の構築が走っていた。どちらも問い合わせと対象が
/// 同じなら結果も同じなのに、Pod 2,000 件なら 1 打鍵で 2,000 回ずつ回っていた
/// （しかも列は 1 件あたり全列ぶんの JSON を辿る）。外で 1 度だけ作る。
struct ResourceSearch: Sendable {
    private let terms: [SearchTerm]
    /// 素の文字の項があるときだけ持つ。名前やラベルだけを見る問い合わせで
    /// 列を組み立てても使わない。
    private let columns: [ResourceColumn]

    init(query: String, target: ResourceTarget) {
        let terms = SearchTerm.parse(query)
        self.terms = terms
        let needsColumns = terms.contains {
            if case .free = $0 { return true }
            return false
        }
        guard needsColumns else {
            columns = []
            return
        }
        switch target {
        case .builtIn(let kind):
            columns = ResourceTable.columns(for: kind, showNamespace: false)
        case .custom(let type):
            columns = ResourceTable.columns(for: type, showNamespace: false)
        }
    }

    /// 語が 1 つも無い＝何も絞らない。呼び出し側は元の配列をそのまま使える。
    var isEmpty: Bool { terms.isEmpty }

    func matches(_ object: K8sObject) -> Bool {
        // **空白区切りは AND。** `app=web crash` のように「絞ってから探す」の
        // が絞り込みのふつうの使い方で、OR にすると項目を足すほど増えていく。
        terms.allSatisfy { matches(object, term: $0) }
    }

    private func matches(_ object: K8sObject, term: SearchTerm) -> Bool {
        switch term {
        case .free(let needle):
            if object.name.lowercased().contains(needle) { return true }
            if object.namespace?.lowercased().contains(needle) == true { return true }
            if object.labels.contains(where: {
                $0.key.lowercased().contains(needle) || $0.value.lowercased().contains(needle)
            }) {
                return true
            }
            return columns.contains { $0.value(object).text.lowercased().contains(needle) }

        case .label(let key, let value):
            guard let found = object.labels.first(where: {
                $0.key.lowercased() == key
            }) else { return false }
            // `app=` は「そのラベルを持つもの」。値まで求めない。
            guard let value else { return true }
            // **値は完全一致。** ラベルはセレクタの語彙なので、`env=prod` が
            // `env=production` を拾うと絞り込んだつもりで絞れていない。
            return found.value.lowercased() == value

        case .field(let field, let needle):
            switch field {
            case .namespace:
                return object.namespace?.lowercased().contains(needle) == true
            case .status:
                return StatusResolver.status(for: object).text.lowercased().contains(needle)
            case .node:
                return object.spec?["nodeName"]?.stringValue?.lowercased()
                    .contains(needle) == true
            }
        }
    }
}

// MARK: - 検索語

/// 絞り込みの 1 項目。
///
/// **素の部分一致だけでは足りない。** Kubernetes はラベルで全部が動くのに、
/// 名前の一部でしか探せないと「この Deployment の Pod だけ」が出せない。
/// かといって本物のセレクタ（`in`、`notin`、`!key`）まで実装すると、
/// 絞り込み欄 1 つのために式の評価を背負うことになる。**よく打つ形だけ**を
/// 見て、それ以外は素の文字として扱う。
enum SearchTerm: Equatable, Sendable {
    /// 素の文字。名前・Namespace・ラベル・各セルの表示文字列を見る。
    case free(String)
    /// `app=nginx`。値が nil（`app=`）なら「そのラベルを持つもの」。
    case label(key: String, value: String?)
    /// `ns:kube-system` のように場所を指定したもの。
    case field(Field, String)

    enum Field: Sendable {
        case namespace
        case status
        case node

        /// 打ちやすい別名を受ける。**知らない語は場所として扱わない** —
        /// `nginx:1.21` のような素の文字を絞り込みの指定と取り違えないため。
        init?(keyword: String) {
            switch keyword {
            case "ns", "namespace": self = .namespace
            case "status", "state": self = .status
            case "node": self = .node
            default: return nil
            }
        }
    }

    /// 空白で区切って 1 語ずつ読む。
    static func parse(_ query: String) -> [SearchTerm] {
        query.split(whereSeparator: \.isWhitespace).compactMap { token in
            let text = token.lowercased()
            guard !text.isEmpty else { return nil }

            // `=` はラベル。名前に `=` はまず入らない。
            if let separator = text.firstIndex(of: "="), separator != text.startIndex {
                let key = String(text[..<separator])
                let value = String(text[text.index(after: separator)...])
                return .label(key: key, value: value.isEmpty ? nil : value)
            }

            // `:` は場所の指定。ただし知らない語なら素の文字に落とす
            // （`nginx:1.21` を「nginx という場所」と読まないため）。
            if let separator = text.firstIndex(of: ":"),
               separator != text.startIndex,
               let field = Field(keyword: String(text[..<separator])) {
                let value = String(text[text.index(after: separator)...])
                guard !value.isEmpty else { return nil }
                return .field(field, value)
            }

            return .free(text)
        }
    }
}
