#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-malibu-publication-set] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 7 ]] || die "usage: MANIFEST DMG APPCAST ARTIFACT_INDEX CHECKSUMS SIGNATURE PROVENANCE"
openssl_bin="${OPENSSL_BIN:-}"
[[ "$openssl_bin" == /* ]] ||
  die "OPENSSL_BIN must identify the absolute reviewed release verifier"
manifest="$1"
dmg="$2"
appcast="$3"
artifact_index="$4"
checksums="$5"
signature="$6"
provenance="$7"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

for path in "$manifest" "$dmg" "$appcast" "$artifact_index" "$checksums" "$signature" "$provenance"; do
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
[[ "$expected_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "publication tag is invalid"
frozen_bridge_appcast="$repo_root/scripts/dist/malibu-frozen-bridge-appcast.xml"
if [[ "$expected_tag" == v1.8.39 ]]; then
  frozen_appcast=false
else
  # Non-v1.8.39 download promotions ship the committed frozen legacy Sparkle
  # bridge appcast, which is NOT part of the per-release signed provenance, so
  # it is excluded from checksum coverage and verified against the committed
  # constant below.
  frozen_appcast=true
fi
if [[ "$frozen_appcast" == true ]]; then
  checksum_assets=("$dmg" "$artifact_index" "$provenance")
else
  checksum_assets=("$dmg" "$appcast" "$artifact_index" "$provenance")
fi
bash "$repo_root/scripts/verify-release-checksums.sh" \
  --allow-partial --openssl "$openssl_bin" \
  "$checksums" "$signature" "$provenance" \
  "$expected_repository" "$expected_tag" "$expected_commit" \
  "${checksum_assets[@]}" >/dev/null

publication_identity="$(python3 - "$frozen_appcast" "$frozen_bridge_appcast" "$manifest" "$dmg" "$appcast" "$artifact_index" "$checksums" "$signature" "$provenance" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

frozen_mode = sys.argv[1] == "true"
frozen_ref = pathlib.Path(sys.argv[2])
manifest_path, dmg_path, appcast_path, index_path, checksums_path, signature_path, provenance_path = map(pathlib.Path, sys.argv[3:])
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

# For non-v1.8.39 promotions the frozen legacy Sparkle bridge appcast is not a
# per-release signed asset, so it is excluded from the manifest/provenance
# binding here and verified against the committed constant below instead.
if frozen_mode:
    paths = [dmg_path, index_path, checksums_path, signature_path, provenance_path]
else:
    paths = [dmg_path, appcast_path, index_path, checksums_path, signature_path, provenance_path]
local = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
dmg_name = f"Malibu-{tag}.dmg"
if dmg_path.name != dmg_name or index_path.name != "compatibility-artifact-index.json":
    raise SystemExit("publication filenames do not match the tag")
if not frozen_mode and appcast_path.name != "appcast.xml":
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

if frozen_mode:
    if not frozen_ref.is_file() or frozen_ref.is_symlink():
        raise SystemExit("committed frozen bridge appcast is missing")
    if hashlib.sha256(appcast_path.read_bytes()).hexdigest() != hashlib.sha256(frozen_ref.read_bytes()).hexdigest():
        raise SystemExit("appcast is not the committed frozen Malibu bridge appcast")
    publication_content = {
        "compatibility_artifact_index_sha256": local["compatibility-artifact-index.json"],
        "dmg_sha256": local[dmg_name],
    }
else:
    publication_content = {
        "appcast_sha256": local["appcast.xml"],
        "compatibility_artifact_index_sha256": local["compatibility-artifact-index.json"],
        "dmg_sha256": local[dmg_name],
    }
content = json.dumps(
    publication_content,
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

bash "$repo_root/scripts/test-coordinator-advertised-version.sh" "$tag"
# The Sparkle EdDSA cross-check binds the appcast enclosure to the DMG it
# advertises. That correspondence only holds for the v1.8.39 bootstrap, whose
# appcast describes its own DMG. Non-v1.8.39 promotions ship the frozen bridge
# appcast (verified byte-identical to the committed constant above) alongside a
# newer DMG the frozen appcast does not describe, so the enclosure cross-check
# does not apply.
if [[ "$frozen_appcast" == false ]]; then
  python3 "$repo_root/scripts/verify-malibu-sparkle-signature.py" \
    "$tag" "$dmg" "$appcast" \
    "$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
fi
bash "$repo_root/scripts/verify-malibu-release-artifacts.sh" \
  "$dmg" --legacy-app-only-no-provider-tarball

printf '[verify-malibu-publication-set] ok: release %s (%s)\n' "$tag" "$commit"
