import SwiftUI

struct RootView: View {
    @Environment(ClusterStore.self) private var store
    @State private var showsInspector = true
    /// ログパネルの高さ。仕切りのドラッグで変わる。
    @State private var logHeight: CGFloat = 280

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
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: StatusLevel.critical.symbol)
                    .foregroundStyle(Palette.color(for: .critical))
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .lineLimit(4)
                Spacer(minLength: 8)
                Button("閉じる") { store.errorMessage = nil }
                    .buttonStyle(.link)
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
