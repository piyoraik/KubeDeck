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
        volumes: String = "[]"
    ) -> K8sObject {
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
              "spec": { \(nodeJSON) "containers": \(containers), "volumes": \(volumes) },
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
        name: String, namespace: String = "default", backends: [String]
    ) -> K8sObject {
        let paths = backends
            .map { #"{"backend":{"service":{"name":"\#($0)"}}}"# }
            .joined(separator: ",")
        return object(
            """
            {
              "kind": "Ingress",
              "metadata": {"name": "\(name)", "namespace": "\(namespace)",
                           "uid": "\(namespace)-ing-\(name)"},
              "spec": {"rules": [{"http": {"paths": [\(paths)]}}]}
            }
            """, assuming: .ingress)
    }

    static func claim(name: String, namespace: String = "default") -> K8sObject {
        object(
            """
            {
              "kind": "PersistentVolumeClaim",
              "metadata": {"name": "\(name)", "namespace": "\(namespace)",
                           "uid": "\(namespace)-pvc-\(name)"},
              "status": {"phase": "Bound"}
            }
            """, assuming: .persistentVolumeClaim)
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
