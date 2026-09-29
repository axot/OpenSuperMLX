#!/bin/bash
set -euo pipefail
export LC_ALL=C

fail() {
    printf 'release preflight: %s\n' "$1" >&2
    exit 1
}

event_name="${GITHUB_EVENT_NAME:-}"
[[ "$event_name" == "push" ]] || fail "event must be push"

ref_name="${GITHUB_REF_NAME:-}"
release_input_sha="${GITHUB_SHA:-}"
repository="${GITHUB_REPOSITORY:-}"
[[ -n "$ref_name" ]] || fail "GITHUB_REF_NAME is required"
[[ -n "$release_input_sha" ]] || fail "GITHUB_SHA is required"
[[ -n "$repository" ]] || fail "GITHUB_REPOSITORY is required"

ref_type="${GITHUB_REF_TYPE:-}"
ref="${GITHUB_REF:-}"
if [[ "$ref_type" != "tag" && "$ref" != "refs/tags/$ref_name" ]]; then
    fail "release ref must be a tag"
fi

release_tag_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ ! "$ref_name" =~ $release_tag_pattern ]]; then
    fail "tag must use X.Y.Z format"
fi

project_file="OpenSuperMLX.xcodeproj/project.pbxproj"
[[ -f "$project_file" ]] || fail "project file is missing"

# Prints the distinct values of one build setting read from a project file on stdin.
read_project_setting() {
    awk -v key="$1" '
        $0 ~ key "[[:space:]]*=" {
            value = $0
            sub("^.*" key "[[:space:]]*=[[:space:]]*", "", value)
            sub(/[[:space:]]*;.*$/, "", value)
            if (value != "") print value
        }
    ' | sort -u
}

project_versions="$(read_project_setting MARKETING_VERSION < "$project_file" 2>/dev/null)" \
    || fail "could not parse MARKETING_VERSION"

version_count="$(printf '%s\n' "$project_versions" | awk 'NF { count++ } END { print count + 0 }')"
[[ "$version_count" -gt 0 ]] || fail "MARKETING_VERSION is missing"
[[ "$version_count" -eq 1 ]] || fail "MARKETING_VERSION values must be identical"
[[ "$project_versions" == "$ref_name" ]] || fail "tag does not match MARKETING_VERSION"

if ! git fetch --no-tags origin master:refs/remotes/origin/master >/dev/null 2>&1; then
    fail "could not fetch origin master"
fi

tag_object_type="$(git cat-file -t "refs/tags/${ref_name}" 2>/dev/null)" \
    || fail "release tag does not exist"
[[ "$tag_object_type" == "tag" ]] || fail "release tag must be an annotated tag"

release_sha="$(git rev-parse --verify "${release_input_sha}^{commit}" 2>/dev/null)" \
    || fail "GITHUB_SHA is not a commit"
tag_sha="$(git rev-parse --verify "refs/tags/${ref_name}^{commit}" 2>/dev/null)" \
    || fail "release tag is not a commit"
[[ "$tag_sha" == "$release_sha" ]] || fail "release tag does not match GITHUB_SHA"

if ! git merge-base --is-ancestor "$release_sha" refs/remotes/origin/master >/dev/null 2>&1; then
    fail "release commit is not on origin/master"
fi

build_number="$(read_project_setting CURRENT_PROJECT_VERSION < "$project_file")" \
    || fail "could not parse CURRENT_PROJECT_VERSION"
[[ -n "$build_number" ]] || fail "CURRENT_PROJECT_VERSION is missing"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "CURRENT_PROJECT_VERSION values must be one positive integer"

# Sparkle compares build numbers, so every release must raise CURRENT_PROJECT_VERSION.
previous_tag="$(git tag --merged "$release_sha" --sort=-v:refname \
    | grep -E "$release_tag_pattern" \
    | grep -vxF "$ref_name" | head -n 1 || true)"
if [[ -n "$previous_tag" ]]; then
    previous_build="$(git show "refs/tags/${previous_tag}:${project_file}" 2>/dev/null \
        | read_project_setting CURRENT_PROJECT_VERSION || true)"
    [[ "$previous_build" =~ ^[1-9][0-9]*$ ]] || fail "could not read CURRENT_PROJECT_VERSION for $previous_tag"
    (( build_number > previous_build )) \
        || fail "CURRENT_PROJECT_VERSION $build_number must be greater than $previous_build in $previous_tag"
fi

workflow_metadata="$(
    gh api --method GET \
        "repos/$repository/actions/workflows/build.yml" \
        --jq '[.id, .name, .state] | @tsv' 2>/dev/null
)" || fail "could not query Build Check workflow"
[[ -n "$workflow_metadata" && "$workflow_metadata" != *$'\n'* ]] \
    || fail "invalid Build Check workflow metadata"

IFS=$'\t' read -r workflow_id workflow_name workflow_state workflow_extra <<< "$workflow_metadata"
[[ "$workflow_id" =~ ^[1-9][0-9]*$ && -z "${workflow_extra:-}" ]] \
    || fail "invalid Build Check workflow metadata"
[[ "$workflow_name" == "Build Check" ]] || fail "workflow name must be Build Check"
[[ "$workflow_state" == "active" ]] || fail "Build Check workflow is not active"

selected_run_id="$(
    gh api --method GET \
        "repos/$repository/actions/workflows/$workflow_id/runs" \
        -f "event=push" \
        -f "status=completed" \
        -f "head_sha=$release_sha" \
        -f "per_page=100" \
        --jq "[.workflow_runs[]? | select(.name == \"Build Check\" and .head_sha == \"$release_sha\" and .event == \"push\" and .status == \"completed\" and .conclusion == \"success\")] | sort_by(.id) | reverse | .[0].id // empty" \
        2>/dev/null
)" || fail "could not query Build Check runs"
[[ "$selected_run_id" =~ ^[1-9][0-9]*$ ]] || fail "no successful Build Check found for release commit"

selected_run="$(
    gh api --method GET \
        "repos/$repository/actions/runs/$selected_run_id" \
        --jq '[.workflow_id, .name, .event, .status, .conclusion, .head_sha] | @tsv' \
        2>/dev/null
)" || fail "could not revalidate selected Build Check run"
[[ -n "$selected_run" && "$selected_run" != *$'\n'* ]] \
    || fail "invalid selected Build Check run"

IFS=$'\t' read -r selected_workflow_id selected_name selected_event selected_status \
    selected_conclusion selected_sha selected_extra <<< "$selected_run"
[[ "$selected_workflow_id" == "$workflow_id" && -z "${selected_extra:-}" ]] \
    || fail "selected run is not from Build Check workflow"
[[ "$selected_name" == "Build Check" ]] || fail "selected run name is not Build Check"
[[ "$selected_sha" == "$release_sha" ]] || fail "selected run SHA changed"
[[ "$selected_event" == "push" ]] || fail "selected run event changed"
[[ "$selected_status" == "completed" ]] || fail "selected run is not completed"
[[ "$selected_conclusion" == "success" ]] || fail "selected run is not successful"
