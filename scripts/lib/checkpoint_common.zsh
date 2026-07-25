#!/bin/zsh

# Shared, source-only helpers for checkpoint scripts. Callers are expected to
# enable `set -euo pipefail` before sourcing this file.

typeset -gr SXM_MANIFEST_HEADER=$'timestamp\tbuild\tversion\tbranch\tcommit\tbundle\tsha256\ttests'
typeset -gr SXM_PENDING_RECEIPT_HEADER="sxm-browser-pending-v1"

typeset -g SXM_CHECKPOINT_LOCK_DIR=""
typeset -g SXM_CHECKPOINT_LOCK_TOKEN=""
typeset -gi SXM_RECOVERED_PENDING_COUNT=0

sxm_error() {
    print -u2 -r -- "$*"
}

sxm_sha256() {
    shasum -a 256 "$1" | awk '{print $1}'
}

sxm_file_mode() {
    stat -f '%Lp' "$1"
}

sxm_sanitize_field() {
    local value="$1"
    value="${value//$'\r'/ }"
    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    REPLY="$value"
}

sxm_maybe_fail() {
    local stage="$1"
    if [[ "${SXM_CHECKPOINT_TESTING:-0}" == "1" \
        && "${SXM_CHECKPOINT_TEST_FAIL_AT:-}" == "$stage" ]]; then
        sxm_error "Injected checkpoint failure at stage: $stage"
        return 99
    fi
}

sxm_reclaim_stale_lock() {
    local lock_dir="$1"
    local recorded_pid=""
    local recorded_owner=""
    local recorded_inode=""
    local owner_host
    local owner_pid
    local current_host
    local quarantine
    local quarantined_pid=""
    local quarantined_owner=""
    local quarantined_inode=""

    if [[ ! -d "$lock_dir" \
        || ! -f "$lock_dir/pid" \
        || ! -f "$lock_dir/owner" ]]; then
        return 1
    fi
    IFS= read -r recorded_pid < "$lock_dir/pid" || return 1
    IFS= read -r recorded_owner < "$lock_dir/owner" || return 1
    recorded_inode="$(stat -f '%i' "$lock_dir")" || return 1
    owner_host="${recorded_owner%%:*}"
    owner_pid="${recorded_owner#*:}"
    owner_pid="${owner_pid%%:*}"
    current_host="$(hostname)"

    if [[ "$recorded_pid" != <-> \
        || "$recorded_pid" -le 1 \
        || "$owner_host" != "$current_host" \
        || "$owner_pid" != "$recorded_pid" ]]; then
        return 1
    fi
    if kill -0 "$recorded_pid" 2>/dev/null; then
        return 1
    fi

    quarantine="${lock_dir}.stale.$$.$RANDOM$RANDOM"
    if ! mv "$lock_dir" "$quarantine" 2>/dev/null; then
        return 1
    fi
    if [[ -f "$quarantine/pid" && -f "$quarantine/owner" ]]; then
        IFS= read -r quarantined_pid < "$quarantine/pid" || true
        IFS= read -r quarantined_owner < "$quarantine/owner" || true
        quarantined_inode="$(stat -f '%i' "$quarantine" 2>/dev/null || true)"
    fi
    if [[ "$quarantined_pid" != "$recorded_pid" \
        || "$quarantined_owner" != "$recorded_owner" \
        || "$quarantined_inode" != "$recorded_inode" ]]; then
        if [[ ! -e "$lock_dir" ]] \
            && mv "$quarantine" "$lock_dir" 2>/dev/null; then
            sxm_error "Checkpoint lock changed during stale-lock recovery; it was restored."
        else
            sxm_error \
                "Checkpoint lock changed during recovery and was quarantined for manual inspection: $quarantine"
        fi
        return 1
    fi

    rm -f "$quarantine/pid" "$quarantine/owner"
    if ! rmdir "$quarantine" 2>/dev/null; then
        sxm_error \
            "Stale lock contains unexpected files and was quarantined: $quarantine"
        return 1
    fi
    sxm_error "Recovered stale checkpoint lock: $lock_dir"
}

sxm_acquire_backup_lock() {
    local backup_root="$1"
    local lock_dir="$backup_root/.checkpoint.lock"
    local lock_token

    lock_token="$(hostname):$$:${EPOCHSECONDS:-$(date '+%s')}:$RANDOM$RANDOM"

    mkdir -p "$backup_root"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        if ! sxm_reclaim_stale_lock "$lock_dir" \
            || ! mkdir "$lock_dir" 2>/dev/null; then
            sxm_error "Another checkpoint operation is active: $lock_dir"
            return 75
        fi
    fi
    SXM_CHECKPOINT_LOCK_DIR="$lock_dir"
    SXM_CHECKPOINT_LOCK_TOKEN="$lock_token"
    print -r -- "$$" > "$lock_dir/pid"
    print -r -- "$lock_token" > "$lock_dir/owner"
}

sxm_release_backup_lock() {
    if [[ -n "${SXM_CHECKPOINT_LOCK_DIR:-}" \
        && -d "$SXM_CHECKPOINT_LOCK_DIR" ]]; then
        local recorded_token=""
        if [[ -f "$SXM_CHECKPOINT_LOCK_DIR/owner" ]]; then
            IFS= read -r recorded_token \
                < "$SXM_CHECKPOINT_LOCK_DIR/owner" || true
        fi
        if [[ -n "${SXM_CHECKPOINT_LOCK_TOKEN:-}" \
            && "$recorded_token" == "$SXM_CHECKPOINT_LOCK_TOKEN" ]]; then
            rm -f \
                "$SXM_CHECKPOINT_LOCK_DIR/pid" \
                "$SXM_CHECKPOINT_LOCK_DIR/owner"
            rmdir "$SXM_CHECKPOINT_LOCK_DIR" 2>/dev/null || true
        fi
    fi
    SXM_CHECKPOINT_LOCK_DIR=""
    SXM_CHECKPOINT_LOCK_TOKEN=""
}

sxm_atomic_copy_replace() {
    local source="$1"
    local destination="$2"
    local destination_dir="${destination:h}"
    local destination_name="${destination:t}"
    local temporary

    temporary="$(mktemp "$destination_dir/.${destination_name}.tmp.XXXXXX")"
    if ! cp -p "$source" "$temporary"; then
        rm -f "$temporary"
        return 74
    fi
    if ! mv -f "$temporary" "$destination"; then
        rm -f "$temporary"
        return 74
    fi
}

sxm_manifest_legacy_count() {
    local manifest="$1"
    awk '
        BEGIN {
            tab = sprintf("%c", 9)
            legacy = 0
        }
        {
            working = $0
            realTabs = split(working, fields, tab) - 1
            working = $0
            literalTabs = gsub(/\\t/, "", working)
            if (realTabs == 0 && literalTabs == 7) {
                legacy++
            }
        }
        END { print legacy }
    ' "$manifest"
}

sxm_canonicalize_manifest() {
    local source="$1"
    local destination="$2"
    local allow_legacy="$3"

    awk -v allowLegacy="$allow_legacy" '
        BEGIN {
            tab = sprintf("%c", 9)
            failed = 0
        }
        {
            if (index($0, sprintf("%c", 13)) != 0) {
                printf "manifest line %d contains a carriage return\n", NR > "/dev/stderr"
                failed = 1
                next
            }

            original = $0
            working = original
            realTabs = split(working, fields, tab) - 1
            working = original
            literalTabs = gsub(/\\t/, "", working)

            if (realTabs == 7) {
                print original
            } else if (allowLegacy == 1 && realTabs == 0 && literalTabs == 7) {
                converted = original
                gsub(/\\t/, tab, converted)
                print converted
            } else {
                printf "manifest line %d has invalid separators (real=%d literal=%d)\n",
                    NR, realTabs, literalTabs > "/dev/stderr"
                failed = 1
            }
        }
        END {
            if (failed) {
                exit 65
            }
        }
    ' "$source" > "$destination"
}

sxm_validate_canonical_manifest() {
    local manifest="$1"

    awk -F '\t' -v expectedHeader="$SXM_MANIFEST_HEADER" '
        function fail(message) {
            printf "manifest line %d: %s\n", NR, message > "/dev/stderr"
            invalid = 1
        }
        NR == 1 {
            if ($0 != expectedHeader) {
                fail("header does not match the canonical schema")
            }
            next
        }
        {
            if (NF != 8) {
                fail("expected exactly 8 TSV fields")
                next
            }
            if ($1 !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9][+-][0-9][0-9][0-9][0-9]$/) {
                fail("invalid timestamp")
            }
            if ($2 !~ /^[1-9][0-9]*$/) {
                fail("build must be a positive integer")
            }
            if ($3 !~ /^[0-9]+\.[0-9]+\.[0-9]+([-.+][0-9A-Za-z.-]+)?$/) {
                fail("invalid semantic version")
            }
            if ($4 == "") {
                fail("branch is empty")
            }
            if (length($5) != 40 || $5 !~ /^[0-9a-f]+$/) {
                fail("commit must be a 40-character lowercase SHA")
            }
            if ($6 !~ /^[0-9A-Za-z][0-9A-Za-z._-]*\.(bundle|zip)$/) {
                fail("artifact filename is unsafe or unsupported")
            }
            if (seenArtifact[$6]++) {
                fail("artifact filename is duplicated")
            }
            if (length($7) != 64 || $7 !~ /^[0-9a-f]+$/) {
                fail("sha256 must be 64 lowercase hexadecimal characters")
            }
            if ($8 == "") {
                fail("test summary is empty")
            }
        }
        END {
            if (NR == 0) {
                printf "manifest is empty\n" > "/dev/stderr"
                invalid = 1
            }
            if (invalid) {
                exit 65
            }
        }
    ' "$manifest"
}

sxm_make_manifest_snapshot() {
    local manifest="$1"
    local destination="$2"
    local allow_legacy="$3"
    local allow_missing="${4:-0}"

    if [[ ! -f "$manifest" ]]; then
        if [[ "$allow_missing" != "1" ]]; then
            sxm_error "Backup manifest not found: $manifest"
            return 66
        fi
        print -r -- "$SXM_MANIFEST_HEADER" > "$destination"
    else
        sxm_canonicalize_manifest \
            "$manifest" \
            "$destination" \
            "$allow_legacy" || return $?
    fi
    sxm_validate_canonical_manifest "$destination" || return $?
}

sxm_manifest_artifact_path() {
    local backup_root="$1"
    local artifact_name="$2"

    case "$artifact_name" in
        (*.bundle)
            REPLY="$backup_root/bundles/$artifact_name"
            ;;
        (*.zip)
            REPLY="$backup_root/milestones/$artifact_name"
            ;;
        (*)
            sxm_error "Unsupported backup artifact: $artifact_name"
            return 65
            ;;
    esac
}

sxm_verify_artifact() {
    local artifact_path="$1"
    local expected_checksum="$2"
    local actual_checksum

    if [[ ! -f "$artifact_path" ]]; then
        sxm_error "Backup artifact is missing: $artifact_path"
        return 66
    fi
    actual_checksum="$(sxm_sha256 "$artifact_path")" || return $?
    if [[ "$actual_checksum" != "$expected_checksum" ]]; then
        sxm_error "Backup checksum mismatch: $artifact_path"
        return 65
    fi

    case "$artifact_path" in
        (*.bundle)
            git bundle verify "$artifact_path" >/dev/null 2>&1 \
                || return $?
            ;;
        (*.zip)
            unzip -t "$artifact_path" >/dev/null 2>&1 \
                || return $?
            ;;
        (*)
            sxm_error "Unsupported backup artifact: $artifact_path"
            return 65
            ;;
    esac
}

sxm_verify_manifest_inventory() {
    local backup_root="$1"
    local manifest="$2"
    local line_number=0
    local timestamp build version branch commit artifact checksum tests
    local artifact_path
    typeset -A indexed_artifacts

    while IFS=$'\t' read -r \
        timestamp build version branch commit artifact checksum tests; do
        line_number=$((line_number + 1))
        if (( line_number == 1 )); then
            continue
        fi
        indexed_artifacts[$artifact]=1
        sxm_manifest_artifact_path "$backup_root" "$artifact" || return $?
        artifact_path="$REPLY"
        sxm_verify_artifact "$artifact_path" "$checksum" || return $?
    done < "$manifest"

    local candidate
    setopt local_options null_glob
    for candidate in \
        "$backup_root"/bundles/*.bundle \
        "$backup_root"/milestones/*.zip; do
        if [[ -z "${indexed_artifacts[${candidate:t}]:-}" ]]; then
            sxm_error "Backup artifact is not indexed: $candidate"
            return 65
        fi
    done
}

sxm_find_verified_bundle_for_commit() {
    local backup_root="$1"
    local manifest="$2"
    local wanted_commit="$3"
    local timestamp build version branch commit artifact checksum tests
    local candidate_artifact=""
    local candidate_checksum=""
    local artifact_path

    while IFS=$'\t' read -r \
        timestamp build version branch commit artifact checksum tests; do
        if [[ "$commit" == "$wanted_commit" \
            && "$artifact" == *.bundle ]]; then
            candidate_artifact="$artifact"
            candidate_checksum="$checksum"
        fi
    done < <(tail -n +2 "$manifest")

    if [[ -z "$candidate_artifact" ]]; then
        sxm_error "No verified bundle is recorded for previous HEAD $wanted_commit."
        return 65
    fi

    sxm_manifest_artifact_path "$backup_root" "$candidate_artifact" \
        || return $?
    artifact_path="$REPLY"
    sxm_verify_artifact "$artifact_path" "$candidate_checksum" || return $?
    if ! git bundle list-heads "$artifact_path" \
        | awk -v wanted="$wanted_commit" '$1 == wanted { found = 1 } END { exit(found ? 0 : 1) }'; then
        sxm_error "Recorded bundle does not advertise previous HEAD: $artifact_path"
        return 65
    fi
    REPLY="$artifact_path"
}

sxm_manifest_row_for_artifact() {
    local manifest="$1"
    local artifact_name="$2"
    awk -F '\t' -v wanted="$artifact_name" '
        NR > 1 && $6 == wanted {
            print
            found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "$manifest"
}

sxm_append_manifest_row_atomic() {
    local manifest="$1"
    local row="$2"
    local manifest_dir="${manifest:h}"
    local artifact_name
    local existing=""
    local temporary

    IFS=$'\t' read -r \
        _ _ _ _ _ artifact_name _ _ <<< "$row"
    if [[ -z "$artifact_name" ]]; then
        sxm_error "Pending manifest row is malformed."
        return 65
    fi

    if [[ -f "$manifest" ]]; then
        existing="$(sxm_manifest_row_for_artifact \
            "$manifest" "$artifact_name" 2>/dev/null || true)"
        if [[ -n "$existing" ]]; then
            if [[ "$existing" == "$row" ]]; then
                return 0
            fi
            sxm_error "Manifest already contains a conflicting artifact row: $artifact_name"
            return 65
        fi
    fi

    temporary="$(mktemp "$manifest_dir/.manifest.tsv.tmp.XXXXXX")"
    if [[ -f "$manifest" ]]; then
        if ! cp -p "$manifest" "$temporary"; then
            rm -f "$temporary"
            return 74
        fi
    else
        print -r -- "$SXM_MANIFEST_HEADER" > "$temporary"
        chmod 644 "$temporary"
    fi
    printf '%s\n' "$row" >> "$temporary"
    if ! sxm_validate_canonical_manifest "$temporary"; then
        rm -f "$temporary"
        return 65
    fi
    if ! mv -f "$temporary" "$manifest"; then
        rm -f "$temporary"
        return 74
    fi
}

sxm_make_manifest_row() {
    local timestamp="$1"
    local build="$2"
    local version="$3"
    local branch="$4"
    local commit="$5"
    local artifact="$6"
    local checksum="$7"
    local tests="$8"

    printf -v REPLY '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$timestamp" \
        "$build" \
        "$version" \
        "$branch" \
        "$commit" \
        "$artifact" \
        "$checksum" \
        "$tests"
}

sxm_write_pending_receipt() {
    local backup_root="$1"
    local artifact_temp="$2"
    local row="$3"
    local artifact_name
    local receipt_dir="$backup_root/.pending"
    local receipt_path
    local receipt_temp
    local validation_manifest

    IFS=$'\t' read -r \
        _ _ _ _ _ artifact_name _ _ <<< "$row"
    validation_manifest="$(mktemp "$backup_root/.pending-row.XXXXXX")"
    {
        print -r -- "$SXM_MANIFEST_HEADER"
        printf '%s\n' "$row"
    } > "$validation_manifest"
    if ! sxm_validate_canonical_manifest "$validation_manifest"; then
        rm -f "$validation_manifest"
        return 65
    fi
    rm -f "$validation_manifest"

    mkdir -p "$receipt_dir" || return $?
    receipt_path="$receipt_dir/$artifact_name.pending"
    if [[ -e "$receipt_path" ]]; then
        sxm_error "Pending checkpoint already exists: $receipt_path"
        return 73
    fi
    receipt_temp="$(mktemp "$receipt_dir/.${artifact_name}.pending.tmp.XXXXXX")"
    {
        print -r -- "$SXM_PENDING_RECEIPT_HEADER"
        print -r -- "$artifact_temp"
        printf '%s\n' "$row"
    } > "$receipt_temp"
    chmod 600 "$receipt_temp"
    if ! mv "$receipt_temp" "$receipt_path"; then
        rm -f "$receipt_temp"
        return 74
    fi
    REPLY="$receipt_path"
}

sxm_refuse_unreceipted_transactions() {
    local backup_root="$1"
    local transaction_dir
    setopt local_options null_glob

    for transaction_dir in "$backup_root"/.transactions/*; do
        if [[ -d "$transaction_dir" ]]; then
            sxm_error \
                "Unreceipted checkpoint transaction requires manual inspection: $transaction_dir"
            return 75
        fi
    done
}

sxm_read_pending_receipt() {
    local receipt_path="$1"
    local header
    local artifact_temp
    local row
    local extra

    {
        IFS= read -r header
        IFS= read -r artifact_temp
        IFS= read -r row
        IFS= read -r extra || true
    } < "$receipt_path"
    if [[ "$header" != "$SXM_PENDING_RECEIPT_HEADER" \
        || -z "$artifact_temp" \
        || -z "$row" \
        || -n "$extra" ]]; then
        sxm_error "Pending receipt is malformed: $receipt_path"
        return 65
    fi
    SXM_PENDING_TEMP="$artifact_temp"
    SXM_PENDING_ROW="$row"
}

sxm_remove_completed_receipt() {
    local receipt_path="$1"
    local artifact_temp="$2"
    local transaction_dir="${artifact_temp:h}"

    if [[ -d "$transaction_dir" \
        && "${transaction_dir:h}" == */.transactions ]]; then
        if ! rmdir "$transaction_dir" 2>/dev/null; then
            sxm_error \
                "Completed transaction directory is not empty: $transaction_dir"
            return 75
        fi
    fi
    rm -f "$receipt_path" || return $?
}

sxm_recover_pending_receipts() {
    local backup_root="$1"
    local manifest="$2"
    local receipt_path
    local artifact_temp
    local row
    local timestamp build version branch commit artifact checksum tests
    local final_path
    local validation_manifest

    SXM_RECOVERED_PENDING_COUNT=0
    setopt local_options null_glob
    for receipt_path in "$backup_root"/.pending/*.pending; do
        sxm_read_pending_receipt "$receipt_path" || return $?
        artifact_temp="$SXM_PENDING_TEMP"
        row="$SXM_PENDING_ROW"

        validation_manifest="$(mktemp "$backup_root/.pending/.receipt-manifest.XXXXXX")"
        {
            print -r -- "$SXM_MANIFEST_HEADER"
            printf '%s\n' "$row"
        } > "$validation_manifest"
        if ! sxm_validate_canonical_manifest "$validation_manifest"; then
            rm -f "$validation_manifest"
            return 65
        fi
        rm -f "$validation_manifest"

        IFS=$'\t' read -r \
            timestamp build version branch commit artifact checksum tests \
            <<< "$row"
        if [[ "${receipt_path:t}" != "$artifact.pending" ]]; then
            sxm_error "Pending receipt name does not match its artifact: $receipt_path"
            return 65
        fi
        sxm_manifest_artifact_path "$backup_root" "$artifact" || return $?
        final_path="$REPLY"
        local transaction_parent="${artifact_temp:h:h}"
        if [[ "${artifact_temp:t}" != "$artifact" \
            || "${transaction_parent:A}" != "${backup_root:A}/.transactions" ]]; then
            sxm_error \
                "Pending artifact path does not match its receipt: $artifact_temp"
            return 65
        fi

        if [[ -f "$final_path" ]]; then
            sxm_verify_artifact "$final_path" "$checksum" || return $?
            if [[ -f "$artifact_temp" ]]; then
                sxm_verify_artifact "$artifact_temp" "$checksum" || return $?
                rm -f "$artifact_temp" || return $?
            fi
        elif [[ -f "$artifact_temp" ]]; then
            sxm_verify_artifact "$artifact_temp" "$checksum" || return $?
            mkdir -p "${final_path:h}" || return $?
            mv "$artifact_temp" "$final_path" || return $?
            sxm_verify_artifact "$final_path" "$checksum" || return $?
        else
            sxm_error "Pending checkpoint has neither a temporary nor final artifact: $receipt_path"
            return 66
        fi

        sxm_append_manifest_row_atomic "$manifest" "$row" || return $?
        sxm_remove_completed_receipt "$receipt_path" "$artifact_temp" \
            || return $?
        SXM_RECOVERED_PENDING_COUNT=$((SXM_RECOVERED_PENDING_COUNT + 1))
        print "Recovered pending checkpoint: $artifact"
    done
}
