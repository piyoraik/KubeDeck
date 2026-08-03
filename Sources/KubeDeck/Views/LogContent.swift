import SwiftUI

/// ログ本体。下部パネルと独立ウインドウの両方から使う。
///
/// 操作列・本文・状態表示をまとめて持つので、包む側は見出しと閉じ方だけを足せばよい。
struct LogContent: View {
    @Environment(ClusterStore.self) private var store
    let request: PodLogRequest
    /// 下部パネルでは行を詰める。窓では少し余裕を持たせる。
    var isCompact = false

    @State private var lines: [LogLine] = []
    @State private var container: String = ""
    /// `kubectl logs --follow` を付けるか。**取得そのものの話。**
    /// 切ると、いま出ている範囲を読み終えた時点で kubectl が終了する。
    @State private var streams = Preferences.shared.logFollowsByDefault
    /// 新しい行が来たら末尾へスクロールするか。**見え方だけの話。**
    ///
    /// **`streams` と 1 つにしない。** 以前は 1 つのトグルが両方を兼ねており、
    /// しかも取得の鍵（`reloadKey`）に入っていたので、**「スクロールを止めたい」
    /// だけで切ると取得ごとやり直しになり、それまで読んでいた行が全部消えた。**
    /// 遡って読もうとする場面がまさにそこなので、いちばん困る消え方だった。
    @State private var autoScroll = Preferences.shared.logFollowsByDefault
    @State private var timestamps = Preferences.shared.logShowsTimestamps
    @State private var previous = false
    /// 折り返すか。切ると横スクロールになる。
    @State private var wraps = Preferences.shared.logWrapsByDefault
    @State private var filter = ""
    @State private var handle: ProcessHandle?
    @State private var streamTask: Task<Void, Never>?
    @State private var isRunning = false
    /// 上限に達して古い行を捨てたか。捨てた事実を黙っていると、
    /// 「最初のほうのログが無い」を不具合と誤解する。
    @State private var didTruncate = false
    /// 何番目の取得か。待っているあいだに対象が変わったかの判定に使う。
    @State private var generation = 0

    /// 行数の上限。追従したままにすると際限なく積み上がる。設定で変えられる。
    private var maximumLines: Int { Preferences.shared.logBufferLines }

    var body: some View {
        // **1 度だけ絞り込む。** 本文・空の判定・件数の 3 か所がそれぞれ
        // `visibleLines` を読んでいたので、絞り込み中は 1 回の描画で
        // 全行を 3 度舐めていた。
        let visible = visibleLines

        return VStack(spacing: 0) {
            controls
            Divider()
            output(visible)
            Divider()
            status(visible)
        }
        .task(id: reloadKey) { await restart() }
        .onDisappear { stop() }
        .onAppear {
            if container.isEmpty { container = request.containers.first ?? "" }
        }
    }

    // MARK: - 操作列

    private var controls: some View {
        HStack(spacing: 10) {
            if request.containers.count > 1 {
                Picker("コンテナ", selection: $container) {
                    ForEach(request.containers, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }

            // **取得と見え方を別のトグルにする。** 「末尾へ送る」を切るのは
            // 遡って読みたいときで、そこで取得を切ると読んでいた行が消える。
            Toggle(isOn: $streams) {
                Label("追いかける", systemImage: "dot.radiowaves.left.and.right")
            }
            .help("kubectl logs --follow を付けて、新しい行を受け取り続ける。"
                + "切ると、いま出ている範囲まで読んで終わる")

            Toggle(isOn: $autoScroll) {
                Label("末尾へ送る", systemImage: "arrow.down.to.line")
            }
            .help("新しい行が来たら末尾までスクロールする。"
                + "切っても取得は続くので、遡って読んでも行は消えない")

            Toggle(isOn: $wraps) {
                Label("折り返し", systemImage: "text.append")
            }
            .help("長い行を折り返す。切ると横スクロールになる")

            Menu {
                Toggle("時刻を出す", isOn: $timestamps)
                Toggle("前回の起動のログ", isOn: $previous)
                Divider()
                Button("表示中の行をコピー") { copyVisible() }
            } label: {
                Label("その他", systemImage: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 8)

            TextField("行を絞り込む", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - 本文

    private func output(_ visible: [LogLine]) -> some View {
        ScrollViewReader { proxy in
            ScrollView(wraps ? .vertical : [.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(visible) { line in
                        row(line)
                    }
                    Color.clear.frame(height: 1).id(-1)
                }
                .padding(.vertical, 4)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .onChange(of: lines.count) {
                guard autoScroll else { return }
                proxy.scrollTo(-1, anchor: .bottom)
            }
            .onChange(of: autoScroll) { _, isOn in
                if isOn { proxy.scrollTo(-1, anchor: .bottom) }
            }
            .overlay {
                if visible.isEmpty { placeholder }
            }
        }
    }

    /// 1 行。左に深刻度の帯、次に行番号、そして本文。
    ///
    /// **本文の色は変えない。** 何百行も並ぶ場所で文字色を振ると、
    /// 読むこと自体が疲れる。目を引かせるのは細い帯とごく薄い下地だけにする。
    private func row(_ line: LogLine) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Rectangle()
                .fill(accent(for: line.level) ?? .clear)
                .frame(width: 2)

            Text("\(line.id + 1)")
                .font(.system(size: fontSize - 1, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.quaternary)
                .frame(width: 46, alignment: .trailing)
                .padding(.trailing, 8)
                // 行番号は選択に含めない。コピーしたときに紛れ込む。
                .textSelection(.disabled)

            Text(attributed(line))
                .font(.system(size: fontSize, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: false)
                .lineSpacing(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 10)
        }
        .padding(.vertical, 1)
        .background(tint(for: line.level))
        .id(line.id)
    }

    private var fontSize: CGFloat { isCompact ? 10.5 : 11 }

    private func accent(for level: LogLevel) -> Color? {
        level.statusLevel.map { Palette.color(for: $0) }
    }

    private func tint(for level: LogLevel) -> Color {
        guard let status = level.statusLevel else { return .clear }
        return Palette.color(for: status).opacity(0.07)
    }

    /// 時刻は控えめに、絞り込みに一致した部分は目立たせる。
    private func attributed(_ line: LogLine) -> AttributedString {
        var text = AttributedString(line.text)

        if line.timestampLength > 0, line.timestampLength < line.text.count {
            let end = text.index(text.startIndex, offsetByCharacters: line.timestampLength)
            text[text.startIndex..<end].foregroundColor = .secondary
        }

        let needle = filter.trimmingCharacters(in: .whitespaces)
        if !needle.isEmpty {
            var searchRange = text.startIndex..<text.endIndex
            while let found = text[searchRange].range(
                of: needle, options: [.caseInsensitive])
            {
                text[found].backgroundColor = Palette.color(for: .warning).opacity(0.35)
                guard found.upperBound < text.endIndex else { break }
                searchRange = found.upperBound..<text.endIndex
            }
        }
        return text
    }

    @ViewBuilder
    private var placeholder: some View {
        if !lines.isEmpty {
            ContentUnavailableView(
                "一致する行がありません",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("「\(filter)」を含む行は、いま読み込んでいる範囲にありません。"))
        } else if isRunning {
            LoadingView(message: "ログを待っています")
        } else {
            ContentUnavailableView(
                "ログがありません",
                systemImage: "text.alignleft",
                description: Text("このコンテナはまだ何も出力していません。"))
        }
    }

    // MARK: - 状態

    private func status(_ visible: [LogLine]) -> some View {
        HStack(spacing: 10) {
            if isRunning, streams {
                Label("追いかけ中", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: .good))
            }
            Text(countText(visible))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if didTruncate {
                // 何行あるかだけでなく、古い行を捨てたことも言う。
                Text("· 上限 \(maximumLines) 行を超えた分は捨てています")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func countText(_ visible: [LogLine]) -> String {
        let total = lines.count
        return visible.count == total ? "\(total) 行" : "\(visible.count) / \(total) 行"
    }

    private var visibleLines: [LogLine] {
        let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return lines }
        return lines.filter { $0.text.lowercased().contains(needle) }
    }

    private func copyVisible() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            visibleLines.map(\.text).joined(separator: "\n"), forType: .string)
    }

    // MARK: - 取得

    /// これが変われば取り直す。
    ///
    /// **見え方だけの状態を入れない。** `autoScroll` はここに無い。入れると、
    /// スクロールを止めるたびに取得がやり直しになって行が消える。
    private var reloadKey: String {
        "\(request.id)|\(container)|\(streams)|\(timestamps)|\(previous)"
    }

    private func restart() async {
        stop()
        generation += 1
        let token = generation
        lines = []
        didTruncate = false
        // 対象が変わったらコンテナの選択も入れ直す。
        if !request.containers.contains(container) {
            container = request.containers.first ?? ""
        }

        var options = Kubectl.LogOptions()
        options.container = container.isEmpty ? nil : container
        options.follow = streams
        options.timestamps = timestamps
        options.previous = previous
        options.tailLines = Preferences.shared.logTailLines

        switch await store.logStream(
            namespace: request.namespace, pod: request.pod, options: options)
        {
        case .failure(let error):
            guard token == generation else { return }
            lines = [LogLine(id: 0, text: error.localizedDescription)]
        case .success(let (stream, processHandle)):
            // 待っているあいだに対象が変わっていたら、掴んだプロセスをその場で捨てる。
            // `stop()` はこの時点でまだ存在しないハンドルを止められないので、
            // ここで見捨てると `kubectl logs -f` が選んだ Pod の数だけ残る。
            guard token == generation else {
                processHandle.terminate()
                return
            }
            handle = processHandle
            isRunning = true
            streamTask = Task { await consume(stream, token: token) }
        }
    }

    /// 読めた塊ごとに反映する。
    ///
    /// **1 行ずつ append しない。** append のたびに body が作り直され、1 行あたり
    /// - 上限に達したあとは `removeFirst` の O(n) の詰め直し
    /// - 絞り込み中は `visibleLines` の O(n) が body 1 回につき 3 か所
    /// - `ForEach` の同一性リストを上限（既定 5,000）ぶん歩き直す
    ///
    /// が走っていた。毎秒数百行を出す Pod を開くと UI が張り付く。
    /// **溜め込みで直さない** — 溜めると、静かになった Pod の最後の数行が
    /// 次の行が来るまで出ないことになる。塊はもともとパイプから塊で届いて
    /// いるので、ばらさずに受ければよい（`ProcessRunner.stream`）。
    private func consume(_ stream: AsyncStream<[String]>, token: Int) async {
        for await chunk in stream {
            guard !Task.isCancelled, token == generation else { break }
            guard !chunk.isEmpty else { continue }

            var next = lines
            next.reserveCapacity(next.count + chunk.count)
            var index = (next.last?.id ?? -1) + 1
            for text in chunk {
                next.append(LogLine(id: index, text: text))
                index += 1
            }
            // 溢れたぶんは 1 度で落とす。1 行ごとの `removeFirst` をやめる。
            if next.count > maximumLines {
                next.removeFirst(next.count - maximumLines)
                didTruncate = true
            }
            lines = next
        }
        if token == generation { isRunning = false }
    }

    private func stop() {
        streamTask?.cancel()
        streamTask = nil
        handle?.terminate()
        handle = nil
        isRunning = false
    }
}
