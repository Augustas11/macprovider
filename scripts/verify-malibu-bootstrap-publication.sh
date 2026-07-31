#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[verify-malibu-bootstrap-publication] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 3 ]] || die "usage: TAG DMG APPCAST"
tag="$1"
dmg="$2"
appcast="$3"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "tag must be vX.Y.Z"
for path in "$dmg" "$appcast"; do
  [[ -f "$path" && ! -L "$path" ]] || die "expected a regular publication input: $path"
done
repo_root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$tag" != v1.8.39 ]]; then
  # Non-v1.8.39 promotions ship the committed frozen legacy Sparkle bridge
  # appcast. Confirm the local reference bytes match the committed constant so
  # the public byte-comparison below anchors to the reviewed appcast.
  frozen_bridge_appcast="$repo_root/scripts/dist/malibu-frozen-bridge-appcast.xml"
  [[ -f "$frozen_bridge_appcast" && ! -L "$frozen_bridge_appcast" ]] ||
    die "committed frozen bridge appcast is missing"
  if command -v shasum >/dev/null 2>&1; then
    a="$(shasum -a 256 "$appcast" | awk '{print $1}')"
    b="$(shasum -a 256 "$frozen_bridge_appcast" | awk '{print $1}')"
  else
    a="$(sha256sum "$appcast" | awk '{print $1}')"
    b="$(sha256sum "$frozen_bridge_appcast" | awk '{print $1}')"
  fi
  [[ "$a" == "$b" ]] || die "appcast is not the committed frozen Malibu bridge appcast"
fi

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

expected_dmg_sha="$(sha256_file "$dmg")"
expected_appcast_sha="$(sha256_file "$appcast")"
curl_args=(
  --fail --show-error --silent --location --proto '=https' --tlsv1.2
  --connect-timeout 20 --max-time 240 --retry 3 --retry-delay 2
)
# The cache-bust key must vary per release so a CDN/proxy cannot serve a stale
# prior latest.dmg. For non-v1.8.39 promotions the appcast is the frozen bridge
# constant (identical every release), so key off the per-release DMG sha; the
# v1.8.39 bootstrap keeps its unique per-release appcast sha.
if [[ "$tag" == v1.8.39 ]]; then
  cache_key="publication=${expected_appcast_sha}"
else
  cache_key="publication=${expected_dmg_sha}"
fi
curl "${curl_args[@]}" -o "$work/appcast.xml" "${base}/appcast.xml?${cache_key}"
curl "${curl_args[@]}" -o "$work/latest.dmg" "${base}/latest.dmg?${cache_key}"
curl "${curl_args[@]}" -o "$work/Malibu-${tag}.dmg" \
  "${base}/Malibu-${tag}.dmg?${cache_key}"

[[ "$(sha256_file "$work/appcast.xml")" == "$expected_appcast_sha" ]] ||
  die "public appcast bytes differ from the immutable release asset"
for published_dmg in "$work/latest.dmg" "$work/Malibu-${tag}.dmg"; do
  [[ "$(sha256_file "$published_dmg")" == "$expected_dmg_sha" ]] ||
    die "public DMG bytes differ from the immutable release asset: $published_dmg"
done

# The Sparkle EdDSA enclosure signature binds the appcast to the DMG it
# advertises, which only corresponds for the v1.8.39 bootstrap. Non-v1.8.39
# promotions serve the frozen bridge appcast (already confirmed byte-identical
# to the committed constant) beside a newer DMG it does not describe.
if [[ "$tag" == v1.8.39 ]]; then
  python3 "$repo_root/scripts/verify-malibu-sparkle-signature.py" \
    "$tag" "$work/latest.dmg" "$work/appcast.xml" \
    "$repo_root/scripts/dist/malibu-v1.8.32-sparkle-public-key"
fi

printf '[verify-malibu-bootstrap-publication] ok: %s serves the exact published bytes for %s\n' \
  "$base" "$tag"
