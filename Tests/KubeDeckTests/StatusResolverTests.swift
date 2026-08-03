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
