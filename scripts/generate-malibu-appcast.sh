#!/usr/bin/env bash
# Build Sparkle appcast.xml for a signed Malibu-{tag}.dmg release asset.
#
# Requires:
#   - Malibu-{tag}.dmg at phase3-binary/app/dist/ (or pass DMG=...)
#   - SPARKLE_EDDSA_PRIVATE_KEY (base64 Ed25519 seed) or SPARKLE_PRIVATE_KEY_FILE
#   - curl + tar (Sparkle release tools downloaded on demand)
#
# Usage:
#   SPARKLE_EDDSA_PRIVATE_KEY=... bash scripts/generate-malibu-appcast.sh v1.8.18
#   DMG=path/to/Malibu-v1.8.18.dmg bash scripts/generate-malibu-appcast.sh v1.8.18

set -euo pipefail

tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "usage: $0 vX.Y.Z" >&2
  exit 2
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dmg="${DMG:-$repo_root/phase3-binary/app/dist/Malibu-${tag}.dmg}"
[[ -f "$dmg" ]] || {
  echo "missing dmg: $dmg" >&2
  exit 1
}

sparkle_version="${SPARKLE_VERSION:-2.6.4}"
tools_dir="${SPARKLE_TOOLS_DIR:-$repo_root/.cache/sparkle-${sparkle_version}}"
if [[ ! -x "$tools_dir/bin/generate_appcast" ]]; then
  mkdir -p "$(dirname "$tools_dir")"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-tools.XXXXXX")"
  curl -fsSL -o "$tmp/sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz"
  rm -rf "$tools_dir"
  mkdir -p "$tools_dir"
  tar -xJf "$tmp/sparkle.tar.xz" -C "$tools_dir" --strip-components=0
  rm -rf "$tmp"
fi

key_file=""
cleanup_key() {
  [[ -n "$key_file" && -f "$key_file" ]] && rm -f "$key_file"
}
trap cleanup_key EXIT

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  key_file="$SPARKLE_PRIVATE_KEY_FILE"
elif [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
  key_file="$(mktemp "${TMPDIR:-/tmp}/sparkle-ed-key.XXXXXX")"
  printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" > "$key_file"
else
  echo "SPARKLE_EDDSA_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE is required" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-appcast.XXXXXX")"
cleanup_work() { rm -rf "$work"; }
trap cleanup_work EXIT
trap cleanup_key EXIT

cp "$dmg" "$work/Malibu-${tag}.dmg"
release_notes="$work/release-notes.html"
cat > "$release_notes" <<EOF
<html><body><p>Malibu ${tag} — see the GitHub release for notes.</p></body></html>
EOF

"$tools_dir/bin/generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "https://download.malibu.tech/" \
  "$work"

out="$repo_root/phase3-binary/app/dist/appcast.xml"
cp "$work/appcast.xml" "$out"
echo "wrote $out"
