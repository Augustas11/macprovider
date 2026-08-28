# T0 rollup — Throughput measurement foundation

**Date:** 2026-07-07  
**Plan:** `docs/runbooks/PLAN_THROUGHPUT_ENGINEERING_RUNBOOK.md`  
**Gate:** **TG0 PROCEED** (YELLOW — 2/3 baseline models; Gemma deferred to T1-01)

---

## Task verdicts

| Task ID | Verdict | Branch / worktree | Artifact |
|---------|---------|---------------------|----------|
| T0-01 | **GREEN** | `perf/decode-bench-harness` @ `../macprovider-throughput-t0-01` | `T0-01-decode-bench-harness.md` (on branch) |
| T0-02 | **YELLOW** | same branch | `T0-02-baseline-matrix.json` + `audits/2026-07-07/bench-snapshots/*.json` (on branch) |
| T0-03 | **GREEN (structural)** | `perf/egress-trace-t0-03` @ `../macprovider-throughput-t0-03` | `T0-03-egress-profile.md` (on branch) |

---

## Reference hardware (T0-02)

| Field | Value |
|-------|-------|
| Machine | MacBook Air (Mac17,3), Apple **M5**, **32 GB** |
| macOS | 26.5 (25F71) |
| MLX pins | `mlx-swift` **0.31.6**, `mlx-swift-lm` **3.31.4** |
| Bench binary | `phase3-binary/.build/release/malibu-cli` |
| Metallib | **Must match pin** — built via `scripts/build-mlx-metallib.sh` from mlx-swift 0.31.6 checkout |

---

## Baseline matrix (p50, generation-only decode TPS)

| Model | Role | Decode TPS | Prefill TPS | TTFT | Verdict |
|-------|------|------------|-------------|------|---------|
| `Qwen2.5-7B-Instruct-4bit` | Dense control | **27.1** | 420.7 | 1.29s | GREEN (−7.2% vs Jun-30 29.2; within 10%) |
| `gpt-oss-20b-MXFP4-Q8` | MoE control | **26.3** | 314.2 | 1.85s | GREEN (vs 12 TPS catalog floor) |
| `gemma-4-26b-a4b-it-4bit` | MoE primary | — | — | — | **BLOCKED** on pin 3.31.4 |

**Swap:** none (production provider stopped via `launchctl bootout` for bench window, restored after).

---

## Key decisions (pinned session)

### D-T0-1 — TG0 closes as PROCEED (YELLOW)

Harness is validated; dense + gpt-oss baselines are sufficient to gate **T1-01 pin bump** (token-exact regression on Qwen). Gemma-4 baseline is a **hard precondition for T1-02**, not TG0.

### D-T0-2 — Gemma-4 blocked on current mlx-swift-lm pin

`Gemma4DecoderLayer` fails on MoE keys (`experts`, `router`, …). Fix is **T1-01**, not a MacProvider provider patch. Bandwidth model predicts **~42 TPS** at ~3.97B active params once loadable — **unverified**.

### D-T0-3 — Metallib version match is load-bearing (elevates T1-03)

Mismatched production metallib produced **12.4 TPS** on Qwen (wrong shaders, no error). Version-matched build restored **27.1 TPS**. **T1-03 is a merge gate**, not optional packaging polish.

### D-T0-4 — NWConnection cluster stays DEFER

T0-03 structural analysis: `BlockingChunkBuffer` decouples decode from WS send; estimated egress **~1–2%** of token period at catalog TPS. Live `MACPROVIDER_PERF_TRACE=1` run optional before T1; does not block TG0.

### D-T0-5 — PR merge order for T0 code

1. **`perf/decode-bench-harness`** — `DecodeBenchCommand` + T0-02 audit snapshots (harness value)
2. **`perf/egress-trace-t0-03`** — gated trace (can merge independently or stack after #1)

---

## gpt-oss MoE sparsity note

Implied **6.4B active** of 20B total at 26.3 TPS → MoE routing appears sparse on current stack. Useful sanity check for post-bump Gemma comparison in T1-02.

---

## TG0 recommendation

**PROCEED to T1-01** with conditions:

| Condition | Owner |
|-----------|-------|
| Merge T0-01 harness PR | Operator |
| T1-01 includes Gemma4 load fix via lm pin bump | T1-01 executor |
| T1-02 re-runs full 3-model matrix post-bump | T1-02 executor |
| T1-03 verifies metallib from bumped checkout | T1-03 executor |

---

## Next tasks (spawn order)

1. **T1-01** — MLX pin bump (`perf/mlx-0.32-bump` worktree)
2. **T1-03** — can parallel metallib rebuild once pin chosen
3. **T1-02** — blocked until T1-01 merged
