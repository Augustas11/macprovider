#!/usr/bin/env bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

# This installer is intentionally release-specific. A later Malibu release must
# regenerate these monotonic floors instead of silently reusing this bundle.
readonly expected_key_id="macprovider-release-p256-v1"
readonly minimum_keyring_generation="1"
readonly minimum_index_generation="1"
readonly minimum_envelope_generation="1"
readonly minimum_build="41"

die() { printf 'install-malibu-app: %s\n' "$*" >&2; exit 1; }

validate_mounted_layout() {
  local root="$1"
  [[ -d "$root/Malibu.app" && ! -L "$root/Malibu.app" ]] || die "DMG lacks one safe Malibu.app root"
  [[ -L "$root/Applications" && "$(readlink "$root/Applications")" == "/Applications" ]] ||
    die "DMG lacks the exact Applications -> /Applications convenience link"
  [[ "$(find "$root" -mindepth 1 -maxdepth 1 -print | wc -l | tr -d ' ')" == "2" ]] ||
    die "DMG contains unexpected top-level members"
}

if [[ "${1:-}" == "--check-mounted-layout" && "$#" -eq 2 ]]; then
  validate_mounted_layout "$2"
  exit 0
fi
[[ "$#" -eq 0 ]] || die "this release-specific installer accepts no arguments"

[[ ! -L "${BASH_SOURCE[0]}" ]] || die "installer must not be invoked through a symlink"
bundle_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly expected_dmg_name="Malibu-v1.8.41.dmg"
readonly members=(
  "malibu-app-transaction.py"
  "malibu-release-envelope.py"
  "malibu-release-envelope-v1.8.41.json"
  "malibu-release-index.json"
  "malibu-release-keyring.json"
  "malibu-release-revocations.json"
  "release-signing-public.pem"
  "$expected_dmg_name"
)
for name in "${members[@]}"; do
  file="$bundle_dir/$name"
  [[ -f "$file" && ! -L "$file" ]] || die "missing or unsafe bundle member: $(basename "$file")"
done

work="$(mktemp -d "${TMPDIR:-/tmp}/install-malibu-app.XXXXXX")"
work="$(cd "$work" && pwd -P)"
chmod 700 "$work"
private_bundle="$work/bundle"
mkdir -m 700 "$private_bundle"
mounted=0
mount="$work/mount"
cleanup() {
  if [[ "$mounted" -eq 1 ]]; then
    /usr/bin/hdiutil detach "$mount" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT HUP INT TERM

for name in "${members[@]}"; do
  /bin/cp -p "$bundle_dir/$name" "$private_bundle/$name"
  [[ -f "$private_bundle/$name" && ! -L "$private_bundle/$name" ]] ||
    die "could not privately stage bundle member: $name"
done
transaction="$private_bundle/malibu-app-transaction.py"
envelope="$private_bundle/malibu-release-envelope-v1.8.41.json"
index="$private_bundle/malibu-release-index.json"
keyring="$private_bundle/malibu-release-keyring.json"
revocations="$private_bundle/malibu-release-revocations.json"

binding="$(python3 "$transaction" verify-bundle \
  --envelope "$envelope" \
  --index "$index" \
  --keyring "$keyring" \
  --revocations "$revocations" \
  --expected-key-id "$expected_key_id" \
  --minimum-keyring-generation "$minimum_keyring_generation" \
  --minimum-index-generation "$minimum_index_generation" \
  --minimum-envelope-generation "$minimum_envelope_generation" \
  --minimum-build "$minimum_build")"
dmg_name="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dmg_name"])' <<<"$binding")"
dmg_sha256="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["dmg_sha256"])' <<<"$binding")"
dmg="$private_bundle/$dmg_name"
[[ "$dmg_name" == "$expected_dmg_name" ]] || die "signed DMG name differs from this release bundle"
[[ -f "$dmg" && ! -L "$dmg" ]] || die "signed DMG is missing or unsafe"
actual_sha256="$(/usr/bin/shasum -a 256 "$dmg" | /usr/bin/awk '{print $1}')"
[[ "$actual_sha256" == "$dmg_sha256" ]] || die "DMG SHA-256 differs from the signed envelope"
mkdir -m 700 "$mount"
/usr/bin/hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mount" "$dmg" >/dev/null
mounted=1
validate_mounted_layout "$mount"
/usr/bin/ditto --rsrc --extattr --noqtn "$mount/Malibu.app" "$work/Malibu.app"
/usr/bin/hdiutil detach "$mount" >/dev/null
mounted=0

install_parent="$HOME/Applications"
if [[ ! -e "$install_parent" ]]; then
  mkdir -m 700 "$install_parent"
fi
[[ -d "$install_parent" && ! -L "$install_parent" ]] || die "user Applications path is not a real directory"
[[ "$(/usr/bin/stat -f '%u' "$install_parent")" == "$(id -u)" ]] || die "user Applications directory has the wrong owner"
install_parent_mode="$(/usr/bin/stat -f '%Lp' "$install_parent")"
(( (8#$install_parent_mode & 8#022) == 0 )) || die "user Applications directory is group/world writable"

python3 "$transaction" install \
  --source-app "$work/Malibu.app" \
  --destination-app "$install_parent/Malibu.app" \
  --state-dir "$HOME/Library/Application Support/Malibu/Release" \
  --envelope "$envelope" \
  --index "$index" \
  --keyring "$keyring" \
  --revocations "$revocations" \
  --expected-key-id "$expected_key_id" \
  --minimum-keyring-generation "$minimum_keyring_generation" \
  --minimum-index-generation "$minimum_index_generation" \
  --minimum-envelope-generation "$minimum_envelope_generation"
