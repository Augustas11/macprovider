#!/usr/bin/env bash
# Re-sign the SPEC-023 static feeds (autotune-candidates.json,
# demand-rank.json) with the v3 Curve25519 (Ed25519) private key.
#
# Usage:
#   scripts/resign-autotune-static.sh                    # reads default key path
#   AUTOTUNE_STATIC_V3_PRIVATE_KEY_PATH=<path> scripts/resign-autotune-static.sh
#
# The **private** key is intentionally NOT in the repository. This
# script expects to find it at, in order of preference:
#
#   1. $AUTOTUNE_STATIC_V3_PRIVATE_KEY_PATH — explicit env override
#   2. $HOME/.config/macprovider/keys/autotune-static-v3.private.base64
#      — the operator's local secure default
#
# The file must contain the base64-encoded 32-byte raw Curve25519
# private key on a single line (whitespace tolerated). Recommended
# permissions: `chmod 0600`.
#
# The **public** key IS committed to the repo, at
# `phase3-binary/dist/static/keys/autotune-static-v3.public.base64`,
# and is also baked into `AutotuneRecommend.swift` as
# `autotune_static_json_ed25519_v3`. The signature verifier only
# needs the public key.
#
# The script signs each JSON file byte-for-byte as it lives on disk
# (no re-serialization; the signature covers the exact bytes served
# to clients), and writes a matching `.sig` sidecar next to it with:
#
#   {"key_id":"streamvc-autotune-static-v3","alg":"ed25519","signature":"<b64>"}
#
# See `phase3-binary/dist/static/keys/README.md` for the security
# posture, the rotation path, and how to generate a fresh key.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_KEY_PATH="$HOME/.config/macprovider/keys/autotune-static-v3.private.base64"
KEY_PATH="${AUTOTUNE_STATIC_V3_PRIVATE_KEY_PATH:-$DEFAULT_KEY_PATH}"
STATIC_DIR="$REPO_ROOT/phase3-binary/dist/static"
KEY_ID="streamvc-autotune-static-v3"

fatal() {
  printf '[resign-autotune-static] ERROR: %s\n' "$*" >&2
  exit 1
}

if [ ! -f "$KEY_PATH" ]; then
  cat >&2 <<EOF
[resign-autotune-static] ERROR: private key not found at $KEY_PATH.

The v3 signing private key is not committed to the repo. Place it at:

  $DEFAULT_KEY_PATH   (chmod 0600 recommended)

or set AUTOTUNE_STATIC_V3_PRIVATE_KEY_PATH to an alternate absolute path.

See phase3-binary/dist/static/keys/README.md for the security posture
and how to rotate.
EOF
  exit 1
fi

# Reject the key file if it is world-readable — a signing key with mode
# 0644 or wider is an operational red flag; refuse rather than sign
# silently.
key_mode="$(stat -f '%A' "$KEY_PATH" 2>/dev/null || stat -c '%a' "$KEY_PATH" 2>/dev/null || echo "")"
case "$key_mode" in
  600|400) ;;
  *)
    fatal "private key $KEY_PATH has permissions $key_mode; expected 0600 or 0400. Run: chmod 0600 \"$KEY_PATH\""
    ;;
esac

[ -d "$STATIC_DIR" ] || fatal "missing static dir: $STATIC_DIR"

if ! command -v swift >/dev/null 2>&1; then
  fatal "swift is required (uses CryptoKit's Curve25519.Signing to match the client verifier)"
fi

private_b64="$(tr -d '[:space:]' < "$KEY_PATH")"
[ -n "$private_b64" ] || fatal "private key file is empty"

sign_one() {
  local json_path="$1"
  local sig_path="${json_path}.sig"
  [ -f "$json_path" ] || fatal "missing input JSON: $json_path"

  local signature_b64
  signature_b64="$(PRIV_B64="$private_b64" INPUT_PATH="$json_path" \
    swift -e '
import CryptoKit
import Foundation

let env = ProcessInfo.processInfo.environment
guard let privB64 = env["PRIV_B64"],
      let inputPath = env["INPUT_PATH"] else {
  FileHandle.standardError.write(Data("missing PRIV_B64 or INPUT_PATH\n".utf8))
  exit(1)
}
guard let privRaw = Data(base64Encoded: privB64) else {
  FileHandle.standardError.write(Data("PRIV_B64 not valid base64\n".utf8))
  exit(1)
}
let key: Curve25519.Signing.PrivateKey
do {
  key = try Curve25519.Signing.PrivateKey(rawRepresentation: privRaw)
} catch {
  FileHandle.standardError.write(Data("invalid private key: \(error)\n".utf8))
  exit(1)
}
let inputURL = URL(fileURLWithPath: inputPath)
let bytes: Data
do {
  bytes = try Data(contentsOf: inputURL)
} catch {
  FileHandle.standardError.write(Data("read \(inputPath): \(error)\n".utf8))
  exit(1)
}
let signature: Data
do {
  signature = try key.signature(for: bytes)
} catch {
  FileHandle.standardError.write(Data("sign \(inputPath): \(error)\n".utf8))
  exit(1)
}
print(signature.base64EncodedString())
')"

  [ -n "$signature_b64" ] || fatal "signing produced empty output for $json_path"

  printf '{"key_id":"%s","alg":"ed25519","signature":"%s"}\n' \
    "$KEY_ID" "$signature_b64" > "$sig_path"
  printf '  signed %s -> %s\n' "$(basename "$json_path")" "$(basename "$sig_path")"
}

printf '[resign-autotune-static] Signing static feeds under %s with key_id=%s (private key: %s)\n' \
  "$STATIC_DIR" "$KEY_ID" "$KEY_PATH"
sign_one "$STATIC_DIR/autotune-candidates.json"
sign_one "$STATIC_DIR/demand-rank.json"
printf '[resign-autotune-static] Done.\n'
