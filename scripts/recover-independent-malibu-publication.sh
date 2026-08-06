#!/usr/bin/env bash
# Recover only the post-GitHub Pearl publication for an independent Malibu release.
set -euo pipefail

die() {
  printf '[recover-independent-malibu-publication] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 ]] || die "usage: RELEASE_ID"
release_id="$1"
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || die "release id must be numeric"
repo="${REPO:-Augustas11/macprovider}"
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repository must be owner/name"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN is required"

script_dir="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-independent-publication-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT

release_json="$work/release.json"
manifest="$work/publication-manifest.json"
asset_dir="$work/assets"
mkdir -p "$asset_dir"

gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
  "repos/$repo/releases/$release_id" > "$release_json"

identity="$(
  python3 - "$release_json" "$release_id" "$repo" <<'PY'
import json
import pathlib
import re
import sys

release_path, release_id, repo = sys.argv[1:]
release = json.loads(pathlib.Path(release_path).read_text(encoding="utf-8"))
tag = release.get("tag_name")
commit = release.get("target_commitish")
if release.get("id") != int(release_id):
    raise SystemExit("release id mismatch")
if release.get("draft") is not False or release.get("prerelease") is not False:
    raise SystemExit("release must be public stable")
if release.get("immutable") is not True:
    raise SystemExit("release must be immutable before Pearl recovery")
if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    raise SystemExit("release tag must be vX.Y.Z")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("release commit is invalid")
required = {f"Malibu-{tag}.dmg", f"Malibu-{tag}.dmg.sha256", "appcast.xml"}
assets = release.get("assets")
if not isinstance(assets, list):
    raise SystemExit("release assets are invalid")
names = {asset.get("name") for asset in assets if isinstance(asset, dict)}
if not required.issubset(names):
    raise SystemExit("release omits independent Malibu publication assets")
print(tag, commit)
PY
)"
read -r tag commit <<< "$identity"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] ||
  die "release identity verification failed"

if git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  [[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]] ||
    die "recovery worktree has tracked or staged changes"
  head_commit="$(git -C "$repo_root" rev-parse HEAD)"
  [[ "$head_commit" == "$commit" ]] ||
    die "recovery must run from the exact release commit $commit (current $head_commit)"
fi

gh release download "$tag" --repo "$repo" --dir "$asset_dir" \
  --pattern "Malibu-${tag}.dmg" \
  --pattern "Malibu-${tag}.dmg.sha256" \
  --pattern "appcast.xml"

dmg="$asset_dir/Malibu-${tag}.dmg"
checksum="$asset_dir/Malibu-${tag}.dmg.sha256"
appcast="$asset_dir/appcast.xml"

python3 - "$release_json" "$manifest" "$dmg" "$appcast" "$checksum" "$repo" <<'PY'
import hashlib
import json
import pathlib
import sys

release_path, manifest_path, dmg_path, appcast_path, checksum_path, repo = sys.argv[1:]
release = json.loads(pathlib.Path(release_path).read_text(encoding="utf-8"))
dmg = pathlib.Path(dmg_path)
appcast = pathlib.Path(appcast_path)
checksum = pathlib.Path(checksum_path)
tag = release["tag_name"]
digests = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in (dmg, appcast, checksum)}
content = json.dumps(
    {
        "appcast_sha256": digests[appcast.name],
        "dmg_sha256": digests[dmg.name],
        "sha256_sidecar_sha256": digests[checksum.name],
    },
    sort_keys=True,
    separators=(",", ":"),
).encode()
by_name = {
    asset.get("name"): asset
    for asset in release.get("assets", [])
    if isinstance(asset, dict)
}
manifest = {
    "schema_version": 1,
    "repository": repo,
    "tag": tag,
    "commit": release["target_commitish"],
    "prerelease": False,
    "release_id": release["id"],
    "publication_id": hashlib.sha256(content).hexdigest(),
    "assets": {},
}
for name, digest in digests.items():
    row = by_name.get(name)
    if not isinstance(row, dict) or row.get("digest") != f"sha256:{digest}":
        raise SystemExit(f"release asset digest mismatch for {name}")
    manifest["assets"][name] = {"id": row["id"], "sha256": digest}
pathlib.Path(manifest_path).write_text(
    json.dumps(manifest, sort_keys=True, indent=2) + "\n",
    encoding="utf-8",
)
PY

bash "$script_dir/publish-independent-malibu-latest-dmg.sh" \
  "$release_json" "$manifest" "$dmg" "$appcast" "$checksum"
