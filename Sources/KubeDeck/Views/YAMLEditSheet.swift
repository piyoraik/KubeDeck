import SwiftUI
import AppKit

/// YAML を直して書き戻す（`kubectl edit` 相当）。
///
/// **詳細パネルの中で編集させない。** あそこは 300pt まで縮むので、1 行が
/// 収まらず、折り返せばインデントが崩れて構造が読めなくなる（「右のパネルは
/// YAML を主役にしない」で決めたとおり）。編集はシートで、広く取る。
///
/// **押した瞬間に効かせない。** 編集 → 確かめる → 適用の 2 段にして、
/// あいだに**差分**と**サーバの dry-run の答え**を挟む。
struct YAMLEditSheet: View {
    @Environment(ClusterStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let object: K8sObject

    private enum Phase {
        case editing
        case reviewing
    }

    /// 取ってきたままの原文。差分の元になるので**編集で触らない。**
    @State private var original: String?
    @State private var draft = ""
    @State private var loadFailure: String?
    @State private var phase: Phase = .editing
    @State private var dryRunMessage: String?
    @State private var dryRunFailure: String?
    @State private var isChecking = false
    @State private var isApplying = false

    private var managedBy: ManagedBy? { ManagedBy.detect(object) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            notices

            if let loadFailure {
                // **「空です」と出さない。** 引けなかっただけ。
                ContentUnavailableView {
                    Label("YAML を取得できません", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(loadFailure).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if original == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if phase == .editing {
                CodeEditor(text: $draft)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 8))
            } else {
                reviewPane
            }

            footer
        }
        .padding(20)
        .frame(width: 820, height: 660)
        .task { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(phase == .editing ? "YAML を編集" : "この内容で書き戻します")
                .font(.headline)
            HStack(spacing: 6) {
                Image(systemName: object.kind?.symbol ?? "doc.plaintext")
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

    /// 押す前に言っておくこと。**「効かなかった」と思わせない。**
    @ViewBuilder
    private var notices: some View {
        if let managedBy {
            notice(managedBy.warning, level: .serious)
        }
        // Pod の spec はほとんど変えられず、変えられても作り直せば消える。
        // **どこを直せばよいのかまで書く。**
        if object.kind == .pod {
            let hasOwner = !(object.raw.path("metadata.ownerReferences")?
                .arrayValue ?? []).isEmpty
            notice(
                hasOwner
                    ? "この Pod は作り直されると元に戻ります。ふだん直すのは、"
                        + "所有者（Deployment など）のほうです。"
                    : "Pod は変えられる項目がごく限られています（image など）。",
                level: .warning)
        }
    }

    private func notice(_ text: String, level: StatusLevel) -> some View {
        Label(text, systemImage: level.symbol)
            .font(.caption)
            .foregroundStyle(Palette.textColor(for: level))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 確かめる

    private var reviewPane: some View {
        let diff = TextDiff.compare(original ?? "", draft)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(diff.isEmpty
                     ? "変更はありません"
                     : "\(diff.added) 行を足し、\(diff.removed) 行を消します")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isChecking { ProgressView().controlSize(.small) }
                Spacer(minLength: 4)
                if diff.isCoarse {
                    // **黙って粗くしない。** 1 行ずつの対応を諦めたことを言う。
                    Text("差が大きいので、まるごと入れ替えとして出しています")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            ScrollView {
                if diff.isEmpty {
                    Text("元の YAML と同じです。書き戻しても何も変わりません。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diff.hunks) { hunk in
                            if hunk.id > 0 {
                                Divider().padding(.vertical, 4)
                            }
                            ForEach(hunk.lines) { line in
                                diffRow(line)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 8))

            dryRunResult
        }
    }

    /// **色だけに意味を持たせない。** 行頭の `+` / `-` を必ず出す
    /// （状態の 4 色と同じ話で、色は補助）。
    private func diffRow(_ line: TextDiff.Line) -> some View {
        let tint: Color? = {
            switch line.kind {
            case .added: return Palette.color(for: .good)
            case .removed: return Palette.color(for: .critical)
            case .same: return nil
            }
        }()
        let marker: String = {
            switch line.kind {
            case .added: return "+"
            case .removed: return "-"
            case .same: return " "
            }
        }()

        return HStack(alignment: .top, spacing: 8) {
            Text(line.newNumber.map(String.init) ?? line.oldNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 38, alignment: .trailing)
            Text(marker + " " + line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(tint ?? .secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background((tint ?? .clear).opacity(tint == nil ? 0 : 0.10))
    }

    /// サーバの答え。**エラーの種類で言うことを変える。**
    @ViewBuilder
    private var dryRunResult: some View {
        if let dryRunFailure {
            VStack(alignment: .leading, spacing: 4) {
                if Kubectl.isConflict(dryRunFailure) {
                    // **他の失敗と混ぜない。** 直す先が違う（中身ではなく、古さ）。
                    notice(
                        "開いたあとに、この \(object.kind?.displayName ?? "オブジェクト")は"
                            + "変わっています。書き戻すと、そのあいだの変更を消すことに"
                            + "なるので弾かれました。「読み直す」で最新から編集し直して"
                            + "ください（いまの編集内容はコピーできます）。",
                        level: .critical)
                } else {
                    notice("このままでは書き戻せません。理由は次のとおりです。", level: .critical)
                }
                ScrollView {
                    Text(dryRunFailure)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 78)
                .background(Palette.insetFill, in: RoundedRectangle(cornerRadius: 6))
            }
        } else if let dryRunMessage {
            // kubectl が言ったことをそのまま出す（`... replaced (server dry run)`）。
            Label("サーバに聞きました: \(dryRunMessage)", systemImage: StatusLevel.good.symbol)
                .font(.caption)
                .foregroundStyle(Palette.textColor(for: .good))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 下の行

    private var footer: some View {
        HStack(spacing: 8) {
            // **何を編集していても取り出せるようにする。** 書き戻しが弾かれた
            // ときに、編集した内容を失わずに読み直せる唯一の道。
            Button("コピー") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(draft, forType: .string)
            }
            .disabled(original == nil)

            Button("読み直す") {
                Task { await load(force: true) }
            }
            .disabled(original == nil || isApplying)
            .help("クラスタから取り直します。編集した内容は失われます（先にコピーを）")

            Spacer()

            Button("やめる", role: .cancel) { dismiss() }
                .disabled(isApplying)

            switch phase {
            case .editing:
                Button("変更を確かめる…") {
                    phase = .reviewing
                    Task { await check() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(original == nil || draft == original)

            case .reviewing:
                Button("編集に戻る") { phase = .editing }
                Button("書き戻す") {
                    Task { await apply() }
                }
                .keyboardShortcut(.defaultAction)
                // 通らないと分かっているものを押させない。
                .disabled(isApplying || dryRunFailure != nil || draft == original)
            }
        }
        .controlSize(.regular)
    }

    // MARK: - 取得と適用

    private func load(force: Bool = false) async {
        if force {
            original = nil
            phase = .editing
            dryRunMessage = nil
            dryRunFailure = nil
        }
        switch await store.yaml(for: object) {
        case .success(let text):
            original = text
            draft = text
            loadFailure = nil
        case .failure(let error):
            loadFailure = error.localizedDescription
        }
    }

    private func check() async {
        isChecking = true
        defer { isChecking = false }
        switch await store.validateYAML(draft) {
        case .success(let message):
            dryRunMessage = message
            dryRunFailure = nil
        case .failure(let error):
            dryRunMessage = nil
            dryRunFailure = error.localizedDescription
        }
    }

    private func apply() async {
        isApplying = true
        defer { isApplying = false }
        switch await store.applyYAML(draft, to: object) {
        case .success:
            dismiss()
        case .failure(let error):
            // **閉じない。** 閉じると編集した内容ごと消える。
            dryRunFailure = error.localizedDescription
        }
    }
}

/// YAML を打つための欄。
///
/// **`TextEditor` をそのまま使わない。** macOS の `NSTextView` は既定で
/// スマート引用符とダッシュの置き換えが効いており、`"foo"` が `"foo"` に
/// なる。YAML では**黙って値が変わる**（あるいは構文が壊れる）ので、
/// 置き換えの類をすべて切った `NSTextView` を自分で載せる。
private struct CodeEditor: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        // **折り返さない。** インデントが崩れると YAML の構造が読めなくなる
        // （ログの折り返しとは逆の判断。あちらは 1 行が本文なので折り返す）。
        textView.isHorizontallyResizable = true
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = CGSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = CGSize(width: 6, height: 8)
        textView.drawsBackground = false

        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // **打っている最中に差し戻さない。** 同じ内容で `string` を代入すると
        // 選択位置が先頭へ飛ぶ。
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
