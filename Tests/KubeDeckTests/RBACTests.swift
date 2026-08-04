import Testing
@testable import KubeDeck

/// RBAC は**名前だけ並べても何も分からない**種別。どの Role が強いのかは
/// `rules` を開かないと見えず、Binding は「誰に効いているか」が本体。
/// 一覧でそこまで出す、というのがここで固めたいこと。
@Suite("RBAC の読み取り")
struct RBACTests {

    private func role(_ rules: String, kind: ResourceKind = .role) -> K8sObject {
        Fixture.object(
            """
            {
              "kind": "\(kind.apiKind)",
              "metadata": {"name": "reader", "namespace": "default", "uid": "role-1"},
              "rules": \(rules)
            }
            """, assuming: kind)
    }

    // MARK: - できること

    @Test("動詞と対象をまとめて 1 行にする")
    func ruleSummary() {
        let object = role(
            """
            [{"apiGroups": [""], "resources": ["pods"], "verbs": ["get", "list"]}]
            """)

        let summary = ResourceTable.ruleSummary(object)
        #expect(summary.text == "get,list → pods")
        #expect(!summary.isWildcard)
    }

    @Test("* は必ず見えるところへ出す")
    func wildcardIsSurfaced() {
        let object = role(
            """
            [{"apiGroups": ["*"], "resources": ["*"], "verbs": ["*"]}]
            """)

        let summary = ResourceTable.ruleSummary(object)
        // **並び順で沈ませない。** `*` は「なんでもできる」で、いちばん
        // 見つけたいもの。名前順に混ぜると後ろに流れる。
        #expect(summary.text.hasPrefix("*"))
        #expect(summary.isWildcard)
    }

    @Test("動詞のどれかが * なら強いものとして扱う")
    func wildcardVerbOnly() {
        let object = role(
            """
            [{"apiGroups": [""], "resources": ["secrets"], "verbs": ["*"]}]
            """)
        #expect(ResourceTable.ruleSummary(object).isWildcard)
    }

    @Test("多すぎるときは切って「他 N」と書く")
    func longListIsTruncated() {
        let object = role(
            """
            [{"apiGroups": [""],
              "resources": ["pods", "services", "configmaps", "secrets", "endpoints", "events"],
              "verbs": ["get"]}]
            """)

        // **黙って切らない。** 切った事実が出ていないと、それで全部だと読める。
        #expect(ResourceTable.ruleSummary(object).text.contains("他 2"))
    }

    @Test("nonResourceURLs しか無い規則も拾う")
    func nonResourceURLs() {
        let object = role(
            """
            [{"nonResourceURLs": ["/healthz"], "verbs": ["get"]}]
            """)
        #expect(ResourceTable.ruleSummary(object).text.contains("/healthz"))
    }

    @Test("規則が無い Role は空で返す")
    func emptyRules() {
        #expect(ResourceTable.ruleSummary(role("[]")).text.isEmpty)
    }

    // MARK: - Binding

    private func binding(_ subjects: String) -> K8sObject {
        Fixture.object(
            """
            {
              "kind": "RoleBinding",
              "metadata": {"name": "bind", "namespace": "default", "uid": "rb-1"},
              "roleRef": {"kind": "ClusterRole", "name": "view"},
              "subjects": \(subjects)
            }
            """, assuming: .roleBinding)
    }

    @Test("参照するロールは 種別/名前 で出す")
    func roleRef() {
        #expect(ResourceTable.roleRef(binding("[]")) == "ClusterRole/view")
    }

    @Test("ServiceAccount は Namespace まで書く")
    func serviceAccountSubjectKeepsNamespace() {
        let object = binding(
            """
            [{"kind": "ServiceAccount", "name": "deployer", "namespace": "ci"}]
            """)

        // Namespace を落とすと、同じ名前の ServiceAccount のどれか決まらない。
        #expect(ResourceTable.subjectSummary(object) == "ServiceAccount/ci/deployer")
    }

    @Test("種別を落とさない")
    func subjectKindIsKept() {
        let object = binding(
            """
            [{"kind": "User", "name": "alice"}, {"kind": "Group", "name": "alice"}]
            """)

        // 同じ名前の User と Group は別物。混ぜると誰に効くのか分からない。
        #expect(ResourceTable.subjectSummary(object) == "User/alice,Group/alice")
    }

    @Test("対象が空でも壊れない")
    func noSubjects() {
        #expect(ResourceTable.subjectSummary(binding("[]")).isEmpty)
    }

    // MARK: - 種別の設定

    @Test("RBAC は API グループを付けて引く")
    func resourceNamesCarryAPIGroup() {
        // 別グループが同じ複数形を持つことがある。短い名前だと別の種別を引く。
        #expect(ResourceKind.role.resourceName == "roles.rbac.authorization.k8s.io")
        #expect(ResourceKind.clusterRoleBinding.resourceName
                == "clusterrolebindings.rbac.authorization.k8s.io")
        // ServiceAccount は core グループなので付けない。
        #expect(ResourceKind.serviceAccount.resourceName == "serviceaccounts")
    }

    @Test("Cluster が付くものは Namespace を持たない")
    func clusterScopedKinds() {
        #expect(!ResourceKind.clusterRole.isNamespaced)
        #expect(!ResourceKind.clusterRoleBinding.isNamespaced)
        #expect(ResourceKind.role.isNamespaced)
        #expect(ResourceKind.serviceAccount.isNamespaced)
    }

    @Test("アクセス制御の節にまとまっている")
    func accessCategory() {
        let kinds = ResourceKind.kinds(in: .access)
        #expect(kinds == [.serviceAccount, .role, .roleBinding, .clusterRole, .clusterRoleBinding])
    }

    @Test("apiKind からの復元が RBAC でも効く")
    func roundTrip() {
        for kind in ResourceKind.kinds(in: .access) {
            #expect(ResourceKind(apiKind: kind.apiKind) == kind)
        }
    }
}
