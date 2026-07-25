#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
INFO_PLIST="$ROOT/native/SXMBrowserNative/Bundle/Info.plist"
BACKUP_ROOT="${SXM_BROWSER_BACKUP_ROOT:-${ROOT:h}/SXM Browser Backups}"
MILESTONE_DIR="$BACKUP_ROOT/milestones"
MANIFEST="$BACKUP_ROOT/manifest.tsv"

if [[ $# -lt 2 || $# -gt 3 ]]; then
    print -u2 "Usage: $0 <tag> <verified-bundle-path> [test-summary]"
    exit 64
fi

TAG="$1"
BUNDLE_PATH="$2"
TEST_SUMMARY="${3:-full-validation-passed}"

cd "$ROOT"

if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    print -u2 "Refusing to archive a dirty working tree."
    git status --short
    exit 65
fi

if [[ "$(git cat-file -t "refs/tags/$TAG" 2>/dev/null || true)" != "tag" ]]; then
    print -u2 "Annotated tag not found: $TAG"
    exit 66
fi

HEAD_SHA="$(git rev-parse HEAD)"
TAG_SHA="$(git rev-list -n 1 "$TAG")"
if [[ "$HEAD_SHA" != "$TAG_SHA" ]]; then
    print -u2 "Tag $TAG does not point to HEAD."
    exit 65
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
if [[ "$TAG" != "v$VERSION" ]]; then
    print -u2 "Tag $TAG does not match semantic version $VERSION."
    exit 65
fi

if [[ ! -f "$BUNDLE_PATH" ]]; then
    print -u2 "Verified bundle not found: $BUNDLE_PATH"
    exit 66
fi
git bundle verify "$BUNDLE_PATH"
if [[ -z "$(git bundle list-heads "$BUNDLE_PATH" "refs/tags/$TAG")" ]]; then
    print -u2 "Bundle does not contain refs/tags/$TAG."
    exit 65
fi

mkdir -p "$MILESTONE_DIR"
ARCHIVE_NAME="sxm-browser-${TAG}-source.zip"
ARCHIVE_PATH="$MILESTONE_DIR/$ARCHIVE_NAME"
if [[ -e "$ARCHIVE_PATH" ]]; then
    print -u2 "Milestone archive already exists: $ARCHIVE_PATH"
    exit 73
fi

git archive \
    --format=zip \
    --prefix="sxm-browser-${TAG}/" \
    --output="$ARCHIVE_PATH" \
    "$TAG"
unzip -t "$ARCHIVE_PATH"
CHECKSUM="$(shasum -a 256 "$ARCHIVE_PATH" | awk '{print $1}')"
BRANCH="$(git branch --show-current)"
TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
TEST_SUMMARY="${TEST_SUMMARY//$'\n'/ }"
TEST_SUMMARY="${TEST_SUMMARY//$'\t'/ }"

if [[ ! -f "$MANIFEST" ]]; then
    print -r -- $'timestamp\tbuild\tversion\tbranch\tcommit\tbundle\tsha256\ttests' > "$MANIFEST"
fi
print -r -- "${TIMESTAMP}\t${BUILD}\t${VERSION}\t${BRANCH}\t${HEAD_SHA}\t${ARCHIVE_NAME}\t${CHECKSUM}\tmilestone:${TEST_SUMMARY}" >> "$MANIFEST"

print "Milestone archive verified: $ARCHIVE_PATH"
print "SHA-256: $CHECKSUM"
