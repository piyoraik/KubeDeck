import Foundation
import Testing
@testable import KubeDeck

/// 壊せる力に釣り合う安全側の作り。
///
/// **ここが黙って緩むのがいちばん怖い。** 操作を 1 つ足すたびに
/// 「読み取り専用なのに押せる」「連鎖の説明が付いていない」が起きうるので、
/// 判定そのものを固めておく。
@Suite("安全側の作り")
@MainActor
struct SafetyTests {

    private func actions(
        _ objects: [K8sObject], target: ResourceTarget?, readOnly: Bool
    ) -> [ResourceAction] {
        ResourceActionSet.actions(
            for: objects, target: target, isReadOnly: readOnly, openLogWindow: { _ in })
    }

    // MARK: - 読み取り専用

    /// **穴を 1 つでも残さない。** 押せてしまえば、読み取り専用は約束として
    /// 成り立たない。
    @Test("読み取り専用では、クラスタを動かす操作が 1 つも残らない")
    func readOnlyRemovesEveryMutation() {
        let cases: [(K8sObject, ResourceTarget)] = [
            (Fixture.pod(), .builtIn(.pod)),
            (Fixture.node(name: "node-a"), .builtIn(.node)),
            (Fixture.object("""
                {"kind":"Deployment","metadata":{"name":"web","namespace":"d"},
                 "spec":{"replicas":1}}
                """), .builtIn(.deployment)),
        ]
        for (object, target) in cases {
            #expect(actions([object], target: target, readOnly: true).allSatisfy { !$0.mutates })
        }
    }

    /// **読めるものまで消さない。** ログが見られない「読み取り専用」は、
    /// 読み取り専用ではなくただ使えないだけ。
    @Test("読み取り専用でも、読むだけの操作は残る")
    func readOnlyKeepsHarmlessActions() {
        let ids = actions([Fixture.pod()], target: .builtIn(.pod), readOnly: true).map(\.id)
        #expect(ids.contains("logs"))
        #expect(ids.contains("logs-window"))
        #expect(ids.contains("copy-name"))
        #expect(!ids.contains("delete"))
        // exec は入ってしまえば中で何でもできるので、読むだけには数えない。
        #expect(!ids.contains("exec"))
    }

    @Test("読み取り専用でなければ、これまでどおり全部出る")
    func writableKeepsEverything() {
        let ids = actions([Fixture.pod()], target: .builtIn(.pod), readOnly: false).map(\.id)
        #expect(ids.contains("delete"))
        #expect(ids.contains("exec"))
    }

    /// **まとめて削除も塞ぐ。** 1 件ずつを塞いで複数を通すと、いちばん被害の
    /// 大きい経路だけが開いたままになる。
    @Test("読み取り専用では、まとめて削除も出ない")
    func readOnlyBlocksBulkDelete() {
        let objects = [Fixture.pod(name: "a"), Fixture.pod(name: "b")]
        let ids = actions(objects, target: .builtIn(.pod), readOnly: true).map(\.id)
        #expect(!ids.contains("delete-many"))
        #expect(ids.contains("copy-names"))
    }

    // MARK: - 削除の確認

    /// **種別を問わず同じ文面にしない。** 取り返しのつかなさがまるで違う。
    @Test("削除の確認に、種別ごとの連鎖が書いてある")
    func deleteMessagesExplainCascade() {
        let namespace = PendingAction.delete(
            Fixture.object("""
                {"kind":"Namespace","metadata":{"name":"prod"}}
                """, assuming: .namespace),
            kindName: "Namespace")
        #expect(namespace.message.contains("すべて一緒に消えます"))

        let claim = PendingAction.delete(
            Fixture.claim(name: "data", namespace: "d"), kindName: "PersistentVolumeClaim")
        #expect(claim.message.contains("データごと消えます"))

        let deployment = PendingAction.delete(
            Fixture.object("""
                {"kind":"Deployment","metadata":{"name":"web","namespace":"d"}}
                """),
            kindName: "Deployment")
        #expect(deployment.message.contains("Pod も一緒に消えます"))
    }

    /// **安心できることも書く。** 作り直される Pod を怖がらせない。
    @Test("所有者のいる Pod は、作り直されることを書く")
    func podDeleteSaysItComesBack() {
        let message = PendingAction.delete(Fixture.pod(), kindName: "Pod").message
        #expect(message.contains("作り直されます"))
    }

    /// **数を絞る。** 何にでも打ち込ませると、読まずに写す作業になる。
    @Test("打ち込ませるのは Namespace の削除だけ")
    func onlyNamespaceNeedsTyping() {
        let namespace = Fixture.object("""
            {"kind":"Namespace","metadata":{"name":"prod"}}
            """, assuming: .namespace)
        #expect(PendingAction.delete(namespace, kindName: "Namespace")
            .requiredPhrase == "prod")
        #expect(PendingAction.delete(Fixture.pod(), kindName: "Pod")
            .requiredPhrase == nil)
        // まとめて消すときも、1 つでも混ざっていれば打たせる。
        #expect(PendingAction.deleteMany([namespace, Fixture.pod()], kindName: "Namespace")
            .requiredPhrase != nil)
        #expect(PendingAction.deleteMany(
            [Fixture.pod(name: "a"), Fixture.pod(name: "b")], kindName: "Pod")
            .requiredPhrase == nil)
    }

    // MARK: - コンテキストの札

    /// **既定のままのものを覚えない。** 覚えると、触るたびに中身の無い項目が増える。
    @Test("空の覚え書きは保存しない")
    func emptyProfilesAreNotStored() {
        let preferences = Preferences.shared
        let saved = preferences.contextProfiles
        defer { preferences.contextProfiles = saved }

        preferences.contextProfiles = [:]
        preferences.setProfile(ContextProfile(tint: .red), for: "prod")
        #expect(preferences.contextProfiles["prod"] != nil)

        preferences.setProfile(ContextProfile(), for: "prod")
        #expect(preferences.contextProfiles["prod"] == nil)
    }

    /// **状態の 4 色と混ぜない。** 同じ「赤」でも意味が違う。
    @Test("札の色は、状態の色と別の値を持つ")
    func contextTintIsNotStatusColor() {
        #expect(Palette.color(for: ContextTint.none) == nil)
        #expect(Palette.color(for: ContextTint.red) != nil)
        #expect(Palette.color(for: ContextTint.red) != Palette.color(for: StatusLevel.critical))
    }
}

/// ターミナルに渡す使い捨てのファイル。
///
/// **中身にはクラスタ名と Pod 名が入る。** 置き場所と権限を間違えると、
/// 同じマシンの他の利用者に見える。ここは押して確かめられない
/// （Terminal が開いてしまう）ので、書き出すところだけ固める。
@Suite("exec の受け渡し")
struct ExecScriptTests {

    @Test("実行できる形で、本人しか読めない権限で書く")
    func writesExecutablePrivateScript() throws {
        let url = try ExecScript.write(command: "'/usr/bin/true'", title: "ns/pod")
        defer { try? FileManager.default.removeItem(at: url) }

        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.hasPrefix("#!/bin/sh"))
        // `exec` で置き換えるので、抜けた時点でシェルごと終わる。
        #expect(text.contains("exec '/usr/bin/true'"))

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
        #expect(mode as? Int == 0o700)
        #expect(url.pathExtension == "command")
    }

    /// **`/tmp` に置かない。** 他人も読める。
    @Test("置き場所はアプリのキャッシュの中")
    func staysInsideAppCache() throws {
        let url = try ExecScript.write(command: "'/usr/bin/true'", title: "x")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.path.contains("com.piyoraik.KubeDeck"))
        #expect(!url.path.hasPrefix("/tmp/"))
    }
}
