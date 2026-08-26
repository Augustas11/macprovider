#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '[provision-spec043-production-release-key] ERROR: %s\n' "$*" >&2
  exit 1
}

[[ "$#" == 1 ]] || die "usage: OWNER/REPO"
repository="$1"
[[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository"
for command in gh openssl python3; do
  command -v "$command" >/dev/null 2>&1 || die "required command is unavailable: $command"
done

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
public_key="$root/security/spec-043-production-release-p256-v1.pem"
keyring="$root/security/spec-043-production-release-keyring.json"
register="$root/scripts/register-spec043-production-release-key.py"
[[ -f "$register" && ! -L "$register" ]] || die "register script is absent or unsafe"
[[ ! -e "$public_key" && ! -L "$public_key" ]] || die "public key already exists: $public_key"
[[ -f "$keyring" && ! -L "$keyring" ]] || die "keyring is absent or unsafe"
python3 - "$keyring" <<'PY' || die "keyring is not empty/fail-closed"
import json
import pathlib
import sys

keyring = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
if keyring.get("keys") != []:
    raise SystemExit(1)
PY

umask 077
temporary="$(mktemp -d "${TMPDIR:-/tmp}/macprovider-spec043-production-release-key.XXXXXX")"
private_key="$temporary/private.pem"
derived_public_key="$temporary/public.pem"
original_keyring="$temporary/original-keyring.json"
cp "$keyring" "$original_keyring"
registered=0
cleanup() {
  if [[ "$registered" == 1 ]]; then
    rm -f "$public_key"
    cp "$original_keyring" "$keyring"
  fi
  rm -rf "$temporary"
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

python3 "$register" \
  --root "$root" \
  --public-key "$derived_public_key" \
  --issuer macprovider-ops \
  --valid-from 2026-08-26T00:00:00Z \
  --valid-until 2027-08-26T00:00:00Z
registered=1

gh secret set MACPROVIDER_SPEC043_PRODUCTION_RELEASE_SIGNING_KEY_PEM \
  --env production-release \
  --repo "$repository" \
  < "$private_key"

registered=0
printf '[provision-spec043-production-release-key] ok: secret provisioned; review and commit %s and %s\n' \
  "${public_key#"$root"/}" \
  "${keyring#"$root"/}"
