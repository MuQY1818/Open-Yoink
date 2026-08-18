#!/bin/bash
# 验证 OpenYoink 发布 app 的版本、签名与 Sparkle helper 权限边界。
# 用法：verify-distribution.sh <OpenYoink.app> <adhoc|developer-id> [VERSION] [BUILD]

set -euo pipefail

if [ $# -lt 2 ] || [ $# -gt 4 ]; then
    echo "用法：$0 <OpenYoink.app> <adhoc|developer-id> [VERSION] [BUILD]" >&2
    exit 1
fi

APP_PATH="$1"
RELEASE_MODE="$2"
EXPECTED_VERSION="${3:-}"
EXPECTED_BUILD="${4:-}"

if [ ! -d "$APP_PATH" ]; then
    echo "error: app 不存在：$APP_PATH" >&2
    exit 1
fi
if [ "$RELEASE_MODE" != "adhoc" ] && [ "$RELEASE_MODE" != "developer-id" ]; then
    echo "error: 签名模式必须是 adhoc 或 developer-id。" >&2
    exit 1
fi

SPARKLE_ROOT="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
COMPONENTS=(
    "$SPARKLE_ROOT/XPCServices/Installer.xpc"
    "$SPARKLE_ROOT/XPCServices/Downloader.xpc"
    "$SPARKLE_ROOT/Autoupdate"
    "$SPARKLE_ROOT/Updater.app"
    "$APP_PATH/Contents/Frameworks/Sparkle.framework"
    "$APP_PATH"
)

for component in "${COMPONENTS[@]}"; do
    if [ ! -e "$component" ]; then
        echo "error: 缺少 Sparkle 发布组件：$component" >&2
        exit 1
    fi
    codesign --verify --strict --verbose=2 "$component"

    SIGN_INFO="$(codesign -dvvv "$component" 2>&1)"
    if [ "$RELEASE_MODE" = "adhoc" ]; then
        if ! printf '%s\n' "$SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
            echo "error: ad hoc 模式组件未使用 ad hoc 签名：$component" >&2
            exit 1
        fi
        if printf '%s\n' "$SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
            echo "error: ad hoc 组件仍启用 Hardened Runtime：$component" >&2
            exit 1
        fi
    else
        if printf '%s\n' "$SIGN_INFO" | grep -Fq 'Signature=adhoc'; then
            echo "error: Developer ID 模式仍含 ad hoc 组件：$component" >&2
            exit 1
        fi
        if ! printf '%s\n' "$SIGN_INFO" | grep -Eq 'flags=.*runtime'; then
            echo "error: Developer ID 组件未启用 Hardened Runtime：$component" >&2
            exit 1
        fi
    fi
done

ENTITLEMENTS_DIR="$(mktemp -d /tmp/openyoink-verify.XXXXXX)"
trap 'rm -rf "$ENTITLEMENTS_DIR"' EXIT

for component in "${COMPONENTS[@]}"; do
    file="$ENTITLEMENTS_DIR/$(printf '%s' "$component" | shasum | cut -d' ' -f1).plist"
    codesign -d --entitlements :- "$component" >"$file" 2>/dev/null || true
    if grep -Fq '$(PRODUCT_BUNDLE_IDENTIFIER)' "$file"; then
        echo "error: 签名权限仍含未展开的构建变量：$component" >&2
        exit 1
    fi
done

# 上一版失败的直接原因：--deep 把主 app sandbox / application-identifier
# 灌给 Installer、Updater。它们必须保留 Sparkle 自己的空权限集。
for helper in "$SPARKLE_ROOT/XPCServices/Installer.xpc" "$SPARKLE_ROOT/Updater.app"; do
    file="$ENTITLEMENTS_DIR/$(printf '%s' "$helper" | shasum | cut -d' ' -f1).plist"
    if [ "$(plutil -extract com.apple.security.app-sandbox raw -o - "$file" 2>/dev/null || true)" = "true" ]; then
        echo "error: Sparkle helper 错误继承了主 app sandbox：$helper" >&2
        exit 1
    fi
    if grep -Fq 'com.weijue.OpenYoink' "$file"; then
        echo "error: Sparkle helper 错误继承了 OpenYoink application identifier：$helper" >&2
        exit 1
    fi
done

MAIN_ENTITLEMENTS="$ENTITLEMENTS_DIR/$(printf '%s' "$APP_PATH" | shasum | cut -d' ' -f1).plist"
if [ "$(plutil -extract com.apple.security.get-task-allow raw -o - "$MAIN_ENTITLEMENTS" 2>/dev/null || true)" = "true" ]; then
    echo "error: Release app 含 get-task-allow 调试权限。" >&2
    exit 1
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP_PATH/Contents/Info.plist")"
if [ -n "$EXPECTED_VERSION" ] && [ "$SHORT_VERSION" != "$EXPECTED_VERSION" ]; then
    echo "error: 版本不一致，期望 $EXPECTED_VERSION，实际 $SHORT_VERSION。" >&2
    exit 1
fi
if [ -n "$EXPECTED_BUILD" ] && [ "$BUNDLE_VERSION" != "$EXPECTED_BUILD" ]; then
    echo "error: build 不一致，期望 $EXPECTED_BUILD，实际 $BUNDLE_VERSION。" >&2
    exit 1
fi

echo "验证通过：OpenYoink $SHORT_VERSION ($BUNDLE_VERSION)，模式 $RELEASE_MODE"
