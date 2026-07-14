#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-release-source] ERROR: %s\n' "$*" >&2
  exit 1
}

tag="${1:-}"
expected_commit="${2:-}"
remote="${3:-origin}"
absence_policy="${4:---require-existing}"
source_mode="${5:---production}"
source_ref="${6:-${GITHUB_REF:-}}"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be vX.Y.Z"
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || die "expected commit must be a full lowercase SHA"
[[ "$absence_policy" == "--allow-absent" || "$absence_policy" == "--require-existing" ]] ||
  die "absence policy must be --allow-absent or --require-existing"
[[ "$source_mode" == "--production" || "$source_mode" == "--acceptance-candidate" ]] ||
  die "source mode must be --production or --acceptance-candidate"
[[ "${GITHUB_EVENT_NAME:-}" == "workflow_dispatch" ]] || die "releases must be manually dispatched"
[[ "${GITHUB_SHA:-}" == "$expected_commit" ]] || die "GITHUB_SHA does not match the reviewed release commit"

head_commit="$(git rev-parse HEAD)"
[[ "$head_commit" == "$expected_commit" ]] || die "checked-out HEAD differs from the reviewed release commit"

case "$source_mode" in
  --production)
    [[ "$source_ref" == "refs/heads/main" ]] || die "release dispatch must select refs/heads/main"
    [[ "${GITHUB_REF:-}" == "$source_ref" ]] || die "GITHUB_REF does not match the selected production source"
    git fetch --quiet --no-tags "$remote" \
      +refs/heads/main:refs/remotes/origin/main || die "could not refresh origin/main"
    main_commit="$(git rev-parse refs/remotes/origin/main)"
    if [[ "$absence_policy" == "--allow-absent" ]]; then
      [[ "$main_commit" == "$expected_commit" ]] ||
        die "candidate release commit is not the fresh origin/main tip"
    else
      git merge-base --is-ancestor "$expected_commit" refs/remotes/origin/main ||
        die "tagged release commit is not reachable from fresh origin/main"
    fi
    source_description="reviewed origin/main"
    ;;
  --acceptance-candidate)
    [[ "$absence_policy" == "--allow-absent" ]] ||
      die "acceptance-candidate source verification must allow an absent tag"
    [[ "$source_ref" == refs/heads/* ]] ||
      die "acceptance-candidate dispatch must select a branch ref"
    [[ "${GITHUB_REF:-}" == "$source_ref" ]] ||
      die "GITHUB_REF does not match the selected acceptance-candidate source"
    source_branch="${source_ref#refs/heads/}"
    git check-ref-format --branch "$source_branch" >/dev/null 2>&1 ||
      die "acceptance-candidate source branch is invalid"
    fetched_ref="refs/remotes/release-source/acceptance-candidate"
    git fetch --quiet --no-tags "$remote" \
      "+$source_ref:$fetched_ref" || die "could not refresh selected acceptance-candidate branch"
    selected_commit="$(git rev-parse "$fetched_ref")"
    [[ "$selected_commit" == "$expected_commit" ]] ||
      die "acceptance-candidate commit is not the fresh selected branch tip"
    source_description="reviewed $source_ref"
    ;;
esac

bash "$(dirname "$0")/verify-release-tag-target.sh" \
  "$tag" "$expected_commit" "$remote" "$absence_policy"

printf '[verify-release-source] ok: %s at %s %s\n' "$tag" "$source_description" "$expected_commit"
