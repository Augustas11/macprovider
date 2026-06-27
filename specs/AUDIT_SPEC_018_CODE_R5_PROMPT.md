# SPEC-018 v0.1.4 — CODE-lane round-5 audit (lock confirmation)

You are the code lane returning for round 5. r4 verdict was FIX REQUIRED with 0C/0H/2M/2m. v0.1.4 absorbed all 4. Verify and lock-confirm.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.4 (commit `e74aca0`)
- Round-4 code findings: `specs/SPEC-018-code-r4-audit.md`

## What changed in v0.1.4 (code lane lens)

1. **Code r4 M-1 — AC-23 baseline pin file:** v0.1.4 §1.2 now contains an "AC-23 baseline-pin file obligation" subsection requiring the v0.1.4 IMPL prompt to commit `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt` to the repo root. AC-23 itself was updated to point at `openai-python-spec-018-v0_1_3-baseline.txt`. Verify:
   - Is the IMPL-prompt obligation phrased clearly enough that an executor can implement it?
   - Does AC-23 now have a mechanically reproducible baseline?
2. **Code r4 M-2 — §1.1 #4 model_hash overclaim:** §1.1 #4 reworded to clarify SPEC-008 verifies loaded weights but does NOT yet gate parser family in v0.1; v0.2 §10a #2 closes the malicious-provider case. §3.2 rationale reworded symmetrically. Verify both rewordings are consistent with §10a #2 and §10c.
3. **Code r4 m-1 — §10a #5 stale "mixed sentinels":** dropped from the parse-failure list, replaced with "depth/byte-cap exceeded." Verify no other stale mixed-sentinel reference remains.
4. **Code r4 m-2 — §8.4 stale "v0.1.2":** changed to "v0.1.3 IMPL prompt" and expanded rejection-fixture enumeration. Verify consistency with §1.2 IMPL deltas.
5. **Critic r2 m-1 — AC-23 baseline-version drift:** v0.1.4 aligns AC-23 to v0.1.3 baseline (not v0.1.2). Verify §10c and AC-23 now both reference v0.1.3 consistently.

## Round-5 scope

1. **Verify each v0.1.4 delta is internally consistent.** Specifically grep for any remaining "v0.1.2" or "v0.1.2 IMPL prompt" reference that should have been updated. Grep for "mixed sentinels" or "mixed-sentinel" outside of historical/change-log context.
2. **Run a fresh code-lane pass on the v0.1.4-changed sections** (§1.1 #4, §3.2 rationale, §8.4 source, AC-23, §10a #5, §1.2). Find any new mechanical-verifiability or citation-drift gap introduced by v0.1.4.

## Output format

```
# SPEC-018 v0.1.4 — Code-lane round-5 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r4-absorption verification
[per r4 finding: CONFIRMED | RESIDUAL | NEW-ISSUE]

## Findings (if any)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. Tight. Be honest — if v0.1.4 cleanly absorbed, say so.
