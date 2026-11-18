import Testing
@testable import KubeDeck

/// 絞り込みのメニューに並べる Namespace を、まとめ取りのついでに拾う。
@Suite("Namespace の一覧")
struct NamespaceListTests {

    private static func namespace(_ name: String) -> K8sObject {
        Fixture.object(
            #"{"apiVersion":"v1","kind":"Namespace","metadata":{"name":"\#(name)"}}"#)
    }

    @Test("Namespace だけを名前順で拾う")
    func picksNamespacesSorted() {
        let objects = [
            Self.namespace("kube-system"),
            Fixture.pod(name: "p", namespace: "default"),
            Self.namespace("added-later"),
        ]
        #expect(ClusterStore.namespaceNames(in: objects, uncounted: [])
            == ["added-later", "kube-system"])
    }

    @Test("読めなかったときは空ではなく nil（メニューを空にしない）")
    func unreadIsNil() {
        #expect(ClusterStore.namespaceNames(in: [], uncounted: [.namespace]) == nil)
        #expect(ClusterStore.namespaceNames(in: [], uncounted: [.secret]) == [])
    }
}
