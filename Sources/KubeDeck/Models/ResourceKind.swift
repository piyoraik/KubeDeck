import Foundation

/// 左サイドバーの分類。Kubernetes Dashboard の並びに合わせてある。
enum ResourceCategory: String, CaseIterable, Identifiable, Sendable {
    case workloads
    case network
    case config
    /// **「クラスタ」に混ぜない。** RBAC は 5 種あり、混ぜるとノードや
    /// Namespace が埋もれる。権限を追うときは 5 つを行き来するので、
    /// まとまっているほうが速い。
    case access
    case cluster

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workloads: return String(localized: "ワークロード")
        case .network: return String(localized: "ネットワーク")
        case .config: return String(localized: "設定と保存")
        case .access: return String(localized: "アクセス制御")
        case .cluster: return String(localized: "クラスタ")
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
    /// **drain を止めている当人。** アプリから drain できるのに、何がそれを
    /// 止めているのかを見る手段が無い、という状態にしない。
    case podDisruptionBudget

    case service
    case ingress
    /// **Service と同じ場所に置く。** どちらもラベルで Pod を選ぶもので、
    /// 「外から届くか」を決めているのはこの 2 つ。
    case networkPolicy
    /// **Service に実際に何が繋がっているか。** セレクタからの推測ではなく、
    /// コントローラが書いた事実。「Service はあるのに繋がらない」の切り分けは
    /// ここでしか付かない。
    case endpointSlice

    case configMap
    case secret
    case persistentVolumeClaim
    /// **Namespace で作れない理由。** 上限に当たっていることは、拒まれた
    /// メッセージにしか出ない。
    case resourceQuota
    /// **勝手に既定値が入る理由。** requests を書いていないのに付いている、
    /// 上限を上げたのに弾かれる、はここで決まっている。
    case limitRange

    case serviceAccount
    case role
    case roleBinding
    case clusterRole
    case clusterRoleBinding

    case persistentVolume
    /// **PVC が Pending の理由。** 既定の StorageClass が無い、名前が違う、
    /// といったことはここを見ないと決まらない。
    case storageClass
    /// **追い出された理由。** 優先度は数字だけ見ても大小が分からない。
    case priorityClass
    /// **作成が謎に失敗する理由。** admission webhook は、失敗しても
    /// 「webhook が拒みました」としか出ないことがある。
    case validatingWebhookConfiguration
    case mutatingWebhookConfiguration
    /// **`discoveryHint` が「ここを見ろ」と言っている当の場所。** 集約 API が
    /// 落ちると、その API グループが丸ごと一覧から消える。
    case apiService
    /// **サイドバーに CRD 由来の種別を並べておきながら、定義そのものは
    /// どこからも見られなかった。** `Kubectl.customResourceTypes` は
    /// `kubectl get crd` を引いているのに、group / version / kind / plural /
    /// scope / printerColumns だけ抜いて残りを捨てていた。捨てていたのは
    /// **なぜその種別が使えないのかを説明する当の値**:
    ///
    /// | 捨てていたもの | それが無いと分からないこと |
    /// |---|---|
    /// | `openAPIV3Schema` | CR を作って弾かれた理由（必須項目・validation） |
    /// | `versions[]` の served / storage / deprecated | どの版が正で、どれが非推奨か |
    /// | `status.conditions` | `Established=False`（＝種別がサイドバーに出ない理由そのもの） |
    /// | `conversion` | webhook が落ちていて読み書きできない |
    /// | `subresources` | scale できるか（HPA を付けられるか） |
    ///
    /// しかも CRD を選ぶ画面が無いので、**YAML タブで原文を読む逃げ道も
    /// なかった**（`APIService` を足したのと同じ判断 —— 「なぜ動かないか」を
    /// 説明する側に回る種別は揃える）。
    case customResourceDefinition
    case node
    case namespace
    case event

    var id: String { rawValue }

    /// `kubectl get <これ>` に渡す名前。
    ///
    /// **コアグループにも `.v1.` を付ける。** 「API グループを必ず付ける」を
    /// core だけ免除していたが、**core こそ黙って別グループに流れる**。
    /// 覚えている API の一覧のコアグループが縮退していると
    /// （`{"name":"","versions":null}`。`Kubectl.cacheDirectory` の説明を参照）、
    /// kubectl は `nodes` を core から解決できず、**同じ複数形を持つ
    /// `metrics.k8s.io` へ流れる**。実測（Connect Gateway 越しの GKE、
    /// kubectl v1.32.13）:
    ///
    /// ```
    /// $ kubectl get pods,nodes -o json     # 縮退したキャッシュのまま
    /// exit=0   items = PodMetrics 185 + NodeMetrics 3
    /// $ kubectl get pods.v1.,nodes.v1. -o json
    /// exit=0   items = Pod 225 + Node 3
    /// ```
    ///
    /// **これは「知らない種別」より悪い壊れ方。** `pods` が本当に解決できない
    /// ときは `the server doesn't have a resource type "pods"` で終了コードが
    /// 立つので、`Kubectl.run` の捨てて引き直す網に掛かる。ところがこちらは
    /// **exit 0・200 OK・valid JSON** なので、網が 1 つも発火しない。返るのは
    /// `status.conditions` も `status.allocatable` も持たない NodeMetrics で、
    /// アプリはそれを Node として読み、**全ノードを `Unknown`（橙）と表示し、
    /// 割り当て可能量を 0 にして使用量を消していた。** 誰も嘘をつかないまま
    /// 画面だけが嘘になる。
    ///
    /// 付けても `Kubectl.plural(of:)` が最初の `.` で切るので、stderr との
    /// 突き合わせ（`deniedKinds` / `unknownKinds`）はそのまま働く。`get -o yaml`・
    /// `delete`・`--selector` でも通ることは実測で確かめてある。
    ///
    /// **版まで固定してよい種別だけに付ける。** core は v1 しか無いので、
    /// `autoscaling`（v1 / v2 が併存）のようにグループだけ付ける場合とは違い、
    /// 版を書いても環境で別のものを引く余地が無い。
    var resourceName: String {
        switch self {
        case .pod: return "pods.v1."
        case .deployment: return "deployments"
        case .replicaSet: return "replicasets"
        case .statefulSet: return "statefulsets"
        case .daemonSet: return "daemonsets"
        case .job: return "jobs"
        case .cronJob: return "cronjobs"
        // **API グループを付ける。** `autoscaling` は v1 / v2 が併存し、
        // 短い名前だと環境によって別のバージョンを引く。
        case .horizontalPodAutoscaler: return "horizontalpodautoscalers.autoscaling"
        case .service: return "services.v1."
        case .ingress: return "ingresses"
        // API グループを付ける。`networkpolicies` は Calico など別グループにも
        // 居るので、短い名前だと環境によって別の種別を引く。
        case .networkPolicy: return "networkpolicies.networking.k8s.io"
        case .configMap: return "configmaps.v1."
        case .secret: return "secrets.v1."
        case .persistentVolumeClaim: return "persistentvolumeclaims.v1."
        case .serviceAccount: return "serviceaccounts.v1."
        // RBAC は必ず API グループを付ける。`roles` は別グループにも居る。
        case .role: return "roles.rbac.authorization.k8s.io"
        case .roleBinding: return "rolebindings.rbac.authorization.k8s.io"
        case .clusterRole: return "clusterroles.rbac.authorization.k8s.io"
        case .clusterRoleBinding: return "clusterrolebindings.rbac.authorization.k8s.io"
        case .podDisruptionBudget: return "poddisruptionbudgets.policy"
        case .endpointSlice: return "endpointslices.discovery.k8s.io"
        case .resourceQuota: return "resourcequotas.v1."
        case .limitRange: return "limitranges.v1."
        case .persistentVolume: return "persistentvolumes.v1."
        case .storageClass: return "storageclasses.storage.k8s.io"
        case .priorityClass: return "priorityclasses.scheduling.k8s.io"
        case .validatingWebhookConfiguration:
            return "validatingwebhookconfigurations.admissionregistration.k8s.io"
        case .mutatingWebhookConfiguration:
            return "mutatingwebhookconfigurations.admissionregistration.k8s.io"
        case .apiService: return "apiservices.apiregistration.k8s.io"
        case .customResourceDefinition:
            return "customresourcedefinitions.apiextensions.k8s.io"
        // **`nodes` と `pods` と `events` は同じ複数形が別グループにも居る**
        // （`metrics.k8s.io` / `events.k8s.io`）。実際に流れたのはここ。
        case .node: return "nodes.v1."
        case .namespace: return "namespaces.v1."
        case .event: return "events.v1."
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
        case .networkPolicy: return "NetworkPolicy"
        case .configMap: return "ConfigMap"
        case .secret: return "Secret"
        case .persistentVolumeClaim: return "PersistentVolumeClaim"
        case .serviceAccount: return "ServiceAccount"
        case .role: return "Role"
        case .roleBinding: return "RoleBinding"
        case .clusterRole: return "ClusterRole"
        case .clusterRoleBinding: return "ClusterRoleBinding"
        case .podDisruptionBudget: return "PodDisruptionBudget"
        case .endpointSlice: return "EndpointSlice"
        case .resourceQuota: return "ResourceQuota"
        case .limitRange: return "LimitRange"
        case .persistentVolume: return "PersistentVolume"
        case .storageClass: return "StorageClass"
        case .priorityClass: return "PriorityClass"
        case .validatingWebhookConfiguration: return "ValidatingWebhookConfiguration"
        case .mutatingWebhookConfiguration: return "MutatingWebhookConfiguration"
        case .apiService: return "APIService"
        case .customResourceDefinition: return "CustomResourceDefinition"
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
        case .networkPolicy: return "NetworkPolicy"
        case .configMap: return "ConfigMap"
        case .secret: return "Secret"
        case .persistentVolumeClaim: return "PersistentVolumeClaim"
        case .serviceAccount: return "ServiceAccount"
        case .role: return "Role"
        case .roleBinding: return "RoleBinding"
        case .clusterRole: return "ClusterRole"
        case .clusterRoleBinding: return "ClusterRoleBinding"
        case .podDisruptionBudget: return "PodDisruptionBudget"
        case .endpointSlice: return "EndpointSlice"
        case .resourceQuota: return "ResourceQuota"
        case .limitRange: return "LimitRange"
        case .persistentVolume: return "PersistentVolume"
        case .storageClass: return "StorageClass"
        case .priorityClass: return "PriorityClass"
        case .validatingWebhookConfiguration: return "ValidatingWebhookConfiguration"
        case .mutatingWebhookConfiguration: return "MutatingWebhookConfiguration"
        case .apiService: return "APIService"
        case .customResourceDefinition: return "CustomResourceDefinition"
        case .node: return "Node"
        case .namespace: return "Namespace"
        case .event: return String(localized: "イベント")
        }
    }

    var category: ResourceCategory {
        switch self {
        case .pod, .deployment, .replicaSet, .statefulSet, .daemonSet, .job, .cronJob,
             .horizontalPodAutoscaler, .podDisruptionBudget:
            return .workloads
        case .service, .ingress, .networkPolicy, .endpointSlice:
            return .network
        case .configMap, .secret, .persistentVolumeClaim, .resourceQuota, .limitRange:
            return .config
        case .serviceAccount, .role, .roleBinding, .clusterRole, .clusterRoleBinding:
            return .access
        case .persistentVolume, .node, .namespace, .event, .storageClass, .priorityClass,
             .validatingWebhookConfiguration, .mutatingWebhookConfiguration, .apiService,
             .customResourceDefinition:
            // PersistentVolume はクラスタ全体のもので Namespace に属さない。
            // Kubernetes Dashboard も「クラスタ」に置いている。
            return .cluster
        }
    }

    /// Namespace に属さないもの（Namespace 絞り込みを効かせない）。
    var isNamespaced: Bool {
        switch self {
        case .node, .namespace, .persistentVolume, .clusterRole, .clusterRoleBinding,
             .storageClass, .priorityClass, .validatingWebhookConfiguration,
             .mutatingWebhookConfiguration, .apiService, .customResourceDefinition:
            return false
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
        case .networkPolicy: return "shield.lefthalf.filled"
        case .configMap: return "doc.text"
        case .secret: return "key"
        case .persistentVolumeClaim: return "externaldrive"
        case .serviceAccount: return "person.badge.key"
        case .role: return "checklist"
        case .roleBinding: return "link"
        case .clusterRole: return "list.bullet.rectangle"
        case .clusterRoleBinding: return "link.circle"
        case .podDisruptionBudget: return "shield.lefthalf.filled"
        case .endpointSlice: return "point.3.connected.trianglepath.dotted"
        case .resourceQuota: return "gauge.with.needle"
        case .limitRange: return "arrow.left.and.right.square"
        case .persistentVolume: return "internaldrive"
        case .storageClass: return "square.stack.3d.down.right"
        case .priorityClass: return "arrow.up.arrow.down.square"
        case .validatingWebhookConfiguration: return "checkmark.shield"
        case .mutatingWebhookConfiguration: return "wand.and.rays"
        case .apiService: return "point.topleft.down.curvedto.point.bottomright.up"
        // CRD 由来の種別は `puzzlepiece.extension`。**同じにしない** ――
        // あちらは「この CRD が定義した種別」、こちらは「定義そのもの」。
        case .customResourceDefinition: return "puzzlepiece"
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

    /// `kubectl rollout`（restart / history / undo）が効く種別。
    var supportsRollout: Bool {
        switch self {
        case .deployment, .statefulSet, .daemonSet: return true
        default: return false
        }
    }

    /// `kubectl rollout pause` / `resume` が効く種別。
    ///
    /// **`supportsRollout` と同じにしない。** 実測で StatefulSet と DaemonSet は
    /// `statefulsets.apps "x" pausing is not supported` を返す。同じ集合に
    /// してしまうと、押しても必ず失敗するボタンを出すことになる。
    var supportsRolloutPause: Bool { self == .deployment }

    static func kinds(in category: ResourceCategory) -> [ResourceKind] {
        allCases.filter { $0.category == category }
    }
}
