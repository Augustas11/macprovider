# SPEC-018 v0.1.2 — ARCHITECT-lane round-3 audit (lock confirmation)

You are the **architect** lane of a round-3 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.2. This is a lock confirmation round.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round-2 architect findings: `specs/SPEC-018-architect-r2-audit.md`
- Round-2 absorbed: M-1, M-2, m-1 all marked absorbed in v0.1.2.

## Round-3 lane scope

1. **Verify r2 absorption.** For each r2 finding:
   - **M-1** (Qwen-row ambiguity): §3.1 now has ONE Qwen row "Qwen (2.5 / 3 / Coder variants)" with predicate `qwen2.5` OR `qwen3`. §3.6 mentions disjoint predicates. Is the ambiguity actually closed, or did the row collapse introduce a new boundary issue (e.g. Qwen2.5-Coder vs Qwen3 disambiguation at the body-grammar level)?
   - **M-2** (§2.3 SDK obligation): Verify §2.3 no longer contains "SDKs MUST." Reading the §2.3 bullet about JSON string arguments, is it now purely about provider-side validation with downstream guidance pointed at §1 + AC-20?
   - **m-1** (§7 informative voice): Verify §7 no longer uses RFC-2119 MUST.
2. **Find residuals + new issues.** v0.1.2 added new normative content: §10c forward-compatibility invariant, AC-23, the buyer-facing sentence in §10a #2, the Sec Q-1 fail-closed normative requirement, the §1 IMPL deltas enumeration. Apply the architect lens to that new content. Particular checks:
   - §10c invariant says "v0.2 and beyond MUST preserve v0.1.2 non-streaming response shape." Is this the right authority to declare it from, given v0.2 is a separate SPEC-018 vN that doesn't exist yet? Or should this live as a future-version pre-commitment that v0.2 has to assume?
   - §10a #2's normative "v0.2 MUST require unknown/unregistered model_hash to fail closed" is a SPEC-018 v0.1.2 statement constraining a future SPEC-018 v0.2. Is this normative scope coherent?
   - §3.1's "JSON body parsing tried first; on failure, falls back to Python-style" — does this disambiguation belong in the table cell, or in §3.3 body parsing? Cell-level prose might be hard to maintain.
3. **Coherence.** v0.1.2 is now ~428 lines. Read the SPEC top to bottom. Does it still read as a coherent normative contract?

## Output format

Brief — keep findings tight. Same format as r2.

```
# SPEC-018 v0.1.2 — Architect-lane round-3 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r2-absorption verification
[per r2 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
[…]

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

## Final prompt

# SPEC-018 v0.1.2 — ARCHITECT-lane round-3 audit (lock confirmation)

You are the **architect** lane of a round-3 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.2. This is a lock confirmation round.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.2 (commit `4cc4f9f`)
- Round-2 architect findings: `specs/SPEC-018-architect-r2-audit.md`
- Round-2 absorbed: M-1, M-2, m-1 all marked absorbed in v0.1.2.

## Round-3 lane scope

1. **Verify r2 absorption.** For each r2 finding:
   - **M-1** (Qwen-row ambiguity): §3.1 now has ONE Qwen row "Qwen (2.5 / 3 / Coder variants)" with predicate `qwen2.5` OR `qwen3`. §3.6 mentions disjoint predicates. Is the ambiguity actually closed, or did the row collapse introduce a new boundary issue (e.g. Qwen2.5-Coder vs Qwen3 disambiguation at the body-grammar level)?
   - **M-2** (§2.3 SDK obligation): Verify §2.3 no longer contains "SDKs MUST." Reading the §2.3 bullet about JSON string arguments, is it now purely about provider-side validation with downstream guidance pointed at §1 + AC-20?
   - **m-1** (§7 informative voice): Verify §7 no longer uses RFC-2119 MUST.
2. **Find residuals + new issues.** v0.1.2 added new normative content: §10c forward-compatibility invariant, AC-23, the buyer-facing sentence in §10a #2, the Sec Q-1 fail-closed normative requirement, the §1 IMPL deltas enumeration. Apply the architect lens to that new content. Particular checks:
   - §10c invariant says "v0.2 and beyond MUST preserve v0.1.2 non-streaming response shape." Is this the right authority to declare it from, given v0.2 is a separate SPEC-018 vN that doesn't exist yet? Or should this live as a future-version pre-commitment that v0.2 has to assume?
   - §10a #2's normative "v0.2 MUST require unknown/unregistered model_hash to fail closed" is a SPEC-018 v0.1.2 statement constraining a future SPEC-018 v0.2. Is this normative scope coherent?
   - §3.1's "JSON body parsing tried first; on failure, falls back to Python-style" — does this disambiguation belong in the table cell, or in §3.3 body parsing? Cell-level prose might be hard to maintain.
3. **Coherence.** v0.1.2 is now ~428 lines. Read the SPEC top to bottom. Does it still read as a coherent normative contract?

## Output format

Brief — keep findings tight. Same format as r2.

```
# SPEC-018 v0.1.2 — Architect-lane round-3 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r2-absorption verification
[per r2 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
[…]

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**.

## Raw output

```text
# SPEC-018 v0.1.2 — Architect-lane round-3 audit

## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 0  
MINOR: 1  
QUESTIONS: 0

## r2-absorption verification
- M-1: CONFIRMED. §3.1 has one Qwen row matching `qwen2.5` OR `qwen3`; Qwen2.5-Coder and Qwen3 variants select the same family. No new body-grammar boundary issue found.
- M-2: CONFIRMED. §2.3 no longer contains “SDKs MUST”; JSON string arguments are provider-side validation/canonicalization only, with downstream validation pointed to §1 + AC-20.
- m-1: CONFIRMED. §7 no longer imposes RFC-2119 requirements in SPEC-018’s voice; it refers normative timeout authority back to SPEC-002 / SPEC-006.

## Findings

### m-1 — Body parsing precedence belongs in §3.3, not only the table cell
- Where: `specs/SPEC-018-agentic-tool-calling.md:123-136`
- What: The Qwen row now closes the r2 ambiguity, but the JSON-first/Python-style-fallback rule lives primarily inside the §3.1 table cell. That is coherent today, but table-cell prose is a weaker maintenance surface than §3.3 for parser precedence.
- Recommended fix: Deferrable polish. Move the “try JSON first, then Python-style” rule into §3.3 and let the table reference it.

## Verdict
READY TO LOCK

