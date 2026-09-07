import Testing
@testable import KubeDeck

/// CRD の定義そのものを見せる経路。
///
/// **サイドバーに CRD 由来の種別を並べておきながら、定義はどこからも
/// 見られなかった。** `Kubectl.customResourceTypes` は `kubectl get crd` を
/// 引いているのに、group / version / kind / plural / scope / printerColumns
/// だけ抜いて残りを捨てていたので、`Established=False`（＝その種別が使えない
/// 理由そのもの）も非推奨の版も、CR を書くときの必須項目も出せなかった。
///
/// ここで固めるのは、実クラスタ（188 CRD）で実際に出た形と、
/// **「無い」と「取れていない」を混ぜない**判断。
struct CustomResourceTests {
    private static let healthy = #"""
        [{"type":"NamesAccepted","status":"True"},
         {"type":"Established","status":"True"}]
        """#

    // MARK: - 一覧の「版」列

    /// **storage の版だけを出す。** 実測で 1 版が 161・2 版が 23・3 版が 4 件で、
    /// 読みたいのは「いま書き込まれる版」。
    @Test("版の列は storage に指された版を出す")
    func versionColumnShowsStoredVersion() {
        let cell = ResourceTable.crdVersion(
            crd(versions: #"""
                [{"name":"v1beta1","served":true,"storage":false},
                 {"name":"v1","served":true,"storage":true}]
                """#))
        // **「他 N」を付けない。** 測ったら日本語でも溢れた
        // （`v1alpha1 (非推奨) 他 2` が 132.7pt、列は 150pt）。
        #expect(cell.text == "v1")
        #expect(cell.level == nil)
    }

    /// **非推奨を色だけで言わない。** 実測で storage の版そのものが非推奨な
    /// CRD が 2 件あった（`addresspools.metallb.io` の v1beta1 と
    /// `virtualmachineinstancepresets.kubevirt.io` の v1alpha3）。
    @Test("非推奨の版は文字と色の両方で言う")
    func deprecatedStorageVersionIsMarked() {
        let cell = ResourceTable.crdVersion(
            crd(versions: #"""
                [{"name":"v1alpha3","served":true,"storage":true,"deprecated":true,
                  "deprecationWarning":"kubevirt.io/v1alpha3 ... removed in v2."}]
                """#))
        #expect(cell.level == .warning)
        #expect(cell.text.hasPrefix("v1alpha3"))
        // 色だけにしない —— 版名のほかに文字が付くこと。
        #expect(cell.text != "v1alpha3")
    }

    /// **引けたものを「取れていない」ことにしない。** storage の版が無い CRD は
    /// API サーバが受け付けないが、こちらは空欄にするだけ。
    @Test("storage の版が無くても失敗にしない")
    func missingStorageVersionIsBlank() {
        let cell = ResourceTable.crdVersion(crd(versions: #"[{"name":"v1","served":true}]"#))
        #expect(cell.text.isEmpty)
        #expect(cell.level == nil)
    }

    // MARK: - 一覧の「状態」列

    /// **`Established=False` はいちばん重い。** その種別はサイドバーに出るのに
    /// 押せば必ず空になる（`APIService` の `Available=False` と同じ形）。
    @Test("Established=False は critical")
    func establishedFalseIsCritical() {
        let cell = ResourceTable.crdState(
            crd(versions: Self.oneVersion,
                conditions: #"""
                    [{"type":"NamesAccepted","status":"True"},
                     {"type":"Established","status":"False","reason":"NotAccepted"}]
                    """#))
        #expect(cell.level == .critical)
        #expect(cell.text.contains("Established"))
    }

    /// 承認の条件が落ちていても種別は使えるので、赤にはしない。
    @Test("Established 以外が落ちているのは warning")
    func otherFalseConditionIsWarning() {
        let cell = ResourceTable.crdState(
            crd(versions: Self.oneVersion,
                conditions: #"""
                    [{"type":"Established","status":"True"},
                     {"type":"KubernetesAPIApprovalPolicyConformant","status":"False"}]
                    """#))
        #expect(cell.level == .warning)
        #expect(cell.text.contains("KubernetesAPIApprovalPolicyConformant"))
    }

    /// **条件が無いことを異常にしない。** 作られた直後は空になる。
    @Test("条件が無いことを異常にしない")
    func missingConditionsAreNotAFailure() {
        let cell = ResourceTable.crdState(crd(versions: Self.oneVersion, conditions: "[]"))
        #expect(cell.text.isEmpty)
        #expect(cell.level == nil)
    }

    /// **正常なものを並べない。** 実測では健全なクラスタの 188 CRD すべてが
    /// 全条件 True。3 つ並べると合格印で埋まる。
    @Test("正常なら Established の 1 語だけ")
    func healthyStateIsOneWord() {
        let cell = ResourceTable.crdState(
            crd(versions: Self.oneVersion, conditions: Self.healthy))
        #expect(cell.text == "Established")
        #expect(cell.level == .good)
    }

    // MARK: - 設定タブ

    /// **補間の入った見出しを、そのまま id にしない。**
    /// `LocalizedStringResource.key` は書式指定子のまま（`"版 %@"`）なので、
    /// 版が複数ある CRD（実測で 27 件）では 3 つとも同じ鍵になる。`ForEach` の
    /// 同一性が重なると SwiftUI は行を取り違える（`RBACTests` と同じ罠）。
    @Test("版が複数ある CRD の設定タブで id が重ならない")
    func versionGroupsHaveDistinctIDs() {
        let groups = SettingsDigest.groups(
            for: crd(versions: #"""
                [{"name":"v1alpha1","served":true,"storage":false},
                 {"name":"v1alpha2","served":true,"storage":false},
                 {"name":"v1beta1","served":true,"storage":true}]
                """#))
        let ids = groups.map(\.id)
        #expect(Set(ids).count == ids.count)
        for group in groups {
            let rowIDs = group.rows.map(\.id)
            #expect(Set(rowIDs).count == rowIDs.count)
        }
    }

    /// **ふつうの値で埋めない。** 実測で非推奨の版は 21 個だけ。
    @Test("非推奨でない版に非推奨の行を出さない")
    func deprecationRowOnlyWhenDeprecated() {
        let plain = SettingsDigest.groups(for: crd(versions: Self.oneVersion))
        #expect(!rows(of: plain).contains { $0.label == "非推奨" })

        let deprecated = SettingsDigest.groups(
            for: crd(versions: #"""
                [{"name":"v1","served":true,"storage":true,"deprecated":true,
                  "deprecationWarning":"v2 で消えます"}]
                """#))
        // **サーバの文言をそのまま出す。** いつ消えるかを書いてくれる
        // 唯一の場所で、こちらで組み立てようがない。
        let row = rows(of: deprecated).first { $0.label == "非推奨" }
        #expect(row?.value == "v2 で消えます")
        #expect(row?.level == .warning)
    }

    /// **`scale` があることを「はい」で済ませない。** それは「レプリカ数を
    /// 変えられる＝HPA を付けられる」の意味で、実測で 5 件だけが持つ。
    @Test("scale を持つ版は意味まで書く")
    func scaleSubresourceIsSpelledOut() {
        let withScale = SettingsDigest.groups(
            for: crd(versions: #"""
                [{"name":"v1","served":true,"storage":true,
                  "subresources":{"status":{},"scale":{"specReplicasPath":".spec.replicas"}}}]
                """#))
        let row = rows(of: withScale).first { $0.label == "別に更新できるもの" }
        #expect(row?.value.contains("レプリカ数") == true)

        // status だけの版（実測で 157 件）は kubectl の語をそのまま出す。
        let statusOnly = SettingsDigest.groups(
            for: crd(versions: #"""
                [{"name":"v1","served":true,"storage":true,"subresources":{"status":{}}}]
                """#))
        #expect(rows(of: statusOnly).first { $0.label == "別に更新できるもの" }?.value == "status")

        // **無い版に行を出さない。**
        let none = SettingsDigest.groups(for: crd(versions: Self.oneVersion))
        #expect(!rows(of: none).contains { $0.label == "別に更新できるもの" })
    }

    /// **変換の節は Webhook のときだけ。** 実測で 179 件が `None`。
    @Test("変換の節は Webhook のときだけ出す")
    func conversionGroupOnlyForWebhook() {
        let none = SettingsDigest.groups(
            for: crd(versions: Self.oneVersion, conversion: #""conversion":{"strategy":"None"},"#))
        #expect(!none.contains { $0.title == "版の変換" })

        let webhook = SettingsDigest.groups(
            for: crd(
                versions: Self.oneVersion,
                conversion: #"""
                    "conversion":{"strategy":"Webhook","conversionReviewVersions":["v1"],
                      "webhook":{"clientConfig":{"service":{"namespace":"cert-manager","name":"webhook"}}}},
                    """#))
        let group = webhook.first { $0.title == "版の変換" }
        #expect(group != nil)
        #expect(group?.rows.first { $0.label == "指し先" }?.value == "cert-manager/webhook")
        // **落ちたときに何が起きるかを書く**（`ValidatingWebhook` の「失敗時」と同じ）。
        #expect(group?.subtitle?.isEmpty == false)
    }

    /// CR を書くときにいちばん要るもの。実測で 219 版のうち 127 が持っていた。
    @Test("spec の必須項目を出す。無い版は「未設定」")
    func requiredFieldsAreListed() {
        let groups = SettingsDigest.groups(
            for: crd(versions: #"""
                [{"name":"v1","served":true,"storage":true,
                  "schema":{"openAPIV3Schema":{"type":"object","properties":{
                    "spec":{"type":"object","required":["size","target"]}}}}}]
                """#))
        let row = rows(of: groups).first { $0.label == "spec の必須項目" }
        #expect(row?.value.contains("size") == true)
        #expect(row?.value.contains("target") == true)
        #expect(row?.isUnset == false)

        // スキーマが無い版でも行は出す（値は「未設定」）。
        let bare = SettingsDigest.groups(for: crd(versions: Self.oneVersion))
        #expect(rows(of: bare).first { $0.label == "spec の必須項目" }?.isUnset == true)
    }

    // MARK: - 土台

    private static let oneVersion = #"[{"name":"v1","served":true,"storage":true}]"#

    private func rows(of groups: [SettingGroup]) -> [SettingRow] {
        groups.flatMap(\.rows)
    }

    private func crd(
        versions: String,
        conversion: String = "",
        conditions: String = CustomResourceTests.healthy
    ) -> K8sObject {
        Fixture.object(
            #"""
            {"kind":"CustomResourceDefinition","apiVersion":"apiextensions.k8s.io/v1",
             "metadata":{"name":"widgets.example.com","uid":"crd-1"},
             "spec":{"group":"example.com","scope":"Namespaced",
               \#(conversion)
               "names":{"kind":"Widget","plural":"widgets","singular":"widget",
                        "shortNames":["wg"],"categories":["all"]},
               "versions":\#(versions)},
             "status":{"conditions":\#(conditions)}}
            """#,
            assuming: .customResourceDefinition)
    }
}
