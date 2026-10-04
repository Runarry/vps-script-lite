#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

TEST_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_TEMP="$(mktemp -d)"
WORKSPACE="${TEST_TEMP}/workspace with spaces"
RELEASE_TAG="v$(<"${TEST_ROOT}/VERSION")"
CASE_ROOT=''
RUN_STATUS=0
RUN_COUNT=0
trap 'rm -rf -- "$TEST_TEMP"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [[ -f "${CASE_ROOT}/workflow.log" ]]; then cat -- "${CASE_ROOT}/workflow.log" >&2; fi
    exit 1
}

mkdir -p -- "${TEST_TEMP}/bin" "${WORKSPACE}/dist/release"
# shellcheck source=../../lib/registry.sh
source "${TEST_ROOT}/lib/registry.sh"
ASSET_NAMES=(vpsctl.sh vpsctl-manifest.tsv)
for bundle in "${VPS_BUNDLE_IDS[@]}"; do
    ASSET_NAMES+=("vpsctl-${bundle}-${RELEASE_TAG#v}.tar.gz")
done
for asset in "${ASSET_NAMES[@]}"; do
    printf 'new contents: %s\n' "$asset" >"${WORKSPACE}/dist/release/${asset}"
done

cat >"${TEST_TEMP}/bin/gh" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'
die() { printf 'mock gh: %s\n' "$*" >&2; exit 99; }
operation="$1 $2"
shift 2
printf '%s\n' "$operation" >>"${GH_MOCK_ROOT}/calls"
case "$operation" in
    'api graphql')
        query='' tag='' filter=''
        while (($#)); do
            case "$1" in
                -f)
                    case "$2" in
                        query=*) query="${2#query=}" ;;
                        tag=*) tag="${2#tag=}" ;;
                        *) die "unexpected GraphQL field: $2" ;;
                    esac
                    shift 2 ;;
                --jq) filter="$2"; shift 2 ;;
                *) die "unexpected API argument: $1" ;;
            esac
        done
        [[ "$tag" == "$GITHUB_REF_NAME" && -n "$filter" ]] || die 'missing tag or filter'
        query="$(printf '%s' "$query" | tr -d '[:space:]')"
        # Match the literal GraphQL variable, not a shell expansion.
        # shellcheck disable=SC2016
        [[ "$query" == *'query($tag:String!)'* &&
           "$query" == *'repository(owner:"Runarry",name:"vps-script-lite")'* &&
           "$query" == *'release(tagName:$tag){isDraft}'* ]] || die 'unexpected lookup target'
        case "$GH_MOCK_MODE" in
            permission) printf 'gh: HTTP 403\n' >&2; exit 41 ;;
            network) printf 'gh: connection failed\n' >&2; exit 42 ;;
            graphql)
                # GraphQL may return data and errors together. Nonzero wins.
                jq -r "$filter" "${GH_MOCK_ROOT}/response.json"
                printf 'gh: GraphQL query failed\n' >&2
                exit 43 ;;
            empty-output) exit 0 ;;
            unexpected-output) printf 'unknown\n'; exit 0 ;;
        esac
        # Exercise the workflow's actual expression against raw response fixtures.
        jq -r "$filter" "${GH_MOCK_ROOT}/response.json"
        ;;
    'release create')
        [[ "$1" == "$GITHUB_REF_NAME" ]] || die 'wrong create tag'
        shift
        jq -e '.data.repository.release == null' "${GH_MOCK_ROOT}/response.json" >/dev/null ||
            die 'release already exists'
        repo='' title='' draft=0 notes=0
        while (($#)); do
            case "$1" in
                --repo) repo="$2"; shift 2 ;;
                --title) title="$2"; shift 2 ;;
                --draft) draft=1; shift ;;
                --generate-notes) notes=1; shift ;;
                *) die "unexpected create argument: $1" ;;
            esac
        done
        [[ "$repo" == Runarry/vps-script-lite && "$title" == "vpsctl ${GITHUB_REF_NAME}" &&
           "$draft" == 1 && "$notes" == 1 ]] || die 'incorrect draft creation options'
        [[ "$GH_MOCK_MODE" != create-fail ]] || exit 44
        printf '{"data":{"repository":{"release":{"isDraft":true}}}}\n' >"${GH_MOCK_ROOT}/response.json"
        printf '%s\n' "$title" >"${GH_MOCK_ROOT}/title"
        printf 'generated release notes\n' >"${GH_MOCK_ROOT}/notes"
        ;;
    'release upload')
        [[ "$1" == "$GITHUB_REF_NAME" ]] || die 'wrong upload tag'
        shift
        repo='' clobber=0
        files=()
        while (($#)); do
            case "$1" in
                --repo) repo="$2"; shift 2 ;;
                --clobber) clobber=1; shift ;;
                dist/release/*) files+=("$1"); shift ;;
                *) die "unexpected upload argument: $1" ;;
            esac
        done
        [[ "$repo" == Runarry/vps-script-lite && "$clobber" == 1 ]] || die 'incorrect upload options'
        expected=(dist/release/*)
        [[ "${#files[@]}" == "${#expected[@]}" ]] || die 'incomplete upload set'
        for index in "${!expected[@]}"; do
            [[ "${files[$index]}" == "${expected[$index]}" ]] || die 'unexpected upload file'
        done
        jq -e '.data.repository.release.isDraft == true' "${GH_MOCK_ROOT}/response.json" >/dev/null ||
            die 'upload target is not a draft'
        count=0
        for file in "${files[@]}"; do
            target="${GH_MOCK_ROOT}/assets/${file##*/}"
            rm -f -- "$target"
            count=$((count + 1))
            # Model clobber deleting an old asset before a failed replacement.
            if [[ "$GH_MOCK_MODE" == upload-fail && "$count" == 2 ]]; then exit 45; fi
            cp -- "$file" "$target"
        done
        ;;
    *) die "unexpected operation: $operation" ;;
esac
BASH
chmod +x -- "${TEST_TEMP}/bin/gh"

reset_case() {
    local name="$1" response="$2" contents="${3:-empty}" asset count=0
    CASE_ROOT="${TEST_TEMP}/${name}"
    mkdir -p -- "${CASE_ROOT}/assets"
    printf '%s\n' "$response" >"${CASE_ROOT}/response.json"
    printf 'custom title\n' >"${CASE_ROOT}/title"
    printf 'custom notes\nwith another line\n' >"${CASE_ROOT}/notes"
    cp -- "${CASE_ROOT}/title" "${CASE_ROOT}/original-title"
    cp -- "${CASE_ROOT}/notes" "${CASE_ROOT}/original-notes"
    printf 'unrelated attachment\n' >"${CASE_ROOT}/assets/extra.txt"
    if [[ "$contents" != empty ]]; then
        for asset in "${ASSET_NAMES[@]}"; do
            printf 'old contents: %s\n' "$asset" >"${CASE_ROOT}/assets/${asset}"
            count=$((count + 1))
            if [[ "$contents" == partial && "$count" == 2 ]]; then break; fi
        done
    fi
    cp -a -- "${CASE_ROOT}/assets" "${CASE_ROOT}/original-assets"
    : >"${CASE_ROOT}/calls"
}

run_workflow() {
    local mode="${1:-normal}"
    RUN_COUNT=$((RUN_COUNT + 1))
    if (
        cd -- "$WORKSPACE"
        PATH="${TEST_TEMP}/bin:${PATH}" GH_TOKEN=workflow-test-only GITHUB_REF_NAME="$RELEASE_TAG" \
            GH_MOCK_ROOT="$CASE_ROOT" GH_MOCK_MODE="$mode" bash "${TEST_ROOT}/scripts/prepare-draft-release.sh"
    ) >"${CASE_ROOT}/workflow.log" 2>&1; then RUN_STATUS=0; else RUN_STATUS=$?; fi
}

assert_calls() {
    [[ "$(<"${CASE_ROOT}/calls")" == "$1" ]] || fail "${CASE_ROOT##*/}: incorrect gh calls"
}

assert_metadata() {
    cmp -s -- "${CASE_ROOT}/title" "${CASE_ROOT}/original-title" || fail 'existing title changed'
    cmp -s -- "${CASE_ROOT}/notes" "${CASE_ROOT}/original-notes" || fail 'existing notes changed'
}

assert_uploaded() {
    local asset
    local -a actual=("${CASE_ROOT}/assets/"*)
    [[ "${#actual[@]}" == "$((${#ASSET_NAMES[@]} + 1))" ]] || fail 'unexpected resulting asset set'
    for asset in "${ASSET_NAMES[@]}"; do
        cmp -s -- "${WORKSPACE}/dist/release/${asset}" "${CASE_ROOT}/assets/${asset}" ||
            fail "asset was not replaced: $asset"
    done
    [[ "$(<"${CASE_ROOT}/assets/extra.txt")" == 'unrelated attachment' ]] || fail 'unrelated attachment changed'
}

MISSING='{"data":{"repository":{"release":null}}}'
DRAFT='{"data":{"repository":{"release":{"isDraft":true}}}}'
PUBLISHED='{"data":{"repository":{"release":{"isDraft":false}}}}'

for contents in empty partial complete; do
    reset_case "draft-${contents}" "$DRAFT" "$contents"
    run_workflow
    [[ "$RUN_STATUS" == 0 ]] || fail "existing ${contents} draft could not be retried"
    assert_calls $'api graphql\nrelease upload'
    assert_metadata
    assert_uploaded
done

reset_case missing "$MISSING"
run_workflow
[[ "$RUN_STATUS" == 0 ]] || fail 'new draft preparation failed'
assert_calls $'api graphql\nrelease create\nrelease upload'
[[ "$(<"${CASE_ROOT}/title")" == "vpsctl ${RELEASE_TAG}" &&
   "$(<"${CASE_ROOT}/notes")" == 'generated release notes' ]] || fail 'new draft metadata is incorrect'
assert_uploaded

reset_case published "$PUBLISHED" complete
run_workflow
[[ "$RUN_STATUS" != 0 ]] || fail 'published release was accepted'
assert_calls 'api graphql'
assert_metadata
diff -r -- "${CASE_ROOT}/original-assets" "${CASE_ROOT}/assets" || fail 'published assets changed'
grep -Fq 'already published' "${CASE_ROOT}/workflow.log" || fail 'missing published diagnostic'

for fault in permission network graphql empty-output unexpected-output; do
    reset_case "lookup-${fault}" "$MISSING"
    run_workflow "$fault"
    [[ "$RUN_STATUS" != 0 ]] || fail "${fault} lookup failure was ignored"
    assert_calls 'api graphql'
    assert_metadata
done

fixture=0
while IFS= read -r response; do
    fixture=$((fixture + 1))
    reset_case "bad-response-${fixture}" "$response"
    run_workflow
    [[ "$RUN_STATUS" != 0 ]] || fail "invalid response ${fixture} was accepted"
    assert_calls 'api graphql'
done <<'JSON'
not JSON
{}
{"data":{"repository":null}}
{"data":{"repository":[]}}
{"data":{"repository":{}}}
{"data":{"repository":{"release":{}}}}
{"data":{"repository":{"release":{"isDraft":null}}}}
{"data":{"repository":{"release":{"isDraft":"false"}}}}
JSON

reset_case create-failure "$MISSING"
run_workflow create-fail
[[ "$RUN_STATUS" == 44 ]] || fail 'create failure was not propagated'
assert_calls $'api graphql\nrelease create'

reset_case upload-retry "$DRAFT" complete
run_workflow upload-fail
[[ "$RUN_STATUS" == 45 ]] || fail 'upload failure was not propagated'
assert_calls $'api graphql\nrelease upload'
assert_metadata
sorted_assets=("${WORKSPACE}/dist/release/"*)
first="${sorted_assets[0]##*/}"
second="${sorted_assets[1]##*/}"
cmp -s -- "${WORKSPACE}/dist/release/${first}" "${CASE_ROOT}/assets/${first}" || fail 'partial upload did not start'
[[ ! -e "${CASE_ROOT}/assets/${second}" ]] || fail 'replacement failure was not injected'
run_workflow
[[ "$RUN_STATUS" == 0 ]] || fail 'retry after partial upload failed'
assert_calls $'api graphql\nrelease upload\napi graphql\nrelease upload'
assert_metadata
assert_uploaded

printf 'PASS: release workflow (%s runs)\n' "$RUN_COUNT"
