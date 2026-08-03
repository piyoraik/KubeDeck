import Foundation

/// 左サイドバーの分類。Kubernetes Dashboard の並びに合わせてある。
enum ResourceCategory: String, CaseIterable, Identifiable, Sendable {
    case workloads
    case network
    case config
    case cluster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workloads: return "ワークロード"
        case .network: return "ネットワーク"
        case .config: return "設定と保存"
        case .cluster: return "クラスタ"
        }
    }
}

/// 扱うリソース種別。
enum ResourceKind: String, CaseIterable, Identifiable, Sendable {
    case pod
    case deployment
    case replicaSet
    case statefulSet
    case daemonSet
    case job
    case cronJob
    /// **ワークロードに置く。** レプリカ数を決めているのはこれなので、
    /// 一覧で Deployment の隣に並んでいないと、なぜ数が動くのか辿れない。
    case horizontalPodAutoscaler

    case service
    case ingress

    case configMap
    case secret
    case persistentVolumeClaim

    case persistentVolume
    case node
    case namespace
    case event

    var id: String { rawValue }

    /// `kubectl get <これ>` に渡す名前。
    var resourceName: String {
        switch self {
        case .pod: return "pods"
        case .deployment: return "deployments"
        case .replicaSet: return "replicasets"
        case .statefulSet: return "statefulsets"
        case .daemonSet: return "daemonsets"
        case .job: return "jobs"
        case .cronJob: return "cronjobs"
        // **API グループを付ける。** `autoscaling` は v1 / v2 が併存し、
        // 短い名前だと環境によって別のバージョンを引く。
        case .horizontalPodAutoscaler: return "horizontalpodautoscalers.autoscaling"
        case .service: return "services"
        case .ingress: return "ingresses"
        case .configMap: return "configmaps"
        case .secret: return "secrets"
        case .persistentVolumeClaim: return "persistentvolumeclaims"
        case .persistentVolume: return "persistentvolumes"
        case .node: return "nodes"
        case .namespace: return "namespaces"
        case .event: return "events"
        }
    }

    /// API が返す `kind`。複数種別をまとめて get したときの振り分けに使う。
    var apiKind: String {
        switch self {
        case .pod: return "Pod"
        case .deployment: return "Deployment"
        case .replicaSet: return "ReplicaSet"
        case .statefulSet: return "StatefulSet"
        case .daemonSet: return "DaemonSet"
        case .job: return "Job"
        case .cronJob: return "CronJob"
        case .horizontalPodAutoscaler: return "HorizontalPodAutoscaler"
        case .service: return "Service"
        case .ingress: return "Ingress"
        case .configMap: return "ConfigMap"
        case .secret: return "Secret"
        case .persistentVolumeClaim: return "PersistentVolumeClaim"
        case .persistentVolume: return "PersistentVolume"
        case .node: return "Node"
        case .namespace: return "Namespace"
        case .event: return "Event"
        }
    }

    init?(apiKind: String) {
        guard let match = ResourceKind.allCases.first(where: { $0.apiKind == apiKind }) else {
            return nil
        }
        self = match
    }

    var displayName: String {
        switch self {
        case .pod: return "Pod"
        case .deployment: return "Deployment"
        case .replicaSet: return "ReplicaSet"
        case .statefulSet: return "StatefulSet"
        case .daemonSet: return "DaemonSet"
        case .job: return "Job"
        case .cronJob: return "CronJob"
        // 略さない。サイドバーで `PersistentVolumeClaim` と並ぶので、
        // ここだけ `HPA` にすると別の何かに見える。
        case .horizontalPodAutoscaler: return "HorizontalPodAutoscaler"
        case .service: return "Service"
        case .ingress: return "Ingress"
        case .configMap: return "ConfigMap"
        case .secret: return "Secret"
        case .persistentVolumeClaim: return "PersistentVolumeClaim"
        case .persistentVolume: return "PersistentVolume"
        case .node: return "Node"
        case .namespace: return "Namespace"
        case .event: return "イベント"
        }
    }

    var category: ResourceCategory {
        switch self {
        case .pod, .deployment, .replicaSet, .statefulSet, .daemonSet, .job, .cronJob,
             .horizontalPodAutoscaler:
            return .workloads
        case .service, .ingress:
            return .network
        case .configMap, .secret, .persistentVolumeClaim:
            return .config
        case .persistentVolume, .node, .namespace, .event:
            // PersistentVolume はクラスタ全体のもので Namespace に属さない。
            // Kubernetes Dashboard も「クラスタ」に置いている。
            return .cluster
        }
    }

    /// Namespace に属さないもの（Namespace 絞り込みを効かせない）。
    var isNamespaced: Bool {
        switch self {
        case .node, .namespace, .persistentVolume: return false
        default: return true
        }
    }

    var symbol: String {
        switch self {
        case .pod: return "shippingbox"
        case .deployment: return "square.stack.3d.up"
        case .replicaSet: return "square.on.square"
        case .statefulSet: return "cylinder.split.1x2"
        case .daemonSet: return "square.grid.3x3"
        case .job: return "checkmark.seal"
        case .cronJob: return "clock.arrow.circlepath"
        case .horizontalPodAutoscaler: return "arrow.up.arrow.down.circle"
        case .service: return "network"
        case .ingress: return "arrow.down.right.and.arrow.up.left"
        case .configMap: return "doc.text"
        case .secret: return "key"
        case .persistentVolumeClaim: return "externaldrive"
        case .persistentVolume: return "internaldrive"
        case .node: return "server.rack"
        case .namespace: return "folder"
        case .event: return "bell"
        }
    }

    /// `kubectl scale` が効く種別。
    var isScalable: Bool {
        switch self {
        case .deployment, .statefulSet, .replicaSet: return true
        default: return false
        }
    }

    /// `kubectl rollout restart` が効く種別。
    var isRestartable: Bool {
        switch self {
        case .deployment, .statefulSet, .daemonSet: return true
        default: return false
        }
    }

    static func kinds(in category: ResourceCategory) -> [ResourceKind] {
        allCases.filter { $0.category == category }
    }
}
