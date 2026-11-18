#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
COMMON="$SCRIPT_DIR/lib/checkpoint_common.zsh"
INFO_PLIST="$ROOT/native/SXMBrowserNative/Bundle/Info.plist"
BACKUP_ROOT="${SXM_BROWSER_BACKUP_ROOT:-${ROOT:h}/SXM Browser Backups}"
BUNDLE_DIR="$BACKUP_ROOT/bundles"
MILESTONE_DIR="$BACKUP_ROOT/milestones"
MANIFEST="$BACKUP_ROOT/manifest.tsv"
PENDING_DIR="$BACKUP_ROOT/.pending"
TRANSACTION_ROOT="$BACKUP_ROOT/.transactions"
TEMP_BASE="${TMPDIR:-/tmp}"
TEMP_BASE="${TEMP_BASE:A}"

source "$COMMON"

usage() {
    print -u2 \
        "Usage: $0 <annotated-tag> --sample-dir <canonical-example-graph>"
}

if [[ $# -ne 3 \
    || "$2" != "--sample-dir" \
    || -z "${1//[[:space:]]/}" \
    || -z "${3//[[:space:]]/}" ]]; then
    usage
    exit 64
fi

TAG="$1"
SAMPLE_DIR="${3:A}"
TAG_REF="refs/tags/$TAG"

if ! print -r -- "$TAG" \
    | awk '/^v[0-9]+\.[0-9]+\.[0-9]+$/ { valid = 1 } END { exit(valid ? 0 : 1) }'; then
    sxm_error "Milestone tag must use the form v<major>.<minor>.<patch>."
    exit 64
fi
cd "$ROOT"

ACTIVE_TRANSACTION_DIR=""
ACTIVE_RECEIPT=""
ACTIVE_MANIFEST_SNAPSHOT=""
RESTORE_ROOT=""
ARCHIVE_NAME=""
CLEANUP_RAN=0

milestone_remove_restore_root() {
    if [[ -z "${RESTORE_ROOT:-}" ]]; then
        return 0
    fi
    local normalized_restore="${RESTORE_ROOT:A}"
    if [[ "${normalized_restore:h}" != "$TEMP_BASE" \
        || "${normalized_restore:t}" != sxm-milestone-restore.* ]]; then
        sxm_error \
            "Refusing to remove an unexpected restore directory: $RESTORE_ROOT"
        return 65
    fi
    rm -rf "$normalized_restore" || return $?
    RESTORE_ROOT=""
}

cleanup_once() {
    local exit_code="$1"
    if [[ "$CLEANUP_RAN" == "1" ]]; then
        return 0
    fi
    CLEANUP_RAN=1
    milestone_remove_restore_root || true
    if [[ -n "${ACTIVE_TRANSACTION_DIR:-}" \
        && -d "$ACTIVE_TRANSACTION_DIR" \
        && -z "${ACTIVE_RECEIPT:-}" ]]; then
        if [[ -n "${ARCHIVE_NAME:-}" ]]; then
            rm -f "$ACTIVE_TRANSACTION_DIR/$ARCHIVE_NAME"
        fi
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

verify_source_archive() {
    local archive_path="$1"
    local expected_prefix="$2"

    if ! unzip -t "$archive_path" >/dev/null 2>&1; then
        sxm_error "Milestone source archive failed ZIP validation: $archive_path"
        return 65
    fi
    if ! unzip -Z1 "$archive_path" \
        | awk -v expectedPrefix="$expected_prefix" '
            function reject(message, path) {
                printf "%s: %s\n", message, path > "/dev/stderr"
                invalid = 1
            }
            function forbidden(component) {
                return component == ".DS_Store" \
                    || component == "__MACOSX" \
                    || component == ".git" \
                    || component == ".swiftpm" \
                    || component == "DerivedData" \
                    || component == "dist" \
                    || component == "backups" \
                    || component == "example-graph" \
                    || component == "SXM Browser Backups" \
                    || component ~ /^\.build($|[-.])/ \
                    || component ~ /^\.build-cache($|[-.])/ \
                    || component ~ /\.app$/
            }
            {
                entries++
                if (index($0, expectedPrefix) != 1) {
                    reject("archive entry is outside the expected prefix", $0)
                    next
                }
                relative = substr($0, length(expectedPrefix) + 1)
                if (relative == "") {
                    next
                }
                if (substr(relative, 1, 1) == "/") {
                    reject("archive entry is absolute", $0)
                    next
                }
                count = split(relative, components, "/")
                for (indexValue = 1; indexValue <= count; indexValue++) {
                    component = components[indexValue]
                    if (component == ".." || forbidden(component)) {
                        reject("archive entry is forbidden", $0)
                        break
                    }
                }
                if (substr($0, length($0), 1) != "/") {
                    files++
                }
            }
            END {
                if (entries == 0 || files == 0) {
                    printf "archive has no source files\n" > "/dev/stderr"
                    invalid = 1
                }
                exit(invalid ? 65 : 0)
            }
        '; then
        sxm_error \
            "Milestone source archive contains unsafe or generated content: $archive_path"
        return 65
    fi
}

mkdir -p \
    "$BUNDLE_DIR" \
    "$MILESTONE_DIR" \
    "$PENDING_DIR" \
    "$TRANSACTION_ROOT"
sxm_acquire_backup_lock "$BACKUP_ROOT"

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sxm_error "Milestone checkpoint must run inside a Git work tree."
    exit 69
fi

ACTIVE_MANIFEST_SNAPSHOT="$(
    mktemp "$BACKUP_ROOT/.manifest-milestone-preflight.XXXXXX"
)"
if ! sxm_make_manifest_snapshot \
    "$MANIFEST" \
    "$ACTIVE_MANIFEST_SNAPSHOT" \
    0 \
    0; then
    rm -f "$ACTIVE_MANIFEST_SNAPSHOT"
    ACTIVE_MANIFEST_SNAPSHOT=""
    sxm_error \
        "Milestones require an existing canonical manifest with verified history."
    exit 65
fi
rm -f "$ACTIVE_MANIFEST_SNAPSHOT"
ACTIVE_MANIFEST_SNAPSHOT=""

sxm_recover_pending_receipts "$BACKUP_ROOT" "$MANIFEST"
ACTIVE_MANIFEST_SNAPSHOT="$(
    mktemp "$BACKUP_ROOT/.manifest-milestone-inventory.XXXXXX"
)"
sxm_make_manifest_snapshot \
    "$MANIFEST" \
    "$ACTIVE_MANIFEST_SNAPSHOT" \
    0 \
    0
sxm_verify_manifest_inventory \
    "$BACKUP_ROOT" \
    "$ACTIVE_MANIFEST_SNAPSHOT"
sxm_refuse_unreceipted_transactions "$BACKUP_ROOT"
if (( SXM_RECOVERED_PENDING_COUNT > 0 )); then
    print \
        "Recovered $SXM_RECOVERED_PENDING_COUNT pending checkpoint(s); no new milestone was created."
    exit 0
fi

if [[ ! -d "$SAMPLE_DIR" || ! -r "$SAMPLE_DIR" ]]; then
    sxm_error "Canonical sample directory is missing or unreadable: $SAMPLE_DIR"
    exit 66
fi
if [[ -n "$(git status --porcelain --untracked-files=all)" ]]; then
    sxm_error "Refusing to create a milestone from a dirty working tree."
    git status --short
    exit 65
fi

BRANCH="$(git branch --show-current)"
if [[ -z "$BRANCH" ]]; then
    sxm_error "Refusing to create a milestone from detached HEAD."
    exit 65
fi
if [[ "$(git cat-file -t "$TAG_REF" 2>/dev/null || true)" != "tag" ]]; then
    sxm_error "Annotated tag not found: $TAG"
    exit 66
fi

TAG_OBJECT="$(git rev-parse "$TAG_REF")"
TAG_COMMIT="$(git rev-parse "$TAG_REF^{commit}")"
HEAD_SHA="$(git rev-parse HEAD)"
if [[ "$HEAD_SHA" != "$TAG_COMMIT" ]]; then
    sxm_error "Annotated tag $TAG does not peel to HEAD."
    exit 65
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
if [[ "$VERSION" != <->.<->.<-> || "$TAG" != "v$VERSION" ]]; then
    sxm_error "Tag $TAG does not match semantic version $VERSION."
    exit 65
fi
if [[ "$BUILD" != <-> || "$BUILD" -lt 1 ]]; then
    sxm_error "CFBundleVersion must be a positive integer."
    exit 65
fi

ARCHIVE_NAME="sxm-browser-${TAG}-source.zip"
ARCHIVE_PATH="$MILESTONE_DIR/$ARCHIVE_NAME"
if [[ -e "$ARCHIVE_PATH" ]]; then
    sxm_error "Milestone archive already exists: $ARCHIVE_PATH"
    exit 73
fi

sxm_find_latest_verified_bundle_for_tag_object \
    "$BACKUP_ROOT" \
    "$ACTIVE_MANIFEST_SNAPSHOT" \
    "$TAG_REF" \
    "$TAG_OBJECT"
SELECTED_BUNDLE="$REPLY"
SELECTED_BUNDLE_NAME="${SELECTED_BUNDLE:t}"
rm -f "$ACTIVE_MANIFEST_SNAPSHOT"
ACTIVE_MANIFEST_SNAPSHOT=""

RESTORE_ROOT="$(
    mktemp -d "$TEMP_BASE/sxm-milestone-restore.XXXXXX"
)"
RESTORE_REPOSITORY="$RESTORE_ROOT/repository"
git clone --no-checkout "$SELECTED_BUNDLE" "$RESTORE_REPOSITORY"
git -C "$RESTORE_REPOSITORY" fsck --full --strict

if [[ "$(git -C "$RESTORE_REPOSITORY" cat-file -t "$TAG_OBJECT" 2>/dev/null || true)" != "tag" ]]; then
    sxm_error "Restored repository does not contain the annotated tag object."
    exit 65
fi
RESTORED_TAG_OBJECT="$(
    git -C "$RESTORE_REPOSITORY" rev-parse "$TAG_REF"
)"
RESTORED_TAG_COMMIT="$(
    git -C "$RESTORE_REPOSITORY" rev-parse "$TAG_REF^{commit}"
)"
if [[ "$RESTORED_TAG_OBJECT" != "$TAG_OBJECT" \
    || "$RESTORED_TAG_COMMIT" != "$TAG_COMMIT" ]]; then
    sxm_error "Restored annotated tag identity does not match the source repository."
    exit 65
fi

git -C "$RESTORE_REPOSITORY" checkout -q --detach "$TAG_COMMIT"
if [[ "$(git -C "$RESTORE_REPOSITORY" rev-parse HEAD)" != "$TAG_COMMIT" \
    || -n "$(git -C "$RESTORE_REPOSITORY" status --porcelain --untracked-files=all)" ]]; then
    sxm_error "Restored repository did not check out the tagged source cleanly."
    exit 65
fi

RESTORED_INFO_PLIST="$RESTORE_REPOSITORY/native/SXMBrowserNative/Bundle/Info.plist"
RESTORED_VERSION="$(
    plutil -extract CFBundleShortVersionString raw "$RESTORED_INFO_PLIST"
)"
RESTORED_BUILD="$(
    plutil -extract CFBundleVersion raw "$RESTORED_INFO_PLIST"
)"
if [[ "$RESTORED_VERSION" != "$VERSION" \
    || "$RESTORED_BUILD" != "$BUILD" \
    || "$TAG" != "v$RESTORED_VERSION" ]]; then
    sxm_error "Restored tagged build metadata does not match the release checkpoint."
    exit 65
fi

VALIDATION_COMMAND="$RESTORE_REPOSITORY/scripts/validate_stage2.command"
if [[ -n "${SXM_MILESTONE_TEST_VALIDATION_COMMAND:-}" ]]; then
    if [[ "${SXM_CHECKPOINT_TESTING:-0}" != "1" ]]; then
        sxm_error \
            "A milestone validation override is allowed only in checkpoint tests."
        exit 65
    fi
    VALIDATION_COMMAND="${SXM_MILESTONE_TEST_VALIDATION_COMMAND:A}"
fi
if [[ ! -x "$VALIDATION_COMMAND" ]]; then
    sxm_error "Milestone validation command is unavailable: $VALIDATION_COMMAND"
    exit 66
fi
(
    cd "$RESTORE_REPOSITORY"
    export SXM_MILESTONE_RESTORE_REPOSITORY="$RESTORE_REPOSITORY"
    "$VALIDATION_COMMAND" --sample-dir "$SAMPLE_DIR"
)
sxm_maybe_fail after_restore_validation

ACTIVE_TRANSACTION_DIR="$(
    mktemp -d "$TRANSACTION_ROOT/milestone.XXXXXX"
)"
TEMP_ARCHIVE="$ACTIVE_TRANSACTION_DIR/$ARCHIVE_NAME"
ARCHIVE_PREFIX="sxm-browser-${TAG}/"
git -C "$RESTORE_REPOSITORY" archive \
    --format=zip \
    --prefix="$ARCHIVE_PREFIX" \
    --output="$TEMP_ARCHIVE" \
    "$TAG_REF"
verify_source_archive "$TEMP_ARCHIVE" "$ARCHIVE_PREFIX"
CHECKSUM="$(sxm_sha256 "$TEMP_ARCHIVE")"
sxm_verify_artifact "$TEMP_ARCHIVE" "$CHECKSUM"
sxm_maybe_fail after_milestone_archive_verified

milestone_remove_restore_root

if [[ -n "$(git status --porcelain --untracked-files=all)" \
    || "$(git branch --show-current)" != "$BRANCH" \
    || "$(git rev-parse HEAD)" != "$HEAD_SHA" \
    || "$(git rev-parse "$TAG_REF")" != "$TAG_OBJECT" \
    || "$(git rev-parse "$TAG_REF^{commit}")" != "$TAG_COMMIT" ]]; then
    sxm_error "Source repository or annotated tag changed during milestone validation."
    exit 65
fi

TIMESTAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"
TEST_SUMMARY="milestone:restore=${SELECTED_BUNDLE_NAME};fsck=passed;validate_stage2=passed;source_archive=passed"
sxm_make_manifest_row \
    "$TIMESTAMP" \
    "$RESTORED_BUILD" \
    "$RESTORED_VERSION" \
    "$BRANCH" \
    "$TAG_COMMIT" \
    "$ARCHIVE_NAME" \
    "$CHECKSUM" \
    "$TEST_SUMMARY"
MANIFEST_ROW="$REPLY"

sxm_write_pending_receipt \
    "$BACKUP_ROOT" \
    "$TEMP_ARCHIVE" \
    "$MANIFEST_ROW"
ACTIVE_RECEIPT="$REPLY"
sxm_maybe_fail after_receipt

mv "$TEMP_ARCHIVE" "$ARCHIVE_PATH"
sxm_verify_artifact "$ARCHIVE_PATH" "$CHECKSUM"
verify_source_archive "$ARCHIVE_PATH" "$ARCHIVE_PREFIX"
sxm_maybe_fail after_artifact_publish

sxm_append_manifest_row_atomic "$MANIFEST" "$MANIFEST_ROW"
sxm_maybe_fail after_manifest_publish

RECORDED_ROW="$(
    sxm_manifest_row_for_artifact "$MANIFEST" "$ARCHIVE_NAME"
)"
if [[ "$RECORDED_ROW" != "$MANIFEST_ROW" ]]; then
    sxm_error "Published milestone manifest row does not match its source archive."
    exit 65
fi
sxm_verify_artifact "$ARCHIVE_PATH" "$CHECKSUM"
verify_source_archive "$ARCHIVE_PATH" "$ARCHIVE_PREFIX"

sxm_remove_completed_receipt "$ACTIVE_RECEIPT" "$TEMP_ARCHIVE"
ACTIVE_RECEIPT=""
ACTIVE_TRANSACTION_DIR=""

print "Milestone archive verified: $ARCHIVE_PATH"
print "Restored from Bundle: $SELECTED_BUNDLE"
print "SHA-256: $CHECKSUM"
