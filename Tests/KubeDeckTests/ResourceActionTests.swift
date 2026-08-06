import Testing
@testable import KubeDeck

/// 操作の出し分け。
///
/// **入口が 2 つあるので固める。** 一覧の右クリックと詳細パネルのボタンは
/// どちらも `ResourceActionSet` から作る。ここが分かれると
/// **片方からだけ操作できない種別**ができ、しかも足したときには気付けない
/// （`PodLogRequest` の判定を 2 か所に書いて Job のログが詳細から開けなかった、
/// というのを一度踏んでいる）。
@Suite("操作の出し分け")
@MainActor
struct ResourceActionTests {

    private func ids(
        _ objects: [K8sObject], target: ResourceTarget?
    ) -> [String] {
        ResourceActionSet.actions(for: objects, target: target, openLogWindow: { _ in })
            .map(\.id)
    }

    // MARK: - 種別ごと

    @Test("Node には cordon と drain が両方出る（片方だけだと導線が途切れる）")
    func nodeHasCordonAndDrain() {
        let actions = ids([Fixture.node(name: "node-a")], target: .builtIn(.node))
        #expect(actions.contains("cordon"))
        #expect(actions.contains("drain"))
        #expect(!actions.contains("scale"))
    }

    @Test("Deployment にはレプリカ数・再起動・ロールバック・更新の一時停止が出る")
    func deploymentHasRolloutActions() {
        let deployment = Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"web","namespace":"default"},
             "spec":{"replicas":2}}
            """)
        let actions = ids([deployment], target: .builtIn(.deployment))
        #expect(actions.contains("scale"))
        #expect(actions.contains("restart"))
        #expect(actions.contains("rollback"))
        #expect(actions.contains("rollout-pause"))
        #expect(!actions.contains("cordon"))
    }

    /// **押しても必ず失敗するボタンを出さない。** 実測で StatefulSet と
    /// DaemonSet は `pausing is not supported` を返す。ロールバックのほうは効く。
    @Test("StatefulSet / DaemonSet に更新の一時停止は出さない。ロールバックは出す")
    func pauseIsDeploymentOnly() {
        for (kind, name) in [(ResourceKind.statefulSet, "StatefulSet"),
                             (.daemonSet, "DaemonSet")] {
            let object = Fixture.object(
                """
                {"kind":"\(name)","metadata":{"name":"w","namespace":"default"},"spec":{}}
                """)
            let actions = ids([object], target: .builtIn(kind))
            #expect(!actions.contains("rollout-pause"))
            #expect(actions.contains("rollback"))
        }
    }

    /// 止めているものには「再開」を出す。**同じ文言のままにしない** —
    /// 押すと何になるのかが分からない。
    @Test("止めている Deployment には再開が出る")
    func pausedDeploymentOffersResume() {
        let paused = Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"web","namespace":"default"},
             "spec":{"replicas":2,"paused":true}}
            """)
        let action = ResourceActionSet.actions(
            for: [paused], target: .builtIn(.deployment), openLogWindow: { _ in }
        ).first { $0.id == "rollout-pause" }
        #expect(action?.shortTitle == "更新を再開…")
    }

    /// ReplicaSet に rollout は効かない（世代そのものなので戻る先が無い）。
    @Test("ReplicaSet は数を変えられるが、rollout は出さない")
    func replicaSetHasNoRollout() {
        let replicaSet = Fixture.object(
            """
            {"kind":"ReplicaSet","metadata":{"name":"web-abc","namespace":"default"},
             "spec":{"replicas":2}}
            """)
        let actions = ids([replicaSet], target: .builtIn(.replicaSet))
        #expect(actions.contains("scale"))
        #expect(!actions.contains("restart"))
        #expect(!actions.contains("rollback"))
    }

    @Test("Pod はログを開ける。レプリカ数も再起動も出さない")
    func podHasLogs() {
        let actions = ids([Fixture.pod()], target: .builtIn(.pod))
        #expect(actions.contains("logs"))
        #expect(!actions.contains("scale"))
        #expect(!actions.contains("restart"))
    }

    /// **Job からもログを開ける。** 開ける種別の判定は `PodLogRequest` だけが
    /// 持つので、ここが通っていれば一覧からも詳細からも同じように開ける。
    @Test("Job もログを開ける")
    func jobHasLogs() {
        let job = Fixture.object(
            """
            {"kind":"Job","metadata":{"name":"batch","namespace":"default"},
             "spec":{"selector":{"matchLabels":{"controller-uid":"abc"}}}}
            """)
        #expect(ids([job], target: .builtIn(.job)).contains("logs"))
    }

    /// **セレクタを持つものはまとめて開ける。** ここも入口は 1 つ
    /// （`PodLogRequest(group:)`）なので、通っていれば一覧からも詳細からも
    /// 同じように開ける。
    @Test(
        "Deployment / StatefulSet / DaemonSet / ReplicaSet はまとめてログを開ける",
        arguments: [
            (ResourceKind.deployment, "Deployment"),
            (.statefulSet, "StatefulSet"),
            (.daemonSet, "DaemonSet"),
            (.replicaSet, "ReplicaSet"),
        ])
    func workloadHasGroupedLogs(_ kind: ResourceKind, _ name: String) {
        let object = Fixture.object(
            """
            {"kind":"\(name)","metadata":{"name":"web","namespace":"default"},
             "spec":{"selector":{"matchLabels":{"app":"web"}},
                     "template":{"spec":{"containers":[{"name":"app"}]}}}}
            """)
        let actions = ids([object], target: .builtIn(kind))
        #expect(actions.contains("logs-group"))
        // **1 つを読む操作と両方は出さない。** どちらを押したのかで結果が
        // 変わる操作が同じ名前で 2 つ並ぶことになる。
        #expect(!actions.contains("logs"))
    }

    @Test("Service もまとめてログを開ける（掴んでいる Pod がその Service の実体）")
    func serviceHasGroupedLogs() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        #expect(ids([service], target: .builtIn(.service)).contains("logs-group"))
    }

    /// **空のセレクタでは出さない。** `ExternalName` や手書き Endpoints の
    /// Service は Pod を 1 つも掴んでいないので、押しても Namespace の Pod を
    /// 全部読むか、何も出ないかにしかならない。
    @Test("セレクタが空の Service にはログを出さない")
    func serviceWithoutSelectorHasNoLogs() {
        let service = Fixture.service(name: "ext", selector: [:])
        let actions = ids([service], target: .builtIn(.service))
        #expect(!actions.contains("logs-group"))
        #expect(!actions.contains("logs"))
    }

    /// CronJob はセレクタを持たず Job を経由する 2 段なので、ここでは解けない。
    /// **押しても何も出ないボタンを出さない。**
    @Test("CronJob にはログを出さない")
    func cronJobHasNoLogs() {
        let cron = Fixture.object(
            """
            {"kind":"CronJob","metadata":{"name":"nightly","namespace":"default"},
             "spec":{"jobTemplate":{"spec":{}}}}
            """)
        let actions = ids([cron], target: .builtIn(.cronJob))
        #expect(!actions.contains("logs-group"))
        #expect(!actions.contains("logs"))
    }

    @Test("イベントは削除しない（消せる相手ではない）")
    func eventHasNoDelete() {
        let event = Fixture.object(
            """
            {"kind":"Event","metadata":{"name":"e1","namespace":"default"},
             "reason":"Scheduled"}
            """, assuming: .event)
        #expect(!ids([event], target: .builtIn(.event)).contains("delete"))
    }

    // MARK: - 種別が決まらないとき

    /// **押しても何も起きないボタンを出さない。** kubectl に渡す種別名は
    /// 開いている一覧から取るので、それが無いまま削除を出すと黙って空振りする。
    @Test("種別が決まらないときはクラスタを動かす操作を出さない")
    func withoutTargetOnlyHarmlessActions() {
        let actions = ids([Fixture.pod()], target: nil)
        #expect(!actions.contains("delete"))
        #expect(!actions.contains("scale"))
        // ログと名前のコピーは種別名を要らないので残る。
        #expect(actions.contains("logs"))
        #expect(actions.contains("copy-name"))
    }

    // MARK: - 複数選択

    /// **1 つ向けの操作を出さない。** 「ログを見る」がどれのログか決まらない。
    @Test("複数選んでいるときは、まとめてできることだけ")
    func bulkOmitsSingleActions() {
        let objects = [Fixture.pod(name: "a"), Fixture.pod(name: "b")]
        let actions = ids(objects, target: .builtIn(.pod))
        #expect(!actions.contains("logs"))
        #expect(!actions.contains("delete"))
        #expect(actions.contains("delete-many"))
    }

    /// **件数を必ず書く。** 何件に効くのかが出ていないと、見えている選択とは
    /// 別のものが消えたときに気付けない。
    @Test("まとめての操作には件数が入る")
    func bulkTitlesCarryCount() {
        let objects = [Fixture.pod(name: "a"), Fixture.pod(name: "b"), Fixture.pod(name: "c")]
        let actions = ResourceActionSet.actions(
            for: objects, target: .builtIn(.pod), openLogWindow: { _ in })
        let delete = actions.first { $0.id == "delete-many" }
        #expect(delete?.title.contains("3 件") == true)
        #expect(delete?.shortTitle.contains("3 件") == true)
    }

    // MARK: - 危険度

    /// **全部を赤にしない。** 赤の意味が薄れる。消えるものだけ。
    @Test("赤にするのは削除だけ")
    func onlyDeleteIsDestructive() {
        let destructive = ResourceActionSet.actions(
            for: [Fixture.node(name: "node-a")], target: .builtIn(.node),
            openLogWindow: { _ in }
        ).filter { $0.group == .destructive }.map(\.id)
        #expect(destructive == ["delete"])
    }

    /// 詳細パネルのボタンに並ぶのは `utility` を除いたもの。ここが空になると
    /// **パネルからは何も操作できない**ので、種別ごとに 1 つは残ることを見る。
    @Test("ボタンに出すものが、主な種別で空にならない")
    func barIsNotEmpty() {
        for (object, target) in [
            (Fixture.pod(), ResourceTarget.builtIn(.pod)),
            (Fixture.node(name: "node-a"), .builtIn(.node)),
        ] {
            let shown = ResourceActionSet.actions(
                for: [object], target: target, openLogWindow: { _ in }
            ).filter { $0.group != .utility }
            #expect(!shown.isEmpty)
        }
    }
}
