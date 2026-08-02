import SwiftUI

@main
struct KubeDeckApp: App {
    @State private var store = ClusterStore()
    @State private var updater = UpdateController.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
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
