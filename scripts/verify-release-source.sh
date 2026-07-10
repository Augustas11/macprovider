#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-release-source] ERROR: %s\n' "$*" >&2
  exit 1
}

tag="${1:-}"
expected_commit="${2:-}"
remote="${3:-origin}"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be vX.Y.Z"
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || die "expected commit must be a full lowercase SHA"
[[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]] || die "releases must be manually dispatched"
[[ "${GITHUB_REF:-}" == "refs/heads/main" ]] || die "release dispatch must select refs/heads/main"
[[ "${GITHUB_SHA:-}" == "$expected_commit" ]] || die "GITHUB_SHA does not match the reviewed release commit"

git fetch --quiet --no-tags "$remote" \
  refs/heads/main:refs/remotes/origin/main || die "could not refresh origin/main"

head_commit="$(git rev-parse HEAD)"
main_commit="$(git rev-parse refs/remotes/origin/main)"
[[ "$head_commit" == "$expected_commit" ]] || die "checked-out HEAD differs from the reviewed release commit"
[[ "$main_commit" == "$expected_commit" ]] || die "reviewed release commit is not the fresh origin/main tip"
git merge-base --is-ancestor "$expected_commit" refs/remotes/origin/main ||
  die "reviewed release commit is not reachable from origin/main"

bash "$(dirname "$0")/verify-release-tag-target.sh" \
  "$tag" "$expected_commit" "$remote" --require-existing

printf '[verify-release-source] ok: %s at reviewed origin/main %s\n' "$tag" "$expected_commit"
