#!/usr/bin/env bash
# Publish Malibu-{tag}.dmg to the download.malibu.tech bucket and refresh latest.dmg.
#
# Requires operator credentials for the object store backing download.malibu.tech.
# Example (Cloudflare R2 via awscli-compatible endpoint):
#
#   export MALIBU_DOWNLOAD_ENDPOINT="https://<account>.r2.cloudflarestorage.com"
#   export MALIBU_DOWNLOAD_BUCKET="malibu-download"
#   export AWS_ACCESS_KEY_ID=...
#   export AWS_SECRET_ACCESS_KEY=...
#   bash scripts/publish-malibu-latest-dmg.sh v1.8.13
#
# Without object-store credentials this script prints the GitHub Release URL to
# wire manually in Cloudflare (redirect latest.dmg → versioned asset).

set -euo pipefail

die() {
  printf '[publish-malibu-latest-dmg] ERROR: %s\n' "$*" >&2
  exit 1
}

tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "usage: $0 vX.Y.Z"

repo="${GITHUB_REPOSITORY:-Augustas11/macprovider}"
dmg_name="Malibu-${tag}.dmg"
versioned_key="Malibu-${tag}.dmg"
latest_key="latest.dmg"

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-publish.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

gh release download "$tag" \
  --repo "$repo" \
  --pattern "$dmg_name" \
  --pattern "appcast.xml" \
  --dir "$work" \
  --clobber

asset="$work/$dmg_name"
[[ -f "$asset" ]] || die "release asset missing: $dmg_name"

sha256="$(shasum -a 256 "$asset" | awk '{print $1}')"
printf '%s  %s\n' "$sha256" "$dmg_name" > "$work/${dmg_name}.sha256"

if [[ -z "${MALIBU_DOWNLOAD_BUCKET:-}" ]]; then
  cat <<EOF
[publish-malibu-latest-dmg] No MALIBU_DOWNLOAD_BUCKET set — manual step required.

1. Upload $dmg_name to download.malibu.tech as:
     $versioned_key
     SHA-256: $sha256
2. Point https://download.malibu.tech/latest.dmg at that object (redirect or copy).
3. GitHub Release asset (fallback):
     https://github.com/$repo/releases/download/$tag/$dmg_name
EOF
  exit 0
fi

command -v aws >/dev/null 2>&1 || die "aws CLI required when MALIBU_DOWNLOAD_BUCKET is set"

aws_args=()
if [[ -n "${MALIBU_DOWNLOAD_ENDPOINT:-}" ]]; then
  aws_args+=(--endpoint-url "$MALIBU_DOWNLOAD_ENDPOINT")
fi

aws s3 cp "$asset" "s3://${MALIBU_DOWNLOAD_BUCKET}/${versioned_key}" "${aws_args[@]}"
aws s3 cp "$asset" "s3://${MALIBU_DOWNLOAD_BUCKET}/${latest_key}" "${aws_args[@]}"
aws s3 cp "$work/${dmg_name}.sha256" "s3://${MALIBU_DOWNLOAD_BUCKET}/${dmg_name}.sha256" "${aws_args[@]}"

appcast="$work/appcast.xml"
if [[ -f "$appcast" ]]; then
  aws s3 cp "$appcast" "s3://${MALIBU_DOWNLOAD_BUCKET}/appcast.xml" "${aws_args[@]}"
  printf '[publish-malibu-latest-dmg] ok: appcast.xml published\n'
else
  printf '[publish-malibu-latest-dmg] WARN: appcast.xml missing from release %s — Sparkle feed unchanged\n' "$tag" >&2
fi

printf '[publish-malibu-latest-dmg] ok: s3://%s/%s and latest.dmg (sha256=%s)\n' \
  "$MALIBU_DOWNLOAD_BUCKET" "$versioned_key" "$sha256"
