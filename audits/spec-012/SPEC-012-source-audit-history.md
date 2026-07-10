# SPEC-010 v0.1 — Audit Report

**Audited:** SPEC-010 v0.1 (specs/SPEC-010-model-catalog.md)  
**Auditor model:** Codex / GPT-5  
**Audit round:** 1 of N  
**Date:** 2026-06-06  
**Total findings:** 2 CRITICAL / 9 MAJOR / 3 MINOR / 2 QUESTION

---

## Executive summary

Verdict: **READY WITH FIX PASS, not ready to implement as-is.**

SPEC-010 is directionally sound: the core split between `supported_models` and the single warm `model_id` is the right additive shape, and the spec preserves the important no-allowlist and one-active-model decisions. The blockers are contract precision, not a failed architecture.

The two CRITICAL issues are default/backward-compatibility leakage and Tier-2 hash-state drift. First, §4.3.3 adds `supported_models` to public `/v1/status` even for legacy providers where `SupportedModels` is synthesized, violating L-1's "no coordinator behavior change with all SPEC-010 fields absent." Second, §8.4 invents `hash_status: unknown`, a value absent from SPEC-008 v0.3 and current coordinator code, on the exact route-safety boundary Pillar A owns.

The MAJOR issues cluster around Phase 1 routing semantics: §4.4 says to select a cold-but-supported provider and rewrite `body.model`, while §4.5 says the same request must return 503 `model_not_warm`; warm-provider preference is only in a candidate companion-spec note, not in Phase 1 normative text; and sticky/hard-pin eligibility ordering is not nailed down. These are fixable with a narrow v0.2 pass before implementation.

## Category A: Locked-decision preservation

### A1. Public `/v1/status` changes for legacy providers

**Severity:** CRITICAL  
**Location:** SPEC-010 §2 L-1 lines 70-76; §4.3.1-§4.3.3 lines 201-207; §7.1 lines 405-410; AC-1/AC-4 lines 494-504. Cross-check current `Provider` has no `SupportedModels` field in `phase4-coordinator/internal/pool/provider.go` lines 50-88.

**What:** §4.3.1 synthesizes `SupportedModels: [ModelID]` when the field is absent, and §4.3.3 then requires public coordinator `/v1/status` to include `supported_models` when non-empty. For a legacy provider, that synthesized list is non-empty, so a provider that sends no SPEC-010 fields still changes a public response.

**Why it matters:** This directly violates L-1: "No coordinator behavior change with all SPEC-010 fields absent." AC-4 only checks gateway `/v1/models`, so this default-regression path would pass the current acceptance suite.

**Recommendation:** Gate public `/v1/status.supported_models` on an explicit provider-sent field, or on a default-false publication flag. Add an AC proving a legacy provider produces byte-identical `/v1/models` and `/v1/status` when `publish_unwarm_models=false` and no SPEC-010 field is sent.

## Category B: Wire-format correctness

### B1. Empty `supported_models: []` is not specified

**Severity:** MAJOR  
**Location:** SPEC-010 §4.1 lines 151-169; AC-7 lines 510-512.

**What:** The spec defines omitted `supported_models` and arrays longer than 64, but not a present empty array. A present empty array is valid JSON array syntax under R-4.1.1, but fails R-4.1.3 because `model_id` cannot appear in it.

**Why it matters:** Implementers can diverge between treating `[]` as legacy omission, rejecting it as `bad_request`, or accepting a provider with no supported models. This affects auth compatibility and error tests.

**Recommendation:** State that a present empty array is invalid and must be rejected with the same `bad_request` code as R-4.1.3, unless the operator explicitly wants `[]` to mean omitted.

### B2. Provider CLI/config validation is only implied

**Severity:** MAJOR  
**Location:** SPEC-010 §4.1.3 lines 156-159; §8.1 lines 449-458. Cross-check current CLI has only `--model` in `MacProviderCLI.swift` lines 24-28, and `ModelRuntime.configuration(for:)` accepts path/cache/HF IDs in `ModelRuntime.swift` lines 246-254.

**What:** Coordinator auth rejects `model_id` not in `supported_models`, but §8.1 only says to add `--supported-models`, env, config, and default `[--model]`. It does not require the provider binary to validate the effective merged config before connecting.

**Why it matters:** A user can launch `--model A --supported-models B,C`, then hit a remote auth rejection instead of a local CLI/config error. This is predictable operator confusion and makes the new field feel brittle.

**Recommendation:** Add a SPEC-001 candidate rule: after CLI > env > config resolution, the provider MUST normalize and validate that loaded `model` is included in `supported_models`, otherwise fail locally with a clear config error before opening the coordinator WS.

### B3. Length caps need exact normalization and diagnostics

**Severity:** MINOR  
**Location:** SPEC-010 §4.1.5-§4.1.7 lines 164-169; AC-8 lines 513-514.

**What:** The spec names 64 entries and 256 bytes per entry, but does not say whether duplicate case variants count before or after case-insensitive normalization, nor what error code/reason applies to a 257-byte entry.

**Why it matters:** This is unlikely to break architecture, but it will create inconsistent tests and logs around malformed provider auth.

**Recommendation:** Define validation order: type check, per-entry byte length, trim/no-trim decision, case-insensitive dedupe, then max unique entries. Add exact `bad_request` reason strings for over-length entry and too-many entries.

## Category C: Routing semantics

### C1. Cold-supported routing contradicts the required 503 path

**Severity:** MAJOR  
**Location:** SPEC-010 §4.4 R-4.4.1/R-4.4.2 lines 228-241; §4.5 R-4.5.3 lines 263-268; AC-5 lines 505-507. Cross-check current buyer path rejects unknown models via `ModelKnown` in `buyer/server.go` lines 1027-1030 and filters candidates by `providerMatchesRequest` plus `baseRoutingEligible` in lines 2200-2206.

**What:** R-4.4.1 says that if candidates support the requested model but none has it loaded, the dispatcher MUST select a candidate and rewrite `body.model` to the candidate's loaded model. R-4.5.3 says the same Phase 1 request MUST return `503 model_not_warm`.

**Why it matters:** A literal implementation can either dispatch to the wrong loaded model or return 503, and both would claim spec compliance. The dispatch-rewrite path is especially risky because it can silently serve a different model than the buyer requested.

**Recommendation:** In Phase 1, do not select a provider for cold-supported model requests. Define the routing flow as: if no warm candidate has `ModelID == req.model`, short-circuit before provider selection with `503 model_not_warm`. Keep the "which candidate to wake" ranking only in Phase 2.

### C2. Warm-provider preference is not normative in Phase 1

**Severity:** MAJOR  
**Location:** SPEC-010 §4.4 lines 211-241; §8.3 lines 469-475; AC-9 lines 515-517.

**What:** AC-9 requires a request for A to always route to the warm provider when two providers support A but only one has A loaded. The only text that says "prefer warm" is §8.3, a SPEC-004 v0.4 candidate annotation. Phase 1's normative §4.4 candidate predicate admits both providers and does not state that `ModelID == req.model` is a hard preference.

**Why it matters:** Existing SPEC-004 ranking could choose the cold provider if it has better throughput/slots, making AC-9 fail or requiring implementers to infer behavior from a vNEXT annotation.

**Recommendation:** Move warm preference into §4.4 normative text: when at least one candidate has `ModelID == req.model`, all non-warm candidates for that request are ineligible in Phase 1. Only Phase 2 may consider waking cold candidates.

### C3. Sticky and hard-pin eligibility order is unclear

**Severity:** MAJOR  
**Location:** SPEC-010 §4.4 lines 211-223; SPEC-004 FR-SR-18 lines 522-526; current pinned validation in `buyer/server.go` lines 2730-2739.

**What:** §4.4 says to add `SupportedModels` containment before `ModelID == request.model` fall-through, but does not say whether that predicate is applied before sticky soft affinity, hard pins, retry, and preflight advancement.

**Why it matters:** SPEC-004 requires no feature to route to a provider SPEC-002 considers ineligible. Without an explicit placement rule, a sticky or hard-pinned provider that merely supports but does not have the requested model warm could bypass the `model_not_warm` behavior.

**Recommendation:** State that warm-model eligibility is applied to every provider selection attempt in Phase 1: initial selection, sticky hit, hard-pin validation, preflight advancement, failover, and retry. A hard pin to a non-warm supported model should fail deterministically with the same `model_not_warm` envelope unless Phase 2 hot-swap is enabled.

## Category D: Gateway and API behavior

### D1. Byte-identical `/v1/models` restoration is under-specified

**Severity:** MAJOR  
**Location:** SPEC-010 §4.5.1/§4.5.4 lines 256-271; §4.6.2 lines 295-296; §7.1 lines 408-410; AC-4 lines 503-504.

**What:** R-4.5.1 says every returned model entry MUST include `warm: bool`. R-4.5.4 says legacy providers default `warm` to true. §7.1 then says a legacy provider's `/v1/models` output is identical to pre-SPEC-010, even though pre-SPEC-010 entries did not have `warm`.

**Why it matters:** AC-4 cannot pass byte-for-byte if `warm: true` remains present. This is the same class of default-preservation bug caught in prior SPEC-008 audits.

**Recommendation:** Define `publish_unwarm_models=false` as suppressing both unwarm entries and all additive `warm` fields. If `publish_unwarm_models=true`, explicitly mark `/v1/models` as non-byte-identical.

### D2. `model_not_warm` error envelope is not testable

**Severity:** MAJOR  
**Location:** SPEC-010 §4.5.3 lines 263-268; AC-5 lines 505-507. Cross-check SPEC-002 buyer errors use OpenAI-compatible codes, e.g. `model_not_found` in `buyer/server.go` lines 1027-1030.

**What:** The spec says `503 model_not_warm` with `retry_after_seconds` hint, but does not define the HTTP headers, OpenAI error envelope fields, exact `error.type`, exact `error.code`, message, or whether `Retry-After` must match `retry_after_seconds`.

**Why it matters:** Gateway/coordinator tests will diverge, and SDK clients may parse the body differently from existing errors.

**Recommendation:** Add an error table row: HTTP 503, `error.type`, `error.code: "model_not_warm"`, exact message template, JSON location for `retry_after_seconds`, optional/required `Retry-After` header, and behavior for streaming requests before/after response commit.

### D3. Defaulting `publish_unwarm_models=true` is a product decision, not settled by the spec

**Severity:** QUESTION  
**Location:** SPEC-010 §4.6.1 lines 291-294; §7.3 lines 422-439; OQ-1 lines 533-536.

**What:** The spec intentionally defaults to a buyer-visible behavior change: `/v1/models` advertises models that will 503 in Phase 1.

**Why it matters:** This improves discoverability, but it also makes OpenAI SDK model pickers show entries that cannot yet serve a request. The prior SPEC-008 default-preservation posture would normally push this behind an explicit opt-in until the behavior is actionable.

**Recommendation:** Operator decision. My recommendation is default `publish_unwarm_models=false` until Phase 2 hot-swap is available, or expose unwarm entries only on a separate discovery/status endpoint in Phase 1.

## Category E: Phase 2 hot-swap design

### E1. Sticky TTL cross-reference points at the wrong source

**Severity:** MINOR  
**Location:** SPEC-010 §5.1.5 lines 328-331; SPEC-008 F-1.5 survivability invariants in §2.1-§2.4.

**What:** R-5.1.5 has the right MUST: hot-swap must not extend sticky TTL or change `conv:` derivation. But it cites "SPEC-006 sticky-affinity TTL" and cross-checks "SPEC-008 §2.1"; the TTL invariant is SPEC-008 §2.4, while §2.1 is the HMAC derivation invariant.

**Why it matters:** The substance is correct, but future hot-swap implementers need the exact survivability invariant references because sticky lifecycle mistakes are security/privacy-sensitive.

**Recommendation:** Cite SPEC-008 F-1.5 §2.1 for derivation and §2.4 for TTL. Keep the MUST unchanged.

## Category F: Tier-2 / Pillar A compatibility

### F1. `hash_status: unknown` is an unsupported Tier-2 state

**Severity:** CRITICAL  
**Location:** SPEC-010 §8.4 lines 477-484; SPEC-008 v0.3 hash states lines 723-744; current coordinator `HashStatus` constants in `provider.go` lines 37-42 and route exclusion in `buyer/server.go` lines 2765-2782.

**What:** §8.4 says that after hot-swap, until verification completes, `hash_status` is `unknown` and routing follows SPEC-008 §C.5. SPEC-008 v0.3 and the current code have no `unknown` state; the finite states are `hash_verified`, `hash_mismatch`, `hash_invalid`, `uncatalogued`, and `catalog_unavailable`.

**Why it matters:** This changes the Tier-2 state machine in a vNEXT note while claiming compatibility with locked SPEC-008 semantics. A new unknown state also changes routing under `require_hash_verified`, exactly where Pillar A prevents serving unverified or mismatched model identity.

**Recommendation:** Do not introduce `unknown` in SPEC-010. Map the swap window to an existing SPEC-008 state, likely `uncatalogued` until verification completes, or explicitly mark a future SPEC-008 vNEXT change with exact route predicates and ACs.

## Category G: Acceptance criteria completeness

### G1. AC suite misses malformed wire and default-preservation cases

**Severity:** MAJOR  
**Location:** SPEC-010 AC-1 through AC-10 lines 494-520; related rules §4.1.1-§4.1.7 lines 151-169, §4.2 lines 176-180, §4.3.3 lines 206-207, §4.6.2 lines 295-296.

**What:** The ACs cover the happy path, mismatch, over-64 array, cold 503, unsupported 404, warm preference, and hash scoping. They do not cover malformed non-array values, non-string array entries, a present empty array, per-entry 257-byte strings, case-insensitive dedupe/compare, `supported_models` immutability across heartbeats, legacy `/v1/status` byte identity, or suppression of `warm` fields when `publish_unwarm_models=false`.

**Why it matters:** These are exactly the branches where additive wire changes tend to regress legacy compatibility or produce inconsistent error behavior.

**Recommendation:** Add focused ACs for malformed type rejection, empty array policy, per-entry length, case-insensitive normalization, heartbeat immutability, legacy status byte identity, and `warm` suppression under `publish_unwarm_models=false`.

### AC walkthrough required by audit prompt

| AC | Exact test setup | Exact assertion |
|---|---|---|
| AC-1 | Start coordinator/gateway with a SPEC-010 provider advertising `supported_models=[A,B,C]`, `model_id=A`. | Registration succeeds; internal provider has `ModelID=A`, `SupportedModels=[A,B,C]`; public status shows all three only if publication is enabled by the fixed compatibility rule. |
| AC-2 | Start legacy provider sending only `model_id=A` through the current hello/auth shape. | Registration succeeds; internal `SupportedModels=[A]`; no warning; no public response changes unless explicitly enabled. |
| AC-3 | `publish_unwarm_models=true`; one ready provider has `model_id=A`, `supported_models=[A,B]`. | Gateway `/v1/models` includes B exactly once with `warm:false`; A has `warm:true`. |
| AC-4 | Same pool as AC-3, but `publish_unwarm_models=false`; capture pre-SPEC-010 golden `/v1/models`. | Response bytes match the golden exactly, including no `warm` field and no unwarm B entry. |
| AC-5 | Same pool as AC-3; POST chat with `model=B`. | Before provider dispatch, return HTTP 503 with OpenAI envelope `model_not_warm` and `retry_after_seconds`; no provider receives the request. |
| AC-6 | Pool supports only A/B; POST chat with `model=Z`. | Return existing HTTP 404 `model_not_found`; no provider receives the request. |
| AC-7 | Provider sends `model_id=A`, `supported_models=[B]`. | Auth is rejected with `auth_response.error.code="bad_request"` and stable reason containing `model_id not in supported_models`. |
| AC-8 | Provider sends 65 unique supported model IDs. | Auth is rejected with `bad_request`; provider is not added to pool; rejection is logged without dumping the full list. |
| AC-9 | Two ready providers both support A; provider P1 has `model_id=A`, P2 has `model_id=B`. | Repeated chat requests for A select P1 every time, regardless of P2's SPEC-004 ranking metrics. |
| AC-10 | Provider sends `model_id=A`, `model_hash=hash(A)`, `supported_models=[A,B]`, with Tier-2 catalog entries for A and B. | Coordinator verifies only A/hash(A); B remains unverified/uncomputed and cannot create hash mismatch or verification success events. |

## Category H: Companion-spec annotations

Standalone findings: (no findings).

Cross-category notes: C2 must be fixed by moving warm preference from the SPEC-004 candidate note into Phase 1 normative routing text. F1 must be fixed before the SPEC-008 compatibility note is safe. J1 covers stale companion-version references.

## Category I: Canary symptom closure

### I1. "Phase 1 alone closes the canary symptom" is overstated

**Severity:** MAJOR  
**Location:** SPEC-010 symptom list lines 22-39; phase plan lines 83-123; root-gap summary lines 59-61.

**What:** The canary symptom had four concrete pieces: no running CLI switch, restart/cold-load/red dashboard, model picker shows only loaded model, and no recommended catalog. Phase 1 only addresses capability advertisement and partial buyer discoverability. It does not provide a running model switch, avoid reconnect/cold load, or publish a recommended provider catalog.

**Why it matters:** This can lead implementers/operators to expect SPEC-010 v0.1 to fix the operational pain that actually requires Phase 2 and Phase 3.

**Recommendation:** Reword the phase plan: "Phase 1 closes G-2/G-3 and partially improves G-5; Phase 2 closes G-1; Phase 3 closes provider-facing catalog discovery."

### I2. Demand-pulled hot-swap may need to move earlier, or Phase 1 should narrow its promise

**Severity:** QUESTION  
**Location:** SPEC-010 §3 lines 83-123; §5.3 lines 350-362; OQ-3 lines 541-544.

**What:** The spec asks whether Phase 1 should include demand-pulled hot-swap. Given the current Phase 1 cold-request behavior is "advertise then 503," the answer drives the product promise.

**Why it matters:** If buyers see unwarm models in `/v1/models`, demand-pulled hot-swap is the feature that makes those entries useful instead of frustrating.

**Recommendation:** Operator decision. Either keep Phase 1 strictly informational and default-hide unwarm models, or pull a minimal demand-pulled swap into Phase 1 with conservative ETA/cooldown limits.

Canary mapping:

| Canary symptom | Phase 1 | Phase 2 | Phase 3 |
|---|---:|---:|---:|
| No CLI command to change active model | No | Yes | No |
| Restart causes reconnect/cold load/red dashboard | No | Yes | No |
| Picker shows only loaded model | Partial | Yes, if hot-swap is exposed | Yes |
| Operator cannot discover expected HF IDs | No | No | Yes |

## Category J: Spec hygiene and future-proofing

### J1. Companion version references are stale relative to the repo files read for this audit

**Severity:** MINOR  
**Location:** SPEC-010 header lines 11-16; SPEC-002 header lines 1-10; SPEC-008 header lines 1-12; SPEC-010 §8.4 line 477.

**What:** SPEC-010 says it companions SPEC-002 v1.3.3 and SPEC-008 v0.1, while the files in the required reading list are SPEC-002 v1.3.4 and SPEC-008 v0.3. §8.4 then labels the compatibility note "SPEC-008 v0.2."

**Why it matters:** This is mostly editorial, but stale version anchors make it easier to cite already-fixed old semantics, as happened with `hash_status: unknown`.

**Recommendation:** Update the header and companion sections to the actual locked baseline versions in the repo, or explicitly state that SPEC-010 intentionally audits against older frozen versions despite newer files being present.

## Self-verification

- Read the required files in the prompt's order: SPEC-010, CLAUDE.md, SPEC-001, SPEC-002, SPEC-004, SPEC-008, beta decision log, required code spot-checks, prior SPEC-006 and SPEC-008 audits.
- Did not inspect d-inference source.
- Covered categories A through J.
- Every finding includes severity, location, what, why, and recommendation.
- Walked AC-1 through AC-10 with test setup and assertion.
- Verdict included in the executive summary.

---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v0.2 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 12 MAJOR / 1 MINOR / 1 QUESTION

### Round-2 executive summary

Verdict: **READY WITH SECOND FIX PASS, not ready to implement as-is.**

SPEC-010 v0.2 genuinely closes the two round-1 CRITICAL findings. Public `/v1/status.supported_models` is now gated by `publishes_supported_models` (R-4.1.6, R-4.3.3, AC-2), and the Tier-2 swap window no longer invents `hash_status: "unknown"`; it uses `swap_pending/loading_model` route-ineligibility plus post-swap Pillar A verification (R-4.4.7, §8.4, AC-19). The v0.2 restructure also fixes the core C1/C2 routing contradiction by pulling demand-pulled `set_model` into Phase 1 and making warm-first ranking normative.

The remaining blockers are not architectural reversals. They are implementation-contract gaps in the newly normative v0.2 surface: cold-wake parked queues are unbounded, retry/accounting semantics around cold-wake are not tied to the existing per-attempt billing/request-log contracts, `set_model` correlation and `drain_timeout` failure semantics are under-specified, SPEC-008 `/v1/models.hash_verification` is undefined for cold-supported entries, swap audit event payloads are missing, and several new R-4 rules lack deterministic ACs.

The only round-1 fix I do not consider fully closed is I1. v0.2 honestly fixes the demand-pulled swap mechanism for pain #1/#2, but §3 still says Phase 1 closes pain #3 even though the default `publish_unwarm_models: false` keeps the buyer picker warm-only unless an operator opts in. B3 is also only partially closed: NFC + ASCII case folding is now specified, but duplicate/diagnostic behavior remains thin.

### Round-1 fix verification (R1V)

| Round-1 finding | Status | v0.2 location verified | Evidence |
|---|---|---|---|
| R1V-A1 public `/v1/status` legacy leakage | PASS | §4.1 R-4.1.6 lines 192-197; §4.3 R-4.3.3 lines 243-247; AC-2 lines 785-789 | `supported_models` appears in public status iff `PublishesSupportedModels == true`; legacy providers are explicitly false. |
| R1V-F1 unsupported `hash_status: unknown` | PASS | Change log lines 35-39; R-4.4.7 lines 350-367; §8.4 lines 757-770; AC-19 lines 868-875 | v0.2 names only SPEC-008's five states and handles the swap window via route-ineligible `swap_pending/loading_model`. |
| R1V-C1 cold-supported routing vs 503 contradiction | PASS | §4.5.2 lines 411-414; §4.5.3 lines 431-456; §4.5.4 lines 458-464; AC-11/12 lines 826-834 | The flow is now warm-first, then cold-wake when enabled, or immediate `503 model_not_warm` when disabled. |
| R1V-C2 warm-provider preference not normative | PASS | §4.5.2 lines 400-414; AC-10 lines 821-825 | Warm-first is a Phase 1 normative MUST, not only a companion-spec note. |
| R1V-C3 sticky/hard-pin order unclear | PASS | §4.5.2 lines 416-427 | Sticky-break and hard-pin-to-cold behavior are explicitly ordered, though see the cooldown error-code coverage gap below. |
| R1V-B1 empty `supported_models: []` unspecified | PASS | R-4.1.1 lines 170-174; AC-3 lines 790-792 | Present empty array must be rejected with `bad_request` and deterministic reason text. |
| R1V-B2 provider CLI validation implied | PASS | §4.8 R-4.8.1-R-4.8.3 lines 583-600; AC-7 lines 801-804 | Local pre-flight validation before WS connect is now a MUST and AC-7 tests the exit path. |
| R1V-B3 length caps and normalization | PARTIAL | R-4.1.2 lines 175-178; R-4.1.7 lines 198-202; AC-5/6 lines 796-800 | NFC + ASCII case folding is specified, but duplicate normalized entries and exact over-cap diagnostics remain under-specified. |
| R1V-D1 byte-identical `/v1/models` | PASS | R-4.6.1.2 lines 488-494; lines 498-501; AC-8 lines 808-812 | Default `publish_unwarm_models: false` suppresses unwarm entries and the `warm` field, making AC-8 achievable for legacy pools. |
| R1V-D2 `model_not_warm` envelope | PASS | §4.6.2 lines 503-533; AC-21 lines 884-888 | The HTTP status, `Retry-After`, `error.code`, `error.type`, `param`, and `retry_after_seconds` are specified. |
| R1V-I1 Phase 1 canary closure claim | PARTIAL | §3 lines 98-118; AC-22 lines 892-899 | Demand-pulled swap now fixes pain #1/#2 mechanically, but §3 still claims pain #3 while default `/v1/models` remains warm-only. |
| R1V-J1 stale companion versions | PASS | Header lines 6-7; §12 lines 956-960 | SPEC-002 v1.3.4 and SPEC-008 v0.3 are now the locked companion anchors. |

Status checks for findings not claimed fixed: D3 is now a v0.2 design decision: `publish_unwarm_models` flipped to default `false`, with cold-wake latency called out in §7.3. I2 is resolved by restructure: demand-pulled hot-swap moved into Phase 1.

### Category A2: Locked-decision preservation (v0.2 reverification)

(no findings)

L-1 is enforced by R-4.1.5, R-4.1.6, R-4.3.3, R-4.6.1.2, R-4.7.1, and §7.1-§7.3. L-2 is preserved by accepting provider-declared model IDs subject only to shape/length rules. L-3 is preserved at the routing surface by R-4.4.4 and R-4.4.5: in-flight OLD-model work drains, but no new buyer request routes during swap. L-4 is preserved by R-4.4.7 and §8.4. L-5 is untouched by SPEC-010. L-6 is preserved by R-4.4.8 and AC-23; the `set_model` schemas contain no `conv:`, `account_id`, sticky ID, or AAD-like sticky input.

### Category B2: Wire-format correctness (v0.2 new fields)

### B2.1 `set_model.request_id` format is example-only   [MAJOR]
Location: §4.4, line ~259-266; R-4.4.3, line ~328-335

The examples use `request_id: "swap_01HK4..."`, but no rule defines required format, uniqueness window, collision handling, or whether these IDs share the same namespace as buyer `request_id` values. The coordinator depends on the field to correlate ack/complete/failure messages.

If implementations choose different namespaces or accidentally reuse buyer request IDs, a stale `set_model_complete` could complete the wrong swap or make audit correlation ambiguous.

Recommendation: add a short normative rule, e.g. coordinator-generated `swap_<ULID>` or equivalent globally unique swap ID, unique among active and recently completed swaps for a bounded retention window.

### B2.2 `set_model_complete.reason_code: "drain_timeout"` conflicts with R-4.4.6   [MAJOR]
Location: §4.4 failure example, line ~304-313; R-4.4.6, line ~344-349

The failure enum includes `drain_timeout`, but R-4.4.6 says drain timeout sends `503 swap_drain_timeout` to still-in-flight requests and then the swap proceeds. That makes drain timeout a per-inference failure, not necessarily a `set_model_complete{result:"failed"}` reason.

Implementers can diverge between completing the swap after timeout, failing the whole swap, or doing both. This directly affects parked-request release and provider state.

Recommendation: decide whether drain timeout is only an in-flight-request outcome or can fail the entire swap, and make the enum/rule consistent.

### B2.3 `swap_reason` future value is not decided   [QUESTION]
Location: §4.4.8, line ~371-373; OQ-5, line ~932-934

`swap_reason` is defined with `demand_pull | operator_push | policy`, while OQ-5 still asks whether `"policy"` should be added. The body already includes it.

This is not a blocker, but future readers should not see an open question for a value the normative enum already contains.

Recommendation: close OQ-5 as decided, or remove `"policy"` from the Phase 1 enum until the policy path exists.

### Category C2: Routing semantics (v0.2)

### C2.1 Cold-wake retry lacks request-log and billing attempt semantics   [MAJOR]
Location: §4.5.3.5, line ~445-453

The cold-wake path may retry once on another cold candidate before any provider has served inference. The spec does not say whether this produces one buyer request-log row, multiple swap-attempt records, or any `retried`/attempt accounting visible to SPEC-005/SPEC-006.

SPEC-005 relies on per-attempt rows when providers actually do work, while no provider-reached paths write zero ledger rows. Cold-wake sits between those: providers may spend load/drain resources without an inference attempt, and a later dispatch may still bill normally.

Recommendation: state that cold-wake swap attempts are not billable inference attempts and define their audit/request-log representation separately from SPEC-004 provider-retry attempts.

### C2.2 Parked-request queue is unbounded   [MAJOR]
Location: R-4.5.3.3, line ~438-441

Additional buyer requests for the same `req_model` may join a per-swap queue, but there is no maximum queue depth, memory bound, per-account cap, or backpressure rule.

A thundering herd for one cold-supported model could allocate an unbounded parked-request map for up to the ETA window, exactly when the coordinator is already doing swap coordination.

Recommendation: add a config-backed maximum queue depth or memory budget per swap/model/account, with deterministic overflow behavior such as immediate `503 model_not_warm`.

### C2.3 Default drain/load/retry timing leaves little practical retry budget   [MINOR]
Location: R-4.4.6 lines ~344-349; §4.7 lines ~556-563; R-4.5.3.6 lines ~454-456

The defaults give 30s for drain and 60s total buyer ETA. With a typical 15-25s load, any drain near the default leaves little or no time for the one retry path to run before the buyer budget expires.

This does not break correctness, but the retry path may be mostly theoretical under the default values.

Recommendation: either document that retry is best-effort and rare under defaults, or tune drain/load/ETA defaults with explicit slowest-provider margin.

### Category D2: Backward compatibility (v0.2)

(no findings)

Legacy provider behavior is covered by R-4.1.5, R-4.3.3, R-4.6.1.2, §7.1, and AC-8/9. The current `ws/messages.go` path uses `json.Unmarshal` helpers and no auth-path `DisallowUnknownFields`, so SPEC-010 providers are compatible with legacy coordinators. `ModelKnown()` has one production caller at `phase4-coordinator/internal/buyer/server.go:1027`, where expanding known-ness to cold-supported models intentionally changes 404 to cold-wake/503 only when SPEC-010 fields are present.

### Category E2: SPEC-008 / Pillar A interaction

### E2.1 SPEC-008 `/v1/models.hash_verification` is undefined for cold-supported entries   [MAJOR]
Location: SPEC-010 §4.6.1, line ~470-494; §8.4, line ~762-769; SPEC-008 §5.7, lines ~773-803

When `publish_unwarm_models: true`, `/v1/models` can include cold-supported entries with no currently routable provider serving that model. SPEC-008 §5.7 defines `hash_verified` and `hash_verification` over "currently routable providers for that model," but a cold-supported entry has none until after swap.

If Pillar A observation is active, implementers cannot tell whether to omit the hash block, emit `uncatalogued`, set provider counts to zero, or count supported-but-not-loaded providers. Counting supported entries would violate L-4; omitting without a rule creates client-visible ambiguity.

Recommendation: add a SPEC-010 rule for cold-supported `/v1/models` entries under Pillar A observation: supported-only entries are not hash-verified and supported models must not contribute to SPEC-008 provider counts until loaded/routable.

### Category F2: Operator UX completeness (I1 closure check)

### F2.1 Phase 1 still overclaims buyer-picker pain #3   [MAJOR]
Location: §3, lines ~96-118; R-4.6.1.2, lines ~488-494; §7.3, lines ~695-707

§3 says Phase 1 alone closes pain points #1, #2, and #3, but default `publish_unwarm_models: false` means `/v1/models` and buyer pickers remain warm-only unless an operator opts in.

This is a product-honesty gap, not a routing bug. The safer default is reasonable, but it means the picker pain is opt-in/partial, not closed by default Phase 1.

Recommendation: change the phase-plan claim to "#1/#2 closed; #3 closed only when `publish_unwarm_models: true` or in Phase 3 catalog surfaces."

### F2.2 "No red dashboard" is asserted in AC-22 but dashboard behavior is out of scope   [MAJOR]
Location: AC-22, lines ~892-899; §11, lines ~950-951

AC-22 requires verifying "no red dashboard" during automatic swap, while §11 says operator UI/dashboard for swap monitoring is Phase 3+ out of scope. The spec does not define what coordinator/gateway status should expose for `swap_pending` or `loading_model`, nor what dashboard color/state should render.

An implementer can pass the swap mechanics and still fail the operator-visible "restart causes red dashboard" pain if dashboards treat non-ready as down.

Recommendation: either remove the dashboard assertion from AC-22 or add a minimal Phase 1 status contract for swap states, such as amber/loading rather than down/red.

### Category G2: AC coverage (23 ACs in v0.2)

### G2.1 New normative rule coverage still has gaps   [MAJOR]
Location: §4 rules, lines ~170-625; AC-1 through AC-23, lines ~780-903

Several R-4 rules have no deterministic AC or only partial coverage: R-4.1.7 normalized duplicate handling, R-4.1.8 legacy `hello` fields, R-4.3.4 `seenModels`/`ModelKnown` expansion, R-4.4.9 swap audit events, R-4.6.1.1 `warm: true/false` when publishing unwarm models, R-4.8.1/2/4/5 CLI flags and set_model handling, and R-4.9.1 operator-pushed swap constraint.

These are precisely the new normative surfaces most likely to drift during implementation because they are not exercised by AC-1 through AC-23.

Recommendation: add targeted ACs for each uncovered cluster, especially normalized duplicates, legacy `hello`, `seenModels`, audit events, published `warm` fields, CLI flag/env/config resolution, provider `set_model` handling, and operator-pushed local refusal.

### G2.2 Cooldown rejection branch lacks an AC   [MAJOR]
Location: §4.5.2 lines ~424-427; R-4.5.3.5 lines ~445-453; AC-17 lines ~858-861

AC-17 covers not issuing a second `set_model` to a provider within cooldown, but it does not explicitly cover `set_model_ack{state:"rejected", reason_code:"cooldown"}` and the resulting cold-wake fallthrough/retry behavior.

That branch is materially different: the coordinator has already selected a cold candidate and received a provider rejection. Without an AC, implementers may leave parked requests stuck or fail to advance to the next candidate.

Recommendation: add a negative-path AC where the selected provider rejects with `cooldown`, parked requests retry once on another eligible cold candidate or receive `503 model_not_warm`.

### G2.3 Audit-log event payloads and AC are missing   [MAJOR]
Location: R-4.4.9, lines ~374-379; §8.2 lines ~741-743; AC list lines ~780-903

R-4.4.9 requires `model_swap_started`, `model_swap_completed`, and `model_swap_failed`; §8.2 also names `cold_wake_queued` and `cold_wake_drained`. No payload shape is defined and no AC verifies emission.

Audit logs are how operators debug swap failures, drain timeouts, and parked-request latency. Event names alone are not enough for implementation or tests.

Recommendation: define required payload fields at least for `request_id`, provider identity, old/new model IDs, reason, duration, result/failure code, parked request count, and ETA outcome; add an AC asserting those fields.

### Category H2: Companion-spec annotations (v0.2)

### H2.1 SPEC-001 async-load candidate is not implementable from §8.1 alone   [MAJOR]
Location: §8.1, lines ~717-731; §4.4 lines ~255-379; §4.8 lines ~583-607

§8.1 says SPEC-001 v1.2.5 should add async load, swap mechanism, drain semantics, rollback-on-failure, and WS handlers, but it does not include provider-side state timing or error behavior. The required details exist scattered in §4.4 and §4.8, not in the candidate annotation itself.

A future BUILD prompt that uses §8.1 as its source will need to pull in §4.4 and resolve the `drain_timeout` ambiguity above before implementation.

Recommendation: either make §8.1 explicitly incorporate §4.4/R-4.8 by reference as normative source text, or expand §8.1 enough that the provider-side BUILD prompt is self-contained.

### H2.2 Swap audit event payloads are undefined in both §4.4.9 and §8.2   [MAJOR]
Location: §4.4.9 lines ~374-379; §8.2 lines ~741-743

The companion-spec annotation names event types but no payload schema. This is separate from AC coverage: SPEC-002 §11 is an audit namespace, so future implementers need stable field names and redaction rules.

Without a payload schema, logs may omit the swap `request_id`, old/new model IDs, parked queue size, cooldown status, or failure reason, making later incident review weak.

Recommendation: define payload shape in SPEC-010 now, and let SPEC-002 v1.3.5 import it rather than inventing it during the build.

### Category I2: Anything else

(no findings)

No clean-room violation was found. No v0.2 clause requires inspecting d-inference source. A decision-log entry should be added when SPEC-010 locks, but this draft is explicitly pre round-2 audit, so I am not filing that as a finding.

### Self-verification

- Read the required files in order: SPEC-010 v0.2, SPEC-010 round-1 audit, round-1 prompt, CLAUDE.md, SPEC-001, SPEC-002, SPEC-004, SPEC-008, decision log entries context, required code spot-checks, SPEC-006 audit, SPEC-008 audit.
- Did not inspect d-inference source.
- Round-1 findings are each marked PASS / PARTIAL / FAIL in R1V.
- Every category R1V and A2-I2 has a section.
- Every finding has severity, location, what, why, and recommendation.
- Round-2 executive summary states a clear verdict.

---

## Round 3 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v0.3 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N
**Date:** 2026-06-06
**Total findings:** 1 CRITICAL / 12 MAJOR / 3 MINOR / 1 QUESTION

### Round-3 executive summary

Verdict: **NOT READY TO LOCK; ready for another narrow fix pass after the CRITICAL and MAJOR findings are closed.**

SPEC-010 v0.3 is a real improvement over v0.2. Most round-2 findings are closed in substance: swap request IDs now have a namespace and retention rule, drain timeout is correctly scoped to in-flight requests, `swap_reason` no longer advertises a nonexistent policy producer, queue bounds exist, the default timing budget is more plausible, and the operator-facing `state: "loading"` contract is much clearer than the v0.2 "no red dashboard" assertion.

The remaining blocker is cross-spec shape, not the warm-swap architecture. The largest issue is that R-4.6.1.4 tells cold-supported `/v1/models` entries to omit SPEC-008 §5.7 hash fields while §8.4 simultaneously claims no SPEC-008 change is required; locked SPEC-008 says those fields are required on `/v1/models` entries when Pillar A observation/enforcement is active. v0.3 also leaves no swap failure stage for no-response/timeouts, retries on a rejection code it calls a coordinator bug, has an AC-35 request-log contradiction, and has several acceptance-coverage gaps around the new v0.3 normative surface.

### Round-2 fix verification (R2V)

| Round-2 finding | Status | v0.3 location verified | Evidence |
|---|---|---|---|
| R2V-B2.1 request_id format example-only | PASS | §4.4 R-4.4.0 lines 407-421 | `set_model` IDs are now coordinator-generated `swap_<ULID>`, unique across active and recently completed swaps, with stale responses discarded. |
| R2V-B2.2 drain_timeout in failure enum | PASS | §4.4 failure example lines 390-403; R-4.4.6 lines 448-461 | `drain_timeout` is removed from `set_model_complete{failed}.reason_code`; timeout produces per-request `503 swap_drain_timeout` and the swap proceeds. |
| R2V-B2.3 swap_reason policy undecided | PASS | R-4.4.8 lines 480-489; §10 lines 1369-1371 | `swap_reason` is a closed two-value enum and OQ-5 is marked closed. |
| R2V-C2.1 cold-wake billing semantics undefined | PARTIAL | R-4.5.3.7 lines 666-683; AC-35 lines 1347-1353 | The body correctly says cold-wake swaps are not billable inference attempts, but AC-35 contradicts the final-503 request-log row rule. |
| R2V-C2.2 parked-request queue unbounded | PARTIAL | R-4.5.3.8 lines 684-700; §4.7 lines 834-837; AC-33/34 lines 1334-1343 | Three caps and deterministic 503 overflow now exist, but per-account identity and post-overflow drain behavior remain under-specified. |
| R2V-C2.3 default timing leaves no retry budget | PASS | §4.7 lines 819-829; R-4.7.3 lines 853-861 | Defaults are retuned to drain 20s and ETA 90s, with explicit retry-budget rationale. |
| R2V-E2.1 SPEC-008 hash block undefined for cold entries | PARTIAL | R-4.6.1.4 lines 741-759 | v0.3 defines omission for cold entries, but that omission conflicts with locked SPEC-008 §5.7's active-Pillar `/v1/models` field requirements. |
| R2V-F2.1 Phase 1 overclaims pain #3 | PASS | §3 lines 174-181 | Pain #3 is now honestly qualified as closed only when `publish_unwarm_models: true` or by Phase 3 catalog. |
| R2V-F2.2 no-red-dashboard lacks coord support | PASS | §4.10 lines 911-945; AC-22 lines 1240-1249 | `/v1/status` now has a `state: "loading"` contract and AC-22 tests the coordinator status value rather than dashboard colors. |
| R2V-G2.1 R-4 rule coverage gaps | PASS | AC-24 through AC-30 lines 1257-1303 | The specific v0.2 gaps for duplicates, legacy `hello`, `seenModels`, `warm`, CLI resolution, swap handling, and operator-pushed refusal now have ACs. |
| R2V-G2.2 cooldown rejection branch lacks AC | PASS | AC-31 lines 1307-1316 | The cooldown rejection branch now tests retry on another cold candidate within remaining ETA budget. |
| R2V-G2.3 audit-log event payloads missing | PARTIAL | R-4.4.9 lines 490-582; AC-32 lines 1320-1330 | Five payload schemas exist, but timeout/no-response and some drain outcomes remain uncovered or unrepresented. |
| R2V-H2.1 SPEC-001 candidate not implementable from §8.1 alone | PASS | §8.1 lines 1040-1059 | §8.1 now imports §4.1, §4.4, §4.8, §4.9, and §4.10 as binding source text. |
| R2V-H2.2 swap audit event payloads undefined | PARTIAL | Same as R2V-G2.3 | Payloads exist, but §8.2 still does not explicitly reference R-4.4.9 and the timeout/no-response payload is absent. |
| R2V-B3 length cap normalization | PASS | R-4.1.9 lines 270-289; AC-24 lines 1259-1264 | v0.3 defines exact validation order and reason strings, including normalized duplicate handling. |
| R2V-I1 Phase 1 closes canary | PASS | §3 lines 174-181; AC-22 lines 1240-1249 | v0.3 limits the Phase 1 closure claim to demand-pull/no-restart plus opt-in picker improvement. |
| R2V-C2.3 (MINOR) retry budget documented | PASS | §4.7 and R-4.7.3 lines 819-861 | The retry budget is now explicit and defaults are retuned. |

Status notes: OQ-2 and OQ-4 remain open in §10 by design.

### Category A3: Locked-decision preservation (v0.3 re-verification)

### A3.1 AC-35 contradicts the final-503 request_log rule   [MAJOR]
Location: §4.5.3.7 lines 666-683; AC-35 lines 1347-1353; SPEC-002 §FR-B9 lines 1095-1124; SPEC-005 §6.2 lines 516-524

R-4.5.3.7 says the buyer's eventual successful dispatch or final 503 writes exactly one `request_log` row per buyer request, but AC-35 expects the `request_log` table to contain zero rows for a cold-wake request that ultimately 503s. SPEC-002 says every buyer request is logged, and SPEC-005 counts provider-not-reached 503s through `request_log` rows with `provider_assigned_id IS NULL`.

This creates a billing/reconciliation test that can pass only by violating the locked request-log contract, or by ignoring AC-35. It also makes C2.1 only partially closed because implementers cannot tell whether "not billable" means "no ledger row" or "no request_log row."

Recommendation: Change AC-35 to assert zero SPEC-005 ledger/settlement rows and one final `request_log` row with no provider assignment for the 503 path. Keep zero `request_log` rows only for cold-wake swap attempts themselves.

### A3.2 Per-account queue bounds lack a normative account key   [MAJOR]
Location: §4.5.3.8 lines 684-700; SPEC-006 §1.3 lines 165-178

R-4.5.3.8 requires a per-account parked-request cap, but SPEC-010 does not say which authenticated account identifier the coordinator uses, how direct coordinator traffic without gateway account context is counted, or whether the key is raw `account_id`, an internal account key, or a redacted derivative. The audit payloads correctly forbid raw `account_id`, but the queue-bound rule still needs an implementation key.

Without a source-of-truth account key, one implementation may collapse all unauthenticated/direct requests into a single account while another may skip the cap. That changes denial-of-service behavior and fairness under SPEC-005/SPEC-006 multi-account traffic.

Recommendation: Define the per-account counter input explicitly, including the no-account/direct-coordinator case, and state that raw `account_id` remains out of audit payloads.

### Category B3: Wire-format correctness (v0.3 new fields)

### B3.1 Buyer request_id namespace is mis-cited   [MAJOR]
Location: §4.4 R-4.4.0 lines 407-412; SPEC-001 §6.6 lines 1307-1319

R-4.4.0 says buyer inference IDs follow SPEC-001's `req_<ULID>` shape, but SPEC-001 v1.2.4 actually specifies `request_id` as `req-{uuid}` and describes it as a coordinator-assigned UUID. The `swap_` prefix still avoids collision, but the cross-spec reference is factually wrong.

This matters because request demux, stale-frame handling, and tests will copy the cited shape. An implementer following SPEC-010 could add buyer-ID validation that rejects locked SPEC-001 traffic.

Recommendation: Correct R-4.4.0 to cite the actual locked buyer namespace (`req-{uuid}` / UUID), or explicitly say the buyer namespace is whatever SPEC-001 v1.2.4 currently defines and only `swap_` is new here.

### B3.2 No failure stage for no-response or retention-timeout swaps   [MAJOR]
Location: §4.4 R-4.4.0 lines 407-421; §4.4.9 lines 530-547

R-4.4.0 allows the coordinator to retire a `swap_request_id` after the retention window and drop late `set_model_complete` messages, but R-4.4.9 has only `failure_stage: "rejected" | "load_failed"`. A provider that disconnects after `set_model`, never acks, or finishes after retention has no defined `model_swap_failed` stage.

That leaves provider `SwapState`, parked-request audit, and incident review ambiguous exactly when the swap fails silently. It also weakens the 600s retention tradeoff because the spec says what to drop but not what terminal swap outcome to record.

Recommendation: Add a terminal no-response/timeout stage, with reason codes for ack timeout, completion timeout, provider disconnect, and retired-late-complete as needed.

### B3.3 `swap_request_ids` request_log field has no storage owner   [MINOR]
Location: §4.5.3.7 lines 675-680; SPEC-005 §4.1-§4.2 lines 224-245

R-4.5.3.7 says the buyer's `request_log.swap_request_ids: []text` SHOULD list swap IDs, but neither SPEC-002's `request_log` schema nor SPEC-005's read-only column list contains that field. SPEC-005 explicitly says it MUST NOT alter `request_log`.

This is informational, so it does not block v0.3, but leaving the type as `[]text` without a schema owner will produce divergent SQLite encodings. Some implementations will choose JSON text, some a join table, and some will omit it.

Recommendation: Either move this to a SPEC-002 vNEXT candidate with a concrete storage shape, or mark it audit-log-only and remove the request_log column suggestion from v0.3.

### Category C3: Routing semantics (v0.3)

### C3.1 Retry-on-`not_in_supported_models` hides a coordinator bug   [MAJOR]
Location: R-4.4.1 lines 422-426; R-4.5.3.5 lines 649-661

R-4.4.1 says sending `set_model` for a non-supported model is a coordinator bug, but R-4.5.3.5 then retries parked requests on any rejection reason, explicitly including `not_in_supported_models`. That turns a violated invariant into ordinary cold-wake failover.

Retrying on a coordinator-bug code can mask a corrupted `SupportedModels` index or case-folding bug and may serve traffic after an invariant breach that should be visible. It also makes AC-15's safety path look like a normal routing branch.

Recommendation: Treat `not_in_supported_models` as terminal for that swap and emit a high-severity audit event; parked requests should 503 or move only under an explicitly named "coordinator bug recovery" rule.

### C3.2 `state: "loading"` conflates waiting-for-ack and actual load   [MAJOR]
Location: §4.10 R-4.10.1-R-4.10.3 lines 920-940

R-4.10.1 maps both `swap_pending` and `loading_model` to the single public value `state: "loading"`, with only `swap_pending_since` as additional data. Operators cannot tell whether a provider is stuck before ack, actively loading weights, or wedged after ack.

The whole purpose of §4.10 is operator-visible triage during swaps. Collapsing the two substates makes the "amber" status less actionable and pushes implementers toward ad hoc dashboards or log scraping.

Recommendation: Keep `state: "loading"` for compatibility, but add a stable subordinate field such as `swap_phase: "pending_ack" | "loading_model"` on loading entries.

### Category D3: Backward compatibility (v0.3 re-verification)

### D3.1 `state` gating is not restart-persistent   [MAJOR]
Location: §4.10 R-4.10.2 lines 931-936; SPEC-002 §FR-O5 lines 1299-1319

R-4.10.2 gates the new `/v1/status.state` field on whether at least one provider in the response has ever transitioned through a SPEC-010 swap state. SPEC-002 says live pool routing state is in-memory only and is re-established from fresh hello and heartbeats after coordinator restart.

If the "ever transitioned" bit is also only in memory, `/v1/status.state` can appear after a swap, disappear after coordinator restart, then reappear after the next swap. That flicker is not an L-1 legacy violation, but it is a backward-compatibility and operator-dashboard confusion risk for deployments that have already crossed the v0.3 swap boundary.

Recommendation: Specify whether the gating bit is persisted, derived per response from durable swap audit history, or intentionally resets on restart. If reset is intentional, AC coverage should lock that behavior.

### D3.2 v0.3 default retuning changes v0.2 canary behavior   [QUESTION]
Location: §4.7 lines 819-829; R-4.7.3 lines 853-861

v0.3 changes draft defaults from drain 30s / ETA 60s to drain 20s / ETA 90s. For a fresh implementation this is just a better draft default, but for any operator who already canaried v0.2 semantics, the same config file behaves differently after the spec update.

This is probably acceptable because v0.2 was pre-implementation draft text, but it is still an operator decision rather than a pure audit fact. The spec should make clear whether v0.2 canaries are expected to absorb the new defaults.

Recommendation: Close this as an explicit v0.3 decision in §10 or the change log: v0.2 defaults are not preserved because v0.2 was not a locked implementation target.

### Category E3: SPEC-008 / Pillar A interaction (v0.3)

### E3.1 Cold-entry hash omission contradicts locked SPEC-008 §5.7   [CRITICAL]
Location: §4.6.1.4 lines 741-759; §8.4 lines 1105-1118; SPEC-008 §5.7 lines 773-808

R-4.6.1.4 says cold-supported `/v1/models` entries MUST omit `hash_verified` and `hash_verification` when Pillar A is active. Locked SPEC-008 §5.7 says that when Pillar A observation or enforcement is active, the aggregated `/v1/models` entry for each model MUST include those fields, and it separately defines when the hash block is present.

This is a locked-spec scope conflict. SPEC-010 may be right product-wise that cold-supported entries should not imply hash provenance, but §8.4's "no SPEC-008 spec change required" claim does not hold against the current MUST language.

Recommendation: Either make the SPEC-008 v0.4 compatibility note a real candidate normative edit that changes §5.7 for cold-supported entries, or avoid publishing cold-supported entries while Pillar A active until SPEC-008 is updated.

### Category F3: Operator UX (v0.3, F2.1/F2.2 closure check)

(no findings)

The §3 pain-point table is now honest about default buyer-picker behavior, R-4.10.4 scopes AC-22 to the coordinator's status value rather than dashboard rendering, and `state: "loading"` at least gives dashboards a non-`down` value to render.

### Category G3: AC coverage (v0.3 35 ACs)

### G3.1 New request_id, retention, validation-order, and state-gating rules lack direct ACs   [MAJOR]
Location: R-4.1.9 lines 270-289; R-4.4.0 lines 407-421; R-4.10.2 lines 931-936; AC-1 through AC-35 lines 1122-1353

The ACs test several validation failures, but no AC proves the priority order when multiple failures apply. There is also no AC for `swap_<ULID>` format, late ack/complete discard after retention, or absence of `/v1/status.state` when R-4.10.2 gating is unmet.

These are deterministic contract details, not implementation trivia. Without ACs, tests can pass while implementations diverge on externally observable reason strings, correlation IDs, stale response handling, or L-1 status shape.

Recommendation: Add ACs for multi-failure validation priority, exact swap ID format, late response discard, and `state` field absence before any SPEC-010 swap state has occurred.

### G3.2 AC-32 does not cover all audit event outcomes   [MAJOR]
Location: R-4.4.9 lines 490-582; AC-32 lines 1320-1330

AC-32 covers one success path and one `oom` load-failure path. It does not cover `cold_wake_drained{outcome: "503_eta_expired"}`, `503_queue_overflow`, ack rejection, or no-response timeout, and it does not assert that no extra duplicate events are emitted.

The audit event schemas are the primary incident-review surface for swaps and queues. Partial sequence coverage will miss double-emits, missing terminal events, and the exact timeout paths most likely to hurt operators.

Recommendation: Split AC-32 into exact-event-set cases for success, ack rejection, load failure, ETA expiry, queue overflow, and no-response timeout once that stage exists.

### G3.3 AC-32 does not assert an exact event set   [MINOR]
Location: AC-32 lines 1320-1330

AC-32 says the named events are emitted in order, but it does not say the set is exact. An implementation could double-emit `model_swap_completed` or emit both success and failure terminal events and still satisfy a loose "contains these in order" test.

This is a quality issue rather than a design blocker, but audit logs are most useful when event cardinality is stable. Duplicate terminals are painful to debug after the fact.

Recommendation: Add "and no additional swap/cold_wake events for the same `swap_request_id` / `buyer_request_id`" to each AC-32 branch.

### G3.4 Queue overflow ACs do not prove the queue drains after overflow   [MAJOR]
Location: R-4.5.3.8 lines 684-700; AC-33/34 lines 1332-1343

AC-33 and AC-34 prove immediate 503 on per-swap and per-account overflow, but neither proves the already-parked requests still release or 503 normally after the swap completes or fails. A cap implementation could wedge the queue after the overflow branch and still satisfy the written ACs.

This is a denial-of-service safety gap: the cap must reject excess work without poisoning the in-flight swap queue. The test suite needs to prove the non-overflowed requests still reach terminal outcomes.

Recommendation: Extend AC-33/34 to complete or fail the underlying swap after overflow and assert every parked request receives exactly one terminal outcome.

### Category H3: Companion-spec annotations (v0.3 §8)

### H3.1 SPEC-001 candidate references provider status without a heartbeat wire contract   [MAJOR]
Location: §8.1 lines 1040-1079; §4.10 lines 920-945; SPEC-002 heartbeat/state lines 1705-1752

§8.1 says the binary contributes the `state` field via heartbeat and imports §4.10 as source text, but §4.10 defines coordinator `/v1/status` output, not a provider heartbeat schema. Locked SPEC-002 heartbeats use `status` and state_update values from the existing five-state set, which does not include `loading_model`.

Demand-pull swaps can be represented by coordinator-owned `SwapState`, but provider-initiated/operator-pushed swaps need a clear way to expose loading without overloading locked `status` semantics. As written, a SPEC-001 implementer still has to invent the binary-to-coordinator status path.

Recommendation: Add a SPEC-001 v1.2.5 candidate rule for how the provider reports local loading state, or state that only coordinator-initiated swaps produce `state: "loading"` in Phase 1.

### H3.2 SPEC-002 candidate still names audit events without importing payload schemas   [MAJOR]
Location: §8.2 lines 1081-1091; R-4.4.9 lines 490-582

§8.2 lists the five event types for SPEC-002 v1.3.5 but does not explicitly reference R-4.4.9 as the payload schema source. R-4.4.9 says the candidate will incorporate these payload schemas by reference, but the candidate annotation itself still only names event types.

This repeats part of H2.2 at the companion-spec boundary: a future SPEC-002 BUILD prompt could copy §8.2 and miss the required payload fields and redaction rules. The payload schemas are now present, but the import edge is weak.

Recommendation: Amend §8.2 to say "with payload schemas and redaction rules per R-4.4.9" in the audit-log bullet.

### Category I3: Anything else

### I3.1 Phase 2 deferral text points to the current version   [MINOR]
Location: §5 line 964

The Phase 2 outline says "Phase 2 spec deferred to SPEC-010 v0.3" inside SPEC-010 v0.3. The surrounding text says Phase 2 is deferred to v0.4, so this is stale wording.

This will not block implementation, but it creates avoidable confusion when readers search for the Phase 2 operator CLI contract. It also undercuts the otherwise improved phase accounting in §3.

Recommendation: Change the sentence to "deferred to SPEC-010 v0.4" or remove the version number.

### Self-verification

- Read the required files in order for the active audit pass: SPEC-010 v0.3, SPEC-010-audit rounds 1-2, round-2 prompt, CLAUDE.md, SPEC-001, SPEC-002, SPEC-004, SPEC-005, SPEC-008, SPEC-006, decision log entries 21/35 context, and required code spot-checks.
- Did not inspect d-inference source.
- Every round-2 finding has PASS / PARTIAL / FAIL in R2V.
- Every category R2V and A3-I3 has a section.
- Every finding has severity, location, what, why, and recommendation.
- Round-3 executive summary states a clear verdict.
