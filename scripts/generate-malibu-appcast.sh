#!/usr/bin/env bash
# Build the one-time Sparkle bootstrap appcast for Malibu v1.8.32 clients.
#
# Requires:
#   - Malibu-{tag}.dmg at phase3-binary/app/dist/ (or pass DMG=...)
#   - SPARKLE_EDDSA_PRIVATE_KEY (base64 Ed25519 seed) or SPARKLE_PRIVATE_KEY_FILE
#   - curl + tar (reviewed Sparkle release tools downloaded on demand)
#
# The current Malibu app remains free of Sparkle runtime and feeds. Its signed
# v1.8.39 target retains only the old public trust anchor required by Sparkle's
# post-extraction policy. This signer is locked to that one bridge tag.

set -euo pipefail

tag="${1:-}"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "usage: $0 vX.Y.Z" >&2
  exit 2
}
bridge_tag="v1.8.39"
[[ "$tag" == "$bridge_tag" ]] || {
  echo "legacy Malibu Sparkle bootstrap is frozen to $bridge_tag" >&2
  exit 1
}

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
dmg="${DMG:-$repo_root/phase3-binary/app/dist/Malibu-${tag}.dmg}"
[[ -f "$dmg" && ! -L "$dmg" ]] || {
  echo "missing dmg: $dmg" >&2
  exit 1
}

sparkle_version="2.6.4"
sparkle_sha256="50612a06038abc931f16011d7903b8326a362c1074dabccb718404ce8e585f0b"
tools_dir="$(mktemp -d "${TMPDIR:-/tmp}/sparkle-tools.XXXXXX")"
key_file=""
work=""
cleanup() {
  if [[ -n "$key_file" && "$key_file" != "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
    rm -f "$key_file"
  fi
  [[ -n "$work" ]] && rm -rf "$work"
  rm -rf "$tools_dir"
}
trap cleanup EXIT
archive="$tools_dir/Sparkle-${sparkle_version}.tar.xz"
curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
  -o "$archive" \
  "https://github.com/sparkle-project/Sparkle/releases/download/${sparkle_version}/Sparkle-${sparkle_version}.tar.xz"
actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
[[ "$actual_sha256" == "$sparkle_sha256" ]] || {
  echo "Sparkle tools sha256 mismatch: got $actual_sha256" >&2
  exit 1
}
tar -xJf "$archive" -C "$tools_dir"
generate_appcast="$tools_dir/bin/generate_appcast"
[[ -f "$generate_appcast" && ! -L "$generate_appcast" && -x "$generate_appcast" ]] || {
  echo "reviewed Sparkle generate_appcast tool is missing" >&2
  exit 1
}

if [[ -n "${SPARKLE_PRIVATE_KEY_FILE:-}" ]]; then
  key_file="$SPARKLE_PRIVATE_KEY_FILE"
elif [[ -n "${SPARKLE_EDDSA_PRIVATE_KEY:-}" ]]; then
  key_file="$(mktemp "${TMPDIR:-/tmp}/sparkle-ed-key.XXXXXX")"
  printf '%s' "$SPARKLE_EDDSA_PRIVATE_KEY" > "$key_file"
  chmod 600 "$key_file"
else
  echo "SPARKLE_EDDSA_PRIVATE_KEY or SPARKLE_PRIVATE_KEY_FILE is required" >&2
  exit 1
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-appcast.XXXXXX")"

cp "$dmg" "$work/Malibu-${tag}.dmg"
release_notes="$work/release-notes.html"
cat > "$release_notes" <<EOF
<html><body><p>Malibu ${tag} — see the GitHub release for notes.</p></body></html>
EOF

"$generate_appcast" \
  --ed-key-file "$key_file" \
  --download-url-prefix "https://download.malibu.tech/" \
  "$work"

out="$repo_root/phase3-binary/app/dist/appcast.xml"
cp "$work/appcast.xml" "$out"
[[ -f "$out" && ! -L "$out" ]] || {
  echo "generated appcast is not a regular file" >&2
  exit 1
}
echo "wrote $out"
