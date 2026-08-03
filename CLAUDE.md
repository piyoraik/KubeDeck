# CLAUDE.md

KubeDeck は Kubernetes Dashboard 相当の画面を macOS ネイティブで持つアプリ。SwiftUI、Swift 6 strict concurrency、macOS 14 以降、Apple Silicon。

## ビルド

```bash
# 新しい .swift ファイルを追加したときだけ必要
xcodegen generate

xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
  -configuration Debug -destination 'platform=macOS' build
```

既存ファイルの編集だけなら `xcodegen generate` は不要。`project.yml` がソースオブトゥルースで、`.xcodeproj` は生成物。**`.xcodeproj` を直接編集しない。**

**`xcodebuild` の出力を `head` に通さない。** パイプを早く閉じると `xcodebuild` が居残り、DerivedData の `XCBuildData/build.db` を握り続ける。次のビルドが `database is locked` で落ちるが、原因は自分の残骸であって同時ビルドではない。絞りたいときはログをファイルに落としてから `grep` する。

起動確認:

```bash
pkill -f "KubeDeck.app/Contents/MacOS/KubeDeck"
open "$(xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/KubeDeck.app"
```

## クラスタへの接続は kubectl 経由

API サーバを直接叩かず、`kubectl ... -o json` の標準出力を読む（`Services/Kubectl.swift`）。**この方針を変えない。** kubeconfig の exec 認証プラグイン（EKS の `aws`、GKE の `gke-gcloud-auth-plugin`）、クライアント証明書、OIDC のトークン更新、プロキシ設定を、すべて kubectl に肩代わりさせるため。自前で URLSession を張ると、この認証まわりを全部実装することになる。

**`PATH` を子プロセスに明示して渡す。** Finder から起動した GUI アプリの `PATH` は `/usr/bin:/bin:/usr/sbin:/sbin` しかなく、Homebrew の kubectl も、kubeconfig が呼ぶ認証プラグインも見つからない。`Kubectl.searchPath(loginShellPath:)` がログインシェルの `PATH` と、Homebrew / krew / gcloud SDK の決め打ちの場所を足している。ここを削るとターミナルからは動くのに `.app` からは動かない、という切り分けの難しい壊れ方をする。

### exec 認証プラグインの場所は決め打ちで当てられない

kubectl 本体は決まった場所を順に見れば見つかるが、kubeconfig の exec 認証プラグイン（GKE の `gke-gcloud-auth-plugin`、EKS の `aws`）はそうはいかない。gcloud SDK は tarball を好きな場所へ展開して `path.zsh.inc` をシェルの設定から読ませる手順が公式にあり、置き場所がユーザごとに違う。**候補の一覧を足していくやり方では追いつかない。** `LoginShell.environment()` がログインシェルを起こして `PATH` を写す。

- **`-l` だけでは足りない。** `path.zsh.inc` を読む行が書かれるのは `.zshrc` で、非対話のログインシェルには現れない。実測でも `-lc` では `.zshrc` で足した場所が丸ごと落ちた。対話ログインシェルで起こすこと。
- **フラグをまとめて渡さない。** `-ilc` は zsh / bash では通るが fish では通らない。`-i` `-l` `-c` と分ける。
- **目印から後ろだけ読む。** 対話シェルは起動時に何か書き出す（p10k の instant prompt など）。`env -0` を NUL 区切りで読むのは、値に改行が入っていても壊れないようにするため。
- **待ち上限を付ける。** 相手はユーザの設定ファイルを読むシェルで、対話入力を求めて止まることがある。
- **繰り返し起こさない。** rc を全部読むので 0.5〜1 秒かかる。`Kubectl` が 1 度だけ取って持ち回る（kubectl の場所を変えられたぐらいでは取り直さない）。
- **ログインシェルの `PATH` を先頭に置く。** 同じ名前の実行ファイルが複数あるとき、ターミナルで選ばれるものと同じ実体を選ぶため。

**環境変数も選んで渡さない。** 一度は「認証プラグインが見るもの」を並べた一覧を持ったが、追いつかなかった。プラグインの先で動く gcloud / aws が何を見るかは環境で違う。TLS を覗く社内プロキシの下では独自の CA を指す変数（`REQUESTS_CA_BUNDLE` など）が要り、落とすと**認証ではなく TLS の検証で落ちる**（`CERTIFICATE_VERIFY_FAILED`）。python を mise や pyenv でしか入れていなければ `CLOUDSDK_PYTHON` が要る。**PATH とまったく同じ話なので、同じ答えにする** — ログインシェルの環境をそのまま土台にし、`PATH` / `HOME` / `TERM` だけ上書きする。

シェルの覚え書き（`PWD` / `OLDPWD` / `SHLVL` / `_`）だけは落とす。子プロセスの実際の cwd と食い違うため。

確認は、Finder 相当の最小環境でアプリを起こして子プロセスの環境を見る。`env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME=... SHELL=/bin/zsh KubeDeck.app/Contents/MacOS/KubeDeck` で起動し、`ps -Ewwp <kubectl の pid>` の `PATH` に**シェルの設定でしか足されない場所**（このマシンなら `~/.bun/bin`）が入っていること。

### 認証の失敗は言い換える

`Kubectl.explain(_:)` が、原因と対処の決まっている失敗に日本語の説明を頭に足す。いまは 4 つ。

- 証明書を検証できない（`CERTIFICATE_VERIFY_FAILED`）— **認証の失敗と混ぜない。** 資格情報は正しく検証で落ちているだけなので、`gcloud auth login` をいくら実行しても直らない。
- exec プラグインが見つからない（`executable ... not found`）— 入れ方と、PATH を確かめる場所を出す。
- プラグインは動いたがその先の gcloud が失敗（`failure while executing gcloud`）— 期限切れなら再ログイン。**対話的な再認証は代行できない**（プラグインは標準入力を持たない状態で動く）。
- 古い `auth-provider: gcp` 形式（kubectl 1.26 で in-tree の GCP 認証が消えた）— `get-credentials` で作り直すよう出す。
- API サーバに届かない（`Unable to connect` / `context deadline exceeded` ほか）— **認証の失敗と混ぜない。** 認証が通っているからこそ、ここまで来て接続で落ちている。宛先のホストを文言から拾って出す（private なら VPN や社内ネットワークが要る、と分かる）。上のどれにも当たらなかったときだけ見るので、いちばん最後に置く。

**元の文言を捨てない。** 言い換えだけにすると、当てはまらなかったときに何が起きたのか確かめる手段が無くなる。kubectl は同じ失敗を API グループの一覧を引くたびに書き出すので、重複行だけ落とす。

帯は言い換えだけを出し、元の文言は「元の文言」に畳む（`RootView.splitError`）。**切り捨てない。** 以前は 4 行で切っており、原因が末尾にある失敗（exec プラグインの先で起きた TLS のエラーなど）をアプリの中では追えなかった。**同じ文言を 2 度出さない**ので、畳むのは見出しに入らなかった分だけ。貼って共有できるよう「コピー」も置く（無いと結局ターミナルで再現する羽目になる）。

設定の「接続」に、**子プロセスへ渡している環境**を出す。「ターミナルでは通るのに `.app` では通らない」を追うとき、いちばん知りたいのが「何が届いているか」だった。**値をそのまま並べない** — 環境をまるごと渡すので鍵やトークンが混ざりうる。ただしファイルの場所まで伏せると診断にならない（CA の指し先が合っているかを見る場所なので）ため、伏せるのは「秘密を思わせる名前」かつ「場所に見えない値」だけ。

**Form の中に `ScrollView` を置かない。** 高さが潰れて 1 行も見えないことがある。Form 自体がスクロールするので素直に並べる。

実クラスタなしで確かめられる。合成した kubeconfig を `KUBECONFIG` に足せば（`kubectl config get-contexts` に出る）、到達できない GKE のコンテキストとして両方の経路を通せる。

**取得系には必ず `--request-timeout` を付ける。** 到達できないコンテキストを選んだとき、付いていないと kubectl が待ち続け、UI が読み込み中のまま固まる。

**それだけでは足りない。プロセスごと上限を掛ける。** `--request-timeout` が縛るのは API への要求だけで、**kubeconfig の exec 認証プラグインが返ってこない場合には効かない**（gcloud が再認証の入力を待つ、プロキシの向こうで詰まる）。実際にこれで全画面が読み込み中のまま止まった。`Kubectl.run` が `ProcessRunner.run(timeout:)` に `待ち上限 + 10 秒` を渡し、先に kubectl 自身を諦めさせる。

打ち切ったかどうかは `CommandResult.timedOut` で分ける。**終了コードだけで判断しない** — 相手が自分で失敗したのか、こちらが殺したのかが区別できない。**「取れなかった」と「返ってこない」を混ぜない**（見るところが違う）。

**絞りすぎない。** ここは「終わらないもの」を切るためだけの網で、ふつうの失敗は kubectl 自身の待ち上限が捌く。届かないクラスタでは kubectl が API グループの一覧を数回引き直すので、待ち上限の 2 倍以上かかる。最初 `待ち上限 + 10 秒` にしたら、kubectl の「届きません」より先に殺してしまい、**経路の問題なのに「認証プラグインが返ってこない」と表示した**。いまは `待ち上限 × 2 + 15 秒`。

**打ち切ったことを理由にしない。** 打ち切るまでに kubectl が何か書き出していれば、そちらのほうが確かな手がかりなので、`timeoutMessage` は先に `authenticationHint` を通す。**言い換えを先に置く** — 帯は最初の段落しか見出しに出さないので、打ち切った断りを先に書くと肝心の理由が畳まれた側に入る（そうなった）。

打ち切りは `terminate()` → 2 秒待って駄目なら `SIGKILL`。確認は、返ってこない認証プラグイン（`sleep` するだけのスクリプト）を `command:` に指定した kubeconfig で起動し、`ps -eo ppid,args` で本数を数える。実行中のぶん（`async let` の 4 本×重なり）を超えて増えないこと、`ppid` が 1 のプラグインが残らないこと。

**概要画面は 1 回の kubectl でまとめて取る。** 種別ごとに投げると 13 プロセス起動することになる。カンマ区切りで複数種別を get すると `items` に `kind` が入るので、呼び出し側で振り分けられる（単一種別の get では `kind` が空になる版もあるため、`K8sObject.list(from:assuming:)` で要求種別を補う）。

## リソースの型付けは metadata だけ

`spec` / `status` は `JSONValue`（`Models/JSONValue.swift`）のままキーパスで引く。**全リソースに Codable の struct を起こさない。** 15 種あり、同じ種別でも API バージョンやアドオンの有無でフィールドが増減する。型を付けると、フィールドが 1 つ欠けただけで一覧が丸ごとデコードエラーで落ちる。いまの作りなら、引けないフィールドは nil になって該当セルが空になるだけで済む。

## 一覧の STATUS 列と、ドーナツの集計は別物

- `StatusResolver.status(for:)` — 一覧の STATUS 列。**kubectl の printer の再現**。Pod は phase をそのまま出さず `containerStatuses` まで見る（phase は CrashLoopBackOff でも `Running` のため）。ここを「分かりやすく」書き換えない。kubectl と表示がずれると、どちらが正しいのか確かめる手段が無くなる。
- `StatusResolver.health(for:)` — 概要のドーナツと一覧の並べ替え。`status` を土台に、**Running だが Ready が揃っていない Pod を正常側に混ぜない**。kubectl の STATUS 列だけ見ていると気付けない状態がここで表に出る。`Completed`（Ready 0/1 が正常）を巻き込まないよう、降格は `Running` に限っている。

検証は実クラスタと突き合わせる。`kubectl get pods -A --no-headers` の STATUS / READY / RESTARTS と、`Models` の 4 ファイルだけを `swiftc` で固めた小さなバイナリの出力を比べればよい。異常系（CrashLoopBackOff、`Init:`、Terminating、OOMKilled、ExitCode）はクラスタを汚さずに合成 JSON で確かめる。

## 舵輪は 2 つある。持ち場を混ぜない

| | 図形 | どこ |
|---|---|---|
| 画面内 | Kubernetes 公式ロゴ | `Views/KubernetesLogo.swift` |
| App アイコン | 独自に引いた舵輪 | `Scripts/KubeDeckLogo.swift` |

**この 2 つを揃えようとしない。** 指しているものが違う。画面内のマークは「これは
Kubernetes を見ている」というしるしなので公式ロゴが正しく（対象の明示に使うぶんには
CNCF の商標も問題にならない）、App アイコンは「この製品」を指すので、公式ロゴを流用すると
商標に触れるうえ他の k8s ツールと Dock で見分けが付かない。

### 画面内（公式ロゴ）

`Views/KubernetesLogo.swift` は公式 SVG を、絶対座標の `M` / `L` / `C` / `Z` だけに畳んで
単位正方形へ正規化したもの。**円弧（`A`）と相対座標は取り込み時に潰してある。**
実行時に円弧をベジエへ直す処理を持ち込むと、ロゴ 1 つのために SVG の仕様を実装することになる。

**解析結果はキャッシュする。** `unitBody` / `unitWheel` を `static let` で持つ。持たないと、
回転のたびに 6,000 文字超の字句解析が走る。

### App アイコン（独自マーク）

`Scripts/KubeDeckLogo.swift` の `unitPrimitives`——単位正方形に置いた「線の集まり」
（輪 1 本・スポーク 7 本・握り 7 本・中央のハブ）——が唯一の定義で、丸端で太らせて塗る。
**アプリのターゲットには入れない。** 配布物を焼くためだけのコードなので `Scripts` に置く。

PNG も SVG もこの 1 つの配列から作る（`Scripts/generate-icon.sh` /
`Scripts/generate-svg.sh` が一緒にコンパイルする。出力は `Design/*.svg`）。
**幾何をスクリプト側へ写さない。** 写した時点で PNG と SVG と README がずれ始める。

**単位正方形のまま `copy(strokingWithWidth:)` を呼ばない。** 曲線の平坦化の許容誤差は
座標の絶対値で効くので、1 辺 1.0 では丸端も円弧も直線に潰れる（輪が弦になり端が角になった）。
1024 倍の座標で太らせてから縮める。

**塗りは nonzero。巻き方向を揃える。** ハブの円をスポークと逆向きに閉じると、重なった
ところが穴になってハブが花びらに割れる。CoreGraphics が線を太らせたときの外周と同じ向き
（時計回り）で閉じること。

**輪を弧に割らない。輪よりスポークを細くする。** どちらも破ると舵輪ではなく雪の結晶に見える。
比率は実際に 16 / 32 / 512px で描いて決めてある（`wheelScale` を 0.52 にすると 16px で団子になる）。

## 回転は Core Animation にやらせる

**SwiftUI の `rotationEffect` で回さない。** 舵輪は 180 を超えるセグメントの塗りで、`TimelineView` から角度を与えると毎フレーム塗り直しになる。Release ビルドの実測で **待機中に CPU 25%**。`drawingGroup()` を挟んでも、TimelineView が中身を作り直す以上ラスタライズは繰り返されるので **38% に悪化した**。

いまはロゴを 1 枚のビットマップとして `CALayer` に載せ、`CABasicAnimation` で回している（`Views/RotatingKubernetesMark.swift`）。回すのはレンダーサーバなので、アプリ側の CPU は **0.0%**。この構造を SwiftUI に戻さない。

**回転の向きは実測で決めてある。** レイヤの `transform.rotation.z` は角度が正で左回りなので、右回りにするには負を与える（`isGeometryFlipped` は contents の向きを直すだけで回転の向きは変えない）。確かめ方は、連続でスクリーンショットを撮り、青い画素のうち中心からいちばん遠い点（＝七角形の頂点）の角度差を見る。**間隔を空けて撮らない。** ロゴは 7 回対称で 51.43° 周期なので、1 コマの回転が 25° を超えると折り返して向きを誤判定する。

**回転と色だけに意味を持たせない。** ロゴは公式の配色のまま扱い、状態で塗り替えない。異常時だけ隅に状態のしるしを重ね、同じ内容を概要の見出しとツールバーのツールチップに文字で出している。

## CRD も同じ経路で扱う

一覧の対象は `ResourceTarget`（組み込みの `ResourceKind` か、CRD 由来の `CustomResourceType`）。取得・YAML・削除は種別名の文字列だけで動くので、両者で経路を分けていない。

**操作に使う種別名はオブジェクトから引かない。** `K8sObject.kind` は組み込みの enum で、CRD には対応する値が無い。いま開いている一覧（`currentResourceName`）から取る。

**kubectl に渡す名前には API グループを付ける**（`applications.argoproj.io`）。別グループが同じ複数形を持つことがあり、短い名前だと別の種別を引く。

### 列は CRD 自身の宣言を使う

`api-resources` ではなく CRD そのものを読むのは、`additionalPrinterColumns` が要るため。これがあるので `kubectl get` と同じ列を出せる。**priority が 1 以上の列は出さない** — kubectl が `-o wide` のときだけ出す扱いの列で、既定で並べると横に長くなりすぎる。

JSONPath は `.a.b` と `.a[0].b` までしか解釈しない。`[?(@.type=="Ready")]` のような絞り込みは式の評価が要り、表示列 1 つのために持ち込む重さではない。解釈できないパスはセルが空欄になる。

**任意の文字列を状態として色分けしない。** 列名が status / health / phase / state / ready / sync を含むときだけ色を付ける。全部に付けると、ただの名前が「異常」に見える。

## 設定タブは API のフィールド名を並べない

**木でそのまま出さない。** 一度 `spec` を木にして出したが、
`preferredDuringSchedulingIgnoredDuringExecution` のような語がそのまま並び、
結局 YAML を読んでいるのと変わらなかった。

`Models/SettingsDigest.swift` が種別ごとに見るべき項目を選び、日本語の見出しと
整形した値にする。`restartPolicy: Always` は「再起動の方針 / 常に再起動」、
深い `affinity` は「配置の希望 / 分散（希望）」まで畳む。原文が要るときは YAML タブ。

**未設定を空欄にしない。** 「未設定」と書いて薄く出す。空欄だと、値が空なのか
項目が無いのか区別が付かず、全部が設定済みに見える。

**Secret の中身は出さない。** キー名と大きさ（文字数）まで。

種別を足すときは `groups(for:)` に分岐を 1 つ足す。スキーマの分からない CRD だけは
選びようがないので `SpecOutline`（木）に落ちる。

## 右のパネルは YAML を主役にしない

幅が 300〜360pt しかないので、YAML を出すと 1 行が収まらず横スクロールが要る。
折り返せばインデントが崩れて構造が読めない。「どの項目に何が設定されているか」を
見たいだけなら木のほうが速いので、**設定タブ（`SpecOutline`）を既定の見せ方**にし、
YAML は原文が要るときのものとして残す。種別を問わず同じ経路なので CRD にも効く。

**畳んだまま出さない。** 開いていないと「設定が無い」のか「畳まれている」のかが
区別できず、パネルが白いままになる（実際そうなっていた）。上 3 段は必ず開き、
それより深いところは中身が小さいときだけ開く。全部開くと今度は文字の壁になる。

**狭い幅で 1 行に押し込まない。** `app.kubernetes.io/name` のような長いキーは
1 文字ずつ折れて読めなくなる。`ViewThatFits` で、収まるなら 1 行・収まらなければ
2 行に落とす。字下げも 5 段で頭打ちにする（際限なく下げると値の幅が無くなる）。

## 設定は `Models/Preferences.swift` に集める

保存する値はすべてここ。以前は `ClusterStore` の中の private enum に散らしており、
項目を足すたびにストアを触ることになっていた。**新しい設定をストアや画面に
直接置かない。**

項目を足すときは 3 つ揃えるだけ。

1. `Key` に保存キー
2. 既定値付きの格納プロパティ（`didSet` で書き戻す）
3. `SettingsView` に行

`resetAll()` にも足すこと。足し忘れると「すべて既定値に戻す」がその項目だけ残す。

`@Observable` なので画面は `Preferences.shared` を読むだけでよい。

**MainActor の外から読む値は写しを置く。** 一覧のセルを作る閉包は nonisolated なので、
使用率のしきい値は `Preferences.usageThresholds`（`nonisolated(unsafe)`）へ変更のたびに
publish している。同じ必要が出たら同じやり方にする。

**アクターへは投げ込む。** `Kubectl` は待ち時間と実行ファイルの場所を持つが、
アクターなので直接読ませられない。`applyToKubectl()` が `configure(...)` で渡す。
場所が変わったら、覚えている解決結果を捨てること（捨てないと古い場所を使い続ける）。

## メトリクスは 2 系統ある

- **metrics-server**（`Kubectl.metrics`）— いまの値。`kubectl get nodes.metrics.k8s.io` / `pods.metrics.k8s.io` を `-o json` で引く。`kubectl top` と同じ出どころ。
- **Prometheus**（`Services/PrometheusClient.swift`）— 履歴。スパークラインの元。

**どちらも「入っていなければ列ごと出さない」。** 空の列や 0 を並べると、値が 0 なのか取得できていないのか区別が付かない。一覧の CPU 列で値が引けないセルは `0` ではなく `—` を出す。

**APIService の登録ではなく、実際に引いて存在を判定する。** 登録が残ったまま実体が落ちていることがある。

**メトリクスを `--raw` で引かない。** `kubectl get --raw` は discovery を通らない素の HTTP GET で、**Connect Gateway 越しの GKE では `/apis/metrics.k8s.io/v1beta1/pods` が 404 になる**（実測。`kubectl top` は同じクラスタで通る）。`kubectl get <resource>` は discovery を通るので `top` と同じ経路になり、`top` で見えるものは必ず引ける。返る JSON は `--raw` と同じ `List`（`items[].usage` / `items[].containers[].usage`）なので、読む側は変えなくてよい。

`raw()` 自体は残してある。Prometheus は Service のプロキシ（`/api/v1/namespaces/.../proxy/...`）を叩くもので、こちらは種別として引けない。

**ノードだけで判定しない。** 管理されたクラスタ（GKE の Warden など）は、ノードの指標や全 Namespace の一覧を拒みつつ Pod の指標は通すことがある。`metricsServerAvailable` は `nodes.metrics.k8s.io` → 全 Namespace の `pods.metrics.k8s.io` → 選択中の Namespace の順に試し、**1 つでも引けたら「入っている」**とする。

**取得元が無いことにしない。** 取得元はあるのにノードの使用量だけ引けないとき、使用量カードに「metrics-server も Prometheus も見つかりません」と書くと、入れれば直ると読めてしまう。`UsageMeter.unavailableReason` が「取得元は○○だが、ノードの使用量が引けない」と書き分ける。これも「無い」と「取れていない」を混ぜないという同じ話。

### 単位は必ず基本単位に直してから比べる

metrics API は CPU をナノコア（`81768992n`）、メモリを `Ki` で返す一方、requests は `100m` や `512Mi`。同じ「CPU」で桁が 9 つ違う。`Quantity.parse` がコア / バイトへ揃える。**`129e6`（指数）と `1E`（exa）を取り違えない** — 単位を剥がす前に数値部が `Double` として読めるか確かめている。

### 使用率の分母

- ノードは **allocatable**。capacity にはシステム予約が入っており、Pod が使える量ではない。
- Pod は **requests**。limits は未設定のことが多く、設定されていても「そこまで使ってよい」意味ではない。
- 分母が取れないときは棒を描かない。`0%` と描くと「まだ余裕がある」と読めてしまう。

### 取得元は設定で選べる（`MetricsSourcePreference`）

`自動` / `metrics-server` / `Prometheus` の 3 択。実際に使う先は設定とクラスタの状況の両方で決まり、`ClusterStore.activeMetricsSource` が答えを持つ。

- `自動` は現在値に **metrics-server を優先**する。呼び出しが 2 本で済み、`rate()` の窓に引きずられないぶん「いま」の値として素直。
- `Prometheus` を選ぶと現在値も PromQL の瞬時クエリから作る（`PrometheusClient.snapshot`）。**Pod ごとに問い合わせない。** `by (namespace, pod, container)` で 4 本にまとめる。Pod の数だけ kubectl が立ち上がるのを避けるため。
- 履歴は取得元の設定に関わらず Prometheus からしか出ない。metrics-server は履歴を持たないため。

**選んだ先が使えないときに黙って別の先へ流さない。** `metricsSourceProblem` が理由を返し、設定画面と使用量カードの両方がそれを出す。勝手に切り替えると、どちらの数字を見ているのか分からなくなる。

2 つの取得元は同時刻で比べると一致する（実測で 11 Pod 中 9 件が完全一致、残りは scrape 間隔ぶんの 6〜9% 差）。**ずれを見つけたら、まず両者を同時に取って比べる。** 別々のタイミングで撮った値を並べると、実装の誤りに見える差がいくらでも出る。

### Prometheus は API サーバのプロキシ経由で叩く

`/api/v1/namespaces/<ns>/services/<svc>:<port>/proxy/api/v1/query_range`。**port-forward を張らない。** 認証・TLS・プロキシ設定をすべて kubectl に任せられ、待ち受けポートの管理も要らない。

**探索は名前だけで決めない。** 候補に `/api/v1/query` を投げ、Prometheus 互換の応答が返ったものだけを採用する。見つけた場所は `UserDefaults` に覚えるが、起動時に必ず一度叩き直す。

**指標の出どころは環境で変わる。** kube-prometheus-stack は kubelet の cAdvisor（`/metrics/cadvisor`）を拾うが、orbstack の k3s ではそこに `machine_*` しか出ておらず、コンテナ単位の値は `/metrics/resource` にある。**幸い指標名は同じ**（`container_cpu_usage_seconds_total` / `container_memory_working_set_bytes`）なので、クエリは両対応で書ける。node 単位の集計は `node` ラベルに依存し、これは scrape 側の relabel 次第で在ったり無かったりする。

**履歴の取得間隔は一覧と分ける。** 範囲クエリは 1 回につき kubectl を 1 本起こす。自動更新（既定 10 秒）に合わせると 4 本増える。30 分幅のグラフにその頻度は要らないので 60 秒間隔。選択が変わったときだけ間隔を無視する。

**時系列の線に状態の 4 色を使わない。** 使うと、ただの CPU の線が「異常」の意味を帯びる。系列色は別枠（`Palette.seriesCPU` / `seriesMemory`）。

## 同じ数字を 2 度出さない

画面が散らかる最大の原因は重複だった。整理したときの持ち場は次のとおり。**ここを崩して同じ値を足さない。**

| 情報 | 持ち場 |
|---|---|
| 種別ごとの件数 | サイドバーの行末（概要にタイルを並べ直さない） |
| コンテキスト名・全体の状態 | 概要の見出し |
| Namespace | ツールバー |
| バージョン・更新間隔・最終更新 | 右パネル |
| 一覧の件数 | ウインドウの副題 |

### カードの作りを揃える

概要の 3 枚（状態 / リソース使用量 / 最近のイベント）は同じ形にしてある。

```
見出し（.headline）              添え書き（.caption・薄い）
────────────────────────────────────────────────
中身
```

**見出しをカードの外に置かない。** 外に置いた箱と中に題がある箱が混ざると落ち着かない。
**カードを分けない。** 見出しだけのカードは横がまるごと空き、リングごとに枠を立てると
中身より枠が目立つ。同じ話は 1 枚に収める。

イベント行とログ行は同じ作り（左端 2pt の帯 + ごく薄い下地）。目を引かせるのは帯だけで、
本文の色は変えない。

右のパネルは**本文に出ていないものだけ**を置く。行を選んでいれば選択の詳細、
一覧なら状態と Namespace の内訳、概要ならバージョンと更新の状況。

**空きを埋めるために数字を持ってこない。** 使用量の合計（概要のクラスタ合計とほぼ同じ）や
ノード別の使用量（Node 一覧が割合付きで出している）を置いてみたが、どちらも重複だった。
パネルが空いていることより、同じ数字が 2 か所にあることのほうが読みにくい。

同じ理由で、リングは 1 枚のカードにまとめ（枠が 3 つ並ぶと中身より枠が目立つ）、
瞬時値と推移も 1 枚にまとめてある（別カードだと CPU とメモリの見出しが画面に 2 度出る）。

**割合の棒と折れ線を同時に出さない。** どちらも「どれだけ使っているか」を描く図で、
並べても情報が増えない。推移が取れるなら折れ線、無ければ棒。

**ただし、見せ方が変わる理由は黙らない。** 同じアプリなのにクラスタによって
折れ線だったり棒だったりするので、断りが無いと作りが違うように見える（実際に
そう言われた）。添え書きを `metrics-server · 推移 30 分` / `metrics-server · 現在値のみ`
と書き分け、ツールチップで「推移は Prometheus からしか出せない」ことを言う。

**3 つのリングで形を変えない。** 以前は「内訳が 1 種類しかないときは凡例を出さない」
としていた（リング中央の数字と重複するため）。だが Pod とワークロードには内訳が
並び、ノードだけ何も出ない、という食い違いのほうが目についた。**1 行ぶんの重複より、
3 つが同じ作りに見えることを採る。**

**比だけを状態として並べない。** レプリカを持つワークロードの状態は `0/1` や `2/3`
という比で、一覧の列ではそれが正しい（kubectl と同じ）。だが右パネルの「気になる状態」に
置くと `Error` や `Pending` と並んで**状態の名前に見えない**。`ReasonCount.displayName` が、
比のときだけ重みの名前を前に付ける（`異常 0/1`）。

**しるしと文字を食い違わせない。** 概要の見出しはアイコンがクラスタの状態（色つき）で、
文字が活動（取得中 / 稼働中）だった。異常のあるクラスタでは赤いしるしの隣に「取得中」と
出て、取得が失敗しているように読めた。取得中でも状態の語を併記する（`取得中 · 異常`）。

## 「無い」と「取れていない」を混ぜない

このアプリで最も繰り返し踏んだ間違い。取得に失敗しているのに `0 件` や
`ありません` と出すと、**確かめていないことを断定する**表示になる。

- 一覧: 読み込み中 / 取得失敗 / 本当に 0 件 の 3 つを別の表示にする（`LoadingView` / `failureState` / `emptyState`）。
- 概要: `hasOverviewData` が偽で `errorMessage` があるときは、0 の並んだタイルではなく失敗表示を出す。
- 副題: 失敗時は `0 件` ではなく `取得できません`。
- メトリクスの列: 値が引けないセルは `0` ではなく `—`。
- 詳細パネル: 概要を読む前の件数は行ごと出さない。

到達できないコンテキスト（`kubectl config get-contexts` に出るが繋がらないもの）に
切り替えると、この経路をまとめて確認できる。

### 1 度だけ調べるものは、取れるようになったら拾い直す

Namespace の一覧（`loadNamespaces`）とメトリクスの有無（`detectMetricsSources`）は
クラスタを開いたときに 1 度だけ調べている。**そのとき届かないと、取れなかったのか
無いのかを区別しないまま空で固定される。** 絞り込みのメニューが無効のまま、
メトリクスの列が出ないまま、アプリを建て直すまで直らない（実際にそうなった）。

`recoverClusterInfoIfNeeded()` が、**取れていないものがあるときだけ**拾い直す。
走らせるのは「失敗から成功に変わった瞬間」か「人が更新を押したとき」に限る。
**自動更新のたびに走らせない** — 権限が無くて本当に空のクラスタでは、10 秒ごとに
kubectl が 2〜3 本増えることになる。

確認は、到達できない `server:` を書いた kubeconfig でアプリを起動し、
そのファイルの `server:` を実際に届く先へ書き換えて待つ。kubeconfig は
kubectl の呼び出しごとに読まれるので、アプリを建て直さずに復旧を見られる。

## NSSplitView を 3 つ入れ子にしない（落ちる）

`NavigationSplitView` と `.inspector` で、すでに `NSSplitView` が 2 つ入れ子になっている。
そこへ **`VSplitView` を足して出し入れすると、レイアウト中に AppKit が例外を投げてアプリが落ちる。**

```
+[NSApplication _crashOnException:]
___NSViewLayout_block_invoke
-[NSView _layoutSubtreeWithOldSize:]
```

ログパネルの高さは自前の `@State` で持ち、仕切りは `DragGesture` で動かす
（`LogPanelHandle`）。`VSplitView` に戻さない。

**再現のしかた**: パネルの開閉・対象の切り替え・詳細パネルの開閉・高さ変更を
20 回ほど繰り返す。手で触っていると出たり出なかったりするが、繰り返せば必ず出る。
落ちたかどうかは `~/Library/Logs/DiagnosticReports/KubeDeck-*.ips` の増減で分かる。

## ログは選択に追従する

Pod の行を選ぶとパネルがその Pod に切り替わる（`followLogsToSelection`）。
パネルの ✕ は追従も切る。**閉じたのに選ぶたび開き直すと ✕ が効かないものに見える**ため。
もう一度ログを開けば追従が戻る。

**取得の受け渡しに世代番号を付ける。** `store.logStream(...)` は await をまたぐので、
`stop()` の時点でまだ掴んでいないプロセスは止められない。番号を見ずに書くと、
選んだ Pod の数だけ `kubectl logs -f` が残る（実測で 18 回切り替えて 6 本残った）。
待ちから戻った時点で世代が変わっていたら、掴んだハンドルをその場で `terminate()` する。

確認は `ps -eo ppid,args | awk '$1==<アプリのpid>' | grep " logs "` の本数。
何回切り替えても 1 本であること。

## ログの見え方

- 行頭に**深刻度の帯**（2pt）とごく薄い下地。klog（`E0802`）、JSON（`"level":"error"`）、
  logfmt（`level=error`）、括弧（`[ERROR]`）を見る。判定は取り込み時に 1 度だけ
  （描画のたびに走らせると追従中は毎フレーム全行を舐める）。
- **本文の色は変えない。** 何百行も並ぶ場所で文字色を振ると読むこと自体が疲れる。
- **行番号**を左に置く。折り返した行の塊がこれで分かるので、1 行おきの下地は要らない。
- `--timestamps` の先頭の時刻は落とし、絞り込みに一致した部分は色を敷く。

**誤爆に注意。** `no errors expected` や `/api/errors` を error にしないこと。
語の前後に空白か記号を要求している。変えたら実ログで確かめる。

## ログは一覧の下のパネルに出す

**シートで出さない。** 開いているあいだ一覧も他の Pod も触れず、大きさも変えられない。
ログは「どの Pod のものか」を一覧と突き合わせながら読む画面なので、`VSplitView` で
上下に分け、仕切りで高さを変えられるようにしてある。並べて比べたいときだけ
`WindowGroup(for: PodLogRequest.self)` で窓へ出せる。

**窓へ渡す値に `K8sObject` を使わない。** 窓は一覧より長く生き、`WindowGroup(for:)` に
載せる値は Codable である必要がある。`PodLogRequest`（Namespace・Pod 名・コンテナ名）
だけを渡し、取得側も名前で受ける。

**1 行おきの下地を敷かない。** 折り返した行の塊を見分ける目的で入れてみたが、
折り返しが起きていないときはただの縞になって読みにくい。折り返しの曖昧さは
「折り返し」を切って横スクロールにすれば解ける。

**捨てた行があることを黙らない。** 上限 5,000 行を超えると古いほうから捨てるので、
捨てたときは下の帯にその旨を出す。黙っていると「最初のほうのログが無い」を
不具合と誤解する。

## ローディング表示

`LoadingView` は舵輪を右回りに回す（`RotatingKubernetesMark(activity: .busy)`）。
**出すのはまだ出せる中身が無いときだけ。** すでに一覧が出ているのに差し替えると、
更新のたびに画面が消えて点滅する。中身があるときの更新中は副題に文字で出す。

## ツールバーで踏んだもの

**場所を確保するために透明な項目を置かない。** `ProgressView().opacity(0)` を独立した `ToolbarItem` にすると、隠しても項目の枠が残り、**縦棒が浮いて見える**。

**Menu のラベルに `ProgressView` を入れても、ツールバーでは描画されない。** アイコンが空のボタンになる。取得中の合図は副題（`navigationSubtitle`）に文字で出している。

**メニューはアイコンだけにしない。** ツールバーの `Menu` は既定でアイコンのみになる。コンテキストと Namespace は取り違えると影響が大きいので `.labelStyle(.titleAndIcon)` で名前を常に出す。そのぶん副題からは同じ情報を落とす（二重に出すとどちらが操作対象か紛れる）。

**`.searchable` は一覧にだけ付ける。** `NavigationSplitView` に付けると概要でも検索欄が出るが、絞り込む相手がおらず、打ち込めるのに何も起きない入力欄になる。

## 詳細パネルは選択に連動して出し入れしない

`.inspector` は現れるときに、その列を作るぶんウインドウを広げる。表示を選択に連動させると、左で種別を選ぶたびに窓の幅が変わる。出す / 畳むはツールバーのボタンだけが決める。**選択の有無で `isPresented` を切り替えない。**

そのぶん選択が無いときもパネルは残るので、そこにはクラスタの要約を出す（`ClusterSummaryPane`）。

**概要を読む前の件数を 0 と書かない。** ワークロード一覧から起動すると `overview` は空のままで、そこを素直に表示するとノード 0 / Pod 0 と出る。「まだ数えていない」と「0 件ある」は別物なので、`hasOverviewData` が偽のあいだは行ごと出さない。

## ウインドウの幅を測るときの落とし穴

`CGWindowListCopyWindowInfo` で幅を見ても、窓が zoom されていると常にディスプレイの表示領域と同じ値が返り、何を変えても動かない。`NSWindow.isZoomed` と `minSize` を一緒に記録しないと、「変わらない」のか「変えられない」のか区別できない。

`defaults write` で設定を差し替えても効かないことがある。アプリは終了時に自分の設定を書き戻すので、`pkill` の直後に書くと競合して消える（ウインドウ枠でも選択の復元でも踏んだ）。**書いたあと `defaults read` で確かめてから起動する。**

## 状態の色は 4 段に固定

good / warning / serious / critical（`Views/Palette.swift`）。系列色とは別枠で、ライトとダークで振らない。同じ「異常」が外観設定で違う色に見えないようにするため。

**状態色を単独で出さない。** ライト背景では warning と serious がコントラスト 3:1 に届かない。一覧のセルも凡例もバッジも、必ずアイコンかラベル文字列と組にして出している。この組を外さない。

## 配布と更新

配るのは GitHub Releases、更新は Sparkle（`Services/UpdateController.swift`）。

**EdDSA の公開鍵（`project.yml` の `SUPublicEDKey`）を変えない。** 配布物は ad-hoc 署名
なので cdhash が版ごとに変わり、Apple のコード署名どうしを突き合わせる検証は通らない。
Sparkle が更新を受け入れているのは「新旧の公開鍵が一致して EdDSA 署名が有効」な経路
だけ（`SUUpdateValidator` は、この経路では署名 identity の変化を許す）。**鍵を差し替えた
時点で、既に配ったアプリは以後の更新を一切受け取れなくなる。** 秘密鍵は login キーチェーンと
Secrets の `SPARKLE_PRIVATE_KEY` の 2 か所にあり、失うと同じことが起きる。

**署名を外さない。** Sparkle は「署名付きだったものが署名無しになる」更新を拒む。ad-hoc は
その最低線として明示的に認められている。CI が `codesign --verify --deep --strict` を
毎回通しているのはこのため。

**版は `Scripts/release.sh` が xcodebuild の引数で注入する。** `project.yml` の
`MARKETING_VERSION` は「タグを打たずに手元で建てたもの」用の値。スクリプトは焼いた
Info.plist の版と指定した版が一致することを確かめてから詰める。ずれたまま出すと、
入れ替えても Sparkle が同じ更新を出し続ける。

**appcast は 1 リリースに 1 項目でよい。** 全履歴を持つ appcast を作るには過去の
アーカイブを集め直すことになる。古い版から見ても「最新が 1 つある」ことは分かるので、
`releases/latest/download/appcast.xml` に毎回 1 項目だけ上げている。この URL は
プレリリースを指さないので、試し焼きは `--prerelease` で出せば既存の利用者に届かない。

**appcast.xml を後から書き換えない。** ファイル自身に署名を埋めてあるので、1 文字でも
変えると検証に落ちる。直すときは `Scripts/release.sh` から作り直す。

**更新の設定を Sparkle 側と二重に持たない。** `Info.plist` に `SUEnableAutomaticChecks` を
置いて Sparkle 自身の問い合わせを止め、実際に効く値は `Preferences` から
`UpdateController.configure(...)` で渡している（kubectl と同じやり方）。両方を生かすと、
設定画面のスイッチと Sparkle のダイアログのどちらが効いているのか分からなくなる。

**確認の結果を時刻だけで表さない。** Sparkle は取得に失敗しても `lastUpdateCheckDate` を
進めるので、時刻だけを出すと「確認できた」ように見える。`UpdateCheckOutcome` が
「まだ確認していない / 最新 / 更新がある / 確認できなかった」を分けている。ここは
「無い」と「取れていない」を混ぜないという同じ話。

**`SPUUpdater` を画面へ直接渡さない。** Objective-C の素のオブジェクトで `@Observable`
ではないので、値が変わっても画面が追従しない。KVO のクロージャの中で `updater` を
読むのも駄目で（MainActor 隔離のプロパティを Sendable な文脈から読むことになる）、
`change.newValue` だけを受け取って写しに入れる。

## 起動時の復元は didSet を止めてから

`ClusterStore.bootstrap()` は `isBootstrapping` を立てているあいだプロパティの didSet からの連鎖を止める。止めないと `currentContext` の didSet が `selectedNamespace` を nil に落とし、その didSet が `UserDefaults` の保存値を上書きするので、**読み出す前に前回の Namespace が消える**。
