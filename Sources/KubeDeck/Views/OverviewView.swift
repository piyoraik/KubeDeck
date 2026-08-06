import SwiftUI

struct OverviewView: View {
    @Environment(ClusterStore.self) private var store

    var body: some View {
        // 初回は 0 の並んだカードを見せない。まだ数えていないだけなのに
        // 「全部 0 件のクラスタ」に見える。
        if store.isLoading && !store.hasOverviewData {
            LoadingView(detail: store.currentContext)
                .background(Color(nsColor: .windowBackgroundColor))
        } else if !store.hasOverviewData, store.errorMessage != nil {
            // 取得に失敗したまま 0 のタイルを並べない。数えられていないだけで、
            // 「全部 0 件のクラスタ」ではない。
            failure
                .background(Color(nsColor: .windowBackgroundColor))
        } else {
            content
        }
    }

    private var failure: some View {
        ContentUnavailableView {
            Label("クラスタの状態を取得できません", systemImage: "exclamationmark.triangle")
        } description: {
            Text("\(store.currentContext) から応答がありませんでした。件数や使用量は分かりません。")
        } actions: {
            Button("もう一度試す") { store.reload() }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // **読めたぶんは出したうえで、欠けを断る。** 権限の無い種別が
                // 1 つあるだけで概要ごと消していた（kubectl は読めた種別を
                // 標準出力に書いているのに、終了コードだけ見て捨てていた）。
                if let notice = store.partialDataNotice {
                    PartialDataNotice(text: notice)
                }
                ClusterStatusCard(
                    pods: store.overview.pods,
                    workloads: store.overview.workloads,
                    nodes: store.overview.nodes
                ) {
                    clusterHeader
                }
                ClusterUsageCard()
                events
            }
            .padding(20)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - 見出し

    /// 舵輪が回っていること自体が「見ている」の合図。色はクラスタ全体の重み。
    /// 枠は持たない。`ClusterStatusCard` の見出し行として置かれる。
    private var clusterHeader: some View {
        HStack(spacing: 14) {
            ClusterActivityIcon(
                activity: store.activity, level: store.clusterHealth, size: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.currentContext.isEmpty ? "コンテキスト未選択" : store.currentContext)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // 回転と色だけに意味を持たせない。状態は文字でも出す。
                // バージョンと最終更新はここに書かない。右のパネルが持っている。
                Label(activityText, systemImage: store.clusterHealth.symbol)
                    .font(.caption)
                    .foregroundStyle(Palette.textColor(for: store.clusterHealth))
            }
            Spacer(minLength: 0)
        }
    }

    private var activityText: String {
        switch store.activity {
        // **しるしと文字を食い違わせない。** アイコンはクラスタの状態（色つき）
        // なのに、取得中だけ文字が「取得中」に変わっていた。異常があるクラスタ
        // では赤いしるしの隣に「取得中」と出て、取得が失敗しているように読めた。
        case .busy: return "取得中 · \(store.clusterHealth.label)"
        case .live: return "稼働中 · \(store.clusterHealth.label)"
        case .idle:
            return store.setupErrorMessage == nil
                ? "自動更新は停止中 · \(store.clusterHealth.label)"
                : "未接続"
        }
    }


    // MARK: - イベント

    /// 使用量カードと同じ作りにする。見出しをカードの外に置くと、
    /// 同じ画面に「枠の中に題がある箱」と「外にある箱」が混ざって落ち着かない。
    private var events: some View {
        let loaded = store.overview.recentEvents
        let recent = Array((loaded ?? []).prefix(8))

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("最近のイベント")
                    .font(.headline)
                Spacer(minLength: 8)
                if !recent.isEmpty {
                    Text("直近 \(recent.count) 件")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)

            Divider()

            if loaded == nil {
                // **「ありません」と言わない。** 引けなかっただけで、
                // 何か起きたかどうかは確かめていない（詳細パネルの
                // `EventsPane` と同じ言い分け）。
                emptyNote(
                    "イベントを取得できませんでした。",
                    detail: "この Namespace のイベントを読む権限が無いか、"
                        + "クラスタから応答がありませんでした。"
                        + "何も起きていないという意味ではありません。",
                    level: .warning)
            } else if recent.isEmpty {
                // **0 件も黙って終えない。** イベントには寿命があり
                // （既定で 1 時間）、古い出来事は本当に消える。
                emptyNote(
                    "イベントはありません。",
                    detail: "イベントはしばらく（クラスタの既定で 1 時間）で消えます。"
                        + "それより前の出来事はクラスタに残っていません。",
                    level: nil)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().padding(.leading, 16) }
                    eventRow(event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Palette.cardStroke, lineWidth: 1))
        .shadow(color: Palette.cardShadow, radius: 6, y: 2)
    }

    /// 行が無いときの断り。**「取れていない」と「0 件」で書き分ける。**
    private func emptyNote(
        _ text: String, detail: String, level: StatusLevel?
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: level?.symbol ?? "bell.slash")
                .font(.callout)
                .foregroundStyle(
                    level.map { Palette.textColor(for: $0) } ?? Color.secondary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }

    private func eventRow(_ event: K8sObject) -> some View {
        let status = StatusResolver.status(for: event)
        return HStack(alignment: .top, spacing: 10) {
            // ログの行と同じ作りにする。目を引かせるのは細い帯だけ。
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
                    Text(ResourceTable.eventTarget(event))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(ResourceTable.eventMessage(event))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            Text(ResourceTable.age(of: event, kind: .event))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
        .padding(.trailing, 14)
        .padding(.vertical, 9)
        .fixedSize(horizontal: false, vertical: true)
    }

}
