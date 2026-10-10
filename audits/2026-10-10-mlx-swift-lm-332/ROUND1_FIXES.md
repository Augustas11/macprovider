# Round 1 fixes: mlx-swift-lm 3.32.3 / MLX 0.32 (PR #1927)

Round 1 ran the three lanes over the scope in `SCOPE.md` (prompts
`PROMPT_*.md`). Verdicts: architecture 0 C / 1 H / 1 M / 3 L, code
0 C / 0 H / 1 M / 1 L (+1 INFO), security 0 C / 0 H / 0 M / 1 L.

Fork commits are on `Augustas11/mlx-swift-lm` branch `macprovider/3.32.3`,
tag `3.32.3-macprovider.6` (`72c4ab082a08f291ba270a7303880e90036742e3`). The
mlx-swift (`0.32.3-macprovider.2`) and MLX core (`v0.32.2-macprovider.2`) forks
are unchanged.

## Finding to fix

| # | Lane / severity | Finding | Fix |
| --- | --- | --- | --- |
| 1 | Architecture HIGH | SPEC-048 R003 authorized only the 3.31.4-based `ca8c384c…` candidate and excluded other revisions and transitive sources. | `16750f2e3`: SPEC-048 v0.1.28. R003 adopts the permanent fork model, authorizes the exact three-fork tuple with upstream bases, adds compiled verification, declared compile state, exact-type fused-MoE eligibility, batch-invariant routing and every-thread erase to the authorized surface, and defines the per-rebase review gate. The upstream-replacement removal trigger, the re-review date and the `ca8c384c…` authorization are removed. CONFORMANCE version and R003 rationale updated; spec index regenerated. No expiry or review-due date added. |
| 2 | Architecture MEDIUM | The upgrade matrix did not document the fork rebase process. | `83934b573`: `docs/runbooks/MLX_ENGINE_UPGRADE_MATRIX.md` gains Fork model (repos, upstream bases, tag scheme, current tags and revisions), patch inventory per fork, pin sites, bounded routing exceptions, and the mandatory per-rebase acceptance gate. The model-specific compiled decode/verify row is separate from the generic #964 row; #965 is unchanged; `.remainder` stays until a reviewed balanced-prefill migration passes. |
| 3 | Code MEDIUM | Fused-MoE eligibility accepted subclasses (`RotateSwitchGLU`, `QLoRALinear`) and would drop their computation. | Fork `965f78e`: eligibility requires `type(of:) ==` the stock `SwitchGLU`, `QuantizedSwitchLinear` and `QuantizedLinear`; anything else takes the stock path. Rejection tests for a rotated `SwitchGLU` and LoRA adapters on the shared expert and router, with a stock control. Pinned in `38aff2880`. |
| 4 | Security LOW | Evidence recorded an unrelated live binary replacement, backup filename and watchdog timestamps. | `61cf9591b`: removed from `step3-compile-state.md`; the same class of detail (backup name, another session's deployment and canary) removed from `step45-throughput.md`. The rest of `docs/research/mlx-swift-lm-3.32.3/` was grepped for backup names, watchdog, kickstart, buyer-runner, Pearl and other-session details; the only other match is the `last_watchdog` status field name. |
| 5 | Code LOW | Compiled-verify tests never called `prepare()`, so the fused GDN projection was never in the traced step. | Fork `8941054`, `72c4ab0`: a prepared bf16 q4 fixture asserts every GDN layer has its fused projection and declares it as trace state; a reload regression loads new weights in place into the traced fused projection and requires the replay to match the general path, then frees and rebuilds models with different weights. Mutation check on the Studio: with the fused projection removed from `traceState(forLayers:)` the reload test fails (hidden state and cache bitwise mismatches); restored, it passes. Pinned in `38aff2880`. |
| 6 | Architecture LOW | The fork lowered swift-tools-version to 6.1 although the graph needs Swift 6.3. | Fork `e81dd7c`: upstream's 6.2 restored. Pushed history is not rewritten; the runbook inventory says to drop `784f021` and `e81dd7c` together on the next rebase. Pinned in `38aff2880`. |
| 7 | Architecture LOW | `native_mtp_rehearsal_release.py` stamped a literal runtime revision. | `763e975f2`: derived from `phase3-binary/Package.resolved` through `scripts/read_swiftpm_pins.py`, fail closed when absent or unreviewed; `scripts/tests/test_native_mtp_rehearsal_release.py` covers both. |

## Carried

| Lane / severity | Finding | Reason |
| --- | --- | --- |
| Architecture LOW | Build and signer toolchain profiles are encoded in both `scripts/build-release-provenance.py` and `scripts/validate-release-toolchain.py`. | Release-tooling refactor outside this dependency upgrade. A drift fails provenance generation loudly; it cannot publish a wrong record. |
| Code INFO | `GatherQMM` sorted-gather, `qvm`, `QQMatmul` routing exceptions. | Recorded with bounds in the runbook. Decode and verify stay below the `gather_qmm_rhs` switch. Grouped short prefill (two to four rows of 32-127 tokens on A3B) can cross it; the startup isolation probe does not cover that shape. No token divergence is demonstrated. |

## Verification

Fork (Mac Studio, Xcode toolchain via `DEVELOPER_DIR`, metallib `f42aef60…`):
`swift test --filter "Qwen35FusedMoETests|Qwen35CompiledVerifyTests"` at
`72c4ab0`: 12 tests, 0 failures. A Studio-only probe (not committed) loaded the
served A3B artifact through `LLMModelFactory` with the `.6` code:
`blocks=40 fusable=40 forward_fused_T1=true`, so the stock A3B layout still
takes the fused path.

macprovider build `38aff2880` on the Studio (`swift build -c release`,
resolved `72c4ab08…` / `ca2f61d2…` / core `c9196eb7…`), executable SHA-256
`fbf355ac31fe5ffe375eba52bb738d9d933b1865e23b5ac787982f168ae18782`, metallib
`f42aef609211980ad87cf72f75b5551b767a0160858257b997bac49f0e95a756`. Startup
probes on isolated loopback:

| Probe | Parity | Batched isolation | CB |
| --- | --- | --- | --- |
| A3B fused MoE on (default) | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=True paged=attached proof=passed slots=8` |
| A3B fused MoE off (`MLX_LM_QWEN35_FUSED_MOE=0`) | `established=true`, 640/640 | `proven=true rowsDecoded=2 rowFailures=0 crossRowDivergences=0 challengeDistinguishing=true` | `active=True paged=attached proof=passed slots=8` |

Native-MTP R015 was not rerun: `.6` changes no decode-path line relative to
the R015 build's fork (eligibility restriction for non-stock module types,
tests, manifest tools version), and the stock A3B layout resolves to the same
fused path (AGENTS rule 2).

Checks: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest
scripts.tests.test_upstream_watch` (27 OK),
`scripts.tests.test_native_mtp_rehearsal_release` (2 OK),
`bash scripts/test-swift-package-lock.sh` (passed),
`python3 scripts/check_spec_governance.py` (passed),
`python3 scripts/gen_spec_index.py --check` (up to date),
`python3 scripts/check_spec_pr_declaration.py` on the updated PR body
(passed).
