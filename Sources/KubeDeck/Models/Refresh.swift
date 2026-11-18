import Foundation

/// 入れ替わりが終わったかを、`kubectl rollout status` と同じ規則で判定する。
enum RolloutProgress {
    /// kubectl に status viewer がある種別だけ判定できる。
    static func covers(_ kind: ResourceKind?) -> Bool {
        kind == .deployment || kind == .statefulSet || kind == .daemonSet
    }

    /// kubectl が待ち続けるあいだは false。kubectl がエラーで打ち切る状態は、待っても進まないので true。
    static func isSettled(_ object: K8sObject) -> Bool {
        switch object.kind {
        case .deployment: return deploymentSettled(object)
        case .statefulSet: return statefulSetSettled(object)
        case .daemonSet: return daemonSetSettled(object)
        default: return true
        }
    }

    private static func deploymentSettled(_ object: K8sObject) -> Bool {
        let status = object.status
        guard generation(of: object) <= count(status, "observedGeneration") else { return false }
        let progressing = status?["conditions"]?.arrayValue.first {
            $0["type"]?.stringValue == "Progressing"
        }
        if progressing?["reason"]?.stringValue == "ProgressDeadlineExceeded" { return true }
        // kubectl はここで待ち続けるが、止めてあるあいだは入れ替わらない。
        if object.spec?["paused"]?.boolValue == true { return true }
        let updated = count(status, "updatedReplicas")
        if let desired = object.spec?["replicas"]?.intValue, updated < desired { return false }
        if count(status, "replicas") > updated { return false }
        return count(status, "availableReplicas") >= updated
    }

    private static func statefulSetSettled(_ object: K8sObject) -> Bool {
        let status = object.status
        let strategy = object.spec?["updateStrategy"]
        guard strategy?["type"]?.stringValue == "RollingUpdate" else { return true }
        let observed = count(status, "observedGeneration")
        guard observed != 0, generation(of: object) <= observed else { return false }
        let desired = object.spec?["replicas"]?.intValue
        if let desired, count(status, "readyReplicas") < desired { return false }
        // API サーバが partition: 0 を埋めるので、ふつうはこちらで決まる（kubectl も同じ）。
        if case .object? = strategy?["rollingUpdate"] {
            if let desired,
               let partition = strategy?["rollingUpdate"]?["partition"]?.intValue,
               count(status, "updatedReplicas") < desired - partition {
                return false
            }
            return true
        }
        return (status?["updateRevision"]?.stringValue ?? "")
            == (status?["currentRevision"]?.stringValue ?? "")
    }

    private static func daemonSetSettled(_ object: K8sObject) -> Bool {
        let status = object.status
        guard object.spec?["updateStrategy"]?["type"]?.stringValue == "RollingUpdate" else {
            return true
        }
        guard generation(of: object) <= count(status, "observedGeneration") else { return false }
        let desired = count(status, "desiredNumberScheduled")
        if count(status, "updatedNumberScheduled") < desired { return false }
        return count(status, "numberAvailable") >= desired
    }

    private static func generation(of object: K8sObject) -> Int {
        object.raw.path("metadata.generation")?.intValue ?? 0
    }

    /// Go の構造体に読み込んだときと同じく、無い数は 0 として扱う。
    private static func count(_ value: JSONValue?, _ key: String) -> Int {
        value?[key]?.intValue ?? 0
    }
}

/// 操作のあと、落ち着くまで取り直す対象（`ClusterStore.follow`）。
struct FollowUp: Equatable, Sendable {
    struct Target: Hashable, Sendable {
        enum Goal: Hashable, Sendable {
            /// 一覧から消えるまで。
            case gone
            /// 入れ替わりが終わるまで（`RolloutProgress`）。
            case rolledOut
        }

        let uid: String
        let goal: Goal

        static func gone(_ object: K8sObject) -> Target? {
            object.uid.isEmpty ? nil : Target(uid: object.uid, goal: .gone)
        }

        /// 入れ替わりを判定できない種別は追わない。
        static func rolledOut(_ object: K8sObject) -> Target? {
            guard !object.uid.isEmpty, RolloutProgress.covers(object.kind) else { return nil }
            return Target(uid: object.uid, goal: .rolledOut)
        }

        func isSettled(in objects: [K8sObject]) -> Bool {
            let current = objects.first { $0.uid == uid }
            switch goal {
            case .gone: return current == nil
            // 一覧に無いものは判定できない（別の種別へ移った・消えた）ので追わない。
            case .rolledOut: return current.map(RolloutProgress.isSettled) ?? true
            }
        }
    }

    static let interval: Duration = .seconds(5)
    static let limit: TimeInterval = 5 * 60

    let context: String
    private(set) var targets: Set<Target>
    /// この世代より前に取った一覧では判定しない（操作の前の姿を「落ち着いた」と読まない）。
    private(set) var generation: Int
    private(set) var deadline: Date

    init(context: String, targets: [Target], generation: Int, now: Date) {
        self.context = context
        self.targets = Set(targets)
        self.generation = generation
        self.deadline = now.addingTimeInterval(Self.limit)
    }

    /// 操作が重なったら対象を足し、上限もそこから数え直す。
    mutating func add(_ targets: [Target], generation: Int, now: Date) {
        self.targets.formUnion(targets)
        self.generation = max(self.generation, generation)
        deadline = now.addingTimeInterval(Self.limit)
    }

    /// 取り込めた一覧で、落ち着いた対象を外す。
    mutating func prune(loaded objects: [K8sObject], loadedGeneration: Int) {
        guard loadedGeneration >= generation else { return }
        targets = targets.filter { !$0.isSettled(in: objects) }
    }

    func isFinished(now: Date) -> Bool { targets.isEmpty || now >= deadline }
}

/// 一覧を取ってからの経過を、副題に添える言い方にする。
enum Freshness {
    static func label(since fetched: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(fetched)) / 60)
        if minutes < 1 { return String(localized: "たったいま取得") }
        if minutes < 60 { return String(localized: "\(minutes) 分前に取得") }
        return String(localized: "\(minutes / 60) 時間前に取得")
    }
}
