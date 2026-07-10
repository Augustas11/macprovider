# SPEC-015 v0.1 audit report

## Round 1 (Codex, 2026-06-22T08:53:20Z)

### Summary
- 3 CRITICAL findings
- 8 MAJOR findings
- 4 MINOR findings
- 2 QUESTIONS

SPEC-015 v0.1 is directionally coherent: it chooses a compact seven-field
receipt, keeps the v0.1 trust root honest, defers model-hash binding, and
mostly preserves the OpenAI body shape by using metadata outside the JSON
response. It is not ready to lock. The blocking issues are concentrated in
streaming transport compatibility, locked-spec boundary discipline, and
canonicalization precision.

### Category sweep

| Category | Result |
|---|---|
| A BUILD-prompt directive fidelity | Findings C3, M7, m2 |
| B Receipt content correctness | Findings M8, q1; seven-key tuple otherwise pinned |
| C Canonicalization correctness | Findings M1, M2, M4 |
| D Wire transport | Finding C1; header name does not collide |
| E Keypair lifecycle | Findings C2, C3, M3, M5 |
| F Pubkey trust root | Finding q1; operator-mutability is otherwise honest |
| G Audit categories and observability | Finding M6 |
| H Storage and persistence | Finding C3 |
| I Cross-spec invariant preservation | Findings C2, C3, M4, m1 |
| J Acceptance criteria quality | Findings C1, M3, M7, m2 |
| K Honesty about deferrals | No additional findings beyond q1/q2 |
| L Spec hygiene | Findings m1, m2, m3, m4 |

### CRITICAL findings

C1. Streaming `event: receipt` breaks OpenAI SDK drop-in parsing
    **Location:** §6.3 lines 596-628; AC-R8/R10 lines 1061-1077
    **Finding:** SPEC-015 emits a terminal SSE event whose `data:` value is the raw `<base64(JCS(T))>.<base64(SIG)>` receipt string, and claims the Python and JavaScript OpenAI SDKs skip unknown event types. Current official SDK source contradicts that claim: openai-python's stream loop JSON-parses every non-`[DONE]` SSE `data` payload unless the event starts with `thread.`, and openai-node does the same when `event` is null or does not start with `thread.`. A base64 receipt string is not JSON, so `chat.completions.create(stream=True)` will raise before `[DONE]`.
    **Why it matters:** The audit prompt classifies OpenAI SDK streaming incompatibility as CRITICAL. This also invalidates AC-R10 as drafted.
    **Suggested fix:** Do not emit a custom non-JSON receipt event into the OpenAI chat-completions stream unless verified against both SDKs. Candidate fixes need a new compatibility proof, e.g. encode as an OpenAI-compatible JSON chunk the SDK accepts, move streaming receipts to a post-stream fetch surface, or defer streaming receipts until a tested SDK-compatible shape exists.

C2. The proof-stage `auth_request` extension exceeds the allowed SPEC-001 candidate boundary
    **Location:** §7.2 lines 678-700; locked SPEC-001 v1.5 §6.7.1 lines 1758-1787 and §6.7.2 lines 1853-1870
    **Finding:** The audit prompt allows exactly one SPEC-001 v1.6 candidate annotation: `provider_receipt_public_key` on the initial-stage `auth_request` frame. SPEC-015 also declares the field valid on the proof-stage echo. Locked SPEC-001 proof-stage required/optional fields do not include arbitrary echo fields; R-6.7.6 only discusses `supported_models[]` and `publishes_supported_models`.
    **Why it matters:** This is scope creep across a locked spec boundary. A conforming SPEC-001 v1.5 proof parser can reject the extra proof-stage field, or two implementations can disagree on whether proof-stage echo is required, optional, or forbidden.
    **Suggested fix:** Restrict `provider_receipt_public_key` to the initial-stage candidate annotation only. If proof-stage echo is required later, name it as a separate SPEC-001 candidate with its own compatibility analysis.

C3. Coordinator persistence requires locked SPEC-002/storage changes outside the allowed `/poolz` annotation
    **Location:** §7.3 lines 702-721; §13 lines 1002-1010; locked SPEC-002 v1.3.5 §7/FR-O5 lines 1376-1385
    **Finding:** SPEC-015 mandates `ALTER TABLE providers ADD COLUMN receipt_pubkey TEXT` plus additional `providers.receipt_pubkey_prev` and `providers.receipt_pubkey_rotated_at` storage. The audit prompt's allowed SPEC-002 v1.4 candidate is limited to `receipt_pubkey` and `receipt_pubkey_prev` on `/poolz` provider rows. Locked SPEC-002 also states live pool routing state is in-memory only across coordinator restart. The current coordinator schema has durable `provider_tokens`, `request_log`, admission/canary/audit/billing tables, but no locked `providers` table matching the requested ALTER.
    **Why it matters:** This is both unimplementable as written and a locked-spec boundary violation. The spec tries to change coordinator persistence semantics, not merely annotate `/poolz`.
    **Suggested fix:** Either make receipt pubkey persistence a separate SPEC-002 v1.4 candidate with the actual storage surface named, or keep SPEC-015 to the allowed `/poolz` annotation and defer persistence mechanics to the implementation BUILD prompt.

### MAJOR findings

M1. `prompt_hash` excludes output-affecting OpenAI request fields
    **Location:** §4.2 lines 364-396; SPEC-006 v0.8.3 lines 1042-1048
    **Finding:** The canonical prompt object excludes `presence_penalty`, `frequency_penalty`, `logit_bias`, `logprobs`, `top_logprobs`, and `n`, even though several of these are accepted/forwarded by SPEC-006 and materially affect generation or response shape.
    **Why it matters:** A receipt can verify against the same messages/model/temperature while failing to commit to parameters that changed the output distribution. That weakens "prompt binding" and will confuse buyers comparing their raw request with a receipt.
    **Suggested fix:** Either include all output-affecting OpenAI request fields forwarded to the provider, or explicitly rename the field/claim to a narrower "prompt subset hash" with a buyer-visible limitation.

M2. JCS reuse claim does not match the current Swift canonicalizer
    **Location:** §1.3 lines 189-193; §3.2 lines 296-304; §4.2 lines 373-374; §4.3.1 lines 419-422; RFC8785JCS.swift lines 5-11, 29-30, 48-75
    **Finding:** SPEC-015 says no parallel canonicalizer is permitted and reuses `RFC8785JCS.swift`, but the Swift `Value` enum supports only `int`, not JSON floating-point numbers. The spec's prompt object includes `temperature` and `top_p` as floats. The file also performs string escaping and UTF-16 key sorting but does not perform NFC normalization; SPEC-015 requires NFC in prompt/output canonicalization.
    **Why it matters:** Implementers cannot satisfy the prompt canonicalization rules using the named in-house implementation as-is. A verifier and provider can diverge on floats or Unicode normalization while both believe they are following "JCS".
    **Suggested fix:** Define a pre-JCS normalization profile and either extend the shared Swift canonicalizer to support RFC8785 JSON numbers and explicit NFC-normalized strings, or state that SPEC-015 uses a new canonicalization helper with tests.

M3. Rotation grace expiration mixes timestamps and request counts
    **Location:** §7.5 lines 757-763; §7.5.2 lines 787-805; AC-R12 lines 1088-1094
    **Finding:** The grace window is `min(7 days, 10000 requests)`, but `receipt_pubkey_prev.expires_at` is defined as `min(rotated_at + 7*86400, rotated_at_request_count + 10000-request equivalent)`. A request count is not a Unix timestamp, and the spec does not define what requests are counted, where the counter is stored, or how a buyer interprets `expires_at` when the count threshold fires first.
    **Why it matters:** Buyers and coordinators cannot deterministically know whether the previous key is still valid. Two conforming implementations could expire at different times and reject otherwise valid receipts.
    **Suggested fix:** Split time and count into explicit fields, e.g. `expires_at` plus `expires_after_request_index`, or choose only a time-based grace window for v0.1.

M4. Streaming/non-streaming receipt byte-identity AC is impossible
    **Location:** §5.5 lines 556-564; AC-R8 lines 1061-1065
    **Finding:** §5.5 correctly requires identical `output_hash` for identical output bytes across streaming and non-streaming. AC-R8 goes further and requires the streaming receipt `data:` value to be byte-identical to the non-streaming `X-MacProvider-Receipt` header for an equivalent request. The receipt tuple includes `ttft_ms` and `unix_ts`, so two separate requests will normally produce different signed payloads even if their output bytes match.
    **Why it matters:** This AC is not mechanically satisfiable except in artificial same-timestamp/same-latency conditions. It will fail correct implementations.
    **Suggested fix:** Change AC-R8 to require the same wire format and exactly one terminal receipt event, and let AC-R9 cover `output_hash` equality.

M5. First-launch Keychain generation race is not specified
    **Location:** §7.1 lines 654-676
    **Finding:** The first-launch algorithm is check-then-generate-then-store, but it does not define the atomic Keychain operation or duplicate-item handling when two `serve` processes launch simultaneously with the same `provider_id`.
    **Why it matters:** A race can produce two private keys, publish one pubkey, and sign with another depending on which process caches which value. That leads to non-verifying receipts and hard-to-debug operator behavior.
    **Suggested fix:** Require an atomic insert-or-load pattern: on duplicate item, discard the generated key and reload the existing Keychain item; only one key may be cached for a `(service, account)` pair.

M6. Audit event prose contradicts its field list
    **Location:** §11 lines 960-978
    **Finding:** `receipt_issued` lists seven fields (`provider_id`, `request_id`, `model_id`, `tokens_out`, `ttft_ms`, `unix_ts`, `signature_len=64`), then says logging "the four scalar fields listed" is sufficient.
    **Why it matters:** Audit sinks are used for reconciliation and incident review. Ambiguous event schemas reliably become implementation drift.
    **Suggested fix:** State the exact field set once. If only four are intended, identify which four and why `provider_id/request_id/model_id` are inherited from common audit fields.

M7. Manual rotation CLI name drifts from the BUILD prompt
    **Location:** BUILD prompt line 59; SPEC-015 §1.1 line 85 and §7.5 lines 738-747
    **Finding:** The BUILD prompt required manual rotation via `macprovider rotate-key`; SPEC-015 specifies `macprovider rotate-receipt-key`.
    **Why it matters:** This is BUILD-prompt directive drift on an operator-facing command. It is not architecturally deep, but it will create implementation/test mismatch unless the operator intentionally accepts the rename.
    **Suggested fix:** Either use `macprovider rotate-key` or explicitly call out the rename as an operator-approved divergence.

M8. README schema divergence is not explained field-by-field
    **Location:** README lines 117-128; SPEC-015 §1 lines 63-69 and §3.1 lines 268-279
    **Finding:** The README sketch includes `model`, `provider_id`, `ts` as RFC3339, prefixed hashes/pubkeys/signature, and says the gateway issues the receipt. SPEC-015 changes these to `model_id`, no signed `provider_id`, Unix seconds, unprefixed hashes/base64 keys, and provider-side signing. The spec notes the README block exists but does not explain the divergences.
    **Why it matters:** The audit prompt required the spec to match or explain divergence from the README sketch. The missing `provider_id` explanation is especially important because buyer-visible provider identity is now out-of-band through `/poolz`.
    **Suggested fix:** Add a short compatibility note/table explaining each schema change and explicitly state whether `provider_id` is intentionally out-of-band.

### MINOR findings

m1. SSE citation names the wrong RFC
    **Location:** §6.3 lines 610-614
    **Finding:** The spec cites "RFC 8895 / SSE" for event framing. SSE event-stream processing is defined by WHATWG HTML; this citation is at best confusing.
    **Why it matters:** Minor reference hygiene issue, but a crypto/transport spec should not send implementers to the wrong standard.
    **Suggested fix:** Cite WHATWG HTML Server-sent events/event stream parsing, or simply say "per the SSE event-stream format."

m2. Acceptance criteria numbering does not match the BUILD prompt house-style directive
    **Location:** BUILD prompt lines 24-27; SPEC-015 lines 21 and 1025-1129
    **Finding:** The BUILD prompt says existing SPECs use `AC-1`, `AC-2`, etc. SPEC-015 uses `AC-R1` through `AC-R18`.
    **Why it matters:** This does not block implementation, but it is house-style drift in a spec corpus that relies on predictable AC labels.
    **Suggested fix:** Rename to `AC-1` through `AC-18`, or document that receipt ACs intentionally use an `R` namespace.

m3. `model_id` definition says both ASCII-normalized and byte-for-byte
    **Location:** §3.1 lines 271-279
    **Finding:** The `model_id` row says the value is "ASCII-normalized per SPEC-001" but also "stored in the receipt as the buyer submitted it byte-for-byte."
    **Why it matters:** The intended behavior is likely "match case-insensitively, store verbatim"; the current wording reads like the stored value is both normalized and verbatim.
    **Suggested fix:** Reword to: "Matching is ASCII case-insensitive per SPEC-001; the receipt stores the original request `model` string verbatim."

m4. Section 16 references README line ranges inconsistently
    **Location:** §16 lines 1180-1182
    **Finding:** SPEC-015 cites README lines 113-137 for the schema sketch, but the actual JSON schema block is README lines 117-128.
    **Why it matters:** Minor auditability issue.
    **Suggested fix:** Cite the precise block range.

### Operator questions surfaced

q1. Should `provider_id` be inside the signed tuple?
    **Location:** §3.1 lines 268-279; README lines 117-128; §8.1-§8.3 lines 839-889
    **Question:** SPEC-015 binds the key, not the human/operator-facing provider id. Is that intentional for v0.1, with `/poolz` as the out-of-band id-to-key map, or should `provider_id` be an eighth signed field?

q2. Should v0.1 receipts commit to all accepted request semantics or only prompt text/core sampling fields?
    **Location:** §4.2 lines 364-396
    **Question:** If the answer is "all accepted request semantics," M1 needs a fix. If the answer is "core prompt only," the product claim should be weakened so buyers do not think the receipt binds every field they sent.

### Verdict
- READY WITH FIX PASS

The design does not need a full reset, but it cannot lock until the streaming
transport is made SDK-compatible and the locked-spec boundary/canonicalization
issues are narrowed. A focused v0.1.1 fix pass plus re-audit should be enough
if the operator accepts the out-of-band provider-id posture.

### Self-verification
- [x] Read every section of SPEC-015 v0.1 (§§1-16, ACs R1-R18).
- [x] Compared SPEC-015 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented.
- [x] Walked each Category A through L. Even when no direct finding was found, noted in the category sweep.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location on every finding.
- [x] Suggested fix for CRITICAL findings.
- [x] Verdict at end.

## Round 2 (Codex, 2026-06-22T09:05:40Z)

### Preamble

The audit prompt says round 2 should be run by Claude after Codex. This
round was intentionally run by Codex again for cross-round consistency per
operator instruction. I audited the current SPEC-015 v0.1.1 fix pass, not the
v0.1 text from round 1.

### Summary
- 4 CRITICAL findings
- 4 MAJOR findings
- 2 MINOR findings
- 0 QUESTIONS

The round-1 fix pass closes most of the named round-1 findings directly:
C2, C3, M1, M2, M3, M4, M5, M6, M7, M8, m1, m2, m3, m4, and q1 are
substantively addressed. C1 is closed only in the narrow sense that the
`event: receipt` SDK parser break is removed. The replacement streaming
design introduces new locked-spec and BUILD-prompt violations, so v0.1.1 is
not ready to lock.

### Round-1 closure matrix

| Round-1 item | Round-2 status |
|---|---|
| C1 streaming `event: receipt` SDK break | Old bug closed, but new blockers C1/C3 below replace it |
| C2 proof-stage `auth_request` scope | Closed: field restricted to initial-stage only (§7.2 lines 824-853) |
| C3 coordinator ALTER TABLE/storage scope | Mostly closed: schema prescription removed (§7.3 lines 855-888; §13 lines 1179-1202) |
| M1 prompt field coverage | Closed for the six named missing fields (§4.2 lines 473-516) |
| M2 JCS reuse mismatch | Closed at spec level by naming required canonicalizer extensions (§3.2 lines 369-411) |
| M3 grace time+count ambiguity | Closed: time-only 7-day grace (§7.5.2 lines 954-977) |
| M4 streaming/non-streaming byte-identical receipt AC | Closed, but AC-9 is now non-executable (M2 below) |
| M5 Keychain race | Closed: atomic insert-or-load (§7.1 lines 787-817) |
| M6 audit event field contradiction | Closed (§11 lines 1132-1155) |
| M7 CLI name drift | Closed: `macprovider rotate-key` (§7.5 lines 905-914) |
| M8 README divergence | Closed with compatibility table (§16.1 lines 1391-1409) |
| q1 provider_id in tuple | Resolved explicitly (§3.1 lines 341-358) |

### Category sweep

| Category | Result |
|---|---|
| A BUILD-prompt directive fidelity | Findings C3, C4, M2 |
| B Receipt content correctness | Finding M3; seven-field tuple otherwise pinned |
| C Canonicalization correctness | Round-1 M1/M2 fixed; residual model-id/NFC wording issue M3 |
| D Wire transport | Findings C1, C3, C4 |
| E Keypair lifecycle | Findings C2, M1, M4 |
| F Pubkey trust root | Operator-mutability remains honest; finding M1 on `/poolz` candidate wording |
| G Audit categories and observability | Finding C4; omission reasons now map 1:1 |
| H Storage and persistence | Finding C4; coordinator durable-storage overreach removed |
| I Cross-spec invariant preservation | Findings C1, C2; locked files themselves are untouched |
| J Acceptance criteria quality | Finding M2 |
| K Honesty about deferrals | Finding C3; streaming deferral exceeds v0.1 BUILD contract |
| L Spec hygiene | Findings m1, m2 |

### CRITICAL findings

C1. `X-MacProvider-Receipt-Pending` is an unauthorized SPEC-006 response header
    **Location:** §1 lines 101-107; §6.3 lines 727-760; §6.4 lines 764-781; AC-8/AC-10 lines 1246-1270. Locked SPEC-006 v0.8.3 §17 lines 1079-1083 and §8.3 lines 1732-1736.
    **Finding:** The audit prompt allows exactly one SPEC-006 v0.9 candidate response-pass-through addition: `X-MacProvider-Receipt`. v0.1.1 introduces a second buyer-visible `X-MacProvider-*` response header, `X-MacProvider-Receipt-Pending`, and requires it on streaming responses. Locked SPEC-006 strips any `X-MacProvider-*` response header not on a documented response-pass-through allowlist, and the prompt did not authorize this second allowlist addition.
    **Why it matters:** This is a locked-spec boundary violation and is also unimplementable through the current gateway contract: a conforming SPEC-006 v0.8.3 gateway strips the pending header before the buyer sees it.
    **Suggested fix:** Do not introduce a second `X-MacProvider-*` header in v0.1. Either keep streaming receipt delivery fully out of v0.1 with no buyer-visible pending header, or name `X-MacProvider-Receipt-Pending` as a separate SPEC-006 candidate in a later spec round and re-audit that boundary.

C2. Rotation still invents a new provider WS control frame outside the allowed SPEC-001 candidate
    **Location:** §7.5 lines 916-930; §7.5.1 lines 932-952; AC-11 lines 1272-1279. Locked SPEC-001 v1.5 §6.7 lines 1758-1873.
    **Finding:** v0.1.1 keeps a new `provider_receipt_public_key_rotate` WS control frame. The audit prompt's locked-spec exception for SPEC-001 is limited to one parser-optional field, `provider_receipt_public_key`, on the initial-stage `auth_request` frame. A new provider-to-coordinator frame type is a separate protocol extension and is not one of the allowed annotations. The BUILD prompt also specified manual rotation as "new pubkey re-published on next WS auth frame," not a new live control frame.
    **Why it matters:** A locked SPEC-001 v1.5 coordinator has no obligation to parse or accept this frame. Two implementations can disagree on whether rotation requires reconnect/auth or a live frame, which creates key-publication races and non-verifying receipts.
    **Suggested fix:** For v0.1, make manual rotation happen via reconnect and the already-authorized initial-stage `auth_request` field. If live rotation is required, file it as an explicit SPEC-001 candidate extension with frame schema, parser behavior, replay defense, and ACs.

C3. Streaming responses no longer carry a signed receipt in v0.1.1
    **Location:** BUILD prompt lines 47-52; SPEC-015 §1 lines 101-107 and 121-130; §6.3 lines 727-746; AC-8/AC-9 lines 1246-1259.
    **Finding:** The BUILD prompt says streaming receipt transport "must be" present and asks the spec to pin where it appears. v0.1.1 instead states the receipt body is not obtainable from the streaming response and punts body delivery to an unspecified v0.x endpoint. This fixes the original SDK-breaking SSE encoding by removing the receipt from streaming v0.1 rather than by specifying a compatible receipt transport.
    **Why it matters:** Under the prompt's Category A rules, semantic drift from a "MUST normatively pin" item is CRITICAL. It also leaves the README/product claim only partially closed: non-streaming responses carry receipts, streaming responses carry at most a pending marker.
    **Suggested fix:** Either return v0.1.1 to a non-streaming-only SPEC and explicitly narrow the mission/product claim, or produce a streaming receipt transport that is SDK-compatible and within the allowed locked-spec candidate set.

C4. v0.1.1 both forbids and recommends server-side receipt retention
    **Location:** §6.3 lines 742-758; §13 lines 1193-1202.
    **Finding:** §13 says the coordinator MUST NOT store the `X-MacProvider-Receipt` value server-side under v0.1.1. §6.3 simultaneously says v0.1.1 implementations SHOULD retain the streaming receipt server-side for a bounded window so a future v0.x lookup endpoint can return it.
    **Why it matters:** The audit prompt treats server-side full-receipt persistence as CRITICAL because it violates the buyer-held/offline-verifiability posture. The contradictory MUST/SHOULD also leaves implementers unable to know whether retaining streaming receipts is compliant.
    **Suggested fix:** Remove the v0.1.1 retention SHOULD. If a future lookup endpoint needs bounded storage, defer both the endpoint and the storage contract to the same v0.x spec and do not recommend current retention.

### MAJOR findings

M1. `/poolz` candidate annotation says "one field" but the schema requires two
    **Location:** §1.3 lines 189-193; §7.5 lines 924-928; §8.1 lines 1013-1025.
    **Finding:** §1.3 says SPEC-015 annotates one additive `/poolz` field, `receipt_pubkey`. §8.1 and rotation require both `receipt_pubkey` and `receipt_pubkey_prev`. The audit prompt explicitly allowed `receipt_pubkey` and `receipt_pubkey_prev`, but the v0.1.1 relationship section no longer names the second field as part of the SPEC-002 v1.4 candidate.
    **Why it matters:** Rotation verification depends on buyers seeing the previous key during grace. If `receipt_pubkey_prev` is not clearly part of the candidate contract, a conforming `/poolz` implementation can omit the very field AC-12 needs.
    **Suggested fix:** State consistently that SPEC-002 v1.4 candidate adds exactly two optional provider-row fields: `receipt_pubkey` and `receipt_pubkey_prev`.

M2. AC-9 is explicitly not executable in v0.1.1
    **Location:** §14 AC-9 lines 1253-1259.
    **Finding:** AC-9 says the streaming/non-streaming `output_hash` equality check is "not directly executable until the v0.x endpoint exists." The audit prompt requires every AC to have a deterministic verification step.
    **Why it matters:** Acceptance criteria are the lock gate for the implementing PR. An AC that cannot run until an unspecified future endpoint exists cannot prove v0.1.1 conformance.
    **Suggested fix:** Move AC-9 to an informative future-invariant note, or scope it to an internal unit-level canonicalization test that does not depend on a future endpoint.

M3. `model_id` is both verbatim and NFC-normalized
    **Location:** §3.1 lines 329-335 and 360-367; §3.2 lines 383-391; §4.2 lines 473-476.
    **Finding:** The tuple table says `model_id` stores the buyer-submitted `model` string verbatim, with no normalization. §3.2 then requires every JSON string entering canonical form, explicitly including `model_id`, to be NFC-normalized before escaping. §4.2 also calls request `model` verbatim while §3.2 recursively normalizes prompt object strings.
    **Why it matters:** For non-ASCII model IDs or future provider labels, a provider and verifier can disagree on whether the receipt commits to raw submitted bytes or NFC-normalized text. That is a canonicalization ambiguity that can produce non-verifying receipts.
    **Suggested fix:** Choose one rule. Given SPEC-001 model matching is ASCII-oriented, the narrow fix is to require model IDs to be ASCII and state NFC is a no-op for `model_id`, while preserving NFC for prompt/output natural-language strings.

M4. Rotation writes the new private key before coordinator acceptance
    **Location:** §7.5 lines 916-930; §7.5.1 lines 944-952.
    **Finding:** The rotation sequence replaces the Keychain private key before sending and validating the rotate frame. If the coordinator rejects the frame because `ts` is outside ±300s, `provider_id` mismatches, or `new_pubkey` is malformed, the provider has already lost the old private key locally and the coordinator still publishes the old key.
    **Why it matters:** A failed rotation can leave the provider signing with a key not present in `/poolz`, or unable to sign receipts that match the old published key. This is a predictable operator-burden and verifier-failure path.
    **Suggested fix:** Stage the new key until coordinator acceptance, then commit it to Keychain atomically. On rejection, keep the old key active and omit receipts until state is known.

### MINOR findings

m1. v0.1 changelog still says receipts are specified for SSE responses
    **Location:** Change log v0.1 lines 60-65.
    **Finding:** The historical v0.1 changelog says `X-MacProvider-Receipt` applies to both non-streaming and SSE responses. v0.1.1 now defers streaming receipt body delivery.
    **Why it matters:** This is historical prose, not the operative contract, but it sends readers toward the rejected C1 design.
    **Suggested fix:** Amend the old changelog note or add a parenthetical that v0.1.1 supersedes the SSE delivery part.

m2. SPEC-011 drain references use §3.8 in some places but the local heading is §3.4
    **Location:** §1.3 lines 234-238; §16.2 lines 1434-1435; SPEC-011 v0.5 lines 790-835.
    **Finding:** SPEC-015 cites SPEC-011 §3.8 for drain semantics; the relevant normative drain section in the current file excerpt is §3.4, with additional compatibility text later under §3.8-era history.
    **Why it matters:** Minor reference hygiene; the substantive invariant is correct.
    **Suggested fix:** Cite the exact SPEC-011 requirement IDs or §3.4 drain semantics.

### Cross-spec invariant check

I verified the locked dependency files were not modified by this branch. `git diff --cached --name-only` lists only:
`specs/AUDIT_SPEC_015_V0_1_PROMPT.md`, `specs/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md`, `specs/SPEC-015-audit.md`, and `specs/SPEC-015-receipts.md`.

Version lines still match SPEC-015's dependency header:
SPEC-001 v1.5, SPEC-002 v1.3.5, SPEC-005 v0.3, SPEC-006 v0.8.3,
SPEC-008 v0.3, SPEC-011 v0.5, SPEC-013 v0.3.

Invariant status:
- SPEC-001 v1.5 text is untouched, but C2 shows SPEC-015 still demands a new WS frame outside the allowed annotation.
- SPEC-002 v1.3.5 text is untouched; the prior ALTER TABLE/storage issue is closed. M1 remains a `/poolz` candidate wording bug.
- SPEC-005 v0.3 text is untouched; `tokens_out` still reuses `effective_completion_tokens`, and null-usage `tokens_out=0` matches SPEC-005 §5.3.
- SPEC-006 v0.8.3 text is untouched, but C1 introduces an unauthorized second response header that SPEC-006 would strip.
- SPEC-008 v0.3 text is untouched; receipt issuance remains orthogonal to Pillars A/B/C.
- SPEC-011 v0.5 text is untouched; the same-runtime drain invariant is substantively preserved, aside from the minor citation issue m2.
- SPEC-013 v0.3 text and `RFC8785JCS.swift` are untouched; v0.1.1 no longer falsely claims the current helper already supports floats/NFC, but implementation must still add those extensions before emitting receipts.

### Verdict
- DESIGN ROUND NEEDED

The old round-1 blockers were mostly fixed, but the streaming replacement is not a narrow fix pass: it changes the v0.1 product contract, adds an unauthorized `X-MacProvider-*` header, and creates a storage contradiction. The rotation path also still needs a locked-spec boundary decision. These are design-boundary issues, not just prose polish.

### Self-verification
- [x] Read every section of SPEC-015 v0.1.1 (§§1-16, ACs 1-18).
- [x] Compared SPEC-015 v0.1.1 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists.
- [x] Checked closure of C1, C2, C3, and all 8 round-1 MAJOR findings.
- [x] Walked Categories A through L and recorded no-finding categories in the sweep.
- [x] Verified locked cross-spec files are untouched on disk and checked the current version lines.
- [x] Applied severity definitions from the prompt.
- [x] Included locations and suggested fixes for CRITICAL findings.

## Round 3 (Codex, 2026-06-22T09:16:45Z)

### Preamble

This round audited SPEC-015 v0.1.2, the post-round-2 fix pass. I treated the
round-2 DESIGN ROUND NEEDED findings as the closure target and used
`specs/AUDIT_SPEC_015_V0_1_PROMPT.md` as the severity contract, with the
operator's v0.1.x non-streaming concession considered an accepted scope
narrowing for this round.

### Summary
- 0 CRITICAL findings
- 1 MAJOR finding
- 3 MINOR findings
- 0 QUESTIONS

v0.1.2 closes the two locked-spec boundary blockers from round 2: the
unauthorized pending header is gone from the operative wire contract, and
rotation now uses reconnect plus the already-authorized initial-stage
`auth_request` field. The contradictory server-side retention clause is also
gone. The remaining blocker is narrower: the spec says v0.1.x is non-streaming
only, but several normative streaming/cancellation clauses survived outside
§6.3 and still read as v0.1.x requirements.

### Round-2 closure matrix

| Round-2 item | Round-3 status |
|---|---|
| C1 `X-MacProvider-Receipt-Pending` unauthorized header | Closed in the operative contract: §6.3 requires no receipt header, no pending header, no SSE event, and AC-8 forbids additional `X-MacProvider-*` response headers on streaming. Historical changelog text still mentions v0.1.1's rejected header, but labels it superseded. |
| C2 rotate control frame | Closed in the operative rotation design: §7.5 uses WS reconnect and explicitly says no new control frame. No `provider_receipt_public_key_rotate` frame remains outside historical changelog text. Minor stale AC wording remains (m2). |
| C3 streaming deferral drift | Directionally closed by §1.1, §1.2, §6.3, §9, and §15 Q5 narrowing v0.1.x to non-streaming only. Not fully internally consistent because normative streaming output/cancellation clauses remain (M1). |
| C4 contradictory retention | Closed: §13 prohibits coordinator/gateway storage of receipt header bytes and says there is no v0.1.x exception for streaming retention. |
| M1 `/poolz` field count | Substantively closed in §1.3 and the §8.1 schema, which include both `receipt_pubkey` and `receipt_pubkey_prev`. Minor singular wording remains (m1). |
| M2 AC-9 non-executable | Closed: the old streaming/non-streaming hash-equivalence AC is gone. AC-9 is now SDK compatibility and executable. |
| M3 `model_id` NFC vs verbatim | Closed: §3.1 pins `model_id` as ASCII-only, verbatim, and NFC no-op; §3.2 limits NFC to natural-language prompt/output strings. |
| M4 rotation Keychain race | Closed: §7.5 stages the new key in memory, commits Keychain only after successful reconnect auth/proof, and preserves old-key signing on failure. |

### Category sweep

| Category | Result |
|---|---|
| A BUILD-prompt directive fidelity | Accepted operator concession narrows v0.1.x to non-streaming; residual internal-consistency issue M1 |
| B Receipt content correctness | Seven-field tuple remains exact; `model_id` ASCII-only fix is coherent |
| C Canonicalization correctness | No new signature/canonicalization ambiguity for non-streaming receipts |
| D Wire transport | No new CRITICAL; only one buyer-visible receipt header remains |
| E Keypair lifecycle | Reconnect rotation closes the control-frame and Keychain race issues |
| F Pubkey trust root | `/poolz` operator-mutability remains honestly described |
| G Audit categories and observability | Rotation events now match reconnect design; no receipt body logging retained |
| H Storage and persistence | Server-side receipt-value retention is prohibited |
| I Cross-spec invariant preservation | Locked files are untouched; no new unauthorized locked-spec extension found |
| J Acceptance criteria quality | ACs are executable, but AC-11 has stale control-frame wording (m2) |
| K Honesty about deferrals | Streaming deferral is explicit, but M1 shows leftover normative streaming semantics |
| L Spec hygiene | Findings m1, m2, m3 |

### MAJOR findings

M1. Non-streaming scope narrowing still leaves normative streaming/cancellation
    semantics in v0.1.x
    **Location:** §5.2 lines 693-700; §5.3 lines 726-728; §5.4 lines
    741-744; §6.3 lines 793-827; §9 lines 1168-1170; §12 lines
    1242-1253; AC-8 lines 1325-1331.
    **Finding:** §6.3 and §9 say streaming requests are receipt-free in
    v0.1.x and the streaming path does not run receipt construction. AC-8
    also requires no extra streaming wire changes. But §5.2 still uses
    normative "For streaming responses" language and says the provider MUST
    hold a single byte buffer during the stream and NFC-normalize at end of
    stream; §5.3 similarly says streaming tool-call deltas MUST be
    concatenated. §5.4 defines a streaming buyer-disconnect
    `finish_reason="cancelled"`, and §12 says "Buyer disconnect after some
    tokens" produces a receipt with byte-estimated tokens. Those clauses read
    as v0.1.x implementation requirements even though v0.1.x no longer emits
    streaming receipts.
    **Why it matters:** Two conforming implementers can now resolve the
    non-streaming concession differently: one can leave streaming completely
    unchanged per §6.3/AC-8, while another can add buffering/canonicalization
    and receipt/cancel accounting per §5/§12. That is predictable
    implementation drift and operator burden, especially on the SDK-sensitive
    streaming path.
    **Suggested fix:** Make all streaming canonicalization text in §5
    explicitly informative forward-compatibility guidance, or move it under
    §15 Q5. In §12, change every streaming/buyer-disconnect row to "no
    receipt" for v0.1.x unless the row is explicitly about a non-streaming
    HTTP disconnect after full provider completion; if that edge is intended,
    define it without referencing streaming token chunks or SPEC-006
    streaming byte-estimation.

### MINOR findings

m1. `/poolz` candidate field count still has singular wording
    **Location:** §1.3 lines 260-265; §8.1 lines 1090-1102.
    **Finding:** §1.3 correctly says the SPEC-002 v1.4 candidate is an
    annotation pair with `receipt_pubkey` and `receipt_pubkey_prev`, and the
    §8.1 JSON schema includes both fields. §8.1 still says v0.1 "ANNOTATES
    one new field" per provider object.
    **Why it matters:** The operative schema is clear enough to avoid the
    round-2 MAJOR, but the singular wording can reintroduce audit churn.
    **Suggested fix:** Change §8.1 to "two new fields" or "one annotation
    pair".

m2. AC-11 still references an acknowledged rotation control frame
    **Location:** §7.5 lines 973-1029; AC-11 lines 1355-1363.
    **Finding:** v0.1.2 removes the rotation control frame, but AC-11's
    explanatory sentence says the -60 s slack covers receipts signed before
    "the rotation control frame was acknowledged."
    **Why it matters:** This is stale wording, not an operative frame
    requirement, because §7.5 and AC-10 define reconnect rotation. Still, it
    points readers back to the rejected design.
    **Suggested fix:** Replace with "before the reconnect rotation was
    accepted" or "before coordinator rotation detection".

m3. Several v0.1.1 labels remain in v0.1.2 normative prose
    **Location:** §3.2 lines 469-484; §4.2 lines 585-590; §7.2 lines
    913-919; §7.3 lines 930-956; §7.5.1 lines 1050-1054; §11 lines
    1229-1233; §13 lines 1257-1263; §16.1 lines 1470-1488.
    **Finding:** The spec is versioned v0.1.2, but multiple normative or
    reference clauses still say v0.1.1. Most are harmless leftovers from the
    previous fix pass.
    **Why it matters:** Version drift is a spec-hygiene problem and can
    confuse later lock/audit references, but it does not change receipt
    behavior.
    **Suggested fix:** Update stale v0.1.1 references to v0.1.2 where they
    describe the current contract; keep v0.1.1 only where discussing
    historical rejected designs.

### Cross-spec invariant check

`git diff --cached --name-only` lists only:
`specs/AUDIT_SPEC_015_V0_1_PROMPT.md`,
`specs/BUILD_SPEC_015_RECEIPTS_v0_1_PROMPT.md`,
`specs/SPEC-015-audit.md`, and `specs/SPEC-015-receipts.md`.

The locked dependency files themselves are not staged: SPEC-001 v1.5,
SPEC-002 v1.3.5, SPEC-005 v0.3, SPEC-006 v0.8.3, SPEC-008 v0.3,
SPEC-011 v0.5, and SPEC-013 v0.3 remain untouched by this branch.

Invariant status:
- SPEC-001: no new WS control frame remains; the only provider-wire
  extension is the initial-stage `provider_receipt_public_key` candidate.
- SPEC-002: `/poolz` is the only coordinator surface extension; durable
  storage mechanics remain deferred to implementation BUILD scope.
- SPEC-005: `tokens_out` continues to reuse `effective_completion_tokens`;
  null-usage errors keep `tokens_out: 0`.
- SPEC-006: only `X-MacProvider-Receipt` remains as the response-pass-through
  candidate; streaming adds no new header or SSE event.
- SPEC-008: receipt issuance remains orthogonal to Pillars A/B/C.
- SPEC-011: same-runtime receipt issuance still composes with warm-swap drain
  semantics.
- SPEC-013 / `RFC8785JCS.swift`: the spec still correctly names the required
  NFC and double-number extensions rather than claiming the current helper
  already supports them.

### Verdict
- READY WITH FIX PASS

No design reset is needed. The round-2 CRITICAL findings are closed in the
intended direction, and no new locked-spec or SDK-compatibility CRITICAL was
introduced. v0.1.2 still needs a focused prose/normativity pass to make the
non-streaming scope narrowing internally consistent and to clean stale
v0.1.1/control-frame wording before lock.

### Self-verification
- [x] Read SPEC-015 v0.1.2 end to end, including §§1-16 and AC-1 through
      AC-17.
- [x] Checked every round-2 CRITICAL and MAJOR against v0.1.2.
- [x] Searched for removed surfaces: `X-MacProvider-Receipt-Pending`,
      `provider_receipt_public_key_rotate`, rotate/control-frame wording,
      `AC-R`, stale AC numbering, and server-side retention.
- [x] Rechecked the BUILD prompt's pinned/deferred items with the operator's
      v0.1.x non-streaming concession.
- [x] Verified `git diff --cached --name-only` is limited to SPEC-015 prompt,
      build prompt, spec, and audit files.

## Round 4 (Codex, 2026-06-22T09:23:19Z)

### Preamble

This round audited SPEC-015 v0.1.3, the post-round-3 LOCK-candidate fix pass.
I treated Round 3's READY WITH FIX PASS findings as the closure target and
used `specs/AUDIT_SPEC_015_V0_1_PROMPT.md` as the severity contract. The LOCK
gate remains 0 CRITICAL and 0 MAJOR.

### Summary
- 0 CRITICAL findings
- 0 MAJOR findings
- 2 MINOR findings
- 0 QUESTIONS

v0.1.3 closes the Round 3 MAJOR finding. The operative v0.1.x contract is now
non-streaming-only throughout the tested surfaces: §§1, 5, 6, 9, 12, 14, and
15 consistently say streaming requests carry no receipt, no header, no SSE
event, and no altered `data:` payload. The remaining issues are stale-version
and schema-comment hygiene; they do not introduce verifier ambiguity, SDK
breakage, locked-spec scope creep, or a stronger-than-true trust-root claim.

### Round-3 closure matrix

| Round-3 item | Round-4 status |
|---|---|
| M1 residual streaming normative clauses | Closed. §5.2 and §5.3 now put streaming canonicalization under explicit informative v0.2+ forward-compat notes; §5.4 says v0.1.x streaming carries no receipt regardless of `finish_reason`; §9 says receipt construction steps do not run on streaming; §12 scopes the table to non-streaming and makes streaming any-outcome receipt-free; AC-8/AC-9 preserve SDK-compatible no-wire-change streaming. |
| m1 §8.1 "one new field" | Closed. §1.1 and §8.1 both say the `/poolz` candidate annotation adds two fields: `receipt_pubkey` and `receipt_pubkey_prev`. |
| m2 AC-11 control-frame wording | Closed. §7.5 and AC-10/AC-11 use reconnect-based rotation; AC-11 now says the slack covers receipt signing before reconnect-based rotation was accepted by the coordinator. |
| m3 stale v0.1.1 labels in current-contract prose | Partially closed. Most current-contract references now say v0.1.3, but several stale labels remain in historical/reference prose and one proof-stage paragraph. This is MINOR m1 below, not a LOCK blocker. |

### Category sweep

| Category | Result |
|---|---|
| A BUILD-prompt directive fidelity | No new blocker. The accepted v0.1.x non-streaming narrowing remains explicit and truthfully disclosed. |
| B Receipt content correctness | Seven-field tuple remains exact; no optional receipt fields added. |
| C Canonicalization correctness | Non-streaming prompt/output canonicalization remains deterministic; streaming canonicalization is informative v0.2+ guidance only. |
| D Wire transport | Exactly one buyer-visible candidate header remains: `X-MacProvider-Receipt`; streaming adds no header/event/payload mutation. |
| E Keypair lifecycle | Reconnect rotation and Keychain staging remain coherent; no control frame reintroduced. |
| F Pubkey trust root | `/poolz` operator mutability remains honestly described in §1.4 and §8.3. |
| G Audit categories and observability | Receipt audit events match non-streaming issuance/omission and reconnect rotation. |
| H Storage and persistence | Server-side receipt-value persistence remains prohibited; no streaming retention exception remains. |
| I Cross-spec invariant preservation | No new unauthorized locked-spec extension found; candidate annotations stay within SPEC-001, SPEC-002, and SPEC-006 boundaries. |
| J Acceptance criteria quality | ACs remain mechanically testable; stale tuple-version wording is MINOR m2. |
| K Honesty about deferrals | Streaming, verifier CLI, model-hash binding, on-chain anchoring, request-id binding, route binding, and stronger trust root remain deferred. |
| L Spec hygiene | MINOR findings m1 and m2. |

### MINOR findings

m1. Some stale version labels remain outside the v0.1.3 changelog
    **Location:** §7.2 lines 943-949; §11 lines 1255-1258; §15 Q5 lines
    1470-1493; §16.1 lines 1505-1523.
    **Finding:** v0.1.3 correctly updated many current-contract labels, but
    several non-changelog clauses still name v0.1.1 or v0.1.2. Most are
    historical explanations, but §7.2's proof-stage paragraph and §16.1's
    compatibility table also describe the still-current contract.
    **Why it matters:** This can confuse later audit/LOCK references and makes
    the v0.1.3 changelog overstate full closure of Round 3 m3. It does not
    change behavior: the proof-stage frame is still unmodified, streaming is
    still deferred, and the README compatibility table's field mapping remains
    correct.
    **Suggested fix:** In a post-LOCK polish pass, change current-contract
    labels to v0.1.3 and reserve v0.1.1/v0.1.2 labels only for explicitly
    historical rejected designs.

m2. Two version/comment hygiene leftovers remain in normative-adjacent text
    **Location:** §5.1 line 703; AC-15 lines 1415-1418.
    **Finding:** §5.1's schema comment still lists `"cancelled"` in the
    `finish_reason` examples even though §5.4 restricts v0.1.x non-streaming
    receipts to `"stop"`, `"length"`, `"tool_calls"`, `"content_filter"`, or
    `"error"` and moves streaming cancellation to an informative v0.2+ note.
    AC-15 also says "v0.1.2 tuple shape" instead of v0.1.3.
    **Why it matters:** Both are hygiene issues. §5.4 and §12 control the
    operative non-streaming behavior, so this does not re-open Round 3 M1.
    **Suggested fix:** Drop `"cancelled"` from the §5.1 v0.1.x schema comment
    or label it v0.2+ only; update AC-15 to v0.1.3.

### Non-streaming-scope consistency check

- §1.1/§1.2 define v0.1.x as non-streaming chat completions only and require
  buyer-facing copy to disclose that streaming is uncovered.
- §5.2/§5.3/§5.4 retain streaming canonicalization only as informative v0.2+
  design guidance; the v0.1.x receipt-bearing path is non-streaming.
- §6.3 says streaming requests emit no `X-MacProvider-Receipt` header, no SSE
  event, and no altered `data:` payload.
- §9 says receipt construction steps t4-t9 do not run on the streaming path.
- §11 includes `streaming_request` only as an omission reason, not as receipt
  construction.
- §12 scopes the failure table to non-streaming behavior and makes streaming
  any-outcome receipt-free.
- §14 AC-8 and AC-9 test that streaming carries no SPEC-015 wire changes while
  non-streaming carries the header.
- §15 Q5 keeps streaming receipt delivery as v0.2+ open design space.

Conclusion: v0.1.x non-streaming scope is internally consistent across the
requested sections. The stale `"cancelled"` schema comment is not enough to
create a second conforming v0.1.x streaming implementation path because §5.4,
§6.3, §9, §12, AC-8, and AC-9 all say streaming emits no receipt.

### Cross-spec invariant check

Locked dependency version lines remain the same as SPEC-015's dependency
header: SPEC-001 v1.5, SPEC-002 v1.3.5, SPEC-005 v0.3, SPEC-006 v0.8.3,
SPEC-008 v0.3, SPEC-011 v0.5, and SPEC-013 v0.3.

Invariant status:
- SPEC-001: the only provider-wire extension is the parser-optional
  `provider_receipt_public_key` field on the initial-stage `auth_request`;
  no proof-stage echo or rotation control frame is required.
- SPEC-002: `/poolz` gains exactly `receipt_pubkey` and
  `receipt_pubkey_prev`; storage mechanics remain BUILD-scope.
- SPEC-005: `tokens_out` continues to reuse `effective_completion_tokens`;
  null-usage errors keep `tokens_out: 0`.
- SPEC-006: only `X-MacProvider-Receipt` is added as a response-pass-through
  candidate; streaming adds no pending header or SSE receipt.
- SPEC-008: receipt issuance remains orthogonal to Pillars A/B/C and uses a
  distinct `provider_receipt_public_key` name.
- SPEC-011: same-runtime receipt issuance composes with warm-swap drain
  semantics; model-hash binding remains deferred.
- SPEC-013 / `RFC8785JCS.swift`: SPEC-015 still names NFC and double-number
  handling as required implementation extensions rather than claiming the
  current helper already provides them.

### Verdict
- READY TO LOCK

The v0.1 LOCK gate is met: 0 CRITICAL and 0 MAJOR findings remain. The two
MINOR findings above are post-LOCK polish items and do not block locking
SPEC-015 v0.1.3.

### Self-verification
- [x] Read SPEC-015 v0.1.3 end to end, including §§1-16 and AC-1 through
      AC-17.
- [x] Checked each Round 3 finding against v0.1.3.
- [x] Rechecked the requested non-streaming scope consistency across §§5, 6,
      9, 11, 12, 14, and 15.
- [x] Searched for removed or stale surfaces:
      `X-MacProvider-Receipt-Pending`, `provider_receipt_public_key_rotate`,
      control-frame wording, streaming/cancelled wording, and stale
      v0.1.1/v0.1.2 labels.
- [x] Checked BUILD-prompt directives under the accepted v0.1.x
      non-streaming narrowing.
- [x] Checked locked-spec version lines and relevant cross-spec invariants.
