# SPEC-003 Redistribution Audit Report

Auditor: Codex GPT-5.5

Specs audited:
- SPEC-001 v1.2 commit d9dcb0d244df30f5442494ab60fd268dccff4f8b
- SPEC-002 v1.1 commit d9dcb0d244df30f5442494ab60fd268dccff4f8b
- SPEC-003 v0.2 commit d9dcb0d244df30f5442494ab60fd268dccff4f8b

Reference: SPEC-003 v0.1 (commit 0b4bbb7)

Audit completed: 2026-05-28T05:25:44Z

## TL;DR verdict

NEEDS REVISION. The redistribution is directionally right and the main backward-compat invariant holds for M4/M1 because SPEC-001 has the verbatim compatibility statement, § 6.6 is scoped to WS-tunneled mode, and SPEC-002 § 3 resolves config `endpoint_url` before WS tunneling. However, I found 4 CRITICAL and 7 MAJOR issues. The top risks are: SPEC-002's replicated § 7.1 wire schemas are stale and omit the v1.2 fields that § 3 depends on; SPEC-003 v0.1's WS error and demux semantics were partially lost during redistribution; and SPEC-003 v0.2 weakens the clean-Mac install acceptance criterion from "coordinator connection succeeds" to "succeeds or warns."

## Redistribution fidelity matrix (Category Z)

| v0.1 ID | v0.1 description | Destination spec + ID | Auditor verdict |
|---|---|---|---|
| FR-A1 | Deliver inference requests over provider WS | SPEC-001 FR-21; SPEC-002 FR-P14 | preserved |
| FR-A2 | Relay streaming WS chunks as SSE immediately | SPEC-001 FR-22; SPEC-002 FR-P14 | preserved |
| FR-A3 | Accumulate non-streaming chunks and return JSON | SPEC-001 FR-23; SPEC-002 FR-P14 | preserved |
| FR-A4 | Request ID correlation; unknown request_id discarded | SPEC-001 FR-24; § 6.6 ordering | semantically changed |
| FR-A5 | Multiplex up to max_concurrency over one WS | SPEC-001 FR-25; § 6.6 | preserved |
| FR-A6 | Buyer disconnect sends cancel_request, frees slot | SPEC-001 FR-26; SPEC-002 FR-P18 | preserved |
| FR-A7 | Provider-side handler reuses existing pipeline | SPEC-001 FR-21, FR-29 | preserved |
| FR-A8 | Error statuses map to coordinator HTTP behavior | SPEC-001 FR-27; SPEC-002 missing mapping | semantically changed |
| FR-A9 | Coordinator WS write buffer 64 messages | SPEC-002 FR-P19 | preserved |
| FR-A10 | Coordinator response timeout 300s, 3 strikes degrade | SPEC-002 FR-P20 | preserved |
| FR-A11 | Provider write buffer 256 chunks, pause/resume | SPEC-001 FR-28; OQ-5 | preserved |
| FR-A12 | HTTP-forwarding and WS-tunneled coexist | SPEC-001 FR-29/FR-30/FR-31; SPEC-002 § 3 | preserved |
| FR-B1 | Three admission tiers | SPEC-002 FR-P15 | preserved |
| FR-B2 | Unknown provider admitted provisional | SPEC-002 FR-P15/FR-P17; AC-11 | preserved |
| FR-B3 | Provisional rate, pool, request quotas | SPEC-002 FR-P16 | partial |
| FR-B4 | Close codes 4007/4008/4009 | SPEC-002 close-code table; AC-12/AC-14 | preserved |
| FR-B5 | Tier weight multiplier in routing | SPEC-002 § 5; FR-P15 | preserved |
| FR-B6 | Persist provisional/rejected providers | SPEC-002 FR-P17; § 7.5 | preserved |
| FR-B7 | Show tier and inference_path in /poolz | SPEC-002 FR-P21 | preserved |
| FR-C1 | GitHub Release shape | SPEC-003 FR-C1 | preserved |
| FR-C2 | install.sh contract and exit codes | SPEC-003 FR-C2 | preserved |
| FR-C3 | macprovider-cli update | SPEC-003 FR-C3 | preserved |
| FR-C4 | macprovider-cli status | SPEC-003 FR-C4 | preserved |
| FR-C5 | launchd plist | SPEC-003 FR-C5 | preserved |
| FR-C6 | macprovider-cli uninstall | SPEC-003 FR-C6 | preserved |
| FR-C7 | recommended_binary_version nudge | SPEC-003 FR-C7; SPEC-001 FR-32 | preserved |
| FR-C8 | Log rotation | SPEC-003 FR-C8 | preserved |
| FR-D1 | README Join the Network flow | SPEC-003 FR-D1 | preserved |
| FR-D2 | RAM-based model selection | SPEC-003 FR-D2 | preserved |
| FR-D3 | First-run self-test | SPEC-003 FR-D3 | preserved |
| FR-D4 | Status as contributor diagnostic | SPEC-003 FR-D4 | preserved |
| FR-D5 | Graceful degradation when coordinator unavailable | SPEC-003 FR-D5 | preserved |
| AC-1 | WS non-streaming through coordinator | SPEC-001 AC-11; SPEC-002 FR-P14 | preserved |
| AC-2 | WS streaming with TTFT check | SPEC-001 AC-12; SPEC-002 FR-P14 | preserved |
| AC-3 | Cancellation propagation | SPEC-001 AC-13; SPEC-002 FR-P18 | preserved |
| AC-4 | Concurrent multiplexing | SPEC-001 AC-14 | preserved |
| AC-5 | Pinned HTTP-forwarding compatibility | SPEC-001 AC-15; SPEC-002 § 3 | preserved |
| AC-6 | Provisional admission | SPEC-002 AC-11 | preserved |
| AC-7 | Provisional rate limit | SPEC-002 AC-12 | preserved |
| AC-8 | install.sh clean Mac reaches coordinator | SPEC-003 AC-1 | semantically changed |
| AC-9 | macprovider-cli update | SPEC-003 AC-2 | preserved |
| AC-10 | launchd reboot survival | SPEC-003 AC-3 | preserved |
| AC-11 | admin/promote | SPEC-002 AC-13 | preserved |
| AC-12 | admin/reject | SPEC-002 AC-14 | preserved |
| OQ-1 | WS frame size | SPEC-001 OQ-4 | preserved, rationale shortened |
| OQ-2 | WS write buffer sizing | SPEC-001 OQ-5 and SPEC-002 OQ-10 | duplicated |
| OQ-3 | Surface provisional tier to buyers | SPEC-002 OQ-6 | preserved, rationale shortened |
| OQ-4 | recommended_binary_version enforcement | SPEC-002 OQ-7 | preserved |
| OQ-5 | Code signing strategy | SPEC-003 OQ-1 | preserved |
| OQ-6 | Promotion persistence | SPEC-002 OQ-8 | preserved, rationale shortened |
| OQ-7 | Provisional identity verification | SPEC-002 OQ-9 | preserved |

## Findings by severity

### CRITICAL (4)

**C1 - SPEC-002 § 7.1 republishes stale hello/hello_ack schemas.**

Severity: CRITICAL

Category: A.2, A.3, A.4

Spec ref: SPEC-002 v1.1 § 7.1

Quoted spec text:
- `SPEC-002 § 3`: `if hello.endpoint_url is present and non-empty`
- `SPEC-002 § 7.1 hello`: `"attestation": null` followed by no `endpoint_url`
- `SPEC-002 § 7.1 hello_ack`: only `type`, `coordinator_version`, `assigned_id`, `heartbeat_interval_s`

What's wrong: SPEC-002 § 3 depends on `hello.endpoint_url`, and SPEC-001 § 6.5 defines both `endpoint_url` in hello plus `tier` and `recommended_binary_version` in hello_ack. SPEC-002's build-facing replicated schema omits all three fields and still shows `"provider_id": "uuid-of-this-instance"`, contradicting SPEC-001's stable provider_id clarification. This is a wire-contract hazard because a coordinator implementer following § 7.1 will not parse or emit the v1.1/v1.2 fields that routing mode and admission require.

Fix direction: Update SPEC-002 § 7.1's replicated hello/hello_ack schemas to match SPEC-001 v1.2 § 6.5 exactly, including optional `endpoint_url`, `tier`, and `recommended_binary_version`, and replace the provider_id example with an operator-issued stable ID such as `m4-anon` or `<operator-issued-provider-id>`.

**C2 - FR-A8 lost the coordinator error-behavior mapping.**

Severity: CRITICAL

Category: Z.1, B.6

Spec ref: SPEC-003 v0.1 FR-A8; SPEC-001 v1.2 FR-27 / § 6.6; SPEC-002 v1.1 FR-P14

Quoted spec text:
- v0.1 FR-A8: `Model not loaded | "error_model_not_loaded" | Return HTTP 503 to buyer`
- v0.1 FR-A8: `Queue full | "error_queue_full" | Return HTTP 503 to buyer; try next provider`
- SPEC-001 v1.2 FR-27: lists only status values.
- SPEC-002 v1.1 FR-P14: says chunks are relayed/accumulated, but gives no status-to-HTTP mapping.

What's wrong: The provider status enum survived, but the coordinator's normative behavior for each terminal status did not. The lost part is not commentary; it decides buyer HTTP status and whether `error_queue_full` tries the next provider. That is semantic loss from v0.1.

Fix direction: Add a SPEC-002 § 7.2 or FR-P14 table mapping each `inference_response_end.status` to buyer behavior exactly as v0.1 FR-A8 did. Keep provider-internal error messages out of the buyer body as v0.1 required.

**C3 - Request-id demux error handling was weakened during the move.**

Severity: CRITICAL

Category: Z.1, B.1

Spec ref: SPEC-003 v0.1 FR-A4; SPEC-001 v1.2 § 6.6

Quoted spec text:
- v0.1 FR-A4: `Messages with an unknown request_id are logged at warn level and discarded.`
- SPEC-001 v1.2 § 6.6: `The request_id is the demultiplexing key.`

What's wrong: v1.2 keeps the correlation field and ordering rules, but drops the explicit unknown-`request_id` behavior from v0.1. It also does not state duplicate active `request_id` handling. In a multiplexed relay, those are not optional polish: they determine whether stale or malicious provider frames can corrupt the wrong buyer stream.

Fix direction: Restore the v0.1 behavior in SPEC-001 § 6.6 or SPEC-002 FR-P14: unknown response IDs are warn+discard; duplicate active IDs are protocol errors; completed request IDs have a defined cleanup window.

**C4 - SPEC-003 AC-1 weakens the clean-Mac onboarding pass condition.**

Severity: CRITICAL

Category: Z.2, E.2

Spec ref: SPEC-003 v0.2 AC-1

Quoted spec text:
- v0.1 AC-8: `Self-test passes (model loads, inference works, coordinator connection succeeds).`
- v0.2 AC-1: `Self-test passes (model loads, inference works, coordinator connection succeeds or warns).`

What's wrong: v0.1's acceptance criterion proved the core product promise: clean Mac to in-pool provider. v0.2 allows a warning on coordinator connection while still claiming pass and a "Ready to serve" message in under 2 minutes. That changes a normative acceptance criterion and can ship an installer that never joins the pool.

Fix direction: Restore `coordinator connection succeeds` as the pass condition. If offline install is desired, define it as a separate degraded-mode AC that does not satisfy build-complete.

### MAJOR (7)

**M1 - Provisional request quota is not integrated into routing.**

Severity: MAJOR

Category: C.1, M.2

Spec ref: SPEC-002 v1.1 FR-P16 and § 5

Quoted spec text:
- FR-P16: `Over quota -> skip provider in routing`
- § 5 pseudocode: filters state, slots, context, then appends candidates; no quota check.

What's wrong: The quota exists as an FR, but the executable routing algorithm never checks it. The pinning path returns a provider before any quota check, so a buyer who can target a provisional `provider_id` may bypass the intended cap.

Fix direction: Add a quota predicate before returning either pinned or candidate providers. Define the buyer-visible result when a pinned provisional provider is over quota.

**M2 - Routing pseudocode still uses case-sensitive model comparison.**

Severity: MAJOR

Category: H.1, G.2

Spec ref: SPEC-002 v1.1 § 5

Quoted spec text:
- Pseudocode: `if provider.model_id != model`
- Selection detail: `Model match is case-insensitive string comparison`

What's wrong: D9 exists because a case-sensitive comparison caused a production 404 storm. The prose fix is present, but the high-value pseudocode still implements the old bug in both provider-pinning and candidate filtering.

Fix direction: Replace both comparisons with a named `model_id_equal(a,b)` or `casefold(a) == casefold(b)` helper and state that canonical casing is preserved only for display/storage.

**M3 - OQ-2 was duplicated as SPEC-001 OQ-5 and SPEC-002 OQ-10.**

Severity: MAJOR

Category: Z.3, Z.4, J.1

Spec ref: SPEC-001 OQ-5; SPEC-002 OQ-10; SPEC-003 v0.2 OQ note

Quoted spec text:
- SPEC-003 v0.2 note: `OQ-2 (WS write buffer) -> SPEC-001 v1.2 OQ-5`
- SPEC-002 OQ-10: `Per-provider WS write buffer sizing. FR-P19 specifies 64 messages.`

What's wrong: The redistribution note says OQ-2 moved to SPEC-001 only, but SPEC-002 adds OQ-10 for the coordinator write buffer. This duplicates the same v0.1 concern across specs and pushes total OQ count above the intended range.

Fix direction: Pick one home. Recommended: keep coordinator-side buffer sizing in SPEC-002 and provider-side buffer sizing in SPEC-001, but make the split explicit and update the SPEC-003 note. Do not leave two OQs both presented as the v0.1 OQ-2 destination.

**M4 - SPEC-003 has a broken clean-room cross-reference.**

Severity: MAJOR

Category: A.1, K.1

Spec ref: SPEC-003 v0.2 § 7.3

Quoted spec text: `SPEC-003 v0.2 inherits the strict clean-room policy from SPEC-001 v1.2 § 8.2 and SPEC-002 v1.1 § 8.2.`

What's wrong: SPEC-001 v1.2's clean-room section is § 7.2, not § 8.2. The SPEC-002 reference resolves; the SPEC-001 reference does not.

Fix direction: Change the reference to SPEC-001 v1.2 § 7.2.

**M5 - SPEC-002's nak behavior contradicts the backward-compat fallback.**

Severity: MAJOR

Category: F.4, H.4

Spec ref: SPEC-001 v1.2 change log; SPEC-002 v1.1 § 7.1

Quoted spec text:
- SPEC-001 change log: coordinators observing unexpected § 6.6 `nak` `MUST mark the routing-mode resolution buggy and not retry`
- SPEC-002 § 7.1: `Do NOT disconnect the provider. A nak is informational`

What's wrong: General nak behavior is fine for old message types, but SPEC-001's backward-compat note requires special handling if an HTTP-forwarding/v1.1.x provider receives an unexpected § 6.6 message. SPEC-002 does not carry that requirement, and no SPEC-002 AC tests the coordinator-side fallback.

Fix direction: Add a § 7.1 paragraph or AC stating that `nak unknown_message_type` in response to § 6.6 dispatch is a routing-mode bug and the session is treated HTTP-forwarding-only / not retried.

**M6 - OQ rationales were shortened instead of preserved intact.**

Severity: MAJOR

Category: Z.3

Spec ref: SPEC-001 OQ-4/OQ-5; SPEC-002 OQ-6/OQ-8/OQ-9/OQ-10

Quoted spec text:
- v0.1 OQ-1 includes the non-streaming max_tokens bound and gobwas/ws note.
- SPEC-001 OQ-4 compresses this to a shorter "current position" paragraph.

What's wrong: The redistribution prompt explicitly required each OQ to retain its rationale paragraph. Several OQs preserve the decision but shorten the rationale. That makes the operator re-research context that v0.1 already captured.

Fix direction: Restore the rationale paragraphs verbatim or near-verbatim under each redistributed OQ.

**M7 - SPEC-001 OQ-3 is now decidable and stale.**

Severity: MAJOR

Category: J.2

Spec ref: SPEC-001 v1.2 OQ-3; SPEC-003 v0.2 FR-C1/FR-C2

Quoted spec text: `How does the binary reach contributors? Options: GitHub Releases download, Homebrew tap, direct link from operator.`

What's wrong: SPEC-003 v0.2 answers this: GitHub Releases plus `https://get.streamvc.live/install.sh`. Leaving SPEC-001 OQ-3 open creates an artificial OQ that conflicts with the redistributed distribution spec.

Fix direction: Close OQ-3 in SPEC-001 as resolved-by-SPEC-003, or remove it from the open-question list.

### MINOR (3)

**m1 - SPEC-003's D8 cross-reference is too narrow.**

Severity: MINOR

Category: A.1

Spec ref: SPEC-003 v0.2 § 8

Quoted spec text: `D8 (drain conflation) -> SPEC-002 v1.1 FR-P14`

What's wrong: D8 is about coordinator drain not terminating WS-tunneled inference. SPEC-002 covers that in D8 plus drain lifecycle requirements, not only FR-P14. The reference is not broken, but it is too imprecise for a future reader.

Fix direction: Reference SPEC-002 § 10 D8 and SPEC-001 FR-30.

**m2 - SPEC-001 hello text is locally confusing about absent endpoint_url.**

Severity: MINOR

Category: A.3

Spec ref: SPEC-001 v1.2 § 6.5

Quoted spec text: `When absent or null, the provider operates in WS-tunneled mode` followed by `because v1.1.x binaries are in config.providers[] ... fallback to config.providers[].endpoint_url`.

What's wrong: The global invariant is correct, but the local paragraph first says absent means WS-tunneled, then immediately adds a config fallback exception. This is easy to misread if SPEC-001 is read without SPEC-002 § 3.

Fix direction: Phrase it as "absent/null is the provider-side WS signal; final mode is resolved by SPEC-002 § 3 using both hello and config."

**m3 - SPEC-003 v0.2 misses the 1200-1500 line target without justification.**

Severity: MINOR

Category: Z.7

Spec ref: SPEC-003 v0.2 whole document

Quoted evidence: `wc -l specs/SPEC-003-open-onboarding.md` returns 752.

What's wrong: The redistribution prompt targeted 1200-1500 lines and the audit prompt asks for justification if shorter. I found no note justifying the 752-line result. This is not itself build-blocking, but it is a process-control miss.

Fix direction: Add a short redistribution note explaining why Parts C+D are genuinely smaller after A+B moved out, or restore omitted explanatory material that should have remained in SPEC-003.

### QUESTIONS (1)

**Q1 - Should unknown provisional providers be allowed to self-report an HTTP endpoint?**

Severity: QUESTION

Category: A.5, L.2

Spec ref: SPEC-002 v1.1 § 3

Quoted spec text: For provider not in config, `if hello.endpoint_url is present and non-empty: inference_path = HTTP_FORWARDING(hello.endpoint_url)`.

Question: This is deterministic, but it may reintroduce the public-endpoint path for strangers, which Part A was meant to remove. I cannot determine whether this is intentional compatibility for advanced users or accidental scope creep. If intentional, the reachability/security checks need to be stronger than the single comment currently present.

## Cross-spec consistency matrix

| Source spec/section | Reference target | Auditor verdict |
|---|---|---|
| SPEC-001 § 6.5 | SPEC-002 v1.1 § 7.5 | resolves |
| SPEC-001 § 6.6 | SPEC-002 § 3 mode resolution | resolves |
| SPEC-002 § 3 | SPEC-001 v1.2 § 6.5 endpoint_url | resolves |
| SPEC-002 FR-P14 | SPEC-001 v1.2 § 6.6 inference_request/chunk/end/cancel | resolves |
| SPEC-002 § 7.1 | Replicated SPEC-001 § 6.5 hello/hello_ack schema | broken / stale |
| SPEC-002 § 7.2 | SPEC-001 § 6.2 buyer request schema | resolves |
| SPEC-002 § 8.2 | SPEC-001 § 7.2 clean-room wording | resolves; verbatim with prior version |
| SPEC-003 § 2 | SPEC-001 v1.2 § 6.6 | resolves |
| SPEC-003 § 2 | SPEC-002 v1.1 § 7.5 | resolves |
| SPEC-003 § 7.3 | SPEC-001 v1.2 § 8.2 | broken; actual section is § 7.2 |
| SPEC-003 § 7.3 | SPEC-002 v1.1 § 8.2 | resolves |
| SPEC-003 § 8 | SPEC-002 v1.1 § 10 D7-D10 | resolves |

Clean-room check: SPEC-001 current § 7.2 is verbatim identical to commit 0b4bbb7's clean-room block. SPEC-002 current § 8.2 is verbatim identical to commit 0b4bbb7's clean-room block.

## OQ disposition

**SPEC-001 OQ-4 / v0.1 OQ-1 - WS frame size.**
I can answer this from v0.1: no explicit response frame size limit for v1; keep the 16 MB `inference_request` cap, rely on provider `max_tokens`, and monitor AC-2. The OQ can remain as a telemetry follow-up, but its rationale should be restored.

**SPEC-001 OQ-5 / v0.1 OQ-2 - Provider-side write buffer.**
Real operator decision. 256 chunks is a reasonable v1 default from v0.1's rationale. The duplicated SPEC-002 OQ-10 should be split or removed.

**SPEC-002 OQ-6 / v0.1 OQ-3 - Surface provisional tier to buyers.**
Answerable from source materials: do not surface tier in v1. The v0.1 rationale is sufficient: routing weight handles QoS and a tier header creates a premature SLA promise.

**SPEC-002 OQ-7 / v0.1 OQ-4 - Version enforcement.**
Answerable from source materials: no enforcement in v1. SPEC-003 FR-C7 and v0.1 OQ-4 both say `recommended_binary_version` is informational.

**SPEC-003 OQ-1 / v0.1 OQ-5 - Code signing.**
Answerable from source materials: v1.2 ships unsigned; `install.sh` runs `xattr -d com.apple.quarantine`; notarization is later.

**SPEC-002 OQ-8 / v0.1 OQ-6 - Promotion persistence.**
Answerable from source materials: no auto-edit of config in v1. Runtime promotion plus manual `coordinator.yaml` update is the intended workflow.

**SPEC-002 OQ-9 / v0.1 OQ-7 - Provisional identity.**
Answerable from source materials: UUID self-reporting is acceptable for v1, with reduced weight and quotas. Stronger identity is Tier 2.

**SPEC-002 OQ-10 - Coordinator write buffer sizing.**
This appears to be a duplicate/scope split of v0.1 OQ-2. It should either be merged with the appropriate OQ destination or rewritten as a distinct coordinator-only telemetry question.

**SPEC-001 OQ-3 - Binary distribution method.**
Answerable from SPEC-003 v0.2 FR-C1/FR-C2. It should not remain open.

## Suggested fix order

1. Fix CRITICAL redistribution losses first: restore FR-A8 coordinator error behavior, FR-A4 unknown/duplicate request-id handling, and AC-8's coordinator-success pass condition.
2. Patch SPEC-002 § 7.1 wire schemas to match SPEC-001 v1.2 § 6.5, including endpoint_url and hello_ack fields.
3. Patch routing implementability: case-insensitive model comparison in pseudocode and provisional request-quota filtering in every routing path.
4. Resolve OQ hygiene: remove duplicate OQ-10 or explicitly split it, close stale SPEC-001 OQ-3, and restore OQ rationale paragraphs.
5. Fix cross-references and low-friction drift: SPEC-003 clean-room reference, D8 reference, and SPEC-001 endpoint_url wording.
6. Add or revise ACs for coordinator-side backward compatibility: observe `nak unknown_message_type` after an accidental § 6.6 dispatch and mark the session HTTP-forwarding-only / do not retry.
