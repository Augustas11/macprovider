#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-malibu-publication-set] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 7 || "$#" == 8 ]] ||
  die "usage: MANIFEST DMG APPCAST ARTIFACT_INDEX CHECKSUMS SIGNATURE PROVENANCE [DISCOVERY]"
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
discovery="${8:-}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
frozen_appcast="$repo_root/scripts/dist/malibu-frozen-bridge-appcast.xml"
frozen_appcast_sha256="94ecf57584a2a203336d3219ea42dec1945bae2e123cfce0b1b39f8e0231d83c"
expected_publication_repository="${MALIBU_PUBLICATION_EXPECTED_REPOSITORY:-Augustas11/macprovider}"
[[ "$expected_publication_repository" == "Augustas11/macprovider" ]] ||
  die "Malibu publication is restricted to Augustas11/macprovider"

for path in "$manifest" "$dmg" "$appcast" "$artifact_index" "$checksums" "$signature" "$provenance"; do
  [[ -f "$path" && ! -L "$path" ]] || die "publication input is not a regular file: $path"
done
if [[ -n "$discovery" ]]; then
  [[ -f "$discovery" && ! -L "$discovery" ]] || die "publication input is not a regular file: $discovery"
fi

expected_identity="$(python3 - "$provenance" <<'PY'
import json
import pathlib
import sys

value = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
print(value.get("repository", ""), value.get("tag", ""), value.get("commit", ""))
PY
)"
read -r expected_repository expected_tag expected_commit <<< "$expected_identity"
[[ "$expected_repository" == "$expected_publication_repository" ]] ||
  die "signed provenance repository is not the expected Malibu publication repository"
[[ "$expected_tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "publication tag must be vX.Y.Z"
sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}
frozen_mode=false
checksum_assets=("$dmg" "$appcast" "$artifact_index" "$provenance")
[[ -z "$discovery" ]] || checksum_assets+=("$discovery")
if [[ "$expected_tag" != v1.8.39 ]]; then
  frozen_mode=true
  [[ -n "$discovery" ]] || die "current provider publication requires release discovery"
  [[ "$(sha256_file "$frozen_appcast")" == "$frozen_appcast_sha256" ]] ||
    die "committed frozen bridge appcast hash changed"
  cmp -s "$appcast" "$frozen_appcast" ||
    die "current provider publication must use the committed frozen bridge appcast"
  checksum_assets=("$dmg" "$artifact_index" "$discovery" "$provenance")
fi
bash "$repo_root/scripts/verify-release-checksums.sh" \
  --allow-partial --openssl "$openssl_bin" \
  "$checksums" "$signature" "$provenance" \
  "$expected_repository" "$expected_tag" "$expected_commit" \
  "${checksum_assets[@]}" >/dev/null

publication_identity="$(python3 - "$manifest" "$dmg" "$appcast" "$artifact_index" "$checksums" "$signature" "$provenance" "$frozen_mode" "$frozen_appcast_sha256" "${discovery:-}" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

manifest_path, dmg_path, appcast_path, index_path, checksums_path, signature_path, provenance_path = map(pathlib.Path, sys.argv[1:8])
frozen_mode = sys.argv[8] == "true"
frozen_appcast_sha256 = sys.argv[9]
discovery_path = pathlib.Path(sys.argv[10]) if sys.argv[10] else None
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
if manifest.get("schema_version") != 1 or provenance.get("schema_version") != 1:
    raise SystemExit("unsupported manifest schema")
for key in ("repository", "tag", "commit", "prerelease"):
    if manifest.get(key) != provenance.get(key):
        raise SystemExit(f"publication manifest and signed provenance disagree on {key}")
if manifest.get("prerelease") is not False:
    raise SystemExit("prerelease must not publish the stable Malibu feed")
if manifest.get("repository") != "Augustas11/macprovider":
    raise SystemExit("publication repository is not the expected Malibu repository")
tag = manifest.get("tag")
commit = manifest.get("commit")
if not isinstance(tag, str) or not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
    raise SystemExit("invalid publication tag")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("invalid publication commit")
if type(manifest.get("release_id")) is not int or manifest["release_id"] <= 0:
    raise SystemExit("invalid numeric release id")

paths = [dmg_path, appcast_path, index_path, checksums_path, signature_path, provenance_path]
if discovery_path is not None:
    paths.append(discovery_path)
local = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
dmg_name = f"Malibu-{tag}.dmg"
if (
    dmg_path.name != dmg_name
    or index_path.name != "compatibility-artifact-index.json"
):
    raise SystemExit("publication filenames do not match the tag")
if not frozen_mode and appcast_path.name != "appcast.xml":
    raise SystemExit("publication filenames do not match the tag")
assets = manifest.get("assets")
if not isinstance(assets, dict):
    raise SystemExit("publication asset map is invalid")
bound_names = [dmg_name, "compatibility-artifact-index.json", checksums_path.name, signature_path.name, provenance_path.name]
if frozen_mode:
    if discovery_path is None:
        raise SystemExit("current provider publication requires release discovery")
    if discovery_path.name != "macprovider-release-discovery.json":
        raise SystemExit("release discovery filename is invalid")
    if local[appcast_path.name] != frozen_appcast_sha256:
        raise SystemExit("frozen bridge appcast digest changed")
    if "appcast.xml" in assets:
        raise SystemExit("current provider publication must not bind a release appcast asset")
    discovery = json.loads(discovery_path.read_text(encoding="utf-8"))
    release_sequence = discovery.get("signed", {}).get("release_sequence")
    if type(release_sequence) is not int or release_sequence <= 0:
        raise SystemExit("release discovery sequence is invalid")
    if manifest.get("release_sequence") != release_sequence:
        raise SystemExit("current provider publication requires a release sequence")
    bound_names.append("macprovider-release-discovery.json")
else:
    bound_names.append("appcast.xml")
    release_sequence = manifest.get("release_sequence")
    if release_sequence is not None and (type(release_sequence) is not int or release_sequence <= 0):
        raise SystemExit("publication release sequence is invalid")
    if discovery_path is not None:
        if discovery_path.name != "macprovider-release-discovery.json":
            raise SystemExit("release discovery filename is invalid")
        discovery = json.loads(discovery_path.read_text(encoding="utf-8"))
        discovery_sequence = discovery.get("signed", {}).get("release_sequence")
        if type(discovery_sequence) is not int or discovery_sequence <= 0:
            raise SystemExit("release discovery sequence is invalid")
        if release_sequence != discovery_sequence:
            raise SystemExit("publication release sequence differs from release discovery")
        bound_names.append("macprovider-release-discovery.json")
for name in bound_names:
    digest = local[name]
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

content_fields = {
    "compatibility_artifact_index_sha256": local["compatibility-artifact-index.json"],
    "dmg_sha256": local[dmg_name],
}
if not frozen_mode:
    content_fields["appcast_sha256"] = local["appcast.xml"]
if release_sequence is not None:
    content_fields["release_sequence"] = release_sequence
content = json.dumps(content_fields, sort_keys=True, separators=(",", ":")).encode()
if manifest.get("publication_id") != hashlib.sha256(content).hexdigest():
    raise SystemExit("publication id is not the deterministic content digest")

print(tag, commit)
PY
)"
read -r tag commit <<< "$publication_identity"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$commit" =~ ^[0-9a-f]{40}$ ]] ||
  die "publication identity verification failed"

coordinator_args=("$tag")
staged_candidate="${MALIBU_PUBLICATION_STAGED_CANDIDATE:-}"
allow_previous_stable="${MALIBU_PUBLICATION_ALLOW_PREVIOUS_STABLE:-}"
if [[ -n "$staged_candidate" || -n "$allow_previous_stable" ]]; then
  [[ -n "$staged_candidate" && -n "$allow_previous_stable" ]] ||
    die "staged coordinator publication policy requires candidate and previous stable"
  staged_candidate="${staged_candidate#v}"
  [[ "$staged_candidate" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "staged coordinator candidate must be a semantic version"
  [[ "$allow_previous_stable" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "previous stable coordinator allowance must be a semantic version"
  if [[ "$tag" == "v$staged_candidate" ]]; then
    coordinator_args+=(
      "--allow-previous-stable=$allow_previous_stable"
      "--staged-candidate=$staged_candidate"
    )
  fi
fi
bash "$repo_root/scripts/test-coordinator-advertised-version.sh" "${coordinator_args[@]}"
if [[ "$frozen_mode" == false ]]; then
  python3 "$repo_root/scripts/verify-malibu-sparkle-signature.py" \
    "$tag" "$dmg" "$appcast" \
    "$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
fi
bash "$repo_root/scripts/verify-malibu-release-artifacts.sh" \
  "$dmg" --legacy-app-only-no-provider-tarball

printf '[verify-malibu-publication-set] ok: release %s (%s)\n' "$tag" "$commit"
