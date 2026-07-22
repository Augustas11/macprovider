#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY="$ROOT/scripts/catalog-release.py"
CANONICAL="$ROOT/phase3-binary/catalog/autotune"
STATIC="$ROOT/phase3-binary/dist/static"
TMP="$(umask 077 && mktemp -d -t macprovider-catalog-test.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cat >"$TMP/libressl" <<'EOF'
#!/usr/bin/env bash
echo 'LibreSSL 3.3.6'
EOF
chmod +x "$TMP/libressl"
if OPENSSL_BIN="$TMP/libressl" python3 "$VERIFY" verify \
  >"$TMP/libressl.out" 2>"$TMP/libressl.err"; then
  fail "catalog verifier accepted LibreSSL for Ed25519 verification"
fi
grep -q 'OPENSSL_BIN must identify a trusted OpenSSL 3 or newer executable' \
  "$TMP/libressl.err"

cat >"$TMP/openssl-1" <<'EOF'
#!/usr/bin/env bash
echo 'OpenSSL 1.1.1w  11 Sep 2023'
EOF
chmod +x "$TMP/openssl-1"
if OPENSSL_BIN="$TMP/openssl-1" python3 "$VERIFY" verify \
  >"$TMP/openssl-1.out" 2>"$TMP/openssl-1.err"; then
  fail "catalog verifier accepted OpenSSL 1.1 for Ed25519 verification"
fi
grep -q 'OPENSSL_BIN must identify a trusted OpenSSL 3 or newer executable' \
  "$TMP/openssl-1.err"

if OPENSSL_BIN=openssl python3 "$VERIFY" verify \
  >"$TMP/relative.out" 2>"$TMP/relative.err"; then
  fail "catalog verifier accepted a relative OPENSSL_BIN override"
fi
grep -q 'OPENSSL_BIN must be an absolute path to OpenSSL 3 or newer' \
  "$TMP/relative.err"

stage_release() {
  rm -rf "$TMP/release"
  mkdir -p "$TMP/release"
  cp "$CANONICAL/release.json" "$TMP/release/"
  cp "$CANONICAL/trusted-keys.json" "$TMP/release/"
  cp "$STATIC/autotune-candidates.json" "$TMP/release/"
  cp "$STATIC/autotune-candidates.json.sig" "$TMP/release/"
  cp "$STATIC/demand-rank.json" "$TMP/release/"
  cp "$STATIC/demand-rank.json.sig" "$TMP/release/"
}

expect_rejected() {
  local label="$1"
  if python3 "$VERIFY" verify-directory --directory "$TMP/release" >/dev/null 2>&1; then
    fail "$label was accepted"
  fi
}

python3 "$VERIFY" verify
python3 - "$VERIFY" "$CANONICAL" "$STATIC" "$ROOT/phase4-coordinator/dist/coordinator.yaml" <<'PY'
import importlib.util
import base64
import json
import os
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location("catalog_release", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
canonical = pathlib.Path(sys.argv[2])
static = pathlib.Path(sys.argv[3])
coordinator_config = pathlib.Path(sys.argv[4])

assert module.root_trusted_executable("/usr/bin/true")
with tempfile.TemporaryDirectory() as directory:
    user_owned = pathlib.Path(directory) / "openssl"
    user_owned.write_text("#!/bin/sh\nexit 0\n")
    user_owned.chmod(0o755)
    assert not module.root_trusted_executable(str(user_owned))

def rejected(label, operation):
    try:
        operation()
    except module.CatalogError:
        return
    raise SystemExit(f"{label} was accepted")

rejected("duplicate top-level key", lambda: module.strict_json(b'{"a":1,"a":2}', "duplicate"))
rejected("duplicate nested key", lambda: module.strict_json(b'{"a":{"b":1,"b":2}}', "duplicate"))
rejected("NaN", lambda: module.strict_json(b'{"a":NaN}', "nan"))
rejected("Infinity", lambda: module.strict_json(b'{"a":Infinity}', "infinity"))
rejected("integer above Int64", lambda: module.strict_json(b'{"a":9223372036854775808}', "integer"))
rejected(
    "duplicate sidecar key",
    lambda: module.parse_sidecar(b'{"key_id":"v4","key_id":"v5","alg":"ed25519","signature":"x"}', "sidecar"),
)

def noncanonical_base64(raw):
    encoded = base64.b64encode(raw).decode("ascii")
    padding = len(encoded) - len(encoded.rstrip("="))
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    index = len(encoded) - padding - 1
    original = alphabet.index(encoded[index])
    alias = alphabet[original ^ 1]
    assert alias != encoded[index]
    return encoded[:index] + alias + encoded[index + 1:]

with tempfile.TemporaryDirectory() as directory:
    bad_keyring = pathlib.Path(directory) / "trusted-keys.json"
    bad_keyring.write_text(json.dumps({
        "schema_version": "macprovider.autotune-keys.v1",
        "keys": {"noncanonical": {"public_key_base64": noncanonical_base64(b"k" * 32), "status": "active"}},
    }))
    rejected("noncanonical public-key base64", lambda: module.keyring(bad_keyring))

bad_signature = json.dumps({
    "key_id": "v4",
    "alg": "ed25519",
    "signature": noncanonical_base64(b"s" * 64),
}).encode()
rejected("noncanonical signature base64", lambda: module.parse_sidecar(bad_signature, "sidecar"))

candidate = json.loads((canonical / "autotune-candidates.json").read_bytes())
candidate["generated_at"] = "2026-07-10T12:00:00"
rejected("timezone-less generated_at", lambda: module.validate_candidate(module.canonical_bytes(candidate)))

candidate = json.loads((canonical / "autotune-candidates.json").read_bytes())
candidate["version"] = " padded-release "
rejected("padded candidate version", lambda: module.validate_candidate(module.canonical_bytes(candidate)))
demand = json.loads((canonical / "demand-rank.json").read_bytes())
demand["version"] = " padded-release "
rejected("padded demand version", lambda: module.validate_demand(module.canonical_bytes(demand)))

for label, mutation in (
    ("uppercase row key", lambda rows: rows.__setitem__("UPPER", rows.pop(next(iter(rows))))),
    ("invalid model ID", lambda rows: next(iter(rows.values())).__setitem__("model_id", "org/repo with space")),
    ("non-string notes", lambda rows: next(iter(rows.values())).__setitem__("notes", 7)),
    ("falsy non-array draft candidates", lambda rows: next(iter(rows.values())).__setitem__("draft_candidates", "")),
):
    candidate = json.loads((canonical / "autotune-candidates.json").read_bytes())
    mutation(candidate["rows"])
    rejected(label, lambda candidate=candidate: module.validate_candidate(module.canonical_bytes(candidate)))

candidate = json.loads((canonical / "autotune-candidates.json").read_bytes())
row = next(iter(candidate["rows"].values()))
row["runtime_status"] = "blocked"
row["model_revision"] = "bad"
rejected("blocked row invalid optional revision", lambda: module.validate_candidate(module.canonical_bytes(candidate)))

demand = json.loads((canonical / "demand-rank.json").read_bytes())
demand["cold_start_floor"] = 0.14
rejected("changed cold_start_floor", lambda: module.validate_demand(module.canonical_bytes(demand)))

candidate = module.validate_candidate((canonical / "autotune-candidates.json").read_bytes())
demand = module.validate_demand((canonical / "demand-rank.json").read_bytes())
demand["version"] = "different-release"
rejected("mixed release pair", lambda: module.validate_pair(candidate, demand))

corpus = canonical / "testdata"
module.validate_candidate((corpus / "valid-workload-profile.json").read_bytes())
for fixture in (
    "invalid-workload-profiles-type.json",
    "invalid-draft-candidates-type.json",
    "invalid-workload-no-winner-samples.json",
):
    rejected(fixture, lambda fixture=fixture: module.validate_candidate((corpus / fixture).read_bytes()))

trusted = json.loads((canonical / "trusted-keys.json").read_bytes())["keys"]
configured = {}
in_public_keys = False
for raw_line in coordinator_config.read_text().splitlines():
    if raw_line == "  public_keys:":
        in_public_keys = True
        continue
    if in_public_keys and raw_line.startswith("    "):
        key_id, encoded = raw_line.strip().split(":", 1)
        configured[key_id] = encoded.strip().strip('"')
        continue
    if in_public_keys:
        break
expected = {
    key_id: metadata["public_key_base64"]
    for key_id, metadata in trusted.items()
    if metadata["status"] != "retired"
}
if configured != expected:
    raise SystemExit(f"coordinator public_keys drift from canonical keyring: {configured!r} != {expected!r}")

release_id, record = module.release_record((canonical / "release.json").read_bytes())
ledger = module.validate_release_ledger((canonical / "release-ledger.json").read_bytes())
expected_history = {
    "published-2026-07-02",
    "published-2026-07-03",
    "published-2026-07-06",
    "published-2026-07-06-mbase-lite",
    "published-2026-07-07-p1-gemma",
    release_id,
}
if set(ledger["releases"]) != expected_history:
    raise SystemExit(f"release ledger history is incomplete: {set(ledger['releases'])!r}")
rebound_id = "published-2026-07-07-p2-qwen3-8b"
if rebound_id in ledger["releases"] or rebound_id not in ledger["tombstones"]:
    raise SystemExit("historically rebound release ID is not permanently tombstoned")
overlapping_ledger = {
    "schema_version": "macprovider.autotune-release-ledger.v2",
    "releases": {release_id: record},
    "tombstones": {release_id: ledger["tombstones"][rebound_id]},
}
rejected(
    "published and tombstoned release overlap",
    lambda: module.validate_release_ledger(json.dumps(overlapping_ledger).encode()),
)
rejected(
    "historical release rebind",
    lambda: module.require_ledger_evolution(
        {"releases": {release_id: record}, "tombstones": {}},
        {"releases": {release_id: {**record, "policy_version": "changed"}}, "tombstones": {}},
    ),
)
rejected(
    "historical release removal",
    lambda: module.require_ledger_evolution(
        {"releases": {release_id: record}, "tombstones": {}},
        {"releases": {}, "tombstones": {}},
    ),
)
rejected(
    "historical tombstone removal",
    lambda: module.require_ledger_evolution(
        {"releases": {}, "tombstones": {rebound_id: ledger["tombstones"][rebound_id]}},
        {"releases": {}, "tombstones": {}},
    ),
)
rebound_manifest = json.loads((canonical / "release.json").read_bytes())
rebound_manifest["release_id"] = rebound_id
rejected(
    "tombstoned release reuse",
    lambda: module.updated_release_ledger(json.dumps(rebound_manifest).encode()),
)
old_base = os.environ.get("CATALOG_RELEASE_BASE_REF")
os.environ["CATALOG_RELEASE_BASE_REF"] = "refs/heads/definitely-missing-catalog-base"
try:
    rejected("missing ledger base ref", module.base_release_ledger)
finally:
    if old_base is None:
        os.environ.pop("CATALOG_RELEASE_BASE_REF", None)
    else:
        os.environ["CATALOG_RELEASE_BASE_REF"] = old_base
PY
stage_release
python3 "$VERIFY" verify-directory --directory "$TMP/release"

python3 - "$TMP/release/autotune-candidates.json" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
p.write_bytes(p.read_bytes().replace(b'"min_ram_gb":28', b'"min_ram_gb":27', 1))
PY
expect_rejected "tampered candidate bytes"

stage_release
python3 - "$TMP/release/autotune-candidates.json.sig" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
d["extra"] = True
p.write_text(json.dumps(d))
PY
expect_rejected "sidecar with unknown field"

stage_release
python3 - "$TMP/release/autotune-candidates.json.sig" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
d["key_id"] = "streamvc-autotune-static-unknown"
p.write_text(json.dumps(d))
PY
expect_rejected "unknown signing key"

stage_release
printf ' {}' >> "$TMP/release/demand-rank.json"
expect_rejected "trailing JSON"

# #608 Partial: Tier-2 identity binding derived from the autotune release.
python3 - "$VERIFY" "$CANONICAL" <<'PY'
import importlib.util
import json
import pathlib
import sys
import tempfile

spec = importlib.util.spec_from_file_location("catalog_release", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
canonical = pathlib.Path(sys.argv[2])
candidate = (canonical / "autotune-candidates.json").read_bytes()
candidate_obj = module.validate_candidate(candidate)
binding_path = canonical / "tier2-identity-binding.json"
module.validate_tier2_identity_binding(binding_path.read_bytes(), candidate, candidate_obj)

qwen = next(
    m for m in json.loads(binding_path.read_bytes())["models"]
    if m["model_id"] == "mlx-community/Qwen3-8B-4bit"
)
assert qwen["sha256"] == candidate_obj["rows"]["qwen3-8b"]["model_sha256"]

with tempfile.TemporaryDirectory() as directory:
    good = pathlib.Path(directory) / "tier2-good.json"
    bad = pathlib.Path(directory) / "tier2-bad.json"
    body = {
        "catalog_id": "binding-test",
        "expires_at": "2099-01-01T00:00:00Z",
        "issued_at": "2026-07-10T00:00:00Z",
        "models": [{
            "artifact_kind": "mlx_weight_file",
            "hash_scope": "primary_weight_file",
            "model_id": "mlx-community/Qwen3-8B-4bit",
            "min_ram_gb": 12,
            "sha256": qwen["sha256"],
            "source": "operator-curated",
        }],
        "version": 1,
    }
    good.write_text(json.dumps(body))
    module.check_tier2_binding(candidate, good.read_bytes())
    body["models"][0]["sha256"] = "f" * 64
    bad.write_text(json.dumps(body))
    try:
        module.check_tier2_binding(candidate, bad.read_bytes())
    except module.CatalogError as exc:
        if "conflicts" not in str(exc):
            raise SystemExit(f"conflict error missing detail: {exc}")
    else:
        raise SystemExit("stale/conflicting tier2 binding was accepted")

    try:
        module.derive_tier2_unsigned_body(
            candidate_obj,
            catalog_id="should-not-write",
            issued_at="2026-07-10T00:00:00Z",
            expires_at="2099-01-01T00:00:00Z",
        )
    except module.CatalogError as exc:
        if "disabled" not in str(exc):
            raise SystemExit(f"derive-tier2 disable message missing: {exc}")
    else:
        raise SystemExit("derive-tier2 must remain disabled until snapshot-manifest scope exists")

    conflicted = json.loads(candidate)
    first_key = next(iter(conflicted["rows"]))
    row = dict(conflicted["rows"][first_key])
    row["model_sha256"] = "a" * 64
    conflicted["rows"][first_key + "-dup"] = row
    try:
        module.validate_candidate(module.canonical_bytes(conflicted))
    except module.CatalogError as exc:
        if "conflicting model_sha256" not in str(exc):
            raise SystemExit(f"duplicate-hash rejection missing: {exc}")
    else:
        raise SystemExit("conflicting duplicate model_sha256 was accepted")
print("tier2 binding checks locked")
PY

stage_release
cp "$CANONICAL/tier2-identity-binding.json" "$TMP/release/" 2>/dev/null || true
python3 - "$TMP/release" <<'PY'
import json, pathlib, sys
release = pathlib.Path(sys.argv[1])
# Plant a conflicting Tier-2 catalog beside the release and ensure verify-directory fails closed.
candidate = json.loads((release / "autotune-candidates.json").read_text())
row = candidate["rows"]["qwen3-8b"]
conflict = {
    "catalog_id": "stale-backup",
    "expires_at": "2099-01-01T00:00:00Z",
    "issued_at": "2026-05-31T00:00:00Z",
    "models": [{
        "artifact_kind": "mlx_weight_file",
        "hash_scope": "primary_weight_file",
        "model_id": row["model_id"],
        "min_ram_gb": row["min_ram_gb"],
        "sha256": "0" * 64,
        "source": "stale-backup",
    }],
    "version": 1,
}
(release / "tier2-catalog.json").write_text(json.dumps(conflict))
PY
expect_rejected "conflicting tier2 catalog in release directory"

echo "PASS: catalog release generation and trust failures are locked"
