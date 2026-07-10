# SPEC-010 v1.0 — Audit Report (post-split)

**Audited:** SPEC-010 v1.0 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 1 of N
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 3 MAJOR / 1 MINOR / 0 QUESTION

**Predecessor audit history:**
specs/SPEC-012-source-audit-history.md (3 rounds against the
wide-scope draft that produced this split).

## Executive summary

Verdict: **ready for one narrow fix pass; not ready to lock unchanged.**

SPEC-010 v1.0 successfully narrows the former wide-scope catalog draft. I did not find new SPEC-011/SPEC-012 scope creep, and the central compatibility design is coherent: legacy providers still synthesize singleton catalog state, router dispatch remains constrained to the warm loaded model, and the `ModelKnown` 404-to-503 semantic shift is explicitly documented.

The remaining issues are contract precision and testability, not architecture. The largest risk is that the new provider auth surface names an `auth` frame even though the current coordinator consumes `auth_request`; the other blockers are missing direct acceptance coverage for provider-binary/default validation behavior and an AC that requires raw byte-identical log streams in a way that is likely flaky without normalization.

## A. Narrow-Scope Completeness

(no findings)

## B. Spec Contradictions / Ambiguities

### B.1 Auth frame name and source-section reference are inconsistent [MAJOR]

Location: SPEC-010 §3.1 lines 101-119; SPEC-010 §6.2 lines 456-459; SPEC-002 §7.1 lines 1569-1715; SPEC-002 §7.2 lines 1895-2055; `phase4-coordinator/internal/ws/messages.go` lines 302-329.

What:
SPEC-010 says the "auth frame" gains `supported_models` and `publish_supported_models`, and its example uses `"type": "auth"`. The current coordinator wire parser accepts `AuthRequest` messages only when `type == "auth_request"`, `version == 2`, and `stage` is `initial` or `proof`. SPEC-010 also cites SPEC-002 §7.2 as the "provider auth frame" source, but SPEC-002 §7.2 is the Buyer HTTP API; provider WebSocket handshake details live in §7.1, with token/auth behavior in §7.3.

Why it matters:
This is the one new wire-facing SPEC-010 surface. If an implementer follows the v1.0 example literally, the provider will send `type: "auth"` and the existing coordinator will reject it before reaching catalog validation. If a future SPEC-001 binary prompt follows the wrong SPEC-002 section, it may add fields to the wrong protocol contract.

Recommendation:
Rewrite §3.1 and §6.2 to bind the extension to the existing v2 `auth_request` initial frame, or explicitly state the exact frame name if SPEC-002 is amended. Change the source reference from SPEC-002 §7.2 to the provider WebSocket/auth sections, and add an acceptance case that sends `auth_request` with `stage: "initial"` plus the new fields.

## C. Backward Compatibility and Regression Risk

(no findings)

## D. Cross-Spec Coherence

(no findings)

## E. Acceptance Criteria Quality

### E.1 Provider-binary and malformed catalog rules lack direct AC coverage [MAJOR]

Location: SPEC-010 §3.1 lines 124-177; SPEC-010 §3.6 lines 291-314; SPEC-010 §5 AC-3 through AC-10 lines 375-404; SPEC-001 §6.5 lines 1040-1155.

What:
Several normative rules are not directly proven by the acceptance criteria:

- R-3.1.1 requires `supported_models` to be an array of strings, but the ACs cover an empty array and ordering cases, not a non-array value or a mixed array containing a non-string entry.
- R-3.6.2 requires a provider binary with unset `supported_models` to send `[model_id]`, but no AC proves the outbound default auth frame from the binary.
- R-3.6.3 requires local binary failure for all invalid catalog values, including length and per-entry byte limits, but AC-9 only covers `model_id` not contained in the set.
- R-3.6.4 introduces `--publish-supported-models` defaulting false, but the ACs do not directly prove the default false outbound field behavior versus explicit true.

Why it matters:
The coordinator-side tests could pass while the provider binary never sends the default catalog field, misses length-limit validation, or serializes the publish flag incorrectly. The audit prompt requires every MUST/SHALL/REQUIRED rule to have an objective AC; these gaps are narrow but material because SPEC-010 is a cross-component protocol change.

Recommendation:
Add targeted ACs for provider-binary default emission, local binary rejection for `>64` entries and `>256` UTF-8 bytes per entry, `--publish-supported-models` default false versus true, and malformed `supported_models` types on the coordinator auth path.

### E.2 AC-13 raw log-stream byte identity is not CI-stable as written [MAJOR]

Location: SPEC-010 lock L-1 lines 86-91; SPEC-010 R-3.5.1 lines 285-289; SPEC-010 AC-13 lines 413-418.

What:
AC-13 requires diffing `/v1/models`, `/v1/status`, and "log streams" byte-for-byte before and after enabling defaulted catalog config. The response byte-identity portion is objective. Raw log-stream byte identity across separate coordinator runs is not reliably objective unless the test harness freezes or normalizes timestamps, generated session/request IDs, connection ordering, and similar runtime entropy.

Why it matters:
The AC may fail for unrelated nondeterminism, or implementers may weaken it informally and miss the actual invariant: no new public behavior, warnings, event types, or fields on the legacy/default path.

Recommendation:
Keep byte-identical response diffs literal, but change the log assertion to a normalized-log comparison. For example, strip known nondeterministic fields and assert that the set/order of log event names, severity levels, stable fields, and SPEC-010-related additions is unchanged for legacy providers.

### E.3 Multi-failure validation priority is only partly locked by ACs [MINOR]

Location: SPEC-010 R-3.1.9 lines 158-177; SPEC-010 AC-8 lines 389-394.

What:
R-3.1.9 gives a deterministic validation order and reason strings. AC-8 proves that max-length failure wins over the `model_id` containment failure, but it does not cover other plausible multi-failure combinations: non-string entry plus containment failure, or duplicate entry plus containment failure.

Why it matters:
The rule text is clear enough for implementation, so this is not a major ambiguity. Still, the exposed rejection reason is a protocol-level behavior, and the test suite will converge faster if representative priority conflicts are explicitly locked.

Recommendation:
Add two small priority cases: one where step 1 wins over a later containment failure, and one where step 4 wins over step 5.

## F. Source-of-Truth Hygiene

(no findings)

Notes:
The targeted non-spec documentation search found no SPEC-010/SPEC-011/SPEC-012 drift in `HANDOFF.md`, `RUNBOOK.md`, `CONTINUE_RUNBOOK.md`, or `AGENTS.md`. Decision-log Entry 21 was considered as a caution against overclaiming; a new decision-log entry should be added after SPEC-010 is locked, not during this audit round.

## Self-verification

- Required inputs were read in the prompt-specified order after the audit prompt.
- `specs/SPEC-012-source-audit-history.md` was used only as predecessor audit context.
- The audit stayed inside SPEC-010 v1.0's narrowed scope and did not reopen deferred SPEC-011/SPEC-012 functionality.
- No `d-inference` source was inspected.

---

## Round 2 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.1 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 2 of N
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 3 MAJOR / 2 MINOR / 0 QUESTION

### Round-2 executive summary

Verdict: **not ready to lock until the round-2 MAJOR findings are closed.**

v1.1 closes three of the four round-1 findings in substance: E.1, E.2, and E.3 now have direct acceptance coverage and the AC-13 log assertion is testable against the coordinator's structured zerolog output. B.1 is only partially closed. The body now uses `auth_request`, `version: 2`, and `stage: "initial"`, and AC-16 correctly tests rejection of the old `type: "auth"` shape, but the claimed locked-spec source citation still does not support the contract: SPEC-001 v1.2.4 §6.5 and SPEC-002 v1.3.4 §7.1 both document the legacy `hello` flow, not the v2 `auth_request` initial/proof flow.

The new v1.1 normative surface is directionally coherent and still narrow: I found no SPEC-011 warm-swap, SPEC-012 demand-pull, buyer catalog visibility, billing, sticky-routing, or SPEC-008 §5.7 scope creep. The remaining problems are contract precision: where implementers are supposed to reconstruct the actual v2 auth shape, how the new `supported_models` fields are added to `AuthRequest`, and how the proof-stage mismatch check is parsed and compared.

### Round-1 fix verification (R1V)

| Round-1 finding ID | Verdict | v1.1 location verified | Evidence |
|---|---|---|---|
| R1V-B.1 | PARTIAL | §3.1 lines 126-165; AC-16 lines 493-503; §6.1 lines 573-579; §6.2 lines 588-594 | The wire name and AC are corrected to `auth_request` v2, but the cited locked specs still document `hello`, not the v2 `auth_request` flow, so the source-of-truth half remains open. |
| R1V-E.1 | PASS | AC-17 through AC-21 lines 504-540 | v1.1 adds direct ACs for non-array/mixed-array rejection, stage mismatch, binary default emission, binary length validation, and publish flag default/explicit behavior. |
| R1V-E.2 | PASS | AC-13 lines 458-479 | The response byte-diff remains literal while logs are compared as normalized structured event records, and coordinator logging is zerolog JSON. |
| R1V-E.3 | PASS | AC-22 and AC-23 lines 541-553 | The added cases lock step-1-vs-step-5 and step-4-vs-step-5 priority with exact reason strings. |

### R1V

#### B.1 remains only partially fixed because the corrected citation does not support `auth_request`   [MAJOR]
Location: §3.1 lines 128-135; §6.1 lines 573-579; §6.2 lines 588-594; SPEC-001 §6.5 lines 1019-1083; SPEC-002 §7.1 lines 1571-1674

What:
v1.1 correctly changes the example and AC-16 to `type: "auth_request"`, `version: 2`, and `stage: "initial"`. However, SPEC-001 v1.2.4 §6.5 and SPEC-002 v1.3.4 §7.1 both document the legacy `hello` handshake and state that SPEC-001 §6.5 is the authoritative source; neither locked section documents `auth_request`, `initial`, or `proof`.

Why it matters:
B.1 was not just a spelling issue; it was a source-of-truth issue for the one new wire-facing surface. An implementer following v1.1's locked-spec citations cannot reconstruct the v2 auth contract without reading code, and the companion-spec annotations currently misstate what the locked specs contain.

Recommendation:
Either cite a real normative source for the v2 `auth_request` flow or make SPEC-010 §3.1 self-contained for every required v2 initial/proof field it depends on. Update §6.1 and §6.2 so they say the companion specs need to gain this text, not that they already contain it.

### A2

(no findings)

### B2

#### B2.1 `auth_request` field contract is still code-dependent   [MAJOR]
Location: §3.1 lines 139-155; `phase4-coordinator/internal/ws/messages.go` lines 37-57 and 333-388

What:
The §3.1 example includes `supported_models` and `publishes_supported_models`, but the current `AuthRequest` struct cited by v1.1 does not contain those fields. The same example hides required current initial-stage fields behind `"..."`; the parser requires `model_params_b`, `ram_gb`, `max_context_tokens`, `max_concurrency`, `throughput_tps_estimate`, `provider_ecdh_public_key`, and `tier2_capabilities`.

Why it matters:
AC-16 says a real `auth_request` with the new fields is accepted and stored, but the spec never explicitly says `AuthRequest` gains those two fields or lists the required existing fields needed for a minimally valid initial frame. That leaves the contract dependent on code inspection, which is exactly what the corrected SPEC-002 citation was supposed to avoid.

Recommendation:
Add a compact normative field table for the v2 initial-stage `auth_request`: existing required fields, existing optional fields, and SPEC-010-added optional fields. State that the coordinator's auth parser/struct must retain the SPEC-010 fields for downstream catalog validation and provider registration.

#### B2.2 Proof-stage mismatch rule lacks a parser/retention contract   [MAJOR]
Location: §3.1 lines 158-161; AC-18 lines 510-515; `phase4-coordinator/internal/ws/messages.go` lines 391-401

What:
v1.1 requires rejection when `supported_models` differs between initial and proof stages. The current proof parser only reads `auth_attempt_id`, `provider_id`, and `attestation_token`; it ignores unknown proof-stage fields, so a proof-stage `supported_models` value would not be available for comparison unless the parser is changed.

Why it matters:
The rule is compatible with legacy proof frames if it fires only when the proof stage actually carries catalog fields, but the spec does not say how proof-stage catalog fields are parsed, retained, or compared to the initial-stage source of truth. AC-18 therefore requires implementation machinery that the normative rules do not describe.

Recommendation:
Clarify that absent proof-stage `supported_models` is not a mismatch, and add an explicit parser rule: when proof-stage catalog fields are present, parse them with the same normalization/type rules, compare them to the initial-stage values retained for the auth attempt, then reject with the AC-18 reason on divergence.

### C2

(no findings)

### D2

(no findings)

### E2

#### E2.1 References still point SPEC-002 readers at buyer HTTP §7.2   [MINOR]
Location: §9 lines 656-658

What:
The §6.2 body correctly says SPEC-002 §7.1 is the intended provider WebSocket section and §7.2 is buyer HTTP, but the references list still cites "SPEC-002 v1.3.4 §3, §5, §7.2, §11".

Why it matters:
This is not the primary B.1 blocker because §7.1 also lacks the v2 auth_request text, but it preserves the exact source-section drift v1.1 set out to remove. Future readers using only the references list will land on the buyer HTTP API again.

Recommendation:
Change the SPEC-002 reference to include §7.1 and §7.3, and omit §7.2 unless a buyer-HTTP reference is intentionally needed elsewhere.

#### E2.2 v1.1 change log misnumbers the added ACs   [MINOR]
Location: change log lines 21-32

What:
The change log says the E.1 fix is AC-17 through AC-20 while also claiming coverage for R-3.6.4 publish flag default; the publish flag AC is actually AC-21. It also says E.3 is covered by AC-21 and AC-22, but the actual priority ACs are AC-22 and AC-23.

Why it matters:
The normative AC text is clear, so this does not block implementation. It does make audit traceability noisier because the top-level fix claims do not match the AC numbers used later in the same file.

Recommendation:
Update the change log to say E.1 is covered by AC-17 through AC-21 and E.3 is covered by AC-22 and AC-23.

### Self-verification

- Required files were read in the prompt-specified order.
- R1V covers B.1, E.1, E.2, and E.3 with PASS / PARTIAL / FAIL verdicts.
- Every category R1V, A2, B2, C2, D2, and E2 has a section.
- No `d-inference` source was inspected.
- The round-1 section and round-1 verdict were not changed.

---

## Round 3 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.2 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 3 of N
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 5 MAJOR / 0 MINOR / 0 QUESTION

### Round-3 executive summary

Verdict: **not ready to lock until the round-3 MAJOR findings are closed.**

v1.2 closes the round-2 source-of-truth framing problem in form: it no longer claims that SPEC-001 v1.2.4 or SPEC-002 v1.3.4 already normatively document v2 `auth_request`, and §6.1 / §6.2 are correctly reframed as future candidate additions. The §9 reference correction and change-log AC numbering correction also close cleanly.

The load-bearing v1.2 replacement text does not yet close the contract in substance. §3.1.A is advertised as a frozen snapshot of `AuthRequest`, but it omits one existing struct field, invents the two SPEC-010 fields before they exist in the struct, and marks several parser-required initial-stage fields optional. §3.1.B's example and "minimally valid" claim are therefore not parser-valid, and R-3.1.10's retention rule depends on an initial-stage `auth_attempt_id` and SPEC-002 §7.3 timeout text that do not exist as stated.

### Round-2 fix verification (R2V)

| Round-2 finding ID | Verdict | v1.2 location verified | Evidence |
|---|---|---|---|
| R2V-B.1 round 2 | PASS | §3.1 lines 166-183; §6.1 lines 745-754; §6.2 lines 771-779 | v1.2 explicitly says locked SPEC-001/SPEC-002 document legacy `hello`, makes §3.1.A the interim source of truth, and reframes companion edits as new v2 sections rather than extensions of existing locked text. |
| R2V-B2.1 | PARTIAL | §3.1.A lines 197-218; §3.1.B lines 224-253; `messages.go` lines 37-57 and 333-388 | v1.2 adds a table and removes hidden `"..."`, but the table and example do not match the actual `AuthRequest` struct/parser, so the field contract remains inaccurate. |
| R2V-B2.2 | PARTIAL | R-3.1.10 lines 317-356; AC-18 lines 654-675 | v1.2 adds an explicit proof-stage parser/retention rule and absent-is-OK behavior, but the retention key, timeout source, and AC coverage are still under-specified. |
| R2V-E2.1 | PASS | §9 lines 849-854 | The reference list now cites SPEC-002 §7.1 and §7.3, labels §7.1 as legacy `hello`, and no longer points readers at buyer HTTP §7.2. |
| R2V-E2.2 | PASS | change log lines 20-42 | The v1.2 change log now correctly names AC-17 through AC-21 for E.1 and AC-22 / AC-23 for E.3. |

### A3 — Locked-decision preservation

#### A3.2 R-3.1.10's retention bound cites a SPEC-002 timeout that is not there [MAJOR]

Location: SPEC-010 R-3.1.10 lines 324-329 and 351-356; SPEC-002 v1.3.4 §7.3 lines 2057-2122; `phase4-coordinator/internal/ws/server.go` lines 354-355 and 379-398.

What:
R-3.1.10 says retained initial-stage catalog values are bounded by "the existing auth-attempt timeout in SPEC-002 §7.3." SPEC-002 §7.3 documents token issuance, bearer-token validation, revocation, and token storage; it does not define an `auth_attempt_id` lifecycle or timeout. Current code has implementation timers (`ProviderWSHandshakeTimeout`, default 10s, and a 10-minute `challengeExpiresAt`), but those are not the cited locked SPEC-002 §7.3 contract.

Why it matters:
The new retention map is coordinator state. Without a normative timeout source, implementers cannot prove the map is bounded or know which timer releases retained values on slow proof, failed proof, or disconnect-before-proof paths.

Recommendation:
Move the timeout bound into SPEC-010 R-3.1.10 directly, or make §6.2's SPEC-002 v1.3.5 candidate explicitly add an auth-attempt lifecycle with a concrete timeout and disconnect cleanup requirement. Do not cite SPEC-002 §7.3 as if it already contains that contract.

### B3 — §3.1.A field table accuracy

#### B3.1 §3.1.A does not accurately reflect the `AuthRequest` struct or initial parser [MAJOR]

Location: SPEC-010 §3.1.A lines 197-218; `phase4-coordinator/internal/ws/messages.go` lines 37-57 and 333-388.

What:
The table is not an accurate snapshot of `AuthRequest`. It omits the existing `auth_attempt_id` struct field (`json:"auth_attempt_id,omitempty"`), while adding `supported_models` and `publishes_supported_models` rows that do not exist in the current struct. It also marks parser-required initial-stage fields optional: `hostname`, `model_id`, `model_params_b`, `ram_gb`, `max_context_tokens`, `max_concurrency`, `throughput_tps_estimate`, `binary_version`, `provider_ecdh_public_key`, and `tier2_capabilities` are all required by `parseAuthInitial`.

Why it matters:
§3.1.A is the new source-of-truth artifact introduced to close round-2 B.1/B2.1. If its rows do not match the actual struct/parser, future SPEC-001/SPEC-002 implementers will still need to reverse-engineer code and may build a frame the coordinator rejects.

Recommendation:
Regenerate §3.1.A from `AuthRequest` plus parser-requiredness: include `auth_attempt_id` with correct stage semantics, clearly distinguish proposed SPEC-010-added fields from fields already present in the Go struct, and mark every `parseAuthInitial` required field as REQUIRED unless the parser is intentionally changed first.

#### B3.4 §3.1.B's example and "minimally valid" frame are not parser-valid [MAJOR]

Location: SPEC-010 §3.1.B lines 224-253; `phase4-coordinator/internal/ws/messages.go` lines 333-388.

What:
The example omits `provider_ecdh_public_key` and `tier2_capabilities` "for readability," but `parseAuthInitial` currently rejects an initial-stage v2 `auth_request` without both fields. The prose then says a minimally valid SPEC-010 initial-stage frame contains only `{type, version, stage, provider_id}` plus the SPEC-010 fields, but the parser also requires hostname, model_id, capacity fields, throughput, binary_version, provider ECDH key, and Tier-2 capabilities.

Why it matters:
This preserves the core round-2 implementation risk: an implementer can copy the normative example or minimum claim and produce a frame that fails before catalog validation.

Recommendation:
Make the example parser-valid by including every currently required initial-stage field, or explicitly state that the parser will be relaxed and list the exact requiredness change. Replace the "minimally-valid" sentence with a minimum that matches `parseAuthInitial`.

### C3 — R-3.1.10 proof-stage parser contract

#### C3.2 R-3.1.10 keys retention by an initial-stage value that is not carried on the initial frame [MAJOR]

Location: SPEC-010 §3.1.A lines 197-222; R-3.1.10 lines 324-329; `phase4-coordinator/internal/ws/messages.go` lines 333-388; `phase4-coordinator/internal/ws/server.go` lines 354-360.

What:
R-3.1.10 requires retaining initial-stage values per `auth_attempt_id`, but the initial-stage table does not include `auth_attempt_id`, the struct marks it `omitempty`, and `parseAuthInitial` does not read or require it. In current code the coordinator generates `authAttemptID` only after parsing the initial frame, when it creates the `auth_challenge`.

Why it matters:
The rule is ambiguous about the retention key at the moment the initial-stage values are observed. If retention is keyed by a client-supplied initial field, that field is absent; if retention is keyed by the coordinator-generated challenge ID, the rule should say so and specify when the retained entry is created.

Recommendation:
Define the retention key as the coordinator-generated `auth_challenge.auth_attempt_id` and state that the coordinator attaches the already-parsed initial-stage SPEC-010 values to that generated ID before sending the challenge. Alternatively, require initial-stage `auth_attempt_id`, but that would be a wire-shape change and should be justified separately.

### D3 — AC quality

#### D3.1 AC-18 does not cover R-3.1.10 clauses 1, 2, and 5 [MAJOR]

Location: SPEC-010 R-3.1.10 lines 324-356; AC-18 lines 654-675.

What:
AC-18 covers absent proof-stage `supported_models` and present match/mismatch cases, which exercises R-3.1.10 clauses 3 and 4. It does not objectively test clause 1 retention scope, clause 2 parser extension for both `supported_models` and `publishes_supported_models`, or clause 5 cleanup across all three cleanup triggers. Sub-case (c) mentions release after mismatch, but there is no assertion that success, generic failure, timeout, or disconnect-before-proof paths do not leak retained entries.

Why it matters:
The new implementation machinery is the main v1.2 addition for B2.2. Without AC coverage, an implementation could pass AC-18 while retaining per-attempt state indefinitely, ignoring `publishes_supported_models` on proof, or cleaning up only the mismatch path.

Recommendation:
Add AC cases or sub-assertions for retention creation keyed by the generated auth attempt, parser capture of both SPEC-010 proof-stage fields, and cleanup on success, non-mismatch failure, timeout, and disconnect-before-proof. A bounded-state assertion over repeated failed attempts is enough for the cleanup claim.

### E3 — Companion-spec annotation framing

(no findings)

### F3 — Anything else

(no findings)

Notes:
The v1.2 scope remains narrow. I found no SPEC-011 warm-swap mechanism, no SPEC-012 demand-pull or `set_model` wire surface, no `/v1/models` aggregation change, and no SPEC-008 §5.7 hash-block interaction beyond the explicit "none" statement in §6.3. The `ModelKnown` caller note remains directionally accurate: `buyer/server.go` still uses `ModelKnown(req.Model)` to decide the 404 `model_not_found` path, although the current `Provider` and `Registry` code have not yet implemented `SupportedModels`.

A decision-log entry should be added when SPEC-010 eventually locks; not a finding for this draft round.

### Self-verification

- Round-3 section was appended; the round-1 and round-2 sections above were not rewritten.
- Every round-2 finding has PASS / PARTIAL / FAIL in R2V.
- Every category R2V, A3, B3, C3, D3, E3, and F3 has a section.
- Every finding includes severity, location, what, why, and recommendation.
- No `d-inference` source was inspected.

---

## Round 4 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.3 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 4 of N
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 2 MAJOR / 5 MINOR / 0 QUESTION

### Round-4 executive summary

Verdict: **not ready to lock directly; v1.3 needs a narrow v1.4 cleanup and round-5 spot check.**

The round-3 fixes mostly moved in the right direction. The parser-required initial-stage fields in §3.1.A now match `parseAuthInitial`, §3.1.B's example includes the fields the parser requires, and R-3.1.10 now correctly keys retention on the coordinator-generated `authAttemptID` rather than a nonexistent initial-stage field.

The code-grounding pass is still not clean enough to lock. §3.1.A remains an "initial-stage field table" but still includes a proof-stage-only `attestation_token` row that `parseAuthInitial` never reads. R-3.1.10 also says disconnect cleanup is done by "the disconnect handler," but the current pre-proof v2 auth flow returns before `handleDisconnect` is armed; the spec needs to point cleanup at the auth-attempt scope, e.g. a `handleV2Conn` defer, not the registered-session disconnect handler.

### Round-3 fix verification (R3V)

| Round-3 finding ID | Verdict | v1.3 location verified | Evidence |
|---|---|---|---|
| R3V-B3.1 | PARTIAL | §3.1.A field table and `messages.go` lines 302-388 | The 11 parser-required initial-stage rows now match `requireString` / `requireInt` / `requireFloat` / explicit ok-check calls at `messages.go:334-384`, and `auth_attempt_id` is correctly moved to a note, but §3.1.A still contains proof-stage-only `attestation_token`, which is not read by `parseAuthInitial`. |
| R3V-B3.4 | PASS | §3.1.B example and `messages.go` lines 333-388 | The example includes every currently required parser key: provider identity, host/model/capacity fields, binary version, provider ECDH key, and `tier2_capabilities`; extra SPEC-010 fields are ignored by the current parser and therefore do not break parser validity. |
| R3V-C3.2 | PASS | R-3.1.10 clause 1 and `server.go` lines 354-367 | Clause 1 now keys retention on `authAttemptID := "auth-" + s.newUUID()` generated at `server.go:354` and sent in `auth_challenge.AuthAttemptID` at `server.go:359`. |
| R3V-A3.2 | PASS | R-3.1.10 clause 5(c), §6.2, and `server.go` lines 355 and 398 | The timeout bound is now stated inline as 10 minutes, matching `challengeExpiresAt := s.now().Add(10 * time.Minute)` and the proof-stage expiry check at `server.go:398`; §6.2 frames the lifecycle as a SPEC-002 v1.3.5 candidate. |
| R3V-D3.1 | PASS | AC-18(a-f) | AC-18 now has sub-cases for absent proof, matching proof, mismatching proof, retention creation, success/failure/timeout cleanup, and disconnect-before-proof cleanup; remaining issues are test hook and disconnect-placement precision, not missing textual coverage. |

### Category R3V — Round-3 fix verification

See the table above. No additional R3V findings beyond the PARTIAL/PASS status recorded there.

### Category A4 — Locked-decision preservation

#### A4.2 Periodic retention sweep implies new coordinator machinery [MINOR]

Location: SPEC-010 R-3.1.10 clause 5(c); `phase4-coordinator/internal/ws/server.go` lines 621-630 and 1314-1324.

What:
R-3.1.10 permits cleanup by "a periodic sweeper that runs at least every 60s." The current WS server has per-session goroutines for writer and heartbeat monitoring, and a warmup timer path, but no existing auth-attempt retention sweeper that could host this without new machinery.

Why it matters:
The spec is otherwise careful to keep SPEC-010 narrow. A new global periodic task is implementable, but it should be called out explicitly if it is an allowed implementation path.

Recommendation:
Either require cleanup via auth-attempt-local `defer` / timer handling and remove the sweeper option, or state that implementations MAY add a small auth-retention sweeper and that this does not change public behavior or logs.

### Category B4 — §3.1.A field table accuracy

#### B4.1 Initial-stage table still includes proof-stage-only `attestation_token` [MAJOR]

Location: SPEC-010 §3.1.A field table; `phase4-coordinator/internal/ws/messages.go` lines 333-388 and 391-401.

What:
§3.1.A is titled as a compact v2 `auth_request` **initial-stage** field table and says initial-stage requirements come from `parseAuthInitial`. Every parser-required row now matches the code, but the table still includes `attestation_token` with "NOT in `parseAuthInitial`; checked in proof stage." The actual proof parser reads `attestation_token` only in `parseAuthProof` at `messages.go:398-399`.

Why it matters:
This is the same class of code-grounding issue v1.3 was meant to eliminate: a row in the initial-stage table is not an initial-stage parser row. Future SPEC-001/SPEC-002 edits could incorrectly copy `attestation_token` into the initial-stage field set.

Recommendation:
Move `attestation_token` out of §3.1.A into a proof-stage field note/table next to R-3.1.10, or retitle/split the table so parser-derived initial-stage rows, SPEC-010-added initial rows, and proof-stage rows are not mixed.

#### B4.3 Example ECDH public key is copy-paste-invalid placeholder text [MINOR]

Location: SPEC-010 §3.1.B example; `phase4-coordinator/internal/ws/server.go` lines 330-333.

What:
The example uses `"provider_ecdh_public_key": "BPwjzkU0..."`. `parseAuthInitial` only requires a string, so the example is parser-valid, but `handleV2Conn` next calls `tier2.ParseX25519PublicKey` and would reject an ellipsis placeholder.

Why it matters:
A tester copying the "parser-valid" example into an end-to-end WS auth test would fail after parsing with `tier2_key_exchange_failed`, which makes the example less useful as executable documentation.

Recommendation:
Replace the ellipsis value with an explicit placeholder label such as `"<base64url-32-byte-x25519-public-key>"`, or provide a syntactically valid test key and state it is non-production test material.

### Category C4 — R-3.1.10 contract precision

#### C4.4 Disconnect cleanup points at the wrong existing handler for pre-proof attempts [MAJOR]

Location: SPEC-010 R-3.1.10 clause 5(d) and AC-18(f); `phase4-coordinator/internal/ws/server.go` lines 223-238, 315-421, and 1292-1312.

What:
Clause 5(d) says "the disconnect handler MUST release the retention entry." In current code, `handleConn` only calls `handleDisconnect(providerID, assignedID)` when the handler has returned non-empty IDs. The v2 path does not return IDs until after proof succeeds and `registerProviderSession` runs. A disconnect before proof, proof read error, proof parse error, provider-ID mismatch, expiry rejection, or attestation failure all return from `handleV2Conn` before the registered-session disconnect handler has enough identity to run.

Why it matters:
The cleanup target for the retained SPEC-010 values is not the existing disconnect handler; it is the auth-attempt lifetime inside `handleV2Conn` after `authAttemptID` generation. If implementers follow the spec literally and wire only `handleDisconnect`, AC-18(f)'s disconnect-before-proof case can leak the retention entry.

Recommendation:
Rewrite clause 5(d) and AC-18(f) to require cleanup through an auth-attempt-scoped cleanup path, such as a `defer releaseRetention(authAttemptID)` installed immediately after retention creation, with explicit notes that this covers challenge write failure, proof read failure, proof parse failure, proof mismatch/expiry, attestation failure, success, and pre-proof connection close.

#### C4.2 Retained `provider_id` cross-check is redundant with current proof validation [MINOR]

Location: SPEC-010 R-3.1.10 clauses 1 and 4; `phase4-coordinator/internal/ws/server.go` line 398.

What:
R-3.1.10 stores `provider_id` in the retention entry and requires a retained-provider cross-check. Current code already rejects proof frames when `proof.ProviderID != initial.ProviderID` before SPEC-010 retained catalog comparison would run.

Why it matters:
The spec calls the retained check defensive, but does not explain what additional case it catches after the existing line-398 check. That creates two sources of truth for the same invariant.

Recommendation:
Either drop `provider_id` from the retention entry and rely on the existing proof validation, or add one sentence explaining that the retained value is only an assertion against future refactors that might separate catalog comparison from the current `initial` local variable.

#### C4.5 Retention map cap of 10000 entries is not tied to a coordinator memory budget [MINOR]

Location: SPEC-010 R-3.1.10 clause 5.

What:
The spec suggests bounding the aggregate retention map at 10000 entries with oldest-evict, but no cited coordinator memory budget or connection limit justifies that number. The closest current bound is `ws.max_unauthenticated_conn`, default 64, not 10000.

Why it matters:
An arbitrary cap can become cargo-cult implementation guidance. If the actual unauthenticated connection limit is much lower, the cap is irrelevant; if config changes allow higher concurrency, the spec should say what resource model governs the cap.

Recommendation:
Tie the cap to `ws.max_unauthenticated_conn` or a documented memory budget, or present 10000 strictly as an example with guidance to size it from deployment limits.

### Category D4 — AC quality

#### D4.1 AC-18(d) depends on a retention debug/test hook that does not exist yet [MINOR]

Location: SPEC-010 AC-18(d); `phase4-coordinator/internal/ws/server_test.go` lines 1706-1739.

What:
AC-18(d) says the test asserts retention entry existence via a coordinator debug/test hook. The current server harness exposes the HTTP server, registry, and provider server instance, but there is no existing retention map or hook because this feature is new.

Why it matters:
The AC is testable, but it silently requires either an exported debug/test accessor or a package-internal test path. That implementation dependency should be explicit so the AC does not get deferred or replaced with indirect assertions.

Recommendation:
State that the implementation must expose package-internal test access or a test-only accessor for retention entry count/lookup, with no production debug endpoint required.

#### D4.3 AC-18(f) "baseline" is underspecified [MINOR]

Location: SPEC-010 AC-18(f).

What:
AC-18(f) says that after 100 partial auth attempts followed by disconnect, retention map size returns to "baseline." It does not define whether baseline means zero, pre-test count, or the count after unrelated concurrent auth attempts are excluded.

Why it matters:
The assertion is meant to prove bounded state. Ambiguous baseline wording can let tests pass while leaving unrelated retained entries or relying on test ordering.

Recommendation:
Define baseline as the pre-test retention count for that coordinator instance, and require the test to isolate or subtract unrelated in-flight attempts.

### Category E4 — Companion-spec annotation framing

(no findings)

Notes:
SPEC-001 v1.2.4 §6.5 and SPEC-002 v1.3.4 §7.1 still document the legacy `hello` handshake, not v2 `auth_request`. SPEC-002 v1.3.4 §7.3 remains token/auth text and does not contain auth-attempt lifecycle text. SPEC-010 §6.2 frames both v2 `auth_request` and auth-attempt lifecycle text as SPEC-002 v1.3.5 candidate additions rather than edits to locked v1.3.4.

### Category F4 — Anything else

(no findings)

Notes:
I found no SPEC-011 warm-swap mechanism, no SPEC-012 demand-pull or `set_model` wire surface, no buyer-facing `/v1/models` aggregation change, and no SPEC-008 hash-block interaction added by v1.3. A decision-log entry should be added when SPEC-010 eventually locks; not a finding for this draft round.

### Self-verification

- Round-4 section was appended after round 3; rounds 1-3 were not rewritten.
- Every round-3 finding has PASS / PARTIAL / FAIL in R3V.
- Every category R3V, A4, B4, C4, D4, E4, and F4 has a section.
- Every finding includes severity, location, what, why, and recommendation.
- No `d-inference` source was inspected.

---

## Round 5 — Codex GPT-5 — 2026-06-06

**Audited:** SPEC-010 v1.4 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 5 of N
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 0 MAJOR / 3 MINOR / 0 QUESTION

### Round-5 executive summary

Verdict: **READY TO LOCK.** SPEC-010 v1.4 reaches the round-5 lock target of 0 CRITICAL / 0 MAJOR. All round-4 fix targets requested in this pass are closed at PASS: `attestation_token` moved out of the initial-stage table and into the proof-stage note, R-3.1.10 cleanup now uses an auth-attempt-scoped defer, the sweeper option is removed, and the AC/test-accessor clarifications are present.

The code-grounded spot checks support the two major fixes. `parseAuthInitial` reads only the §3.1.A initial-stage rows and does not read `attestation_token`; `parseAuthProof` reads `auth_attempt_id`, `provider_id`, and optional `attestation_token`. `handleV2Conn` is a single linear auth flow, and a defer installed immediately after retention creation and before `auth_challenge` write would cover success, proof failures, expiry, pre-proof disconnect/read/parse failures, and challenge write failure.

The remaining issues are minor lock-polish items: clause 1 should explicitly gate retention/defer creation to initial-stage SPEC-010 field presence, AC-18(f)'s 1s settlement allowance is arbitrary given synchronous defer semantics, and §6.1 has a stale `SPEC-010 v1.2` citation. None requires another major iteration; SPEC-010 v1.4 is the lockable contract for the SPEC-001 v1.2.5 / SPEC-002 v1.3.5 BUILD prompts.

### Round-4 fix verification (R4V)

| Round-4 finding ID | Verdict | v1.4 location verified | Evidence |
|---|---|---|---|
| R4V-B4.1 | PASS | §3.1.A lines 319-339; §3.1.C lines 436-452; `messages.go` lines 333-401 | §3.1.A no longer has an `attestation_token` row; §3.1.C places it on proof-stage, matching `parseAuthProof` lines 398-399 while `parseAuthInitial` lines 333-388 never reads it. |
| R4V-C4.4 | PASS | R-3.1.10 clause 5 lines 614-681; `server.go` lines 223-238 and 315-460 | Clause 5 now requires `defer releaseRetention(authAttemptID)` in `handleV2Conn`, which covers all pre-registration returns that `handleDisconnect` cannot see. |
| R4V-A4.2 | PASS | R-3.1.10 clause 5 lines 675-681; AC-18(e) lines 1043-1049 | The periodic sweeper option is removed; cleanup is specified as synchronous on `handleV2Conn` return via defer, with expiry enforced by the existing proof check. |
| R4V-B4.3 | PASS | §3.1.B lines 384 and 407-419; `server.go` lines 330-333 | The example now uses the explicit placeholder `"<base64url-32-byte-x25519-public-key>"` and warns fixtures must substitute a real X25519 key before the server parse call. |
| R4V-C4.2 | PASS | R-3.1.10 clause 1 lines 566-577; `server.go` line 398 | The retained `provider_id` is reframed as defense-in-depth against future refactors, while current code already checks `proof.ProviderID != initial.ProviderID`. |
| R4V-C4.5 | PASS | R-3.1.10 clause 1 lines 554-564; `config.go` line 269; `server.go` lines 111 and 693-706 | The separate 10000 cap is gone; the spec ties retention size to `ws.max_unauthenticated_conn`, whose default is 64 and whose semaphore gates unauthenticated connections. |
| R4V-D4.1 | PASS | AC-18(d) lines 1027-1035; package tests `relay_test.go` lines 804-810 | AC-18(d) now requires a package-internal accessor, matching the package's ability to test unexported helpers from same-package `_test.go` files. |
| R4V-D4.3 | PASS | AC-18(f) lines 1062-1077 | AC-18(f) defines baseline as pre-test `retentionMapSize()` for the coordinator instance and gives a 4-step bounded-state assertion. |

### Category R4V — Round-4 fix verification

(no findings)

All requested round-4 targets are PASS in the table above. Note: the prompt describes "2 MAJOR + 5 MINOR" but enumerates 8 target IDs; this audit verified all 8 enumerated IDs.

### Category A5 — Locked-decision preservation

#### A5.1 Retention/defer creation gate is implicit, not explicit [MINOR]

Location: SPEC-010 R-3.1.10 clause 1 lines 522-540; L-1 lines 270 and 805-809.

What:
Clause 1 says that after `parseAuthInitial` succeeds, the coordinator MUST attach parsed initial-stage values to a retention entry and install `defer releaseRetention(authAttemptID)`, but it does not explicitly say this happens only when initial-stage SPEC-010 fields are present.

Why it matters:
The prompt's A5 lock check expects the defer to install only when SPEC-010 fields are present in the initial frame. An unconditional retention/defer path would likely be public-behavior-neutral, but it introduces unnecessary internal state on the all-legacy L-1 path.

Recommendation:
Add one sentence to clause 1: "Create this retention entry and install the defer only when `supported_models` or `publishes_supported_models` is present on the initial-stage frame; otherwise no SPEC-010 retention state is created."

### Category B5 — §3.1.C proof-stage table accuracy

(no findings)

Notes:
`ParseAuthRequest` validates `type`, `version`, and `stage` at `messages.go` lines 302-329; proof routing then reaches `parseAuthProof`, which requires `auth_attempt_id` and `provider_id` and optionally reads `attestation_token` at lines 391-401. §3.1.C correctly marks `supported_models` and `publishes_supported_models` as SPEC-010 proof-stage extension fields governed by R-3.1.10 clauses 2-4. §3.1.A remains initial-stage-only and contains no `attestation_token` row.

### Category C5 — R-3.1.10 clause 5 defer mechanism

(no findings)

Notes:
A `defer releaseRetention(authAttemptID)` installed immediately after retention creation and before `writeServerText` would fire on every relevant `handleV2Conn` return path: challenge write failure at lines 374-377, proof read/type/parse failures at lines 379-397, auth-attempt/provider/expiry rejection at lines 398-401, attestation failure at lines 403-407, response write failure at lines 447-455, and normal return after `readProviderLoop` at lines 459-460. The cap claim is also code-grounded: one upgraded provider connection reserves one unauthenticated slot, runs one `handleConn` goroutine, and dispatches to exactly one v1 or v2 auth flow.

### Category D5 — AC-18 sub-case refinements

#### D5.3 AC-18(f) 1s settlement window is arbitrary under synchronous defer semantics [MINOR]

Location: SPEC-010 AC-18(f) lines 1051-1077.

What:
AC-18(f) correctly says the disconnect-before-proof defer fires synchronously on `handleV2Conn` return, but the bounded-state assertion then allows "a bounded settlement window of 1s" without tying that value to a timeout, goroutine join, or other measurable implementation condition.

Why it matters:
The AC remains implementable, but an arbitrary time allowance can mask a race in the test harness or make a synchronous cleanup requirement look like polling-based eventual cleanup.

Recommendation:
Replace the fixed 1s allowance with a deterministic harness condition, such as waiting for the 100 handler goroutines to return and then asserting `retentionMapSize() == baseline`; if a timeout is retained, state that it is only a test harness join timeout, not a cleanup semantic.

### Category E5 — Companion-spec annotations

(no findings)

Notes:
§6.1 and §6.2 remain candidate annotations rather than edits to locked SPEC-001 v1.2.4 or SPEC-002 v1.3.4. §6.2 still keeps the auth-attempt lifecycle candidate at lines 1193-1216 and clarifies release on success, proof rejection, expiry, and disconnect-before-proof.

### Category F5 — Lock readiness assessment

(no findings)

Notes:
Major-count trajectory is 3 / 3 / 5 / 2 / 0. SPEC-010 v1.4 is READY TO LOCK because round 5 found 0 CRITICAL / 0 MAJOR. A decision-log entry should be added after lock in `beta/DECISION_CRITERIA.md` summarizing the SPEC-010 / SPEC-011 / SPEC-012 split and the 5-round audit history. Implementation readiness is adequate from the v1.4 text alone, with the minor polish items above not blocking BUILD prompt use.

### Category G5 — Anything else

#### G5.1 Stale self-version citation in §6.1 [MINOR]

Location: SPEC-010 §6.1 line 1144.

What:
The SPEC-001 v1.2.5 candidate says its BUILD prompt MUST cite "SPEC-010 v1.2 §3.1 and §3.6" even though the audited contract is v1.4.

Why it matters:
This is documentation drift, not a behavioral contract issue, but a BUILD prompt following the literal citation could anchor on an older revision instead of the lockable v1.4 text.

Recommendation:
When locking v1.4, update the citation to `SPEC-010 v1.4 §3.1 and §3.6` or `SPEC-010 v1.x locked §3.1 and §3.6`.

### Self-verification

- Round-5 section was appended after round 4; rounds 1-4 were not rewritten.
- Every requested round-4 finding ID has PASS / PARTIAL / FAIL in R4V.
- Every category R4V, A5, B5, C5, D5, E5, F5, and G5 has a section.
- Every round-5 finding includes severity, location, what, why, and recommendation.
- Round-5 executive summary states an explicit lock verdict: READY TO LOCK.
- No `d-inference` source was inspected.

---

## Round 6 — Codex GPT-5 — 2026-06-06 — LOCK CONFIRMATION

**Audited:** SPEC-010 v1.5 (specs/SPEC-010-model-catalog.md)
**Auditor model:** Codex / GPT-5
**Audit round:** 6 of N (LOCK confirmation pass)
**Date:** 2026-06-06
**Total findings:** 0 CRITICAL / 0 MAJOR / 0 MINOR / 0 QUESTION

### Round-6 executive summary — LOCK VERDICT

Verdict: **LOCK CONFIRMED.** SPEC-010 v1.5 closes all three round-5 polish findings with no new CRITICAL, MAJOR, or MINOR regressions found in the requested sanity-check surface.

### Round-5 fix verification (R5V)

| Round-5 finding | PASS/PARTIAL/FAIL | v1.5 location | Evidence |
|---|---|---|---|
| R5V-A5.1 retention/defer creation gate explicit | PASS | R-3.1.10 clause 1 lines 558-568 and 570-582 | The new presence gate creates retention state and installs the defer only when `supported_models` or `publishes_supported_models` is present, while preserving the v1.4 behavior exactly when the gate passes. |
| R5V-D5.3 AC-18(f) deterministic harness join | PASS | AC-18(f) lines 1094-1135 | The arbitrary settlement window is replaced by a `sync.WaitGroup` or equivalent join and a post-join `retentionMapSize() == baseline` assertion with no cleanup-semantics slack. |
| R5V-G5.1 §6.1 stale "v1.2" citation | PASS | §6.1 lines 1200-1203 | The SPEC-001 v1.2.5 candidate now cites `SPEC-010 v1.x locked §3.1 and §3.6`, avoiding the stale v1.2 anchor. |

### Category R5V — Round-5 fix verification

(no findings)

All three requested round-5 polish items are PASS. The v1.5 change log lines 10-35 also accurately summarizes the three edits.

### Category A6 — Locked-decision preservation (sanity check)

(no findings)

A6.1: When SPEC-010 fields are present, R-3.1.10 clause 1 lines 570-582 still requires the same retention entry and auth-attempt-scoped defer that v1.4 specified. The new guard only chooses whether that SPEC-010 path is entered.

A6.2: Legacy initial frames with neither SPEC-010 field present now explicitly create no SPEC-010 retention state, install no defer, and increment no retention metric at lines 558-568. That strengthens L-1's byte-identical default-path guarantee without adding observable behavior.

### Category B6 — AC-18(f) implementability (sanity check)

(no findings)

B6.1: `handleV2Conn` has a single linear return path for the v2 auth handler (`server.go` lines 315-460). A test-only hook that fires synchronously on return can signal a `sync.WaitGroup`, making AC-18(f)'s post-join cleanup assertion deterministic.

B6.2: The hook/accessor shape is consistent with AC-18(d)'s package-internal test accessor pattern: same package tests can reach unexported helpers without a production debug endpoint.

### Category C6 — §6.1 citation correctness (sanity check)

(no findings)

C6.1: The `SPEC-010 v1.x locked §3.1 and §3.6` citation at §6.1 lines 1200-1203 is acceptable because it intentionally points to the eventual locked SPEC-010 v1 line, rather than a stale draft patch number.

### Category D6 — Anything else

(no findings)

D6.1: The v1.5 polish pass introduces no new normative surface beyond the three targeted edits.

D6.2: No documentation drift found in the reviewed v1.5 lines or the round-5 fix targets.

D6.3: Not a finding, but the round-5 reminder still applies: add the SPEC-010 lock decision-log entry to `beta/DECISION_CRITERIA.md` after lock.

### Self-verification

- Round-6 section was appended after round 5; rounds 1-5 were not overwritten.
- Every round-5 MINOR has PASS / PARTIAL / FAIL in R5V.
- Every category R5V, A6, B6, C6, and D6 has a section.
- Executive summary states the explicit lock verdict: LOCK CONFIRMED.
- Code spot-checks covered `server.go` lines 315-460 and `messages.go` lines 333-388, plus surrounding parser context for the presence-gate feasibility check.
- No `d-inference` source was inspected.
