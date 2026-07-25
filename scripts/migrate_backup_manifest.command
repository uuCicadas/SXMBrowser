#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT="${SCRIPT_DIR:h}"
COMMON="$SCRIPT_DIR/lib/checkpoint_common.zsh"
BACKUP_ROOT="${SXM_BROWSER_BACKUP_ROOT:-${ROOT:h}/SXM Browser Backups}"
MANIFEST="$BACKUP_ROOT/manifest.tsv"

source "$COMMON"

if [[ $# -ne 1 || ( "$1" != "--check" && "$1" != "--apply" ) ]]; then
    print -u2 "Usage: $0 --check|--apply"
    exit 64
fi
MODE="$1"

if [[ ! -f "$MANIFEST" ]]; then
    sxm_error "Backup manifest not found: $MANIFEST"
    exit 66
fi

CANONICAL_TEMP=""
ORIGINAL_BACKUP=""
MIGRATION_PUBLISHED=0
BACKUP_TEMP=""
POST_TEMP=""
CLEANUP_RAN=0

cleanup_once() {
    local exit_code="$1"
    if [[ "$CLEANUP_RAN" == "1" ]]; then
        return 0
    fi
    CLEANUP_RAN=1
    if (( exit_code != 0 )) \
        && [[ "$MIGRATION_PUBLISHED" == "1" \
            && -n "${ORIGINAL_BACKUP:-}" \
            && -f "$ORIGINAL_BACKUP" ]]; then
        if sxm_atomic_copy_replace "$ORIGINAL_BACKUP" "$MANIFEST"; then
            sxm_error \
                "Manifest migration failed post-publication; the permanent original was restored."
        else
            sxm_error \
                "CRITICAL: manifest migration failed and automatic restoration also failed. Original: $ORIGINAL_BACKUP"
        fi
    fi
    if [[ -n "${CANONICAL_TEMP:-}" ]]; then
        rm -f "$CANONICAL_TEMP"
    fi
    if [[ -n "${BACKUP_TEMP:-}" ]]; then
        rm -f "$BACKUP_TEMP"
    fi
    if [[ -n "${POST_TEMP:-}" ]]; then
        rm -f "$POST_TEMP"
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

sxm_acquire_backup_lock "$BACKUP_ROOT"
sxm_refuse_unreceipted_transactions "$BACKUP_ROOT"

setopt null_glob
pending_receipts=("$BACKUP_ROOT"/.pending/*.pending)
if (( ${#pending_receipts} > 0 )); then
    sxm_error \
        "Pending checkpoint receipts must be recovered before manifest migration."
    exit 75
fi

LEGACY_COUNT="$(sxm_manifest_legacy_count "$MANIFEST")"
CANONICAL_TEMP="$(
    mktemp "$BACKUP_ROOT/.manifest-migration.XXXXXX"
)"
sxm_canonicalize_manifest "$MANIFEST" "$CANONICAL_TEMP" 1
sxm_validate_canonical_manifest "$CANONICAL_TEMP"
sxm_verify_manifest_inventory "$BACKUP_ROOT" "$CANONICAL_TEMP"

ORIGINAL_SHA="$(sxm_sha256 "$MANIFEST")"
CANONICAL_SHA="$(sxm_sha256 "$CANONICAL_TEMP")"
CANONICAL_BYTES="$(stat -f '%z' "$CANONICAL_TEMP")"
CANONICAL_LINES="$(wc -l < "$CANONICAL_TEMP" | tr -d '[:space:]')"

if [[ "$MODE" == "--check" ]]; then
    print "Manifest check passed."
    print "Legacy rows requiring migration: $LEGACY_COUNT"
    print "Current SHA-256: $ORIGINAL_SHA"
    print "Canonical SHA-256: $CANONICAL_SHA"
    print "Canonical size: $CANONICAL_BYTES bytes, $CANONICAL_LINES lines"
    exit 0
fi

if (( LEGACY_COUNT == 0 )); then
    print "Manifest is already canonical: $MANIFEST"
    print "SHA-256: $ORIGINAL_SHA"
    exit 0
fi

ORIGINAL_BACKUP="$BACKUP_ROOT/manifest.tsv.before-tabs-fix-${ORIGINAL_SHA}.bak"
if [[ -e "$ORIGINAL_BACKUP" ]]; then
    if [[ ! -f "$ORIGINAL_BACKUP" \
        || "$(sxm_sha256 "$ORIGINAL_BACKUP")" != "$ORIGINAL_SHA" ]]; then
        sxm_error "Permanent manifest backup conflicts: $ORIGINAL_BACKUP"
        exit 73
    fi
else
    BACKUP_TEMP="$(
        mktemp "$BACKUP_ROOT/.manifest-original.XXXXXX"
    )"
    cp -p "$MANIFEST" "$BACKUP_TEMP"
    mv "$BACKUP_TEMP" "$ORIGINAL_BACKUP"
    BACKUP_TEMP=""
fi

chmod "$(sxm_file_mode "$MANIFEST")" "$CANONICAL_TEMP"
sxm_atomic_copy_replace "$CANONICAL_TEMP" "$MANIFEST"
MIGRATION_PUBLISHED=1
rm -f "$CANONICAL_TEMP"
CANONICAL_TEMP=""

POST_TEMP="$(mktemp "$BACKUP_ROOT/.manifest-postcheck.XXXXXX")"
sxm_make_manifest_snapshot "$MANIFEST" "$POST_TEMP" 0 0
sxm_verify_manifest_inventory "$BACKUP_ROOT" "$POST_TEMP"
POST_SHA="$(sxm_sha256 "$MANIFEST")"
rm -f "$POST_TEMP"
POST_TEMP=""

if [[ "$POST_SHA" != "$CANONICAL_SHA" ]]; then
    sxm_error "Published manifest checksum does not match its verified candidate."
    exit 65
fi
MIGRATION_PUBLISHED=0

print "Manifest migration complete: $MANIFEST"
print "Converted legacy rows: $LEGACY_COUNT"
print "Original preserved: $ORIGINAL_BACKUP"
print "Canonical SHA-256: $POST_SHA"
