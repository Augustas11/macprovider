# SPEC-018 v0.1.1 — ARCHITECT-lane round-2 audit

You are the **architect** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 narrative: `specs/SPEC-018-r1-audit.md`
- Round-1 architect findings: `specs/SPEC-018-architect-r1-audit.md`
- Round-1 absorption record: every architect r1 finding (H-1, H-2, M-1, M-2, M-3, M-4, m-1, m-2, m-3, Q-1) was marked absorbed in the round narrative.

## Round-2 lane scope

Your job is two-fold:
1. **Verify r1 absorption.** For each round-1 architect finding listed in `specs/SPEC-018-architect-r1-audit.md`, confirm the v0.1.1 SPEC body actually closes it. Flag any finding the round narrative claimed absorbed where the SPEC body does not match the claim.
2. **Find residuals + new issues.** v0.1.1 added new normative content (§3.2 modelID-match-required, §3.6 mixed-sentinel rule + table-order priority, §3.7 SPEC-bump-required rule, §7 informative reframing, §8.4 commit-worthy validation, AC-15a/15b/16a/16b/19/20/21/22, §10a/§10b split, Q6 RESOLVED close, §12 expansion). Apply the architect lens to that new content: module boundaries, cross-SPEC consistency, scope-guard hygiene, future-version reservation discipline, anti-pattern entrenchment, and altitude.

## Architect-lane checks for v0.1.1 specifically

### ARCH-R2-1. r1-absorption fidelity
- **r1 H-1** (gateway timeout authority): §7 is now informative. Does the reframing actually defuse the cross-SPEC boundary violation, or does §7 still issue normative requirements that belong to SPEC-002 / SPEC-006? Read §7 + AC-15a + AC-15b carefully — any leftover MUST about gateway YAML in SPEC-018's voice is a residual.
- **r1 H-2** (X-MacProvider namespace): §10b says "no concrete header name is reserved in SPEC-018." Verify no concrete `X-MacProvider-*` header appears anywhere else in the SPEC body. Grep would catch literal matches.
- **r1 M-1** (table source-of-truth): §3 introduction now says "§3 is the normative source of truth." Does §3.7 ("Adding a new family") + §3 introduction close the "add detector outside table" loophole, or could a future PR still add a detector without violating the literal text?
- **r1 M-2** (priority rationale): §3.6 replaces "Llama before Qwen" with "deterministic precedence by table order." Does the table order in §3.1 match the as-built? (Code lane verifies; you flag if §3.1 ordering vs §3.6 rule creates new ambiguity.)
- **r1 M-3** (Ring-1 overclaim): §1 + §1.1 + AC-14 + §10a #1 + §12 collectively re-scope. Does the re-scope hold across every mention? Search the SPEC body for any residual "Ring-1 complete" or "drop-in compatibility" framing that contradicts the re-scope.
- **r1 M-4** (AC-17 SPEC-015 binding): AC-17 now scopes to "non-streaming receipt-bearing responses" and cites SPEC-015 v0.3 §5.1–§5.3. Verify SPEC-015 v0.3 is named in `**Depends on:**`.
- **r1 m-1** (SPEC-002 citation): §6 now cites SPEC-001:950-979 + SPEC-002:2280-2318. Verify both ranges are normatively correct (architect lane — line range verification belongs to code lane, but boundary "is this the right authority" check is yours).
- **r1 m-3** (SDK altitude): §10b says "SDK packaging lives in SPEC-006 / a dedicated SDK SPEC." Confirm no §1–§9 normative requirement names an SDK.
- **r1 Q-1** (security depends on architecture): Q6 marked RESOLVED. Verify the resolution coheres — §3.2 normative + §10a #2 model-hash binding + §10a #3 prompt-echo guard should be a complete story.

### ARCH-R2-2. New content lens
- §3.2 modelID-match-required is now normative. This is a SPEC-driven IMPL change (not pure ratification). Architect lens: is the SPEC explicit enough about the implementation delta from as-built? The change log mentions it; is §3.2 itself self-contained as a normative rule?
- §8.4 commit-worthy validation. Architect lens: is the validator's authority over coordinator commit-signal logic clear, or does it leak into territory SPEC-002 owns?
- §10a item #6 (multi-turn `tool_call_id` validation) and #7 (`function.arguments` size cap) are now §10a items rather than open questions. Are they v0.2-gating in the strong sense, or genuinely §10b enhancements that crept up?
- §10a #2 (model-hash → family registry) cites SPEC-008 Pillar A + SPEC-011 v0.5 as the infrastructure base. Verify those citations actually point at the right surface (file paths in coordinator/internal/pool/provider.go + coordinator/internal/buyer/server.go are mentioned).

### ARCH-R2-3. Coherence + voice
- v0.1.1 is now ~395 lines (vs v0.1 ~333). Does the SPEC still read as a single coherent contract, or has the round-1 absorption introduced redundancy / contradiction across §1, §1.1, §3.2, §6, §10a, §11 Q6 RESOLVED, §12?
- Specific voice check: does §1.1 "Known v0.1 limitations" duplicate content already in §4, §5, §6 + §10a in a way that creates drift risk if v0.2 updates only one place?

## Output format (same as round 1)

```
# SPEC-018 v0.1.1 — Architect-lane round-2 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- Where: file:line-range or §N
- What: 1-3 sentences
- Recommended fix: 1-3 sentences

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in architect lane.

## Final prompt

# SPEC-018 v0.1.1 — ARCHITECT-lane round-2 audit

You are the **architect** lane of a four-lane round-2 audit of `specs/SPEC-018-agentic-tool-calling.md` v0.1.1. Stay narrowly in your lane.

## Scope under audit
- Branch: `spec/018-agentic-tool-calling`
- Worktree: `/Users/augstar/macprovider-spec-018-tool-calling`
- File: `specs/SPEC-018-agentic-tool-calling.md` v0.1.1 (commit `14d0319`)
- Round-1 narrative: `specs/SPEC-018-r1-audit.md`
- Round-1 architect findings: `specs/SPEC-018-architect-r1-audit.md`
- Round-1 absorption record: every architect r1 finding (H-1, H-2, M-1, M-2, M-3, M-4, m-1, m-2, m-3, Q-1) was marked absorbed in the round narrative.

## Round-2 lane scope

Your job is two-fold:
1. **Verify r1 absorption.** For each round-1 architect finding listed in `specs/SPEC-018-architect-r1-audit.md`, confirm the v0.1.1 SPEC body actually closes it. Flag any finding the round narrative claimed absorbed where the SPEC body does not match the claim.
2. **Find residuals + new issues.** v0.1.1 added new normative content (§3.2 modelID-match-required, §3.6 mixed-sentinel rule + table-order priority, §3.7 SPEC-bump-required rule, §7 informative reframing, §8.4 commit-worthy validation, AC-15a/15b/16a/16b/19/20/21/22, §10a/§10b split, Q6 RESOLVED close, §12 expansion). Apply the architect lens to that new content: module boundaries, cross-SPEC consistency, scope-guard hygiene, future-version reservation discipline, anti-pattern entrenchment, and altitude.

## Architect-lane checks for v0.1.1 specifically

### ARCH-R2-1. r1-absorption fidelity
- **r1 H-1** (gateway timeout authority): §7 is now informative. Does the reframing actually defuse the cross-SPEC boundary violation, or does §7 still issue normative requirements that belong to SPEC-002 / SPEC-006? Read §7 + AC-15a + AC-15b carefully — any leftover MUST about gateway YAML in SPEC-018's voice is a residual.
- **r1 H-2** (X-MacProvider namespace): §10b says "no concrete header name is reserved in SPEC-018." Verify no concrete `X-MacProvider-*` header appears anywhere else in the SPEC body. Grep would catch literal matches.
- **r1 M-1** (table source-of-truth): §3 introduction now says "§3 is the normative source of truth." Does §3.7 ("Adding a new family") + §3 introduction close the "add detector outside table" loophole, or could a future PR still add a detector without violating the literal text?
- **r1 M-2** (priority rationale): §3.6 replaces "Llama before Qwen" with "deterministic precedence by table order." Does the table order in §3.1 match the as-built? (Code lane verifies; you flag if §3.1 ordering vs §3.6 rule creates new ambiguity.)
- **r1 M-3** (Ring-1 overclaim): §1 + §1.1 + AC-14 + §10a #1 + §12 collectively re-scope. Does the re-scope hold across every mention? Search the SPEC body for any residual "Ring-1 complete" or "drop-in compatibility" framing that contradicts the re-scope.
- **r1 M-4** (AC-17 SPEC-015 binding): AC-17 now scopes to "non-streaming receipt-bearing responses" and cites SPEC-015 v0.3 §5.1–§5.3. Verify SPEC-015 v0.3 is named in `**Depends on:**`.
- **r1 m-1** (SPEC-002 citation): §6 now cites SPEC-001:950-979 + SPEC-002:2280-2318. Verify both ranges are normatively correct (architect lane — line range verification belongs to code lane, but boundary "is this the right authority" check is yours).
- **r1 m-3** (SDK altitude): §10b says "SDK packaging lives in SPEC-006 / a dedicated SDK SPEC." Confirm no §1–§9 normative requirement names an SDK.
- **r1 Q-1** (security depends on architecture): Q6 marked RESOLVED. Verify the resolution coheres — §3.2 normative + §10a #2 model-hash binding + §10a #3 prompt-echo guard should be a complete story.

### ARCH-R2-2. New content lens
- §3.2 modelID-match-required is now normative. This is a SPEC-driven IMPL change (not pure ratification). Architect lens: is the SPEC explicit enough about the implementation delta from as-built? The change log mentions it; is §3.2 itself self-contained as a normative rule?
- §8.4 commit-worthy validation. Architect lens: is the validator's authority over coordinator commit-signal logic clear, or does it leak into territory SPEC-002 owns?
- §10a item #6 (multi-turn `tool_call_id` validation) and #7 (`function.arguments` size cap) are now §10a items rather than open questions. Are they v0.2-gating in the strong sense, or genuinely §10b enhancements that crept up?
- §10a #2 (model-hash → family registry) cites SPEC-008 Pillar A + SPEC-011 v0.5 as the infrastructure base. Verify those citations actually point at the right surface (file paths in coordinator/internal/pool/provider.go + coordinator/internal/buyer/server.go are mentioned).

### ARCH-R2-3. Coherence + voice
- v0.1.1 is now ~395 lines (vs v0.1 ~333). Does the SPEC still read as a single coherent contract, or has the round-1 absorption introduced redundancy / contradiction across §1, §1.1, §3.2, §6, §10a, §11 Q6 RESOLVED, §12?
- Specific voice check: does §1.1 "Known v0.1 limitations" duplicate content already in §4, §5, §6 + §10a in a way that creates drift risk if v0.2 updates only one place?

## Output format (same as round 1)

```
# SPEC-018 v0.1.1 — Architect-lane round-2 audit

## Counts
CRITICAL: <n>
HIGH: <n>
MEDIUM: <n>
MINOR: <n>
QUESTIONS: <n>

## r1-absorption verification
[per r1 finding: CONFIRMED | RESIDUAL | UNCHANGED | NEW-ISSUE]

## Findings
### C-1 / H-1 / M-1 / m-1 / Q-1 — Title
- Where: file:line-range or §N
- What: 1-3 sentences
- Recommended fix: 1-3 sentences

## Verdict
[READY TO LOCK | FIX REQUIRED]
```

Lock bar: **0 CRITICAL + 0 HIGH + 0 MEDIUM**. MINORs + QUESTIONS deferrable. Stay in architect lane.

## Raw output

```text
# SPEC-018 v0.1.1 — Architect-lane round-2 audit

## Counts
CRITICAL: 0  
HIGH: 0  
MEDIUM: 2  
MINOR: 1  
QUESTIONS: 0

## r1-absorption verification
- H-1: CONFIRMED. §7 is informative and AC-18 is parametric; no concrete gateway URL remains. Minor voice issue below.
- H-2: CONFIRMED. No concrete `X-MacProvider-*` header is reserved in SPEC-018; only the wildcard namespace appears in §10b.
- M-1: CONFIRMED. §3 introduction + §3.7 now make §3 the normative detector/table source of truth.
- M-2: RESIDUAL. Table-order priority is now declared, but §3.1 has two identical `qwen2.5` modelID predicates, creating a new ambiguity.
- M-3: CONFIRMED. No residual “Ring-1 complete” or “drop-in compatibility” framing found; first-turn scope is explicit.
- M-4: CONFIRMED. SPEC-015 v0.3 is named in `Depends on`, and AC-17 is scoped to non-streaming receipt-bearing responses.
- m-1: CONFIRMED. SPEC-001:950-979 and SPEC-002:2280-2318 are the right request-validation authority.
- m-2: CONFIRMED. §10a #4 adds a real token-incremental streaming release gate.
- m-3: RESIDUAL. SDK packaging is moved to §10b/§12, but §2.3 still has a normative SDK requirement.
- Q-1: CONFIRMED. §3.2 + §10a #2/#3 + AC-20 form a coherent v0.1/v0.2 security story.

## Findings

### M-1 — Table-order priority makes one Qwen row ambiguous or unreachable
- Where: `specs/SPEC-018-agentic-tool-calling.md:112-116`, `specs/SPEC-018-agentic-tool-calling.md:147-155`
- What: §3.6 says table order chooses the first matching family row and also claims no v0.1 `modelID` matches more than one row. But §3.1 has two rows whose required `modelID` predicate is `qwen2.5`; literal table-order selection makes the second Qwen coding-tuned row ambiguous or unreachable as a family row.
- Recommended fix: Either collapse the two Qwen rows into one `qwen2.5` family with JSON and Python-style body variants, or make the predicates disjoint and state the body-level disambiguation rule. Remove the false “no modelID matches more than one row” parenthetical.

### M-2 — Core §2 still imposes an SDK obligation
- Where: `specs/SPEC-018-agentic-tool-calling.md:85-94`, compare `specs/SPEC-018-agentic-tool-calling.md:363-366`, `specs/SPEC-018-agentic-tool-calling.md:389-395`
- What: §2.3 says “SDKs MUST JSON-parse and schema-validate before execution,” which is a normative client/SDK requirement inside the provider response-synthesis contract. That contradicts the §10b/§12 position that SDK packaging is downstream and buyer-side validation authority lives with the buyer framework.
- Recommended fix: Remove the SDK RFC-2119 wording from §2.3. Point to §1 / AC-20 instead, or reword as non-normative guidance for buyer-side frameworks.

### m-1 — Informative §7 still contains RFC-2119 voice
- Where: `specs/SPEC-018-agentic-tool-calling.md:235-243`
- What: §7 correctly returns gateway YAML authority to SPEC-006 and coordinator timeout authority to SPEC-002, but the informative section still says compliant deployments “MUST satisfy” SPEC-002 / SPEC-006 timeout invariants. This is not the original gateway-YAML boundary violation, but it weakens the informative/normative split.
- Recommended fix: Replace the RFC-2119 sentence with lower-case informative wording, or move the normative assertion entirely to the ACs / upstream SPECs.

## Verdict
FIX REQUIRED

