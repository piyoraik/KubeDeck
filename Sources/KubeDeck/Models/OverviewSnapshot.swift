import Foundation

struct StatusBucket: Identifiable, Sendable, Hashable {
    let level: StatusLevel
    let count: Int

    var id: Int { level.rawValue }
    var label: String { level.label }
}

struct ReasonCount: Identifiable, Sendable, Hashable {
    let reason: String
    let level: StatusLevel
    let count: Int

    var id: String { reason }

    /// 一覧に並べるときの表示。
    ///
    /// **比だけを状態として並べない。** レプリカを持つワークロードの状態は
    /// `0/1` や `2/3` という比で、一覧の列ではそれが正しい（kubectl と同じ）。
    /// だが状態の内訳に置くと、`Error` や `Pending` と並んで**状態の名前に
    /// 見えない**。比のときだけ重みの名前を前に付ける。
    var displayName: String {
        guard reason.wholeMatch(of: /\d+\/\d+/) != nil else { return reason }
        return "\(level.label) \(reason)"
    }
}

/// ドーナツ 1 つ分の集計。状態の重みごとの件数と、内訳の理由。
struct StatusTally: Sendable, Hashable {
    var buckets: [StatusBucket] = []
    var reasons: [ReasonCount] = []

    var total: Int { buckets.reduce(0) { $0 + $1.count } }
    var healthy: Int { buckets.first { $0.level == .good }?.count ?? 0 }
    var isEmpty: Bool { total == 0 }

    /// 正常でないものの件数。見出しの添え書きに使う。
    var unhealthy: Int {
        buckets.filter { $0.level == .critical || $0.level == .serious }
            .reduce(0) { $0 + $1.count }
    }

    /// 落ち着くのを待っているものの件数（ロールアウト中、`Pending`、
    /// `Running (未 Ready)` など）。
    ///
    /// **`unhealthy` に混ぜない。** あちらは「困っている」で、こちらは
    /// 「途中」。ただし**「すべて正常」とも言わない** — リングには橙の
    /// セグメントが出ているのに見出しが「すべて正常」だと、しるしと文字が
    /// 食い違う（概要の見出しで同じ間違いを踏んでいる）。
    var inProgress: Int {
        buckets.first { $0.level == .warning }?.count ?? 0
    }

    static func make(from objects: [K8sObject]) -> StatusTally {
        var perLevel: [StatusLevel: Int] = [:]
        var perReason: [String: (StatusLevel, Int)] = [:]

        for object in objects {
            let status = StatusResolver.health(for: object)
            perLevel[status.level, default: 0] += 1
            let key = status.text.isEmpty ? status.level.label : status.text
            perReason[key, default: (status.level, 0)].1 += 1
        }

        let buckets = StatusLevel.allCases.compactMap { level -> StatusBucket? in
            guard let count = perLevel[level], count > 0 else { return nil }
            return StatusBucket(level: level, count: count)
        }
        // 重い状態を先に、同じ重さなら件数の多い順。困っているものが上に来る。
        let reasons = perReason
            .map { ReasonCount(reason: $0.key, level: $0.value.0, count: $0.value.1) }
            .sorted { lhs, rhs in
                if lhs.level.severityOrder != rhs.level.severityOrder {
                    return lhs.level.severityOrder < rhs.level.severityOrder
                }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.reason < rhs.reason
            }

        return StatusTally(buckets: buckets, reasons: reasons)
    }
}

struct OverviewSnapshot: Sendable {
    /// 概要として**集計まで済んでいるか**。リングと使用量が出せるかの判定。
    ///
    /// **件数の有無で代用しない。** `counts` は一覧を見ているあいだにも
    /// サイドバーのために埋まる（`refreshSidebarCounts`）ので、そちらを印に
    /// すると「サイドバーの数字がある」を「概要を読んだ」と取り違える。
    /// 一覧から概要へ移ったとき、まだ何も数えていないのに 0 の並んだリングが
    /// 出ていたのはこれ（読み込み中の表示が出なかった）。
    ///
    /// 印を `ClusterStore` 側に別の変数として持たない。**snapshot を捨てれば
    /// 一緒に落ちる**ようにしておかないと、コンテキストを切り替えたときのように
    /// 片方だけ消す経路が残る（実際そうなっていた）。
    var isTallied = false
    var serverVersion: String = ""
    var counts: [ResourceKind: Int] = [:]
    var pods = StatusTally()
    var workloads = StatusTally()
    var nodes = StatusTally()
    /// 直近のイベント。**nil は「引けなかった」。**
    ///
    /// 空配列（本当に 1 件も無い）と分ける。以前は失敗を `[]` に潰していたので、
    /// イベントを読む権限が無いクラスタで概要が「イベントはありません。」と
    /// 断定していた（詳細パネルの `EventsPane` は 3 つを分けているのに、
    /// 概要だけが混ぜていた）。ここも「無い」と「取れていない」を混ぜない話。
    var recentEvents: [K8sObject]?
    /// 全ノードの割り当て可能量の合計。使用率の分母。
    var allocatable = ResourceUsage()
    /// 権限が無くて読めなかった種別。
    ///
    /// **`counts` に 0 を入れない。** 入れると「拒まれた」が「無い」になる。
    /// `counts` から抜いておけば、件数の消費側（サイドバー）は nil を
    /// 「まだ分からない」として扱うので、既存の経路がそのまま正しく働く。
    var deniedKinds: [ResourceKind] = []
    /// サーバが名前を知らなかった種別。**拒まれたのとは分けて持つ**
    /// （権限の話ではないので、見る場所も対処も違う）。`counts` に
    /// 入れないのは拒まれた種別と同じ理由。
    var unknownKinds: [ResourceKind] = []

    func count(_ kind: ResourceKind) -> Int { counts[kind] ?? 0 }

    /// 集計だけを捨てる。**件数は残す** — あちらの持ち場はサイドバーで、
    /// 概要を読み直しているあいだに数字が消える理由が無い。
    mutating func discardTallies() {
        isTallied = false
        pods = StatusTally()
        workloads = StatusTally()
        nodes = StatusTally()
        recentEvents = nil
        allocatable = ResourceUsage()
    }
}
