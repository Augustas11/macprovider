#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 /private/var/macprovider-openssl-<name>" >&2
  exit 2
fi

sealed_root="$1"
if [[ ! "$sealed_root" =~ ^/private/var/macprovider-openssl-[A-Za-z0-9._-]+$ ]]; then
  echo "sealed OpenSSL root must be a direct /private/var/macprovider-openssl-* path" >&2
  exit 2
fi

source_root="$(cd "$(brew --prefix openssl@3)" && pwd -P)"
config_root="$(cd "$(brew --prefix)/etc/openssl@3" && pwd -P)"
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
