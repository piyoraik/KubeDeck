import Testing
@testable import KubeDeck

/// 一覧の STATUS 列は **kubectl の printer の再現**。
/// ドーナツの `health` はそこから 1 段変える。**この 2 つを混ぜない。**
@Suite("状態の判定")
struct StatusResolverTests {

    // MARK: - phase をそのまま出さない

    @Test("phase が Running でも CrashLoopBackOff を隠さない")
    func crashLoopBackOff() {
        let pod = Fixture.pod(
            phase: "Running",
            containerStatuses: "[\(Fixture.containerStatus(ready: false, state: Fixture.waiting("CrashLoopBackOff")))]")

        #expect(StatusResolver.status(for: pod).text == "CrashLoopBackOff")
        #expect(StatusResolver.status(for: pod).level == .critical)
    }

    @Test("ImagePullBackOff も phase の下に隠れている")
    func imagePullBackOff() {
        let pod = Fixture.pod(
            phase: "Pending",
            containerStatuses: "[\(Fixture.containerStatus(ready: false, state: Fixture.waiting("ImagePullBackOff")))]")

        #expect(StatusResolver.status(for: pod).text == "ImagePullBackOff")
    }

    @Test("初期化コンテナは Init:<理由> で出す")
    func initContainerWaiting() {
        let pod = Fixture.pod(
            phase: "Pending",
            initContainerStatuses:
                "[\(Fixture.containerStatus(name: "wait", ready: false, state: Fixture.waiting("ImagePullBackOff")))]")

        #expect(StatusResolver.status(for: pod).text == "Init:ImagePullBackOff")
    }

    @Test("PodInitializing は理由にしない（何番目まで進んだかを出す）")
    func initContainerProgress() {
        let statuses = [
            Fixture.containerStatus(name: "a", ready: false, state: Fixture.waiting("PodInitializing")),
            Fixture.containerStatus(name: "b", ready: false, state: Fixture.waiting("PodInitializing")),
        ].joined(separator: ",")
        let pod = Fixture.pod(phase: "Pending", initContainerStatuses: "[\(statuses)]")

        #expect(StatusResolver.status(for: pod).text == "Init:0/2")
    }

    /// **ネイティブ sidecar を「初期化が終わっていない」と読まない。**
    ///
    /// `spec.initContainers[].restartPolicy: Always`（1.29 で GA。Istio の
    /// sidecar 注入がこの形）は**終了しない**ので、状態は `terminated` でも
    /// `waiting` でもなく `running` のまま。素直に読むと `Init:0/1` で止まり、
    /// **健全に動いている Pod の STATUS が橙のまま固定される**。しかも READY 列は
    /// `containerStatuses` だけを見るので `1/1` と出て、同じ行の中で食い違う。
    /// kubectl の printer は 1.28 以降、`started` の立った restartable init
    /// container を読み飛ばす。
    @Test("started の立ったネイティブ sidecar を Init: 扱いしない")
    func restartableInitContainerIsNotInitializing() {
        let pod = Fixture.object(
            """
            {
              "kind": "Pod",
              "metadata": {"name": "web-0", "namespace": "default", "uid": "u"},
              "spec": {
                "nodeName": "node-a",
                "containers": [{"name": "app"}],
                "initContainers": [{"name": "istio-proxy", "restartPolicy": "Always"}]
              },
              "status": {
                "phase": "Running",
                "conditions": [{"type": "Initialized", "status": "True"}],
                "containerStatuses": [
                  {"name":"app","ready":true,"restartCount":0,
                   "state":{"running":{"startedAt":"2026-01-01T00:00:00Z"}}}
                ],
                "initContainerStatuses": [
                  {"name":"istio-proxy","ready":true,"restartCount":0,"started":true,
                   "state":{"running":{"startedAt":"2026-01-01T00:00:00Z"}}}
                ]
              }
            }
            """, assuming: .pod)

        #expect(StatusResolver.status(for: pod).text == "Running")
        #expect(StatusResolver.status(for: pod).level == .good)
        // **READY も kubectl に揃える。** kubectl は restartable init を
        // total と ready の両方に足すので `2/2`。
        #expect(StatusResolver.podReady(pod).ready == 2)
        #expect(StatusResolver.podReady(pod).total == 2)
    }

    /// **`podStatus` だけ揃えても足りない。**
    ///
    /// sidecar を読み飛ばすようにすると STATUS は `Running` になるが、READY を
    /// `containerStatuses` だけで数えていると `1/1` を返す。すると
    /// `health(for:)` の降格（Running なのに Ready が揃っていない）が発火せず、
    /// **sidecar が Ready でない Pod がドーナツで完全に正常になる**
    /// （kubectl は `1/2` と出す）。kubectl の STATUS 列だけ見ていると
    /// 気付けない状態を表に出す、という `health` の役目がそこだけ抜けていた。
    @Test("Ready でない sidecar を正常側に混ぜない")
    func notReadySidecarIsDegraded() {
        let pod = Fixture.object(
            """
            {
              "kind": "Pod",
              "metadata": {"name": "web-1", "namespace": "default", "uid": "u2"},
              "spec": {
                "nodeName": "node-a",
                "containers": [{"name": "app"}],
                "initContainers": [{"name": "istio-proxy", "restartPolicy": "Always"}]
              },
              "status": {
                "phase": "Running",
                "conditions": [{"type": "Initialized", "status": "True"}],
                "containerStatuses": [
                  {"name":"app","ready":true,"restartCount":0,
                   "state":{"running":{"startedAt":"2026-01-01T00:00:00Z"}}}
                ],
                "initContainerStatuses": [
                  {"name":"istio-proxy","ready":false,"restartCount":2,"started":true,
                   "state":{"running":{"startedAt":"2026-01-01T00:00:00Z"}}}
                ]
              }
            }
            """, assuming: .pod)

        #expect(StatusResolver.podReady(pod).ready == 1)
        #expect(StatusResolver.podReady(pod).total == 2)
        // 再起動も数える（kubectl と同じ。sidecar は落ちても Pod が生き続ける）。
        #expect(StatusResolver.podRestarts(pod) == 2)
        // STATUS は Running のままでも、集計では正常側に混ぜない。
        #expect(StatusResolver.health(for: pod).level != .good)
    }

    @Test("理由の無い異常終了は ExitCode / Signal で出す")
    func terminatedWithoutReason() {
        let byCode = Fixture.pod(
            containerStatuses: "[\(Fixture.containerStatus(ready: false, state: Fixture.terminated(exitCode: 137)))]")
        #expect(StatusResolver.status(for: byCode).text == "ExitCode:137")

        let bySignal = Fixture.pod(
            containerStatuses:
                "[\(Fixture.containerStatus(ready: false, state: Fixture.terminated(exitCode: 0, signal: 9)))]")
        #expect(StatusResolver.status(for: bySignal).text == "Signal:9")
    }

    @Test("OOMKilled は理由がそのまま出る")
    func oomKilled() {
        let pod = Fixture.pod(
            containerStatuses:
                "[\(Fixture.containerStatus(ready: false, state: Fixture.terminated(reason: "OOMKilled", exitCode: 137)))]")

        #expect(StatusResolver.status(for: pod).text == "OOMKilled")
        #expect(StatusResolver.status(for: pod).level == .critical)
    }

    @Test("削除中は Terminating。NodeLost だけは Unknown")
    func terminating() {
        let pod = Fixture.pod(deleted: true)
        #expect(StatusResolver.status(for: pod).text == "Terminating")

        let lost = Fixture.pod(reason: "NodeLost", deleted: true)
        #expect(StatusResolver.status(for: lost).text == "Unknown")
    }

    @Test("Completed でも動いているコンテナがあれば Running を優先する")
    func completedButRunning() {
        let statuses = [
            Fixture.containerStatus(name: "done", ready: false,
                                    state: Fixture.terminated(reason: "Completed")),
            Fixture.containerStatus(name: "live", ready: true, state: Fixture.running),
        ].joined(separator: ",")
        let pod = Fixture.pod(phase: "Running", containerStatuses: "[\(statuses)]")

        #expect(StatusResolver.status(for: pod).text == "Running")
    }

    // MARK: - health は STATUS 列と別物

    @Test("Running だが Ready が揃っていない Pod を正常側に混ぜない")
    func runningButNotReady() {
        let statuses = [
            Fixture.containerStatus(name: "a", ready: true, state: Fixture.running),
            Fixture.containerStatus(name: "b", ready: false, state: Fixture.running),
        ].joined(separator: ",")
        let pod = Fixture.pod(phase: "Running", containerStatuses: "[\(statuses)]")

        // 一覧の列は kubectl と同じ「Running」のまま。
        #expect(StatusResolver.status(for: pod).text == "Running")
        #expect(StatusResolver.status(for: pod).level == .good)
        // 集計では正常側に入れない。
        #expect(StatusResolver.health(for: pod).level == .warning)
    }

    @Test("Completed（Ready 0/1 が正常）を降格に巻き込まない")
    func completedIsNotDegraded() {
        let pod = Fixture.pod(
            phase: "Succeeded",
            containerStatuses:
                "[\(Fixture.containerStatus(ready: false, state: Fixture.terminated(reason: "Completed")))]")

        #expect(StatusResolver.status(for: pod).text == "Completed")
        // health は status をそのまま返す。Running に限って降格するため。
        #expect(StatusResolver.health(for: pod).text == "Completed")
        #expect(StatusResolver.health(for: pod).level == StatusResolver.status(for: pod).level)
    }

    @Test("Ready がすべて揃っていれば降格しない")
    func allReadyStaysGood() {
        let pod = Fixture.pod(
            phase: "Running",
            containerStatuses: "[\(Fixture.containerStatus(ready: true, state: Fixture.running))]")

        #expect(StatusResolver.health(for: pod).level == .good)
    }

    // MARK: - イベント

    @Test("Normal のイベントに合格印を付けない")
    func normalEventIsNeutral() {
        let event = Fixture.object(
            #"{"kind":"Event","metadata":{"name":"e1","namespace":"default"},"type":"Normal"}"#,
            assuming: .event)

        #expect(StatusResolver.status(for: event).level == .neutral)
    }
}
