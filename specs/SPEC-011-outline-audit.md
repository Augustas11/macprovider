# SPEC-011 v0.1 outline — Audit Report (pre-draft scope review)

**Audited:** SPEC-011 v0.1 outline
(specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N (outline pre-draft pass)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 6 MAJOR / 1 MINOR / 1 QUESTION

**Sibling audits:**
- specs/SPEC-010-audit.md — SPEC-010 v1.0 round 1 (parallel)
- specs/SPEC-012-source-audit-history.md — wide-scope predecessor

---

## Executive summary

Verdict: **ready for v0.2 normative drafting after the MAJOR findings are addressed in the outline/draft plan; no re-scoping required.** The split from the wide-scope predecessor is structurally sound: SPEC-011 does not smuggle in coordinator-initiated `set_model`, demand-pull cold wake, parked queues, buyer catalog aggregation, or `model_not_warm`. Those remain SPEC-012 territory, and expanding SPEC-011 to include them would violate the split rationale.

The outline's main weakness is not scope creep. It is that several operator-only surfaces are thinner than they look: heartbeat `model_hash` is not currently a heartbeat field, the current heartbeat model-change path clears hash evidence rather than accepting new evidence, SPEC-008 does not itself define an automatic hash-change trigger, and the Swift runtime is built around immutable startup-loaded model state. v0.2 can handle these additively, but it must name them directly.

The §6 estimate of "1-2 audit rounds to lock" is **plausible only after these MAJOR gaps are reflected in v0.2's anticipated AC surface**. As written, the estimate is optimistic because §5's 10-12 AC count omits concurrency/race handling, heartbeat cadence during load, mutable runtime state, hash-on-heartbeat re-verification, and legacy/new coordinator behavior during `loading: true`.

## Category S: Scope-split correctness

(no findings)

SPEC-011 §2.1 covers operator-host CLI, binary-local async load, drain, rollback, heartbeat observation, and Pillar A re-verification. SPEC-010 v1.0 only provides `supported_models`/publication primitives, and SPEC-012-source owns coordinator `set_model`, cold wake, queues, buyer-visible cold catalog, `/v1/status.state`, and `model_not_warm`. SPEC-011 §4 does not assume a coordinator-side swap trigger.

## Category C: Cross-spec interactions

### C.3  Heartbeat hash re-verification path is not actually present   [MAJOR]
Location: SPEC-011 §4.3-§4.5, lines ~135-173; `phase4-coordinator/internal/ws/messages.go` lines 121-135; `phase4-coordinator/internal/pool/provider.go` lines 420-432

SPEC-011 says load success emits a heartbeat with new `model_id` and `model_hash`, and that SPEC-008 §5.3-§5.6 "re-runs" on the new hash. Current heartbeat structs have `model_id` but no `model_hash`, and the current `ApplyHeartbeat` path clears `ModelHash` and sets `HashStatusUncatalogued` when `ModelID` changes.

This would trip v0.2 drafting because the outline treats re-verification as already automatic, while the actual additive surface includes a new heartbeat `model_hash` field, coordinator ingestion of that field, and an explicit hash-status recomputation trigger on heartbeat model/hash changes.

Recommendation: In v0.2, make heartbeat `model_hash` an anticipated normative field alongside `loading`, and specify that a changed `model_id`/`model_hash` pair triggers the existing SPEC-008 hash-status computation before routing eligibility is restored.

### C.4  Async load must preserve heartbeat and WS liveness cadence   [MAJOR]
Location: SPEC-011 §4.2-§4.3, lines ~118-148; SPEC-002 §7.1 heartbeat, lines ~1695-1729; SPEC-002 §11 J.1, lines ~2801-2816

The outline says the WS session stays connected during async load, but it does not anticipate a normative rule that heartbeats continue at the negotiated interval while MLX load work is running. SPEC-002 has a specific production lesson that long MLX work starving heartbeat/activity caused live provider failures.

Without this surface, v0.2 can pass a mechanical "load in background" design while still making the coordinator consider the provider stale, trigger wake/degraded behavior, or lose operator-visible progress during the exact warm-swap window SPEC-011 exists to improve.

Recommendation: Add a v0.2 rule/AC that `models switch` load work MUST NOT block WS receive/send loops or heartbeat emission; a provider in `loading: true` still sends heartbeat/activity frames at the normal cadence until success or failure.

### C.5  Current runtime shape implies a mutable-state rewrite, not a small sibling path   [MAJOR]
Location: SPEC-011 §4.2, lines ~118-133; `ModelRuntime.swift` lines 25-68, 86-147

SPEC-011 says the existing synchronous startup load stays and an async path is added alongside. The current Swift `ModelRuntime` actor stores `modelID`, `container`, and `modelHash` as immutable `let` fields initialized once, and inference methods validate against those fixed fields.

This does not make SPEC-011 impossible, but it means v0.2 needs a real runtime state contract: ready/loading/draining, atomic swap point, rejection of new work during load, rollback semantics, and how old in-flight calls retain their old container. If the draft treats this as a narrow helper function, implementation and audit will churn.

Recommendation: In v0.2, specify the binary-side model-state machine and atomic ownership model explicitly. Keep the implementation additive to SPEC-001, but do not imply the current immutable runtime can absorb warm swap without a stateful runtime refactor.

## Category L: Locked-decision consistency

### L.2  "Zero warm models" conflicts with old-model in-flight drain wording   [MAJOR]
Location: SPEC-011 §3 L-3, line ~87; §4.2, lines ~123-128; §4.4, lines ~152-160

L-3 says that during load the provider has zero warm models. §4.2 and §4.4 say existing in-flight requests continue on the old weights during the load window until completion or drain timeout.

These can both be made true only if "zero warm models" means "zero routing-eligible warm models for new dispatch," not "no old weights remain resident." Otherwise v0.2 may contradict itself on whether old in-flight requests can continue and when the old container is released.

Recommendation: Rephrase L-3 in v0.2 as single routing-eligible warm model, with a transient old-container drain reference allowed only for requests already in flight at switch time. New routing eligibility remains zero while `loading: true`.

## Category F: Forward-compatibility with SPEC-012

(no findings)

SPEC-012 can reuse SPEC-011's binary-side async load primitive if v0.2 defines it trigger-agnostically: local CLI signal now, coordinator `set_model` later. The current outline points in that direction and does not force a fundamentally different binary contract.

## Category A: Anticipated AC + audit footprint realism

### A.1  10-12 ACs understates the required v0.2 surface   [MAJOR]
Location: SPEC-011 §5-§6, lines ~193-226

The listed AC estimate covers core happy/negative paths, but omits several externally visible branches: repeated `models switch` while already loading, WS drop/reconnect mid-load, heartbeat cadence during async load, legacy coordinator/new provider behavior, heartbeat `model_hash` ingestion, exact `provider_loading` envelope, streaming drain timeout behavior, and `loading: true` routing ineligibility.

This matters because the predecessor draft repeatedly failed audits on missing negative paths and cross-component timing, not on the happy path. If v0.2 is drafted with only 10-12 ACs, the first normative audit will likely rediscover these as MAJOR coverage gaps.

Recommendation: Treat 10-12 as low. Plan roughly 16-20 focused ACs, still much smaller than SPEC-012-source, with explicit coverage for load/race/timing/hash/compat branches.

## Category Q: OQ quality

### Q.2  Concurrent switch while already loading is a hidden OQ   [MAJOR]
Location: SPEC-011 §4.1-§4.2, lines ~103-133; §8, lines ~258-271

The outline asks about CLI/process signaling, blocking vs background UX, cooldown, and target visibility, but it does not ask what happens if an operator invokes `models switch X` while the provider is already loading Y. SPEC-012-source had an explicit `load_in_progress` rejection path for this class of race; SPEC-011 has no equivalent anticipated surface.

This race will produce audit churn because it crosses CLI UX, runtime state, rollback, and audit logging. It is not SPEC-012 demand-pull scope; it is intrinsic to operator-pushed local swaps.

Recommendation: Add a v0.2 decision: second switch during `loading: true` is rejected deterministically, queued locally, or cancels/replaces the current load. The conservative recommendation is deterministic local rejection with a stable exit code and diagnostic.

### Q.3  WS drop mid-load needs a stated policy   [QUESTION]
Location: SPEC-011 §4.2-§4.3, lines ~118-148; SPEC-002 §3/§7.1 heartbeat behavior, lines ~389-439 and ~1695-1729

The outline says the WS stays connected, but does not state what the provider does if the coordinator connection drops mid-load: abort the load, finish and reconnect with the new model, or roll back to the old model. Each choice is defensible, but they have different operator and coordinator-visible outcomes.

This probably can be resolved in v0.2 drafting rather than before drafting, but it should be an explicit OQ because reconnect semantics interact with model/hash state, audit emission, and whether the old model remains available.

Recommendation: Add this to §8 or decide it in v0.2. If kept simple, finish the local load and reconnect/reauth with the final loaded model and hash; emit no `operator_model_swap` event unless the coordinator observed the full loading-to-loaded transition.

## Category H: Hygiene

### H.2  CLI name and SPEC-010 validation citation are imprecise   [MINOR]
Location: SPEC-011 §2.1 and §4.1, lines ~47-50 and ~97-116; SPEC-010 §3.1.4 lines ~137-140; SPEC-010 §3.6.3 lines ~300-310; `MacProviderCLI.swift` lines 7-15

SPEC-011 examples use `macprovider models ...`, but the current binary command is `macprovider-cli` with subcommands `serve`, `status`, `self-test`, `update`, and `uninstall`. The outline also cites SPEC-010 R-3.1.4 for local CLI validation; R-3.1.4 exists, but it is the coordinator auth containment rule, while binary-local validation is specified more directly in SPEC-010 R-3.6.3.

This is a hygiene issue, not a scope flaw. If left uncorrected, v0.2 examples and tests may target the wrong executable name or copy the wrong validation reference.

Recommendation: In v0.2, choose the command name deliberately (`macprovider-cli models ...` or a documented rename to `macprovider`) and cite SPEC-010 R-3.6.3 for local pre-flight validation, with R-3.1.4 as the underlying wire containment invariant.

## Out of scope for this audit

- Inspecting d-inference source (NOASSERTION license)
- Drafting SPEC-011 v0.2 (this is pre-draft review)
- Auditing SPEC-001, SPEC-002, SPEC-004, SPEC-008 themselves
- Auditing SPEC-010 v1.0 (parallel audit)
- Grading SPEC-011 outline against normative-spec standards
  (R-rule count, AC enumeration, wire example completeness —
  those come in v0.2)

## Self-verification

- Read the required files in the prompt's order: SPEC-011 v0.1 outline, SPEC-010 v1.0, SPEC-012-source, SPEC-012-source-audit-history, CLAUDE.md, SPEC-001 v1.2.4, SPEC-002 v1.3.4, SPEC-008 v0.3, then the required code spot-checks.
- Spot-checked `phase4-coordinator/internal/ws/messages.go` lines 8-57 and heartbeat struct lines 121-135 for message/field conflicts.
- Did not inspect d-inference source.
- Covered categories S, C, L, F, A, Q, H.
- Every finding has severity, location, what, why, and recommendation.
- Verdict and §6 audit-round estimate evaluation are included in the executive summary.

---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-011 v0.1.1 outline
(specs/SPEC-011-operator-pushed-warm-swap.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N (outline pre-draft pass)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 2 MAJOR / 1 MINOR / 1 QUESTION

### Round-2 executive summary

Verdict: **ready for v0.2 normative drafting after the two MAJOR findings are explicitly carried into the v0.2 plan; no further outline iteration is required on scope.** v0.1.1 materially closes the round-1 outline gaps: it adds the heartbeat hash path, no-starve rule, mutable runtime state machine, concurrency policy, WS-drop policy, corrected CLI naming/citations, and a much broader AC plan.

The split remains structurally sound. The v0.1.1 additions do not smuggle in SPEC-012's coordinator-initiated `set_model`, cold-wake queue, buyer-facing `/v1/models` aggregation, `/v1/status.state`, or `model_not_warm` envelope. The coordinator remains a passive observer of an operator-pushed local swap.

The remaining problems are contract-precision issues that v0.2 must not bury: §4.8 names the wrong reconnect handshake surface for the locked SPEC-001/SPEC-002 protocol, and §4.3's hash-on-heartbeat fix is a replacement of SPEC-002's current hash-clearing behavior that needs an explicit SPEC-002 v1.3.5 candidate annotation. The AC plan is now realistically scoped, but its stated total is wrong.

### Round-1 fix verification (R1V)

| Round-1 finding | Result | v0.1.1 location verified | Evidence |
|---|---|---|---|
| R1V-C.3 heartbeat hash re-verification path | PARTIAL | §4.3 lines 290-332 | PASS on substance: §4.3 adds optional `model_hash` and re-runs SPEC-008 §5.3-5.6 on changed `(model_id, model_hash)`; PARTIAL because the fix replaces SPEC-002's current clearing behavior without a companion-spec replacement annotation (see D2.1). |
| R1V-C.4 async load must preserve heartbeat | PASS | §4.2 lines 270-280; §5 lines 488-496 | The no-starve rule says async load MUST NOT block WS receive/send loops or heartbeat emission, and §5 adds a 30s no-missed-heartbeat AC. |
| R1V-C.5 mutable-state runtime refactor | PASS | §4.2 lines 197-268; code spot-check `ModelRuntime.swift` lines 25-68, 86-147 | §4.2 names the existing immutable actor fields and requires a mutable-state runtime with snapshot semantics; the current actor shape confirms the refactor target. |
| R1V-L.2 "zero warm models" conflict | PASS | §3 L-3 line 146; §4.2 lines 234-249 | L-3 now says zero routing-eligible warm models during load while the old resident container may serve in-flight requests until drain/swap. |
| R1V-A.1 10-12 ACs understates surface | PARTIAL | §5 lines 463-537 | PASS on scope: §5 expands to the requested 16-20 range; PARTIAL because the bullets enumerate 20 ACs while the footer says "Total: 16" (see A2.1). |
| R1V-Q.2 concurrent switch hidden OQ | PASS | §4.7 lines 402-425; §4.1 lines 180-185 | §4.7 defines deterministic local rejection for a second switch during `loading`/`draining`, with exit code 3 and stable diagnostic. |
| R1V-Q.3 WS drop mid-load policy | PARTIAL | §4.8 lines 427-459 | PASS on policy choice: finish local load, reconnect, and conditionally emit `operator_model_swap`; PARTIAL because §4.8 cites an `auth_request` reconnect flow that locked SPEC-001/SPEC-002 define as fresh `hello` (see C2.1). |
| R1V-H.2 CLI name + SPEC-010 citation | PASS | §4.1 lines 156-174; §2.1 lines 99-101; SPEC-010 R-3.6.3 lines 382-392 | The outline uses `macprovider-cli` and cites R-3.6.3 for binary-local pre-flight validation, with R-3.1.4 as the wire containment invariant. |

### Category R1V

See the table above.

### Category S2: Scope-split correctness

(no findings)

§2.2 explicitly leaves coordinator `set_model`, cold-wake routing, parked queues, buyer ETA, `/v1/models` aggregation, `/v1/status.state`, `model_not_warm`, and cold-wake config to SPEC-012. The new §4.2, §4.3, §4.6, §4.7, and §4.8 surfaces remain operator-pushed and heartbeat-observed. §4.3's re-verification rule is coordinator-side behavior, but it is still passive observation of a provider-reported `(model_id, model_hash)` change, not coordinator-managed swap state.

### Category B2: Binary state machine + atomic swap

(no findings)

The §4.2 state machine is implementable against the current Swift actor model if v0.2 chooses the actor-isolated `var current_container` path. `ModelRuntime.swift` currently captures `container` before `inferenceGate.withPermit` and `container.perform`, so per-request snapshot semantics are conceptually aligned, though v0.2 should include concrete Swift-typed pseudocode as §6 already recommends. `loaded` and `failed` read as transient binary-local states, not externally observable wire states.

### Category H2: Heartbeat re-verification rule

(no findings)

Legacy heartbeat behavior is preserved when `model_hash` is absent: §4.3 says the coordinator MUST set `HashStatus = HashStatusUncatalogued`, matching current `ApplyHeartbeat` lines 420-432. The `tier2.require_hash_verified: true` semantics match SPEC-008 §5.6: only `hash_verified` providers route, otherwise requests fail with the existing Tier-2 predicate error. The companion-spec replacement annotation gap is filed once under D2.1.

### Category C2: Concurrent switch + WS drop

### C2.1  §4.8 cites `auth_request` for reconnect, but locked SPEC-001/SPEC-002 reconnects with `hello`   [MAJOR]
Location: SPEC-011 §4.8 lines 432-440; SPEC-001 §6.5 lines 1024-1041 and 1218-1238; SPEC-002 §7.1 lines 1578-1592 and 1654-1681

What: §4.8 says the post-reconnect handshake "`auth_request` re-issued per SPEC-002" carries the final `model_id` and `model_hash`. The locked SPEC-001/SPEC-002 protocol defines provider reconnect admission as a fresh WebSocket open followed by `hello`, then `hello_ack`, then heartbeat. `auth_request` exists in code as a newer auth struct, but it is not the locked reconnect flow cited by SPEC-002 v1.3.4.

Why it matters: v0.2 would otherwise specify the right behavior on the wrong wire surface. That would confuse whether final model/hash evidence arrives in `hello`, heartbeat, or a future auth flow, and it would make the WS-drop policy fail audit against the locked protocol text.

Recommendation: In v0.2, replace the §4.8 wording with "fresh `hello` on reconnect carries the final `model_id` and, if available, `model_hash`; the next heartbeat carries `loading: false`." If the project intends to migrate reconnects to `auth_request`, that belongs in a separate SPEC-001/SPEC-002 candidate annotation, not implicit SPEC-011 text.

### C2.2  Conditional `operator_model_swap` emission creates an intentional audit gap for completed local swaps   [QUESTION]
Location: SPEC-011 §4.6 lines 379-400; §4.8 lines 440-459

What: A successful operator-pushed swap emits `operator_model_swap` only if the coordinator observed a prior `loading: true` heartbeat. If the WS drops during load and reconnects after completion, the coordinator treats the provider as a fresh admission and emits no swap event.

Why it matters: Audit-log readers can see two identical local operator actions produce different coordinator audit histories depending only on disconnect timing. The invariant is coherent, but it may surprise operators who expect a swap event for every successful `models switch`.

Recommendation: Decide in v0.2 whether this is acceptable as an observation-only audit invariant or whether the binary should backfill a post-reconnect "local swap completed while disconnected" signal. Do not add a coordinator-initiated swap protocol to solve this; that would be SPEC-012 scope.

### Category A2: AC plan realism

### A2.1  §5 enumerates 20 ACs but says "Total: 16"   [MINOR]
Location: SPEC-011 §5 lines 469-537

What: The bucket counts add to 20: CLI 4, async load 4, heartbeat 3, Pillar A 2, concurrent switch 1, WS drop 2, backward compatibility 3, audit-log 1. The footer says "Total: 16 ACs in the plan above."

Why it matters: The fix for round-1 A.1 is directionally correct, but the arithmetic drift can confuse the v0.2 drafting target and the post-draft audit budget.

Recommendation: Change the footer to "Total: 20 ACs" or collapse four bullets intentionally and state which ACs are combined. The title's "16-20 ACs" range is fine.

### Category F2: Forward-compatibility with SPEC-012

(no findings)

SPEC-012 can reuse §4.2's binary-local state primitive as long as v0.2 keeps the trigger separate from the state machine: CLI signal now, coordinator `set_model` later. SPEC-011's `loading: bool` heartbeat is enough as the minimal current primitive; SPEC-012 can later layer `/v1/status.state = "loading"` and richer operator visibility without requiring SPEC-011 to expose buyer-facing status now.

### Category D2: Companion-spec annotations

### D2.1  §4.3 replacement of SPEC-002 hash-clearing behavior is not called out in the companion-spec footprint   [MAJOR]
Location: SPEC-011 §4.3 lines 284-332; §4.6 lines 399-400; §6 lines 546-556; `provider.go` lines 420-432

What: §4.3 correctly says the current heartbeat path clears `Provider.ModelHash` and sets `HashStatusUncatalogued` on `ModelID` change, and that v0.2 must replace this when heartbeat `model_hash` is present. But the companion footprint text only clearly calls out one SPEC-002 v1.3.5 addition for the `operator_model_swap` audit event; it does not explicitly list the `ApplyHeartbeat` behavior replacement as a SPEC-002 v1.3.5 candidate normative edit.

Why it matters: This is not just an additive optional field. The current coordinator behavior on model change is "clear hash"; SPEC-011's desired behavior is "store new hash and recompute SPEC-008 status before routing." If v0.2 leaves that as prose inside SPEC-011 only, implementers can update the heartbeat struct and still miss the required replacement in the coordinator state transition.

Recommendation: Add a companion-spec annotation that SPEC-002 v1.3.5 replaces the current heartbeat model-change rule: when `model_id` changes and `model_hash` is present, store the new `ModelHash`, recompute the SPEC-008 §5.3-5.6 state, and only fall back to `HashStatusUncatalogued` when `model_hash` is absent.

### Category E2: Anything else

(no findings)

Documentation drift check: `HANDOFF.md`, `RUNBOOK.md`, `CONTINUE_RUNBOOK.md`, and `AGENTS.md` contain no SPEC-011 / warm-swap / `macprovider-cli models` references to update in this outline audit. Naming is otherwise coherent after the `macprovider-cli` fix, except for the `auth_request` reconnect term already filed as C2.1.

### Round-2 self-verification

- Appended this round-2 section after the round-1 report; round 1 remains intact.
- Read the required files in the prompt's order: SPEC-011 v0.1.1, existing SPEC-011 outline audit, round-1 prompt, CLAUDE.md, SPEC-010, SPEC-012-source, SPEC-001, SPEC-002, SPEC-008, then the required code spot-checks.
- Spot-checked `ModelRuntime.swift` lines 25-68, 86-147 and 139-230; `provider.go` lines 420-432; `messages.go` heartbeat struct lines 121-135; and `MacProviderCLI.swift` lines 7-15.
- Did not inspect d-inference source.
- Covered categories R1V, S2, B2, H2, C2, A2, F2, D2, and E2.
- Every finding has severity, location, what, why, and recommendation.
