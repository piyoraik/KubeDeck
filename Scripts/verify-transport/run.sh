#!/usr/bin/env bash
#
# 読み取りの経路（常駐 `kubectl proxy` ＋ HTTP）を、**実クラスタに当てて**
# 確かめる。アプリの実コード（`Kubectl` / `ClusterProxy` / `APIClient` /
# `APIDiscovery`）をそのまま呼ぶので、画面を通さずに通る道を叩ける。
#
#   Scripts/verify-transport/run.sh kind-kubedeck
#   Scripts/verify-transport/run.sh <context> --switch=<別のコンテキスト>
#   Scripts/verify-transport/run.sh <context> --namespace=kube-system
#
# **既定は読み取りだけ。** クラスタに何も書き込まない（他人のクラスタに
# 当てても安全）。CRD と「権限で一部だけ拒まれる」経路まで見たいときは、
# 先に `fixtures.sh up` で kind に材料を置く（**kind 専用**。終わったら
# `fixtures.sh down`）。
#
#   Scripts/verify-transport/fixtures.sh up
#   Scripts/verify-transport/run.sh kind-kubedeck
#   KUBECONFIG=Scripts/verify-transport/nobody.kubeconfig \
#     Scripts/verify-transport/run.sh kind-kubedeck --expect-denied
#   Scripts/verify-transport/fixtures.sh down
#
# **単体テストの代わりではない。** あちらは合成 JSON で判断を固定するもので、
# こちらは「実際のクラスタで、実際の kubectl と同じ数字になるか」を見る。
# 実測でしか出なかった壊れ方（Connect Gateway でパスが落ちて全 API が 404、
# metadata だけで引くと件数が空欄、立ち上げに相乗りした側が畳まれた proxy を
# 受け取る）は、どれもここで見つかっている。
set -euo pipefail

cd "$(dirname "$0")/../.."
ROOT="$PWD"
OUT="$ROOT/build/verify-transport"
mkdir -p "$OUT"

SOURCES="$ROOT/Sources/KubeDeck"
# **アプリのコードは 1 行も変えない。** Sparkle に依存する `UpdateController`
# だけ、形を合わせたスタブに差し替える（そこを引きずり込むと建たない）。
swiftc -swift-version 6 -O -o "$OUT/verify-transport" \
  "$ROOT/Scripts/verify-transport/main.swift" \
  "$ROOT/Scripts/verify-transport/Stub.swift" \
  "$SOURCES"/Models/*.swift \
  "$SOURCES/Services/Kubectl.swift" \
  "$SOURCES/Services/ClusterProxy.swift" \
  "$SOURCES/Services/APIClient.swift" \
  "$SOURCES/Services/APIDiscovery.swift" \
  "$SOURCES/Services/ProcessRunner.swift" \
  "$SOURCES/Services/LoginShell.swift" \
  "$SOURCES/Services/PrometheusClient.swift"

exec "$OUT/verify-transport" "$@"
