#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
SOURCE_ROOT="${SCRIPT_DIR:h:h}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sxm-checkpoint-tests.XXXXXX")"
TEST_COUNT=0

cleanup() {
    local exit_code=$?
    if [[ "${SXM_CHECKPOINT_TEST_KEEP_TEMP:-0}" != "1" \
        && -n "${TEST_ROOT:-}" \
        && -d "$TEST_ROOT" \
        && "$TEST_ROOT" == "${TMPDIR:-/tmp}"/sxm-checkpoint-tests.* ]]; then
        rm -rf "$TEST_ROOT"
    fi
    return "$exit_code"
}
trap cleanup EXIT

fail() {
    print -u2 -r -- "FAIL: $*"
    exit 1
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    print -r -- "PASS: $*"
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [[ "$actual" != "$expected" ]]; then
        fail "$message (expected=$expected actual=$actual)"
    fi
}

assert_file() {
    [[ -f "$1" ]] || fail "Expected file: $1"
}

assert_no_file() {
    [[ ! -e "$1" ]] || fail "Unexpected path: $1"
}

expect_exit() {
    local expected="$1"
    shift
    local actual
    set +e
    if [[ "${SXM_CHECKPOINT_TEST_VERBOSE:-0}" == "1" ]]; then
        "$@"
    else
        "$@" >/dev/null 2>&1
    fi
    actual=$?
    set -e
    if [[ "$actual" != "$expected" ]]; then
        fail "Expected exit $expected, got $actual: $*"
    fi
}

copy_checkpoint_scripts() {
    local repository="$1"
    mkdir -p "$repository/scripts/lib" "$repository/scripts/tests"
    cp "$SOURCE_ROOT/scripts/lib/checkpoint_common.zsh" \
        "$repository/scripts/lib/checkpoint_common.zsh"
    cp "$SOURCE_ROOT/scripts/version_checkpoint.command" \
        "$repository/scripts/version_checkpoint.command"
    cp "$SOURCE_ROOT/scripts/backup_checkpoint.command" \
        "$repository/scripts/backup_checkpoint.command"
    cp "$SOURCE_ROOT/scripts/migrate_backup_manifest.command" \
        "$repository/scripts/migrate_backup_manifest.command"
    chmod +x "$repository/scripts/"*.command
}

make_fixture() {
    local name="$1"
    local repository="$TEST_ROOT/$name/repository"
    local backup_root="$TEST_ROOT/$name/backups"
    local info="$repository/native/SXMBrowserNative/Bundle/Info.plist"
    local changelog="$repository/CHANGELOG.md"
    local manifest="$backup_root/manifest.tsv"
    local bundle_name="sxm-browser-b0007-20260101-000000-baseline.bundle"
    local bundle_path="$backup_root/bundles/$bundle_name"
    local commit
    local checksum

    mkdir -p \
        "${info:h}" \
        "$backup_root/bundles" \
        "$backup_root/milestones"
    copy_checkpoint_scripts "$repository"
    cp "$SOURCE_ROOT/native/SXMBrowserNative/Bundle/Info.plist" "$info"
    plutil -replace CFBundleVersion -string 7 "$info"
    plutil -replace CFBundleShortVersionString -string 2.0.0 "$info"
    {
        print -r -- "# Changelog"
        print
        print -r -- "## Unreleased"
        print
        print -r -- "- Build 7 (2026-01-01): baseline"
    } > "$changelog"
    chmod 644 "$info" "$changelog"
    print -r -- "fixture" > "$repository/fixture.txt"

    git -C "$repository" init -q -b test-branch
    git -C "$repository" config user.name "Checkpoint Test"
    git -C "$repository" config user.email "checkpoint@example.invalid"
    git -C "$repository" add .
    git -C "$repository" commit -q -m "baseline"
    commit="$(git -C "$repository" rev-parse HEAD)"
    git -C "$repository" bundle create "$bundle_path" --all
    checksum="$(shasum -a 256 "$bundle_path" | awk '{print $1}')"

    print -r -- \
        $'timestamp\tbuild\tversion\tbranch\tcommit\tbundle\tsha256\ttests' \
        > "$manifest"
    print -r -- \
        "2026-01-01T00:00:00+0000\\t7\\t2.0.0\\ttest-branch\\t${commit}\\t${bundle_name}\\t${checksum}\\tbaseline-tests" \
        >> "$manifest"

    FIXTURE_REPOSITORY="$repository"
    FIXTURE_BACKUP_ROOT="$backup_root"
    FIXTURE_MANIFEST="$manifest"
    FIXTURE_INFO="$info"
    FIXTURE_CHANGELOG="$changelog"
}

run_version() {
    local repository="$1"
    local backup_root="$2"
    shift 2
    (
        cd "$repository"
        env \
            SXM_BROWSER_BACKUP_ROOT="$backup_root" \
            "$@" \
            zsh scripts/version_checkpoint.command "test checkpoint"
    )
}

run_migration() {
    local repository="$1"
    local backup_root="$2"
    local mode="$3"
    (
        cd "$repository"
        env SXM_BROWSER_BACKUP_ROOT="$backup_root" \
            zsh scripts/migrate_backup_manifest.command "$mode"
    )
}

run_backup() {
    local repository="$1"
    local backup_root="$2"
    local summary="$3"
    shift 3
    (
        cd "$repository"
        env \
            SXM_BROWSER_BACKUP_ROOT="$backup_root" \
            "$@" \
            zsh scripts/backup_checkpoint.command "$summary"
    )
}

prepare_committed_checkpoint() {
    local repository="$1"
    local backup_root="$2"
    run_version "$repository" "$backup_root" >/dev/null
    print -r -- "logical change" >> "$repository/fixture.txt"
    git -C "$repository" add .
    git -C "$repository" commit -q -m "test checkpoint"
}

test_manifest_migration() {
    make_fixture migration
    local old_sha="$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{print $1}')"
    local check_output
    check_output="$(
        run_migration \
            "$FIXTURE_REPOSITORY" \
            "$FIXTURE_BACKUP_ROOT" \
            --check
    )"
    [[ "$check_output" == *"Legacy rows requiring migration: 1"* ]] \
        || fail "Migration check did not report the legacy row."
    assert_equal \
        "$old_sha" \
        "$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{print $1}')" \
        "Migration check must not modify the manifest"

    run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --apply >/dev/null
    local original_backup="$FIXTURE_BACKUP_ROOT/manifest.tsv.before-tabs-fix-${old_sha}.bak"
    assert_file "$original_backup"
    assert_equal \
        "$old_sha" \
        "$(shasum -a 256 "$original_backup" | awk '{print $1}')" \
        "Permanent manifest original must be byte-identical"
    assert_equal \
        "2" \
        "$(awk -F '\t' 'NF == 8 { count++ } END { print count + 0 }' "$FIXTURE_MANIFEST")" \
        "Canonical manifest rows must have 8 fields"
    assert_equal \
        "0" \
        "$(awk '{ value = $0; count += gsub(/\\t/, "", value) } END { print count + 0 }' "$FIXTURE_MANIFEST")" \
        "Migrated separators must not remain literal"

    local canonical_sha="$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{print $1}')"
    run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --apply >/dev/null
    assert_equal \
        "$canonical_sha" \
        "$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{print $1}')" \
        "Migration apply must be idempotent"
    pass "strict, permanent and idempotent manifest migration"
}

test_manifest_rejects_mixed_line() {
    make_fixture malformed
    local baseline_sha
    local commit="$(git -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"
    local bundle="$(ls "$FIXTURE_BACKUP_ROOT/bundles/"*.bundle)"
    local checksum="$(shasum -a 256 "$bundle" | awk '{print $1}')"
    {
        print -r -- "$(
            print -r -- \
                $'timestamp\tbuild\tversion\tbranch\tcommit\tbundle\tsha256\ttests'
        )"
        printf '2026-01-01T00:00:00+0000\t7\\t2.0.0\\ttest-branch\\t%s\\t%s\\t%s\\tbroken\n' \
            "$commit" "${bundle:t}" "$checksum"
    } > "$FIXTURE_MANIFEST"
    baseline_sha="$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{print $1}')"
    expect_exit 65 \
        run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --check
    assert_equal \
        "$baseline_sha" \
        "$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{print $1}')" \
        "Malformed migration must leave the source byte-identical"
    pass "mixed manifest separators are rejected without mutation"
}

test_migration_rejects_orphan_transaction() {
    make_fixture migration-orphan
    mkdir -p "$FIXTURE_BACKUP_ROOT/.transactions/orphan"
    expect_exit 75 \
        run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --check
    assert_file "$FIXTURE_MANIFEST"
    [[ -d "$FIXTURE_BACKUP_ROOT/.transactions/orphan" ]] \
        || fail "Migration must not remove an unreceipted transaction."
    pass "manifest migration refuses unreceipted transactions"
}

test_version_transaction_and_repeat_guard() {
    make_fixture version
    local info_mode="$(stat -f '%Lp' "$FIXTURE_INFO")"
    local changelog_mode="$(stat -f '%Lp' "$FIXTURE_CHANGELOG")"
    run_version "$FIXTURE_REPOSITORY" "$FIXTURE_BACKUP_ROOT" >/dev/null
    assert_equal \
        "8" \
        "$(plutil -extract CFBundleVersion raw "$FIXTURE_INFO")" \
        "Version checkpoint must increment once"
    assert_equal \
        "1" \
        "$(awk 'index($0, "- Build 8 (") == 1 { count++ } END { print count + 0 }' "$FIXTURE_CHANGELOG")" \
        "Changelog must contain one new build entry"
    assert_equal "$info_mode" "$(stat -f '%Lp' "$FIXTURE_INFO")" \
        "Info.plist mode must be preserved"
    assert_equal "$changelog_mode" "$(stat -f '%Lp' "$FIXTURE_CHANGELOG")" \
        "Changelog mode must be preserved"
    expect_exit 73 \
        run_version "$FIXTURE_REPOSITORY" "$FIXTURE_BACKUP_ROOT"
    assert_equal \
        "8" \
        "$(plutil -extract CFBundleVersion raw "$FIXTURE_INFO")" \
        "Repeated checkpoint must not increment twice"
    pass "version transaction publishes both files once and preserves modes"
}

test_version_failure_and_recovery() {
    make_fixture version-rollback
    local info_sha="$(shasum -a 256 "$FIXTURE_INFO" | awk '{print $1}')"
    local changelog_sha="$(shasum -a 256 "$FIXTURE_CHANGELOG" | awk '{print $1}')"
    expect_exit 99 \
        run_version \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        SXM_CHECKPOINT_TESTING=1 \
        SXM_CHECKPOINT_TEST_FAIL_AT=after_info_publish
    assert_equal "$info_sha" "$(shasum -a 256 "$FIXTURE_INFO" | awk '{print $1}')" \
        "Failed version transaction must roll Info.plist back"
    assert_equal "$changelog_sha" "$(shasum -a 256 "$FIXTURE_CHANGELOG" | awk '{print $1}')" \
        "Failed version transaction must roll Changelog back"

    make_fixture version-recovery
    expect_exit 99 \
        run_version \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        SXM_CHECKPOINT_TESTING=1 \
        SXM_CHECKPOINT_TEST_FAIL_AT=after_info_publish \
        SXM_CHECKPOINT_TEST_PRESERVE_TRANSACTION=1
    expect_exit 73 \
        run_version "$FIXTURE_REPOSITORY" "$FIXTURE_BACKUP_ROOT"
    assert_equal "8" "$(plutil -extract CFBundleVersion raw "$FIXTURE_INFO")" \
        "Recovered transaction must publish the prepared build"
    assert_equal \
        "1" \
        "$(awk 'index($0, "- Build 8 (") == 1 { count++ } END { print count + 0 }' "$FIXTURE_CHANGELOG")" \
        "Recovered transaction must publish its Changelog entry"
    assert_no_file \
        "$FIXTURE_REPOSITORY/.git/sxm-version-transaction"
    pass "version failure rolls back normally and recovers preserved mixed state"
}

test_version_requires_previous_backup() {
    make_fixture no-previous-backup
    print -r -- \
        $'timestamp\tbuild\tversion\tbranch\tcommit\tbundle\tsha256\ttests' \
        > "$FIXTURE_MANIFEST"
    local info_sha="$(shasum -a 256 "$FIXTURE_INFO" | awk '{print $1}')"
    expect_exit 65 \
        run_version "$FIXTURE_REPOSITORY" "$FIXTURE_BACKUP_ROOT"
    assert_equal "$info_sha" "$(shasum -a 256 "$FIXTURE_INFO" | awk '{print $1}')" \
        "Missing previous backup must block version changes"
    pass "version checkpoint verifies a previous HEAD bundle"
}

test_backup_guards_and_real_tsv() {
    make_fixture backup
    prepare_committed_checkpoint \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT"

    expect_exit 65 \
        run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "tests passed"
    run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --apply >/dev/null

    print -r -- "dirty" > "$FIXTURE_REPOSITORY/untracked.txt"
    expect_exit 65 \
        run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "tests passed"
    rm -f "$FIXTURE_REPOSITORY/untracked.txt"
    expect_exit 64 \
        run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "   "

    git -C "$FIXTURE_REPOSITORY" checkout -q --detach
    expect_exit 65 \
        run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "tests passed"
    git -C "$FIXTURE_REPOSITORY" checkout -q test-branch

    run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        '196 tests; literal\\ttext; 中文' >/dev/null
    assert_equal \
        "3" \
        "$(awk -F '\t' 'NF == 8 { count++ } END { print count + 0 }' "$FIXTURE_MANIFEST")" \
        "New backup row must be canonical TSV"
    local final_line="$(tail -n 1 "$FIXTURE_MANIFEST")"
    assert_equal \
        "7" \
        "$(printf '%s\n' "$final_line" \
            | awk '{ tab = sprintf("%c", 9); print split($0, fields, tab) - 1 }')" \
        "New backup row must contain seven real tabs"
    [[ "$final_line" == *'literal\\ttext'* ]] \
        || fail "Literal backslash text inside a field must be preserved."
    local newest_bundle="$(ls -t "$FIXTURE_BACKUP_ROOT/bundles/"*.bundle | head -1)"
    git -C "$FIXTURE_REPOSITORY" bundle verify "$newest_bundle" >/dev/null
    pass "backup rejects unsafe states and emits verified real TSV"
}

test_pending_receipt_recovery() {
    make_fixture pending
    prepare_committed_checkpoint \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT"
    run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --apply >/dev/null

    expect_exit 99 \
        run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "fault recovery" \
        SXM_CHECKPOINT_TESTING=1 \
        SXM_CHECKPOINT_TEST_FAIL_AT=after_artifact_publish
    assert_equal \
        "1" \
        "$(find "$FIXTURE_BACKUP_ROOT/.pending" -name '*.pending' -type f | wc -l | tr -d '[:space:]')" \
        "Fault must leave one recoverable receipt"
    assert_equal \
        "2" \
        "$(find "$FIXTURE_BACKUP_ROOT/bundles" -name '*.bundle' -type f | wc -l | tr -d '[:space:]')" \
        "Verified artifact must already be final"

    run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "fault recovery" >/dev/null
    assert_equal \
        "0" \
        "$(find "$FIXTURE_BACKUP_ROOT/.pending" -name '*.pending' -type f | wc -l | tr -d '[:space:]')" \
        "Recovery must consume its receipt"
    assert_equal \
        "2" \
        "$(find "$FIXTURE_BACKUP_ROOT/bundles" -name '*.bundle' -type f | wc -l | tr -d '[:space:]')" \
        "Recovery must not create a duplicate bundle"
    assert_equal \
        "3" \
        "$(wc -l < "$FIXTURE_MANIFEST" | tr -d '[:space:]')" \
        "Recovery must append exactly one row"
    pass "pending receipt repairs final-artifact/old-manifest crash window"
}

test_backup_lock() {
    make_fixture lock
    prepare_committed_checkpoint \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT"
    run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --apply >/dev/null
    mkdir "$FIXTURE_BACKUP_ROOT/.checkpoint.lock"
    print -r -- "foreign" > "$FIXTURE_BACKUP_ROOT/.checkpoint.lock/owner"
    expect_exit 75 \
        run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "locked"
    rm -f "$FIXTURE_BACKUP_ROOT/.checkpoint.lock/owner"
    rmdir "$FIXTURE_BACKUP_ROOT/.checkpoint.lock"
    pass "backup root lock rejects a concurrent writer"
}

test_stale_backup_lock_recovery() {
    make_fixture stale-lock
    prepare_committed_checkpoint \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT"
    run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --apply >/dev/null
    mkdir "$FIXTURE_BACKUP_ROOT/.checkpoint.lock"
    print -r -- "2147483647" \
        > "$FIXTURE_BACKUP_ROOT/.checkpoint.lock/pid"
    print -r -- \
        "$(hostname):2147483647:stale-test-token" \
        > "$FIXTURE_BACKUP_ROOT/.checkpoint.lock/owner"

    run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "stale lock recovery" >/dev/null
    assert_no_file "$FIXTURE_BACKUP_ROOT/.checkpoint.lock"
    assert_equal \
        "0" \
        "$(find "$FIXTURE_BACKUP_ROOT" -maxdepth 1 \
            -name '.checkpoint.lock.stale.*' | wc -l \
            | tr -d '[:space:]')" \
        "A verified stale lock must not leave quarantine debris"
    pass "dead same-host backup locks are atomically reclaimed"
}

zsh -n \
    "$SOURCE_ROOT/scripts/lib/checkpoint_common.zsh" \
    "$SOURCE_ROOT/scripts/migrate_backup_manifest.command" \
    "$SOURCE_ROOT/scripts/version_checkpoint.command" \
    "$SOURCE_ROOT/scripts/backup_checkpoint.command"
pass "zsh syntax validation"

test_manifest_migration
test_manifest_rejects_mixed_line
test_migration_rejects_orphan_transaction
test_version_transaction_and_repeat_guard
test_version_failure_and_recovery
test_version_requires_previous_backup
test_backup_guards_and_real_tsv
test_pending_receipt_recovery
test_backup_lock
test_stale_backup_lock_recovery

print "checkpoint_workflow_tests=passed count=$TEST_COUNT"
