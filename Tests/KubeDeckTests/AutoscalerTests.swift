import Testing
@testable import KubeDeck

/// HPA は**数字が揃って見えるまま何もしていない**ことがある種別。
/// `REPLICAS 2` と出ていても、指標が引けていなければ調整は起きていない。
/// ここで固めるのは「取れていない」を「0」や「正常」に落とさないこと。
@Suite("HPA の読み取り")
struct AutoscalerTests {

    /// 実クラスタ（orbstack の k3s）から採った、requests 未設定の Deployment に
    /// HPA を付けた状態。kubectl は `cpu: <unknown>/75%` と出す。
    static let unknownMetric = """
        {
          "kind": "HorizontalPodAutoscaler",
          "apiVersion": "autoscaling/v2",
          "metadata": {"name": "web", "namespace": "kubedeck-hpa", "uid": "hpa-1"},
          "spec": {
            "scaleTargetRef": {"apiVersion": "apps/v1", "kind": "Deployment", "name": "web"},
            "minReplicas": 2,
            "maxReplicas": 8,
            "metrics": [
              {"type": "Resource",
               "resource": {"name": "cpu", "target": {"type": "Utilization", "averageUtilization": 75}}}
            ]
          },
          "status": {
            "currentReplicas": 2,
            "desiredReplicas": 2,
            "currentMetrics": [{"type": ""}],
            "conditions": [
              {"type": "AbleToScale", "status": "True", "reason": "SucceededGetScale"},
              {"type": "ScalingActive", "status": "False", "reason": "FailedGetResourceMetric"}
            ]
          }
        }
        """

    static let healthy = """
        {
          "kind": "HorizontalPodAutoscaler",
          "apiVersion": "autoscaling/v2",
          "metadata": {"name": "api", "namespace": "prod", "uid": "hpa-2"},
          "spec": {
            "scaleTargetRef": {"apiVersion": "apps/v1", "kind": "Deployment", "name": "api"},
            "minReplicas": 3,
            "maxReplicas": 10,
            "metrics": [
              {"type": "Resource",
               "resource": {"name": "cpu", "target": {"type": "Utilization", "averageUtilization": 80}}}
            ]
          },
          "status": {
            "currentReplicas": 3,
            "desiredReplicas": 3,
            "currentMetrics": [
              {"type": "Resource",
               "resource": {"name": "cpu", "current": {"averageUtilization": 42}}}
            ],
            "conditions": [
              {"type": "AbleToScale", "status": "True", "reason": "ReadyForNewScale"},
              {"type": "ScalingActive", "status": "True", "reason": "ValidMetricFound"}
            ]
          }
        }
        """

    // MARK: - 指標

    @Test("引けていない指標を 0% と書かない")
    func unknownIsNotZero() {
        let hpa = Fixture.object(Self.unknownMetric, assuming: .horizontalPodAutoscaler)
        let targets = ResourceTable.hpaTargets(hpa)

        // **ここが本題。** `0%` と書くと「まだ余裕がある」と読め、
        // HPA が動いていないという肝心の事実が消える。
        #expect(!targets.text.contains("0%"))
        #expect(targets.text == "cpu —/75%")
        #expect(targets.hasUnknown)
    }

    @Test("引けている指標はそのまま出す")
    func knownMetric() {
        let hpa = Fixture.object(Self.healthy, assuming: .horizontalPodAutoscaler)
        let targets = ResourceTable.hpaTargets(hpa)

        #expect(targets.text == "cpu 42%/80%")
        #expect(!targets.hasUnknown)
    }

    @Test("autoscaling/v1 の形（metrics を持たない）でも読める")
    func legacyVersion() {
        let hpa = Fixture.object(
            """
            {
              "kind": "HorizontalPodAutoscaler",
              "apiVersion": "autoscaling/v1",
              "metadata": {"name": "old", "namespace": "default", "uid": "hpa-3"},
              "spec": {
                "scaleTargetRef": {"kind": "Deployment", "name": "old"},
                "maxReplicas": 5,
                "targetCPUUtilizationPercentage": 60
              },
              "status": {"currentReplicas": 1, "desiredReplicas": 1,
                         "currentCPUUtilizationPercentage": 12}
            }
            """, assuming: .horizontalPodAutoscaler)

        #expect(ResourceTable.hpaTargets(hpa).text == "cpu 12%/60%")
        #expect(!ResourceTable.hpaTargets(hpa).hasUnknown)
    }

    @Test("対象は 種別/名前 で出す")
    func reference() {
        let hpa = Fixture.object(Self.healthy, assuming: .horizontalPodAutoscaler)
        #expect(ResourceTable.hpaReference(hpa) == "Deployment/api")
    }

    // MARK: - 状態

    @Test("指標が引けていない HPA を「正常」にしない")
    func scalingActiveFalseIsSurfaced() {
        let hpa = Fixture.object(Self.unknownMetric, assuming: .horizontalPodAutoscaler)
        let status = StatusResolver.status(for: hpa)

        // レプリカ数は 2/2 で揃っている。数だけ見ると健全に見えるので、
        // 条件を読まないとこの壊れ方は見つからない。
        #expect(status.text == "FailedGetResourceMetric")
        #expect(status.level == .serious)
    }

    @Test("正常な HPA は Active")
    func activeHPA() {
        let hpa = Fixture.object(Self.healthy, assuming: .horizontalPodAutoscaler)
        #expect(StatusResolver.status(for: hpa).level == .good)
    }

    @Test("調整中は現在と目標のずれで分かる")
    func scaling() {
        let hpa = Fixture.object(
            """
            {
              "kind": "HorizontalPodAutoscaler",
              "metadata": {"name": "api", "namespace": "prod", "uid": "hpa-4"},
              "spec": {"scaleTargetRef": {"kind": "Deployment", "name": "api"}, "maxReplicas": 10},
              "status": {"currentReplicas": 3, "desiredReplicas": 7, "conditions": []}
            }
            """, assuming: .horizontalPodAutoscaler)

        #expect(StatusResolver.status(for: hpa).text == "Scaling")
        #expect(StatusResolver.status(for: hpa).level == .warning)
    }

    @Test("条件を持たない版を異常にしない")
    func missingConditionsIsNotAFailure() {
        let hpa = Fixture.object(
            """
            {
              "kind": "HorizontalPodAutoscaler",
              "metadata": {"name": "old", "namespace": "default", "uid": "hpa-5"},
              "spec": {"scaleTargetRef": {"kind": "Deployment", "name": "old"}, "maxReplicas": 5},
              "status": {"currentReplicas": 1, "desiredReplicas": 1}
            }
            """, assuming: .horizontalPodAutoscaler)

        // `autoscaling/v1` は conditions を持たない。**無いことを異常にしない。**
        #expect(StatusResolver.status(for: hpa).level == .good)
    }

    // MARK: - 一覧の既定値

    @Test("minReplicas の省略は 1 として読む")
    func minReplicasDefaultsToOne() {
        let hpa = Fixture.object(
            """
            {
              "kind": "HorizontalPodAutoscaler",
              "metadata": {"name": "x", "namespace": "default", "uid": "hpa-6"},
              "spec": {"scaleTargetRef": {"kind": "Deployment", "name": "x"}, "maxReplicas": 4},
              "status": {}
            }
            """, assuming: .horizontalPodAutoscaler)

        // 空欄にすると「下限なし」に読める。
        #expect(hpa.spec?["minReplicas"]?.intValue == nil)
        let columns = ResourceTable.columns(
            for: .horizontalPodAutoscaler, showNamespace: false)
        let minimum = columns.first { $0.title == "最小" }
        #expect(minimum?.value(hpa).text == "1")
    }
}
