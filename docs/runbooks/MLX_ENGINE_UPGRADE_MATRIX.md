# MLX engine dependency-upgrade release gate

This is the mandatory correctness-first matrix for any change to `mlx-swift-lm`, `mlx-swift`, bundled core MLX/metallib, or adjacent generation APIs. It implements the acceptance surface tracked by #700. `phase3-binary/Package.resolved` is the production dependency authority.

## Hard rules

1. Use a tagged, remotely consumable `mlx-swift-lm` release. Never resolve production from `main`.
2. Record exact before/after versions and revisions for `mlx-swift-lm`, `mlx-swift`, `swift-transformers`, and `swift-jinja`.
3. Keep `swift-transformers` unchanged during the MLX engine migration; evaluate it separately under #966.
4. Keep production on Xcode 16.4 / Swift 6.1 unless a separately reviewed release-toolchain migration lands first. `mlx-swift 0.31.5/0.31.6` require Swift 6.3.
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

## Package and toolchain preflight

| Gate | Required result |
| --- | --- |
| Tagged release | Candidate functionality is in a published `mlx-swift-lm` tag; upstream #518 or equivalent remote-package consumption failure is closed. |
| Deterministic resolution | A clean `Package.resolved` regeneration resolves the reviewed exact graph; no branch dependencies or unexplained transitive drift. |
| Protected toolchain | Debug and release manifests/builds pass on the protected Xcode/Swift pair. A newer pair requires its own migration and release-runner proof. |
| API inventory | Compile errors and deprecations from `GenerateParameters`, cache creation/configuration, model factories, loading and generation are explicitly adapted and reviewed. |
| Core provenance | The core MLX revision carried by `mlx-swift` is recorded; a newer standalone core release is not claimed unless it is actually bundled. |

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
| `.remainder` prefill | Legacy/current prefill boundary produces exact tokens and accounting across below/equal/above-step prompts. |
| Balanced/adaptive prefill | Evaluate only after `.remainder` parity is green; preserve exact output, memory bounds and cancellation behavior. |
| Compiled decode | Generic compile remains off until #964/upstream #406 is released and stateful KV offsets, retrace and failure recovery pass. |
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

Current protected baseline (2026-08-09): `mlx-swift-lm 3.31.4`, `mlx-swift 0.31.4`, `swift-transformers 1.0.0`, `swift-jinja 2.4.2`.
