import SwiftUI

struct RootView: View {
    @Environment(ClusterStore.self) private var store
    @State private var showsInspector = true
    /// ログパネルの高さ。仕切りのドラッグで変わる。
    @State private var logHeight: CGFloat = 280
    /// エラーの元の文言を開いているか。既定は畳んでおく。
    @State private var showsErrorDetail = false

    var body: some View {
        @Bindable var store = store

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 300)
        } detail: {
            detailWithLogs
                .navigationTitle(title)
                .navigationSubtitle(subtitle)
                .toolbar { toolbar }
                // 詳細パネルの出し入れを選択に連動させない。連動させると、
                // 左で種別を選んだ瞬間にパネルが現れ、AppKit がその列を作るために
                // ウインドウごと広げる（選ぶたびに窓の幅が変わる）。出す / 畳むは
                // ツールバーのボタンだけが決める。
                .inspector(isPresented: $showsInspector) {
                    InspectorView()
                        .inspectorColumnWidth(min: 300, ideal: 360, max: 560)
                }
        }
        .overlay(alignment: .bottom) { errorBar }
    }

    // MARK: - 本体

    /// ログは一覧の下に積む。掴んで高さを変えられる。
    ///
    /// **`VSplitView` を使わない。** `NavigationSplitView` と `.inspector` で
    /// すでに 2 つの `NSSplitView` が入れ子になっており、そこへ 3 つ目を足して
    /// 出し入れすると、レイアウト中に AppKit が例外を投げて落ちる
    /// （`-[NSView _layoutSubtreeWithOldSize:]` → `_crashOnException:`）。
    /// 高さは自分で持ち、仕切りは自前のドラッグにする。
    private var detailWithLogs: some View {
        detail
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let request = store.logRequest {
                    VStack(spacing: 0) {
                        LogPanelHandle(height: $logHeight)
                        LogPanel(request: request)
                    }
                    .frame(height: logHeight)
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        if let message = store.setupErrorMessage {
            SetupErrorView(message: message)
        } else {
            switch store.selection {
            case .overview:
                OverviewView()
            case .resource(let target):
                ResourceListView(target: target)
            }
        }
    }

    private var title: String {
        switch store.selection {
        case .overview: return "概要"
        case .resource(let target): return target.displayName
        }
    }

    /// 副題にはコンテキストと Namespace を書かない。ツールバーのメニューが
    /// 同じことを言っており、二重に出すとどちらが操作対象か紛れる。
    ///
    /// 取得中の合図もここに出す。**ツールバーには置かない。** 独立した項目に
    /// すると隠しても枠が縦棒として残り、Menu のラベルに `ProgressView` を
    /// 入れてもツールバーでは描画されず、アイコンが空のボタンになる。
    private var subtitle: String {
        if store.isLoading { return "読み込み中…" }
        guard case .resource = store.selection else { return "" }
        // 失敗しているときに「0 件」と出さない。数えられていない。
        if store.errorMessage != nil, store.objects.isEmpty { return "取得できません" }
        let shown = store.filteredObjects.count
        let total = store.objects.count
        return shown == total ? "\(total) 件" : "\(shown) / \(total) 件"
    }

    // MARK: - ツールバー

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) { contextMenu }
        ToolbarItem(placement: .navigation) { namespaceMenu }
        ToolbarItem { refreshControl }
        ToolbarItem {
            Button {
                showsInspector.toggle()
            } label: {
                Label("詳細", systemImage: "sidebar.trailing")
            }
            .help("詳細パネルの表示を切り替える")
        }
    }

    private var contextMenu: some View {
        Menu {
            Picker("コンテキスト", selection: Binding(
                get: { store.currentContext },
                set: { store.currentContext = $0 })
            ) {
                ForEach(store.contexts, id: \.self) { context in
                    Text(context).tag(context)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Label {
                Text(store.currentContext.isEmpty ? "コンテキスト" : store.currentContext)
                    .lineLimit(1)
            } icon: {
                Image(systemName: "cube.transparent")
            }
        }
        // アイコンだけだと何のメニューか分からない。接続先は取り違えると
        // 影響が大きいので、名前を常に見えるところに出す。
        .labelStyle(.titleAndIcon)
        .help("接続先のクラスタ（kubeconfig のコンテキスト）")
    }

    private var namespaceMenu: some View {
        Menu {
            Button {
                store.selectedNamespace = nil
            } label: {
                if store.selectedNamespace == nil {
                    Label("すべての Namespace", systemImage: "checkmark")
                } else {
                    Text("すべての Namespace")
                }
            }
            Divider()
            ForEach(store.namespaces, id: \.self) { namespace in
                Button {
                    store.selectedNamespace = namespace
                } label: {
                    if store.selectedNamespace == namespace {
                        Label(namespace, systemImage: "checkmark")
                    } else {
                        Text(namespace)
                    }
                }
            }
        } label: {
            Label {
                Text(store.namespaceLabel).lineLimit(1)
            } icon: {
                Image(systemName: "square.stack.3d.down.right")
            }
        }
        .labelStyle(.titleAndIcon)
        .help("Namespace の絞り込み")
        .disabled(store.namespaces.isEmpty)
    }

    private var refreshControl: some View {
        Menu {
            Toggle("自動更新", isOn: Binding(
                get: { store.autoRefresh },
                set: { store.autoRefresh = $0 }))
            Picker("間隔", selection: Binding(
                get: { store.refreshInterval },
                set: { store.refreshInterval = $0 })
            ) {
                Text("5 秒").tag(TimeInterval(5))
                Text("10 秒").tag(TimeInterval(10))
                Text("30 秒").tag(TimeInterval(30))
                Text("60 秒").tag(TimeInterval(60))
            }
            if let lastUpdated = store.lastUpdated {
                Divider()
                Text("最終更新 \(lastUpdated.formatted(date: .omitted, time: .standard))")
            }
        } label: {
            Label("再読み込み", systemImage: "arrow.clockwise")
        } primaryAction: {
            store.reload()
        }
        .help("いま表示しているものを読み直す（⌘R）")
    }


    // MARK: - エラー表示

    @ViewBuilder
    private var errorBar: some View {
        if let message = store.errorMessage {
            let parts = Self.splitError(message)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: StatusLevel.critical.symbol)
                    .foregroundStyle(Palette.color(for: .critical))
                VStack(alignment: .leading, spacing: 6) {
                    Text(parts.summary)
                        .font(.callout)
                        .textSelection(.enabled)
                        .lineLimit(4)
                    // 元の文言は畳んでおく。開いておくと帯が画面の半分を占める。
                    // **切り捨てない。** 切り捨てると、原因の手がかりが末尾に
                    // ある種の失敗（exec プラグインが出す TLS のエラーなど）を
                    // アプリの中では追えなくなる。
                    if let detail = parts.detail {
                        DisclosureGroup(isExpanded: $showsErrorDetail) {
                            ScrollView {
                                Text(detail)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 160)
                        } label: {
                            Text("元の文言").font(.caption)
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 6) {
                    // 貼って共有できないと、結局ターミナルで再現する羽目になる。
                    Button("コピー") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message, forType: .string)
                    }
                    .buttonStyle(.link)
                    Button("閉じる") { store.errorMessage = nil }
                        .buttonStyle(.link)
                }
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Palette.color(for: .critical).opacity(0.35), lineWidth: 1))
            .padding(16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// 帯の見出しと、畳んでおく残り。
    ///
    /// `Kubectl.explain(_:)` が言い換えを足したものは、空行で言い換えと元の文言が
    /// 分かれている。**同じ文言を 2 度出さない** ので、残りは見出しに入らなかった
    /// 分だけにする。空行が無いものは 4 行目で切る（帯が出す行数と揃える）。
    static func splitError(_ message: String) -> (summary: String, detail: String?) {
        if let separator = message.range(of: "\n\n") {
            let tail = String(message[separator.upperBound...])
            return (String(message[..<separator.lowerBound]), tail.isEmpty ? nil : tail)
        }
        let lines = message.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 4 else { return (message, nil) }
        return (lines.prefix(4).joined(separator: "\n"),
                lines.dropFirst(4).joined(separator: "\n"))
    }
}

/// kubectl そのものが見つからない場合。一覧の読み込み失敗とは扱いを分ける。
struct SetupErrorView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("クラスタに接続できません", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
                .textSelection(.enabled)
        }
    }
}


/// ログパネルの仕切り。掴んで上下に動かすと高さが変わる。
private struct LogPanelHandle: View {
    @Binding var height: CGFloat
    /// ドラッグ開始時の高さ。translation は開始点からの差分なので、
    /// 毎回の変化量として足すと動きが加速してしまう。
    @State private var startHeight: CGFloat?

    private static let minimum: CGFloat = 120
    private static let maximum: CGFloat = 900

    var body: some View {
        ZStack {
            Divider()
            Color.clear
                .frame(height: 7)
                .contentShape(Rectangle())
        }
        .frame(height: 7)
        .onHover { inside in
            if inside {
                NSCursor.resizeUpDown.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let start = startHeight ?? height
                    if startHeight == nil { startHeight = start }
                    height = min(Self.maximum, max(Self.minimum, start - value.translation.height))
                }
                .onEnded { _ in startHeight = nil })
        .accessibilityLabel(Text("ログの高さを変える"))
    }
}
