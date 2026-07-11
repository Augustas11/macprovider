#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-malibu-publication-set] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 6 ]] || die "usage: MANIFEST DMG APPCAST CHECKSUMS SIGNATURE PROVENANCE"
manifest="$1"
dmg="$2"
appcast="$3"
checksums="$4"
signature="$5"
provenance="$6"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for path in "$manifest" "$dmg" "$appcast" "$checksums" "$signature" "$provenance"; do
  [[ -f "$path" && ! -L "$path" ]] || die "publication input is not a regular file: $path"
done

expected_identity="$(python3 - "$provenance" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(value.get("repository", ""), value.get("tag", ""), value.get("commit", ""))
PY
)"
read -r expected_repository expected_tag expected_commit <<< "$expected_identity"
bash "$repo_root/scripts/verify-release-checksums.sh" --allow-partial \
  "$checksums" "$signature" "$provenance" \
  "$expected_repository" "$expected_tag" "$expected_commit" \
  "$dmg" "$appcast" "$provenance" >/dev/null

publication_identity="$(python3 - "$manifest" "$dmg" "$appcast" "$checksums" "$signature" "$provenance" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

manifest_path, dmg_path, appcast_path, checksums_path, signature_path, provenance_path = map(pathlib.Path, sys.argv[1:])
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
if manifest.get("schema_version") != 1 or provenance.get("schema_version") != 1:
    raise SystemExit("unsupported manifest schema")
for key in ("repository", "tag", "commit", "prerelease"):
    if manifest.get(key) != provenance.get(key):
        raise SystemExit(f"publication manifest and signed provenance disagree on {key}")
if manifest.get("prerelease") is not False:
    raise SystemExit("prerelease must not publish the stable Malibu feed")
tag = manifest.get("tag")
commit = manifest.get("commit")
if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    raise SystemExit("invalid publication tag")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("invalid publication commit")
if type(manifest.get("release_id")) is not int or manifest["release_id"] <= 0:
    raise SystemExit("invalid numeric release id")

paths = [dmg_path, appcast_path, checksums_path, signature_path, provenance_path]
local = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
dmg_name = f"Malibu-{tag}.dmg"
if dmg_path.name != dmg_name or appcast_path.name != "appcast.xml":
    raise SystemExit("publication filenames do not match the tag")
assets = manifest.get("assets")
if not isinstance(assets, dict):
    raise SystemExit("publication asset map is invalid")
for name, digest in local.items():
    row = assets.get(name)
    if not isinstance(row, dict) or type(row.get("id")) is not int or row.get("sha256") != digest:
        raise SystemExit(f"publication manifest does not bind the local {name}")

signed_assets = provenance.get("assets")
if not isinstance(signed_assets, dict):
    raise SystemExit("signed provenance asset map is invalid")
for name, digest in signed_assets.items():
    row = assets.get(name)
    if not isinstance(row, dict) or row.get("sha256") != digest:
        raise SystemExit(f"signed provenance differs from publication manifest for {name}")

content = json.dumps(
    {"appcast_sha256": local["appcast.xml"], "dmg_sha256": local[dmg_name]},
    sort_keys=True,
    separators=(",", ":"),
).encode()
if manifest.get("publication_id") != hashlib.sha256(content).hexdigest():
    raise SystemExit("publication id is not the deterministic content digest")

print(tag, commit)
PY
)"
read -r tag commit <<< "$publication_identity"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] ||
  die "publication identity verification failed"

bash "$repo_root/scripts/test-coordinator-advertised-version.sh" "$tag" "$appcast"
python3 "$repo_root/scripts/verify-malibu-sparkle-signature.py" \
  "$tag" "$dmg" "$appcast" "$repo_root/phase3-binary/app/project.yml"
bash "$repo_root/scripts/verify-malibu-release-artifacts.sh" "$dmg"

printf '[verify-malibu-publication-set] ok: release %s (%s)\n' "$tag" "$commit"
