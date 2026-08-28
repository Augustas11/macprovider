#!/usr/bin/env bash
# Sign the generated SPEC-023 feed bytes with a trusted Ed25519 release key.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATIC_DIR="$REPO_ROOT/phase3-binary/dist/static"
TRUSTED_KEYS="$REPO_ROOT/phase3-binary/catalog/autotune/trusted-keys.json"
KEY_ID="${AUTOTUNE_STATIC_KEY_ID:-streamvc-autotune-static-v4}"
KEY_VERSION="${KEY_ID##*-}"
DEFAULT_KEY_PATH="$HOME/.config/macprovider/keys/autotune-static-${KEY_VERSION}.private.base64"
KEY_PATH="${AUTOTUNE_STATIC_PRIVATE_KEY_PATH:-${AUTOTUNE_STATIC_V4_PRIVATE_KEY_PATH:-$DEFAULT_KEY_PATH}}"
TMP_DIR=""

fatal() {
  printf '[resign-autotune-static] ERROR: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

[ -f "$TRUSTED_KEYS" ] || fatal "missing trusted keyring: $TRUSTED_KEYS"
[ -f "$KEY_PATH" ] || fatal "private key not found at $KEY_PATH"
command -v swift >/dev/null 2>&1 || fatal "swift is required"
command -v python3 >/dev/null 2>&1 || fatal "python3 is required"

key_mode="$(stat -f '%A' "$KEY_PATH" 2>/dev/null || stat -c '%a' "$KEY_PATH" 2>/dev/null || echo '')"
case "$key_mode" in
  600|400) ;;
  *) fatal "private key $KEY_PATH has permissions $key_mode; expected 0600 or 0400" ;;
esac

public_b64="$(python3 - "$TRUSTED_KEYS" "$KEY_ID" <<'PY'
import json, pathlib, sys
data = json.loads(pathlib.Path(sys.argv[1]).read_text())
row = data.get("keys", {}).get(sys.argv[2])
if not isinstance(row, dict) or row.get("status") not in {"active", "bridge"}:
    raise SystemExit(f"unknown, retired, or malformed signing key: {sys.argv[2]}")
print(row["public_key_base64"])
PY
)" || fatal "key ID $KEY_ID is not authorized by the trusted keyring"

# Materialize canonical feed bytes before signing. Supplying the intended
# signer avoids trusting or parsing stale sidecars while repairing a release.
python3 "$REPO_ROOT/scripts/catalog-release.py" generate --signer-key-id "$KEY_ID"

private_b64="$(tr -d '[:space:]' < "$KEY_PATH")"
[ -n "$private_b64" ] || fatal "private key file is empty"

# The private key is passed to the Swift signer as a FILE PATH, never as bytes in
# the child process environment (process env is a leakage surface even on the
# signing host). The Swift snippet reads and base64-decodes the file itself.
derived_public_b64="$(KEY_FILE="$KEY_PATH" swift -e '
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
guard let path = env["KEY_FILE"],
      let text = try? String(contentsOfFile: path, encoding: .utf8),
      let raw = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw) else { exit(1) }
print(key.publicKey.rawRepresentation.base64EncodedString())
')" || fatal "private key is not a raw 32-byte Ed25519 key"

[ "$derived_public_b64" = "$public_b64" ] ||
  fatal "private key does not derive the trusted public key for $KEY_ID"

TMP_DIR="$(umask 077 && mktemp -d -t macprovider-autotune-sign.XXXXXXXX)" ||
  fatal "mktemp -d failed"

sign_one() {
  local json_path="$1"
  local output_path="$2"
  [ -f "$json_path" ] || fatal "missing input JSON: $json_path"

  local signature_b64
  signature_b64="$(KEY_FILE="$KEY_PATH" INPUT_PATH="$json_path" swift -e '
import CryptoKit
import Foundation
let env = ProcessInfo.processInfo.environment
guard let keyPath = env["KEY_FILE"],
      let keyText = try? String(contentsOfFile: keyPath, encoding: .utf8),
      let raw = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      let path = env["INPUT_PATH"],
      let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: raw),
      let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
      let signature = try? key.signature(for: bytes) else { exit(1) }
print(signature.base64EncodedString())
')" || fatal "signing failed for $json_path"

  printf '{"key_id":"%s","alg":"ed25519","signature":"%s"}\n' \
    "$KEY_ID" "$signature_b64" > "$output_path"
}

verify_one() {
  local json_path="$1"
  local sidecar_path="$2"
  PUBLIC_B64="$public_b64" INPUT_PATH="$json_path" SIDECAR_PATH="$sidecar_path" swift -e '
import CryptoKit
import Foundation
struct Sidecar: Decodable { let key_id: String; let alg: String; let signature: String }
let env = ProcessInfo.processInfo.environment
guard let publicRaw = env["PUBLIC_B64"].flatMap({ Data(base64Encoded: $0) }),
      let input = env["INPUT_PATH"].flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }),
      let sidecarData = env["SIDECAR_PATH"].flatMap({ try? Data(contentsOf: URL(fileURLWithPath: $0)) }),
      let sidecar = try? JSONDecoder().decode(Sidecar.self, from: sidecarData),
      sidecar.alg == "ed25519",
      let signature = Data(base64Encoded: sidecar.signature),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicRaw),
      publicKey.isValidSignature(signature, for: input) else { exit(1) }
' || fatal "post-sign verification failed for $json_path"
}

candidate_json="$STATIC_DIR/autotune-candidates.json"
demand_json="$STATIC_DIR/demand-rank.json"
rate_card_json="$STATIC_DIR/rate-card.json"
candidate_sig="$TMP_DIR/autotune-candidates.json.sig"
demand_sig="$TMP_DIR/demand-rank.json.sig"
rate_card_sig="$TMP_DIR/rate-card.json.sig"

sign_one "$candidate_json" "$candidate_sig"
sign_one "$demand_json" "$demand_sig"
sign_one "$rate_card_json" "$rate_card_sig"
verify_one "$candidate_json" "$candidate_sig"
verify_one "$demand_json" "$demand_sig"
verify_one "$rate_card_json" "$rate_card_sig"

# All signatures are verified before any generated sidecar is replaced.
install -m 0644 "$candidate_sig" "$STATIC_DIR/autotune-candidates.json.sig.new"
install -m 0644 "$demand_sig" "$STATIC_DIR/demand-rank.json.sig.new"
install -m 0644 "$rate_card_sig" "$STATIC_DIR/rate-card.json.sig.new"
mv "$STATIC_DIR/autotune-candidates.json.sig.new" "$STATIC_DIR/autotune-candidates.json.sig"
mv "$STATIC_DIR/demand-rank.json.sig.new" "$STATIC_DIR/demand-rank.json.sig"
mv "$STATIC_DIR/rate-card.json.sig.new" "$STATIC_DIR/rate-card.json.sig"

python3 "$REPO_ROOT/scripts/catalog-release.py" generate --signer-key-id "$KEY_ID"
python3 "$REPO_ROOT/scripts/catalog-release.py" verify
printf '[resign-autotune-static] Signed and verified release with key_id=%s\n' "$KEY_ID"
