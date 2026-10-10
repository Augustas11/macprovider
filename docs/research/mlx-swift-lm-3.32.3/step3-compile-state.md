# Native-MTP parity event on 3.32.3: compiled-trace state contract (2026-10-10)

**Status: mechanism confirmed and fixed; R015 on the fixed build PASS.**
The Qwen3.5 traces in our fork read the fused GDN input projection as a
compile-time constant instead of compile state. MLX keeps compiled traces in
per-thread caches keyed by the function's address, and mlx-swift erases a
freed function only from the cache of the thread that frees it. After an
in-process model reload (R015 builds a new engine per cell), a new trace that
is allocated at a dead trace's address replays the dead trace on any thread
that still holds it. The declared weights are the new model's, but the
constants are the dead trace's, which belong to a different GDN layer. A lab
reload loop reproduced this on the old build: 4 replays of GDN layer traces
differed from a fresh trace, and one native request diverged from its ordinary
pair in `s1-p4096-o512`. On the fixed build, 74 natural replays (15 of them
compiled verify segments) were all bit-exact, with 0 divergences in 72 native
runs. When every same-signature trace is forced to share one cache entry, the
old build fails the startup batched-isolation gate and the fixed build
reproduces the reference outputs bit for bit.

The `d07d0cf09` R015 (fork `1007bc6`) failed parity and is **superseded, not
discarded**: its record stays FAIL, its evidence stays in
`step3-native-margin/`, and this file qualifies a new build with a code change
that addresses the mechanism.

## Evidence header

| Field | Value |
| --- | --- |
| macprovider | `8875789e7f6d378e5f1c9bf075a850ea07d9d50a` on `deps/mlx-swift-lm-3.32.3` (parent `44af9ba00`), local commit, not pushed |
| mlx-swift-lm fork | `905170fa017cef0e7ccc4483eb0bba59a77592d0`, tag `3.32.3-macprovider.4`, on `1007bc6` (`3.32.3-macprovider.3`): `7be182c` (upstream `1830ae4`, #631, cherry-picked with `-x`) and `905170f` |
| mlx-swift / MLX core | unchanged: `d073a644` (`0.32.3-macprovider.1`) / `ff1b9483` (`v0.32.2-macprovider.1`) |
| Serve executable | `swift build -c release` at `8875789e7`, reports 1.8.230, SHA-256 `56bdd9e9d997955473fe2f33fa51530b46fd07d1a689f17ee9aae7577b1007fa` |
| Lab-harness executable | `-DMACPROVIDER_LAB_HARNESS` at `8875789e7`, SHA-256 `05d685425b63afe6d922646fac953d53b7f6dee23b3c2633f1ec650edca21047` |
| `mlx.metallib` | `f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756` (unchanged; no kernel change) |
| Build trees | serve at `<studio-home>/build-mlx332`, lab harness at `<studio-home>/lab-332/src/phase3-binary`, both synced from `git archive 8875789e7` (`rsync --dry-run` empty), both resolved `mlx-swift-lm` to `905170f` |
| Host | Mac15,14, M3 Ultra, 256 GB, macOS 26A434, Swift 6.3.3 (Command Line Tools) |
| Live provider | Not stopped, restarted or reconfigured. Paused only by `bench.sh` and resumed each time (windows under Files). |

## 1. Mechanism

### 1.1 What a trace reads that it does not declare

`CompiledTrace` passes the `innerState()` of each declared module as compile
inputs. Any other array the body reads is captured into the trace's tape as a
constant (`mlx/compile.cpp` `compile_dfs`; `compile_replace` reuses tape
arrays without a primitive as they are).

- **Fused GDN projection.** `Qwen35GatedDeltaNet` builds one physical
  `QuantizedLinear` from the four input projections and installs four
  storage-sharing views as its registered children
  (`FusedQuantizedLinear.swift`). The fused module itself is not a child. With
  the fusion on (the default), `projectInputs` reads only the fused module, so
  the declared views are unused and the arrays that are actually read are tape
  constants. That held for all three trace kinds on `1007bc6`: the per-layer
  `compiledLinearLayer` (`Qwen35.swift`), the decode segments, and the
  compiled verify segments that `1007bc6` added. Upstream #631 (`1830ae4`,
  2026-10-02) fixed the first two to stop a leak. `1007bc6` predates the
  cherry-pick, so its verify segments inherited the old state list.
- **Fused-MoE cache.** `Qwen35FusedMoE.Cache` holds the block's own
  parameter objects (`QuantizedLinear.weight` and so on, and
  `QuantizedSwitchLinear.quantizedParts` returns the same objects). Any trace
  that declares the block or its layer therefore declares them too, and the
  trace swaps them for tracers in place. This is not a captured constant
  today. It would become one if a module in the block were replaced after
  resolution, because the cache never invalidated.
- Nothing else. All other arrays the bodies read are module parameters of
  declared modules. The scalars that the bodies create while tracing (the GDN
  kernel's `T` and checkpoint column) are per-trace constants by design and
  are part of the trace key through shape. RoPE, KV writes and SDPA stay
  outside the traces.

### 1.2 Why a constant becomes the wrong value: orphaned per-thread traces

- MLX core keeps the compile cache in a `static thread_local`
  (`mlx/compile.cpp:414`, `compile_cache_unsafe`), keyed by the function id.
  It also matches on the input shapes and dtypes and on the thread's default
  stream, which is thread-local too.
- mlx-swift uses the `CompiledFunction` object's address as the id. Its
  `deinit` erases the id from `mlx_detail_compile_cache()`, which returns the
  calling thread's cache only (`Transforms+Compile.swift`, `deinit`). The
  comment there still describes the cache as a process-global singleton.
- `ModelContainer.perform` runs on the Swift cooperative pool, so one
  model's compiled calls trace on many threads. When the model is released,
  every thread except the releasing one keeps its trace entries. The pool
  threads outlive the model.
- A later `CompiledFunction` allocated at a freed address gets the same id.
  The first time it runs on a thread that still holds an entry for that id
  with the same input signature, MLX does not trace. It replays the dead
  trace: the new call's inputs (arguments and declared state) flow through the
  old tape, and the old tape's constants are used as they are.
- Every GDN layer of a model has the same per-layer trace signature, and the
  middle segments of a hybrid model have the same segment signature. A replay
  across layers therefore runs layer *k* with layer *j*'s fused projection. If
  all state is declared, the same replay computes layer *k* exactly, because
  the tapes are structurally identical.

This also explains why the event was rare and transient. It needs a reload,
an address reuse by a trace with the same signature but a different layer or
segment, and a call on the one pool thread that holds the dead entry. It goes
away when the work moves to another thread. The two event blocks were wrong
from their first verify round, which fits a stale verify-segment entry that
was hit on the thread that ran those requests. Which trace and thread it was
in the formal run cannot be recovered from its logs.

## 2. Fix

Fork `3.32.3-macprovider.4` (`905170f`), on `1007bc6`:

1. `7be182c`: cherry-pick of upstream `1830ae4` (#631) with `-x`. It applied
   cleanly. `fusedProjectionTraceState` is added to the per-layer
   `compiledLinearLayer` state and to the decode segments through
   `traceState(forLayers:)`, together with upstream's leak test.
2. `905170f`:
   - The compiled verify segments (`CompiledVerifySegmentCaches`) declare
     `traceState(forLayers:)`, the same state as the decode segments.
   - `Qwen35SparseMoeBlock` overrides `update(modules:…)`,
     `update(parameters:…)` and `updateModule(key:_:)` to drop the fused-MoE
     cache (`Qwen35FusedMoE.Cache.invalidate()`), so the cache cannot hold
     arrays that no trace declares.
   - No kernel or numeric change. Declaring the projection changes which
     arrays are compile inputs, not the graph.

Not changed: the mlx-swift erase defect. After the fix, orphaned entries are
still left and replayed (74 replays below), but a replay computes the same
graph on the new model's arrays, so it is harmless for every Qwen3.5 trace.
The defect remains a hazard for any compiled function anywhere that reads an
undeclared array or bakes a non-shape constant whose value differs between two
functions with the same input signature. Fixing it means erasing every
thread's entry on `deinit`, for example by recording the caches each
`CompiledFunction` ran on. That is an mlx-swift change and is out of scope
for this pin.

## 3. Reproduction (Studio, lab harness, in-process reloads)

Method: in one `native-mtp-bench` process, the four one-slot R015 cells
(`s1-p1536-o128`, `s1-p1536-o512`, `s1-p4096-o128`, `s1-p4096-o512`) run in
R015 order. Each cell loads a fresh engine (`LLMModelFactory.loadContainer`,
the same per-cell reload as R015) and runs 1 warmup and 2 blocks of native
plus ordinary, compared token for token by content hash. The matrix repeats 6
times (`LAB_REPEAT=6`), which gives 24 reloads and 72 native runs per run. The
churn runs (`LAB_CHURN_GB=16`) allocate and free 16 GB of MLX buffers and a
burst of small objects before each engine. All runs used the exploratory
policy `build/cs-reload.json`, seed 20261006, and ran under `bench.sh`. The
prompts are deterministic per (cell, block), so the runs share reference
hashes.

The lab-only mlx-swift instrumentation (`build/patch_mlx_swift*.py`, never
shipped):

- **Stale-replay detector** (`MLX_LAB_STALE=1`). For stateful compiled
  functions (every `CompiledTrace`), it flags a call that ran on a thread and
  argument signature this instance never traced, but that did not trace
  either. That is a replay of an entry left by a freed function at the same
  address. Each replay is checked against a fresh trace of the same call under
  a never-used id: EQUAL means bit-identical outputs, MISMATCH means it
  differs. It also counts the trace entries orphaned at `deinit` (threads the
  function ran on, minus the freeing thread).
- **Forced replay** (`MLX_LAB_ALIAS=1`). Every stateful function uses one
  cache id per full input signature, so every same-signature trace replays
  the first one traced on that thread. This is the replay condition made
  deterministic.

The phase3 lab patch (`build/patch_p3*.py`) adds the repeat and churn knobs
and per-cell log lines. The lab trees used `../mlx-swift-lm` and
`../mlx-swift` path dependencies with the same macprovider sources as the
formal `d07d0cf09` lab binary.

| Run | Build | Reloads | Orphaned entries | Stale replays (EQUAL / MISMATCH) | Native runs | Native != ordinary | Outputs vs reference |
| --- | --- | ---: | ---: | --- | ---: | ---: | --- |
| A-old | `1007bc6` | 24 | (v1 detector, not counted) | 13 / **0** | 72 | 0 | reference |
| B-old-churn | `1007bc6` | 24 | 4,944 | 28 / **4** | 72 | **1** | 143/144 identical to A |
| C-old-alias | `1007bc6`, forced replay | 1 | - | - | - | - | **refused at startup**: batched isolation `proven=false crossRowDivergences=4`, serial decode `[240911]` vs `[248068]` |
| D-new-alias | `905170f`, forced replay | 4 | 434 | (all calls replay; 16 signatures) | 12 | 0 | **24/24 identical** to A |
| E-new-churn | `905170f` | 24 | 5,041 | **74 / 0** | 72 | 0 | **144/144 identical** to A |

Details:

- B's four mismatches are four GDN-layer traces (`compiledLinearLayer`, 3
  arguments, 45 state arrays) replayed on one thread within 12 ms, which is
  one forward pass. Their max abs difference from a fresh trace was 8.1-19.0.
  The same request, `s1-p4096-o512` repeat 2 block 1 (native), produced
  `ecd7ca63…` where the ordinary arm and every other run produced
  `e62af9de…`. Acceptance stayed at 0.861, so only part of the request ran on
  that thread. The cell is the same one as the formal event.
- B's 28 EQUAL replays: MoE-block traces (24 state arrays, B = 1 and 2) and
  attention traces (40 state arrays). These declare everything they read, so
  a replay is exact.
- E's 74 replays include 15 compiled verify segments (9 arguments, 224 state
  arrays, `[1, 2, 2048]`) and 22 GDN-layer traces (48 state arrays: the 45
  layer arrays plus the declared fused projection). All 74 were bit-exact.
- About 200 trace entries are orphaned per reload on both builds. Replays
  occur at about 0.5 to 3 per reload. On the old build, a replay corrupts only
  when it lands on a trace that reads an undeclared array of another layer or
  segment: 4 of 45 here, in one episode. That matches a one-off event in
  R015.
- No anomaly in A, the old build without churn. The rate is low enough that
  one 24-reload run can miss it, as the 208 earlier native runs did. Allocation
  churn made address reuse more frequent (13 to 32 replays).

## 4. Startup probes on the `8875789e7` serve build

`step3-compile-state/probes/`, isolated loopback 18190/18191, inside the
R015 `bench.sh` window.

| Probe | Gather parity | Batched isolation | `/v1/status` |
| --- | --- | --- | --- |
| A3B fused MoE (default) | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=true`, `paged_kv_decision=attached`, `local_proof_result=passed`, `slots_total=8` |
| A3B `MLX_LM_QWEN35_FUSED_MOE=0` | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=true`, `paged_kv_decision=attached`, `local_proof_result=passed`, `slots_total=8` |

Both are identical to the `d07d0cf09` and step-1 probes.

## 5. R015 on `8875789e7` (compiled verify ON)

Policy `r015/policy.json`, SHA-256
`002929b3bfc36a78533bba3b41c1e9a8795b6e6c22e193be35fe6f19ae862ceb`, was frozen
at 2026-10-09T21:27:09Z, before any request (`r015/policy-freeze.txt`). It is
byte-identical to `8722ddbf…` (the `d07d0cf09` policy) except for
`provider_commit` (`8875789e7…`) and `mlx_fork_revision` (`905170fa…`).
Compiled verify was on: `MLX_LM_QWEN35_COMPILED_VERIFY` was unset. Run
script `r015/r015-8875.sh` in the `bench.sh` window `r015/window-8875.sh`,
after the probes (live paused 21:27:25, resumed 22:24:41 UTC):

| Phase | Result |
| --- | --- |
| `native-mtp-hardware-e2e` (serve path) | exit 0, `status: pass`, 3 admissions, batch depth 2, `serve_path_verified=true` (21:30:12Z) |
| `--phase matrix` | exit 0, 133 records (21:52:32Z) |
| `--phase sustained` | exit 0, 1800 s, 213 records in total; JSONL SHA-256 `75e29942ccfbec0d7feb07adaa7d6175988c0a8ee1365535915747dadfa2dab7` (22:23:35Z) |
| Analyzer | **`overall_status: PASS`** (exit 0), unmodified output in `r015/analysis.{json,md}` |

Gates against the 2026-10-06 quiet PASS and the `d07d0cf09` run. Bounds are
Holm-corrected, as fractions of the ordinary arm. Thresholds: one-slot decode
LB at least +15% and TTFT UB at most +10%; gated decode LB at least -5%, TTFT
UB at most +5%, TPOT UB at most +5%.

| Cell | Decode LB 10-06 / d07d / **now** | TTFT p95 UB 10-06 / d07d / **now** | TPOT p95 UB now | Gap p99 UB now | Rejection UB | Status d07d → **now** |
| --- | --- | --- | ---: | ---: | ---: | --- |
| s1-p1536-o128 | +25.8% / +26.6% / **+25.5%** | +4.6% / +4.7% / **+5.0%** | -20.3% | -3.0% | 0 | PASS → **PASS** |
| s1-p1536-o512 | +24.2% / +25.1% / **+24.4%** | +4.7% / +4.5% / **+4.6%** | -19.6% | -22.6% | 0 | PASS → **PASS** |
| s1-p4096-o128 | +21.0% / +20.3% / **+20.6%** | +5.6% / +7.6% / **+7.1%** | -17.1% | -17.6% | 0 | PASS → **PASS** |
| s1-p4096-o512 | +18.5% / +17.7% / **+18.4%** | +5.6% / +7.8% / **+7.7%** | -15.6% | -18.7% | 0 | FAIL (`parity_mismatch`) → **PASS** |
| s2-p1536-o512 (gated) | -0.3% / -0.44% / **-0.48%** | +2.6% / +4.14% / **+4.51%** | +0.47% | +0.32% | 0 | PASS → **PASS** |
| s8-p1536-o512 (gated) + sustained | -0.2% / -0.31% / **-0.09%** | +0.8% / +2.84% / **+2.40%** | +0.15% | +1.57% | 0 | PASS → **PASS** |

- Parity: 0 mismatches in 60 matrix pairs and in the 40 sustained pairs.
  Native acceptance ranged from 0.819 to 0.954 across the 40 native runs with
  verify rounds. No block shows the collapse seen in `d07d0cf09`.
- Median decode, ordinary / native (tok/s): s1-p1536-o128 121.2 / 154.7
  (1.276), s1-p1536-o512 120.0 / 151.9 (1.266), s1-p4096-o128 116.8 / 146.3
  (1.252), s1-p4096-o512 116.3 / 139.7 (1.201), s2 144.0 / 143.6, s8
  206.5 / 206.4. These are within 1% of `d07d0cf09`. Declaring the projection
  costs nothing measurable, as expected for a change to compile inputs only.
- Errors, fallbacks and capacity rejections were 0 everywhere. The minimum
  available memory fraction was 0.609, and thermal state was nominal at the
  start and end of every run.
- The `d07d0cf09` R015 (FAIL, parity) is superseded by this run, not
  discarded. It is the run that exposed the mechanism, and its record and
  evidence stay in `step3-native-margin/`. The `d07d0cf09` run with compiled
  verify off (`step3-parity-event.md`, FAIL on throughput and TTFT) is
  superseded the same way.

## Files

Paths are relative to `step3-compile-state/`. Studio home paths are replaced
with `<studio-home>`.

- `build/`: lab instrumentation patchers, `run-repro.sh`, `seq1.sh`,
  `build.sh`, the repro policy `cs-reload.json`, and `summarize.py` /
  `compare.py` (parity, acceptance, replay counts, and hash comparison
  against a reference run).
- `repro/<run>/`: `run.log`, gzipped `bench.log` (with the `[lab-stale]` and
  `[lab-cell]` lines) and gzipped JSONL for A-E, plus the `bench.sh`
  consoles.
- `probes/`: serve logs and `/v1/status` for the two A3B startup probes.
- `r015/`: frozen policy and freeze record, status, hardware-e2e and bench
  logs, contamination log, `bench.sh` console, gzipped JSONL, analyzer output,
  and `r015-8875.sh` / `window-8875.sh`.
- Live pause windows (UTC, 2026-10-09):
  - A-old 20:00:31-20:28:09
  - repro B-E 20:28:25-21:27:07
  - probes + R015 21:27:25-22:24:41

## Trace-cache cleanup fix (2026-10-10)

**Status: fixed at the source; 0 dead-trace replays and no orphaned entries
in the reload loop; startup probes unchanged.** Section 2 left the erase
defect in place. It is now fixed in our MLX core fork, so a freed compiled
function's traces are removed from every thread, for every compiled function,
not only for the Qwen3.5 traces that 3.32.3-macprovider.4 made replay-safe.

### Fix

| Repo | Commit | Tag |
| --- | --- | --- |
| MLX core fork, `macprovider/0.32.2` | `c9196eb7161358f1e4a7f0605182186f8686e5f8` | `v0.32.2-macprovider.2` |
| mlx-swift fork, `macprovider/0.32.3` | `ca2f61d22c5e8afe87170525ebc1769f72da5b41` | `0.32.3-macprovider.2` |
| mlx-swift-lm fork, `macprovider/3.32.3` | `5203b732c451344aef936958ef3f765480cf6a9a` | `3.32.3-macprovider.5` |
| macprovider, `deps/mlx-swift-lm-3.32.3` | `cc64e13d7f67b102969c50ff6f4ef2a9e277aed9` (on origin: a concurrent session pushed it with its own `ffd79639b` on top) | - |

- Core (`mlx/compile.cpp`): `compile_cache_unsafe()` registers each new
  thread-local `CompileCache` in a process-wide list of weak pointers
  (`CompileCacheRegistry`, leaked on purpose so it outlives thread-local
  destructors; expired entries are pruned when a thread registers).
  `compile_erase(cache, fun_id)` now erases `fun_id` from every live
  thread's cache, not only the one passed in. It copies the live caches out
  under the registry mutex and erases outside it, so the only lock order is
  registry, then nothing; each `CompileCache::erase` takes that cache's
  exclusive lock, and `find()` already holds the entry vector it is filling
  through a `shared_ptr`, which is the cross-thread erase the cache was built
  for. The core's own `compile(fun)` deleter and the Python bindings use the
  same call and get the same fix.
- mlx-swift: submodule bump to `c9196eb7` and a rewrite of the
  `CompiledFunction.deinit` comment (it still described one process-global
  cache). `deinit` is unchanged: it still erases synchronously under
  `evalLock`, before the object's address can be reused, so no compiled
  call or trace runs on any thread while the erase does.
- The id is still the object's address. With every thread's entry gone
  before the memory is freed, a reused address cannot find a dead entry; a
  separate monotonic id is not needed.
- mlx-swift-lm and macprovider: revision bumps only (Package.swift,
  Package.resolved, `KVBuildIdentity.mlxSwiftLMRevision` /
  `mlxSwiftRevision` (so `mlxVersion`), the pin reader, the upstream-watch
  exception and its tests, and the rehearsal tuple).

**Decode path: no change.** No model, kernel, sampler, scheduler or
decode-path line changed in any repo. The change is compile-cache lifetime
bookkeeping: which cache entries exist after a compiled function is freed.
A trace that is not dead runs exactly as before, and `mlx.metallib` is
byte-identical (`f42aef60…`). Under AGENTS.md rule 2, the R015 PASS on
`8875789e7` (section 5) stands for this build; the only thing this build
removes is the replay of dead traces, which the R015 build had already made
exact for every Qwen3.5 trace.

### Reproduction: B scenario on the fixed build (F)

Same method as section 3 (24 in-process reloads, `LAB_REPEAT=6`,
`LAB_CHURN_GB=16`, `cs-reload.json`, under `bench.sh`), lab tree `fix2` =
`new2` (mlx-swift-lm `905170f`, same lab instrumentation) with the core
fix applied, plus `build/patch_core_lab.py` (lab only, never shipped). That
patch counts, in core, the live thread caches, the total function ids across
them, and the entries the erase removed from threads other than the freeing
one, and adds them to the `[lab-cell]` line. The Swift-side
`orphaned_thread_entries` counter is unchanged: it still counts the threads
a function ran on minus the freeing thread, which is what was left behind
before the fix.

| Run | Build | Reloads | Entries left on other threads at free (Swift count) | Removed by cross-thread erase | Function ids alive in all caches | Stale replays (EQUAL / MISMATCH) | Native != ordinary | Outputs vs A |
| --- | --- | ---: | ---: | ---: | --- | --- | ---: | --- |
| B-old-churn | `1007bc6` | 24 | 4,944 | - (all left) | not measured; grows ~200 per reload | 28 / **4** | **1** | 143/144 |
| E-new-churn | `905170f` | 24 | 5,041 | - (all left) | not measured; grows ~200 per reload | 74 / 0 | 0 | 144/144 |
| **F-fix-churn** | `905170f` + core `c9196eb7` | 24 | 5,071 | 4,897 | **8-21, flat across all 24 reloads** | **0 / 0** | **0** | **144/144** |

- Stale replays: 0 in 24 reloads, against 32 (B) and 74 (E) on the same
  workload. The detector is unchanged and fires on any call that neither
  traced nor had traced on that thread before.
- Leftover entries per reload: about 0. The total of live function ids across
  all thread caches stayed between 8 and 21 from the first reload to the last
  (the long-lived stateless `MLXNN` activations plus whatever the current
  engine holds), while the pre-fix builds left about 200 per reload.
- The Swift count exceeds the cross-thread erase count by 174 (3.4%) from
  repeat 2 on. Those are entries on pool threads that had already exited;
  their caches were destroyed with the thread (live caches varied from 2 to
  6), so nothing was left behind. Mach thread ports can also be reused, which
  the Swift count does not see.
- Parity and outputs: 72 native runs, 0 anomalies, acceptance min / median
  0.796 / 0.875 (E: identical), and all 144 content hashes identical to the
  A reference.
- The `[lab-cell]` line is printed before each engine loads, so the
  counters above are as of the start of the last cell (23 releases).

### Startup probes on the `ffd79639b` serve build

`ffd79639b` is `cc64e13d7` plus a concurrent session's test-seam commit
(`ThermalGate` test hook and two tests; no decode-path change).

`swift build -c release --product macprovider-cli` in
`<studio-home>/build-mlx332`, synced from `git archive ffd79639b:phase3-binary`
(`rsync --checksum --dry-run` empty after sync; the build resolved mlx-swift
`ca2f61d` with core `c9196eb71` and mlx-swift-lm `5203b73`; Package.resolved
unchanged by the build). The executable reports 1.8.230, SHA-256
`5abd005f677badbcd37fdbf186ff093de6d5d93f0a2411ee8ad0cb907ca29fa1`.
Isolated loopback 18192/18193, one `bench.sh` window (`probes/window-ffd7.sh`):

| Probe | Gather parity | Batched isolation | `/v1/status` |
| --- | --- | --- | --- |
| A3B fused MoE (default) | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=true`, `paged_kv_decision=attached`, `local_proof_result=passed`, `slots_total=8` |
| A3B `MLX_LM_QWEN35_FUSED_MOE=0` | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=true`, `paged_kv_decision=attached`, `local_proof_result=passed`, `slots_total=8` |

Identical to the `8875789e7` probes in section 4, including the two
non-distinguishing challenge pairs before the third distinguishes.

### Checks (macprovider `cc64e13d7`)

- `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest scripts.tests.test_upstream_watch`: 27 tests OK.
- `bash scripts/test-swift-package-lock.sh`: passed.
- `python3 scripts/gen_spec_index.py --check`: spec index up to date.
- No core C++ test was added or run: the Studio has no CMake, and this Mac
  has no XCTest. The reload loop above is the test.

### Files (added)

- `build/patch_core_lab.py`: lab-only core counters (applied on top of the
  core fix in the `fix2` lab tree).
- `repro/F-fix-churn/`: `run.log`, gzipped `bench.log` and JSONL;
  `repro/console-F-fix-churn.txt`.
- `probes/a3b-fused-ffd7/`, `probes/a3b-stock-ffd7/`: serve logs and
  `/v1/status`; `probes/window-ffd7.sh`, `probes/console-ffd7.txt`.
- Live pause windows (UTC, 2026-10-09), both through `bench.sh`, each
  resumed with `Provider is ready`:
  - repro F 22:38:04-23:10:57
  - probes 23:16:18-23:19:14
