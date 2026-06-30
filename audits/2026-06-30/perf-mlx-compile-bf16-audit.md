# perf/mlx-compile-bf16 — audit round narrative

**Date:** 2026-06-30
**Branch (audit subject, unmerged):** `perf/mlx-compile-bf16`
**Branch (this docs landing):** `docs/perf-mlx-research-findings`
**Spec:** `specs/perf-mlx-compile-bf16-upgrade.md`
**Discipline:** three-lane codex (code / security / architect),
narrow-scope IMPL audit per
`[[feedback-three-lane-codex-audits]]` / `[[feedback-build-audit-loop]]`.

> **Note:** the code that was the subject of these audits lives on the
> unmerged `perf/mlx-compile-bf16` branch (PR #265, since closed in
> favor of this docs-only landing). The audit narrative is preserved
> here because the convergence record + finding history is useful
> input for the compile() wire-in follow-up that will eventually
> ship the real perf surface.

## Round 1

Prompts (one per lane):
- `specs/AUDIT_PERF_MLX_COMPILE_BF16_CODE_PROMPT.md`
- `specs/AUDIT_PERF_MLX_COMPILE_BF16_SECURITY_PROMPT.md`
- `specs/AUDIT_PERF_MLX_COMPILE_BF16_ARCHITECT_PROMPT.md`

Artifacts (codex output):
- `.omc/artifacts/ask/codex-perf-mlx-compile-bf16-code-lane-audit-round-1-…md`
- `.omc/artifacts/ask/codex-perf-mlx-compile-bf16-security-lane-audit-round-1-…md`
- `.omc/artifacts/ask/codex-perf-mlx-compile-bf16-architect-lane-audit-round-1-…md`

Tally:

| Lane | Critical | High | Medium | Low | Nit |
|---|---|---|---|---|---|
| code | 0 | 0 | 0 | 1 | 0 |
| security | 0 | 0 | 0 | 1 | 0 |
| architect | 0 | 0 | 0 | 5 | 1 |

### Findings fixed inline (round 1 → round 2)

- **CODE-1 LOW** (`WeightCast.swift`): `Module.apply` with the default
  `Module.filterValidParameters` does NOT prune `QuantizedLinear` /
  `QuantizedEmbedding` subtrees — the filter only rejects "invalid"
  parameter keys. As written, `MACPROVIDER_BF16_WEIGHTS=1` would have
  cast `QuantizedLinear.scales` / `.biases` (fp16 on 4-bit checkpoints)
  to bf16, which the dequant path is not designed to handle. **Fix:**
  introduced `WeightCast.nonQuantizedParameterFilter` that returns
  `false` when the parent module conforms to `any Quantized`, otherwise
  delegates to `Module.filterValidParameters`. Both `castFloat16ToBFloat16`
  and `DTypeHistogram.init` now use this filter, so the diagnostic
  histogram and the actual cast see the same surface.

- **SEC-2 LOW** (`DecodeBenchCommand.swift`): operator-supplied `--label`
  was interpolated into the output filename before `appendPathComponent`,
  allowing `--label '../etc/passwd'` to escape `--output-dir`. Not a
  remote / money-path surface (operator-local CLI), but worth hardening.
  **Fix:** added `sanitizeFilenameComponent(_:)` — ASCII alnum + `_`
  + `.` + `-` allowlist, replaces other bytes with `_`, collapses runs,
  trims leading separators, caps at 80 chars, empty → `"unlabeled"`.
  Both `label` and `modelTag` are now sanitized before the filename
  is assembled. Three new tests in `WeightCastTests.swift` pin the
  contract.

### Findings tracked as LOW/NIT, no inline fix

- **ARCH-1..6** (all LOW/NIT): architectural suggestions — alternative
  override paths for Phase 1, the per-request lifetime of
  `CompiledDecodeStep`, the bench command's fit alongside `serve`/
  `self-test`, audit documentation density, hardcoded pin tag drift
  risk. Each is a follow-up consideration rather than a blocking fix.
  Per `[[feedback-skip-accepted-audit-lanes]]`, the architect lane is
  ACCEPTed for this PR; the suggestions are recorded in the round-1
  artifact and can drive a follow-up PR after live evidence on
  M-series.

## Round 2 (lanes touched only)

Per `[[feedback-skip-accepted-audit-lanes]]`, only the code and
security lanes were re-fired (architect scope unchanged since R1).

Prompts:
- `specs/AUDIT_PERF_MLX_COMPILE_BF16_CODE_R2_PROMPT.md`
- `specs/AUDIT_PERF_MLX_COMPILE_BF16_SECURITY_R2_PROMPT.md`

Artifacts:
- `.omc/artifacts/ask/codex-perf-mlx-compile-bf16-code-lane-audit-round-2-…md`
- `.omc/artifacts/ask/codex-perf-mlx-compile-bf16-security-lane-audit-round-2-…md`

Result:

| Lane | Verdict |
|---|---|
| code | ACCEPT — CODE-1 (R1) resolved, no new findings |
| security | ACCEPT — SEC-2 (R1) resolved, no new findings |
| architect | (skipped — R1 ACCEPTed with LOW/NIT only) |

## Convergence (R2)

All three codex lanes at **0 CRITICAL / 0 HIGH / 0 MEDIUM** after round 2.
Per `[[feedback-build-audit-loop]]`, this cleared the bar to push the
branch and open PR #265.

## Round 3 — deep-pass audit (user-requested, post-PR)

Triggered after the user asked for a heavier-weight pass: "full
implementation 3-lane auditors + adversarial verification + product
critique." Each lane re-ran against the FULL implementation rather
than R2's narrowed delta-only scope.

### Lanes run (R3)

- **Codex CODE R3** — `specs/AUDIT_PERF_MLX_COMPILE_BF16_FULL_IMPL_PROMPT.md` with `LANE: CODE` suffix.
- **Codex SECURITY R3** — same prompt with `LANE: SECURITY` suffix.
- **Codex ARCHITECT R3** — same prompt with `LANE: ARCHITECT` suffix.
- **Claude adversarial verification** — `critic` subagent, structured attack lens.
- **Claude product critique** — `analyst` subagent, "should this exist in this shape" lens.

### R3 findings

| Lane | Critical | High | Medium | Low | Nit |
|---|---|---|---|---|---|
| codex code | 0 | 0 | 0 | 4 | 0 |
| codex security | 0 | 0 | **1** | 1 | 0 |
| codex architect | 0 | 0 | 0 | 5 | 0 |
| claude adversarial | 0 | 0 | **1** | 4 | 0 |
| claude product | n/a — RESHAPE / E2E_FIRST verdict (judgment, not severity) | | | | |

### MEDIUMs (both fixed inline before R4)

- **SEC-1 (codex security):** `MACPROVIDER_BF16_WEIGHTS=1` mutates
  loaded weights in-memory, but `currentModelHash` is derived from
  the on-disk safetensors manifest — so SPEC-015 receipts attest to
  the wrong dtype when the cast runs. Two providers reporting the
  same `model_hash` could be serving fp16 vs bf16-truncated weights;
  individual receipts still verify (output_hash binds delivered bytes)
  but the model-identity attestation contract weakens silently.
  **Fix:** plumbed `receiptsEnabled: Bool` into `ModelRuntime`'s
  primary `init` and through into `applyWeightCastIfEnabled(...)`.
  When receipts are on, the cast is refused even with the env flag
  set; a one-line stderr diagnostic surfaces the skip. `ServeCommand`
  passes `resolved.enableReceipts`; `DecodeBenchCommand` and
  `SelfTestCommand` use the default `false` so bench measurement is
  unaffected. The test/mock `init` defaults to `false` since no test
  exercises receipts state today.

- **ADV-1 (claude adversarial):** `CompiledDecodeStep` constructed
  with `enabled: true` against an empty cache would trace
  `MLX.compile()` with a zero-length state array; once prefill
  populates `[keys, values]`, the state-shape mismatch risks silent
  recompile or — worse — reuse of the traced graph that never
  threaded the cache (decode reads stale KV state, producing wrong
  tokens). The adversarial agent explicitly noted "not blocking
  this PR (no wire-in yet) — flag for the follow-up", but the fix
  is cheap. **Fix:** added a precondition in `CompiledDecodeStep.init`
  that asserts `cache.allSatisfy { !$0.innerState().isEmpty }` when
  enabled, and expanded the class docstring to spell out the
  "construct AFTER prefill" lifecycle requirement. Future wire-in
  PR will be a compile-time-visible programmer-error guard, not a
  runtime correctness gap.

### LOWs / NITs / product judgments (tracked, not fixed)

- Codex CODE/ARCHITECT/SECURITY LOWs are observability and ergonomics
  suggestions (e.g. record `kvBits`/`maxContext`/`maxBatch`/load-time
  in bench JSON, distinguish "cast did nothing" from "flag not picked
  up", convert deferred items to tracking issues, soften pin-tag
  drift risk). None block the PR.
- Claude adversarial ADV-2..5 are similar observability + future-
  proofing items.
- Claude product critique recommended RESHAPE (move CompiledDecode
  to draft follow-up PR, hide decode-bench from `--help`, consolidate
  audit-docs density, file deferred items as GitHub issues, run e2e
  before merge). These are PR-shape judgments rather than correctness
  findings; the user will decide which to act on as part of the
  merge-vs-e2e call.

## Round 4 — verification of R3 fixes (touched lanes only)

Per `[[feedback-skip-accepted-audit-lanes]]`, only codex CODE +
SECURITY were re-fired (architect scope unchanged; adversarial +
product not re-fired since their scopes either had non-blocking
findings already addressed or were judgment-tier rather than
severity-tier).

Prompts:
- `specs/AUDIT_PERF_MLX_COMPILE_BF16_R4_CODE_PROMPT.md`
- `specs/AUDIT_PERF_MLX_COMPILE_BF16_R4_SECURITY_PROMPT.md`

Result:

| Lane | Verdict |
|---|---|
| codex code R4 | ACCEPT — SEC-1 + ADV-1 fixes correct, no new findings |
| codex security R4 | ACCEPT — SEC-1 (R3) resolved, no new findings |

## Final convergence

All five audit sources at **0 CRITICAL / 0 HIGH / 0 MEDIUM** after R4.
Tests: 683 pass (unchanged count; the SEC-1 fix is wire-in only, no
new test required by spec — covered by the existing
`WeightCastTests.testEnvFlagAcceptsCommonTruthyForms` for the env
guard path and proven by codex re-audit for the receipts-skip path).

