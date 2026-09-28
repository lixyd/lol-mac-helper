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

echo "完成：$APP"
