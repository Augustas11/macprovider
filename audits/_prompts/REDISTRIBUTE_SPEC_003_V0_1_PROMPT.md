# Redistribute prompt — SPEC-003 v0.1 → SPEC-001 v1.2 + SPEC-002 v1.1 + SPEC-003 v0.2

Operator-paste prompt to **restructure** the existing SPEC-003 v0.1 draft
into three coordinated spec updates that avoid the cross-spec drift trap.

**The problem this prompt solves.** SPEC-003 v0.1 (committed at `0b4bbb7`)
takes the "amends by reference" approach: the new WS message types and
admission tier semantics live in SPEC-003 while SPEC-001 v1.1.4 and
SPEC-002 v1.0.4 stay frozen. This creates a maintenance trap — a future
reader of SPEC-001 § 6.5 in isolation sees the old 9 message types with
no breadcrumb to the 4 new ones. Worse, it leaves the backward-
compatibility scoping (M4/M1 v1.1.x binaries must keep working) only in
SPEC-003, where it's easy to miss.

**The structural fix.** Redistribute SPEC-003 v0.1's content so that each
spec owns its natural surface:

  - **SPEC-001 v1.2** absorbs Part A (WS-tunneled inference wire protocol)
    as an OPT-IN capability with explicit backward-compat scoping.
    v1.1.x binaries remain fully compliant with the MANDATORY portion.
  - **SPEC-002 v1.1** absorbs Part B (admission tier semantics, routing
    weight, forwarding mode resolution, new admin endpoints).
  - **SPEC-003 v0.2** shrinks to Parts C + D (distribution + lifecycle +
    onboarding UX) plus the integration narrative for how A + B + C + D
    compose.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Claude Code session rooted at `/Users/augstar/macprovider-poc`.
Expected duration: ~3 hours of focused work.

---

```
=== BEGIN PROMPT ===

You are restructuring SPEC-003 v0.1 (committed at 0b4bbb7) into three
coordinated spec updates:

  SPEC-001 v1.1.4 → v1.2 (absorb Part A wire protocol)
  SPEC-002 v1.0.4 → v1.1 (absorb Part B admission + routing)
  SPEC-003 v0.1   → v0.2 (shrink to Parts C + D + integration narrative)

This is NOT a fresh spec write. Every normative claim in your output
must trace back to a passage in SPEC-003 v0.1. You are MOVING content
between specs and re-articulating it in each spec's voice. You are NOT
inventing new design choices, and you are NOT removing design choices
already in SPEC-003 v0.1.

The deliverable is three modified markdown files plus a handback summary.

## Mission

Mac Provider needs to scale its supply side beyond operator-vetted
partners. SPEC-003 v0.1 specified four parts (WS-tunneled inference +
dynamic admission + distribution + onboarding) as a single document.
But Parts A and B amend the wire protocol and coordinator behavior
that already have homes (SPEC-001 § 6.5 and SPEC-002 § 3/§ 5/§ 7).
Keeping them in SPEC-003 creates cross-spec drift.

This redistribution puts each part where it belongs:

  Part A → SPEC-001 v1.2 (it's wire protocol; the binary spec owns
                          the wire protocol)
  Part B → SPEC-002 v1.1 (it's coordinator behavior; the coordinator
                          spec owns coordinator behavior)
  Part C → SPEC-003 v0.2 (distribution is new ground, no prior home)
  Part D → SPEC-003 v0.2 (onboarding UX is new ground, no prior home)
  Integration narrative → SPEC-003 v0.2 (how A + B + C + D compose to
                                          deliver "stranger downloads
                                          and joins")

## Critical constraints (re-read these before each editing pass)

**1. Drift avoidance is the load-bearing invariant.** SPEC-001 v1.2
MUST be structured so that phase3-binary v1.1.3 and v1.1.4 binaries —
deployed today on M4 and M1 — remain fully compliant with the
MANDATORY portion of SPEC-001 v1.2.

The drift trap (wrong way to write v1.2): "All providers MUST handle
inference_request." This breaks v1.1.x binaries immediately.

The backward-compat way (right way to write v1.2): The new § 6.6
(Inference message types) is NORMATIVELY SCOPED to providers operating
in WS-tunneled mode. Mode is determined by:
  - Provider sends `endpoint_url` in hello (opt-in HTTP-forwarding) → HTTP mode
  - Coordinator's static config.providers[] has an endpoint_url for
    this provider_id → HTTP mode
  - Neither → WS-tunneled mode

M4 and M1 fall into the second bucket. They will never receive
inference_request and remain fully compliant with v1.2's MANDATORY
portion. NO M4/M1 BINARY UPGRADE IS REQUIRED.

Verify this invariant explicitly in:
  - SPEC-001 v1.2 change-log header (Backward Compatibility note)
  - SPEC-001 v1.2 § 6.6 normative scope clause
  - SPEC-002 v1.1 § 3 routing-mode resolution table

**2. d-inference clean-room.** Do NOT inspect d-inference source.
The clean-room paragraphs in SPEC-001 v1.1.4 § 8.2 and SPEC-002 v1.0.4
§ 8.2 stay as-is. SPEC-003 v0.2 reaffirms via cross-reference.

**3. Buyer API stable.** Zero observable change to POST /v1/chat/completions,
GET /v1/models, GET /healthz. Verify this in SPEC-002 v1.1 § 7.2.

**4. Preserve all 7 OQs from SPEC-003 v0.1.** Redistribute them to the
spec that owns the question:
  - OQ-1 (WS frame size) → SPEC-001 v1.2 (wire protocol concern)
  - OQ-2 (per-provider write buffer) → SPEC-001 v1.2 (wire concern) OR
    SPEC-002 v1.1 (coord backpressure) — pick the better home
  - OQ-3 (surface tier=provisional to buyers) → SPEC-002 v1.1
    (buyer-facing surface)
  - OQ-4 (version enforcement for provisional) → SPEC-002 v1.1
    (admission control)
  - OQ-5 (code signing) → SPEC-003 v0.2 (distribution concern)
  - OQ-6 (promotion persistence) → SPEC-002 v1.1 (coord state)
  - OQ-7 (provisional identity verification) → SPEC-002 v1.1 (admission)

Each OQ retains its rationale paragraph. Do not delete any.

**5. Match the rigor pattern.** SPEC-001/002 went through 3-4 audit
rounds. Match the same severity bar. RFC 2119 normative keywords.
Numeric thresholds with rationale. No hand-waving.

## Read these files first (in order, fully)

1. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
   — the source document. 2245 lines / 92 KB / 15 sections. Read all
   of it. Take notes on which section belongs in which destination
   spec (most are obvious; some compose).

2. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
   v1.1.4 — the binary spec you will modify. Pay attention to:
     § 0    Change log header — you'll add a v1.2 entry
     § 6.5  WebSocket envelope — you'll add optional endpoint_url
            field to hello + reference new § 6.6
     (new) § 6.6  Inference message types (Part A absorbs here)
     § 8.2  Reference hygiene — preserve verbatim

3. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md v1.0.4
   — the coordinator spec you will modify. Pay attention to:
     § 0    Change log header — you'll add a v1.1 entry
     § 3    Request forwarding model — split into two paths
            (HTTP-forwarding for pinned, WS-tunneled for provisional)
     § 5    Routing algorithm — add admission-tier weight
     § 7.1  Provider WebSocket — F-2 amendment (relax to three-tier model)
     § 7.4  Operator endpoints — add /admin/provisional, /admin/promote,
            /admin/reject
     § 8.2  Reference hygiene — preserve verbatim
     § 10   D6 findings — add D7-D10 entries that SPEC-003 v0.1 already
            drafted

4. /Users/augstar/macprovider-poc/specs/BUILD_SPEC_003_PROMPT.md
   — what SPEC-003 v0.1 was originally instructed to produce. Use it
   to understand the design choices SPEC-003 v0.1 represents.

5. /Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md
   — Decision log entries 12-18 are the source of truth for what
   SPEC-003 v0.2 must encode in SPEC-002 v1.1 § 10 (D7-D10).

6. /Users/augstar/macprovider-poc/phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift
   — current provider-side WS handler. Verify your SPEC-001 v1.2 § 6.6
   message types compose cleanly with drainFromCoordinator() (v1.1.3+)
   and the v1.1.4 state-reset path.

You may browse the rest of the repo for context. Do NOT browse
d-inference repos.

## Redistribution map (use this as your editing plan)

Walk through SPEC-003 v0.1 section by section. The target home for
each is:

| SPEC-003 v0.1 section | Target |
|---|---|
| § 0 Operator-paste invocation block | SPEC-003 v0.2 § 0 (updated) |
| § 1 Mission | SPEC-003 v0.2 § 1 (narrowed: distribution + onboarding mission) |
| § 2 Scope | SPEC-003 v0.2 § 2 (narrowed) + SPEC-001 v1.2 change-log + SPEC-002 v1.1 change-log |
| § 3 Architecture overview | Split: SPEC-001 v1.2 § 6.5 routing-mode preamble, SPEC-002 v1.1 § 3 (two-path forwarding diagram), SPEC-003 v0.2 § 3 (the integration narrative — how a stranger goes from `curl` to "in the pool") |
| § 4 Functional requirements | Split by part: FR-A* → SPEC-001 v1.2 § 4, FR-B* → SPEC-002 v1.1 § 4, FR-C* + FR-D* → SPEC-003 v0.2 § 4 |
| § 5 Wire protocol (Part A) | SPEC-001 v1.2 § 6.6 (new), § 6.5 hello field addition, § 6.5 hello_ack field additions |
| § 6 Admission tiers (Part B) | SPEC-002 v1.1 § 7.1 (F-2 amendment), § 3.1 (mode resolution), § 5.1 (tier-weighted routing), new § 7.5 (provisional state) |
| § 7 Interface contracts | Split: § 7.1 (new WS message types) → SPEC-001 v1.2 § 7.x; § 7.2 (new operator endpoints) → SPEC-002 v1.1 § 7.4; § 7.3-7.6 (install.sh, CLI subcommands, launchd, releases) → SPEC-003 v0.2 § 7 |
| § 8 Dependencies + clean-room | Each spec gets its own (preserve SPEC-001/002 § 8.2 verbatim; SPEC-003 v0.2 cross-references) |
| § 9 Phase 4 findings + Day 2 lessons | D7-D10 → SPEC-002 v1.1 § 10 (extends existing D1-D6); SPEC-003 v0.2 § 9 cross-references |
| § 10 Acceptance criteria | Split: AC-1..AC-5 (WS-tunneled inference) → SPEC-001 v1.2 § 11; AC-6, AC-7, AC-11, AC-12 (admission) → SPEC-002 v1.1 § 11; AC-8, AC-9, AC-10 (distribution + onboarding) → SPEC-003 v0.2 § 10. Renumber within each destination. |
| § 11 Open questions | Redistribute per § "Critical constraints" item 4 above. |
| § 12 Build steps | SPEC-003 v0.2 § 11 (point at separate BUILD_SPEC_001_V1_2_PROMPT.md, BUILD_SPEC_002_V1_1_PROMPT.md, BUILD_SPEC_003_V0_2_PROMPT.md — but you don't write those prompts; you just reference them) |
| Appendix A | Drop or merge into SPEC-003 v0.2 |

## Deliverables

Modify three files in place:

  1. /Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md
     - Bump version to 1.2 in the header
     - Add v1.2 change-log entry at the top with backward-compat
       statement (verbatim text below in "Backward-compat statement")
     - Add optional `endpoint_url` field to § 6.5 hello message schema
     - Add optional `latest_binary_version` and (optional)
       `required_binary_version` fields to § 6.5 hello_ack schema
       (from SPEC-003 v0.1 § C.5)
     - Add new § 6.6 "Inference message types" (the largest insertion;
       ~400-600 lines from SPEC-003 v0.1 § 5)
     - Add FR-9.x WS-tunneled FRs (FR-A1..FR-A12 from SPEC-003 v0.1,
       renumbered into SPEC-001's FR namespace)
     - Add AC-W1..AC-W5 (WS-tunneled inference ACs from SPEC-003 v0.1
       § 10 AC-1..AC-5, renumbered)
     - Redistribute relevant OQs

  2. /Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md
     - Bump version to 1.1 in the header
     - Add v1.1 change-log entry
     - Amend § 3 "Request forwarding model" to describe the two-path
       resolution (HTTP-forwarding for providers with endpoint_url via
       hello OR config; WS-tunneled otherwise)
     - Amend § 5 "Routing algorithm" to add admission-tier weight as
       a new factor (specify exact algorithmic placement: multiplicative
       factor on throughput? primary sort key? secondary?)
     - Amend § 7.1 to relax F-2 with three-tier admission (pinned /
       provisional / rejected), including transition rules and rate
       limits
     - Add § 7.5 "Admission state and operator endpoints" with
       /admin/provisional, /admin/promote/{id}, /admin/reject/{id}
       (live on provider_port per F-3, bearer-auth gated)
     - Add new WS close codes 4007, 4008, 4009 to FR-P13's table
     - Extend § 10 with D7-D10 (drift fixes, drain conflation lesson,
       case-sensitivity lesson, coord overhead measurement)
     - Add FR-Px.y for admission tier mechanics + tier-weighted routing
     - Add new ACs covering admission tier (from SPEC-003 v0.1 AC-6,
       AC-7, AC-11, AC-12)
     - Redistribute relevant OQs

  3. /Users/augstar/macprovider-poc/specs/SPEC-003-open-onboarding.md
     - Rewrite header to v0.2 with restructure note
     - Narrow § 1 mission to: "make Mac Provider downloadable. Part C
       (distribution lifecycle) + Part D (onboarding UX) + integration
       narrative for how the SPEC-001 v1.2 WS-tunneled inference and
       SPEC-002 v1.1 dynamic admission compose into a stranger-can-join
       experience."
     - Drop content moved to SPEC-001 v1.2 (§ 4 FR-A*, § 5 entire
       Part A, § 10 AC-1..5)
     - Drop content moved to SPEC-002 v1.1 (§ 4 FR-B*, § 6 entire
       Part B, § 7 admin endpoints, § 9 D7-D10, § 10 AC-6, AC-7,
       AC-11, AC-12)
     - Keep + tighten content for Parts C + D
     - Add new § 3 integration narrative: ASCII diagram showing how
       SPEC-001 v1.2 § 6.6 messages + SPEC-002 v1.1 admission + SPEC-003
       v0.2 distribution combine
     - Final length target: 1200-1500 lines (down from 2245)

## Backward-compat statement (paste verbatim into SPEC-001 v1.2 change-log)

> **Backward compatibility.** Phase 3 binaries implementing SPEC-001
> v1.1.4 (or earlier v1.1.x patches v1.1.2, v1.1.3) remain FULLY
> COMPLIANT with the MANDATORY portion of SPEC-001 v1.2 without any
> code change, recompile, or reinstall. The new § 6.6 (Inference
> message types) is NORMATIVELY SCOPED to providers operating in
> WS-tunneled mode, signalled by the absence of `endpoint_url` in
> their `hello` message AND the absence of a corresponding
> `endpoint_url` in the coordinator's `config.providers[]` entry for
> their `provider_id`. Operator-configured pinned providers (e.g.,
> M4 and M1 as of 2026-05-28, both running v1.1.x binaries with
> coordinator-side static endpoint_url entries) operate in HTTP-
> forwarding mode and MUST NEVER receive § 6.6 messages from the
> coordinator. Coordinators (SPEC-002 v1.1) MUST verify routing mode
> via § 3 mode resolution before dispatching any § 6.6 message.
> v1.1.x binaries that receive an unexpected § 6.6 message SHOULD
> respond with `nak code=unknown_message_type` per § 6.5 nak
> semantics; coordinators that observe such a nak MUST mark the
> routing-mode resolution buggy and not retry, treating the provider
> as HTTP-forwarding-only for that session.

## Process

1. Read everything in "Read these files first". Take notes on the
   redistribution map.

2. Outline your edits in a scratchpad before opening any spec file.
   List every section to be added/modified/deleted in each of the
   three target files. Cross-reference with the redistribution map.

3. Edit SPEC-001-phase3-binary.md first (because it owns the
   protocol that SPEC-002 v1.1 will reference). Add change-log
   entry, hello field additions, § 6.6, FRs, ACs, OQs. Verify the
   backward-compat statement is verbatim.

4. Edit SPEC-002-coordinator.md second. Add change-log entry, § 3
   mode resolution, § 5 tier-weighted routing, § 7.1 F-2 amendment,
   § 7.5 admission endpoints, D7-D10, new FRs/ACs/OQs.

5. Rewrite SPEC-003-open-onboarding.md last. Drop redistributed
   content, rewrite § 1-3 with the narrower mission and integration
   narrative, keep Parts C + D content. Final length target:
   1200-1500 lines.

6. Cross-spec consistency self-review pass:
   - Every reference SPEC-003 v0.2 makes to SPEC-001 v1.2 or SPEC-002
     v1.1 must resolve to a real section number.
   - Every FR/AC/OQ moved must retain its semantic content.
   - No content silently lost.
   - Numeric thresholds (rate limits, buffer sizes) appear in
     exactly one spec each, not duplicated.

7. Print a 300-word handback summary to stdout describing:
   - SPEC-001 v1.2 change-log highlights (1-2 sentences)
   - SPEC-002 v1.1 change-log highlights (1-2 sentences)
   - SPEC-003 v0.2 final length + which parts remain
   - Backward-compat verification result (did you confirm v1.1.x
     binaries remain MANDATORY-compliant?)
   - Which OQs ended up where
   - Any cross-spec inconsistencies you couldn't fully resolve
     (these become audit findings)

8. Do NOT commit. Operator reviews + commits as a single coordinated
   commit covering all three files.

## What NOT to do

- Do NOT invent new design choices. Every normative statement in
  your output must trace to a passage in SPEC-003 v0.1 OR be a
  cross-spec consistency clause required by the redistribution.
- Do NOT remove design choices already in SPEC-003 v0.1.
- Do NOT modify SPEC-001 v1.1.4 message types in ways that break
  v1.1.x binary wire compat. Add fields/sections only; never change
  or remove existing fields.
- Do NOT inspect d-inference source.
- Do NOT skip the backward-compat statement.
- Do NOT delete OQs. Redistribute them.
- Do NOT write new BUILD_*/AUDIT_* prompts; the operator handles
  those separately.
- Do NOT touch phase4-coordinator/, phase3-binary/, beta/ code —
  only the three spec files in specs/.

## Risk if you get this wrong

The drift trap is real. If SPEC-001 v1.2 omits the backward-compat
scoping, M4 and M1 (currently in production) become spec-non-compliant
the moment v1.2 is committed. The operator then has to either upgrade
both partners (operationally painful — today they're already on their
3rd or 4th install of the day) OR revert v1.2. Avoid both by keeping
the backward-compat statement load-bearing.

When done, print the 300-word handback summary and stop.

=== END PROMPT ===
```

---

## After running this prompt

The operator's review checklist:

1. Verify SPEC-001 v1.2 change-log has the backward-compat statement
   verbatim.
2. Verify SPEC-001 v1.2 § 6.6 has a normative scope clause limiting it
   to WS-tunneled mode.
3. Verify SPEC-002 v1.1 § 3 has the routing-mode resolution table.
4. Verify SPEC-003 v0.2 shrank to 1200-1500 lines (vs. v0.1's 2245).
5. Spot-check that all 7 OQs from v0.1 still exist (renumbered, in
   their new homes).
6. Spot-check that all 12 ACs from v0.1 still exist (renumbered, in
   their new homes).
7. `git diff` all three files in one view to confirm no content lost.

Then commit as a single coordinated commit. Suggested message:

```
SPEC-001 v1.2 + SPEC-002 v1.1 + SPEC-003 v0.2: redistribute v0.1 by spec ownership

Resolves the cross-spec drift trap from SPEC-003 v0.1 by relocating
each part to the spec that naturally owns its surface:
  Part A wire protocol -> SPEC-001 v1.2 § 6.6 (scoped opt-in)
  Part B admission     -> SPEC-002 v1.1 § 3/§ 5/§ 7
  Part C distribution  -> SPEC-003 v0.2 (kept)
  Part D onboarding    -> SPEC-003 v0.2 (kept)

Backward compat: v1.1.x binaries (M4, M1) remain fully compliant with
mandatory v1.2 portion. Verified via § 6.6 normative scope clause.

[...detailed listing of which FRs/ACs/OQs moved where...]
```

Then run the audit cycle against all three updated specs simultaneously
(see AUDIT_SPEC_003_PROMPT.md — it'll need a small update to cover the
new spec versions, but the audit categories all still apply).
