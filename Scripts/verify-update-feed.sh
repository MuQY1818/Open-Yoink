#!/bin/bash
# 对已经上传的 Sparkle feed 做端到端只读验证：feed XML → 下载附件 →
# 长度/Ed25519 签名 → 挂载 DMG → app 版本与 Sparkle helper 签名边界。
# 用法：verify-update-feed.sh [APPCAST_URL_OR_PATH] [EXPECTED_VERSION]

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:-https://muqy1818.github.io/OpenYoink/appcast.xml}"
EXPECTED_VERSION="${2:-}"
WORK_DIR="$(mktemp -d /tmp/openyoink-feed-verify.XXXXXX)"
MOUNT_DIR="$WORK_DIR/mount"
MOUNTED=0

cleanup() {
    if [ "$MOUNTED" -eq 1 ]; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

APPCAST_PATH="$WORK_DIR/appcast.xml"
if [[ "$SOURCE" == http://* || "$SOURCE" == https://* ]]; then
    echo "==> 下载 appcast：$SOURCE"
    curl --fail --location --silent --show-error "$SOURCE" --output "$APPCAST_PATH"
else
    cp "$SOURCE" "$APPCAST_PATH"
fi
xmllint --noout "$APPCAST_PATH"

IFS=$'\t' read -r FEED_VERSION FEED_BUILD ENCLOSURE_URL ED_SIGNATURE DECLARED_LENGTH < <(
    python3 - "$APPCAST_PATH" <<'PYEOF'
import sys
import xml.etree.ElementTree as ET

ns = {"sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle"}
root = ET.parse(sys.argv[1]).getroot()
item = root.find("./channel/item")
if item is None:
    raise SystemExit("appcast 没有 item")
version = item.findtext("sparkle:shortVersionString", namespaces=ns) or ""
build = item.findtext("sparkle:version", namespaces=ns) or ""
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("最新 item 没有 enclosure")
signature = enclosure.get(f"{{{ns['sparkle']}}}edSignature", "")
print("\t".join([version, build, enclosure.get("url", ""), signature,
                 enclosure.get("length", "")]))
PYEOF
)

if [ -z "$FEED_VERSION" ] || [ -z "$FEED_BUILD" ] || [ -z "$ENCLOSURE_URL" ] \
    || [ -z "$ED_SIGNATURE" ] || [ -z "$DECLARED_LENGTH" ]; then
    echo "error: 最新 appcast item 缺少版本、URL、签名或长度。" >&2
    exit 1
fi
if [ -n "$EXPECTED_VERSION" ] && [ "$FEED_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "error: feed 最新版本为 ${FEED_VERSION}，期望 ${EXPECTED_VERSION}。" >&2
    exit 1
fi
if [[ ! "$DECLARED_LENGTH" =~ ^[0-9]+$ ]]; then
    echo "error: enclosure length 不是数字。" >&2
    exit 1
fi

DMG_PATH="$WORK_DIR/OpenYoink-$FEED_VERSION.dmg"
echo "==> 下载 OpenYoink $FEED_VERSION ($FEED_BUILD)"
curl --fail --location --silent --show-error "$ENCLOSURE_URL" --output "$DMG_PATH"
ACTUAL_LENGTH="$(stat -f '%z' "$DMG_PATH")"
if [ "$ACTUAL_LENGTH" != "$DECLARED_LENGTH" ]; then
    echo "error: DMG 长度不一致，feed=${DECLARED_LENGTH}，实际=${ACTUAL_LENGTH}。" >&2
    exit 1
fi

# Sparkle 的 SUPublicEDKey 是 32-byte raw Ed25519 key。加上标准 SPKI DER
# 前缀后交给 OpenSSL，直接验证 appcast 的 EdDSA enclosure 签名。
TRUSTED_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$REPO_ROOT/OpenYoink/App/Info.plist")"
printf '302a300506032b6570032100' | xxd -r -p >"$WORK_DIR/public.der"
printf '%s' "$TRUSTED_KEY" | base64 -D >>"$WORK_DIR/public.der"
printf '%s' "$ED_SIGNATURE" | base64 -D >"$WORK_DIR/signature.bin"
if ! openssl pkeyutl -verify -pubin -keyform DER \
    -inkey "$WORK_DIR/public.der" -rawin -in "$DMG_PATH" \
    -sigfile "$WORK_DIR/signature.bin" >/dev/null; then
    echo "error: Sparkle Ed25519 签名验证失败。" >&2
    exit 1
fi

mkdir "$MOUNT_DIR"
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$MOUNT_DIR" -quiet
MOUNTED=1
APP_PATH="$(find "$MOUNT_DIR" -maxdepth 1 -type d -name 'OpenYoink.app' -print -quit)"
if [ -z "$APP_PATH" ]; then
    echo "error: DMG 中没有 OpenYoink.app。" >&2
    exit 1
fi

DOWNLOADED_KEY="$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$APP_PATH/Contents/Info.plist")"
if [ "$DOWNLOADED_KEY" != "$TRUSTED_KEY" ]; then
    echo "error: DMG 内 app 的 Sparkle 公钥与仓库信任根不一致。" >&2
    exit 1
fi

SIGN_INFO="$(codesign -dvvv "$APP_PATH" 2>&1)"
MODE="developer-id"
if printf '%s\n' "$SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
    MODE="adhoc"
fi
"$REPO_ROOT/Scripts/verify-distribution.sh" \
    "$APP_PATH" "$MODE" "$FEED_VERSION" "$FEED_BUILD"

echo "端到端更新链路验证通过：$FEED_VERSION ($FEED_BUILD)，$ACTUAL_LENGTH bytes"
