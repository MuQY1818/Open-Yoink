#!/bin/bash
#
# make-dmg.sh — 构建 OpenYoink 分发 DMG（拖应用到 Applications 的经典安装界面）。
#
# 用法：./Scripts/make-dmg.sh [路径到 OpenYoink.app]
#   默认 app：export/OpenYoink.app（先跑过 archive 导出；见 README「构建」）。
# 产物：export/OpenYoink-1.0.dmg
#
# 流程：staging（app + Applications 符号链接 + 背景图）→ 读写 DMG →
# Finder AppleScript 设置窗口布局（图标位置/大小/背景）→ 压缩为 UDZO。
# Finder 布局步骤需要「自动化」权限（首次运行系统会弹授权）；未授权时
# 跳过布局美化，DMG 仍可用（图标位置默认）。
#
# 签名/公证：本脚本不重签名。分发前请先按 Scripts/notarize.sh 的说明
# 对 export/OpenYoink.app 重签并公证，再跑本脚本。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="${1:-$REPO_ROOT/export/OpenYoink.app}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo 1.0)"
DMG_NAME="OpenYoink-$VERSION"
STAGE="$REPO_ROOT/export/dmg-stage"
RW_DMG="$REPO_ROOT/export/$DMG_NAME-rw.dmg"
FINAL_DMG="$REPO_ROOT/export/$DMG_NAME.dmg"
BACKGROUND_SRC="$REPO_ROOT/Scripts/dmg-background.png"

# 窗口/图标布局（与 generate-dmg-background.swift 的坐标约定一致）。
WIN_W=600; WIN_H=400
APP_X=150; APP_Y=230
ALIAS_X=450; ALIAS_Y=230
ICON_SIZE=128

if [ ! -d "$APP_PATH" ]; then
    echo "error: app not found at $APP_PATH（先 archive 导出或传入路径）" >&2
    exit 1
fi
if [ ! -f "$BACKGROUND_SRC" ]; then
    echo "生成背景图…"
    swift "$REPO_ROOT/Scripts/generate-dmg-background.swift"
fi

echo "==> 准备 staging"
rm -rf "$STAGE"
mkdir -p "$STAGE/.background"
cp -R "$APP_PATH" "$STAGE/OpenYoink.app"
ln -s /Applications "$STAGE/Applications"
cp "$BACKGROUND_SRC" "$STAGE/.background/background.png"

echo "==> 创建读写 DMG"
rm -f "$RW_DMG" "$FINAL_DMG"
hdiutil create -srcfolder "$STAGE" -volname "OpenYoink" -fs HFS+ \
    -format UDRW -ov "$RW_DMG" >/dev/null

echo "==> 挂载"
MOUNT_DIR="$(hdiutil attach -readwrite -noverify "$RW_DMG" | tail -1 | sed -E 's/.*(\/Volumes\/.*)$/\1/')"
echo "    mounted at $MOUNT_DIR"

# Finder 窗口布局（需要自动化权限；失败时跳过美化但保留 DMG）。
echo "==> 设置窗口布局（可能弹「自动化」授权）"
if osascript <<EOF 2>/dev/null
tell application "Finder"
    tell disk "OpenYoink"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 200, 400 + $WIN_W, 200 + $WIN_H}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $ICON_SIZE
        set background picture of viewOptions to file ".background:background.png"
        set position of item "OpenYoink.app" of container window to {$APP_X, $APP_Y}
        set position of item "Applications" of container window to {$ALIAS_X, $ALIAS_Y}
        close
        open
        update without registering applications
        close
    end tell
end tell
EOF
then
    echo "    布局完成"
else
    echo "    ⚠️  Finder 自动化未授权或失败，跳过窗口美化（DMG 仍可用）" >&2
fi

echo "==> 卸载并压缩"
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGE"

echo "==> 完成：$FINAL_DMG"
hdiutil imageinfo "$FINAL_DMG" | grep -E 'Format:|Compressed Size' || true
