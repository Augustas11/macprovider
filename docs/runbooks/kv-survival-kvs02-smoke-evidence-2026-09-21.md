# KVS-02 warm-swap invalidation smoke evidence — 2026-09-21

SPEC-037 warm-swap correctness gate (persist under model A → kill → launch
same-family model B → `disk_miss_envelope`, `cached_prompt_tokens=0`, fresh
correct output; control arm: same-model relaunch → `disk_hit`). Validates
FR-KVP4 "family/alias similarity is never sufficient for a cache hit".
Sanitized: token counts, reason codes, TTFT, binary identity. No prompts,
no conversation keys, no bearer headers.

## Header

- **Date:** 2026-09-21
- **Operator:** augstar
- **Hardware tuple:** Mac Studio M3 Ultra, 256 GB unified memory, macOS 26.4.1, AC power
- **Topology:** isolated local HTTP `127.0.0.1:18080`, `--no-join`,
  `credential_store: protected_file`, `continuous_batching: off`,
  `kv_disk_cache.enabled: true`, `allow_buyer_keys: false`. Synthetic keys
  only (`conv:kvs-synth:`). Live Pearl-connected `127.0.0.1:8080` was not
  killed.
- **Model A:** `mlx-community/Qwen3-Coder-30B-A3B-Instruct-4bit`,
  snapshot `6e302ea604ad9ab206367e2c501d1571023e7b6d`,
  `model_sha256=10adb5da9840c8fe0e3036b10f6e2f8f34b41c615f3925b4132302e9cdbab9c0`
- **Model B:** `mlx-community/Qwen3-8B-4bit`,
  snapshot `545dc4251c05440727734bcd94334791f6ab0192`
  (same Qwen3 family, different model-id and sha256)
- **Prompt class:** 512 tokens (KVS-02 default; measured persist
  `prompt_tokens=520`, control `cached_prompt_tokens=528`)
- **Harness:** `test/e2e/coldwarm-ttft/kvs-02.sh --smoke` (1 cycle)

## Binary

| Role | Path | SHA-256 | Identity |
| --- | --- | --- | --- |
| KVS-02 smoke lab CLI | `/Users/a1/.local/state/kvs-01a/run-v013/macprovider-cli` | `9be5e2f18f0c7db0a11253480f511b5ab2641f0df3ef6d872c2175a47c74d5f0` | worktree build from this PR branch (`feat/037-kvs02-03`); `--version` `1.8.123` |

## Smoke (1 cycle)

- **Window:** 2026-09-21T02:51:04Z → 2026-09-21T02:52:17Z
- **Exit:** 0

| Arm | disk_reason | cached_prompt_tokens | correctness | ttft_ms |
| --- | --- | ---: | --- | ---: |
| persist (model A) | — | 0 | ok | 312 |
| miss_envelope (model B) | `disk_miss_envelope` | 0 | ok | 587 |
| control_hit (model A again) | `disk_hit` | 528 | ok | 286 |

**PASS:** `disk_miss_envelope` on cross-family warm-swap; `disk_hit` on
same-model control relaunch; no stale payload promoted.

Driver transcript: [`data/kvs02-2026-09-21/smoke.out`](data/kvs02-2026-09-21/smoke.out).  
Redacted cycle records: [`data/kvs02-2026-09-21/smoke-samples.redacted.json`](data/kvs02-2026-09-21/smoke-samples.redacted.json).

## Status

- **KVS-02 (SPEC-037-R013 warm-swap arm):** PASS on smoke. 3-cycle gate run
  pending (FR-KVP13 §6 requires `GATE_MIN_SAMPLES=3`; smoke 1 cycle is
  sufficient for correctness confidence, gate run closes SPEC-037-R013).
- **KVS-03 (sha256-change arm):** blocked pending a second snapshot of the
  same HF model-id on Studio disk (see PR body for download requirement).
