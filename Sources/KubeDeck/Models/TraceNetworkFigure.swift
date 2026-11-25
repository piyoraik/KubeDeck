import Foundation

// たどるの「通信」を図にするための形。判定はせず、`TraceNetwork` の行の描き方だけを決める。

/// 図の 1 行。相手 1 つと、そこへ引く線 1 本。
struct FlowLane: Identifiable, Sendable {
    /// 相手の居る場所。箱の描き分けに使う。
    enum Place: Sendable, Hashable {
        case namespace(String)
        case external
        case nowhere
    }

    /// ✕ を置く側。
    enum Stop: Sendable, Hashable {
        case peer
        case origin
        case both
        case ports
    }

    enum Line: Sendable, Hashable {
        case open
        case stopped(Stop)
        case unsettled
    }

    let id: String
    let place: Place
    let symbol: String
    /// 手元に実物がある相手（ワークロード）。
    let isResolved: Bool
    let name: String
    let detail: String
    var detailLevel: StatusLevel?
    /// 線の上に書くもの（ポート、または「制限なし」）。
    let label: String
    let line: Line
    /// 線の下に書く短い理由。
    var note: String?
    /// 省略しない言い方。指したときに出す。
    var explanation: String?
    var anchor: TraceAnchor?
    var policies: [String] = []
}

/// 同じ場所に居る相手のまとまり。箱 1 つぶん。
struct FlowLaneGroup: Identifiable, Sendable {
    let place: FlowLane.Place
    var lanes: [FlowLane]

    var id: String { lanes.first?.id ?? "" }
}

/// 片側の相手を数えたもの。
enum FlowTally: Sendable, Hashable {
    case unrestricted
    case denied
    case peers(count: Int, stopped: Int, unsettled: Int)

    var stopped: Int {
        switch self {
        case .denied: return 1
        case .peers(_, let stopped, _): return stopped
        case .unrestricted: return 0
        }
    }

    var unsettled: Int {
        guard case .peers(_, _, let unsettled) = self else { return 0 }
        return unsettled
    }
}

extension TraceFlowColumn {
    var tally: FlowTally {
        var count = 0
        var stopped = 0
        var unsettled = 0
        var denied = false
        for row in rows {
            switch row.subject {
            case .unrestricted:
                continue
            case .denyAll:
                denied = true
            case .workload(_, let outcome, _):
                count += 1
                switch outcome {
                case .blocked: stopped += 1
                case .mixed, .undetermined: unsettled += 1
                case .allowed: break
                }
            case .unmatched:
                count += 1
                unsettled += 1
            case .anywhere, .namespace, .ipBlock:
                count += 1
            }
        }
        guard count > 0 else { return denied ? .denied : .unrestricted }
        return .peers(count: count, stopped: stopped, unsettled: unsettled)
    }
}

/// 複数のワークロードにまたがる起点の、ワークロード 1 つぶんの通信。
struct BranchNetwork: Identifiable, Sendable {
    let workload: TraceAnchor
    let podCount: Int
    let network: TraceNetwork

    var id: String { workload.id }
    var isRestricted: Bool { !network.policies.isEmpty }
}

extension PlacementTrace {
    static let lanePortLimit = 3
    static let laneLimit = 8

    static func lanes(
        _ column: TraceFlowColumn, direction: FlowDirection, limit: Int? = nil
    ) -> [FlowLaneGroup] {
        var groups: [FlowLaneGroup] = []
        // 上限は箱にまとめる前の並びに掛ける（まとめた後だと、止まる通信が後ろの箱へ回って畳まれる）。
        for row in column.rows.prefix(limit ?? column.rows.count) {
            var lane = Self.lane(row, direction: direction)
            lane.policies = row.policies
            if lane.place != .nowhere,
               let index = groups.firstIndex(where: { $0.place == lane.place }) {
                groups[index].lanes.append(lane)
            } else {
                groups.append(FlowLaneGroup(place: lane.place, lanes: [lane]))
            }
        }
        return groups
    }

    static func lane(_ row: TraceFlowRow, direction: FlowDirection) -> FlowLane {
        let inbound = direction == .ingress
        let anyone = inbound ? String(localized: "どこからでも") : String(localized: "どこへでも")
        let ports = laneLabel(row.ports)

        switch row.subject {
        case .unrestricted(let count):
            let detail: String
            if let count {
                detail = String(localized: "\(count) 個の Pod は制限なし")
            } else {
                detail = String(localized: "制限する NetworkPolicy なし")
            }
            return FlowLane(
                id: row.id, place: .nowhere, symbol: "globe", isResolved: false,
                name: anyone, detail: detail, label: String(localized: "制限なし"), line: .open)

        case .denyAll:
            return FlowLane(
                id: row.id, place: .nowhere, symbol: "nosign", isResolved: false,
                name: inbound
                    ? String(localized: "すべて拒否（入ってこられる相手なし）")
                    : String(localized: "すべて拒否（出ていける先なし）"),
                detail: row.policies.joined(separator: ", "), label: "",
                line: .stopped(.origin))

        case .anywhere:
            return FlowLane(
                id: row.id, place: .nowhere, symbol: "globe", isResolved: false,
                name: anyone, detail: String(localized: "相手を問わない規則"),
                label: ports, line: .open)

        case .workload(let peer, let outcome, let count):
            var lane = FlowLane(
                id: row.id, place: peer.namespace.map(FlowLane.Place.namespace) ?? .nowhere,
                symbol: peer.symbol, isResolved: true,
                name: count > 1 ? "\(peer.name) ×\(count)" : peer.name,
                detail: peer.kindLabel, label: ports, line: line(for: outcome, direction: direction))
            lane.anchor = peer.anchor
            switch outcome {
            case .allowed:
                break
            case .blocked(let blockers):
                lane.note = stopNote(stop(blockers, direction: direction), direction: direction)
                lane.explanation = stopExplanation(blockers, direction: direction)
            case .mixed:
                lane.note = String(localized: "Pod によって違う")
                lane.explanation = String(localized: "Pod によって通るものと止まるものがあります")
            case .undetermined:
                lane.note = String(localized: "決まらない")
                lane.explanation = String(localized: "ラベルを読めないため、通るか決まりません")
            }
            return lane

        case .namespace(let name, let pods):
            var lane = FlowLane(
                id: row.id, place: .namespace(name), symbol: ResourceKind.pod.symbol,
                isResolved: false, name: pods ?? String(localized: "すべての Pod"),
                detail: String(localized: "中の Pod は未取得"), label: ports, line: .open)
            lane.note = String(localized: "相手側は未確認")
            lane.explanation = inbound
                ? String(localized: "中の Pod を取得していないので、相手の出口は見ていません")
                : String(localized: "中の Pod を取得していないので、相手の入口は見ていません")
            return lane

        case .ipBlock(let cidr, let except):
            let name: String
            if except.isEmpty {
                name = cidr
            } else {
                let excluded = except.joined(separator: ", ")
                name = String(localized: "\(cidr)（\(excluded) を除く）")
            }
            var lane = FlowLane(
                id: row.id, place: .external, symbol: "network", isResolved: false,
                name: name, detail: String(localized: "IP の範囲"), label: ports, line: .open)
            lane.explanation = String(localized: "クラスタの外の宛先として扱います")
            return lane

        case .unmatched(let description):
            var lane = FlowLane(
                id: row.id, place: .nowhere, symbol: "questionmark", isResolved: false,
                name: description, detail: String(localized: "手元の Pod には 1 つも当たりません"),
                label: ports, line: .unsettled)
            lane.detailLevel = .warning
            return lane
        }
    }

    private static func line(
        for outcome: FlowPeerGroup.Outcome, direction: FlowDirection
    ) -> FlowLane.Line {
        switch outcome {
        case .allowed: return .open
        case .blocked(let blockers): return .stopped(stop(blockers, direction: direction))
        case .mixed, .undetermined: return .unsettled
        }
    }

    /// どちらの側が止めているか。起点から見た向きで言う。
    static func stop(_ blockers: [FlowBlocker], direction: FlowDirection) -> FlowLane.Stop {
        if blockers.contains(.ports) { return .ports }
        let own: FlowBlocker = direction == .ingress ? .ingress : .egress
        let peer: FlowBlocker = direction == .ingress ? .egress : .ingress
        switch (blockers.contains(own), blockers.contains(peer)) {
        case (true, true): return .both
        case (false, true): return .peer
        default: return .origin
        }
    }

    private static func stopNote(_ stop: FlowLane.Stop, direction: FlowDirection) -> String {
        let inbound = direction == .ingress
        switch stop {
        case .ports: return String(localized: "ポートが重ならない")
        case .both: return String(localized: "両側で止まる")
        case .peer:
            return inbound
                ? String(localized: "相手の出口で止まる") : String(localized: "相手の入口で止まる")
        case .origin:
            return inbound
                ? String(localized: "起点の入口で止まる") : String(localized: "起点の出口で止まる")
        }
    }

    private static func stopExplanation(
        _ blockers: [FlowBlocker], direction: FlowDirection
    ) -> String {
        switch stop(blockers, direction: direction) {
        case .ports: return String(localized: "両側とも許していますが、ポートが重なりません")
        case .both: return String(localized: "両側の NetworkPolicy で止まります")
        case .peer:
            return direction == .ingress
                ? String(localized: "相手の出口（Egress）で止まります")
                : String(localized: "相手の入口（Ingress）で止まります")
        case .origin: return String(localized: "この起点の NetworkPolicy で止まります")
        }
    }

    static func laneLabel(_ ports: [PolicyPort]?) -> String {
        guard let ports, ports.count > lanePortLimit else { return portsText(ports) }
        let rest = ports.count - lanePortLimit
        return portsText(Array(ports.prefix(lanePortLimit))) + " " + String(localized: "他 \(rest)")
    }

    /// 起点の枝（ワークロード）ごとに同じ判定を呼ぶ。止まる通信のあるものが先。
    static func branchNetworks(
        for graph: TraceGraph, inventory: PlacementInventory,
        controllers index: [String: K8sObject], scope: String?,
        namespaceLabels: [String: [String: String]]?
    ) -> [BranchNetwork] {
        graph.branches
            .filter { $0.podCount > 0 }
            .map { branch in
                BranchNetwork(
                    workload: branch.workload, podCount: branch.podCount,
                    network: network(
                        for: branch.pods, inventory: inventory, controllers: index,
                        scope: scope, namespaceLabels: namespaceLabels))
            }
            .sorted { order(of: $0) < order(of: $1) }
    }

    private static func order(of branch: BranchNetwork) -> (Int, String) {
        let ingress = branch.network.ingress.tally
        let egress = branch.network.egress.tally
        let rank: Int
        if !branch.isRestricted {
            rank = 3
        } else if ingress.stopped + egress.stopped > 0 {
            rank = 0
        } else if ingress.unsettled + egress.unsettled > 0 {
            rank = 1
        } else {
            rank = 2
        }
        return (rank, "\(branch.workload.namespace ?? "")/\(branch.workload.name)")
    }
}
