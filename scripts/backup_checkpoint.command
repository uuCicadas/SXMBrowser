#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
INFO_PLIST="$ROOT/native/SXMBrowserNative/Bundle/Info.plist"
BACKUP_ROOT="${SXM_BROWSER_BACKUP_ROOT:-${ROOT:h}/SXM Browser Backups}"
BUNDLE_DIR="$BACKUP_ROOT/bundles"
MILESTONE_DIR="$BACKUP_ROOT/milestones"
MANIFEST="$BACKUP_ROOT/manifest.tsv"
TEST_SUMMARY="${1:-not-recorded}"

cd "$ROOT"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    print -u2 "Refusing to back up a dirty working tree. Commit the logical change first."
    git status --short
    exit 65
fi

BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
FULL_SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short HEAD)"
BRANCH="$(git branch --show-current)"
STAMP="$(date '+%Y%m%d-%H%M%S')"
TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
PADDED_BUILD="$(printf '%04d' "$BUILD")"
BUNDLE_NAME="sxm-browser-b${PADDED_BUILD}-${STAMP}-${SHORT_SHA}.bundle"
BUNDLE_PATH="$BUNDLE_DIR/$BUNDLE_NAME"

TEST_SUMMARY="${TEST_SUMMARY//$'\n'/ }"
TEST_SUMMARY="${TEST_SUMMARY//$'\t'/ }"

mkdir -p "$BUNDLE_DIR" "$MILESTONE_DIR"
if [[ -e "$BUNDLE_PATH" ]]; then
    print -u2 "Backup already exists: $BUNDLE_PATH"
    exit 73
fi

git bundle create "$BUNDLE_PATH" --all
git bundle verify "$BUNDLE_PATH"
CHECKSUM="$(shasum -a 256 "$BUNDLE_PATH" | awk '{print $1}')"

if [[ ! -f "$MANIFEST" ]]; then
    print -r -- $'timestamp\tbuild\tversion\tbranch\tcommit\tbundle\tsha256\ttests' > "$MANIFEST"
fi

print -r -- "${TIMESTAMP}\t${BUILD}\t${VERSION}\t${BRANCH}\t${FULL_SHA}\t${BUNDLE_NAME}\t${CHECKSUM}\t${TEST_SUMMARY}" >> "$MANIFEST"

print "Backup verified: $BUNDLE_PATH"
print "SHA-256: $CHECKSUM"
