---
type: 設計書
title: たどるに経路（HTTPRoute）を載せる
status: 実装済み（オプション。既定は切）
date: 2026-11-25
---

# たどるに経路（HTTPRoute）を載せる

## 結論

メッシュを入れたクラスタで「この Service を呼ぶと、どのワークロードに何 % 届くのか」を、たどるの図に出す。
最初に載せるのは Gateway API の HTTPRoute で、Istio の VirtualService は後段に回す。
**図に出すのは宣言された経路で、実際の流量ではない。** 実測で、宣言があっても振り分けが起きない場合が 3 通りあった。

| 決めること | 決めた内容 | 理由 |
|---|---|---|
| 有効化 | 設定の「配置 › Istio / Gateway API」で入れたときだけ動く。既定は切 | 使わないクラスタに取得を足さない。切っているあいだは図も取得も変わらない（実画面で確認） |
| 対象 | HTTPRoute を先に載せる | 手元の Istio は ambient モード。HTTPRoute は受け付けの結果をコントローラが書く。VirtualService には書かれない（実測） |
| 受け付けたか | コントローラが書いた `status.parents` を読む。自前で判定しない | ReferenceGrant を自前で評価していたら、届いている経路を「届かない」と描いていた（実測） |
| 図 | 経路を起点にしたときは、呼び出し先から宛先へ割合つきで分かれる「振り分け」の図を出す。ほかの起点では、親が Gateway の経路は入口の列に器で、親が Service の経路は Service に札で指す | 割合は 1 つの呼び出し先から複数の宛先へ分かれる形で、枝ごとの札だけでは「残りは親に行く」と読まれた（実機での指摘）。親が Service の経路を入口に置くと、親を経路の下流に描くことになる（実際の順と逆） |
| 起点 | 起点の種別に HTTPRoute を足す | 「この経路の先に何があるか」は Ingress と同じ問い |
| 取得 | 配置の取得と並行して、同じ世代番号で引く | 割合はカナリアの途中で動く。Pod と別の時点の絵にしない |

| 段階 | 内容 | 状態 |
|---|---|---|
| 0 | 実クラスタで `status` と実際の振り分けを測る | 済み |
| 1 | 経路を読むモデルと単体テスト | 済み |
| 2 | 取得と、入口の列への表示 | 済み |
| 3 | 起点 | 済み |

テスト一式は 527 件が通っている（うち今回のものは `TrafficRouteTests` 31 件と `TraceRoutesTests` 26 件）。画面は `cluster-dev` に検証用のリソースを当てて撮って確かめた。振り分けの図にしたあとに見たのは 5 通り: 親が Service の経路、親が Gateway の経路、宛先の片方が無い経路（破線と ✕）、規則が 3 つある経路（宛先を持たない規則を含む）、ワークロードを起点にした図（入口の器と札）。それより前に、入口の列が無い枝が既定の窓幅で詳細パネルを開いても収まることを見ている。札や器を押したときの動きは、画面では確かめていない。

## 何が見えるようになるか

Service `reviews` が v1 と v2 の Pod を両方掴み、HTTPRoute が v1 に 90、v2 に 10 を割り当てているとする。

```
いま（reviews-v2 の枝）
  reviews         reviews-v2
  Service     ─▶  Deployment  ─▶ ReplicaSet ─▶ Pod ─▶ ノード
  reviews-v2
  Service

経路を起点にしたとき（振り分けの図。割合の全体はここで見る）
  ┌───────────────────────────┐
  │ reviews  Service           │ ── 90% ──▶  reviews-v1  Service
  │ ここ宛ての呼び出しの行き先   │ ── 10% ──▶  reviews-v2  Service
  │ [██████████████████|██]    │
  └───────────────────────────┘
  宛先の先
  reviews-v1  Service  ─▶  reviews-v1  Deployment  ─▶ ReplicaSet ─▶ Pod ─▶ ノード
  reviews-v2  Service  ─▶  reviews-v2  Deployment  ─▶ ReplicaSet ─▶ Pod ─▶ ノード

ほかの起点のとき（親が Gateway の経路。外からの入口。図は入口から始まる）
  shop-edge             web-v2       web-v2
  HTTPRoute · 10%  ─▶   Service  ─▶  Deployment  ─▶ ReplicaSet ─▶ Pod ─▶ ノード

ほかの起点のとき（親が Service の経路。メッシュの中の振り分け。札で指すだけ）
  reviews                 reviews-v2
  Service             ─▶  Deployment  ─▶ ReplicaSet ─▶ Pod ─▶ ノード
  └ reviews が振り分け
  reviews-v2
  Service
  └ reviews から 10%
```

割合の全体（どこへ何 %、足して 100%）は、経路を起点にした図で見る。ほかの起点の図の器と札は、押すとその図へ飛ぶ入口になる。

- なぜ v2 にリクエストが来ないのか（割合が 0%）。カナリアはいま何 % か。
- この経路は受け付けられているか。受け付けられていなければ、コントローラが書いた理由を出す。
- 宛先の Service が無い（そのぶんのリクエストは 500 になる）。

画面のモック: <https://claude.ai/artifact/V7DBTaz2NcjhWc28x4K3bN>

## 実測

`cluster-dev`、Istio 1.32.0（ambient）、Gateway API v1.6.1、2026-11-25。振り分けは、同じ Namespace の Pod からリクエストを投げて、応えた Pod を数えた。v1 は 2 Pod、v2 は 1 Pod。

| 試したこと | `status` に書かれたこと | 実際の振り分け |
|---|---|---|
| 経路なし | — | 40:20（Pod 数の比） |
| Service が親（90:10）。waypoint なし | 3 条件とも True。`ResolvedWaypoints` の文言は「…route will not be respected」 | **40:20 のまま。効かない** |
| 同じ経路。waypoint あり | `ResolvedWaypoints` の文言が「All waypoints resolved」に変わる | 187:13 |
| Service に `istio.io/use-waypoint: none` | 「All waypoints resolved」 | **67:33。効かない** |
| 存在しない waypoint を指すラベル | 「All waypoints resolved」 | **42:18。効かない** |
| 宛先の片方が存在しない（50:50） | `ResolvedRefs=False`、reason は `BackendNotFound` | 200 が 52 回、500 が 48 回 |
| 別の Namespace の宛先。ReferenceGrant なし | `ResolvedRefs=True` | **別の Namespace へ 44/100 届いた** |
| 規則が 3 つ（ヘッダ、リダイレクト、既定） | すべて True | ヘッダ付きは 40/40 が v2。既定は 94:6。`/old` は 302 |
| Gateway が親（90:10） | すべて True | 91:9 |
| Gateway が親。ホスト名がリスナーと合わない | `Accepted=False`、`NoMatchingListenerHostname` | — |
| 別の Namespace から Gateway を親にする | `Accepted=False`、`NotAllowedByListeners` | — |
| 存在しない Gateway が親 | `status.parents` が空 | — |
| 存在しない Service が親 | `Accepted=False`、`NoMatchingParent` | — |
| ambient に入れていない Namespace で Service が親 | waypoint なしと同じ文言 | — |

分かったこと:

- **Service が親でも `status` は書かれる。** `Accepted` と `ResolvedRefs` は True / False で読める。
- **Istio 独自の `ResolvedWaypoints` は常に True で、文言だけが変わる。** True / False では読めない。
- **waypoint の誤り（`none`、存在しない名前）は `status` に出ない。** `status` だけでは、経路が効いているかは決まらない。
- **ReferenceGrant は自前で評価しない。** していたら、実際に届いている経路を「届かない」と描いていた。

ほかに確かめたこと:

- VirtualService の `status` は書かれない（null）。
- CRD の一覧は items に `kind` が付く。0 件のときは `"items":[]`。
- 取得は 12 件で 27KB、0.08〜0.11 秒（ローカルのクラスタ。kubectl の起動込み）。
- ambient に入っている Pod には、annotation `ambient.istio.io/redirection: enabled` が付く。

**未確認:** 遅い経路（Connect Gateway 越しの GKE）での取得の費用。Istio 以外の実装と sidecar モードでの `status`。

仕様は、クラスタに入っている CRD の説明（`kubectl explain`）で確かめた。`weight` は割合ではなく比で、省略時は 1。親は Gateway か Service。無効な宛先に流れるはずだったリクエストは 500 を返す。

## 設計

### 図

**割合の全体は、経路を起点にした図で見せる。ほかの起点の図は、器と札でそこを指すだけにする。**

#### 経路を起点にしたとき: 振り分けの図（`TraceRouteSplit` / `TraceRouteSplitView`）

- 左の箱が呼び出し先（経路の親。Service か Gateway）、線が割合、右が宛先の Service。規則が複数あるか、match の条件があれば、規則ごとに段を分けて見出しを付ける。
- **割合の数字は線にだけ書く。** 箱の中の帯は、同じ割合を「全体を配り切っている」形で見せるもので、数字は書かない（同じ数字を 2 か所に出さない）。帯の区切りと宛先は、宛先の横の色見本で対応させる。濃淡は宛先ごとに決め、規則をまたいでも変えない。
- **こうした理由。** 最初は枝ごとの札（`web の親`、`web · 90%`）だけで出していて、「残りの 10% は親に行くのか」と読まれた（実機での指摘）。割合は 1 つの呼び出し先から複数の宛先へ分かれる形なので、枝をまたいで読ませない。親を左の箱に置けば、割合を受け取る側ではないことが位置で決まる。
- 届かない宛先は、同じ場所に破線と ✕ で出す（「通信」の図の、止まる通信と同じ描き方）。器は置かない。文言は下の「宛先が手元に無いとき」のとおりで、図の上の断りには重ねない。
- 下の枝（見出しは「宛先の先」）は、宛先の Service から先だけにする（`PlacementTrace.focused`）。入口の器も札も出さない（割合と呼び出し先は上の図が持つ）。同じ Pod を掴むだけの Service も出さない。出していたときは、選んだ経路と関係の無い Service や札が同じ枝に並び、どれがその経路の話なのか読めなかった（実画面）。そういう Service は、ワークロードを起点にすれば見える。
- Gateway は引いていないので、呼び出し先が Gateway のときは名前だけを出す（押せない）。

#### ほかの起点のとき: 器と札

| 経路の親 | 置き場所 | 書き方 |
|---|---|---|
| Gateway（外からの入口） | 入口の列。Ingress と同じ列、同じ器 | 2 行目に割合（`HTTPRoute · 10%`） |
| Service だけ（メッシュの中の振り分け） | 列に置かない。Service の器の下に札 | 宛先の Service に `経路名 から 10%`、振り分け元（親）の Service に `経路名 が振り分け`。兼ねる Service には 2 枚 |

- **親が Service の経路を入口の列に置かない。** 置くと `経路 → 親の Service` と描くことになるが、実際の順は「親宛ての呼び出し → 経路 → 宛先」。メッシュの代表的な分け方（親の Service が全部の版を掴み、版ごとの Service が宛先）では、どの枝にも親と宛先が並ぶ（検証用の構成がこの形）。最初は列に置いていて、実画面で親が宛先と同格に並んだ。
- **札に「親」と書かない。** Gateway API の parentRefs の訳だが、残りの割合が親に残るように読まれた。1 枚にまとめた `web の親 · 90%` も同じ理由でやめ、2 枚に分けた。説明（ツールチップ）の「親: Service web」は残してある。
- **振り分け元の Service から Pod への線は残す。** waypoint が無いときやメッシュの外からは、その Service がそのまま Pod へ届ける（実測）。振り分けられていることは札で言う。
- この枝へ流さない経路でも、振り分け元の Service には札を付ける。そういう経路のことは図の上には書かない（札のしるしと説明に出る）。
- 札を押すと、その経路が起点になり、振り分けの図が出る。Service の器のボタンには入れ子にしない。
- **札は器の左端にそろえる（名前の位置まで字下げしない）。** 字下げしていたときは、入口の列がある枝で欄が下限まで詰まり、経路の名前が丸ごと消えた（`… · 10〜100%`。実画面）。
- **縮めるのは経路の名前だけ。** 割合や「が振り分け」は切らせない。真ん中を落とすと `10〜100%` が「0〜100%」と読めた（実画面）。札の文は 1 つの鍵で訳し、名前の前後に分けて描く（語順は訳に任せる）。
- 枝の矢印は列と列をつなぐ 1 本で、器どうしを結んでいない。割合は矢印に載せない。
- 規則が複数あって割合が違うときは、範囲で書く（`10〜100%`）。規則ごとの値・match の条件・親・宛先・問題の文言は、ツールチップに出す。振り分け元の札のツールチップには、振り分け先をぜんぶ書く（`規則 1: web-v1 90%, web-v2 10%`）。

#### どちらにも共通

- `0%` はそのまま書き、色は付けない。`0` と `100` は本当にそうのときだけ書く（それ以外は `<0.1` と `>99.9`）。
- **割合を出した図には断りを 1 行出す。**「割合は宣言です。実際の流量ではありません。match の条件と、経路どうしの優先順は評価していません。」置き場所は図の上（ほかの断りと同じ場所）。
- 図の上には、起点の経路か、その図に割合を出している経路について、コントローラが言っていることを書く。経路が起点のときは、その経路のことだけを書く。

分かっている制約:

- **入口の列を持つ枝（Ingress か、Gateway が親の経路）は、既定の窓幅で詳細パネルを開いていると右にはみ出す**（ノード名が切れる）。図に使える幅は 829pt で、44〜84pt 足りない。この機能の前からある 5 段の図の限界で、詳細パネルを畳むか窓を広げれば収まる。親が Service の経路は列を増やさないので、収まる。経路を起点にした図は、枝に入口の列が無いので、この限界に掛からない。
- 起点の一覧を詰める基準（`TraceMapView.figureWidth` の 600pt）は、図の下限の合計（概算で、入口なしが 714pt、入口ありが 860〜892pt）より小さい。固定で引き上げれば最大 68pt 出る（計算値。未実施）。オプションを切った画面も変わるので、この機能とは別に決める。
- 親に Gateway と Service の両方を持つ経路は、ほかの起点の図では入口の列に出す。その親の Service との左右は逆のまま残る（経路を起点にした図では、どちらの親も左の箱に並ぶ）。
- 帯の濃淡は 6 段を使い回す。宛先が 7 つ以上ある規則では同じ濃淡が出るので、数字と並び順で読むことになる。

### 置き場所

| ファイル | 中身 |
|---|---|
| `Models/TrafficRoute.swift` | HTTPRoute 1 件を読む純粋関数。表示の文言は持たない |
| `Models/TraceRoutes.swift` | 図への載せ方（振り分けの図、入口に出す経路、Service に付ける札、経路の起点、断りの文言） |
| `Services/MeshRouteLoader.swift` | 取得と、読めたかどうかの状態 |
| `Views/TraceRouteViews.swift` | 振り分けの図、経路の器、Service に付ける札、起点の種別の出し分け |
| `PlacementTrace.swift`・`ClusterStore.swift`・`TraceMapView.swift`・`Preferences.swift`・`SettingsView.swift` | 上を呼ぶ差し込みだけ |

表示の文言は String Catalog に入れてある（英訳済み）。判断の要点は CLAUDE.md の「経路（HTTPRoute）は宣言を載せる」にも置いた。

### 読み方（`Models/TrafficRoute.swift`）

HTTPRoute 1 件を「親・規則・宛先・重み・状態」に読む純粋関数。

- `shares(toService:namespace:)`: その Service に流す割合を、規則ごとに返す。
- `Parent.findings`: 親ごとに、画面に出すべきことを返す。reason と message はコントローラの文字のまま運ぶ。
- `destinations(among:scope:servicesReadable:)`: 宛先を手元の Service に解く。
- `deadShares(_:)`: 500 になる割合を返す。

### 受け付けられたか

| `status.parents` の中身 | 出し方 |
|---|---|
| `Accepted` も `ResolvedRefs` も True | 何も添えない |
| どちらかが False | しるしを付け、reason と message をそのまま出す |
| どちらかが Unknown | 「まだ決まっていない」。False とは分ける |
| 実装独自の条件（Istio の `ResolvedWaypoints` など） | True / False を当てにしない。文言が「問題なし」の決まり文句でなければ、そのまま出す |
| 親に対応する記録が無い | 「受け付けた記録がありません」。壊れているとは言わない |

- 「問題なし」の決まり文句は `TrafficRoute.allClearMessages` に持つ（いまは `All waypoints resolved` の 1 つ）。Istio が文言を変えたら、害の無い補足が 1 行増える。黙って警告が消える側には倒れない。
- 受け付けられていない親への補足は重ねない（`parent not found` は言い直しになる）。
- 記録の突き合わせは、同じ相手を指す親が 1 つなら port や sectionName の書き方を問わない。複数あるときだけ厳密に見る。
- **waypoint の `none` と、存在しない名前は拾えない。** 図の断りで補う。拾うには Gateway を引く必要があり、段階を分ける。

### 宛先が手元に無いとき

振り分けの図の、その宛先の行に書く。器は置かない。

| 手元の Service | `ResolvedRefs` | 行の出し方 |
|---|---|---|
| 取得範囲の中に無い | False | 破線と ✕。「Service がありません。この 50% は 500 を返します」 |
| 取得範囲の中に無い | True か記録なし | 破線と ✕。「取得した一覧にありません」。500 とは言わない（コントローラは解決できたと言っている） |
| 取得範囲の外（Namespace を絞っている） | 問わない | ふつうの線。「いまの取得範囲の外です」。無いとは言わない |
| Service を読めていない | 問わない | 同上 |
| 宛先が Service ではない | 問わない | ふつうの線。「Service ではないので、辿っていません」 |

宛先を持たない規則（リダイレクトなど）は、その規則の段に「宛先なし」と書く。

### 起点

- `TraceAnchorKind.route` を足す。`pods(for:)` に「経路から Service、Service から Pod」の分岐を 1 つ足す。
- 経路を起点にしたときだけ、図の先頭に振り分けの図を出し、枝は宛先の Service から先に絞る（上の「図」）。Ingress や Service を起点にしたときは、これまでどおり絞らない。
- 経路の実物は専用の配列（`PlacementInventory.routes`）から Namespace と名前で引く。

### 取得

- 設定（`Preferences.showsMeshRoutes`）が切なら、何も引かない。
- 配置の取得と並行して `list(resource: "httproutes.gateway.networking.k8s.io", …)` を走らせ、同じ世代番号の検査を通してから書く。`list(kinds:)` には入れない（組み込みの `ResourceKind` しか受けない）。
- **種別があるかどうかは、取りに行って決める。CRD の一覧（`customTypes`）では決めない。** あの一覧は読めなかったときも空を返す（`Kubectl.swift` の `customResourceTypes`）。コンテキストを切り替えた直後も空のまま配置を読む。
- 「知らない種別」と返ったら 10 分覚え、そのあいだはたずねない。人が更新を押したら聞き直す。
- 捨てる場所をそろえる（`discardLoadedResources()` とコンテキストの切り替え）。
- Gateway 本体は引かない。親の名前は `parentRefs` に、受け付けの結果は `status` にある。
- 退避先: 遅い経路で配置の取得が目に見えて遅くなったら、起点を開いたときだけ引く形に移す。

### 「無い」と「取れていない」

| 状態 | 出し方 |
|---|---|
| クラスタがその種別を知らない | 何も出さない。起点の選択肢にも出さない |
| 0 件 | 器も札も足さない。起点の一覧は「HTTPRoute がありません。」 |
| 拒否・失敗 | 「HTTPRoute を読めないので、経路は描いていません」 |
| Namespace を絞っている | 「ほかの Namespace に置かれた経路は、いまの取得範囲の外です」 |

## やらないこと

- match（パス・ヘッダなど）の評価。文字で出すだけ。
- リスナーとの照合と ReferenceGrant の評価。`status` に答えがある。
- waypoint が実在するかの確認と、Gateway 本体の表示。
- フィルタ（ミラーなど）の図示。種類を文字で添えるだけ。
- GRPCRoute・TCPRoute・TLSRoute。`parentRefs`・`backendRefs[].weight`・`status.parents` が同じ形なので、あとから同じ読み方で足せる。
- 認可（AuthorizationPolicy）と実際の流量。別の段。

## 確かめ方

マニフェストは `Scripts/mesh-fixtures/` に 2 組置いてある。どちらも Istio の ambient が入ったクラスタに当てる。**確かめたら消す。**

**画面の見え方を確かめるとき**は、現実的な最小の構成（`demo-shop.yaml`、Namespace は `kubedeck-shop`）を使う。外からの入口（Gateway `shop` → `frontend`）と、メッシュの中の振り分け（`reviews` 宛てを v1 に 90、v2 に 10）が 1 つずつ入っている。実測（`cluster-dev`、2026-11-25）で、`reviews` 宛て 200 回のうち v1 が 189、v2 が 11 だった。

```bash
kubectl --context <コンテキスト> apply -f Scripts/mesh-fixtures/demo-shop.yaml
```

**壊れ方や書き方を網羅するとき**は、実測に使った `01-base.yaml` 以降を順に当てる。経路ごとに別の親が要るので、同じ Pod を 8 つの Service が掴む不自然な形をしている。画面の理解には向かない（実機で「なぜ複数の Service が 1 つの Deployment に繋がるのか」と訊かれた）。

```bash
kubectl --context <コンテキスト> apply -f Scripts/mesh-fixtures/01-base.yaml
kubectl --context <コンテキスト> apply -f Scripts/mesh-fixtures/02-route-web.yaml
kubectl --context <コンテキスト> apply -f Scripts/mesh-fixtures/03-waypoint.yaml
kubectl --context <コンテキスト> label namespace kubedeck-mesh istio.io/use-waypoint=waypoint
kubectl --context <コンテキスト> apply -f Scripts/mesh-fixtures/04-variants.yaml

kubectl --context <コンテキスト> delete namespace -l kubedeck.dev/purpose=route-verification
```

- 入口の Gateway は Deployment と Service を作る。LoadBalancer の実装が無いクラスタ向けに ClusterIP にしてある。
- `Tests/KubeDeckTests/TrafficRouteTests.swift` の状態の JSON は、この手順で取った実物から作った。
- 段階 2 以降は、画面を `Scripts/screenshot.sh` で撮って確かめる。

## 後段: VirtualService / DestinationRule

sidecar モードのクラスタ向け。`status` は書かれない（実測）ので、自前の判定が要る。そのとき守る規則は次のとおり（Istio の公式ドキュメントの要約。原文とは未照合）。

- 短い名前は VirtualService の Namespace で解く（Service の Namespace ではない）。
- `gateways` を省くと、メッシュ内の全通信に効く。名前を並べて `mesh` が無ければ、ゲートウェイにしか効かない。
- 同じ host の VirtualService が複数あるとき、sidecar での優先順は未定義。どれが効くかを決めない。
- `exportTo` の既定は全 Namespace だが、メッシュの設定で変えられる。設定を読めなければ決めない。
- DestinationRule の subset は、Service が掴んだ Pod をラベルでさらに絞る。
- ambient では VirtualService は Alpha で、Gateway API と混ぜた場合の挙動は未定義。

## 参考

- Gateway API v1.6.1 の CRD の説明（`kubectl explain httproutes.spec.parentRefs` / `.spec.rules.backendRefs` / `.status.parents`、`cluster-dev`）
- Istio: [ambient の L7 機能](https://istio.io/latest/docs/ambient/usage/l7-features/)、[waypoint](https://istio.io/latest/docs/ambient/usage/waypoint/)、[VirtualService](https://istio.io/latest/docs/reference/config/networking/virtual-service/)、[Traffic Management Best Practices](https://istio.io/latest/docs/ops/best-practices/traffic-management/)
