# SPEC-018 v0.1.3 — Code-lane round-4 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## v0.1.3-delta verification
[per delta listed above: CONFIRMED | RESIDUAL | NEW-ISSUE]

## Findings (if any)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. Tight findings only.

## Final prompt

# SPEC-018 v0.1.3 — CODE-lane round-4 audit (lock confirmation after Claude blind-spot absorption)

You are the **code** lane of a round-4 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.3. This is a lock confirmation round after Claude critic blind-spot absorption.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.3 (commit `db6bd19`)
- Round-3 returned READY TO LOCK; v0.1.3 absorbed Claude critic blind-spot findings.
- Critic findings: `specs/SPEC-018-critic-blindspot-audit.md`

## What changed in v0.1.3 (code lane lens)

1. **AC-23 reworked** — replaces tautology with new-emission-vs-old-parser regression. Verify the new wording is mechanically expressible.
2. **AC-24 added** — coordinator request-side pass-through WS-frame byte-equivalence test. Verify the test is implementable against `phase4-coordinator/internal/ws/` outbound `InferenceRequest` frame code paths.
3. **§3.4 + §8.4 + AC-21 depth/byte caps** (32 / 256 KiB). Verify:
   - Are these limits implementable against the current parser code (`ToolCallParser.swift:266-448`)?
   - Are they implementable against the coordinator commit-signal code path (`phase4-coordinator/internal/buyer/server.go:2482-2605`)?
   - Does Go's `encoding/json` provide depth introspection, or does the IMPL need a custom decoder?
4. **AC-7 reworded** — "at framing positions" qualifier. Mechanically expressible against current streaming tests?
5. **AC-16b "passes" verb pin** — "SDK return-handling completes, reaches execute-decision boundary." Verify this is testable.
6. **§3.6 mixed-sentinel rule dropped** — AC-22 marked reserved-as-deprecated. Verify nothing in §1.2 IMPL deltas, §3, §5, §8, §9 still references mixed-sentinel detection.
7. **§1.1 + §3.2 "modelID is self-declared; model_hash is verified" sentence** — no code impact, but verify it doesn't introduce conflicting normative claims.

## Round-4 lane scope

1. Verify each v0.1.3 delta is internally consistent (no stale references to AC-22, §3.6 mixed-sentinel, the old AC-23 wording, the old §10a #2 operator-override clause, or any "three IMPL deltas" left over from v0.1.2).
2. Verify all citations in v0.1.3-changed sections still anchor correct code locations (especially the new depth/byte cap mentions of `ToolCallParser.swift:266-448`, `phase4-coordinator/internal/buyer/server.go:2482-2605`, and §1.2's enumeration).
3. Find any new mechanical-verifiability gaps introduced by v0.1.3's edits.

## Output format

```
# SPEC-018 v0.1.3 — Code-lane round-4 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## v0.1.3-delta verification
[per delta listed above: CONFIRMED | RESIDUAL | NEW-ISSUE]

## Findings (if any)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. Tight findings only.

## Raw output

```text
# SPEC-018 v0.1.3 — Code-lane round-4 audit

## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 2  
MINOR: 2  
QUESTIONS: 0

## v0.1.3-delta verification
1. AC-23 reworked: RESIDUAL — direction is fixed, but the referenced baseline pin file is absent.
2. AC-24 added: CONFIRMED — implementable at WS `InferenceRequest.Body` frame layer.
3. §3.4 + §8.4 + AC-21 depth/byte caps: CONFIRMED — implementable; Go `encoding/json` v1 has no public 32-depth introspection/config, so IMPL needs a custom token scanner/decoder or equivalent pre-parse guard.
4. AC-7 reworded: CONFIRMED — mechanically testable by parsing SSE JSON and allowing delimiter substrings only inside escaped `function.arguments`.
5. AC-16b verb pin: CONFIRMED — testable as “SDK return-handling completes and framework reaches execute-decision boundary.”
6. §3.6 mixed-sentinel rule dropped: RESIDUAL — one stale future-target reference remains.
7. §1.1 + §3.2 modelID/model_hash sentence: NEW-ISSUE — §1.1 overclaims the v0.1 protection.

## Findings

MEDIUM: AC-23 references a missing baseline pin artifact.  
`specs/SPEC-018-agentic-tool-calling.md:392` says `tools/version-pins/openai-python-spec-018-v0_1_2-baseline.txt` records the exact OpenAI Python SDK semver, but no `tools/` or version-pin file exists in the worktree. The regression direction is correct, but the old-parser baseline is not mechanically reproducible from the repo.

MEDIUM: §1.1 overclaims model_hash protection in v0.1.  
`specs/SPEC-018-agentic-tool-calling.md:49` says verified `model_hash` means a malicious provider cannot advertise a tool-capable family while serving different weights. That conflicts with §3.2 / §10a / §10c, which correctly say modelID is still self-declared in v0.1 and model_hash→family binding is a v0.2 deliverable. Reword §1.1 to say `model_hash` verifies loaded weights, but v0.1 does not bind those weights to parser family.

MINOR: Stale mixed-sentinel reference remains in §10a.  
`specs/SPEC-018-agentic-tool-calling.md:406` lists “mixed sentinels” as a future structured `malformed_tool_call` parse-failure category. Since v0.1.3 deliberately drops mixed-sentinel detection, this should be removed or rewritten.

MINOR: §8.4 stale version wording.  
`specs/SPEC-018-agentic-tool-calling.md:332` still says “v0.1.2 IMPL prompt” while describing the current commit-signal patch surface. This should say v0.1.3 and include the depth/byte rejection fixture.

## Verdict
FIX REQUIRED

