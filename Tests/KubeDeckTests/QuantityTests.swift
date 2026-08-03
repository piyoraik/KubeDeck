import Testing
@testable import KubeDeck

/// metrics API は CPU をナノコア、メモリを `Ki` で返す一方、requests は `100m` や
/// `512Mi`。**同じ「CPU」で桁が 9 つ違う**ので、比べる前に基本単位へ揃える。
@Suite("単位の換算")
struct QuantityTests {

    @Test("metrics API のナノコアをコアに直す")
    func nanocores() throws {
        let cores = try #require(Quantity.parse("81768992n"))
        #expect(abs(cores - 0.081768992) < 1e-12)
    }

    @Test("requests のミリコアをコアに直す")
    func millicores() {
        #expect(Quantity.parse("100m") == 0.1)
        #expect(Quantity.parse("1500m") == 1.5)
    }

    @Test("2 進接頭辞をバイトに直す")
    func binaryPrefixes() {
        #expect(Quantity.parse("512Mi") == 536_870_912)
        #expect(Quantity.parse("1Ki") == 1024)
        #expect(Quantity.parse("2Gi") == 2_147_483_648)
    }

    @Test("単位なしはそのまま")
    func bare() {
        #expect(Quantity.parse("8") == 8)
        #expect(Quantity.parse("0") == 0)
    }

    /// **`129e6`（指数）と `1E`（exa）を取り違えない。**
    /// 単位を剥がす前に、数値部が `Double` として読めるかを確かめている。
    @Test("指数表記の e/E を単位と取り違えない")
    func exponentIsNotExa() throws {
        // 129e6 は 1.29 億であって、129 エクサではない。
        let exponent = try #require(Quantity.parse("129e6"))
        #expect(exponent == 129_000_000)

        // こちらは本物の E（exa）。
        let exa = try #require(Quantity.parse("1E"))
        #expect(exa == 1e18)
    }

    @Test("読めないものは nil。0 と混ぜない")
    func unparsable() {
        #expect(Quantity.parse("") == nil)
        #expect(Quantity.parse("なし") == nil)
        // 単位だけで数値部が無いものも nil。
        #expect(Quantity.parse("Mi") == nil)
    }

    // MARK: - 割合

    /// **分母が 0 のときに `0%` と出さない。**
    /// 「まだ余裕がある」と読めてしまう。
    @Test("分母が 0 なら割合を出さない")
    func ratioWithoutDenominator() {
        #expect(Quantity.ratio(1, of: 0) == nil)
        #expect(Quantity.ratio(0, of: 0) == nil)
        #expect(Quantity.ratio(1, of: 2) == 0.5)
    }

    // MARK: - 整形

    /// **1m 未満を `0m` と出さない。** 「使っていない」に見える。
    @Test("わずかな使用量を 0 と出さない")
    func tinyUsage() {
        #expect(Quantity.formatCPU(cores: 0.0001) == "1m")
        #expect(Quantity.formatCPU(cores: 0) == "0m")
    }

    @Test("ちょうどのコア数は小数を付けない")
    func wholeCores() {
        #expect(Quantity.formatCPU(cores: 8) == "8")
        #expect(Quantity.formatCPU(cores: 0.5) == "500m")
    }

    @Test("メモリは kubectl top と同じ 2 進接頭辞で出す")
    func memoryFormatting() {
        #expect(Quantity.formatMemory(bytes: 512 * 1_048_576) == "512Mi")
        #expect(Quantity.formatMemory(bytes: 1024) == "1.0Ki")
        #expect(Quantity.formatMemory(bytes: 0) == "0")
    }

    // MARK: - Pod 合計

    /// **初期化コンテナは同時に動かないので合計に入れない。**
    /// `containerResourceTotal` と設定タブがずれると、2 か所で違う数字が出る。
    @Test("Pod 合計は通常コンテナだけを足す")
    func podTotalsExcludeInitContainers() {
        let pod = Fixture.pod(
            containers: """
                [{"name":"a","resources":{"requests":{"cpu":"100m","memory":"128Mi"}}},
                 {"name":"b","resources":{"requests":{"cpu":"200m","memory":"256Mi"}}}]
                """)

        let requests = pod.containerResourceTotal("requests")
        #expect(abs(requests.cpuCores - 0.3) < 1e-9)
        #expect(requests.memoryBytes == 402_653_184)
    }

    @Test("limits が無いコンテナは 0 として足す（欠けを合計に混ぜない）")
    func missingLimits() {
        let pod = Fixture.pod(
            containers: #"[{"name":"a","resources":{"requests":{"cpu":"100m"}}}]"#)

        #expect(pod.containerResourceTotal("limits").cpuCores == 0)
        #expect(pod.containerResourceTotal("limits").isZero)
    }

    @Test("ノードの分母は capacity ではなく allocatable")
    func nodeAllocatable() {
        let node = Fixture.node(name: "n1", cpu: "8", memory: "16Gi")
        #expect(node.nodeAllocatable.cpuCores == 8)
        #expect(node.nodeAllocatable.memoryBytes == 17_179_869_184)
    }
}
