#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
PROJECT="$ROOT/native/SXMBrowserNative"
DEVELOPER_DIR="$(xcode-select -p)"
FRAMEWORK_DIR="$DEVELOPER_DIR/Library/Developer/Frameworks"
INTEROP_DIR="$DEVELOPER_DIR/Library/Developer/usr/lib"
ARGS=(test --scratch-path "$PROJECT/.build-tests")

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
