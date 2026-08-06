import Foundation
@testable import KubeDeck

/// 合成 JSON から `K8sObject` を起こす。
///
/// **実クラスタを要らなくするための土台。** 異常系（CrashLoopBackOff、
/// `Init:`、Terminating、OOMKilled）はクラスタを汚さずに作れるほうが速いし、
/// 手元のクラスタの状態に結果が左右されない。
enum Fixture {
    static func object(_ json: String, assuming kind: ResourceKind? = nil) -> K8sObject {
        let value = try! JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return K8sObject(raw: value, assuming: kind)!
    }

    // MARK: - Pod

    /// コンテナの状態をそのまま渡して Pod を組む。
    static func pod(
        name: String = "web-0",
        namespace: String = "default",
        phase: String = "Running",
        reason: String? = nil,
        deleted: Bool = false,
        labels: [String: String] = [:],
        node: String? = "node-a",
        owner: (kind: String, name: String)? = nil,
        containerStatuses: String = "[]",
        initContainerStatuses: String = "[]",
        containers: String = "[]",
        initContainers: String = "[]",
        volumes: String = "[]",
        imagePullSecrets: [String] = [],
        serviceAccount: String? = nil
    ) -> K8sObject {
        let accountJSON = serviceAccount.map { #""serviceAccountName":"\#($0)","# } ?? ""
        let pullNames = imagePullSecrets
            .map { #"{"name":"\#($0)"}"# }
            .joined(separator: ",")
        let pullJSON = imagePullSecrets.isEmpty ? "" : #","imagePullSecrets":[\#(pullNames)]"#
        let ownerJSON = owner.map {
            """
            ,"ownerReferences":[{"kind":"\($0.kind)","name":"\($0.name)","controller":true}]
            """
        } ?? ""
        let deletionJSON = deleted ? #","deletionTimestamp":"2026-01-01T00:00:00Z""# : ""
        let reasonJSON = reason.map { #","reason":"\#($0)""# } ?? ""
        let nodeJSON = node.map { #""nodeName":"\#($0)","# } ?? ""

        return object(
            """
            {
              "kind": "Pod",
              "metadata": {
                "name": "\(name)",
                "namespace": "\(namespace)",
                "uid": "\(namespace)-\(name)",
                "labels": \(dictionary(labels))
                \(ownerJSON)
                \(deletionJSON)
              },
              "spec": { \(nodeJSON) \(accountJSON) "containers": \(containers),
                        "initContainers": \(initContainers),
                        "volumes": \(volumes)\(pullJSON) },
              "status": {
                "phase": "\(phase)"\(reasonJSON),
                "containerStatuses": \(containerStatuses),
                "initContainerStatuses": \(initContainerStatuses)
              }
            }
            """, assuming: .pod)
    }

    /// `waiting` / `terminated` / `running` のどれか 1 つを持つコンテナ。
    static func containerStatus(
        name: String = "app", ready: Bool = true, restarts: Int = 0, state: String
    ) -> String {
        """
        {"name":"\(name)","ready":\(ready),"restartCount":\(restarts),"state":\(state)}
        """
    }

    static func waiting(_ reason: String) -> String {
        #"{"waiting":{"reason":"\#(reason)"}}"#
    }

    static func terminated(reason: String? = nil, exitCode: Int = 0, signal: Int? = nil) -> String {
        var parts = [#""exitCode":\#(exitCode)"#]
        if let reason { parts.append(#""reason":"\#(reason)""#) }
        if let signal { parts.append(#""signal":\#(signal)"#) }
        return #"{"terminated":{\#(parts.joined(separator: ","))}}"#
    }

    static let running = #"{"running":{"startedAt":"2026-01-01T00:00:00Z"}}"#

    /// `spec.containers` / `spec.initContainers` の 1 つ。割り当てだけを書く。
    /// 書かなかった項目は `resources` に現れない（「0」ではなく「未設定」）。
    static func container(
        name: String = "app",
        cpuRequest: String? = nil, memoryRequest: String? = nil,
        cpuLimit: String? = nil, memoryLimit: String? = nil
    ) -> String {
        func quantities(_ cpu: String?, _ memory: String?) -> String? {
            var parts: [String] = []
            if let cpu { parts.append(#""cpu":"\#(cpu)""#) }
            if let memory { parts.append(#""memory":"\#(memory)""#) }
            return parts.isEmpty ? nil : "{\(parts.joined(separator: ","))}"
        }
        var fields: [String] = []
        if let requests = quantities(cpuRequest, memoryRequest) {
            fields.append(#""requests":\#(requests)"#)
        }
        if let limits = quantities(cpuLimit, memoryLimit) {
            fields.append(#""limits":\#(limits)"#)
        }
        return #"{"name":"\#(name)","resources":{\#(fields.joined(separator: ","))}}"#
    }

    // MARK: - そのほかの種別

    static func node(name: String, cpu: String = "8", memory: String = "16Gi") -> K8sObject {
        object(
            """
            {
              "kind": "Node",
              "metadata": {"name": "\(name)", "uid": "node-\(name)"},
              "spec": {},
              "status": {
                "allocatable": {"cpu": "\(cpu)", "memory": "\(memory)"},
                "conditions": [{"type": "Ready", "status": "True"}]
              }
            }
            """, assuming: .node)
    }

    static func service(
        name: String, namespace: String = "default", selector: [String: String]
    ) -> K8sObject {
        object(
            """
            {
              "kind": "Service",
              "metadata": {"name": "\(name)", "namespace": "\(namespace)",
                           "uid": "\(namespace)-svc-\(name)"},
              "spec": {"selector": \(dictionary(selector))}
            }
            """, assuming: .service)
    }

    static func ingress(
        name: String, namespace: String = "default", backends: [String],
        tlsSecrets: [String] = []
    ) -> K8sObject {
        let paths = backends
            .map { #"{"backend":{"service":{"name":"\#($0)"}}}"# }
            .joined(separator: ",")
        let tlsJSON = tlsSecrets.isEmpty
            ? ""
            : #","tls":[\#(tlsSecrets.map { #"{"secretName":"\#($0)"}"# }.joined(separator: ","))]"#
        return object(
            """
            {
              "kind": "Ingress",
              "metadata": {"name": "\(name)", "namespace": "\(namespace)",
                           "uid": "\(namespace)-ing-\(name)"},
              "spec": {"rules": [{"http": {"paths": [\(paths)]}}]\(tlsJSON)}
            }
            """, assuming: .ingress)
    }

    /// **`phase` は既定で `volumeName` から決める。** 束ねる先が無いのに
    /// `Bound` という組み合わせは実際には起きないので、合成でも作らない。
    static func claim(
        name: String, namespace: String = "default", volumeName: String? = nil,
        phase: String? = nil, requested: String? = nil
    ) -> K8sObject {
        var spec: [String] = []
        if let volumeName { spec.append(#""volumeName":"\#(volumeName)""#) }
        if let requested {
            spec.append(#""resources":{"requests":{"storage":"\#(requested)"}}"#)
        }
        return object(
            """
            {
              "kind": "PersistentVolumeClaim",
              "metadata": {"name": "\(name)", "namespace": "\(namespace)",
                           "uid": "\(namespace)-pvc-\(name)"},
              "spec": {\(spec.joined(separator: ","))},
              "status": {"phase": "\(phase ?? (volumeName == nil ? "Pending" : "Bound"))"}
            }
            """, assuming: .persistentVolumeClaim)
    }

    /// `claimRef` は**バインドしたコントローラが書く事実**。`phase` と組で
    /// 渡せるようにしてあるのは、`Released`（PVC は消えた）と `Bound`（PVC は
    /// 在るが手元に引けていない）を作り分けるため。
    static func volume(
        name: String, capacity: String = "10Gi", storageClass: String = "standard",
        phase: String? = nil, claimRef: (namespace: String?, name: String)? = nil
    ) -> K8sObject {
        var spec = [#""storageClassName":"\#(storageClass)""#]
        if let claimRef {
            let ns = claimRef.namespace.map { #""namespace":"\#($0)","# } ?? ""
            spec.append(#""claimRef":{\#(ns)"name":"\#(claimRef.name)"}"#)
        }
        let phaseJSON = phase.map { #""phase":"\#($0)","# } ?? ""
        return object(
            """
            {
              "kind": "PersistentVolume",
              "metadata": {"name": "\(name)", "uid": "pv-\(name)"},
              "spec": {\(spec.joined(separator: ","))},
              "status": {\(phaseJSON) "capacity": {"storage": "\(capacity)"}}
            }
            """, assuming: .persistentVolume)
    }

    static func policy(
        name: String, namespace: String = "default", selector: [String: String],
        egress: Bool = false
    ) -> K8sObject {
        let egressJSON = egress ? #","egress":[],"policyTypes":["Ingress","Egress"]"# : ""
        return object(
            """
            {
              "kind": "NetworkPolicy",
              "metadata": {"name": "\(name)", "namespace": "\(namespace)",
                           "uid": "\(namespace)-np-\(name)"},
              "spec": {"podSelector": {"matchLabels": \(dictionary(selector))}\(egressJSON)}
            }
            """, assuming: .networkPolicy)
    }

    /// RoleBinding / ClusterRoleBinding。`namespace` が nil なら後者。
    static func binding(
        name: String, namespace: String?, role: (kind: String, name: String),
        subjects: [(kind: String, name: String, namespace: String?)]
    ) -> K8sObject {
        let kind = namespace == nil ? "ClusterRoleBinding" : "RoleBinding"
        let namespaceJSON = namespace.map { #""namespace":"\#($0)","# } ?? ""
        let subjectsJSON = subjects
            .map { subject in
                let ns = subject.namespace.map { #","namespace":"\#($0)""# } ?? ""
                return #"{"kind":"\#(subject.kind)","name":"\#(subject.name)"\#(ns)}"#
            }
            .joined(separator: ",")
        return object(
            """
            {
              "kind": "\(kind)",
              "metadata": {"name": "\(name)", \(namespaceJSON)
                           "uid": "\(namespace ?? "-")-rb-\(name)"},
              "roleRef": {"kind": "\(role.kind)", "name": "\(role.name)"},
              "subjects": [\(subjectsJSON)]
            }
            """, assuming: namespace == nil ? .clusterRoleBinding : .roleBinding)
    }

    /// ReplicaSet / Job など、Pod と親ワークロードのあいだにあるもの。
    static func controller(
        kind: String, name: String, namespace: String = "default",
        owner: (kind: String, name: String)?
    ) -> K8sObject {
        let ownerJSON = owner.map {
            """
            ,"ownerReferences":[{"kind":"\($0.kind)","name":"\($0.name)","controller":true}]
            """
        } ?? ""
        return object(
            """
            {
              "kind": "\(kind)",
              "metadata": {"name": "\(name)", "namespace": "\(namespace)",
                           "uid": "\(namespace)-\(kind)-\(name)"\(ownerJSON)},
              "spec": {}, "status": {}
            }
            """)
    }

    private static func dictionary(_ values: [String: String]) -> String {
        let pairs = values.keys.sorted()
            .map { #""\#($0)":"\#(values[$0]!)""# }
            .joined(separator: ",")
        return "{\(pairs)}"
    }
}
