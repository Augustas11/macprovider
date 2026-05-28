# Audit prompt — SPEC-003 redistribution second-opinion review

Operator-paste prompt to audit the redistributed SPEC-003 corpus —
**three coordinated specs**, not one:

  - `specs/SPEC-001-phase3-binary.md` (v1.2, absorbs Part A wire protocol)
  - `specs/SPEC-002-coordinator.md` (v1.1, absorbs Part B admission)
  - `specs/SPEC-003-open-onboarding.md` (v0.2, narrowed to Parts C + D)

Run with **Codex CLI** for cross-model independence — the redistribution
was performed by Claude; the auditor should be Codex to maximize the
chance of catching blind spots. Expected duration: ~60-75 min (longer
than a single-spec audit because the redistribution-fidelity check is
the highest-value category).

Paste everything between the markers into a fresh Codex CLI session
rooted at `/Users/augstar/macprovider-poc`.

History note: SPEC-003 v0.1 was written as a single 2245-line document
that "amended by reference." It was redistributed (commit `d9dcb0d`)
into the three-spec form audited here. v0.1 still exists in git history
(commit `0b4bbb7`) and serves as the source-of-truth reference for the
redistribution-fidelity check (Category Z).

---

```
=== BEGIN PROMPT ===

You are auditing a coordinated three-spec change in the Mac Provider
project. You previously audited SPEC-001 (Phase 3 binary spec) and
SPEC-002 (Phase 4 coordinator spec); your prior audit outputs live at
specs/SPEC-001-audit.md, specs/SPEC-001-v1-1-audit.md,
specs/SPEC-002-audit.md, and specs/SPEC-002-v1-0-2-audit.md.

The change under audit is the redistribution of SPEC-003 v0.1's content
into three coordinated spec updates (commit d9dcb0d):

  SPEC-001 v1.1.4 -> v1.2  (absorbed Part A wire protocol as opt-in
                            capability with backward-compat scoping)
  SPEC-002 v1.0.4 -> v1.1  (absorbed Part B admission tier semantics +
                            routing changes + new admin endpoints)
  SPEC-003 v0.1   -> v0.2  (narrowed to Parts C distribution + D
                            onboarding + integration narrative)

Your job: read all four documents (3 new + v0.1 for reference) and
produce a structured audit report at
/Users/augstar/macprovider-poc/specs/SPEC-003-audit.md.

The highest-value check (Category Z below) is REDISTRIBUTION FIDELITY:
verify nothing semantically meaningful was lost, changed, or duplicated
when content moved from SPEC-003 v0.1 to its new homes.

You are NOT here to validate, rewrite, or extend these specs. Find
problems, report them, let the operator decide fixes.

## Critical constraints to honor while auditing

**1. Backward-compat is the load-bearing invariant.** Phase 3 binaries
implementing SPEC-001 v1.1.3/v1.1.4 (deployed today on M4 and M1)
MUST remain fully compliant with the MANDATORY portion of SPEC-001
v1.2. If you find ANY way the v1.2 changes would make v1.1.x binaries
non-compliant in their current production configuration, that is a
CRITICAL finding.

The opt-in signal: provider sends `endpoint_url` in hello OR coordinator's
`config.providers[]` has an `endpoint_url` for this provider_id. Both
true -> HTTP-forwarding mode (legacy, where M4/M1 live). Neither true
-> WS-tunneled mode (new path, requires § 6.6 implementation).

Verify the SPEC-001 v1.2 change-log includes the verbatim backward-
compatibility statement (the prompt that produced the redistribution
contains the exact text; check it appears verbatim in the spec). Verify
the § 6.6 normative scope clause limits the new message types to
WS-tunneled mode. Verify SPEC-002 v1.1 § 3 contains the routing-mode
resolution table/pseudocode.

**2. d-inference clean-room.** Do NOT inspect d-inference source.
Reading their LICENSE for cross-reference is allowed; reading
README/docs is allowed but discouraged. The clean-room paragraphs
in SPEC-001 § 8.2 and SPEC-002 § 8.2 should remain VERBATIM
identical to v1.1.4/v1.0.4. Any divergence is a finding.

**3. Buyer API stability.** The buyer-facing HTTP API
(POST /v1/chat/completions, GET /v1/models, GET /healthz) MUST NOT
change in observable behavior. SPEC-002 v1.1 should state this
explicitly somewhere in § 4 or § 7.2. Any spec text describing
buyer-side change is a CRITICAL finding.

**4. Match SPEC-001/002 rigor.** These specs went through 3-4 audit
rounds in their prior lives. Apply the same severity bar. "Hand-wavy"
requirements, unjustified numeric thresholds, and "TBD"s disguised
as OQs are MAJOR findings.

**5. No invented content.** The redistribution agent was instructed
to ONLY move content, not invent new design choices. If any normative
claim in SPEC-001 v1.2 / SPEC-002 v1.1 / SPEC-003 v0.2 has no source
passage in SPEC-003 v0.1 AND is not a mechanical cross-spec
consistency clause required by the redistribution, that is a MAJOR
finding ("scope creep during redistribution").

## Required reading (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.2 — read fully, especially the v1.2 change-log header, the
   added `endpoint_url` field in § 6.5 hello, the new § 6.6
   (Inference message types), FR-21..FR-32, AC-11..AC-15, OQ-4,
   OQ-5. Verify v1.1.4 + earlier change-log entries are preserved.

2. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
   v1.1 — read fully, especially the v1.1 change-log, § 3 mode
   resolution, § 5 admission-tier-weighted routing + case-insensitive
   model match, § 7.1 F-2 amendment + new close codes 4007/4008/4009,
   § 7.5 admission endpoints, § 10 D7-D10, FR-P14..FR-P21,
   AC-11..AC-14, OQ-6..OQ-10. Verify v1.0.4 + earlier change-log
   entries are preserved.

3. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   v0.2 — read fully. Verify it's been narrowed to Parts C + D +
   integration narrative. Check final line count is in the
   1200-1500 range (or if shorter, that the agent justified it).

4. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   AT COMMIT 0b4bbb7 — the v0.1 reference. To view it without
   checking out the commit, run:
     git show 0b4bbb7:specs/SPEC-003-open-onboarding.md > /tmp/spec003-v0.1.md
   Then read /tmp/spec003-v0.1.md fully. This is your source-of-
   truth for the redistribution-fidelity check (Category Z).

5. /Users/augstar/macprovider-poc/specs/REDISTRIBUTE_SPEC_003_V0_1_PROMPT.md
   — what the redistribution agent was instructed to produce.
   Especially: the redistribution map table (which v0.1 section
   went where), the backward-compat statement (must appear verbatim
   in SPEC-001 v1.2 change-log), and the "What NOT to do" list.

6. /Users/augstar/macprovider-poc/specs/SPEC-001-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-001-v1-1-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-002-audit.md
   /Users/augstar/macprovider-poc/specs/SPEC-002-v1-0-2-audit.md
   — your prior audits, for tone/format continuity.

7. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — Decision log entries 12-18. SPEC-002 v1.1 § 10 should have
   D7-D10 added; verify they faithfully encode the corresponding
   entries.

8. /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
   — current provider-side WS handler. Verify SPEC-001 v1.2 § 6.6
   composes cleanly with drainFromCoordinator() and v1.1.4 state-
   reset path.

9. /Users/augstar/macprovider-poc/phase4-coordinator/internal/ws/
   messages.go, server.go — current coordinator wire-format Go
   structs + handlers. SPEC-002 v1.1's new FRs should be
   implementable in terms compatible with this code.

10. /Users/augstar/macprovider-poc/HANDOFF.md and CONTINUE_RUNBOOK.md
    — project context.

You may browse the rest of the repo for context. Do NOT browse
d-inference repos or sources.

## Audit categories — work through each

### Category Z: Redistribution fidelity (HIGHEST PRIORITY)

This is the category that gates whether the redistribution was sound.

Z.1  Walk through every FR in SPEC-003 v0.1 (FR-A1..A12, FR-B1..B7,
     FR-C1..C8, FR-D1..D5). For each, identify its destination spec
     (v1.2 / v1.1 / v0.2) and verify it appears in the destination
     with the same normative semantics. Findings:
       - MISSING (FR present in v0.1 but absent from all destinations) = CRITICAL
       - SEMANTICALLY CHANGED (present but with different normative content) = CRITICAL
       - DUPLICATED (present in two specs) = MAJOR
       - RENUMBERED ONLY (same semantics, new ID) = OK

Z.2  Walk through every AC in SPEC-003 v0.1 (AC-1..AC-12). Verify
     each appears in its destination spec. Same severity rules as Z.1.

Z.3  Walk through every OQ in SPEC-003 v0.1 (OQ-1..OQ-7). Verify
     each is preserved in its new home AND that the rationale
     paragraph attached to each OQ survived intact. Lost rationale = MAJOR.

Z.4  Walk through numeric thresholds in SPEC-003 v0.1 (e.g., 10
     admissions/hr, 100 provisional cap, 100 requests/hr/provider,
     1s cancellation SLA, 15s reconnect grace). Each should appear
     in exactly ONE destination spec with rationale preserved.
     - Appears in 0 destinations = CRITICAL (lost normative content)
     - Appears in 2+ destinations = MAJOR (duplication, drift risk)
     - Rationale dropped or changed = MAJOR

Z.5  Walk through new content that exists in v1.2/v1.1/v0.2 but
     NOT in v0.1. The only legitimate additions are:
       - Cross-spec consistency clauses (e.g., "see SPEC-002 § 5
         for routing weight")
       - The backward-compat statement in SPEC-001 v1.2 (verbatim
         from the redistribution prompt)
       - Renumbering, restructuring, and reformatting
     Anything else (new FRs, ACs, normative clauses, design choices)
     = MAJOR finding ("scope creep during redistribution").

Z.6  Verify the redistribution map from the prompt was actually
     followed. For example, SPEC-003 v0.1 § 5 (Wire protocol) was
     supposed to move to SPEC-001 v1.2 § 6.6. Is it there? Did
     anything get sent to the wrong destination?

Z.7  Verify SPEC-003 v0.2 final length is in the 1200-1500-line
     target range, OR if shorter, that the redistribution agent
     surfaced this and justified it (e.g., "Parts C + D were
     genuinely smaller than the protocol/admission content that
     moved out"). Length wildly off target (>2000 or <500) without
     justification = MINOR.

### Category A: Cross-spec consistency

A.1  Every reference SPEC-003 v0.2 makes to SPEC-001 v1.2 or
     SPEC-002 v1.1 must resolve to a real section number in those
     specs. Broken cross-reference = MAJOR.

A.2  SPEC-002 v1.1 references SPEC-001 v1.2 in its "Depends on"
     line. Every protocol message SPEC-002 v1.1 expects (e.g.,
     inference_request, inference_response_chunk) must be defined
     in SPEC-001 v1.2 § 6.6 with consistent wire format. Any field
     name / enum value / shape mismatch = CRITICAL (wire-compat
     hazard).

A.3  SPEC-001 v1.2 § 6.5 hello message — is the new `endpoint_url`
     field optional? Is its absence interpretation explicit (null
     or absent = WS-tunneled mode signal)? CRITICAL if ambiguous.

A.4  SPEC-001 v1.2 § 6.5 hello_ack message — new `tier` and
     `recommended_binary_version` fields are stated as optional
     and informational? Coordinator MUST set them under what
     conditions? MAJOR if undefined.

A.5  SPEC-002 v1.1 mode resolution (§ 3) — every provider state
     transition path (new hello, reconnect, drain + reconnect)
     must produce a deterministic mode. Edge cases:
       - Provider in config.providers[] with endpoint_url, but
         hello has different endpoint_url. Which wins? MAJOR if
         undefined.
       - Provider NOT in config.providers[], hello has endpoint_url.
         Provisional or HTTP-forwarding? MAJOR if undefined.

A.6  SPEC-001/SPEC-002 § 8.2 clean-room paragraphs are VERBATIM
     identical to v1.1.4/v1.0.4? Diff them. Any change = MAJOR
     unless explicitly justified.

### Category B: Wire protocol rigor (Part A in SPEC-001 v1.2 § 6.6)

(All previously in audit prompt as Category B — still applies.)

B.1  Multiplexing semantics: duplicate request_id detection,
     unknown request_id handling, per-request_id cleanup policy?
B.2  Streaming chunk framing: explicit choice of one-chunk-per-frame
     vs batched vs bytestream?
B.3  Cancellation latency: 1s SLA traceable? Path documented?
B.4  Backpressure: per-provider WS write buffer bounds + drop policy?
B.5  Backward-compat detection: all four combinations of
     (hello has endpoint_url) × (config has endpoint_url) handled?
B.6  Error semantics: protocol error vs inference error vs network
     error each have distinct paths?
B.7  Frame size limits: at least interim default specified pending
     OQ-4 resolution?

### Category C: Admission tier semantics (Part B in SPEC-002 v1.1)

(All previously applied — still applies.)

C.1  Rate limits internally consistent? Eviction policy when cap hit?
C.2  Routing weight integration: explicit placement in SPEC-002 § 5
     sort/multiplier?
C.3  Rejected tier persistence across coord restart?
C.4  Anti-abuse posture without Tier 2 attestation: are mitigations
     adequate, or just lip service called out as such (OQ-9)?
C.5  Promotion persistence (OQ-8 territory): runtime-only or
     write-back to config?

### Category D: Distribution lifecycle (Part C in SPEC-003 v0.2)

D.1  install.sh contract precise enough for security review?
D.2  Self-update behavior for in-flight requests (drain protocol)?
D.3  launchd plist normative path + restart policy?
D.4  Version nudging vs enforcement OQ resolved or explicit?
D.5  Coordinator-advertised version field documented in SPEC-001
     v1.2 hello_ack (per A.4)?

### Category E: Onboarding UX (Part D in SPEC-003 v0.2)

E.1  curl-pipe-bash security tradeoff acknowledged?
E.2  First-run model download size + duration surfaced?
E.3  Uninstall coverage complete (binary, plist, logs, models,
     coordinator-side cleanup)?

### Category F: Backward compatibility for pinned providers

F.1  M4 (v1.1.4) reconnect after v1.2 coordinator deploy — walk
     through. Does the coordinator route via HTTP-forwarding
     unconditionally? CRITICAL if not.

F.2  Provisional handle collides with pinned provider_id (e.g.,
     stranger claims "m4-anon"). Resolution? CRITICAL if undefined.

F.3  Existing install-m4-coordinator.sh / install-m1-coordinator.sh
     continue to work? Verify.

F.4  AC-15 (or equivalent) actually tests this invariant by
     simulating a v1.1.x binary receiving an unexpected inference_request?
     If absent = MAJOR.

### Category G: Buyer API stability

G.1  SPEC-002 v1.1 modifies any field in OpenAI-compatible
     request/response? CRITICAL if yes.

G.2  Routing for any model_id-buyer-request that worked under v1.0.4
     now produces a different target? CRITICAL if yes for production
     traffic.

G.3  /v1/models aggregation — admission tier affects which models
     are advertised? Should it?

### Category H: Internal consistency (within each spec)

H.1  FRs contradict each other within a spec?
H.2  In-scope (§ 2) matches what FRs (§ 4) cover?
H.3  Acceptance criteria test the FRs?
H.4  Interface contracts (§ 7) consistent with FRs?
H.5  Open questions actually open, or hand-waved decisions?

### Category I: Acceptance criteria

I.1  Each AC measurable with concrete commands/script names?
I.2  AC-15 (or equivalent) — backward-compat test referenced an
     existing or to-be-created mockprovider tool?
I.3  Distribution ACs reference a "clean Mac" baseline that's
     testable? Reproducible test environment specified?
I.4  Pass rule stated per spec?
I.5  At least one AC per spec exercises cross-spec interaction
     (e.g., AC-15 in SPEC-001 v1.2 tests behavior involving
     SPEC-002 v1.1 mode resolution)?

### Category J: Open questions

J.1  Total OQ count across all three specs: target 7-10 (vs 7 in
     v0.1). Big jump = MAJOR (OQs added during redistribution =
     scope creep).
J.2  For each OQ, can YOU answer it from source materials (Decision
     log, prior specs, industry practice)? If yes, the OQ is
     artificial and should be MAJOR finding "OQ-X is decidable
     from sources."
J.3  OQ-1 (frame size), OQ-7 (version enforcement), code signing
     OQ each have enough rationale that the operator can decide
     without re-research?

### Category K: Reference hygiene (clean-room)

K.1  § 8 (or wherever it lives in each spec) reaffirms d-inference
     clean-room separation? Same verbatim wording across all three
     specs?
K.2  Any d-inference URLs or references outside the hygiene block?
K.3  Convergent-design rationale chain (Tor, Tailscale, GitHub
     Actions runners, etc.) cited in the WS-tunneled section of
     SPEC-001 v1.2 § 6.6 with at least one concrete reference per
     citation?

### Category L: Scope discipline

L.1  Anything that belongs in SPEC-004 (smart router), SPEC-005
     (rewards), SPEC-007 (Antseed seller) sneak in?
L.2  Tier 2 attestation territory crept in?
L.3  Anything bloating v1.2/v1.1/v0.2 that should be in a future
     revision?

### Category M: Implementability

M.1  Could a competent Swift+Go developer (or fresh Claude/Codex
     session) start coding SPEC-001 v1.2 § 6.6 with ≤3
     clarifications?
M.2  Could a competent Go developer start coding SPEC-002 v1.1
     FR-P14..FR-P21 with ≤3 clarifications?
M.3  Could a competent shell developer write install.sh from
     SPEC-003 v0.2 § 7 (or wherever the install contract lives)
     with ≤3 clarifications?
M.4  All Go dependencies (if any new ones added) pinned to specific
     versions?

## Severity rubric

  CRITICAL — wire compat break with SPEC-001 v1.1.4 (would corrupt
             M4/M1 routing), buyer API observable change, anti-abuse
             loophole at provisional tier, undefined behavior in
             backward-compat path, internally contradictory FRs,
             OR redistribution-fidelity FAILURE (Category Z: MISSING
             or SEMANTICALLY CHANGED v0.1 content).

  MAJOR    — ambiguous requirement with multiple valid interpretations,
             missing acceptance for a stated capability, OQ that's
             actually decidable from sources, dependency not pinned
             where pinning matters, numeric threshold without
             rationale, normative gap in error semantics, OR
             redistribution-fidelity issue (Category Z: DUPLICATED
             content, lost rationale, scope creep).

  MINOR    — formatting, wording, or default choices that cause
             friction but not failure.

  QUESTION — auditor cannot determine from source materials.

## Output format

Write to:
  /Users/augstar/macprovider-poc/specs/SPEC-003-audit.md

Structure:

  # SPEC-003 Redistribution Audit Report
  Auditor: <model name + version>
  Specs audited:
    SPEC-001 v1.2 commit <hash>
    SPEC-002 v1.1 commit <hash>
    SPEC-003 v0.2 commit <hash>
  Reference: SPEC-003 v0.1 (commit 0b4bbb7)
  Audit completed: <UTC timestamp>

  ## TL;DR verdict
  READY TO BUILD | NEEDS REVISION | RESTART
  One paragraph with finding counts and the top three risks.

  ## Redistribution fidelity matrix (Category Z)

  Standalone table covering EVERY FR / AC / OQ from SPEC-003 v0.1.
  Columns:
    - v0.1 ID (e.g., FR-A3)
    - v0.1 description (one line)
    - Destination spec + ID (e.g., SPEC-001 v1.2 FR-23)
    - Auditor verdict: preserved / semantically changed / missing /
      duplicated

  ## Findings by severity

  ### CRITICAL (N)
  ### MAJOR (N)
  ### MINOR (N)
  ### QUESTIONS (N)

  Format per finding: title, severity, category (Z/A-M), spec ref
  (e.g., "SPEC-001 v1.2 § 6.6"), quoted spec text, what's wrong,
  fix direction.

  ## Cross-spec consistency matrix

  Standalone table verifying each cross-spec reference resolves.
  Columns:
    - Source spec/section
    - Reference target (e.g., "see SPEC-002 § 5.1")
    - Auditor verdict: resolves / broken / partial

  ## OQ disposition

  For each of the OQs (target ~7) across the three specs:
    - Quote the OQ
    - State whether you (auditor) can answer it from source materials
    - If yes, propose the answer + cite the source
    - If no, confirm it's a real operator decision

  ## Suggested fix order

  Ordered list of which findings should be addressed first in the
  next revision. Group CRITICALs first (Z fidelity issues take
  priority, then wire-compat issues), then MAJORs that block build
  start, then MAJORs that block ship.

## What NOT to do

  - Do NOT modify the specs yourself. Audit only.
  - Do NOT build or scaffold code.
  - Do NOT browse d-inference repos or sources.
  - Do NOT propose features beyond fix direction (no scope creep
    into v0.3 design).
  - Do NOT validate by running AC scripts — those don't exist yet.
    Validate by reading the spec.
  - Do NOT skip Category Z. It is the primary value-add of this
    audit. A redistribution that lost or changed v0.1 semantics
    is the failure mode this prompt exists to catch.

When done, print a 200-word summary to stdout with:
  - Verdict
  - CRITICAL / MAJOR finding counts (broken out by category Z vs others)
  - Top three risks
  - Which OQs you could answer from sources
  - Whether the backward-compat invariant holds (yes/no with one-line
    rationale)
Then stop.

=== END PROMPT ===
```

---

## After running this prompt

Operator's review checklist:

1. Skim the **Redistribution fidelity matrix** first — this is the unique
   contribution of this audit pass. If it shows MISSING or SEMANTICALLY
   CHANGED rows, fix those before anything else.
2. Read CRITICAL findings in Category Z and F (backward-compat) before
   any others.
3. Cross-check the OQ disposition against the redistribution prompt's
   OQ mapping.
4. Decide: are CRITICALs fixable by another redistribution pass, or do
   we need to revert + restart?

Then:
- If 0 CRITICALs and ≤5 MAJORs → write `FIX_SPEC_003_V0_2_PROMPT.md`,
  resolve, re-audit ONCE with narrower scope (only the changed sections),
  then move to BUILD prompts.
- If >0 CRITICALs → write `FIX_SPEC_003_V0_2_PROMPT.md` covering them,
  re-run THIS audit (not narrower), confirm CRITICALs cleared.
- If >10 MAJORs → consider whether the redistribution itself was the
  wrong call. Reverting to v0.1 + adding a conflict-resolution clause
  (Option A from conversation) may be cheaper than fixing.

Expected total path: 1-2 audit rounds, then build prompts. Aim to have
specs locked by Friday EOD (Day 3).
