# mlx-swift-lm 3.32.3 / mlx-swift 0.32.3 Studio qualification (2026-10-09)

**Status: RED at step 3 (native-MTP R015 FAIL on its frozen gates).** Step 1
and every step-2 row that can run on the Studio pass on the fixed tree, with no
regression against 1.8.230. The R015 identity blocker is fixed in `f424aa9d6`,
and R015 then ran its full matrix: parity, errors, fallbacks and memory are all
clean, but four of the 30 gated statistics miss their thresholds. Ordinary
decode got about 8% faster on this build while native-MTP decode moved only
0.5-3%, so the native lead shrank below +15% on the 4096-token cells. Steps 4
and 5 were not run.

The first attempt on `149a3c39a` failed step 1. That evidence is kept in
`superseded-149a3c39a/`, and the root cause and fix are in
`step1-root-cause.md`.

## Evidence header

| Field | Value |
| --- | --- |
| Branch / commit | `deps/mlx-swift-lm-3.32.3`. Steps 1-2 ran at `531ce132afb8410f5d7a18469045de40b0d27cbd`; step 3 ran at `f424aa9d6d381b24056e556b9d6386c47ce2bf10`. `f424aa9d6` changes only compiled-in identity constants: the `KVBuildIdentity` mlx-swift-lm revision and the MLX version string, which keys the KV cold-tier ABI and the bench's `mlx_fork_revision`. It changes no decode-path line, so steps 1-2 were not rerun (AGENTS rule 2). The Studio tree was synced each time and checked with `rsync --dry-run`. |
| Host | Mac15,14, Apple M3 Ultra, 256 GB, macOS 27.0.1 build 26A434, AC power, thermal nominal |
| Toolchain | Apple Swift 6.3.3 (swiftlang-6.3.3.1.3), Command Line Tools only (no Xcode or Metal toolchain on the Studio) |
| mlx-swift-lm | fork `Augustas11/mlx-swift-lm` `37f0d7ceacf6f5eca3ec2ceddc96d0f6e91ed2f1` (tag `3.32.3-macprovider.2`). Model code is identical to `d9897e6`. |
| mlx-swift | fork `Augustas11/mlx-swift` `d073a644c559318d93e267ed2a53baf434787a41` (tag `0.32.3-macprovider.1`). Its diff from upstream 0.32.3 `19601207` is the core submodule only. |
| Core MLX | `ff1b9483201578cf55e9c9220414c46427f20969` (`v0.32.2-macprovider.1`, upstream v0.32.2 plus host-only `quantized.cpp` routing) |
| swift-transformers / swift-jinja | `1.3.4` (`c21fdcde…`) / `2.5.1` (`4588064a…`) |
| Serve executable | `swift build -c release`, reports `1.8.230`. SHA-256 `6a0f923919b4c5212f63c9a3f96cc3b433d00780707e3f17b990d78429153c12` at `531ce132a` (steps 1-2); `ecf24bff0d27f0d93538c7ad6041d69fd72aadb31a79af64c235ad336c8c1e17` at `f424aa9d6` (current; staged for steps 4-5). |
| Lab-harness executable | `swift build -c release --product macprovider-cli -Xswiftc -DMACPROVIDER_LAB_HARNESS`. SHA-256 `1e385bd92b7a42b5a0c60da9803df58637b8495c1c552d270cc81044243ec7d2` at `531ce132a` (refused by R015); `38fc549b25b28efe2a7ef417b3ba8f9a7bc872ed8db0e38902d88e9ddaa99472` at `f424aa9d6` (R015 run). |
| `mlx.metallib` | SHA-256 `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756`, co-located with both executables. Built from the 0.32.3 kernel sources with the 0.32 kernel list now in `scripts/build-mlx-metallib.sh` (`fe398edbd`). The core fix touches host code only, so the kernel sources and the library are unchanged. |
| Models | `qwen/qwen3.6-35b-a3b` = `mlx-community/Qwen3.6-35B-A3B-4bit` rev `38740b84…`, artifact `3fed776d41b6883888541d19f71a3866acc3bc6e628402066b67e5ac0a676ff1` (the live provider's artifact). `qwen/qwen3.6-27b` = `mlx-community/Qwen3.6-27B-4bit` rev `c000ac2c…`, artifact `518ef47c298783d8547b50406e84548e5bf7705b82355a38f9eaef1368817931`. |
| Serve config | `build/lab-serve.sh` on isolated loopback 18190-18199 with `--no-join --autotune-candidate --no-idle-prewarm`. Settings: `paged_kv.enabled: true` (`max_physical_blocks` 102400), `continuous_batching: canary`, `max_concurrency_override: 8` and `continuous_batch_queue_limit: 16` (both as on live), `mlx_cache_limit_mb: 2048`, `max_context_override: 200000` (A3B only), prefill step 512 with legacy `.remainder` chunking, CB prefill 2048 tokens per iteration (default), hybrid decode window 1 (fixed on `main`). Lab `continuous_batching_accepted_tuples` carry metallib `f42aef60…`, which is a manual test input and not a signed policy. |
| Live provider | Not stopped, restarted or reconfigured. Paused only by `bench.sh`, for four GPU windows, and resumed each time (`LIVE_RESUMED` at 14:05:52, 14:10:04, 14:19:01, 14:57:40 UTC). |

## Step 1: startup parity and batched isolation — PASS

`step1-probes/<run>/serve.log` and `status-continuous-batching.json`.

| Run | Gather parity | Batched isolation | `/v1/status` |
| --- | --- | --- | --- |
| A3B, fused MoE (default) | `established=true`, 640/640 gather calls | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` (pair 2; pairs 0-1 parity-exact but indistinguishable, as on 1.8.230) | `active=true`, `paged_kv_decision=attached`, `local_proof_result=passed`, `slots_total=8` |
| A3B, `MLX_LM_QWEN35_FUSED_MOE=0` | same | same | same |
| 27B (dense hybrid), default | `established=true`, 1024/1024 | `proven=true` with the same field values (pair 2) | `active=true`, `attached`, `passed` |
| 27B, `MLX_LM_QWEN35_FUSED_MOE=0` (no-op on a dense model) | same | same | same |

Runtime-measured tuples (`[paged-kv] runtime-identity`): `hardware_class=apple-silicon:Apple M3 Ultra:ram-256gb`,
`metallib_sha256=f42aef60…`, `kernel_identifier=macprovider_paged_kv_gather_v1`,
`cache_class=mixed`, KV fp16 (no `kv_bits`), `requires_moe` true for A3B and
false for 27B.

Both 27B artifacts are 4-bit quantized. The bf16 `gemv_wide` / `dot_product`
routes that `step1-root-cause.md` flags as the same class of risk did not
change the gate result on either model. A model with unquantized linears would
still need its own probe.

## Step 2: CB enable-gate rows executable on the Studio

### HTTP rows (`step2-cb-gate/http/`, A3B, live not paused, correctness only)

Script: `build/cb_gate_http.py`. It uses four fixtures with distinct
1091-token prompts and `max_tokens` 96-192 at temperature 0. Each fixture runs
against a CB-off serve (`MACPROVIDER_CONTINUOUS_BATCHING=off`, serial path),
then against a CB-on serve alone, then as one of 4 concurrent rows. The same
script ran against the 1.8.230 binary as a control.

| Gate row | 3.32.3 fixed | 1.8.230 control |
| --- | --- | --- |
| Keyless scheduler 200 (`X-Request-ID`, no key) | HTTP 200, `stop`, `scheduler_admitted` | HTTP 200, `stop` |
| Keyed first-turn scheduler 200 (`X-MacProvider-Provider-Conversation`, `cached_prompt_tokens=0`) | HTTP 200, `stop`, admitted. The only `serial_routed` line is the pre-attach startup line; no `conversation_key_rollout_unavailable`. | HTTP 200, `stop` |
| Batch invariance: CB alone vs CB as 1 of 4 concurrent rows | **4/4 token-identical**, equal usage | 4/4 identical |
| Usage attribution (concurrent) | `prompt_tokens` 1091 each, `cached_prompt_tokens` 0, completion equals emitted, model hash `3fed776d…` on every row | same |
| Observability (`/v1/status` sampled at 4 Hz) | `active_decode_rows` reached 4 and `shared_forward_calls` advanced | same |
| Deterministic parity: CB vs serial (CB off) | **0/4 identical**; divergence at character 82-367 | **1/4 identical**; divergence at character 70-499 |

The serial-vs-CB parity row fails on 1.8.230 as well, so it is **not a
regression of this upgrade**. It is an open gate row on the build that serves
the live canary today. It does not come from the CB prefill chunk size: rerun
with `MACPROVIDER_CONTINUOUS_BATCH_PREFILL_TOKENS_PER_ITERATION=512`, all 4
rows still differ. The startup gate compares only 48 tokens after a 513-token
prompt; these fixtures diverge later in 96-192-token generations. This is
flagged once here; as the runbook asks, it was not used to block the
upgrade.

The response does not echo `X-Request-ID` on either build. This is
informational only and not a gate row.

### In-process harness rows (`step2-cb-gate/msb/`, A3B, under `bench.sh`)

`build/msb-332.sh`. Live was paused and drained from 13:58:51 to 14:05:52 UTC.

| Row | Result | 1.8.230 / prior |
| --- | --- | --- |
| MSB-01 paged 1 row (L=1536, 128 decode) | 115.8 tok/s, 0.73x production serial (159.6) | #1906 split, 0.31.4 campaign build: 107.6, 0.74x serial (145.2) |
| MSB-04 paged 2 rows | 158.2 tok/s, 1.00x serial | n/a |
| MSB-02 paged 4 rows | 215.7 tok/s, 1.35x serial | n/a |
| Paged 8 rows | 262.1 tok/s, 1.64x serial | #1906 split: 253.3, 1.74x |
| MSB-03 ragged 512/1024/1536/2048 (scheduler) | aggregate 195.3 tok/s, 1.23x serial; short-row TTFT ratio 0.99 (pass); **`pass=false` on `usagePass`** | 1.8.230 run under `bench.sh`: 188.0 tok/s, 1.32x; **same `usagePass=false`** |
| MSB-05 Q1 native parallel | 0.74x serial; Q2 oMLX sidecar not present | packaged 171: 0.73x |
| Failure isolation (scheduler) | pass: cancelled row `cancelled`, healthy row `length` | packaged 171: pass |
| Durable replay | pass: `eligible_owner`, then `non_settling_replay`, tokens match | pass |
| Warm-swap / operator drain | pass: queued row rejected, active rows `length`, permit valid, post-drain reject | pass |
| Temp-0 parity, standalone and batched (32 tokens) | pass, 2/2 and 2/2 | packaged 171: fail at index 9 |

MSB-03 `usagePass=false` is a harness off-by-one, not attribution:
every row reports 257 completion and 257 emitted tokens against
`expectedCompletionTokens` 256 (`MSBThroughputLeftovers.swift:139`). The
request IDs are distinct, prompt tokens match, and `cached_prompt_tokens` is 0.
1.8.230 gives the identical 257 (`step2-cb-gate/msb-control-1.8.230/`), so it
is pre-existing.

The 1-row paged ratio of 0.73x is below the 0.90x FR-PKV13 bound that was
recorded for 27B, but A3B was already at 0.74x on 0.31.4. It is pre-existing,
and the runbook notes that canary serial-routes lone requests. Absolute
throughput is up on this build: serial is about +10%, MSB-03 aggregate +4%,
and 8 rows +3% against the earlier 0.31.4 measurements.

### Rows that need the signed packaged release (not faked)

Package identity (RC install, standalone/Malibu byte identity); acceptance
coverage (signed policy `live_verified`, policy and tuple digests: the lab used
manual accepted tuples, which do not authorize production); the FR-PKV13
ceiling re-recorded on the packaged RC; AC-26 sticky retained-KV proof;
packaged durable replay and settlement disposition through usage/receipt;
AC-25 API lifecycle over the packaged HTTP/relay surface; packaged warm swap
with receipt model hash; Gate A5.

## Step 3: native-MTP R015 — FAIL

The fixture was recreated as APFS clones, from the recipe in
`scripts/native_mtp_rehearsal_release.py`: `target/` is the served artifact
(`3fed776d…`, tokenizer `87a7830d…`), and `mtp/` is
`mlx-community/Qwen3.6-35B-A3B-MTP-4bit` rev `0295b814…`, artifact `fa01beec…`.
The run script is `build/r015-332.sh`, under `bench.sh`. Live was paused and
drained from 14:32:34 to 14:57:40 UTC. The contamination log shows no other
inference process above 0.1% CPU.

**Policy.** `step3-r015/policy.json`, SHA-256
`7c6d65793399ac95613837298105cf78df584c950ec3ca756361a119eb287278`, was frozen at
14:32:29Z, before any warmup or measured request. It is the #1862 quiet-run
policy (`e24cb7bc…`) with two fields changed: `mlx_fork_revision` is
`37f0d7ce…` and `provider_commit` is `f424aa9d6…`. Thresholds, matrix, seed
`20261006`, 10 blocks, 250 ms arrivals and the 1800 s sustained window are
unchanged.

The coordinator asked for the earlier freeze, `69747b2b…`, to be reused. It
is byte-identical except that it names `provider_commit` `531ce132a`, and the
binary measured here was built from `f424aa9d6`. Declaring a commit that was
not built is the same false-identity problem that blocked the previous attempt,
so the policy was re-frozen with the true commit. `69747b2b…` never produced a
record: the bench refused it at 14:17:46Z
(`step3-r015/superseded-531ce132a-refused/`).

**Run.**

| Phase | Result |
| --- | --- |
| `native-mtp-hardware-e2e` (serve path) | PASS: 3 admissions, batch depth 2, `serve_path_verified=true` |
| `--phase matrix` | exit 0, 133 records (incl. warmups), 14:33:37-14:56:17Z; JSONL SHA-256 `5d277956ed622c8c53cc32befaf984b572fc89eac26c904c7053d64aeef1ddab` (`r015-a3b-332.jsonl.gz`) |
| `--phase sustained` | stopped by this run 17 s in, with 0 records written (exit 143) |

The analyzer computes every paired statistic from matrix blocks only. The
sustained window feeds only the hard gates (parity, errors, memory). Once the
matrix had failed four statistics, the sustained window could not change the
verdict, so it was stopped to end the live pause about 30 minutes early.
`analysis.json` and `analysis.md` are the unmodified analyzer output (exit 1,
`overall_status: FAIL`). The s8 cell also lists `sustained_missing` for that
reason.

**Gates against the 2026-10-06 quiet PASS.** Holm-corrected bounds, as
fractions of the ordinary arm. One-slot cells must reach a decode LB of at
least +15% and a TTFT UB of at most +10%. Gated cells must reach a decode LB of
at least -5% and a TTFT UB of at most +5%.

| Cell | Decode LB 10-06 / now | TTFT p95 UB | TPOT p95 UB | Gap p99 UB | Rejection UB | Status now |
| --- | --- | --- | --- | --- | --- | --- |
| s1-p1536-o128 | +25.8% / +18.5% | +4.6% / +5.0% | -20.5% / -15.7% | -23.2% / -17.7% | 0 / 0 | PASS |
| s1-p1536-o512 | +24.2% / +15.6% | +4.7% / +4.6% | -19.5% / -13.5% | -24.0% / -13.2% | 0 / 0 | PASS |
| s1-p4096-o128 | +21.0% / **+13.1%** | +5.6% / +6.9% | -17.4% / -11.3% | -19.2% / -12.6% | 0 / 0 | **FAIL** (decode) |
| s1-p4096-o512 | +18.5% / **+11.1%** | +5.6% / +6.8% | -15.6% / -9.2% | -19.0% / -13.0% | 0 / 0 | **FAIL** (decode) |
| s2-p1536-o512 (gated) | -0.3% / -0.6% | +2.6% / **+5.39%** | +0.3% / +0.5% | +0.3% / +0.4% | 0 / 0 | **FAIL** (TTFT, 0.0539 > 0.05) |
| s8-p1536-o512 (gated) | -0.2% / -0.2% | +0.8% / +2.4% | +0.3% / +0.2% | +0.9% / +1.3% | 0 / 0 | statistics PASS; hard gate `sustained_missing` |

Hard gates in the matrix: 0 parity mismatches, 0 fallbacks or errors, and no
invalid records in any cell. Minimum available memory was at least 0.66.
Acceptance is unchanged: 0.881 / 0.850 / 0.939 / 0.855 now, against 0.888 /
0.855 / 0.917 / 0.843.

Median aggregate decode, ordinary / native, in tok/s:

| Cell | 10-06 (0.31.4, fork `ca8c384c`) | Now (3.32.3 fixed) | Ordinary change | Native change |
| --- | --- | --- | ---: | ---: |
| s1-p1536-o128 | 111.7 / 142.5 | 119.8 / 143.1 | +7.3% | +0.4% |
| s1-p1536-o512 | 110.3 / 138.5 | 119.7 / 139.8 | +8.5% | +0.9% |
| s1-p4096-o128 | 106.9 / 133.2 | 117.3 / 136.8 | +9.7% | +2.7% |
| s1-p4096-o512 | 107.3 / 127.9 | 115.5 / 129.9 | +7.6% | +1.6% |
| s2-p1536-o512 | 137.0 / 137.1 | 143.6 / 143.2 | +4.8% | +4.4% |
| s8-p1536-o512 | 197.3 / 197.4 | 206.8 / 206.5 | +4.8% | +4.6% |

Reading. The failures are not correctness failures: parity, acceptance and
errors are unchanged. The upgrade sped up ordinary one-slot decode by 7-10%,
but native-MTP decode gained only 0.4-2.7%, so the native/ordinary ratio fell
from 1.19-1.28 to 1.13-1.20. The two 4096-token cells now sit below the
frozen +15% bound.

One likely reason, not isolated here: ordinary T=1 decode now runs through the
3.32 compiled Qwen3.5 decode segments (with fused MoE in the trace), while
native verify rows (T = 2) take the general path. With batch-dependent small-M
routes disabled (`ff1b948`), they also lose the `qmv_wide` gain at M = 2.

The s2 TTFT miss is 0.39 points over a 5% bound. It moved from +2.6%, at an
unchanged decode ratio. As frozen, the tuple (`max_native_active_rows` 1, cap
4096) does not requalify on this build. Native MTP stays default-off, and
nothing here changes that.

## Steps 4 and 5: not run

Steps 4 and 5 were stopped at the step 3 RED (R015 FAIL). `build/rtcmp-332.sh` is ready.
It follows `runtime-compare-1906.sh` with the same load generator
(`depth_sweep.py`, byte-identical to the campaign branch), the same shapes
(1536/256 and 1800/1024), depths 1/8/16, 30 s warmup and 90 s window. It runs
our build with `main`'s `max_batch` 8 and window 1, under `bench.sh`, one call
per MoE setting:

```bash
bench.sh rtcmp-332.sh <out> ours332-fused
bench.sh rtcmp-332.sh <out> ours332-stock MLX_LM_QWEN35_FUSED_MOE=0
```

Settings that differ from the 2026-10-09 ours-w1 rows: `max_batch` 8 with
queue 16 here, against 32 with queue 256 there. The 1-concurrent and
8-concurrent cells are like for like. At 16 concurrent, this build runs 8
rows with 8 queued, and the old row ran 16 rows.

## Files

- `step1-probes/`: serve logs and `/v1/status` excerpts for the four step-1 runs.
- `step2-cb-gate/http/`: fixtures and outputs for serial, CB, CB at
  prefill 512, and the 1.8.230 control, plus serve logs.
- `step2-cb-gate/msb/`, `step2-cb-gate/msb-control-1.8.230/`: MSB JSON and logs,
  and the `bench.sh` console.
- `step3-r015/`: frozen policy, raw JSONL (gzip), analyzer JSON/markdown,
  status, hardware-e2e and bench logs, contamination log, `bench.sh` console.
  `superseded-531ce132a-refused/` holds the refused attempt on the stale identity.
- `build/`: lab launcher, probe, HTTP, MSB, R015 and runtime-compare scripts.
- `superseded-149a3c39a/`: the first (RED) step-1 attempt and its lab-harness
  compiler errors, both fixed on `531ce132a`.
- `step1-root-cause.md`: root cause and fix for the first attempt (not
  written by this run).

Studio home paths are replaced with `<studio-home>`.
