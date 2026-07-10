# Audit prompt — SPEC-010 v0.2 (round 2)

Operator-paste prompt to audit SPEC-010 v0.2
(`specs/SPEC-010-model-catalog.md`).

**Round 2.** Round 1 (Codex GPT-5) audited v0.1 and produced
[SPEC-010-audit.md](SPEC-010-audit.md): 2 CRITICAL, 9 MAJOR, 3 MINOR,
2 QUESTION. v0.2 is a **restructure**, not a cleanup pass:
- Former Phase 2 (warm swap: `set_model`, `loading_model` state,
  drain semantics, ETA budget) is absorbed into Phase 1.
- Former Phase 3 (operator CLI) becomes Phase 2 (deferred to v0.3).
- Former Phase 4 (recommended catalog) becomes Phase 3 (deferred to
  v0.4).
- Round-1 fixes applied: A1, F1, C1, C2, C3, B1, B2, B3, D1, D2,
  I1, J1.
- New default: `publish_unwarm_models: false` (OQ-1 resolved
  toward safer default).

Round 2 has two jobs: (a) verify the v0.2 restructure didn't break
anything Round 1 validated; (b) audit the newly-normative surface
(`set_model` wire, cold-wake path, Pillar A interaction at swap
boundary, drain semantics).

The previous round-1 audit prompt
(`specs/AUDIT_SPEC_010_PROMPT.md`) is still useful as background but
is superseded by this file for v0.2.

Append round-2 findings to the same file
(`specs/SPEC-010-audit.md`) as a new top-level section after the
round-1 report. Do not overwrite round-1 — operator wants the
diff-over-time visible.

Paste everything between `=== BEGIN PROMPT ===` and `=== END PROMPT
===` into a fresh Codex CLI session rooted at
`/Users/augstar/macprovider-poc`.

---

```
=== BEGIN PROMPT ===

You are auditing SPEC-010 v0.2, the Provider Model Catalog & Warm
Swap spec at /Users/augstar/macprovider-poc/specs/SPEC-010-model-
catalog.md. This is round 2 of the audit.

Round 1 produced /Users/augstar/macprovider-poc/specs/SPEC-010-
audit.md with 2 CRITICAL, 9 MAJOR, 3 MINOR, 2 QUESTION findings on
SPEC-010 v0.1. v0.2 restructures the spec (former Phase 2 warm-swap
work folded into Phase 1) AND claims to fix round-1 findings A1, F1,
C1, C2, C3, B1, B2, B3, D1, D2, I1, J1.

You are NOT here to validate, rewrite, or extend the spec. Two
explicit jobs:

  J-1. Verify each round-1 finding the spec claims to fix is actually
       fixed. Cite the specific v0.2 rule/section that closes the
       finding. Findings the spec doesn't claim to fix (D3, B3
       partially, I2) — note their current status without re-arguing.

  J-2. Audit the newly normative surface added in v0.2:
       - §4.4 set_model wire (request, ack, complete, failure)
       - §4.5.2 warm-first ranking and §4.5.3 cold-wake path
       - §4.6 error envelopes (model_not_warm, Retry-After)
       - §4.7 config additions (cold_wake_enabled, cooldowns, ETA)
       - §4.8 provider CLI pre-flight validation
       - §4.9 operator-pushed swap heartbeat path
       - §8.4 SPEC-008 interaction at the swap boundary
       - The 23 ACs (up from 10 in v0.1)

Output:
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md

APPEND a new top-level section to the existing file:
  `## Round 2 — Codex GPT-5 — 2026-06-06`
followed by category-organized findings (same structure as round 1).
Do NOT touch the round-1 sections. Do NOT change the round-1
verdict; round-2 has its own verdict.

## Severity definitions

Unchanged from round 1:
- **CRITICAL** — production failure on Phase 1 rollout, silent
  regression of locked-spec behavior, scope creep into a locked
  upstream spec (SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1,
  SPEC-008 v0.3), security regression, violation of L-1..L-6.
- **MAJOR** — significant implementer confusion, predictable v0.3
  patch, unjustified thresholds, ambiguous failure semantics,
  back-compat that doesn't hold up.
- **MINOR** — quality issues; don't block v0.2.
- **QUESTION** — unresolved design choice the spec couldn't decide.

## Critical constraints to honor while auditing

**1. Locked decisions (§2 L-1 through L-6) are READ-ONLY.** Findings
that recommend inverting L-1..L-6 are rejected unless they show
structural incompatibility with another locked constraint. v0.2 §2
restates these locks; if the body of the spec contradicts them, that
is a CRITICAL finding (locked decision unenforced).

**2. SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-004 v0.3.1, SPEC-008
v0.3 are LOCKED.** Any v0.2 clause requiring a normative edit to
one of these is a CRITICAL scope-creep finding. Companion changes
belong in §8 as vNEXT candidates only.

**3. v0.2 explicitly trades L-1 byte-identical for one new behavior:
cold-wake latency.** §7.3 acknowledges that with default
`cold_wake_enabled: true`, buyer requests for cold-supported models
get up to 60s extra latency. This is documented and operator-opt-out
via `cold_wake_enabled: false`. Do NOT file this as a CRITICAL L-1
violation — the spec explicitly carves it out. But DO file as
MAJOR if you find the carve-out is incomplete (e.g. side-channel
behavior changes that aren't covered by the cold_wake_enabled
toggle).

**4. SPEC-008 F-1.5 survivability invariants MUST be preserved.**
L-6 codifies this. Walk §4.4 set_model wire and §4.5.3 cold-wake
path for any field that could feed sticky derivation, expose conv:,
hand sticky lifecycle to provider, or extend sticky TTL.

**5. SPEC-008 Pillar A hash semantics MUST stay bound to
loaded_model only (L-4).** v0.2 §4.4.7 claims the swap window is
handled via the not-ready `loading_model` sub-state, NOT a new
hash_status value. Verify this is actually true everywhere — search
the spec for any clause that treats supported_models entries as
hash-relevant or invents a sixth hash state.

**6. Cold-wake path must converge.** §4.5.3 says parked requests
get the new model after swap completes + Pillar A verification, or
fall through after ETA expires, or retry once on another candidate.
Audit for: infinite-park scenarios, double-billed requests
(re-dispatched after a swap then again after a retry), thundering-
herd swaps (N buyers each trigger N swaps for the same cold model).

**7. Drain timeout is bounded and observable.** §4.4.6 says
in-flight requests get `503 swap_drain_timeout` after the configured
window. Audit for: in-flight request loss without a 503, double-
charging on swap_drain_timeout, request_id reuse across the timeout
boundary.

**8. Clean-room.** Do NOT inspect d-inference (layr-labs) source.
NOASSERTION license.

## Required reading (in order)

1. `/Users/augstar/macprovider-poc/specs/SPEC-010-model-catalog.md`
   v0.2 — the spec under audit. Read all 12 sections + change log
   + 23 ACs fully. Bias toward §4.4 (set_model wire), §4.5
   (routing), §4.6 (error envelopes), §4.8 (CLI), §7 (back-compat),
   and §9 (ACs) most carefully.

2. `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md` —
   round-1 audit. You will be appending to this file. Read the
   round-1 findings carefully: your J-1 verification is "does v0.2
   close each one?"

3. `/Users/augstar/macprovider-poc/specs/AUDIT_SPEC_010_PROMPT.md` —
   round-1 prompt. Background only; the prompt you are following is
   THIS one (v0.2 prompt). The category framework (A-J) carries
   over but is augmented for the new surface.

4. `/Users/augstar/macprovider-poc/CLAUDE.md` — project conventions
   (PR workflow rule, Augustas11 git identity rule, spec naming).

5. `/Users/augstar/macprovider-poc/specs/SPEC-001-phase3-binary.md`
   v1.2.4 — focus on §6.1, §6.2, single-model-per-process assumption.
   v0.2 §4.8 and §8.1 propose CLI extensions; verify they don't
   accidentally trip over §6.2 today.

6. `/Users/augstar/macprovider-poc/specs/SPEC-002-coordinator.md`
   v1.3.4 — focus on §3 state machine (v0.2 adds swap_pending,
   loading_model sub-states per §4.4 and §8.2), §5 routing (v0.2
   §4.5 modifies dispatch), §7.2 auth (v0.2 §4.1 extends), §11
   audit-log (v0.2 §4.4.9 adds event types).

7. `/Users/augstar/macprovider-poc/specs/SPEC-004-smart-router.md`
   v0.3.1 — focus on §4 sticky-affinity, exact model ID routing.
   v0.2 §4.5.2 explicitly addresses the sticky/swap interaction;
   verify it actually does so without breaking SPEC-004 §4
   guarantees.

8. `/Users/augstar/macprovider-poc/specs/SPEC-008-tier2.md` v0.3 —
   focus on §5.5 hash state enumeration (FIVE states only; v0.2
   claims it adds none), §5.6 routing predicate (v0.2 says candidate
   filter precedes hash predicate, so cold-supported skips trivially),
   §2 F-1.5 invariants (v0.2 §4.4.8 cites these as preserved).

9. `/Users/augstar/macprovider-poc/beta/DECISION_CRITERIA.md` —
   Entries 21, 23, 35 for context.

10. Code spot-checks (sanity-check §4 and §8 against reality):
    - `phase4-coordinator/internal/ws/messages.go` lines 8-57
      (Hello, AuthRequest shapes)
    - `phase4-coordinator/internal/pool/provider.go` lines 50-88,
      174, 420-432, 464-477 (Provider struct, seenModels,
      ModelKnown, heartbeat ModelID change path)
    - `phase5-gateway/internal/router/server.go` lines 143, 461-479,
      1309 (model resolution, /v1/models aggregation)
    - `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift`
      lines 18-28 (ServeCommand --model flag)

11. `/Users/augstar/macprovider-poc/specs/SPEC-006-audit.md` and
    `/Users/augstar/macprovider-poc/specs/SPEC-008-audit.md` — tone
    and severity-bar continuity.

## Audit categories — work through each

### Category R1V: Round-1 fix verification (HIGHEST PRIORITY)

This is J-1. For each round-1 finding the spec claims to fix,
verify the v0.2 clause that closes it. Cite the v0.2
section/line numbers. If the fix is incomplete, partial, or
introduces a new problem, file a new finding (R2-Anew, R2-Bnew, etc.)
in the relevant category below AND note the partial-fix in R1V.

Round-1 findings to verify:

- R1V-A1: §4.3.3 + R-4.1.6 + AC-2 should close "Public /v1/status
  changes for legacy providers" (CRITICAL). Verify the
  `PublishesSupportedModels` gate actually prevents the field from
  appearing for legacy providers.
- R1V-F1: §4.4.7 + §8.4 + AC-19 should close "hash_status:unknown
  unsupported Tier-2 state" (CRITICAL). Verify no sixth hash state
  is introduced and the swap window is handled purely via
  loading_model not-ready.
- R1V-C1: §4.5.2 + §4.5.3 + AC-11 + AC-12 should close
  "cold-supported routing contradicts the required 503 path" (MAJOR).
  Verify there is no residual contradiction between candidate
  filter, warm-first ranking, and the 503 path.
- R1V-C2: §4.5.2 should close "warm-provider preference not
  normative" (MAJOR). Verify warm-first is stated as a MUST in §4.5.2
  and that it appears in Phase 1 normative text, not §8 candidate
  text.
- R1V-C3: §4.5.2 paragraphs 3-4 should close "sticky and hard-pin
  eligibility order unclear" (MAJOR). Verify the sticky-break rule
  and hard-pin-with-cooldown rule are both unambiguous.
- R1V-B1: R-4.1.1 + AC-3 should close "empty supported_models: []
  not specified" (MAJOR). Verify the rejection is normative and the
  AC is deterministically testable.
- R1V-B2: §4.8 + R-4.8.3 + AC-7 should close "provider CLI/config
  validation only implied" (MAJOR). Verify local pre-flight is a
  MUST and AC-7 actually tests the pre-WS-connect exit.
- R1V-B3: R-4.1.2 + R-4.1.7 should close "length caps need exact
  normalization" (MINOR). Verify Unicode NFC + ASCII case folding
  is specified once and referenced.
- R1V-D1: R-4.6.1.2 + AC-8 should close "byte-identical /v1/models
  restoration under-specified" (MAJOR). Verify the default change
  (publish_unwarm_models: false default in v0.2) makes AC-8
  achievable.
- R1V-D2: §4.6.2 + AC-21 should close "model_not_warm error envelope
  not testable" (MAJOR). Verify the OpenAI envelope shape is
  precisely specified.
- R1V-I1: §3 phase plan + AC-22 should close "Phase 1 alone closes
  the canary symptom is overstated" (MAJOR). Verify §3 honestly
  describes what Phase 1 fixes (operator pain via demand-pull) and
  what it defers (operator-pushed CLI in Phase 2, catalog discovery
  in Phase 3). AC-22 should demonstrate end-to-end the operator pain
  is fixed by Phase 1 alone.
- R1V-J1: spec header line "Companion to (LOCKED)" should close
  "stale companion version references" (MINOR). Verify SPEC-002
  v1.3.4 and SPEC-008 v0.3 appear (not v1.3.3 and v0.1).

For each: PASS / PARTIAL / FAIL. Include the v0.2 location verified
and 1 sentence of evidence.

Round-1 findings NOT claimed fixed (status check only):
- D3 (publish_unwarm_models default): v0.2 flipped to `false` default,
  changing the OQ-1 answer. Note this as a v0.2 design decision; the
  product-decision aspect remains.
- I2 (demand-pulled hot-swap timing): v0.2 absorbs into Phase 1.
  Note as resolved by restructure.

### Category A2: Locked-decision preservation (v0.2 reverification)

A2.1 Walk L-1 through L-6 in v0.2 §2. Confirm each is enforced by
     specific §4 / §8 clauses. If a lock is restated in §2 but no
     concrete clause enforces it = MAJOR.

A2.2 L-1 backward compat: with `publish_unwarm_models: false` AND
     `cold_wake_enabled: false` AND no SPEC-010 fields sent by any
     provider, walk every code path the spec touches and confirm
     byte-identical output. Spot-check §4.3.4 seenModels change
     against caller code in `provider.go:464-477`. If seenModels
     change is observable to any external client = CRITICAL.

A2.3 L-3 one *active* model: confirm §4.4 swap mechanism maintains
     {warm models} ⊆ {ModelID} ∪ ∅ at all times. Specifically:
     during swap_pending and loading_model, the provider should not
     be advertising or serving ANY model. If §4.4 or §4.6 implies
     two models are simultaneously available = CRITICAL.

A2.4 L-4 hash semantics: confirm §4.4.7 actually keeps hash bound
     to loaded_model only. Verify supported_models entries are NEVER
     hash-checked.

A2.5 L-6 F-1.5: walk §4.4 message types (set_model, set_model_ack,
     set_model_complete) field by field. None may include conv:,
     account_id, sticky identifiers, or AAD inputs. §4.4.8 codifies
     this — verify the message schemas in §4.4 actually satisfy it.

### Category B2: Wire-format correctness (v0.2 new fields)

B2.1 §4.4 set_model message: is `request_id` format precisely
     specified? (e.g. swap_<ULID>) Or left to coordinator
     implementation? If undefined and the spec relies on request_id
     correlation = MAJOR.

B2.2 §4.4 swap_reason enum has three values (demand_pull,
     operator_push, policy). Is the enum exhaustive? OQ-5 already
     asks; the audit may comment but it's QUESTION not finding.

B2.3 §4.4 set_model_ack reason_code enum (not_in_supported_models,
     already_loaded, load_in_progress, cooldown, other). Is "other"
     enough? If a real-world rejection reason wouldn't map cleanly
     = MINOR.

B2.4 §4.4 set_model_complete failure reason_code enum
     (weights_not_found, config_invalid, oom, drain_timeout, other).
     Is "drain_timeout" the right shape? It's an internal timeout
     reason, not a coordinator-observed event — verify the provider
     can actually distinguish drain_timeout from other load failures.

B2.5 §4.1.7 case-folding rule: Unicode NFC + ASCII case folding.
     Verify this matches SPEC-001 §6.1 case-insensitive rule.
     SPEC-001 uses "case-insensitive" without specifying the
     algorithm; v0.2 picks NFC + ASCII fold. If they're
     incompatible for any model ID seen in practice = MAJOR.

### Category C2: Routing semantics (v0.2)

C2.1 §4.5.2 sticky-break rule: "if sticky-affinity points at a
     provider whose loaded model is no longer req_model, dispatcher
     MUST break sticky and re-rank within warm_candidates." Verify
     this does NOT break SPEC-004 §4 sticky guarantees for
     non-swapping providers.

C2.2 §4.5.3.5 retry-once-on-another-candidate: a buyer request
     can re-route to a second cold provider if the first swap
     fails or times out. Verify this does NOT cause double-charging
     (request_id reuse, billing increment twice). Cross-reference
     SPEC-005 billing rules.

C2.3 §4.5.3.3 parked-request queue: "additional buyer requests for
     the same req_model MAY join the queue." Is there an upper
     bound on queue depth? Without one, a thundering-herd of buyers
     for the same cold model could OOM the coordinator's parked
     request map. If unbounded = MAJOR.

C2.4 §4.5.3.6 ETA budget per-buyer-request: "a request that joins
     a swap queue with 40s elapsed gets 20s remaining of its 60s
     budget." This is correct but is it implementable without
     per-request timer state on the coordinator? If yes, no finding.
     If it implies per-request state that doesn't exist today =
     MAJOR.

C2.5 §4.4.6 drain timeout 30s default + §4.7
     cold_wake_request_eta_seconds 60s default. Is 30s drain +
     ~20s typical load time + retry budget < 60s ETA budget? If a
     successful swap-with-drain just barely fits the ETA window
     (i.e. failure leaves no time for retry), the retry path is
     never exercised in practice = MINOR (default tuning).

C2.6 §4.4.2 swap_cooldown_seconds 60s per provider. If a fleet has
     N providers all supporting model B but none warm, a buyer
     request triggers a swap on one. While that provider is on
     cooldown, can a different buyer request trigger a swap on
     another provider? Verify §4.4.2 is per-provider not global.
     Spec says per-provider (R-4.4.2 phrasing), so this should be
     OK; double-check the words.

C2.7 §4.5.4 cold_wake_enabled escape valve: when false, behavior
     is "503 model_not_warm immediately." With publish_unwarm_models
     also false (default), the only buyers who hit this path are
     those who know the model exists via out-of-band catalog. Is
     this the intended composite behavior? Could be MAJOR if it
     creates an undocumented surprise.

### Category D2: Backward compatibility (v0.2)

D2.1 v0.2 §7.3 acknowledges the cold-wake latency carve-out from
     L-1 byte-identical. Walk every default value in §4.7 and
     confirm only `cold_wake_enabled: true` (default) produces any
     behavior change. If any other default flips behavior = MAJOR.

D2.2 Legacy provider against SPEC-010 coordinator under v0.2:
     verify §7.1 walkthrough is complete. Specifically: does the
     warm-first ranking in §4.5.2 produce identical dispatch
     decisions to pre-SPEC-010 for a pool of legacy providers? It
     should (only warm candidates, ranking unchanged) but the spec
     should say so.

D2.3 SPEC-010 v0.2 provider against legacy coordinator: §7.2 says
     legacy coordinator ignores unknown fields. Spot-check
     phase4-coordinator/internal/ws/messages.go: any usage of
     json.NewDecoder with DisallowUnknownFields, or strict
     unmarshalers anywhere in the auth path? If yes = CRITICAL.

D2.4 §4.3.4 seenModels populated from union of ModelID +
     SupportedModels. Caller ModelKnown is at
     phase4-coordinator/internal/pool/provider.go:464. What's the
     semantic effect of ModelKnown returning true for a model no
     provider currently serves warm? Audit the callers; if any
     caller relies on ModelKnown == "model is or has been served
     warm," the union expansion silently changes that meaning =
     MAJOR.

### Category E2: SPEC-008 / Pillar A interaction

E2.1 §4.4.7 claim: "the provider is not routing-eligible while
     SwapState ∈ {swap_pending, loading_model}, so SPEC-008 §5.6
     routing exclusion doesn't fire." Verify this is consistent
     with the actual SPEC-008 §5.6 phrasing. SPEC-008 §5.6 says
     the hash predicate filters routing candidates; if the provider
     is not a candidate (state != ready), the predicate is
     vacuously satisfied. Good — but verify SPEC-002 v1.3.4 §3
     actually treats loading_model as non-ready. If it doesn't
     today (v1.3.4 is locked), the SPEC-002 v1.3.5 candidate in
     §8.2 must add this state.

E2.2 §4.4.7 post-swap re-verification: "On set_model_complete
     {succeeded}, the provider MUST include model_hash for the
     NEW model. Coordinator MUST run normal Pillar A verification
     before marking the provider routing-eligible for the new
     model." Verify the existing Pillar A verification path in
     SPEC-008 §5.3 runs automatically on hash arrival; if it
     requires an explicit trigger that v0.2 doesn't provide = MAJOR.

E2.3 Adversarial swap-then-report-old-hash attack: a malicious
     provider sends set_model_complete{succeeded} with hash(A)
     when it actually loaded B. Verify §4.4.7 explicitly addresses
     this. If not addressed (hash is provider-self-reported), is
     this attack worse than the existing Pillar A "honest-but-
     misconfigured vs adversarial" scope limit in SPEC-008 §5.4?
     If yes = MAJOR. If equivalent (Pillar A already accepts
     honest-but-misconfigured threat model) = no new finding.

E2.4 SPEC-008 §5.7 hash_verification block on /v1/models: with
     v0.2 §4.6.1 union aggregation, does the hash_verification
     block apply to cold-supported entries? Cold-supported has no
     warm provider serving it, so "verified_provider_count" is
     undefined. Spec is silent. If undefined = MAJOR.

### Category F2: Operator UX completeness (the I1 closure check)

F2.1 §3 phase plan + AC-22: walk the four arm64golf canary pains
     (§1.1) one more time. For each, is the Phase 1 fix actually
     end-to-end usable by an operator today (i.e. with no Phase 2
     CLI)?
       - Pain #1 (no CLI to change active model): Phase 1 enables
         demand-pull. The operator still has no CLI; they "change
         the model" by directing buyer traffic. Is this an
         honest fix or a UX evasion? File as QUESTION if you
         think the operator would view this as a fix; MAJOR if
         not.
       - Pain #2 (restart causes red dashboard): Phase 1 demand-pull
         avoids restart. Does the dashboard correctly reflect
         loading_model state (amber, not red)? Spec doesn't say. If
         the existing dashboard treats !ready as red = MAJOR (Phase 1
         introduces a state that operators will see as a
         regression of "always green").
       - Pain #3 (picker shows only loaded): default
         publish_unwarm_models: false means this is unfixed unless
         operator opts in. Is this acknowledged in §3 or §7? If not
         = MAJOR (silent regression of expected Phase 1 fix).
       - Pain #4 (no HF ID discovery): Phase 3 fix. §3 says so.

F2.2 v0.2 §3 says "Phase 1 alone closes operator pain points #1,
     #2 from §1.1." Verify this phrasing is accurate given F2.1's
     answers. If overstated again (I1 from round 1 not fully
     closed) = MAJOR.

### Category G2: AC coverage (the 23 ACs in v0.2)

G2.1 Walk every R-4.x.y normative rule in §4. For each, find an AC
     that exercises it. If a rule has no AC = MAJOR per uncovered
     rule. v0.1 had 10 ACs; v0.2 has 23; the new ACs should map to
     the new wire surface (set_model, cold-wake, error envelopes).

G2.2 AC-22 is the "Phase 1 fixes operator pain" AC. Is the
     described scenario actually a sufficient demonstration that
     the canary symptom is closed? Or does it skip important steps
     (e.g. dashboard state observation)? If insufficient = MAJOR.

G2.3 Negative-path AC coverage: is there an AC for the case where
     `set_model` rejected with reason_code: "cooldown" causes the
     cold-wake path to fall through correctly per §4.5.3.5? AC-17
     comes closest but doesn't explicitly cover the reason_code:
     "cooldown" branch. If missing = MAJOR.

G2.4 Audit-log AC: §4.4.9 introduces model_swap_started,
     model_swap_completed, model_swap_failed event types. Is there
     an AC that verifies these are emitted with the right shape?
     If absent = MAJOR.

### Category H2: Companion-spec annotations (v0.2)

H2.1 §8.1 SPEC-001 v1.2.5 candidate now lists CLI flags, async
     load, swap handlers, local pre-flight validation. Is the
     candidate BUILD prompt implementable from §8.1 alone? Or does
     it require additional design? If the latter = MAJOR per
     missing detail.

H2.2 §8.2 SPEC-002 v1.3.5 candidate lists state machine sub-states,
     routing changes, auth fields, audit-log events. Are the audit-
     log event payload shapes specified anywhere (in §4.4.9 or
     §8.2)? If event types are named but payloads undefined =
     MAJOR.

H2.3 §8.3 SPEC-004 v0.4 candidate: candidate selection adds
     SupportedModels predicate, warm-first partition, cold-wake
     dispatch outcome. Is the dispatch outcome enumeration
     complete? SPEC-004 §4 enumerates outcomes (dispatched / no-
     eligible / failover); v0.2 adds cold-wake. If the existing
     outcomes are not preserved alongside = MAJOR.

H2.4 §8.4 SPEC-008 v0.4 compatibility note: claim is "no SPEC-008
     spec change required — the verification flow already triggers
     on hash arrival." Verify this against SPEC-008 §5.3 actual
     phrasing. If SPEC-008 actually requires a trigger that v0.2
     doesn't provide = MAJOR.

### Category I2: Anything else

Anything that doesn't fit R1V or A2-H2. Examples to consider:
- Documentation drift: HANDOFF.md, RUNBOOK.md, CONTINUE_RUNBOOK.md,
  AGENTS.md that v0.2 should trigger updates to.
- Decision-log entry to be added when v0.2 locks: should describe
  trigger, restructure decision, what shipped vs deferred.
- Naming nits or section ordering.
- Anything that round-1 missed and round-2 spotted in newly
  normative surface.
- Test infrastructure gaps: any existing integration test that
  would fail the moment §4.5.2 warm-first ranking is implemented?

## Output structure

APPEND to `/Users/augstar/macprovider-poc/specs/SPEC-010-audit.md`.
Do not overwrite. Start your section with:

```
---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v0.2 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N
**Date:** 2026-06-06
**Total findings:** [N CRITICAL / N MAJOR / N MINOR / N QUESTION]

### Round-2 executive summary

[2-4 paragraphs. State whether v0.2 is ready to implement, ready
with the round-2 CRITICAL findings closed, or needs another
restructure. Be specific about which round-1 findings v0.2
genuinely closed vs claimed to close.]

### Round-1 fix verification (R1V)

[Table or list: round-1 finding ID, PASS / PARTIAL / FAIL, v0.2
section verified, 1-sentence evidence.]
```

Then for each category R1V, A2, B2, C2, D2, E2, F2, G2, H2, I2,
write a section. For each finding within a category:

```
### A2.3  [SHORT TITLE]   [CRITICAL | MAJOR | MINOR | QUESTION]
Location: §4.4.7, line ~XXX

[What. 1-3 sentences.]

[Why it matters. 1-3 sentences.]

[Recommendation. 1-2 sentences. Don't rewrite the spec.]
```

If a category has zero findings, write `(no findings)` under the
category header.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Rewriting the spec
- Implementing the spec
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing the arm64golf canary infrastructure
- Designing the SPEC-001 v1.2.5 BUILD prompt
- Phase 2 (operator CLI) normative design — that's v0.3
- Phase 3 (recommended catalog) normative design — that's v0.4

## Done criteria

You are done when:

- The round-2 section has been APPENDED to
  /Users/augstar/macprovider-poc/specs/SPEC-010-audit.md (round-1
  section intact)
- Round-1 findings are each marked PASS / PARTIAL / FAIL in R1V
- Every category R1V, A2-I2 has a section (even if "(no findings)")
- Every finding has severity, location, what/why/recommendation
- Round-2 executive summary states a clear verdict

=== END PROMPT ===
```

---

## Operator notes (NOT part of the prompt)

- Run with `codex` CLI on the host that has the repo checked out.
- Expected wall-clock: 30-45 min Codex round 2 (smaller diff to
  audit; new normative surface is mostly §4.4 + §4.5.3 + §4.6.2).
- After Codex finishes, decide:
  - 0 CRITICAL, ≤3 MAJOR → lock SPEC-010 v0.2, start SPEC-001
    v1.2.5 BUILD session
  - ≥1 CRITICAL or >3 MAJOR → draft v0.3 fix pass, re-audit round 3
  - Significant new restructure recommended → discuss with operator
    before another draft
- After lock, append decision-log entry to
  `beta/DECISION_CRITERIA.md` summarizing trigger, locks (L-1..L-6),
  Phase 1 scope, deferred phases.
