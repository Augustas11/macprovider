#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
AUDIT="$ROOT/scripts/audit-autotune-gate-matrix.py"
CANDIDATE="$ROOT/phase3-binary/catalog/autotune/autotune-candidates.json"
MIN_GENERATED_AT="2026-07-25T18:05:00Z"
AS_OF="2026-07-30T12:00:00Z"
TMP="$(umask 077 && mktemp -d -t macprovider-gate-matrix.XXXXXXXX)"
trap 'rm -rf "$TMP"' EXIT

python3 - "$AUDIT" "$CANDIDATE" "$TMP/complete.json" <<'PY'
import copy
import importlib.util
import json
import pathlib
import sys

spec = importlib.util.spec_from_file_location("gate_audit", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
candidate_path = pathlib.Path(sys.argv[2])
candidate = module.catalog_release.validate_candidate(candidate_path.read_bytes(), require_provenance=True)
catalog_sha = module.catalog_release.sha256(candidate_path.read_bytes())
generated_at = "2026-07-30T12:00:00Z"

for policy_field in ("draft_candidates", "workload_profiles"):
    policy_probe = copy.deepcopy(next(iter(candidate["rows"].values())))
    policy_probe[policy_field] = {}
    try:
        module.row_identity("policy-probe", policy_probe, candidate["policy_version"])
    except module.AuditError:
        pass
    else:
        raise AssertionError("policy-bearing row identity must fail closed")

providers = []
for index, (chip, memory_gb, tier) in enumerate((("Apple M5 Ultra", 64, "S"), ("Apple M5 Max", 64, "A"), ("Apple M5 Max", 64, "A"))):
    provider_id = f"provider-{index + 1}"
    hardware_hash = f"{index + 1:064x}"
    benchmarks = []
    for model_key, row in candidate["rows"].items():
        benchmarks.append({
            "model_key": model_key,
            "model_id": row["model_id"],
            "sustained_tps": 20.0 + index,
            "ttft_ms": 1000 + index,
            "model_artifact_path": f"/tmp/macprovider-model-{index}",
            "swap_detected": False,
            "thermal_throttle_detected": False,
            "artifact_sha256": row["model_sha256"],
            "candidate_catalog_sha256": catalog_sha,
            "candidate_row_identity": module.row_identity(model_key, row, candidate["policy_version"]),
            "generated_at": generated_at,
            "binary_version": "1.9.0",
            "hardware_identity_hash": hardware_hash,
        })
    providers.append({
        "provider_id": provider_id,
        "verification": {
            "status": "verified",
            "decision_reason": module.VERIFIED_DECISION_REASON,
        },
        "evidence": {
            "schema_version": "hardware_evidence.autotune.v2",
            "provider_id": provider_id,
            "generated_at": generated_at,
            "probe_protocol": "spec-023-harmony-stream.v2",
            "hardware": {
                "chip": chip,
                "memory_gb": memory_gb,
                "bandwidth_tier": tier,
                "detected": True,
                "os_version": "macOS test",
                "binary_version": "1.9.0",
                "hardware_identity_hash": hardware_hash,
                "executable_sha256": "e" * 64,
            },
            "candidate_catalog_sha256": catalog_sha,
            "recommended_model": "test-model",
            "benchmarks": benchmarks,
        },
    })

matrix = {
    "schema_version": module.MATRIX_SCHEMA,
    "source": "hardware_verifier_export",
    "generated_at": generated_at,
    "candidate_catalog_sha256": catalog_sha,
    "providers": providers,
}
pathlib.Path(sys.argv[3]).write_text(json.dumps(matrix, separators=(",", ":")))
PY

python3 "$AUDIT" --candidate "$CANDIDATE" --matrix "$TMP/complete.json" \
  --min-generated-at "$MIN_GENERATED_AT" --as-of "$AS_OF" >"$TMP/complete-report.json"
python3 - "$TMP/complete-report.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report["ready_for_matrix_review"] is True, report
assert report["rederivation_authorized"] is False, report
assert report["numeric_gates_changed"] is False, report
assert report["provider_count"] == 3, report
assert report["hardware_class_count"] == 2, report
assert report["candidate_signature_verified"] is True, report
assert report["matrix_sha256"], report
assert report["matrix_authentication"] == "not_performed_export_contract_only", report
assert all(row["ready_for_matrix_review"] for row in report["rows"].values()), report
PY

python3 - "$TMP/complete.json" "$TMP/incomplete.json" <<'PY'
import json
import pathlib
import sys

matrix = json.loads(pathlib.Path(sys.argv[1]).read_text())
matrix["providers"][0]["evidence"]["benchmarks"] = matrix["providers"][0]["evidence"]["benchmarks"][:-1]
pathlib.Path(sys.argv[2]).write_text(json.dumps(matrix, separators=(",", ":")))
PY
if python3 "$AUDIT" --candidate "$CANDIDATE" --matrix "$TMP/incomplete.json" \
  --min-generated-at "$MIN_GENERATED_AT" --as-of "$AS_OF" >"$TMP/incomplete-report.json"; then
  echo "FAIL: incomplete gate matrix was accepted" >&2
  exit 1
fi
python3 - "$TMP/incomplete-report.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report["ready_for_matrix_review"] is False, report
assert any("qwen3-coder-30b-a3b-instruct" in blocker for blocker in report["blockers"]), report
PY

python3 - "$TMP/complete.json" "$TMP/ineligible.json" <<'PY'
import copy
import json
import pathlib
import sys

matrix = json.loads(pathlib.Path(sys.argv[1]).read_text())
ineligible = copy.deepcopy(matrix)
ineligible["providers"][0]["evidence"]["hardware"]["chip"] = "Apple M5"
ineligible["providers"][0]["evidence"]["hardware"]["memory_gb"] = 32
ineligible["providers"][0]["evidence"]["hardware"]["bandwidth_tier"] = "C"
pathlib.Path(sys.argv[2]).write_text(json.dumps(ineligible, separators=(",", ":")))
PY
if python3 "$AUDIT" --candidate "$CANDIDATE" --matrix "$TMP/ineligible.json" \
  --min-generated-at "$MIN_GENERATED_AT" --as-of "$AS_OF" >"$TMP/ineligible-report.json"; then
  echo "FAIL: hardware-ineligible gate matrix was accepted" >&2
  exit 1
fi
python3 - "$TMP/ineligible-report.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert report["ready_for_matrix_review"] is False, report
assert any("qwen2.5-coder-32b-instruct:provider_quorum:2/3" in blocker for blocker in report["blockers"]), report
assert any("qwen2.5-coder-32b-instruct:hardware_ineligible_samples:1" in warning for warning in report["warnings"]), report
PY

python3 - "$TMP/complete.json" "$TMP/bad-binding.json" "$TMP/untrusted.json" "$TMP/zero-ttft.json" "$TMP/future-benchmark.json" "$TMP/missing-path.json" "$TMP/relative-path.json" "$TMP/equivalent-chips.json" "$TMP/inflated-tier.json" <<'PY'
import copy
import json
import pathlib
import sys

matrix = json.loads(pathlib.Path(sys.argv[1]).read_text())
bad_binding = copy.deepcopy(matrix)
bad_binding["providers"][0]["evidence"]["benchmarks"][0]["artifact_sha256"] = "0" * 64
pathlib.Path(sys.argv[2]).write_text(json.dumps(bad_binding, separators=(",", ":")))
untrusted = copy.deepcopy(matrix)
untrusted["providers"][0]["verification"]["status"] = "pending"
pathlib.Path(sys.argv[3]).write_text(json.dumps(untrusted, separators=(",", ":")))
zero_ttft = copy.deepcopy(matrix)
zero_ttft["providers"][0]["evidence"]["benchmarks"][0]["ttft_ms"] = 0
pathlib.Path(sys.argv[4]).write_text(json.dumps(zero_ttft, separators=(",", ":")))
future_benchmark = copy.deepcopy(matrix)
future_benchmark["providers"][0]["evidence"]["benchmarks"][0]["generated_at"] = "2099-01-01T00:00:00Z"
pathlib.Path(sys.argv[5]).write_text(json.dumps(future_benchmark, separators=(",", ":")))
missing_path = copy.deepcopy(matrix)
del missing_path["providers"][0]["evidence"]["benchmarks"][0]["model_artifact_path"]
pathlib.Path(sys.argv[6]).write_text(json.dumps(missing_path, separators=(",", ":")))
relative_path = copy.deepcopy(matrix)
relative_path["providers"][0]["evidence"]["benchmarks"][0]["model_artifact_path"] = "models/current"
pathlib.Path(sys.argv[7]).write_text(json.dumps(relative_path, separators=(",", ":")))
equivalent_chips = copy.deepcopy(matrix)
equivalent_chips["providers"][0]["evidence"]["hardware"]["chip"] = "  APPLE   M5 MAX  "
equivalent_chips["providers"][0]["evidence"]["hardware"]["bandwidth_tier"] = "A"
equivalent_chips["providers"][1]["evidence"]["hardware"]["chip"] = "m5 max"
equivalent_chips["providers"][2]["evidence"]["hardware"]["chip"] = "Apple M5 Max"
pathlib.Path(sys.argv[8]).write_text(json.dumps(equivalent_chips, separators=(",", ":")))
inflated_tier = copy.deepcopy(matrix)
inflated_tier["providers"][2]["evidence"]["hardware"]["bandwidth_tier"] = "S"
pathlib.Path(sys.argv[9]).write_text(json.dumps(inflated_tier, separators=(",", ":")))
PY
for bad_matrix in "$TMP/bad-binding.json" "$TMP/untrusted.json" "$TMP/zero-ttft.json" "$TMP/future-benchmark.json" "$TMP/missing-path.json" "$TMP/relative-path.json" "$TMP/inflated-tier.json"; do
  if python3 "$AUDIT" --candidate "$CANDIDATE" --matrix "$bad_matrix" \
    --min-generated-at "$MIN_GENERATED_AT" --as-of "$AS_OF" >/dev/null 2>&1; then
    echo "FAIL: invalid gate matrix was accepted: $bad_matrix" >&2
    exit 1
  fi
done
if python3 "$AUDIT" --candidate "$CANDIDATE" --matrix "$TMP/complete.json" \
  --min-generated-at 2026-07-25T18:04:59Z --as-of "$AS_OF" >/dev/null 2>&1; then
  echo "FAIL: pre-#745 cutoff was accepted" >&2
  exit 1
fi
if python3 "$AUDIT" --candidate "$CANDIDATE" --matrix "$TMP/equivalent-chips.json" \
  --min-generated-at "$MIN_GENERATED_AT" --as-of "$AS_OF" >"$TMP/equivalent-chips-report.json"; then
  echo "FAIL: equivalent chip labels inflated hardware-class quorum" >&2
  exit 1
fi
python3 - "$TMP/equivalent-chips-report.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert any("matrix_hardware_class_quorum:1/2" in blocker for blocker in report["blockers"]), report
PY

echo "PASS: autotune gate matrix readiness audit"
