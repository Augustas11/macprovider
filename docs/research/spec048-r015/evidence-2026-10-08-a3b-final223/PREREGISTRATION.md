# R015 preregistration for released CLI 1.8.223

Frozen before any warmup or measurement for this confirmation. The exact source
revision is `9c8c87dbff8ee00ba2c72f7923e1dce268c42e78`, the released 1.8.223
source. The prior 2026-10-06 evidence remains unchanged and is not retargeted.
Only `provider_commit` differs from that run's amended-gates policy; the tuple,
methodology, matrix, thresholds, order, seed and sustained duration are unchanged.

Policy SHA-256:
`902bf1257ec0193a3a69d66aec881d44c09225e2fc1498f8e447b339fdcf50e4`.
The JSON code block below contains the exact policy bytes, including the final
newline. A changed policy requires another preregistration and fresh output.

The exact-source lab build enables only the existing lab harness for isolated
qualification. Its executable SHA-256 is
`f045c7a79a1e42e66072ffd493a530d911d29324c3c6bfa9a6a48bfd3f60c802`.
It uses the released 223 metallib, SHA-256
`84e487182336648a826132e50e7a4cd2cae0bc77ac6eafa89cc72f3a964fdbaf`.
This lab build never joins Malibu. Final released-binary serving confirmation
uses the separately signed public 223 payload and its actual CDHash.

Acceptance remains all existing R015 analyzer gates passing; this document
records no measured result and does not enable native MTP. Subsequent signed
admission and release-journey evidence must bind the newly measured policy hash.

```json
{
  "schema": "macprovider.native-mtp-r015-policy.v1",
  "model_id": "qwen/qwen3.6-35b-a3b",
  "target_sha256": "3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1",
  "mtp_sha256": "fa01beecb6c1e76845e9880623c3b5a009baa602c52e9e9b5d12edc489a23fd2",
  "tokenizer_sha256": "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4",
  "hw_model": "Mac15,14",
  "chip": "Apple M3 Ultra",
  "ram_gb": 256,
  "os_build": "26A434",
  "xcode_build_version": "unknown",
  "swift_version": "Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)",
  "provider_commit": "9c8c87dbff8ee00ba2c72f7923e1dce268c42e78",
  "mlx_fork_revision": "ca8c384c4fb6bc7d2fbb7c70a18c34b935701805",
  "quantization": "4bit",
  "cache_mode": "paged_kv_mixed",
  "proposal_depth": 1,
  "run_order": "seeded_random_counterbalanced",
  "prompt_corpus": "deterministic_synthetic_unique_v2",
  "exclusion_rules": "none",
  "confidence_method": "paired_block_bootstrap_holm_v1",
  "qualified_slots": 8,
  "max_native_active_rows": 1,
  "arrival_interval_ms": 250,
  "slots": [
    1
  ],
  "maximum_prompt_tokens": 4096,
  "prompt_tokens": [
    1536,
    4096
  ],
  "max_tokens": [
    128,
    512
  ],
  "gated_cells": [
    "s2-p1536-o512",
    "s8-p1536-o512"
  ],
  "warmup_runs": 1,
  "blocks": 10,
  "seed": 20261006,
  "sustained_seconds": 1800,
  "sustained_cell_id": "s8-p1536-o512",
  "memory_safety_margin_bytes": 8589934592,
  "thresholds": {
    "throughput_lower_bound_min": 0.15,
    "ttft_p95_upper_bound_max": 0.1,
    "tpot_p95_upper_bound_max": 0.0,
    "chunk_gap_p99_upper_bound_max": 1.0,
    "rejection_increase_max_pp": 1.0,
    "min_available_memory_fraction": 0.1,
    "bootstrap_draws": 10000,
    "alpha": 0.05,
    "gated_throughput_lower_bound_min": -0.05,
    "gated_ttft_p95_upper_bound_max": 0.05,
    "gated_tpot_p95_upper_bound_max": 0.05
  }
}
```
