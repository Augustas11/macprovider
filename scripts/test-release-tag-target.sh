#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/verify-release-tag-target.sh"
source_guard="$repo_root/scripts/verify-release-source.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/release-tag-target.XXXXXX")"
trap 'rm -rf "$work"' EXIT

git init --bare -q "$work/remote.git"
git init -q "$work/source"
git -C "$work/source" config user.name release-test
git -C "$work/source" config user.email release-test@example.invalid
printf '%s\n' one > "$work/source/value"
git -C "$work/source" add value
git -C "$work/source" commit -qm one
first="$(git -C "$work/source" rev-parse HEAD)"
printf '%s\n' two > "$work/source/value"
git -C "$work/source" commit -qam two
second="$(git -C "$work/source" rev-parse HEAD)"
git -C "$work/source" remote add origin "$work/remote.git"
git -C "$work/source" push -q origin HEAD:refs/heads/main

bash "$guard" v1.0.0 "$second" "$work/remote.git" --allow-absent | grep -q 'is absent and may be created'
set +e
bash "$guard" v1.0.0 "$second" "$work/remote.git" >"$work/absent.out" 2>&1
absent_status=$?
set -e
if [[ "$absent_status" -eq 0 ]]; then
  echo "tag target guard accepted an absent required tag" >&2
  exit 1
fi
[[ "$absent_status" -eq 3 ]] || {
  echo "tag target guard did not distinguish an absent required tag" >&2
  exit 1
}
grep -q 'release tag v1.0.0 is absent' "$work/absent.out"
if bash "$guard" v1.0.0 "$second" "$work/remote.git" --invalid-policy >"$work/policy.out" 2>&1; then
  echo "tag target guard accepted an invalid absence policy" >&2
  exit 1
fi
grep -q 'absence policy must be --allow-absent or --require-existing' "$work/policy.out"

if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.0 "$second" "$work/remote.git"
) >"$work/source-absent.out" 2>&1; then
  echo "strict release source guard accepted an absent tag" >&2
  exit 1
fi
grep -q 'release tag v1.0.0 is absent' "$work/source-absent.out"
(
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.0 "$second" "$work/remote.git" --allow-absent
) | grep -q 'ok: v1.0.0 at reviewed origin/main'

git -C "$work/source" tag v1.0.0 "$second"
git -C "$work/source" push -q origin refs/tags/v1.0.0
bash "$guard" v1.0.0 "$second" "$work/remote.git" | grep -q 'already targets build commit'
if bash "$guard" v1.0.0 "$first" "$work/remote.git" >"$work/lightweight-drift.out" 2>&1; then
  echo "tag target guard accepted a lightweight tag on the wrong commit" >&2
  exit 1
fi
grep -q "targets $second; refusing assets built from $first" "$work/lightweight-drift.out"

git -C "$work/source" tag v1.0.3 "$first"
git -C "$work/source" push -q origin refs/tags/v1.0.3
if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.3 "$second" "$work/remote.git" --allow-absent
) >"$work/candidate-tag-drift.out" 2>&1; then
  echo "candidate release source guard accepted an existing tag on the wrong commit" >&2
  exit 1
fi
grep -q "targets $first; refusing assets built from $second" "$work/candidate-tag-drift.out"

git -C "$work/source" tag -a v1.0.1 -m v1.0.1 "$first"
git -C "$work/source" push -q origin refs/tags/v1.0.1
bash "$guard" v1.0.1 "$first" "$work/remote.git" | grep -q 'already targets build commit'
if bash "$guard" v1.0.1 "$second" "$work/remote.git" >"$work/annotated-drift.out" 2>&1; then
  echo "tag target guard accepted an annotated tag on the wrong commit" >&2
  exit 1
fi
grep -q "targets $first; refusing assets built from $second" "$work/annotated-drift.out"

(
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.0 "$second" "$work/remote.git"
)

# A draft may exist for minutes before publication. A protected-tag race must
# still be caught by the repeated source gate immediately before draft=false.
git -C "$work/source" tag v1.0.2 "$second"
git -C "$work/source" push -q origin refs/tags/v1.0.2
(
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.2 "$second" "$work/remote.git"
)
git -C "$work/source" tag -f v1.0.2 "$first" >/dev/null
git -C "$work/source" push -q --force origin refs/tags/v1.0.2
if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.2 "$second" "$work/remote.git"
) >"$work/tag-race.out" 2>&1; then
  echo "final release source gate accepted a tag changed after draft verification" >&2
  exit 1
fi
grep -q "targets $first; refusing assets built from $second" "$work/tag-race.out"

if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/release \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.0 "$second" "$work/remote.git"
) >"$work/wrong-ref.out" 2>&1; then
  echo "release source guard accepted a non-main dispatch" >&2
  exit 1
fi
grep -q 'release dispatch must select refs/heads/main' "$work/wrong-ref.out"

if (
  cd "$work/source"
  GITHUB_EVENT_NAME=push \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.0 "$second" "$work/remote.git"
) >"$work/wrong-event.out" 2>&1; then
  echo "release source guard accepted a push event" >&2
  exit 1
fi
grep -q 'must be manually dispatched' "$work/wrong-event.out"

printf '%s\n' three > "$work/source/value"
git -C "$work/source" commit -qam three
third="$(git -C "$work/source" rev-parse HEAD)"
if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$third" \
    bash "$source_guard" v1.0.0 "$third" "$work/remote.git" --allow-absent
) >"$work/stale-main.out" 2>&1; then
  echo "release source guard accepted a commit not freshly equal to origin/main" >&2
  exit 1
fi
grep -q 'candidate release commit is not the fresh origin/main tip' "$work/stale-main.out"

# Once the exact immutable tag exists, protected publication may finish from
# the captured reviewed commit even if unrelated main commits land while the
# environment review, signing, or notarization is in progress.
git -C "$work/source" push -q origin HEAD:refs/heads/main
git -C "$work/source" checkout -q --detach "$second"
(
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.0 "$second" "$work/remote.git" --require-existing
) | grep -q 'ok: v1.0.0 at reviewed origin/main'

# The frozen v1.8.39 pre-publication recovery is a one-time compare-and-swap:
# stale leases cannot delete, the exact old object can be retired, candidate
# mode accepts the absent ref, and only an expected-absent lease may recreate
# the signed annotated tag at the fresh reviewed commit.
git -C "$work/source" tag -a v1.0.4 -m old-unpublished-v1.0.4 "$first"
old_recovery_object="$(git -C "$work/source" rev-parse refs/tags/v1.0.4)"
git -C "$work/source" push -q origin refs/tags/v1.0.4
if git -C "$work/source" push -q \
  --force-with-lease="refs/tags/v1.0.4:$second" \
  origin :refs/tags/v1.0.4 >"$work/stale-delete.out" 2>&1; then
  echo "pre-publication recovery deleted a tag through a stale lease" >&2
  exit 1
fi
[[ "$(git ls-remote "$work/remote.git" refs/tags/v1.0.4 | awk '{print $1}')" == \
  "$old_recovery_object" ]] || {
  echo "stale deletion lease changed the remote tag" >&2
  exit 1
}
git -C "$work/source" push -q \
  --force-with-lease="refs/tags/v1.0.4:$old_recovery_object" \
  origin :refs/tags/v1.0.4
[[ -z "$(git ls-remote "$work/remote.git" refs/tags/v1.0.4 'refs/tags/v1.0.4^{}')" ]] || {
  echo "exact-object recovery deletion did not remove the tag" >&2
  exit 1
}

git -C "$work/source" checkout -q --detach "$third"
(
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/main \
    GITHUB_SHA="$third" \
    bash "$source_guard" v1.0.4 "$third" "$work/remote.git" --allow-absent
) | grep -q 'ok: v1.0.4 at reviewed origin/main'

git -C "$work/source" tag -d v1.0.4 >/dev/null
git -C "$work/source" tag -a v1.0.4 -m replacement-v1.0.4 "$third"
new_recovery_object="$(git -C "$work/source" rev-parse refs/tags/v1.0.4)"
[[ "$new_recovery_object" != "$old_recovery_object" ]]
git -C "$work/source" push -q \
  --force-with-lease='refs/tags/v1.0.4:' \
  origin refs/tags/v1.0.4
[[ "$(git ls-remote "$work/remote.git" refs/tags/v1.0.4 | awk '{print $1}')" == \
  "$new_recovery_object" ]]
[[ "$(git ls-remote "$work/remote.git" 'refs/tags/v1.0.4^{}' | awk '{print $1}')" == \
  "$third" ]]
bash "$guard" v1.0.4 "$third" "$work/remote.git" | \
  grep -q 'already targets build commit'
if bash "$guard" v1.0.4 "$first" "$work/remote.git" \
  >"$work/recovery-old-target.out" 2>&1; then
  echo "strict source guard accepted the retired tag target" >&2
  exit 1
fi
grep -q "targets $third; refusing assets built from $first" \
  "$work/recovery-old-target.out"
if git -C "$work/source" push -q \
  --force-with-lease="refs/tags/v1.0.4:$old_recovery_object" \
  origin :refs/tags/v1.0.4 >"$work/reused-delete.out" 2>&1; then
  echo "pre-publication recovery reused the consumed deletion lease" >&2
  exit 1
fi
[[ "$(git ls-remote "$work/remote.git" refs/tags/v1.0.4 | awk '{print $1}')" == \
  "$new_recovery_object" ]] || {
  echo "consumed deletion lease changed the replacement tag" >&2
  exit 1
}

echo "release tag target regression checks passed"
