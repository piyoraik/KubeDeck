// アプリの実コード（Kubectl / ClusterProxy / APIClient / APIDiscovery）を
// 実クラスタに当てて確かめる。**画面を通さずに、通る道をそのまま叩く。**
//
//   harness <context> [--mutating]
//
// `--mutating` を付けたときだけクラスタに書き込む（kind 専用）。
// **付けなければ読み取りだけ。** Connect Gateway 越しの GKE はこちらで回す。
import Foundation

// MARK: - 小さな検査の枠

actor Report {
    static let shared = Report()
    private var passed = 0
    private var failed: [String] = []
    private var skipped = 0

    func ok(_ name: String, _ detail: String = "") {
        passed += 1
        print("  ✓ \(name)\(detail.isEmpty ? "" : "  — \(detail)")")
    }

    func ng(_ name: String, _ detail: String) {
        failed.append("\(name): \(detail)")
        print("  ✘ \(name)  — \(detail)")
    }

    func skip(_ name: String, _ why: String) {
        skipped += 1
        print("  — \(name)（飛ばした: \(why)）")
    }

    func summary() -> Int {
        print("")
        print("合格 \(passed) / 不合格 \(failed.count) / 飛ばした \(skipped)")
        for f in failed { print("  ✘ \(f)") }
        return failed.isEmpty ? 0 : 1
    }
}

func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") async {
    if condition { await Report.shared.ok(name, detail()) }
    else { await Report.shared.ng(name, detail()) }
}

// MARK: - kubectl を直に叩く（突き合わせの相手）

func kubectlLines(_ arguments: [String], context: String) async -> [String] {
    let environment = try? await Kubectl.shared.environment()
    guard let environment else { return [] }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: environment.executable)
    process.arguments = ["--context", context, "--cache-dir=\(Kubectl.cacheDirectory)"] + arguments
    process.environment = environment.variables
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return [] }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
}

/// 標準入力から `apply` する（**kind 専用**。`--mutating` のときだけ呼ばれる）。
func kubectlApply(_ yaml: String, context: String) async -> Bool {
    guard let environment = try? await Kubectl.shared.environment() else { return false }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: environment.executable)
    process.arguments = ["--context", context, "--cache-dir=\(Kubectl.cacheDirectory)",
                         "apply", "-f", "-"]
    process.environment = environment.variables
    let input = Pipe()
    process.standardInput = input
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return false }
    input.fileHandleForWriting.write(Data(yaml.utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    return process.terminationStatus == 0
}

func kubectlCount(_ resource: String, context: String, namespace: String?) async -> Int? {
    var arguments = ["get", resource, "-o", "name", "--request-timeout=60s"]
    if let namespace, !namespace.isEmpty { arguments += ["-n", namespace] }
    else { arguments.append("--all-namespaces") }
    let lines = await kubectlLines(arguments, context: context)
    return lines.isEmpty ? 0 : lines.count
}

// MARK: - 引き直しの取り合い

/// 表を引いたあとに足された CRD を、**存在しない種別と同時に**解く。
///
/// **「引き直しの取り合い」の再現ではない。** 指摘としては「先に来たほうが
/// `invalidate` で走っている引き直しをキャンセルし、実在する種別が
/// `unknownResource` に化ける」という筋書きだったが、**実測では起きなかった**
/// （旧実装のままで 2 回とも通った。存在しない種別 3 本を先に投げて順序も
/// 寄せた）。理由はコードの並びにある —— `resource()` は先頭で
/// `loadedTable` に入るので、表が捨てられたあとに来た側は**走っている取得に
/// 相乗りする**。相乗り側は古い表を持たないまま新しい表を受け取るので、
/// `invalidate` のある枝に**そもそも到達しない**。
///
/// ここが見ているのは、引き直しの経路そのもの ——
/// **アプリを開いたまま入れた CRD が、同時に走る他の解決に巻き込まれずに
/// 使えるようになるか。** 経路を書き換えたときの回帰網として残す。
///
/// **手元の表にある種別で確かめない。** `services` を相手にすると `match` が
/// 即座に見つけて返すので、**引き直しの枝に一度も入らない**（実測。旧実装の
/// ままでも通ってしまった ——「歯の無い検査」）。表を引いたあとに CRD を
/// 足して、はじめてその枝に入る。
///
/// **本番側に検証用の口を足さない。** 表を古くする近道を作るより、実際の
/// 間隔（`refreshCooldown` ＝ 30 秒）をそのまま待つ。引き直しに入る条件を
/// すり替えると、確かめたつもりになる。
func checkRefreshRace(context: String, client: APIClient, mayMutate: Bool) async {
    guard mayMutate else {
        await Report.shared.skip(
            "引き直しの取り合い", "CRD を足すので --mutating のときだけ（kind 専用）")
        return
    }
    let crd = """
    apiVersion: apiextensions.k8s.io/v1
    kind: CustomResourceDefinition
    metadata:
      name: refreshprobes.kubedeck.test
    spec:
      group: kubedeck.test
      names:
        kind: RefreshProbe
        listKind: RefreshProbeList
        plural: refreshprobes
        singular: refreshprobe
      scope: Namespaced
      versions:
        - name: v1alpha1
          served: true
          storage: true
          schema:
            openAPIV3Schema:
              type: object
    """
    defer {
        // **確かめたら消す。**
        let done = Task.detached {
            _ = await kubectlLines(
                ["delete", "crd", "refreshprobes.kubedeck.test", "--ignore-not-found"],
                context: context)
        }
        _ = done
    }
    guard await kubectlApply(crd, context: context) else {
        await Report.shared.ng("引き直しの取り合い", "CRD を置けなかった")
        return
    }
    print("  … 表が古くなるまで 31 秒待つ（refreshCooldown）")
    try? await Task.sleep(for: .seconds(31))

    // **`async let` で書かない。** ここは最上位から呼ばれるが、`async let` に
    // すると子タスクが隔離の検査に当たって `dispatch_assert_queue_fail` で
    // 落ちた（実測。EXC_BREAKPOINT）。`withTaskGroup` は**アプリが実際に
    // 14 種別を同時に解いている形そのもの**なので、再現としても正しい。
    // **存在しない種別を先に投げる。** 引き直しに入る順序で結果が変わりうる
    // ので、CRD 側を最後に置いて不利な順序に寄せる。
    let outcome = await withTaskGroup(of: (Bool, String?).self) { group in
        for _ in 0..<3 {
            group.addTask {
                do {
                    _ = try await APIDiscovery.shared.resource(
                        for: "hoges.example.com", context: context, client: client)
                    return (false, "解決できてしまった")
                } catch let error as APIDiscoveryError {
                    if case .unknownResource = error { return (false, nil) }
                    return (false, "\(error)")
                } catch {
                    return (false, "\(error)")
                }
            }
        }
        group.addTask {
            do {
                let found = try await APIDiscovery.shared.resource(
                    for: "refreshprobes.kubedeck.test", context: context, client: client)
                return (true, "\(found.plural)/\(found.version)")
            } catch {
                return (true, nil)
            }
        }
        var real: String?
        var fakeDetail: String?
        var fakeIsUnknown = false
        for await (isReal, detail) in group {
            if isReal { real = detail } else {
                fakeDetail = detail
                fakeIsUnknown = detail == nil
            }
        }
        return (real: real, fakeIsUnknown: fakeIsUnknown, fakeDetail: fakeDetail)
    }
    await check(
        "同時に引き直しても、足した CRD が解ける", outcome.real != nil,
        outcome.real ?? "解けなかった")
    await check(
        "同時でも「無い」は「無い」のまま", outcome.fakeIsUnknown,
        outcome.fakeIsUnknown ? "unknownResource" : (outcome.fakeDetail ?? ""))
}

// MARK: - 入口

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    fputs("usage: harness <context> [--mutating]\n", stderr)
    exit(2)
}
let context = arguments[1]
let mayMutate = arguments.contains("--mutating")
let namespace: String? = arguments.first { $0.hasPrefix("--namespace=") }
    .map { String($0.dropFirst("--namespace=".count)) }

print("=== \(context) ===")
print("書き込み: \(mayMutate ? "する（kind 専用）" : "しない（参照のみ）")  Namespace: \(namespace ?? "すべて")")
print("")

await Kubectl.shared.configure(timeoutSeconds: 60, executableOverride: "", usesAPIProxy: true)

// MARK: - 1. 経路が立つか

print("[1] 経路")
let transport = await Kubectl.shared.readTransport(for: context)
_ = try? await Kubectl.shared.list(.namespace, context: context, namespace: nil)
let transport2 = await Kubectl.shared.readTransport(for: context)
await check("proxy 経由になる", transport2 == .apiProxy, "\(transport) → \(transport2)")

if let diagnostics = await Kubectl.shared.proxyDiagnostics(for: context) {
    await check("待ち受けは loopback", diagnostics.address.hasPrefix("127.0.0.1:"), diagnostics.address)
    await check("proxy は走っている", diagnostics.isRunning, "pid \(diagnostics.pid)")
    // **秘密の prefix を診断に出さない。**
    let leaked = diagnostics.recentOutput.contains { $0.contains("api-prefix") }
    await check("診断に prefix を出さない", !leaked)
} else {
    await Report.shared.ng("proxy の診断", "取れない")
}

// MARK: - 2. discovery：アプリが要求する種別名がすべて解けるか

print("")
print("[2] 種別名の解決")
var resolved: [ResourceKind: APIResource] = [:]
if let endpoint = try? await ClusterProxy.shared.endpoint(for: context) {
    let client = APIClient(endpoint: endpoint, timeout: 60)
    // **健全なクラスタの表を「欠けている」扱いにしていないか。**
    //
    // 集約 discovery の `freshness` を読むようにしたので、読み違えると
    // **どのクラスタでも表が partial になり**、覚えていられる時間が
    // 10 分から 1 分に落ちる（そのぶん discovery を引き直す）。しかも
    // 画面には出ないので、測らないと気付けない。
    if let table = try? await APIDiscovery.shared.loadedTable(for: context, client: client) {
        await check("表に欠けが無い", table.isComplete,
                    table.isComplete
                        ? "\(table.entries.count) 種別 / 覚える \(Int(table.lifetime)) 秒"
                        : "欠け: \(table.missingGroups.sorted().joined(separator: ", "))")
    }
    for kind in ResourceKind.allCases {
        do {
            let resource = try await APIDiscovery.shared.resource(
                for: kind.resourceName, context: context, client: client)
            resolved[kind] = resource
            // 解けた先が要求と食い違っていないか（複数形と scope）
            let plural = APIDiscovery.parse(kind.resourceName).plural
            if resource.plural != plural {
                await Report.shared.ng("\(kind.rawValue) の解決", "\(plural) → \(resource.plural)")
            } else if resource.namespaced != kind.isNamespaced {
                await Report.shared.ng(
                    "\(kind.rawValue) の scope",
                    "アプリ \(kind.isNamespaced) / サーバ \(resource.namespaced)")
            }
        } catch {
            await Report.shared.ng("\(kind.rawValue) の解決", "\(error)")
        }
    }
    await check("組み込みの全種別が解けた", resolved.count == ResourceKind.allCases.count,
                "\(resolved.count)/\(ResourceKind.allCases.count)")
    if let node = resolved[.node] {
        // **NodeMetrics に流れていないこと。**
        await check("nodes が core の Node", node.group.isEmpty && node.kind == "Node",
                    "\(node.group.isEmpty ? "core" : node.group)/\(node.kind)")
    }
    if let policy = resolved[.networkPolicy] {
        await check("networkpolicies は networking.k8s.io",
                    policy.group == "networking.k8s.io", policy.group)
    }
} else {
    await Report.shared.ng("endpoint", "立たない")
}

// MARK: - 3. 件数が kubectl と一致するか（読み取りのみ）

print("")
print("[3] 件数の突き合わせ（HTTP と kubectl）")
let sampled: [ResourceKind] = [
    .pod, .deployment, .replicaSet, .daemonSet, .service, .configMap, .secret,
    .node, .namespace, .persistentVolume, .job,
]
for kind in sampled {
    guard resolved[kind] != nil else { continue }
    let scoped = kind.isNamespaced ? namespace : nil
    // **前後で挟んで数える。** 生きているクラスタは数えているあいだにも動く
    // （このクラスタは Helm のリリース Secret が毎分増減する）。前後の
    // kubectl の数の間に入っていれば一致とみなす。
    let before = await kubectlCount(kind.resourceName, context: context, namespace: scoped)
    let viaHTTP = try? await Kubectl.shared.list(kind, context: context, namespace: scoped)
    let after = await kubectlCount(kind.resourceName, context: context, namespace: scoped)
    guard let viaHTTP, let before, let after else {
        await Report.shared.skip("\(kind.rawValue) の件数", "どちらかが引けない")
        continue
    }
    let low = min(before, after), high = max(before, after)
    await check("\(kind.rawValue) の件数", (low...high).contains(viaHTTP.count),
                "HTTP \(viaHTTP.count) / kubectl \(low == high ? "\(low)" : "\(low)〜\(high)")")
}

// MARK: - 4. metadata だけの取得が、ふつうの取得と同じ数になるか

print("")
print("[4] metadata だけの取得")
let countedKinds: [ResourceKind] = [.secret, .configMap, .service, .replicaSet, .namespace]
let full = try? await Kubectl.shared.list(
    kinds: countedKinds, context: context, namespace: namespace)
let meta = try? await Kubectl.shared.list(
    kinds: countedKinds, context: context, namespace: namespace,
    metadataOnly: Set(countedKinds))
if let full, let meta {
    for kind in countedKinds {
        let a = full.objects.filter { $0.kind == kind }.count
        let b = meta.objects.filter { $0.kind == kind }.count
        await check("\(kind.rawValue) は同数", a == b, "ふつう \(a) / metadata \(b)")
    }
    await check("拒まれた種別も同じ", full.denied.count == meta.denied.count)
    await check("知らない種別も同じ", full.unknown.count == meta.unknown.count)
    // metadata だけの側は中身が無いこと（＝運んでいないこと）を確かめる
    let hasSpec = meta.objects.contains { $0.spec != nil || $0.status != nil }
    await check("metadata だけの側に spec/status が無い", !hasSpec)
} else {
    await Report.shared.ng("metadata だけの取得", "引けない")
}

// MARK: - 5. ページ送り

print("")
print("[5] ページ送り")
if let endpoint = try? await ClusterProxy.shared.endpoint(for: context),
   let pods = resolved[.pod] {
    let client = APIClient(endpoint: endpoint, timeout: 60)
    let path = pods.listPath(namespace: namespace)

    /// **数だけでなく、中身の重なりと欠けを見る。**
    /// 続きの目印が戻る実装に当たると、同じものを 2 度取ったり、途中を
    /// 落としたりする。件数の一致だけでは、その両方が打ち消し合って通る。
    func uids(_ pages: [Data]) -> [String] {
        pages.flatMap { page -> [String] in
            guard let root = try? JSONDecoder().decode(JSONValue.self, from: page) else { return [] }
            return (root["items"]?.arrayValue ?? []).compactMap {
                $0.path("metadata.uid")?.stringValue
            }
        }
    }

    let chunked = uids((try? await client.list(path: path, chunk: 3)) ?? [])
    await check("刻んだページに重なりが無い", Set(chunked).count == chunked.count,
                "\(chunked.count) 件 / 相異なる \(Set(chunked).count) 件")

    // **同じ刻み方を 2 回。** クラスタが動いていても、ページ送り自体は
    // 1 回の一覧の中で一貫している（続きの目印が版を固定する）。
    let again = uids((try? await client.list(path: path, chunk: 3)) ?? [])
    let drift = Set(chunked).symmetricDifference(Set(again)).count
    // **増減する種別で「完全一致」を求めない。** このクラスタは毎分 Pod を
    // 作り消しする CronJob を抱えており、77 ページ引くあいだに数個が入れ替わる。
    // ページ送りそのものの正しさは、下の「動かない種別」と「重なりが無い」が
    // 担う。ここでは**桁で外れていないこと**だけを見る。
    let tolerance = max(4, chunked.count / 20)
    await check("刻んだ結果が桁で変わらない", drift <= tolerance,
                "差 \(drift) 件 / 許容 \(tolerance) 件（この間に増減したぶん）")

    // metadata だけでも同じ中身が来ること（**件数ではなく uid で見る**）
    let metaUIDs = uids((try? await client.list(
        path: path, chunk: 3, accept: APIClient.metadataOnlyAccept)) ?? [])
    let missing = Set(again).subtracting(Set(metaUIDs)).count
    await check("metadata だけでも同じものが来る", missing <= tolerance,
                "取れなかった \(missing) 件 / 許容 \(tolerance) 件（増減ぶんを含む）")
    await check("metadata だけでも重なりが無い",
                Set(metaUIDs).count == metaUIDs.count,
                "\(metaUIDs.count) 件")

    // 動かないもので厳密に見る（Namespace は毎分は増減しない）
    if let namespaces = resolved[.namespace] {
        let nsPath = namespaces.listPath(namespace: nil)
        let whole = uids([(try? await client.data(path: nsPath)) ?? Data()])
        let split = uids((try? await client.list(path: nsPath, chunk: 2)) ?? [])
        await check("動かない種別なら刻んでも完全に一致",
                    Set(whole) == Set(split) && !whole.isEmpty,
                    "一括 \(whole.count) / 2 件ずつ \(split.count)")
    }
}

// MARK: - 6. 知らない種別・拒まれた種別

print("")
print("[6] 知らない種別")
if let endpoint = try? await ClusterProxy.shared.endpoint(for: context) {
    let client = APIClient(endpoint: endpoint, timeout: 60)
    do {
        _ = try await APIDiscovery.shared.resource(
            for: "hoges.example.com", context: context, client: client)
        await Report.shared.ng("知らない種別", "解決できてしまった")
    } catch is APIDiscoveryError {
        await Report.shared.ok("知らない種別は APIDiscoveryError")
    } catch {
        await Report.shared.ng("知らない種別", "別の失敗: \(error)")
    }
    // 存在しないパスを直に叩いたときの読み分け
    do {
        _ = try await client.data(path: "apis/nosuch.example.com/v1/widgets")
        await Report.shared.ng("知らないグループ", "200 が返った")
    } catch let error as APIError {
        if case .notFound = error { await Report.shared.ok("知らないグループは 404") }
        else { await Report.shared.ng("知らないグループ", "\(error)") }
    } catch {
        await Report.shared.ng("知らないグループ", "\(error)")
    }

    await checkRefreshRace(context: context, client: client, mayMutate: mayMutate)
}

// MARK: - 7. 取り消し

print("")
print("[7] 取り消し")
let cancelTask = Task {
    try await Kubectl.shared.list(.pod, context: context, namespace: nil)
}
try? await Task.sleep(for: .milliseconds(30))
cancelTask.cancel()
switch await cancelTask.result {
case .success(let objects):
    // 取り消しが間に合わないことはある（速いクラスタ）。落ちなければよい。
    await Report.shared.ok("取り消しても落ちない", "\(objects.count) 件返った")
case .failure(let error):
    await Report.shared.ok("取り消しは失敗として返る", "\(type(of: error))")
}

// MARK: - 8. 常駐の数と後始末

print("")
print("[8] 常駐の数")
// **同時に何本も立てない。** わざと 12 本同時に要求する。
await withTaskGroup(of: Void.self) { group in
    for _ in 0..<12 {
        group.addTask { _ = try? await ClusterProxy.shared.endpoint(for: context) }
    }
}
let running = await kubectlLines(["version", "--client=false"], context: context) // ダミー（待つため）
_ = running
let processes = countProxies()
await check("12 本同時に要求しても proxy は 1 本", processes == 1, "\(processes) 本")

/// **自分の子だけを数える。** `pgrep -f` をシェル越しに使うと、パターンを
/// 含むシェル自身に当たって数が増える（実際それで「2 本立っている」と
/// 誤判定した）。`ps` の出力を自分で読み、親が自分のものだけを数える。
func countProxies() -> Int {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-eo", "ppid=,args="]
    let pipe = Pipe()
    process.standardOutput = pipe
    try? process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let mine = ProcessInfo.processInfo.processIdentifier
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n")
        .filter { line in
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, Int32(parts[0].trimmingCharacters(in: .whitespaces)) == mine
            else { return false }
            return parts[1].contains("proxy") && parts[1].contains("--api-prefix=")
        }
        .count
}

// MARK: - 8b. 立ち上げに相乗りした側も endpoint を受け取れるか

print("")
print("[8b] 起動への相乗り")
await ClusterProxy.shared.stopAll()
await APIDiscovery.shared.invalidateAll()
// **まっさらから 12 本同時に要求する。** 1 本が立ち上げ、残り 11 本は
// それに相乗りする。相乗り側が「畳まれた」と誤判定すると、ここで落ちる
// （実測でその形の取りこぼしを 1 度出した）。
let riders = await withTaskGroup(of: Bool.self) { group in
    for _ in 0..<12 {
        group.addTask {
            ((try? await ClusterProxy.shared.endpoint(for: context)) != nil)
        }
    }
    var ok = 0
    for await success in group where success { ok += 1 }
    return ok
}
await check("12 本すべてが待ち受け先を受け取る", riders == 12, "\(riders)/12")
await check("それでも proxy は 1 本", countProxies() == 1, "\(countProxies()) 本")

// MARK: - 9. イベント（fieldSelector）

print("")
print("[9] イベント")
if let pods = try? await Kubectl.shared.list(.pod, context: context, namespace: namespace),
   let pod = pods.first {
    let events = try? await Kubectl.shared.events(for: pod, context: context)
    let viaCLI = await kubectlLines(
        ["get", "events", "-n", pod.namespace ?? "default",
         "--field-selector=involvedObject.uid=\(pod.uid)", "-o", "name",
         "--request-timeout=60s"], context: context)
    if let events {
        await check("イベントの件数が一致", events.count == viaCLI.count,
                    "HTTP \(events.count) / kubectl \(viaCLI.count)")
        // 新しい順に並んでいること
        let dates = events.compactMap { ResourceTable.lastSeen($0) }
        await check("新しい順", dates == dates.sorted(by: >), "\(dates.count) 件")
    } else {
        await Report.shared.ng("イベント", "引けない")
    }
} else {
    await Report.shared.skip("イベント", "Pod がいない")
}

// MARK: - 10. メトリクス

print("")
print("[10] メトリクス")
let hasMetrics = await Kubectl.shared.metricsServerAvailable(context: context, namespace: namespace)
if hasMetrics {
    let snapshot = await Kubectl.shared.metrics(context: context, namespace: namespace)
    let topLines = await kubectlLines(
        ["top", "pods", "--no-headers"] + (namespace.map { ["-n", $0] } ?? ["--all-namespaces"]),
        context: context)
    await check("Pod の使用量が取れた", !snapshot.pods.isEmpty, "\(snapshot.pods.count) 件")
    if !topLines.isEmpty {
        // ±10% の差は scrape の間隔で出る。件数だけ突き合わせる。
        await check("kubectl top と同じ規模", abs(snapshot.pods.count - topLines.count) <= 2,
                    "HTTP \(snapshot.pods.count) / top \(topLines.count)")
    }
    await check("ノードの使用量が取れた", !snapshot.nodes.isEmpty, "\(snapshot.nodes.count) 台")
} else {
    await Report.shared.skip("メトリクス", "metrics-server が無い")
}

// MARK: - 11. CRD（書き込みを許したときだけ作る）

print("")
print("[11] CRD")
let customTypes = await Kubectl.shared.customResourceTypes(context: context)
await check("CRD の一覧が引けた", true, "\(customTypes.count) 種")
if let sample = customTypes.first {
    let objects = try? await Kubectl.shared.list(
        resource: sample.resourceName, namespaced: sample.namespaced,
        context: context, namespace: sample.namespaced ? namespace : nil)
    let viaCLI = await kubectlCount(
        sample.resourceName, context: context,
        namespace: sample.namespaced ? namespace : nil)
    if let objects, let viaCLI {
        await check("CRD \(sample.kind) の件数", objects.count == viaCLI,
                    "HTTP \(objects.count) / kubectl \(viaCLI)")
    } else {
        await Report.shared.skip("CRD の件数", "引けない（権限？）")
    }
} else {
    await Report.shared.skip("CRD の中身", "CRD が入っていない")
}

// MARK: - 12. Namespace の指定まわり

print("")
print("[12] Namespace の扱い")
// Namespace を持たない種別に Namespace を渡しても壊れないこと
let nodesWithNS = try? await Kubectl.shared.list(.node, context: context, namespace: "kube-system")
await check("Node に Namespace を渡しても引ける", (nodesWithNS?.isEmpty == false),
            "\(nodesWithNS?.count ?? -1) 台")
// 空文字はすべての Namespace と同じ扱いになること
let emptyNS = try? await Kubectl.shared.list(.pod, context: context, namespace: "")
let allNS = try? await Kubectl.shared.list(.pod, context: context, namespace: nil)
await check("空文字 = すべての Namespace",
            (emptyNS?.count ?? -1) == (allNS?.count ?? -2),
            "\(emptyNS?.count ?? -1) / \(allNS?.count ?? -1)")


// MARK: - 13. 拒まれた種別（--expect-denied を付けたときだけ）

if arguments.contains("--expect-denied") {
    print("")
    print("[13] 拒まれた種別")
    let kinds: [ResourceKind] = [.pod, .secret, .namespace]
    if let listed = try? await Kubectl.shared.list(
        kinds: kinds, context: context, namespace: nil) {
        await check("拒まれた種別が拒否として返る", !listed.denied.isEmpty,
                    "denied=\(listed.denied.map(\.rawValue))")
        // **0 件と混ぜない。** 拒まれた種別は数に入れてはいけない。
        await check("拒まれた種別を 0 件にしない",
                    listed.denied.allSatisfy { kind in
                        !listed.objects.contains { $0.kind == kind }
                    })
        // **一部だけ拒まれたとき、読めたぶんを捨てない。** ここがこの経路の
        // いちばん大事なところ（kubectl 経由では「読めた JSON を伴う exit 1」を
        // 拾い直して守っていた性質）。
        let readable = kinds.filter { !listed.uncounted.contains($0) }
        await check("読めた種別は捨てない", !readable.isEmpty,
                    "読めた \(readable.map(\.rawValue))")
        for kind in readable {
            await check("\(kind.rawValue) は中身が来ている",
                        listed.objects.contains { $0.kind == kind })
        }
    } else {
        await Report.shared.ng("拒まれた種別", "丸ごと投げられた（読めたぶんも捨てている）")
    }
}

// MARK: - 14. proxy が死んだときの立て直し

print("")
print("[14] 立て直し")
if let before = await Kubectl.shared.proxyDiagnostics(for: context) {
    kill(before.pid, SIGKILL)
    try? await Task.sleep(for: .seconds(1))
    let objects = try? await Kubectl.shared.list(.namespace, context: context, namespace: nil)
    let after = await Kubectl.shared.proxyDiagnostics(for: context)
    await check("殺しても引き直せる", (objects?.isEmpty == false), "\(objects?.count ?? -1) 件")
    await check("別の proxy が立っている", after != nil && after?.pid != before.pid,
                "\(before.pid) → \(after?.pid ?? -1)")
    await check("立て直しても 1 本のまま", countProxies() == 1, "\(countProxies()) 本")
} else {
    await Report.shared.skip("立て直し", "proxy が無い")
}

// MARK: - 15. kubeconfig が変わったら立て直す

print("")
print("[15] kubeconfig の見張り")
if let path = ProcessInfo.processInfo.environment["KUBECONFIG"], !path.contains(":") {
    let before = await Kubectl.shared.proxyDiagnostics(for: context)
    // 中身は変えず、更新時刻だけ動かす（指紋は mtime と大きさで見ている）
    try? FileManager.default.setAttributes(
        [.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: path)
    _ = try? await Kubectl.shared.list(.namespace, context: context, namespace: nil)
    let after = await Kubectl.shared.proxyDiagnostics(for: context)
    await check("書き換わったら立て直す", before?.pid != after?.pid,
                "\(before?.pid ?? -1) → \(after?.pid ?? -1)")
    await check("立て直しても 1 本のまま", countProxies() == 1, "\(countProxies()) 本")
} else {
    await Report.shared.skip("kubeconfig の見張り", "KUBECONFIG が単一のパスでない")
}

// MARK: - 15b. ラベルで Pod を引く（ログの経路で唯一 HTTP を通るところ）

print("")
print("[15b] ラベルで引く")
if let deployments = try? await Kubectl.shared.list(
    .deployment, context: context, namespace: namespace),
   let deployment = deployments.first(where: {
       !($0.spec?.path("selector.matchLabels")?.stringDictionary ?? [:]).isEmpty
   }),
   let labels = deployment.spec?.path("selector.matchLabels")?.stringDictionary,
   let ns = deployment.namespace {
    let pods = try? await Kubectl.shared.pods(
        matchingLabels: labels, namespace: ns, context: context)
    let selector = labels.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",")
    let viaCLI = await kubectlLines(
        ["get", "pods", "-n", ns, "-l", selector, "-o", "name", "--request-timeout=60s"],
        context: context)
    await check("ラベルで引いた Pod の数が一致", pods?.count == viaCLI.count,
                "HTTP \(pods?.count ?? -1) / kubectl \(viaCLI.count)（\(deployment.name)）")
    // **空のセレクタで引かない**（Namespace 全部を掴んでしまう）。
    let empty = try? await Kubectl.shared.pods(
        matchingLabels: [:], namespace: ns, context: context)
    await check("空のセレクタでは 1 件も引かない", empty?.isEmpty == true)
} else {
    await Report.shared.skip("ラベルで引く", "セレクタを持つ Deployment がいない")
}

// MARK: - 16. コンテキストを行き来する（--switch=<別のコンテキスト>）

if let other = arguments.first(where: { $0.hasPrefix("--switch=") })
    .map({ String($0.dropFirst("--switch=".count)) }) {
    print("")
    print("[16] コンテキストの行き来")
    var ok = true
    var counts: [String] = []
    for round in 1...4 {
        for target in [context, other] {
            // アプリと同じ順序：切り替えたら、要らない proxy を畳んでから引く。
            await Kubectl.shared.releaseTransports(keeping: target)
            let objects = try? await Kubectl.shared.list(.namespace, context: target, namespace: nil)
            let n = countProxies()
            counts.append("\(target.prefix(12))=\(objects?.count ?? -1)/\(n)本")
            if (objects?.isEmpty ?? true) || n != 1 { ok = false }
        }
        _ = round
    }
    await check("行き来しても引けて、proxy は常に 1 本", ok, counts.joined(separator: " "))
}

// MARK: - 17. 設定で経路を切り替える

print("")
print("[17] 経路の切り替え")
// 切る → kubectl 経由になり、常駐は畳まれる
await Kubectl.shared.configure(
    timeoutSeconds: 60, executableOverride: "", usesAPIProxy: false)
let offObjects = try? await Kubectl.shared.list(.namespace, context: context, namespace: nil)
let offTransport = await Kubectl.shared.readTransport(for: context)
await check("切ると kubectl 経由になる", offTransport == .kubectl(reason: nil), "\(offTransport)")
await check("切っても引ける", (offObjects?.isEmpty == false), "\(offObjects?.count ?? -1) 件")
await check("切ると常駐が畳まれる", countProxies() == 0, "\(countProxies()) 本")

// 入れ直す → また常駐が立つ
await Kubectl.shared.configure(
    timeoutSeconds: 60, executableOverride: "", usesAPIProxy: true)
let onObjects = try? await Kubectl.shared.list(.namespace, context: context, namespace: nil)
let onTransport = await Kubectl.shared.readTransport(for: context)
await check("入れ直すと proxy 経由に戻る", onTransport == .apiProxy, "\(onTransport)")
await check("戻しても引ける", onObjects?.count == offObjects?.count,
            "\(onObjects?.count ?? -1) / \(offObjects?.count ?? -1)")
await check("戻したら 1 本", countProxies() == 1, "\(countProxies()) 本")

// MARK: - 後始末

await ClusterProxy.shared.stopAll()
let left = countProxies()
await check("畳んだら proxy が残らない", left == 0, "\(left) 本")

exit(Int32(await Report.shared.summary()))
