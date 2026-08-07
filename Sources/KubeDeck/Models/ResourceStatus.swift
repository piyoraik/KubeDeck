import Foundation

/// 状態の重み。色はここではなく `Palette` が持つ。
///
/// データ可視化の慣行に従い、状態色は系列色とは別枠の 4 段（good / warning /
/// serious / critical）に固定する。色だけで意味を運ばせないため、UI では必ず
/// ラベル文字列と一緒に出す。
enum StatusLevel: Int, Sendable, Hashable, CaseIterable, Comparable {
    case good = 0
    case warning = 1
    case serious = 2
    case critical = 3
    case neutral = 4

    static func < (lhs: StatusLevel, rhs: StatusLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var symbol: String {
        switch self {
        case .good: return "checkmark.circle.fill"
        case .warning: return "clock.fill"
        case .serious: return "exclamationmark.triangle.fill"
        case .critical: return "xmark.octagon.fill"
        case .neutral: return "minus.circle.fill"
        }
    }

    /// 深刻な順の並び。一覧や内訳で「困っているもの」を上に出すために使う。
    var severityOrder: Int {
        switch self {
        case .critical: return 0
        case .serious: return 1
        case .warning: return 2
        case .good: return 3
        case .neutral: return 4
        }
    }

    var label: String {
        switch self {
        case .good: return String(localized: "正常")
        case .warning: return String(localized: "処理中")
        case .serious: return String(localized: "注意")
        case .critical: return String(localized: "異常")
        case .neutral: return String(localized: "対象外")
        }
    }
}

struct ResourceStatus: Sendable, Hashable {
    let text: String
    let level: StatusLevel

    static let unknown = ResourceStatus(text: "Unknown", level: .serious)
}

// MARK: - 文字列から重みを引く

extension StatusLevel {
    /// 状態文字列の分類。Kubernetes は種別ごとに別の語彙を使うが、
    /// 出てくる語そのものは共通なので 1 箇所にまとめる。
    static func classify(_ reason: String) -> StatusLevel {
        switch reason {
        case "Running", "Succeeded", "Completed", "Ready", "Active", "Bound",
             "Available", "Healthy", "Normal":
            return .good
        case "Pending", "ContainerCreating", "PodInitializing", "Terminating",
             "ContainerStatusUnknown", "Progressing", "Released", "Waiting":
            return .warning
        case "Unknown", "NotReady", "SchedulingDisabled", "Lost", "Suspended",
             "Unschedulable", "NodeLost", "Warning":
            return .serious
        case "Failed", "Error", "CrashLoopBackOff", "ImagePullBackOff",
             "ErrImagePull", "CreateContainerConfigError", "CreateContainerError",
             "InvalidImageName", "OOMKilled", "Evicted", "DeadlineExceeded",
             "BackoffLimitExceeded":
            return .critical
        default:
            // `Init:0/2` や `Init:CrashLoopBackOff` のような複合表記。
            if reason.hasPrefix("Init:") {
                let tail = String(reason.dropFirst("Init:".count))
                let inner = classify(tail)
                return inner == .neutral ? .warning : max(inner, .warning)
            }
            if reason.hasPrefix("Signal:") || reason.hasPrefix("ExitCode:") { return .critical }
            return .neutral
        }
    }
}

// MARK: - 種別ごとの状態

enum StatusResolver {
    static func status(for object: K8sObject) -> ResourceStatus {
        switch object.kind {
        case .pod: return podStatus(object)
        case .node: return nodeStatus(object)
        case .deployment, .statefulSet: return replicaStatus(object)
        case .replicaSet: return replicaSetStatus(object)
        case .daemonSet: return daemonSetStatus(object)
        case .job: return jobStatus(object)
        case .cronJob: return cronJobStatus(object)
        case .horizontalPodAutoscaler: return hpaStatus(object)
        case .persistentVolumeClaim, .persistentVolume, .namespace:
            let phase = object.status?["phase"]?.stringValue ?? "Unknown"
            return ResourceStatus(text: phase, level: StatusLevel.classify(phase))
        case .event:
            let type = object.raw["type"]?.stringValue ?? "Normal"
            // Normal は「起きたこと」の記録でしかなく、正常の保証ではない
            // （BackOff も Normal で出る）。緑の合格印を付けると一覧が
            // 合格印で埋まり、本当に見るべき Warning が沈む。
            return ResourceStatus(text: type, level: type == "Warning" ? .serious : .neutral)
        default:
            return ResourceStatus(text: "", level: .neutral)
        }
    }

    /// 集計と並べ替えに使う重み。
    ///
    /// 一覧の STATUS 列は kubectl の表示に揃える（`status(for:)`）。一方で
    /// ドーナツは「困っているものがあるか」を見る場所なので、Running でも
    /// Ready が揃っていない Pod を正常側に混ぜない。phase は Running のまま
    /// なので、kubectl の STATUS 列だけ見ていると気付けない状態が隠れる。
    static func health(for object: K8sObject) -> ResourceStatus {
        let status = status(for: object)
        guard object.kind == .pod, status.level == .good, status.text == "Running" else {
            // Completed（Ready 0/1 が正常）を巻き込まないよう、Running に限る。
            return status
        }
        let counts = podReady(object)
        guard counts.total > 0, counts.ready < counts.total else { return status }
        return ResourceStatus(
                text: String(localized: "Running (未 Ready)"), level: .warning)
    }

    // MARK: Pod

    /// `kubectl get pods` の STATUS 列の再現。
    ///
    /// phase をそのまま出すと CrashLoopBackOff も ImagePullBackOff も
    /// "Running" に見えてしまう（phase としては Running のため）。
    /// kubectl の printer と同じく containerStatuses まで見る。
    static func podStatus(_ pod: K8sObject) -> ResourceStatus {
        var reason = pod.status?["phase"]?.stringValue ?? "Unknown"
        if let explicit = pod.status?["reason"]?.stringValue, !explicit.isEmpty {
            reason = explicit
        }

        let initStatuses = pod.status?["initContainerStatuses"]?.arrayValue ?? []
        var initializing = false
        for (index, container) in initStatuses.enumerated() {
            let state = container["state"]
            if let terminated = state?["terminated"] {
                if terminated["exitCode"]?.intValue == 0 { continue }
                if let terminatedReason = terminated["reason"]?.stringValue, !terminatedReason.isEmpty {
                    reason = "Init:\(terminatedReason)"
                } else if let signal = terminated["signal"]?.intValue, signal != 0 {
                    reason = "Init:Signal:\(signal)"
                } else {
                    reason = "Init:ExitCode:\(terminated["exitCode"]?.intValue ?? 0)"
                }
            } else if let waiting = state?["waiting"],
                      let waitingReason = waiting["reason"]?.stringValue,
                      !waitingReason.isEmpty, waitingReason != "PodInitializing" {
                reason = "Init:\(waitingReason)"
            } else {
                reason = "Init:\(index)/\(initStatuses.count)"
            }
            initializing = true
            break
        }

        if !initializing {
            var hasRunning = false
            // kubectl と同じく後ろから見る。最後に見つかった異常が表に出る。
            for container in (pod.status?["containerStatuses"]?.arrayValue ?? []).reversed() {
                let state = container["state"]
                if let waiting = state?["waiting"],
                   let waitingReason = waiting["reason"]?.stringValue, !waitingReason.isEmpty {
                    reason = waitingReason
                } else if let terminated = state?["terminated"] {
                    if let terminatedReason = terminated["reason"]?.stringValue, !terminatedReason.isEmpty {
                        reason = terminatedReason
                    } else if let signal = terminated["signal"]?.intValue, signal != 0 {
                        reason = "Signal:\(signal)"
                    } else {
                        reason = "ExitCode:\(terminated["exitCode"]?.intValue ?? 0)"
                    }
                } else if state?["running"] != nil, container["ready"]?.boolValue == true {
                    hasRunning = true
                }
            }
            // Job から作られた Pod で、1 つでも動いていれば Running を優先する。
            if reason == "Completed", hasRunning {
                reason = "Running"
            }
        }

        if pod.isTerminating {
            reason = pod.status?["reason"]?.stringValue == "NodeLost" ? "Unknown" : "Terminating"
        }

        return ResourceStatus(text: reason, level: StatusLevel.classify(reason))
    }

    /// READY 列（`2/3`）と RESTARTS 列。
    static func podReady(_ pod: K8sObject) -> (ready: Int, total: Int) {
        let statuses = pod.status?["containerStatuses"]?.arrayValue ?? []
        let ready = statuses.filter { $0["ready"]?.boolValue == true }.count
        let total = statuses.isEmpty
            ? (pod.spec?["containers"]?.arrayValue.count ?? 0)
            : statuses.count
        return (ready, total)
    }

    static func podRestarts(_ pod: K8sObject) -> Int {
        (pod.status?["containerStatuses"]?.arrayValue ?? [])
            .reduce(0) { $0 + ($1["restartCount"]?.intValue ?? 0) }
    }

    // MARK: Node

    static func nodeStatus(_ node: K8sObject) -> ResourceStatus {
        let conditions = node.status?["conditions"]?.arrayValue ?? []
        let ready = conditions.first { $0["type"]?.stringValue == "Ready" }
        var parts: [String] = []
        var level: StatusLevel

        switch ready?["status"]?.stringValue {
        case "True":
            parts.append("Ready")
            level = .good
        case "False":
            parts.append("NotReady")
            level = .critical
        default:
            parts.append("Unknown")
            level = .serious
        }

        if node.spec?["unschedulable"]?.boolValue == true {
            parts.append("SchedulingDisabled")
            level = max(level, .serious)
        }
        return ResourceStatus(text: parts.joined(separator: ","), level: level)
    }

    static func nodeRoles(_ node: K8sObject) -> String {
        let roles = node.labels.keys.compactMap { key -> String? in
            if key == "kubernetes.io/role" { return node.labels[key] }
            guard key.hasPrefix("node-role.kubernetes.io/") else { return nil }
            let role = String(key.dropFirst("node-role.kubernetes.io/".count))
            return role.isEmpty ? nil : role
        }
        return roles.isEmpty ? "<none>" : roles.sorted().joined(separator: ",")
    }

    static func nodeInternalIP(_ node: K8sObject) -> String {
        (node.status?["addresses"]?.arrayValue ?? [])
            .first { $0["type"]?.stringValue == "InternalIP" }?["address"]?.stringValue ?? ""
    }

    // MARK: レプリカを持つワークロード

    /// Deployment / StatefulSet。desired と ready の差で色を決める。
    static func replicaStatus(_ object: K8sObject) -> ResourceStatus {
        let desired = object.spec?["replicas"]?.intValue ?? 0
        let ready = object.status?["readyReplicas"]?.intValue ?? 0
        return replicaLevel(ready: ready, desired: desired)
    }

    static func replicaSetStatus(_ object: K8sObject) -> ResourceStatus {
        let desired = object.spec?["replicas"]?.intValue ?? 0
        let ready = object.status?["readyReplicas"]?.intValue ?? 0
        // 旧世代の ReplicaSet は desired 0 が正常な状態なので、異常扱いしない。
        return replicaLevel(ready: ready, desired: desired)
    }

    static func daemonSetStatus(_ object: K8sObject) -> ResourceStatus {
        let desired = object.status?["desiredNumberScheduled"]?.intValue ?? 0
        let ready = object.status?["numberReady"]?.intValue ?? 0
        return replicaLevel(ready: ready, desired: desired)
    }

    static func replicaLevel(ready: Int, desired: Int) -> ResourceStatus {
        let text = "\(ready)/\(desired)"
        if desired == 0 {
            return ResourceStatus(text: text, level: ready == 0 ? .neutral : .warning)
        }
        if ready >= desired { return ResourceStatus(text: text, level: .good) }
        if ready == 0 { return ResourceStatus(text: text, level: .critical) }
        return ResourceStatus(text: text, level: .warning)
    }

    // MARK: Job / CronJob

    static func jobStatus(_ job: K8sObject) -> ResourceStatus {
        let conditions = job.status?["conditions"]?.arrayValue ?? []
        if conditions.contains(where: {
            $0["type"]?.stringValue == "Failed" && $0["status"]?.stringValue == "True"
        }) {
            return ResourceStatus(text: "Failed", level: .critical)
        }
        if conditions.contains(where: {
            $0["type"]?.stringValue == "Complete" && $0["status"]?.stringValue == "True"
        }) {
            return ResourceStatus(text: "Complete", level: .good)
        }
        let active = job.status?["active"]?.intValue ?? 0
        return active > 0
            ? ResourceStatus(text: "Running", level: .warning)
            : ResourceStatus(text: "Pending", level: .warning)
    }

    static func cronJobStatus(_ cronJob: K8sObject) -> ResourceStatus {
        if cronJob.spec?["suspend"]?.boolValue == true {
            return ResourceStatus(text: "Suspended", level: .serious)
        }
        return ResourceStatus(text: "Active", level: .good)
    }

    /// HPA の状態。
    ///
    /// **数だけ見て「正常」にしない。** 指標が引けていない HPA は、
    /// レプリカ数がぴたりと揃ったまま**何もしない**。数字の上では健全に
    /// 見えるので、`ScalingActive=False` をここで表に出さないと気付けない
    /// （metrics-server が落ちている環境でいちばん起きる）。
    static func hpaStatus(_ hpa: K8sObject) -> ResourceStatus {
        let conditions = hpa.status?["conditions"]?.arrayValue ?? []

        func failing(_ type: String) -> String? {
            guard let condition = conditions.first(where: {
                $0["type"]?.stringValue == type
            }), condition["status"]?.stringValue == "False" else { return nil }
            // 理由（`FailedGetResourceMetric` など）のほうが対処に直結する。
            let reason = condition["reason"]?.stringValue ?? ""
            return reason.isEmpty ? "\(type)=False" : reason
        }

        if let reason = failing("AbleToScale") {
            return ResourceStatus(text: reason, level: .serious)
        }
        if let reason = failing("ScalingActive") {
            return ResourceStatus(text: reason, level: .serious)
        }

        let current = hpa.status?["currentReplicas"]?.intValue
        let desired = hpa.status?["desiredReplicas"]?.intValue
        if let current, let desired, current != desired {
            return ResourceStatus(text: "Scaling", level: .warning)
        }

        // **条件が無いことを異常にしない。** `autoscaling/v1` は conditions を
        // 持たず、動いていても空で返る。
        return ResourceStatus(text: "Active", level: .good)
    }
}
