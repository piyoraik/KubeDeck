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
        case .busy: return "取得中"
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
        let recent = Array(store.overview.recentEvents.prefix(8))

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

            if recent.isEmpty {
                Text("イベントはありません。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
            } else {
                ForEach(Array(recent.enumerated()), id: \.element.id) { index, event in
                    if index > 0 { Divider().padding(.leading, 16) }
                    eventRow(event)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.hairline, lineWidth: 1))
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
