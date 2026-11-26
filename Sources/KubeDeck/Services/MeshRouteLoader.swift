import Foundation

/// メッシュの経路を引けたかどうか。
enum MeshRouteAvailability: Sendable, Equatable {
    /// 設定で切ってある。
    case off
    case loaded
    /// クラスタがその種別を知らない（Gateway API が入っていない）。
    case absent
    case unreadable(String)

    /// 経路を起点の種別に出すか。切ってある・種別が無いと分かったときだけ出さない。
    var offersRoutes: Bool {
        switch self {
        case .loaded, .unreadable: return true
        case .off, .absent: return false
        }
    }
}

/// 経路（Gateway API の HTTPRoute）の取得。設定で有効にしたときだけ引く。
@MainActor
enum MeshRouteLoader {
    static let resourceName = "httproutes.gateway.networking.k8s.io"

    struct Loaded: Sendable {
        var routes: [TrafficRoute] = []
        var availability: MeshRouteAvailability = .off
    }

    /// 知らない種別を繰り返したずねると API の一覧を引き直させるので、しばらく覚えておく。
    private static var absentSince: [String: Date] = [:]
    private static let absentLifetime: TimeInterval = 600

    /// 人が更新を押したとき。入れたばかりの CRD を拾えるようにする。
    static func forget() {
        absentSince = [:]
    }

    static func load(context: String, namespace: String?) async -> Loaded {
        guard Preferences.shared.showsMeshRoutes else {
            forget()
            return Loaded()
        }
        if let since = absentSince[context], Date().timeIntervalSince(since) < absentLifetime {
            return Loaded(availability: .absent)
        }
        do {
            let objects = try await Kubectl.shared.list(
                resource: resourceName, namespaced: true, context: context, namespace: namespace)
            absentSince[context] = nil
            return Loaded(routes: TrafficRoute.routes(from: objects), availability: .loaded)
        } catch {
            if isUnknownKind(error) {
                absentSince[context] = Date()
                return Loaded(availability: .absent)
            }
            return Loaded(availability: .unreadable(error.localizedDescription))
        }
    }

    /// 「その種別は無い」と言えるのは、API の一覧に照らして確かめられたときだけ。
    nonisolated static func isUnknownKind(_ error: any Error) -> Bool {
        if case APIDiscoveryError.unknownResource = error { return true }
        if let command = error as? CommandError {
            let text = command.rawStderr.isEmpty ? command.message : command.rawStderr
            return command.discoveryWasFresh && text.contains("doesn't have a resource type")
        }
        return false
    }
}
