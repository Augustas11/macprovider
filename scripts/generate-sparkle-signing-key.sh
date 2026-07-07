#!/usr/bin/env bash
# Generate a Sparkle Ed25519 signing keypair for Malibu.app appcast signing.
#
# Commits only the public key into MalibuUpdateConfiguration.swift (operator
# action). Store the printed PRIVATE_B64 in GitHub secret SPARKLE_EDDSA_PRIVATE_KEY.
#
# Usage:
#   bash scripts/generate-sparkle-signing-key.sh

set -euo pipefail

work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-sparkle-key.XXXXXX")"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

openssl genpkey -algorithm ED25519 -out "$work/private.pem"
openssl pkey -in "$work/private.pem" -pubout -outform DER -out "$work/public.der"

read -r PUBLIC_B64 PRIVATE_B64 <<EOF
$(python3 - "$work/private.pem" "$work/public.der" <<'PY'
import base64, pathlib, re, sys
priv_pem = pathlib.Path(sys.argv[1]).read_text()
pub_der = pathlib.Path(sys.argv[2]).read_bytes()
priv_raw = base64.b64decode(''.join(re.findall(
    r'-----BEGIN PRIVATE KEY-----(.*?)-----END PRIVATE KEY-----',
    priv_pem,
    re.S,
)[0].split()))
seed = priv_raw[-32:]
public = pub_der[-32:]
print(base64.b64encode(public).decode())
print(base64.b64encode(seed).decode())
PY
)
EOF

cat <<EOF
Sparkle signing keypair generated.

1. Update phase3-binary/app/Sources/Malibu/System/MalibuUpdateConfiguration.swift:
     publicEdKeyBase64 = "$PUBLIC_B64"

2. Set GitHub Actions secret SPARKLE_EDDSA_PRIVATE_KEY to:
     $PRIVATE_B64

3. Re-sign appcast entries after rotation with scripts/generate-malibu-appcast.sh

Never commit the private key to git.
EOF
