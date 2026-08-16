# SPEC-018 v0.1 — ARCHITECT-lane audit

You are the **architect** lane of a four-lane audit (architect / code / security / product-design) of `specs/SPEC-018-agentic-tool-calling.md` v0.1. Stay narrowly in your lane.

The architect lens cares about: module boundaries, single source of truth, abstraction altitude, cross-SPEC consistency, scope-guard hygiene, future-version reservation discipline, anti-pattern entrenchment.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1 (commit `77c0ec5`)
- This is a **post-hoc ratification SPEC** of cf2f135 + c823a96 + 7b8b1be. The architect lens does NOT design new behavior; it audits whether the SPEC ratifies the right boundary at the right altitude.

## House conventions to enforce
- Line 3 is the version of record (`grep -m1 '^\*\*Version' specs/SPEC-*.md`).
- Audit narrative does NOT live in the SPEC body (per [[feedback-spec-audit-file-convention]]). Audit findings go in `specs/SPEC-018-architect-rN-audit.md` per round; round narrative in `specs/SPEC-018-rN-audit.md`.
- Cross-spec references cite `specs/SPEC-NNN-name.md:line-range`.
- RFC 2119 keywords (MUST/SHOULD/MAY) used consistently.

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Scope-guard hygiene — Ring 1 vs Ring 2/3
- §1 names Ring 2 (provider-side agent execution → SPEC-019) and Ring 3 (provider-hosted MCP → SPEC-020) as out of SPEC-018 entirely.
- §12 restates this. §10 (Reserved for v0.2+) lists structured output, streaming-incremental, prefix-cache, SDKs, max_tool_calls.
- Is the boundary between "v0.2+ within SPEC-018" and "out to SPEC-019/020 entirely" stable? Could a reasonable PR author misread §10 and creep Ring-2 features into v0.2?
- Is the "MUST NOT execute tools on behalf of the buyer" rule in §1 strong enough to block a future "but we just sandbox it" PR? Or does it need an explicit §non-goal item naming sandbox/fs/shell?

### ARCH-2. Cross-SPEC consistency
- §6 cites SPEC-001 + SPEC-002 for the request half (lines `2280-2318`, `1079-1085`). Verify those line references against the locked versions named in line 3 (SPEC-001 v1.6, SPEC-002 v1.4.1). Do the cited line ranges actually contain the referenced content at those versions?
- AC-17 asserts: *"Receipt canonicalization includes canonicalized `tool_calls[]` in the output object when tool calls are emitted."* This is a SPEC-015 binding claim. SPEC-015 v0.3 is the current locked version. Does SPEC-015 v0.3 actually pin this behavior, or is AC-17 inventing a cross-SPEC binding that doesn't exist? If invention, this is a **CRITICAL** finding: SPEC-018 cannot ratify behavior in SPEC-015's domain.
- §7 ties to c823a96. Does the gateway timeout policy belong in SPEC-018, in SPEC-006 (buyer API gateway), or in SPEC-002 (coordinator)? Is SPEC-018 the right authority for an operator config requirement, or is it leaking concern across SPEC boundaries?

### ARCH-3. Model-family registry as normative authority
- §3 establishes a 3-row family table (Qwen native / Qwen coding-tuned / Llama 3.3 MLX) and the rule "A new model family's tool-call grammar MUST land via a SPEC-018 version bump."
- This is the load-bearing closure of the 7b8b1be precedent ([[audit-cycles-are-design-discovery]]). Is the rule normatively strong enough? Could a parser PR add a 4th family detector without violating the rule literally? (E.g. "we did not mutate the table, we added a new detection path that the table doesn't mention.")
- Is the table itself the authority, or is the source file? If the source file gains a 4th family before SPEC-018 v0.2, who wins? State whether the SPEC needs an explicit "the table is the source of truth; source file is the implementation of the table" invariant.

### ARCH-4. Detection-priority pin
- §3 last paragraph: "If multiple family detectors could match the same output, the v0.1 detector checks Llama 3.3 before Qwen. Implementations MUST preserve this priority unless a later SPEC-018 version changes it."
- Is encoding the as-built ordering as normative correct, or premature? An audit-lane SHOULD ask: does the priority order have a security/correctness rationale, or is it accidental?
- Could a future family detector reasonably need a different priority? Should §3 instead pin "deterministic, table-order" rather than the specific order?

### ARCH-5. Streaming v0.1 baseline — buffered-to-end ratification
- §4 ratifies buffered-to-end as the v0.1 baseline (because that's what the as-built does) and Q1 reserves token-incremental for v0.2.
- This is honest, but it bakes a probably-suboptimal behavior into normative status. Architect concern: is "v0.2 will fix it" a strong enough commitment, or does §10 need a numbered roadmap entry tying token-incremental to a specific release gate?
- §4 last line says streaming-failed-parse uses non-tool finish reason (`stop` or `length`). Is the transition from "streamed tool_calls intent" to "fell back to content" buyer-observable mid-stream? If so, is this a wire-protocol leak that v0.2 needs to fix?

### ARCH-6. Acceptance criteria altitude
- AC-1 through AC-18: are these at the right altitude for an architect to verify? Are any too low-level (implementation detail that should be in a test, not a SPEC AC)? Are any too high-level (mechanically un-verifiable)?
- AC-16 includes a footnote: "SPEC-018 v0.1 does not certify the second provider turn after tool execution because AC-14 ratifies the current provider limitation." Is this a real limitation that breaks the Ring-1 product story? If a Cline user cannot complete a multi-turn tool loop, does §1's product framing overclaim?
- AC-18 names `https://api.malibu.tech/v1` directly. Is hard-coding a deployment URL into a normative AC appropriate, or should it be parametric ("any production gateway deployment")?

### ARCH-7. §10 reservation overlap
- "Token-incremental streaming verification and promotion" (§10 item 2) — does this overlap with any SPEC-001 or SPEC-002 streaming concern?
- "X-MacProvider-Context-Cache prefix-cache reuse header" (§10 item 3) — header-name allocation: does SPEC-006 (buyer API gateway) own the `X-MacProvider-*` namespace? Cross-check `grep "X-MacProvider" specs/SPEC-006-buyer-api.md`. If SPEC-006 owns it, SPEC-018 reserving it is a boundary violation.
- Python and TypeScript SDK surfaces — does any other SPEC reserve SDK territory? Should SDK live in a dedicated SPEC family (SPEC-021+) rather than as a v0.2+ slice of SPEC-018?

### ARCH-8. Open Questions hygiene
- 9 open questions (Q1-Q9). Are any of them actually load-bearing for v0.1 (i.e., not knowing the answer makes v0.1 unimplementable)?
- Q5 (warm-swap mid-tool-call interaction with SPEC-011) — is this a real risk that should block v0.1, or genuinely deferrable?
- Q6 (content-sentinel detection as fingerprinting/injection surface) — architect-lane lens: is this a SECURITY question that lives in the security lane, or a cross-cutting concern that v0.1 must resolve?

## Output format

Return a single audit report:

```
# SPEC-018 v0.1 — Architect-lane round-1 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- Where: file:line-range or §N
- What: 1-3 sentences
- Why architect-lane: 1 sentence on lens fit
- Recommended fix: 1-3 sentences (specific edit to the SPEC body)

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS are deferrable.

Stay in architect lane. Do not produce code-citation or security findings — those have their own lanes. If you notice a code-lane or security-lane issue, note it as a Q (question for the other lane) but do not score it.
