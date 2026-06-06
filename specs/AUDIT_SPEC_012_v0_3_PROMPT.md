# Audit prompt — SPEC-010 v0.3 (round 3)

Operator-paste prompt to audit SPEC-010 v0.3
(`specs/SPEC-010-model-catalog.md`).

**Round 3.** Round 1 (Codex GPT-5 on v0.1) found 2 CRITICAL / 9
MAJOR / 3 MINOR / 2 QUESTION. Round 2 (Codex GPT-5 on v0.2) found
0 CRITICAL / 12 MAJOR / 1 MINOR / 1 QUESTION and verified 10 of 12
round-1 fixes as PASS, 2 as PARTIAL (B3, I1). v0.3 is a
**contract-tightening pass**, not a restructure: closes all 12
round-2 MAJORs + the 2 PARTIALs + the 1 QUESTION.

Round 3 has two jobs:

1. **Round-2 fix verification (R2V)** — for each round-2 finding
   that v0.3 claims to fix, cite the v0.3 rule/AC and mark PASS /
   PARTIAL / FAIL.
2. **Newly normative surface audit** — v0.3 added §4.4.0 (request_id
   format), R-4.1.9 (validation order), R-4.4.9 (audit event payload
   schemas), R-4.5.3.7 (cold-wake billing), R-4.5.3.8 (queue bounds),
   R-4.6.1.4 (Pillar A interaction for cold entries), §4.10 (provider
   state visibility), and 12 new ACs (AC-24 through AC-35). Audit
   these for the same failure modes that produced round-2 findings.

The round-2 prompt (`specs/AUDIT_SPEC_010_V0_2_PROMPT.md`) and the
round-1 prompt (`specs/AUDIT_SPEC_010_PROMPT.md`) are background;
this is the active prompt for v0.3.

Append round-3 findings to the same file
(`specs/SPEC-010-audit.md`) as a new top-level section after the
round-2 report. Do not overwrite either prior round.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT
===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v0.3, the Provider Model Catalog & Warm
Swap spec at /Users/augstar/macprovider-poc/specs/SPEC-010-model-
catalog.md. This is round 3 of the audit.

Prior rounds produced /Users/augstar/macprovider-poc/specs/SPEC-010-
audit.md:
  - Round 1 (v0.1): 2 CRITICAL / 9 MAJOR / 3 MINOR / 2 QUESTION
  - Round 2 (v0.2): 0 CRITICAL / 12 MAJOR / 1 MINOR / 1 QUESTION
v0.3 claims to fix all 12 round-2 MAJORs + the 2 PARTIAL completions
(B3, I1) + the 1 QUESTION (B2.3 / OQ-5).

You are NOT here to validate, rewrite, or extend the spec. Two
explicit jobs:

  J-1. **Round-2 fix verification (R2V).** For each round-2 finding
       v0.3 claims to fix, cite the specific v0.3 rule/section that
       closes it. Findings whose fix is incomplete = file a new
       round-3 finding in the appropriate category AND mark PARTIAL
       in R2V.

  J-2. **Audit the v0.3-new normative surface.** Specifically:
       - §4.1 R-4.1.9 validation order (5-step ordered list with
         exact reason strings)
       - §4.4 R-4.4.0 request_id format and retention
       - §4.4 R-4.4.6 (rewritten): drain timeout = per-request only,
         removed from failure enum
       - §4.4 R-4.4.8: swap_reason enum reduced to 2 values
       - §4.4 R-4.4.9: full audit event payload schemas for 5 event
         types
       - §4.5.3.7 cold-wake billing/request-log isolation
       - §4.5.3.8 parked-queue bounds (3 caps)
       - §4.6.1.4 Pillar A interaction for cold-supported /v1/models
         entries
       - §4.7 retuned defaults (drain 20s, ETA 90s) + new configs
         for queue bounds and request_id retention
       - §4.10 provider state visibility (`state` enum, gating,
         `swap_pending_since`)
       - §8.1 SPEC-001 v1.2.5 candidate now incorporates §4.4/§4.8/
         §4.10 by explicit reference
       - 12 new ACs (AC-24 through AC-35)

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

APPEND a new top-level section to the existing file:
  `## Round 3 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings (same structure as rounds 1
and 2). Do NOT touch the round-1 or round-2 sections. Do NOT change
their verdicts.

## Severity definitions

Unchanged from rounds 1-2:
- **CRITICAL** — production failure on Phase 1 rollout, silent
  regression of locked-spec behavior, scope creep into a locked
  upstream spec (SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1,
  SPEC-008 v0.3), security regression, violation of L-1..L-6.
- **MAJOR** — significant implementer confusion, predictable v0.4
  patch, unjustified thresholds, ambiguous failure semantics,
  back-compat that doesn't hold up.
- **MINOR** — quality issues; don't block v0.3.
- **QUESTION** — unresolved design choice.

## Critical constraints to honor while auditing

**1. Locked decisions (§2 L-1 through L-6) are READ-ONLY.** Same as
rounds 1-2.

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
v0.3 are LOCKED.** Any v0.3 clause requiring a normative edit to
one of these is CRITICAL scope creep. v0.3 §8.1 now explicitly
incorporates §4.4 / §4.8 / §4.10 as normative source for the
SPEC-001 v1.2.5 BUILD prompt — verify this works structurally
without leaking SPEC-010 commitments into SPEC-001 v1.2.4 itself.

**3. v0.3 carve-out for L-1 byte-identical.** With
`publish_unwarm_models: false` AND `cold_wake_enabled: false` AND
no SPEC-010 fields sent by any provider AND the new `state` field
in §4.10 omitted per R-4.10.2 (no provider has transitioned through
swap), coordinator behavior MUST be byte-identical to pre-SPEC-010.
The R-4.10.2 gating rule is new and load-bearing — verify it
actually preserves L-1.

**4. SPEC-008 F-1.5 invariants MUST be preserved (L-6).** Walk the
new R-4.4.9 audit event payload schemas (5 event types) for any
field that could feed sticky derivation, expose conv:, hand sticky
lifecycle to a provider, or extend sticky TTL. The events live on
the coordinator side, not the provider side, but they ARE persisted
to the SPEC-002 §11 audit-log namespace which has its own
redaction rules.

**5. Pillar A hash semantics bound to loaded_model only (L-4).**
v0.3 §4.6.1.4 explicitly excludes cold-supported entries from
SPEC-008 §5.7 hash blocks. Verify this rule actually prevents
hash-state leakage to cold entries everywhere it could leak, not
just /v1/models. Spot-check `seenModels` index (R-4.3.4) and
coordinator-internal data structures.

**6. Billing isolation (C2.1 fix).** v0.3 §4.5.3.7 says cold-wake
attempts are NOT billable inference attempts and MUST NOT write
SPEC-005 X-2 request_log rows. Verify this is implementable against
the actual SPEC-005 schema and that the spec is precise about who
DOES write the row (the eventual successful dispatch, or the
final 503).

**7. Queue-bound denial-of-service safety (C2.2 fix).** v0.3
§4.5.3.8 introduces 3 cap layers (per-swap, per-account, global).
Verify all three are actually checked in the right order; verify
overflow behavior is deterministic (immediate 503, never silent
drop); verify per-account counting interacts correctly with
SPEC-005 multi-account semantics.

**8. Clean-room.** Do NOT inspect d-inference (layr-labs) source.
NOASSERTION license.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v0.3 — the spec under audit. Read the v0.3 change log at the
   top FIRST to map fixes to sections. Then read §4.1, §4.4, §4.5,
   §4.6, §4.7, §4.10, §8.1, §9 (especially AC-24 through AC-35),
   and §10 (closed/open OQs) carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md` —
   rounds 1 and 2. Your R2V section requires reading every round-2
   finding (search for `### A2`, `### B2.`, `### C2.`, `### D2`,
   `### E2.`, `### F2.`, `### G2.`, `### H2.`, `### I2`). Round-1
   findings are background; don't re-litigate them unless v0.3
   introduces a regression.

3. `/Users/augstar/macprovider-poc/specs/AUDIT_SPEC_010_V0_2_PROMPT.md`
   — the round-2 prompt. Background only; this is the v0.3 active
   prompt.

4. `/Users/augstar/macprovider-poc/CLAUDE.md` — project conventions.

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on §6.1 /v1/models, §6.2 CLI shape.

6. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on §3 state machine (loading/swap_pending
   sub-states), §5 routing, §7.2 auth, §11 audit-log namespace and
   redaction rules.

7. `/Users/augstar/macprovider-poc/specs/SPEC-004-smart-router.md`
   v0.3.1 — focus on §4 sticky-affinity.

8. `/Users/augstar/macprovider-poc/specs/SPEC-005-billing.md` —
   focus on §3 attempt accounting and the X-2 request_log schema.
   v0.3 §4.5.3.7 makes specific claims about SPEC-005 ledger
   semantics; verify they match. If SPEC-005 X-2 doesn't exist or
   has different schema = MAJOR.

9. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md` v0.3 —
   focus on §5.5 hash state enumeration, §5.7 /v1/models hash
   block, §2 F-1.5 invariants.

10. `/Users/augstar/macprovider-poc/specs/SPEC-006-buyer-api.md`
    v0.8.1 — F-1.5 redaction rules (cited in v0.3 R-4.4.9).

11. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md` —
    Entries 21, 35.

12. Code spot-checks:
    - `phase4-coordinator/internal/ws/messages.go` lines 8-57
    - `phase4-coordinator/internal/pool/provider.go` lines 50-88,
      174, 420-432, 464-477
    - `phase5-gateway/internal/router/server.go` lines 143, 461-479,
      1309
    - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
      lines 18-28
    - `phase4-coordinator/internal/buyer/server.go` lines 1027-1030,
      2200-2206 (per round-2 D2 finding)

## Audit categories — work through each

### Category R2V: Round-2 fix verification (HIGHEST PRIORITY)

For each round-2 finding, verify v0.3 closure. Output as a table.
Mark PASS / PARTIAL / FAIL with v0.3 location verified and 1-sentence
evidence.

Round-2 findings to verify:

- **R2V-B2.1** request_id format example-only → v0.3 R-4.4.0
- **R2V-B2.2** drain_timeout in failure enum conflicts with R-4.4.6
  → v0.3 R-4.4.6 (rewritten) + failure enum sans `drain_timeout`
- **R2V-B2.3** swap_reason "policy" undecided → v0.3 R-4.4.8 enum
  reduced to two values; OQ-5 closed in §10
- **R2V-C2.1** cold-wake retry billing semantics undefined → v0.3
  R-4.5.3.7 + AC-35
- **R2V-C2.2** parked-request queue unbounded → v0.3 R-4.5.3.8 +
  §4.7 configs + AC-33, AC-34
- **R2V-C2.3** default timing leaves no retry budget → v0.3 §4.7
  retuned defaults + R-4.7.3
- **R2V-E2.1** SPEC-008 /v1/models hash block undefined for cold
  entries → v0.3 R-4.6.1.4
- **R2V-F2.1** Phase 1 still overclaims pain #3 → v0.3 §3 pain-point
  table now qualifies #3 as opt-in
- **R2V-F2.2** "no red dashboard" assertion in AC-22 lacks coord
  support → v0.3 §4.10 + R-4.10.4 + AC-22 (updated)
- **R2V-G2.1** new R-4 rule coverage gaps → v0.3 AC-24 through AC-30
- **R2V-G2.2** cooldown rejection branch lacks AC → v0.3 AC-31
- **R2V-G2.3** audit-log event payloads missing → v0.3 R-4.4.9
  (expanded) + AC-32
- **R2V-H2.1** SPEC-001 candidate not implementable from §8.1 alone
  → v0.3 §8.1 (rewritten with explicit normative-source references)
- **R2V-H2.2** swap audit event payloads undefined → R2V-G2.3 (same
  fix)
- **R2V-B3 (PARTIAL from round 1)** length cap normalization →
  v0.3 R-4.1.9 (5-step validation order with exact reason strings)
- **R2V-I1 (PARTIAL from round 1)** Phase 1 closes canary → v0.3 §3
  pain-point table qualifies #3
- **R2V-C2.3 (MINOR)** → v0.3 §4.7 + R-4.7.3 documents the retry
  budget

Status notes (no fix expected):
- OQ-2 and OQ-4 remain open in v0.3 §10 by design

### Category A3: Locked-decision preservation (v0.3 re-verification)

A3.1 R-4.10.2 gating rule for the new `state` field: with no
     provider ever swapping, the field MUST NOT appear. Verify this
     genuinely preserves L-1 byte-identical, especially across
     coordinator restarts (does the gating reset?).

A3.2 R-4.4.9 audit-log payloads: walk every field in the 5 event
     schemas. None may contain `conv:`, raw `account_id`, buyer
     prompt text, or any input that could feed sticky derivation.
     R-4.4.9 ends with a SPEC-006 §F-1.5 reference — verify it's
     enforced field-by-field, not just asserted at the bottom.

A3.3 §4.5.3.7 billing isolation: confirm cold-wake activity NEVER
     touches SPEC-005 X-2 `request_log` rows, NEVER increments
     SPEC-004 `provider_retry_attempts`, and NEVER triggers
     SPEC-005 settlement. If any path could leak = CRITICAL.

A3.4 §4.6.1.4 Pillar A interaction: walk §4.5 (router), §4.6
     (gateway), §4.3 (provider struct) for any other surface where
     cold-supported entries could pick up hash status implicitly.
     If yes = MAJOR.

A3.5 L-3 one *active* model: §4.10's `state: "loading"` makes
     `loading_model` operator-visible. Does this accidentally
     advertise the provider as multi-model? Verify §4.10 phrasing
     explicitly says the provider is unavailable for routing
     during loading.

### Category B3: Wire-format correctness (v0.3 new fields)

B3.1 R-4.4.0 request_id format: Crockford base32 ULID is a strong
     uniqueness guarantee but is it ALSO the format SPEC-001 uses
     for `req_<ULID>`? Verify the two namespaces are clearly
     distinguishable beyond the prefix. If a parser misroutes a
     swap response as a buyer response due to ID-shape collision
     = MAJOR.

B3.2 R-4.4.0 retention window: 600s default. Is there any path
     where a `set_model_complete` could arrive >600s after the
     `set_model` was issued? (e.g. provider on a long load with
     temporary network partition.) If yes, the message would be
     dropped — verify the spec accepts this tradeoff.

B3.3 R-4.1.9 validation order: 5-step list with exact reason
     strings. Walk each step and verify the reason string is
     unambiguous. Are reason strings stable across coordinator
     versions (i.e. operators/test suites can grep for them)? If
     not = MINOR.

B3.4 R-4.1.9 step 4 duplicate check: "After normalization,
     duplicate entries MUST cause bad_request." Does this also
     apply when the duplicate is between `model_id` and a
     `supported_models` entry (e.g. they normalize to the same
     value but `model_id` was an explicit duplicate)? The rule
     focuses on dup WITHIN supported_models; the cross-field
     containment check is R-4.1.4. Verify they don't accidentally
     reject a valid case.

B3.5 R-4.4.6 drain_timeout: now NOT in failure enum. Verify the
     ack/complete examples and the prose are consistent — no
     residual mention of `drain_timeout` as a failure reason.

B3.6 R-4.4.9 event payload `failure_stage` enum has two values
     (`rejected`, `load_failed`). Are these the only failure
     stages? What about a swap that times out without ANY response
     (provider disconnected mid-load)? If undefined = MAJOR.

### Category C3: Routing semantics (v0.3)

C3.1 R-4.5.3.5 retry: "for any reason_code (including cooldown,
     not_in_supported_models, already_loaded, ...)". The retry
     proceeds for ALL rejection codes. Is retrying on
     `not_in_supported_models` ever sensible (coordinator should
     never send to a provider that doesn't support the model per
     R-4.4.1)? If the spec retries on a code that indicates a
     coordinator bug, the retry hides the bug = MAJOR. If
     `not_in_supported_models` should short-circuit to 503 without
     retry, the spec needs to say so.

C3.2 R-4.5.3.8 cap ordering: per-swap → per-account → global. Is
     this the right order? If per-account is checked first (cheaper
     lookup), the per-swap cap might be exceeded for one account
     while another account's request gets parked. Verify the order
     is intentional and produces fair behavior.

C3.3 R-4.5.3.7 swap_request_ids field on request_log:
     `swap_request_ids: []text` is SHOULD, not MUST. If a request
     queues behind a swap, then retries on another candidate
     queuing behind a second swap, the row gets ≥ 2 swap IDs. Is
     `text` the right column type? Should it be a JSON array? If
     left to implementer = MINOR.

C3.4 §4.10 `state` field: "loading" applies to both `swap_pending`
     AND `loading_model`. Is the distinction observable elsewhere
     (e.g. to operators triaging "stuck waiting for ack" vs "stuck
     loading")? If conflated and operators need the distinction =
     MAJOR.

### Category D3: Backward compatibility (v0.3 re-verification)

D3.1 R-4.10.2 gates the `state` field on "at least one provider in
     the response has ever transitioned through a SPEC-010 swap
     state." This is coordinator state — does it survive coordinator
     restart? If yes, fine. If no, the field flickers in/out across
     restarts = MAJOR (operator confusion).

D3.2 v0.3 retuned defaults (drain 20s vs 30s; ETA 90s vs 60s).
     These are NEW config defaults compared to v0.2; for a fresh
     deploy this is just a defaults choice, but for an operator
     who already deployed v0.2 in canary, upgrading to v0.3 changes
     behavior even if config files are unchanged. Should v0.3
     preserve v0.2 defaults? Or is the change OK because v0.2 is
     pre-implementation draft? Status: QUESTION.

### Category E3: SPEC-008 / Pillar A interaction (v0.3)

E3.1 R-4.6.1.4 exclusion: cold-supported entries omit
     `hash_verified` and `hash_verification`. Walk SPEC-008 §5.7
     for any required field that v0.3 says to omit but SPEC-008
     says MUST be present. If SPEC-008 §5.7 requires `hash_verified`
     on EVERY entry (not just routable), v0.3 §4.6.1.4 is
     contradicting it = MAJOR.

E3.2 SPEC-008 §5.7 example shows `hash_verification.catalogued:
     true|false` per entry. For cold-supported entries, this would
     be omitted per R-4.6.1.4. Does any caller (buyer SDK,
     dashboard) depend on `catalogued` being always-present? If
     yes = MAJOR.

E3.3 R-4.4.7 + R-4.4.9 `hash_verification` enum in
     `model_swap_completed`: lists SPEC-008's 5 states. Verify the
     enum values match SPEC-008 §5.5 exactly (literal string
     equality). If misspelled or out of date = MAJOR.

### Category F3: Operator UX (v0.3, F2.1/F2.2 closure check)

F3.1 §3 pain-point table now qualifies pain #3 as "closed only
     when publish_unwarm_models: true (operator opt-in) or via
     Phase 3 catalog." Is this honest? Walk the default-config
     deployment scenario: does an operator who just upgrades to
     v0.3 with no config changes see ANY improvement on pain #3?
     If no, the table is now honest = PASS. If the table claims
     even partial improvement that isn't real = MAJOR.

F3.2 §4.10 state field "loading" maps to amber. Dashboard
     implementation is out of scope, but is the contract enough
     for dashboards to do the right thing? Specifically, does an
     existing dashboard that knows about "ready"/"down" silently
     break when it encounters "loading" (e.g. defaults to "down"
     for unknown enum)? If existing dashboards would mis-render
     = MAJOR.

F3.3 R-4.10.4 says AC-22's "no red dashboard" is satisfied iff
     `state: "loading"`. But AC-22's text says "no red dashboard"
     directly. If a dashboard implementation chooses to render
     "loading" as red anyway (operator's call), AC-22 would fail
     spec-conformance even though SPEC-010 did its part. Verify
     AC-22 phrasing makes this clear: the AC is about the
     coordinator's status value, not about dashboard rendering.

### Category G3: AC coverage (v0.3 35 ACs)

G3.1 Walk every R-4 rule introduced or modified in v0.3. For each,
     find at least one AC that exercises it:
       - R-4.1.9 validation order: AC-3 covers empty array, AC-5
         covers >64, AC-6 covers >256 bytes, AC-24 covers
         duplicates, AC-4 covers model_id-not-in. Order itself
         (step priority) is not directly tested — if two failures
         could both apply, is there an AC verifying the order? If
         not = MAJOR.
       - R-4.4.0 request_id format: no AC directly tests the
         Crockford ULID format. If implementer uses a different
         ULID variant = MAJOR (silent divergence).
       - R-4.4.0 retention: no AC tests "late ack discarded." If
         missing = MAJOR.
       - R-4.4.9 each event type: AC-32 tests sequence and key
         fields for 1 success + 1 oom path. Does AC-32 cover
         the `cold_wake_drained{outcome: "503_eta_expired"}`
         branch? If not = MAJOR (sub-coverage gap).
       - R-4.6.1.4 Pillar A exclusion: AC-27 covers it. Does the
         AC explicitly assert NO hash_verified field appears? If
         only implicitly = MAJOR.
       - §4.10 state field: AC-22 references it. Is there a
         negative AC that asserts the field is ABSENT when
         R-4.10.2 gating is unmet? If not = MAJOR.

G3.2 AC-31 cooldown retry: tests the cooldown branch. Does it
     also verify the timing — i.e. retry happens within remaining
     ETA budget, not after? If timing assertion missing = MINOR.

G3.3 AC-32 audit event sequence: does the AC verify there are NO
     additional events beyond the named sequence? (e.g. an
     implementer might double-emit on success.) If "exact event
     set" not asserted = MINOR.

G3.4 AC-33/34 queue overflow: tests immediate 503 on overflow.
     Does any AC test that the parked queue actually drains
     correctly after overflow (i.e. the cap doesn't permanently
     wedge the swap)? If not = MAJOR.

### Category H3: Companion-spec annotations (v0.3 §8)

H3.1 §8.1 SPEC-001 v1.2.5 candidate now explicitly cites §4.1,
     §4.4, §4.8, §4.9, §4.10 as normative source. Does this
     produce a self-contained BUILD prompt? Spot-check: if a
     SPEC-001 implementer reads ONLY SPEC-001 v1.2.4 + SPEC-010
     §§4.1, 4.4, 4.8, 4.9, 4.10, can they implement Phase 1
     without further design work? If not, name the missing piece.

H3.2 §8.2 SPEC-002 v1.3.5 candidate: lists state machine sub-states,
     routing changes, auth fields, audit-log events. Now with v0.3
     R-4.4.9 payload schemas, the audit-log piece is implementable.
     But does §8.2 reference R-4.4.9 explicitly? If §8.2 still
     just names event types without the payload reference = MAJOR.

H3.3 §8.3 SPEC-004 v0.4 candidate: cold-wake dispatch outcome.
     With R-4.5.3.7's billing isolation, does §8.3 need to mention
     the SPEC-005 interaction? If not, fine; if SPEC-004 readers
     would expect to find it there = MINOR.

H3.4 §8.4 SPEC-008 v0.4 compatibility note: claims "no SPEC-008
     spec change required." With R-4.6.1.4 now excluding cold
     entries from §5.7 hash blocks, does that hold? If §5.7's
     current MUSTs are violated by R-4.6.1.4 = CRITICAL scope
     creep (would need SPEC-008 v0.4 normative edit, not just
     compatibility note).

### Category I3: Anything else

Anything that doesn't fit R2V or A3-H3:
- Documentation drift (HANDOFF.md, RUNBOOK.md, AGENTS.md, etc.)
- Decision-log entry to be added when v0.3 locks
- Naming nits or section ordering
- Test infrastructure gaps
- Surfaces round-2 didn't probe that you spotted in v0.3

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Start your section with:

```
---

## Round 3 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v0.3 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-3 executive summary

[2-4 paragraphs. State whether v0.3 is ready to lock and implement,
ready with the round-3 findings closed, or still needs another pass.]

### Round-2 fix verification (R2V)

[Table: round-2 finding ID, PASS / PARTIAL / FAIL, v0.3 location
verified, 1-sentence evidence.]
```

Then for each category R2V, A3-I3: a section. For each finding:

```
### A3.2  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §4.4.9, line ~XXX

[What. 1-3 sentences.]

[Why it matters. 1-3 sentences.]

[Recommendation. 1-2 sentences.]
```

If a category has zero findings, write `(no findings)`.

## Out of scope

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-005, SPEC-008
  themselves
- Phase 2 / Phase 3 normative design
- Re-litigating round-1 or round-2 findings already marked PASS

## Done criteria

You are done when:

- Round-3 section APPENDED to SPEC-010-audit.md (rounds 1-2 intact)
- Every round-2 finding has PASS / PARTIAL / FAIL in R2V
- Every category R2V, A3-I3 has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Round-3 executive summary states a clear verdict

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Expected wall-clock: 20-35 min Codex round 3 (smaller diff than
  round 2; mostly contract-tightening to verify, not new architecture).
- Decision points after round 3:
  - 0 CRITICAL, ≤2 MAJOR → lock SPEC-010 v0.3, start SPEC-001 v1.2.5
    BUILD session.
  - ≥1 CRITICAL or >2 MAJOR → narrow v0.4 patch, re-audit round 4.
- After lock, append decision-log entry to
  `beta/DECISION_CRITERIA.md` summarizing trigger, locks (L-1..L-6),
  Phase 1 scope, deferred phases, audit history (rounds 1-3).
