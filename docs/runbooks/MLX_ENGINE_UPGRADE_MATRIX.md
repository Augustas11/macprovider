# MLX engine dependency-upgrade release gate

This is the mandatory correctness-first matrix for any change to `mlx-swift-lm`, `mlx-swift`, bundled core MLX/metallib, or adjacent generation APIs. It implements the acceptance surface tracked by #700. `phase3-binary/Package.resolved` is the production dependency authority.

## Hard rules

1. Resolve production only from the immutable fork tags in [Fork model](#fork-model), each pinned by full revision. Never resolve production from a branch, a version range, or a moved tag.
2. Record exact before/after versions and revisions for `mlx-swift-lm`, `mlx-swift`, `swift-transformers`, and `swift-jinja`.
3. Keep `swift-transformers` unchanged during the MLX engine migration; evaluate it separately under #966.
4. Build, test, resolve, candidate, and release jobs that compile `phase3-binary` or Malibu.app run only on the protected build toolchain: Xcode 26.6 (17F113) at `/Applications/Xcode_26.6.app`, Swift 6.3.3, macOS SDK 26.5, on the `macos-26` / `macos-26-intel` images. It replaced Xcode 16.4 / Swift 6.1 in the reviewed release-toolchain migration that landed with the mlx-swift-lm 3.32.3 dependency upgrade (`mlx-swift 0.32.3` declares `swift-tools-version: 6.3`; Related: #1906, #700). The protected `macos-15-intel` signers stay on the pinned signer toolchain (Xcode 16.4) for the sealed OpenSSL bottle and never compile the package. Any further toolchain move needs its own reviewed migration and release-runner proof.
5. Correctness, token accounting, cache ownership, and artifact parity gate throughput. No performance waiver may override a red correctness row.

## Evidence header

Every run must attach:

- branch and commit;
- macOS, Xcode, Swift, Mac model/chip/RAM, power and thermal state;
- all four resolved package versions/revisions;
- executable SHA-256, model ID and artifact SHA-256;
- `default.metallib` SHA-256 and the MLX/core revision it was built from;
- generation parameters, random seed, prompt fixture revision, and cache/prefill/speculative settings;
- baseline and candidate JSON outputs containing prompt token IDs, generated token IDs, decoded bytes, stop reason, prompt/completion accounting, and tool/reasoning parse result.

## Fork model

The production MLX runtime is three operator-owned forks under `Augustas11`.
They are the permanent production runtime: MacProvider makes no upstream
contributions and does not wait for upstream to carry its patches. Each
upstream release MacProvider adopts is a rebase of all three patch stacks onto
the new upstream tags, new fork tags, and a pass of the per-rebase acceptance
gate below. SPEC-048 MTP-3 (R003) names the exact authorized tuple; a new tuple
needs a SPEC revision.

| Fork | Upstream | Tag scheme | Current tag | Revision | Upstream base |
| --- | --- | --- | --- | --- | --- |
| `Augustas11/mlx-swift-lm` | `ml-explore/mlx-swift-lm` | `<upstream>-macprovider.<n>` | `3.32.3-macprovider.6` | `72c4ab082a08f291ba270a7303880e90036742e3` | `3.32.3` (`3b339ad6…`) |
| `Augustas11/mlx-swift` | `ml-explore/mlx-swift` | `<upstream>-macprovider.<n>` | `0.32.3-macprovider.2` | `ca2f61d22c5e8afe87170525ebc1769f72da5b41` | `0.32.3` (`19601207…`) |
| `Augustas11/mlx` (MLX core) | `ml-explore/mlx` | `v<upstream>-macprovider.<n>` | `v0.32.2-macprovider.2` | `c9196eb7161358f1e4a7f0605182186f8686e5f8` | `v0.32.2` (`1f8e74e3…`) |

Tags are immutable: a change is a new `<n>`, never a moved tag. Each link pins
the next by full revision: `phase3-binary/Package.swift` pins mlx-swift-lm,
mlx-swift-lm's manifest pins mlx-swift, and mlx-swift's `Source/Cmlx/mlx`
submodule commit pins core (`Source/Cmlx/mlx-c` stays upstream). Swift 6.3 is
the effective minimum for the graph (mlx-swift declares tools version 6.3);
the mlx-swift-lm fork keeps upstream's tools version.

### Patch inventory

Every rebase replays these stacks and drops any patch upstream now carries
(record which, and why it is equivalent).

mlx-swift-lm (`3.32.3..3.32.3-macprovider.6`):

| Patch | Commits | What it carries |
| --- | --- | --- |
| MTP cache transactions | `87cefcd` | Public row-mapped `MTPKVCacheTransaction` stage/commit/discard/rewind. |
| Packed MTP verification | `d7404cf`, `5c8811c`, `2c36a18`, `5402834`, `47835cf`, `038edb7`, `53e32e9`, `edeee8a` | `verifyMTPPackedTargets`, exact state across rounds, row state outside drafters, serialized drafter access, standalone Qwen MTP for packed hybrid schedulers, padded zero-proposal Mamba fix, host offset mirrors, deferred Mamba commit evaluation. |
| Packed drafter | `49aa6af` | `advanceAndProposePacked`: every native row's drafter advances and proposes in one forward. |
| GDN verify checkpoint | `9500c78` | `gatedDeltaUpdateCheckpointed`, one recurrent pass, bit-identical to the split recurrence. |
| SSM mask skip | `d9897e6` | No all-true SSM mask when no packed verify row is padded. |
| Fused A3B MoE | `e787537`, `965f78e` | `MLX_LM_QWEN35_FUSED_MOE` decode/verify-width kernels; eligible only for the exact stock module types and exact quantized layout, stock path otherwise. |
| Compiled MTP verify | `1007bc6` | Qwen 3.5 verify step compiled like single-token decode (`MLX_LM_QWEN35_COMPILED_VERIFY`). |
| Compile-state ownership | `7be182c` (upstream #631, `-x`), `905170f` | The fused GDN projection and every array a verify trace reads are declared compile state. |
| Core pin | `37f0d7c`, `5203b73` | Resolves the mlx-swift fork. |
| Tests | `8941054`, `72c4ab0` | Prepared fused-GDN compiled-verify fixture and in-place reload regression. |

`784f021` (Swift 6.1 tools version) is reverted by `e81dd7c`; drop both on the
next rebase.

mlx-swift (`0.32.3..0.32.3-macprovider.2`): `d073a644`, `ca2f61d2` move the
`Source/Cmlx/mlx` submodule to the core fork and update the compiled-function
erase documentation. No API change.

MLX core (`v0.32.2..v0.32.2-macprovider.2`):

| Patch | Commit | What it carries |
| --- | --- | --- |
| Batch-invariant small-M quantized matmul | `ff1b94832` | No `qmv_wide` (every small-M product stays on `qmv`) and no `qmm_splitk` (`qmm` reduces K in one order for every M), so a continuously batched row matches its serial result. |
| Every-thread compiled-function erase | `c9196eb71` | Freeing a compiled function erases it from every thread's compile cache, so a later function at the same address never replays a dead trace. |

### Bounded routing exceptions

Within each route, `QuantizedMatmul` is batch invariant: a row's result
does not depend on how many rows share the call. These routes still depend on
the call's shape:

- `QuantizedMatmul` (`mlx/backend/metal/quantized.cpp` ~1798) flattens
  `[rows, chunk]` to `M = rows x chunk` and takes `qmv` (`qmv_quad` at K
  64/128) below `vector_limit`, `qmm` at or above it.
  `vector_limit = get_qmv_batch_limit(K, N, device)` for transposed weights
  (4 otherwise); across every architecture generation, device class and shape
  its largest value is 33 (M3 Ultra: 32 for K, N <= 2048, 18 up to 4096, 12
  above; M5-class: 33/25/13). **Prefill is enforced by the CB grouping
  rule** below: a chunk co-batches only at 33 tokens or more, where it
  already takes `qmm` alone. Before that bound, on the Studio every
  Qwen3.6-27B projection has limit 12, so a 6-11-token chunk took `qmv` alone
  and `qmm` beside a second row. Decode carries one token per row, so `M` is
  the decode row count (at most 8). That stays below the limit on the Studio
  (smallest limit 12) and on every Ultra and M3-or-later device, but M1/M2
  non-Ultra devices have limit 6 for K or N above 4096, where 6-8 decode rows
  switch to `qmm`. The grouping rule cannot cover decode; a CB tuple on such
  a device needs its own batched-isolation evidence at 6-8 rows.
- `GatherQMM` (`mlx/backend/metal/quantized.cpp` ~1901) takes
  `gather_qmm_rhs` for sorted gathers when `M == 1`, `B >= 16` and
  `B / E >= 4`, otherwise `gather_qmv`. MoE expert projections sort once a
  call carries 64 or more expert selections (`SwitchGLU`), with `B` =
  tokens x top-k; Qwen3.5 then also takes the direct weighted reduction.
  Decode stays below the `gather_qmm_rhs` switch: A3B (256 experts, top-8) at
  8 rows is `B / E = 0.25`, and decode/verify widths of at most seven tokens
  per row take the fused path when it is on. With `MLX_LM_QWEN35_FUSED_MOE=0`,
  8 decode rows reach 64 selections and switch to the sorted gather and the
  direct reduction (still `gather_qmv`); the 2026-10-10 grouped-prefill probe
  (`audits/2026-10-10-mlx-swift-lm-332/ROUND1_FIXES.md`) found 14/14 rows
  token-identical to their lone runs at 8 rows.
  **Prefill is enforced by the CB grouping rule.** Continuous batching groups
  up to four prefill rows with the same cursor and chunk length into one
  forward, and a group carries every row's selections. Before the rule, a
  32-127-token A3B chunk took `gather_qmv` alone and `gather_qmm_rhs` when
  grouped, and greedy outputs depended on the neighbours (Studio, build
  `38aff2880`: 69 of 108 grouped rows differed from their lone runs, exactly
  in the groups whose combined selections reach 1024). Now
  `ContinuousBatchPrefillGroupingRule` (`ContinuousBatchScheduler.swift`,
  SPEC-038 FR-CB2 v0.3.11/v0.3.12) co-batches a chunk only when it is at
  least 33 tokens (the `QuantizedMatmul` bound above) and, on MoE models,
  `chunk x top-k >= max(16, 64, 4 x experts)`, read from the loaded model's
  `config.json` (A3B: 128 tokens; Qwen3.6-27B: 33). Shorter chunks prefill
  alone; an MoE configuration without both counts, or a configuration that
  declares no quantization or excludes a layer from it, prefills every chunk
  alone. The serve log prints
  `event=continuous_batch_prefill_grouping min_grouped_chunk_tokens=N` at
  scheduler build. At the default 512-token chunk the scheduler balances
  the chunks of an uncached prompt of 128 or more tokens to at least 128
  tokens each, so long prompts still group (R015: 1536/4096 tokens in
  512-token chunks).
  The rule's constants are the fork's routing bounds: a rebase that changes
  `get_qmv_batch_limit`, the `GatherQMM` condition or the `SwitchGLU` sort
  threshold updates them.
- Unquantized matmuls (steel GEMM) take `gemv_wide` for 2-15 rows and pick
  split-K partitions and tiles from M. The served Qwen3.6 text paths have no
  unquantized matmul (the only unquantized text weights are the depthwise
  `conv1d` of the linear-attention layers, a per-row kernel; the unquantized
  vision tower does not run for text). The grouping rule never groups a model
  whose configuration declares no quantization or excludes a layer.
- Attention picks its kernel from the query length, key length, head
  dimensions and mask, never from the batch. Grouped rows share chunk length
  and offset, so they take the same attention route as each row alone. With
  head dimension 256 and more than 8 query tokens the unfused path runs
  batched GEMMs whose tile size follows `rows x heads x L x keys`; tiles
  change the blocking, not each element's K accumulation order.
- Non-transposed small-M products keep `qvm` / `qvm_split_k`. The served
  quantized linears are transposed, so serve shapes do not use them.
- `QQMatmul` always takes the vector route. It is independent of `M`, so it
  cannot split a row's result by batch size.

A new model, expert count, top-k, or batch/prefill shape re-runs the startup
isolation probe and re-derives these bounds before it serves.

### Pin sites

Moving a tag changes these together. The checks that catch a disagreement:

- `phase3-binary/Package.swift` against `phase3-binary/Package.resolved`: the
  CI `swift-package-lock` job resolves with
  `-onlyUsePackageVersionsFromResolvedFile`.
- `Package.resolved` against `KVBuildIdentity.mlxSwiftLMRevision`
  (`KVConversationColdTierAdapter.swift`): `KVBuildIdentityDriftTests`.
- `Package.resolved` against `scripts/read_swiftpm_pins.py`, which holds the
  reviewed fork tuple (fork revisions and upstream bases): the reader fails
  closed on an unreviewed fork revision, and
  `scripts/tests/test_upstream_watch.py` reads the checked-in file.
- `read_swiftpm_pins.py` against the SPEC-048 R003 fork table:
  `ReviewedForkTupleSourceTests` in `test_upstream_watch.py`.
- `scripts/check-upstream-throughput-blockers.sh` imports the tuple from
  `read_swiftpm_pins.py` and carries no revision of its own; the same test
  class fails if it hardcodes one or binds a different value.

The native-MTP bench (`NativeMTPHardwareE2ERunner.upstreamRevision`) reads
`KVBuildIdentity`, and `scripts/native_mtp_rehearsal_release.py` reads
`Package.resolved` through `read_swiftpm_pins.py`.

### Per-rebase acceptance gate

Mandatory for every new fork tuple, in addition to the matrices below. Record
results in the evidence header.

| Row | Required proof |
| --- | --- |
| Patch replay | Each inventory patch applies or is dropped with a recorded upstream equivalent; the fork tests for every touched surface pass. |
| Startup batched-isolation (fused MoE on) | On the Studio A3B tuple: `established=true`, `proven=true`, `crossRowDivergences=0`, `paged_kv_decision=attached`, with the fused path active. |
| Startup batched-isolation (fused MoE off) | The same with `MLX_LM_QWEN35_FUSED_MOE=0`. |
| CB enable gate | The rows of `docs/runbooks/continuous-batching-enable-gate.md` that run on the Studio pass on the new build; an open row that also fails on the previous build is recorded, not hidden. |
| Native-MTP R015 | Required when a decode-path line changed since the last R015 evidence (AGENTS rule 2): name the line, or record that none changed. |
| Cross-thread model reload | A reload loop that frees and rebuilds models across threads shows zero stale trace replays (every replay bit-exact to a fresh trace). |
| Compile-state ownership | Every compiled trace declares every model array it reads; the compiled verify/decode steps stay bit-identical to the general path on a `prepare()`d model, including after weights are reloaded in place. |
| Fused-layout eligibility and fallback | The stock A3B layout is fusable; mismatched layouts, rotated `SwitchGLU`, and adapter-backed projections fall back to the stock path. |
| Routing bounds | The core routing patches still apply, and the bounded exceptions above are re-derived for the new upstream, including the constants in `ContinuousBatchPrefillGroupingRule`. |
| Grouped short prefill | On the A3B tuple with CB on, 32-127-token prompts sent concurrently in pairs and quads behind a decoding row produce exactly their lone greedy outputs, fused MoE on and off. The same on the dense 27B tuple with prompts below and above the 33-token bound. |

## Package and toolchain preflight

| Gate | Required result |
| --- | --- |
| Fork tags | Every fork in the tuple has a new immutable tag on the rebased stack, pushed before the pin moves; each link pins the next by full revision (see [Fork model](#fork-model)). |
| Deterministic resolution | A clean `Package.resolved` regeneration resolves the reviewed exact graph; no branch dependencies or unexplained transitive drift. |
| Protected toolchain | Debug and release manifests/builds pass on the protected Xcode/Swift pair. A newer pair requires its own migration and release-runner proof. |
| API inventory | Compile errors and deprecations from `GenerateParameters`, cache creation/configuration, model factories, loading and generation are explicitly adapted and reviewed. |
| Core provenance | The core MLX revision carried by `mlx-swift` is recorded; a newer standalone core release is not claimed unless it is actually bundled. |

Pin bumps that change tokenizer cleanup rules must re-run the table-driven incremental cleanup oracle in `StreamingEmitterCleanupRewriteTests`.

## Token-exact model and protocol matrix

Run temperature 0 with identical fixtures and parameters. Unless a row explicitly documents an intended upstream correction, baseline and candidate token IDs, EOS/stop reason, tool-call payload, and accounting must match exactly.

| Row | Required proof |
| --- | --- |
| Dense control | Existing Llama-family and Qwen dense models load and generate exact baseline output. |
| Gemma 4 MoE | Reviewed Gemma 4 26B-A4B artifact loads, generates, stops, and reports usage without loader/shape mismatch. |
| GPT-OSS plain text | Harmony plain-text response has no channel/control-token leakage. |
| GPT-OSS reasoning | Analysis/final channel extraction and hidden/reported token accounting match the current contract. |
| GPT-OSS tools | Tool rendering, recipient/channel parsing, argument bytes, and terminal handling match; upstream parser adoption does not double-parse Macprovider's implementation. |
| Qwen tools | Qwen XML/JSON grammar covers hyphenated names, declared-tool allowlisting, null/default schemas, and streaming fragments. |
| Nemotron tools | Nemotron template, tool grammar, EOS, and accounting remain exact. |
| Stop handling | EOS IDs, explicit stop strings, multi-token stops, cancellation, and max-token termination have exact output and completion-token counts. |
| Safetensors indexes | Single-file and sharded/indexed artifacts resolve the intended tensors and reject ambiguous/missing files. |
| Null/default schemas | Absent, null, empty and default-valued tool schemas remain deterministic and fail closed where required. |

## Cache, prefill, compile, and speculative matrix

| Row | Required proof |
| --- | --- |
| Reusable fp16 KV | Two-turn and multi-turn hot reuse recover late prior-turn facts; cache offsets equal the committed canonical token ledger. |
| Quantized reusable KV | #965 real-model ownership/aliasing/mutation tests pass before `kvBits` is re-enabled for any `conversation_key`. Until then Macprovider must fail closed to fp16 reuse. |
| Cold-tier ABI | Persist/promote/reuse passes with exact identity; old dependency-version cache state is invalidated or explicitly migrated, never silently read. |
| Paged KV | Default-off behavior, descriptor admission, bridge capability and metallib/kernel parity remain intact; no unsupported tuple becomes routable. |
| `.remainder` prefill | Legacy/current prefill boundary produces exact tokens and accounting across below/equal/above-step prompts. MacProvider keeps legacy `.remainder` chunking on every generation path until a reviewed balanced-prefill migration passes the next row. |
| Balanced/adaptive prefill | Evaluate only after `.remainder` parity is green, as its own reviewed migration: exact output and accounting against `.remainder`, memory bounds, and cancellation behavior must all pass before any path leaves `.remainder`. |
| Compiled decode (generic) | The generic `GenerateParameters` compile path stays off until #964/upstream #406 is released and stateful KV offsets, retrace and failure recovery pass. This row does not cover the model-specific compiled traces below. |
| Compiled decode/verify (Qwen 3.5, fork) | The fork's model-specific compiled single-token decode segments and compiled MTP verify step (`MLX_LM_QWEN35_COMPILED_VERIFY`) stay on only while the per-rebase compile-state rows pass: bit-identical to the general path, every array a trace reads declared as compile state, zero stale trace replays across model reload. They are not the generic compile path and do not satisfy or reopen #964. |
| Speculative pre-wrap | Exact target-only output parity with accepted/rejected draft paths in streaming and non-streaming modes. |
| Speculative cache wrap | #377 crosses the rotating-window boundary and proves exact rollback. While upstream #424 is unresolved, classic production speculation remains disabled by default; the global-context boundary check is defense in depth, not enable authority. |
| Speculative failure | Draft load/generation/cancellation failure falls back before mixed output and leaves no conversation lease or stale cache state. |
| Concurrency | Concurrent model requests, load/swap, cancellation, heartbeat and coordinator control traffic remain responsive and isolated. |

## Artifact and release parity

This matrix is subordinate to
`docs/runbooks/provider-cli-release-verification.md`. A GREEN engine matrix does
not authorize publication unless the complete provider release contract also
passes, including previous-stable updater behavior, nested-signing posture,
immutable downloaded-asset verification, live authority/recommendation checks,
and failed-publication recovery.

- Build with `phase3-binary/dist/package.sh` or the release workflow, not only `swift run`.
- Verify the installed executable and every packaged metallib against immutable SHA-256 values.
- Prove the metallib was built for the same resolved MLX graph as the executable.
- Run model load/generation from the installed release candidate with the worktree absent from `PATH`.
- Verify standalone CLI and Malibu-packaged CLI byte identity where both ship.
- Reject benchmark records whose dependency metadata differs from `Package.resolved`.
- Run cold start, warm start, model swap, cancellation, restart/reboot, and failure recovery.

## Performance evaluation (only after all correctness rows are green)

Measure TTFT, decode tok/s, peak RSS, Metal memory, energy/thermal state, and concurrency responsiveness against identical artifacts and fixtures. Report regressions as well as improvements. Existing catalog and regression budgets remain release gates; an unexplained failure outside those budgets is RED. oMLX may be used as a benchmark/reference implementation, never as proof that the Swift runtime is correct.

## Decision

- **GREEN:** every applicable correctness, artifact, and performance-budget row passes; no unexplained token/accounting delta; package and toolchain gates pass.
- **RED:** any correctness, ownership, rollback, accounting, tool parsing, cold-cache ABI, artifact-parity, or unexplained performance-budget failure. Revert the pin candidate.
- **BLOCKED:** required upstream release/package/toolchain condition is absent. Keep production pins unchanged.

Current protected baseline (2026-10-10): fork `mlx-swift-lm 3.32.3-macprovider.6` (`72c4ab08…`, upstream `3.32.3`), fork `mlx-swift 0.32.3-macprovider.2` (`ca2f61d2…`, upstream `0.32.3`), and fork MLX core `v0.32.2-macprovider.2` (`c9196eb7…`, upstream `v0.32.2`), built on Xcode 26.6 / Swift 6.3.3 / macOS SDK 26.5; `swift-transformers` and `swift-jinja` exactly as pinned in `phase3-binary/Package.resolved`. Previous baseline (2026-09-04): `mlx-swift-lm 3.31.4`, `mlx-swift 0.31.4`, `swift-transformers 1.3.4`, `swift-jinja 2.4.2` on Xcode 16.4 / Swift 6.1.

`swift-transformers` was moved `1.0.0 → 1.3.3` by Dependabot #1336 without the
#966 token-exact gate, then to `1.3.4` under that gate (2026-09-04). The gate is
recorded in `audits/2026-09-04-swift-transformers-134/GATE.md`: token-exact for
all byte-level/BPE catalog families (Qwen, Llama, GPT-OSS); Gemma carries five
intended Unicode corrections (invalidate Gemma Unicode-heavy KV caches);
Nemotron is newly loadable. `mlx-swift-lm` / `mlx-swift` were frozen throughout.
