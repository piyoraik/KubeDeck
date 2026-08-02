#!/usr/bin/env bash
#
# 1 つの版を焼く。手元でも GitHub Actions でも同じものが出る。
#
#   ./Scripts/release.sh 0.2.0
#
# 出るもの（すべて dist/ の下）
#   KubeDeck-<版>.zip   Sparkle が落としてくる本体
#   KubeDeck-<版>.dmg   人が手で入れるためのもの
#   appcast.xml         更新の目録。Sparkle の SUFeedURL が指している
#
# 秘密鍵は login キーチェーン（「Private key for signing Sparkle updates」）から
# 読む。CI では SPARKLE_PRIVATE_KEY 環境変数に入れておけば、そちらを使う。
# **鍵をファイルに落とさない。** sign_update は標準入力から受け取れる。
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "版を指定してください: ./Scripts/release.sh 0.2.0" >&2
  exit 2
fi
# タグ名（v0.2.0）を渡されても通す。
VERSION="${VERSION#v}"

REPO_SLUG="${REPO_SLUG:-piyoraik/KubeDeck}"
NOTES_FILE="${NOTES_FILE:-}"

cd "$(dirname "$0")/.."
ROOT="$PWD"
DIST="$ROOT/dist"
DERIVED="$ROOT/build/DerivedData"
APP_ZIP="$DIST/KubeDeck-$VERSION.zip"
APP_DMG="$DIST/KubeDeck-$VERSION.dmg"
APPCAST="$DIST/appcast.xml"

rm -rf "$DIST"
mkdir -p "$DIST"

# --- 建てる -----------------------------------------------------------------
# 版はここで注入する。project.yml の値は「タグを打たずに手元で建てたもの」用。
echo "==> xcodegen generate"
xcodegen generate

echo "==> xcodebuild (Release $VERSION)"
BUILD_LOG="$ROOT/build/xcodebuild-$VERSION.log"
mkdir -p "$(dirname "$BUILD_LOG")"
# **出力を head に通さない。** パイプを早く閉じると xcodebuild が居残り、
# 次のビルドが XCBuildData の database is locked で落ちる。
set +e
xcodebuild -project KubeDeck.xcodeproj -scheme KubeDeck \
  -configuration Release -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$VERSION" \
  build > "$BUILD_LOG" 2>&1
STATUS=$?
set -e
if [[ $STATUS -ne 0 ]]; then
  echo "ビルドに失敗しました。最後の 40 行:" >&2
  tail -40 "$BUILD_LOG" >&2
  exit $STATUS
fi

APP="$DERIVED/Build/Products/Release/KubeDeck.app"
[[ -d "$APP" ]] || { echo "KubeDeck.app が見当たりません: $APP" >&2; exit 1; }

# 焼いたものが名乗る版と、これから配る版が食い違っていないか確かめる。
# 食い違ったまま出すと、入れ替えても Sparkle が同じ更新を出し続ける。
BUILT_SHORT=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
BUILT_BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist")
MIN_SYSTEM=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$APP/Contents/Info.plist")
if [[ "$BUILT_SHORT" != "$VERSION" || "$BUILT_BUNDLE" != "$VERSION" ]]; then
  echo "版が一致しません: 指定 $VERSION / bundle $BUILT_SHORT ($BUILT_BUNDLE)" >&2
  exit 1
fi

# ad-hoc 署名が壊れていないこと。Sparkle は「署名付きだったものが署名無しに
# なる」更新を拒むので、ここで崩れていると次の版から更新できなくなる。
echo "==> codesign --verify"
codesign --verify --deep --strict "$APP"

# --- 詰める -----------------------------------------------------------------
echo "==> zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$APP_ZIP"

echo "==> dmg"
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT
# cp ではなく ditto。拡張属性ごと運ばないと署名が崩れる。
ditto "$APP" "$STAGING/KubeDeck.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "KubeDeck $VERSION" -srcfolder "$STAGING" \
  -ov -format UDZO -quiet "$APP_DMG"

# --- 署名して目録を書く -----------------------------------------------------
# 署名に使う道具は、実際に組み込んだ Sparkle と同じ版のものを取る。
# **版を手で書かない。** Package.resolved が唯一の出どころ。
RESOLVED="$ROOT/KubeDeck.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
SPARKLE_VERSION=$(python3 - "$RESOLVED" <<'PY'
import json, sys
pins = json.load(open(sys.argv[1]))["pins"]
for pin in pins:
    if pin["identity"].lower() == "sparkle":
        print(pin["state"]["version"])
        break
else:
    sys.exit("Package.resolved に sparkle がありません")
PY
)
echo "==> Sparkle $SPARKLE_VERSION のツールを用意"
TOOLS="$ROOT/build/sparkle-$SPARKLE_VERSION"
if [[ ! -x "$TOOLS/bin/sign_update" ]]; then
  mkdir -p "$TOOLS"
  curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz" \
    | tar xJ -C "$TOOLS"
fi
SIGN_UPDATE="$TOOLS/bin/sign_update"

# 鍵の出どころ。CI は環境変数、手元はキーチェーン。
sign() {
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - "$@"
  else
    "$SIGN_UPDATE" "$@"
  fi
}

echo "==> sign_update"
# 出てくるのは `sparkle:edSignature="..." length="..."` の 1 行。
# enclosure の属性としてそのまま差し込める。
ENCLOSURE_ATTRS=$(sign "$APP_ZIP")

PUB_DATE=$(LC_ALL=C date "+%a, %d %b %Y %H:%M:%S %z")
DOWNLOAD_URL="https://github.com/$REPO_SLUG/releases/download/v$VERSION/KubeDeck-$VERSION.zip"
RELEASE_URL="https://github.com/$REPO_SLUG/releases/tag/v$VERSION"

if [[ -n "$NOTES_FILE" && -f "$NOTES_FILE" ]]; then
  NOTES=$(cat "$NOTES_FILE")
else
  NOTES="<p>変更点は <a href=\"$RELEASE_URL\">リリースページ</a> にあります。</p>"
fi

cat > "$APPCAST" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>KubeDeck</title>
    <link>https://github.com/$REPO_SLUG</link>
    <description>KubeDeck の更新</description>
    <language>ja</language>
    <item>
      <title>$VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <link>$RELEASE_URL</link>
      <sparkle:version>$BUILT_BUNDLE</sparkle:version>
      <sparkle:shortVersionString>$BUILT_SHORT</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <description><![CDATA[
$NOTES
      ]]></description>
      <enclosure url="$DOWNLOAD_URL"
                 type="application/octet-stream"
                 $ENCLOSURE_ATTRS />
    </item>
  </channel>
</rss>
XML

# 目録そのものにも署名する。差し替えられても Sparkle 側で気付ける。
# **この後で appcast.xml を書き換えない。** 署名が合わなくなる。
echo "==> sign_update (appcast)"
sign --disable-signing-warning "$APPCAST"

echo
echo "できました:"
ls -lh "$DIST"
