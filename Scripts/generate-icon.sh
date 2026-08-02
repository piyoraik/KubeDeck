#!/bin/bash
# App アイコンの PNG と、単体で使える .icns を作り直す。
# 図形は Scripts/KubeDeckLogo.swift を共有する（写さない）。
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

icons="$root/Resources/Assets.xcassets/AppIcon.appiconset"
swiftc -O -o "$tmp/icongen" \
  "$root/Scripts/generate-icon.swift" \
  "$root/Scripts/KubeDeckLogo.swift"
"$tmp/icongen" "$icons"

# アプリのビルドを通さずにアイコンを見たい・配りたいときのために .icns も置く。
# Assets.xcassets から作られる AppIcon.icns は DerivedData の中にしか出ないので、
# それだけだとリポジトリを見てもアイコンの実体が無いように見える。
set="$tmp/KubeDeck.iconset"
mkdir -p "$set"
cp "$icons/icon_16.png"   "$set/icon_16x16.png"
cp "$icons/icon_32.png"   "$set/icon_16x16@2x.png"
cp "$icons/icon_32.png"   "$set/icon_32x32.png"
cp "$icons/icon_64.png"   "$set/icon_32x32@2x.png"
cp "$icons/icon_128.png"  "$set/icon_128x128.png"
cp "$icons/icon_256.png"  "$set/icon_128x128@2x.png"
cp "$icons/icon_256.png"  "$set/icon_256x256.png"
cp "$icons/icon_512.png"  "$set/icon_256x256@2x.png"
cp "$icons/icon_512.png"  "$set/icon_512x512.png"
cp "$icons/icon_1024.png" "$set/icon_512x512@2x.png"
mkdir -p "$root/Design"
iconutil -c icns "$set" -o "$root/Design/KubeDeck.icns"
cp "$icons/icon_1024.png" "$root/Design/kubedeck-icon-1024.png"
echo "generated $root/Design/KubeDeck.icns"
