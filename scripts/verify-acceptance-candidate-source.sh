#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-acceptance-candidate-source] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 6 ]] || die "usage: CONTROL_DIR CANDIDATE_DIR EXPECTED_REMOTE CANDIDATE_REF CANDIDATE_SHA TAG"
control_dir="$1"
candidate_dir="$2"
expected_remote="${3%.git}"
candidate_ref="$4"
candidate_sha="$5"
tag="$6"

[[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]] || die "acceptance signing requires manual workflow dispatch"
[[ "${GITHUB_REF:-}" == "refs/heads/main" ]] || die "workflow definition must execute from refs/heads/main"
[[ "${GITHUB_SHA:-}" =~ ^[0-9a-f]{40}$ ]] || die "GITHUB_SHA must be an exact commit"
[[ "${GITHUB_REPOSITORY:-}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "GITHUB_REPOSITORY is invalid"
[[ "$candidate_ref" == refs/heads/* ]] || die "candidate ref must be a branch ref"
candidate_branch="${candidate_ref#refs/heads/}"
git check-ref-format --branch "$candidate_branch" >/dev/null 2>&1 || die "candidate branch is invalid"
[[ "$candidate_sha" =~ ^[0-9a-f]{40}$ ]] || die "candidate SHA must be 40 lowercase hexadecimal characters"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be vMAJOR.MINOR.PATCH"
[[ "$expected_remote" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] ||
  [[ "$expected_remote" =~ ^file:///.+$ ]] || die "expected remote is invalid"

control_dir="$(cd "$control_dir" && pwd -P)"
candidate_dir="$(cd "$candidate_dir" && pwd -P)"
[[ "$(git -C "$control_dir" rev-parse HEAD)" == "$GITHUB_SHA" ]] ||
  die "trusted control checkout differs from the dispatched main commit"
[[ "$(git -C "$candidate_dir" rev-parse HEAD)" == "$candidate_sha" ]] ||
  die "candidate checkout differs from the exact requested SHA"
[[ "$(git -C "$candidate_dir" cat-file -t "$candidate_sha")" == "commit" ]] ||
  die "candidate SHA is not a commit"

actual_remote="$(git -C "$candidate_dir" remote get-url origin)"
actual_remote="${actual_remote%.git}"
[[ "$actual_remote" == "$expected_remote" ]] || die "candidate checkout remote differs from the requested repository"

remote_row="$(git -C "$candidate_dir" ls-remote --exit-code origin "$candidate_ref")" ||
  die "candidate branch is not available from origin"
[[ "$(printf '%s\n' "$remote_row" | wc -l | tr -d ' ')" == "1" ]] ||
  die "candidate branch lookup was ambiguous"
read -r remote_sha remote_ref extra <<<"$remote_row"
[[ -z "${extra:-}" && "$remote_ref" == "$candidate_ref" ]] || die "candidate branch lookup returned an unexpected ref"
[[ "$remote_sha" == "$candidate_sha" ]] ||
  die "candidate ref tip is $remote_sha, not requested SHA $candidate_sha"

tag_rows="$(git -C "$candidate_dir" ls-remote origin "refs/tags/$tag" "refs/tags/$tag^{}")" ||
  die "could not verify candidate tag absence"
[[ -z "$tag_rows" ]] || die "candidate tag already exists on origin; acceptance signing is forbidden"

printf '[verify-acceptance-candidate-source] ok: %s at %s for %s, control %s\n' \
  "$candidate_ref" "$candidate_sha" "$tag" "$GITHUB_SHA"
