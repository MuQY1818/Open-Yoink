#!/bin/bash
#
# make-release.sh — 构建 OpenYoink 发布产物并更新 Sparkle appcast。
#
# 用法：./Scripts/make-release.sh <VERSION> [BUILD] [--adhoc]
#   VERSION   市场版本号（写入 MARKETING_VERSION，如 1.0.2）。
#   BUILD     可选，CFBundleVersion（Sparkle 的版本比较键）；缺省取现有
#             appcast 最大 build + 1。
#   --adhoc   显式选择免费社区发布模式：跳过 Developer ID 与 Apple 公证。
#             Sparkle EdDSA 更新签名仍会生成，但首次下载会触发 Gatekeeper
#             的「无法验证开发者」提示。
#
# 流程：Developer ID archive（Release）→ 验证 app 与嵌套组件签名 →
# Scripts/make-dmg.sh 打包 → Developer ID 签 DMG → notarytool 公证并装订
# 最终 DMG → Sparkle sign_update 计算 EdDSA 签名 → 更新 appcast。
#
# 本脚本不执行 gh release create——构建完成后由人工/主代理把
# export/OpenYoink-<VERSION>.dmg 上传到 GitHub Releases（tag v<VERSION>），
# enclosure URL 才可达。
#
# 环境变量：
#   DEVELOPER_ID_APPLICATION  钥匙串中的完整签名身份，例如：
#                 Developer ID Application: Example Name (ABCDE12345)
#   DEVELOPMENT_TEAM_ID  10 位 Apple Developer Team ID。
#   NOTARY_PROFILE  `xcrun notarytool store-credentials <name>` 保存的 profile。
#   SPARKLE_BIN   sign_update 所在目录；缺省自动定位 DerivedData 里
#                 SourcePackages/artifacts/sparkle/Sparkle/bin。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [ $# -lt 1 ] || [ $# -gt 3 ]; then
    echo "用法：$0 <VERSION> [BUILD] [--adhoc]" >&2
    exit 1
fi
VERSION="$1"
BUILD_NUMBER="${2:-}"
RELEASE_MODE="developer-id"
if [ "${3:-}" = "--adhoc" ]; then
    RELEASE_MODE="adhoc"
elif [ -n "${3:-}" ]; then
    echo "error: 未知参数 ${3}；第三个参数只支持 --adhoc。" >&2
    exit 1
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION 必须是三段数字版本号（例如 1.0.2）。" >&2
    exit 1
fi
if [ -n "$BUILD_NUMBER" ] && [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
    echo "error: BUILD 必须是正整数。" >&2
    exit 1
fi

PROJECT="Open-Yoink.xcodeproj"
SCHEME="OpenYoink"
ARCHIVE_PATH="export/OpenYoink.xcarchive"
APP_PATH="export/OpenYoink.app"
DMG_PATH="export/OpenYoink-$VERSION.dmg"
APPCAST="docs/appcast.xml"
RELEASE_URL="https://github.com/MuQY1818/OpenYoink/releases/download/v$VERSION/OpenYoink-$VERSION.dmg"

if [ "$RELEASE_MODE" = "developer-id" ]; then
    for required_name in DEVELOPER_ID_APPLICATION DEVELOPMENT_TEAM_ID NOTARY_PROFILE; do
        if [ -z "${!required_name:-}" ]; then
            echo "error: 缺少环境变量 ${required_name}。没有 Apple 证书时请显式使用：$0 $VERSION ${BUILD_NUMBER:-<BUILD>} --adhoc" >&2
            exit 1
        fi
    done
    if [[ ! "$DEVELOPMENT_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]]; then
        echo "error: DEVELOPMENT_TEAM_ID 必须是 10 位大写字母/数字。" >&2
        exit 1
    fi
    CODE_SIGN_IDENTITIES="$(security find-identity -v -p codesigning)"
    case "$CODE_SIGN_IDENTITIES" in
        *"$DEVELOPER_ID_APPLICATION"*) ;;
        *)
            echo "error: 钥匙串中未找到指定的 Developer ID Application 身份。" >&2
            exit 1
            ;;
    esac
else
    echo "==> 发布模式：ad hoc（免费、未公证；首次下载会触发 Gatekeeper 提示）"
fi

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

# ---- build number（评审 P2）：sparkle:version 必须严格递增，否则老用户
# 不会把新包视为更新。不传 BUILD 时自动取 appcast 最大 sparkle:version + 1；
# 传入时校验必须大于该最大值，防止误发「看似新版实则同 build」的更新。
MAX_BUILD="$(grep -o '<sparkle:version>[0-9]*' "$APPCAST" 2>/dev/null | grep -o '[0-9]*' | sort -n | tail -1 || true)"
MAX_BUILD="${MAX_BUILD:-0}"
EXISTING_VERSION_BUILD="$(python3 - "$APPCAST" "$VERSION" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

appcast_path, requested_version = sys.argv[1:3]
ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
try:
    root = ET.parse(appcast_path).getroot()
except (FileNotFoundError, ET.ParseError):
    raise SystemExit(0)
for item in root.findall("./channel/item"):
    short_version = item.find("sparkle:shortVersionString", ns)
    build = item.find("sparkle:version", ns)
    if short_version is not None and short_version.text == requested_version and build is not None:
        print(build.text or "")
        break
PYEOF
)"
if [ -z "${BUILD_NUMBER}" ]; then
    if [ -n "$EXISTING_VERSION_BUILD" ]; then
        BUILD_NUMBER="$EXISTING_VERSION_BUILD"
        echo "==> 重建现有 ${VERSION} item：沿用 build ${BUILD_NUMBER}"
    else
        BUILD_NUMBER=$((MAX_BUILD + 1))
        echo "==> 自动 build number：${BUILD_NUMBER}（appcast 最大 ${MAX_BUILD} + 1）"
    fi
elif [ "${BUILD_NUMBER}" -le "${MAX_BUILD}" ] && [ "$BUILD_NUMBER" != "$EXISTING_VERSION_BUILD" ]; then
    echo "error: BUILD=${BUILD_NUMBER} 不大于 appcast 最大 sparkle:version ${MAX_BUILD} —— 老用户将收不到更新。请传更大值，或省略第二个参数自动递增。" >&2
    exit 1
elif [ "$BUILD_NUMBER" = "$EXISTING_VERSION_BUILD" ]; then
    echo "==> 重建现有 ${VERSION} item：沿用 build ${BUILD_NUMBER}"
fi

# ---- 1. Archive ----
# build number 在上文已保证存在且严格递增，总是显式写入。
VERSION_ARGS=(
    MARKETING_VERSION="$VERSION"
    CURRENT_PROJECT_VERSION="${BUILD_NUMBER}"
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO
    CODE_SIGN_STYLE=Manual
)
if [ "$RELEASE_MODE" = "developer-id" ]; then
    VERSION_ARGS+=(
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM_ID"
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
else
    VERSION_ARGS+=(
        CODE_SIGN_IDENTITY=-
        DEVELOPMENT_TEAM=
        AD_HOC_CODE_SIGNING_ALLOWED=YES
        ENABLE_HARDENED_RUNTIME=NO
    )
fi
echo "==> archive（Release, ${VERSION} (${BUILD_NUMBER})）"
rm -rf "$ARCHIVE_PATH"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    "${VERSION_ARGS[@]}" \
    archive

# ---- 2. 导出并验证 Xcode 已签名的 app ----
echo "==> 导出 $APP_PATH"
rm -rf "$APP_PATH"
ditto "$ARCHIVE_PATH/Products/Applications/OpenYoink.app" "$APP_PATH"

# Developer ID 模式保留 Xcode 为各嵌套组件生成的独立签名。ad hoc 模式下
# 则统一把主程序与 Sparkle 嵌套组件改为临时签名，避免无 Team ID 的主程序
# 连接到仍带第三方 Team ID 的 XPC 服务时被拒绝。ad hoc 签名之间没有可供
# library validation 比对的 Team ID，因此该模式必须去掉 Hardened Runtime；
# 否则 dyld 会在启动时拒载 Sparkle.framework。各组件自己的 identifier 与
# entitlements 仍逐一保留，不能把主程序权限套给 Sparkle 的 helper/XPC。
if [ "$RELEASE_MODE" = "adhoc" ]; then
    codesign --force --deep --sign - \
        --preserve-metadata=identifier,entitlements \
        "$APP_PATH"
fi
codesign --verify --deep --strict --verbose=2 "$APP_PATH"
APP_SIGN_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
if [ "$RELEASE_MODE" = "developer-id" ]; then
    if ! printf '%s\n' "$APP_SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
        echo "error: 导出的 app 未启用 Hardened Runtime，拒绝 Developer ID 发布。" >&2
        exit 1
    fi
    if printf '%s\n' "$APP_SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
        echo "error: 导出的 app 仍是 ad hoc 签名，拒绝 Developer ID 发布。" >&2
        exit 1
    fi
    if ! printf '%s\n' "$APP_SIGN_INFO" | grep -Fq "TeamIdentifier=$DEVELOPMENT_TEAM_ID"; then
        echo "error: app 的 TeamIdentifier 与 DEVELOPMENT_TEAM_ID 不一致。" >&2
        exit 1
    fi
elif ! printf '%s\n' "$APP_SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
    echo "error: --adhoc 模式未生成 ad hoc 主程序签名。" >&2
    exit 1
elif printf '%s\n' "$APP_SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
    echo "error: --adhoc 模式仍启用了 Hardened Runtime，Sparkle 会因 Team ID 不匹配而无法载入。" >&2
    exit 1
fi
ENTITLEMENTS_FILE="$(mktemp /tmp/openyoink-entitlements.XXXXXX)"
trap 'rm -f "$ENTITLEMENTS_FILE"' EXIT
codesign -d --entitlements :- "$APP_PATH" >"$ENTITLEMENTS_FILE" 2>/dev/null
if grep -Fq '$(PRODUCT_BUNDLE_IDENTIFIER)' "$ENTITLEMENTS_FILE"; then
    echo "error: app entitlements 仍含未展开的构建变量，拒绝发布。" >&2
    exit 1
fi
GET_TASK_ALLOW="$(plutil -extract com.apple.security.get-task-allow raw -o - "$ENTITLEMENTS_FILE" 2>/dev/null || true)"
if [ "$GET_TASK_ALLOW" = "true" ]; then
    echo "error: Release app 含 get-task-allow 调试权限，拒绝发布。" >&2
    exit 1
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
echo "    shortVersionString=$SHORT_VERSION  bundleVersion=$BUNDLE_VERSION"
if [ "$SHORT_VERSION" != "$VERSION" ] || [ "$BUNDLE_VERSION" != "$BUILD_NUMBER" ]; then
    echo "error: 归档内版本与请求不一致（期望 $VERSION ($BUILD_NUMBER)），拒绝发布。" >&2
    exit 1
fi

# ---- 3. DMG ----
echo "==> 打 DMG"
./Scripts/make-dmg.sh "$APP_PATH"

# ---- 4. Developer ID 模式签名、公证并装订最终分发 DMG ----
if [ "$RELEASE_MODE" = "developer-id" ]; then
    echo "==> Developer ID 签名 DMG"
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG_PATH"
    NOTARY_PROFILE="$NOTARY_PROFILE" ./Scripts/notarize.sh "$DMG_PATH"
else
    echo "==> 跳过 Apple 公证（ad hoc 模式）"
fi

# ---- 5. EdDSA 签名（必须在公证/装订后执行，因为 DMG 字节已改变）----
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

# ---- 6. 更新 docs/appcast.xml（同 shortVersionString 替换而非追加）----
# 注意：item 不写 <sparkle:channel> —— 应用的 Info.plist 未声明 SUChannel，
# 带 channel 的 item 会被 Sparkle 过滤（「无频道订阅只看默认频道」），
# 导致明明有新版却判为最新（1.0.1 发布时实测踩坑）。
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

# ---- 7. 输出 Homebrew cask 元数据（不提前修改远端）----
# GitHub Release 此时尚未上传；自动推送 cask 会先发布一个失效 URL。
# 上传后重跑整条构建链又会因签名/公证时间戳生成不同 DMG，因此这里只输出
# 最终已公证产物的精确 SHA，留给上传完成后的独立人工提交。
DMG_SHA="$(shasum -a 256 "$DMG_PATH" | cut -d' ' -f1)"
echo "==> Homebrew cask：version=$SHORT_VERSION  sha256=$DMG_SHA"
echo "    GitHub Release 上传成功后，用以上两个值更新 homebrew-tap。"

echo ""
echo "==> 完成"
echo "    DMG:     $DMG_PATH"
echo "    appcast: $APPCAST"
echo "    mode:    $RELEASE_MODE"
echo "下一步（本脚本不执行）：git 提交 docs/appcast.xml，并创建 GitHub Release："
echo "    gh release create v$VERSION $DMG_PATH --title \"OpenYoink $VERSION\""
