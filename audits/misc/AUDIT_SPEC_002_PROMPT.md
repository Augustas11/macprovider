# Audit prompt — SPEC-002 second-opinion review

Operator-paste prompt to audit `specs/SPEC-002-coordinator.md` after it's
been written by Claude. Run with **Codex CLI** for cross-model independence.

The auditor's job: find problems. Be skeptical. Expected duration: ~45min.

Paste everything between the markers into a fresh Codex CLI session rooted
at `/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-002 (Phase 4 coordinator spec) for a project where
you previously audited SPEC-001 (Phase 3 binary spec). Your prior audit
output lives at specs/SPEC-001-audit.md.

Your job: read SPEC-002 and its source materials, then produce a structured
audit report. Find what's wrong, ambiguous, missing, over-specified, or
inconsistent with SPEC-001's protocol contract. You are NOT here to
validate or rewrite SPEC-002. Find problems, report them, let the
operator decide fixes.

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   — the spec under audit.

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.1.1 — the binary spec. § 6.5 (coordinator WebSocket protocol) is
   the most important section to remember. Every protocol decision in
   § 6.5 must be respected by SPEC-002.

3. /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-001-v1-1-audit.md
   — your prior audits, for tone/format continuity.

4. /Users/augstar/macprovider-poc/specs/BUILD_SPEC_002_PROMPT.md
   — what the spec writer was instructed to produce. Check whether
   SPEC-002 actually delivers it.

5. /Users/augstar/macprovider-poc/HANDOFF.md
   — project context, especially the "Coordinator on VPS" section.

6. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — decision log; especially D1 (502/530) and D4 (capacity routing)
   which SPEC-001 deferred to SPEC-002.

7. /Users/augstar/macprovider-poc/beta/harness.py
   — the first buyer that will hit the coordinator. Spot-check that
   SPEC-002 § 7.2 buyer API accepts what the harness sends.

## Audit categories — work through each

### Category A: SPEC-001 protocol compatibility

This is the highest-value check. SPEC-001 § 6.5 defines the wire protocol.
Every message there must have coordinator-side handling in SPEC-002.

A.1  Walk through SPEC-002's § 9 (SPEC-001 protocol compatibility matrix).
     Does every SPEC-001 § 6.5 message have at least one SPEC-002 FR
     covering it? Missing entries are CRITICAL findings.

A.2  For each provider→coordinator message (hello, heartbeat,
     state_update, drain_status, preflight_response, nak), verify
     SPEC-002 specifies what the coordinator DOES with it (not just
     that it accepts it).

A.3  For each coordinator→provider message (hello_ack, preflight, drain,
     warm_up), verify SPEC-002 specifies the TRIGGER condition for
     sending it.

A.4  Are there any places where SPEC-002 silently changes a field name,
     enum value, or message shape from SPEC-001 § 6.5? Any difference =
     CRITICAL finding (would break wire compat with the binary).

A.5  Does SPEC-002 handle SPEC-001's coordinator-deferred items per the
     decision log:
     - D1 (502 vs 530 routing distinction) — is FR-P11 (or equivalent)
       present and complete?
     - D4 (capacity-vs-quality routing) — is FR-R2 (or equivalent)
       present?
     - Post-wake warm-up dispatch — does the coordinator know WHEN to
       send warm_up, not just that it can?

### Category B: Internal consistency

B.1  Do FRs contradict each other?
B.2  In-scope (§ 2) matches what FRs (§ 4) cover?
B.3  Acceptance criteria (§ 11) test the FRs?
B.4  Interface contracts (§ 7) consistent with FRs referencing them?

### Category C: Tier 1 / Tier 2 architecture

C.1  Tier 2 hook points named (not just gestured at)?
C.2  Anything Tier 2-territory snuck into Tier 1 scope?
C.3  Anything required for Tier 2 readiness missing?
C.4  Does SPEC-002 speculate about Tier 2 implementation beyond hooks?

### Category D: Reference hygiene

D.1  Section 8.2 should be VERBATIM from SPEC-001 § 7.2 (strict clean-
     room). Is it?
D.2  Any d-inference URLs or references outside the hygiene policy block?
D.3  Code snippets in the spec? (Only JSON, pseudocode for routing
     algorithm, and ASCII diagrams allowed.)

### Category E: Interface contracts

E.1  Buyer HTTP API in § 7.2 — is the request schema complete enough to
     build a real OpenAI-compatible buyer against? Cross-reference
     SPEC-001 § 6.2 — should be the same shape.
E.2  Provider WebSocket in § 7.1 — does it cover every SPEC-001 § 6.5
     message + the connection lifecycle (open → hello → heartbeats →
     drain → close)?
E.3  Auth flow in § 7.3 — token issuance, validation, rotation,
     revocation all specified? Storage shape defined?
E.4  Error responses for both buyer HTTP and provider WebSocket
     (nak shape, HTTP 503 body, etc.)?

### Category F: Acceptance criteria

F.1  Are the ACs measurable, with concrete commands or script names?
F.2  Does AC-2 (harness against pool of 2 mock providers) reference an
     existing harness config file path that will exist at v1.0 commit
     time? Or is it a path that the build session must create?
F.3  Pass rule stated? (All ACs must pass, no partials.)

### Category G: Open questions

G.1  Count: target 4-6. <3 = lazy; >8 = vague.
G.2  Are they actually blocking, or defaults dressed as questions?
G.3  Auditor's own answers from source materials?

### Category H: Implementability

H.1  Could a competent Go developer (or fresh Claude/Codex session)
     start coding with ≤3 clarifications? List them if more.
H.2  Are Go dependencies pinned to specific versions/tags?
H.3  Is the routing algorithm (§ 5) detailed enough for the build
     session to implement without operator guidance?

### Category I: Scope discipline

I.1  Anything that belongs in SPEC-003 (Antseed integration), SPEC-004
     (smart router), SPEC-005 (rewards), SPEC-006 (public API) sneak in?
I.2  Does SPEC-002 over-constrain SPEC-003's eventual Antseed integration?
I.3  Does SPEC-002 accidentally redesign anything from SPEC-001 v1.1.1?

## Severity rubric

  CRITICAL — protocol mismatch with SPEC-001 (would break wire compat),
             missing core capability that prevents build start, internally
             contradictory FRs at the level of "X must Y" / "X must not Y."

  MAJOR    — ambiguous requirement with multiple valid interpretations,
             missing acceptance for a stated capability, Tier 2 hook
             missing that would force re-architecture, dependency not
             pinned where pinning matters.

  MINOR    — formatting, wording, or default choices that cause friction
             but not failure.

  QUESTION — auditor cannot determine from source materials.

## Output format

Write to:
  /Users/augstar/macprovider-poc/specs/SPEC-002-audit.md

Structure:

  # SPEC-002 Audit Report
  Auditor: <model name + version>
  Spec audited: SPEC-002 v<x.y> commit <hash if known>
  Audit completed: <UTC timestamp>

  ## TL;DR verdict
  READY TO BUILD | NEEDS REVISION | RESTART
  One paragraph with finding counts and the top risk.

  ## Findings by severity

  ### CRITICAL (N)
  ### MAJOR (N)
  ### MINOR (N)
  ### QUESTIONS (N)

  Format per finding: title, severity, category (A-I), section ref (§ N),
  quoted spec text, what's wrong, fix direction.

  ## SPEC-001 protocol compatibility matrix

  Standalone table verifying every SPEC-001 § 6.5 message has SPEC-002
  coverage. Use the same format SPEC-002 § 9 uses; add a column for
  "auditor verdict: matches / silent mismatch / not covered."

  ## Coverage of Phase 2 decision log

  Table of decision log entries SPEC-001 deferred to SPEC-002 (D1, D4,
  post-wake warm-up) and SPEC-002's coverage.

  ## What SPEC-002 does well

  3-5 things. Same anti-bias check as before.

  ## Final verdict recommendation

  Concrete next step:
    - READY TO BUILD → "Commit SPEC-002 v1.0, start coordinator build"
    - NEEDS REVISION → list ≤5 items to patch in-place
    - RESTART → list reasons (very unlikely)

## Hard rules for the auditor

1. Do NOT rewrite SPEC-002. Identify problems only.
2. The wire protocol from SPEC-001 § 6.5 is locked. If SPEC-002 violates
   it, that's a CRITICAL finding. Do not suggest changing SPEC-001 — the
   operator decides whether to fix SPEC-002 or amend SPEC-001.
3. Cite section numbers and quote text. Vague findings drop out.
4. You MAY check Go dependency tag existence via gh CLI / pkg.go.dev,
   but do not clone any d-inference content (strict clean-room).
5. If a SPEC-002 FR mentions an external service (Antseed, Caddy, etc.),
   you may briefly verify the service exists / has the named feature,
   but do not deeply audit external systems.

## Anti-rules

- Don't audit project strategy (Tier 1/2, Go vs Rust — already decided).
- Don't audit prose quality. Technical content only.
- Don't ask the operator questions during the audit.
- Don't audit BUILD_SPEC_002_PROMPT.md itself.

## When you finish

1. Re-read your audit. Anything you'd back off from? Move to MAJOR or
   QUESTIONS.
2. Verify every CRITICAL finding has section ref + quote.
3. Print to stdout: TL;DR verdict + finding counts + top 3 items.

Begin by reading the required files in order. Most of your time should
be in Category A (SPEC-001 protocol compatibility) — that's the
highest-leverage check.

=== END PROMPT ===
```

---

## How to use

```bash
cd /Users/augstar/macprovider-poc

# After SPEC-002 v1.0 lands:
codex < specs/AUDIT_SPEC_002_PROMPT.md
```

## Expected outcomes

| Outcome | Action |
|---|---|
| **READY TO BUILD** | Commit, then start coordinator build |
| **NEEDS REVISION** | Patch in-place if scope is small (≤5 items); otherwise draft `FIX_SPEC_002_V1_1_PROMPT.md` analogous to SPEC-001's fix prompt |
| **RESTART** | Very unlikely; would mean SPEC-002 fundamentally missed the brief |

## Why we don't pre-write a FIX_SPEC_002 prompt

The fix prompt is tailored to whatever findings the audit surfaces. Pre-writing it would over-specify. If a fix cycle is needed, I'll draft `FIX_SPEC_002_V1_1_PROMPT.md` from the audit findings the same way I drafted SPEC-001's.

## Two-prompt loop, summary

```
1. claude < specs/BUILD_SPEC_002_PROMPT.md         ~2h     → SPEC-002 v1.0
2. Operator reads v1.0                             ~20min
3. codex < specs/AUDIT_SPEC_002_PROMPT.md          ~45min  → SPEC-002-audit.md
4. Operator reads audit                            ~15min
5. IF READY → commit + start coordinator build     same day
   IF REVISION → patch or draft FIX prompt         +1-3h
```

Total to v1.0 build-ready SPEC-002: half a day in the optimistic case, 1 day in the conservative case. Both prompts ready when you are.
