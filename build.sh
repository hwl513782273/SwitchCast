#!/bin/bash
set -e
cd "$(dirname "$0")"

APP_NAME="SwitchCast"
MIN_MACOS="12.0"
BUILD_DIR="build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"

FRAMEWORKS="-framework SwiftUI -framework AppKit -framework AVFoundation -framework VideoToolbox \
-framework CoreMedia -framework CoreVideo -framework CoreImage -framework IOUSBHost -framework IOKit"

# 旧产物走废纸篓，不用 rm -rf（本环境 safe-delete 钩子会拦）
if [ -d "$APP_PATH" ]; then
    mkdir -p "$HOME/.Trash"
    mv "$APP_PATH" "$HOME/.Trash/${APP_NAME}-build-$(date +%s).app"
fi

mkdir -p "$BUILD_DIR"
TMPBIN=$(mktemp -d "${TMPDIR:-/tmp}/switchcast-bin.XXXXXX")

echo "🔨 编译 arm64..."
swiftc -O -target "arm64-apple-macosx$MIN_MACOS" $FRAMEWORKS Sources/*.swift -o "$TMPBIN/sc_arm64"
echo "🔨 编译 x86_64..."
swiftc -O -target "x86_64-apple-macosx$MIN_MACOS" $FRAMEWORKS Sources/*.swift -o "$TMPBIN/sc_x86_64"

mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

echo "🔗 合并 universal..."
lipo -create -output "$TMPBIN/sc_universal" "$TMPBIN/sc_arm64" "$TMPBIN/sc_x86_64"
mv "$TMPBIN/sc_universal" "$APP_PATH/Contents/MacOS/$APP_NAME"
mv "$TMPBIN" "$HOME/.Trash/switchcast-tmp-$(date +%s)" 2>/dev/null || true

cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP_PATH/Contents/Resources/"
else
    echo "⚠️ 缺少 Resources/AppIcon.icns"
fi

plutil -lint "$APP_PATH/Contents/Info.plist" > /dev/null
echo "🔏 ad-hoc 签名..."
codesign --force --deep --sign - "$APP_PATH"

echo "✅ 构建完成: $APP_PATH"
lipo -info "$APP_PATH/Contents/MacOS/$APP_NAME"
