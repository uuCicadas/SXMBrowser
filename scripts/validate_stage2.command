#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
PROJECT="$ROOT/native/SXMBrowserNative"
APP="$ROOT/SXM Browser.app"
PROGRAM="$0"
BUILD_ID="$(md5 -q -s "$PROJECT")"
BUILD_DIR="$PROJECT/.build-$BUILD_ID"
RELEASE_DIR="$BUILD_DIR/release"
CACHE_DIR="$PROJECT/.build-cache-$BUILD_ID"

usage() {
    print -u2 \
        "Usage: $PROGRAM [--sample-dir <canonical-example-graph>]"
}

if [[ $# -eq 0 ]]; then
    SAMPLE_DIR="${ROOT:h}/example-graph"
elif [[ $# -eq 2 && "$1" == "--sample-dir" && -n "$2" ]]; then
    SAMPLE_DIR="${2:A}"
else
    usage
    exit 64
fi

run_step() {
    local name="$1"
    shift
    print "stage=$name status=running"
    if "$@"; then
        print "stage=$name status=passed"
    else
        local code=$?
        print -u2 "stage=$name status=failed exit_code=$code"
        print -u2 "stage2_validation=failed"
        exit "$code"
    fi
}

check_platform() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        print -u2 "Stage 2 validation requires macOS."
        return 69
    fi
    if [[ "$(uname -m)" != "arm64" ]]; then
        print -u2 "Stage 2 validation requires native Apple Silicon."
        return 69
    fi
    if ! command -v swift >/dev/null 2>&1; then
        print -u2 "The Swift toolchain is unavailable."
        return 69
    fi
    if ! command -v xcode-select >/dev/null 2>&1 \
        || ! xcode-select -p >/dev/null 2>&1; then
        print -u2 "The active Xcode developer directory is unavailable."
        return 69
    fi

    local version
    local major
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    if [[ "$major" != <-> || "$major" -lt 14 ]]; then
        print -u2 "Stage 2 validation requires macOS 14 or newer."
        return 69
    fi
}

check_sample_directory() {
    if [[ ! -d "$SAMPLE_DIR" || ! -r "$SAMPLE_DIR" ]]; then
        print -u2 \
            "Canonical sample directory is missing or unreadable: $SAMPLE_DIR"
        return 66
    fi
}

build_debug() {
    (
        cd "$PROJECT"
        swift build --disable-sandbox -c debug --scratch-path "$BUILD_DIR"
    )
}

check_app_bundle() {
    local executable_name
    local minimum_system

    if [[ ! -d "$APP/Contents" \
        || ! -f "$APP/Contents/Info.plist" \
        || ! -x "$APP/Contents/MacOS/SXMBrowserNative" \
        || ! -s "$APP/Contents/Resources/AppIcon.icns" ]]; then
        print -u2 "The built App bundle is incomplete: $APP"
        return 1
    fi
    if ! plutil -lint "$APP/Contents/Info.plist" >/dev/null; then
        print -u2 "The built App Info.plist is invalid."
        return 1
    fi
    if ! cmp -s \
        "$PROJECT/Bundle/Info.plist" \
        "$APP/Contents/Info.plist"; then
        print -u2 "The built App Info.plist does not match the source."
        return 1
    fi

    executable_name="$(
        plutil -extract CFBundleExecutable raw \
            "$APP/Contents/Info.plist"
    )"
    minimum_system="$(
        plutil -extract LSMinimumSystemVersion raw \
            "$APP/Contents/Info.plist"
    )"
    if [[ "$executable_name" != "SXMBrowserNative" \
        || "${minimum_system%%.*}" != <-> \
        || "${minimum_system%%.*}" -lt 14 ]]; then
        print -u2 "The built App bundle metadata is inconsistent."
        return 1
    fi
    if ! lipo "$APP/Contents/MacOS/SXMBrowserNative" \
        -verify_arch arm64 >/dev/null 2>&1; then
        print -u2 "The built App executable does not contain arm64."
        return 1
    fi
    if [[ ! -x "$RELEASE_DIR/SXMBrowserSmoke" \
        || ! -x "$RELEASE_DIR/SXMBrowserBenchmark" ]]; then
        print -u2 "Release validation executables are missing."
        return 1
    fi
}

mkdir -p "$CACHE_DIR/clang" "$CACHE_DIR/swiftpm"
export SWIFTPM_CACHE_PATH="$CACHE_DIR/swiftpm"
export CLANG_MODULE_CACHE_PATH="$CACHE_DIR/clang"

run_step platform check_platform
run_step canonical_sample check_sample_directory
run_step tests "$ROOT/scripts/test_all.command"
run_step debug_build build_debug
run_step release_app_build "$ROOT/scripts/build_native_app.command"
run_step app_bundle check_app_bundle
run_step canonical_smoke \
    "$RELEASE_DIR/SXMBrowserSmoke" \
    --canonical-sample "$SAMPLE_DIR"
run_step performance_gate \
    "$RELEASE_DIR/SXMBrowserBenchmark" \
    --files 500 \
    --width 512 \
    --height 512 \
    --trials 5 \
    --max-scan-ms 1000 \
    --max-image-ms 100 \
    --max-thumbnail-ms 100

print "stage2_validation=passed"
