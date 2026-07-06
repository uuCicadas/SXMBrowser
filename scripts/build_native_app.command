#!/bin/zsh
set -euo pipefail

ROOT="/Users/wuziyou/Documents/数据处理/sxm-browser"
PROJECT="$ROOT/native/SXMBrowserNative"
APP="$ROOT/SXM Browser.app"

cd "$PROJECT"
mkdir -p .build-cache/clang .build-cache/swiftpm
export SWIFTPM_CACHE_PATH="$PROJECT/.build-cache/swiftpm"
export CLANG_MODULE_CACHE_PATH="$PROJECT/.build-cache/clang"
swift build -c release --scratch-path .build

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT/Bundle/Info.plist" "$APP/Contents/Info.plist"
if [ -d "$PROJECT/Bundle/Resources" ]; then
    ditto "$PROJECT/Bundle/Resources" "$APP/Contents/Resources"
fi
cp "$PROJECT/.build/release/SXMBrowserNative" "$APP/Contents/MacOS/SXMBrowserNative"
chmod +x "$APP/Contents/MacOS/SXMBrowserNative"

echo "Built: $APP"
