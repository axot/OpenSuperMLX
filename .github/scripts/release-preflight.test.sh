#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMPLEMENTATION="$SCRIPT_DIR/release-preflight.sh"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
RELEASE_WORKFLOW="$REPOSITORY_ROOT/.github/workflows/release.yml"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/release-preflight-tests.XXXXXX")"
trap 'rm -rf "$TEMP_ROOT"' EXIT

PASS_COUNT=0
FAIL_COUNT=0
FIXTURE_COUNT=0

create_gh_stub() {
    local stub_dir="$1"

    mkdir -p "$stub_dir"
    cat > "$stub_dir/gh" <<'STUB'
#!/bin/bash
set -euo pipefail

if [[ "${1:-}" != "api" ]]; then
    echo "unexpected gh command: $*" >&2
    exit 64
fi
shift

endpoint=""
head_sha=""
jq_filter=""
event=""
status=""
per_page=""
method="GET"
method_set=0
paginate=0
slurp=0
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --method|-X)
            method="${2:-}"
            method_set=1
            shift 2
            ;;
        -f|-F|--field|--raw-field)
            case "${2:-}" in
                head_sha=*) head_sha="${2#head_sha=}" ;;
                event=*) event="${2#event=}" ;;
                status=*) status="${2#status=}" ;;
                per_page=*) per_page="${2#per_page=}" ;;
                *) echo "unsupported gh api field: ${2:-}" >&2; exit 64 ;;
            esac
            shift 2
            ;;
        --jq)
            jq_filter="${2:-}"
            shift 2
            ;;
        --paginate)
            paginate=1
            shift
            ;;
        --slurp)
            slurp=1
            shift
            ;;
        -*)
            echo "unsupported gh api option: $1" >&2
            exit 64
            ;;
        *)
            if [[ -n "$endpoint" ]]; then
                echo "unexpected gh api argument: $1" >&2
                exit 64
            fi
            endpoint="$1"
            shift
            ;;
    esac
done

endpoint="${endpoint#/}"
if [[ "$endpoint" == *\?* ]]; then
    echo "gh api parameters must be passed as GET fields" >&2
    exit 64
fi

scenario="${GH_SCENARIO:-success}"
case "$scenario" in
    success|missing|failed|wrong-event|wrong-sha|inactive-workflow|wrong-workflow-name|refetch-failed|refetch-wrong-event|refetch-wrong-sha) ;;
    api-failure) ;;
    *) echo "unknown GH_SCENARIO: $scenario" >&2; exit 64 ;;
esac

call_number=0
if [[ -f "$GH_CALL_STATE" ]]; then
    read -r call_number < "$GH_CALL_STATE"
fi
call_number=$((call_number + 1))
printf '%s\n' "$call_number" > "$GH_CALL_STATE"
printf '%s\n' "$endpoint" >> "$GH_CALL_LOG"

if [[ "$scenario" == "api-failure" ]]; then
    echo "simulated gh api failure" >&2
    exit 42
fi

case "$call_number" in
    1)
        expected_endpoint="repos/${GITHUB_REPOSITORY}/actions/workflows/build.yml"
        if [[ "$endpoint" != "$expected_endpoint" || "$method" != "GET" || \
              -n "$head_sha$event$status$per_page" || "$paginate" -ne 0 || "$slurp" -ne 0 ]]; then
            echo "invalid workflow metadata request: $endpoint" >&2
            exit 64
        fi
        workflow_name="Build Check"
        workflow_state="active"
        [[ "$scenario" == "wrong-workflow-name" ]] && workflow_name="Other Workflow"
        [[ "$scenario" == "inactive-workflow" ]] && workflow_state="disabled_manually"
        if [[ "$jq_filter" != *"@tsv"* ]]; then
            echo "workflow metadata request must use a TSV projection" >&2
            exit 64
        fi
        printf '4242\t%s\t%s\n' "$workflow_name" "$workflow_state"
        ;;
    2)
        expected_endpoint="repos/${GITHUB_REPOSITORY}/actions/workflows/4242/runs"
        if [[ "$endpoint" != "$expected_endpoint" || "$method" != "GET" || "$method_set" -ne 1 || \
              "$event" != "push" || "$status" != "completed" || "$head_sha" != "$GITHUB_SHA" || \
              "$per_page" != "100" || "$paginate" -ne 0 || "$slurp" -ne 0 ]]; then
            echo "invalid workflow run listing request: $endpoint" >&2
            exit 64
        fi
        run_name="Build Check"
        run_sha="$GITHUB_SHA"
        run_event="push"
        run_conclusion="success"
        [[ "$scenario" == "missing" ]] && run_name="Other Workflow"
        [[ "$scenario" == "failed" ]] && run_conclusion="failure"
        [[ "$scenario" == "wrong-event" ]] && run_event="pull_request"
        [[ "$scenario" == "wrong-sha" ]] && run_sha="0000000000000000000000000000000000000000"
        if [[ -z "$jq_filter" ]]; then
            echo "workflow run listing request must select a run ID" >&2
            exit 64
        fi
        matches=1
        [[ "$scenario" == "missing" ]] && matches=0
        [[ "$jq_filter" == *"Build Check"* && "$run_name" != "Build Check" ]] && matches=0
        [[ "$jq_filter" == *head_sha* && "$run_sha" != "$GITHUB_SHA" ]] && matches=0
        [[ "$jq_filter" == *event*push* && "$run_event" != "push" ]] && matches=0
        [[ "$jq_filter" == *conclusion*success* && "$run_conclusion" != "success" ]] && matches=0
        [[ "$matches" -eq 1 ]] && echo 1001
        ;;
    3)
        expected_endpoint="repos/${GITHUB_REPOSITORY}/actions/runs/1001"
        if [[ "$endpoint" != "$expected_endpoint" || "$method" != "GET" || \
              -n "$head_sha$event$status$per_page" || "$paginate" -ne 0 || "$slurp" -ne 0 ]]; then
            echo "invalid selected run request: $endpoint" >&2
            exit 64
        fi
        run_sha="$GITHUB_SHA"
        run_event="push"
        run_conclusion="success"
        [[ "$scenario" == "failed" || "$scenario" == "refetch-failed" ]] && run_conclusion="failure"
        [[ "$scenario" == "wrong-event" || "$scenario" == "refetch-wrong-event" ]] && run_event="pull_request"
        [[ "$scenario" == "wrong-sha" || "$scenario" == "refetch-wrong-sha" ]] && run_sha="0000000000000000000000000000000000000000"
        if [[ "$jq_filter" != *"@tsv"* ]]; then
            echo "selected run request must use a TSV projection" >&2
            exit 64
        fi
        printf '4242\tBuild Check\t%s\tcompleted\t%s\t%s\n' \
            "$run_event" "$run_conclusion" "$run_sha"
        ;;
    *)
        echo "unexpected extra gh api call: $endpoint" >&2
        exit 64
        ;;
esac
STUB
    chmod +x "$stub_dir/gh"
}

create_fixture() {
    FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
    FIXTURE_ROOT="$TEMP_ROOT/fixture-$FIXTURE_COUNT"
    FIXTURE_REPO="$FIXTURE_ROOT/repository"
    FIXTURE_ORIGIN="$FIXTURE_ROOT/origin.git"
    FIXTURE_BIN="$FIXTURE_ROOT/bin"
    FIXTURE_GH_CALL_STATE="$FIXTURE_ROOT/gh-call-state"
    FIXTURE_GH_CALL_LOG="$FIXTURE_ROOT/gh-call-log"

    mkdir -p "$FIXTURE_REPO/OpenSuperMLX.xcodeproj"
    git init --bare --quiet "$FIXTURE_ORIGIN"
    git init --quiet "$FIXTURE_REPO"
    git -C "$FIXTURE_REPO" config user.name "Release Preflight Test"
    git -C "$FIXTURE_REPO" config user.email "release-preflight@example.invalid"
    git -C "$FIXTURE_REPO" checkout --quiet -b master
    git -C "$FIXTURE_REPO" remote add origin "$FIXTURE_ORIGIN"
    set_project_versions "0.0.17"
    printf 'fixture\n' > "$FIXTURE_REPO/README.md"
    git -C "$FIXTURE_REPO" add OpenSuperMLX.xcodeproj/project.pbxproj README.md
    git -C "$FIXTURE_REPO" commit --quiet -m "Fixture release"
    git -C "$FIXTURE_REPO" tag -a 0.0.17 -m "Release 0.0.17"
    git -C "$FIXTURE_REPO" push --quiet origin master
    git -C "$FIXTURE_REPO" push --quiet origin refs/tags/0.0.17
    FIXTURE_SHA="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
    : > "$FIXTURE_GH_CALL_LOG"
    create_gh_stub "$FIXTURE_BIN"
}

set_project_versions() {
    local version

    : > "$FIXTURE_REPO/OpenSuperMLX.xcodeproj/project.pbxproj"
    for version in "$@"; do
        printf 'MARKETING_VERSION = %s;\n' "$version" \
            >> "$FIXTURE_REPO/OpenSuperMLX.xcodeproj/project.pbxproj"
    done
}

run_preflight() {
    local event_name="${1:-push}"
    local ref_name="${2:-0.0.17}"
    local sha="${3:-$FIXTURE_SHA}"
    local scenario="${4:-success}"

    (
        cd "$FIXTURE_REPO"
        PATH="$FIXTURE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
        GITHUB_EVENT_NAME="$event_name" \
        GITHUB_REF="refs/tags/$ref_name" \
        GITHUB_REF_NAME="$ref_name" \
        GITHUB_SHA="$sha" \
        GITHUB_REPOSITORY="test-owner/test-repo" \
        GH_SCENARIO="$scenario" \
        GH_CALL_STATE="$FIXTURE_GH_CALL_STATE" \
        GH_CALL_LOG="$FIXTURE_GH_CALL_LOG" \
            /bin/bash "$IMPLEMENTATION"
    )
}

assert_complete_gh_progression() {
    local call_count=0
    local endpoint

    while IFS= read -r endpoint; do
        call_count=$((call_count + 1))
        case "$call_count:$endpoint" in
            "1:repos/test-owner/test-repo/actions/workflows/build.yml") ;;
            "2:repos/test-owner/test-repo/actions/workflows/4242/runs") ;;
            "3:repos/test-owner/test-repo/actions/runs/1001") ;;
            *) echo "unexpected gh call progression at call $call_count: $endpoint" >&2; return 1 ;;
        esac
    done < "$FIXTURE_GH_CALL_LOG"
    [[ "$call_count" -eq 3 ]]
}

expect_accept() {
    run_preflight "$@" && assert_complete_gh_progression
}

expect_reject() {
    if run_preflight "$@"; then
        echo "preflight unexpectedly accepted invalid release state" >&2
        return 1
    fi
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

test_workflow_dispatch_rejected() {
    local fixture="$TEMP_ROOT/workflow-dispatch"

    mkdir -p "$fixture/bin" "$fixture/empty"
    cat > "$fixture/bin/git" <<'STUB'
#!/bin/bash
echo "git must not run for workflow_dispatch" >&2
exit 97
STUB
    cat > "$fixture/bin/gh" <<'STUB'
#!/bin/bash
echo "gh must not run for workflow_dispatch" >&2
exit 98
STUB
    chmod +x "$fixture/bin/git" "$fixture/bin/gh"
    (
        cd "$fixture/empty"
        export PATH="$fixture/bin:/usr/bin:/bin"
        if GITHUB_EVENT_NAME="workflow_dispatch" \
           GITHUB_REF="refs/heads/master" \
           GITHUB_REF_NAME="master" \
           GITHUB_SHA="unavailable" \
           GITHUB_REPOSITORY="test-owner/test-repo" \
               /bin/bash "$IMPLEMENTATION"
        then
            echo "preflight unexpectedly accepted workflow_dispatch" >&2
            return 1
        fi
    )
}

test_valid_release() {
    create_fixture
    expect_accept push 0.0.17 "$FIXTURE_SHA" success
}

test_lightweight_tag() {
    create_fixture
    git -C "$FIXTURE_REPO" tag -d 0.0.17 >/dev/null
    git -C "$FIXTURE_REPO" tag 0.0.17
    git -C "$FIXTURE_REPO" push --quiet origin :refs/tags/0.0.17
    git -C "$FIXTURE_REPO" push --quiet origin refs/tags/0.0.17
    expect_reject
}

test_malformed_tag() {
    local tag="$1"

    create_fixture
    expect_reject push "$tag" "$FIXTURE_SHA" success
}

test_missing_version() {
    create_fixture
    set_project_versions
    expect_reject
}

test_multiple_versions() {
    create_fixture
    set_project_versions 0.0.17 0.0.18
    expect_reject
}

test_version_mismatch() {
    create_fixture
    set_project_versions 0.0.18
    expect_reject
}

test_tag_sha_mismatch() {
    create_fixture
    printf 'later\n' >> "$FIXTURE_REPO/README.md"
    git -C "$FIXTURE_REPO" add README.md
    git -C "$FIXTURE_REPO" commit --quiet -m "Later master commit"
    git -C "$FIXTURE_REPO" push --quiet origin master
    local later_sha
    later_sha="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
    expect_reject push 0.0.17 "$later_sha" success
}

test_sha_not_on_master() {
    create_fixture
    git -C "$FIXTURE_REPO" checkout --quiet -b release-side
    printf 'side\n' >> "$FIXTURE_REPO/README.md"
    git -C "$FIXTURE_REPO" add README.md
    git -C "$FIXTURE_REPO" commit --quiet -m "Side commit"
    git -C "$FIXTURE_REPO" tag -d 0.0.17 >/dev/null
    git -C "$FIXTURE_REPO" tag -a 0.0.17 -m "Release 0.0.17 from side"
    local side_sha
    side_sha="$(git -C "$FIXTURE_REPO" rev-parse HEAD)"
    expect_reject push 0.0.17 "$side_sha" success
}

test_build_check_result() {
    local scenario="$1"

    create_fixture
    expect_reject push 0.0.17 "$FIXTURE_SHA" "$scenario"
}

test_release_notes_macos_version() {
    grep -F -- '- macOS 15.0 or later' "$RELEASE_WORKFLOW" >/dev/null
}

test_homebrew_sequoia_requirement() {
    grep -F -- 'depends_on macos: ">= :sequoia"' "$RELEASE_WORKFLOW" >/dev/null
}

test_no_stale_generated_release_metadata() {
    if grep -E 'macOS 14(\.0)?|depends_on macos:.*:sonoma' "$RELEASE_WORKFLOW" >/dev/null; then
        echo "release.yml still generates macOS 14 or :sonoma metadata" >&2
        return 1
    fi
}

test_no_workflow_dispatch_trigger() {
    if grep -E '^[[:space:]]*workflow_dispatch:' "$RELEASE_WORKFLOW" >/dev/null; then
        echo "release.yml must not permit workflow_dispatch releases" >&2
        return 1
    fi
}

run_case "reject workflow_dispatch release" test_workflow_dispatch_rejected
run_case "valid 0.0.17 release provenance" test_valid_release
run_case "reject lightweight release tag" test_lightweight_tag
run_case "reject tag v0.0.17" test_malformed_tag v0.0.17
run_case "reject tag 0.0" test_malformed_tag 0.0
run_case "reject tag 0.0.17-rc1" test_malformed_tag 0.0.17-rc1
run_case "reject tag 0.0.17+build" test_malformed_tag 0.0.17+build
run_case "reject tag 00.0.17" test_malformed_tag 00.0.17
run_case "reject tag 0.0.17foo" test_malformed_tag 0.0.17foo
run_case "reject missing MARKETING_VERSION" test_missing_version
run_case "reject multiple MARKETING_VERSION values" test_multiple_versions
run_case "reject tag and version mismatch" test_version_mismatch
run_case "reject tag and GITHUB_SHA mismatch" test_tag_sha_mismatch
run_case "reject SHA outside origin master" test_sha_not_on_master
run_case "reject inactive Build Check workflow" test_build_check_result inactive-workflow
run_case "reject incorrectly named Build Check workflow" test_build_check_result wrong-workflow-name
run_case "reject missing Build Check" test_build_check_result missing
run_case "reject failed Build Check" test_build_check_result failed
run_case "reject pull_request Build Check" test_build_check_result wrong-event
run_case "reject Build Check for wrong SHA" test_build_check_result wrong-sha
run_case "reject selected run that changed to failed" test_build_check_result refetch-failed
run_case "reject selected run with changed event" test_build_check_result refetch-wrong-event
run_case "reject selected run with changed SHA" test_build_check_result refetch-wrong-sha
run_case "reject gh API failure" test_build_check_result api-failure
run_case "release notes require macOS 15.0 or later" test_release_notes_macos_version
run_case "generated cask requires Sequoia" test_homebrew_sequoia_requirement
run_case "generated release metadata has no stale Sonoma references" test_no_stale_generated_release_metadata
run_case "release workflow disallows workflow_dispatch" test_no_workflow_dispatch_trigger

printf '\n%d passed, %d failed\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
