#!/usr/bin/env bash

set -euo pipefail
# GraphQL variables are passed separately from the literal query.
# shellcheck disable=SC2016
if ! release_state="$(gh api graphql \
  -f tag="${GITHUB_REF_NAME}" \
  -f query='query($tag: String!) {
    repository(owner: "Runarry", name: "vps-script-lite") {
      release(tagName: $tag) { isDraft }
    }
  }' \
  --jq '.data.repository |
    if type != "object" then error("release repository is unavailable")
    elif (has("release") | not) then error("release lookup is missing")
    elif .release == null then "missing"
    elif .release.isDraft == true then "draft"
    elif .release.isDraft == false then "published"
    else error("release draft state is invalid")
    end')"; then
  printf 'release: cannot determine release state for %s\n' "${GITHUB_REF_NAME}" >&2
  exit 1
fi
case "$release_state" in
  missing)
    gh release create "${GITHUB_REF_NAME}" \
      --repo Runarry/vps-script-lite \
      --title "vpsctl ${GITHUB_REF_NAME}" \
      --draft \
      --generate-notes
    ;;
  draft) ;;
  published)
    printf 'release: %s is already published; assets were not changed\n' "${GITHUB_REF_NAME}" >&2
    exit 1
    ;;
  *)
    printf 'release: unexpected release state for %s\n' "${GITHUB_REF_NAME}" >&2
    exit 1
    ;;
esac
gh release upload "${GITHUB_REF_NAME}" dist/release/* \
  --repo Runarry/vps-script-lite \
  --clobber
