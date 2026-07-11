#!/usr/bin/env bash
set -euo pipefail

tag="${1:-}"
expected_commit="${2:-}"
remote="${3:-origin}"
absence_policy="${4:---require-existing}"

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "usage: $0 vX.Y.Z EXPECTED_COMMIT [REMOTE]" >&2
  exit 2
}
[[ "$expected_commit" =~ ^[0-9a-f]{40}$ ]] || {
  echo "expected commit must be a full lowercase commit SHA" >&2
  exit 2
}
[[ "$absence_policy" == "--allow-absent" || "$absence_policy" == "--require-existing" ]] || {
  echo "absence policy must be --allow-absent or --require-existing" >&2
  exit 2
}

rows="$(git ls-remote "$remote" "refs/tags/$tag" "refs/tags/$tag^{}")"
tag_object="$(printf '%s\n' "$rows" | awk -v ref="refs/tags/$tag" '$2 == ref { print $1 }')"
peeled_commit="$(printf '%s\n' "$rows" | awk -v ref="refs/tags/$tag^{}" '$2 == ref { print $1 }')"

tag_count="$(printf '%s\n' "$tag_object" | awk 'NF { count++ } END { print count + 0 }')"
peeled_count="$(printf '%s\n' "$peeled_commit" | awk 'NF { count++ } END { print count + 0 }')"
if [[ "$tag_count" -gt 1 || "$peeled_count" -gt 1 ]]; then
  echo "remote returned ambiguous refs for $tag" >&2
  exit 1
fi

if [[ -z "$tag_object" ]]; then
  if [[ "$absence_policy" == "--require-existing" ]]; then
    echo "release tag $tag is absent" >&2
    exit 3
  fi
  echo "release tag $tag is absent and may be created at $expected_commit"
  exit 0
fi

actual_commit="${peeled_commit:-$tag_object}"
if [[ "$actual_commit" != "$expected_commit" ]]; then
  echo "release tag $tag targets $actual_commit; refusing assets built from $expected_commit" >&2
  exit 1
fi

echo "release tag $tag already targets build commit $expected_commit"
