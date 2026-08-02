#!/bin/bash
# KubeDeck のマークの SVG を作り直す。
# 図形は Scripts/KubeDeckLogo.swift を共有する（写さない）。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$root/Design"
swiftc -O -o "$tmp/svggen" \
  "$root/Scripts/generate-svg.swift" \
  "$root/Scripts/KubeDeckLogo.swift"
"$tmp/svggen" "$root/Design"
