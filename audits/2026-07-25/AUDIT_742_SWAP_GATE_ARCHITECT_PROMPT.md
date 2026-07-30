# AUDIT — #742 swap paid hard-veto + remove 60s TTFT default — architect lane

You are the ARCHITECT audit lane reviewing the complete fix for GitHub issue
#742 as it will land (full diff vs the merge base).

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

Also read issue #742 and related issues #743/#744/#745 only for boundary
clarity — this PR must not implement those.

## Architectural constraints

1. Minimum change that stops the live incident (swapping model selected).
2. Do not enforce unmeasured catalog `bench_gate` thresholds.
3. Do not change SPEC-023 §4 scoring (that's #744).
4. Preserve donor mode as escape hatch when no non-swapping paid row exists.
5. Absolute TTFT ceiling selection is deferred to #744; this PR only removes
   the indefensible 60s default.

## Lane focus

- Is the paid vs donor boundary clean and future-compatible with #744/#745?
- Does treating `gateTTFTMS == 0` as "disabled" conflict with SPEC-013
  classic-autotune semantics in a way that must be called out?
- Any layering violation (scoring vs eligibility vs probe feasibility)?
- Spec amendment scope: is v0.7 the right size, or did we under/over-specify?
- Sequencing: does anything here bake in bad catalog measurements (#745)?

Report findings as a numbered list; each finding must state severity
(CRITICAL / HIGH / MEDIUM / LOW / INFO), file:line when possible, the defect,
and a concrete fix. End with exactly one summary line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
