import Testing
@testable import KubeDeck

/// Service・Ingress・PVC とワークロードのつながりは API に無いので、取ってきた
/// オブジェクトどうしを突き合わせる。**「一致」であって「参照」ではない**ので、
/// 一致の条件を緩めると無関係なものまで繋がる。
@Suite("関係の突き合わせ")
struct WorkloadRelationsTests {

    // MARK: - Service → Pod

    /// **空のセレクタを一致させない。** 空は「すべてに一致」ではなく
    /// 「まだ何も選んでいない」。通すと全部の Service がどのワークロードにも付く。
    @Test("セレクタが空の Service は何も掴まない")
    func emptySelectorMatchesNothing() {
        let pod = Fixture.pod(labels: ["app": "web"])
        let empty = Fixture.service(name: "unset", selector: [:])

        #expect(WorkloadRelations.pods(selectedBy: empty, among: [pod]).isEmpty)
        #expect(WorkloadRelations.services(for: [pod], among: [empty]).isEmpty)
    }

    @Test("セレクタは部分集合として一致する（Pod は余分なラベルを持てる）")
    func selectorIsSubset() {
        let pod = Fixture.pod(labels: ["app": "web", "pod-template-hash": "abc123"])
        let service = Fixture.service(name: "web", selector: ["app": "web"])

        #expect(WorkloadRelations.pods(selectedBy: service, among: [pod]).count == 1)
    }

    @Test("セレクタの一部でも合わなければ掴まない")
    func selectorNeedsEveryKey() {
        let pod = Fixture.pod(labels: ["app": "web"])
        let service = Fixture.service(name: "web", selector: ["app": "web", "tier": "front"])

        #expect(WorkloadRelations.pods(selectedBy: service, among: [pod]).isEmpty)
    }

    /// **Namespace をまたいで掴ませない。** 別の Namespace に同じラベルの
    /// Pod があるのはふつう。
    @Test("Namespace が違えば一致しない")
    func namespaceIsPartOfTheMatch() {
        let pod = Fixture.pod(namespace: "team-a", labels: ["app": "web"])
        let service = Fixture.service(name: "web", namespace: "team-b", selector: ["app": "web"])

        #expect(WorkloadRelations.pods(selectedBy: service, among: [pod]).isEmpty)
    }

    @Test("Pod が無いときはテンプレートのラベルで引ける")
    func matchByTemplateLabels() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        let found = WorkloadRelations.services(
            matching: ["app": "web"], namespace: "default", among: [service])

        #expect(found.map(\.name) == ["web"])
    }

    // MARK: - Ingress → Service

    /// **見つからなかった名前も返す。** 黙って落とすと「Ingress の先に何も無い」
    /// のか「壊れている」のかが分からない。
    @Test("Ingress が指しているのに実在しない Service を黙って落とさない")
    func missingBackendIsReported() {
        let existing = Fixture.service(name: "web", selector: ["app": "web"])
        let ingress = Fixture.ingress(name: "public", backends: ["web", "typo-api"])

        let resolved = WorkloadRelations.services(of: ingress, among: [existing, ingress])
        #expect(resolved.found.map(\.name) == ["web"])
        #expect(resolved.missing == ["typo-api"])
    }

    @Test("同じ Service を 2 度返さない（複数のパスが同じ backend を指す）")
    func duplicateBackends() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        let ingress = Fixture.ingress(name: "public", backends: ["web", "web"])

        #expect(WorkloadRelations.services(of: ingress, among: [service, ingress]).found.count == 1)
    }

    @Test("Service から Ingress を引く逆向きも通る")
    func ingressesForServices() {
        let service = Fixture.service(name: "web", selector: ["app": "web"])
        let ingress = Fixture.ingress(name: "public", backends: ["web"])

        let found = WorkloadRelations.ingresses(for: [service], among: [service, ingress])
        #expect(found.map(\.name) == ["public"])
    }

    // MARK: - Pod → PVC

    @Test("Pod が使っている PVC だけを拾う")
    func claims() {
        let pod = Fixture.pod(
            volumes: #"[{"name":"data","persistentVolumeClaim":{"claimName":"data-0"}}]"#)
        let used = Fixture.claim(name: "data-0")
        let unused = Fixture.claim(name: "other")

        let found = WorkloadRelations.claims(for: [pod], among: [used, unused])
        #expect(found.map(\.name) == ["data-0"])
    }

    @Test("PVC を使っていない Pod では空を返す（無いことは異常ではない）")
    func noClaims() {
        let pod = Fixture.pod(volumes: #"[{"name":"tmp","emptyDir":{}}]"#)
        #expect(WorkloadRelations.claims(for: [pod], among: [Fixture.claim(name: "data-0")]).isEmpty)
    }

    // MARK: - PVC → PV

    /// **3 つを分ける。** バインド済み / 未バインド / PV を引けていない。
    /// 未バインドは Pod が起動しない原因そのもので、「PV が無い」ではない。
    @Test("PVC の行き先の PV を解く。未バインドと引けていないを分ける")
    func storageLinks() {
        let bound = Fixture.claim(name: "data-0", volumeName: "pvc-aaa")
        let pending = Fixture.claim(name: "data-1")
        let missingVolume = Fixture.claim(name: "data-2", volumeName: "pvc-ccc")
        let volume = Fixture.volume(name: "pvc-aaa", capacity: "10Gi", storageClass: "standard")

        let links = WorkloadRelations.storageLinks(
            for: [bound, pending, missingVolume], among: [volume])

        #expect(links[0].volumeName == "pvc-aaa")
        #expect(links[0].volume?.name == "pvc-aaa")
        // **phase が来ていない PV を `Unknown` で埋めない。** クラスタが答えて
        // いないことを、答えたことにしない（この fixture は phase を持たない）。
        #expect(links[0].volumeDetail == "PV · 10Gi · standard")
        // 未バインド。名前そのものが無い。
        #expect(links[1].volumeName == nil)
        #expect(links[1].volume == nil)
        // 名前はあるのに実物が無い＝引けていない。空欄と同じにしない。
        #expect(links[2].volumeName == "pvc-ccc")
        #expect(links[2].volume == nil)
        #expect(links[2].volumeDetail == nil)
    }

    /// **`Released` を容量だけの表示に埋もれさせない。** PVC を消したあとも
    /// PV とデータが残っている状態で、実運用でいちばんよくある回収漏れ。
    @Test("PV の状態を見どころに含める")
    func volumeDetailCarriesPhase() {
        let claim = Fixture.claim(name: "data-0", volumeName: "pvc-aaa")
        let released = Fixture.volume(name: "pvc-aaa", phase: "Released")

        let links = WorkloadRelations.storageLinks(for: [claim], among: [released])
        #expect(links[0].volumeDetail == "PV · Released · 10Gi · standard")
    }

    /// **PV と同じ容量を 2 度書かない。** 束ねる先があるなら実容量は PV 側が
    /// 持っているので、要求は未バインドのときだけ出す（そのときはどこにも無い）。
    @Test("PVC の見どころ。要求容量は未バインドのときだけ出す")
    func claimDetail() {
        let bound = Fixture.claim(name: "data-0", volumeName: "pvc-aaa", requested: "8Gi")
        let pending = Fixture.claim(name: "data-1", requested: "8Gi")
        let volume = Fixture.volume(name: "pvc-aaa")

        let links = WorkloadRelations.storageLinks(for: [bound, pending], among: [volume])
        #expect(links[0].claimDetail == "PVC · Bound")
        #expect(links[1].claimDetail == "PVC · Pending · 要求 8Gi")
    }

    // MARK: - PVC → Pod（逆引き）

    /// **同じ名前の PVC は Namespace ごとに別物。** StatefulSet が作る
    /// `data-web-0` のような名前はとくに重なる。
    @Test("PVC を使っている Pod を逆引きする。Namespace を跨がない")
    func podsUsingClaim() {
        let volumes = #"[{"name":"data","persistentVolumeClaim":{"claimName":"data-0"}}]"#
        let user = Fixture.pod(name: "web-0", namespace: "team-a", volumes: volumes)
        let sameNameOtherNamespace = Fixture.pod(
            name: "web-0", namespace: "team-b", volumes: volumes)
        let other = Fixture.pod(name: "api-0", namespace: "team-a")

        let found = WorkloadRelations.pods(
            using: "data-0", namespace: "team-a",
            among: [user, sameNameOtherNamespace, other])
        #expect(found.map(\.name) == ["web-0"])
        #expect(found.first?.namespace == "team-a")
    }

    /// **空の名前で引かない。** `claimName` を持たないボリュームと当たって、
    /// 無関係な Pod を掴む。
    @Test("空の PVC 名では 1 つも掴まない")
    func podsUsingEmptyClaimName() {
        let pod = Fixture.pod(volumes: #"[{"name":"tmp","emptyDir":{}}]"#)
        #expect(WorkloadRelations.pods(using: "", namespace: "default", among: [pod]).isEmpty)
    }

    // MARK: - PV → PVC（逆引き）

    /// **`claimRef` が事実。** バインドしたコントローラが書くもので、PVC 側の
    /// `spec.volumeName` は人が先に書いておくこともある（まだ束ねられていない指名）。
    @Test("PV から PVC を claimRef で引く")
    func claimBoundToVolume() throws {
        let claim = Fixture.claim(name: "data-0", namespace: "team-a", volumeName: "pvc-aaa")
        let volume = Fixture.volume(
            name: "pvc-aaa", claimRef: (namespace: "team-a", name: "data-0"))

        let found = try #require(WorkloadRelations.claim(boundTo: volume, among: [claim]))
        #expect(found.name == "data-0")
    }

    /// **`claimRef` が指す先が手元に無いときに、別の PVC に落ちない。**
    /// Namespace を絞っていれば在るのに引けていないだけで、そこで
    /// `volumeName` 側の逆引きへ落とすと**別の Namespace の PVC を掴みうる**。
    @Test("claimRef の指す PVC が無ければ nil。volumeName へ落ちない")
    func claimReferenceDoesNotFallBack() {
        let elsewhere = Fixture.claim(
            name: "data-0", namespace: "team-b", volumeName: "pvc-aaa")
        let volume = Fixture.volume(
            name: "pvc-aaa", claimRef: (namespace: "team-a", name: "data-0"))

        #expect(WorkloadRelations.claim(boundTo: volume, among: [elsewhere]) == nil)
    }

    /// `claimRef` が無い PV は、まだ誰にも束ねられていないか、PVC 側の指名しか
    /// 無い状態。そのときだけ `volumeName` から引く。
    @Test("claimRef が無ければ PVC の volumeName から引く")
    func claimByVolumeName() throws {
        let claim = Fixture.claim(name: "data-0", volumeName: "pvc-aaa")
        let volume = Fixture.volume(name: "pvc-aaa")

        let found = try #require(WorkloadRelations.claim(boundTo: volume, among: [claim]))
        #expect(found.name == "data-0")
    }

    /// **実物が引けたかとは別に、指し先は分かる。** ここが分かれていないと
    /// 「消えている」と「取得の範囲外」を書き分けられない。
    @Test("claimRef の中身は実物が無くても読める")
    func claimReferenceIsReadableWithoutTheClaim() throws {
        let volume = Fixture.volume(
            name: "pvc-aaa", phase: "Released",
            claimRef: (namespace: "team-a", name: "data-0"))

        let reference = try #require(WorkloadRelations.claimReference(of: volume))
        #expect(reference.namespace == "team-a")
        #expect(reference.name == "data-0")
        #expect(WorkloadRelations.claimReference(of: Fixture.volume(name: "free")) == nil)
    }

    // MARK: - Pod → NetworkPolicy

    /// **Service と逆。** `podSelector: {}` は「すべての Pod」。
    /// 取り違えると、いちばん効きの強い設定を「効いていない」ことにする。
    @Test("空の podSelector は Namespace のすべての Pod に効く")
    func emptyPolicySelectorMatchesEverything() {
        let pod = Fixture.pod(name: "web-0", labels: ["app": "web"])
        let all = Fixture.policy(name: "deny-all", selector: [:])
        let other = Fixture.policy(name: "other-ns", namespace: "kube-system", selector: [:])

        let found = WorkloadRelations.policies(for: [pod], among: [all, other])
        #expect(found.map(\.name) == ["deny-all"])
    }

    @Test("ラベルの合う NetworkPolicy だけを拾う")
    func policiesMatchLabels() {
        let pod = Fixture.pod(name: "web-0", labels: ["app": "web"])
        let hit = Fixture.policy(name: "web-policy", selector: ["app": "web"])
        let miss = Fixture.policy(name: "db-policy", selector: ["app": "db"])

        let found = WorkloadRelations.policies(for: [pod], among: [hit, miss])
        #expect(found.map(\.name) == ["web-policy"])
    }

    // MARK: - Pod → ServiceAccount → Binding

    /// **省略時は `default`。** 空欄にすると権限が無いように読める。
    @Test("ServiceAccount 名は省略時に default")
    func defaultServiceAccountName() {
        #expect(WorkloadRelations.serviceAccountName(of: Fixture.pod()) == "default")
        #expect(
            WorkloadRelations.serviceAccountName(of: Fixture.pod(serviceAccount: "web-sa"))
                == "web-sa")
    }

    @Test("その ServiceAccount に付いている Binding だけを逆引きする")
    func accessSummaryFindsBindings() {
        let pod = Fixture.pod(namespace: "app", serviceAccount: "web-sa")
        let hit = Fixture.binding(
            name: "web-reader", namespace: "app", role: (kind: "Role", name: "pod-reader"),
            subjects: [(kind: "ServiceAccount", name: "web-sa", namespace: "app")])
        let clusterHit = Fixture.binding(
            name: "web-view", namespace: nil, role: (kind: "ClusterRole", name: "view"),
            subjects: [(kind: "ServiceAccount", name: "web-sa", namespace: "app")])
        // **Namespace が違えば別物。** 同じ名前の SA は Namespace ごとに居る。
        let otherNamespace = Fixture.binding(
            name: "other", namespace: "other", role: (kind: "Role", name: "pod-reader"),
            subjects: [(kind: "ServiceAccount", name: "web-sa", namespace: "other")])
        // **種別を落とさない。** 同じ名前の User は別物。
        let user = Fixture.binding(
            name: "human", namespace: "app", role: (kind: "Role", name: "pod-reader"),
            subjects: [(kind: "User", name: "web-sa", namespace: nil)])

        let summary = WorkloadRelations.accessSummary(for: [pod])
        #expect(summary.accounts.map(\.name) == ["web-sa"])

        // **Binding は別に引く。** 逆引きに一覧が要るので重く、自動更新に
        // 載せていない（`ClusterStore.serviceAccountBindings`）。
        let found = WorkloadRelations.bindings(
            for: summary.accounts, among: [hit, clusterHit, otherNamespace, user])
        let bound = try! #require(found["app/web-sa"])

        #expect(bound.map(\.name) == ["web-reader", "web-view"])
        #expect(bound[0].roleID == "Role/app/pod-reader")
        // ClusterRole は Namespace を持たない。Role と同じ鍵にしない。
        #expect(bound[1].roleID == "ClusterRole//view")
        #expect(bound[1].isClusterWide)
    }

    /// **無いことを異常にしない。** ただし「何も付いていない」と断定もしない
    /// （グループ経由の付与は見ていないので、画面側が断る）。
    @Test("Binding が 1 つも無くても ServiceAccount は出す")
    func accessSummaryKeepsAccountWithoutBindings() {
        let summary = WorkloadRelations.accessSummary(for: [Fixture.pod()])
        #expect(summary.accounts.map(\.name) == ["default"])
        // **鍵は必ず作る。** nil（引いていない）と空（付いていない）を
        // 呼び出し側で区別できるようにしておく。
        let found = WorkloadRelations.bindings(for: summary.accounts, among: [])
        #expect(found["default/default"]?.isEmpty == true)
    }

    /// **口座の一覧は kubectl を増やさずに作れる。** `spec.serviceAccountName` は
    /// Pod が持っているので、Binding を引く前でも帯そのものは出せる。
    @Test("口座の一覧は Pod だけから作る。Namespace で分ける")
    func accessSummaryIsNamespaced() {
        let summary = WorkloadRelations.accessSummary(for: [
            Fixture.pod(name: "a", namespace: "team-a", serviceAccount: "web-sa"),
            Fixture.pod(name: "b", namespace: "team-a", serviceAccount: "web-sa"),
            Fixture.pod(name: "c", namespace: "team-b", serviceAccount: "web-sa"),
        ])

        // 同じ名前でも Namespace が違えば別物。同じ口座は 1 度だけ。
        #expect(summary.accounts.map(\.id) == ["team-a/web-sa", "team-b/web-sa"])
    }

    /// **「まだ引いていない」と「無い」を混ぜない。**
    @Test("引く前の AccessBindings は isLoaded が偽")
    func accessBindingsDistinguishesUnloaded() {
        #expect(AccessBindings().isLoaded == false)
        #expect(AccessBindings(isLoaded: true).all.isEmpty)
    }

    // MARK: - Pod → ConfigMap / Secret

    /// **6 か所すべてを見る。** どれか 1 つでも落とすと、参照しているのに
    /// 図に出ない設定ができる（見えない依存がいちばん困る）。
    @Test("参照している ConfigMap / Secret を付き方ごとに拾う")
    func configReferences() {
        let pod = Fixture.pod(
            containers: """
                [{"name":"app",
                  "envFrom":[{"configMapRef":{"name":"flags"}},{"secretRef":{"name":"db"}}],
                  "env":[{"name":"K","valueFrom":{"secretKeyRef":{"name":"token"}}}]}]
                """,
            initContainers: """
                [{"name":"init",
                  "env":[{"name":"C","valueFrom":{"configMapKeyRef":{"name":"init-conf"}}}]}]
                """,
            volumes: """
                [{"name":"conf","configMap":{"name":"app-config"}},
                 {"name":"tls","secret":{"secretName":"web-tls"}},
                 {"name":"mix","projected":{"sources":[{"configMap":{"name":"projected-conf"}},
                                                       {"secret":{"name":"projected-sec"}}]}}]
                """,
            imagePullSecrets: ["regcred"])
        let ingress = Fixture.ingress(
            name: "public", backends: ["web"], tlsSecrets: ["ingress-tls"])

        let found = WorkloadRelations.configReferences(for: [pod], ingresses: [ingress])
        let named = Dictionary(uniqueKeysWithValues: found.map { ($0.name, $0) })

        // ConfigMap が先、その中は名前順。
        #expect(
            found.map(\.name) == [
                "app-config", "flags", "init-conf", "projected-conf",
                "db", "ingress-tls", "projected-sec", "regcred", "token", "web-tls",
            ])
        #expect(named["app-config"]?.attachments == [.volume])
        #expect(named["flags"]?.attachments == [.environment])
        // 初期化コンテナも見る（設定を取りに行くのが init の仕事、はよくある）。
        #expect(named["init-conf"]?.attachments == [.environment])
        #expect(named["projected-sec"]?.source == .secret)
        #expect(named["regcred"]?.attachments == [.imagePull])
        #expect(named["ingress-tls"]?.attachments == [.ingressTLS])
    }

    /// **同じものを何度も出さない。** レプリカの数だけ並べると帯が埋まる。
    @Test("複数の Pod が同じものを参照していても 1 つに束ねる")
    func configReferencesAreDeduplicated() {
        let volumes = #"[{"name":"conf","configMap":{"name":"app-config"}}]"#
        let pods = [
            Fixture.pod(name: "web-0", volumes: volumes),
            Fixture.pod(name: "web-1", volumes: volumes),
        ]

        #expect(WorkloadRelations.configReferences(for: pods).map(\.name) == ["app-config"])
    }

    /// **付き方を 1 つに決めない。** マウントもされ環境変数にも入っている、は
    /// ふつうにある。片方だけ書くと、見に行く場所を間違える。
    @Test("同じものが 2 通りで付いていれば両方書く")
    func configReferenceKeepsEveryAttachment() {
        let pod = Fixture.pod(
            containers: #"[{"name":"app","envFrom":[{"configMapRef":{"name":"app-config"}}]}]"#,
            volumes: #"[{"name":"conf","configMap":{"name":"app-config"}}]"#)

        let found = WorkloadRelations.configReferences(for: [pod])
        #expect(found.count == 1)
        #expect(found[0].attachments == [.volume, .environment])
        #expect(found[0].detail == "ConfigMap · マウント・環境変数")
    }

    /// **全部に出るものは何も言わない。** `kube-root-ca.crt` はどの Pod にも
    /// 自動で投影されるので、並べると本当の参照を帯の外へ押し出す。
    /// ただし**自分でマウントしていれば意図した参照**なので、そちらは出す。
    @Test("自動で投影される CA は出さない。自分でマウントしていれば出す")
    func automaticRootCAIsHidden() {
        let automatic = Fixture.pod(
            volumes: """
                [{"name":"kube-api-access-abcde",
                  "projected":{"sources":[{"configMap":{"name":"kube-root-ca.crt"}},
                                          {"serviceAccountToken":{"path":"token"}}]}}]
                """)
        #expect(WorkloadRelations.configReferences(for: [automatic]).isEmpty)

        let explicit = Fixture.pod(
            volumes: #"[{"name":"ca","configMap":{"name":"kube-root-ca.crt"}}]"#)
        #expect(
            WorkloadRelations.configReferences(for: [explicit]).map(\.name)
                == ["kube-root-ca.crt"])
    }

    @Test("何も参照していない Pod では空を返す（無いことは異常ではない）")
    func noConfigReferences() {
        let pod = Fixture.pod(volumes: #"[{"name":"tmp","emptyDir":{}}]"#)
        #expect(WorkloadRelations.configReferences(for: [pod]).isEmpty)
    }
}
