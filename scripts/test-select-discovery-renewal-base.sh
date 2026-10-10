#!/usr/bin/env bash
# Fail-closed checks for the freshness-only renewal base/ceiling selector.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
selector="$root/scripts/select-discovery-renewal-base.py"
work="$(mktemp -d "${TMPDIR:-/tmp}/select-renewal-base.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  printf '[test-select-discovery-renewal-base] ERROR: %s\n' "$*" >&2
  exit 1
}

# Build a one-page releases listing from "seq:draft:prerelease:immutable:assets"
# specs (assets=1 includes the three discovery assets, 0 omits them).
write_releases() {
  local path="$1"
  shift
  python3 - "$path" "$@" <<'PY'
import json
import pathlib
import sys

path = sys.argv[1]
assets = [
    {"name": "compatibility-artifact-index.json"},
    {"name": "macprovider-release-discovery.json"},
    {"name": "macprovider-release-discovery.json.sig"},
]
releases = []
for spec in sys.argv[2:]:
    seq, draft, prerelease, immutable, has_assets = spec.split(":")
    releases.append({
        "tag_name": f"release-discovery-v1-{seq}",
        "draft": draft == "1",
        "prerelease": prerelease == "1",
        "immutable": immutable == "1",
        "assets": assets if has_assets == "1" else [],
    })
pathlib.Path(path).write_text(json.dumps([releases]), encoding="utf-8")
PY
}

write_tags() {
  local path="$1"
  shift
  : > "$path"
  for seq in "$@"; do
    printf 'deadbeef\trefs/tags/release-discovery-v1-%s\n' "$seq" >> "$path"
  done
}

expect_reject() {
  local label="$1"
  shift
  if "$@" >"$work/$label.out" 2>&1; then
    fail "$label was accepted: $(cat "$work/$label.out")"
  fi
}

# 1) Divergent-latest normal case: the public head IS the ceiling; renew ceil+1.
write_releases "$work/normal.json" "2176955688681473:0:1:1:1"
write_tags "$work/empty-tags.txt"
result="$(python3 "$selector" "$work/normal.json" "$work/empty-tags.txt")"
[[ "$result" == "2176955688681473 release-discovery-v1-2176955688681473 2176955688681474" ]] \
  || fail "normal renewal did not resolve ceil+1: '$result'"

# 2) A same-sequence git tag alongside the public release is fine (ceiling==head).
write_tags "$work/same-tag.txt" 2176955688681473
result="$(python3 "$selector" "$work/normal.json" "$work/same-tag.txt")"
[[ "$result" == "2176955688681473 release-discovery-v1-2176955688681473 2176955688681474" ]] \
  || fail "same-sequence tag changed selection: '$result'"

# 3) DOMINATION GUARD: a higher-sequence DRAFT (pending rollout of a newer
#    target) above the public head must fail closed, not mint ceiling+1.
write_releases "$work/draft.json" \
  "2176955688681473:0:1:1:1" "2186103947198465:1:1:0:1"
expect_reject draft-above python3 "$selector" "$work/draft.json" "$work/empty-tags.txt"
grep -q "higher-sequence discovery signal exists above the current public head" \
  "$work/draft-above.out" || fail "draft-above did not report the domination guard"

# 4) COLLISION/GUARD: a higher-sequence ORPHAN git tag (no release) must fail closed.
write_tags "$work/orphan-tag.txt" 2186103947198465
expect_reject orphan-tag python3 "$selector" "$work/normal.json" "$work/orphan-tag.txt"

# 5) No public immutable transport (only a draft) must fail closed.
write_releases "$work/draft-only.json" "2176955688681473:1:1:0:1"
expect_reject no-public python3 "$selector" "$work/draft-only.json" "$work/empty-tags.txt"

# 6) A public release missing the discovery assets is not a valid base.
write_releases "$work/no-assets.json" "2176955688681473:0:1:1:0"
expect_reject no-assets python3 "$selector" "$work/no-assets.json" "$work/empty-tags.txt"

# 7) No transports at all must fail closed.
printf '[[]]\n' > "$work/none.json"
expect_reject none python3 "$selector" "$work/none.json" "$work/empty-tags.txt"

# 8) A PEELED (^{}) higher orphan tag must be counted (annotated-tag refs), so it
#    trips the domination guard exactly like an unpeeled ref.
printf 'deadbeef\trefs/tags/release-discovery-v1-2186103947198465^{}\n' > "$work/peeled-tag.txt"
expect_reject peeled-tag python3 "$selector" "$work/normal.json" "$work/peeled-tag.txt"
grep -q "higher-sequence discovery signal exists above the current public head" \
  "$work/peeled-tag.out" || fail "peeled orphan tag was not counted in the ceiling"

# 9) A public head at UINT64_MAX exhausts the append-only sequence space (ceil+1
#    would overflow uint64) and must fail closed.
write_releases "$work/exhausted.json" "18446744073709551615:0:1:1:1"
expect_reject exhausted python3 "$selector" "$work/exhausted.json" "$work/empty-tags.txt"
grep -q "sequence space is exhausted" "$work/exhausted.out" \
  || fail "uint64-exhausted ceiling did not fail closed"

printf '[test-select-discovery-renewal-base] ok: renewal base/ceiling selector fails closed\n'
