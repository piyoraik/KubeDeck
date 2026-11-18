import Foundation
import Testing
@testable import KubeDeck

/// `kubectl rollout status`（k8s.io/kubectl の polymorphichelpers/rollout_status.go）と同じ判定か。
@Suite("入れ替わりが終わったか")
struct RolloutProgressTests {

    private func deployment(
        generation: Int = 2, observed: Int = 2, replicas: Int = 3,
        statusReplicas: Int? = nil, updated: Int = 3, available: Int = 3,
        paused: Bool = false, progressingReason: String? = nil
    ) -> K8sObject {
        let conditions = progressingReason.map {
            #","conditions":[{"type":"Progressing","status":"False","reason":"\#($0)"}]"#
        } ?? ""
        return Fixture.object("""
            {"kind":"Deployment",
             "metadata":{"name":"web","namespace":"default","uid":"web","generation":\(generation)},
             "spec":{"replicas":\(replicas),"paused":\(paused)},
             "status":{"observedGeneration":\(observed),"replicas":\(statusReplicas ?? updated),
                       "updatedReplicas":\(updated),"availableReplicas":\(available)\(conditions)}}
            """)
    }

    private func statefulSet(
        generation: Int = 2, observed: Int = 2, replicas: Int = 3, ready: Int = 3,
        updated: Int = 3,
        strategy: String = #"{"type":"RollingUpdate","rollingUpdate":{"partition":0}}"#,
        currentRevision: String = "db-1", updateRevision: String = "db-1"
    ) -> K8sObject {
        Fixture.object("""
            {"kind":"StatefulSet",
             "metadata":{"name":"db","namespace":"default","uid":"db","generation":\(generation)},
             "spec":{"replicas":\(replicas),"updateStrategy":\(strategy)},
             "status":{"observedGeneration":\(observed),"readyReplicas":\(ready),
                       "updatedReplicas":\(updated),
                       "currentRevision":"\(currentRevision)","updateRevision":"\(updateRevision)"}}
            """)
    }

    private func daemonSet(
        generation: Int = 2, observed: Int = 2, desired: Int = 3, updated: Int = 3,
        available: Int = 3, strategy: String = "RollingUpdate"
    ) -> K8sObject {
        Fixture.object("""
            {"kind":"DaemonSet",
             "metadata":{"name":"agent","namespace":"kube-system","uid":"agent","generation":\(generation)},
             "spec":{"updateStrategy":{"type":"\(strategy)"}},
             "status":{"observedGeneration":\(observed),"desiredNumberScheduled":\(desired),
                       "updatedNumberScheduled":\(updated),"numberAvailable":\(available)}}
            """)
    }

    @Test("Deployment: 変更を見るまで・新しい版が揃うまで・古い版が消えるまで・使えるまで待つ")
    func deploymentWaits() {
        #expect(!RolloutProgress.isSettled(deployment(generation: 3, observed: 2)))
        #expect(!RolloutProgress.isSettled(deployment(updated: 1)))
        #expect(!RolloutProgress.isSettled(deployment(statusReplicas: 4, updated: 3)))
        #expect(!RolloutProgress.isSettled(deployment(available: 2)))
        #expect(RolloutProgress.isSettled(deployment()))
    }

    /// kubectl はここでエラーを返して待つのをやめる。待っても進まない。
    @Test("Deployment: 進捗の期限切れは追わない")
    func deploymentDeadlineExceeded() {
        #expect(RolloutProgress.isSettled(
            deployment(updated: 1, progressingReason: "ProgressDeadlineExceeded")))
        #expect(!RolloutProgress.isSettled(
            deployment(updated: 1, progressingReason: "ReplicaSetUpdated")))
    }

    /// kubectl とずらしてある唯一の点。kubectl は待ち続けるが、止めてあるあいだは入れ替わらない。
    @Test("Deployment: 止めてあるものは追わない。ただし変更を見るまでは待つ")
    func deploymentPaused() {
        #expect(RolloutProgress.isSettled(deployment(updated: 0, paused: true)))
        #expect(!RolloutProgress.isSettled(deployment(generation: 3, observed: 2, paused: true)))
    }

    @Test("StatefulSet: observedGeneration が 0 のあいだと、Ready が揃うまでは待つ")
    func statefulSetWaits() {
        #expect(!RolloutProgress.isSettled(statefulSet(generation: 1, observed: 0)))
        #expect(!RolloutProgress.isSettled(statefulSet(generation: 3, observed: 2)))
        #expect(!RolloutProgress.isSettled(statefulSet(ready: 2)))
        #expect(RolloutProgress.isSettled(statefulSet()))
    }

    /// API サーバが partition: 0 を埋めるので、ふつうはこちらの枝で決まる。版の一致は見ない（kubectl も同じ）。
    @Test("StatefulSet: partition があれば、その手前まで更新されたら終わり")
    func statefulSetPartition() {
        #expect(!RolloutProgress.isSettled(statefulSet(updated: 2)))
        #expect(RolloutProgress.isSettled(
            statefulSet(currentRevision: "db-1", updateRevision: "db-2")))
        let partitioned = #"{"type":"RollingUpdate","rollingUpdate":{"partition":2}}"#
        #expect(RolloutProgress.isSettled(statefulSet(updated: 1, strategy: partitioned)))
        #expect(!RolloutProgress.isSettled(statefulSet(updated: 0, strategy: partitioned)))
    }

    @Test("StatefulSet: rollingUpdate が無ければ版の一致で決める。OnDelete は追わない")
    func statefulSetRevisionAndOnDelete() {
        let bare = #"{"type":"RollingUpdate"}"#
        #expect(!RolloutProgress.isSettled(
            statefulSet(strategy: bare, currentRevision: "db-1", updateRevision: "db-2")))
        #expect(RolloutProgress.isSettled(statefulSet(strategy: bare)))
        #expect(RolloutProgress.isSettled(
            statefulSet(ready: 0, strategy: #"{"type":"OnDelete"}"#)))
    }

    @Test("DaemonSet: 変更を見るまで・更新が揃うまで・使えるまで待つ。OnDelete は追わない")
    func daemonSetWaits() {
        #expect(!RolloutProgress.isSettled(daemonSet(generation: 3, observed: 2)))
        #expect(!RolloutProgress.isSettled(daemonSet(updated: 2)))
        #expect(!RolloutProgress.isSettled(daemonSet(available: 2)))
        #expect(RolloutProgress.isSettled(daemonSet()))
        #expect(RolloutProgress.isSettled(daemonSet(updated: 0, strategy: "OnDelete")))
    }
}

@Suite("操作のあとの取り直し")
struct FollowUpTests {

    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func rollingDeployment(updated: Int) -> K8sObject {
        Fixture.object("""
            {"kind":"Deployment",
             "metadata":{"name":"web","namespace":"default","uid":"web","generation":2},
             "spec":{"replicas":3},
             "status":{"observedGeneration":2,"replicas":\(updated),
                       "updatedReplicas":\(updated),"availableReplicas":\(updated)}}
            """)
    }

    /// 操作の前の姿は「落ち着いている」ように見える。それで打ち切らない。
    @Test("操作のあとの取得が届くまで判定しない")
    func waitsForFetchAfterOperation() throws {
        let pod = Fixture.pod(deleted: true)
        let target = try #require(FollowUp.Target.gone(pod))
        var followUp = FollowUp(context: "kind", targets: [target], generation: 5, now: start)

        followUp.prune(loaded: [], loadedGeneration: 4)
        #expect(followUp.targets == [target])

        followUp.prune(loaded: [], loadedGeneration: 5)
        #expect(followUp.targets.isEmpty)
    }

    @Test("消したものは一覧から消えるまで追う")
    func goneUntilAbsent() throws {
        let pod = Fixture.pod(deleted: true)
        var followUp = FollowUp(
            context: "kind", targets: [try #require(FollowUp.Target.gone(pod))],
            generation: 1, now: start)

        followUp.prune(loaded: [pod], loadedGeneration: 1)
        #expect(!followUp.isFinished(now: start))

        followUp.prune(loaded: [Fixture.pod(name: "web-1")], loadedGeneration: 2)
        #expect(followUp.isFinished(now: start))
    }

    @Test("入れ替わりは終わるまで追い、一覧に無くなったら追わない")
    func rolledOutUntilSettledOrUnseen() throws {
        let rolling = rollingDeployment(updated: 1)
        let target = try #require(FollowUp.Target.rolledOut(rolling))
        var followUp = FollowUp(context: "kind", targets: [target], generation: 1, now: start)

        followUp.prune(loaded: [rolling], loadedGeneration: 1)
        #expect(followUp.targets == [target])
        followUp.prune(loaded: [rollingDeployment(updated: 3)], loadedGeneration: 2)
        #expect(followUp.targets.isEmpty)

        var unseen = FollowUp(context: "kind", targets: [target], generation: 1, now: start)
        unseen.prune(loaded: [Fixture.pod()], loadedGeneration: 1)
        #expect(unseen.targets.isEmpty)
    }

    @Test("入れ替わりを判定できない種別と、uid の無いものは追わない")
    func untrackable() {
        #expect(FollowUp.Target.rolledOut(Fixture.pod()) == nil)
        let noUID = Fixture.object(#"{"kind":"Deployment","metadata":{"name":"web"}}"#)
        #expect(FollowUp.Target.rolledOut(noUID) == nil)
        #expect(FollowUp.Target.gone(noUID) == nil)
    }

    @Test("上限で打ち切る。操作が重なれば、そこから数え直し、あとの取得まで判定しない")
    func deadlineAndOverlap() throws {
        let first = try #require(FollowUp.Target.gone(Fixture.pod(name: "a")))
        let second = try #require(FollowUp.Target.gone(Fixture.pod(name: "b")))
        var followUp = FollowUp(context: "kind", targets: [first], generation: 1, now: start)

        #expect(!followUp.isFinished(now: start.addingTimeInterval(FollowUp.limit - 1)))
        #expect(followUp.isFinished(now: start.addingTimeInterval(FollowUp.limit)))

        followUp.add([second], generation: 3, now: start.addingTimeInterval(100))
        #expect(!followUp.isFinished(now: start.addingTimeInterval(FollowUp.limit)))
        followUp.prune(loaded: [], loadedGeneration: 2)
        #expect(followUp.targets == [first, second])
    }
}

@Suite("取ってからの経過")
struct FreshnessTests {

    private let fetched = Date(timeIntervalSince1970: 1_000_000)

    private func label(after seconds: TimeInterval) -> String {
        Freshness.label(since: fetched, now: fetched.addingTimeInterval(seconds))
    }

    @Test("1 分未満は「たったいま」。時計が取得より手前でも負にしない")
    func justNow() {
        #expect(label(after: 0) == "たったいま取得")
        #expect(label(after: 59) == "たったいま取得")
        #expect(label(after: -30) == "たったいま取得")
    }

    @Test("分、60 分からは時間で数える")
    func minutesAndHours() {
        #expect(label(after: 60) == "1 分前に取得")
        #expect(label(after: 59 * 60 + 59) == "59 分前に取得")
        #expect(label(after: 60 * 60) == "1 時間前に取得")
        #expect(label(after: 3 * 60 * 60 + 59 * 60) == "3 時間前に取得")
    }
}
