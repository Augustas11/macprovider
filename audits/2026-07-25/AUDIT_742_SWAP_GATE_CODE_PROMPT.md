# AUDIT — #742 swap paid hard-veto + remove 60s TTFT default — code lane

You are the CODE audit lane reviewing the complete fix for GitHub issue #742
as it will land (full diff vs the merge base, not an incremental slice).

Repo root: the current working directory (a macprovider worktree on branch
`fix/742-disqualify-swap`).

## Scope (full fix)

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

Also read issue #742 and SPEC-023 v0.7 change log + §5 + AC-12/AC-22.

## Intended behavior (do not expand)

1. `swap_detected == true` hard-blocks **paid** recommendation (`isEligible`).
2. Donor mode still admits swap (advisory) when other donor gates pass.
3. No default `gateTTFTMS = 60_000`; omitting `--gate-ttft-ms` disables the
   Stage 1/2 TTFT feasibility ceiling (`0` means disabled).
4. Do **not** hard-enforce catalog `bench_gate` TPS/TTFT — still advisory.
5. SPEC-023 §4 scoring is untouched; only §5 eligibility gains the swap gate.

## Acceptance criteria to verify

- AC-1: swapping candidate never becomes `recommended_model`
- AC-2/AC-5: 2026-07-23 M5/32GB fixture never yields `qwen3-coder-30b-a3b-instruct`
- AC-3: no 60s TTFT default reachable on paid path
- AC-4: all-swapping paid rows → donor with transcript/why naming swap

## Lane focus

- Correctness of eligibility / donor separation
- Warning attachment not reintroducing false positives for clean paid picks
- Stage1/Stage2 `gateTTFTMS == 0` skip path
- Test coverage adequacy and fixture fidelity
- Spec/code consistency for v0.7

Report findings as a numbered list; each finding must state severity
(CRITICAL / HIGH / MEDIUM / LOW / INFO), file:line when possible, the defect,
and a concrete fix. End with exactly one summary line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
