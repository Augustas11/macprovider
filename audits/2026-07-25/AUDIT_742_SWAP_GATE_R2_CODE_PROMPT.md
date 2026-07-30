# AUDIT — #742 R2 re-audit after R1 fixes — code lane

You are the CODE audit lane re-reviewing the **complete** #742 fix after R1
remediation. Audit the full fix diff vs origin/main, not an incremental slice.

Repo root: current worktree on `fix/742-disqualify-swap`.

## Full-fix scope

```bash
git diff origin/main...HEAD -- \
  phase3-binary/Sources/macprovider-cli/AutotuneCommand.swift \
  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift \
  phase3-binary/Sources/macprovider-cli/Stage1Iterator.swift \
  phase3-binary/Sources/macprovider-cli/Stage2HillClimb.swift \
  phase3-binary/Tests/macprovider-cliTests/AutotuneCommandTests.swift \
  phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift \
  specs/SPEC-023-installer-autotune-recommend.md \
  specs/README.md
```

Also read `audits/2026-07-25/AUDIT_742_R1_TALLY.md` for R1 findings claimed fixed.

## Intended post-R1 behavior

1. Paid: `swap_detected` hard-blocks `recommended_model`; donor keeps swap advisory.
2. `--gate-ttft-ms` optional; explicit `0` disables; negatives rejected.
3. Classic Stage 1/2 omitted → 60_000 (SPEC-013); paid `--recommend` omitted → 0 (disabled). AC-3.
4. Catalog bench_gate TPS/TTFT still advisory. §4 scoring untouched.
5. SPEC-023 §8 donor no longer requires no-swap; AC-12/§5 warn on swap when no paid row.

## R1 residual risk to re-check

- Path-dependent gate resolution is actually used on both paths.
- Donor / paid boundary still clean.
- No silent 60s default on paid path.
- Spec internal consistency (§5, §8, AC-12, AC-22, changelog).

Report findings numbered with severity CRITICAL/HIGH/MEDIUM/LOW/INFO.
End with exactly:
`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`
PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
