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

## Final prompt

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

## Raw output

```text
# SPEC-018 v0.1 — Architect-lane round-1 audit

## Counts
CRITICAL: 0  
HIGH: 2  
MEDIUM: 4  
MINOR: 3  
QUESTIONS: 1

## Findings

### H-1 — Gateway timeout policy is asserted from the wrong SPEC authority
- Where: `specs/SPEC-018-agentic-tool-calling.md:200-215`, `specs/SPEC-018-agentic-tool-calling.md:287-293`; compare `specs/SPEC-002-coordinator.md:1079-1097`, `specs/SPEC-006-buyer-api.md:2327-2402`
- What: §7 creates a standalone operator config MUST for gateway YAML, and AC-18 hard-codes `https://api.malibu.tech/v1`. Timeout ordering already lives in SPEC-002, while gateway config and public deployment contracts live in SPEC-006.
- Why architect-lane: This is module-boundary and single-source-of-truth drift across coordinator, gateway, and response-synthesis specs.
- Recommended fix: Make §7 informative in SPEC-018: tool-call buffering creates first-header latency, so compliant deployments must satisfy the SPEC-002/SPEC-006 gateway timeout invariants. Move normative gateway YAML requirements to SPEC-006 or cite an existing SPEC-006 amendment. Rewrite AC-15/AC-18 parametrically as “any production gateway deployment satisfying SPEC-002/SPEC-006 timeout invariants,” with no live URL.

### H-2 — SPEC-018 reserves an `X-MacProvider-*` header that SPEC-006 owns
- Where: `specs/SPEC-018-agentic-tool-calling.md:301`; compare `specs/SPEC-006-buyer-api.md:1065-1095`
- What: §10 reserves `X-MacProvider-Context-Cache`, but SPEC-006 strips every unallowlisted inbound and outbound `X-MacProvider-*` header and owns the documented allowlists. A future SPEC-018 v0.2 header would be non-compliant or silently stripped unless SPEC-006 changes first.
- Why architect-lane: Header namespace allocation is a cross-module API boundary, not response-synthesis internals.
- Recommended fix: Replace the header-name reservation with a neutral future item: “prefix-cache request/response signaling, requiring SPEC-006 header-allowlist allocation.” Do not name a concrete `X-MacProvider-*` header in SPEC-018 unless the same version also depends on a SPEC-006 bump.

### M-1 — The model-family table is not explicitly the normative source of truth
- Where: `specs/SPEC-018-agentic-tool-calling.md:95-122`
- What: The rule says new family grammars need a SPEC-018 version bump and parser PRs must not mutate the table silently, but it does not explicitly ban adding a new detector path outside the table. A source change could add a fourth family detector while claiming the table was not mutated.
- Why architect-lane: This is the load-bearing registry boundary for parser extensibility.
- Recommended fix: Add an invariant after the table: “This table is the normative source of truth for v0.1 model-family tool-call grammars; implementation source is only an implementation of this table. Any detector, sentinel, model-id match, or grammar path not represented here is non-compliant until a SPEC-018 version bump.”

### M-2 — Detection priority pins as-built order without rationale
- Where: `specs/SPEC-018-agentic-tool-calling.md:95-101`, `specs/SPEC-018-agentic-tool-calling.md:120`
- What: §3 pins Llama-before-Qwen priority even though the table lists Qwen first and gives no correctness/security rationale for that overlap rule. This risks entrenching accidental implementation order as architecture.
- Why architect-lane: Priority rules are abstraction-altitude decisions that affect future detector additions.
- Recommended fix: Either reorder the table to match the as-built priority and state the overlap rationale, or replace the specific priority with “deterministic precedence is declared by the grammar table order,” requiring future SPEC-018 versions to add explicit overlap tests when adding a family.

### M-3 — Product framing overclaims the v0.1 Ring-1 loop
- Where: `specs/SPEC-018-agentic-tool-calling.md:15-21`, `specs/SPEC-018-agentic-tool-calling.md:186-198`, `specs/SPEC-018-agentic-tool-calling.md:283-289`
- What: §1 frames Ring 1 as client-side agent framework compatibility, but §6/AC-14/AC-16 admit the current provider rejects `role:"tool"` and assistant-history `tool_calls[]`. That means v0.1 certifies first assistant tool-call response synthesis, not a complete OpenAI-style multi-turn tool loop.
- Why architect-lane: This is scope-guard hygiene between response shape, transport pass-through, and full product semantics.
- Recommended fix: Narrow §1 to “first assistant tool-call response wire compatibility and transport preservation.” Add an explicit sentence that v0.1 does not certify completing the post-tool second provider turn, and point to §10’s future second-turn acceptance item.

### M-4 — AC-17 is real in SPEC-015, but overbroad and under-cited
- Where: `specs/SPEC-018-agentic-tool-calling.md:291`; compare `specs/SPEC-015-receipts.md:1322-1374`, `specs/SPEC-015-receipts.md:1407-1416`, `specs/SPEC-015-receipts.md:3785-3791`
- What: SPEC-015 does pin canonicalized `tool_calls[]` in the non-streaming canonical output object, so AC-17 is not invented. But AC-17 lacks a SPEC-015 dependency/citation and can be read to include streaming tool calls, while SPEC-015 says v0.1.x streaming requests carry no receipt.
- Why architect-lane: SPEC-018 must not silently expand SPEC-015’s receipt domain.
- Recommended fix: Add SPEC-015 v0.3 to `Depends on`. Rewrite AC-17 as: “For non-streaming receipt-bearing responses, SPEC-015 v0.3 §5.1-§5.3 canonical output includes canonicalized `tool_calls[]` when tool calls are emitted.”

### m-1 — §6 cites one SPEC-002 range for the wrong claim
- Where: `specs/SPEC-018-agentic-tool-calling.md:188-194`; compare `specs/SPEC-001-phase3-binary.md:950-979`, `specs/SPEC-002-coordinator.md:1079-1085`, `specs/SPEC-002-coordinator.md:2280-2318`
- What: `SPEC-002:2280-2318` contains the request-side `tools`, assistant `tool_calls`, and `role:"tool"` validation content. `SPEC-002:1079-1085` is a streaming commit-worthy-event predicate, not the request-half pass-through rule.
- Why architect-lane: Cross-SPEC references must point to the authority they claim.
- Recommended fix: Cite SPEC-001 `950-979` and SPEC-002 `2280-2318` for request validation. If SPEC-018 wants an opaque ID pass-through invariant, state it as SPEC-018’s response-side transport invariant instead of calling `1079-1085` a request pass-through rule.

### m-2 — Buffered-to-end streaming is honest, but the v0.2 roadmap is weak
- Where: `specs/SPEC-018-agentic-tool-calling.md:128-157`, `specs/SPEC-018-agentic-tool-calling.md:295-300`, `specs/SPEC-018-agentic-tool-calling.md:309`
- What: v0.1 correctly ratifies buffered-to-end behavior, and parse-failure fallback is not buyer-observable mid-stream because tool deltas are emitted only after generation and parse success. The future token-incremental item is only a loose reservation.
- Why architect-lane: This is future-version reservation discipline.
- Recommended fix: Either leave §10 explicitly non-committal, or add a release gate: token-incremental streaming may promote only after SDK compatibility, byte-equivalence, and parse-failure fallback tests pass.

### m-3 — SDK wrapper reservation is outside SPEC-018’s natural altitude
- Where: `specs/SPEC-018-agentic-tool-calling.md:302`, `specs/SPEC-018-agentic-tool-calling.md:333`; compare `specs/SPEC-006-buyer-api.md:245-247`, `specs/SPEC-006-buyer-api.md:811-819`, `specs/SPEC-006-buyer-api.md:2695-2706`
- What: Python/TypeScript SDK wrappers are product/distribution surfaces, while SPEC-018 is response synthesis. SPEC-006 already owns public gateway SDK compatibility and docs expectations.
- Why architect-lane: This avoids expanding a wire-shape spec into client library ownership.
- Recommended fix: Reword §10 to “SDK examples or helper libraries require SPEC-006/docs alignment or a dedicated SDK SPEC,” rather than reserving SDK wrappers inside SPEC-018.

### Q-1 — Content-sentinel detection should be resolved by security, with architecture depending on the result
- Where: `specs/SPEC-018-agentic-tool-calling.md:99-101`, `specs/SPEC-018-agentic-tool-calling.md:319`
- What: Q6 is primarily a security-lane question because content-sentinel detection may create fingerprinting or prompt-injection surfaces. Architecturally, the answer affects whether content sentinels remain first-class detector keys in the normative grammar table.
- Why architect-lane: The architecture needs the security decision to keep the detector registry stable.
- Recommended fix: If security accepts content sentinels, keep them in §3 with explicit table-source-of-truth language. If security rejects them, remove raw-output sentinel detection from the v0.1 normative grammar table and make model-family detection model-id based only.

## Verdict
FIX REQUIRED

