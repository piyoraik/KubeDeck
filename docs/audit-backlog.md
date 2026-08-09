---
type: 作業一覧
状態: 未着手（2026-08-09 の監査で挙がり、その回では直さなかったもの）
---

# 監査の残り

2026-08-09 に、セキュリティ・並行性・モデルの正しさ・UI/UX を通しで精査した。
**確定した 24 件はその場で直してある**（`git log` と CLAUDE.md の各節に根拠がある）。
ここに残すのは、同じ精査で挙がったが**その回では手を付けなかったもの**。

判断の根拠は CLAUDE.md 側にあるので、ここには「何を・なぜまだやっていないか」だけ書く。
**「無い」と「取れていない」を混ぜない**をはじめとする既存の規則は、直すときも当然守る。

## 決定済み（蒸し返さない）

- **Apple Developer に登録しない。Hardened Runtime も入れない。**
  実測の根拠は CLAUDE.md「Hardened Runtime は入れない」。
  代わりに **README に「何が守られていないか」を書く**（下の R-1）。
- **push しない。** リリースの予定が無い。`main` は origin より進んでいるが、
  それでよい（`build.yml` は push で動く。`release.yml` はタグでしか動かない）。
  コミットはする。

## 着手する順

**一度に全部やらない。** 1 回のセッションで見るのは下の 1 段だけにする。
段を終えたらコミットして、`/clear` してから次の段に移る。

1. **D**（前回の修正が残した不整合・言い過ぎ）— 自分で入れたものなので先に消す
2. **R-1**（README に何が守られていないかを書く）
3. **S-3 / S-4**（denylist の取りこぼし、Sparkle ツールのハッシュ固定）
4. **U-1 / U-2**（シートにクラスタ名が出ない、件数が 0 と未取得を潰す）
5. **A**（アクセシビリティ。CLAUDE.md がまったく扱っていない領域なので、
   方針を 1 節書き足すところから）
6. **C**（並行性・性能）と **U** の残り
7. **S-1 / S-2**（上限の話。文言の設計が要るので最後）

**着手前に案を出して確認を取るもの:**

- **U-1** — 6 つのシートに同じ 1 行を足すか、共通の見出しを作るか。CLAUDE.md は
  「操作ごとに書くと足したものだけ書き忘れる」と言っているので後者に寄せたいが、
  難点も一緒に出してから決める。
- **S-3** — denylist に語を足すだけか、「既定で伏せてホワイトリストで見せる」へ
  反転するか。反転は切り分けに要る値まで隠す危険がある。
- **S-2** — 落とした行を数えて帯に出せる形にできるか。できないなら入れない。

## R. 見送りの明示

| id | 内容 | いまの状態 |
|---|---|---|
| R-1 | ad-hoc 署名で何が守られないかを README に書く | **未着手。** 「同じユーザ権限の攻撃者は前提に入っていない」ことを明記する。**「安全」と書かない** |

## S. セキュリティ・堅牢性

| id | 内容 | なぜまだか |
|---|---|---|
| S-1 | `ProcessRunner.runSynchronously` の `readToEnd()` が上限なし | 巨大／敵対的な応答で OOM しうる。上限を入れると「切り捨てた」旨の文言と `CommandResult` の変更が要る。**切ったことを黙らない**のが条件 |
| S-2 | ログの `AsyncStream` が `.unbounded` | 消費が追いつかないと伸び続ける。`.bufferingNewest` は**黙って行を落とす**ので、そのままでは「捨てた行を黙らない」に反する。落とした数を数えて帯に出せる形なら入れてよい |
| S-3 | `Kubectl.secretHints` の取りこぼし | `MYSQL_PWD` / `GH_PAT` / `STRIPE_SK_LIVE` は今も平文で出る。denylist の限界そのものなので、**既定を伏せてホワイトリストで見せる**への反転が根治 |
| S-4 | `Scripts/release.sh` が Sparkle のツールをハッシュ検証なしで取得 | `sign_update` は秘密鍵を扱う当人。`shasum -c` 1 行で済む |
| S-5 | `Kubectl.logArguments` が `checkedName` を通らない | 純粋関数＋テスト契約のため見送り。フラグ化だけは `pod/<名前>` 前置で塞いである |

## D. 直した側に残った言い過ぎ・不整合（自分で入れたもの）

| id | 場所 | 内容 |
|---|---|---|
| D-1 | `PlacementView` の「小」タイル | 状態記号を**無条件で**入れたので、正常な Pod にも合格印が付く。CLAUDE.md「正常なときは付けない（合格印で埋め尽くさない）」と逆。**異常のときだけ出す**（色と `accessibilityLabel` は残す） |
| D-2 | `Kubectl.looksLikeFilePath` の doc | 「base64 の字種に `.` は無い」は正しいが **`/` はある**ので、保護を過大に書いている。実際に守っているのは先に走る名前判定のほう |
| D-3 | `RootView.splitError` の doc | 「空行が無いものは 4 行目で切る（帯が出す行数と揃える）」が stale。帯の `lineLimit(4)` は外した |
| D-4 | `InspectorView.ListSummaryPane.header` | 件数を落としたので `Spacer(minLength: 6)` が意味を失っている |

## A. アクセシビリティ（CLAUDE.md がまったく扱っていない領域）

| id | 内容 |
|---|---|
| A-1 | 一覧の行・ログの行・イベントの行・コンテナの行が、VoiceOver に**バラバラの文字列**として届く（`List` を捨てた副作用）。各 row builder に `.accessibilityElement(children: .combine)`、一覧は `.isSelected` も |
| A-2 | 「たどる」の**ワークロードの器だけ Button でない**（`onTapGesture`）ので、キーボードで到達も起動もできない。兄弟の器は正しく Button |
| A-3 | 仕切り（`PanelResizeHandle`）にキーボード代替が無く、`.accessibilityLabel` の付く先も無い。`.accessibilityAdjustableAction` を足す |
| A-4 | コンテキスト色帯の白文字が **黄 2.43:1 / 橙 3.22:1 / 緑 4.09:1**（WCAG 未達）。明るい tint では黒文字に切り替える。**状態の 4 色には触らない** |
| A-5 | ポイント固定フォント約 30 か所が拡大文字に追従しない。とくに `PlacementView` の状態記号 8pt と、drain / rollback の dry-run 出力 11pt（固定高と併用） |

## U. UI/UX

| id | 内容 |
|---|---|
| U-1 | **操作シート 6 つにクラスタ名が出ない**（Drain / Rollback / Scale / YAML 編集 / Resources / Exec）。確認ダイアログ 2 か所にしか入っていない。CLAUDE.md が「操作ごとに書くと書き忘れる」と予告した形。dev と prod に同名 `api` があると見分けが付かない |
| U-2 | サイドバーの件数が `count > 0` の条件付きなので、**「本当に 0 件」と「まだ数えていない」が同じ見た目**になる。`ClusterStore` 側はわざわざ 0 で埋めているのに、表示層が打ち消している |
| U-3 | ConfigMap の `binaryData` を見ていないので、バイナリだけの ConfigMap が「データ 0 / キー 未設定」になる |
| U-4 | 「たどる」（`.map`）でだけ `partialDataNotice` の帯が出ない。Service を読めないクラスタで「Service がありません。」と断定する |
| U-5 | 設定の Prometheus 行が、探索前も失敗も同じ「見つかりません」。真上の metrics-server 行は「確認中」を出せる（同じ節で規則が違う） |
| U-6 | `RollbackSheet` で取得失敗が「戻す先の中身」として表示され、「戻す」も押せたまま |
| U-7 | `DrainSheet` の「このままでは止まります」が、接続失敗や権限エラーでも出る（PDB の話に見える） |
| U-8 | 「すべて既定値に戻す」の文面が、失うもの（外した種別・使用率のしきい値・**kubectl の場所の指定**）を名指ししていない |
| U-9 | ログの絞り込み欄まわり: 固定幅 200pt で狭い欄に収まらない／欄の出し分けが実測幅を見ていない／Escape で消せない・⌘F が一覧の欄へ飛ぶ |
| U-10 | 切れる名前に `.help` が無い箇所が多数（設定のコンテキスト名、配置のノード名・ワークロード名、概要のイベント本文など） |
| U-11 | エラー帯を開いた状態だと成功の札が重なる（`padding(.bottom, 96)` 固定）／setup 失敗だけ「もう一度試す」が無い／Namespace メニューが空のとき理由が出ない |

## C. 並行性・性能

| id | 内容 |
|---|---|
| C-1 | Namespace に紐づく非同期の書き込み（`refreshSidebarCounts` / `refreshMetrics` / `detectMetricsSources`）が `contextGeneration` しか見ていない。Namespace を変えても進まないので、**古い Namespace で数えた結果が新しい Namespace の状態として書き込まれる** |
| C-2 | `bootstrap()` 中にコンテキストを切り替えると、`isBootstrapping` の guard で reset も reload もされない（ツールバーは操作できる状態） |
| C-3 | `recoverClusterInfoIfNeeded()` を待つあいだ `isLoading` / `isFetching` が下りないので、一覧が出ているのにスピナーと自動更新の停止が続く。順序の入れ替えだけ |
| C-4 | `Preferences.resetAll()` が `ClusterStore` の写し（`autoRefresh` / `refreshInterval` / `metricsPreference`）を戻さない |
| C-5 | `SpecOutline` の `leafCount` が描画のたびに部分木を歩く／配列の子の id が `name` 重複で衝突しうる |
| C-6 | `ResourceKind(apiKind:)` が毎回 33 件の線形探索（オブジェクト 1 件につき 1 回）。`static let byAPIKind` 辞書で消える |
| C-7 | `LogContent.consume` の `var next = lines` が塊ごとに最大 5,000 要素の CoW コピー |

## 直すときの作法（このリポジトリの既存の規則）

- **測ってから「直した」と書く。** 2026-08-09 の回で、`ProcessRunner` のスレッド枯渇を
  `ioQueue` を分けて直したことにしかけた。実測すると**数字が 1 つも動いていなかった**
  （上限は root queue 単位）。`release.sh` の appcast 署名で「無い保護を有ると読ませて
  いた」と指摘したのと同じことを、同じ差分の中でやるところだった。
- **表示文言を足したら `Scripts/sync-strings.sh` を引数なしで走らせる。**
  en の訳と、ソース言語 `ja` の項目（`state: translated`）まで埋める。埋めないと
  `ja.lproj` が焼かれない。

  **`--check` で済ませない。** あれは同期せず、いまのカタログを報告するだけ。
  足したばかりの鍵はまだカタログに無いので**現れず、「未訳 0」と出る**。
  2026-08-09 の回で実際にこれを踏み、**CI が落ちる状態のままコミットした**
  （`ScaleSheet` の文言）。押さえるなら、CI と同じくビルド後の `.stringsdata` を
  カタログの**写し**へ sync して見る。写しのファイル名は `Localizable.xcstrings`
  のまま変えない（変えるとテーブル名が一致せず、全鍵が「使われていない」になる）。

- **報告の前に CI の 4 ゲートをローカルで再現する。**
  ① `xcodebuild test`（`TZ=UTC` でも。CI ランナーは UTC）
  ② 訳の確認（上のとおり写しに sync）
  ③ Release ビルド
  ④ `codesign --verify --deep --strict`
- **踏んだ間違いだけをテストに固める。** 「そう書いてある」を確かめるテストは足さない。
- CI は未訳・stale の鍵をエラーにする。
