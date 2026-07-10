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

echo "PASS: catalog release generation and trust failures are locked"
