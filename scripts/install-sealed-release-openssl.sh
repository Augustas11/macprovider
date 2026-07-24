#!/bin/bash
set -euo pipefail

readonly expected_arch="x86_64"
readonly expected_macos_major="15"
readonly expected_openssl_version="3.6.3"
readonly expected_formula_revision="0"
readonly expected_bottle_rebuild="1"
readonly expected_bottle_tag="sequoia"
readonly expected_bottle_sha256="5477285c4ebec45713873ae4002affece39e427c5f1b655c6a3df49c6b90f924"
readonly expected_formula_sha256="00e19cdcb1b7d99058a8a15f316e5dce2e4b5cd2afee14b272e7f5448624801d"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /private/var/macprovider-openssl-<name>" >&2
  exit 2
fi

sealed_root="$1"
if [[ ! "$sealed_root" =~ ^/private/var/macprovider-openssl-[A-Za-z0-9._-]+$ ]]; then
  echo "sealed OpenSSL root must be a direct /private/var/macprovider-openssl-* path" >&2
  exit 2
fi

actual_arch="$(uname -m)"
actual_macos_major="$(sw_vers -productVersion | cut -d. -f1)"
if [ "$actual_arch" != "$expected_arch" ] ||
  [ "$actual_macos_major" != "$expected_macos_major" ]; then
  echo "sealed OpenSSL requires the reviewed macos-15 x86_64 runner" >&2
  exit 2
fi

work="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/reviewed-openssl.XXXXXX")"
trap 'rm -rf "$work"' EXIT
formula_json="$work/openssl-formula.json"
HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 openssl@3 >"$formula_json"
python3 - "$formula_json" \
  "$expected_openssl_version" "$expected_formula_revision" \
  "$expected_bottle_rebuild" "$expected_bottle_tag" \
  "$expected_bottle_sha256" "$expected_formula_sha256" <<'PY'
import json
import pathlib
import sys

(
    metadata_path,
    expected_version,
    expected_revision,
    expected_rebuild,
    expected_tag,
    expected_bottle_sha256,
    expected_formula_sha256,
) = sys.argv[1:]
payload = json.loads(pathlib.Path(metadata_path).read_text(encoding="utf-8"))
formulae = payload.get("formulae")
if not isinstance(formulae, list) or len(formulae) != 1:
    raise SystemExit("reviewed OpenSSL formula metadata must contain one formula")
formula = formulae[0]
bottle = formula.get("bottle", {}).get("stable", {})
bottle_file = bottle.get("files", {}).get(expected_tag, {})
checks = {
    "formula": (formula.get("full_name"), "openssl@3"),
    "version": (formula.get("versions", {}).get("stable"), expected_version),
    "revision": (str(formula.get("revision")), expected_revision),
    "bottle rebuild": (str(bottle.get("rebuild")), expected_rebuild),
    "bottle sha256": (bottle_file.get("sha256"), expected_bottle_sha256),
    "bottle cellar": (bottle_file.get("cellar"), "/usr/local/Cellar"),
    "formula sha256": (
        formula.get("ruby_source_checksum", {}).get("sha256"),
        expected_formula_sha256,
    ),
}
for label, (actual, expected) in checks.items():
    if actual != expected:
        raise SystemExit(
            f"reviewed OpenSSL {label} drifted: expected {expected!r}, got {actual!r}"
        )
PY

HOMEBREW_NO_AUTO_UPDATE=1 brew fetch --force \
  --bottle-tag="$expected_bottle_tag" openssl@3 >&2
bottle_path="$(
  HOMEBREW_NO_AUTO_UPDATE=1 brew --cache \
    --bottle-tag="$expected_bottle_tag" openssl@3
)"
test -f "$bottle_path"
actual_bottle_sha256="$(shasum -a 256 "$bottle_path" | awk '{print $1}')"
if [ "$actual_bottle_sha256" != "$expected_bottle_sha256" ]; then
  echo "reviewed OpenSSL bottle digest drifted" >&2
  exit 2
fi

if HOMEBREW_NO_AUTO_UPDATE=1 brew list --versions openssl@3 >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew reinstall --force-bottle openssl@3 >&2
else
  HOMEBREW_NO_AUTO_UPDATE=1 brew install --force-bottle openssl@3 >&2
fi

source_root="$(cd "$(brew --prefix openssl@3)" && pwd -P)"
expected_source_root="/usr/local/Cellar/openssl@3/$expected_openssl_version"
if [ "$source_root" != "$expected_source_root" ]; then
  echo "reviewed OpenSSL cellar path drifted: $source_root" >&2
  exit 2
fi
config_root="$source_root/.bottle/etc/openssl@3"
receipt="$source_root/INSTALL_RECEIPT.json"
python3 - "$receipt" "$expected_openssl_version" <<'PY'
import json
import pathlib
import sys

receipt_path, expected_version = sys.argv[1:]
receipt = json.loads(pathlib.Path(receipt_path).read_text(encoding="utf-8"))
if receipt.get("poured_from_bottle") is not True:
    raise SystemExit("reviewed OpenSSL was not poured from its pinned bottle")
if receipt.get("built_as_bottle") is not True:
    raise SystemExit("reviewed OpenSSL receipt does not identify a bottle build")
actual_version = receipt.get("source", {}).get("versions", {}).get("stable")
if actual_version != expected_version:
    raise SystemExit(
        f"reviewed OpenSSL receipt version drifted: {actual_version!r}"
    )
PY

for reviewed_file in \
  "$source_root/bin/openssl" \
  "$source_root/lib/libssl.3.dylib" \
  "$source_root/lib/libcrypto.3.dylib" \
  "$source_root/lib/ossl-modules/legacy.dylib" \
  "$config_root/openssl.cnf"; do
  test -f "$reviewed_file"
  test ! -L "$reviewed_file"
done
"$source_root/bin/openssl" version |
  grep -F "OpenSSL $expected_openssl_version " >/dev/null

script_root="$(cd "$(dirname "$0")" && pwd -P)"
wrapper="$sealed_root/openssl"

sudo test ! -e "$sealed_root"
sudo install -d -o root -g wheel -m 0755 \
  "$sealed_root/bin" "$sealed_root/lib/ossl-modules" "$sealed_root/etc"
sudo install -o root -g wheel -m 0555 \
  "$source_root/bin/openssl" "$sealed_root/bin/openssl"
sudo install -o root -g wheel -m 0444 \
  "$source_root/lib/libssl.3.dylib" "$sealed_root/lib/libssl.3.dylib"
sudo install -o root -g wheel -m 0444 \
  "$source_root/lib/libcrypto.3.dylib" "$sealed_root/lib/libcrypto.3.dylib"
sudo install -o root -g wheel -m 0444 \
  "$source_root/lib/ossl-modules/legacy.dylib" \
  "$sealed_root/lib/ossl-modules/legacy.dylib"
sudo install -o root -g wheel -m 0444 \
  "$config_root/openssl.cnf" "$sealed_root/etc/openssl.cnf"
sudo install -o root -g wheel -m 0555 \
  "$script_root/sealed-release-openssl-wrapper.sh" "$wrapper"

python3 - "$sealed_root" <<'PY'
import pathlib
import stat
import sys

root = pathlib.Path(sys.argv[1])
paths = [root, *root.rglob("*")]
ancestors = [parent for parent in root.parents if parent != pathlib.Path(".")]
for path in [*paths, *ancestors]:
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode):
        raise SystemExit(f"sealed OpenSSL path must not be a symlink: {path}")
    if metadata.st_uid != 0 or stat.S_IMODE(metadata.st_mode) & 0o022:
        raise SystemExit(f"sealed OpenSSL path is not root-trusted: {path}")
PY

"$wrapper" version | grep -E '^OpenSSL 3\.' >/dev/null
printf '%s\n' "$wrapper"
