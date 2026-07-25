#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
COMMON="$SCRIPT_DIR/lib/checkpoint_common.zsh"
INFO_PLIST="$ROOT/native/SXMBrowserNative/Bundle/Info.plist"
CHANGELOG="$ROOT/CHANGELOG.md"
BACKUP_ROOT="${SXM_BROWSER_BACKUP_ROOT:-${ROOT:h}/SXM Browser Backups}"
BUNDLE_DIR="$BACKUP_ROOT/bundles"
MILESTONE_DIR="$BACKUP_ROOT/milestones"
MANIFEST="$BACKUP_ROOT/manifest.tsv"
PENDING_DIR="$BACKUP_ROOT/.pending"
TRANSACTION_ROOT="$BACKUP_ROOT/.transactions"

source "$COMMON"

if [[ $# -ne 1 || -z "${1//[[:space:]]/}" ]]; then
    print -u2 "Usage: $0 \"verified test summary\""
    exit 64
fi
TEST_SUMMARY="$1"
sxm_sanitize_field "$TEST_SUMMARY"
TEST_SUMMARY="$REPLY"
if [[ -z "${TEST_SUMMARY//[[:space:]]/}" ]]; then
    sxm_error "Test summary must not be empty."
    exit 64
fi

cd "$ROOT"

if [[ ! -f "$INFO_PLIST" || ! -f "$CHANGELOG" ]]; then
    sxm_error "Missing Info.plist or CHANGELOG.md."
    exit 66
fi

ACTIVE_TRANSACTION_DIR=""
ACTIVE_RECEIPT=""
ACTIVE_MANIFEST_SNAPSHOT=""
BUNDLE_NAME=""
BUNDLE_PATH=""
CLEANUP_RAN=0

cleanup_once() {
    local exit_code="$1"
    if [[ "$CLEANUP_RAN" == "1" ]]; then
        return 0
    fi
    CLEANUP_RAN=1
    if [[ -n "${ACTIVE_TRANSACTION_DIR:-}" \
        && -d "$ACTIVE_TRANSACTION_DIR" \
        && -z "${ACTIVE_RECEIPT:-}" ]]; then
        rm -f "$ACTIVE_TRANSACTION_DIR/$BUNDLE_NAME"
        rmdir "$ACTIVE_TRANSACTION_DIR" 2>/dev/null || true
    fi
    if [[ -n "${ACTIVE_MANIFEST_SNAPSHOT:-}" ]]; then
        rm -f "$ACTIVE_MANIFEST_SNAPSHOT"
    fi
    sxm_release_backup_lock
}

TRAPZERR() {
    local exit_code=$?
    if (( ZSH_SUBSHELL > 0 )); then
        return "$exit_code"
    fi
    cleanup_once "$exit_code"
    return "$exit_code"
}

TRAPEXIT() {
    local exit_code=$?
    if (( ZSH_SUBSHELL > 0 )); then
        return "$exit_code"
    fi
    cleanup_once "$exit_code"
}

mkdir -p \
    "$BUNDLE_DIR" \
    "$MILESTONE_DIR" \
    "$PENDING_DIR" \
    "$TRANSACTION_ROOT"
sxm_acquire_backup_lock "$BACKUP_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sxm_error "Checkpoint must run inside a Git work tree."
    exit 69
fi
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    sxm_error \
        "Refusing to back up a dirty working tree. Commit the logical change first."
    git status --short
    exit 65
fi

BRANCH="$(git branch --show-current)"
if [[ -z "$BRANCH" ]]; then
    sxm_error "Refusing to back up a detached HEAD."
    exit 65
fi

BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
if [[ "$BUILD" != <-> || "$BUILD" -lt 1 ]]; then
    sxm_error "CFBundleVersion must be a positive integer."
    exit 65
fi
if ! print -r -- "$VERSION" \
    | awk '
        /^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$/ {
            valid = 1
        }
        END { exit(valid ? 0 : 1) }
    '; then
    sxm_error "CFBundleShortVersionString must be a semantic version."
    exit 65
fi

CHANGELOG_BUILD_COUNT="$(
    awk -v build="$BUILD" '
        index($0, "- Build " build " (") == 1 { count++ }
        END { print count + 0 }
    ' "$CHANGELOG"
)"
if [[ "$CHANGELOG_BUILD_COUNT" != "1" ]]; then
    sxm_error \
        "CHANGELOG.md must contain exactly one entry for build $BUILD."
    exit 65
fi

FULL_SHA="$(git rev-parse HEAD)"
SHORT_SHA="$(git rev-parse --short HEAD)"
STAMP="$(date '+%Y%m%d-%H%M%S')"
TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
PADDED_BUILD="$(printf '%04d' "$((10#$BUILD))")"
BUNDLE_NAME="sxm-browser-b${PADDED_BUILD}-${STAMP}-${SHORT_SHA}.bundle"
BUNDLE_PATH="$BUNDLE_DIR/$BUNDLE_NAME"

ALLOW_MISSING_MANIFEST=0
if [[ ! -f "$MANIFEST" ]]; then
    setopt local_options null_glob
    existing_artifacts=(
        "$BUNDLE_DIR"/*.bundle
        "$MILESTONE_DIR"/*.zip
    )
    pending_receipts=("$PENDING_DIR"/*.pending)
    existing_transactions=("$TRANSACTION_ROOT"/*)
    if (( ${#existing_artifacts} > 0 \
        || ${#pending_receipts} > 0 \
        || ${#existing_transactions} > 0 )); then
        sxm_error \
            "Backup manifest is missing while backup artifacts or transactions still exist: $MANIFEST"
        exit 65
    fi
    ALLOW_MISSING_MANIFEST=1
fi

ACTIVE_MANIFEST_SNAPSHOT="$(
    mktemp "$BACKUP_ROOT/.manifest-preflight.XXXXXX"
)"
if ! sxm_make_manifest_snapshot \
    "$MANIFEST" \
    "$ACTIVE_MANIFEST_SNAPSHOT" \
    0 \
    "$ALLOW_MISSING_MANIFEST"; then
    rm -f "$ACTIVE_MANIFEST_SNAPSHOT"
    ACTIVE_MANIFEST_SNAPSHOT=""
    sxm_error \
        "The backup manifest is not canonical. Run migrate_backup_manifest.command --check/--apply first."
    exit 65
fi
rm -f "$ACTIVE_MANIFEST_SNAPSHOT"
ACTIVE_MANIFEST_SNAPSHOT=""

sxm_recover_pending_receipts "$BACKUP_ROOT" "$MANIFEST"
ACTIVE_MANIFEST_SNAPSHOT="$(
    mktemp "$BACKUP_ROOT/.manifest-inventory.XXXXXX"
)"
sxm_make_manifest_snapshot \
    "$MANIFEST" \
    "$ACTIVE_MANIFEST_SNAPSHOT" \
    0 \
    "$ALLOW_MISSING_MANIFEST"
sxm_verify_manifest_inventory \
    "$BACKUP_ROOT" \
    "$ACTIVE_MANIFEST_SNAPSHOT"
rm -f "$ACTIVE_MANIFEST_SNAPSHOT"
ACTIVE_MANIFEST_SNAPSHOT=""
if (( SXM_RECOVERED_PENDING_COUNT > 0 )); then
    print \
        "Recovered $SXM_RECOVERED_PENDING_COUNT pending checkpoint(s); no new bundle was created."
    exit 0
fi
sxm_refuse_unreceipted_transactions "$BACKUP_ROOT"

if [[ -e "$BUNDLE_PATH" ]]; then
    sxm_error "Backup already exists: $BUNDLE_PATH"
    exit 73
fi

ACTIVE_TRANSACTION_DIR="$(
    mktemp -d "$TRANSACTION_ROOT/bundle.XXXXXX"
)"
TEMP_BUNDLE="$ACTIVE_TRANSACTION_DIR/$BUNDLE_NAME"
git bundle create "$TEMP_BUNDLE" --all
git bundle verify "$TEMP_BUNDLE"

if ! git bundle list-heads \
    "$TEMP_BUNDLE" \
    "refs/heads/$BRANCH" \
    | awk -v wanted="$FULL_SHA" \
        '$1 == wanted { found = 1 } END { exit(found ? 0 : 1) }'; then
    sxm_error \
        "Bundle does not advertise refs/heads/$BRANCH at $FULL_SHA."
    exit 65
fi

CHECKSUM="$(sxm_sha256 "$TEMP_BUNDLE")"
sxm_maybe_fail after_bundle_verified

sxm_make_manifest_row \
    "$TIMESTAMP" \
    "$BUILD" \
    "$VERSION" \
    "$BRANCH" \
    "$FULL_SHA" \
    "$BUNDLE_NAME" \
    "$CHECKSUM" \
    "$TEST_SUMMARY"
MANIFEST_ROW="$REPLY"

sxm_write_pending_receipt \
    "$BACKUP_ROOT" \
    "$TEMP_BUNDLE" \
    "$MANIFEST_ROW"
ACTIVE_RECEIPT="$REPLY"
sxm_maybe_fail after_receipt

mv "$TEMP_BUNDLE" "$BUNDLE_PATH"
sxm_verify_artifact "$BUNDLE_PATH" "$CHECKSUM"
sxm_maybe_fail after_artifact_publish

sxm_append_manifest_row_atomic "$MANIFEST" "$MANIFEST_ROW"
sxm_maybe_fail after_manifest_publish

RECORDED_ROW="$(
    sxm_manifest_row_for_artifact "$MANIFEST" "$BUNDLE_NAME"
)"
if [[ "$RECORDED_ROW" != "$MANIFEST_ROW" ]]; then
    sxm_error "Published manifest row does not match the verified bundle."
    exit 65
fi
sxm_verify_artifact "$BUNDLE_PATH" "$CHECKSUM"

sxm_remove_completed_receipt "$ACTIVE_RECEIPT" "$TEMP_BUNDLE"
ACTIVE_RECEIPT=""
ACTIVE_TRANSACTION_DIR=""

print "Backup verified: $BUNDLE_PATH"
print "SHA-256: $CHECKSUM"
