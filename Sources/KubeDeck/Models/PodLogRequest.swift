import Foundation

/// ログウインドウを開くための指定。
///
/// `K8sObject` をそのまま渡さない。ウインドウは一覧より長く生きるうえ、
/// `WindowGroup(for:)` に載せる値は Codable である必要がある。
struct PodLogRequest: Codable, Hashable, Identifiable {
    var namespace: String
    var pod: String
    var containers: [String]

    var id: String { "\(namespace)/\(pod)" }

    init(namespace: String, pod: String, containers: [String]) {
        self.namespace = namespace
        self.pod = pod
        self.containers = containers
    }

    init(pod: K8sObject) {
        self.namespace = pod.namespace ?? ""
        self.pod = pod.name
        self.containers = (pod.spec?["containers"]?.arrayValue ?? [])
            .compactMap { $0["name"]?.stringValue }
    }
}
