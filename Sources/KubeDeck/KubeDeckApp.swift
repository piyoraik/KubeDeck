import SwiftUI

@main
struct KubeDeckApp: App {
    @State private var store = ClusterStore()
    @State private var updater = UpdateController.shared
    /// 確認待ちの操作とシート。
    ///
    /// **画面ではなくここで持つ。** メニューバーからも同じ操作を出したいが、
    /// コマンドはウインドウの外側にいるので、`RootView` の `@State` には
    /// 手が届かない。持ち主を上げれば、メニューと画面が同じ 1 つを見る。
    @State private var actions = ResourceActionHost()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(actions)
                .task { await store.bootstrap() }
                // 表は横スクロールするので、ここは窓として最低限あればよい。
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1_680, height: 960)
        .commands {
            // 「KubeDeck について」のすぐ下。macOS のアプリはここに置く決まり。
            CommandGroup(after: .appInfo) {
                Button("アップデートを確認…") { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
            CommandGroup(after: .toolbar) {
                Button("再読み込み") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Toggle("自動更新", isOn: Binding(
                    get: { store.autoRefresh },
                    set: { store.autoRefresh = $0 }))
                Divider()
                Button("概要") { store.selection = .overview }
                    .keyboardShortcut("1", modifiers: .command)
                Button("配置") { store.selection = .placement }
                    .keyboardShortcut("2", modifiers: .command)
                Divider()
            }
            // **絞り込みは「編集」の下に置く。** 探すための欄なので、
            // macOS の作法では検索の仲間。
            CommandGroup(after: .textEditing) {
                Button("絞り込みへ移動") { store.requestSearchFocus() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(store.selection == .overview)
            }
            // **操作をメニューバーにも出す。** 1 日中触る道具なので、
            // ショートカットが要る。**中身は画面と同じ `ResourceActionSet`**
            // から作る（出し分けを 2 か所に書かない、といういつもの話）。
            CommandMenu("操作") {
                ObjectCommands(store: store, actions: actions)
            }
            // 「新規ウインドウ」以外の File メニューは使い道が無い。
            CommandGroup(replacing: .newItem) {}
        }

        // ログは独立したウインドウで開く。Pod ごとに 1 枚で、同じ Pod を
        // 二度開いても同じ窓が前に出る（WindowGroup(for:) が値で束ねる）。
        WindowGroup("ログ", id: LogWindow.id, for: PodLogRequest.self) { $request in
            if let request {
                LogView(request: request)
                    .environment(store)
                    .frame(minWidth: 620, minHeight: 380)
            }
        }
        .defaultSize(width: 1_040, height: 680)

        Settings {
            SettingsView()
                .environment(store)
        }
    }
}


enum LogWindow {
    static let id = "pod-logs"
}

/// メニューバーの「操作」。
///
/// **中身を自分で決めない。** 一覧の右クリック・詳細パネルのボタンと同じ
/// `ResourceActionSet` から作る。ここだけ別に並べると、種別を足したときに
/// メニューバーからだけ届かない操作ができる。
private struct ObjectCommands: View {
    let store: ClusterStore
    let actions: ResourceActionHost

    /// よく使うものにだけ割り当てる。**全部に付けない** —— 覚えられないし、
    /// 押し間違いが増えるだけ。
    private static let shortcuts: [String: KeyEquivalent] = [
        "logs": "l",
        "exec": "e",
        "delete": .delete,
        "delete-many": .delete,
    ]

    var body: some View {
        let selected = store.selectedObjects
        let objects = selected.isEmpty ? [store.selectedObject].compactMap { $0 } : selected

        if objects.isEmpty {
            // **空のメニューにしない。** 何も無いと壊れているように見える。
            Text("行を選ぶと、ここに操作が出ます")
        } else {
            ForEach(
                ResourceActionSet.actions(
                    for: objects, target: store.actionTarget,
                    isReadOnly: store.isReadOnly,
                    // メニューバーからは別ウインドウを開かない（対象が決まらない
                    // 場面で開くことになるので、画面側の入口に任せる）。
                    openLogWindow: { _ in })
            ) { action in
                item(action)
            }
        }
    }

    @ViewBuilder
    private func item(_ action: ResourceAction) -> some View {
        let button = Button(action.title) { action.run(actions, store) }
        if let key = Self.shortcuts[action.id] {
            button.keyboardShortcut(key, modifiers: .command)
        } else {
            button
        }
    }
}
