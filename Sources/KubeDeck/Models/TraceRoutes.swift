import Foundation

extension TrafficRoute {
    /// 入口の列に置くのは、Gateway を親に持つ経路だけ（親が Service の経路は、親の下流ではない）。
    var entersThroughGateway: Bool {
        parents.contains { $0.kind == .gateway }
    }

    /// 割合の文字。規則ごとに違うときは範囲で書く（1 つの数字に丸めない）。
    static func shareText(_ shares: [Share]) -> String {
        let fractions = shares.map(\.fraction)
        guard let low = fractions.min(), let high = fractions.max() else { return "" }
        let lowText = percentText(low)
        let highText = percentText(high)
        if lowText == highText { return "\(lowText)%" }
        return String(localized: "\(lowText)〜\(highText)%")
    }
}

/// 枝の入口に出す経路 1 件。
struct TraceRouteEntry: Identifiable, Sendable {
    let route: TrafficRoute
    /// この枝の Service に流す割合。規則ごとに違いうる。
    let shares: [TrafficRoute.Share]
    /// 経路が指している、この枝の Service。
    let serviceNames: [String]

    var id: String { route.id }

    var anchor: TraceAnchor {
        TraceAnchor(
            anchorKind: .route, resourceKind: nil, kindLabel: route.kindLabel,
            namespace: route.namespace, name: route.name)
    }

    var shareText: String { TrafficRoute.shareText(shares) }

    /// 器の 2 行目。
    var subtitle: String {
        let share = shareText
        return share.isEmpty ? route.kindLabel : "\(route.kindLabel) · \(share)"
    }

    /// 器に付けるしるし。問題が無いか、記録が無いだけなら付けない。
    var badge: StatusLevel? { PlacementTrace.level(of: route) }

    var help: String {
        var lines = PlacementTrace.headerLines(route)
        let targets = serviceNames.joined(separator: ", ")
        lines.append(String(localized: "宛先: \(targets)"))
        lines += PlacementTrace.shareLines(shares, in: route)
        // しるしだけにしない。何が起きているかを文字でも出す。
        lines += PlacementTrace.findingNotes(route).map(\.text)
        lines.append(String(localized: "押すと、この経路を起点にします。"))
        return lines.joined(separator: "\n")
    }
}

/// Service の器に付ける経路の札 1 枚。親が Service の経路は、列に置かずここに出す。
struct TraceRouteTag: Identifiable, Sendable {
    enum Role: String, Sendable {
        /// この Service 宛ての呼び出しを、経路が振り分ける。
        case parent
        /// 経路が、この Service へ流す。
        case destination
    }

    let route: TrafficRoute
    let serviceNamespace: String
    let serviceName: String
    let role: Role
    /// この Service へ流す割合。宛先の札だけが持つ。
    let shares: [TrafficRoute.Share]

    var id: String { "\(route.id)|\(serviceNamespace)/\(serviceName)|\(role.rawValue)" }

    var anchor: TraceAnchor {
        TraceAnchor(
            anchorKind: .route, resourceKind: nil, kindLabel: route.kindLabel,
            namespace: route.namespace, name: route.name)
    }

    /// 経路の名前。Service と Namespace が違うときは Namespace を添える。
    var name: String {
        route.namespace == serviceNamespace ? route.name : "\(route.namespace)/\(route.name)"
    }

    var shareText: String { TrafficRoute.shareText(shares) }

    /// 「親」と書かない。残りの割合が親に残るように読まれた（実画面）。
    var text: String {
        let name = self.name
        switch role {
        case .parent:
            return String(localized: "\(name) が振り分け")
        case .destination:
            let share = shareText
            return String(localized: "\(name) から \(share)")
        }
    }

    /// 名前の前後。欄が狭いときに名前だけを縮めるために分ける（語順は訳に任せる）。
    var parts: (lead: String, trail: String) {
        let text = self.text
        guard let range = text.range(of: name) else { return (text, "") }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }

    var badge: StatusLevel? { PlacementTrace.level(of: route) }

    var help: String {
        var lines = PlacementTrace.headerLines(route)
        switch role {
        case .parent:
            lines.append(String(localized: "この Service 宛ての呼び出しを、この経路が振り分けます。"))
            lines += route.rules.map { PlacementTrace.describe($0, in: route) }
        case .destination:
            lines += PlacementTrace.shareLines(shares, in: route)
        }
        lines += PlacementTrace.findingNotes(route).map(\.text)
        lines.append(String(localized: "押すと、この経路を起点にします。"))
        return lines.joined(separator: "\n")
    }
}

extension TraceBranch {
    func tags(on service: K8sObject) -> [TraceRouteTag] {
        routeTags.filter {
            $0.serviceName == service.name && $0.serviceNamespace == service.namespace
        }
    }
}

/// 経路を起点にしたときの「振り分け」の図。呼び出し先から、規則ごとに宛先へ分かれる。
struct TraceRouteSplit: Sendable {
    /// 呼び出し先（経路の親）。
    struct Origin: Identifiable, Sendable {
        let kindLabel: String
        let name: String
        let symbol: String
        /// 押したときの起点。手元に実物がある Service だけ。
        let anchor: TraceAnchor?

        var id: String { "\(kindLabel)/\(name)" }
    }

    enum Target: Sendable, Equatable {
        case service
        /// 取得範囲の中に無い。`dead` は、コントローラも解決できていないと言っているとき。
        case missing(dead: Bool)
        case outOfScope
        case unsupported
    }

    struct Row: Identifiable, Sendable {
        let id: String
        let name: String
        let kindLabel: String
        let fraction: Double
        let target: Target
        /// 帯と色見本の濃淡。宛先ごとに決め、規則をまたいでも変えない。
        let shade: Int
        let anchor: TraceAnchor?

        var percentText: String { "\(TrafficRoute.percentText(fraction))%" }

        /// 宛先の 2 行目。500 と言うのは、コントローラも解決できていないと言うときだけ。
        var detail: String {
            switch target {
            case .service:
                return kindLabel
            case .missing(let dead):
                let percent = percentText
                return dead
                    ? String(localized: "Service がありません。この \(percent) は 500 を返します")
                    : String(localized: "取得した一覧にありません")
            case .outOfScope:
                return String(localized: "いまの取得範囲の外です")
            case .unsupported:
                return String(localized: "\(kindLabel)。Service ではないので、辿っていません")
            }
        }

        var level: StatusLevel? {
            switch target {
            case .missing(let dead): return dead ? .serious : .warning
            case .service, .outOfScope, .unsupported: return nil
            }
        }
    }

    struct Rule: Identifiable, Sendable {
        let number: Int
        /// match の条件を文字にしたもの。空なら条件なし。
        let conditions: String
        let rows: [Row]

        var id: Int { number }

        var caption: String {
            conditions.isEmpty
                ? String(localized: "規則 \(number)（条件なし）")
                : String(localized: "規則 \(number)（\(conditions)）")
        }
    }

    let origins: [Origin]
    let rules: [Rule]

    /// 条件の無い規則 1 つだけなら、見出しは要らない。
    var showsRuleCaptions: Bool {
        rules.count > 1 || rules.contains { !$0.conditions.isEmpty }
    }

    var originCaption: String {
        if origins.isEmpty {
            return String(localized: "親の指定がありません。どこにも付いていない経路です。")
        }
        return origins.allSatisfy { $0.kindLabel == "Service" }
            ? String(localized: "ここ宛ての呼び出しの行き先")
            : String(localized: "ここに来た呼び出しの行き先")
    }
}

extension PlacementTrace {
    // MARK: - 枝に出す経路

    /// 入口の列に出す経路。割合は、枝の Service ぶんを規則ごとに足したもの。
    static func routeEntries(
        for services: [K8sObject], inventory: PlacementInventory
    ) -> [TraceRouteEntry] {
        guard !services.isEmpty else { return [] }

        return ordered(inventory.routes.filter(\.entersThroughGateway))
            .compactMap { route -> TraceRouteEntry? in
                var targets: [(name: String, namespace: String)] = []
                for service in services {
                    guard let namespace = service.namespace,
                          !route.shares(toService: service.name, namespace: namespace).isEmpty
                    else { continue }
                    targets.append((name: service.name, namespace: namespace))
                }
                let shares = route.shares(toServices: targets)
                guard !shares.isEmpty else { return nil }
                return TraceRouteEntry(route: route, shares: shares, serviceNames: targets.map(\.name))
            }
    }

    /// Service の器に付ける札。その Service が親か宛先になっている経路ぶん。兼ねていれば 2 枚。
    static func routeTags(
        for services: [K8sObject], inventory: PlacementInventory
    ) -> [TraceRouteTag] {
        // 親の無い経路（と、親が Gateway でも Service でもない経路）は何も振り分けないので札にしない。
        let routes = ordered(inventory.routes.filter { route in
            !route.entersThroughGateway && route.parents.contains { $0.kind == .service }
        })
        guard !routes.isEmpty else { return [] }

        return services.flatMap { service -> [TraceRouteTag] in
            guard let namespace = service.namespace else { return [] }
            return routes.flatMap { route -> [TraceRouteTag] in
                var tags: [TraceRouteTag] = []
                let isParent = route.parents.contains {
                    $0.kind == .service && $0.namespace == namespace && $0.name == service.name
                }
                if isParent {
                    tags.append(
                        TraceRouteTag(
                            route: route, serviceNamespace: namespace, serviceName: service.name,
                            role: .parent, shares: []))
                }
                let shares = route.shares(toService: service.name, namespace: namespace)
                if !shares.isEmpty {
                    tags.append(
                        TraceRouteTag(
                            route: route, serviceNamespace: namespace, serviceName: service.name,
                            role: .destination, shares: shares))
                }
                return tags
            }
        }
    }

    /// 経路が起点のときは、枝を「宛先の Service から先」だけにする。割合と親は、振り分けの図が持つ。
    static func focused(
        _ branches: [TraceBranch], onRoute anchor: TraceAnchor, inventory: PlacementInventory
    ) -> [TraceBranch] {
        guard let route = route(for: anchor, in: inventory) else { return branches }
        return branches.map { branch in
            let services = branch.services.filter { service in
                guard let namespace = service.namespace else { return false }
                return !route.shares(toService: service.name, namespace: namespace).isEmpty
            }
            return TraceBranch(
                workload: branch.workload, ingresses: [], services: services,
                generations: branch.generations)
        }
    }

    private static func ordered(_ routes: [TrafficRoute]) -> [TrafficRoute] {
        routes.sorted { lhs, rhs in
            lhs.name == rhs.name ? lhs.namespace < rhs.namespace : lhs.name < rhs.name
        }
    }

    // MARK: - 経路を起点にする

    static func routeAnchors(inventory: PlacementInventory) -> [TraceAnchor] {
        inventory.routes
            .map { route in
                TraceAnchor(
                    anchorKind: .route, resourceKind: nil, kindLabel: route.kindLabel,
                    namespace: route.namespace, name: route.name,
                    podCount: pods(of: route, inventory: inventory).count,
                    detail: route.parents
                        .map { describe($0, in: route) }
                        .joined(separator: ", "))
            }
            .sorted { lhs, rhs in
                lhs.name == rhs.name
                    ? (lhs.namespace ?? "") < (rhs.namespace ?? "") : lhs.name < rhs.name
            }
    }

    static func route(for anchor: TraceAnchor, in inventory: PlacementInventory) -> TrafficRoute? {
        guard anchor.anchorKind == .route else { return nil }
        return inventory.routes.first {
            $0.namespace == anchor.namespace && $0.name == anchor.name
                && $0.kindLabel == anchor.kindLabel
        }
    }

    static func pods(ofRoute anchor: TraceAnchor, inventory: PlacementInventory) -> [K8sObject] {
        guard let route = route(for: anchor, in: inventory) else { return [] }
        return pods(of: route, inventory: inventory)
    }

    /// 経路が指しているのに、Pod を 1 つも掴んでいない Service。
    static func danglingServices(
        ofRoute anchor: TraceAnchor, inventory: PlacementInventory
    ) -> [K8sObject] {
        guard let route = route(for: anchor, in: inventory) else { return [] }
        return destinations(of: route, inventory: inventory).services.filter {
            WorkloadRelations.pods(selectedBy: $0, among: inventory.pods).isEmpty
        }
    }

    private static func destinations(
        of route: TrafficRoute, inventory: PlacementInventory
    ) -> TrafficRoute.Destinations {
        route.destinations(
            among: inventory.related, scope: inventory.scope,
            servicesReadable: inventory.servicesReadable)
    }

    private static func pods(of route: TrafficRoute, inventory: PlacementInventory) -> [K8sObject] {
        var seen = Set<String>()
        var result: [K8sObject] = []
        for service in destinations(of: route, inventory: inventory).services {
            for pod in WorkloadRelations.pods(selectedBy: service, among: inventory.pods)
            where seen.insert(pod.id).inserted {
                result.append(pod)
            }
        }
        return result
    }

    // MARK: - 振り分けの図

    /// 経路を起点にしたときだけ作る。呼び出し先（親）と、規則ごとの宛先と割合。
    static func routeSplit(
        for anchor: TraceAnchor, inventory: PlacementInventory
    ) -> TraceRouteSplit? {
        guard let route = route(for: anchor, in: inventory) else { return nil }
        let destinations = destinations(of: route, inventory: inventory)
        let dead = route.reportsUnresolvedBackends

        func key(_ backend: TrafficRoute.Backend) -> String {
            "\(backend.group)/\(backend.kind)/\(backend.namespace)/\(backend.name)"
        }
        func matches(_ backend: TrafficRoute.Backend, in list: [TrafficRoute.Backend]) -> Bool {
            list.contains { key($0) == key(backend) }
        }

        var shades: [String: Int] = [:]
        let rules = route.rules.map { rule -> TraceRouteSplit.Rule in
            // 同じ宛先を 2 度書いた規則は、重みを足して 1 行にする。
            var order: [TrafficRoute.Backend] = []
            var weights: [String: Int] = [:]
            for backend in rule.backends {
                if weights[key(backend)] == nil { order.append(backend) }
                weights[key(backend), default: 0] += backend.weight
            }
            let total = rule.totalWeight

            let rows = order.map { backend -> TraceRouteSplit.Row in
                let id = key(backend)
                let shade = shades[id] ?? shades.count
                shades[id] = shade

                let service = destinations.services.first {
                    $0.namespace == backend.namespace && $0.name == backend.name
                }
                let target: TraceRouteSplit.Target
                if !backend.isService {
                    target = .unsupported
                } else if service != nil {
                    target = .service
                } else if matches(backend, in: destinations.missing) {
                    target = .missing(dead: dead)
                } else {
                    target = .outOfScope
                }
                return TraceRouteSplit.Row(
                    id: "\(rule.number)|\(id)",
                    name: backend.namespace == route.namespace
                        ? backend.name : "\(backend.namespace)/\(backend.name)",
                    kindLabel: backend.kind,
                    fraction: total > 0 ? Double(weights[id] ?? 0) / Double(total) : 0,
                    target: target, shade: shade,
                    anchor: service.map(serviceAnchor))
            }
            return TraceRouteSplit.Rule(
                number: rule.number, conditions: rule.matches.joined(separator: " / "),
                rows: rows)
        }

        var seen = Set<String>()
        let origins = route.parents
            .map { parent -> TraceRouteSplit.Origin in
                let name = parent.namespace == route.namespace
                    ? parent.name : "\(parent.namespace)/\(parent.name)"
                switch parent.kind {
                case .service:
                    let service = inventory.related.first {
                        $0.kind == .service && $0.namespace == parent.namespace
                            && $0.name == parent.name
                    }
                    return TraceRouteSplit.Origin(
                        kindLabel: "Service", name: name, symbol: ResourceKind.service.symbol,
                        anchor: service.map(serviceAnchor))
                case .gateway:
                    // Gateway は引いていないので、入口のしるしだけを借りる。
                    return TraceRouteSplit.Origin(
                        kindLabel: "Gateway", name: name, symbol: ResourceKind.ingress.symbol,
                        anchor: nil)
                case .other(let kind):
                    return TraceRouteSplit.Origin(
                        kindLabel: kind, name: name, symbol: "square.dashed", anchor: nil)
                }
            }
            .filter { seen.insert($0.id).inserted }

        return TraceRouteSplit(origins: origins, rules: rules)
    }

    private static func serviceAnchor(_ service: K8sObject) -> TraceAnchor {
        TraceAnchor(
            anchorKind: .service, resourceKind: .service,
            kindLabel: ResourceKind.service.apiKind,
            namespace: service.namespace, name: service.name)
    }

    // MARK: - 図に添える断り

    /// 経路についての断り。図に経路が 1 つも出ていなければ、読めなかったこと以外は言わない。
    static func routeNotes(
        for anchor: TraceAnchor, branches: [TraceBranch], inventory: PlacementInventory
    ) -> [TraceNote] {
        var notes: [TraceNote] = []
        if let problem = inventory.routeProblem {
            let reason = problem.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            notes.append(
                TraceNote(
                    text: reason.isEmpty
                        ? String(localized: "HTTPRoute を読めないので、経路は描いていません。")
                        : String(localized: "HTTPRoute を読めないので、経路は描いていません: \(reason)"),
                    level: .warning))
        }

        let anchored = route(for: anchor, in: inventory)
        let tags = branches.flatMap(\.routeTags)
        // 割合を出している経路。振り分け元の札しか出ていない経路は、札のしるしと説明に任せる。
        var rated: [TrafficRoute] = anchored.map { [$0] } ?? []
        let drawn = branches.flatMap(\.routes).map(\.route)
            + tags.filter { $0.role == .destination }.map(\.route)
        for route in drawn where !rated.contains(where: { $0.id == route.id }) {
            rated.append(route)
        }
        guard !rated.isEmpty || !tags.isEmpty else { return notes }

        // 起点が経路なら、その経路のことだけを言う。宛先ごとの事情は、振り分けの図の行に出る。
        for route in anchored.map({ [$0] }) ?? rated {
            notes += findingNotes(route)
        }
        // status に出ない「効かない」がある（waypoint の指定の誤りなど。実測）ので、いつも断る。
        if !rated.isEmpty {
            notes.append(
                TraceNote(
                    text: String(localized: """
                        割合は宣言です。実際の流量ではありません。\
                        match の条件と、経路どうしの優先順は評価していません。
                        """),
                    level: .neutral))
        }
        if inventory.scope != nil {
            notes.append(
                TraceNote(
                    text: String(
                        localized: "ほかの Namespace に置かれた経路は、いまの取得範囲の外です。"),
                    level: .neutral))
        }

        var seen = Set<String>()
        return notes.filter { seen.insert($0.text).inserted }
    }

    static func findingNotes(_ route: TrafficRoute) -> [TraceNote] {
        // 断りは文で重複を除くので、Namespace が無いと別の Namespace の同名の経路が 1 つに潰れる。
        let label = "\(route.kindLabel) \(route.namespace)/\(route.name)"
        return route.parents.flatMap { parent -> [TraceNote] in
            let parentLabel = describe(parent, in: route)
            return parent.findings.map { finding in
                switch finding {
                case .notAccepted(let reason, let message):
                    return TraceNote(
                        text: String(
                            localized: "\(label) は \(parentLabel) に付いていません（\(reason)）: \(message)"),
                        level: .serious)
                case .unresolvedReferences(let reason, let message):
                    return TraceNote(
                        text: String(
                            localized: "\(label) は宛先を解決できていません（\(reason)）: \(message)"),
                        level: .serious)
                case .advisory(let type, let message):
                    return TraceNote(
                        text: String(localized: "\(label)（\(type)）: \(message)"),
                        level: .warning)
                case .undecided(let type, let message):
                    return TraceNote(
                        text: String(
                            localized: "\(label) の \(type) は、まだ決まっていません: \(message)"),
                        level: .warning)
                case .noRecord:
                    return TraceNote(
                        text: String(localized: """
                            \(label) を \(parentLabel) が受け付けた記録がありません\
                            （親が存在しないか、担当するコントローラが居ません）。
                            """),
                        level: .neutral)
                }
            }
        }
    }

    // MARK: - 状態の重み

    /// 経路の器に付けるしるしの重み。記録が無いだけなら nil（壊れているとは言わない）。
    static func level(of route: TrafficRoute) -> StatusLevel? {
        route.parents
            .flatMap(\.findings)
            .compactMap { finding -> StatusLevel? in
                switch finding {
                case .notAccepted, .unresolvedReferences: return .serious
                case .advisory, .undecided: return .warning
                case .noRecord: return nil
                }
            }
            .max()
    }

    // MARK: - 説明の文字

    static func describe(_ parent: TrafficRoute.Parent, in route: TrafficRoute) -> String {
        let name = parent.namespace == route.namespace
            ? parent.name : "\(parent.namespace)/\(parent.name)"
        switch parent.kind {
        case .gateway: return "Gateway \(name)"
        case .service: return "Service \(name)"
        case .other(let kind): return "\(kind) \(name)"
        }
    }

    /// 規則 1 つの振り分け先。
    static func describe(_ rule: TrafficRoute.Rule, in route: TrafficRoute) -> String {
        let targets = rule.backends.isEmpty
            ? String(localized: "宛先なし")
            : rule.backends
                .map { backend -> String in
                    let name = backend.namespace == route.namespace
                        ? backend.name : "\(backend.namespace)/\(backend.name)"
                    let label = backend.isService ? name : "\(backend.kind) \(name)"
                    return "\(label) \(TrafficRoute.percentText(rule.share(of: backend)))%"
                }
                .joined(separator: ", ")
        let number = rule.number
        let conditions = rule.matches.joined(separator: " / ")
        return conditions.isEmpty
            ? String(localized: "規則 \(number): \(targets)")
            : String(localized: "規則 \(number)（\(conditions)）: \(targets)")
    }

    /// 説明の頭。経路そのものと、その親。
    static func headerLines(_ route: TrafficRoute) -> [String] {
        var lines = ["\(route.kindLabel) \(route.namespace)/\(route.name)"]
        let parents = route.parents
            .map { describe($0, in: route) }
            .joined(separator: ", ")
        if !parents.isEmpty {
            lines.append(String(localized: "親: \(parents)"))
        }
        return lines
    }

    static func shareLines(_ shares: [TrafficRoute.Share], in route: TrafficRoute) -> [String] {
        shares.map { share in
            let number = share.rule
            let percent = TrafficRoute.percentText(share.fraction)
            let conditions = (route.rules.first { $0.number == number }?.matches ?? [])
                .joined(separator: " / ")
            return conditions.isEmpty
                ? String(localized: "規則 \(number): \(percent)%")
                : String(localized: "規則 \(number)（\(conditions)）: \(percent)%")
        }
    }
}
