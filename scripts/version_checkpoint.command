#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
COMMON="$SCRIPT_DIR/lib/checkpoint_common.zsh"
INFO_PLIST="$ROOT/native/SXMBrowserNative/Bundle/Info.plist"
CHANGELOG="$ROOT/CHANGELOG.md"
BACKUP_ROOT="${SXM_BROWSER_BACKUP_ROOT:-${ROOT:h}/SXM Browser Backups}"
MANIFEST="$BACKUP_ROOT/manifest.tsv"

source "$COMMON"

if [[ $# -ne 1 || -z "${1//[[:space:]]/}" ]]; then
    print -u2 "Usage: $0 \"checkpoint summary\""
    exit 64
fi

if [[ ! -f "$INFO_PLIST" || ! -f "$CHANGELOG" ]]; then
    sxm_error "Missing Info.plist or CHANGELOG.md."
    exit 66
fi

cd "$ROOT"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    sxm_error "Checkpoint must run inside a Git work tree."
    exit 69
fi

SUMMARY="$1"
sxm_sanitize_field "$SUMMARY"
SUMMARY="$REPLY"
TODAY="$(date '+%Y-%m-%d')"

GIT_TRANSACTION_PATH="$(git rev-parse --git-path sxm-version-transaction)"
VERSION_TRANSACTION_DIR="${GIT_TRANSACTION_PATH:A}"
VERSION_LOCK_DIR="${VERSION_TRANSACTION_DIR}.lock"
VERSION_TRANSACTION_CREATED=0
VERSION_PREPARED=0
VERSION_LOCK_HELD=0
VERSION_LOCK_TOKEN=""
PREVIOUS_MANIFEST_SNAPSHOT=""
CLEANUP_RAN=0

version_hash() {
    sxm_sha256 "$1"
}

version_remove_transaction() {
    if [[ -d "$VERSION_TRANSACTION_DIR" ]]; then
        rm -f \
            "$VERSION_TRANSACTION_DIR/original-info.plist" \
            "$VERSION_TRANSACTION_DIR/original-changelog.md" \
            "$VERSION_TRANSACTION_DIR/new-info.plist" \
            "$VERSION_TRANSACTION_DIR/new-changelog.md" \
            "$VERSION_TRANSACTION_DIR/generated-changelog.md" \
            "$VERSION_TRANSACTION_DIR/metadata.tsv" || return $?
        if ! rmdir "$VERSION_TRANSACTION_DIR" 2>/dev/null; then
            sxm_error \
                "Version transaction contains unexpected files: $VERSION_TRANSACTION_DIR"
            return 75
        fi
    fi
}

version_read_metadata() {
    local header
    {
        IFS= read -r header
        IFS=$'\t' read -r \
            VERSION_OLD_BUILD \
            VERSION_NEW_BUILD \
            VERSION_OLD_INFO_SHA \
            VERSION_NEW_INFO_SHA \
            VERSION_OLD_CHANGELOG_SHA \
            VERSION_NEW_CHANGELOG_SHA
    } < "$VERSION_TRANSACTION_DIR/metadata.tsv"
    if [[ "$header" != "sxm-version-transaction-v1" \
        || -z "${VERSION_OLD_BUILD:-}" \
        || -z "${VERSION_NEW_BUILD:-}" \
        || -z "${VERSION_OLD_INFO_SHA:-}" \
        || -z "${VERSION_NEW_INFO_SHA:-}" \
        || -z "${VERSION_OLD_CHANGELOG_SHA:-}" \
        || -z "${VERSION_NEW_CHANGELOG_SHA:-}" ]]; then
        sxm_error "Version transaction metadata is malformed."
        return 65
    fi
}

version_validate_transaction_files() {
    local original_info="$VERSION_TRANSACTION_DIR/original-info.plist"
    local original_changelog="$VERSION_TRANSACTION_DIR/original-changelog.md"
    local new_info="$VERSION_TRANSACTION_DIR/new-info.plist"
    local new_changelog="$VERSION_TRANSACTION_DIR/new-changelog.md"
    local original_build
    local prepared_build

    if [[ ! -f "$original_info" \
        || ! -f "$original_changelog" \
        || ! -f "$new_info" \
        || ! -f "$new_changelog" ]]; then
        sxm_error "Version transaction is missing a recovery file."
        return 65
    fi
    if [[ "$(version_hash "$original_info")" != "$VERSION_OLD_INFO_SHA" \
        || "$(version_hash "$new_info")" != "$VERSION_NEW_INFO_SHA" \
        || "$(version_hash "$original_changelog")" != "$VERSION_OLD_CHANGELOG_SHA" \
        || "$(version_hash "$new_changelog")" != "$VERSION_NEW_CHANGELOG_SHA" ]]; then
        sxm_error "Version transaction recovery files failed checksum validation."
        return 65
    fi

    plutil -lint "$original_info" >/dev/null || return $?
    plutil -lint "$new_info" >/dev/null || return $?
    original_build="$(
        plutil -extract CFBundleVersion raw "$original_info"
    )" || return $?
    prepared_build="$(
        plutil -extract CFBundleVersion raw "$new_info"
    )" || return $?
    if [[ "$original_build" != "$VERSION_OLD_BUILD" \
        || "$prepared_build" != "$VERSION_NEW_BUILD" \
        || "$VERSION_OLD_BUILD" != <-> \
        || "$VERSION_NEW_BUILD" != <-> \
        || $((10#$VERSION_OLD_BUILD + 1)) -ne $((10#$VERSION_NEW_BUILD)) ]]; then
        sxm_error "Version transaction build metadata is inconsistent."
        return 65
    fi
    if [[ "$(
        awk -v build="$VERSION_NEW_BUILD" '
            $0 == "## Unreleased" { unreleased++ }
            index($0, "- Build " build " (") == 1 { entries++ }
            END { print (unreleased == 1 && entries == 1) ? "ok" : "bad" }
        ' "$new_changelog"
    )" != "ok" ]]; then
        sxm_error "Prepared Changelog failed transaction validation."
        return 65
    fi
}

version_recover_if_needed() {
    local live_info_sha
    local live_changelog_sha

    if [[ ! -d "$VERSION_TRANSACTION_DIR" ]]; then
        return 0
    fi
    if [[ ! -f "$VERSION_TRANSACTION_DIR/metadata.tsv" ]]; then
        sxm_error \
            "Incomplete version transaction has no recovery metadata: $VERSION_TRANSACTION_DIR"
        return 65
    fi

    version_read_metadata || return $?
    version_validate_transaction_files || return $?
    live_info_sha="$(version_hash "$INFO_PLIST")" || return $?
    live_changelog_sha="$(version_hash "$CHANGELOG")" || return $?

    if [[ "$live_info_sha" == "$VERSION_OLD_INFO_SHA" \
        && "$live_changelog_sha" == "$VERSION_OLD_CHANGELOG_SHA" ]]; then
        version_remove_transaction || return $?
        return 0
    fi

    if [[ "$live_info_sha" != "$VERSION_OLD_INFO_SHA" \
        && "$live_info_sha" != "$VERSION_NEW_INFO_SHA" ]]; then
        sxm_error \
            "Info.plist changed outside the pending version transaction; refusing to overwrite it."
        return 65
    fi
    if [[ "$live_changelog_sha" != "$VERSION_OLD_CHANGELOG_SHA" \
        && "$live_changelog_sha" != "$VERSION_NEW_CHANGELOG_SHA" ]]; then
        sxm_error \
            "CHANGELOG.md changed outside the pending version transaction; refusing to overwrite it."
        return 65
    fi

    sxm_atomic_copy_replace \
        "$VERSION_TRANSACTION_DIR/new-info.plist" \
        "$INFO_PLIST" || return $?
    sxm_atomic_copy_replace \
        "$VERSION_TRANSACTION_DIR/new-changelog.md" \
        "$CHANGELOG" || return $?
    if [[ "$(version_hash "$INFO_PLIST")" != "$VERSION_NEW_INFO_SHA" \
        || "$(version_hash "$CHANGELOG")" != "$VERSION_NEW_CHANGELOG_SHA" ]]; then
        sxm_error "Could not complete the pending version transaction."
        return 74
    fi
    version_remove_transaction || return $?
    print \
        "Recovered prepared checkpoint build $VERSION_NEW_BUILD; refusing to increment it again."
    return 73
}

version_rollback_on_failure() {
    if [[ "$VERSION_TRANSACTION_CREATED" != "1" \
        || ! -d "$VERSION_TRANSACTION_DIR" \
        || "${SXM_CHECKPOINT_TEST_PRESERVE_TRANSACTION:-0}" == "1" ]]; then
        return 0
    fi
    if [[ -f "$VERSION_TRANSACTION_DIR/metadata.tsv" ]]; then
        version_read_metadata || return 0
        version_validate_transaction_files || return 0
        local live_info_sha="$(version_hash "$INFO_PLIST")"
        local live_changelog_sha="$(version_hash "$CHANGELOG")"
        if [[ ( "$live_info_sha" == "$VERSION_OLD_INFO_SHA" \
                || "$live_info_sha" == "$VERSION_NEW_INFO_SHA" ) \
            && ( "$live_changelog_sha" == "$VERSION_OLD_CHANGELOG_SHA" \
                || "$live_changelog_sha" == "$VERSION_NEW_CHANGELOG_SHA" ) ]]; then
            local restored=1
            if ! sxm_atomic_copy_replace \
                "$VERSION_TRANSACTION_DIR/original-info.plist" \
                "$INFO_PLIST"; then
                restored=0
            fi
            if ! sxm_atomic_copy_replace \
                "$VERSION_TRANSACTION_DIR/original-changelog.md" \
                "$CHANGELOG"; then
                restored=0
            fi
            if [[ "$restored" == "1" \
                && "$(version_hash "$INFO_PLIST")" == "$VERSION_OLD_INFO_SHA" \
                && "$(version_hash "$CHANGELOG")" == "$VERSION_OLD_CHANGELOG_SHA" ]]; then
                version_remove_transaction || true
            else
                sxm_error \
                    "CRITICAL: version rollback was incomplete; recovery files were preserved at $VERSION_TRANSACTION_DIR"
            fi
        fi
    else
        version_remove_transaction || true
    fi
}

cleanup_once() {
    local exit_code="$1"
    if [[ "$CLEANUP_RAN" == "1" ]]; then
        return 0
    fi
    CLEANUP_RAN=1
    if (( exit_code != 0 )) && [[ "$VERSION_PREPARED" != "1" ]]; then
        version_rollback_on_failure
    fi
    if [[ -n "${PREVIOUS_MANIFEST_SNAPSHOT:-}" ]]; then
        rm -f "$PREVIOUS_MANIFEST_SNAPSHOT"
    fi
    if [[ "$VERSION_LOCK_HELD" == "1" ]]; then
        local recorded_token=""
        if [[ -f "$VERSION_LOCK_DIR/owner" ]]; then
            IFS= read -r recorded_token \
                < "$VERSION_LOCK_DIR/owner" || true
        fi
        if [[ -n "$VERSION_LOCK_TOKEN" \
            && "$recorded_token" == "$VERSION_LOCK_TOKEN" ]]; then
            rm -f \
                "$VERSION_LOCK_DIR/pid" \
                "$VERSION_LOCK_DIR/owner"
            rmdir "$VERSION_LOCK_DIR" 2>/dev/null || true
        fi
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

if ! mkdir "$VERSION_LOCK_DIR" 2>/dev/null; then
    if ! sxm_reclaim_stale_lock "$VERSION_LOCK_DIR" \
        || ! mkdir "$VERSION_LOCK_DIR" 2>/dev/null; then
        sxm_error "Another version checkpoint operation is active."
        exit 75
    fi
fi
VERSION_LOCK_HELD=1
VERSION_LOCK_TOKEN="$(
    print -r -- "$(hostname):$$:${EPOCHSECONDS:-$(date '+%s')}:$RANDOM$RANDOM"
)"
print -r -- "$$" > "$VERSION_LOCK_DIR/pid"
print -r -- "$VERSION_LOCK_TOKEN" > "$VERSION_LOCK_DIR/owner"

sxm_acquire_backup_lock "$BACKUP_ROOT"
if version_recover_if_needed; then
    :
else
    exit $?
fi

HEAD_BUILD="$(
    git show HEAD:native/SXMBrowserNative/Bundle/Info.plist \
        | plutil -extract CFBundleVersion raw -o - -
)"
CURRENT_BUILD="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
if [[ "$HEAD_BUILD" != <-> || "$HEAD_BUILD" -lt 1 \
    || "$CURRENT_BUILD" != <-> || "$CURRENT_BUILD" -lt 1 ]]; then
    sxm_error "CFBundleVersion must be a positive integer."
    exit 65
fi

CURRENT_ENTRY_COUNT="$(
    awk -v build="$CURRENT_BUILD" '
        index($0, "- Build " build " (") == 1 { count++ }
        END { print count + 0 }
    ' "$CHANGELOG"
)"
if [[ "$CURRENT_BUILD" != "$HEAD_BUILD" ]]; then
    if (( 10#$CURRENT_BUILD == 10#$HEAD_BUILD + 1 )) \
        && [[ "$CURRENT_ENTRY_COUNT" == "1" ]]; then
        sxm_error \
            "Checkpoint build $CURRENT_BUILD is already prepared; commit it instead of incrementing again."
        exit 73
    fi
    sxm_error \
        "Working CFBundleVersion $CURRENT_BUILD does not match HEAD build $HEAD_BUILD."
    exit 65
fi

NEXT_BUILD=$((10#$CURRENT_BUILD + 1))
NEXT_ENTRY_COUNT="$(
    awk -v build="$NEXT_BUILD" '
        index($0, "- Build " build " (") == 1 { count++ }
        END { print count + 0 }
    ' "$CHANGELOG"
)"
if [[ "$NEXT_ENTRY_COUNT" != "0" ]]; then
    sxm_error "CHANGELOG.md already contains build $NEXT_BUILD."
    exit 65
fi

PREVIOUS_MANIFEST_SNAPSHOT="$(
    mktemp "${TMPDIR:-/tmp}/sxm-previous-manifest.XXXXXX"
)"
sxm_make_manifest_snapshot \
    "$MANIFEST" \
    "$PREVIOUS_MANIFEST_SNAPSHOT" \
    1 \
    0
PREVIOUS_HEAD="$(git rev-parse HEAD)"
sxm_find_verified_bundle_for_commit \
    "$BACKUP_ROOT" \
    "$PREVIOUS_MANIFEST_SNAPSHOT" \
    "$PREVIOUS_HEAD" >/dev/null
rm -f "$PREVIOUS_MANIFEST_SNAPSHOT"
PREVIOUS_MANIFEST_SNAPSHOT=""

mkdir "$VERSION_TRANSACTION_DIR"
VERSION_TRANSACTION_CREATED=1
cp -p "$INFO_PLIST" \
    "$VERSION_TRANSACTION_DIR/original-info.plist"
cp -p "$CHANGELOG" \
    "$VERSION_TRANSACTION_DIR/original-changelog.md"
cp -p "$INFO_PLIST" \
    "$VERSION_TRANSACTION_DIR/new-info.plist"
cp -p "$CHANGELOG" \
    "$VERSION_TRANSACTION_DIR/new-changelog.md"

plutil -replace CFBundleVersion \
    -string "$NEXT_BUILD" \
    "$VERSION_TRANSACTION_DIR/new-info.plist"
plutil -lint "$VERSION_TRANSACTION_DIR/new-info.plist" >/dev/null

SXM_CHANGELOG_ENTRY="- Build ${NEXT_BUILD} (${TODAY}): ${SUMMARY}" \
awk '
    BEGIN {
        inserted = 0
        skipExistingBlank = 0
    }
    {
        if ($0 == "## Unreleased") {
            inserted++
            print
            print ""
            print ENVIRON["SXM_CHANGELOG_ENTRY"]
            skipExistingBlank = 1
            next
        }
        if (skipExistingBlank && $0 == "") {
            skipExistingBlank = 0
            next
        }
        skipExistingBlank = 0
        print
    }
    END {
        if (inserted != 1) {
            exit 2
        }
    }
' "$CHANGELOG" \
    > "$VERSION_TRANSACTION_DIR/generated-changelog.md"
chmod "$(sxm_file_mode "$CHANGELOG")" \
    "$VERSION_TRANSACTION_DIR/generated-changelog.md"
mv "$VERSION_TRANSACTION_DIR/generated-changelog.md" \
    "$VERSION_TRANSACTION_DIR/new-changelog.md"

NEW_BUILD_CHECK="$(
    plutil -extract CFBundleVersion raw \
        "$VERSION_TRANSACTION_DIR/new-info.plist"
)"
NEW_ENTRY_COUNT="$(
    awk -v build="$NEXT_BUILD" '
        index($0, "- Build " build " (") == 1 { count++ }
        END { print count + 0 }
    ' "$VERSION_TRANSACTION_DIR/new-changelog.md"
)"
if [[ "$NEW_BUILD_CHECK" != "$NEXT_BUILD" \
    || "$NEW_ENTRY_COUNT" != "1" ]]; then
    sxm_error "Generated checkpoint files failed validation."
    exit 65
fi

OLD_INFO_SHA="$(version_hash \
    "$VERSION_TRANSACTION_DIR/original-info.plist")"
NEW_INFO_SHA="$(version_hash \
    "$VERSION_TRANSACTION_DIR/new-info.plist")"
OLD_CHANGELOG_SHA="$(version_hash \
    "$VERSION_TRANSACTION_DIR/original-changelog.md")"
NEW_CHANGELOG_SHA="$(version_hash \
    "$VERSION_TRANSACTION_DIR/new-changelog.md")"
{
    print -r -- "sxm-version-transaction-v1"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$CURRENT_BUILD" \
        "$NEXT_BUILD" \
        "$OLD_INFO_SHA" \
        "$NEW_INFO_SHA" \
        "$OLD_CHANGELOG_SHA" \
        "$NEW_CHANGELOG_SHA"
} > "$VERSION_TRANSACTION_DIR/metadata.tsv"

sxm_maybe_fail after_version_prepared
sxm_atomic_copy_replace \
    "$VERSION_TRANSACTION_DIR/new-info.plist" \
    "$INFO_PLIST"
sxm_maybe_fail after_info_publish
sxm_atomic_copy_replace \
    "$VERSION_TRANSACTION_DIR/new-changelog.md" \
    "$CHANGELOG"
sxm_maybe_fail after_changelog_publish

if [[ "$(version_hash "$INFO_PLIST")" != "$NEW_INFO_SHA" \
    || "$(version_hash "$CHANGELOG")" != "$NEW_CHANGELOG_SHA" ]]; then
    sxm_error "Published checkpoint files do not match the verified transaction."
    exit 74
fi

VERSION_PREPARED=1
version_remove_transaction

print "Checkpoint prepared: build $NEXT_BUILD"
print \
    "Next: run tests, commit the logical change, then run backup_checkpoint.command."
