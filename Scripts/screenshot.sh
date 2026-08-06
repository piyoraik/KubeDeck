#!/bin/bash
# 決め打ちの状態でアプリを起こして、窓だけを撮る。
#
# **画面の確認を人に頼まずに済ませるための道具。** UI をテスト対象にしない
# 方針は変えないが、「その画面が本当にそう出ているか」を確かめる手立てが
# 無いままだと、変更のたびに人へ見てもらうことになる（実際そうなった）。
#
#   Scripts/screenshot.sh out.png                       いまの状態のまま撮る
#   Scripts/screenshot.sh out.png pod                    Pod 一覧を開いて撮る
#   Scripts/screenshot.sh out.png podDisruptionBudget ns  Namespace も指定して撮る
#
# 種別の名前は `ResourceKind` の rawValue（`Selection.storageKey`）。
# `overview` と `placement` も渡せる。
set -euo pipefail

DOMAIN="com.piyoraik.KubeDeck"
OUT="${1:?出力先の png を指定してください}"
SELECTION="${2:-}"
NAMESPACE="${3:-}"

APP="$(xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
  -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/KubeDeck.app"
[ -d "$APP" ] || { echo "先にビルドしてください: $APP が見つかりません" >&2; exit 1; }

# **終了させてから設定を書く。** アプリは終了時に自分の設定を書き戻すので、
# 起動中に書くと競合して消える（ウインドウ枠でも選択の復元でも踏んだ）。
pkill -f "KubeDeck.app/Contents/MacOS/KubeDeck" 2>/dev/null || true
sleep 1

if [ -n "$SELECTION" ]; then
  defaults write "$DOMAIN" selection -string "$SELECTION"
  # **書いたら読み直して確かめる。** 競合で消えていても気付けるように。
  [ "$(defaults read "$DOMAIN" selection)" = "$SELECTION" ] \
    || { echo "selection を書き込めませんでした" >&2; exit 1; }
fi
if [ -n "$NAMESPACE" ]; then
  defaults write "$DOMAIN" selectedNamespace -string "$NAMESPACE"
fi

open "$APP"

# 一覧が埋まるまで待つ。**固定で待たない** —— 窓が出るまでの時間は
# クラスタの応答で変わる。窓が見えてから、描画のぶんだけ足す。
WINDOW=""
for _ in $(seq 1 40); do
  WINDOW="$("$(dirname "$0")/window-id.swift" 2>/dev/null || true)"
  [ -n "$WINDOW" ] && break
  sleep 0.5
done
[ -n "$WINDOW" ] || { echo "KubeDeck の窓が見つかりません" >&2; exit 1; }
sleep 2.5

# `-o` は影を除く（窓の大きさと画像の大きさを一致させるため）。
# `-x` は撮影音を鳴らさない。
screencapture -x -o -l "$WINDOW" "$OUT"
echo "$OUT ($(sips -g pixelWidth -g pixelHeight "$OUT" | awk '/pixel/{printf "%s ", $2}'))"
