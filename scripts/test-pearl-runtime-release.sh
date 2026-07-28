#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="$repo_root/scripts/verify-pearl-runtime-release.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/pearl-runtime-release-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

bash -n "$guard"

git init --bare -q "$work/remote.git"
git init -q "$work/source"
git -C "$work/source" config user.name pearl-runtime-release-test
git -C "$work/source" config user.email pearl-runtime-release-test@example.invalid
printf '%s\n' one > "$work/source/value"
git -C "$work/source" add value
git -C "$work/source" commit -qm one
first="$(git -C "$work/source" rev-parse HEAD)"
printf '%s\n' two > "$work/source/value"
git -C "$work/source" commit -qam two
second="$(git -C "$work/source" rev-parse HEAD)"
git -C "$work/source" remote add origin "$work/remote.git"
git -C "$work/source" push -q origin HEAD:refs/heads/main
git -C "$work/source" tag v1.8.66 "$second"
git -C "$work/source" push -q origin refs/tags/v1.8.66

make_release_dir() {
  local directory="$1"
  local tag="$2"
  local commit="$3"
  rm -rf "$directory"
  mkdir -p "$directory"
  printf '%s\n' coordinator > "$directory/coordinator-linux-amd64"
  printf '%s\n' coordinator-cli > "$directory/coordinator-cli-linux-amd64"
  printf '%s\n' gateway > "$directory/gateway-linux-amd64"
  printf '%s\n' signed-metadata > "$directory/pearl-release.json.sig"
  printf '%s\n' signed-checksums > "$directory/checksums.txt.sig"
  printf '%s\n' catalog-release > "$directory/release.json"
  printf '%s\n' trusted-keys > "$directory/trusted-keys.json"
  printf '%s\n' tier2-catalog > "$directory/tier2-catalog.json"
  printf '%s\n' autotune-candidates > "$directory/autotune-candidates.json"
  printf '%s\n' autotune-candidates-sig > "$directory/autotune-candidates.json.sig"
  printf '%s\n' demand-rank > "$directory/demand-rank.json"
  printf '%s\n' demand-rank-sig > "$directory/demand-rank.json.sig"
  python3 - "$directory" "$tag" "$commit" <<'PY'
import hashlib
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
tag = sys.argv[2]
commit = sys.argv[3]
version = tag.removeprefix("v")

def digest(name: str) -> str:
    return hashlib.sha256((directory / name).read_bytes()).hexdigest()

metadata = {
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "release_version": version,
    "commit": commit,
    "architecture": "linux-amd64",
    "provider_advertised_version": version,
    "components": {
        "coordinator": {
            "asset": "coordinator-linux-amd64",
            "sha256": digest("coordinator-linux-amd64"),
            "embedded_version": tag,
        },
        "gateway": {
            "asset": "gateway-linux-amd64",
            "sha256": digest("gateway-linux-amd64"),
            "embedded_version": tag,
        },
    },
    "catalog": {
        "release_id": "test-release",
        "policy_version": "test-policy",
        "files": {
            "release.json": digest("release.json"),
            "trusted-keys.json": digest("trusted-keys.json"),
            "tier2-catalog.json": digest("tier2-catalog.json"),
            "autotune-candidates.json": digest("autotune-candidates.json"),
            "autotune-candidates.json.sig": digest("autotune-candidates.json.sig"),
            "demand-rank.json": digest("demand-rank.json"),
            "demand-rank.json.sig": digest("demand-rank.json.sig"),
        },
    },
}
(directory / "pearl-release.json").write_text(
    json.dumps(metadata, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
checksums = []
for path in sorted(directory.iterdir()):
    if path.name == "checksums.txt":
        continue
    checksums.append(f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n")
(directory / "checksums.txt").write_text("".join(checksums), encoding="utf-8")
PY
}

make_release_dir "$work/release-ok" v1.8.66 "$second"
bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-ok" |
  grep -q 'ok: v1.8.66 has Pearl runtime assets'

if bash "$guard" --tag v1.8.65 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-ok" \
  >"$work/absent-tag.out" 2>&1; then
  fail "accepted a release whose required tag is absent"
fi
grep -q 'release tag v1.8.65 is absent' "$work/absent-tag.out"

git -C "$work/source" tag v1.8.67 "$first"
git -C "$work/source" push -q origin refs/tags/v1.8.67
make_release_dir "$work/release-wrong-tag-target" v1.8.67 "$second"
if bash "$guard" --tag v1.8.67 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-wrong-tag-target" \
  >"$work/tag-drift.out" 2>&1; then
  fail "accepted a release whose tag targets a different commit"
fi
grep -q "targets $first; refusing assets built from $second" "$work/tag-drift.out"

make_release_dir "$work/release-missing-asset" v1.8.66 "$second"
rm "$work/release-missing-asset/gateway-linux-amd64"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-missing-asset" \
  >"$work/missing-asset.out" 2>&1; then
  fail "accepted a release missing a Pearl runtime asset"
fi
grep -q 'missing Pearl runtime release asset(s): gateway-linux-amd64' "$work/missing-asset.out"

make_release_dir "$work/release-wrong-metadata-commit" v1.8.66 "$first"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-wrong-metadata-commit" \
  >"$work/metadata-commit.out" 2>&1; then
  fail "accepted release metadata for the wrong commit"
fi
grep -q "pearl-release.json commit is '$first', expected '$second'" "$work/metadata-commit.out"

make_release_dir "$work/release-bad-digest" v1.8.66 "$second"
printf '%s\n' tampered > "$work/release-bad-digest/coordinator-linux-amd64"
if bash "$guard" --tag v1.8.66 --expected-commit "$second" \
  --remote "$work/remote.git" --release-dir "$work/release-bad-digest" \
  >"$work/bad-digest.out" 2>&1; then
  fail "accepted a runtime binary whose digest no longer matches metadata"
fi
grep -q 'coordinator-linux-amd64 sha256 does not match pearl-release.json' "$work/bad-digest.out"

echo "PASS: Pearl runtime release preflight fails closed on missing assets and source drift"
