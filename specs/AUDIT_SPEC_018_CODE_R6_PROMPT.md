# SPEC-018 v0.1.5 — CODE-lane round-6 audit (final lock confirmation)

You are the code lane returning for round 6. r5 verdict was FIX REQUIRED with 0C/0H/1M (§10c "v0.1.2-baseline parser" vs AC-23 "v0.1.3-baseline parser" drift). v0.1.5 absorbed that single MEDIUM.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.5 (commit `eb5bdde`)
- Round-5 code findings: `specs/SPEC-018-code-r5-audit.md`

## What changed in v0.1.5

§10c line 440 (was: "v0.1.2-baseline parser") → "v0.1.3-baseline parser (semver pinned in `tools/version-pins/openai-python-spec-018-v0_1_3-baseline.txt`)". Single normative edit + change-log addition. No other normative content changed.

## Round-6 scope

1. Verify §10c is now consistent with AC-23 on the baseline parser version.
2. Verify no NEW drift introduced by this surgical edit.
3. Sanity-grep for any remaining v0.1.2 normative reference (change-log mentions are OK; normative MUSTs / ACs / IMPL deltas are not).

That's it. Tight pass. Lock if clean.

## Output format

```
# SPEC-018 v0.1.5 — Code-lane round-6 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r5-absorption verification

## Findings (if any)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.
