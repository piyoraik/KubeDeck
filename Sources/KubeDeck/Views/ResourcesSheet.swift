import SwiftUI

/// requests / limits を直す専用の画面。
///
/// **YAML の自由編集だけにしない。** ここはいちばん頻繁に触る値なのに、
/// YAML では**いちばん危ない直し方**になる（インデントを 1 つ間違えれば
/// 別の場所に書き込む）。項目を決めて出せば、間違えようがない形にできる。
///
/// **数字を当てずっぽうで入れさせない。** 上限を決めるのに要るのは
/// 「いまどれだけ使っているか」で、それはこのアプリがすでに持っている。
/// 欄の隣に出し、**上限が実測を下回るときは押す前に言う**（メモリなら
/// そのまま OOMKilled になる）。
struct ResourcesSheet: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let object: K8sObject

    @State private var containers: [ContainerResources] = []
    @State private var selection: ContainerResources.ID?
    @State private var cpuRequest = ""
    @State private var memoryRequest = ""
    @State private var cpuLimit = ""
    @State private var memoryLimit = ""
    /// コンテナ名 → その Pod たちの使用量。nil は「取得元が無い」。
    @State private var usage: [String: [ResourceUsage]]?
    @State private var dryRunMessage: String?
    @State private var failure: String?
    @State private var isChecking = false
    @State private var isApplying = false

    private var current: ContainerResources? {
        containers.first { $0.id == selection }
    }

    private var changes: [ResourcePatch.Change] {
        guard let current else { return [] }
        return ResourcePatch.changes(
            from: current, cpuRequest: cpuRequest, memoryRequest: memoryRequest,
            cpuLimit: cpuLimit, memoryLimit: memoryLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let managedBy = ManagedBy.detect(object) {
                Label(managedBy.warning, systemImage: StatusLevel.serious.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .serious))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if containers.count > 1 {
                Picker("コンテナ", selection: $selection) {
                    ForEach(containers) { container in
                        // **初期化コンテナを見分けられるようにする。**
                        // 同じ名前で並ぶことがあるし、効く場面が違う。
                        Text(container.isInit ? "\(container.name)（初期化）" : container.name)
                            .tag(ContainerResources.ID?.some(container.id))
                    }
                }
                .pickerStyle(.menu)
            }

            fields

            Divider()

            summary

            HStack {
                Spacer()
                Button("やめる", role: .cancel) { dismiss() }
                    .disabled(isApplying)
                Button("適用") {
                    Task { await apply() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(changes.isEmpty || isApplying)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await load() }
        // コンテナを選び直したら、欄をそのコンテナの値に入れ替える。
        .onChange(of: selection) { _, _ in fillFields() }
        // 打つたびに聞きに行かない。**手が止まってから**サーバに聞く。
        .task(id: changes.map(\.summary).joined(separator: "|")) {
            await checkAfterPause()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("資源の割り当てを変える")
                .font(.headline)
            HStack(spacing: 6) {
                Image(systemName: object.kind?.symbol ?? "square")
                    .foregroundStyle(.secondary)
                Text(object.name)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let namespace = object.namespace {
                    Text(namespace).font(.caption).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - 欄

    private var fields: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            GridRow {
                Text("").gridCellUnsizedAxes(.horizontal)
                Text("要求").font(.caption).foregroundStyle(.secondary)
                Text("上限").font(.caption).foregroundStyle(.secondary)
                Text("いま").font(.caption).foregroundStyle(.secondary)
            }
            row(
                title: "CPU", request: $cpuRequest, limit: $cpuLimit,
                placeholder: "100m",
                observed: observed(\.cpuCores), format: { Quantity.formatCPU(cores: $0) })
            row(
                title: "メモリ", request: $memoryRequest, limit: $memoryLimit,
                placeholder: "128Mi",
                observed: observed(\.memoryBytes), format: { Quantity.formatMemory(bytes: $0) })
        }
    }

    private func row(
        title: String, request: Binding<String>, limit: Binding<String>,
        placeholder: String, observed: Double?, format: (Double) -> String
    ) -> some View {
        GridRow {
            Text(title).font(.callout)
            // **空欄を「0」と読ませない。** placeholder は「未設定」と書く。
            TextField("未設定", text: request, prompt: Text("未設定"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            TextField("未設定", text: limit, prompt: Text("未設定"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 110)
            if let observed {
                Text(format(observed))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else if usage == nil {
                // 取得元そのものが無いときは、何も言わない（列を出さないのと同じ）。
                Text("").font(.caption)
            } else {
                // 取得元はあるのに引けなかった。**0 と書かない。**
                Text("—").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .help("空にすると外します（未設定に戻します）。例: \(placeholder)")
    }

    /// そのコンテナを持つ Pod のうち、いちばん使っているもの。
    /// **平均にしない** — 上限は「いちばん食う Pod」で決まる。
    private func observed(_ key: KeyPath<ResourceUsage, Double>) -> Double? {
        guard let current, let samples = usage?[current.name], !samples.isEmpty else {
            return nil
        }
        return samples.map { $0[keyPath: key] }.max()
    }

    // MARK: - 変更の要約とサーバの答え

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if changes.isEmpty {
                Text("変更はありません。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(changes, id: \.field.rawValue) { change in
                    Text("・" + change.summary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // **上限を実測より下げようとしていることを、押す前に言う。**
            // メモリならそのまま OOMKilled になる。
            if let warning = tooLowWarning {
                Label(warning, systemImage: StatusLevel.warning.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .warning))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let failure {
                Label(failure, systemImage: StatusLevel.critical.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .critical))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let dryRunMessage {
                HStack(spacing: 6) {
                    if isChecking { ProgressView().controlSize(.small) }
                    Label("サーバに聞きました: \(dryRunMessage)", systemImage: StatusLevel.good.symbol)
                        .font(.caption)
                        .foregroundStyle(Palette.textColor(for: .good))
                }
            } else if isChecking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("確かめています…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tooLowWarning: String? {
        guard let current, let samples = usage?[current.name], !samples.isEmpty else {
            return nil
        }
        let memoryPeak = samples.map(\.memoryBytes).max() ?? 0
        if let limit = Quantity.parse(memoryLimit.trimmingCharacters(in: .whitespaces)),
           limit > 0, memoryPeak > limit {
            return "メモリの上限が、いま使っている量"
                + "（\(Quantity.formatMemory(bytes: memoryPeak))）を下回ります。"
                + "このまま当てると OOMKilled になります。"
        }
        let cpuPeak = samples.map(\.cpuCores).max() ?? 0
        if let limit = Quantity.parse(cpuLimit.trimmingCharacters(in: .whitespaces)),
           limit > 0, cpuPeak > limit {
            return "CPU の上限が、いま使っている量"
                + "（\(Quantity.formatCPU(cores: cpuPeak))）を下回ります。"
                + "落ちはしませんが、そのぶん遅くなります（スロットル）。"
        }
        return nil
    }

    // MARK: - 取得と適用

    private func load() async {
        containers = ResourcePatch.containers(of: object)
        selection = containers.first?.id
        fillFields()
        usage = await store.containerUsage(for: object)
    }

    private func fillFields() {
        guard let current else { return }
        cpuRequest = current.cpuRequest ?? ""
        memoryRequest = current.memoryRequest ?? ""
        cpuLimit = current.cpuLimit ?? ""
        memoryLimit = current.memoryLimit ?? ""
        dryRunMessage = nil
        failure = nil
    }

    /// **打っている最中に投げない。** 1 文字ごとに kubectl を起こすことになる。
    /// 少し待ってから、それでも同じ内容ならサーバに聞く。
    private func checkAfterPause() async {
        dryRunMessage = nil
        failure = nil
        guard !changes.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        isChecking = true
        defer { isChecking = false }
        await send(dryRun: true)
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }
        if await send(dryRun: false) { dismiss() }
    }

    @discardableResult
    private func send(dryRun: Bool) async -> Bool {
        guard let current,
              let patch = ResourcePatch.patch(
                kind: object.kind, container: current, changes: changes)
        else { return false }

        switch await store.patchResources(object, patch: patch, dryRun: dryRun) {
        case .success(let message):
            dryRunMessage = message
            failure = nil
            return true
        case .failure(let error):
            dryRunMessage = nil
            failure = error.localizedDescription
            return false
        }
    }
}
