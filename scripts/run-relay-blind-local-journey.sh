#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
output_dir="${1:-${TMPDIR:-/tmp}/macprovider-relay-blind-local-journey-$(date -u +%Y%m%dT%H%M%SZ)}"
case "$output_dir" in
  /*) ;;
  *) echo "output directory must be absolute" >&2; exit 2 ;;
esac
if [[ -L "$output_dir" ]]; then
  echo "output directory must not be a symlink" >&2
  exit 2
fi
output_dir="$(python3 - "$output_dir" <<'PY'
import pathlib, sys
print(pathlib.Path(sys.argv[1]).resolve(strict=False))
PY
)"
case "$output_dir" in
  "$root"|"$root"/*) echo "test evidence must be written outside the repository" >&2; exit 2 ;;
esac

umask 077
mkdir -p "$output_dir"
work="$(mktemp -d "${TMPDIR:-/tmp}/relay-blind-test-signer.XXXXXX")"
trap 'rm -rf "$work"' EXIT

log="$output_dir/go-test.log"
command=(go test -json -run '^TestRelayBlind' -race -count=1 -timeout 4m)
(
  cd "$root/test/integration"
  "${command[@]}"
) >"$log" 2>&1

python3 "$root/scripts/validate-relay-blind-local-test-log.py" "$log"

commit="$(git -C "$root" rev-parse HEAD)"
content_sha="$(python3 - "$root" <<'PY'
import hashlib, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
tracked = subprocess.check_output(["git", "-C", str(root), "diff", "--name-only", "-z", "HEAD"])
untracked = subprocess.check_output(["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"])
digest = hashlib.sha256()
paths = sorted({item.decode("utf-8", errors="strict") for item in (tracked + untracked).split(b"\0") if item})
for path_text in paths:
    if path_text == "d-inference" or path_text.startswith("d-inference/"):
        continue
    path = root / path_text
    digest.update(path_text.encode("utf-8") + b"\0")
    if path.is_file() and not path.is_symlink():
        digest.update(oct(path.stat().st_mode & 0o777).encode("ascii") + b"\0")
        digest.update(path.read_bytes())
    elif path.is_symlink():
        digest.update(path.readlink().as_posix().encode("utf-8"))
    digest.update(b"\0")
print(digest.hexdigest())
PY
)"
log_sha="$(shasum -a 256 "$log" | awk '{print $1}')"
captured_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
payload="$output_dir/payload.json"

CAPTURED_AT="$captured_at" COMMIT="$commit" CONTENT_SHA="$content_sha" LOG_SHA="$log_sha" \
python3 - "$payload" <<'PY'
import json, os, sys
payload = {
    "schema_version": "macprovider.relay-blind-local-test-evidence.v1",
    "classification": "ephemeral_test_only",
    "promotion_ready": False,
    "production_services_contacted": False,
    "production_funds_used": False,
    "physical_hardware_claimed": False,
    "signer_trust": "self_attested_ephemeral_test_key",
    "captured_at": os.environ["CAPTURED_AT"],
    "repository": {
        "commit": os.environ["COMMIT"],
        "working_tree_content_sha256": os.environ["CONTENT_SHA"],
    },
    "test_command": "go test -json -run '^TestRelayBlind' -race -count=1 -timeout 4m",
    "test_log_sha256": os.environ["LOG_SHA"],
    "result": "pass",
    "covered_journeys": [
        "real_local_swift_nonstream",
        "real_local_swift_stream",
        "buyer_cancel_after_first_encrypted_chunk",
        "provider_disconnect_before_dispatch",
        "provider_disconnect_after_first_encrypted_chunk",
        "provider_process_crash_after_first_encrypted_chunk_and_replay_rejection",
        "provider_rejects_underdeclared_input_bound",
        "provider_rejects_tampered_aead",
        "provider_reconnect_with_persisted_key_and_journal",
        "gateway_restart_replay_rejection",
        "default_off_mixed_version_and_unsupported_provider_fail_closed",
        "relay_log_plaintext_leak_scan",
    ],
    "limitations": [
        "deterministic test model runtime; no production model weights",
        "loopback gateway and coordinator only",
        "no physical hardware, notarization, promotion, or production claims",
    ],
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY

private_key="$work/ephemeral-test-private.pem"
public_key="$output_dir/ephemeral-test-public.pem"
signature="$work/signature.bin"
/usr/bin/openssl ecparam -name prime256v1 -genkey -noout -out "$private_key" >/dev/null 2>&1
/usr/bin/openssl ec -in "$private_key" -pubout -out "$public_key" >/dev/null 2>&1
/usr/bin/openssl dgst -sha256 -sign "$private_key" -out "$signature" "$payload"
/usr/bin/openssl dgst -sha256 -verify "$public_key" -signature "$signature" "$payload" >/dev/null
signature_b64="$(base64 <"$signature" | tr -d '\n')"
public_sha="$(shasum -a 256 "$public_key" | awk '{print $1}')"

SIGNATURE_B64="$signature_b64" PUBLIC_SHA="$public_sha" PAYLOAD_SHA="$(shasum -a 256 "$payload" | awk '{print $1}')" \
python3 - "$payload" "$output_dir/evidence.signed.json" <<'PY'
import json, os, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
envelope = {
    "schema_version": "macprovider.relay-blind-local-test-evidence-envelope.v1",
    "signature": {
        "algorithm": "ecdsa-p256-sha256",
        "key_class": "ephemeral_test_only",
        "public_key_sha256": os.environ["PUBLIC_SHA"],
        "payload_sha256": os.environ["PAYLOAD_SHA"],
        "value_base64": os.environ["SIGNATURE_B64"],
    },
    "signed": payload,
}
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(envelope, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

echo "relay-blind local TEST journey passed; non-promotable evidence: $output_dir/evidence.signed.json"
