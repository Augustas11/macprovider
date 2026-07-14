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
git -C "$work/source" push -q origin "$second":refs/heads/fix/acceptance
git -C "$work/source" push -q origin "$first":refs/heads/fix/drifted-acceptance

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

# A protected acceptance candidate may use the exact selected branch head and
# an absent tag, but the production mode must never inherit that relaxation.
(
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/fix/acceptance \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.4 "$second" "$work/remote.git" \
      --allow-absent --acceptance-candidate refs/heads/fix/acceptance
) | grep -q 'ok: v1.0.4 at reviewed refs/heads/fix/acceptance'
if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/fix/acceptance \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.4 "$second" "$work/remote.git" \
      --allow-absent --production refs/heads/fix/acceptance
) >"$work/production-branch.out" 2>&1; then
  echo "production release source guard accepted branch mode" >&2
  exit 1
fi
grep -q 'release dispatch must select refs/heads/main' "$work/production-branch.out"
if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/fix/drifted-acceptance \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.4 "$second" "$work/remote.git" \
      --allow-absent --acceptance-candidate refs/heads/fix/drifted-acceptance
) >"$work/acceptance-ref-drift.out" 2>&1; then
  echo "acceptance-candidate source guard accepted ref drift" >&2
  exit 1
fi
grep -q 'acceptance-candidate commit is not the fresh selected branch tip' \
  "$work/acceptance-ref-drift.out"
if (
  cd "$work/source"
  GITHUB_EVENT_NAME=workflow_dispatch \
    GITHUB_REF=refs/heads/fix/acceptance \
    GITHUB_SHA="$second" \
    bash "$source_guard" v1.0.4 "$second" "$work/remote.git" \
      --require-existing --acceptance-candidate refs/heads/fix/acceptance
) >"$work/acceptance-tag-policy.out" 2>&1; then
  echo "acceptance-candidate source guard accepted strict tag policy" >&2
  exit 1
fi
grep -q 'acceptance-candidate source verification must allow an absent tag' \
  "$work/acceptance-tag-policy.out"

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

echo "release tag target regression checks passed"
