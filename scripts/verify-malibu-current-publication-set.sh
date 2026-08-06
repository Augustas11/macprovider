#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-malibu-current-publication-set] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 5 ]] || die "usage: RELEASE_JSON MANIFEST DMG APPCAST SHA256"
release_json="$1"
manifest="$2"
dmg="$3"
appcast="$4"
checksum="$5"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for path in "$release_json" "$manifest" "$dmg" "$appcast" "$checksum"; do
  [[ -f "$path" && ! -L "$path" ]] || die "publication input is not a regular file: $path"
done

identity="$(
  python3 - "$release_json" "$manifest" "$dmg" "$appcast" "$checksum" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

release_path, manifest_path, dmg_path, appcast_path, checksum_path = map(pathlib.Path, sys.argv[1:])
release = json.loads(release_path.read_text(encoding="utf-8"))
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
if manifest.get("schema_version") != 1:
    raise SystemExit("unsupported manifest schema")
if manifest.get("repository") != "Augustas11/macprovider":
    raise SystemExit("publication manifest repository mismatch")
tag = manifest.get("tag")
commit = manifest.get("commit")
if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    raise SystemExit("invalid publication tag")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("invalid publication commit")
if manifest.get("prerelease") is not False:
    raise SystemExit("prerelease must not publish the stable Malibu feed")
release_id = manifest.get("release_id")
if type(release_id) is not int or release_id <= 0:
    raise SystemExit("invalid numeric release id")
if (
    release.get("id") != release_id
    or release.get("tag_name") != tag
    or release.get("target_commitish") != commit
    or release.get("draft") is not False
    or release.get("prerelease") is not False
    or release.get("immutable") is not True
):
    raise SystemExit("GitHub release does not match the immutable Malibu publication")

dmg_name = f"Malibu-{tag}.dmg"
if dmg_path.name != dmg_name or appcast_path.name != "appcast.xml" or checksum_path.name != f"{dmg_name}.sha256":
    raise SystemExit("publication filenames do not match the tag")
local = {
    dmg_path.name: hashlib.sha256(dmg_path.read_bytes()).hexdigest(),
    appcast_path.name: hashlib.sha256(appcast_path.read_bytes()).hexdigest(),
    checksum_path.name: hashlib.sha256(checksum_path.read_bytes()).hexdigest(),
}
if checksum_path.read_text(encoding="utf-8") != f"{local[dmg_path.name]}  {dmg_path.name}\n":
    raise SystemExit("versioned DMG checksum file is invalid")
assets = manifest.get("assets")
if not isinstance(assets, dict):
    raise SystemExit("publication asset map is invalid")
release_assets = release.get("assets")
if not isinstance(release_assets, list):
    raise SystemExit("release asset list is invalid")
release_by_name = {asset.get("name"): asset for asset in release_assets if isinstance(asset, dict)}
for name, digest in local.items():
    row = assets.get(name)
    release_row = release_by_name.get(name)
    if not isinstance(row, dict) or type(row.get("id")) is not int or row.get("sha256") != digest:
        raise SystemExit(f"publication manifest does not bind {name}")
    if not isinstance(release_row, dict) or release_row.get("id") != row["id"]:
        raise SystemExit(f"release asset id mismatch for {name}")
    if release_row.get("digest") != f"sha256:{digest}":
        raise SystemExit(f"release asset digest mismatch for {name}")
content = json.dumps(
    {
        "appcast_sha256": local["appcast.xml"],
        "dmg_sha256": local[dmg_name],
        "sha256_sidecar_sha256": local[f"{dmg_name}.sha256"],
    },
    sort_keys=True,
    separators=(",", ":"),
).encode()
if manifest.get("publication_id") != hashlib.sha256(content).hexdigest():
    raise SystemExit("publication id is not the deterministic content digest")
print(tag, commit)
PY
)"
read -r tag commit <<< "$identity"

python3 "$repo_root/scripts/verify-malibu-sparkle-signature.py" \
  "$tag" "$dmg" "$appcast" \
  "$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
if [[ -n "${EXPECTED_CLI_SHA256:-}" ]]; then
  bash "$repo_root/scripts/verify-malibu-release-artifacts.sh" \
    "$dmg" --expected-cli-sha256 "$EXPECTED_CLI_SHA256"
fi

printf '[verify-malibu-current-publication-set] ok: release %s (%s)\n' "$tag" "$commit"
