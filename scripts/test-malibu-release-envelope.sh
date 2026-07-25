#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tool="$repo_root/scripts/malibu-release-envelope.py"
committed_keyring="$repo_root/phase3-binary/app/release-trust/malibu-release-keyring.json"
committed_revocations="$repo_root/phase3-binary/app/release-trust/malibu-release-revocations.json"
work="$(mktemp -d "${TMPDIR:-/tmp}/malibu-release-envelope.XXXXXX")"
trap 'rm -rf "$work"' EXIT

python3 "$tool" validate-trust \
  --keyring "$committed_keyring" \
  --revocations "$committed_revocations"

openssl ecparam -name prime256v1 -genkey -noout -out "$work/private.pem" 2>/dev/null
openssl pkey -in "$work/private.pem" -pubout -out "$work/public.pem" 2>/dev/null
public_digest="$(openssl pkey -pubin -in "$work/public.pem" -outform DER 2>/dev/null | shasum -a 256 | awk '{print $1}')"

python3 - "$work" "$public_digest" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
public_digest = sys.argv[2]
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
keyring = {
    "generation": 1,
    "keys": [{
        "algorithm": "ecdsa-p256-sha256",
        "key_id": "test-key",
        "public_key_path": "public.pem",
        "public_key_spki_sha256": public_digest,
        "status": "active",
    }],
    "schema_version": "malibu-release-keyring.v1",
}
revocations = {
    "generation": 1,
    "issued_at": "2030-01-01T00:00:00Z",
    "keyring_generation": 1,
    "revoked_key_ids": [],
    "revoked_keyring_generations": [],
    "schema_version": "malibu-release-revocations.v1",
}
(root / "keyring.json").write_bytes(canonical(keyring))
(root / "revocations.json").write_bytes(canonical(revocations))
payload = {
    "app": {
        "build": 41,
        "bundle_id": "tech.malibu.app",
        "designated_requirement": "identifier tech.malibu.app and certificate leaf[subject.OU] = YF7XNRJUG4",
        "entry_count": 7,
        "marketing_version": "1.8.41",
        "release_tag": "malibu-v1.8.41",
        "root_mode": 0o755,
        "source_commit": "1" * 40,
        "team_id": "YF7XNRJUG4",
        "tree_sha256": "9" * 64,
    },
    "artifacts": {
        "bundled_provider_cli": {"sha256": "2" * 64, "version": "1.8.40"},
        "dmg": {"name": "Malibu-v1.8.41.dmg", "sha256": "3" * 64},
    },
    "envelope_generation": 41,
    "legacy_bootstrap": {
        "allowed_source_cohorts": [
            {"app_build": 39, "app_entry_count": 38, "app_root_mode": 493, "app_tree_sha256": "4" * 64, "app_version": "1.8.39", "cli_version": "1.8.30"},
            {"app_build": 39, "app_entry_count": 38, "app_root_mode": 493, "app_tree_sha256": "4" * 64, "app_version": "1.8.39", "cli_version": "1.8.32"},
        ],
        "backend_handoff_required": True,
        "caller_selected_target": False,
        "expires_at": "2030-01-02T00:00:00Z",
        "no_downgrade": True,
        "target_cli_version": "1.8.40",
        "target_manifest_sha256": "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c",
    },
    "publication": {"published_at": "2030-01-01T00:00:00Z"},
    "runtime_posture": {"hardened_runtime": True, "notarized": True, "stapled": True},
    "supported_provider": {
        "capabilities": {
            "admission_recovery": ["v1"],
            "control_socket": ["v1"],
            "credential_handoff": ["v1"],
            "local_status_reader": ["v1"],
        },
        "compatibility_sets": [{
            "id": "Augustas11/macprovider:v1.8.40@18638472fe3e885f3534eeac29ab89b4c7ffdd7a",
            "manifest_sha256": "fe17e7a3cca392edea185c304970ef6d6fb9f06ff65aa6cffed6c7d9325a161c",
            "provider_cli": {
                "designated_identifier": "live.streamvc.macprovider.cli",
                "team_id": "YF7XNRJUG4",
                "version": "1.8.40",
            },
        }],
        "provider_mutation": "forbidden",
    },
}
(root / "unsigned-envelope.json").write_bytes(canonical({
    "schema_version": "malibu-release-envelope.v1",
    "signed": payload,
}))
PY

python3 "$tool" sign-envelope \
  --input "$work/unsigned-envelope.json" \
  --private-key "$work/private.pem" \
  --key-id test-key \
  --output "$work/envelope.json" \
  --now 2030-01-01T00:00:00Z

python3 "$tool" validate-envelope \
  --input "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --minimum-build 41 \
  --minimum-envelope-generation 41 \
  --now 2030-01-01T00:00:00Z

# Expiry of the optional legacy-bootstrap bridge must not expire the ordinary
# signed app envelope itself.
python3 "$tool" validate-envelope \
  --input "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --minimum-build 41 \
  --minimum-envelope-generation 41 \
  --now 2030-01-03T00:00:00Z

python3 - "$work" <<'PY'
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
canonical = lambda value: json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
payload = {
    "channel": "stable",
    "envelope": {
        "build": 41,
        "generation": 41,
        "name": "malibu-release-envelope-v1.8.41.json",
        "sha256": hashlib.sha256((root / "envelope.json").read_bytes()).hexdigest(),
    },
    "expires_at": "2030-01-08T00:00:00Z",
    "index_generation": 1,
    "issued_at": "2030-01-01T00:00:00Z",
    "minimum_accepted_envelope_generation": 41,
    "trust": {
        "keyring_generation": 1,
        "keyring_sha256": hashlib.sha256((root / "keyring.json").read_bytes()).hexdigest(),
        "revocations_generation": 1,
        "revocations_sha256": hashlib.sha256((root / "revocations.json").read_bytes()).hexdigest(),
    },
}
(root / "unsigned-index.json").write_bytes(canonical({
    "schema_version": "malibu-release-index.v1",
    "signed": payload,
}))
PY

python3 "$tool" sign-index \
  --input "$work/unsigned-index.json" \
  --private-key "$work/private.pem" \
  --key-id test-key \
  --output "$work/index.json" \
  --now 2030-01-01T00:00:00Z

python3 "$tool" validate-index \
  --input "$work/index.json" \
  --envelope "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --minimum-index-generation 1 \
  --minimum-build 41 \
  --minimum-envelope-generation 41 \
  --now 2030-01-01T00:00:00Z

python3 "$tool" validate-index \
  --input "$work/index.json" \
  --envelope "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --minimum-index-generation 1 \
  --minimum-build 41 \
  --minimum-envelope-generation 41 \
  --now 2030-01-03T00:00:00Z

if python3 "$tool" validate-index \
  --input "$work/index.json" \
  --envelope "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --minimum-index-generation 1 \
  --minimum-build 41 \
  --minimum-envelope-generation 41 \
  --now 2030-01-10T00:00:00Z >"$work/expired-discovery.out" 2>&1; then
  echo "discovery validation accepted an expired index" >&2
  exit 1
fi
grep -q 'index: expired' "$work/expired-discovery.out"

python3 "$tool" validate-index \
  --input "$work/index.json" \
  --envelope "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --minimum-index-generation 1 \
  --minimum-build 41 \
  --minimum-envelope-generation 41 \
  --installed-transaction \
  --now 2030-01-10T00:00:00Z

if python3 "$tool" validate-index \
  --input "$work/index.json" \
  --envelope "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --minimum-index-generation 2 \
  --now 2030-01-01T00:00:00Z >"$work/rollback.out" 2>&1; then
  echo "validator accepted an index generation rollback" >&2
  exit 1
fi
grep -q 'generation rollback' "$work/rollback.out"

python3 - "$work/revocations.json" <<'PY'
import json
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
value = json.loads(path.read_text())
value["revoked_key_ids"] = ["test-key"]
path.write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
PY
if python3 "$tool" validate-envelope \
  --input "$work/envelope.json" \
  --keyring "$work/keyring.json" \
  --revocations "$work/revocations.json" \
  --expected-key-id test-key \
  --now 2030-01-01T00:00:00Z >"$work/revoked.out" 2>&1; then
  echo "validator accepted a revoked signing key" >&2
  exit 1
fi
grep -q 'key_id is revoked' "$work/revoked.out"

python3 "$tool" canonicalize \
  --input "$repo_root/schemas/fixtures/malibu-release-canonical-parity.json" \
  | xxd -p -c 1000 \
  | tr -d '\n' > "$work/parity.hex"
test "$(cat "$work/parity.hex")" = "$(tr -d '\n' < "$repo_root/schemas/fixtures/malibu-release-canonical-parity.hex")"

python3 "$repo_root/scripts/test-malibu-release-rollback-rotation.py"

echo "Malibu signed release envelope regression checks passed"
