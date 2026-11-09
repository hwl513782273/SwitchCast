#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="SwitchCast"
VERSION="1.0"
APP_PATH="build/$APP_NAME.app"
VOL_NAME="Switch Cast"
DMG_NAME="12-${APP_NAME}-${VERSION}-universal.dmg"
DEST_DIR="/Users/banqiu/WorkBuddy/DMG"

[ -d "$APP_PATH" ] || { echo "❌ 先运行 ./build.sh"; exit 1; }

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/switchcast-dmg.XXXXXX")
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

echo "💿 生成 DMG: $DMG_NAME"
hdiutil create -volname "$VOL_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG_NAME"
mv "$STAGING" "$HOME/.Trash/switchcast-dmg-staging-$(date +%s)"

mkdir -p "$DEST_DIR"
if [ -f "$DEST_DIR/$DMG_NAME" ]; then
    echo "⚠️ $DEST_DIR 已存在同名文件，未覆盖（additive-only）"
else
    cp "$DMG_NAME" "$DEST_DIR/"
    echo "📦 已复制到 $DEST_DIR/$DMG_NAME"
fi

hdiutil verify "$DMG_NAME" > /dev/null && echo "✅ DMG 校验通过"
ls -lh "$DMG_NAME"
