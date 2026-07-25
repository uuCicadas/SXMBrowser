#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
INFO_PLIST="$ROOT/native/SXMBrowserNative/Bundle/Info.plist"
CHANGELOG="$ROOT/CHANGELOG.md"

if [[ $# -ne 1 || -z "${1//[[:space:]]/}" ]]; then
    print -u2 "Usage: $0 \"checkpoint summary\""
    exit 64
fi

if [[ ! -f "$INFO_PLIST" || ! -f "$CHANGELOG" ]]; then
    print -u2 "Missing Info.plist or CHANGELOG.md."
    exit 66
fi

CURRENT_BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
if [[ "$CURRENT_BUILD" != <-> ]]; then
    print -u2 "CFBundleVersion must be a positive integer."
    exit 65
fi

NEXT_BUILD=$((CURRENT_BUILD + 1))
SUMMARY="${1//$'\n'/ }"
SUMMARY="${SUMMARY//$'\t'/ }"
TODAY="$(date '+%Y-%m-%d')"
TEMP_CHANGELOG="$(mktemp "${TMPDIR:-/tmp}/sxm-changelog.XXXXXX")"
trap 'rm -f "$TEMP_CHANGELOG"' EXIT

plutil -replace CFBundleVersion -string "$NEXT_BUILD" "$INFO_PLIST"

awk -v entry="- Build ${NEXT_BUILD} (${TODAY}): ${SUMMARY}" '
    BEGIN { inserted = 0 }
    {
        print
        if (!inserted && $0 == "## Unreleased") {
            print ""
            print entry
            inserted = 1
            getline
            if ($0 != "") {
                print $0
            }
        }
    }
    END {
        if (!inserted) {
            exit 2
        }
    }
' "$CHANGELOG" > "$TEMP_CHANGELOG"

mv "$TEMP_CHANGELOG" "$CHANGELOG"
trap - EXIT

print "Checkpoint prepared: build $NEXT_BUILD"
print "Next: run tests, commit the logical change, then run backup_checkpoint.command."
