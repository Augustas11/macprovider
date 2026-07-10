#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[recover-malibu-publication] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: recover-malibu-publication.sh TAG COMMIT RELEASE_ID DMG_ASSET_ID APPCAST_ASSET_ID CHECKSUMS_ASSET_ID SIGNATURE_ASSET_ID PROVENANCE_ASSET_ID
EOF
  exit 2
}

[[ "$#" == 8 ]] || usage
tag="$1"
commit="$2"
release_id="$3"
shift 3
asset_ids=("$@")
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid tag"
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || die "invalid commit"
[[ "$release_id" =~ ^[1-9][0-9]*$ ]] || die "invalid numeric release id"
for value in "${asset_ids[@]}"; do
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "invalid numeric asset id"
done
[[ -n "${GH_TOKEN:-}" ]] || die "GH_TOKEN with contents:read is required"

repo="${GITHUB_REPOSITORY:-Augustas11/macprovider}"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
git_remote="${RELEASE_GIT_REMOTE:-origin}"
[[ "$(git -C "$repo_root" rev-parse HEAD)" == "$commit" ]] ||
  die "recovery must run from a worktree checked out at the exact release commit"
bash "$repo_root/scripts/verify-release-tag-target.sh" \
  "$tag" "$commit" "$git_remote" --require-existing
work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-recovery.XXXXXX")"
trap 'rm -rf "$work"' EXIT
release_json="$work/release.json"
gh api "repos/$repo/releases/$release_id" >"$release_json"

names=("Malibu-${tag}.dmg" appcast.xml checksums.txt checksums.txt.sig release-provenance.json)
for index in "${!asset_ids[@]}"; do
  gh api -H 'Accept: application/octet-stream' \
    "repos/$repo/releases/assets/${asset_ids[$index]}" >"$work/${names[$index]}"
done

python3 - "$release_json" "$tag" "$commit" "$release_id" "${asset_ids[@]}" <<'PY'
import json
import sys

release_path, tag, commit, release_id, *asset_ids = sys.argv[1:]
release = json.load(open(release_path, encoding="utf-8"))
if release.get("id") != int(release_id) or release.get("tag_name") != tag or release.get("target_commitish") != commit:
    raise SystemExit("numeric release identity differs from the requested recovery identity")
if release.get("draft") is not False or release.get("immutable") is not True:
    raise SystemExit("numeric release is draft or mutable")
expected_names = [f"Malibu-{tag}.dmg", "appcast.xml", "checksums.txt", "checksums.txt.sig", "release-provenance.json"]
by_id = {str(row.get("id")): row.get("name") for row in release.get("assets", []) if isinstance(row, dict)}
for asset_id, name in zip(asset_ids, expected_names):
    if by_id.get(asset_id) != name:
        raise SystemExit(f"numeric asset {asset_id} is not {name} in release {release_id}")
PY

manifest="$work/publication-manifest.json"
python3 "$repo_root/scripts/capture-release-publication.py" \
  "$release_json" "$work/release-provenance.json" "$manifest" \
  "$work/Malibu-${tag}.dmg" "$work/appcast.xml" "$work/checksums.txt" \
  "$work/checksums.txt.sig" "$work/release-provenance.json"

bash "$repo_root/scripts/publish-malibu-latest-dmg.sh" \
  "$manifest" "$work/Malibu-${tag}.dmg" "$work/appcast.xml" \
  "$work/checksums.txt" "$work/checksums.txt.sig" "$work/release-provenance.json"
