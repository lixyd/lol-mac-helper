#!/bin/zsh
set -e
cd "$(dirname "$0")"

mkdir -p build
echo "编译 Swift..."
swiftc -O -parse-as-library Sources/XiaobaiHelper.swift -o build/XiaobaiHelper

APP="build/xiaobai助手.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp build/XiaobaiHelper "$APP/Contents/MacOS/XiaobaiHelper"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/donate.jpg "$APP/Contents/Resources/donate.jpg"

echo "Ad-hoc 签名..."
codesign --force -s - "$APP" >/dev/null

# 同步一份真实副本到桌面（真实 App 包，Finder 双击必可用）
DESKTOP_APP="$HOME/Desktop/xiaobai助手.app"
if [ -L "$DESKTOP_APP" ]; then
  rm -f "$DESKTOP_APP"          # 软链接：只删链接
elif [ -d "$DESKTOP_APP" ]; then
  rm -rf "$DESKTOP_APP"         # 旧副本
fi
cp -R "$APP" "$DESKTOP_APP"

# 刷新 LaunchServices 注册，避免 Finder 双击无反应
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREG" ] && "$LSREG" -f "$DESKTOP_APP" >/dev/null 2>&1 || true

echo "完成：$APP（已同步到桌面）"
