#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
recovery="$root/scripts/recover-malibu-publication.sh"
capture="$root/scripts/capture-release-publication.py"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n "$recovery"
work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-recovery-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fixture="$work/fixture"
mock_bin="$work/bin"
named_assets="$work/named-assets"
api_assets="$work/api-assets"
mkdir -p "$fixture/scripts" "$mock_bin" "$named_assets" "$api_assets" "$work/home/.ssh"
cp "$recovery" "$fixture/scripts/recover-malibu-publication.sh"
cp "$capture" "$fixture/scripts/capture-release-publication.py"

commit=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
release_id=701
release_json="$work/release.json"
python3 - "$named_assets" "$api_assets" "$release_json" "$commit" "$release_id" <<'PY'
import hashlib
import json
import pathlib
import sys

named, api, release_path = map(pathlib.Path, sys.argv[1:4])
commit, release_id = sys.argv[4], int(sys.argv[5])
tag = "v1.8.39"
base = {
    f"Malibu-{tag}.dmg": b"signed notarized dmg bytes\n",
    "appcast.xml": b"signed Sparkle appcast bytes\n",
    "compatibility-artifact-index.json": b'{"schema_version":1}\n',
}
for name, content in base.items():
    (named / name).write_bytes(content)
signed_assets = {
    name: hashlib.sha256(content).hexdigest() for name, content in base.items()
}
provenance = {
    "schema_version": 1,
    "repository": "Augustas11/macprovider",
    "tag": tag,
    "commit": commit,
    "prerelease": False,
    "toolchain": {},
    "assets": signed_assets,
}
(named / "release-provenance.json").write_text(
    json.dumps(provenance, sort_keys=True, separators=(",", ":")) + "\n",
    encoding="utf-8",
)
checksum_names = [*base, "release-provenance.json"]
(named / "checksums.txt").write_text(
    "".join(
        f"{hashlib.sha256((named / name).read_bytes()).hexdigest()}  {name}\n"
        for name in checksum_names
    ),
    encoding="utf-8",
)
(named / "checksums.txt.sig").write_bytes(b"captured signature bytes\n")

ordered = [
    f"Malibu-{tag}.dmg",
    "appcast.xml",
    "compatibility-artifact-index.json",
    "checksums.txt",
    "checksums.txt.sig",
    "release-provenance.json",
]
assets = []
for asset_id, name in enumerate(ordered, 801):
    content = (named / name).read_bytes()
    (api / str(asset_id)).write_bytes(content)
    assets.append(
        {
            "id": asset_id,
            "name": name,
            "state": "uploaded",
            "digest": f"sha256:{hashlib.sha256(content).hexdigest()}",
        }
    )
release = {
    "id": release_id,
    "tag_name": tag,
    "target_commitish": commit,
    "draft": False,
    "immutable": True,
    "prerelease": False,
    "name": f"macprovider-cli {tag}",
    "assets": assets,
}
release_path.write_text(json.dumps(release), encoding="utf-8")
PY

cat >"$fixture/scripts/verify-release-tag-target.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 4 ]]
[[ "$1" == v1.8.39 ]]
[[ "$2" == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]
[[ "$3" == origin && "$4" == --require-existing ]]
printf '%s\n' verified >"$MOCK_TAG_MARKER"
SH

cat >"$fixture/scripts/publish-malibu-latest-dmg.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "$#" == 7 ]]
python3 - "$@" <<'PY'
import json
import pathlib
import sys

manifest_path, dmg, appcast, index, checksums, signature, provenance = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
assert manifest["release_id"] == 701
assert manifest["tag"] == "v1.8.39"
assert manifest["commit"] == "a" * 40
assert [path.name for path in (dmg, appcast, index, checksums, signature, provenance)] == [
    "Malibu-v1.8.39.dmg",
    "appcast.xml",
    "compatibility-artifact-index.json",
    "checksums.txt",
    "checksums.txt.sig",
    "release-provenance.json",
]
assert manifest["assets"]["compatibility-artifact-index.json"]["id"] == 803
PY
printf '%s\n' published >"$MOCK_PUBLISH_MARKER"
SH

cat >"$mock_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == api ]] || exit 90
endpoint="${!#}"
case "$endpoint" in
  repos/Augustas11/macprovider/releases/701)
    count=0
    [[ ! -f "$MOCK_RELEASE_CALL_COUNT" ]] || read -r count <"$MOCK_RELEASE_CALL_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" >"$MOCK_RELEASE_CALL_COUNT"
    source="$MOCK_RELEASE_JSON"
    if [[ "$count" -ge 2 && -n "${MOCK_SECOND_RELEASE_JSON:-}" ]]; then
      source="$MOCK_SECOND_RELEASE_JSON"
    fi
    cat "$source"
    ;;
  repos/Augustas11/macprovider/releases/assets/*)
    cat "$MOCK_ASSET_DIR/${endpoint##*/}"
    ;;
  *)
    printf 'unexpected gh endpoint: %s\n' "$endpoint" >&2
    exit 91
    ;;
esac
SH

cat >"$mock_bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == -C ]]; then
  shift 2
fi
case "${1:-}" in
  status)
    [[ "${MOCK_GIT_DIRTY:-0}" == 0 ]] || printf ' M scripts/recover-malibu-publication.sh\n'
    ;;
  rev-parse)
    [[ "${2:-}" == HEAD ]] || exit 92
    printf '%s\n' "$MOCK_GIT_HEAD"
    ;;
  fetch)
    ;;
  merge-base)
    [[ "${2:-}" == --is-ancestor ]] || exit 93
    ;;
  *)
    printf 'unexpected git command: %s\n' "$*" >&2
    exit 94
    ;;
esac
SH
chmod +x "$mock_bin/gh" "$mock_bin/git"
printf 'test ssh key\n' >"$work/home/.ssh/pearl_operator_ed25519"
chmod 600 "$work/home/.ssh/pearl_operator_ed25519"

run_recovery() (
  selected_release="$1"
  second_release="${2:-}"
  selected_head="${3:-$commit}"
  dirty="${4:-0}"
  selected_repo="${5:-Augustas11/macprovider}"
  selected_assets="${6:-$api_assets}"
  rm -f "$work/release-call-count" "$work/publish.marker" "$work/tag.marker"
  export PATH="$mock_bin:$PATH"
  export GH_TOKEN=test-token
  export GITHUB_REPOSITORY="$selected_repo"
  export HOME="$work/home"
  export MALIBU_DOWNLOAD_SSH_KEY="$work/home/.ssh/pearl_operator_ed25519"
  export MOCK_RELEASE_JSON="$selected_release"
  export MOCK_RELEASE_CALL_COUNT="$work/release-call-count"
  export MOCK_PUBLISH_MARKER="$work/publish.marker"
  export MOCK_TAG_MARKER="$work/tag.marker"
  export MOCK_ASSET_DIR="$selected_assets"
  export MOCK_GIT_HEAD="$selected_head"
  export MOCK_GIT_DIRTY="$dirty"
  if [[ -n "$second_release" ]]; then
    export MOCK_SECOND_RELEASE_JSON="$second_release"
  else
    unset MOCK_SECOND_RELEASE_JSON || true
  fi
  bash "$fixture/scripts/recover-malibu-publication.sh" "$release_id"
)

expect_failure() {
  label="$1"
  expected="$2"
  shift 2
  if run_recovery "$@" >"$work/$label.out" 2>&1; then
    fail "$label was accepted"
  fi
  grep -q "$expected" "$work/$label.out" || {
    cat "$work/$label.out" >&2
    fail "$label did not fail at the expected guard"
  }
  [[ ! -e "$work/publish.marker" ]] || fail "$label reached the publisher"
}

run_recovery "$release_json" >"$work/success.out" 2>&1
grep -q 'immutable release 701 republished to Pearl' "$work/success.out" ||
  fail "successful recovery did not report completion"
[[ -f "$work/publish.marker" && -f "$work/tag.marker" ]] ||
  fail "successful recovery skipped tag verification or publication"

python3 - "$release_json" "$work/release-wrong-tag.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["tag_name"] = "v1.8.40"
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
expect_failure wrong-tag 'frozen to v1.8.39' "$work/release-wrong-tag.json"

python3 - "$release_json" "$work/release-mutable.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["immutable"] = False
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
expect_failure mutable 'numeric release is not immutable' "$work/release-mutable.json"

python3 - "$release_json" "$work/release-missing-index.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["assets"] = [
    row for row in value["assets"]
    if row["name"] != "compatibility-artifact-index.json"
]
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
expect_failure missing-index 'missing required asset: compatibility-artifact-index.json' \
  "$work/release-missing-index.json"

python3 - "$release_json" "$work/release-duplicate-id.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["assets"][1]["id"] = value["assets"][0]["id"]
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
expect_failure duplicate-id 'duplicate asset id' "$work/release-duplicate-id.json"

python3 - "$release_json" "$work/release-drift.json" <<'PY'
import json, pathlib, sys
value = json.loads(pathlib.Path(sys.argv[1]).read_text())
value["assets"][1]["id"] += 100
pathlib.Path(sys.argv[2]).write_text(json.dumps(value))
PY
expect_failure reread-drift 'identity changed while recovery assets were downloaded' \
  "$release_json" "$work/release-drift.json"

tampered_assets="$work/tampered-assets"
cp -R "$api_assets" "$tampered_assets"
printf 'tampered dmg bytes\n' >"$tampered_assets/801"
expect_failure tampered-download 'GitHub digest differs from captured workflow asset' \
  "$release_json" '' "$commit" 0 Augustas11/macprovider "$tampered_assets"

expect_failure wrong-head 'exact release commit' \
  "$release_json" '' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
expect_failure dirty-worktree 'tracked or staged changes' \
  "$release_json" '' "$commit" 1
expect_failure wrong-repository 'restricted to Augustas11/macprovider' \
  "$release_json" '' "$commit" 0 attacker/example

echo 'Malibu publication recovery regression checks passed'
