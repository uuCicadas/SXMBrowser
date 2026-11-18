#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
PROJECT="$ROOT/native/SXMBrowserNative"
APP="$ROOT/SXM Browser.app"
BUILD_ID="$(md5 -q -s "$PROJECT")"
BUILD_DIR="$PROJECT/.build-$BUILD_ID"
CACHE_DIR="$PROJECT/.build-cache-$BUILD_ID"

cd "$PROJECT"
mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm"
export SWIFTPM_CACHE_PATH="$CACHE_DIR/swiftpm"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"
swift build --disable-sandbox -c release --scratch-path "$BUILD_DIR"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PROJECT/Bundle/Info.plist" "$APP/Contents/Info.plist"
if [ -d "$PROJECT/Bundle/Resources" ]; then
    ditto "$PROJECT/Bundle/Resources" "$APP/Contents/Resources"
fi
cp "$BUILD_DIR/release/SXMBrowserNative" "$APP/Contents/MacOS/SXMBrowserNative"
chmod +x "$APP/Contents/MacOS/SXMBrowserNative"

# Seal the complete bundle after copying its executable and resources.
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "Built: $APP"
