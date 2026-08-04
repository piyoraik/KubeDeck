import SwiftUI

/// 一覧の下に出すログのパネル。
///
/// **既定はこちら。** シートや別ウインドウだと、ログを読みながら一覧の
/// 他の行を見ることができない。上下に分けておけば、どの Pod のログを
/// 見ているのかを一覧と突き合わせながら追える。高さは仕切りで変えられる。
struct LogPanel: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    let request: PodLogRequest

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LogContent(request: request, isCompact: true)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 8) {
            // Job で開いたときは Job のしるしにする。名前だけだと、同名の
            // Pod のログを見ているように読める。読んでいる Pod 自身の名前は
            // `LogContent` の下の帯（または Pod の Picker）が持つ。
            Image(systemName: request.isJob ? "checkmark.seal" : "text.alignleft")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(request.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(request.isJob ? "\(request.namespace) · Job" : request.namespace)
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

            Button {
                // 並べて比べたいときのために窓へも出せる。
                openWindow(id: LogWindow.id, value: request)
                store.logRequest = nil
            } label: {
                Label("別ウインドウ", systemImage: "macwindow.on.rectangle")
            }
            .help("別のウインドウで開く。複数の Pod を並べて見たいとき")

            Button {
                store.closeLogs()
            } label: {
                Label("閉じる", systemImage: "xmark")
            }
            .help("ログを閉じる。もう一度見るには「ログを見る」から開く")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }
}

/// ログを独立したウインドウで開く場合。複数の Pod を並べて見るとき用。
struct LogView: View {
    let request: PodLogRequest

    var body: some View {
        LogContent(request: request)
            .navigationTitle(request.name)
            .navigationSubtitle(
                request.isJob ? "\(request.namespace) · Job" : request.namespace)
    }
}
