import SwiftUI

/// 読み込み中の表示。舵輪を右回りに回す。
///
/// 出すのは**まだ出せる中身が無いときだけ**。すでに一覧が出ているのに
/// これへ差し替えると、更新のたびに画面が消えて点滅する。中身があるときの
/// 更新中は、ウインドウの副題に文字で出している。
struct LoadingView: View {
    var message: String = "読み込み中"
    var detail: String?

    var body: some View {
        VStack(spacing: 14) {
            RotatingKubernetesMark(activity: .busy, side: 56)
                .frame(width: 56, height: 56)

            VStack(spacing: 4) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(message))
    }
}

/// 中身は出せているが、一部が欠けていることの断り。
///
/// **画面を失敗にしない。** 読めたぶんは出したうえで、欠けていることだけを
/// 上に細く置く。全体をエラーにすると、取れているデータまで見えなくなる
/// （それが「無い」と「取れていない」を混ぜるということ）。
struct PartialDataNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: StatusLevel.warning.symbol)
            .font(.caption)
            .foregroundStyle(Palette.textColor(for: .warning))
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Palette.color(for: .warning).opacity(0.10),
                in: RoundedRectangle(cornerRadius: 8))
    }
}
