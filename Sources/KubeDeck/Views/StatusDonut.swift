import Charts
import SwiftUI

/// 状態の内訳を示すリング 1 つぶん。
///
/// リングは全体に対する割合、中央は総数。状態色は淡いところで見分けにくく
/// なるので、内訳を出すときは必ずアイコンとラベルを添える（色だけで意味を運ばせない）。
struct StatusRing: View {
    let title: String
    let tally: StatusTally
    /// 中央に出す単位（「Pod」など）。
    let unit: String

    var body: some View {
        HStack(spacing: 14) {
            if tally.isEmpty {
                emptyState
            } else {
                ring
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    summary
                    // 内訳が 1 種類なら並べない。リング中央の数と合否で足りている。
                    if tally.buckets.count > 1 { breakdown }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var ring: some View {
        Chart(tally.buckets) { bucket in
            SectorMark(
                angle: .value("件数", bucket.count),
                innerRadius: .ratio(0.7),
                // 隣り合う色が直に触れると境目が消える。面のあいだに隙間を空ける。
                angularInset: 1.5
            )
            .cornerRadius(2)
            .foregroundStyle(Palette.color(for: bucket.level))
        }
        .chartLegend(.hidden)
        .frame(width: 92, height: 92)
        .overlay {
            VStack(spacing: 0) {
                Text("\(tally.total)")
                    .font(.system(size: 22, weight: .semibold))
                    .contentTransition(.numericText())
                Text(unit)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(
            Text(
                tally.buckets
                    .map { "\($0.label) \($0.count)" }
                    .joined(separator: "、")))
    }

    @ViewBuilder
    private var summary: some View {
        if tally.unhealthy > 0 {
            Label("\(tally.unhealthy) 件に問題", systemImage: StatusLevel.critical.symbol)
                .font(.caption)
                .foregroundStyle(Palette.textColor(for: .critical))
        } else {
            Label("すべて正常", systemImage: StatusLevel.good.symbol)
                .font(.caption)
                .foregroundStyle(Palette.textColor(for: .good))
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(tally.buckets) { bucket in
                HStack(spacing: 6) {
                    Image(systemName: bucket.level.symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(Palette.color(for: bucket.level))
                    Text(bucket.label)
                        .font(.caption)
                    Spacer(minLength: 8)
                    Text("\(bucket.count)")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 160)
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "tray")
                .foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text("対象なし").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(height: 92)
    }
}

/// クラスタの見出しと、Pod / ワークロード / ノードの状態を 1 枚にまとめたカード。
///
/// **カードを分けない。** 見出しだけのカードは横がまるごと空き、リングごとに
/// 枠を立てると中身より枠が目立つ。同じ「いまのクラスタ」の話なので 1 枚に収める。
struct ClusterStatusCard<Header: View>: View {
    let pods: StatusTally
    let workloads: StatusTally
    let nodes: StatusTally
    @ViewBuilder var header: Header

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 18)
                .padding(.vertical, 16)

            Divider()

            HStack(alignment: .center, spacing: 0) {
                StatusRing(title: "Pod", tally: pods, unit: "Pod")
                Divider().frame(height: 84)
                StatusRing(title: "ワークロード", tally: workloads, unit: "件")
                Divider().frame(height: 84)
                StatusRing(title: "ノード", tally: nodes, unit: "ノード")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Palette.hairline, lineWidth: 1))
    }
}
