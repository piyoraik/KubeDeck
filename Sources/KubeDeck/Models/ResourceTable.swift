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
        }
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

    /// 一覧の検索ボックス。名前とラベル、それに各セルの表示文字列を対象にする。
    static func matches(_ object: K8sObject, target: ResourceTarget, query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return true }
        if object.name.lowercased().contains(needle) { return true }
        if object.namespace?.lowercased().contains(needle) == true { return true }
        if object.labels.contains(where: {
            $0.key.lowercased().contains(needle) || $0.value.lowercased().contains(needle)
        }) {
            return true
        }
        let columns: [ResourceColumn]
        switch target {
        case .builtIn(let kind): columns = self.columns(for: kind, showNamespace: false)
        case .custom(let type): columns = self.columns(for: type, showNamespace: false)
        }
        return columns.contains { $0.value(object).text.lowercased().contains(needle) }
    }

}
