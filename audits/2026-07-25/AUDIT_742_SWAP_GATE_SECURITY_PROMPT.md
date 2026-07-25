# AUDIT — #742 swap paid hard-veto + remove 60s TTFT default — security lane

You are the SECURITY audit lane reviewing the complete fix for GitHub issue
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

## Threat / abuse model for this change

- Money-path-adjacent: decides which model a provider serves and earns from.
- Locally measured swap must not be spoofable via catalog / remote feeds.
- Donor mode must not re-open a paid network path for a swapping row.
- Removing the 60s TTFT default must not create a path that silently prefers
  attacker-controlled remote catalog thresholds as hard gates.

## Lane focus

- Can a remote catalog or demand feed force a swapping model into paid serve?
- Does donor-mode commit still block network-connected paid registration for
  non-recommendable / swap-only rows (SPEC-023 AC-23)?
- Does disabling TTFT ceiling (flag omitted) create an availability or DoS
  vector against the installer/autotune path itself?
- Integrity of benchmark evidence identity (catalog SHA / hardware hash) still
  required before eligibility?

Report findings as a numbered list; each finding must state severity
(CRITICAL / HIGH / MEDIUM / LOW / INFO), file:line when possible, the defect,
and a concrete fix. End with exactly one summary line:

`VERDICT: PASS|FAIL — X CRITICAL / Y HIGH / Z MEDIUM / W LOW / V INFO`

PASS only if 0 CRITICAL, 0 HIGH, 0 MEDIUM.
