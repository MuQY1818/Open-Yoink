#!/bin/bash
#
# make-release.sh — 构建 OpenYoink 发布产物并更新 Sparkle appcast。
#
# 用法：./Scripts/make-release.sh <VERSION> [BUILD]
#   VERSION   市场版本号（写入 MARKETING_VERSION，如 1.0）。
#   BUILD     可选，CFBundleVersion（Sparkle 的版本比较键）；缺省沿用工程
#             里的 CURRENT_PROJECT_VERSION。
#
# 流程：xcodebuild archive（Release）→ 从 xcarchive 导出 app（ad hoc 签名，
# 沿用现有本地签名流程；如需公证先跑 Scripts/notarize.sh 再打 DMG）→
# Scripts/make-dmg.sh 打 DMG → Sparkle 包内 bin/sign_update 计算 EdDSA
# 签名 → 把 <item> 写入 docs/appcast.xml（同 shortVersionString 已存在则
# 替换，幂等可重跑）。
#
# 本脚本不执行 gh release create——构建完成后由人工/主代理把
# export/OpenYoink-<VERSION>.dmg 上传到 GitHub Releases（tag v<VERSION>），
# enclosure URL 才可达。
#
# 环境变量：
#   SPARKLE_BIN   sign_update 所在目录；缺省自动定位 DerivedData 里
#                 SourcePackages/artifacts/sparkle/Sparkle/bin。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [ $# -lt 1 ]; then
    echo "用法：$0 <VERSION> [BUILD]" >&2
    exit 1
fi
VERSION="$1"
BUILD_NUMBER="${2:-}"

PROJECT="Open-Yoink.xcodeproj"
SCHEME="OpenYoink"
ARCHIVE_PATH="export/OpenYoink.xcarchive"
APP_PATH="export/OpenYoink.app"
DMG_PATH="export/OpenYoink-$VERSION.dmg"
APPCAST="docs/appcast.xml"
RELEASE_URL="https://github.com/MuQY1818/Open-Yoink/releases/download/v$VERSION/OpenYoink-$VERSION.dmg"

# ---- 定位 Sparkle 命令行工具（sign_update）----
if [ -z "${SPARKLE_BIN:-}" ]; then
    SPARKLE_BIN="$(ls -d "$HOME"/Library/Developer/Xcode/DerivedData/Open-Yoink-*/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null | head -1 || true)"
fi
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
if [ ! -x "$SIGN_UPDATE" ]; then
    echo "error: 未找到 sign_update（试过 SPARKLE_BIN=${SPARKLE_BIN}）。先跑 xcodebuild -resolvePackageDependencies，或设 SPARKLE_BIN。" >&2
    exit 1
fi
echo "==> sign_update: $SIGN_UPDATE"

# ---- 1. Archive ----
VERSION_ARGS=(MARKETING_VERSION="$VERSION")
if [ -n "$BUILD_NUMBER" ]; then
    VERSION_ARGS+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")
fi
echo "==> archive（Release, ${VERSION}）"
rm -rf "$ARCHIVE_PATH"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    "${VERSION_ARGS[@]}" \
    archive

# ---- 2. 导出 app（xcarchive 内即已签名完成的成品，沿用现有本地签名流程）----
echo "==> 导出 $APP_PATH"
rm -rf "$APP_PATH"
ditto "$ARCHIVE_PATH/Products/Applications/OpenYoink.app" "$APP_PATH"

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
echo "    shortVersionString=$SHORT_VERSION  bundleVersion=$BUNDLE_VERSION"

# ---- 3. DMG ----
echo "==> 打 DMG"
./Scripts/make-dmg.sh "$APP_PATH"

# ---- 4. EdDSA 签名（私钥在登录钥匙串，条目 "Private key for signing Sparkle updates"）----
echo "==> sign_update"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
echo "    $SIGN_OUTPUT"
# 输出形如：sparkle:edSignature="..." length="..."
ED_SIGNATURE="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
DMG_LENGTH="$(printf '%s' "$SIGN_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [ -z "$ED_SIGNATURE" ] || [ -z "$DMG_LENGTH" ]; then
    echo "error: 无法从 sign_update 输出解析签名/长度" >&2
    exit 1
fi

PUB_DATE="$(LC_TIME=C date '+%a, %d %b %Y %H:%M:%S %z')"

# ---- 5. 更新 docs/appcast.xml（同 shortVersionString 替换而非追加）----
echo "==> 更新 $APPCAST"
python3 - "$APPCAST" "$VERSION" "$SHORT_VERSION" "$BUNDLE_VERSION" "$RELEASE_URL" "$ED_SIGNATURE" "$DMG_LENGTH" "$PUB_DATE" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

(appcast_path, version, short_version, bundle_version,
 url, ed_signature, dmg_length, pub_date) = sys.argv[1:9]

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)

tree = ET.parse(appcast_path, parser=ET.XMLParser(target=ET.TreeBuilder(insert_comments=True)))
channel = tree.getroot().find("channel")

# 幂等：移除同 shortVersionString 的旧 item。
for item in list(channel.findall("item")):
    svs = item.find(f"{{{SPARKLE}}}shortVersionString")
    if svs is not None and svs.text == short_version:
        channel.remove(item)
        print(f"    替换已存在的 {short_version} item")

item = ET.Element("item")
ET.SubElement(item, "title").text = f"Version {short_version}"
ET.SubElement(item, "pubDate").text = pub_date
ET.SubElement(item, f"{{{SPARKLE}}}version").text = bundle_version
ET.SubElement(item, f"{{{SPARKLE}}}shortVersionString").text = short_version
ET.SubElement(item, f"{{{SPARKLE}}}channel").text = "stable"
ET.SubElement(item, "enclosure", {
    "url": url,
    f"{{{SPARKLE}}}edSignature": ed_signature,
    "length": dmg_length,
    "type": "application/octet-stream",
})

# 新 item 插到最前（channel 头部元素之后）。
insert_at = 0
for idx, child in enumerate(list(channel)):
    if child.tag == "item":
        insert_at = idx
        break
else:
    insert_at = len(list(channel))
channel.insert(insert_at, item)

ET.indent(tree, space="    ")
tree.write(appcast_path, encoding="utf-8", xml_declaration=True)
print(f"    appcast 已更新：{short_version} ({bundle_version})")
PYEOF

echo ""
echo "==> 完成"
echo "    DMG:     $DMG_PATH"
echo "    appcast: $APPCAST"
echo "下一步（本脚本不执行）：git 提交 docs/appcast.xml，并创建 GitHub Release："
echo "    gh release create v$VERSION $DMG_PATH --title \"OpenYoink $VERSION\""
