#!/bin/bash
#
# 表示文言の鍵を String Catalog（`Resources/Localizable.xcstrings`）へ同期し、
# 訳の埋まり具合を報告する。
#
#   Scripts/sync-strings.sh            同期して報告する
#   Scripts/sync-strings.sh --check    同期せず、いまのカタログを報告するだけ
#
# **鍵を手で足さない。** 鍵は日本語の原文そのもので、コードが渡すものと
# 1 文字でも違うと訳が当たらず、日本語のまま出る。**しかもどこも失敗しない**
# ので、気付く手立てがこの報告しかない。
#
# **`xcstringstool extract` で済ませない。** あちらはソースを型を見ずに読むので、
# 補間の書式指定子が `%arg` のままになる。実際の鍵は型で決まる（`%lld` /
# `%@` / `%.1f`）ため、抽出だけで作った鍵は当たらない。ここではコンパイラが
# 吐く `.stringsdata`（`SWIFT_EMIT_LOC_STRINGS`）を通す。
set -euo pipefail

cd "$(dirname "$0")/.."

CATALOG="Resources/Localizable.xcstrings"
XCSTRINGSTOOL="$(xcode-select -p)/usr/bin/xcstringstool"

if [[ "${1:-}" != "--check" ]]; then
  # 建ててから同期する。`.stringsdata` は SwiftCompile が吐くので、
  # 変更したあと建て直さないと**消えた鍵が残り、増えた鍵が来ない**。
  echo "==> 建てる（.stringsdata を作らせる）"
  LOG=$(mktemp -t kubedeck-sync-strings)
  # **`head` に通さない。** パイプを早く閉じると xcodebuild が居残り、
  # `XCBuildData/build.db` を握ったまま次のビルドを `database is locked` で
  # 落とす（CLAUDE.md の「ビルド」の節）。
  if ! xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
      -configuration Debug -destination 'platform=macOS' build > "$LOG" 2>&1; then
    echo "ビルドが通らないので同期しない（鍵が欠けたまま同期すると、"
    echo "まだ使われている訳を stale として落としてしまう）" >&2
    grep -E "error:" "$LOG" | sort -u | head -20 >&2
    exit 1
  fi

  OBJROOT=$(xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
    -configuration Debug -destination 'platform=macOS' \
    -showBuildSettings 2>/dev/null | awk '/ OBJROOT = /{print $3}')

  # アプリのターゲットのぶんだけを拾う。テストのターゲット
  # （`KubeDeckTests.build`）に落ちる `.stringsdata` は混ぜない —— テストの
  # 文言はアプリの表示ではないし、混ぜると訳の要る鍵として並ぶ。
  #
  # **`mapfile` を使わない。** macOS の `/bin/bash` は 3.2 で、あれは無い
  # （`command not found` にならず、配列が空のまま進む壊れ方をする）。
  ARGS=()
  COUNT=0
  while IFS= read -r file; do
    ARGS+=("--stringsdata=$file")
    COUNT=$((COUNT + 1))
  done < <(find "$OBJROOT/KubeDeck.build" \
    -path "*/KubeDeck.build/Objects-normal/*" -name "*.stringsdata" | sort)

  if [[ $COUNT -eq 0 ]]; then
    echo "'.stringsdata' が 1 つも無い。SWIFT_EMIT_LOC_STRINGS を確かめること" >&2
    exit 1
  fi

  echo "==> 同期する（.stringsdata $COUNT 個）"
  "$XCSTRINGSTOOL" sync "$CATALOG" "${ARGS[@]}"
fi

echo "==> 報告"
python3 - "$CATALOG" <<'PY'
import json, sys

catalog = json.load(open(sys.argv[1]))
source = catalog["sourceLanguage"]
strings = catalog["strings"]

# ソース言語（ja）は鍵そのものなので数えない。訳が要るのはそれ以外。
targets = sorted({lang
                  for entry in strings.values()
                  for lang in entry.get("localizations", {})
                  if lang != source} | {"en"})

print(f"鍵 {len(strings)} 件（ソース言語 {source}）")
for lang in targets:
    done, review, missing = [], [], []
    for key, entry in strings.items():
        # `shouldTranslate: false` は訳さないと決めたもの。分母から外す。
        if entry.get("shouldTranslate") is False:
            continue
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit")
        if unit is None or not unit.get("value"):
            missing.append(key)
        elif unit.get("state") == "needs_review":
            review.append(key)
        else:
            done.append(key)
    total = len(done) + len(review) + len(missing)
    print(f"  {lang}: 訳あり {len(done)} / 要確認 {len(review)} / 未訳 {len(missing)}"
          f"（対象 {total}）")
    # **未訳を黙って通さない。** 未訳は日本語のまま出るだけで、どこも
    # 失敗しない。名前を出しておかないと気付く手立てが無い。
    for key in missing[:20]:
        print(f"    未訳: {key!r}")
    if len(missing) > 20:
        print(f"    未訳: 他 {len(missing) - 20} 件")
PY
