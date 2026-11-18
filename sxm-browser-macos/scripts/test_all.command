#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
PROJECT="$ROOT/native/SXMBrowserNative"
BUILD_ID="$(md5 -q -s "$PROJECT")"
CACHE_DIR="$PROJECT/.build-cache-$BUILD_ID"
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORK_DIR="$DEVELOPER_DIR/Library/Developer/Frameworks"
INTEROP_DIR="$DEVELOPER_DIR/Library/Developer/usr/lib"
ARGS=(test --disable-sandbox --scratch-path "$PROJECT/.build-tests")

mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm"
export SWIFTPM_CACHE_PATH="${SWIFTPM_CACHE_PATH:-$CACHE_DIR/swiftpm}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$CACHE_DIR/clang}"

if [[ -d "$FRAMEWORK_DIR/Testing.framework" && -f "$INTEROP_DIR/lib_TestingInterop.dylib" ]]; then
    ARGS+=(
        -Xswiftc -F
        -Xswiftc "$FRAMEWORK_DIR"
        -Xlinker "-F$FRAMEWORK_DIR"
        -Xlinker -rpath
        -Xlinker "$FRAMEWORK_DIR"
        -Xlinker -rpath
        -Xlinker "$INTEROP_DIR"
    )
fi

cd "$PROJECT"
exec swift "${ARGS[@]}"
