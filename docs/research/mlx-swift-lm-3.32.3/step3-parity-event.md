# Native-MTP parity event on 3.32.3 (`s1-p4096-o512`, blocks 5-6): root-cause hunt (2026-10-09)

**Status: no defect found; the event is not attributed.** A static audit of
the compiled MTP verification step (fork `1007bc6`) and everything it
touches found no difference from the general path that could change a
logit. An added two-process GPU-contention reproducer on the formal binary
gave 0 anomalies in 82 native runs. Including the earlier replays, that is
208 compiled-verify native runs since the event, all with output equal to the
ordinary arm. As the brief requires for this case, the full R015 was rerun on
the same build with `MLX_LM_QWEN35_COMPILED_VERIFY=0`. Parity holds in every
cell and in the 1800 s sustained window, but three statistical gates fail
(below). On 3.32.3, the uncompiled verify path is correct but too slow to
qualify. No fork fix was made, so there is no `3.32.3-macprovider.4` tag and
no macprovider pin bump. No gate, threshold or policy was changed.

## Evidence header

| Field | Value |
| --- | --- |
| macprovider | `d07d0cf092b1b7c43e4c03dd8973db5f254c4409` (same build as the event) |
| mlx-swift-lm fork | `1007bc667f3255f8ebaa52cfbbafaa76af5a3402` (`3.32.3-macprovider.3`) |
| mlx-swift / MLX core | `d073a644` / `ff1b9483` (unchanged) |
| Lab-harness executable | SHA-256 `53119a378f5dd101c64f2b8df143ca26abd4c1c2a469025c2fc5e2f70c1232e3` (the formal R015 binary) |
| `mlx.metallib` | `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` |
| Host | Mac15,14, M3 Ultra, 256 GB, macOS 26A434 |
| Live provider | Paused only by `bench.sh`, and resumed every time: window A 18:24:12-18:38:45, R015 (compiled off) 18:39:45-19:35:56 UTC. Ready and serving at the end. |

## 1. Event context (from the formal JSONL and logs)

- Each cell runs in a fresh engine with its own startup probes (one
  `runtime-identity` line per cell in `bench-matrix.log`). Before block 5,
  `s1-p4096-o512` had already run 5 clean native requests (warmup and
  blocks 0-4) on the same verify trace (shape B = 1, T = 2, checkpoint 1).
  Blocks 5 and 6 were therefore neither the first compile nor a retrace.
- Order around the event: b4 native (ok, native-first), b4 ordinary, **b5
  native**, b5 ordinary (ok), **b6 native**, b6 ordinary (ok), b7 ordinary,
  b7 native (ok). b4, b8 and b9 were also native-first and clean, so "native
  first in a block" is not sufficient.
- Prompts differ per block. Block hashes are deterministic: the reproducer
  below reproduces the formal ordinary hash for all 22 overlapping
  (cell, block) pairs.
- During the event, the contamination log shows memory, thermal state and
  other inference engines (0.1 to 0.7% CPU) at the same levels as the clean
  blocks. The event cannot be tied to anything in these logs.
- Correction to the step-3 note: the 126 post-event replays (`w5`-`w8`) ran
  `bin-prof5`, a timestamp-instrumented build (labprof diff, no added
  synchronization) built against a local copy of the fork. Its
  `Qwen35.swift` and `GatedDelta.swift` are byte-identical to `1007bc6`.
  The formal binary itself was first replayed in window A below.

## 2. Static audit: what was ruled out

All references are in the fork worktree at `1007bc6` unless prefixed.

| Suspect | Finding |
| --- | --- |
| Weights captured as trace constants (stale-weight class) | Ruled out. `CompiledTrace` passes each declared module's `innerState()` as compile inputs (`Libraries/MLXLMCommon/CompiledTrace.swift:157,162`). The verify state provider (`Qwen35.swift:924`) declares the same modules as decode: segment layers, the embedding (segment 0) and the final norm (last segment). Two arrays sit outside module reflection: the fused GDN input projection (`Qwen35.swift:190`; upstream #631 is not in this fork) and the fused-MoE weight cache (`Qwen35.swift:611`). They become trace constants, but both hold the live weight arrays and nothing rewrites them in a serving process. At worst this is the #631 memory issue, not a correctness one. |
| Offset/shape baked into the trace (#406 class) | Ruled out. RoPE offset, KV write and SDPA stay outside the trace (`attentionCacheStep`). The mask is built once per step outside the trace (`Qwen35.swift:1190`), the same as the general path (`:976`). `makeMask` uses only `n`, so building it from token ids instead of hidden states gives the same mask. Inside the trace, the only scalar constants are `T` and `ckpt` (`GatedDelta.swift:473`). Both are constant per trace: one trace set per checkpoint column, and MLX keys traces on shape. |
| Trace key ignores something that varies | Ruled out for serving. Checkpoint index, width and dtypes are all part of the trace key. The packed Mamba cache only ever requests checkpoint 1 (`MTPPackedTargetVerification.swift:230-235`). Padded rows and depth-0 rows take the general path. No runtime code calls `invalidateCompiledTraces()` (only adapter, conversion and ParoQuant loaders do). |
| Cache-update ordering | Ruled out. Per GDN layer, the compiled step sets conv state, then recurrent state, then saves the checkpoint, then advances (`Qwen35.swift:1203-1215`). That is the general path's order (`:339-349`). Per-layer caches are disjoint, so batching the reads before a segment cannot alias. |
| Emit-state final-norm change | Ruled out. `forward(applyFinalNorm: true)` applies the same `norm` to the same tensor that the old external `norm` call did (`Qwen35.swift:1318`). |
| Uninitialized scratch read in custom kernels | Ruled out. The checkpointed GDN kernel writes every `y`, `state_out` and `state_ckpt` element (`GatedDelta.swift:36`). In the fused MoE, every `fh` slot the down kernel reads is written by the first-occurrence threadgroup (`Qwen35FusedMoE.swift:396`). |
| Retrace or tracer races across threads | Ruled out. Every compiled call and trace runs under mlx-swift's global `evalLock`. Target and drafter work in the bridge is serialized: drafter `perform` calls are awaited inside the target `perform`. Compiled-function ids are object addresses, erased synchronously on deinit (mlx-swift `Transforms+Compile.swift:38`). |
| Buffer donation / WAR hazards, #620 cache clear, `clearMLXBufferCacheAfterPrefill` | No mechanism found. MLX keeps every input's data retained until its command buffer completes, which blocks donation of a buffer that is still being read. `PagedKVCache.write` mutates only through `slice_update`. #620 applies to `TokenIterator`, which the continuous-batch path does not use. Clearing the cache frees only buffers that are no longer referenced. |
| Request-ID collisions (`rows[requestID]`) | Ruled out. Native and ordinary runs in a block share an ID, but release removes the row state and every native map (`PagedKVRuntimeBridge.swift:1402-1404`, `:2561-2570`). A native-first request cannot inherit state anyway. |

Side note: `PagedKVRuntimeBridge.swift:1784` calls
`Stream().synchronize()`, which waits on a new pooled stream rather than the
default one, so it waits for nothing. It is benign there, because every step
already blocks on `asArray`. It is not on the native path.

## 3. Reproducer (window A): GPU contention on the formal binary

The hypothesis was that the compiled step's shorter host phase moves a
timing-sensitive race, and that contention from another GPU process
triggered it. The test ran two concurrent `native-mtp-bench` processes from
the formal binary, compiled verify on, seed 20261006, d07d identity, under
`bench.sh`. Process A ran `s1-p4096-o512` and process B ran
`s1-p1536-o512`, 40 blocks each, overlapping for the whole window
(`build/run-contention.sh`, `repro-wA/`).

| Run | Native runs with verify rounds | Native != ordinary | Acceptance < 0.6 |
| --- | ---: | ---: | ---: |
| A: `s1-p4096-o512`, 40 blocks + warmup | 41 | 0 | 0 |
| B: `s1-p1536-o512`, 40 blocks + warmup | 41 | 0 | 0 |

Contention does not reproduce the event. Totals for compiled-verify native
runs: formal 2 / 44; since then 0 / 208 (126 instrumented replays plus 82
here). The rate is at most about 1.4% at 95% confidence, and the two hits
were consecutive. That points to a short-lived condition this work could not
recreate, not to a defect that recurs at a fixed rate.

## 4. R015 on `d07d0cf09` with `MLX_LM_QWEN35_COMPILED_VERIFY=0`

The policy is byte-identical to the event run (SHA-256
`8722ddbf4393a49fdfa48850d33fe6e9bdbf3c76954d913825b7f46165c0c9d2`). It was
freshly frozen at 2026-10-09T18:39:27Z with the env recorded in the freeze
record (the policy schema rejects extra keys). Run script
`build/r015-d07d-cv0.sh`, same binary and phases as the event run:

| Phase | Result |
| --- | --- |
| `native-mtp-hardware-e2e` | exit 0 (18:40:48Z) |
| `--phase matrix` | exit 0, 133 records |
| `--phase sustained` | exit 0, 1800 s, 213 records; JSONL SHA-256 `8b1ba25970ae1eddd6755d80e1b0b8564c0e492110e53939926f302b9172f2b2` |
| Analyzer | `overall_status: FAIL` (exit 1), unmodified output in `r015-cv0/analysis.{json,md}` |

| Cell | Decode LB (>= +15% one-slot, >= -5% gated) | TTFT p95 UB (<= +10% / <= +5%) | TPOT p95 UB | Gap p99 UB | Rejection UB | Parity | Status |
| --- | ---: | ---: | ---: | ---: | ---: | --- | --- |
| s1-p1536-o128 | +18.5% | +4.9% | -15.6% | -17.0% | 0 | 0 mismatches | PASS |
| s1-p1536-o512 | +15.3% | +4.6% | -13.3% | -15.0% | 0 | 0 | PASS |
| s1-p4096-o128 | **+13.3%** | +7.4% | -11.5% | -12.7% | 0 | 0 | FAIL: throughput |
| s1-p4096-o512 | **+11.0%** | +8.1% | -9.1% | -12.3% | 0 | 0 | FAIL: throughput |
| s2-p1536-o512 (gated) | -0.52% | **+5.66%** | +0.43% | +0.65% | 0 | 0 | FAIL: ttft |
| s8-p1536-o512 (gated) + sustained | -0.14% | +2.60% | +0.14% | +1.02% | 0 | 0 (80 sustained runs) | PASS |

Median decode, ordinary / native (tok/s): 120.1 / 143.9, 120.1 / 140.1,
116.5 / 136.7, 116.3 / 129.6. Errors, fallbacks and capacity rejections were
0 everywhere. The minimum available memory fraction was 0.612, and thermal
state stayed nominal. The uncompiled 3.32.3 path reproduces the earlier
`f424aa9d6` margins (+18.5 / +15.6 / +13.1 / +11.1%). It passes every
correctness gate, including parity on 44 matrix and 80 sustained native
runs, and fails the one-slot p4096 throughput bounds and the s2 TTFT bound.

## 5. Where this leaves the compiled step

- No code path in `1007bc6` was found that can make the verify logits
  differ from the general path, and no reproducer brings the divergence
  back.
- The compiled step is the only change that clears the throughput gates on
  3.32.3. With it off, R015 fails on throughput and TTFT; with it on, R015
  failed once on a parity event that 208 replays have not reproduced.
- Not isolated: a transient, host-level condition lasting about two
  requests during 16:16-16:20Z (the window cannot be observed from these
  logs), or a hardware-level fault. Either would explain two consecutive
  native-only divergences followed by clean runs in the same process. The
  ordinary arm in between did not diverge, which suggests the native verify
  graph was the exposed one, but that is not evidence of a code defect.

## Files

Paths are relative to `step3-parity-event/`. Studio home paths are replaced
with `<studio-home>`.

- `build/`: `run-contention.sh`, the two exploratory policies,
  `r015-d07d-cv0.sh`, and `parity.py` (per-block native/ordinary hash and
  acceptance check).
- `repro-wA/`: window A logs, contamination log, and both gzipped JSONL
  files.
- `r015-cv0/`: policy and freeze record, status, hardware-e2e and bench logs,
  contamination log, `bench.sh` console, gzipped JSONL, and analyzer output.
