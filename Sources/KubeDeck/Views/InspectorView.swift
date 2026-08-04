import SwiftUI

struct InspectorView: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.openWindow) private var openWindow

    private enum Tab: String, CaseIterable, Identifiable {
        case summary
        /// **状態の「なぜ」はここにしかない。** 一覧の STATUS 列も概要の
        /// リングも「異常である」ことまでしか言わず、`FailedScheduling` の
        /// 理由や `Failed to pull image` の中身はイベントにしか出ない。
        case events
        case settings
        case yaml

        var id: String { rawValue }
        var title: String {
            switch self {
            case .summary: return "概要"
            case .events: return "イベント"
            case .settings: return "設定"
            case .yaml: return "YAML"
            }
        }
    }

    @State private var tab: Tab = .summary

    var body: some View {
        Group {
            if let object = store.selectedObject {
                content(for: object)
            } else if let target = store.currentTarget {
                // 一覧を見ているときは、その一覧の内訳を出す。行を選ぶまで
                // 空けておくと画面の 1/4 が遊ぶうえ、内訳はどの画面にも出ていない。
                ListSummaryPane(target: target)
            } else {
                ClusterSummaryPane()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for object: K8sObject) -> some View {
        VStack(spacing: 0) {
            // **どれの話をしているかを言う。** 複数選んでいると一覧は何行も
            // 光っているのに、ここは 1 つぶんしか出ない。断りが無いと、
            // 選択と詳細が食い違っているように見える。
            if store.selectedObjectIDs.count > 1 {
                HStack(spacing: 6) {
                    Image(systemName: "checklist")
                        .font(.caption)
                    Text("\(store.selectedObjectIDs.count) 件を選択中。詳細はこの 1 件です。")
                        .font(.caption)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
            }
            header(for: object)
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)

            switch tab {
            case .summary:
                SummaryPane(object: object)
            case .events:
                // 選択が変わったら引き直す。id を付けないと前の対象の
                // イベントが残り、いま選んでいるものの話に見える。
                EventsPane(object: object).id(object.id)
            case .settings:
                SettingsDigestView(object: object)
            case .yaml:
                // 選択が変わったら読み直す。id を付けないと前の YAML が残る。
                YAMLPane(object: object).id(object.id)
            }
        }
    }

    private func header(for object: K8sObject) -> some View {
        let status = StatusResolver.status(for: object)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: object.kind?.symbol ?? "questionmark.square")
                    .foregroundStyle(.secondary)
                Text(object.name)
                    .font(.headline)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if !status.text.isEmpty {
                    StatusBadge(status: status)
                }
                if let namespace = object.namespace {
                    Text(namespace)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if object.kind == .pod {
                    Button {
                        store.showLogs(for: object)
                    } label: {
                        Label("ログ", systemImage: "text.alignleft")
                    }
                    .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }
}

struct StatusBadge: View {
    let status: ResourceStatus

    var body: some View {
        Label(status.text, systemImage: status.level.symbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(Palette.textColor(for: status.level))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(Palette.color(for: status.level).opacity(0.14)))
    }
}

// MARK: - 概要タブ

private struct SummaryPane: View {
    @Environment(ClusterStore.self) private var store
    let object: K8sObject

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let usage = store.metrics.usage(for: object) {
                    InfoSection(title: "使用量") {
                        usageMeters(usage)
                    }
                }

                if let endpoint = store.prometheus,
                   object.kind == .pod || object.kind == .node {
                    InfoSection(title: "推移（30 分）") {
                        MetricsHistoryRow(
                            title: "CPU", series: store.selectedHistory.cpu,
                            tint: Palette.seriesCPU,
                            format: { Quantity.formatCPU(cores: $0) })
                        MetricsHistoryRow(
                            title: "メモリ", series: store.selectedHistory.memory,
                            tint: Palette.seriesMemory,
                            format: { Quantity.formatMemory(bytes: $0) })
                        Text(endpoint.display)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                InfoSection(title: "基本") {
                    ForEach(basicRows, id: \.0) { row in
                        InfoRow(label: row.0, value: row.1)
                    }
                }

                if let containers = containerList, !containers.isEmpty {
                    InfoSection(title: "コンテナ") {
                        ForEach(containers, id: \.name) { container in
                            ContainerRow(container: container)
                        }
                    }
                }

                if !conditions.isEmpty {
                    InfoSection(title: "条件") {
                        ForEach(conditions, id: \.type) { condition in
                            ConditionRow(condition: condition)
                        }
                    }
                }

                if !object.labels.isEmpty {
                    InfoSection(title: "ラベル") {
                        ChipCloud(entries: object.labels)
                    }
                }

                if !object.annotations.isEmpty {
                    InfoSection(title: "アノテーション") {
                        ChipCloud(entries: object.annotations, truncatesValues: true)
                    }
                }
            }
            .padding(14)
        }
    }

    /// Pod は requests との比、Node は割り当て可能量との比を分母にする。
    /// 分母が無いときは棒を出さず数字だけにする（0% と描くと使い切っていないと読める）。
    @ViewBuilder
    private func usageMeters(_ usage: ResourceUsage) -> some View {
        if object.kind == .node {
            let base = object.nodeAllocatable
            nodeMeter(
                "CPU", used: usage.cpuCores, base: base.cpuCores,
                format: { Quantity.formatCPU(cores: $0) })
            nodeMeter(
                "メモリ", used: usage.memoryBytes, base: base.memoryBytes,
                format: { Quantity.formatMemory(bytes: $0) })
        } else {
            let requests = object.containerResourceTotal("requests")
            let limits = object.containerResourceTotal("limits")
            podMeter(
                "CPU", used: usage.cpuCores,
                request: requests.cpuCores, limit: limits.cpuCores,
                format: { Quantity.formatCPU(cores: $0) })
            podMeter(
                "メモリ", used: usage.memoryBytes,
                request: requests.memoryBytes, limit: limits.memoryBytes,
                format: { Quantity.formatMemory(bytes: $0) })
        }

        if object.kind == .pod, let perContainer = containerUsage, perContainer.count > 1 {
            Divider().padding(.vertical, 2)
            ForEach(perContainer.keys.sorted(), id: \.self) { name in
                if let usage = perContainer[name] {
                    HStack(spacing: 8) {
                        Text(name)
                            .font(.caption2)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        Text(Quantity.formatCPU(cores: usage.cpuCores))
                            .font(.caption2).monospacedDigit()
                        Text(Quantity.formatMemory(bytes: usage.memoryBytes))
                            .font(.caption2).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

    }

    private func nodeMeter(
        _ title: String, used: Double, base: Double, format: (Double) -> String
    ) -> UsageMeter {
        UsageMeter(
            title: title,
            used: format(used),
            total: base > 0 ? "割り当て可能 \(format(base))" : "",
            ratio: Quantity.ratio(used, of: base))
    }

    /// **上限を分母にする。** 要求は「置き場所を決めるための申告」であって上限では
    /// ないので、要求を超えていること自体は異常ではない。実際、要求 4.1Gi / 上限
    /// 9.0Gi の Pod が 4.8Gi 使っているだけで赤くなり、**健全な Pod が異常に見えた。**
    /// 殺されるのは上限を超えたとき（メモリなら OOMKilled、CPU ならスロットル）なので、
    /// 棒と色はそこまでの距離を表す。要求は棒の上の目盛りに置いて関係を残す。
    ///
    /// 上限が無いときだけ要求を分母にする。そのときは「上限 未設定」を橙で出す
    /// （ノードの空きまで伸びられる、という別の話になる）。
    private func podMeter(
        _ title: String, used: Double, request: Double, limit: Double,
        format: (Double) -> String
    ) -> UsageMeter {
        if limit > 0 {
            return UsageMeter(
                title: title,
                used: format(used),
                total: "上限 \(format(limit))",
                ratio: Quantity.ratio(used, of: limit),
                note: request > 0
                    ? "要求 \(format(request))"
                        + "（\(Quantity.formatPercent(used / request)) 使用）"
                    : "要求 未設定（置き場所を決める根拠がありません）",
                noteLevel: request > 0 ? nil : .warning,
                marker: min(1, request / limit))
        }
        return UsageMeter(
            title: title,
            used: format(used),
            total: request > 0 ? "要求 \(format(request))" : "",
            ratio: Quantity.ratio(used, of: request),
            note: "上限 未設定（ノードの空きまで使えます）",
            noteLevel: .warning)
    }

    private var denominator: ResourceUsage {
        switch object.kind {
        case .node: return object.nodeAllocatable
        // limits より requests を分母にする。limits は未設定のことが多く、
        // 設定されていても「上限まで使ってよい」意味ではないため。
        case .pod: return object.containerResourceTotal("requests")
        default: return ResourceUsage()
        }
    }

    private var containerUsage: [String: ResourceUsage]? {
        let key = MetricsSnapshot.key(namespace: object.namespace, name: object.name)
        return store.metrics.containers[key]
    }

    private var basicRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let kind = object.kind { rows.append(("種別", kind.displayName)) }
        if let namespace = object.namespace { rows.append(("Namespace", namespace)) }
        if let created = object.creationTimestamp {
            rows.append(("作成", created.formatted(date: .numeric, time: .shortened)))
            rows.append(("経過", object.age))
        }
        if !object.uid.isEmpty { rows.append(("UID", object.uid)) }

        switch object.kind {
        case .pod:
            if let node = object.spec?["nodeName"]?.stringValue { rows.append(("ノード", node)) }
            if let ip = object.status?["podIP"]?.stringValue { rows.append(("Pod IP", ip)) }
            if let sa = object.spec?["serviceAccountName"]?.stringValue {
                rows.append(("ServiceAccount", sa))
            }
            rows.append(("再起動", "\(StatusResolver.podRestarts(object))"))
        case .service:
            rows.append(("種類", object.spec?["type"]?.stringValue ?? "ClusterIP"))
            rows.append(("Cluster IP", object.spec?["clusterIP"]?.stringValue ?? ""))
            rows.append(("ポート", ResourceTable.servicePorts(object)))
        case .node:
            if let info = object.status?["nodeInfo"] {
                rows.append(("kubelet", info["kubeletVersion"]?.stringValue ?? ""))
                rows.append(("OS", info["osImage"]?.stringValue ?? ""))
                rows.append(("ランタイム", info["containerRuntimeVersion"]?.stringValue ?? ""))
                rows.append(("アーキテクチャ", info["architecture"]?.stringValue ?? ""))
            }
            rows.append(("内部 IP", StatusResolver.nodeInternalIP(object)))
            if let capacity = object.status?["capacity"] {
                rows.append(("CPU", capacity["cpu"]?.displayText ?? ""))
                rows.append(("メモリ", capacity["memory"]?.displayText ?? ""))
                rows.append(("Pod 上限", capacity["pods"]?.displayText ?? ""))
            }
        case .deployment, .statefulSet, .replicaSet, .daemonSet:
            let status = StatusResolver.status(for: object)
            rows.append(("Ready", status.text))
            if let strategy = object.spec?.path("strategy.type")?.stringValue {
                rows.append(("更新方式", strategy))
            }
        case .persistentVolumeClaim:
            rows.append(("容量", object.status?.path("capacity.storage")?.displayText ?? ""))
            rows.append(("アクセス", ResourceTable.accessModes(object)))
            rows.append(("StorageClass", object.spec?["storageClassName"]?.stringValue ?? ""))
        case .event:
            rows.append(("対象", ResourceTable.eventTarget(object)))
            rows.append(("理由", object.raw["reason"]?.stringValue ?? ""))
            rows.append(("回数", "\(object.raw["count"]?.intValue ?? 1)"))
            rows.append(("内容", ResourceTable.eventMessage(object)))
        default:
            break
        }
        return rows.filter { !$0.1.isEmpty }
    }

    struct ContainerInfo {
        let name: String
        let image: String
        let ready: Bool?
        let restarts: Int?
        let state: String?
    }

    /// Pod は status から、ワークロードは template から拾う。
    private var containerList: [ContainerInfo]? {
        let specs = object.spec?["containers"]?.arrayValue
            ?? object.spec?.path("template.spec.containers")?.arrayValue
        guard let specs, !specs.isEmpty else { return nil }

        let statuses = object.status?["containerStatuses"]?.arrayValue ?? []
        return specs.map { spec in
            let name = spec["name"]?.stringValue ?? ""
            let status = statuses.first { $0["name"]?.stringValue == name }
            return ContainerInfo(
                name: name,
                image: spec["image"]?.stringValue ?? "",
                ready: status?["ready"]?.boolValue,
                restarts: status?["restartCount"]?.intValue,
                state: status?["state"]?.objectValue.keys.first)
        }
    }

    struct ConditionInfo {
        let type: String
        let status: String
        let reason: String
        let message: String
    }

    private var conditions: [ConditionInfo] {
        (object.status?["conditions"]?.arrayValue ?? []).map { condition in
            ConditionInfo(
                type: condition["type"]?.stringValue ?? "",
                status: condition["status"]?.stringValue ?? "",
                reason: condition["reason"]?.stringValue ?? "",
                message: condition["message"]?.stringValue ?? "")
        }
    }
}

private struct InfoSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                content
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.caption)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ContainerRow: View {
    let container: SummaryPane.ContainerInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if let ready = container.ready {
                    Image(systemName: ready ? StatusLevel.good.symbol : StatusLevel.critical.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.color(for: ready ? .good : .critical))
                }
                Text(container.name)
                    .font(.caption.weight(.medium))
                Spacer(minLength: 6)
                if let state = container.state {
                    Text(state)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let restarts = container.restarts, restarts > 0 {
                    Text("再起動 \(restarts)")
                        .font(.caption2)
                        .foregroundStyle(Palette.textColor(for: restarts >= 5 ? .critical : .warning))
                }
            }
            Text(container.image)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.subtleFill, in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ConditionRow: View {
    let condition: SummaryPane.ConditionInfo

    private var level: StatusLevel {
        // Ready=True は正常、Pressure 系は True が異常。型で意味が反転する。
        let isNegativeCondition = condition.type.hasSuffix("Pressure")
            || condition.type == "NetworkUnavailable"
            || condition.type == "Failed"
        switch condition.status {
        case "True": return isNegativeCondition ? .critical : .good
        case "False": return isNegativeCondition ? .good : .serious
        default: return .warning
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: level.symbol)
                .font(.system(size: 9))
                .foregroundStyle(Palette.color(for: level))
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(condition.type).font(.caption.weight(.medium))
                    Text(condition.status).font(.caption2).foregroundStyle(.secondary)
                }
                if !condition.message.isEmpty {
                    Text(condition.message)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if !condition.reason.isEmpty {
                    Text(condition.reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ChipCloud: View {
    let entries: [String: String]
    var truncatesValues = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(entries.keys.sorted(), id: \.self) { key in
                HStack(alignment: .top, spacing: 6) {
                    Text(key)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(value(for: key))
                        .font(.caption2)
                        .textSelection(.enabled)
                        .lineLimit(truncatesValues ? 2 : nil)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Palette.subtleFill, in: RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    private func value(for key: String) -> String {
        let raw = entries[key] ?? ""
        // last-applied-configuration は本文がまるごと入っていて、
        // 出しても読めない。存在だけ示す。
        guard truncatesValues, raw.count > 240 else { return raw }
        return String(raw.prefix(240)) + "…"
    }
}

// MARK: - イベントタブ

/// 選択中のオブジェクトに紐づくイベント。
///
/// **一覧の STATUS 列と役割が違う。** あちらは「いま何であるか」、こちらは
/// 「なぜそうなったか」。`Pending` の理由（`FailedScheduling: insufficient cpu`）も
/// `CrashLoopBackOff` の発端（`Failed to pull image`）も、イベントにしか出ない。
private struct EventsPane: View {
    @Environment(ClusterStore.self) private var store
    let object: K8sObject

    /// nil は「まだ引いていない」。空配列は「引いたが 0 件」。
    /// **同じものとして持たない** — 読み込み中と 0 件は別の表示にする。
    @State private var events: [K8sObject]?
    @State private var failure: String?
    @State private var isReloading = false

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            // 失敗したときも出す。出さないと引き直す手段が無くなる。
            if events != nil || failure != nil {
                Divider()
                footer
            }
        }
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let failure {
            // **「ありません」と言わない。** 引けなかっただけで、
            // 無いことは確かめていない。
            ContentUnavailableView {
                Label("イベントを取得できません", systemImage: "exclamationmark.triangle")
            } description: {
                Text(failure).textSelection(.enabled)
            }
        } else if let events {
            if events.isEmpty {
                emptyState
            } else {
                list(events)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// **黙って「ありません」で終えない。** イベントには寿命があり（既定で
    /// 1 時間）、古い出来事は本当に消える。断りが無いと「何も起きていない」と
    /// 読めるが、実際は「もう残っていない」かもしれない。
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("イベントはありません。", systemImage: "bell.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("イベントはしばらく（クラスタの既定で 1 時間）で消えます。"
                 + "それより前の出来事はクラスタに残っていません。")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private func list(_ events: [K8sObject]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().padding(.leading, 16) }
                    row(event)
                }
            }
        }
    }

    /// 概要のイベント行と同じ作り（左端 2pt の帯）。ただし**対象は書かない** —
    /// 選んでいるもの自身なので、見出しと同じ名前を 2 度出すことになる。
    /// 代わりに本文は折り返す。ここでは中身そのものが読みたいもの。
    private func row(_ event: K8sObject) -> some View {
        let status = StatusResolver.status(for: event)
        let count = event.raw["count"]?.intValue ?? 1

        return HStack(alignment: .top, spacing: 10) {
            Rectangle()
                .fill(
                    status.level == .neutral
                        ? Color.clear : Palette.color(for: status.level))
                .frame(width: 2)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(event.raw["reason"]?.stringValue ?? "")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    // 繰り返されたことは回数にしか出ない。同じ行が
                    // 1 度きりなのか 200 回目なのかで意味がまるで違う。
                    if count > 1 {
                        Text("×\(count)")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(ResourceTable.age(of: event, kind: .event))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }

                Text(ResourceTable.eventMessage(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let events, !events.isEmpty {
                Text("\(events.count) 件")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("再読み込み") {
                Task { await load(again: true) }
            }
            .disabled(isReloading)
        }
        .controlSize(.small)
        .padding(10)
        .background(.bar)
    }

    /// 引き直すときは前の結果を消さない。消すと一覧が一瞬空になり、
    /// 「0 件になった」ように見える。
    private func load(again: Bool = false) async {
        if again { isReloading = true }
        defer { isReloading = false }

        switch await store.events(for: object) {
        case .success(let value):
            events = value
            failure = nil
        case .failure(let error):
            failure = error.localizedDescription
        }
    }
}

// MARK: - YAML タブ

private struct YAMLPane: View {
    @Environment(ClusterStore.self) private var store
    let object: K8sObject

    @State private var text: String?
    @State private var failure: String?
    @State private var wraps = true

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView(
                    "YAML を取得できません",
                    systemImage: "exclamationmark.triangle",
                    description: Text(failure))
            } else if let text {
                ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
                    Text(text)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: !wraps, vertical: false)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .safeAreaInset(edge: .bottom) {
                    HStack(spacing: 8) {
                        // 狭いパネルで折り返さないと、1 行が収まらず横スクロールばかりになる。
                        Toggle("折り返し", isOn: $wraps)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                        Spacer()
                        Button("コピー") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                    }
                    .controlSize(.small)
                    .padding(10)
                    .background(.bar)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            switch await store.yaml(for: object) {
            case .success(let value): text = value
            case .failure(let error): failure = error.localizedDescription
            }
        }
    }
}

// MARK: - 選択が無いとき

/// クラスタの要約。一覧で何も選んでいないときに詳細パネルへ出す。
private struct ClusterSummaryPane: View {
    @Environment(ClusterStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                InfoSection(title: "クラスタ") {
                    ForEach(clusterRows, id: \.0) { row in
                        InfoRow(label: row.0, value: row.1)
                    }
                }

                let concerns = concerningReasons
                if !store.hasOverviewData {
                    // 概要を開くまでクラスタ全体は数えていない。黙って
                    // 「問題なし」と出すと、見ていないものを見たことにしてしまう。
                    Text("クラスタ全体の状態は「概要」を開くと集計されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if concerns.isEmpty {
                    Label("気になる状態はありません。", systemImage: StatusLevel.good.symbol)
                        .font(.caption)
                        .foregroundStyle(Palette.textColor(for: .good))
                } else {
                    InfoSection(title: "気になる状態") {
                        ForEach(concerns) { reason in
                            HStack(spacing: 7) {
                                Image(systemName: reason.level.symbol)
                                    .font(.system(size: 9))
                                    .foregroundStyle(Palette.color(for: reason.level))
                                Text(reason.displayName)
                                    .font(.caption)
                                Spacer(minLength: 8)
                                Text("\(reason.count)")
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(14)
        }
    }

    /// **本文と同じことを書かない。** コンテキスト名と状態は概要の見出しが、
    /// 件数はサイドバーが、Namespace はツールバーが持っている。
    /// ここに残すのは、どこにも出ていないものだけ。
    private var clusterRows: [(String, String)] {
        var rows: [(String, String)] = []
        if !store.serverVersion.isEmpty { rows.append(("バージョン", store.serverVersion)) }
        rows.append((
            "自動更新",
            store.autoRefresh ? "\(Int(store.refreshInterval)) 秒ごと" : "停止中"))
        if let lastUpdated = store.lastUpdated {
            rows.append(("最終更新", lastUpdated.formatted(date: .omitted, time: .standard)))
        }
        return rows.filter { !$0.1.isEmpty }
    }

    /// 概要で数えた内訳のうち、正常でないもの。
    private var concerningReasons: [ReasonCount] {
        (store.overview.pods.reasons + store.overview.nodes.reasons
            + store.overview.workloads.reasons)
            .filter { $0.level != .good && $0.level != .neutral }
            .sorted { $0.level.severityOrder < $1.level.severityOrder }
    }
}


// MARK: - 一覧の内訳

/// 行を選んでいないときの右パネル。いま出ている一覧を要約する。
///
/// 数えるのは `filteredObjects`。検索で絞り込んでいるなら、その結果を数える。
/// 画面に出ていないものを数えると、内訳と一覧の行数が食い違う。
private struct ListSummaryPane: View {
    @Environment(ClusterStore.self) private var store
    let target: ResourceTarget

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if objects.isEmpty {
                    Text("表示するものがありません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    // カードと違い、ここは畳む理由がない。1 種類でも出す。
                    InfoSection(title: "状態") {
                        ForEach(tally.buckets) { bucket in
                            countRow(
                                label: bucket.label, count: bucket.count,
                                level: bucket.level)
                        }
                    }

                    let notable = tally.reasons.filter { $0.level != .good && $0.level != .neutral }
                    if !notable.isEmpty {
                        InfoSection(title: "内訳") {
                            ForEach(notable) { reason in
                                countRow(
                                    label: reason.reason, count: reason.count,
                                    level: reason.level)
                            }
                        }
                    }

                    if namespaceCounts.count > 1 {
                        InfoSection(title: "Namespace 別") {
                            ForEach(namespaceCounts, id: \.name) { entry in
                                countRow(label: entry.name, count: entry.count, level: nil)
                            }
                        }
                    }
                }

                Text("行を選ぶと、ここに詳細と YAML が出ます。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: target.symbol)
                .foregroundStyle(.secondary)
            Text(target.displayName)
                .font(.headline)
            Spacer(minLength: 6)
            Text("\(objects.count) 件")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func countRow(label: String, count: Int, level: StatusLevel?) -> some View {
        HStack(spacing: 7) {
            if let level {
                Image(systemName: level.symbol)
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.color(for: level))
            }
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text("\(count)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var objects: [K8sObject] { store.filteredObjects }

    private var tally: StatusTally { StatusTally.make(from: objects) }

    /// 件数の多い順。同数なら名前順。
    private var namespaceCounts: [(name: String, count: Int)] {
        Dictionary(grouping: objects.compactMap(\.namespace), by: { $0 })
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
}
