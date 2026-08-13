#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_WORKFLOW="$REPOSITORY_ROOT/.github/workflows/build.yml"
RUN_SCRIPT="$REPOSITORY_ROOT/run.sh"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/build-safety-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
FIXTURE_COUNT=0

extract_workflow_step() {
    local step_name="$1"

    awk -v target="$step_name" '
        /^[[:space:]]*- name:[[:space:]]*/ {
            if (capturing) exit
            name = $0
            sub(/^[[:space:]]*- name:[[:space:]]*/, "", name)
            if (name == target) capturing = 1
        }
        capturing { print }
    ' "$BUILD_WORKFLOW"
}

assert_test_step_uses_pipefail() {
    local step_name="$1"
    local step_block
    local xcodebuild_line
    local xcpretty_line
    local pipefail_line

    step_block="$(extract_workflow_step "$step_name")"
    if [[ -z "$step_block" ]]; then
        printf 'build.yml is missing step: %s\n' "$step_name" >&2
        return 1
    fi

    xcodebuild_line="$(printf '%s\n' "$step_block" | awk '
        /^[[:space:]]*xcodebuild[[:space:]]+test([[:space:]]|$)/ { print NR; exit }
    ')"
    xcpretty_line="$(printf '%s\n' "$step_block" | awk '
        /\|[[:space:]]*xcpretty([[:space:]]|$)/ { print NR; exit }
    ')"
    pipefail_line="$(printf '%s\n' "$step_block" | awk '
        /^[[:space:]]*set[[:space:]].*pipefail/ { print NR; exit }
    ')"

    if [[ -z "$xcodebuild_line" || -z "$xcpretty_line" || "$xcpretty_line" -lt "$xcodebuild_line" ]]; then
        printf '%s must run xcodebuild test through xcpretty\n' "$step_name" >&2
        return 1
    fi
    if [[ -z "$pipefail_line" || "$pipefail_line" -ge "$xcodebuild_line" ]]; then
        printf '%s must enable pipefail before xcodebuild test is piped to xcpretty\n' "$step_name" >&2
        return 1
    fi
}

create_command_stubs() {
    cat > "$FIXTURE_BIN/security" <<'STUB'
#!/bin/bash
if [[ "$*" != "find-identity -v -p codesigning" ]]; then
    printf 'unexpected security command: %s\n' "$*" >&2
    exit 64
fi
STUB

    cat > "$FIXTURE_BIN/cargo" <<'STUB'
#!/bin/bash
[[ "${1:-}" == "build" ]] || exit 64
STUB

    cat > "$FIXTURE_BIN/cp" <<'STUB'
#!/bin/bash
set -euo pipefail
[[ "$#" -eq 2 ]] || exit 64
mkdir -p "$(dirname "$2")"
: > "$2"
STUB

    cat > "$FIXTURE_BIN/install_name_tool" <<'STUB'
#!/bin/bash
exit 0
STUB

    cat > "$FIXTURE_BIN/codesign" <<'STUB'
#!/bin/bash
set -euo pipefail

call_number=0
if [[ -f "$CODESIGN_CALL_STATE" ]]; then
    read -r call_number < "$CODESIGN_CALL_STATE"
fi
call_number=$((call_number + 1))
printf '%s\n' "$call_number" > "$CODESIGN_CALL_STATE"
artifact="${!#}"
printf '%s\t%s\n' "$call_number" "$artifact" >> "$CODESIGN_CALL_LOG"

if [[ "$call_number" -eq "$CODESIGN_FAIL_CALL" ]]; then
    exit 73
fi
STUB

    cat > "$FIXTURE_BIN/xcodebuild" <<'STUB'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >> "$XCODEBUILD_CALL_LOG"
STUB

    chmod +x "$FIXTURE_BIN"/*
}

create_run_fixture() {
    FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
    FIXTURE_ROOT="$TEMP_ROOT/fixture-$FIXTURE_COUNT"
    FIXTURE_BIN="$FIXTURE_ROOT/bin"
    FIXTURE_CODESIGN_STATE="$FIXTURE_ROOT/codesign-call-state"
    FIXTURE_CODESIGN_LOG="$FIXTURE_ROOT/codesign-call-log"
    FIXTURE_XCODEBUILD_LOG="$FIXTURE_ROOT/xcodebuild-call-log"
    FIXTURE_RESOLVE_LOG="$FIXTURE_ROOT/resolve-call-log"

    mkdir -p "$FIXTURE_BIN" "$FIXTURE_ROOT/Scripts" "$FIXTURE_ROOT/build"
    /bin/cp "$RUN_SCRIPT" "$FIXTURE_ROOT/run.sh"
    printf 'fixture\n' > "$FIXTURE_ROOT/build/processor_main"
    printf 'fixture\n' > "$FIXTURE_ROOT/build/zh_itn_tagger.fst"
    printf 'fixture\n' > "$FIXTURE_ROOT/build/zh_itn_verbalizer.fst"

    cat > "$FIXTURE_ROOT/Scripts/resolve_and_patch.sh" <<'STUB'
#!/bin/bash
set -euo pipefail
printf 'called\n' >> "$RESOLVE_CALL_LOG"
STUB

    create_command_stubs
    chmod +x "$FIXTURE_ROOT/run.sh" "$FIXTURE_ROOT/Scripts/resolve_and_patch.sh"
}

run_fixture() {
    local failing_call="$1"

    (
        cd "$FIXTURE_ROOT"
        PATH="$FIXTURE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        CODESIGN_FAIL_CALL="$failing_call" \
        CODESIGN_CALL_STATE="$FIXTURE_CODESIGN_STATE" \
        CODESIGN_CALL_LOG="$FIXTURE_CODESIGN_LOG" \
        XCODEBUILD_CALL_LOG="$FIXTURE_XCODEBUILD_LOG" \
        RESOLVE_CALL_LOG="$FIXTURE_RESOLVE_LOG" \
            /bin/zsh ./run.sh build
    )
}

has_artifact_signing_failure() {
    local output_file="$1"
    local artifact="$2"

    awk -v artifact="$artifact" '
        BEGIN { artifact = tolower(artifact) }
        {
            line = tolower($0)
            if (index(line, artifact) &&
                line ~ /(codesign|code[ -]?sign|signing)/ &&
                line ~ /(fail|error|unable|cannot|could not)/) {
                found = 1
            }
        }
        END { exit !found }
    ' "$output_file"
}

assert_codesign_failure_stops_build() {
    local failing_call="$1"
    local artifact="$2"
    local output_file
    local failed_artifact
    local status=0
    local assertion_failed=0

    create_run_fixture
    output_file="$FIXTURE_ROOT/run-output"
    run_fixture "$failing_call" > "$output_file" 2>&1 || status=$?

    failed_artifact="$(awk -v call="$failing_call" '$1 == call { print $2 }' "$FIXTURE_CODESIGN_LOG")"
    if [[ "$failed_artifact" != *"$artifact" ]]; then
        printf 'fixture expected codesign call %s to target %s, got %s\n' \
            "$failing_call" "$artifact" "${failed_artifact:-nothing}" >&2
        assertion_failed=1
    fi
    if [[ "$status" -eq 0 ]]; then
        printf 'run.sh returned zero after %s codesign failure; expected nonzero\n' "$artifact" >&2
        assertion_failed=1
    fi
    if ! has_artifact_signing_failure "$output_file" "$artifact"; then
        printf 'run.sh did not report an artifact-specific codesign failure for %s\n' "$artifact" >&2
        assertion_failed=1
    fi

    return "$assertion_failed"
}

run_case() {
    local name="$1"
    local output="$TEMP_ROOT/case-output"
    shift

    if "$@" > "$output" 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS: %s\n' "$name"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL: %s\n' "$name"
        while IFS= read -r line; do
            printf '  %s\n' "$line"
        done < "$output"
    fi
}

run_case "unit test step preserves xcodebuild failure" \
    assert_test_step_uses_pipefail "Run unit tests (hostless)"
run_case "integration test step preserves xcodebuild failure" \
    assert_test_step_uses_pipefail "Run integration tests (hosted)"
run_case "libomp codesign failure stops run.sh" \
    assert_codesign_failure_stops_build 3 "libomp.dylib"
run_case "processor_main codesign failure stops run.sh" \
    assert_codesign_failure_stops_build 4 "processor_main"

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
