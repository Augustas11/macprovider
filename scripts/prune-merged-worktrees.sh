#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: scripts/prune-merged-worktrees.sh [--apply] [--base REF] [--strict] [--delete-branches]

Dry-run by default. Removes only registered, clean MacProvider task worktrees
whose HEAD is already contained in REF, or patch-equivalent to REF unless
--strict is used.

Options:
  --apply            Actually remove eligible worktrees. Without this, print what would happen.
  --base REF         Compare against REF. Default: origin/main.
  --strict           Require HEAD to be an ancestor of REF; do not accept patch equivalence.
  --delete-branches  After removing a worktree, run safe `git branch -d` for its local branch.
  -h, --help         Show this help.
USAGE
}

apply=false
base=origin/main
allow_patch_equivalent=true
delete_branches=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply)
      apply=true
      ;;
    --base)
      [[ $# -ge 2 ]] || { echo "missing value for --base" >&2; exit 2; }
      base="$2"
      shift
      ;;
    --strict)
      allow_patch_equivalent=false
      ;;
    --delete-branches)
      delete_branches=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

repo_root="$(git rev-parse --show-toplevel)"
canonical_root="/Users/augstar/macprovider-poc"
git rev-parse --verify --quiet "$base" >/dev/null || {
  echo "base ref does not exist: $base" >&2
  exit 2
}

is_managed_task_path() {
  local path="$1"
  case "$path" in
    /Users/augstar/macprovider-*|/private/tmp/macprovider-*|/Users/augstar/.codex/worktrees/macprovider/*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

short_branch_name() {
  local ref="$1"
  if [[ "$ref" == refs/heads/* ]]; then
    printf '%s\n' "${ref#refs/heads/}"
  else
    printf '%s\n' ""
  fi
}

worktree_size() {
  du -sh "$1" 2>/dev/null | awk '{print $1}'
}

worktree_kib() {
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

has_clean_status() {
  [[ -z "$(git -C "$1" status --porcelain=v1)" ]]
}

is_patch_equivalent() {
  local head="$1"
  local cherry
  cherry="$(git cherry "$base" "$head")"
  [[ -n "$cherry" ]] && ! grep -q '^+' <<<"$cherry"
}

eligible_reason() {
  local head="$1"
  if git merge-base --is-ancestor "$head" "$base"; then
    printf '%s\n' "ancestor-of-$base"
    return 0
  fi
  if [[ "$allow_patch_equivalent" == true ]] && is_patch_equivalent "$head"; then
    printf '%s\n' "patch-equivalent-to-$base"
    return 0
  fi
  return 1
}

removed=0
skipped=0
eligible_kib=0
path=""
head=""
branch_ref=""

process_worktree() {
  [[ -n "$path" ]] || return 0

  local reason size kib branch_name
  branch_name="$(short_branch_name "$branch_ref")"
  size="$(worktree_size "$path")"
  kib="$(worktree_kib "$path")"

  if [[ "$path" == "$repo_root" || "$path" == "$canonical_root" || "$branch_name" == "main" ]]; then
    printf 'skip canonical\t%s\n' "$path"
    skipped=$((skipped + 1))
    return 0
  fi

  if ! is_managed_task_path "$path"; then
    printf 'skip outside-managed-roots\t%s\n' "$path"
    skipped=$((skipped + 1))
    return 0
  fi

  if ! has_clean_status "$path"; then
    printf 'skip dirty\t%s\t%s\t%s\n' "${size:-?}" "${branch_name:-detached}" "$path"
    skipped=$((skipped + 1))
    return 0
  fi

  if ! reason="$(eligible_reason "$head")"; then
    printf 'skip unmerged\t%s\t%s\t%s\n' "${size:-?}" "${branch_name:-detached}" "$path"
    skipped=$((skipped + 1))
    return 0
  fi

  if [[ "$apply" == true ]]; then
    printf 'remove %s\t%s\t%s\t%s\n' "$reason" "${size:-?}" "${branch_name:-detached}" "$path"
    git worktree remove "$path"
    if [[ "$delete_branches" == true && -n "$branch_name" ]]; then
      git branch -d "$branch_name" || true
    fi
  else
    printf 'would-remove %s\t%s\t%s\t%s\n' "$reason" "${size:-?}" "${branch_name:-detached}" "$path"
  fi
  removed=$((removed + 1))
  if [[ "$kib" =~ ^[0-9]+$ ]]; then
    eligible_kib=$((eligible_kib + kib))
  fi
}

while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ -z "$line" ]]; then
    process_worktree
    path=""
    head=""
    branch_ref=""
    continue
  fi

  case "$line" in
    worktree\ *)
      path="${line#worktree }"
      ;;
    HEAD\ *)
      head="${line#HEAD }"
      ;;
    branch\ *)
      branch_ref="${line#branch }"
      ;;
  esac
done < <(git worktree list --porcelain)
process_worktree

if [[ "$apply" == true ]]; then
  git worktree prune
fi

printf 'summary eligible=%d skipped=%d eligible_gib=%.1f mode=%s base=%s\n' "$removed" "$skipped" "$(awk -v kib="$eligible_kib" 'BEGIN { printf "%.1f", kib / 1024 / 1024 }')" "$([[ "$apply" == true ]] && echo apply || echo dry-run)" "$base"
