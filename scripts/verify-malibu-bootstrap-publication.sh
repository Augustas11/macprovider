#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-malibu-bootstrap-publication] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 4 ]] || die "usage: TAG DMG APPCAST SHA256"
tag="$1"
dmg="$2"
appcast="$3"
checksum="$4"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be vX.Y.Z"
for path in "$dmg" "$appcast" "$checksum"; do
  [[ -f "$path" && ! -L "$path" ]] || die "expected a regular publication input: $path"
done

host="${MALIBU_DOWNLOAD_HOST:-download.malibu.tech}"
base="https://${host}"
work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/malibu-bootstrap-public.XXXXXX")"
trap 'rm -rf "$work"' EXIT

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
frozen_appcast="$repo_root/scripts/dist/malibu-frozen-bridge-appcast.xml"
frozen_appcast_sha256="94ecf57584a2a203336d3219ea42dec1945bae2e123cfce0b1b39f8e0231d83c"
expected_dmg_sha="$(sha256_file "$dmg")"
expected_appcast_sha="$(sha256_file "$appcast")"
expected_checksum_sha="$(sha256_file "$checksum")"
expected_checksum_bytes="${expected_dmg_sha}  Malibu-${tag}.dmg"
[[ "$(cat "$checksum")" == "$expected_checksum_bytes" ]] ||
  die "versioned DMG checksum file is invalid"
frozen_mode=false
if [[ "$tag" != v1.8.39 ]]; then
  frozen_mode=true
  [[ "$(sha256_file "$frozen_appcast")" == "$frozen_appcast_sha256" ]] ||
    die "committed frozen bridge appcast hash changed"
  cmp -s "$appcast" "$frozen_appcast" ||
    die "current provider publication must use the committed frozen bridge appcast"
fi
curl_args=(
  --fail --show-error --silent --location --proto '=https' --tlsv1.2
  --connect-timeout 20 --max-time 240 --retry 3 --retry-delay 2
)
cache_key="publication=${expected_appcast_sha}"
[[ "$frozen_mode" == false ]] || cache_key="publication=${expected_dmg_sha}"
curl "${curl_args[@]}" -o "$work/appcast.xml" "${base}/appcast.xml?${cache_key}"
curl "${curl_args[@]}" -o "$work/latest.dmg" "${base}/latest.dmg?${cache_key}"
curl "${curl_args[@]}" -o "$work/Malibu-${tag}.dmg" \
  "${base}/Malibu-${tag}.dmg?${cache_key}"
curl "${curl_args[@]}" -o "$work/Malibu-${tag}.dmg.sha256" \
  "${base}/Malibu-${tag}.dmg.sha256?${cache_key}"
if [[ "$frozen_mode" == true ]]; then
  curl "${curl_args[@]}" -o "$work/Malibu-v1.8.39.dmg" \
    "${base}/Malibu-v1.8.39.dmg?${cache_key}"
fi

[[ "$(sha256_file "$work/appcast.xml")" == "$expected_appcast_sha" ]] ||
  die "public appcast bytes differ from the immutable release asset"
for published_dmg in "$work/latest.dmg" "$work/Malibu-${tag}.dmg"; do
  [[ "$(sha256_file "$published_dmg")" == "$expected_dmg_sha" ]] ||
    die "public DMG bytes differ from the immutable release asset: $published_dmg"
done
[[ "$(sha256_file "$work/Malibu-${tag}.dmg.sha256")" == "$expected_checksum_sha" ]] ||
  die "public checksum bytes differ from the immutable release asset"
[[ "$(cat "$work/Malibu-${tag}.dmg.sha256")" == "$expected_checksum_bytes" ]] ||
  die "public checksum contents do not match the immutable release DMG"

if [[ "$frozen_mode" == false ]]; then
  python3 "$repo_root/scripts/verify-malibu-sparkle-signature.py" \
    "$tag" "$work/latest.dmg" "$work/appcast.xml" \
    "$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
else
  python3 "$repo_root/scripts/verify-malibu-sparkle-signature.py" \
    v1.8.39 "$work/Malibu-v1.8.39.dmg" "$work/appcast.xml" \
    "$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
fi

printf '[verify-malibu-bootstrap-publication] ok: %s serves %s latest/appcast/checksum bytes\n' "$base" "$tag"
