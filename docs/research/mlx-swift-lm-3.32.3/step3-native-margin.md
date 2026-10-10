# Native-MTP margin on mlx-swift-lm 3.32.3 (step 3 follow-up, 2026-10-09)

**Status: R015 FAIL on one hard gate (parity), every statistical gate PASS.**
Compiling the native-MTP verification step restores the decode margin: all
four one-slot cells clear the +15% decode bound again (+17.7% to +26.6%) and
the s2 TTFT bound now passes (+4.14% against at most +5%). The frozen run
still fails, because 2 of the 40 measured native runs in `s1-p4096-o512`
(blocks 5 and 6, back to back) produced different text from the ordinary arm,
with acceptance collapsing to 0.36 and 0.26. Five later replays of that cell
with the same build (126 more native runs with verify rounds, including a
full replica of the matrix in one process and a 40-block stress run) never
reproduced it. Before this change, none of 156 native runs on earlier builds
showed it. The event is
non-deterministic, and this work could neither attribute it to the compiled
step nor exclude it. Native MTP stays default-off. Nothing here changes a gate,
threshold or policy.

## Evidence header

| Field | Value |
| --- | --- |
| macprovider | `deps/mlx-swift-lm-3.32.3` at `d07d0cf092b1b7c43e4c03dd8973db5f254c4409` (pin bump only; parent `f424aa9d6`), unpushed |
| mlx-swift-lm fork | `1007bc667f3255f8ebaa52cfbbafaa76af5a3402`, tag `3.32.3-macprovider.3`, on `37f0d7ce` (`3.32.3-macprovider.2`) |
| mlx-swift / MLX core | unchanged: `d073a644` (`0.32.3-macprovider.1`) / `ff1b9483` (`v0.32.2-macprovider.1`) |
| Host | Mac15,14, Apple M3 Ultra, 256 GB, macOS 26A434, Swift 6.3.3 (Command Line Tools) |
| Serve executable | `swift build -c release` at `d07d0cf09`, reports 1.8.230, SHA-256 `4d57fe8c8123866fad4984215e7d964ad4c03169703e1cb8d826ccc3b584efaf` |
| Lab-harness executable | `-DMACPROVIDER_LAB_HARNESS` at `d07d0cf09`, SHA-256 `53119a378f5dd101c64f2b8df143ca26abd4c1c2a469025c2fc5e2f70c1232e3` |
| `mlx.metallib` | `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` (unchanged; no kernel change) |
| Build trees | serve at `<studio-home>/build-mlx332`, lab harness at `<studio-home>/lab-332/src/phase3-binary`, both synced from the commit (`rsync --dry-run` empty) and resolved to `1007bc6` |
| Live provider | Not stopped, restarted or reconfigured. Paused only by `bench.sh`, which resumed it every time (windows listed under Files). Ready and serving at the end. |

## 1. Profile: where native decode time goes

Method: a lab-only patch (`step3-native-margin/profile/labprof-instrumentation.diff`, not committed)
times the bridge calls the scheduler makes for each step. That covers the
host graph build up to each blocking host read, and the GPU wait at that read.
The runs used exploratory policies (`macprovider.native-mtp-exploratory-policy.v1`)
under `bench.sh`, with the same fixture, seed and harness as R015. Each round
of the native arm makes one target verify call (T = 2, emit state, recurrent
checkpoint after column 1) and one finalize call. Finalize runs the packed
drafter advance and propose plus the staged commit, in a single `eval`.

`s1-p4096-o512`, per-call means over the whole run (ms):

| Step | Uncompiled verify (`MLX_LM_QWEN35_COMPILED_VERIFY=0`) | Compiled verify (this fix) |
| --- | ---: | ---: |
| Ordinary T=1 step: host build / GPU wait | 1.09 / 7.70 | 1.08 / 7.72 |
| Native verify: host build | **1.52** | **0.81** |
| Native verify: GPU wait | 10.67 | 10.54 |
| Native finalize (drafter advance + commit): build / GPU wait | 0.47 / 1.16 | 0.47 / 1.15 |
| Native propose (host lookup) | 0.002 | 0.001 |
| Native round interval | **14.08** | **13.21** |
| Tokens per round (acceptance 0.82-0.89, depth 1) | 1.87 | 1.87 (identical) |
| Median decode tok/s, ordinary / native | 117.4 / 132.9 | 118.2 / 142.8 |

On `s1-p1536-o512` the native round moved from 13.30 to 12.15 ms: verify
11.76 to 10.64 ms, of which host build 1.53 to 0.77 ms. Median native decode
went from 138.6 to 151.5 tok/s, against ordinary at about 120.5.

Hypotheses from the brief:

- **Confirmed:** the ordinary T=1 step runs in the compiled whole-step
  segments (`decodeStep`, `CompiledDecodeSegments.swift`). The native verify
  forward took the general path, op by op. It never reached the segments: they
  only accept T = 1, and the emit-state forward also asked `forward` for
  `applyFinalNorm: false`. Compiling the verify step cuts the host build by
  0.7 ms and the round by 0.85-1.15 ms, and native decode rises 7.5-9%. The
  GPU time of verify barely moves (10.67 to 10.54 ms). The gain is host
  dispatch, which in this loop sits on the critical path between
  synchronous steps.
- **Refuted:** "the batch-invariance fix removed `qmv_wide` for the M = 2
  verify matmuls" does not explain the loss against 10-06. `qmv_wide` entered
  MLX core in v0.32.0 (`548dd80e8`, #3764). The 10-06 PASS ran MLX 0.31.4, so
  its M = 2 verify matmuls already ran on `qmv`, exactly like the current
  batch-invariant core. Relative to that baseline, nothing was taken away.
- **Drafter:** a finalize costs 1.4-1.7 ms per round, of which 0.3-0.5 ms is
  host build, so compiling the drafter could save about 0.1-0.2 ms. It was
  not changed.

What remains: a T = 2 verify costs 10.5 ms of GPU against 7.7 ms for a T = 1
ordinary step (+37% for the second column, mostly routed experts for a second
token). The native/ordinary ratio is now 1.19-1.29, against 1.19-1.28 on
10-06.

## 2. Fix (fork `1007bc6`, tag `3.32.3-macprovider.3`)

`Qwen35TextModelInner.verifyStep` runs a short verification step through
compiled segments with the same schedule and cache rules as upstream's
`decodeStep`. Eligible steps have 2...8 columns, request a recurrent
checkpoint (0 < c < T, which only packed MTP verification does), have no
padded rows (no SSM mask), have state in every GDN layer, and use plain-route
attention caches.

- KV writes, RoPE and SDPA stay outside the traces (`attentionCacheStep`),
  with the causal mask the general path builds once from the full-attention
  cache.
- GDN conv/recurrent state crosses each segment explicitly. Each GDN layer
  returns its state and its checkpoint (`gatedDeltaUpdateCheckpointed` plus the
  conv window), and the step saves the checkpoint (`saveSpeculativeCheckpoint`)
  and advances the cache in the same order as the general layer path.
- There is one trace set per checkpoint column (`CompiledVerifySegmentCaches`,
  invalidated with the model's other traces). MLX retraces it per shape.
- The emit-state forward now asks `forward` for the final norm instead of
  applying the same `norm` to its output, which is the same computation.
- Prompt chunks, steps without a checkpoint, wider steps and padded rows keep
  the general path. `MLX_LM_QWEN35_COMPILED_VERIFY=0` turns the compiled
  step off for the whole process.

There is no kernel change, so `mlx.metallib` is unchanged.

## 3. Correctness checks

- Fork XCTest `Qwen35CompiledVerifyTests` (local Apple-silicon Mac):
  hidden state, every cache entry and the restored checkpoint are
  bit-identical to the general path over three steps, including a rejected
  step (checkpoint restore plus KV trim). The cases are f16, bf16 and 4-bit
  bf16 weights; B = 1 and 2; T = 2 (checkpoint 1) and T = 3 (checkpoint 2).
  f32 weights differ by 1 ulp in the recurrent state. This is the same
  contract as upstream's compiled decode, which is pinned for f16/bf16 only.
  The A3B checkpoint is bf16 throughout, including `A_log` and `dt_bias`. A
  separate probe found the fused A3B MoE block bit-identical inside and outside
  a trace at T = 1 and T = 2. The full fork suite passes: 662 tests, 0
  failures, 2 skipped.
- Startup probes on the `d07d0cf09` serve build
  (`step3-native-margin/probes/`). A3B with fused MoE on and with
  `MLX_LM_QWEN35_FUSED_MOE=0` both give gather parity `established=true`
  (640/640), batched isolation
  `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true`,
  and `/v1/status` `active=true`, `paged_kv_decision=attached`,
  `local_proof_result=passed`, `slots_total=8`. These are identical to step 1.
- Token level: across the exploratory runs, native output equals ordinary
  output in every block, with the compiled step on and off. Tokens per target
  forward are identical to four digits between the two settings, so they make
  the same accept/reject decisions.
- `native-mtp-hardware-e2e` (serve path) PASS inside the R015 window.

## 4. R015 on `d07d0cf09`

Policy `step3-native-margin/r015/policy.json`, SHA-256
`8722ddbf4393a49fdfa48850d33fe6e9bdbf3c76954d913825b7f46165c0c9d2`, was frozen
at 2026-10-09T16:08:42Z, before any request. It is byte-identical to
`7c6d6579…` except for `provider_commit` (`d07d0cf09…`) and
`mlx_fork_revision` (`1007bc66…`). Run script `build/r015-d07d.sh` under
`bench.sh` (live paused 16:08:57, resumed 17:04:54 UTC):

| Phase | Result |
| --- | --- |
| `native-mtp-hardware-e2e` | exit 0 (16:10:01Z) |
| `--phase matrix` | exit 0, 133 records |
| `--phase sustained` | exit 0, 1800 s, 201 records in total; JSONL SHA-256 `e9e5d1ef68263b43c27be22394a21bb2e66ab4a0c68a69518dfbbb6fea7b919d` |
| Analyzer | `overall_status: FAIL` (exit 1), unmodified output in `r015/analysis.{json,md}` |

Gates against the 2026-10-06 quiet PASS and the 2026-10-09 run on `f424aa9d6`.
Holm-corrected bounds, as fractions of the ordinary arm. Thresholds: one-slot
decode LB at least +15% and TTFT UB at most +10%; gated decode LB at least -5%,
TTFT UB at most +5%, TPOT UB at most +5%.

| Cell | Decode LB 10-06 / f424 / **now** | TTFT p95 UB 10-06 / f424 / **now** | TPOT p95 UB now | Gap p99 UB now | Rejection UB | Status now |
| --- | --- | --- | ---: | ---: | ---: | --- |
| s1-p1536-o128 | +25.8% / +18.5% / **+26.6%** | +4.6% / +5.0% / **+4.7%** | -21.0% | -1.3% | 0 | PASS |
| s1-p1536-o512 | +24.2% / +15.6% / **+25.1%** | +4.7% / +4.6% / **+4.5%** | -20.1% | -20.9% | 0 | PASS |
| s1-p4096-o128 | +21.0% / +13.1% / **+20.3%** | +5.6% / +6.9% / **+7.6%** | -16.9% | -18.8% | 0 | PASS |
| s1-p4096-o512 | +18.5% / +11.1% / **+17.7%** | +5.6% / +6.8% / **+7.8%** | -1.9% | +53.2% | 0 | **FAIL: `parity_mismatch`** (statistics pass) |
| s2-p1536-o512 (gated) | -0.3% / -0.6% / **-0.44%** | +2.6% / +5.39% / **+4.14%** | +0.45% | +0.58% | 0 | PASS |
| s8-p1536-o512 (gated) + sustained | -0.2% / -0.2% / **-0.31%** | +0.8% / +2.4% / **+2.84%** | +0.33% | +2.05% | 0 | PASS |

Median decode, ordinary / native (tok/s): s1-p1536-o128 120.4 / 154.9 (1.287),
s1-p1536-o512 120.2 / 151.0 (1.256), s1-p4096-o128 116.7 / 146.1 (1.252),
s1-p4096-o512 116.5 / 138.7 (1.191), s2 143.7 / 143.2, s8 206.5 / 206.3.
Errors, fallbacks and capacity rejections were 0 everywhere. The sustained
window had 68 runs with 0 parity mismatches. The minimum available memory
fraction was 0.585 and thermal state was nominal.

### The parity failure

In `s1-p4096-o512`, the native runs of blocks 5 and 6 (both native-first,
consecutive) differ from their ordinary pair. Their acceptance was 0.36 and
0.26, against 0.82-0.89 in every other block, and their native decode 103 and
96 tok/s. Both runs still produced 512 tokens. The ordinary arm in those blocks
matches every other build. The chunk timeline is wrong from the first decode
round on: no round shows the accepted two-token pattern, and some 26 ms gaps
emit no visible text. TTFT is normal. The target's own output diverged, which
is why parity fails, not only acceptance.

The anomaly does not reproduce, and the signature has not been seen before:

| Run (same prompts and seed; counts are native runs with verify rounds, since s2/s8 native rows stay at depth 0) | Native runs | Anomalies |
| --- | ---: | ---: |
| Formal R015 matrix (`d07d0cf09`) | 44 | **2** (blocks 5-6 above) |
| Same cell, 6 blocks, compiled on / off (`w5-*`) | 14 | 0 |
| Same cell, 10 blocks with the formal order, compiled on ×2, off ×1 (`w6-*`) | 33 | 0 |
| Full replica of the frozen matrix in one process, compiled on (`w7-on`) | 44 | 0 |
| Same cell, 40 blocks, compiled on (`w8-on`) | 41 | 0 |
| Earlier exploratory runs in this session (`w1`-`w4`, on and off) | 22 | 0 |
| 10-06 quiet PASS, 10-06 step-overhead run and its controls, 10-09 `f424` run (uncompiled verify) | 156 | 0 |

The replays of blocks 5 and 6 match ordinary output exactly
(`39fb4f18…` for block 5, the formal ordinary hash), with acceptance 0.879
and 0.848. Across 126 compiled-step native runs outside the formal run, 0
failed. The rate is therefore low, and nothing ties it to the compiled step.
On the other hand, two consecutive failures in a single window, after 156
clean uncompiled runs, are not evidence that it is unrelated.
Mechanisms checked and ruled out by inspection or measurement:

- Memory pressure: available fraction 0.655-0.67 throughout.
- Thermal state: nominal.
- Other inference processes: the contamination log shows 0.1% CPU.
- Mid-cell retrace: every native verify in the cell has shape B=1, T=2.
- Fused MoE inside a trace: bit-identical.
- Compile versus eager for bf16: bit-identical.
- Prompt chunking: the prefill path, including the emit forward, is unchanged
  for prompt chunks.

Not yet isolated:

- A host/GPU ordering race elsewhere in the native path whose timing the
  faster verify step shifts.
- A process-global effect of the three earlier cells, which `w7-on` replayed
  without a failure.

Per the brief, the frozen policy was not rerun to get a passing record. The
recorded R015 for `d07d0cf09` is FAIL.

## 5. TTFT mechanics (s2), for the record

Compiling the verify step does not touch prefill. The s2 TTFT UB moved from
+5.39% to +4.14% because of block-order noise, not a code change. Event
timelines (`profile/w3-o128`, `profile/w4-s2`) show two effects that set this
bound:

- **First-arm penalty.** Building each block's prompts leaves the GPU idle for
  3.4-4.5 s while prompts are tokenized repeatedly (`makePrompts`). The first
  512-token prefill chunk after that gap takes 300-330 ms against 250-267 ms
  warm, which costs the arm that runs first in a block about 50-60 ms of TTFT.
  The 10-06 data shows the same order effect at about 10 ms.
- **Decode-window race.** In s2, the second request arrives about 255 ms after
  the first. If the first request's first prefill chunk has already finished,
  the second request is still `waiting` when the first request's prefill ends,
  so decode takes a 1-step window and the second prompt starts at once. If not,
  it is already an active prompt, and decode takes the
  `maxDecodeStepsWhilePrefilling` window (about 67 ms, SPEC-038 FR-CB2) first.
  The drafter prompt advance adds 12-15 ms to each 512-token native chunk, so
  the native arm's first chunk (265-280 ms) always lands on the slow side.
  A warm ordinary first chunk (250-252 ms) lands on either side. That gives a
  bimodal ordinary TTFT (1.49 or 1.55-1.59 s) and a 2-4% median native penalty
  on the second request.

Neither effect is in the fork. Both belong to macprovider's scheduler and
bench (SPEC-038/SPEC-048). They are reported here and were not changed.

## Files

Paths are relative to `step3-native-margin/`.

- `r015/`: frozen policy and freeze record, status, hardware-e2e and bench
  logs, contamination log, `bench.sh` console, the gzipped JSONL, and the
  analyzer output.
- `probes/`: serve logs and `/v1/status` for the two A3B startup probes.
- `profile/`: exploratory policies, per-run JSONL and logs (`w1`-`w8`), and
  the lab-only instrumentation diff. Live pause windows (UTC):
  - w1 15:14:04-15:19:54
  - w2 15:29:22-15:36:52
  - w3 15:42:48-15:44:24
  - w4 15:48:33-15:51:15
  - R015 16:08:57-17:04:54
  - w5 17:09:14-17:15:31
  - w6 17:17:02-17:29:13
  - w7 17:31:30-17:55:09
  - w8 17:55:38-18:08:22

  A first w7 launch at 17:31:12 was refused by the bench before any request,
  because of an identity mismatch in its exploratory policy. A w8 launched by
  mistake during w7 was killed while still loading, about 5 s in.
- `build/`: `r015-d07d.sh` and the profile runner.

Studio home paths are replaced with `<studio-home>`.
