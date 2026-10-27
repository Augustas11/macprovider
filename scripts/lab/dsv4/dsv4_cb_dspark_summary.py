#!/usr/bin/env python3
"""Gate summary of the #2111 CB + DSpark window add-on.

  python3 -I dsv4_cb_dspark_summary.py <addon_out_dir> <policy.json>

Reads <dir>/throughput-r{N}.json and parity-r{N}.json (msb-throughput) and
<dir>/dspark/dspark.json (dsv4_dspark_bench.py), prints one JSON object with
the CB gate (aggregate decode tok/s at the gate row count >= the bar, exact
token parity at every parity row count) and the DSpark go/no-go.
"""
import argparse
import hashlib
import importlib.util
import json
import math
import sys
from pathlib import Path


def strict_json(text):
    def reject_constant(value):
        raise ValueError(f"non-finite JSON constant: {value}")

    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    return json.loads(text, parse_constant=reject_constant, object_pairs_hook=unique_keys)


def load(path):
    try:
        return strict_json(Path(path).read_text())
    except (OSError, ValueError):
        return None


def finite_positive(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def native_integrity(directory, depth, policy_path, campaign):
    result = {"decision": "INCOMPLETE", "qualifies_r015": False, "required_groups": 19}
    try:
        frozen = load(policy_path)
        records = [strict_json(line) for line in (directory / f"d{depth}.jsonl").read_text().splitlines() if line.strip()]
        header, runs = records[0], records[1:]
        policy_sha = hashlib.sha256(policy_path.read_bytes()).hexdigest()
        if not frozen or not (frozen.get("proposal_depth") == depth and frozen.get("quantization") == "mlx_mxfp4_mxfp8"
                and header.get("schema") == "macprovider.native-dsv4-dspark-run.v1"
                and header.get("record_type") == "header" and header.get("runtime") == "native_swift_mlx"
                and header.get("qualifies_r015") is False and header.get("policy_sha256") == policy_sha
                and header.get("provider_commit") == frozen.get("provider_commit")
                and header.get("mlx_fork_revision") == frozen.get("mlx_fork_revision")
                and header.get("target_sha256") == campaign["artifact"]["target_sha256"]
                and header.get("requests_sha256") == campaign["dspark"]["requests_sha256"]
                and header.get("tokenizer_sha256") == campaign["artifact"]["tokenizer_sha256"]
                and header.get("requested_maximum_proposal_depth") == depth
                and header.get("long_prompt_token_counts") == [8192, 32768]):
            return result
        keyed = {}
        for record in runs:
            key = (record.get("group_index"), record.get("path"))
            if key in keyed or not (record.get("schema") == header["schema"] and record.get("record_type") == "run"
                    and record.get("runtime") == "native_swift_mlx" and record.get("qualifies_r015") is False
                    and record.get("requested_maximum_proposal_depth") == depth
                    and record.get("requests_sha256") == header["requests_sha256"]):
                return result
            keyed[key] = record
        expected = {(index, path) for index in range(19) for path in ("ordinary", "native_mtp")}
        if set(keyed) != expected:
            return {**result, "recorded_runs": len(runs)}
        requests = strict_json((Path(__file__).parent / "dsv4-dspark-requests.json").read_text())["requests"]
        names = [[r["name"]] for r in requests]
        names.extend([[r["name"] for r in requests if r["stratum"] == stratum] for stratum in ("prose", "reasoning", "code")])
        for count in (8192, 32768):
            names.extend([[f"long-{count}"], [f"long-{count}-r{row}" for row in range(4)]])
        pairs = []
        for index in range(19):
            ordinary, native = (keyed[index, path] for path in ("ordinary", "native_mtp"))
            required_rows = 4 if index in (12, 13, 14, 16, 18) else 1
            for record in (ordinary, native):
                metrics = record.get("request_metrics") or []
                if (record.get("rows") != required_rows or len(metrics) != required_rows
                        or sorted(m.get("name", "") for m in metrics) != sorted(names[index])):
                    return result
                if index >= 15 and any(m.get("prompt_tokens") != (8192 if index < 17 else 32768) for m in metrics):
                    return result
                if not (finite_positive(record.get("aggregate_decode_tps")) and finite_positive(record.get("peak_phys_footprint_bytes"))
                        and all(finite_positive(m.get("ttft_seconds")) and finite_positive(m.get("decode_tps"))
                                and finite_positive(m.get("completion_tokens")) for m in metrics)):
                    return result
            drafted = native.get("mtp_drafted_by_position")
            accepted = native.get("mtp_accepted_by_position")
            if not (isinstance(drafted, list) and isinstance(accepted, list) and len(drafted) == len(accepted) == depth
                    and all(type(d) is int and type(a) is int and 0 <= a <= d for d, a in zip(drafted, accepted))
                    and finite_positive(native.get("mtp_proposed_tokens")) and finite_positive(native.get("mtp_resolved_rounds"))):
                return result
            exact = ordinary.get("parity_pass") is True and native.get("parity_pass") is True
            exact = exact and [(m.get("name"), m.get("token_sha256"), m.get("completion_tokens")) for m in ordinary["request_metrics"]] == [
                (m.get("name"), m.get("token_sha256"), m.get("completion_tokens")) for m in native["request_metrics"]]
            pairs.append({"group_index": index, "rows": required_rows, "parity_pass": exact,
                          "native_over_ordinary_decode_ratio": native["aggregate_decode_tps"] / ordinary["aggregate_decode_tps"],
                          "native_peak_phys_footprint_bytes": native["peak_phys_footprint_bytes"],
                          "mtp_drafted_by_position": drafted, "mtp_accepted_by_position": accepted})
        return {**result, "decision": "PASS" if all(p["parity_pass"] for p in pairs) else "FAIL", "groups": pairs}
    except (OSError, ValueError, IndexError, TypeError, KeyError):
        return result


def native_r015(directory, depth, policy_path, analyzer_path=None):
    result = {"decision": "INCOMPLETE", "qualifies_r015": False}
    policy = load(policy_path)
    data = directory / f"r015-d{depth}.jsonl"
    if not (policy and data.is_file() and policy.get("schema") == "macprovider.native-mtp-r015-policy.v1"
            and policy.get("proposal_depth") == depth and policy.get("quantization") == "mlx_mxfp4_mxfp8"):
        return result
    try:
        source = analyzer_path or Path(__file__).resolve().parents[2] / "native_mtp_r015_analyze.py"
        spec = importlib.util.spec_from_file_location("native_mtp_r015_analyze", source)
        analyzer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(analyzer)
        analysis = analyzer.analyze(data, policy_path)
        status = analysis.get("overall_status")
        if status not in ("PASS", "FAIL"):
            return result
        return {"decision": status, "qualifies_r015": status == "PASS", "analysis": analysis}
    except (OSError, ValueError, IndexError, TypeError, KeyError):
        return result


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("addon_out_dir", type=Path)
    ap.add_argument("policy", type=Path)
    ap.add_argument("--native-policy-dir", type=Path)
    ap.add_argument("--r015-analyzer", type=Path)
    args = ap.parse_args()
    d = args.addon_out_dir
    policy = strict_json(args.policy.read_text())
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
    if invalid or not isinstance(gate_tps, (int, float)) or not math.isfinite(gate_tps) or None in parity_ok:
        cb_decision = "INCOMPLETE"
    elif gate_tps >= cb["gate_aggregate_tps"] and all(parity_ok):
        cb_decision = "PASS"
    else:
        cb_decision = "FAIL"
    dspark = load(d / "dspark" / "dspark.json") or {}
    verdict = dspark.get("verdict") or {}
    native = {}
    for depth in (1, 2, 3, 5):
        depth_policy = (args.native_policy_dir or d / "absent-policies") / f"depth-{depth}.json"
        native[depth] = {"integrity": native_integrity(d / "native", depth, depth_policy, policy),
                         "r015": native_r015(d / "native", depth, depth_policy, args.r015_analyzer)}
    decisions = [cell[kind]["decision"] for cell in native.values() for kind in ("integrity", "r015")]
    native_decision = "INCOMPLETE" if "INCOMPLETE" in decisions else ("PASS" if all(v == "PASS" for v in decisions) else "FAIL")
    out = {
        "cb_gate": {"decision": cb_decision, "bar_tps": cb["gate_aggregate_tps"], "gate_rows": cb["gate_rows"],
                    "gate_tps": gate_tps, "rows": rows, "invalid_or_missing_cells": invalid},
        "native": {"decision": native_decision, "native_hardware_proof": native_decision == "PASS", "depths": native},
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
