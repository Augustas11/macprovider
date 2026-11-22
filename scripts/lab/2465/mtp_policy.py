"""native-mtp-bench policies for the intake windows (#2465, #2466), as
scripts/lab/ablit-perf/job-qwen-mtp-cap.sh writes them.

  mtp_policy.py write OUT --model-id ID --target-sha T --mtp-sha M --tokenizer-sha K
      --qualified-slots N --prompts 1536,4096[,CAP] --outputs 128,512 --blocks B --seed S
      --commit C --fork F --hw H --os-build O --xcode X --swift W
      [--formal] [--exclusion none|single_token_identical_pair] [--shape plain_text]
  mtp_policy.py fix OUT ERROR_TEXT
      Sets the one environment key the bench validator names (`<key> mismatch: frozen=..
      observed=..`) to the observed value; exit 1 when the error names no such key.

--formal writes the SPEC-048 R015 admission matrix (schema macprovider.native-mtp-r015-policy.v1):
the s1 cells at every prompt and output, the gated cells s2 and s<qualified_slots> at p1536-o512,
and the 1800 s sustained window on s<qualified_slots>-p1536-o512. Without it: an exploratory
policy with the s1 cells only. Thresholds: the SPEC-048 0.1.71 gate set, as the signed
qwen/qwen3.8-27b policy (docs/evidence/qwen27b-mtp-cap-2026-11-20/qwen38/r015-policy.json).
"""
import argparse
import json
import re
import sys

THRESHOLDS = {"throughput_lower_bound_min": 0.0, "ttft_p95_upper_bound_max": 0.1,
              "tpot_p95_upper_bound_max": 0.0, "chunk_gap_p99_upper_bound_max": 1.0,
              "rejection_increase_max_pp": 1.0, "min_available_memory_fraction": 0.1, "bootstrap_draws": 10000,
              "alpha": 0.05, "gated_throughput_lower_bound_min": -0.05, "gated_ttft_p95_upper_bound_max": 0.05,
              "gated_tpot_p95_upper_bound_max": 0.05}
ENV_KEYS = r"hw_model|chip|ram_gb|os_build|xcode_build_version|swift_version|mlx_fork_revision"


def write(a):
    if not re.fullmatch(r"[0-9a-f]{40}", a.fork):
        sys.exit("mlx fork revision (mlxSwiftLMRevision) not found in the source tree")
    prompts = [int(x) for x in a.prompts.split(",")]
    outputs = [int(x) for x in a.outputs.split(",")]
    qs = a.qualified_slots
    p = {
        "schema": "macprovider.native-mtp-exploratory-policy.v1", "model_id": a.model_id, "target_sha256": a.target_sha,
        "mtp_sha256": a.mtp_sha, "tokenizer_sha256": a.tokenizer_sha, "hw_model": a.hw, "chip": "Apple M3 Ultra",
        "ram_gb": 256, "os_build": a.os_build, "xcode_build_version": a.xcode, "swift_version": a.swift,
        "provider_commit": a.commit, "mlx_fork_revision": a.fork, "quantization": "4bit", "cache_mode": "paged_kv_mixed",
        "proposal_depth": 1, "run_order": "seeded_random_counterbalanced", "prompt_corpus": "deterministic_synthetic_unique_v2",
        "exclusion_rules": a.exclusion, "confidence_method": "paired_block_bootstrap_holm_v1", "qualified_slots": qs,
        "max_native_active_rows": 1, "arrival_interval_ms": 250, "slots": [1], "maximum_prompt_tokens": max(prompts),
        "prompt_tokens": prompts, "max_tokens": outputs, "gated_cells": [], "request_shape": a.shape, "warmup_runs": 1,
        "blocks": a.blocks, "seed": a.seed, "sustained_seconds": 0,
        "sustained_cell_id": f"s1-p{max(prompts)}-o{max(outputs)}", "memory_safety_margin_bytes": 8589934592,
        "thresholds": THRESHOLDS,
    }
    if a.formal:
        p.update({"schema": "macprovider.native-mtp-r015-policy.v1",
                  "gated_cells": [f"s{n}-p1536-o512" for n in sorted({2, qs})],
                  "sustained_seconds": 1800, "sustained_cell_id": f"s{qs}-p1536-o512"})
    json.dump(p, open(a.out, "w"), indent=2, sort_keys=True)


def fix(a):
    m = re.search(rf"\b({ENV_KEYS}) mismatch: frozen=(.*) observed=(.*)$", a.error, re.M)
    if not m:
        sys.exit(1)
    key, observed = m.group(1), m.group(3).strip()
    p = json.load(open(a.out))
    p[key] = int(observed) if key == "ram_gb" else observed
    json.dump(p, open(a.out, "w"), indent=2, sort_keys=True)
    print(f"policy {key} set to the observed {observed!r}")


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("write")
    w.add_argument("out")
    for k in ("model-id", "target-sha", "mtp-sha", "tokenizer-sha", "prompts", "outputs", "commit", "fork", "hw",
              "os-build", "xcode", "swift"):
        w.add_argument("--" + k, required=True)
    w.add_argument("--qualified-slots", type=int, required=True)
    w.add_argument("--blocks", type=int, required=True)
    w.add_argument("--seed", type=int, required=True)
    w.add_argument("--formal", action="store_true")
    w.add_argument("--exclusion", default="none", choices=("none", "single_token_identical_pair"))
    w.add_argument("--shape", default="plain_text", choices=("plain_text", "tools_history_reasoning"))
    f = sub.add_parser("fix")
    f.add_argument("out")
    f.add_argument("error")
    a = ap.parse_args()
    write(a) if a.cmd == "write" else fix(a)


if __name__ == "__main__":
    main()
