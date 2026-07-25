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
    cp "$SOURCE_ROOT/scripts/milestone_checkpoint.command" \
        "$repository/scripts/milestone_checkpoint.command"
    chmod +x "$repository/scripts/"*.command
}

make_milestone_validation_stub() {
    local stub_path="$1"

    {
        print -r -- '#!/bin/zsh'
        print -r -- 'set -euo pipefail'
        print -r -- 'if [[ $# -ne 2 || "$1" != "--sample-dir" || ! -d "$2" ]]; then'
        print -r -- '    exit 64'
        print -r -- 'fi'
        print -r -- 'repository="$(git rev-parse --show-toplevel)"'
        print -r -- 'if [[ "$repository" != "$SXM_MILESTONE_RESTORE_REPOSITORY" \'
        print -r -- '    || "$repository" == "$SXM_MILESTONE_ORIGINAL_REPOSITORY" ]]; then'
        print -r -- '    exit 65'
        print -r -- 'fi'
        print -r -- 'if [[ "$(git rev-parse refs/tags/v2.0.0)" \'
        print -r -- '    != "$SXM_MILESTONE_EXPECTED_TAG_OBJECT" ]]; then'
        print -r -- '    exit 65'
        print -r -- 'fi'
        print -r -- 'print -r -- "$repository" > "$SXM_MILESTONE_TEST_MARKER"'
        print -r -- 'mkdir -p \'
        print -r -- '    "$repository/native/SXMBrowserNative/.build-test-output" \'
        print -r -- '    "$repository/native/SXMBrowserNative/.build-cache-test-output" \'
        print -r -- '    "$repository/SXM Browser.app/Contents" \'
        print -r -- '    "$repository/dist" \'
        print -r -- '    "$repository/backups" \'
        print -r -- '    "$repository/example-graph"'
        print -r -- 'print -r -- generated \'
        print -r -- '    > "$repository/native/SXMBrowserNative/.build-test-output/generated.txt"'
        print -r -- 'print -r -- generated \'
        print -r -- '    > "$repository/SXM Browser.app/Contents/generated.txt"'
        print -r -- 'exit "${SXM_MILESTONE_TEST_VALIDATION_EXIT:-0}"'
    } > "$stub_path"
    chmod +x "$stub_path"
}

make_fixture() {
    local name="$1"
    local repository="$TEST_ROOT/$name/repository"
    local backup_root="$TEST_ROOT/$name/backups"
    local info="$repository/native/SXMBrowserNative/Bundle/Info.plist"
    local changelog="$repository/CHANGELOG.md"
    local manifest="$backup_root/manifest.tsv"
    local sample_dir="$TEST_ROOT/$name/example-graph"
    local validation_stub="$TEST_ROOT/$name/milestone-validation.command"
    local validation_marker="$TEST_ROOT/$name/milestone-validation.marker"
    local bundle_name="sxm-browser-b0007-20260101-000000-baseline.bundle"
    local bundle_path="$backup_root/bundles/$bundle_name"
    local commit
    local checksum

    mkdir -p \
        "${info:h}" \
        "$backup_root/bundles" \
        "$backup_root/milestones" \
        "$sample_dir"
    copy_checkpoint_scripts "$repository"
    make_milestone_validation_stub "$validation_stub"
    print -r -- "canonical sample" > "$sample_dir/sample.txt"
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
    FIXTURE_SAMPLE_DIR="$sample_dir"
    FIXTURE_VALIDATION_COMMAND="$validation_stub"
    FIXTURE_VALIDATION_MARKER="$validation_marker"
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

run_milestone() {
    local repository="$1"
    local backup_root="$2"
    local tag="$3"
    local sample_dir="$4"
    local validation_command="$5"
    local validation_marker="$6"
    local expected_tag_object="$7"
    shift 7
    (
        cd "$repository"
        env \
            SXM_BROWSER_BACKUP_ROOT="$backup_root" \
            SXM_CHECKPOINT_TESTING=1 \
            SXM_MILESTONE_TEST_VALIDATION_COMMAND="$validation_command" \
            SXM_MILESTONE_TEST_MARKER="$validation_marker" \
            SXM_MILESTONE_EXPECTED_TAG_OBJECT="$expected_tag_object" \
            SXM_MILESTONE_ORIGINAL_REPOSITORY="$repository" \
            "$@" \
            zsh scripts/milestone_checkpoint.command \
                "$tag" \
                --sample-dir \
                "$sample_dir"
    )
}

append_bundle_manifest_row() {
    local manifest="$1"
    local bundle_path="$2"
    local commit="$3"
    local timestamp="$4"
    local checksum

    checksum="$(shasum -a 256 "$bundle_path" | awk '{print $1}')"
    printf '%s\t7\t2.0.0\ttest-branch\t%s\t%s\t%s\tmilestone-fixture\n' \
        "$timestamp" \
        "$commit" \
        "${bundle_path:t}" \
        "$checksum" \
        >> "$manifest"
}

prepare_milestone_fixture() {
    local name="$1"
    local mode="${2:-multiple}"
    local commit
    local exact_first_name="sxm-browser-b0007-20260101-010000-exactfirst.bundle"
    local exact_latest_name="sxm-browser-b0007-20260101-020000-exactlatest.bundle"
    local wrong_name="sxm-browser-b0007-20260101-030000-wrongtag.bundle"
    local wrong_repository="$TEST_ROOT/$name/wrong-tag-repository"

    make_fixture "$name"
    run_migration \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        --apply >/dev/null
    commit="$(git -C "$FIXTURE_REPOSITORY" rev-parse HEAD)"
    git -C "$FIXTURE_REPOSITORY" tag \
        -a v2.0.0 \
        -m "exact milestone tag"
    FIXTURE_TAG_OBJECT="$(
        git -C "$FIXTURE_REPOSITORY" rev-parse refs/tags/v2.0.0
    )"

    if [[ "$mode" == "multiple" ]]; then
        git -C "$FIXTURE_REPOSITORY" bundle create \
            "$FIXTURE_BACKUP_ROOT/bundles/$exact_first_name" \
            --all
        append_bundle_manifest_row \
            "$FIXTURE_MANIFEST" \
            "$FIXTURE_BACKUP_ROOT/bundles/$exact_first_name" \
            "$commit" \
            "2026-01-01T01:00:00+0000"

        git -C "$FIXTURE_REPOSITORY" bundle create \
            "$FIXTURE_BACKUP_ROOT/bundles/$exact_latest_name" \
            --all
        append_bundle_manifest_row \
            "$FIXTURE_MANIFEST" \
            "$FIXTURE_BACKUP_ROOT/bundles/$exact_latest_name" \
            "$commit" \
            "2026-01-01T02:00:00+0000"
        FIXTURE_EXPECTED_BUNDLE="$exact_latest_name"
    else
        FIXTURE_EXPECTED_BUNDLE=""
    fi

    git clone -q "$FIXTURE_REPOSITORY" "$wrong_repository"
    git -C "$wrong_repository" config user.name "Wrong Tag Fixture"
    git -C "$wrong_repository" config user.email "wrong-tag@example.invalid"
    git -C "$wrong_repository" tag -d v2.0.0 >/dev/null
    git -C "$wrong_repository" tag \
        -a v2.0.0 \
        -m "different annotated tag object" \
        "$commit"
    if [[ "$(git -C "$wrong_repository" rev-parse refs/tags/v2.0.0)" \
        == "$FIXTURE_TAG_OBJECT" ]]; then
        fail "Wrong-tag fixture unexpectedly reproduced the exact tag object."
    fi
    git -C "$wrong_repository" bundle create \
        "$FIXTURE_BACKUP_ROOT/bundles/$wrong_name" \
        --all
    append_bundle_manifest_row \
        "$FIXTURE_MANIFEST" \
        "$FIXTURE_BACKUP_ROOT/bundles/$wrong_name" \
        "$commit" \
        "2026-01-01T03:00:00+0000"
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

test_version_rejects_detached_head() {
    make_fixture detached-version
    local info_sha="$(shasum -a 256 "$FIXTURE_INFO" | awk '{print $1}')"
    local changelog_sha="$(
        shasum -a 256 "$FIXTURE_CHANGELOG" | awk '{print $1}'
    )"
    git -C "$FIXTURE_REPOSITORY" checkout -q --detach
    expect_exit 65 \
        run_version "$FIXTURE_REPOSITORY" "$FIXTURE_BACKUP_ROOT"
    assert_equal \
        "$info_sha" \
        "$(shasum -a 256 "$FIXTURE_INFO" | awk '{print $1}')" \
        "Detached version guard must leave Info.plist unchanged"
    assert_equal \
        "$changelog_sha" \
        "$(shasum -a 256 "$FIXTURE_CHANGELOG" | awk '{print $1}')" \
        "Detached version guard must leave Changelog unchanged"
    pass "version checkpoint rejects detached HEAD"
}

test_backup_rejects_missing_manifest_with_history() {
    make_fixture missing-manifest
    prepare_committed_checkpoint \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT"
    local bundle_count="$(
        find "$FIXTURE_BACKUP_ROOT/bundles" -name '*.bundle' -type f \
            | wc -l | tr -d '[:space:]'
    )"
    rm "$FIXTURE_MANIFEST"
    expect_exit 65 \
        run_backup \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        "tests passed"
    assert_equal \
        "$bundle_count" \
        "$(find "$FIXTURE_BACKUP_ROOT/bundles" -name '*.bundle' -type f \
            | wc -l | tr -d '[:space:]')" \
        "Missing-manifest guard must not create or remove artifacts"
    pass "backup refuses to forget existing history when manifest is missing"
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

test_milestone_exact_tag_restore_and_source_archive() {
    prepare_milestone_fixture milestone-success multiple
    local output
    local archive="$FIXTURE_BACKUP_ROOT/milestones/sxm-browser-v2.0.0-source.zip"
    local restored_repository
    local final_row
    local timestamp build version branch commit artifact checksum tests

    output="$(
        run_milestone \
            "$FIXTURE_REPOSITORY" \
            "$FIXTURE_BACKUP_ROOT" \
            v2.0.0 \
            "$FIXTURE_SAMPLE_DIR" \
            "$FIXTURE_VALIDATION_COMMAND" \
            "$FIXTURE_VALIDATION_MARKER" \
            "$FIXTURE_TAG_OBJECT"
    )"
    [[ "$output" == *"$FIXTURE_EXPECTED_BUNDLE"* ]] \
        || fail "Milestone did not select the latest exact-tag Bundle."
    assert_file "$archive"
    assert_file "$FIXTURE_VALIDATION_MARKER"
    restored_repository="$(< "$FIXTURE_VALIDATION_MARKER")"
    [[ "$restored_repository" != "$FIXTURE_REPOSITORY" ]] \
        || fail "Milestone validation ran in the source repository."
    assert_no_file "$restored_repository"

    final_row="$(tail -n 1 "$FIXTURE_MANIFEST")"
    IFS=$'\t' read -r \
        timestamp build version branch commit artifact checksum tests \
        <<< "$final_row"
    assert_equal "8" "$(
        printf '%s\n' "$final_row" \
            | awk -F '\t' '{ print NF }'
    )" "Milestone manifest row must be canonical TSV"
    assert_equal "7" "$build" "Milestone build must come from the restored tag"
    assert_equal "2.0.0" "$version" \
        "Milestone version must come from the restored tag"
    assert_equal \
        "$(git -C "$FIXTURE_REPOSITORY" rev-parse v2.0.0^{commit})" \
        "$commit" \
        "Milestone manifest must record the peeled tag commit"
    assert_equal "sxm-browser-v2.0.0-source.zip" "$artifact" \
        "Milestone manifest must index the source archive"
    [[ "$tests" == *"restore=${FIXTURE_EXPECTED_BUNDLE}"* ]] \
        || fail "Milestone manifest did not record the selected Bundle."

    if unzip -Z1 "$archive" \
        | awk '
            {
                count = split($0, components, "/")
                for (indexValue = 1; indexValue <= count; indexValue++) {
                    component = components[indexValue]
                    if (component ~ /^\.build/ \
                        || component == ".swiftpm" \
                        || component == "DerivedData" \
                        || component ~ /\.app$/ \
                        || component == "dist" \
                        || component == "backups" \
                        || component == "example-graph" \
                        || component == ".DS_Store" \
                        || component == "__MACOSX") {
                        found = 1
                    }
                }
            }
            END { exit(found ? 0 : 1) }
        ' >/dev/null; then
        fail "Milestone source ZIP contains generated or excluded content."
    fi
    assert_equal \
        "fixture" \
        "$(unzip -p "$archive" 'sxm-browser-v2.0.0/fixture.txt')" \
        "Milestone source ZIP must come from the restored tagged tree"
    assert_equal \
        "0" \
        "$(find "$FIXTURE_BACKUP_ROOT/.pending" -name '*.pending' -type f \
            | wc -l | tr -d '[:space:]')" \
        "Successful milestone must consume its receipt"
    pass "milestone restores the latest exact tag object and emits a clean source ZIP"
}

test_milestone_rejects_wrong_annotated_tag_object() {
    prepare_milestone_fixture milestone-wrong-tag wrong-only
    local manifest_sha="$(
        shasum -a 256 "$FIXTURE_MANIFEST" | awk '{ print $1 }'
    )"

    expect_exit 65 \
        run_milestone \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        v2.0.0 \
        "$FIXTURE_SAMPLE_DIR" \
        "$FIXTURE_VALIDATION_COMMAND" \
        "$FIXTURE_VALIDATION_MARKER" \
        "$FIXTURE_TAG_OBJECT"
    assert_no_file "$FIXTURE_VALIDATION_MARKER"
    assert_equal \
        "$manifest_sha" \
        "$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{ print $1 }')" \
        "Wrong tag-object rejection must not change the manifest"
    assert_equal \
        "0" \
        "$(find "$FIXTURE_BACKUP_ROOT/milestones" -name '*.zip' -type f \
            | wc -l | tr -d '[:space:]')" \
        "Wrong tag-object rejection must not create an archive"
    pass "milestone requires the exact annotated tag object"
}

test_milestone_validation_failure_has_no_artifacts() {
    prepare_milestone_fixture milestone-validation-failure multiple
    local manifest_sha="$(
        shasum -a 256 "$FIXTURE_MANIFEST" | awk '{ print $1 }'
    )"
    local restored_repository

    expect_exit 42 \
        run_milestone \
        "$FIXTURE_REPOSITORY" \
        "$FIXTURE_BACKUP_ROOT" \
        v2.0.0 \
        "$FIXTURE_SAMPLE_DIR" \
        "$FIXTURE_VALIDATION_COMMAND" \
        "$FIXTURE_VALIDATION_MARKER" \
        "$FIXTURE_TAG_OBJECT" \
        SXM_MILESTONE_TEST_VALIDATION_EXIT=42
    assert_file "$FIXTURE_VALIDATION_MARKER"
    restored_repository="$(< "$FIXTURE_VALIDATION_MARKER")"
    assert_no_file "$restored_repository"
    assert_equal \
        "$manifest_sha" \
        "$(shasum -a 256 "$FIXTURE_MANIFEST" | awk '{ print $1 }')" \
        "Failed restored validation must not change the manifest"
    assert_equal \
        "0" \
        "$(find "$FIXTURE_BACKUP_ROOT/milestones" -name '*.zip' -type f \
            | wc -l | tr -d '[:space:]')" \
        "Failed restored validation must not publish an archive"
    assert_equal \
        "0" \
        "$(find "$FIXTURE_BACKUP_ROOT/.pending" -name '*.pending' -type f \
            | wc -l | tr -d '[:space:]')" \
        "Failed restored validation must not leave a receipt"
    assert_equal \
        "0" \
        "$(find "$FIXTURE_BACKUP_ROOT/.transactions" -mindepth 1 \
            -maxdepth 1 -type d | wc -l | tr -d '[:space:]')" \
        "Failed restored validation must not leave a transaction"
    pass "failed validation in the restored clone publishes nothing"
}

test_milestone_fault_recovery_is_idempotent() {
    local stage
    for stage in \
        after_receipt \
        after_artifact_publish \
        after_manifest_publish; do
        prepare_milestone_fixture "milestone-fault-$stage" multiple
        local initial_lines="$(
            wc -l < "$FIXTURE_MANIFEST" | tr -d '[:space:]'
        )"
        local archive="$FIXTURE_BACKUP_ROOT/milestones/sxm-browser-v2.0.0-source.zip"

        expect_exit 99 \
            run_milestone \
            "$FIXTURE_REPOSITORY" \
            "$FIXTURE_BACKUP_ROOT" \
            v2.0.0 \
            "$FIXTURE_SAMPLE_DIR" \
            "$FIXTURE_VALIDATION_COMMAND" \
            "$FIXTURE_VALIDATION_MARKER" \
            "$FIXTURE_TAG_OBJECT" \
            SXM_CHECKPOINT_TEST_FAIL_AT="$stage"
        assert_equal \
            "1" \
            "$(find "$FIXTURE_BACKUP_ROOT/.pending" -name '*.pending' -type f \
                | wc -l | tr -d '[:space:]')" \
            "Milestone fault $stage must leave one recoverable receipt"

        run_milestone \
            "$FIXTURE_REPOSITORY" \
            "$FIXTURE_BACKUP_ROOT" \
            v2.0.0 \
            "$FIXTURE_SAMPLE_DIR" \
            "$FIXTURE_VALIDATION_COMMAND" \
            "$FIXTURE_VALIDATION_MARKER" \
            "$FIXTURE_TAG_OBJECT" >/dev/null
        assert_file "$archive"
        assert_equal \
            "0" \
            "$(find "$FIXTURE_BACKUP_ROOT/.pending" -name '*.pending' -type f \
                | wc -l | tr -d '[:space:]')" \
            "Milestone recovery $stage must consume its receipt"
        assert_equal \
            "0" \
            "$(find "$FIXTURE_BACKUP_ROOT/.transactions" -mindepth 1 \
                -maxdepth 1 -type d | wc -l | tr -d '[:space:]')" \
            "Milestone recovery $stage must consume its transaction"
        assert_equal \
            "$((initial_lines + 1))" \
            "$(wc -l < "$FIXTURE_MANIFEST" | tr -d '[:space:]')" \
            "Milestone recovery $stage must append exactly one row"
        assert_equal \
            "1" \
            "$(awk -F '\t' \
                '$6 == "sxm-browser-v2.0.0-source.zip" { count++ } \
                END { print count + 0 }' \
                "$FIXTURE_MANIFEST")" \
            "Milestone recovery $stage must not duplicate its manifest row"

        expect_exit 73 \
            run_milestone \
            "$FIXTURE_REPOSITORY" \
            "$FIXTURE_BACKUP_ROOT" \
            v2.0.0 \
            "$FIXTURE_SAMPLE_DIR" \
            "$FIXTURE_VALIDATION_COMMAND" \
            "$FIXTURE_VALIDATION_MARKER" \
            "$FIXTURE_TAG_OBJECT"
        assert_equal \
            "1" \
            "$(find "$FIXTURE_BACKUP_ROOT/milestones" -name '*.zip' -type f \
                | wc -l | tr -d '[:space:]')" \
            "Repeated milestone $stage must not create another archive"
    done
    pass "milestone receipt recovery is idempotent across all publish windows"
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
    "$SOURCE_ROOT/scripts/backup_checkpoint.command" \
    "$SOURCE_ROOT/scripts/milestone_checkpoint.command"
pass "zsh syntax validation"

test_manifest_migration
test_manifest_rejects_mixed_line
test_migration_rejects_orphan_transaction
test_version_transaction_and_repeat_guard
test_version_failure_and_recovery
test_version_requires_previous_backup
test_version_rejects_detached_head
test_backup_rejects_missing_manifest_with_history
test_backup_guards_and_real_tsv
test_pending_receipt_recovery
test_milestone_exact_tag_restore_and_source_archive
test_milestone_rejects_wrong_annotated_tag_object
test_milestone_validation_failure_has_no_artifacts
test_milestone_fault_recovery_is_idempotent
test_backup_lock
test_stale_backup_lock_recovery

print "checkpoint_workflow_tests=passed count=$TEST_COUNT"
