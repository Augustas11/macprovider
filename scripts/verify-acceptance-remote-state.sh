#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-acceptance-remote-state] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 3 ]] || die "usage: CANDIDATE_REF CANDIDATE_SHA TAG"
candidate_ref="$1"
candidate_sha="$2"
tag="$3"

[[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]] || die "acceptance signing requires manual dispatch"
[[ "${GITHUB_REF:-}" == "refs/heads/main" ]] || die "protected signer must execute from refs/heads/main"
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA is invalid"
[[ "$(git rev-parse HEAD)" == "$GITHUB_SHA" ]] || die "protected checkout differs from GITHUB_SHA"
[[ "$candidate_ref" == refs/heads/* ]] || die "candidate ref must be a branch"
git check-ref-format --branch "${candidate_ref#refs/heads/}" >/dev/null 2>&1 || die "candidate branch is invalid"
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || die "candidate SHA is invalid"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "candidate tag is invalid"

main_row="$(git ls-remote --exit-code origin refs/heads/main)" || die "main control branch is unavailable"
[[ "$(printf '%s\n' "$main_row" | wc -l | tr -d ' ')" == "1" ]] || die "main branch lookup was ambiguous"
read -r main_sha main_ref main_extra <<<"$main_row"
[[ -z "${main_extra:-}" && "$main_ref" == refs/heads/main && "$main_sha" == "$GITHUB_SHA" ]] ||
  die "main control branch drifted after dispatch"

remote_row="$(git ls-remote --exit-code origin "$candidate_ref")" || die "candidate branch is unavailable"
[[ "$(printf '%s\n' "$remote_row" | wc -l | tr -d ' ')" == "1" ]] || die "candidate branch lookup was ambiguous"
read -r remote_sha remote_ref extra <<<"$remote_row"
[[ -z "${extra:-}" && "$remote_ref" == "$candidate_ref" && "$remote_sha" == "$candidate_sha" ]] ||
  die "candidate branch drifted after the unprivileged build"

tag_rows="$(git ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")" || die "could not verify tag absence"
[[ -z "$tag_rows" ]] || die "candidate tag now exists; refusing alternate acceptance bundle"

printf '[verify-acceptance-remote-state] ok: %s remains at %s and %s is absent\n' \
  "$candidate_ref" "$candidate_sha" "$tag"
