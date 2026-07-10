# Audit prompt — SPEC-011 v0.1.1 outline (round 2)

Operator-paste prompt to audit SPEC-011 v0.1.1 outline
(`specs/SPEC-011-operator-pushed-warm-swap.md`).

**Round 2 of outline audit.** Round 1 (Codex GPT-5 on v0.1
outline) found 0 CRITICAL / 6 MAJOR / 1 MINOR / 1 QUESTION at
`specs/SPEC-011-outline-audit.md`. v0.1.1 is the outline fix
pass that claims to close all 8 findings: C.3, C.4, C.5, L.2,
A.1, Q.2, H.2 fixed; Q.3 decided.

Round 2 has two jobs:

1. **Round-1 fix verification (R1V)** — for each round-1
   finding v0.1.1 claims to close, cite the v0.1.1
   section/text and mark PASS / PARTIAL / FAIL.
2. **Audit the v0.1.1-new outline surface** —
   the binary state machine in §4.2 (added per C.5), the
   no-starve rule (added per C.4), the heartbeat `model_hash`
   field + re-verification trigger in §4.3 (added per C.3),
   §4.7 concurrent switch (added per Q.2), §4.8 WS drop policy
   (added per Q.3), and the expanded §5 AC plan (16 ACs).

The round-1 prompt (`specs/AUDIT_SPEC_011_OUTLINE_PROMPT.md`)
is background; this is the active prompt for v0.1.1.

Append round-2 findings to the existing
`specs/SPEC-011-outline-audit.md` file as a new top-level
section after the round-1 report. Do not overwrite round 1.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT ===`
into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-011 v0.1.1 outline at
/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-
warm-swap.md. This is round 2 of the OUTLINE audit (still
pre-normative-draft; v0.2 will be the normative draft).

Round 1 produced /Users/augstar/macprovider-poc/specs/SPEC-011-
outline-audit.md with 0 CRITICAL / 6 MAJOR / 1 MINOR / 1
QUESTION findings on v0.1. v0.1.1 is the outline fix pass that
claims to close all 8 findings:
- C.3 (heartbeat hash re-verification path)
- C.4 (async load must preserve heartbeat cadence)
- C.5 (current runtime requires mutable-state refactor)
- L.2 ("zero warm models" conflict with in-flight drain)
- A.1 (10-12 ACs understates v0.2 surface)
- Q.2 (concurrent switch race is a hidden OQ)
- Q.3 (WS drop mid-load needs a stated policy)
- H.2 (CLI name and SPEC-010 validation citation)

You are NOT here to validate, rewrite, or extend the outline.
Two explicit jobs:

  J-1. **Round-1 fix verification (R1V).** For each round-1
       finding v0.1.1 claims to close, cite the specific v0.1.1
       section/text that closes it. Mark PASS / PARTIAL / FAIL.
       Findings whose fix introduces a NEW problem = file a
       new round-2 finding AND mark PARTIAL in R1V.

  J-2. **Audit the v0.1.1-new outline surface.** Specifically:
       - §4.2 binary state machine (ready/loading/draining/
         failed) with atomic swap contract
       - §4.2 no-starve rule (async load MUST NOT block WS
         loops)
       - §4.3 NEW heartbeat `model_hash` field
       - §4.3 NEW coordinator rule for hash re-verification
         trigger
       - §4.6 expanded `operator_model_swap` payload schema
       - §4.7 concurrent switch policy (exit code 3,
         deterministic rejection)
       - §4.8 WS drop mid-load policy (finish load,
         reconnect, conditional audit emission)
       - §5 expanded AC plan (16 anticipated ACs)
       - Updated §6 audit footprint reasoning

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-011-outline-audit.md

APPEND a new top-level section to the existing file:
  `## Round 2 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings. Do NOT touch the
round-1 section.

## Severity definitions

Unchanged from round 1 (adapted for outline audit):
- **CRITICAL** — structural problem that would force a major
  rewrite of v0.2 mid-draft. Scope creep into SPEC-010/SPEC-012
  is CRITICAL.
- **MAJOR** — missing anticipated surface that v0.2 will need
  but won't be able to add without re-scoping. Hidden cross-
  spec dependency. Missing OQ the outline silently glosses
  over.
- **MINOR** — outline quality. Naming, organization, forward-
  refs.
- **QUESTION** — pre-draft design choice unresolved; OK to
  defer to v0.2 drafting.

## Critical constraints

**1. Scope-creep recommendations are CRITICAL findings.** The
split rationale lives or dies on no overlap with SPEC-010
v1.0/v1.x or SPEC-012. Verify v0.1.1's new sections didn't
accidentally pull in `set_model` wire, cold-wake routing,
`/v1/models` aggregation, or buyer-facing visibility.

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
v0.3 are LOCKED.** v0.1.1 anticipates SPEC-001 v1.3 and SPEC-002
v1.3.5 candidates. Verify those candidate changes are truly
additive.

**3. The binary state machine in §4.2 is the highest-risk new
surface.** It implies a Swift `ModelRuntime` refactor. Spot-
check the actual Swift code to confirm the proposed mutable-
state contract is implementable against the existing actor
isolation. If §4.2's atomic-swap design fights the Swift actor
model = MAJOR.

**4. Clean-room.** Do NOT inspect d-inference source.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-011-operator-pushed-warm-swap.md`
   v0.1.1 — the outline under audit. Read the v0.1.1 change
   log first to map fixes to sections. Then read §4.2 (state
   machine; biggest delta), §4.3 (heartbeat extension + re-
   verification rule), §4.6 (event payload), §4.7, §4.8, §5
   (AC plan) carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-011-outline-audit.md`
   — round-1 findings. R1V target.

3. `/Users/augstar/macprovider-poc/specs/AUDIT_SPEC_011_OUTLINE_PROMPT.md`
   — round-1 prompt. Background only.

4. `/Users/augstar/macprovider-poc/CLAUDE.md` — project
   conventions.

5. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v1.x — verify v0.1.1's SPEC-010 citations (R-3.6.3,
   R-3.1.4) point to the actual rules.

6. `/Users/augstar/macprovider-poc/specs/SPEC-012-source.md`
   — to confirm no SPEC-011 v0.1.1 surface was lifted from
   SPEC-012's territory.

7. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on:
   - §6.5 auth handshake (does v0.1.1's `model_hash` heartbeat
     field rule fit additively?)
   - §6.6 in-flight request lifecycle (does §4.2 draining
     state composes correctly?)

8. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on:
   - §3 provider state machine (v0.1.1 §4.2 introduces binary-
     local sub-states; verify they don't conflict with §3
     coordinator-side states)
   - §7.1 provider WS protocol (heartbeat shape — v0.1.1 adds
     `loading: bool` and `model_hash: string`)
   - §11 audit-log (§4.6 `operator_model_swap` payload)
   - §11 J.1 heartbeat-starvation lesson (v0.1.1 §4.2 cites)

9. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md`
   v0.3 — focus on:
   - §5.3-5.6 Pillar A verification pipeline (v0.1.1 §4.3 rule
     claims this re-runs on heartbeat hash change)
   - §5.5 five hash states (v0.1.1 claims no new state)

10. Code spot-checks:
    - `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift`
      lines 25-68, 86-147 (Swift actor + immutable `let`
      fields — §4.2 refactor target)
    - `phase4-coordinator/internal/pool/provider.go` lines
      420-432 (heartbeat handler — §4.3 coordinator rule
      replaces this)
    - `phase4-coordinator/internal/ws/messages.go` heartbeat
      struct (verify `model_hash` field doesn't exist today,
      §4.3 needs to ADD it)
    - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
      lines 7-15 (existing subcommands — §4.1 adds `models`
      alongside)

## Audit categories — work through each

### Category R1V: Round-1 fix verification (HIGHEST PRIORITY)

Output as a table. Mark PASS / PARTIAL / FAIL with v0.1.1
location verified and 1-sentence evidence.

- **R1V-C.3** (heartbeat hash re-verification path) → §4.3
  NEW `model_hash` field + coordinator rule
- **R1V-C.4** (async load must preserve heartbeat) → §4.2
  no-starve rule
- **R1V-C.5** (mutable-state runtime refactor) → §4.2 state
  machine + atomic-swap contract
- **R1V-L.2** ("zero warm models" conflict) → §3 L-3
  rephrased
- **R1V-A.1** (10-12 ACs understates surface) → §5 expanded
  to 16 ACs
- **R1V-Q.2** (concurrent switch hidden OQ) → §4.7 concurrent
  switch policy
- **R1V-Q.3** (WS drop mid-load policy) → §4.8 WS drop policy
- **R1V-H.2** (CLI name + SPEC-010 citation) → §4.1
  `macprovider-cli` + §2.1 R-3.6.3 citation

### Category S2: Scope-split correctness (v0.1.1 re-verification)

S2.1  Walk §4.2 state machine, §4.3 heartbeat additions, §4.6
      audit payload, §4.7 concurrent-switch, §4.8 WS-drop. For
      each, verify NO smuggling of SPEC-012 features (no
      coordinator-initiated `set_model`, no cold-wake queue,
      no `/v1/models` aggregation, no buyer-facing
      visibility). If smuggled = CRITICAL.

S2.2  §4.3 NEW coordinator rule for hash re-verification on
      heartbeat (model_id, model_hash) change: is this still
      "coordinator passively observes operator-pushed swap,"
      or did it become "coordinator actively manages swap
      state"? The latter would creep into SPEC-012. Audit the
      framing.

### Category B2: Binary state machine + atomic swap (v0.1.1 §4.2)

B2.1  Walk §4.2 state diagram. Are state transitions complete?
      What happens if WS disconnects in `failed` state? What
      if a second `models switch` arrives in `draining`
      state (per §4.7, code 3 — but does §4.2 align)?

B2.2  Atomic-swap contract: "atomically swappable" reference.
      Swift's actor isolation doesn't have lock-free CAS
      semantics for arbitrary references; the typical idiom is
      actor-isolated `var` with `await` access. Does §4.2's
      atomic-swap claim compose with the Swift actor model?
      Spot-check
      phase3-binary/Sources/macprovider-cli/ModelRuntime.swift.
      If §4.2 implies a non-actor primitive = MAJOR.

B2.3  Inference snapshot rule: "snapshot `current_container`
      at request start; in-flight requests use their snapshot
      until completion." For the existing Swift inference path,
      where is the per-request snapshot taken? If the existing
      path holds an actor reference for the full request,
      snapshotting requires a structural change beyond the
      `let → var` swap. Note depth of refactor.

B2.4  `loaded` vs `draining` distinction: §4.2 says after load
      success, state goes through `draining` (where new
      container exists but atomic swap is gated on drain). Is
      this a binary-local concept that ever surfaces over the
      wire? Or only internal? If externally observable, it
      needs a heartbeat field. If purely internal, fine.

### Category H2: Heartbeat re-verification rule (v0.1.1 §4.3)

H2.1  §4.3 says "coordinator MUST update Provider.ModelHash to
      the new value (current path CLEARS it; v0.2 must replace
      this)." This is a replacement of existing locked behavior
      in SPEC-002 / current code. Is this a normative edit to
      SPEC-002, or is it always-additive? The current behavior
      clears hash → SPEC-011 changes it to populate. That's
      a behavior change, not an addition. Should this be
      flagged as a SPEC-002 v1.3.5 candidate normative edit
      (NOT just additive)?

H2.2  Heartbeat `model_hash` field absence (legacy provider):
      §4.3 says "preserves L-1 backward compat for legacy
      providers." Verify: a legacy provider that changes
      `model_id` mid-session (operator restarts with new
      `--model`) — does the existing
      `HashStatusUncatalogued`-clearing behavior still fire?
      If yes = PASS. If the §4.3 path silently disables it
      for legacy providers = MAJOR.

H2.3  `tier2.require_hash_verified: true`: §4.3 says
      "provider's HashStatus is set to the appropriate failure
      state ... provider remains routing-ineligible." Verify
      this matches SPEC-008 §5.6 routing-predicate behavior
      exactly. If §4.3 invents a slightly different rejection
      semantics = MAJOR.

### Category C2: Concurrent switch + WS drop (§4.7, §4.8)

C2.1  §4.7 exit code 3 + stable diagnostic. Is the exit code
      space coherent with §4.1's enumeration (0/2/3/4/5)? Is
      code 3 used anywhere else?

C2.2  §4.7 "previously-queued switch to X is NOT auto-retried":
      good — bounds local state. Operator must reissue. Does
      §4.7 say what the CLI's `--queue-after-current` future
      flag would do? Or is that just a v0.2 hint? If hinted
      but not specified, is that a v0.2 surface to anticipate
      = MINOR.

C2.3  §4.8 reconnect-after-load-completes path: "post-
      reconnect handshake (`auth_request` re-issued per
      SPEC-002) carries the FINAL model_id and model_hash."
      Is the `auth_request` post-disconnect re-issue a
      well-defined SPEC-002 flow? Spot-check SPEC-002 §7.1 or
      §3 state machine for reconnect semantics. If
      reconnection doesn't actually re-run `auth_request` =
      MAJOR (§4.8 makes a wrong assumption).

C2.4  §4.8 conditional `operator_model_swap` emission: rule
      is "emitted only when coordinator observed loading
      window." This means the SAME swap on a different
      session could either emit or not emit the audit event
      depending on disconnect timing. Audit-log readers might
      see "the swap happened but no event was logged" for
      drop-mid-load cases. Is this acceptable, or should v0.2
      add a backfill mechanism? If the gap is operator-
      hostile = MAJOR; if acceptable = QUESTION.

### Category A2: AC plan realism (v0.1.1 §5)

A2.1  §5 lists 16 ACs across 8 buckets. Walk each bucket and
      verify the AC count is realistic for the surface:
      - 4 CLI ACs: list/switch/pre-flight/status — looks right
      - 4 async load ACs: happy/fail/drain-timeout/snapshot —
        looks right
      - 3 heartbeat ACs: new model_hash, loading=true,
        no-starve — looks right
      - 2 Pillar A ACs: re-verification, require_hash_verified
        — looks right
      - 1 concurrent switch AC: §4.7 path — narrow but
        sufficient
      - 2 WS drop ACs: drop-after-load, drop-during-load —
        looks right
      - 3 back-compat ACs: byte-identical, legacy heartbeat,
        legacy coordinator — looks right
      - 1 audit-log AC: operator_model_swap payload — sufficient
      Total: 20 in listing, but text says 16 — discrepancy?
      Re-count actual bullets.

A2.2  §5 says "Total: 16 ACs" but the bucket counts I see add
      to 4+4+3+2+1+2+3+1 = 20. Re-count and report. If the
      total is misstated = MINOR.

A2.3  Missing AC: is there an AC for §4.2 `loaded` →
      `draining` transition (i.e. swap is gated on drain
      completion)? Or is this covered by the "snapshot" AC? If
      not covered = MINOR.

### Category F2: Forward-compatibility with SPEC-012

F2.1  Will SPEC-012's `set_model` wire (when drafted) be able
      to reuse SPEC-011's §4.2 state machine? SPEC-012 will
      need the same state transitions but triggered by a WS
      message instead of CLI signal. v0.1.1 §4.2 says the
      startup-time synchronous load is a third path. Will
      SPEC-012's coordinator-initiated swap fit as a fourth
      trigger to the same state machine, or does it require a
      different state design?

F2.2  Will SPEC-012's `/v1/status.state` field (when drafted)
      be derivable from §4.3's `loading: bool` heartbeat?
      v0.1.1 §4.3 says routing-ineligibility comes from the
      same path as existing non-Ready providers, but SPEC-012
      will want operator-visible amber state. If the SPEC-011
      primitive doesn't support that = MAJOR forward-compat.

### Category D2: Companion-spec annotations (v0.1.1)

D2.1  §4.3 "coordinator MUST update Provider.ModelHash to the
      new value (current path CLEARS it; v0.2 must replace
      this)." — this is a behavior REPLACEMENT in SPEC-002,
      not additive. The outline doesn't flag this as a
      candidate normative edit to SPEC-002. Is the v0.2
      normative draft supposed to make this clear? If left
      implicit, audit it as MAJOR. SPEC-002 v1.3.5 candidate
      should explicitly call out: "current §X behavior of
      clearing ModelHash on model_id change is REPLACED by
      ..."

D2.2  Are there other implicit SPEC-002 v1.3.5 normative-edit
      surfaces in v0.1.1? Walk §4.2 (state machine surfaces),
      §4.3 (heartbeat extension), §4.6 (audit event). For
      each, flag whether it's additive or replacement.

### Category E2: Anything else

E2.1  Documentation drift checks: HANDOFF.md, RUNBOOK.md,
      CONTINUE_RUNBOOK.md, AGENTS.md.

E2.2  Naming nits.

E2.3  Hidden OQs the v0.1.1 outline silently glosses over.

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-011-
outline-audit.md`. Start with:

```
---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-011 v0.1.1 outline
(specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N (outline pre-draft pass)
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-2 executive summary

[2-3 paragraphs. State whether v0.1.1 is ready for v0.2
normative drafting, ready after the round-2 findings are
addressed in v0.2 plan, or needs further outline iteration.]

### Round-1 fix verification (R1V)

[Table: round-1 finding ID, PASS / PARTIAL / FAIL, v0.1.1
location verified, 1-sentence evidence.]
```

Then for each category R1V, S2, B2, H2, C2, A2, F2, D2, E2:
write a section. For each finding: severity, location,
what/why/recommendation.

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source (NOASSERTION license)
- Drafting SPEC-011 v0.2 (still pre-draft)
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-010 v1.1 (separate cycle)
- Grading v0.1.1 as a normative spec (it's still an outline)

## Done criteria

You are done when:

- Round-2 section APPENDED to SPEC-011-outline-audit.md
  (round 1 intact)
- Every round-1 finding has PASS / PARTIAL / FAIL in R1V
- Every category R1V, S2, B2, H2, C2, A2, F2, D2, E2 has a
  section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Round-2 executive summary states a clear verdict on whether
  v0.2 normative drafting can proceed

=== END PROMPT ===
```

---

## Operator notes

- Expected wall-clock: 15-25 min (small surface increment to
  audit).
- Decision after round 2:
  - 0 CRITICAL / 0-2 MAJOR → outline is ready; start SPEC-011
    v0.2 normative draft
  - ≥1 CRITICAL or >2 MAJOR → another outline iteration
    (v0.1.2) before drafting v0.2
