#!/bin/bash
set -euo pipefail

sealed_root="${0%/*}"
if [[ ! "$sealed_root" =~ ^/private/var/macprovider-openssl-[A-Za-z0-9._-]+$ ]]; then
  echo "sealed OpenSSL wrapper must run from its root-trusted installation" >&2
  exit 126
fi

for inherited_name in "${!DYLD_@}" "${!LD_@}" "${!OPENSSL_@}"; do
  unset "$inherited_name"
done

export DYLD_LIBRARY_PATH="$sealed_root/lib"
export OPENSSL_CONF="$sealed_root/etc/openssl.cnf"
export OPENSSL_MODULES="$sealed_root/lib/ossl-modules"
exec "$sealed_root/bin/openssl" "$@"
