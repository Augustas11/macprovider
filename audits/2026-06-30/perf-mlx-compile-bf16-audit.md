# perf/mlx-compile-bf16 — audit round narrative

**Date:** 2026-06-30
**Branch:** `perf/mlx-compile-bf16`
**Spec:** `specs/perf-mlx-compile-bf16-upgrade.md`
**Discipline:** three-lane codex (code / security / architect),
narrow-scope IMPL audit per
`[[feedback-three-lane-codex-audits]]` / `[[feedback-build-audit-loop]]`.

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

## Convergence

All three lanes at **0 CRITICAL / 0 HIGH / 0 MEDIUM** after round 2.
Per `[[feedback-build-audit-loop]]`, this clears the bar to push the
branch and open the PR.
