#!/usr/bin/env bash
# Recover only the post-GitHub Pearl publication for the frozen v1.8.39 bridge.
set -euo pipefail
umask 077

die() {
  printf '[recover-malibu-publication] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: recover-malibu-publication.sh RELEASE_ID

RELEASE_ID must identify the immutable, stable v1.8.39 GitHub release. The
helper discovers the required numeric asset IDs from that release and republishes
only the already-signed Malibu bridge bytes to Pearl.
EOF
  exit 2
}

[[ "$#" == 1 ]] || usage
release_id="$1"
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || die "invalid numeric release id"
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN with contents:read is required"
command -v gh >/dev/null 2>&1 || die "gh is required"

repo="Augustas11/macprovider"
if [[ -n "${GITHUB_REPOSITORY:-}" && "$GITHUB_REPOSITORY" != "$repo" ]]; then
  die "recovery is restricted to $repo"
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ -z "$(git -C "$repo_root" status --porcelain --untracked-files=no)" ]] ||
  die "recovery worktree has tracked or staged changes"

ssh_key="${MALIBU_DOWNLOAD_SSH_KEY:-$HOME/.ssh/pearl_operator_ed25519}"
[[ -f "$ssh_key" && ! -L "$ssh_key" ]] ||
  die "Pearl SSH key is missing or symlinked: $ssh_key"

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT
release_json="$work/release.json"
release_after_download_json="$work/release-after-download.json"
identity="$work/release-identity.txt"
identity_after_download="$work/release-identity-after-download.txt"

fetch_release() {
  gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
    "repos/$repo/releases/$release_id" >"$1"
}

validate_release() {
  python3 - "$1" "$release_id" <<'PY'
import json
import pathlib
import re
import sys

release_path, requested_release_id = pathlib.Path(sys.argv[1]), int(sys.argv[2])
release = json.loads(release_path.read_text(encoding="utf-8"))
tag = "v1.8.39"
expected_names = [
    f"Malibu-{tag}.dmg",
    "appcast.xml",
    "compatibility-artifact-index.json",
    "checksums.txt",
    "checksums.txt.sig",
    "release-provenance.json",
]

if release.get("id") != requested_release_id:
    raise SystemExit("numeric release id differs from the requested recovery id")
if release.get("tag_name") != tag:
    raise SystemExit("legacy Malibu publication recovery is frozen to v1.8.39")
commit = release.get("target_commitish")
if not isinstance(commit, str) or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("numeric release target is not a full lowercase commit")
if release.get("draft") is not False:
    raise SystemExit("numeric release is still a draft")
if release.get("immutable") is not True:
    raise SystemExit("numeric release is not immutable")
if release.get("prerelease") is not False:
    raise SystemExit("numeric release is not the stable v1.8.39 release")
if release.get("name") != f"macprovider-cli {tag}":
    raise SystemExit("numeric release title differs from the reviewed release")

assets = release.get("assets")
if not isinstance(assets, list):
    raise SystemExit("numeric release asset list is invalid")
by_name = {}
seen_ids = set()
for row in assets:
    if not isinstance(row, dict):
        raise SystemExit("numeric release contains an invalid asset row")
    name, asset_id, digest = row.get("name"), row.get("id"), row.get("digest")
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise SystemExit("numeric release contains an unsafe asset name")
    if name in by_name:
        raise SystemExit(f"numeric release has duplicate asset name: {name}")
    if type(asset_id) is not int or asset_id <= 0:
        raise SystemExit(f"numeric asset id is invalid for {name}")
    if asset_id in seen_ids:
        raise SystemExit(f"numeric release has duplicate asset id: {asset_id}")
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
        raise SystemExit(f"numeric release digest is invalid for {name}")
    if row.get("state") != "uploaded":
        raise SystemExit(f"numeric release asset is not uploaded: {name}")
    by_name[name] = row
    seen_ids.add(asset_id)

missing = [name for name in expected_names if name not in by_name]
if missing:
    raise SystemExit(f"numeric release is missing required asset: {missing[0]}")

print(commit, *(by_name[name]["id"] for name in expected_names))
PY
}

fetch_release "$release_json"
validate_release "$release_json" >"$identity"
read -r commit dmg_asset_id appcast_asset_id artifact_index_asset_id \
  checksums_asset_id signature_asset_id provenance_asset_id <"$identity" ||
  die "could not read the validated release identity"

[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$commit" ]] ||
  die "recovery must run from a clean worktree at the exact release commit $commit"
git -C "$repo_root" fetch --quiet --no-tags origin \
  refs/heads/main:refs/remotes/origin/main ||
  die "could not refresh origin/main"
git -C "$repo_root" merge-base --is-ancestor "$commit" refs/remotes/origin/main ||
  die "release commit is not reachable from fresh origin/main"
bash "$repo_root/scripts/verify-release-tag-target.sh" \
  v1.8.39 "$commit" origin --require-existing >/dev/null

names=(
  "Malibu-v1.8.39.dmg"
  "appcast.xml"
  "compatibility-artifact-index.json"
  "checksums.txt"
  "checksums.txt.sig"
  "release-provenance.json"
)
asset_ids=(
  "$dmg_asset_id"
  "$appcast_asset_id"
  "$artifact_index_asset_id"
  "$checksums_asset_id"
  "$signature_asset_id"
  "$provenance_asset_id"
)
for index in "${!names[@]}"; do
  target="$work/${names[$index]}"
  gh api -H 'X-GitHub-Api-Version: 2026-03-10' \
    -H 'Accept: application/octet-stream' \
    "repos/$repo/releases/assets/${asset_ids[$index]}" >"$target"
  [[ -f "$target" && ! -L "$target" ]] ||
    die "downloaded release asset is not regular: ${names[$index]}"
  chmod 600 "$target"
done

# Immutability should make this identity stable. Re-read it anyway so a broken
# API response, wrong numeric release, or asset-ID association cannot race the
# local capture and Pearl publication.
fetch_release "$release_after_download_json"
validate_release "$release_after_download_json" >"$identity_after_download"
cmp -s "$identity" "$identity_after_download" ||
  die "numeric release identity changed while recovery assets were downloaded"

manifest="$work/publication-manifest.json"
python3 "$repo_root/scripts/capture-release-publication.py" \
  "$release_after_download_json" "$work/release-provenance.json" "$manifest" \
  "$work/Malibu-v1.8.39.dmg" "$work/appcast.xml" \
  "$work/compatibility-artifact-index.json" "$work/checksums.txt" \
  "$work/checksums.txt.sig" "$work/release-provenance.json"

bash "$repo_root/scripts/publish-malibu-latest-dmg.sh" \
  "$manifest" "$work/Malibu-v1.8.39.dmg" "$work/appcast.xml" \
  "$work/compatibility-artifact-index.json" "$work/checksums.txt" \
  "$work/checksums.txt.sig" "$work/release-provenance.json"

printf '[recover-malibu-publication] ok: immutable release %s republished to Pearl\n' \
  "$release_id"
