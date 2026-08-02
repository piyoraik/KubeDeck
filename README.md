# KubeDeck

[Kubernetes Dashboard](https://kubernetes.io/ja/docs/tasks/access-application-cluster/web-ui-dashboard/) 相当の画面を、macOS ネイティブアプリとして持つもの。ブラウザも `kubectl proxy` も要らず、`~/.kube/config` にあるクラスタをそのまま開く。

SwiftUI / Swift 6 / macOS 14 以降。

## 入れる

[Releases](https://github.com/piyoraik/KubeDeck/releases/latest) から `KubeDeck-<版>.dmg` を落とし、`KubeDeck.app` を `Applications` へドラッグする。

**初回だけ、隔離属性を外す必要がある。**

```bash
xattr -dr com.apple.quarantine /Applications/KubeDeck.app
```

配布物は ad-hoc 署名で、Apple の公証（notarization）を通していない。ダウンロードした
ファイルには macOS が隔離属性を付けるので、そのまま開こうとすると「開発元を検証できない」
「壊れている」と言われて起動できない。上のコマンドで属性を外せば普通に起動する
（Finder で右クリック →「開く」でも同じことができる）。

一度入れたあとは、**アプリが自分で新しい版を見にいく**。見つかると知らせが出て、その場で
入れ替えられる（入れ替え後は隔離属性の作業も要らない）。確認する / しない、間隔、
先に落としておくかは 設定（⌘,）の「更新」タブで変えられる。確認は GitHub の Releases に
置いた更新情報を読むだけで、クラスタの情報も利用状況も送らない。

## できること

**概要** — Pod・ワークロード・ノードの状態をドーナツで、リソース件数をタイルで、直近のイベントを一覧で。タイルを押すとその一覧へ飛ぶ。

**一覧** — 種別ごとに列を変えて表示する。kubectl の `-o wide` に相当する列を出し、STATUS は kubectl と同じ判定で出す（`CrashLoopBackOff` を `Running` と表示しない）。問題のあるものが上に来る順で並ぶ。名前・Namespace・ラベル・セルの中身を横断して絞り込める。

| 分類 | 種別 |
|---|---|
| ワークロード | Pod / Deployment / ReplicaSet / StatefulSet / DaemonSet / Job / CronJob |
| ネットワーク | Service / Ingress |
| 設定と保存 | ConfigMap / Secret / PersistentVolumeClaim |
| クラスタ | Node / Namespace / PersistentVolume / Event |
| カスタムリソース | クラスタに入っている CRD を API グループごとに（Argo CD の Application、cert-manager の Certificate など） |

CRD の一覧は、CRD 自身が宣言している表示列（`additionalPrinterColumns`）をそのまま出すので、`kubectl get` と同じ列が並ぶ。

**詳細パネル** — 3 つのタブ。**概要**は基本情報・使用量・推移・コンテナ・条件・ラベル。**設定**は種別ごとに項目を選んだ表（配置・ネットワーク・権限・コンテナごとのイメージやプローブなど）。API のフィールド名ではなく日本語の見出しで、未設定の項目も薄く並ぶ。CRD はスキーマが分からないので木で出す。**YAML** は `kubectl get -o yaml` そのまま（折り返しの切り替えあり）。

**ログ** — `kubectl logs` の追従を一覧の下のパネルに出す。仕切りで高さを変えられ、開いたまま一覧を操作できる。コンテナの切り替え、追従、折り返し、時刻表示、`--previous`、行の絞り込み、表示中の行のコピー。複数の Pod を並べて見たいときは別ウインドウにも出せる。

**設定（⌘,）** — 4 つのタブ。

| タブ | 項目 |
|---|---|
| 一般 | 起動時に開く画面、サイドバーの件数表示 / CRD の表示 / 0 件の種別を隠す、**出す種別の取捨選択**、一覧の行の詰め方、すべて既定値に戻す |
| ログ | 選択への追従、開いたときの既定（追従 / 折り返し / 時刻）、遡って読む行数、画面に残す上限 |
| メトリクス | 取得元（自動 / metrics-server / Prometheus）、推移の範囲と取り直す間隔、使用率のしきい値、検出結果と再検出、Prometheus の手動指定 |
| 接続 | 自動更新と間隔、kubectl の待ち上限、kubectl の場所（手動指定と解決結果の表示） |

設定の定義は `Sources/KubeDeck/Models/Preferences.swift` に集めてある。項目を足すときはそこと `SettingsView` の 2 か所で済む。

**メトリクス** — metrics-server が入っていれば Pod と Node の一覧に CPU / メモリの列が出て、概要にクラスタ全体の使用率が出る。Node は allocatable、Pod は requests を分母にした割合も添える。Prometheus（Thanos / VictoriaMetrics 互換も）が見つかれば、直近 30 分の推移をスパークラインで出す。接続は API サーバのプロキシ経由なので port-forward は不要。どちらも入っていなければ、その部分を出さないだけで他は普通に動く。

**操作** — 削除、Deployment / StatefulSet / ReplicaSet のレプリカ数変更、ローリング再起動、ノードの cordon / uncordon。削除は確認を挟む。

**クラスタの稼働表示** — ツールバーと概要の見出しに Kubernetes 公式ロゴを置いている。回転が稼働の合図で、取得中は速く、自動更新が生きているあいだはゆっくり右回りに回り、自動更新を切ると止まる。回転は Core Animation に任せてあるので、回っていてもアプリの CPU は 0%。異常があるときだけ隅に状態のしるしが付き、同じ内容を文字でも出す。

**そのほか** — コンテキストと Namespace の切り替え、自動更新（5 / 10 / 30 / 60 秒）、⌘R で再読み込み。コンテキストと Namespace の選択は次回起動時に復元される。

## 必要なもの

`kubectl` が入っていること。Homebrew (`/opt/homebrew/bin`)、`/usr/local/bin`、krew、gcloud SDK の場所は自動で探す。

クラスタへの接続は kubectl 経由なので、`kubectl` で繋がるクラスタはそのまま繋がる。EKS や GKE の exec 認証プラグイン、クライアント証明書、OIDC も kubeconfig の設定がそのまま効く。

## ビルド

```bash
brew install xcodegen   # 未導入なら
xcodegen generate
xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
  -configuration Debug -destination 'platform=macOS' build
```

`project.yml` がソースオブトゥルースで、`.xcodeproj` は生成物。直接編集しない。

## リリースする

タグを打つと GitHub Actions が焼いて Releases に上げる。

```bash
git tag v0.2.0
git push origin v0.2.0
```

| 上がるもの | 何に使うか |
|---|---|
| `KubeDeck-<版>.dmg` | 人が手で入れる |
| `KubeDeck-<版>.zip` | Sparkle が落としてくる |
| `appcast.xml` | 更新の目録。アプリの `SUFeedURL` が指している |

`SUFeedURL` は `releases/latest/download/appcast.xml` を指している。GitHub の `latest` は
常に最新の「プレリリースでない」リリースを指すので、版を出すたびに URL を書き換えなくてよい。
逆に言うと、**プレリリースとして出したものは既存の利用者に配られない**（試し焼きに使える）。

手元で同じものを焼くこともできる。

```bash
./Scripts/release.sh 0.2.0    # dist/ に 3 つ出る
```

版はここで注入するので、`project.yml` の `MARKETING_VERSION` を書き換える必要はない。

### 署名の鍵

更新の検証は EdDSA 署名で行う。秘密鍵は login キーチェーンの
「Private key for signing Sparkle updates」にあり、CI へは Secrets の
`SPARKLE_PRIVATE_KEY` で渡している（`generate_keys -x` で書き出したもの）。
公開鍵は `project.yml` の `SUPublicEDKey`。

**この鍵を失うと、既に配ったアプリへ更新を届けられなくなる。** 新しい鍵で署名しても、
手元のアプリが持っている公開鍵と合わないので拒まれる。バックアップを取っておくこと。

## 権限について

App Sandbox は無効。`kubectl` を子プロセスとして起動し、`~/.kube/config` を読むため。署名は ad-hoc で、公証は通していない。

Apple Developer Program に入って Developer ID で署名・公証すれば、隔離属性の作業は要らなくなる。
そのときは `project.yml` の `CODE_SIGN_IDENTITY` と `ENABLE_HARDENED_RUNTIME`（公証には必須）を
変え、CI に証明書と App Store Connect の鍵を持たせる。**`SUPublicEDKey` は変えない。**
Sparkle は新旧の公開鍵が一致していれば署名 identity の変化を許すので、鍵を据え置けば
既存の利用者もそのまま公証済みの版へ更新できる。

## ロゴについて

舵輪は 2 つあり、持ち場が違う。**画面内**は Kubernetes 公式ロゴ（CNCF / The Linux
Foundation, CC BY 4.0）で、「これは Kubernetes を見ている」というしるし。
`Sources/KubeDeck/Views/KubernetesLogo.swift` は公式 SVG のパスを正規化したもの。

**App アイコン**は独自に引いた舵輪で、公式ロゴの図形は使っていない。定義は
`Scripts/KubeDeckLogo.swift` の 1 か所にあり、PNG も `Design/*.svg` もそこから生成する。

```bash
./Scripts/generate-icon.sh   # Resources/Assets.xcassets/AppIcon.appiconset/*.png
./Scripts/generate-svg.sh    # Design/kubedeck-{icon,mark,mark-mono}.svg
```

| ファイル | 用途 |
|---|---|
| `Design/kubedeck-icon.svg` | App アイコン（角丸の下地に白い舵輪） |
| `Design/kubedeck-mark.svg` | マーク単体・青一色・背景なし |
| `Design/kubedeck-mark-mono.svg` | 同上、色は `currentColor` に従う |
