#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[provision-acceptance-signing-key] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 ]] || die "usage: OWNER/REPO"
repository="$1"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository"
for command in gh openssl; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
public_key="$root/security/acceptance-candidate-signing-public.pem"
[[ ! -e "$public_key" && ! -L "$public_key" ]] || die "public key already exists: $public_key"
mkdir -p "$(dirname "$public_key")"

umask 077
temporary="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-acceptance-key.XXXXXX")"
private_key="$temporary/private.pem"
derived_public_key="$temporary/public.pem"
installed=0
cleanup() {
  rm -rf "$temporary"
  if [[ "$installed" == 1 ]]; then
    rm -f "$public_key"
  fi
}
trap cleanup EXIT

# The private key exists only in a mode-0700 temporary directory. It is piped
# directly to GitHub's protected environment secret input, never printed or
# written into the repository.
openssl genpkey \
  -algorithm EC \
  -pkeyopt ec_paramgen_curve:P-256 \
  -out "$private_key"
openssl pkey -in "$private_key" -pubout -out "$derived_public_key"
install -m 0644 "$derived_public_key" "$public_key"
installed=1

gh secret set MACPROVIDER_ACCEPTANCE_SIGNING_KEY_PEM \
  --env production-release \
  --repo "$repository" \
  < "$private_key"

installed=0
printf '[provision-acceptance-signing-key] ok: secret provisioned; review and commit %s\n' "$public_key"
