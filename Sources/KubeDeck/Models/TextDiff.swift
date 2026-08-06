import Foundation

/// 行単位の差分。
///
/// **編集した YAML を、確かめずに書き戻させない。** 編集してから適用するまでの
/// あいだに他のことをするのはふつうで、そのとき「自分が何を変えたか」は
/// 覚えていない。dry-run が通ることと、意図した変更であることは別の話
/// （綴りの正しい消し忘れは dry-run を通る）。
///
/// **全文を並べない。** 1 行直しただけで 300 行の壁を出しても読まれない。
/// 変わったところの前後だけを出す。
enum TextDiff {
    struct Line: Identifiable, Equatable {
        enum Kind: Equatable {
            case same
            case added
            case removed
        }

        let id: Int
        let kind: Kind
        let text: String
        /// 元の側の行番号。足された行では nil。
        let oldNumber: Int?
        /// 新しい側の行番号。消された行では nil。
        let newNumber: Int?
    }

    /// 変わったところ 1 か所と、その前後。
    struct Hunk: Identifiable {
        let id: Int
        let lines: [Line]
    }

    struct Result {
        let hunks: [Hunk]
        let added: Int
        let removed: Int
        /// 大きすぎて 1 行ずつの突き合わせを諦めたか。
        /// **黙って諦めない** — 画面に断りを出すために持つ。
        let isCoarse: Bool

        var isEmpty: Bool { added == 0 && removed == 0 }
    }

    /// **前後の同じ行を先に落とす。** ふつうの編集は 1 か所なので、これだけで
    /// 突き合わせる範囲が数行まで縮む。落とさずに LCS を掛けると、YAML 全体
    /// （数百行）の表を毎回作ることになる。
    static func compare(_ old: String, _ new: String, context: Int = 3) -> Result {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")

        var head = 0
        while head < oldLines.count, head < newLines.count,
              oldLines[head] == newLines[head] {
            head += 1
        }
        var tail = 0
        while tail < oldLines.count - head, tail < newLines.count - head,
              oldLines[oldLines.count - 1 - tail] == newLines[newLines.count - 1 - tail] {
            tail += 1
        }

        let oldMiddle = Array(oldLines[head..<(oldLines.count - tail)])
        let newMiddle = Array(newLines[head..<(newLines.count - tail)])

        // **`Int(.infinity)` の話と同じで、大きさを見ずに表を作らない。**
        // LCS の表は行数の積なので、1 万行どうしなら 1 億マスになる。
        // ここまで来るのは全面的な貼り替えなので、そのときは 1 行ずつの
        // 対応を諦めて「まるごと入れ替え」として出す。
        let isCoarse = oldMiddle.count > 800 || newMiddle.count > 800

        var lines: [Line] = []
        var identifier = 0
        func append(_ kind: Line.Kind, _ text: String, old: Int?, new: Int?) {
            lines.append(
                Line(id: identifier, kind: kind, text: text, oldNumber: old, newNumber: new))
            identifier += 1
        }

        for index in 0..<head {
            append(.same, oldLines[index], old: index + 1, new: index + 1)
        }

        if isCoarse {
            for (offset, text) in oldMiddle.enumerated() {
                append(.removed, text, old: head + offset + 1, new: nil)
            }
            for (offset, text) in newMiddle.enumerated() {
                append(.added, text, old: nil, new: head + offset + 1)
            }
        } else {
            var oldNumber = head + 1
            var newNumber = head + 1
            for step in lcsSteps(oldMiddle, newMiddle) {
                switch step {
                case .same(let text):
                    append(.same, text, old: oldNumber, new: newNumber)
                    oldNumber += 1
                    newNumber += 1
                case .removed(let text):
                    append(.removed, text, old: oldNumber, new: nil)
                    oldNumber += 1
                case .added(let text):
                    append(.added, text, old: nil, new: newNumber)
                    newNumber += 1
                }
            }
        }

        for offset in 0..<tail {
            let index = oldLines.count - tail + offset
            append(
                .same, oldLines[index],
                old: index + 1, new: newLines.count - tail + offset + 1)
        }

        return Result(
            hunks: hunks(from: lines, context: context),
            added: lines.filter { $0.kind == .added }.count,
            removed: lines.filter { $0.kind == .removed }.count,
            isCoarse: isCoarse)
    }

    private enum Step {
        case same(String)
        case removed(String)
        case added(String)
    }

    /// 素直な LCS。範囲は上で絞ってある。
    private static func lcsSteps(_ old: [String], _ new: [String]) -> [Step] {
        if old.isEmpty { return new.map { .added($0) } }
        if new.isEmpty { return old.map { .removed($0) } }

        var table = [[Int]](
            repeating: [Int](repeating: 0, count: new.count + 1), count: old.count + 1)
        for i in stride(from: old.count - 1, through: 0, by: -1) {
            for j in stride(from: new.count - 1, through: 0, by: -1) {
                table[i][j] = old[i] == new[j]
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var steps: [Step] = []
        var i = 0
        var j = 0
        while i < old.count, j < new.count {
            if old[i] == new[j] {
                steps.append(.same(old[i]))
                i += 1
                j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                // **消しを先に出す。** 置き換えは「消して足す」で表れるので、
                // 順番を揃えないと同じ行の前後で上下が入れ替わって読みにくい。
                steps.append(.removed(old[i]))
                i += 1
            } else {
                steps.append(.added(new[j]))
                j += 1
            }
        }
        while i < old.count {
            steps.append(.removed(old[i]))
            i += 1
        }
        while j < new.count {
            steps.append(.added(new[j]))
            j += 1
        }
        return steps
    }

    /// 変わった行の前後 `context` 行だけを塊にして返す。
    /// 塊どうしが重なるなら 1 つに繋ぐ（あいだに同じ行が 1 行だけ挟まる、
    /// のような切れ方をさせない）。
    private static func hunks(from lines: [Line], context: Int) -> [Hunk] {
        let changed = lines.indices.filter { lines[$0].kind != .same }
        guard !changed.isEmpty else { return [] }

        var ranges: [ClosedRange<Int>] = []
        for index in changed {
            let lower = max(0, index - context)
            let upper = min(lines.count - 1, index + context)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }
        return ranges.enumerated().map { offset, range in
            Hunk(id: offset, lines: Array(lines[range]))
        }
    }
}
