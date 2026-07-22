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
  cp "$CANONICAL/tier2-catalog.json" "$TMP/release/"
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
legacy_record = json.loads(json.dumps(record))
legacy_record["feeds"].pop("tier2-catalog.json")
rejected(
    "new two-feed release after Tier-2 membership became mandatory",
    lambda: module.require_ledger_evolution(
        {"releases": {}, "tombstones": {}},
        {"releases": {release_id: legacy_record}, "tombstones": {}},
    ),
)
module.require_ledger_evolution(
    {"releases": {release_id: legacy_record}, "tombstones": {}},
    {"releases": {release_id: record}, "tombstones": {}},
)
changed_legacy_feed = json.loads(json.dumps(record))
changed_legacy_feed["feeds"]["autotune-candidates.json"]["sha256"] = "f" * 64
rejected(
    "legacy release enrichment that rebinds an autotune feed",
    lambda: module.require_ledger_evolution(
        {"releases": {release_id: legacy_record}, "tombstones": {}},
        {"releases": {release_id: changed_legacy_feed}, "tombstones": {}},
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

# #608 Partial: Llama-3.2 live-CONFLICT fixture proves check-tier2-binding
# fails closed on the exact stale-vs-current hash pair observed on Pearl, and
# that scripts/catalog-release.py stage-tier2-republish resolves it into an
# agreeing unsigned body without touching derive-tier2's disabled path.
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
binding_data = (canonical / "tier2-identity-binding.json").read_bytes()
module.validate_tier2_identity_binding(binding_data, candidate, candidate_obj)
binding_obj = module.strict_json(binding_data, "tier2-identity-binding")

conflict_template = json.loads(
    (canonical / "testdata" / "tier2-llama-conflict-template.json").read_bytes()
)
llama_row = next(
    m for m in conflict_template["models"]
    if m["model_id"] == "mlx-community/Llama-3.2-3B-Instruct-4bit"
)
STALE_LLAMA_SHA256 = "3975387f249977e5e8bfb7ed0d352f8258ac3d630f961ce1dd952f428ee7216a"
CURRENT_LLAMA_SHA256 = "e7e5bff4248768b4db7a53afb3b514ba5867b800f63d1abd0330eaf08e54aa90"
assert llama_row["sha256"] == STALE_LLAMA_SHA256, "fixture must encode the live Pearl stale hash"
assert candidate_obj["rows"]["meta-llama/llama-3.2-3b-instruct"]["model_sha256"] == CURRENT_LLAMA_SHA256

template_bytes = module.canonical_bytes(conflict_template)

try:
    module.check_tier2_binding(candidate, template_bytes)
except module.CatalogError as exc:
    message = str(exc)
    if "Llama-3.2-3B-Instruct-4bit" not in message or STALE_LLAMA_SHA256 not in message or CURRENT_LLAMA_SHA256 not in message:
        raise SystemExit(f"Llama conflict error missing expected hashes: {exc}")
else:
    raise SystemExit("stale Llama-3.2 tier2 fixture was accepted (must fail closed)")

with tempfile.TemporaryDirectory() as directory:
    staged_path = pathlib.Path(directory) / "tier2-staged.json"
    staged_bytes, changed = module.stage_tier2_republish(
        module.load_tier2_republish_template(json.dumps(conflict_template).encode()),
        binding_obj,
    )
    if len(changed) != 1 or "Llama-3.2-3B-Instruct-4bit" not in changed[0]:
        raise SystemExit(f"stage_tier2_republish changed unexpected rows: {changed!r}")
    # Every overlapping model_id (all 9 in this fixture) must now agree with
    # the current autotune release, not just Llama.
    module.check_tier2_binding(candidate, staged_bytes)
    staged_path.write_bytes(staged_bytes)

    module.cmd_stage_tier2_republish(
        canonical / "autotune-candidates.json",
        canonical / "tier2-identity-binding.json",
        canonical / "testdata" / "tier2-llama-conflict-template.json",
        staged_path,
    )
    module.check_tier2_binding(candidate, staged_path.read_bytes())
    staged_obj = json.loads(staged_path.read_bytes())
    staged_models = {m["model_id"]: m["sha256"] for m in staged_obj["models"]}
    if staged_models["mlx-community/Llama-3.2-3B-Instruct-4bit"] != CURRENT_LLAMA_SHA256:
        raise SystemExit("staged republish body did not adopt the current autotune Llama hash")
    for entry in staged_obj["models"]:
        if entry["model_id"] == "mlx-community/Llama-3.2-3B-Instruct-4bit":
            continue
        original = next(m for m in conflict_template["models"] if m["model_id"] == entry["model_id"])
        if entry != original:
            raise SystemExit(f"stage-tier2-republish changed an already-agreeing row: {entry['model_id']}")

    # Re-staging an already-agreeing body is a no-op (idempotent).
    _, second_pass_changed = module.stage_tier2_republish(
        module.load_tier2_republish_template(staged_path.read_bytes()),
        binding_obj,
    )
    if second_pass_changed:
        raise SystemExit(f"re-staging an agreeing body should be a no-op, got: {second_pass_changed!r}")
print("llama tier2 conflict fixture + stage-tier2-republish checks locked")
PY

# #608 Partial: signed tier2-catalog.json as a release-ledger feed member.
# Historical 2-feed release-ledger rows remain valid in the immutable ledger,
# but current/new release generation and release-directory verification now
# fail closed unless Tier-2 is present, authentic, and declared.
python3 - "$VERIFY" "$CANONICAL" "$STATIC" <<'PY'
import atexit
import base64
import importlib.util
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

spec = importlib.util.spec_from_file_location("catalog_release_tier2", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
canonical = pathlib.Path(sys.argv[2])
static = pathlib.Path(sys.argv[3])

candidate_bytes = (canonical / "autotune-candidates.json").read_bytes()
candidate_obj = module.validate_candidate(candidate_bytes)
demand_bytes = (canonical / "demand-rank.json").read_bytes()
demand_obj = module.validate_demand(demand_bytes)
qwen_row = candidate_obj["rows"]["qwen3-8b"]


def rejected(label, fn):
    try:
        fn()
    except module.CatalogError:
        return
    raise SystemExit(f"{label} was accepted")


def signed_tier2(catalog_id, model_sha256, *, key_id="catalog-key-2026q2", sig="A" * 86, **overrides):
    """Build a structurally-shaped catalog with a placeholder signature.

    Used only against `validate_tier2_catalog` (structural checks) and
    `check_tier2_binding`/`manifest()` (neither authenticate signatures).
    Anything that trusts a catalog as "signed" needs `real_signed_tier2`.
    """
    body = {
        "catalog_id": catalog_id,
        "issued_at": "2026-07-01T00:00:00Z",
        "expires_at": "2099-01-01T00:00:00Z",
        "models": [{
            "artifact_kind": "mlx_weight_file",
            "hash_scope": "artifact_manifest",
            "model_id": qwen_row["model_id"],
            "sha256": model_sha256,
            "source": "operator-curated",
        }],
        "version": 1,
        "signature": {"alg": "Ed25519", "key_id": key_id, "sig": sig},
    }
    body.update(overrides)
    return json.dumps(body).encode()


# --- real Ed25519 keypairs for signature-authentication tests ---
keys_dir = pathlib.Path(tempfile.mkdtemp(prefix="tier2-test-keys-"))
atexit.register(shutil.rmtree, keys_dir, ignore_errors=True)
trusted_pub = keys_dir / "trusted.pub"
trusted_priv = keys_dir / "trusted.priv"
other_pub = keys_dir / "other.pub"
other_priv = keys_dir / "other.priv"
subprocess.run(
    ["go", "run", str(module.SIGN_CATALOG_GO_PATH), "keygen",
     "-public-out", str(trusted_pub), "-private-out", str(trusted_priv)],
    check=True, cwd=str(module.ROOT), capture_output=True, text=True,
)
subprocess.run(
    ["go", "run", str(module.SIGN_CATALOG_GO_PATH), "keygen",
     "-public-out", str(other_pub), "-private-out", str(other_priv)],
    check=True, cwd=str(module.ROOT), capture_output=True, text=True,
)
# No env-var override exists for the trusted key (an ambient env var could
# swap the trust root outside PR review); monkeypatch the module-level
# COORDINATOR_YAML_PATH constant instead, the same pattern already used for
# TIER2_CATALOG_PATH below.
original_coordinator_yaml_path = module.COORDINATOR_YAML_PATH
test_coordinator_yaml = keys_dir / "coordinator.yaml"
test_coordinator_yaml.write_text(f"tier2:\n  catalog_public_key: {trusted_pub.read_text().strip()}\n")
module.COORDINATOR_YAML_PATH = test_coordinator_yaml


def sign_with(priv_path, unsigned_body, *, key_id="test-tier2-key"):
    unsigned_path = keys_dir / f"unsigned-{abs(hash(json.dumps(unsigned_body, sort_keys=True)))}.json"
    unsigned_path.write_text(json.dumps(unsigned_body))
    result = subprocess.run(
        ["go", "run", str(module.SIGN_CATALOG_GO_PATH), "sign",
         "-key", str(priv_path), "-key-id", key_id, str(unsigned_path)],
        check=True, cwd=str(module.ROOT), capture_output=True, text=True,
    )
    return result.stdout.encode()


def unsigned_body(catalog_id, model_sha256, **overrides):
    body = {
        "catalog_id": catalog_id,
        "issued_at": "2026-07-01T00:00:00Z",
        "expires_at": "2099-01-01T00:00:00Z",
        "models": [{
            "artifact_kind": "mlx_weight_file",
            "hash_scope": "artifact_manifest",
            "model_id": qwen_row["model_id"],
            "sha256": model_sha256,
            "source": "operator-curated",
        }],
        "version": 1,
    }
    body.update(overrides)
    return body


def real_signed_tier2(catalog_id, model_sha256, *, priv_path=trusted_priv, **overrides):
    return sign_with(priv_path, unsigned_body(catalog_id, model_sha256, **overrides))


agreeing_tier2 = real_signed_tier2("test-catalog-agree", qwen_row["model_sha256"])
tier2_obj = module.validate_tier2_catalog(agreeing_tier2)
if tier2_obj["catalog_id"] != "test-catalog-agree":
    raise SystemExit("validate_tier2_catalog did not round-trip catalog_id")

trusted_key_fingerprint = module.tier2_trusted_key_fingerprint(trusted_pub.read_text().strip())

# --- signature authentication: verify_tier2_signature must actually check crypto ---
authenticated_signer = module.verify_tier2_signature(agreeing_tier2)  # trusted key + matching signature: accepted
if authenticated_signer != trusted_key_fingerprint:
    raise SystemExit("verify_tier2_signature must return the trusted key's fingerprint")

# key_id is metadata alongside the signature, not covered by
# sign-catalog.go's signed canonical body (#608 audit): a catalog whose
# signature.key_id is tampered after signing must still verify (the bytes
# Ed25519 covers are unchanged), but the *recorded* signer identity must be
# the authenticated trusted-key fingerprint, never the tampered claim.
key_id_tampered = json.loads(agreeing_tier2)
key_id_tampered["signature"]["key_id"] = "forged-id"
key_id_tampered_bytes = json.dumps(key_id_tampered).encode()
key_id_tampered_obj = module.validate_tier2_catalog(key_id_tampered_bytes)
key_id_tampered_signer = module.verify_tier2_signature(key_id_tampered_bytes)
if key_id_tampered_signer != trusted_key_fingerprint:
    raise SystemExit("verify_tier2_signature must ignore the catalog's own claimed key_id")
key_id_tampered_manifest = module.manifest(
    candidate_bytes, demand_bytes, candidate_obj, demand_obj,
    tier2=key_id_tampered_bytes, tier2_obj=key_id_tampered_obj, tier2_signer_key_id=key_id_tampered_signer,
)
if json.loads(key_id_tampered_manifest)["feeds"]["tier2-catalog.json"]["signer_key_id"] == "forged-id":
    raise SystemExit("manifest() recorded an unauthenticated key_id claim instead of the authenticated fingerprint")

print("tier2 key_id tampering does not affect authentication and is never recorded as signer_key_id")

tampered = bytearray(agreeing_tier2)
marker = b"operator-curated"
idx = bytes(tampered).find(marker)
if idx == -1:
    raise SystemExit("tamper fixture setup failed: marker not found")
tampered[idx] = ord("O")
rejected("tampered tier2 catalog bytes", lambda: module.verify_tier2_signature(bytes(tampered)))

wrong_signer_tier2 = real_signed_tier2("test-catalog-wrong-signer", qwen_row["model_sha256"], priv_path=other_priv)
rejected("tier2 catalog signed by an untrusted key", lambda: module.verify_tier2_signature(wrong_signer_tier2))

fake_go = keys_dir / "go"
fake_go.write_text("#!/usr/bin/env bash\nif [ \"$1\" = version ]; then echo 'go version go1.99.0 fake/darwin'; exit 0; fi\nexit 0\n")
fake_go.chmod(0o755)
os.environ["GO_BIN"] = str(fake_go)
os.environ["PATH"] = str(keys_dir) + os.pathsep + os.environ.get("PATH", "")
try:
    rejected(
        "wrong-signer tier2 catalog authenticated through GO_BIN/PATH spoofing",
        lambda: module.verify_tier2_signature(wrong_signer_tier2),
    )
finally:
    os.environ.pop("GO_BIN", None)

sealed_go = keys_dir / "sealed-go"
sealed_go.write_text("#!/usr/bin/env bash\nif [ \"$1\" = version ]; then echo 'go version go1.26.5 linux/amd64'; exit 0; fi\nexit 1\n")
sealed_go.chmod(0o755)
unsealed_go = keys_dir / "unsealed-go"
unsealed_go.write_text("#!/usr/bin/env bash\nif [ \"$1\" = version ]; then echo 'go version go1.26.5 linux/amd64'; exit 0; fi\nexit 1\n")
unsealed_go.chmod(0o755)
saved_fixed_go = module.FIXED_GO_EXECUTABLES
saved_always_trusted = module.ALWAYS_ROOT_TRUSTED_GO_EXECUTABLES
saved_root_trusted = module.root_trusted_executable
try:
    module.FIXED_GO_EXECUTABLES = (str(unsealed_go), str(sealed_go))
    module.ALWAYS_ROOT_TRUSTED_GO_EXECUTABLES = frozenset({str(sealed_go)})
    module.root_trusted_executable = lambda _candidate: False
    rejected("untrusted sealed Go verifier toolchain", module.go_executable)
    module.root_trusted_executable = lambda candidate: pathlib.Path(candidate) == sealed_go
    if module.go_executable() != str(sealed_go):
        raise SystemExit("root-trusted sealed Go verifier toolchain did not take precedence")
finally:
    module.FIXED_GO_EXECUTABLES = saved_fixed_go
    module.ALWAYS_ROOT_TRUSTED_GO_EXECUTABLES = saved_always_trusted
    module.root_trusted_executable = saved_root_trusted

print("sealed Go verifier toolchain requires root trust and wins candidate precedence")

# The trust root is the committed coordinator.yaml only. An ambient
# environment variable set by anything other than a reviewed PR touching
# that file must NOT be able to authenticate a catalog signed by a
# different (untrusted) key.
os.environ["CATALOG_RELEASE_TIER2_PUBLIC_KEY"] = other_pub.read_text().strip()
try:
    rejected(
        "wrong-signer tier2 catalog authenticated via an ambient env var (no such override exists)",
        lambda: module.verify_tier2_signature(wrong_signer_tier2),
    )
finally:
    os.environ.pop("CATALOG_RELEASE_TIER2_PUBLIC_KEY", None)

dummy_signed_tier2 = signed_tier2("test-catalog-dummy-sig", qwen_row["model_sha256"])
module.validate_tier2_catalog(dummy_signed_tier2)  # structurally valid...
rejected("tier2 catalog with a structurally-valid but non-cryptographic signature",
          lambda: module.verify_tier2_signature(dummy_signed_tier2))  # ...but not authentic

expired_tier2 = signed_tier2(
    "test-catalog-expired", qwen_row["model_sha256"],
    issued_at="2020-01-01T00:00:00Z", expires_at="2020-06-01T00:00:00Z",
)
rejected("expired tier2 catalog", lambda: module.validate_tier2_catalog(expired_tier2))

print("tier2 signature authentication (tamper/wrong-key/dummy-sig/expiry) rejects as expected")

# --- structural rejections mirroring scripts/sign-catalog.go validateCatalogBody ---
base_body = json.loads(agreeing_tier2)


def mutated(mutation):
    body = json.loads(json.dumps(base_body))
    mutation(body)
    return json.dumps(body).encode()


rejected("missing signature field", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b.pop("signature"))
))
rejected("unknown top-level field", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b.__setitem__("extra", True))
))
rejected("non-Ed25519 alg", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["signature"].__setitem__("alg", "ed25519"))
))
rejected("short signature", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["signature"].__setitem__("sig", "AA"))
))
rejected("non-base64url signature", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["signature"].__setitem__("sig", "not base64!"))
))
rejected("version must be 1", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b.__setitem__("version", 2))
))
rejected("issued_at after expires_at", lambda: module.validate_tier2_catalog(
    mutated(lambda b: (b.__setitem__("issued_at", "2099-06-01T00:00:00Z")))
))
rejected("empty models", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b.__setitem__("models", []))
))
rejected("unsupported hash_scope", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["models"][0].__setitem__("hash_scope", "bogus_scope"))
))
rejected("unsupported artifact_kind", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["models"][0].__setitem__("artifact_kind", "gguf"))
))
rejected("bad sha256 format", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["models"][0].__setitem__("sha256", "not-hex"))
))
rejected("duplicate model_id case-insensitive", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["models"].append({**b["models"][0], "model_id": b["models"][0]["model_id"].upper()}))
))
rejected("boolean version coincidentally equal to 1", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b.__setitem__("version", True))
))
rejected("float version coincidentally equal to 1", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b.__setitem__("version", 1.0))
))
rejected("non-string hash_scope", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["models"][0].__setitem__("hash_scope", ["artifact_manifest"]))
))
rejected("padded base64 signature", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["signature"].__setitem__("sig", "A" * 84 + "=="))
))
rejected("standard-alphabet (non-urlsafe) signature", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["signature"].__setitem__("sig", "A" * 84 + "+/"))
))


def malleable_variant(value):
    """Find a same-length base64url string that decodes to the same bytes
    as `value` but is not itself the canonical encoding (trailing unused
    bits in the final character differ). Returns None if no such variant
    exists among the base64url alphabet."""
    alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    pad = "=" * (-len(value) % 4)
    original = base64.urlsafe_b64decode(value + pad)
    for c in alphabet:
        if c == value[-1]:
            continue
        candidate = value[:-1] + c
        try:
            if base64.urlsafe_b64decode(candidate + pad) == original:
                return candidate
        except Exception:
            continue
    return None


malleable_sig = malleable_variant(base_body["signature"]["sig"])
if malleable_sig is None:
    raise SystemExit("malleability probe setup failed: no alternate trailing-bit signature found")
rejected("non-canonical base64url signature (trailing-bit malleability)", lambda: module.validate_tier2_catalog(
    mutated(lambda b: b["signature"].__setitem__("sig", malleable_sig))
))

malleable_pubkey = malleable_variant(trusted_pub.read_text().strip())
if malleable_pubkey is None:
    raise SystemExit("malleability probe setup failed: no alternate trailing-bit public key found")
rejected(
    "non-canonical base64url public key (trailing-bit malleability)",
    lambda: module.canonical_urlsafe_b64_decode(malleable_pubkey, 32, "test pubkey"),
)

module.validate_tier2_catalog(agreeing_tier2)  # baseline still accepted after mutation probes

# --- check-tier2-binding fail-closed on conflicting hash ---
conflicting_tier2 = signed_tier2("test-catalog-conflict", "f" * 64)
module.check_tier2_binding(candidate_bytes, agreeing_tier2)
try:
    module.check_tier2_binding(candidate_bytes, conflicting_tier2)
except module.CatalogError as exc:
    if "conflicts" not in str(exc):
        raise SystemExit(f"tier2 feed conflict error missing detail: {exc}")
else:
    raise SystemExit("conflicting tier2 feed candidate was accepted")

# --- manifest() binds tier2-catalog.json as a third feed ---
# signer_key_id must come from the authenticated verify_tier2_signature()
# result (a fingerprint of the trusted key), NOT from the catalog's own
# unauthenticated signature.key_id claim (#608 audit).
manifest_with_tier2 = module.manifest(
    candidate_bytes, demand_bytes, candidate_obj, demand_obj,
    tier2=agreeing_tier2, tier2_obj=tier2_obj, tier2_signer_key_id=trusted_key_fingerprint,
)
manifest_value = json.loads(manifest_with_tier2)
if set(manifest_value["feeds"]) != {"autotune-candidates.json", "demand-rank.json", "tier2-catalog.json"}:
    raise SystemExit(f"tier2 feed missing from manifest: {sorted(manifest_value['feeds'])}")
tier2_feed = manifest_value["feeds"]["tier2-catalog.json"]
if tier2_feed["sha256"] != module.sha256(agreeing_tier2) or tier2_feed["bytes"] != len(agreeing_tier2):
    raise SystemExit("tier2 feed digest/bytes do not bind the signed catalog")
if tier2_feed["version"] != "test-catalog-agree" or tier2_feed["signer_key_id"] != trusted_key_fingerprint:
    raise SystemExit("tier2 feed version must come from the signed catalog; signer_key_id from the authenticated trusted key")

rejected(
    "manifest() with tier2 bytes but no authenticated tier2_signer_key_id",
    lambda: module.manifest(
        candidate_bytes, demand_bytes, candidate_obj, demand_obj,
        tier2=agreeing_tier2, tier2_obj=tier2_obj,
    ),
)

manifest_without_tier2 = module.manifest(candidate_bytes, demand_bytes, candidate_obj, demand_obj)
if "tier2-catalog.json" in json.loads(manifest_without_tier2)["feeds"]:
    raise SystemExit("manifest() must omit tier2-catalog.json when tier2 bytes are not supplied")

# --- release-ledger: historical 2-feed rows stay valid; new 3-feed rows are accepted ---
hist_release_id, hist_record = module.release_record(manifest_without_tier2)

# A synthetic later release_id proves the 3-feed shape is accepted for *new*
# rows without disturbing the real historical row's 2-feed shape.
new_candidate_obj = json.loads(json.dumps(candidate_obj))
new_candidate_obj["version"] = "published-2026-07-20-tier2-bound"
new_demand_obj = json.loads(json.dumps(demand_obj))
new_demand_obj["version"] = new_candidate_obj["version"]
new_manifest_with_tier2 = module.manifest(
    candidate_bytes, demand_bytes, new_candidate_obj, new_demand_obj,
    tier2=agreeing_tier2, tier2_obj=tier2_obj, tier2_signer_key_id=trusted_key_fingerprint,
)
bound_release_id, bound_record = module.release_record(new_manifest_with_tier2)
if bound_release_id == hist_release_id:
    raise SystemExit("synthetic tier2-bound release_id must differ from the real historical release_id")

legacy_ledger = {
    "schema_version": "macprovider.autotune-release-ledger.v2",
    "releases": {hist_release_id: hist_record},
    "tombstones": {},
}
module.validate_release_ledger(json.dumps(legacy_ledger).encode())

tier2_bound_ledger = {
    "schema_version": "macprovider.autotune-release-ledger.v2",
    "releases": {
        hist_release_id: hist_record,
        bound_release_id: bound_record,
    },
    "tombstones": {},
}
module.validate_release_ledger(json.dumps(tier2_bound_ledger).encode())

# Historical rows must not silently gain/require Tier-2, and rows must not mix
# an unexpected feed name into either accepted shape.
hybrid_ledger = json.loads(json.dumps(tier2_bound_ledger))
hybrid_ledger["releases"][bound_release_id]["feeds"]["mystery.json"] = (
    hybrid_ledger["releases"][bound_release_id]["feeds"].pop("demand-rank.json")
)
rejected("unexpected feed name set", lambda: module.validate_release_ledger(json.dumps(hybrid_ledger).encode()))

# tier2-catalog.json's `version` field is the signed catalog_id, not the
# autotune release_id — legacy feeds still must match release_id exactly.
mismatched_autotune_version = json.loads(json.dumps(tier2_bound_ledger))
mismatched_autotune_version["releases"][bound_release_id]["feeds"]["autotune-candidates.json"]["version"] = "wrong"
rejected(
    "autotune feed version must equal release_id even with tier2 bound",
    lambda: module.validate_release_ledger(json.dumps(mismatched_autotune_version).encode()),
)

print("release-ledger accepts historical 2-feed rows and Tier-2-bound 3-feed rows")

# --- generate(): Tier-2 is mandatory for current/new releases ---
original_tier2_path = module.TIER2_CATALOG_PATH
staged_tier2_dir = pathlib.Path(tempfile.mkdtemp(prefix="tier2-test-staged-"))
atexit.register(shutil.rmtree, staged_tier2_dir, ignore_errors=True)
try:
    module.TIER2_CATALOG_PATH = staged_tier2_dir / "tier2-catalog.json"

    rejected("generate without tier2-catalog.json", module.require_tier2_catalog)

    module.TIER2_CATALOG_PATH.write_bytes(agreeing_tier2)
    returned_tier2, returned_obj, returned_signer = module.require_tier2_catalog()
    if returned_tier2 != agreeing_tier2 or returned_obj["catalog_id"] != "test-catalog-agree":
        raise SystemExit("require_tier2_catalog did not round-trip the signed catalog")
    if returned_signer != trusted_key_fingerprint:
        raise SystemExit("require_tier2_catalog did not return the authenticated signer fingerprint")

    module.TIER2_CATALOG_PATH.write_bytes(dummy_signed_tier2)
    rejected(
        "require_tier2_catalog with a structurally-valid but unauthenticated catalog",
        module.require_tier2_catalog,
    )
finally:
    module.TIER2_CATALOG_PATH = original_tier2_path

print("generate() requires an authenticated tier2-catalog.json feed")

# --- verify_directory: tier2-catalog.json must be a declared, authentic feed member ---
with tempfile.TemporaryDirectory() as directory:
    release = pathlib.Path(directory)
    shutil.copy(canonical / "trusted-keys.json", release / "trusted-keys.json")
    for name in ("autotune-candidates.json", "demand-rank.json"):
        shutil.copy(static / name, release / name)
        shutil.copy(static / f"{name}.sig", release / f"{name}.sig")

    # Happy path: tier2-catalog.json present, authentic, AND declared in release.json.
    (release / "tier2-catalog.json").write_bytes(agreeing_tier2)
    (release / "release.json").write_bytes(manifest_with_tier2)
    module.verify_directory(release)

    missing_coordinator_yaml = release / "missing-coordinator.yaml"
    module.COORDINATOR_YAML_PATH = missing_coordinator_yaml
    module.verify_directory(release, trusted_pub)
    explicit_coordinator_yaml = release / "explicit-coordinator.yaml"
    explicit_coordinator_yaml.write_text(
        f"tier2:\n  catalog_public_key: {trusted_pub.read_text().strip()}\n"
    )
    module.verify_directory(release, tier2_coordinator_config=explicit_coordinator_yaml)
    public_key_link = release / "tier2-catalog.pub"
    public_key_link.symlink_to(trusted_pub)
    rejected(
        "verify_directory with a symlinked explicit Tier-2 trust root",
        lambda: module.verify_directory(release, public_key_link),
    )
    public_key_hardlink_source = release / "tier2-hardlink-source.pub"
    public_key_hardlink_source.write_text(trusted_pub.read_text())
    public_key_hardlink = release / "tier2-hardlink.pub"
    os.link(public_key_hardlink_source, public_key_hardlink)
    rejected(
        "verify_directory with a hardlinked explicit Tier-2 trust root",
        lambda: module.verify_directory(release, public_key_hardlink),
    )
    coordinator_config_link = release / "coordinator-link.yaml"
    coordinator_config_link.symlink_to(explicit_coordinator_yaml)
    rejected(
        "verify_directory with a symlinked explicit coordinator trust config",
        lambda: module.verify_directory(release, tier2_coordinator_config=coordinator_config_link),
    )
    coordinator_config_hardlink = release / "coordinator-hardlink.yaml"
    os.link(explicit_coordinator_yaml, coordinator_config_hardlink)
    rejected(
        "verify_directory with a hardlinked explicit coordinator trust config",
        lambda: module.verify_directory(release, tier2_coordinator_config=coordinator_config_hardlink),
    )
    privileged_source = release / "privileged-source.pub"
    privileged_source.write_text(trusted_pub.read_text())
    original_geteuid = module.os.geteuid
    try:
        module.os.geteuid = lambda: 0
        rejected(
            "privileged trust root under a non-root-owned path",
            lambda: module.load_tier2_trusted_public_key(privileged_source),
        )
    finally:
        module.os.geteuid = original_geteuid
    module.COORDINATOR_YAML_PATH = test_coordinator_yaml

    (release / "tier2-catalog.json").unlink()
    rejected("verify_directory without tier2-catalog.json", lambda: module.verify_directory(release))
    (release / "tier2-catalog.json").write_bytes(agreeing_tier2)

    # Undeclared: an agreeing tier2-catalog.json sitting beside a release.json
    # that only binds the legacy 2 feeds must fail closed (feed membership,
    # not just digest overlap, is what #608 requires).
    (release / "release.json").write_bytes(manifest_without_tier2)
    try:
        module.verify_directory(release)
    except module.CatalogError as exc:
        if "manifest does not bind the feed bytes" not in str(exc):
            raise SystemExit(f"undeclared tier2 catalog rejected for the wrong reason: {exc}")
    else:
        raise SystemExit("undeclared tier2-catalog.json feed membership was accepted")

    # A staged catalog that is structurally declared but forged/unauthenticated
    # must fail closed even though its bytes match the declared manifest digest.
    # tier2_signer_key_id here is a fabricated claim (this manifest is built
    # directly, bypassing verify_tier2_signature, to simulate a forged
    # release.json); verify_directory must re-authenticate independently and
    # reject regardless of what signer_key_id the manifest claims.
    forged_manifest = module.manifest(
        candidate_bytes, demand_bytes, candidate_obj, demand_obj,
        tier2=wrong_signer_tier2, tier2_obj=module.validate_tier2_catalog(wrong_signer_tier2),
        tier2_signer_key_id="forged-claim-does-not-matter",
    )
    (release / "tier2-catalog.json").write_bytes(wrong_signer_tier2)
    (release / "release.json").write_bytes(forged_manifest)
    rejected("verify_directory with a declared but untrusted-signer tier2-catalog.json",
              lambda: module.verify_directory(release))

print("verify-directory requires tier2-catalog.json to be a declared AND authenticated feed member")

module.COORDINATOR_YAML_PATH = original_coordinator_yaml_path
PY

echo "PASS: catalog release generation and trust failures are locked"
