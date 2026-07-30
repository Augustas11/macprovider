# Fix prompt — SPEC-004 v0.1 → v0.2 (audit-driven)

Operator-paste prompt to revise `specs/SPEC-004-smart-router.md` from v0.1 to
v0.2 in response to an independent design audit. The audit verdict was
**REVISE** (1 CRITICAL, 2 MAJOR, several MINOR + gaps); the operator chose to
fully specify all four pillars (A sticky, B classes, C retry, D ε-tiebreak),
accepting that **Pillar A's implementation is gated on a sibling SPEC-006
v0.8** that lifts §1.3's sticky-caching prohibition and adds a gateway-derived
conversation id.

This is a **spec-text-only patch** to SPEC-004. No code, no other specs.

## What this stream owns

| Layer | From | To |
|-------|------|----|
| Spec document | SPEC-004 v0.1 | SPEC-004 v0.2 |
| Coordinator code | (no change in this stream) | (no change) |
| Other specs | (locked) | (locked) |

## Sibling prompt queued

A separate **`FIX_SPEC_006_V0_8_PROMPT`** will lift the §1.3 sticky-caching
prohibition, add a gateway-derived per-conversation id (`X-MacProvider-Conv`
or equivalent — name to be decided in that stream), and refresh the
plaintext-to-provider privacy disclosure (H-006 family). Pillar A's
implementation MUST NOT proceed until that lands. Reference it from SPEC-004
v0.2 §6 / §8 as the implementation gate; do NOT pre-empt its design here.

---

```
=== BEGIN PROMPT ===

You are revising `specs/SPEC-004-smart-router.md` (v0.1 → v0.2) to close the
independent audit findings on the v0.1 Smart Router spec. The audit verdict
was REVISE: one CRITICAL contradiction, two MAJOR gaps, several MINOR items,
plus normative resolutions for the five open questions.

## Locked corpus (do NOT modify spec text in this phase)
  SPEC-001 v1.2.4   — phase3-binary provider WS protocol (LOCKED; no wire change)
  SPEC-002 v1.3.3   — coordinator request router (you EXTEND its §5 routing)
  SPEC-003 v0.7    — open onboarding
  SPEC-006 v0.7    — buyer API gateway (a SIBLING fix prompt will move this; do NOT touch here)

## Required reading
1. `specs/SPEC-004-smart-router.md` (v0.1 — the file you are revising)
2. The audit findings on v0.1 — restated below. Treat them as inputs; do NOT
   re-litigate the verdict.
3. `specs/SPEC-002-coordinator.md`:
   - FR-R3 + the routing pseudocode (the `X-MacProvider-Session` HARD-PIN
     contract that v0.1 collided with)
   - F-4 (one-shot failover + hard-pin no-failover)
   - FR-P8a (warm-up gate), FR-P11a (circuit-breaker), FR-P11a C2 (cancel-vs-
     timeout attribution), FR-P18 (slow-cancel-not-unhealthy)
4. `specs/SPEC-006-buyer-api.md` §1.3 (the sticky-caching prohibition that
   blocks Pillar A's implementation until SPEC-006 v0.8) and §1.6 / §19
   (plaintext-disclosure language Pillar A must compose with).
5. `phase4-coordinator/internal/buyer/server.go` pin resolution path (≈979–1008
   today) — for grounding your CRITICAL fix in real code behavior.

## Mandatory resolutions (the audit's CRITICAL + MAJORs)

### R-1 (CRITICAL): Resolve the `X-MacProvider-Session` collision normatively
The v0.1 build prompt's instruction to "reuse `X-MacProvider-Session`, do NOT
invent a new field" was WRONG and the audit correctly overrode it. v0.2 MUST:

- **Reverse FR-SR-2's no-new-field clause.** Sticky affinity is keyed off a
  DISTINCT field, NOT off the `X-MacProvider-Session` buyer header.
- **`X-MacProvider-Session` stays HARD-PIN ONLY.** Any present value triggers
  FR-R3 hard-pin semantics (match `assigned_id`, else 503 `session_ended`,
  no failover, no sticky lookup). This is a MUST.
- **Sticky keys off a NEW, gateway-derived internal session/conversation
  field**, namespaced so it can never collide with an `assigned_id` (e.g.
  prefix `conv:` or a distinct YAML field). The coordinator NEVER reads this
  from a raw buyer header in Pillar A — it is supplied by SPEC-006 via an
  internal mechanism. The spec must NAME the field and its namespace
  convention, and state that SPEC-006 v0.8 owns its derivation/disclosure.
- **State an unambiguous precedence** the coordinator can decide from wire
  data alone: hard-pin header present → FR-R3 (full stop, no sticky). Sticky
  only ever activates when the SPEC-006-derived field is present AND no hard
  pin AND no `X-MacProvider-Provider`.
- **Add a normative test (AC-SR):** a buyer-supplied `X-MacProvider-Session`
  that does NOT match an active assigned_id MUST return 503 `session_ended`
  unchanged from FR-R3; it MUST NOT silently become a soft-affinity key.
- **Implementation gate:** Pillar A MUST NOT be implemented until SPEC-006
  v0.8 lands the conversation-id mechanism + lifts §1.3 + refreshes the
  privacy disclosure. State this as a hard precondition in §8 (hand-off) and
  §2 (scope notes). Pillars B/C/D may proceed independently.

### R-2 (MAJOR M-1): Retry timeout-budget + C2 cancel-during-retry
- **Add config:** `routing.retry_per_attempt_timeout_s` (default 60s, or a
  documented derivation from `request_timeout_s` / `max_retries+1`). Define
  the per-attempt bound precisely; do NOT leave "configured per-attempt
  bound" as a dangling reference.
- **Specify the budget formula normatively.** Use wall-clock:
  `remaining = routing.request_timeout_s − elapsed_since_request_start`.
  Skip retry attempt `n` when `remaining < routing.retry_per_attempt_timeout_s`.
  Total wall-clock budget MUST respect FR-P11a C2 (coordinator
  `request_timeout_s` < gateway `coordinator_request_seconds`); this is the
  hard upper bound.
- **Carve out C2 cancel-during-retry from breaker attribution.** Mirror
  FR-P11a's streaming/non-streaming attribution rules during a retry attempt:
  a buyer/gateway cancellation arriving during a retry attempt is excluded
  from breaker accounting per FR-P11a C2; only provider-attributable faults
  count. Reference FR-P11a C2 by line.
- **Add AC-SR** asserting: (a) retries stop when remaining budget < per-attempt
  bound (no orphan attempts past timeout); (b) a cancel during retry attempt
  N does NOT charge a fault to that provider.

### R-3 (MAJOR M-2): Default-preservation test must cover the pin path + sticky-off no-op
- **Rewrite the "byte-identical" claim** to "identical provider selection and
  identical buyer-visible response/headers, with only additive internal
  routing-decision logging." (The v0.1 wording was technically false because
  v0.2 adds a routing log even at default.)
- **Extend AC-SR-1** to assert, with ALL SPEC-004 keys at default:
  - `X-MacProvider-Session` and `X-MacProvider-Provider` behave EXACTLY as
    FR-R3 (no sticky read/write, including the `session_ended` 503 case).
  - Sticky lookup (Step 4 in §3 pipeline) is a verified NO-OP when
    `sticky_enabled: false` (no map read/write, no log-order change).
  - Preference modes `default`/`fast`/`accurate` route identically to
    SPEC-002 v1.3.3 on equal-metric provider sets (v0.1's existing case).

## Mandatory resolutions (the 5 open questions — decided)

The audit confirmed concrete right-answer resolutions for OQ-1 and OQ-5;
provided strong recommendations for OQ-2, OQ-3, OQ-4. Bake all five into
v0.2 normative text; do NOT leave them as operator discretion.

- **OQ-SR-1 → DECIDED.** See R-1: gateway-derived internal field, hard-pin
  header stays hard-pin-only. Not operator discretion.
- **OQ-SR-2 sticky default → `sticky_enabled: false`.** Opt-in until the
  SPEC-006 v0.8 privacy refresh lands. Matches the implementation gate.
- **OQ-SR-3 `balanced` class scoring → ship a concrete default formula in
  v0.2.** Define a documented normalized blend per-candidate-set:
  ```
  score(p) = 0.4·norm(throughput_tps_estimate)
           + 0.3·norm(model_params_b)
           + 0.2·norm(max_context_tokens)
           + 0.1·norm(slots_free / max(1, slots_total))
  ```
  where `norm(x)` is min-max normalization over the eligible candidate set
  (zero variance → 1.0). Weights are operator-tunable in a future minor;
  the FORMULA is normative in v0.2 so `balanced` is testable (AC-SR coverage).
- **OQ-SR-4 retry public vs internal → KEEP `X-MacProvider-Retry` as a PUBLIC
  buyer opt-in header.** Defaults conservative (`max_retries: 0` → current
  one-shot-only behavior unchanged). Note in §6 that SPEC-005 (billing) may
  later refine retry-cost policy; until then retry attempts each settle per
  the existing FR-P11a attribution.
- **OQ-SR-5 `retried` column → counts ONLY explicit SPEC-004
  `X-MacProvider-Retry`-driven attempts.** F-4 one-shot failover has its own
  SPEC-002 logging and remains invisible to this column. State this
  normatively in §6 schema text; remove the v0.1 "implementer chooses"
  fallback.

## Mandatory resolutions (gaps the audit flagged)

- **Sticky write on retry.** When a retried request commits, the sticky
  affinity entry MUST update to the FINAL committed provider, not any earlier
  failed attempt. State explicitly in the FR-SR governing sticky writes.
- **Sticky map concurrency.** State the synchronization requirement: read/write
  + LRU `last_used_at` update MUST be serialized (mutex or equivalent). The
  spec doesn't dictate implementation, but new-hires must know the contract.
- **Sticky vs pref-sort interaction.** Resolve the §3 line 87 "soft preference"
  ambiguity: sticky promotes the cached provider to position 0 ONLY if it is
  within the `routing.tiebreak_epsilon` cohort of the pref-sort objective;
  otherwise the objective sort wins (stale-cache provider falls back). This
  ties sticky to the load-distribution model coherently.
- **Per-request breaker-degradation cap.** A single retried buyer request
  MUST NOT push more than N distinct providers across the breaker threshold.
  Default `routing.max_providers_faulted_per_request: 2` (≤ `max_retries`).
  Beyond that, abort retries and return the buyer error.
- **Class config + sticky entries on reload.** When `routing.model_classes`
  is reconfigured at runtime, stale sticky entries whose `model_scope` no
  longer matches an existing class MUST be invalidated (treat as miss + fall
  back to default selection).

## Hard rules (carry over from v0.1; restate so the editor doesn't drift)
- **Additive only at default.** All new keys at default → identical provider
  selection + identical buyer-visible behavior to SPEC-002 v1.3.3. R-3 above
  hardens the test.
- **NO SPEC-001 / phase3-binary / wire change.** All changes are
  coordinator-internal + (for A) a SPEC-006-derived field reached internally,
  not as a new provider message.
- **Preserve audit reproducibility on randomized routes** (Pillar D — v0.1's
  FR-SR-17 is sound; keep it).
- **Compose correctly with FR-P5 / F-4 / FR-P8a / FR-P11a.** No path may route
  to an ineligible / held / warming provider.
- **Pillar A is SPECIFIED in v0.2 but NOT IMPLEMENTABLE until SPEC-006 v0.8.**
  State this prominently in §2 (scope) and §8 (implementation hand-off).
  Pillars B / C / D are implementable from v0.2 with no further spec movement.
- Clean-room: do NOT inspect d-inference (NOASSERTION). Design from public
  specs + this repo only.

## Output requirements
- Edit `specs/SPEC-004-smart-router.md` in place, bumping the version header to
  v0.2 and adding a changelog entry that summarizes the R-1 / R-2 / R-3
  resolutions, the five OQ decisions, and the new gap closures.
- Do NOT modify any other spec file. Do NOT write code. Do NOT create new spec
  files (the SPEC-006 v0.8 work has its own sibling prompt).
- Preserve the v0.1 section/FR-SR/AC-SR numbering wherever possible; add new
  ACs (e.g. AC-SR-15 for R-1's `session_ended` regression, AC-SR-16 for R-2's
  budget-stop + cancel-no-charge) rather than renumbering.

## Self-verification checklist (before declaring done)
- [ ] FR-SR-2 no longer permits sticky to key off `X-MacProvider-Session`;
      a new internal field is defined; precedence is wire-decidable.
- [ ] A normative test (AC-SR) covers the `session_ended` 503 case for a
      non-matching hard-pin value.
- [ ] `routing.retry_per_attempt_timeout_s` exists, the budget formula is
      stated, and a C2 cancel-during-retry carve-out is normative.
- [ ] AC-SR-1 covers the pin path + sticky-off no-op + "byte-identical" wording
      corrected.
- [ ] All five OQs are resolved in normative text; no "operator decides"
      remains for OQ-1/3/5; OQ-2/4 have defaults baked in.
- [ ] `balanced` formula is concrete and testable.
- [ ] `retried` column semantics decided (explicit retries only).
- [ ] Sticky write-on-retry, map concurrency, sticky-vs-pref-sort ambiguity,
      per-request breaker-degradation cap, and class-config-reload behavior
      all addressed.
- [ ] Pillar A implementation gate on SPEC-006 v0.8 is stated in §2 and §8.
- [ ] No SPEC-001 wire change. No scope creep into rewards/billing/antfeed.
- [ ] Changelog v0.2 entry added; version header bumped.

=== END PROMPT ===
```

## After running this prompt
1. Run an independent audit on the v0.2 result (mirror the v0.1 audit prompt
   used previously; expand it with the R-1 / R-2 / R-3 verification).
2. If the audit returns ACCEPT, queue **`FIX_SPEC_006_V0_8_PROMPT`** (sibling
   spec movement) so Pillar A can be implemented later.
3. Pillars B / C / D become implementable from SPEC-004 v0.2 the moment its
   audit ACCEPTs — they are NOT blocked on the SPEC-006 v0.8 work.
