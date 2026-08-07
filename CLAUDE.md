# CLAUDE.md

KubeDeck は Kubernetes Dashboard 相当の画面を macOS ネイティブで持つアプリ。SwiftUI、Swift 6 strict concurrency、macOS 14 以降、Apple Silicon。

## ビルド

```bash
# 新しい .swift ファイルを追加したときだけ必要
xcodegen generate

xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
  -configuration Debug -destination 'platform=macOS' build

# テスト（KubeDeckTests は KubeDeck スキームに紐づけてある）
xcodebuild test -project KubeDeck.xcodeproj -scheme KubeDeck \
  -destination 'platform=macOS'
```

既存ファイルの編集だけなら `xcodegen generate` は不要。`project.yml` がソースオブトゥルースで、`.xcodeproj` は生成物。**`.xcodeproj` を直接編集しない。**

**`xcodebuild` の出力を `head` に通さない。** パイプを早く閉じると `xcodebuild` が居残り、DerivedData の `XCBuildData/build.db` を握り続ける。次のビルドが `database is locked` で落ちるが、原因は自分の残骸であって同時ビルドではない。絞りたいときはログをファイルに落としてから `grep` する。

起動確認:

```bash
pkill -f "KubeDeck.app/Contents/MacOS/KubeDeck"
open "$(xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/KubeDeck.app"
```

## 表示文言は String Catalog に集める

ソース言語は **ja**、訳は **en**（`Resources/Localizable.xcstrings`）。
**鍵は日本語の原文そのもの。**

```bash
# 鍵を同期して、訳の埋まり具合を報告する
Scripts/sync-strings.sh
Scripts/sync-strings.sh --check   # 建てずに、いまのカタログだけ見る
```

**セマンティックな鍵（`action.delete`）にしない。** このリポジトリは表示文言を
根拠付きでここに記録する作りで、コードから文言が読めなくなると「なぜこの言い方
なのか」を辿れなくなる。原文を鍵にすれば `Text("削除")` は無変更で訳が当たり、
テストの断定もそのまま残る。**代わりに、文言を直すと鍵が変わる**（カタログの
移行が要る）ことを引き受ける。

**`developmentLanguage` を en にしない。** 訳の無い言語では鍵、つまり日本語へ
落ちる。ソース言語が en だと「en を要求したのに日本語が出た」ことになり、
未訳と取り違える。

### 鍵は手で足さない。コンパイラに吐かせる

`SWIFT_EMIT_LOC_STRINGS` を立ててあるので、ビルドすると 1 ソースにつき 1 つ
`.stringsdata` が出る。`Scripts/sync-strings.sh` が `xcstringstool sync` で
カタログへ流し込む。

**`xcstringstool extract` で済ませない。** あれは型を見ないので、補間の書式
指定子が `%arg` のままになる（実測）。実際の鍵は型で決まる（`%lld` / `%@`）ため、
抽出だけで作った鍵は**当たらない。しかもどこも失敗しない**ので、日本語のまま
出ていることに気付けない。

**ビルドが通らないときは同期しない。** 鍵が欠けた `.stringsdata` で同期すると、
まだ使われている訳を stale として落とす。

**`.xcstrings` の名前を変えない。** `xcstringstool sync` は**ファイル名から
テーブル名を決める**。写しを取って確かめるときに `strings-check.xcstrings` の
ような名前にすると `Localizable` テーブルと一致せず、**全 802 鍵が「使われて
いない」になる**（実測。エラーにはならないので、そのまま信じると訳を全部
捨てる）。CI の写しはディレクトリを分けて名前を保つ。

### ソース言語も明示で埋める

**`state: new` のまま残さない。** `xcstringstool sync` はソース言語の項目を
`new` で書くが、その状態ではコンパイル対象から外れて **`ja.lproj` が焼かれない**。
すると配布物の中身は `en.lproj` だけになり、**日本語環境でも英語が出る**
（実測。`preferred: ["en"]`、`削除しますか？ → Delete?`）。国際化した結果として
既存の利用者に英語を出す、といういちばん避けたい壊れ方。

`ja` は値＝鍵で `state: translated` として全鍵に入れてある。確認は配布物を見る。

```bash
ls "$APP/Contents/Resources" | grep lproj          # en.lproj と ja.lproj の両方
plutil -extract "削除しますか？" raw -o - "$APP/Contents/Resources/en.lproj/Localizable.strings"
```

**`Bundle(path:)` を使ったプローブで確かめない。** CFBundle は
`AppleLanguages` を CFPreferences から読むので、`UserDefaults` の引数ドメインに
入れても効かない（`preferred` が常に同じ値を返して**確かめたつもりになる**）。
アプリ自身を起こして撮る（`defaults write com.piyoraik.KubeDeck AppleLanguages
-array en` → `Scripts/screenshot.sh`。**確かめたら `defaults delete` で戻す**）。

**未対応の言語では日本語に落ちる。** ソース言語が ja で
`CFBundleDevelopmentRegion` も ja なので、en / ja のどちらにも当たらない環境
（de など）は英語ではなく日本語になる。en を既定の落ち先にしたいなら、
ソース言語の選び直しになる（いまはしない）。

### 独自のラッパーを作らない

短く書きたくなるが、`L("…")` のような関数を挟むとコンパイラの抽出が効かず、鍵を
手で書くことになる（上のとおり、それがいちばん危ない）。**素の
`String(localized:)` をそのまま書く。**

### 型の側で受けると、呼び出し側は無変更で済む

`Text("削除")` は SwiftUI が `LocalizedStringKey` で受けるので何もしなくてよい。
**問題は `Text(変数)` に流れる `String`** で、あれは訳されない。そこで
**表示文言を受け取る型のパラメータを `LocalizedStringResource` にする。**
呼び出し側は日本語のリテラルを書くだけで鍵になり、実測で抽出も効く（独自の
初期化子・`String.LocalizationValue`・`LocalizedStringKey`・
`LocalizedStringResource` の 4 つとも拾われた。複数行リテラルと補間も拾う）。

`SettingRow` / `SettingGroup` / `ResourceColumn` / `ResourceAction` /
`PendingAction` / `InfoSection` / `InfoRow` / `UsageMeter` / `StatusRing` /
`LoadingView` / `ClusterStore.perform` などがこの形。これで約 300 の呼び出し側を
1 文字も触らずに済んだ。

**`String` のままにするものもある。** 対象の名前を継ぎ足して組む文面
（`PendingAction.message`）と、**すでに訳された文字列が渡ってくる経路**
（`ManagedBy.warning` → `YAMLEditSheet.notice`）。後者を
`LocalizedStringResource` で受けると、訳した文字列をもう一度鍵として引くことに
なる。

### 鍵と id を兼ねさせない

**訳した文字列を突き合わせに使わない。** 別の原文が同じ訳になったとき
（`要求` と `リクエスト` がどちらも `Requests`）に取り違える。

- `ResourceSort` は `columnTitle` を捨てて `ResourceColumn.key`
  （＝`LocalizedStringResource.key`、つまり原文）で持つ。**列の位置でも表示名でも
  ない。**
- `SettingRow.id` / `SettingGroup.id` も原文の鍵から作る。`ForEach` の同一性が訳で
  動くと行が入れ替わる。
- `ResourceAction.id`（`logs` / `logs-group`）と `PlacementView.unscheduledID` は
  最初から訳さない値にしてある。後者は箱の見出しに `id` を流用していたので、
  **見出しだけを別に持たせた**（`Group.title`）。

CRD の列だけは別で、見出しがサーバから来る（`ResourceColumn(serverTitle:)`）。
**訳す先が無い**ので鍵もその名前をそのまま使う。

### 文をつなぎ合わせて組まない

行の長さに収めるための `+` は、**断片ごとに鍵を作る**。訳す側は語順を変えられない
と英語として組めない（`Spread (preferred)`）。1 つの文に 1 つの鍵を当て、行を
折るのは複数行リテラルの `\`（改行を打ち消す）で行う。

```swift
return String(localized: """
    この Namespace の中にあるものが、すべて一緒に消えます\
    （Pod・Service・ConfigMap・Secret・PVC など）。\
    クラスタでいちばん戻せない操作です。
    """)
```

**補間の中に `"` を書かない。** `\(hpa.spec?["minReplicas"]?.intValue ?? 1)` の
ような添字や `?? "既定値"` を鍵の中に置くと、文言としての切れ目が読めなくなる
（実際に 3 か所壊した）。値は先に `let` で取り出す。

### セルの中で毎回引かない

列の値を作る閉包は、描画のたびに見えているセルの数だけ走る。決まった文言は
`static let` で 1 度だけ引く（`ResourceTable.allPods`、`SettingsDigest.yes` など。
`KubernetesLogo` の `unitBody` と同じ話）。値が混ざるものは鍵に書式指定子が要る
ので、その場で組む。

### テストは ja で走らせる

`SafetyTests` や `PlacementTraceTests` は「『消えています』と書くか」
「『取得している範囲』と書き分けるか」まで断定しており、それはこのリポジトリが
守りたい判断そのもの。ロケール任せにすると**日本語環境の手元では通って英語の
CI ランナーでだけ落ちる**ので、スキームの test action に `language: ja` を
入れてある（`project.yml` の `schemes:`。ターゲットの `scheme: testTargets:` の
略記では指定できないので、明示のスキームに書き換えた）。

**訳の網羅をテストで見ない。** あちらは `Scripts/sync-strings.sh` の報告が持つ
（未訳は日本語のまま出るだけで、どこも失敗しない ——「無い」と「取れていない」を
混ぜないのと同じで、**気付く手立てを別に置く**）。

### 言語はアプリ内でも選べる（`AppLanguage`）

設定の「一般 › 表示 › 言語」で `システムに従う` / `日本語` / `English`。

**独自のキーに覚えない。** 書き込む先は `AppleLanguages` —— macOS 自身が見る
場所で、システム設定（一般 › 言語と地域 › アプリケーション）もここへ書く。
別のキーに持つと真実が 2 つになり、どちらが効いているのか分からなくなる
（更新の設定を Sparkle 側と二重に持たないのと同じ話）。`システムに従う` は
空配列を書くのではなく**キーを消す。**

**切り替えたその場では変わらない。** 起動時に解決されたバンドルの言語は
作り直せない。**断りが無いと設定が壊れているように見える**ので、
`languageChangeNeedsRestart`（起動時の値と設定値が違うか）を見て
「次に KubeDeck を起動したときに変わります」を出す。**起動時の値を別に持つ**の
がこの判断の要 —— 設定値だけを見ていると「変えたが再起動していない」を
言い分けられない。

**言語の名前は訳さない。** 英語の画面でも「日本語」、日本語の画面でも
「English」と出す。探している人は自分の言語の綴りを探すので、訳すと
**その言語の人にだけ見つけられなくなる**（macOS 自身もそうしている）。
訳すのは「システムに従う」だけ。

**`Locale` の一覧を並べない。** 訳があるのは ja と en の 2 つだけで、選べる
中身と訳の有無が食い違うと「選んだのに変わらない」になる（押しても失敗すると
分かっているものを出さない、といつもの話）。

**地域付きを受ける。** システム設定は `ja-JP` のように書く。完全一致で見ると
「システムに従う」に落ちて、選んだ言語が設定画面に出ない（`AppLanguageTests`）。

**テストで `UserDefaults` を触らない。** ここを実際に書くと、テストを走らせる
だけで**開発機のアプリの言語が変わる**（`AppleLanguages` は macOS 自身が見る
場所）。固めるのは `AppLanguage(codes:)` の変換だけ。

`resetAll()` には**入れる** —— 見た目の既定値の 1 つなので巻き添えにしてよい
（`contextProfiles` を外に置いたのは、あれが安全側の札だから）。ただし反映は
次の起動からなので、確認の文面でそう断る。

### 訳は測ってから入れる

```bash
swift Scripts/measure-widths.swift
```

**幅は日本語で決めてある。** 一覧の列は `.fixed(n)`、詳細パネルの見出し欄は
96pt 固定で、収まらなければ `.lineLimit(1)` が黙って切る（**切れたことが画面に
出ない**）。撮って眺めるだけでは、クラスタが繋がっていない画面では列そのものが
出ないので確かめられない。

実測で 3 件溢れていた。`退避できる数 → Disruptions allowed` は 8pt 溢れ ——
ここは**文言を削るより列を広げた**（110 → 130pt。CLAUDE.md がこの列を
「この一覧を足した理由そのもの」と書いている場所なので、短くして意味を削らない）。

**そして、測ったことから誤訳が出た。** 溢れた `希望` を見に行って、
kubectl の `DESIRED`（ReplicaSet の `spec.replicas`）に `Preferred` を当てて
いたことに気付いた。そこから列見出しを kubectl の語彙と突き合わせ直して、
さらに 5 件直した。**とくに `種別`（resource kind）と `種類`（Service や Secret の
`type`）は訳が入れ替わっていた。** 短い語は 1 つの鍵が何か所からも使われるので、
**鍵ごとに使われ方を全部見てから訳す**（`grep -rn '"種類"' Sources/`）。

### 訳さないもの

- 区切り記号（`"・"` / `" / "` / `", "`）。ただし **`" の "` は訳す** ——
  「Namespace x の Pod y」は日本語の語順で、英語では別の繋ぎになる。
- 開発者にしか出ないもの（`fatalError` / `Codable` の `debugDescription`）。
- kubectl / Kubernetes の語（`cordon` / `drain` / `Running`）。**訳し分けると押す
  側にどちらがどちらか決まらない**（`ResourceAction.shortTitle` の判断と同じ）。

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

### 権限で拒まれたときは、押したあとに言う

**押す前に調べる作りにしていない。** `kubectl auth can-i --list` は **JSON を
出せず**（実測。`-o` は unknown flag）、表には `*.*` `[*]` のようなワイルドカードが
並ぶ。要求する種別と突き合わせるには RBAC の評価器を書くことになり、ラベル
セレクタや JSONPath を実装しなかったのと同じ理由でここでは持たない。

代わりに `Kubectl.permissionHint` が、**拒まれたときに何をどうすれば通るのか**を
返す（拒まれた動詞と対象、いまの資格情報、確かめ方の `auth can-i` の打ち方、
許し方）。**認証の失敗と混ぜない** —— 誰であるかは通っていて、その人にその操作が
許されていないだけ。`gcloud auth login` を何度やっても直らない。

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

**名前に頼りきらない。** `DATABASE_URL=postgres://user:pass@host` のような値は
どの目印にも当たらないのに認証情報を含む。この画面はそのまま貼って共有されうる
場所なので、`scheme://user:pass@host` の形でも伏せる。**ただし伏せすぎない** —
資格情報を含まない URL はプロキシの指し先としてまさに見たい値だし、
`ssh://git@host` の `user@host` は資格情報ではない（`Kubectl.hidesValue`）。

**Form の中に `ScrollView` を置かない。** 高さが潰れて 1 行も見えないことがある。Form 自体がスクロールするので素直に並べる。

実クラスタなしで確かめられる。合成した kubeconfig を `KUBECONFIG` に足せば（`kubectl config get-contexts` に出る）、到達できない GKE のコンテキストとして両方の経路を通せる。

**取得系には必ず `--request-timeout` を付ける。** 到達できないコンテキストを選んだとき、付いていないと kubectl が待ち続け、UI が読み込み中のまま固まる。

**それだけでは足りない。プロセスごと上限を掛ける。** `--request-timeout` が縛るのは API への要求だけで、**kubeconfig の exec 認証プラグインが返ってこない場合には効かない**（gcloud が再認証の入力を待つ、プロキシの向こうで詰まる）。実際にこれで全画面が読み込み中のまま止まった。`Kubectl.run` が `ProcessRunner.run(timeout:)` に `待ち上限 + 10 秒` を渡し、先に kubectl 自身を諦めさせる。

打ち切ったかどうかは `CommandResult.timedOut` で分ける。**終了コードだけで判断しない** — 相手が自分で失敗したのか、こちらが殺したのかが区別できない。**「取れなかった」と「返ってこない」を混ぜない**（見るところが違う）。

**絞りすぎない。** ここは「終わらないもの」を切るためだけの網で、ふつうの失敗は kubectl 自身の待ち上限が捌く。届かないクラスタでは kubectl が API グループの一覧を数回引き直すので、待ち上限の 2 倍以上かかる。最初 `待ち上限 + 10 秒` にしたら、kubectl の「届きません」より先に殺してしまい、**経路の問題なのに「認証プラグインが返ってこない」と表示した**。いまは `待ち上限 × 2 + 15 秒`。

**打ち切ったことを理由にしない。** 打ち切るまでに kubectl が何か書き出していれば、そちらのほうが確かな手がかりなので、`timeoutMessage` は先に `authenticationHint` を通す。**言い換えを先に置く** — 帯は最初の段落しか見出しに出さないので、打ち切った断りを先に書くと肝心の理由が畳まれた側に入る（そうなった）。

**取り消されたら子プロセスも殺す。** `Task` を取り消しても `Process` は勝手には
止まらない。取得系には手当てが無かったので、コンテキストや種別を続けて
切り替えると `loadTask?.cancel()` のあとも前の kubectl が最後まで走り、
**1 本あたりスレッドを 3 本（待ち 1 + 読み 2）掴んだまま積み上がっていた**
（概要は 4 本同時に投げる）。結果は世代番号で捨てられるので、走らせ続ける意味が
そもそも無い。`ProcessRunner.run` が `withTaskCancellationHandler` で
`ProcessHandle` を止める（ログの追従と同じ仕組みを取得系にも通す）。

打ち切りは `terminate()` → 2 秒待って駄目なら `SIGKILL`。確認は、返ってこない認証プラグイン（`sleep` するだけのスクリプト）を `command:` に指定した kubeconfig で起動し、`ps -eo ppid,args` で本数を数える。実行中のぶん（`async let` の 4 本×重なり）を超えて増えないこと、`ppid` が 1 のプラグインが残らないこと。

**概要画面は 1 回の kubectl でまとめて取る。** 種別ごとに投げると 13 プロセス起動することになる。カンマ区切りで複数種別を get すると `items` に `kind` が入るので、呼び出し側で振り分けられる（単一種別の get では `kind` が空になる版もあるため、`K8sObject.list(from:assuming:)` で要求種別を補う）。

### 一部の種別だけ読めないときに、読めたぶんを捨てない

**`--ignore-not-found` は権限には効かない。** 握りつぶすのは NotFound だけで、
**Forbidden はそのまま終了コード 1 になる**。にもかかわらず kubectl は
**読めた種別を標準出力に書き出してから**終了する。実測（orbstack + impersonation）:

```
$ kubectl get pods,secrets -A -o json --ignore-not-found=true --as=<pods だけ読める SA>
exit=1
Error from server (Forbidden): secrets is forbidden: ... cannot list resource "secrets"
$ ... | wc -c
241201        ← Pod の JSON は stdout に来ている
```

終了コードだけで投げると、この 241KB を捨てて「取得できません」と出すことになる。
Secret だけ読めないクラスタで概要が丸ごと消えていた。**「取れているのに取れて
いないことにする」のは、「無い」と「取れていない」を混ぜるのと同じ間違い。**

`CommandError` が `partialStdout` を持ち回り、`Kubectl.list(kinds:)` が
`PartialList`（読めたもの＋拒まれた種別）を返す。**どこまで許すかを絞る** —
打ち切りは従来どおり投げるし、標準出力が空なら投げる（認証で落ちていれば
標準出力は空になるので、本物の失敗を握りつぶすことはない）。

拒まれた種別は `stderr` の `<resource> is forbidden` から拾う。グループ付き
（`deployments.apps`）と無し（`secrets`）の両方が来る。**要求した種別に
現れたものだけ**を拒まれた扱いにする（当てはまらない失敗を「権限が無い」に
しない）。書式に依存しているので `KubectlTests` で固めてある。

**突き合わせる前に、両側からグループを落とす**（`Kubectl.plural(of:)`）。
kubectl は文言によってグループを付けたり付けなかったりするが、こちらが要求する
名前は `networkpolicies.networking.k8s.io` のようにグループ付きで固定してある。
**片側だけ切ると、グループ付きの種別が 1 つも一致しない。** 実際 `deniedKinds`
だけが非対称になっており、NetworkPolicy や RoleBinding が拒まれても拒否の一覧に
入らず、**サイドバーに「0 件」と出ていた**（`counts` に 0 で埋まるため）。
テストが `secrets` / `deployments` / `ingresses`（要求側もグループ無し）だけを
使っていたので穴を通り抜けていた。**テストにはグループ付きの種別を必ず混ぜる。**

**拒まれた種別を `counts` に 0 で入れない。** 入れると「拒まれた」が「無い」に
なる。`counts` から抜けば、消費側（サイドバー）は nil を「まだ分からない」として
扱うので既存の経路がそのまま正しく働く。**逆に、要求して読めた種別は 0 で
埋めておく** — 1 件も無い種別は `items` に現れないので、埋めないと「0 件」と
「まだ数えていない」が同じ nil になる。

欠けは画面を失敗にせず、`PartialDataNotice` の帯で断る（`partialDataNotice`）。

### 知らない種別が 1 つあると、まとめ取得が丸ごと消える

**`--ignore-not-found` は「サーバが知らない種別」にも効かない。** 効くのは
NotFound だけ。しかも Forbidden とは**壊れ方が違う** — kubectl は要求を
組み立てる段で諦めるので、**標準出力に 1 バイトも来ない**。実測:

```
$ kubectl get pods,hoges -A -o json --ignore-not-found=true
exit=1  stdout=0 バイト
error: the server doesn't have a resource type "hoges"
```

つまり Pod も Service も読めていたのに、種別 1 つのせいで概要・配置・
サイドバーの件数が**まとめて**「取得できません」になる。API グループが 1 つ
discovery から落ちているだけのクラスタで（集約 API サーバが応答しない、
CRD やアドオンを外した直後）これが起きる。**ターミナルで `kubectl get pods` が
通るのに、アプリでは全部が取れない**という見え方をするので、原因を kubectl 側に
探しに行けない。

`Kubectl.list(kinds:)` は、知らないと言われた種別を除いて引き直す。
**1 回では済まない** — kubectl が名前を出すのは**最初の 1 つだけ**なので
（`get pods,hoges,fugas` でも `hoges` しか出ない）、残りで引き直しては除く、を
繰り返す。書式に依存しているので `KubectlTests` で固めてある。

**拒まれた種別と混ぜない**（`PartialList.unknown`）。権限の話ではないし、
「本当に無い」のか「kubectl の一覧が欠けている」のかもここでは決まらない。
`counts` に 0 で入れないのは拒まれた種別と同じ理由。

**「無い」と断定しない。** `Kubectl.discoveryHint` は見分け方のほうを書く
（`kubectl api-resources` に出るか、`kubectl get apiservices` に AVAILABLE=False が
無いか、一覧に出るのに見つからないなら覚えている一覧が古い）。

**知らない種別を毎周期たずねない。** 実測すると、知らない種別を 1 回 get する
だけで kubectl は**覚えている API の一覧を丸ごと捨てて引き直す**（`discovery/` の
全グループの mtime が更新される。存在する種別の get では更新されない）。
遅いクラスタでこれが自動更新のたびに走ると、そのぶん discovery が失敗しやすくなる。

### API の一覧のキャッシュは、ターミナルと共有しない

**`--cache-dir` を必ず渡す**（`Kubectl.cacheDirectory` =
`~/Library/Caches/com.piyoraik.KubeDeck/kube`）。既定の `~/.kube/cache` は
ターミナルの kubectl と同じ場所で、**どちらかが壊した一覧をもう一方も読む。**

実際に踏んだ壊れ方。`discovery/<サーバ>/servergroups.json` が、本来 63 グループ
（12,701 バイト）あるところ **1 グループだけの縮退状態**（133 バイト）で残っていた。

```json
{"kind":"APIGroupList","groups":[{"name":"","versions":null,
 "preferredVersion":{"groupVersion":"","version":""}}]}
```

コアグループ（`name: ""`）の `versions` が null なので、kubectl は「v1 という
バージョンが存在しない」と読み、`pods` も `services` も `configmaps` も解決
できなくなる。出る文言は `the server doesn't have a resource type "pods"` で、
**上の節の「知らない種別」が全種別で一斉に起きる**。概要も配置も一覧も丸ごと
消えるのに、クラスタにも認証にも異常が無い。

**壊れ方を「アプリが壊した」に決めつけない。** 残っていたのは valid な JSON で、
書き込みが途中で切れたものではない（切れれば壊れた JSON になる）。**縮退した応答を
そのまま覚えている**ので、誰が引いたときに起きたのかはこの証拠からは決まらない。
だから対処は「壊さない」ではなく次の 2 つにする。

- **巻き込まない** — 置き場所を分ける。ターミナルの kubectl が道連れにならない。
- **自力で捨てて引き直す** — `the server doesn't have a resource type` を受けたら
  `discovery/` を捨てて **1 度だけ**引き直す（`Kubectl.run`）。文言からは
  「本当に無い」のか「一覧が欠けている」のかが決まらないので、**引き直して
  確かめる。** 引き直しても同じなら、それは本当に無い。

**捨てられなかったときに引き直さない。** 消えていないのに引き直すと、同じ失敗を
もう 1 度取りに行くだけになる（`removeDiscoveryCache` が false を返す）。

**毎回捨てない。** 本当に存在しない CRD を毎周期たずねる画面があると、そのたびに
全 API グループを引き直すことになる（上の節と同じ話）。捨て直しは 1 分に 1 回まで。

**kubectl の版によっては自力で直る。** 手元の v1.32.1 は縮退したファイルを渡すと
その場で引き直して 63 グループに書き戻した（実測）。報告のあった v1.32.13 は
戻らなかった。**版が変わっても効く形にしておく** — アプリ側で捨てられるなら、
kubectl 側の挙動に依存しない。

置き場所と「最後に捨てた時刻」は設定の「接続」に出す。**黙って直さない** —
自力で復帰するのは正しいが、それが何度も起きているなら見に行く先がある
（縮退した応答を返しているゲートウェイなど）。

確認は、アプリを起動して
`~/Library/Caches/com.piyoraik.KubeDeck/kube/discovery/.../servergroups.json` が
できること、`~/.kube/cache` の mtime が動かないこと。

## 取りに行き方を絞る

**一度に全部を要求しない。** `--chunk-size=500` を付ける。`-o json` でも kubectl は
分けて取り、こちらには 1 つにまとめて返す（実測。複数種別 + `--ignore-not-found`
と併用しても効く）。数千 Pod のクラスタで API サーバに一撃で数十 MB を作らせない
ため。**アプリ側の読み込み量は変わらない** —— そこは種別と Namespace を絞って
もらう話で、この指定で直るのは取りに行き方だけ。

**隠れているあいだは自動更新を止める**（`ClusterStore.isWindowVisible`）。
止めないと、しまってあるノート PC でも 10 秒ごとに kubectl が 4〜8 本立ち上がり
続ける。**`scenePhase` では足りない** —— 他のアプリを触っているだけで
`.inactive` になるが、そのときもロールアウトを横目で見ていることはふつうにある。
止めたいのは「しまった・完全に覆われた」ときだけなので、
`NSApplication.didChangeOcclusionStateNotification` を見る。
**戻ってきたら 1 回引く**（止めているあいだに進んだぶんを、次の周期まで古いまま
出さない）。

**切り分けのときにこれを忘れない。** 覆われているあいだは kubectl が 1 本も
立たないので、**自動更新が壊れたのと見分けが付かない**。実際、直したあとの確認で
88 秒間 1 本も走らず「印が下りていない」と読みかけた（アプリを前面に出したら
すぐ動いた）。プロセスを数える確認は、**窓を前面に置いてから**行う。

### 走っている取得を、自動更新で追い越さない

**重なりの判定に `isLoading` を使わない。** あれは「まだ出せる中身が無い」の意味で、
自動更新では立てない（更新のたびに画面が消えて点滅するのを避けるため）。なのに
周期の見送りをそれで判定していたので、**自動更新のときだけ素通りしていた。**
しかも `reload` は `loadTask?.cancel()` で**子プロセスまで殺す**（取り消しの節）
ので、走っている取得を毎周期捨ててゼロから引き直すことになる。

実測（Connect Gateway 越しの GKE・配置画面の 15 種別で 2.4MB）で 1 回の取得に
**9.7〜15.2 秒**かかり、更新間隔 10 秒がそれを追い越していた。**症状は「もっさり」で、
画面はほぼ常に取得中。** 完走するのは、たまたま 10 秒未満で終わった回だけ。

見つけ方は**子 kubectl の pid と経過時間**。経過 10 秒を超えられずに入れ替わり
続けるなら、これ。

```
23:48:09 子pid=61929 経過=00:09   ← 直す前。10 秒の壁を越えられない
23:48:16 子pid=62124 経過=00:10
23:48:27 子pid=62175 経過=00:07
00:16:15 子pid=75122 経過=00:17   ← 直したあと。同じ pid が完走する
```

`isFetching` を `isLoading` とは別に持ち、**見送るのは自動更新だけ**にする
（人が押した更新や種別・Namespace の切り替えは、これまでどおり打ち切る ——
見ているものが変わったのに前の取得を待つ意味は無い）。**印は同期で立てる** ——
`Task` の中で立てると、走り出す前に次の周期が来て素通りする。**打ち切られたときに
下ろさない** —— 打ち切った側がすでに次を始めている。

**種別を足すぶんだけ往復が増える。** 実測で `clusterrolebindings` 単独 6.54 秒 /
224KB、`rolebindings` 単独 3.87 秒、Pod 単独 2.53 秒 / 1.1MB。まとめ取得に足すのは
プロセス 1 本ぶん得だが、**往復の数は減らない。** 遅い経路では、種別を 1 つ足す
判断が更新間隔を超えるかどうかに直に効く。

**ただし、外した効果を測れたと言わない。** RBAC の 2 種別を抜いて交互に 4 回ずつ
測った結果は 13.29 秒 → 11.45 秒（平均）だが、**分散が 7.4〜19.8 秒あって有意では
ない。** 「もっさり」を直したのは重なりを止めたほうで、種別を減らしたほうは
API サーバに掛ける負荷が減る話として持つ。

## リソースの型付けは metadata だけ

`spec` / `status` は `JSONValue`（`Models/JSONValue.swift`）のままキーパスで引く。**全リソースに Codable の struct を起こさない。** 15 種あり、同じ種別でも API バージョンやアドオンの有無でフィールドが増減する。型を付けると、フィールドが 1 つ欠けただけで一覧が丸ごとデコードエラーで落ちる。いまの作りなら、引けないフィールドは nil になって該当セルが空になるだけで済む。

## 一覧の STATUS 列と、ドーナツの集計は別物

- `StatusResolver.status(for:)` — 一覧の STATUS 列。**kubectl の printer の再現**。Pod は phase をそのまま出さず `containerStatuses` まで見る（phase は CrashLoopBackOff でも `Running` のため）。ここを「分かりやすく」書き換えない。kubectl と表示がずれると、どちらが正しいのか確かめる手段が無くなる。
- `StatusResolver.health(for:)` — 概要のドーナツと一覧の並べ替え。`status` を土台に、**Running だが Ready が揃っていない Pod を正常側に混ぜない**。kubectl の STATUS 列だけ見ていると気付けない状態がここで表に出る。`Completed`（Ready 0/1 が正常）を巻き込まないよう、降格は `Running` に限っている。

異常系（CrashLoopBackOff、`Init:`、Terminating、OOMKilled、ExitCode）は
`Tests/KubeDeckTests/StatusResolverTests.swift` が合成 JSON で押さえている。
kubectl 側の表示が変わったかを疑うときだけ、実クラスタと突き合わせる
（`kubectl get pods -A --no-headers` の STATUS / READY / RESTARTS）。

## テストは純粋関数に掛ける

```bash
xcodebuild test -project KubeDeck.xcodeproj -scheme KubeDeck -destination 'platform=macOS'
```

`Tests/KubeDeckTests`（swift-testing）。**UI は対象にしない** — 見た目の判断は
このリポジトリでは文章と実際の画面で決めており、テストに写しても二重管理になる。

固めているのは、壊れても気付きにくいところだけ。

| 対象 | 何が壊れると困るか |
|---|---|
| `StatusResolver` | kubectl と表示がずれる（どちらが正しいか確かめる手段が無くなる） |
| `Quantity` | 桁が 9 つ違う値を取り違える。`129e6` と `1E` |
| `LogLevel` | 深刻度の誤爆（実際に `handler=errorMiddleware` を踏んだ） |
| `WorkloadRelations` | 空セレクタや Namespace 越えで無関係なものが繋がる |
| `PlacementTrace` | 名前だけで束ねて別物が合体する。ReplicaSet で止まる |
| `Kubectl.deniedKinds` | 依存している kubectl の stderr の書式 |
| 概要の読み込み中 | まだ数えていないのに 0 のリングを出す。逆に読み込み中のまま留まる |
| 並べ替え・しきい値 | 黙って意味が変わる（警告色が出なくなるなど） |

**CI で必ず走らせる**（`.github/workflows/build.yml` と `release.yml` の
「確かめる」）。以前は建てるだけでテストが 1 度も走っておらず、上の表の
「壊れても気付きにくいところ」に網が掛かっていなかった（実際、`deniedKinds` の
非対称は既存テストの脇を通り抜けていた）。**建てるより先に置く** —— 論理の回帰は
Release ビルドを待たずに落とす。**リリース側にも置く** —— タグを打った時点で
配布物になるので、そこだけ素通りにしない。

**画面は撮って確かめる**（`Scripts/screenshot.sh`）。UI をテスト対象にしない
方針は変えないが、「その画面が本当にそう出ているか」を確かめる手立てが無いままだと、
変更のたびに人へ見てもらうことになる（実際そうなった）。決め打ちの状態でアプリを
起こして窓だけを撮る。

```bash
Scripts/screenshot.sh out.png podDisruptionBudget kube-system
```

**終了させてから設定を書く**（アプリは終了時に自分の設定を書き戻すので、起動中に
書くと競合して消える）。**窓の id は `CGWindowList` から取る** ——
`osascript` で数えるだけでも補助アクセスの許可が要り、断られると理由の分かり
にくい失敗になる。`screencapture -o` で影を除くと、画像の大きさが窓の大きさと
一致する（座標を測るときに要る）。

**合成マウス入力は届くが、合成キー入力は届かなかった**（実測）。ショートカットの
確認は人に頼むか、メニューを開いて目で見る。

**合成 JSON で作る**（`Fixtures.swift`）。実クラスタに依存させると、手元の
クラスタの状態で結果が変わるうえ、異常系を作るのにクラスタを汚すことになる。

**テストは「そう書いてある」を確かめるためではなく、踏んだ間違いを固定するために
足す。** 上の表はどれも実際に壊れた（か、壊れうると分かった）ところ。

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

## 種別は「なぜ動かないか」を説明できるものを揃える

一覧を足す基準は、**運用中に「なぜ動かないのか」を説明する側に回るか**。
名前を並べるだけの一覧は増やさない。

| 種別 | 何を説明するか |
|---|---|
| PodDisruptionBudget | **drain を止めている当人。** アプリから drain できるのに、止めている当人が見えない、という状態にしない。一覧の「退避できる数」が 0 なら橙で出す |
| ResourceQuota | Namespace で作れない理由。**使用量と上限を並べる**（片方だけでは、あとどれだけ作れるか分からない） |
| LimitRange | requests を書いていないのに付いている理由、上限を上げたのに弾かれる理由。**種類（Container / Pod / PVC）まで書く** |
| StorageClass | PVC が Pending の理由。**「既定」を最初の列に出す**（既定が無い / 2 つある、が原因の大半） |
| PriorityClass | 追い出された理由。**横取りするかどうかも出す**（`Never` なら他を蹴らない） |
| EndpointSlice | Service に**実際に**何が繋がっているか。セレクタからの推測ではなく、コントローラが書いた事実。**0 を空欄にしない** |
| Validating / MutatingWebhookConfiguration | 作成が謎に失敗する理由。**失敗時の方針を出す**（`Fail` なら、落ちているあいだ対象の作成がすべて止まる） |
| APIService | `discoveryHint` が「ここを見ろ」と言っている当の場所。**Available=False** のグループは種別ごと一覧から消える |

**API グループを必ず付ける**（`poddisruptionbudgets.policy`、
`storageclasses.storage.k8s.io`）。短い名前は別グループと衝突する。

**設定タブは無理に用意しない。** 選ぶべき項目が決まっていない種別は
`SpecOutline`（木）に落ちる（CRD と同じ扱い）。空の設定タブが増えるより、
spec がそのまま見えるほうがまだ役に立つ。

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

### 状態の「なぜ」はイベントタブにしかない

一覧の STATUS 列も概要のリングも、**「異常である」ことまでしか言わない。**
`Pending` の理由（`FailedScheduling: insufficient cpu`）も `CrashLoopBackOff` の
発端（`Failed to pull image`）もイベントにしか出ないので、選択中のオブジェクトの
イベントを詳細パネルに置く（`EventsPane`）。**これが無いと、アプリの中では
「異常だ」で行き止まりになる**（実際そうなっていて、原因を見るにはターミナルで
`kubectl describe` を打つ必要があった）。

**一覧のイベントを手元で絞って使わない。** 概要が持っているのは直近 200 件だけで、
関係するイベントがその外にあると「ありません」と出る。無いのではなく引いていない。
`--field-selector` で**サーバ側で絞って引き直す**（`Kubectl.events(for:context:)`）。

**uid で引く。** 名前で引くと、同じ名前で作り直された前の世代のイベントが混ざる
（Pod は再作成のたびに uid が変わる）。Namespace を持たない Node / PV の
イベントは `default` に載るので、そのときだけ `--all-namespaces` にする。

**`--sort-by=.lastTimestamp` に頼らない。** `lastTimestamp` が無く `eventTime`
しか持たないイベントが実在する（orbstack の k3s で `Scheduled` がそうだった）。
kubectl は落ちないが、それを**時刻が無いものとして扱う**ので、さっき起きたのに
最古の位置へ並ぶ。`ResourceTable.lastSeen` は `eventTime` と
`deprecatedLastTimestamp` まで見るので、並べ替えは呼び出し側で持つ。

**時刻の formatter を 1 つで済ませない。** `eventTime` は `metav1.MicroTime` で
**必ず小数秒が付く**（`2026-08-06T04:12:33.123456Z`）。`ISO8601DateFormatter` は
`.withFractionalSeconds` の有無で読める形が**排他**になる（実測。無しの formatter は
小数秒付きを nil にし、付きの formatter は小数秒無しを nil にする）。片方しか
持っていなかったので `lastSeen` の `eventTime` の段が常に nil を返し、**上の対処が
1 度も効いていなかった。** しかも `creationTimestamp` に落ちるので、それらしい
別の時刻が出て気付けない。`K8sObject.date` が両方を順に試す（`TimestampTests`）。

**自動更新に載せない。** 開いているあいだ 10 秒ごとに引き直すと、読んでいる最中に
行が入れ替わり、選択があるかぎり kubectl が 1 本増え続ける。取り直しはパネルの
「再読み込み」が明示的に行う。**引き直しで前の結果を消さない** — 消すと一瞬空になり
「0 件になった」と読める。

**0 件を黙って「ありません」で終えない。** イベントには寿命があり（クラスタの既定で
1 時間）、古い出来事は本当に消える。断りが無いと「何も起きていない」と読めるが、
実際は「もう残っていない」かもしれない。ここも「無い」と「取れていない」を混ぜない
という同じ話で、**3 つ目に「消えた」がある**。

**対象の名前を行に書かない。** 選んでいるもの自身なので、見出しと同じ名前を 2 度
出すことになる（概要のイベント行は対象がばらばらなので書いている。持ち場が違う）。
そのぶん本文は折り返す。ここでは中身そのものが読みたいもの。**回数は出す** —
同じ行が 1 度きりなのか 200 回目なのかで意味がまるで違う。

## RBAC は名前だけ並べても何も分からない

5 種（ServiceAccount / Role / RoleBinding / ClusterRole / ClusterRoleBinding）を
**独立した節「アクセス制御」**に置く。「クラスタ」に混ぜるとノードや Namespace が
埋もれ、権限を追うときは 5 つを行き来するのでまとまっているほうが速い。

**API グループを必ず付ける**（`roles.rbac.authorization.k8s.io`）。`roles` という
複数形は別グループにも居る。ServiceAccount は core なので付けない。

**一覧で中身まで出す。** 名前だけ並べても「どの Role が強いのか」が分からず、
結局 1 つずつ YAML を開くことになる。Role / ClusterRole は
`ruleSummary`（`get,list → pods`）、Binding は参照ロールと対象を出す。

**`*` を並び順で沈ませない。** `*` は「なんでもできる」で、いちばん見つけたいもの。
名前順に混ぜると後ろへ流れるので先頭に固定し、その列だけ色を付ける
（`cluster-admin` は実際に `verbs: ["*"]`）。

**長い一覧を黙って切らない。** 頭だけ出して「他 N」と書く。切った事実が出ていないと、
それで全部だと読める。

**Subject の種別を落とさない。** 同じ名前の User と Group は別物。ServiceAccount は
**Namespace まで書く** — 落とすと、どの ServiceAccount か決まらない。

**規則は 1 つずつ出す**（設定タブ）。まとめると「どの動詞がどの資源に効くのか」が
混ざり、`get` できるのは Pod だけなのに Secret にも効くように読める。空の
`apiGroups` は core と書き換える（そのままだと空欄に見える）。

## 複数選択は「見えている選択」と「操作する対象」を揃える

**主役（`selectedObjectID`）は残したまま集合を足す。** 詳細パネル・ログ・履歴は
主役だけを見るので、そちらの経路は 1 つのままでよい。増えるのは「まとめて何かする」
ときだけ。

**`TapGesture().modifiers(_:)` を重ねない。** 修飾つきと素のタップを `exclusively` で
並べる書き方は、どちらが勝つかが状況で変わって取りこぼす。押された時点の
`NSEvent.modifierFlags` を聞くほうが確実。`onMoveCommand` も修飾キーを教えて
くれないので同じやり方にする（shift ＋ ↑↓ で伸ばす）。

**範囲選択の起点を主役と兼ねない。** 主役は shift のたびに動くので、それを起点に
すると選択範囲が引きずられて伸び続ける。`selectionAnchorID` を別に持つ。

**主役を外したら選び直す。** 選ばれていないものを詳細パネルが映し続けることになる。

**操作対象は `filteredObjects` から取る。** 絞り込みで画面から消えたものが選択に
残っていても、消してはいけない。**見えているものだけが対象。**

**種別を移ったら選択を捨てる。** 持ち越すと、見えていないものを選んだまま
「まとめて削除」を押せてしまう。

**選んでいないものを右クリックしたら、まずそれを選ぶ。** 選択と操作対象が食い違うと、
見えている選択とは別のものが消える。

**ただし、その選び直しをメニューの中身の前提にしない。** 選び直しは
`.onAppear` で走るが、**メニューの中身はそれより先に評価される**。以前は
メニューが `selectedObjects` を直に読んでいたので、3 件選んだ状態で未選択の行を
右クリックすると「3 件を削除」が出た。`ClusterStore.contextMenuTargets(for:)` が
選択の書き換えを待たずに対象を決め、選び直しは見た目を合わせるだけにする。

**確認に出したものを、そのまま消す。** `PendingAction.deleteMany` は捕まえた
配列を渡す（以前は `deleteSelected()` を呼んでおり、名前を並べた対象と押した
時点の選択が別物になりえた）。**確認と実行が同じものを指すこと。**

**選択の入口を 1 つにする。** 配置とたどるのタイルが `selectedObjectID` を
直に書いていたので、`selectedObjectIDs`（操作の対象になる集合）が空のまま
取り残されていた。一覧の行と同じく `selectOnly(_:)` を通す。

**複数選択中に 1 つ向けの操作を出さない。** 「ログを見る」がどれのログか決まらない。
まとめてできることだけを出し、**件数を必ず書く**（`削除… (3 件)`）。確認の文面にも
名前を並べる — 件数だけだと、何を選んでいたか確かめずに押すことになる。

**まとめて消すとき kubectl を 1 つずつ起こさない。** 選んだ数だけプロセスが立つ。
`-n` は 1 つしか渡せないので Namespace ごとにまとめる。**途中で止めない** — 1 つの
Namespace が拒まれても残りは消せる。全部試して、失敗したぶんだけを投げ、
**一部だけ消えたことを文面で言う**（全部失敗したのと見分けが付かないため）。

## 壊せる力に、安全側を釣り合わせる

削除・drain・patch・書き戻し・exec ができるようになった時点で、**「見るための
道具」ではなくなった。** 操作を足すたびに、次の 3 つが釣り合っているかを見る。

### どのクラスタを触っているか（`Models/ContextProfile.swift`）

**名前の文字列だけに頼らせない。** コンテキスト名はツールバーに小さく出るだけで、
prod と dev の見分けがそれしかない状態は事故の入口そのもの。コンテキストごとに
**色と別名**を持ち（`Preferences.contextProfiles`）、色を付けたものは窓の上に
帯を出す。`gke_project_asia-northeast1_prod` のような名前は帯に収まらないので、
別名を持てるようにしてある。

**色だけに意味を持たせない。** 帯には必ず名前を書く。**状態の 4 色と値を分ける**
（`Palette.color(for: ContextTint)`）—— あちらはクラスタが返してきた事実、
こちらは人が付けた札で、同じ赤でも意味が違う。

**帯を窓ぜんぶに差し込まない。** `NavigationSplitView` の外側に
`safeAreaInset(edge: .top)` を付けたら、帯がツールバーの下に潜り込んだうえ
**サイドバーの先頭の行（概要）を隠した**（実測）。詳細側にだけ掛ける。

**確認の文面にもクラスタ名を入れる。** 操作ごとに書くと足したものだけ書き忘れる
ので、`ResourceActionPresenter` が前に置く（確認を 1 か所にまとめてあるのと同じ理由）。

### 読み取り専用のコンテキスト

**「気をつける」で守らない。** 見るだけのつもりのクラスタでも全操作が押せる、
という状態をやめる。`ContextProfile.isReadOnly` を立てると、
`ResourceActionSet` が**クラスタを動かす操作をすべて落とす。**

**`group` で判定しない。** ログは `.primary` だが何も変えないので残してよい。
`ResourceAction.mutates` を別に持つ。**ここを見落とすと読み取り専用が穴のある
約束になる**ので、`SafetyTests` が「1 つも残らないこと」を種別ごとに見ている。

**exec は「読むだけ」に数えない。** 入ってしまえば中で何でもできる。

**他の設定の巻き添えで外さない。** `Preferences.resetAll()` に
`contextProfiles = [:]` が入っていたので、一般タブの「すべて既定値に戻す」で
**読み取り専用の指定が黙って消えていた**（確認の文面は「接続先のコンテキストや
Namespace の選択は残ります」で、消えることに触れていなかった）。札は
「見た目や既定値の設定」ではなく**そのクラスタに付けた印**なので、`resetAll()`
の対象にしない。消す口は設定の「コンテキスト」タブにだけ置き
（`clearContextProfiles`）、確認の文面で**読み取り専用が外れることを名指しする**。
`SafetyTests` が「戻しても札が残ること」を見ている。

**画面で隠すだけにしない。** `ClusterStore.refuseIfReadOnly` が、実際に kubectl を
起こす手前でも止める（`perform` / `applyYAML` / `patchResources`）。開いたままの
シートから届く道が残りうるため。**dry-run は止めない** —— 何も変えないので。

**できない理由を、できないことより先に出す。** 何も無いメニューが出ると、
壊れているのか権限が無いのか分からない。帯とメニューの先頭に理由を書く。

### 削除は種別ごとに連鎖を書く（`PendingAction.cascade`）

**「取り消せません」だけで済ませない。** ConfigMap を 1 つ消すのと、Namespace を
消して中身を全部消すのと、PVC をデータごと消すのとでは、取り返しのつかなさが
まるで違う。同じ文面だと、そのどれなのかが読み取れない。

**安心できることも書く。** 所有者のいる Pod は作り直される。そこを黙ると、
確かめれば分かることを怖がらせるだけになる。

**Namespace の削除だけは名前を打たせる**（`PendingAction.requiredPhrase`）。
クラスタでいちばん戻せない操作なのに、一覧の行はどれも同じ見た目で、押し間違いが
一瞬で終わる。**数を絞る** —— 何にでも求めると、読まずに写す作業になって意味が消える。
打ち込みは確認のダイアログでは受け取れないので、**同じ `PendingAction` のまま
出し方だけ分ける**（`TypedConfirmSheet`）。

## クラスタが動く操作は、押した瞬間に効かせない

**確認は 1 か所にまとめる**（`PendingAction`）。操作ごとに書くと、足したものだけ
確認を付け忘れる。実際、削除には確認があるのに**ローリング再起動と cordon は
素通り**だった。メニューは指が滑る場所なので、ここを直に繋がない。

**「よろしいですか？」で終わらせない。** 何が起きるかを書く。読まずに押す癖を
作るだけの確認は、何も守らない。

**危険度を段で分ける。** 削除は赤（`.destructive`）、再起動と cordon は普通の
ボタン。全部を赤にすると赤の意味が薄れる。

**cordon と drain を取り違えさせない。** cordon の文面に「いま載っている Pod は
そのまま動き続けます（退避は drain）」と書く。ここを黙ると、退避したつもりで
何も退避していない状態になる。

### 入口は 2 つ。出し分けは 1 か所（`Views/ResourceActions.swift`）

**右クリックの中だけに操作を置かない。** メニューは「そこに何かある」ことが
画面に出ていないので、drain も cordon もレプリカ数も**知っている人にしか
使えない操作**だった。詳細パネルは対象の名前が見出しに出ている場所なので、
そのすぐ下にボタンとして並べる（`ResourceActionBar`）。

**そのぶん、種別ごとの出し分けを 2 か所に書かない。** 一覧のメニューと詳細の
ボタンで別々に書くと、`PodLogRequest` の判定を 2 か所に持って**Job のログが
詳細からだけ開けなかった**のと同じ壊れ方になる。しかも足したときには気付けない。
`ResourceActionSet.actions(for:target:openLogWindow:)` の返す配列から、メニューも
ボタンも作る。`Tests/KubeDeckTests/ResourceActionTests.swift` で固めてある
（`OpenWindowAction` は外から作れないので、窓を開く先は**素のクロージャで
受け取る** —— そうしないと判定ごとテストから触れない）。

**確認とシートも画面ごとに持たない。** `ResourceActionHost` に集め、`RootView`
が 1 度だけ presenting する。画面ごとに `confirmationDialog` を持つと、同じ操作の
文面が 2 つになり、「足したものだけ確認を付け忘れる」余地が戻ってくる。

**ボタンに出すのはクラスタが動くものとログだけ。** 名前のコピーや選択の解除まで
並べると、肝心の操作が埋もれる（メニューには出す）。**名前は短く、正式な名前は
ツールチップに。** ただし cordon / drain は kubectl の語のまま出す —— 「止める」
「退避」と訳し分けても、押す側にはどちらがどちらか決まらない。

**増えたぶんだけ並べない。** 操作を足していったら Deployment で 7 個になり、
300pt の欄では 3〜4 段に折り返して**タブと中身を下へ押し出した**（詳細を見に来た
のに詳細が見えない）。**上限は 3 つ**、残りは「その他」のメニューに畳む
（`ResourceActionBar.visibleCount`）。畳んだものも一覧の右クリックには全部出る
—— 中身が同じ `ResourceActionSet` なので、抜け落ちようがない。

**`HStack` で並べない。** 詳細パネルは 300pt まで縮むので、3 つ並ぶだけで
1 つずつ潰れて読めなくなる。`ActionFlow`（`Layout`）で折り返す。ここでも
**幅が有限のときだけ折り返しを数える** —— SwiftUI は `.infinity` と `nil` を
提案してくるので、`Int(.infinity)` を作らない（`SectionColumns` で実際に落ちた）。

**複数選んでいるときはボタンも「まとめて」に切り替える。** 一覧の右クリックと
同じ判断（1 つ向けの操作は出さない・件数を書く）で、詳細パネルの断りも
「詳細はこの 1 件で、操作は N 件すべてに効きます」と書く。**見えている選択と
操作する対象を揃える**という同じ話。

**配置画面を蚊帳の外にしない。** あそこは一覧ではないので `currentTarget` は
nil だが、並べているのは Pod なので種別は決まっている（`ClusterStore.actionTarget`
が絞り込みと同じ既定に落とす）。逆に、**種別名が本当に決まらないときは
クラスタを動かす操作を出さない** —— kubectl に渡す名前が無いので、出しても
押して何も起きないボタンになる。

### requests / limits には専用の画面を持つ（`Views/ResourcesSheet.swift`）

**YAML の自由編集だけにしない。** ここはいちばん頻繁に触る値なのに、YAML では
**いちばん危ない直し方**になる（インデントを 1 つ間違えれば別の場所に書き込む）。
項目を決めて出せば、間違えようがない形にできる。

**`kubectl set resources` を使わない。** 実測で、あれは**外せない** ——
`--limits=cpu=0` は「0 という上限」を書き込むだけで、キーは消えない。

```
$ kubectl set resources deployment/demo --requests=cpu=0 --limits=cpu=0 --dry-run=server -o jsonpath='{...resources}'
{"limits":{"cpu":"0","memory":"0"},"requests":{"cpu":"0","memory":"0"}}
```

このアプリは「0」と「未設定」を**別のもの**として扱っている（分母が無ければ棒を
描かない、`上限 未設定（ノードの空きまで使えます）`）のに、書き戻す側でそれを
混ぜたら意味が無い。strategic merge patch なら `null` でキーが消え、しかも
**コンテナは名前で合う**（添字を数えなくてよい。実測）。patch の形は
`ResourcePatchTests` で固めてある。

**効く種別だけ出す**（`ResourcePatch.templatePath`）。**Job は出さない** ——
`spec.template` は immutable で、返ってくるのは spec 全体を貼り付けた長大な
エラー（実測）。ReplicaSet は直しても Deployment 側の世代が優先され、Pod は
作り直せば消える。**押せば失敗すると分かっているものを出さない。**
CronJob だけテンプレートの場所が 1 段深い（`spec.jobTemplate.spec.template.spec`）。

**変えていない項目を送らない。** 送っても結果は同じだが、確認に出す変更の一覧が
「触ってもいない行」で埋まる。前後の空白は落として比べる（`100m ` と `100m` を
別の値にしない）。

**数字を当てずっぽうで入れさせない。** 上限を決めるのに要るのは「いまどれだけ
使っているか」で、このアプリはもう持っている。欄の隣に出し（`kubectl top -l` と
同じ経路で、そのワークロードの Pod だけをサーバ側で絞って引く）、**上限が実測を
下回るときは押す前に言う** —— メモリならそのまま OOMKilled、CPU ならスロットル。
**平均を出さない。** 上限は「いちばん食う Pod」で決まる。

**打っている最中に kubectl を起こさない。** dry-run は手が止まってから
（0.5 秒）投げる。1 文字ごとに投げると、入力のあいだじゅうプロセスが立つ。

### YAML の編集は replace で書き戻す（`Views/YAMLEditSheet.swift`）

**設定タブを編集フォームにしない。** あれは意図的に**畳んだ表示**で、
`affinity` は「分散（希望）」まで畳み、Secret は文字数しか出さない。畳んだ値から
原文は復元できないので、そこに書き戻す口を付けると「見えている表示」と
「実際に送る中身」が食い違う。編集の入口は**原文のある YAML** だけにする。

**`apply` ではなく `replace`。** apply は `last-applied-configuration` との
3 方向マージなので、**画面から消した項目が消えないこと**がある。編集の入口
としては「見えている YAML がそのまま新しい姿になる」ほうが読み違えようがない。
replace は `resourceVersion` ごと送るので、**開いたあとに誰かが変えていれば
弾かれる**（実測）。逆に `resourceVersion` を落とすと無条件に上書きになるので、
**落とさない。**

**種別も Namespace も引数で渡さない。** YAML 自身が持っているものを kubectl に
読ませる（`replace -f -`）。渡すと食い違ったときに弾かれるだけで、CRD にも
そのまま効かなくなる。**一時ファイルに書かない** — Secret を編集したときに
中身がディスクへ残る。標準入力に流す。

**押す前に 2 つ見せる。** 差分（`Models/TextDiff.swift`）と、
`--dry-run=server` の答え。dry-run は admission webhook まで通したうえで、
実測で次を言う。**自前で検証を書かない。**

```
deployment.apps/demo replaced (server dry run)
Error from server (BadRequest): ... strict decoding error: unknown field "spec.replicasss"
The Service "svc-demo" is invalid: spec.clusterIPs[0]: ... may not change once set
Error from server (Conflict): ... the object has been modified; please apply your changes ...
```

**Conflict を他の失敗と混ぜない**（`Kubectl.isConflict`）。綴り間違いや immutable な
フィールドは**直せば通る**が、Conflict は中身が古いだけで**直す先が違う**（読み直す）。
しかも**status が動いているあいだは resourceVersion も動く**ので、ロールアウト中の
Deployment ではふつうに起きる。シートには常に「コピー」を置く —— 弾かれたときに
編集した内容を失わずに読み直せる唯一の道。

**差分は全文を並べない。** 1 行直しただけで 300 行の壁を出しても読まれない。
変わったところの前後 3 行だけを塊にする。**大きすぎるときは 1 行ずつの対応を
諦めるが、諦めたことを画面に書く**（`isCoarse`）。行番号は**ある側にだけ**付ける
（足された行に元の番号は無い）。`Tests/KubeDeckTests/TextDiffTests.swift`。

**`TextEditor` をそのまま使わない。** macOS の `NSTextView` は既定でスマート
引用符とダッシュの置き換えが効いており、`"foo"` が `"foo"` になる。YAML では
**黙って値が変わる**（あるいは構文が壊れる）。置き換えの類をすべて切った
`NSTextView` を自分で載せる（`CodeEditor`）。**折り返さない** — インデントが
崩れると構造が読めなくなる（ログとは逆の判断。あちらは 1 行が本文）。

**標準入力の書き込みを呼び出し側のまま行わない。** パイプのバッファ（64KB 程度）を
超えた時点で、相手が読む前に埋まって止まる。症状は「大きい YAML のときだけ固まる」で、
小さいもので試しているあいだは一度も出ない。別の実行単位で書き、**書いたら閉じる**
（閉じないと kubectl は入力の終わりを待ち続ける）。`ProcessInputTests` が 640KB で
押さえてある。**SIGPIPE も無視する** — 相手が読み切る前に終わると、既定の動作は
**プロセスの終了**、つまりアプリごと落ちる。

**戻されることを先に言う**（`Models/ManagedBy.swift`）。Argo CD / Helm / Flux の
下にあるものは手で書き戻しても次の同期で戻る。断りが無いと「書き戻しが効かなかった」と
しか見えず、原因をアプリの側に探しに行くことになる（HPA 管理下でレプリカ数を変える
ときと同じ扱い。**止めはしない**）。**汎用のラベルを管理元にしない** ——
`app.kubernetes.io/managed-by` は誰でも書けるので、値が `Helm` のときだけ Helm とみなす。

**Pod を編集させるときは、どこを直せばよいのかまで書く。** Pod の spec は
ほとんど変えられないうえ、変えられても作り直せば消える。直すのはふつう所有者のほう。

### rollout は restart だけでは足りない

**戻す手段を置く。** 更新を掛けられて再起動もできるのに戻せないと、悪い版を
出したときに打つ手がターミナルにしか無くなる —— いちばん急いでいる場面で。
`rollout undo`（`RollbackSheet`）と `pause` / `resume` を足してある。

**「1 つ前に戻す」だけにしない。** 悪い版が何回か続いていることはふつうにあり、
そのとき 1 つ前も同じく悪い。`rollout history` の世代を選べるようにし、
**`change-cause` も出す**（番号だけ並べても、どれに戻すのか決まらない）。
既定は 1 つ前 —— `--to-revision` を付けないときの kubectl と同じ。

**戻る先の中身も、戻したら何が起きるかも kubectl に答えさせる**（drain と同じ）。
`rollout history --revision=N` の出力をそのまま出し、`undo --dry-run=server` の
答えを添える。実測で、この dry-run は次を**押す前に**言う。

```
deployment.apps/demo rolled back (server dry run)
deployment.apps/demo skipped rollback (current template already matches revision 2)
error: you cannot rollback a paused deployment; resume it first with 'kubectl rollout resume' ...
error: unable to find specified revision 9 in history
```

自前で「同じ版だから何も起きない」を判断すると、kubectl の判断とずれる余地を
作るだけ。書式に依存する `rollout history` の読み取りは `KubectlTests` で固めてある
（**見出しの位置で切らない** —— `CHANGE-CAUSE` は人が書く文なので空白が入る）。

**pause を `supportsRollout` と同じ集合にしない。** 実測で StatefulSet と
DaemonSet は `pausing is not supported` を返す（`supportsRolloutPause` は
Deployment だけ）。同じにすると、押すと必ず失敗するボタンを出すことになる。

**止めたことの見え方を黙らない。** 止めた Deployment は `kubectl get` でも
一覧でも `1/1` のまま健全に見えるのに、設定を変えても Pod は入れ替わらない
（HPA の `<unknown>` と同じ「数字が揃ったまま何もしていない」）。しかも
**止めているあいだはロールバックもできない。** 確認の文面に両方書く。
状態そのものは詳細パネルの「条件」に出る（`Progressing / Unknown /
DeploymentPaused`）ので、**別の行を足して二重に出さない。** ボタンの文言が
「更新を再開…」に変わることが、その場のしるしになる。

確認は、2 世代ある Deployment を作れば足りる。**確かめたら消すこと。**

```bash
kubectl create namespace kubedeck-rollout
kubectl create deployment demo --image=registry.k8s.io/pause:3.9 -n kubedeck-rollout
kubectl set image deployment/demo pause=registry.k8s.io/pause:3.10 -n kubedeck-rollout
kubectl annotate deployment/demo -n kubedeck-rollout \
  kubernetes.io/change-cause="pause 3.10 に上げた" --overwrite
```

### drain の確認は kubectl に答えさせる

**Pod の数を自分で数えない。** 退避できるかは PodDisruptionBudget や DaemonSet の
有無で決まる。こちらで「Pod が N 個あります」と書いても、kubectl が実際にやることと
ずれる。`--dry-run=server` に**同じ判断をさせて**、返ってきたものをそのまま出す
（`DrainSheet`）。dry-run はノードを cordon しない（実測で `spec.unschedulable` は
空のまま）。

**`--force` と `--delete-emptydir-data` を既定にしない。** 前者は管理下にない Pod
（消しても作り直されない）を消し、後者は emptyDir の中身を捨てる。どちらも戻せない
ので押した人に選ばせる。既定のままだと drain は止まるが、**止まるほうが黙って消すより
よい。**

**止まったことを失敗として隠さない。** 既定では終了コード 1 で
`cannot delete Pods with local storage (use --delete-emptydir-data to override): ...`
が返る。これは**まさに読みたい文面**（どのトグルが要るかが書いてある）なので、
そのまま見せて「このままでは止まります」と添える。

**`--ignore-daemonsets` は既定で付ける。** DaemonSet の Pod はそもそも退避できず
（消しても同じノードに作り直される）、付けないと drain は必ず止まる。選ばせても
選べる答えが 1 つしかない。

**`--timeout` を必ず付ける。** 既定は 0（無制限）で、退避できない Pod が 1 つあると
待ち続ける。`run` のプロセス上限で殺すこともできるが、それだと「こちらが殺した」に
なり、kubectl 自身の理由が残らない。**`requestTimeout` は `"15s"` と単位込み**なので
`s` を足さないこと（`--timeout=15ss` は `unknown unit "ss"` で弾かれる。実際に踏んだ）。

## 操作が通ったことを黙らない

以前は**失敗のときだけ**帯を出していた。成功は無言なので、次のように見えた。

- 削除は `--wait=false` で投げるので、押しても行が残る（しばらく Terminating）
- ローリング再起動は見た目が何も変わらない
- レプリカ数の変更は、次の取得までセルが古いまま

どれも「押せていない」と読めるので、**もう一度押すことになる**。`ClusterStore.perform`
が成功時に `actionNotice` を立て、`RootView.noticeBar` が数秒だけ出す。

**やったことより多く言わない。** 要求を投げただけのものは「要求しました」。
`削除しました` と書くと、残っている行のほうが間違いに見える。いまの文言は
「削除を要求しました。消えるまで少しかかります」「ローリング再起動を始めました」。
ここも「やった」と「頼んだ」を混ぜないという、いつもの話。

**エラー帯と同じ見た目にしない。** あちらは赤い縁で留まり続け、読んで対処するもの。
こちらは数秒で消える丸い札で、「効いた」と分かればよいもの。同じ形だと
「また何か起きた」と身構える。

**閉じる操作を付けない。** 自分で消えるものに ✕ を置くと、押す前に消えて押し損ねる。
`allowsHitTesting(false)` にして、下の一覧の操作も邪魔しない。

**失敗したら前の成功を消す。** 残っていると、成功と失敗のどちらの話か分からない。

**`.animation` を消える側に付けない。** 出入りを animate させるには、残っているほう
（overlay を持つ親）に置く必要がある。札そのものに付けても除去は animate されない。

## 絞り込みはラベルまで見る。ただしセレクタは実装しない

**素の部分一致だけでは足りない。** Kubernetes はラベルで全部が動くのに、名前の
一部でしか探せないと「この Deployment の Pod だけ」が出せない。`SearchTerm` が
よく打つ形だけを読む（`Models/ResourceTable.swift`）。

| 打つもの | 意味 |
|---|---|
| `app=nginx` | ラベルが**完全一致** |
| `app=` | そのラベルを持っている |
| `ns:kube-system` / `status:CrashLoopBackOff` / `node:node-a` | 場所を指定 |
| それ以外 | これまでどおり名前・Namespace・ラベル・各セルの文字 |

**本物のセレクタを実装しない。** `in (a,b)`・`notin`・`!key` まで持つと、絞り込み欄
1 つのために式の評価を背負う。CRD の表示列で `[?(@.type=="Ready")]` を切ったのと
同じ判断。

**ラベルの値は完全一致。** 前方一致にすると `env=prod` が `env=production` を拾い、
**絞り込んだつもりで絞れていない**状態になる。セレクタの語彙なので完全一致が正しい。

**知らない語の `:` は素の文字に落とす。** `nginx:1.21`（イメージのタグ）を
「nginx という場所」と読むと、打った文字がどこにも効かないまま 0 件になる。
`Field(keyword:)` が知っている語のときだけ場所として扱う。

**空白区切りは AND。** `app=web crash` のように「絞ってから探す」のがふつうの
使い方で、OR にすると項目を足すほど結果が増える。

**状態は `StatusResolver.status` を通す。** phase を直接見ると、`Running` のまま
CrashLoopBackOff になっている Pod が `status:crash` で出てこない。

**書き方は空状態で教える。** 語彙を知りたいのは、うまく絞れていないとき。欄の脇に
常に出すと、ふだんはただの飾りになる。**できることだけを書く** — 出していない形
（`!key` など）を書くと、効くと思わせる。

**絞り込みは 1 度だけ組み立てる**（`ResourceSearch`）。以前は `filter` の中から
`ResourceTable.matches(_:target:query:)` を呼んでおり、**1 件ごとに**
`SearchTerm.parse` と列定義の構築が走っていた（列は 1 件あたり全列ぶんの JSON を
辿る）。どちらも問い合わせと対象が同じなら結果も同じなので、外で 1 つ作って回す。
`ResourceTable.matches` は 1 件だけ見るときのために残してあるが、**一覧を絞るのに
使わない。** 列は素の文字の項があるときだけ組み立てる。

## HPA は「数字が揃ったまま何もしていない」ことがある

レプリカ数を決めているのは Deployment ではなく HPA なので、**ワークロードの節に
並べる**（`ResourceKind.horizontalPodAutoscaler`）。隣に無いと、なぜ数が動くのかを
辿れない。

**`<unknown>` を 0% と書かない。** requests が設定されていない対象に HPA を付けると、
kubectl は `cpu: <unknown>/75%` と出す。これは「使用率が 0」ではなく「指標が取れて
いない」で、**HPA は何もしていない**。0% と書くと「まだ余裕がある」と読め、
いちばん見つけたい壊れ方が消える。`ResourceTable.hpaTargets` は `—` を返し、
`hasUnknown` で列にしるしを付ける。ここも「無い」と「取れていない」を混ぜない話。

**数だけ見て「正常」にしない。** 上の状態でも `REPLICAS` は `2/2` で揃っており、
一覧の数字はまったく健全に見える。`StatusResolver.hpaStatus` が `ScalingActive` /
`AbleToScale` の条件を読み、`FailedGetResourceMetric` のような**理由をそのまま
STATUS 列に出す**（理由のほうが対処に直結する）。**条件が無いことは異常にしない** —
`autoscaling/v1` は conditions を持たない。

**API グループを付けて引く**（`horizontalpodautoscalers.autoscaling`）。`autoscaling`
は v1 と v2 が併存し、短い名前だと環境によって別のバージョンを引く。読む側は
**両方の形に対応する** — v2 は `spec.metrics` / `status.currentMetrics`、v1 は
`spec.targetCPUUtilizationPercentage` / `status.currentCPUUtilizationPercentage`。

### レプリカ数を変える前に HPA を見る

**`kubectl scale` は HPA 管理下でも通る。そして次の調整で戻される**（既定 15 秒）。
断りが無いと「効かなかった」としか見えず、原因がアプリ側にあるように読める。
`ScaleSheet` は開いたときに `Kubectl.autoscalers(for:context:)` を引き、管理下なら
最小 / 最大とともに「次の調整で HPA が戻します」と出す。

**止めない。** 調整を待たずに増やす、いったん 0 にする、はどれも正当な操作。
禁じるのではなく、戻ることを先に言う。

**4 つの状態を 1 つにしない。** 「まだ調べていない」「管理下にある」「管理下にない」
「調べられなかった」。特に後ろ 2 つを混ぜると、権限が無くて見えないだけなのに
**「HPA は無い」と断定する**。管理下でないことは書かない（ふつうがそちらなので、
毎回出すと読まれなくなる）。

**対象は名前と種別で突き合わせる。** `scaleTargetRef` は uid を持たない（HPA は
「その名前のもの」を指す作りで、作り直しても追随する）。種別まで見るのは、同じ名前の
Deployment と StatefulSet が同居できるため。

確認は、requests を設定していない Deployment に `kubectl autoscale` を付けると
そのまま作れる。`ScalingActive=False` が出るまで 30 秒ほどかかる。
**確かめたら消すこと。**

## 設定は `Models/Preferences.swift` に集める

保存する値はすべてここ。以前は `ClusterStore` の中の private enum に散らしており、
項目を足すたびにストアを触ることになっていた。**新しい設定をストアや画面に
直接置かない。**

項目を足すときは 3 つ揃えるだけ。

1. `Key` に保存キー
2. 既定値付きの格納プロパティ（`didSet` で書き戻す）
3. `SettingsView` に行

`resetAll()` にも足すこと。足し忘れると「すべて既定値に戻す」がその項目だけ残す。
**ただし `contextProfiles` は入れない**（「読み取り専用のコンテキスト」の節を参照。
安全側の札を、他の設定の巻き添えで外さない）。

**画面に出す文言を、設定の値と別に持たない。** 推移の範囲は 15〜180 分から
選べるのに、概要のカードと詳細パネルの見出しが「30 分」固定になっており、
変えてもラベルだけ嘘のままだった。書式は `Preferences.windowLabel(minutes:)` の
1 か所が持ち、設定画面の選択肢も同じものを読む。

`@Observable` なので画面は `Preferences.shared` を読むだけでよい。

**MainActor の外から読む値は写しを置く。** 一覧のセルを作る閉包は nonisolated なので、
使用率のしきい値は `Preferences.usageThresholds`（`nonisolated(unsafe)`）へ変更のたびに
publish している。同じ必要が出たら同じやり方にする。

**互いに縛りのある値は、片方を動かしたらもう片方を押し出す。** 使用率の
「注意」と「異常」がそれで、`usageLevel` は critical から先に見るので、
注意 90 / 異常 80 を許すと**警告色が一度も出なくなり**、80% 超がいきなり赤になる。
壊れはしないが黙って意味が変わる。didSet で押し出すと相互に呼び合うが、
押し出した先では条件が成り立たないので 1 往復で止まる。

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
- Pod は **limits**。無ければ requests に落とす。
- 分母が取れないときは棒を描かない。`0%` と描くと「まだ余裕がある」と読めてしまう。

**requests を分母にしない（上限があるなら）。** 以前は requests に固定していたが、**健全な Pod が軒並み赤くなった。** 要求 4.1Gi / 上限 9.0Gi の Pod が 4.8Gi 使っているだけで 118% の赤になる。要求は「置き場所を決めるための申告」であって上限ではないので、超えること自体は異常ではない。**殺されるのは上限を超えたとき**（メモリなら OOMKilled、CPU ならスロットル）なので、棒と色はそこまでの距離を表す。

**要求は棒の上の目盛りで示す。** もう 1 本棒を出すと同じ量を 2 度描くことになり、どちらの分母を見ているのか分からなくなる。1 本の上に印を置き、下の行で `要求 70Mi（51% 使用）` と書く。目盛りは 6pt の棒では潰れて見えないので、棒を 8pt にしてある。

**上限が無い Pod には色を付けない。** 超える先が無いので、要求比で赤くしても意味が無い。ノードの空きの話になり、それは Node の行が持っている。

**分母が何なのかを書く。** 数字だけ並べると requests と limits と allocatable のどれを見ているのか分からない。詳細パネルは `36Mi / 上限 340Mi`、`120m / 割り当て可能 8` と書く。

**未設定を空欄にしない。** requests が無ければスケジューラは置き場所を決める根拠を持たず、limits が無ければノードの空きまで使える。どちらも「設定されているが 0」とは意味が違うので、`上限 未設定（ノードの空きまで使えます）` と書いて橙で出す。

**補足は自分の棒に寄せる。** 上下を同じ間隔（6pt）で並べたら、CPU の「上限 …」がメモリの見出しと等距離になり、どちらのものか分からなかった。棒と補足のあいだを 3pt、計器どうしのあいだを 13pt にしてある。

**一覧では「取れていない」と「未設定」を分ける。** 使用量が引けないセルは `—`、使用量はあるが requests が無いセルは `1m / 未設定`。前者は metrics-server の話、後者は Pod の書き方の話で、見る場所が違う。

**Pod 合計を出す。** スケジューラが見るのも上限に当たるかを決めるのも Pod 単位の合計なのに、設定タブはコンテナごとの値しか出していなかった。複数コンテナの Pod では読み手が足し算することになる。`資源（Pod 合計）` を設定タブの先頭に置く（いちばん探される項目で、下に置くと配置や権限をかき分けることになる）。初期化コンテナは同時に動かないので合計に入れない — `containerResourceTotal` と揃えること。**ずれると 2 か所で違う数字が出る。**

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

**覚えるのはコンテキストごと。** 1 つのキーに 1 つだけ入れていたので、A → B と
切り替えるたびに B の結果（見つからなければ nil）で上書きされ、A に戻ると
また全 Service を順に叩く探索からやり直しになっていた（覚えている意味が半分
無くなっていた）。`Defaults.prometheus(for:)` / `setPrometheus(_:for:)`。
**見つからなかったことは覚えない** —— 次に開いたときは探し直す。

**全 Namespace が引けないクラスタで諦めない。** 候補集めは `get services --all-namespaces` から始めるが、Connect Gateway 越しの GKE や 1 つの Namespace にしか権限が無い環境では、ここが拒まれる。そこで nil を返すと、Prometheus が入っていても永久に見つからず、**概要の使用量が棒のまま（推移の折れ線が出ないまま）になる。** `metricsServerAvailable` と同じく、全 Namespace → 選択中の Namespace の順に試す。それでも届かないところは設定から手で指定できる（`useManualPrometheus`）。

**指標の出どころは環境で変わる。** kube-prometheus-stack は kubelet の cAdvisor（`/metrics/cadvisor`）を拾うが、orbstack の k3s ではそこに `machine_*` しか出ておらず、コンテナ単位の値は `/metrics/resource` にある。**幸い指標名は同じ**（`container_cpu_usage_seconds_total` / `container_memory_working_set_bytes`）なので、クエリは両対応で書ける。node 単位の集計は `node` ラベルに依存し、これは scrape 側の relabel 次第で在ったり無かったりする。

**履歴の取得間隔は一覧と分ける。** 範囲クエリは 1 回につき kubectl を 1 本起こす。自動更新（既定 10 秒）に合わせると 4 本増える。30 分幅のグラフにその頻度は要らないので 60 秒間隔。選択が変わったときだけ間隔を無視する。

**時系列の線に状態の 4 色を使わない。** 使うと、ただの CPU の線が「異常」の意味を帯びる。系列色は別枠（`Palette.seriesCPU` / `seriesMemory`）。

**同じ系列を、取得元の違いで別の色にしない。** 概要の使用量は履歴が取れれば折れ線、取れなければ棒になる。棒だけ状態の色にしていたので、**同じカードが環境によって緑にも青赤にも見えた**。`UsageBar` に `tint` を渡し、概要では折れ線と同じ系列色で塗る。しきい値超えは割合の文字の色が持つ。

**ただし Pod と Node の使用率の棒は状態の色のまま。** あちらは「上限にどれだけ近いか」が主役で、系列という考え方が無い（`tint` を渡さない）。

## 同じ数字を 2 度出さない

画面が散らかる最大の原因は重複だった。整理したときの持ち場は次のとおり。**ここを崩して同じ値を足さない。**

| 情報 | 持ち場 |
|---|---|
| 種別ごとの件数 | サイドバーの行末（概要にタイルを並べ直さない） |
| コンテキスト名・全体の状態 | 概要の見出し |
| Namespace | ツールバー |
| バージョン・更新間隔・最終更新 | 右パネル |
| 一覧の件数 | ウインドウの副題 |

### 面の作りを揃える

カードは 1 種類だけ（角 14pt・`Palette.cardStroke` の縁・`cardShadow` の影）。
概要も配置も同じ値を使う。**画面ごとに角の丸みや縁の濃さを変えない** — 同じ
アプリの中で作りが違うように見える。

**影は 1 段だけ。** 段を重ねると画面がぼやける。カードの中で沈めたい面
（見出しのしるし、入れ子の行）は影ではなく `Palette.insetFill` の重ねにする。
**不透明な色を足さない** — 外観設定とアクセントカラーの組み合わせで浮く。

**添え物は札にする。** 件数のような値を本文と同じ字面で並べると、どこまでが
見出しなのか分からない。`CountPill` に入れて丸く囲む。色を付けるのは意味が
あるときだけ（固まっているノード数など）。

### 図の部品（`Views/ResourceGlyph.swift`）

Kubernetes の構成図の作りに合わせる。器は**七角形**（`Heptagon`）に種別の
記号を入れたもの、範囲は**囲みの箱**（`DiagramBox`）で見出しを枠線に重ねる、
つながりは**矢印**（`DiagramArrow`）。

**舵輪（`KubernetesLogo`）と混ぜない。** あちらは「これは Kubernetes を見て
いる」というしるしで公式ロゴそのもの。七角形は図の中で種別を表す器で、
中に入れる記号のほうが意味を持つ。

**器の色を状態に使わない。** 種別と状態は別の話で、器を状態色で塗ると種別が
読めなくなる。状態は右上の小さなしるしで示し、正常なときは付けない
（合格印で埋め尽くさない）。

**器の色をアクセントカラーに預けない。** 既定を `Color.accentColor` にしていたら、
アクセントにグラファイトを選んでいる環境で**七角形も囲みも全部灰色になった**
（別のマシンで撮った画面で判明）。図の青は「これは Kubernetes の構成図だ」という
しるしなので、状態の 4 色と同じく外の設定で振らせない（`Palette.diagram`）。
**選択の色は逆にアクセントのまま。** あちらは OS の作法に合わせる場所で、
一覧やタイルの選択が系統の違う色になるほうがおかしい。

**見出しを囲みの中に入れない。** 枠線の左上に重ねる。中に入れると、囲まれて
いるものの 1 つに見える。

**罫線の文字で図を描かない。** `├─` のような等幅の記号は本文の字送りと合わず、
行ごとにずれる。太さも外観設定で変わらない。

**自動でレイアウトしない。** 段は「入口 → ワークロード → 世代 → Pod → ノード」で
決まっているので、列に並べるだけでよい。線を自由に引く仕組みを持つと、
図のためだけにレイアウトの実装を抱えることになる。矢印は行の中の決まった
向きにだけ引く。

**欄の幅は `width` ではなく `maxWidth` で決める。** `frame(width:)` は
**縮められない最小幅**になり、詳細の欄がまとめて窓より広がる。そうなると
`NavigationSplitView` の列が押し出され、**サイドバーの左端と詳細パネルの右端が
両方とも切れる**（この画面でだけ起きた）。上限にすれば狭い窓では縮んで収まる。

ただし、いちばん後ろに置く文字（行き先のノード名）には `minWidth` を残す。
無いと伸び縮みの中でそこから潰れ、矢印の先が空になる。

**個々の欄を上限にしても、まだ足りない。** 段が 5 つ並ぶので、残った最小幅
（器の大きさ・`minWidth`・起点の一覧）を足しただけで詳細の欄より広くなることが
ある。そのまま伝えれば結果は同じで、**サイドバーの左端が切れる**（1367pt 幅・
詳細パネルを出した状態で再発した。「ワークロード」が「ドロード」になった）。
`TraceMapView` の外側で `frame(minWidth: 0, maxWidth: .infinity)` + `clipped()` を
掛け、**最小幅そのものを外へ伝えない。** 起点の一覧も `frame(width: 236)` から
`minWidth: 176` に変えてあり、狭いときは図より先にこちらが詰まる。

使える幅は実測できる。`GeometryReader` の `proxy.safeAreaInsets` に
サイドバーと詳細パネルのぶんが入っているので、`leading` / `trailing` を
引いた残りがこの画面の持ち分（この窓なら 1367 − 238 − 360 = 769）。
**目分量で足し合わせない。**

**`List` を横に並べない。** macOS の `List` も自前で最小幅を要求する。図の左の
一覧は `ScrollView` と自前の行にしてある。

**横スクロールにしない。** `ScrollView([.horizontal, .vertical])` の中では
`Spacer` と `maxWidth: .infinity` が無限に伸び、**図がまるごと消える**
（実際そうなった）。縦だけにして、欄の幅で収める。

### 関係は自分で結ぶ（`Models/WorkloadRelations.swift`）

Service・Ingress・PVC とワークロードのつながりは API に無いので、取ってきた
オブジェクトどうしを突き合わせる。Service は `spec.selector` がラベルに一致する
Pod を掴み、Ingress は backend の名前で Service を指し、Pod は
`volumes[].persistentVolumeClaim` で PVC を使う。

**セレクタが空の Service を一致させない。** 空は「すべてに一致」ではなく
「まだ何も選んでいない」で、通すとすべての Service がどのワークロードにも付く。

**見つからないことを失敗にしない。** Service を持たないワークロードはふつうに
あり、無いことは異常ではない。**空の器も置かない** — 置くと「あるはずのものが
欠けている」ように見える。

### 名前だけで束ねない（配置全体）

**別の Namespace に同じ名前の Deployment / ReplicaSet があるのはふつう。**
名前を `id` にしていたら、**無関係な 2 つのワークロードが 1 つの箱に合体した**
（`kubedeck-test-a/dup-test` と `kubedeck-test-b/dup-test` を作って再現）。
`Spread` / `Workload` / 世代の集計は `Namespace/名前` を鍵にする。同名が並ぶので、
一覧と見出しには Namespace を添える。

`ForEach` の `id` が重なると SwiftUI は行を取り違える。**種別をまたいで名前を
鍵にしない。**

### 一覧の選択を `onAppear` だけで初期化しない

読み込みが終わる前に画面を開くと一覧が空で、そのまま何も選ばれず右が空で固まる。
`onChange(of:initial:true)` にして、**一覧が変わるたびに選択が有効かを見直す**
（消えたものを選んだままにもしない）。「たどるが崩れるときがある」というのは
この時間差だった。

確認は、同名のワークロードを 2 つの Namespace に作って開く。
`kubectl create namespace ...` と `create deployment ... --image=registry.k8s.io/pause:3.9`
で足りる。**確かめたら消すこと。**

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

## 配置の画面（`Views/PlacementView.swift`）

どの Pod がどのノードに載っているか。一覧の「ノード」列でも同じことは分かるが、
**列の文字を目で数えないと偏りが見えない。** ノードを箱にして Pod をタイルで
並べる。

`Selection` に `.placement` を足してあり、種別の一覧ではないのでサイドバーでは
クラスタの節に入れず概要の隣に置く。

**Pod とノードは 1 回の kubectl でまとめて取る。** 別々に投げると片方だけ新しい
状態が混ざり、同じ時点の絵にならない。

**Pod が 0 のノードも出す。** 空いているノードが見えないと、偏りの片側
（受け入れ先があるのに寄っている）が分からない。

**スケジュールされていない Pod をノードの箱に混ぜない。** 最後に「未スケジュール」
としてまとめる。混ぜると「どこかに載っている」ように見える。

**件数と使用率は文字でも出す。** タイルの数を目で数えさせない。使用率が取れない
ノードは行ごと出さない（`0%` と書かない）。

Pod は `objects` に、ノードは `placementNodes` に入れる。Pod を `objects` に
置くのは、検索（`filteredObjects`）と選択（`selectedObject`）を一覧と同じ経路に
載せるため。タイルを押すと右のパネルにその Pod が出る。

### 見え方は設定で選べる

環境によって Pod の数が 10 と 222 で違い、1 つの塩梅では収まらない
（`Preferences` の `placement*`）。

- **タイルの大きさ** — 小 / 中 / 大。**小は名前を出さない。** 数百の Pod を
  名前つきで並べると縦に伸び、「どこに寄っているか」という肝心の絵が見えなくなる。
  そのぶん名前と状態は指したときに出す（形と色だけで意味を運ばせない）。
- **ノードの並び** — 名前順 / Pod が多い順 / 使用率が高い順。**使用率が取れない
  ノードは末尾へ。** 0 とみなして上に出すと「使っていない」と「測れていない」が混ざる。
- **棒が表すもの** — CPU とメモリ（既定）/ CPU / メモリ。CPU で詰まる環境と
  メモリで詰まる環境があり、片方しか見ないなら並べても場所を食うだけ。
- **ワークロードでまとめる** — ノード別のときだけ効く。既定は入り。Pod が少ない
  クラスタでは、まとめないほうが縦に縮む（所有者ごとに 1 行になるため）。
- **Pod が 0 のノードを隠す** — 既定は出す。隠すと縦は縮むが、受け入れ先が
  空いていることは見えなくなる。

**見方（ノード別 / ワークロード別 / たどる）は設定に置かない。** 画面の上の
切り替えで選ぶ。行き来しながら見るもので、そのたびに設定を開くのでは使えない。
設定に残すのは、いちど決めたら変えない類のものだけ。**値の持ち場は `Preferences`
のままで、置き場所だけが違う。**

**逆に、見方でないものを切り替えに置かない。** 一度「ノード別」と
「ノード別・まとめ」を別の見方として並べたが、**箱も答える問いも同じで、中の
並べ方が違うだけ**だった。選ぶときに迷うだけなので、設定のトグルに戻した。
切り替えに並べてよいのは、**答える問いが違うもの**だけ。

### 見方は 3 つ。どれも代わりが無い

| 見方 | 答える問い | ここにしか無いもの |
|---|---|---|
| ノード別 | このノードは混んでいるか | ノード単位の集計と使用量 |
| ワークロード別 | どれがどこに散っているか | 集中しているものを**全部まとめて**見つける |
| たどる | この 1 つはどう繋がっているか | 入口（Service / Ingress）・世代・ストレージ |

**「たどる」の起点はワークロードだけではない。** 知りたいことは「この Ingress の
先に何があるか」「この Service は何を掴んでいるか」「このノードに載っている
ものは何に繋がっているか」でも起きる。**それぞれに別の見方を足さない** —
どれも同じ鎖（入口 → ワークロード → 世代 → Pod → ノード）の別の場所を掴んだ
だけで、答える問いは「どう繋がっているか」の 1 つ。見方は 3 つのままで、
起点の種別を左で選ぶ（`TraceAnchorKind`）。

**「たどる」で「ワークロード別」は代わりにならない。** たどるは 1 つずつなので、
「どのワークロードが 1 ノードに固まっているか」を探すことができない。

**ノードを箱にするだけでは足りない。** それだと「このノードに何が載っているか」
（混み具合）は分かるが、「この Deployment がどこに散っているか」（冗長性）は
ノードの箱をまたいで目で追うことになる。`PlacementGrouping.workload` は
ワークロードを箱にし、その中をノードで割る。

**固まっていることを色だけで言わない。** 2 つ以上あるのに 1 つのノードに全部
載っている状態は、この画面でいちばん見たいものなので文字で書き、並びの先頭に
出す（`Spread.isConcentrated`）。

**1 個しかないものを固まっている扱いにしない。** レプリカ 1 の Deployment は
そもそも散らしようがなく、警告にすると画面が警告で埋まる。

### 使用量は箱の中に出す

**右のパネルに追い出さない。** 「このノードは混んでいるか」は配置を見る目的
そのもので、行を選ばないと分からないのでは遅い。ノードの箱に CPU とメモリの棒を、
Pod のタイルに細い棒を出す（上限に対する割合、無ければ要求。一覧や詳細と同じ順序）。

**タイルの棒は 1 本だけ。** 何を出すかは設定（`placementMetric`）で選び、
「CPU とメモリ」のときは詰まっているほうを出す。2 本並べてもこの大きさでは
読めない。両方の実測値はタイルを指せば出る。

#### ワークロードの合計も同じ場所に出す（`MetricsSnapshot.workloadUsage(of:)`）

使用率が引けるのは Pod と Node だけで（`MetricsSnapshot.usage(for:)` は
それ以外で nil を返す）、**「この Deployment が合計でどれだけ食っているか」を
答える場所がどこにも無かった。** 一覧の CPU 列を目で足すことになる。

**取りに行かない。** ワークロード別の箱はすでに Pod と所有者の対応を解いて
おり（`controllerIndex`）、Pod ごとの実測も手元にある。足し上げるだけなので
kubectl は 1 本も増えない。**分母は Pod と同じ規則**（上限、無ければ要求。
初期化コンテナは足さない）。ノードの割り当て可能量とは別物なので、`/ 上限 600m`
と呼び名を添える（Pod ごとに違えば「上限・要求」と書く）。

**合計と割合の対象を揃える。** 使用量を引けなかった Pod は、分子にも分母にも
入れない。分母にだけ入れると、引けていないぶん割合が低く出て「まだ余裕がある」と
読める。そのかわり **何個ぶんの合計なのかを書く**（完了した Job の Pod は
metrics に出ないので、実際にここへ来る）。

**分母を持たない Pod が混ざったら割合を出さない。** そのぶん分母が小さいので、
割合は必ず高いほうへ外れる（余裕があるのに赤く見える）。合計は出せるので、
諦めるのは割合だけ。**軸ごとに別に見る** —— メモリにだけ上限がある書き方は
ふつうにある。`WorkloadUsageTests` で固めてある。

**棒は 1 か所で描く**（`PlacementUsageBar`）。ノードとワークロードで別々に
書くと、同じ画面の同じ問いなのに箱ごとに作りが違って見える。

### たどる（`PlacementGrouping.map` / `Views/TraceMapView.swift`）

起点を 1 つ選び、入口から Pod、ノードまで図にする。

**全部を一度に描かない。** 222 Pod を線でつないだ図は、線の数が多すぎてどこから
読めばいいのか分からなくなる。左で 1 つ選び、それだけを展開する。

**木ではなく図にする。** 木は階層を表せるが、「Namespace の中に Deployment が
あり、そこから Pod が出て、それぞれ別のノードに載っている」という**入れ子と
行き先**が同時には見えない。七角形の器・囲みの箱・矢印で組む
（`Views/ResourceGlyph.swift`）。

**Pod が 0 の ReplicaSet も出す。** 入れ替わりの途中や、古い世代が残っている
ことが分かる。ここでは**世代が見たい**ので、`ReplicaSet` 名はハッシュ付きの
まま出す（束ねるときとは逆で、`PlacementView.owner` は使わない）。

#### 起点が 7 種類あっても、図は 1 つ（`Models/PlacementTrace.swift`）

起点ごとに違うのは**「掴んでいる Pod をどう解くか」だけ**。ノードなら
`spec.nodeName`、Service ならセレクタ一致、Ingress なら backend の Service 経由、
PVC なら `volumes[].persistentVolumeClaim.claimName` の逆引き、PV なら PVC を
経由してもう 1 段。解いた Pod をワークロードごとの枝に束ね直せば、あとはどの
起点からでも同じ図になる。**描く側に起点の分岐を持たせない** — 持たせると
起点を 1 つ足すたびに view が枝分かれする。

**計算を画面に置かない。** 起点の一覧も図も `PlacementTrace` が組み立てる。
実クラスタの JSON を食わせた小さなバイナリ（`Models` の 5 ファイルを `swiftc` で
固める）で、起点ぜんぶを一度に確かめられる。

**起点は名前で持ち回る。** `TraceAnchor` に `K8sObject` を抱えると、自動更新で
中身が入れ替わるたびに別物として扱われ、選んでいる起点が外れる。使うときに
`object(for:in:)` で引き直す。

**ワークロードの一覧を Pod から起こすだけにしない。** レプリカ 0 の Deployment は
Pod が 1 つも無く、Pod 側からは存在すら見えない（起点に選べず、「無い」のか
「止めてある」のかも分からない）。Deployment / StatefulSet / DaemonSet / CronJob
も**同じ 1 回の kubectl で**取り、Pod から起こした名前と突き合わせる。CRD が
所有者の Pod は逆に実物が無いので、**両方から作る**。

**Pod が 0 でも入口は出す。** レプリカ 0 でも Service は付いたままなので、Pod が
無いときだけワークロードのテンプレートのラベルで引き直す（`services(matching:)`）。
入口が消えると「外から繋がっていない」と読めてしまう。

**辿れなかったことを黙らない。** Ingress が指しているのに Service が無い、
Service が何も掴んでいない、はどちらも設定の誤りとしてよくある。何も描かないと
「先に何も無い」のか「壊れている」のかが分からないので、文字で書く
（`missingServiceNames` / `danglingServices`）。ここも「無い」と「取れていない」を
混ぜないという同じ話。

**世代の段を二重に描かない。** DaemonSet / StatefulSet の Pod は直接の所有者が
ワークロード自身なので、そのまま囲むと同じ名前の箱が入れ子になる。
`TraceGeneration.isImplicit` のときは囲みを出さない。

#### ストレージは付属物だが、起点としては逆引きの入口

PVC / PV は図の下の帯（付属物）に出るが、**そこからしか見えないと逆が引けない。**
運用で出る問いは「この PVC を消してよいか」「なぜ Pending なのか」
「この PV は誰のものだったか」で、どれも**掴んでいる Pod を見つけないと答えが
出ない**。`TraceAnchorKind` に `.claim` / `.volume` を足してあり、解き方が
増えるのは `pods(for:)` の 2 分岐だけ（図は同じ）。

**PV から Pod へ直接は辿れない。** Pod の spec に書いてあるのは PVC の名前だけ
なので、PV → PVC → Pod の 2 段になる。

**`claimRef` を先に見る**（`WorkloadRelations.claim(boundTo:among:)`）。どの PVC に
束ねられたかを書くのはバインドしたコントローラの側で、こちらが事実。PVC の
`spec.volumeName` は人が先に書いておくこともある（まだ束ねられていない指名）ので、
`claimRef` が無いときだけそちらから逆引きする。**指し先が引けなかったときに
`volumeName` へ落とさない** —— Namespace を絞っていて手元に無いだけのときに、
**別の Namespace の同名 PVC を掴む**。

**「消えている」と「取得の範囲外」を混ぜない。** `claimRef` が指す PVC が手元に
無いとき、それが消えているのか絞り込みで見えていないだけなのかは、**PV の phase が
知っている** —— `Released` / `Failed` なら消えており、`Bound` のままなら在る
（＝引けていない）。同じ文言にすると、消えていないものを消えたことにする。
`Available` は待っている状態でふつうなので**警告にしない**（警告で画面を埋めない）。

**起点にした当のものを画面から消さない。** 帯は `claims(for: pods)` から作るので、
Pod が 0 の PVC を起点にすると帯ごと消え、束ねる先も状態も見えないまま
「辿れません」で終わる。`graph()` が起点そのものの PVC を必ず足す。

**枝が空になる理由を書く。** 誰も使っていない PVC、束ねる先の無い PV は、どちらも
枝が空になるだけ。`TraceGraph.anchorNotes` が理由を持ち、**「辿れません」の一言と
二重に出さない**（あちらは `anchorNotes` が空のときだけ）。

**状態は一覧の行に出す**（`TraceAnchor.detail`）。`Released` の PV や `Pending` の
PVC はここでいちばん見つけたいものなので、1 つずつ押させない。**ただし `id` に
入れない** —— phase は自動更新で動くので、入れると同じものを選んでいるのに別の
起点として扱われ、選択が外れる（`onChange` が「無効な選択」とみなす）。

**帯の PVC / PV も押せる。** 「この PVC を使っているのは何か」は帯を見ている
まさにその場で起きる問い。ただし**実物が引けていない PV は押させない** ——
押した先で何も出せない。

**phase を `Unknown` で埋めない。** 来ていないだけのことを、クラスタが答えたことに
しない（`PlacementTrace.phase(of:)` は nil を返し、段そのものを作らない）。

#### 図の中の器も押せる

一覧に戻って選び直させると、繋がりを辿るというこの画面の目的そのものが途切れる。
押した器がそのまま次の起点になり、**戻る**で 1 つ前に帰れる（押した先が外れ
だったときに一覧から選び直すことになるので、戻れないと押せない）。

**押した先の起点が一覧に居ることを確かめる。** `TraceAnchor.id` は
`起点種別|Namespace|種別|名前` で作る。図の中で組み立てた `id` が一覧のものと
1 文字でも食い違うと、選択の見直し（`onChange`）が「無効な選択」とみなして
先頭に飛ぶ。**確認は目視ではなく、押せる器ぜんぶの `id` を一覧の集合に
突き合わせる**（上の小さなバイナリでできる）。

**起点は設定に保存しない。** 行き来しながら見るものなので `@State` のまま。
設定に置くのは、いちど決めたら変えない類のものだけ（`placementTileSize` など）。

#### 幅は入口の側から潰す

段が 5 つ並ぶので、窓が狭いと SwiftUI が伸び縮みする欄を等分に削り、いちばん右の
**Pod 名から先に読めなくなる**（`web-...-58lkg` になった）。
**横スクロールにしない**（`Spacer` が無限に伸びて図がまるごと消える）。

以前は世代の列に `layoutPriority(1)` を付けて先に幅を取らせていたが、**いまは
付けない。** Pod がタイルになり、`WrappingTiles` が名前ぶんの幅（下限 150pt）を
最小として申告するので潰れようがない。優先度を戻すと、こんどはタイルが
「1 行に全部」を要求して**左の入口の列を押しのける**。

#### Pod はノードでまとめて横に流す

以前は Pod 1 つにつき「Pod → 矢印 → ノード」の行を引いていた。**同じノードの
器を Pod の数だけ描くことになる**ので、8 レプリカが 1 ノードに載っているだけで
ノード名が 8 回出て、1 行 500pt が 8 段に伸びた。実測（欄 1245×987）で
**図の高さ 470・枝の幅 806（右に 348pt の空き）** と、横が余ったまま縦にだけ
伸びていた。ノードごとに束ねてタイルを折り返すと **222 / 1160（空き 85pt）**。

**矢印の向きは変えない。** 図ぜんぶが「入口 → … → Pod → ノード」の左から右なので、
ここだけノードを左に置くと読む向きが折り返す。**件数は文字でも出す**
（`Node · 8 Pod`。タイルの数を目で数えさせない）。

`WrappingTiles` で 1 つ踏んだ。**最小・ふつう・最大を取り違えない。** `HStack` は
幅 0 と `.infinity` を提案して子の伸び縮みの幅を測るので、どちらにも同じ値
（「ふつう」の 3 列）を返していたら**伸び縮みしない子だと判断されて幅を等分され**、
8 個の Pod が 1 列のままだった（実測で提案 217.67pt）。最小は 1 列、最大は 1 行に
全部、幅の指定が無いときだけ 3 列を返す。`Int(.infinity)` はトラップするので
`isFinite` を先に見る（`SectionColumns` で踏んだのと同じ）。

#### 付属物は段に入れず、下の帯に置く

ストレージ・設定・通信制限・権限は、流れの先ではなく**付属物**なので、
段（入口 → ワークロード → 世代 → Pod → ノード）には入れず図の下に帯として並べる。
**数が増えたら折り返す**（`HStack` のままだと 1 つずつ潰れてどれも読めなくなる）。

- **設定（ConfigMap / Secret）は取りに行かない。** 参照している名前は Pod の
  spec に全部書いてある（ボリューム・投影ボリューム・`envFrom`・
  `env[].valueFrom`・`imagePullSecrets`、Ingress の `spec.tls`）ので、名前と
  付き方だけなら kubectl は 1 本も増えない。**初期化コンテナも見る** — 設定を
  取りに行くのが init の仕事、という作りは普通にあり、落とすと参照が丸ごと消える。
  **Secret の中身は出さない**（名前と付き方まで）。**付き方を 1 つに決めない** —
  マウントもされ環境変数にも入っているなら両方書く（見に行く場所が変わる）。
  **自動で付くものは出さない** — `kube-api-access-*` の中の `kube-root-ca.crt` と
  ServiceAccount のトークンはどの Pod にも並ぶので、本当の参照を帯の外へ押し出す。
  ただし**自分でマウントしていれば出す**（意図した参照なので）。
- **PVC で止めない。** 容量も StorageClass も PV 側にしか無い。ここも 3 つを
  分ける — バインド済み / **まだバインドされていない**（`spec.volumeName` が空。
  Pod が起動しない原因そのもので、「PV が無い」ではない）/ 名前はあるのに
  PV を引けていない。**両方に状態を出す**（`claimDetail` / `volumeDetail`）——
  `Pending` は Pod が起動しない理由そのもの、`Released` は PVC を消したあとも
  実体とデータが残っている状態で、実運用でいちばんよくある回収漏れ。容量だけ
  出していると、そのどちらも読み取れない。**容量を 2 度書かない** —— 実容量は
  PV 側が持っているので、PVC 側の「要求」は未バインドのときだけ出す
  （そのときはどこにも無い）。
- **RBAC は名前だけ並べない**（「アクセス制御」の節と同じ判断）。Pod からは
  `spec.serviceAccountName` しか辿れず、**何が付いているかは Binding 側にしか
  書いていない**ので逆引きになる。省略時は `default`（空欄にすると権限が無いように
  読める）。**Namespace まで見る** — 同じ名前の SA は Namespace ごとに別物。
  **グループ経由の付与（`system:serviceaccounts:*`）は見ていない**ので、
  何も見つからないことを「権限が無い」と書かない。

**重いものを毎周期引かない。RBAC はまとめ取りに入れない。** 配置画面は 10 秒ごとに
引き直すので、ここに足したものはその頻度で走る。

- **ClusterRole の rules** は重く（実測で 79 件 264KB、実運用なら MB 級）、要るのは
  紐づいた数個だけなので**名前指定で引き直す**（`Kubectl.roles(named:)`）。
- **RoleBinding / ClusterRoleBinding も同じ扱いにした。** 一度はまとめ取りに
  入れていたが（+96KB なので安いと見た）、**測ったのは大きさだけで往復ではなかった。**
  実測で `clusterrolebindings` 単独 6.54 秒 / 224KB、`rolebindings` 単独 3.87 秒。
  逆引きなので絞り込みが効かない（`--field-selector` は `subjects` を見られない）
  ため一覧が要り、**種別を 2 つ足すぶんだけ毎周期の往復が増える。**
  `ClusterStore.serviceAccountBindings` が起点が変わったときだけ引く。

**「まだ引いていない」を「Binding が無い」と書かない。** 引くのを遅らせた時点で、
引く前の空という状態が生まれる（遅いクラスタでは数秒ある）。そこを既存の
「直接付いている Binding はありません」と同じ見た目にすると、**読み込み中に
権限が無いと断定する**ことになる。`AccessBindings.isLoaded` で分ける
（`AccessRules` と同じ 3 分け）。

**口座（ServiceAccount）の一覧は Pod だけから作る。** `spec.serviceAccountName` は
手元にあるので、Binding を引く前でも帯そのものは出せる（`accessSummary(for:)` は
kubectl を 1 本も増やさない）。**`AccessAccount` に Binding を抱えさせない** ——
抱えさせると、自動更新のたびに引くか、引けていないものを「無い」として運ぶかの
どちらかになる。

**引けなかったことを「規則が無い」にしない** — RBAC を読めないクラスタはふつうに
あり、混ぜると権限が無いだけなのに「何もできない ServiceAccount」に見える。
**Binding が読めなかったのと、Binding は読めたがロールが読めなかったのは分けて
出す** —— 見に行く場所が違う。

#### NetworkPolicy の空セレクタは Service と意味が逆

`spec.podSelector: {}` は「まだ選んでいない」ではなく**その Namespace のすべての
Pod**。Service の `spec.selector` は空なら何も掴まない（別項）ので、**同じ「空」で
意味が正反対**になる。ここを Service と同じに書くと、**いちばん効きの強い設定を
「効いていない」ことにする。** 一覧の「対象」列も同じ理由で空欄にせず
「すべての Pod」と書く。

同じ話が中身にもある。**`ingress: []`（規則ゼロ）は「未設定」ではなくすべて拒否**で、
規則が 1 つあるより強い。**`from` の無い規則は「どこからでも」**でいちばん緩い。
`policyTypes` が省略されているときは既定（`ingress` があれば Ingress、`egress` が
あれば Egress）を補って書く。

### 所有者は Deployment / CronJob まで辿る

**ReplicaSet 名で束ねない。** `<Deployment 名>-<ハッシュ>` なので、更新のたびに
別のまとまりに見える。Job も CronJob から作られたものは実行のたびに名前が変わる。
`ownerReferences` をもう一段辿る（`PlacementTrace.workloadOwner(of:controllers:)`）。
**解き方を 2 つ持たない** — 配置の各見方とたどるで別々に実装すると、
「ワークロード別では 3 個なのに、たどると 2 個」のような食い違いが出る。
そのために ReplicaSet と Job も Pod・ノードと**同じ 1 回の kubectl で**取る
（`placementControllers`）。索引は `ClusterStore.controllerIndex` が持つ
— Pod ごとに `first(where:)` で舐めると線形探索になる。

**その索引を計算プロパティにしない。** 索引を作るための索引が、読むたびに
全 ReplicaSet / Job を舐め直していた。しかも配置画面はノードの箱ごとに読むので、
1 描画あたり `ノード数 × 世代数` の挿入になっていた（ノード 20・世代 500 で
1 万回）。いまは `placementControllers` の didSet で 1 度だけ組み立てる。

支配者は `controller: true` のものを採る。`ownerReferences` は複数持てるが、
支配者は 1 つだけ。

**タイルを 1 つにまとめない。** まとめると個々の Pod を選べなくなり、
「1 つだけ落ちている」という配置画面でいちばん見たい状態が消える。
まとめるのは見出し（`名前 ×N`）だけで、タイルはそのまま並べる。

**並べ替えるのはノードの箱だけ。** 出自の分からない箱と「未スケジュール」は常に
最後に置く。並びの中に紛れるとノードの 1 つに見える。

## 「無い」と「取れていない」を混ぜない

このアプリで最も繰り返し踏んだ間違い。取得に失敗しているのに `0 件` や
`ありません` と出すと、**確かめていないことを断定する**表示になる。

- 一覧: 読み込み中 / 取得失敗 / 本当に 0 件 の 3 つを別の表示にする（`LoadingView` / `failureState` / `emptyState`）。
- 概要: `hasOverviewData` が偽で `errorMessage` があるときは、0 の並んだタイルではなく失敗表示を出す。
- 副題: 失敗時は `0 件` ではなく `取得できません`。
- 概要のイベント: `OverviewSnapshot.recentEvents` は**optional**。`loadOverview` が
  失敗を `[]` に潰していたので、イベントを読めないクラスタで
  「イベントはありません。」と断定していた（詳細パネルの `EventsPane` は
  3 つに分けているのに、概要だけが混ぜていた）。**0 件のときも寿命の断りを添える。**
- イベントタブ: 引き直しに失敗しても、**それまで読めていた行を消さない**。
  `failure` を先に見ていたので、再読み込みが落ちた瞬間に行ごと画面から消えていた
  （「前の結果を消さない」と書いてあるのに、表示側で消していた）。帯で断って行は残す。
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
kubectl が 2〜3 本増えることになる。**すでに調べている最中なら重ねない** —
Prometheus の探索は全 Service を順に叩くので、2 本走らせるとそのぶん増える。

### クラスタごとの調べものにも世代番号を通す

一覧の再読み込みには `generation` があるが、コンテキストに紐づく調べもの
（Namespace 一覧・CRD・バージョン・メトリクスの取得元）は素の `Task` で
投げていた。**世代番号もキャンセルも無いと、A → B と続けて切り替えたときに
A 向けの結果が B に書き込まれる。** とくに Prometheus の探索はいちばん遅れて
返るので、**A で見つけた場所を B のものとして `UserDefaults` に永続化していた**
（B に同名の Service が無ければ、以後ずっと推移が出ないまま黙る）。

`contextGeneration` を**一覧の `generation` とは別に**持ち、`refreshClusterInfo()`
がまとめて投げる。**一覧の再読み込みで無効にしない** — 種別や Namespace を
変えただけではクラスタの事実は変わらない。各関数は**書き込む直前に**世代を見る
（await のあとで代入する箇所がすべて対象。`refreshMetrics` も含む — 別クラスタの
使用量が混ざると、ノード名が一致した場合にそのまま棒になる）。

起動時は CRD → 選択の復元 → Namespace 一覧、の順に読む必要があってすでに
手元にあるので、`refreshClusterInfo(includingFacts: false)` で**同じものを
もう 1 度引かない**。以前はここで `detectMetricsSources` を直接 await しつつ
`reload` の完了が `recoverClusterInfoIfNeeded` 経由でもう 1 度呼んでいたので、
起動のたびに Prometheus の探索が二重に走っていた。

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

下の帯の高さと、帯の中で詳細に割く幅は自前の `@State` で持ち、仕切りは
`DragGesture` で動かす（`PanelResizeHandle`）。`VSplitView` に戻さない。

**再現のしかた**: パネルの開閉・対象の切り替え・詳細パネルの開閉・高さ変更を
20 回ほど繰り返す。手で触っていると出たり出なかったりするが、繰り返せば必ず出る。
落ちたかどうかは `~/Library/Logs/DiagnosticReports/KubeDeck-*.ips` の増減で分かる。

### 自前の仕切りは `.global` で測る

**`DragGesture` の既定（`.local`）を使わない。** 仕切りは自分が動かす縁に付いて
いるので、値を変えたぶんだけ**自分も動く**。上へ 10pt 引くと帯が 10pt 高くなり、
仕切りも 10pt 上がるので、カーソルは仕切りの座標系では動いていないことになり
`translation` が 0 に戻る。値が掴んだ時点へ引き戻され、すると仕切りが下がって
また差が出る——を繰り返して**掴んだところで震え、付いてこない**。窓の座標系
（`coordinateSpace: .global`）で測れば、仕切りが動いても差分は動かない。

**掴める上限を決め打ちにしない。** 表示のときだけ使える幅に詰めていると、掴んだ
値は画面の外へ伸び続け、戻すときに**伸ばしたぶんだけ反応しない区間**ができる。
上限は測った大きさから決める（帯の高さは本体の高さ − 160、詳細の幅は帯の 6 割）。

**その測る場所を帯の内側に置かない。** `safeAreaInset` を付けた側で
`GeometryReader` に訊くと、返るのは**安全領域を除いた大きさ**——つまり帯のぶん
だけ縮んだ値になる。実測（起動時に両方を出した）:

```
outer=960   inner=680   dock=280     ← 内側は帯のぶん小さい
outer=1358  inner=168   dock=280     ← 起動直後に 1 度だけ来た一過性の値
outer=1358  inner=1158  dock=200     ← 誰も触っていないのに帯が 280 → 200 に縮んだ
```

これを上限の元にすると、帯を広げる → 測った値が縮む → 上限が下がる → 掴んだ値を
押し戻す、を毎フレーム繰り返して**掴んだところでグラグラする**。しかも 1 フレーム
ごとに `@State` を書くので、一覧とパネルが毎フレーム作り直される。`safeAreaInset`
の**外側**に `GeometryReader` を置けば、帯を動かしても変わらない。

**測った上限で、覚えている値のほうを詰めない。** 上の 2 行目のような一過性の値が
来るので、そこで詰めると誰も触っていないのに帯が縮んだままになる（実際そうなった）。
詰めるのは**表示と、掴んだときの起点だけ**。起点を画面に出ている大きさに合わせるのは、
窓を狭めたあとに覚えている値から動かすと、画面の外から動き始めて最初のひと押しが
効かないため。

**外側で包んだら、中身は広がる枠に入れる。** `GeometryReader` は子を左上に寄せる
ので、伸びない中身（`ContentUnavailableView` など）が隅に張り付く。

**起点を `onEnded` だけで捨てない。** ドラッグが取り消されると `onEnded` は
呼ばれず、`@State` に残った起点を次のドラッグが基点にして**掴んだ瞬間に飛ぶ**。
`@GestureState`（取り消しでも必ず戻る）の変化を見て捨てる。

**`NSCursor` の push と pop の数を合わせる。** `onHover` で押して離すだけだと、
掴んだまま欄の外へ出た瞬間にカーソルが矢印へ戻り（掴めていないように見える）、
カーソルが乗ったままパネルが閉じると pop されないまま**画面ぜんぶが仕切りの
カーソルになる**。押したかどうかを持ち、ドラッグ中は保ち、消えるときは戻す。

## exec は端末をアプリに持ち込まない（`Views/ExecSheet.swift`）

**中に入る手段は要る。** 落ちた理由を追うとき、ログの次に必ず要る。無いあいだは
ここまで来てターミナルに戻ることになっていた。

**ただし端末は自分で持たない。** `kubectl exec -it` には擬似端末が要り、まともに
動かすには VT100 の解釈（カーソル移動・色・画面消去・リサイズ通知）を抱えることに
なる。ログを読むのとは桁違いの重さで、**このアプリの持ち場ではない**（JSONPath の
絞り込みやラベルセレクタを実装しなかったのと同じ判断）。使う人はすでに端末を
持っていて、そこでは補完も色も履歴もコピーも動く。

**AppleScript で Terminal を操らない。** Apple Events の許可が要り、断られると
理由の分かりにくい失敗になる。**実行できる `.command` を書いて `open` する**なら
許可は要らない。置き場所はアプリのキャッシュの中で `0700`（`/tmp` は他人も読める。
中身にはクラスタ名と Pod 名が入る）。**置きっぱなしにしない** —— 1 時間より古い
ものは次に開くときに捨てる。書き出しは `ExecScriptTests` で固めてある
（Terminal が開いてしまうので、押しては確かめられない）。

**アプリと同じ kubectl を指す。** `--context` と `--cache-dir` も揃える。ここだけ
別の実体を使うと、アプリでは通るのにターミナルでは通らない（あるいはその逆）が
起きて、切り分けができなくなる。

**シェルを決め打ちしない。** 既定は
`sh -c 'command -v bash >/dev/null 2>&1 && exec bash || exec sh'`。軽量なイメージには
bash が無く、bash 前提の人は sh だと不便。コマンド欄は書き換えられる（`psql` など）。

## ログは押したときだけ開く。開いているあいだは選択に追従する

**行を選んだだけでパネルを開かない。** 一覧で Pod を選ぶたびに `kubectl logs -f` が
走ることになり、見るつもりのない Pod にも取得が掛かる（選んだ理由はふつう状態や
設定を見るためで、ログはそのうちの 1 つでしかない）。開けるのは「ログを見る」を
押したときだけ（`ClusterStore.showLogs`）。

**開いているパネルの行き先は選択に追従する**（`followLogsToSelection`）。
すでに開いているのに前の Pod のログが残ると、どれを見ているのか分からない。
追従は `logRequest != nil` を条件にしてあるので、✕ で閉じれば止まる
（**閉じたのに選ぶたび開き直すと ✕ が効かないものに見える**）。切り替えたくない
ときは設定で切れる（`followsSelectionForLogs`）。

**取得の受け渡しに世代番号を付ける。** `store.logStream(...)` は await をまたぐので、
`stop()` の時点でまだ掴んでいないプロセスは止められない。番号を見ずに書くと、
選んだ Pod の数だけ `kubectl logs -f` が残る（実測で 18 回切り替えて 6 本残った）。
待ちから戻った時点で世代が変わっていたら、掴んだハンドルをその場で `terminate()` する。

確認は `ps -eo ppid,args | awk '$1==<アプリのpid>' | grep " logs "` の本数。
何回切り替えても 1 本であること。

### Job からも開ける。ただし Pod に潰してから渡さない

Job を選んでもログを開けなかった。だが**ログを見たい場面のかなりの割合が Job**
（バッチが落ちた理由はログにしか無い）で、そのたびに Pod 一覧へ移り、
ハッシュ付きの名前から所有者を目で探すことになっていた。

**開ける種別の判定を 1 か所にする**（`PodLogRequest(object:)` が nil を返すか
どうか）。以前は一覧のメニューが一覧の種別を、詳細パネルが `object.kind` を
見ており、**別々に書いてあるので Job を足すときに片方だけ直しうる**。

**Job を Pod に潰してから渡さない。** Job の Pod は再試行や `completions` で
複数になり、完了後に消えることもある。潰すと「どの試行のログか」も
「そもそも Pod が残っているのか」も画面で言えなくなるので、`PodLogRequest` は
`.job(selector:)` のまま持ち回り、開いたあとに `LogContent` が解決する。

**`kubectl logs job/<名前>` に任せない。** あれは Pod を 1 つ選んで出すだけで、
再試行した Job では最後の試行しか読めず、しかもどれを読んでいるのかが出ない。
Pod が複数なら Picker に並べる（既定は最新）。

**セレクタは Job 自身の `spec.selector` を使う。** `job-name=` のようなラベルは
版で変わる（1.27 で `batch.kubernetes.io/job-name` が足された）。`spec.selector`
は指定しなくても API サーバが必ず埋めるうえ、Job コントローラが自分の Pod を
数えているものそのもの。**空のセレクタで引かない** — ラベル無しで get すると
Namespace の Pod が全部返り、無関係な Pod を Job のものとして出す。

**Pod を引く前に「どういう空か」を分ける。** ここも「無い」と「取れていない」を
混ぜない話で、`LogContent` は 4 つを別の表示にする — まだ引いていない /
Pod が 1 つも無い（`ttlSecondsAfterFinished` や Pod の GC で消えた）/ 引けなかった /
Pod はあるがログが空。とくに 2 つ目と 3 つ目を混ぜると、権限で引けないだけなのに
「Pod はもう残っていません」と断定することになる。

**取得と解決を 1 つの `task` にまとめない。** `id:` を共有すると、「時刻を出す」を
切り替えただけで Pod を引き直すことになる（解決は `request.id`、取得は `reloadKey`）。

**一覧を引くときに要求種別を補う**（`Kubectl.list(resource:...assuming:)`）。
単一種別の `get -o json` は items に `kind` を入れてこない版があり、そうなると
`K8sObject.kind` が nil になる。一覧の表示には効かないので気付きにくいが、
種別で分岐するところ（詳細パネルの「ログ」）が黙って消える。

確認は、`completions: 3` の Job を作ると Pod が 3 つ並ぶ。**確かめたら消すこと。**

### Deployment / Service はまとめて読む。1 つ選ばせない

「どのレプリカで起きたか分からない事象」を追うのがログを開く理由の大半なのに、
入口が Pod と Job しか無かった。Deployment を選んでも一覧に「ログ」が出ず、
Pod 一覧へ移ってハッシュ付きの名前を目で拾い、1 つずつ開いて外れを引き直す、
という作業になっていた。

**Job の形をそのまま流用しない。** あちらは Pod を Picker で 1 つ選ばせる
（「どの試行のログか」に意味がある）。8 レプリカから 1 つ選ばせた時点で、
探しているものを見つける確率が 1/8 になる。**まとめ読みは混ぜて出すのが答え。**
`PodLogRequest.Source` に `.group(kind:selector:)` を足し、`.job` とは別扱いにする。

**kubectl 1 本に任せる**（`kubectl logs -l <selector> --prefix`）。Pod ごとに
`kubectl logs -f` を起こすと Pod の数だけプロセスが立つ（1 本あたりスレッド 3 本、
というのは取得系で一度踏んで直した話）。混ぜ方も並べ替えも向こうが持っている。

- **`--tail` を必ず明示する。** セレクタを付けたときの kubectl の既定は
  **10 行**（実測。`kubectl logs --help` の `--tail` の説明。手元 v1.32.13）。
  落とすと、まとめ読みのときだけ 10 行しか出ない。
- **`--max-log-requests` を既定のままにしない。** 既定は **5**（同上）で、
  6 レプリカを追いかけようとしただけで弾かれる。いまは 30。**上限を超えたら
  黙らない** —— 掴んでいる数は先に分かっているので、帯に書く。
  - **「上限までは読める」と書かない。** 実測（v1.32.13）で、超えたときの
    kubectl は **1 行も出さない**。`exit=1`、標準出力 **0 バイト**、stderr に
    `error: you are attempting to follow 2 log streams, but maximum allowed
    concurrency is 1, use --max-log-requests to increase the limit` だけ。
    帯は「N 個中 30 個までしか追いかけられません」と書いていたので、
    **30 個ぶんは出ていると読める嘘**だった（出ているのは 0 個）。
  - **効くのは `--follow` のときだけ。** 同じ 2 Pod / 上限 1 でも、
    `--follow` を外せば両方とも出る（`exit=0`、210 バイト）。だから帯は
    追いかけているときだけ出し、逃げ道として「追いかけるを切れば全部読める」
    ことを書く。
  - 文言そのものは stderr から本文に混ざるので、行としても読める
    （`ProcessRunner.stream` が stderr を同じ流れに入れている）。
- **`--all-containers=true` はコンテナを選んでいないときだけ。** `-c` と
  両方渡すと、どちらが効くのかを画面の側で説明できなくなる。
- **`--prefix` は自分で付ける。** ヘルプには `--all-containers` の説明として
  `Sets prefix to true` と書いてあるが、**実測では付かなかった**
  （kubectl v1.32.13。単一 Pod に `--all-containers=true` だけを渡すと行頭は
  素のまま。`--prefix` を足すと `[pod/<Pod>/<コンテナ>] ` が付く）。暗黙に
  任せると、剥がす側（`LogLine`）だけがずれて**本文の先頭が黙って消える**。
  付けるかどうかは `Kubectl.logsArePrefixed` の 1 か所が決め、引数を組み立てる
  側も剥がす側もそれを見る（`KubectlTests` が両者の一致を見ている）。

**セレクタの読み先は種別で違う。** ワークロードは `spec.selector.matchLabels`、
Service は素の `spec.selector`。**空のセレクタで開かない** —— Service の空は
「すべてに一致」ではなく「まだ何も選んでいない」（`WorkloadRelations` と同じ規則）。
通すと Namespace の Pod を全部読む。**CronJob は入れない** —— セレクタを持たず
Job を経由する 2 段になるので、ここでは解けない（押しても何も出ないボタンを
出さない）。**世代で絞らない** —— ロールアウト中は新旧の Pod が並ぶが、
そのときこそ両方が見たい（世代 1 つに絞るなら ReplicaSet を起点にできる）。

**prefix は本文から剥がして列にする**（`LogLine.splitPrefix`）。残したままだと
行の絞り込みが Pod 名にも当たり、深刻度の判定も行頭が `[` になってずれる。
**`--prefix` を付けたときだけ剥がす** —— 付けていない行から剥がすと
`[ERROR] ...` を出どころとして食う。剥がす条件は「`/` を含む・空白を含まない・
Kubernetes の名前に使える字だけ」の 3 つで、`[main]` も `[INFO/Server]` も
`[2026-08-02 01:23:45]` も通らない。書式は実測で
`[pod/<Pod 名>/<コンテナ名>] ` の **3 段**（kubectl v1.32.13。セレクタでも
単一 Pod の全コンテナでも同じ）だが、**段を数えず**囲みの中身をそのまま
出どころにしてある（読む側が後ろから数える。`LogLineTests`）。

**時刻は prefix の内側に来る。** kubectl は
`[pod/<Pod>/<コンテナ>] <時刻> <本文>` の順で書くので、剥がす順も
prefix → 時刻 → 本文。

**出どころの色は、状態の色と持ち場を分ける。** 一度は「Pod ごとに色を塗らない」
と決めていた —— 行の帯は深刻度（状態の 4 色）が持っている場所なので、隣で
別の意味の色が動くと、どちらが状態なのか分からなくなる、という理由。だが混ぜて
読んでいるあいだ、出どころが全部同じ灰色だと**どの Pod の行かを毎行読み下す**
ことになり、まとめ読みの用途そのものが鈍る。理由のほうを守って両立させる。

- **色が付くのは出どころの列の文字だけ。** 行頭の帯・下地・本文は深刻度のまま。
- **状態の 4 色を 1 つも使わない**（`Palette.logSources`）。緑・黄・橙・赤を
  避けた寒色 7 色で組む。同じ画面に出る 2 系統の色が、色相の時点で交わらない。
- **色だけに意味を持たせない。** 色を付けている当の列に名前が出ている。
- **単位は Pod ＋コンテナ**（出どころの文字列そのもの）。レプリカの違いも
  サイドカーの違いも同じ 1 つの規則で分かれる。
- **現れた順に振る。名前のハッシュから決めない。** ハッシュだと 2〜3 個しか
  無いときでも隣り合う色になりうる。順に振れば、いま出ている数だけ最も
  離れた色が当たる（7 を超えると一周するが、名前が出ている以上それで別物に
  なるわけではない）。
- **切れるようにする**（`Preferences.logColorsSources`。既定は入り）。

**1 つの Pod でも「すべてのコンテナ」を選べる。** 以前はコンテナを 1 つしか
選べず、サイドカーの立った Pod で本体と proxy を突き合わせるには、切り替えては
読み直すしかなかった（まとめ読みの既定を「すべて」にしたのと同じ理由が、
Pod 1 つのときにも当てはまる）。**既定は変えていない** —— 開いた時点で
1 つ目のコンテナのまま。istio-proxy のアクセスログが本体を埋めるので、
混ぜるかどうかは押す側に選ばせる。**選びようが無いときは付けない** ——
コンテナが 1 つの Pod で `--all-containers` を渡しても読むものは同じで、
要らない出どころの列が増えるだけ。

**Pod の絞り込みは表示だけ。取得に触らない。** 取得を絞ると、絞った瞬間に
それまで読んでいた行が消える（`streams` と `autoScroll` を分けたのと同じ話）。
絞る候補は「kubectl で引いた Pod 一覧」と「実際に行が届いた Pod」の**両方**から
作る —— 前者だけだと権限で一覧が引けないクラスタで絞り込みごと消え、後者だけだと
まだ何も出していない Pod を選べない。**数え直しは取り込みのときに**（body から
5,000 行を舐めない）。

**コピーには出どころと時刻を付ける**（`[pod/container] <原文の時刻> 本文`）。
混ぜて読んでいるので、貼った先で出どころが落ちるとまとめ読みの結果として
使えない。**時刻は現地に直したほうではなく原文（UTC）を貼る。**

**掴んでいる Pod の一覧が引けなくてもログは出す。** 相手を決めるのは kubectl 側
（`-l`）なので、こちらの一覧は数を言うためだけのもの。だから空の表示は
**取得が動いているかを先に見る** —— 「Pod がありません」を先に見ると、
引けていないだけのときに断定することになる。

**⌘L は両方の id に割り当てる**（`logs` と `logs-group`）。同じ種別に同時には
出ないのでキーは衝突しないが、片方だけ書くと **Deployment のときだけ ⌘L が
効かない**という気付きにくい抜け方をする。

**入口は詳細パネルのタブ**（`InspectorView.Tab.logs`）。ログを見たい対象は
Service や Deployment のような上位のリソースで指すほうが多いので、**選んだら
そこにある**のが素直だった（ボタンや右クリックは「知っている人にしか使えない」
という、`ResourceActionBar` を足したときと同じ話が、今度はタブとの間で起きる）。

- **空のタブを増やさない。** ログを開けない種別では並べない
  （`InspectorView.tabs(for:)`）。判定は `PodLogRequest` の 1 か所のまま。
- **選ばれているタブが消えることに備える。** ログの出せない種別へ移ると
  「ログ」が一覧から落ちるので、`tab` をそのまま束ねると**どのセグメントも
  光っていない Picker** になる。出せるものへ倒す。
- **`.id(request.id)` を付ける。** 付けないと対象を変えても view が作り直されず、
  前の `kubectl logs -f` が生き残る（止める側は `LogContent.onDisappear`）。
- **ボタンからは落とす**（`ResourceActionBar.hiddenFromBar`）。名前のすぐ下に
  「ログ」ボタンがあり、その 30pt 下のタブ列にも「ログ」があると、同じ名前が
  2 つ並んで**押した先が違う**（片方はその場、片方は一覧の下）。
  **メニューと ⌘L からは落とさない** —— あれは画面の外にあり、タブと重ならない。
  `ResourceActionSet` の中身は変えていないので、出し分けは 1 か所のまま。
- **ボタンが 0 個のときに「その他」ごと消さない。** 読み取り専用のクラスタでは
  クラスタを動かす操作が全部落ちるので、ログをボタンから外したぶん、
  `utility` しか残らない状態に掛かりやすくなった（名前のコピーも別ウインドウも
  届かなくなっていた）。
- **狭いことを黙らない。** 詳細パネルは右に置くと 300〜360pt しかなく、ログは
  YAML よりさらに 1 行が長い（「右のパネルは YAML を主役にしない」と同じ話）。
  520pt を下回るときは「狭い幅では読みにくい」と出し、別ウインドウの導線を置く。
  **出せないのではなく置き場所の話**なので、下に置けば足りることを添える。
- **「押したときだけ開く」を破っていない。** タブを選ぶこと自体がその操作で、
  選択を変えるたびに取り直すのは、開いているログパネルが選択に追従するのと
  同じ扱い（`followLogsToSelection`）。

**`--follow` 中に生まれた Pod は拾わない。** ロールアウト中に新しい世代の行が
出てこないのはこれ。実測（kubectl v1.32.13 に `-v=6` を付けて要求を見た）で、
kubectl が出すのは次の 3 種類だけだった。

```
GET .../namespaces/default/pods?labelSelector=app%3Ddemo-proxy   ← 1 回だけ。watch=true が無い
GET .../pods/demo-proxy-859f44696-hmhhk/log?container=proxy&follow=true&tailLines=1
GET .../pods/demo-proxy-859f44696-kslx8/log?container=proxy&follow=true&tailLines=1
```

**Pod の一覧を watch していない**ので、掴む相手は始めた時点で固定される。
新しい世代を読むには取り直しが要る（「追いかける」を切って入れ直すか、
対象を選び直す）。**こちらで watch を持たない** —— ラベルセレクタや JSONPath を
実装しなかったのと同じ判断で、そのために Pod の一覧を毎周期引き直すと、
配置画面で RBAC をまとめ取りから外したのと同じ負荷の話になる。

### 「取得」と「見え方」を 1 つのトグルにしない

以前は「追従」1 つが `kubectl logs --follow` と末尾への自動スクロールを兼ねて
おり、しかも取得の鍵（`reloadKey`）に入っていた。**「スクロールを止めたい」
だけで切ると取得ごとやり直しになり、それまで読んでいた行が全部消えた。**
遡って読もうとする場面がまさにそこなので、いちばん困る消え方だった。

いまは `streams`（`--follow` を付けるか）と `autoScroll`（末尾へ送るか）に
分けてある。**`reloadKey` に見え方だけの状態を入れない。**

### 受け取った行を 1 行ずつ画面へ渡さない

`ProcessRunner.stream` は `AsyncStream<[String]>` を返す。**1 行ずつ yield
しない。** パイプから 1 度に読めたぶんはもともと塊で届いており、それをわざわざ
ばらすと受け手は行の数だけ画面を作り直すことになる。1 行あたり

- 上限に達したあとは `removeFirst` の O(n) の詰め直し
- 絞り込み中は `visibleLines` の O(n) が body 1 回につき 3 か所
- `ForEach` の同一性リストを上限（既定 5,000 行）ぶん歩き直す

が走り、毎秒数百行を出す Pod で UI が張り付いた。

**溜め込みで直さない。** タイマーで溜めると、静かになった Pod の最後の数行が
次の行が来るまで出ない。塊のまま受ければ、遅れずに 1 度の更新で済む。

`visibleLines` は body の先頭で 1 度だけ作って渡す（3 か所がそれぞれ読むと、
絞り込み中は 1 回の描画で全行を 3 度舐める）。

## ログの見え方

- 行頭に**深刻度の帯**（2pt）とごく薄い下地。klog（`E0802`）、JSON（`"level":"error"`）、
  logfmt（`level=error`）、括弧（`[ERROR]`）を見る。判定は取り込み時に 1 度だけ
  （描画のたびに走らせると追従中は毎フレーム全行を舐める）。
- **本文の色は変えない。** 何百行も並ぶ場所で文字色を振ると読むこと自体が疲れる。
- **行番号**を左に置く。折り返した行の塊がこれで分かるので、1 行おきの下地は要らない。
- 絞り込みに一致した部分は色を敷く。

### 時刻は本文から剥がして列にする

`--timestamps` が付ける時刻は**本文に残さない**（出どころの prefix と同じ扱い）。
残すと絞り込みが時刻にも当たり、深刻度の判定も行頭でずれる —— 実際、行頭が
日付になるので **klog の判定（`E0802`）が `--timestamps` を付けているあいだ
丸ごと効いていなかった。**

**原文をそのまま列に並べない。** kubectl が出すのは
`2026-08-07T04:12:33.123456789Z` の 30 文字で、狭いパネルでは本文がその半分を
持っていかれるうえ、UTC のまま並ぶので手元の時計と突き合わせられない。列には
現地時刻（`HH:mm:ss.SSS`）を出し、**原文はツールチップとコピーに残す**
（「元の文言を捨てない」と同じ話。貼る相手は別の時間帯にいることも、他所の
ログと突き合わせることもある）。

**日付は日付が変わった行にだけ。** 毎行に `MM-dd ` を並べると 6 文字ぶん本文が
削れる。範囲が日をまたぐときだけ枠を取り、変わり目の行にだけ書く（枠は取って
おくので時刻の桁はどの行でも揃う）。

**行が時系列に並んでいると思わない。** またぐかどうかを「先頭と末尾の行」で
決めていたが、実測（kubectl v1.32.13、`logs -l --prefix`）で、最初に流れてくる
`--tail` のぶんは**時刻順に混ざらず Pod ごとに固まって**出た。

```
1 14:37:59.118 demo-proxy…mhhk/proxy …   ← 新しいほうが先
5 14:37:55.895 demo-proxy…slx8/proxy …   ← 4 秒前に戻る
```

（`--follow` に入ってからは届いた順に混ざる。）幅は**取り込みのときに覚える**
—— 全行を舐めると追従中は毎フレーム 5,000 行を歩く。

**`ISO8601DateFormatter` を通さない。** 小数秒の有無で読める形が排他になり
（`K8sObject.date` で踏んだ）、1 行ごとに通すには重い。**`DateFormatter` でも
整形しない** —— 既定のカレンダーが和暦の環境で月日が変わる。桁を数えて整数で
計算する（`LogTimestamp`）。**整形は取り込みのときに 1 度だけ** —— 描画のたびに
やると追従中は毎フレーム全行を整形することになる（深刻度の判定と同じ理由）。

**時刻の付いていない行を空欄にしない。** kubectl 自身の文言には時刻が無い。
空欄だと「時刻を出す」が効いていないように見えるので `—` を出す。

**列の幅は実測で決める。** `NSFont.monospacedSystemFont` で測った
`00:00:00.000` は **9.5pt で 70.5pt、10.0pt で 74.2pt**（列は本文より 1pt 小さい
ので、詳細パネル 10.5 → 9.5、別ウインドウ 11 → 10）。両方 74pt にしていたら、
**別ウインドウでだけ 0.2pt 足りずに切れる**ところだった。`08-02` は 29.4 / 30.9pt。

**左の欄をこれ以上増やさない。** 詳細パネルを右に置くと 300pt しかなく、
まとめ読みで時刻も出すと 帯 2 ＋ 行番号 54 ＋ 時刻 81 ＋ 出どころ 112 ＝ **249pt**
が左に載り、本文は 40pt しか残らない（実測した幅からの計算）。いまは
「狭い幅では読みにくい」の断りと、下に置く / 別ウインドウという逃げ道で
凌いでいる。**欄を足すならどれかを落とす**こと。

**誤爆に注意。** `no errors expected` や `/api/errors` を error にしないこと。

**前方一致で判定しない。** `=error` をそのまま `contains` すると
`handler=errorMiddleware` や `metric=error_rate` まで error になる（テストで
実際に踏んだ）。`containsToken` が、目印の直後が英数字や `_` `-` なら別の語の頭と
みなす。**見るのは目印が英数字で終わるときだけ** — `"error"` や `[error]` や
`" error "` は目印そのものが区切りで終わっているので、後ろを見ると逆に落とす
（`" error "` の次は本文の 1 文字目）。

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

**ただし「古い」と「別物」を混ぜない。** Namespace を切り替えたときに出ている行は
更新前の姿ではなく**別の Namespace のもの**なので、残すと切り替えたのに前の一覧が
出たままになり、いつ入れ替わったのかが分からない（新しいほうが少なければ、消えるまで
多く見える）。`selectedNamespace` の didSet が `discardLoadedResources()` で捨ててから
`reload()` する。**選択も一緒に捨てる** — 一覧から消えたものを選んだままにすると、
見えていないものが「まとめて削除」の対象になる（種別を移るときと同じ話）。
**概要の集計も捨てる** — 残ると `hasOverviewData` が真のままで、概要が
0 の並んだカードを出す（「まだ数えていない」が「0 件」に化ける）。

**読み込み中を失敗より先に見る。** `errorMessage` は前回の取得のものなので、引き直して
いる最中にこれを先に見ると、まだ何も試していないのに失敗の画面が出たままになる
（`PlacementView` がそうなっていた）。

### 概要にも同じ規則を通す

概要だけが「読み込み中」に入らない道が 2 つあった。どちらも**まだ引いていない
ことを、取得の結果として**出していた（対象なしのリング、「イベントを取得でき
ませんでした」、サイドバーは件数なし）。

- **「概要を読めた」の印を件数で代用しない。** `hasOverviewData` は
  `loadedOverviewCounts` の有無で決めていたが、あそこは一覧を見ているあいだにも
  サイドバーのために埋まる（`refreshSidebarCounts`）。**件数しか無いのに概要が
  出せることになり**、一覧から概要へ移ると読み込み中を飛ばして 0 のリングが出た。
  印は `OverviewSnapshot.isTallied` に移し、集計まで済んだときだけ立てる。
  **`ClusterStore` 側に別の変数として持たない** — snapshot を捨てれば一緒に落ちる
  形にしておかないと、コンテキストを切り替えたときのように片方だけ消す道が残る
  （実際そうなっていた）。
- **最初の `reload()` を待たずに読み込み中にする。** `bootstrap()` は
  コンテキスト一覧・CRD・Namespace 一覧を順に引いてから `reload()` を呼ぶので、
  そこまでは `isLoading` が偽。実測（Connect Gateway 越しの GKE）で、起動から
  数秒はこの姿だった。`bootstrap()` の先頭で立てる。**下ろす道を塞がない** —
  コンテキストが 1 つも無いと `reload()` は何もせず戻るので、そこと
  設定の失敗（`setupErrorMessage`）でも下ろす（`OverviewLoadingTests`）。

**概要を開き直すときも一覧と同じく捨てる。** 一覧は `selection` の didSet が
`objects` を捨てるので読み込み中になるのに、概要だけは前に開いたときの集計が残り、
読み直しているあいだ**古い数字を「いまの状態」として**出していた（更新中だと
画面に出ていない）。**件数までは捨てない** — あれはサイドバーの持ち場で、
概要の読み直しとは関係が無い（`OverviewSnapshot.discardTallies`）。

## 一覧の並べ替えと上下移動は自前で持つ

一覧は `List` ではなく自前の行なので（最小幅の都合。「図の部品」の節を参照）、
**`List` に付いてくる上下移動も列の並べ替えも付いてこない。** 一覧を見ながら
1 行ずつ確かめるのは基本の操作なので、`onMoveCommand` と見出しのボタンで足す。

**並べ替えの鍵は列の位置ではなく見出しで持つ**（`ResourceSort.columnTitle`）。
使用量の列は metrics-server が見つかってから増えるので、位置で覚えると
途中で別の列を指す。種別を変えたら捨てる（列そのものが違う）。

**鍵はセルの文字をそのまま使う。** 見えているものと並び順が食い違わないため。
そのために列の定義は `ClusterStore.currentColumns` の 1 か所だけが持つ。
数字を含む名前は `localizedStandardCompare` で人が読む順になる
（`web-2` < `web-10`）。**比較関数の中でセルを組み立てない** — `value` は
毎回 JSON を辿るので O(n log n) 回になる。先に 1 度だけ引く。

**「取れていない」を先頭に集めない。** 空欄や `—` は値ではないので、昇順でも
降順でも末尾に置く。

**既定に戻せるようにする。** 同じ見出しを 3 度押すと `nil`（異常が上）に戻る。
戻れないと、既定の並びを取り戻すのに種別を開き直すことになる。

### 表は見えている幅で切る

列が増えて表が欄より広くなると、`ScrollView` は safe area まで広がるので、
**はみ出した列が詳細パネルの下へ潜り込む。** あちらは半透明なので、読めない
文字が透けて出るうえ、**列があること自体に気付けない**（metrics-server が
入った環境で `CPU / 要求`・`メモリ / 要求`・`経過` の 3 列がこうなっていた）。

`GeometryReader` が測っている `proxy.size` は safe area の内側なので、
`ScrollView` に `frame(width:height:)` + `clipped()` を掛ければよい。切っても
横スクロールで届くので、列が読めなくなるわけではない。

**推測で直さない。** measure してから決める。

```
proxy=769.0  insets=(top: 52, leading: 238, bottom: 0, trailing: 360)
intrinsic=1181.0  columns=[名前, Namespace, Ready, 状態, 再起動, ノード, …]
```

測っている幅（769）は正しく、表の要求幅（1181）が上回っていた、と分かる。
`fputs(..., stderr)` で出すこと — `print` は標準出力が TTY でないと溜め込まれ、
`pkill` で終わらせると**何も残らない**（実際そうなって空のログを見た）。

### 列の定義は body の先頭で 1 度だけ引く

`ClusterStore.currentColumns` は**呼ぶたびに列定義を丸ごと組み立て直す**計算
プロパティ（`ResourceColumn` はクロージャを持つので、そのぶんの確保が毎回走る）。
`ResourceListView` はこれを計算プロパティ越しに参照しており、`row(for:)` の
`ForEach(columns)` が**行の数だけ**呼んでいた。500 行なら 1 描画で 500 回。

いまは `body` の先頭で 1 度だけ引き、`table(columns:)` → `headerRow(columns:)` /
`row(for:columns:)` へ配る。ログの `visibleLines` を body の先頭で 1 度だけ
作るのと同じ話で、**「読むたびに作り直すもの」を描画の内側から呼ばない。**

### 一覧の行はキャッシュする（`filteredObjects`）

計算プロパティにしていたら、1 描画のあいだに**副題・一覧・詳細パネルの内訳・
配置の 2 か所**から読まれ、そのたびに全件の絞り込みが走っていた（5〜6 回）。
`objects` と `searchText` の didSet で 1 度だけ組み直す。

**キャッシュにすると壊れ方が変わる。** 「重い」ではなく「古い」になり、画面に
出ている行が事実とずれる形で出る。組み直しの引き金は
`Tests/KubeDeckTests/FilteringTests.swift` で押さえてある。

**選択中のものも索引で引く。** `objects.first(where:)` は詳細パネルが毎フレーム
呼ぶので行数ぶんの線形探索になる。`objects` の didSet で `objectIndex` を組む。

## メニューバーからも同じ操作を出す

**1 日中触る道具にはショートカットが要る。** ⌘R しか無かった。⌘1 / ⌘2 で
概要 / 配置、⌘F で絞り込み欄、⌘L でログ、⌘E で exec、⌘⌫ で削除。

**中身を自分で決めない。** 「操作」メニューは画面と同じ
`ResourceActionSet` から作る（`ObjectCommands`）。ここだけ別に並べると、種別を
足したときにメニューバーからだけ届かない操作ができる。**全部にショートカットを
付けない** —— 覚えられないし、押し間違いが増えるだけ。

**そのために `ResourceActionHost` の持ち主をアプリに上げた。** コマンドは
ウインドウの外側にいるので、`RootView` の `@State` には手が届かない。上げれば
メニュー・一覧・詳細パネルが同じ 1 つを見る（確認とシートを出すのは
`RootView` の 1 か所のまま）。

**空のメニューにしない。** 何も選んでいないときは「行を選ぶと、ここに操作が
出ます」と書く。項目がゼロだと壊れているように見える。

**`searchFocused(_:)` は使えない。** macOS 15 以降の API で、ここは 14 以降を
対象にしている。窓の themeFrame から `NSSearchField` を探して first responder に
する（**ツールバーの項目から辿らない** —— SwiftUI が載せた項目の `view` は nil の
ことがある）。見つからなければ何もしない（概要のように欄が無い画面でも呼ばれる）。

## ツールバーで踏んだもの

**場所を確保するために透明な項目を置かない。** `ProgressView().opacity(0)` を独立した `ToolbarItem` にすると、隠しても項目の枠が残り、**縦棒が浮いて見える**。

**Menu のラベルに `ProgressView` を入れても、ツールバーでは描画されない。** アイコンが空のボタンになる。取得中の合図は副題（`navigationSubtitle`）に文字で出している。

**メニューはアイコンだけにしない。** ツールバーの `Menu` は既定でアイコンのみになる。コンテキストと Namespace は取り違えると影響が大きいので `.labelStyle(.titleAndIcon)` で名前を常に出す。そのぶん副題からは同じ情報を落とす（二重に出すとどちらが操作対象か紛れる）。

### ツールバーの項目集合を画面ごとに変えない（落ちる）

**`.searchable` を画面ごとに付け外しすると落ちる。** 以前は「一覧にだけ付ける」
（概要には絞り込む相手がいないため）とし、`ResourceListView` と `PlacementView` が
それぞれ持っていた。だがこの 2 つは `RootView.detail` の switch の枝なので、
概要 → 一覧では項目が**足され**、配置 → 一覧では**外して足す**。ツールバーの
更新は `NSHostingView.layout` の最中に `ToolbarBridge` 経由で走るため、
レイアウト中の `NSToolbar` の書き換えになり、例外でアプリごと落ちる。

```
objc_exception_throw
-[NSToolbar _insertNewItemWithItemIdentifier:atIndex:propertyListRepresentation:notifyFlags:]
SwiftUI.AppKitToolbarStrategy.updateToolbar
SwiftUI.ToolbarBridge.preferencesDidChange
SwiftUI.NSHostingView.layout          ← レイアウトの最中
+[NSApplication _crashOnException:]
```

**`VSplitView` の件（別項）と混ぜない。** どちらも
`-[NSView _layoutSubtreeWithOldSize:]` → `_crashOnException:` で終わるので
スタックの末尾はよく似ているが、**投げているものが違う**。区別は `.ips` の
`asiBacktraces` の先頭（`NSToolbar` か `NSSplitView` か）で付く。集めた
クラッシュログ 11 件のうち 9 件がツールバー側だった。

いまは `RootView.detailWithSearch` が 1 つだけ持ち、**変わるのは文言と
有効・無効だけ**にしてある。項目の数は常に同じ。

**`.disabled` を本体やツールバーに掛けない。** 概要では欄を無効にしたいが、
`.searchable` に続けて `.disabled` を書くと、同じ subtree にいる詳細ビューと
ツールバーまで無効になる（実際、概要でコンテキスト・Namespace・再読み込みが
灰色になり、取得に失敗したときの「もう一度試す」も押せなくなった）。
`ZStack` の兄弟に `Color.clear.searchable(...)` として分け、そちらにだけ
`.disabled` を掛ける（`.allowsHitTesting(false)` で下の一覧の操作を邪魔しない）。

**「打てない欄」は「打てるのに何も起きない欄」より良い。** 元の規則が避けたかった
のは後者なので、無効にして出すことで意図は保てる。

## 詳細パネルは選択の「有無」に連動させない。出す方向だけ人に従う

`.inspector` は現れるときに、その列を作るぶんウインドウを広げる。表示を選択に
連動させると、左で種別を選ぶたびに窓の幅が変わる。畳むのはツールバーのボタンだけが
決める。**選択の有無で `isPresented` を切り替えない。**

**ただし、畳んだまま行を選べる状態を行き止まりにしない。** 畳んでいるときに Pod を
選んでも何も出ないのでは、詳細を見るのにいちどツールバーへ寄る必要がある（毎回そう
なる）。`ClusterStore.inspectorRevealRequests`（**人が行やタイルを押した回数**）を
`RootView` が見て、畳んでいれば出す。

- **`selectedObjectID != nil` から導かない。** 導くと種別を移った直後の選び直しや
  自動更新でもパネルが出入りし、そのたびに窓の幅が変わる（この節の元の判断）。
  数えるのは押されたことだけ。
- **片方向。** 選択が無くなっても勝手には畳まないので、✕ が効かないものには
  ならない（**次に押すまで畳んだまま**。ログの「閉じたのに選ぶたび開き直す」と
  同じ落とし穴を避ける）。
- **回数で渡す。** `selectedObjectID` の変化を見ると、いちど畳んでから**同じ行を
  押し直したとき**に何も起きない。
- **右クリックの選び直しでは出さない**（`selectOnly(_:reveal:)` の `reveal: false`）。
  あれは「まず選ぶ」ための選択で、詳細を見に来たわけではない。出すとメニューが
  開いている最中にウインドウが広がる。
- **映すものが無いときは出さない。** ⌘ クリックで最後の 1 つを外した、種別を移った、
  まとめて消した直後。
- 列を広く見たくて畳んでいる人には邪魔なので、`Preferences.opensInspectorOnSelection`
  で切れる（既定は入り）。

引き金は `SelectionTests`（「畳んでいる詳細パネルを出す合図」）で固めてある。

そのぶん選択が無いときもパネルは残るので、そこにはクラスタの要約を出す（`ClusterSummaryPane`）。

**概要を読む前の件数を 0 と書かない。** ワークロード一覧から起動すると `overview` は空のままで、そこを素直に表示するとノード 0 / Pod 0 と出る。「まだ数えていない」と「0 件ある」は別物なので、`hasOverviewData` が偽のあいだは行ごと出さない。

### 右か下かは選べる。ただし帯は 1 つ

列の多い一覧（Pod に metrics-server の列が付いた状態）では右の欄が一覧を押し、
縦に長い一覧では下の帯が行を隠す。どちらが邪魔かは見ているものによるので、
置き場所を `Preferences.inspectorPlacement` に持つ（`InspectorPlacement`）。

**`.inspector` を外さない。** あれは `NSSplitView` そのもので、付け外しは
ビュー階層から split view が消えることになる（`VSplitView` の件と同じ危うさ）。
下に置いているあいだは `isPresented` を false に固定するだけにし、**中身も
作らない** — 作ると詳細パネルが 2 つ生き、イベントの取得が両方から走る。

**ログと上下に積まない。** 下に置いた詳細とログは同じ帯に**横並び**で入れる
（ログが伸び縮み、詳細が右で固定幅）。積むと仕切りが 2 本になり、帯を 2 倍に
広げないとどちらも数行しか残らない。高さは 1 つ（`dockHeight`）で済む。
詳細を右端に置くのは、右から下ろしたときに左右の関係が変わらないため。

**幅を `GeometryReader` の中で決める。** `frame(width:)` は縮められない最小幅に
なるので、そのまま置くと窓が狭いときにサイドバーの左端が切れる（`TraceMapView`
で踏んだのと同じ）。`GeometryReader` は提案された大きさをそのまま受けるので、
中で決めた幅は外へ出ない。測った幅で上限（6 割）も掛けられる。

**下に置いたときは節を段に割る**（`Views/SectionColumns.swift`）。1 列のまま
1,000pt に伸ばすと、見出しと値が画面の端どうしに離れて対応が読めなくなるうえ、
縦は足りないので何を見るにもスクロールすることになる。**置き場所を見て分岐
しない** — 段が増えるのは 1 段が 320pt を満たすときだけなので、右の欄
（300〜560pt）では自然に 1 列のまま。パネルの幅を変えたときも同じ規則で動く。
タブの切り替え（`Picker`）も横いっぱいに伸ばさない（420pt で止める）。

**`Layout` に来る幅を有限だと思わない。** SwiftUI は「いちばん広いとき」を訊く
ために `.infinity` を提案してくる（`ScrollView` の中で実際に来る）。段の数を
`Int(width / …)` で出していたら **`Int(.infinity)` がトラップして起動直後に
落ちた**（`EXC_BREAKPOINT` / `Double value cannot be converted to Int`）。
**`replacingUnspecifiedDimensions()` は nil を埋めるだけで、無限はそのまま通る。**
落ちたかどうかは `~/Library/Logs/DiagnosticReports/KubeDeck-*.ips` で分かるが、
**`ls -lt` は使わない** — この環境の `ls` は eza の別名で、そのままではオプションを
弾かれて**一覧が空に見える**（`/bin/ls` を使う）。

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
