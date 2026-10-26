#!/usr/bin/env python3
"""Gate summary of the #2111 CB + DSpark window add-on.

  python3 -I dsv4_cb_dspark_summary.py <addon_out_dir> <policy.json>

Reads <dir>/throughput-r{N}.json and parity-r{N}.json (msb-throughput) and
<dir>/dspark/dspark.json (dsv4_dspark_bench.py), prints one JSON object with
the CB gate (aggregate decode tok/s at the gate row count >= the bar, exact
token parity at every parity row count) and the DSpark go/no-go.
"""
import json
import math
import sys
from pathlib import Path


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError):
        return None


def finite_positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    d = Path(sys.argv[1])
    policy = json.loads(Path(sys.argv[2]).read_text())
    cb = policy["cb"]
    invalid = []
    rows = {}
    for n in cb["rows"]:
        t = load(d / f"throughput-r{n}.json")
        p = load(d / f"parity-r{n}.json")
        valid_t = t is not None and all(t.get(k) == v for k, v in {
            "rows": n, "runs": cb["runs"], "scenario": "throughput", "engine": cb["engine"],
            "promptTokensPerRow": cb["prompt_tokens"], "decodeTokensPerRow": cb["decode_tokens"], "compiled": False
        }.items()) and len(t.get("aggregateTPSRuns") or []) == cb["runs"]
        valid_t = valid_t and all(finite_positive(v) for v in t["aggregateTPSRuns"]) and finite_positive(t.get("aggregateTPSp50"))
        valid_p = p is not None and all(p.get(k) == v for k, v in {
            "rows": n, "runs": 1, "scenario": "parity", "engine": cb["engine"], "compiled": False,
            "promptTokensPerRow": cb["prompt_tokens"], "decodeTokensPerRow": cb["decode_tokens"]
        }.items())
        if not valid_t:
            invalid.append(f"throughput-r{n}")
            t = None
        if not valid_p:
            invalid.append(f"parity-r{n}")
            p = None
        reused = (d / f"throughput-r{n}.reused-from").read_text().strip() if (d / f"throughput-r{n}.reused-from").exists() else None
        parity = ((p or {}).get("leftovers") or {}).get("parity") or {}
        rows[n] = {
            "aggregate_tps_p50": (t or {}).get("aggregateTPSp50"),
            "aggregate_cv_pct": (t or {}).get("aggregateCVPct"),
            "serial_tps_p50": (t or {}).get("productionSerialTPSp50"),
            "aggregate_vs_serial": (t or {}).get("aggregateVsProductionSerial"),
            "serial_ttft_s": ((t or {}).get("productionSerialTTFTSecondsRuns") or [None])[0],
            "peak_phys_footprint_mb": (t or {}).get("peakPhysFootprintMB"),
            "throughput_reused_from": reused,
            "parity_pass": (parity.get("pass") is True and parity.get("comparedTokens", 0) >= cb["parity_tokens"]) if p else None,
            "parity_compared_tokens": parity.get("comparedTokens"),
            "parity_usage_pass": (p or {}).get("leftovers", {}).get("usagePass") if p else None,
        }
    gate_tps = rows.get(cb["gate_rows"], {}).get("aggregate_tps_p50")
    parity_ok = [rows.get(n, {}).get("parity_pass") for n in cb["parity_rows"]]
    if not isinstance(gate_tps, (int, float)) or not math.isfinite(gate_tps) or None in parity_ok:
        cb_decision = "INCOMPLETE"
    elif gate_tps >= cb["gate_aggregate_tps"] and all(parity_ok):
        cb_decision = "PASS"
    else:
        cb_decision = "FAIL"
    dspark = load(d / "dspark" / "dspark.json") or {}
    verdict = dspark.get("verdict") or {}
    out = {
        "cb_gate": {"decision": cb_decision, "bar_tps": cb["gate_aggregate_tps"], "gate_rows": cb["gate_rows"],
                    "gate_tps": gate_tps, "rows": rows, "invalid_or_missing_cells": invalid},
        "dspark": {"proof_scope": "reference_only", "native_hardware_proof": False,
                   "decision": verdict.get("decision", "INCOMPLETE"), "status": dspark.get("status"),
                   "reference": (dspark.get("meta") or {}).get("lane"),
                   "fidelity": (dspark.get("meta") or {}).get("fidelity"),
                   "best_block_size": verdict.get("best_depth"), "go_block_sizes": verdict.get("go_depths"),
                   "strata_clearing_bar": verdict.get("strata_clearing_bar"), "by_block_size": verdict.get("by_depth")},
    }
    print(json.dumps(out, indent=1))


if __name__ == "__main__":
    main()
