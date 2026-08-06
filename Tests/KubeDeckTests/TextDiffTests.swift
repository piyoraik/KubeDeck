import Testing
@testable import KubeDeck

/// 書き戻す前に出す差分。
///
/// **ここが黙って間違えると、確かめたつもりで別のものを書き戻す。** 差分は
/// 「これで合っている」と判断するための唯一の材料なので、行番号のずれや
/// 塊の切れ方を固めておく。
@Suite("YAML の差分")
struct TextDiffTests {

    @Test("同じなら差分は無い")
    func identical() {
        let text = "a\nb\nc"
        let result = TextDiff.compare(text, text)
        #expect(result.isEmpty)
        #expect(result.hunks.isEmpty)
    }

    @Test("1 行の書き換えは、消しと足しの組で出る")
    func replacedLine() {
        let result = TextDiff.compare("a\nb\nc", "a\nB\nc")
        #expect(result.removed == 1)
        #expect(result.added == 1)
        #expect(result.hunks.count == 1)

        let kinds = result.hunks[0].lines.map(\.kind)
        // **消しを先に出す。** 上下が入れ替わると、置き換えが読み取りにくい。
        #expect(kinds == [.same, .removed, .added, .same])
    }

    /// **行番号を取り違えない。** 足された行に元の番号は無いし、消された行に
    /// 新しい番号は無い。ここがずれると、差分を見て別の行を直すことになる。
    @Test("行番号は、ある側にだけ付く")
    func lineNumbers() {
        let result = TextDiff.compare("a\nb", "a\nB")
        let lines = result.hunks[0].lines
        let removed = lines.first { $0.kind == .removed }
        let added = lines.first { $0.kind == .added }
        #expect(removed?.oldNumber == 2)
        #expect(removed?.newNumber == nil)
        #expect(added?.newNumber == 2)
        #expect(added?.oldNumber == nil)
    }

    @Test("足すだけ・消すだけも数えられる")
    func pureInsertAndDelete() {
        let inserted = TextDiff.compare("a\nc", "a\nb\nc")
        #expect(inserted.added == 1)
        #expect(inserted.removed == 0)

        let deleted = TextDiff.compare("a\nb\nc", "a\nc")
        #expect(deleted.added == 0)
        #expect(deleted.removed == 1)
    }

    /// **全文を並べない。** 離れた 2 か所を直したら、そのまわりだけを 2 つの
    /// 塊で出す（あいだの何十行も出すと読まれない）。
    @Test("離れた変更は別々の塊になる")
    func separateHunks() {
        let old = (1...40).map(String.init).joined(separator: "\n")
        var newLines = (1...40).map(String.init)
        newLines[2] = "x"
        newLines[35] = "y"
        let result = TextDiff.compare(old, newLines.joined(separator: "\n"))
        #expect(result.hunks.count == 2)
        // 前後 3 行 + 消し + 足し
        #expect(result.hunks[0].lines.count <= 9)
    }

    @Test("近い変更は 1 つの塊にまとまる")
    func mergedHunks() {
        let old = (1...20).map(String.init).joined(separator: "\n")
        var newLines = (1...20).map(String.init)
        newLines[5] = "x"
        newLines[7] = "y"
        let result = TextDiff.compare(old, newLines.joined(separator: "\n"))
        #expect(result.hunks.count == 1)
    }

    /// **黙って粗くしない。** 大きすぎて 1 行ずつの対応を諦めたときは、
    /// そのことが分かるようにする（画面で断りを出すため）。
    @Test("大きすぎるときは、まるごと入れ替えとして返す")
    func coarseForHugeInput() {
        let old = (1...900).map { "old-\($0)" }.joined(separator: "\n")
        let new = (1...900).map { "new-\($0)" }.joined(separator: "\n")
        let result = TextDiff.compare(old, new)
        #expect(result.isCoarse)
        #expect(result.added == 900)
        #expect(result.removed == 900)
    }

    /// YAML の実際の直し方（値だけ変える）で確かめる。
    @Test("YAML の値を 1 つ変えたときに、その行だけが出る")
    func yamlValueChange() {
        let old = """
            spec:
              replicas: 1
              template:
                spec:
                  containers:
                  - image: nginx:1.21
            """
        let new = old.replacingOccurrences(of: "nginx:1.21", with: "nginx:1.25")
        let result = TextDiff.compare(old, new)
        #expect(result.added == 1)
        #expect(result.removed == 1)
        let added = result.hunks[0].lines.first { $0.kind == .added }
        #expect(added?.text.contains("nginx:1.25") == true)
    }
}

/// 外から管理されているものを、黙って書き戻させない。
@Suite("管理元の見分け")
struct ManagedByTests {

    @Test("Argo CD はラベルでも注釈でも見つける")
    func argoCD() {
        let byLabel = Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"a","namespace":"d",
             "labels":{"argocd.argoproj.io/instance":"app"}}}
            """)
        let byAnnotation = Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"a","namespace":"d",
             "annotations":{"argocd.argoproj.io/tracking-id":"app:apps/Deployment:d/a"}}}
            """)
        #expect(ManagedBy.detect(byLabel) == .argoCD)
        #expect(ManagedBy.detect(byAnnotation) == .argoCD)
    }

    @Test("Helm と Flux も見分ける")
    func helmAndFlux() {
        let helm = Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"a","namespace":"d",
             "labels":{"app.kubernetes.io/managed-by":"Helm"}}}
            """)
        let flux = Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"a","namespace":"d",
             "labels":{"kustomize.toolkit.fluxcd.io/name":"apps"}}}
            """)
        #expect(ManagedBy.detect(helm) == .helm)
        #expect(ManagedBy.detect(flux) == .flux)
    }

    /// **汎用のラベルを管理元にしない。** `app.kubernetes.io/managed-by` は
    /// 誰でも書けるので、値が `Helm` のときだけ Helm とみなす。
    @Test("managed-by が別の値なら、管理されているとは言わない")
    func otherManagedByValue() {
        let object = Fixture.object(
            """
            {"kind":"Deployment","metadata":{"name":"a","namespace":"d",
             "labels":{"app.kubernetes.io/managed-by":"kubedeck"}}}
            """)
        #expect(ManagedBy.detect(object) == nil)
    }

    @Test("目印が無ければ nil（何も言わない）")
    func none() {
        #expect(ManagedBy.detect(Fixture.pod()) == nil)
    }
}
