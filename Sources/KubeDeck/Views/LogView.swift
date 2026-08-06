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
            // Pod 以外で開いたときは、そのしるしにする。名前だけだと、同名の
            // Pod のログを見ているように読める。読んでいる Pod 自身の名前は
            // `LogContent` の下の帯（または Pod の Picker）が持つ。
            Image(systemName: LogHeader.symbol(for: request))
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(request.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(LogHeader.subtitle(for: request))
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

/// 詳細パネルの「ログ」タブ。
///
/// **見出しを持たない。** 対象の名前も種別も、すぐ上の詳細パネルの見出しが
/// 出している（`LogPanel` は独立した帯なので自分で出す。持ち場が違う）。
///
/// **「押したときだけ開く」を破っていない。** タブを選ぶこと自体が
/// その操作にあたる。選択を変えるたびに取り直すのは、開いているログパネルが
/// 選択に追従するのと同じ扱い（`followLogsToSelection`）。
struct InspectorLogPane: View {
    @Environment(\.openWindow) private var openWindow
    let request: PodLogRequest

    /// この幅を下回ると、ログの 1 行がほとんど折り返す。
    /// **「読める最小」ではなく「断りを出す境目」。** 詳細パネルは右に
    /// 置くと 300〜360pt しかなく、ログは YAML よりさらに 1 行が長い
    /// （右のパネルを YAML の主役にしていないのと同じ理由）。
    /// 下に置けば幅は足りるので、**出せないのではなく置き場所の話**だと言う。
    private static let narrowWidth: CGFloat = 520

    var body: some View {
        // **外側で測る。** 中で測ると `LogContent` の高さが決まらない。
        GeometryReader { proxy in
            VStack(spacing: 0) {
                header(isNarrow: proxy.size.width < Self.narrowWidth)
                Divider()
                LogContent(request: request, isCompact: true)
            }
            // `GeometryReader` は子を左上に寄せるので、広がる枠に入れる。
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(isNarrow: Bool) -> some View {
        HStack(spacing: 8) {
            // **狭いことを黙らない。** 折り返しだらけの画面を見て
            // 「ログの表示が壊れている」と読まれるより、置き場所の話だと
            // 分かるほうがよい。**記号だけにしない**ので短く文字も出す。
            if isNarrow {
                Label("狭い幅では読みにくい", systemImage: "arrow.left.and.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("詳細パネルを下に置く（設定 › 一般）か、"
                        + "別ウインドウで開くと 1 行が収まります")
            }

            Spacer(minLength: 4)

            Button {
                openWindow(id: LogWindow.id, value: request)
            } label: {
                Label("別ウインドウ", systemImage: "macwindow.on.rectangle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.small)
            .layoutPriority(1)
            .help("別のウインドウで開く。並べて比べたいときと、"
                + "この幅では読みにくいとき")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

/// ログを独立したウインドウで開く場合。複数の Pod を並べて見るとき用。
struct LogView: View {
    let request: PodLogRequest

    var body: some View {
        LogContent(request: request)
            .navigationTitle(request.name)
            .navigationSubtitle(LogHeader.subtitle(for: request))
    }
}

/// 見出しの書き方。
///
/// **パネルと窓で別々に書かない。** 以前はどちらも `request.isJob` を直に
/// 見ており、種別が増えた時点で片方だけ Job のままになる形だった
/// （`PodLogRequest` の判定を 1 か所に寄せてあるのと同じ理由）。
enum LogHeader {
    static func symbol(for request: PodLogRequest) -> String {
        if request.isJob { return "checkmark.seal" }
        if request.isGroup { return "text.line.first.and.arrowtriangle.forward" }
        return "text.alignleft"
    }

    /// **種別を書く。** 「まとめて読んでいる」ことが見出しに出ていないと、
    /// 混ざった行を 1 つの Pod のものと読んでしまう。
    static func subtitle(for request: PodLogRequest) -> String {
        guard let kind = request.kindLabel else { return request.namespace }
        return "\(request.namespace) · \(kind)"
    }
}
