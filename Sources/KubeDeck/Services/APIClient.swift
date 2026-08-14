import Foundation

/// API サーバが失敗を伝えるときの `Status`。
///
/// **文言を正規表現で漁らなくてよくなる。** kubectl 経由では、種別ごとの拒否を
/// `stderr` の `<resource> is forbidden` から拾っていた（書式に依存するので
/// `KubectlTests` で固めてある）。HTTP なら状態コードと `reason` が構造として
/// 来る（実測: 403 で `{"kind":"Status","reason":"Forbidden","message":"secrets is
/// forbidden: …"}`）。
struct APIStatus: Sendable {
    var code: Int
    var reason: String
    var message: String

    init(code: Int, reason: String = "", message: String = "") {
        self.code = code
        self.reason = reason
        self.message = message
    }

    /// body から読む。読めなければ状態コードだけ持つ。
    ///
    /// **body が JSON でないこともある。** 知らない API グループを引くと
    /// apiserver は `404 page not found` という素のテキストを返す（実測。
    /// 知っているグループの知らない種別なら `Status` が返る）。
    init(code: Int, body: Data) {
        self.init(code: code)
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: body),
              root["kind"]?.stringValue == "Status"
        else {
            let text = String(data: body.prefix(400), encoding: .utf8) ?? ""
            message = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return
        }
        reason = root["reason"]?.stringValue ?? ""
        message = root["message"]?.stringValue ?? ""
    }
}

enum APIError: LocalizedError, Sendable {
    case forbidden(APIStatus)
    case notFound(APIStatus)
    case unauthorized(APIStatus)
    case conflict(APIStatus)
    case status(APIStatus)
    /// 待ち上限まで返ってこなかった。
    case timedOut(seconds: Int)
    /// proxy に繋がらない（落ちた・立て直しの最中）。
    case unreachable(String)
    case malformed(String)

    var status: APIStatus? {
        switch self {
        case .forbidden(let status), .notFound(let status), .unauthorized(let status),
             .conflict(let status), .status(let status):
            return status
        case .timedOut, .unreachable, .malformed:
            return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .forbidden(let status):
            return status.message.isEmpty
                ? String(localized: "この操作を行う権限がありません。") : status.message
        case .notFound(let status):
            return status.message.isEmpty
                ? String(localized: "見つかりませんでした。") : status.message
        case .unauthorized(let status):
            // **認証の失敗と権限の不足を混ぜない。** 401 は「誰であるかが通って
            // いない」、403 は「その人にその操作が許されていない」。
            return String(localized: """
                資格情報が受け付けられませんでした（401）。
                \(status.message)
                """)
        case .conflict(let status):
            return status.message.isEmpty
                ? String(localized: "ほかで変更されています。読み直してください。") : status.message
        case .status(let status):
            return status.message.isEmpty
                ? String(localized: "API サーバが \(status.code) を返しました。") : status.message
        case .timedOut(let seconds):
            return String(localized: """
                \(seconds) 秒待っても API サーバから応答がありませんでした。
                認証は通っていて、そこから先の経路で止まっている可能性があります。
                """)
        case .unreachable(let detail):
            return String(localized: """
                kubectl proxy に繋がりませんでした。
                \(detail)
                """)
        case .malformed(let detail):
            return String(localized: "API の応答を読み取れませんでした。\(detail)")
        }
    }
}

/// 常駐 proxy に HTTP で話す口。
///
/// **`kubectl` の代わりではない。** 置き換えるのは読み取りだけで、書き込み・
/// `drain`・`rollout undo`・`exec` は kubectl のまま（あちらはクライアント側の
/// 実装と `--dry-run=server` の答えに依存していて、こちらで組み直すと判断が
/// ずれる）。ログも kubectl のまま —— まとめ読みの `--prefix` と
/// `--max-log-requests` は kubectl 側の機能で、API には無い。
struct APIClient: Sendable {
    let endpoint: ClusterProxy.Endpoint
    let timeout: TimeInterval

    /// **User-Agent を明示する。** apiserver は UA を見て整形を変える（実測:
    /// curl の既定だと pretty で 563KB、アプリ名なら compact で 273.8KB）。
    /// 監査ログにも出るので、名乗っておくほうがよい。
    private static let userAgent: String = {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        return "KubeDeck/\(version)"
    }()

    /// metadata だけを要求する Accept。
    ///
    /// **件数しか使わない取得に spec / status を運ばせない。** Connect Gateway 越しの
    /// GKE で実測（同じ Namespace 集合、1 ページ 500）:
    ///
    /// | 種別 | ふつう | metadata だけ |
    /// |---|---|---|
    /// | secrets | 6.85MB / 2.95〜3.98s | **51KB / 0.13〜0.27s** |
    /// | configmaps | 1.72MB / 0.51〜0.54s | 141KB / 0.21〜0.22s |
    /// | pods | 2.62MB / 0.39〜0.40s | 122KB / 0.20〜0.41s |
    ///
    /// **gzip では代わりにならない。** 圧縮は要求している（URLSession が自動で
    /// `Accept-Encoding` を送る）が、実測では secrets が 4.67MB に縮んでも
    /// **時間は 2.98〜3.97s のまま**だった。運ぶ量ではなく、サーバがその量を
    /// 組み立てる費用が効いている。だから「運ばせない」ほうを選ぶ。
    ///
    /// **返る `kind` は `PartialObjectMetadataList`** になり、items には
    /// `metadata` しか入らない（実測）。だから**件数と metadata しか使わない
    /// 経路にだけ使う。**
    static let metadataOnlyAccept =
        "application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1"

    /// 同時に張る接続の上限。
    ///
    /// **上げすぎない。** 最初は 16 にしていたが、Connect Gateway 越しの GKE で
    /// **14 本を同時に投げると全滅した**（実測。1 巡目だけ 14 本すべてが
    /// 120 秒の待ち上限に当たり、**受信 0 バイト** —— 応答の見出しすら来ない。
    /// 同じ 14 本が別の巡では 2.9〜5.1 秒で終わる）。大きい応答を重ねると
    /// ゲートウェイ側で詰まるらしく、**遅くなるのではなく返ってこなくなる**。
    ///
    /// **下げすぎない。** 同じ 14 種別で、同時 1 本なら 10.6〜15.3 秒、
    /// 4 本で 5.6〜7.7 秒、14 本で 2.9〜3.9 秒（実測）。往復を並べる効きは
    /// はっきりある。
    ///
    /// 6 は macOS の既定でもあり、上の実測の「詰まらなかった側」に収まる。
    /// 件数しか使わない種別は metadata だけを引くので（`metadataOnlyAccept`）、
    /// 波に分かれても軽いほうから抜けていく。
    private static let maxConnections = 6

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = maxConnections
        // **システムのプロキシ設定を引き継がない。** 相手は 127.0.0.1 で、
        // 経由する意味が無い。TLS を覗く社内プロキシが入っていて loopback が
        // 除外に無い環境では、**この要求がそちらへ回されて落ちる** ——
        // 症状は「kubectl proxy に繋がりません」だけで、ターミナルの kubectl は
        // 通るので、いちばん切り分けにくい形になる。
        configuration.connectionProxyDictionary = [:]
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpAdditionalHeaders = [
            "Accept": "application/json",
            "User-Agent": userAgent,
        ]
        return URLSession(configuration: configuration)
    }()

    // MARK: - 引く

    /// 1 本引いて、body を返す。
    ///
    /// `managedFields` はここで落とす。**理由は大きさではなく復号の費用**
    /// （実測、同じ Pod 39 件で `K8sObject.list` まで通したとき）:
    ///
    /// | 経路 | 大きさ | 復号 |
    /// |---|---|---|
    /// | いま（kubectl の pretty・MF なし） | 474KB | 119ms |
    /// | API の compact・MF あり | 273KB | 270ms |
    /// | API の compact・MF を落とす | 273KB → 178KB | **135ms** |
    ///
    /// バイト数は減っているのに、落とさないと**倍以上かかる** —— `JSONValue` は
    /// 節の数だけ `try?` の連鎖を通るので、`f:metadata` のような小さな入れ子が
    /// 大量に増えるのが効く。`JSONSerialization` は 10 倍以上速いので、
    /// 落とす費用（約 5ms）より木が小さくなる得のほうが大きい。
    /// - Parameter accept: 差し替えたいときだけ渡す（集約 discovery を要求する
    ///   ときに使う）。渡さなければ共通設定の `application/json`。
    func data(path: String, query: [URLQueryItem] = [], accept: String? = nil) async throws -> Data {
        guard let url = endpoint.url(path: path, query: query) else {
            throw APIError.malformed(String(localized: "URL を組み立てられませんでした。"))
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.httpMethod = "GET"
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch let error as URLError {
            throw translate(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.malformed(String(localized: "HTTP の応答ではありませんでした。"))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Self.error(code: http.statusCode, body: data)
        }
        return Self.pruned(data)
    }

    /// 一覧を引く。`limit` を超えるぶんは `continue` で継ぎ足す。
    ///
    /// **一度に全部を要求しない。** kubectl に `--chunk-size=500` を渡していたのと
    /// 同じ理由で、数千 Pod のクラスタで API サーバに一撃で数十 MB を作らせない。
    /// こちらは `?limit=&continue=` を自分で回す（実測で `metadata.continue` と
    /// `remainingItemCount` が返る）。
    func list(
        path: String, query: [URLQueryItem] = [], chunk: Int, accept: String? = nil
    ) async throws -> [Data] {
        var pages: [Data] = []
        var token: String?
        repeat {
            var items = query
            items.append(URLQueryItem(name: "limit", value: "\(chunk)"))
            if let token, !token.isEmpty {
                items.append(URLQueryItem(name: "continue", value: token))
            }
            let page = try await data(path: path, query: items, accept: accept)
            pages.append(page)
            let next = Self.continueToken(in: page)
            // **際限なく回さないが、黙って切らない。**
            //
            // 以前は「41 ページで打ち切る」だけにしていた。あれは 2 万件を超える
            // クラスタで**一覧を途中まで出して全部だと言う**ことになり、しかも
            // 画面のどこにも出ない（`--chunk-size` を付ける理由そのものの規模で
            // 起きる）。守りたいのは「`continue` が進まない相手に無限に問い続け
            // ない」ことだけなので、**進んでいるかどうかで見る。**
            if let next, next == token {
                throw APIError.malformed(
                    String(localized: "一覧の続きを取れませんでした（続きの目印が進みません）。"))
            }
            token = next
        } while !(token ?? "").isEmpty
        return pages
    }

    /// 続きの目印。
    ///
    /// **`JSONValue` に落として読まない。** あれは節の数だけ `try?` の連鎖を
    /// 通るので、273KB のページで 135〜270ms かかる（この経路は取得のたびに
    /// 通るうえ、読んだ本体はどのみち呼び出し側でもう 1 度木にする）。
    /// `JSONSerialization` なら同じページが数 ms で済む。
    static func continueToken(in page: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: page)) as? [String: Any],
              let metadata = root["metadata"] as? [String: Any],
              let token = metadata["continue"] as? String, !token.isEmpty
        else { return nil }
        return token
    }

    // MARK: - 失敗の訳し方

    private func translate(_ error: URLError) -> APIError {
        switch error.code {
        case .timedOut:
            return .timedOut(seconds: Int(timeout.rounded()))
        case .cancelled:
            // 取り消しはそのまま伝える（世代番号で捨てる側の判断を邪魔しない）。
            return .unreachable(String(localized: "取り消されました。"))
        default:
            // **URL をそのまま載せない。** `localizedDescription` にも
            // `NSErrorFailingURLStringKey` にも prefix 付きの URL が入る（実測）。
            return .unreachable(endpoint.redacting(error.localizedDescription))
        }
    }

    static func error(code: Int, body: Data) -> APIError {
        let status = APIStatus(code: code, body: body)
        switch code {
        case 401: return .unauthorized(status)
        case 403: return .forbidden(status)
        case 404: return .notFound(status)
        case 409: return .conflict(status)
        default: return .status(status)
        }
    }

    // MARK: - managedFields を落とす

    /// `items[].metadata.managedFields` と、単体取得の
    /// `metadata.managedFields` を落とす。
    ///
    /// **落とせなかったら元のまま返す。** ここで投げると「取れているのに
    /// 取れていないことにする」ことになる。YAML タブは kubectl の
    /// `-o yaml` を通るので、原文が要る場面はこちらの影響を受けない。
    static func pruned(_ data: Data) -> Data {
        guard var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return data }
        var touched = false
        if var items = root["items"] as? [[String: Any]] {
            for index in items.indices {
                if var metadata = items[index]["metadata"] as? [String: Any],
                   metadata.removeValue(forKey: "managedFields") != nil {
                    items[index]["metadata"] = metadata
                    touched = true
                }
            }
            if touched { root["items"] = items }
        }
        if var metadata = root["metadata"] as? [String: Any],
           metadata.removeValue(forKey: "managedFields") != nil {
            root["metadata"] = metadata
            touched = true
        }
        guard touched,
              let pruned = try? JSONSerialization.data(withJSONObject: root)
        else { return data }
        return pruned
    }
}
