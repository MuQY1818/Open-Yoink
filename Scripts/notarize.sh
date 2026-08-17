#!/bin/bash
#
# notarize.sh — 用 Apple notarytool 公证 OpenYoink.app 的占位脚本。
#
# ⚠️ 本脚本为占位（placeholder）：当前发布版本未公证，脚本不会也不应直接
# 运行。填入你自己的 Apple Developer 信息后取消下方 `exit 0` 注释即可使用。
#
# 前置条件：
#   1. 加入 Apple Developer Program（付费账号），拥有 Developer ID
#      Application 证书，并把 TEAM_ID 填到工程 DEVELOPMENT_TEAM 后用
#      Release 配置重新归档。
#   2. 任选一种凭据方式（二选一，见下方 KEYCHAIN_PROFILE / APPLE_ID 段）。
#
# 用法：
#   ./Scripts/notarize.sh export/OpenYoink.app

set -euo pipefail

# ===== 待填变量（占位，请替换为你自己的值）=====
TEAM_ID="YOUR_TEAM_ID"                       # Apple Developer Team ID（10 位）
KEYCHAIN_PROFILE="YOUR_KEYCHAIN_PROFILE"     # 方式 A：`notarytool store-credentials` 预存的 keychain profile 名
APPLE_ID="your-apple-id@example.com"         # 方式 B：Apple ID（需配合 App 专用密码）
APP_PASSWORD="@keychain:AC_PASSWORD"         # 方式 B：App 专用密码（建议存 keychain 后引用）

APP_PATH="${1:-export/OpenYoink.app}"
ZIP_PATH="${APP_PATH%.app}-notarize.zip"

# ===== 占位保护：未填 TEAM_ID 时直接退出，不会执行任何操作 =====
if [[ "$TEAM_ID" == "YOUR_TEAM_ID" ]]; then
    echo "占位脚本：请先把 TEAM_ID 等变量替换为你自己的 Apple Developer 信息。"
    echo "当前分发的 OpenYoink.app 为本地签名（ad hoc），未公证。"
    exit 0
fi

# 1. 用 Developer ID 重新签名（归档时 DEVELOPMENT_TEAM 已生效可省略；
#    此处保留以便对既有归档补签）。
codesign --sign "Developer ID Application: Your Name ($TEAM_ID)" \
    --options runtime --timestamp --force --deep "$APP_PATH"

# 2. 打包为 zip（notarytool 只接受 zip/pkg/dmg）。
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

# 3. 提交公证并等待结果（凭据方式二选一，注释掉另一种）。
xcrun notarytool submit "$ZIP_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --wait
# xcrun notarytool submit "$ZIP_PATH" \
#     --apple-id "$APPLE_ID" --password "$APP_PASSWORD" --team-id "$TEAM_ID" \
#     --wait

# 4. 公证通过后将票据装订进 app，用户双击即不再触发 Gatekeeper 拦截。
xcrun stapler staple "$APP_PATH"

# 5. 验证（可选）。
spctl --assess -vv "$APP_PATH"

echo "公证完成：$APP_PATH"
