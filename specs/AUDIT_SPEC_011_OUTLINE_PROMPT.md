# Audit prompt — SPEC-011 v0.1 outline (pre-draft scope review)

Operator-paste prompt to audit the SPEC-011 v0.1 outline
(`specs/SPEC-011-operator-pushed-warm-swap.md`).

**This is an OUTLINE audit, not a normative audit.** SPEC-011 v0.1
is intentionally not yet normative — it describes scope, locked
decisions, and anticipated surface for the v0.2 normative draft.
The audit's job is to validate the scope decision BEFORE we invest
in a full normative draft, so we don't repeat the SPEC-012-source
mistake of audit-cycling on the wrong-shaped spec.

**Context:** SPEC-011 is one of three specs produced by splitting
the original wide-scope SPEC-010 v0.3 (preserved at
`specs/SPEC-012-source.md`, audit history at
`specs/SPEC-012-source-audit-history.md`). The split rationale:
SPEC-010 v0.3 went through three audit rounds without convergence
because it bundled five features. SPEC-010 v1.0 (capability
advertisement only) is currently in its round-1 audit in parallel
with this one. SPEC-011 v0.1 outlines operator-pushed warm swap;
SPEC-012 (demand-pull + buyer catalog) is deferred until SPEC-008
v0.4 is on the table.

**This audit runs in parallel with SPEC-010 v1.0 round 1.** It
does not depend on the SPEC-010 audit outcome.

Output goes into a new file `specs/SPEC-011-outline-audit.md`.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-011 v0.1 outline at
/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md.

**Important framing.** This is an OUTLINE audit, not a normative
audit. SPEC-011 v0.1 is not yet a normative spec — it describes
scope, locked decisions, and the anticipated normative surface that
the v0.2 draft will fully spell out. Your job is to predict whether
the v0.2 normative draft will be auditable in 1-2 rounds given the
outline as written, and to surface structural problems NOW before
v0.2 is drafted.

This means you are NOT grading:
- Missing R-rule numbers, AC counts, or full normative wire
  examples (those come in v0.2)
- Missing exhaustive validation rules (v0.2 will add them)
- OQs that are explicitly listed in §8 as v0.2 deferrals

You ARE grading:
- Whether the scope split is correct: did SPEC-011 inherit
  something that belongs in SPEC-010 v1.0 (capability) or
  SPEC-012 (demand-pull), or leak something to those that
  belongs here?
- Whether the anticipated normative surface in §4 is complete:
  is there a wire shape, state transition, or error path that
  v0.2 will need but the outline doesn't anticipate?
- Cross-spec interactions: do the §4 surfaces actually fit
  on top of locked SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-008
  v0.3 without forcing a normative edit?
- Whether the "1-2 audit rounds to lock" estimate in §6 is
  plausible given the outline's anticipated surface
- Whether the OQs in §8 cover the real ambiguity, or there
  are hidden OQs the outline silently glosses over
- Whether the locked decisions in §3 are mutually consistent
  with the anticipated surface in §4

You are NOT here to validate, rewrite, or extend the outline. Find
problems, report them with specific severity and location, and let
the operator decide fixes. Output to:
  /Users/augstar/macprovider-poc/specs/SPEC-011-outline-audit.md

## Severity definitions (adapted for outline audit)

- **CRITICAL** — structural problem that would force a major
  rewrite of v0.2 mid-draft. Examples: scope overlap with
  SPEC-010 v1.0 or SPEC-012 that breaks the split rationale;
  required SPEC-008 normative edit that the outline doesn't
  acknowledge; locked-decision inconsistency in §3.
- **MAJOR** — missing anticipated surface that v0.2 will need
  but won't be able to add without re-scoping. Examples: missing
  error path enumeration; hidden cross-spec dependency; missing
  OQ that the outline silently glosses over and will produce
  audit churn.
- **MINOR** — outline quality issues. Naming, organization,
  forward-references.
- **QUESTION** — pre-draft design choice the outline didn't
  resolve and probably can't until v0.2 drafting reveals more.

## Critical constraints

**1. Scope-creep recommendations are CRITICAL findings.** If a
finding's recommendation would expand SPEC-011 to cover what
SPEC-010 v1.0 or SPEC-012 owns, that's a CRITICAL violation of
the split rationale. The split exists to STOP scope bundling.

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
v0.3 are LOCKED.** SPEC-011 v0.2 will need companion-spec
candidate annotations (the outline §3 says SPEC-001 v1.3 and
SPEC-002 v1.3.5). Audit whether the outline's anticipated changes
to those specs are actually additive vs requiring normative
edits.

**3. SPEC-010 v1.0 is in parallel audit.** SPEC-011 v0.2 will
depend on SPEC-010 v1.0 being locked first. Audit whether the
outline correctly identifies what SPEC-010 v1.0 provides vs what
SPEC-011 needs to add.

**4. Clean-room.** Do NOT inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.1 outline — the spec under audit.

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.0 — the foundation SPEC-011 depends on. Verify §3.6 binary
   CLI rules don't overlap with SPEC-011 §4.1 CLI subcommand
   rules.

3. `/Users/augstar/macprovider-poc/specs/SPEC-012-source.md`
   (formerly the wide-scope SPEC-010 v0.3) — to understand what
   SPEC-011 deliberately leaves to SPEC-012. The §4.4 set_model
   wire and §4.5 cold-wake path are SPEC-012's territory.

4. `/Users/augstar/macprovider-poc/specs/SPEC-012-source-audit-history.md`
   — three rounds of audit on the wide-scope draft. Use to
   sanity-check whether SPEC-011's anticipated audit cost
   estimate (§6: 1-2 rounds) is plausible compared to what the
   wide scope cost.

5. `/Users/augstar/macprovider-poc/CLAUDE.md` — project
   conventions.

6. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on:
   - §6.2 CLI shape (SPEC-011 §4.1 adds `models` subcommand;
     verify naming/conflict-free with existing flags)
   - §6.5 auth frame and inference flow
   - §6.6 in-flight request lifecycle (SPEC-011 §4.4 drain
     semantics interact here)
   - Single-model-per-process assumption (SPEC-011 L-3 preserves)

7. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on:
   - §3 provider state machine (SPEC-011 §4.3 anticipates a new
     heartbeat `loading: bool` field — is this purely additive
     or does it require a new state machine state?)
   - Heartbeat handling at
     phase4-coordinator/internal/pool/provider.go lines 420-432
   - §11 audit-log namespace (SPEC-011 §4.6 adds ONE event type
     `operator_model_swap`)

8. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md` v0.3 —
   focus on:
   - §5.3-5.6 Pillar A verification pipeline (SPEC-011 §4.5
     claims this re-runs automatically on hash arrival)
   - §5.5 five hash states (SPEC-011 §3 L-4 claims no new state)
   - F-1.5 invariants (SPEC-011 §3 L-6 claims preserved)

9. Code spot-checks:
   - `phase4-coordinator/internal/pool/provider.go` lines 420-432
     (heartbeat-driven ModelID change path — SPEC-011 §4.3
     reuses this)
   - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
     (existing CLI structure — SPEC-011 §4.1 extends)
   - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
     (current synchronous load path — SPEC-011 §4.2 will need to
     add async path alongside)

## Audit categories — work through each

### Category S: Scope-split correctness (HIGHEST PRIORITY)

S.1  Walk §2.1 (IN scope) item by item. For each, verify it is
     NOT already covered by SPEC-010 v1.0. If overlap = CRITICAL
     scope conflict.

S.2  Walk §2.2 (OUT scope, deferred to SPEC-012) item by item.
     For each, verify the outline's §4 anticipated surface does
     NOT smuggle it back in. If smuggled = CRITICAL.

S.3  The most important boundary: SPEC-011 has NO coordinator →
     provider `set_model` message. All swaps are
     operator-initiated on the provider host. Audit §4 for any
     implicit assumption that the coordinator can trigger a
     swap. If found = CRITICAL.

S.4  Verify the dependency direction: SPEC-011 v0.2 depends on
     SPEC-010 v1.0 being locked. Specifically, §4.1 CLI
     validation cites SPEC-010 v1.0 R-3.1.4 — verify R-3.1.4
     actually exists in SPEC-010 v1.0 as cited.

S.5  Cross-check against SPEC-012-source.md: are there features
     in §4.4 (set_model wire), §4.5 (cold-wake routing), §4.6
     (queue bounds), §4.7 (config), §4.10 (state visibility) of
     SPEC-012-source that an honest reader of SPEC-011 outline
     might expect to find in §4 but don't? If any "implied but
     not stated" surface = MAJOR.

### Category C: Cross-spec interactions

C.1  §4.3 heartbeat extension adds optional `loading: bool`.
     Verify locked SPEC-002 §3 state machine treats `loading:
     true` correctly. Is there a state where the existing
     coordinator would interpret a heartbeat with this field
     incorrectly? Spot-check
     phase4-coordinator/internal/pool/provider.go heartbeat
     handler. If misinterpretation possible = MAJOR.

C.2  §4.3 says "no new WS message type." Walk SPEC-002's WS
     message catalog at messages.go lines 8-57. Is there a
     conflict with an existing field name `loading` on any
     message type? If yes = MAJOR.

C.3  §4.5 Pillar A re-verification: claims "SPEC-008 §5.3–5.6
     re-runs on hash arrival." Walk SPEC-008 §5.3 to confirm the
     verification flow auto-triggers on heartbeat-arrival hash
     change, or requires an explicit trigger. If requires
     trigger = MAJOR (SPEC-011 v0.2 needs to add it).

C.4  §4.2 async load + drain semantics: the provider binary
     currently does synchronous load at startup. SPEC-011 §4.2
     claims the async path is added alongside. Spot-check
     phase3-binary/Sources/macprovider-cli/ModelRuntime.swift
     to confirm the existing path is structurally amenable to
     adding an async sibling. If structural rewrite required =
     MAJOR.

C.5  §4.4 drain timeout (default 20s) + per-request 503: identical
     pattern to SPEC-012-source v0.3 R-4.4.6. Reuses the same
     design decision. Verify the outline's reuse is faithful
     and SPEC-011 doesn't accidentally re-introduce the B2.2
     "drain_timeout in failure enum" mistake.

C.6  §4.6 audit-log event `operator_model_swap`: namespace under
     SPEC-002 §11. Does the event-type string conflict with any
     existing event? If yes = MAJOR.

### Category L: Locked-decision consistency

L.1  Walk L-1 through L-7 in §3. For each, verify the anticipated
     §4 surface is mutually consistent.
       - L-1 backward compat: §4.3 heartbeat field default false
         — does any §4 path emit `loading: true` without explicit
         operator action?
       - L-2 operator-initiated only: §4 has no coordinator-side
         swap trigger.
       - L-3 single warm model: during load, provider has zero
         warm models, not two. Verify §4.4 drain semantics
         preserve this.
       - L-4 SPEC-008 trivial: §4.5 re-uses existing pipeline.
       - L-5 no billing: §4 doesn't touch SPEC-005.
       - L-6 F-1.5 preserved: heartbeat extension adds
         `loading`, `model_id`, `model_hash` — none of these
         feed sticky derivation.
       - L-7 no coordinator cooldown config: §4 doesn't add a
         coordinator-side rate-limit knob; CLI handles thrash.

L.2  L-3 single warm model during load: the spec says provider
     has ZERO warm models during the load window. Is "zero" or
     "the old model still serving in-flight requests until
     drain timeout" the correct framing? The two phrasings
     could imply different routing-eligibility windows. If §4.3
     and §4.4 disagree on this = MAJOR.

### Category F: Forward-compatibility with SPEC-012

F.1  Will SPEC-012 (when drafted) be able to reuse SPEC-011's
     binary-side async-load path for coordinator-initiated
     swaps? Or will SPEC-012's `set_model` mechanism require a
     fundamentally different binary contract? If the latter,
     SPEC-011 is wasting work that SPEC-012 will redo = MAJOR.

F.2  SPEC-012 will add the §4.10-equivalent `state` field on
     `/v1/status` that surfaces `loading`. Will SPEC-011's
     heartbeat `loading: bool` field be the source for that
     SPEC-012 field, or will SPEC-012 need a different
     mechanism? If SPEC-011's primitive is unusable for SPEC-012
     = MAJOR (forward-compat broken).

### Category A: Anticipated AC + audit footprint realism

A.1  §5 estimates "10-12 ACs." Given §4's surface
     (CLI subcommands × 3 + async load + drain + heartbeat
     extension + Pillar A re-verification + audit-log event +
     L-1 back-compat), is 10-12 realistic? If clearly more is
     needed = MAJOR (outline understates scope).

A.2  §6 estimates "1-2 audit rounds to lock." Compare against
     SPEC-008's 3-round audit and SPEC-012-source's 3-round
     non-convergence. Is 1-2 plausible for this surface? If
     clearly more rounds needed = MAJOR (split was not narrow
     enough).

A.3  Hidden surface check: walk SPEC-012-source v0.3 to see if
     there are wire/error/state surfaces SPEC-011 will need
     but doesn't anticipate. Specifically check:
       - In-process signaling mechanism CLI → running provider
         (§8 OQ-1)
       - Heartbeat cadence during long async loads (provider
         can't send heartbeats during synchronous-blocking work)
       - Error envelope for `provider_loading` 503 (§4.2
         mentions it but doesn't specify shape)
       - Race conditions between operator `models switch` and
         already-in-flight `models switch`

### Category Q: OQ quality

Q.1  §8 has 4 OQs. Are they the right ones? Specifically:
       - OQ-1 (CLI ↔ process signaling): this is a real
         pre-draft choice; reasonable.
       - OQ-2 (block vs background): UX choice; reasonable.
       - OQ-3 (CLI cooldown): probably belongs in v0.2 spec, not
         OQ. Document the decision in §4.
       - OQ-4 (`loading` carrying target model_id): observability
         vs surface; reasonable.
     If any OQ is actually a hidden CRITICAL/MAJOR = file in
     appropriate category.

Q.2  Walk §4 anticipated surface for OQs the outline silently
     glosses over. Examples to check:
       - What if the operator invokes `models switch X` while
         provider is already loading Y? Outline doesn't say.
       - What if the WS connection drops mid-load? Does the
         provider abort the load or finish and reconnect?
       - What about hash verification under `tier2.require_
         hash_verified: true` if the new model is uncatalogued?

### Category H: Hygiene

H.1  Outline self-consistency. Does §3 (locked decisions) match
     §4 (anticipated surface)? Does §6 (audit footprint
     estimate) match §5 (AC count)?

H.2  References to SPEC-010 v1.0: do the §-numbers cited
     (R-3.1.4) actually exist in SPEC-010 v1.0?

H.3  References to SPEC-012-source: does the outline correctly
     identify what SPEC-012 will house?

## Output structure

Write a NEW file at
`/Users/augstar/macprovider-poc/specs/SPEC-011-outline-audit.md`
with frontmatter:

```
# SPEC-011 v0.1 outline — Audit Report (pre-draft scope review)

**Audited:** SPEC-011 v0.1 outline
(specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N (outline pre-draft pass)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

**Sibling audits:**
- specs/SPEC-010-audit.md — SPEC-010 v1.0 round 1 (parallel)
- specs/SPEC-012-source-audit-history.md — wide-scope predecessor

---

## Executive summary

[2-4 paragraphs. State whether the outline is ready for v0.2
normative drafting, ready with the CRITICAL/MAJOR findings
addressed, or needs re-scoping. Specifically comment on whether
the §6 estimate of "1-2 audit rounds to lock" is plausible given
the outline as written.]
```

Then for each category S, C, L, F, A, Q, H, write a section. For
each finding:

```
### S.2  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §4.3, line ~XXX

[What. 1-3 sentences.]

[Why it matters. 1-3 sentences. Specifically: how would this
trip up v0.2 drafting or audit?]

[Recommendation. 1-2 sentences. For scope-overlap findings, name
which spec (SPEC-010 v1.0 / SPEC-012) actually owns the surface.]
```

If a category has zero findings, write `(no findings)`.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Drafting SPEC-011 v0.2 (this is pre-draft review)
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-010 v1.0 (parallel audit)
- Grading SPEC-011 outline against normative-spec standards
  (R-rule count, AC enumeration, wire example completeness —
  those come in v0.2)

## Done criteria

You are done when:

- /Users/augstar/macprovider-poc/specs/SPEC-011-outline-audit.md
  exists as a NEW file
- Every category S, C, L, F, A, Q, H has a section (even if
  "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Executive summary states a clear "ready for v0.2 drafting" /
  "ready after these CRITICAL/MAJOR" / "needs re-scoping"
  verdict
- §6's "1-2 audit rounds to lock" estimate is independently
  evaluated as plausible / optimistic / unrealistic with
  justification

=== END PROMPT ===
```

---

## Operator notes

- Runs in parallel with SPEC-010 v1.0 round 1.
- Expected wall-clock: 15-25 min Codex (smaller surface than a
  full normative audit).
- Expected outcome: 0-1 CRITICAL, 2-4 MAJOR is fine for an
  outline at this stage. CRITICALs would indicate the split
  itself has a problem and we should re-discuss.
- Decision after both audits land:
  - If SPEC-010 v1.0 and SPEC-011 outline both come back clean:
    lock SPEC-010 v1.0, draft SPEC-011 v0.2 normative.
  - If SPEC-011 outline reveals scope-split problems: re-scope
    before drafting v0.2.
