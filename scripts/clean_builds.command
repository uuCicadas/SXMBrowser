#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
PROJECT="$ROOT/native/SXMBrowserNative"
BUILD_ID="$(md5 -q -s "$PROJECT")"

usage() {
    print -u2 "Usage: $0 [--all]"
}

CLEAN_ALL=0
if [[ $# -eq 0 ]]; then
    CLEAN_ALL=0
elif [[ $# -eq 1 && "$1" == "--all" ]]; then
    CLEAN_ALL=1
else
    usage
    exit 64
fi

ACTIVE_BUILD=".build-$BUILD_ID"
ACTIVE_CACHE=".build-cache-$BUILD_ID"
ACTIVE_TESTS=".build-tests"

setopt local_options null_glob
removed=()
kept=()

for entry in "$PROJECT"/.build*; do
    name="${entry:t}"
    if [[ "$CLEAN_ALL" == "0" && ( "$name" == "$ACTIVE_BUILD" || "$name" == "$ACTIVE_CACHE" || "$name" == "$ACTIVE_TESTS" ) ]]; then
        kept+=("$entry")
        continue
    fi
    rm -rf "$entry"
    removed+=("$entry")
done

if (( ${#removed[@]} == 0 )); then
    print "No stale build directories removed."
else
    unit="directories"
    (( ${#removed[@]} == 1 )) && unit="directory"
    print "Removed ${#removed[@]} build ${unit}:"
    for item in "${removed[@]}"; do
        print "  - $item"
    done
fi

if (( ${#kept[@]} > 0 )); then
    kept_unit="directories"
    (( ${#kept[@]} == 1 )) && kept_unit="directory"
    print "Kept ${#kept[@]} active build/cache ${kept_unit}:"
    for item in "${kept[@]}"; do
        print "  - $item"
    done
fi
