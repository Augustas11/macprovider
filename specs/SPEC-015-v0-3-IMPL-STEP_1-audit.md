## Lens — CODE — Round 1

### Finding CODE-R1-HIGH-1 — HIGH — AC-42 defence-in-depth refusal is not implemented as specified

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:256-267`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:282-285`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:307-315`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:193-211`, `specs/SPEC-015-receipts.md:2798-2808`, `specs/SPEC-015-receipts.md:3618-3640`.

The implementation only emits `receipt_omitted: model_swap_violation` for `DrainCancelledError`, and does not implement the required synthetic/defence-in-depth refusal for an ambiguous request-start hash slot.

SPEC-015 §M.2.2 requires the provider to refuse receipt emission when the runtime detects swap-in-progress at receipt-emission time and cannot disambiguate which container served the response; AC-42 requires a synthetic harness where the request-start-hash slot is unset/corrupted and proves both no `X-MacProvider-Receipt` header and a `model_swap_violation` audit row. The HTTP success path always passes `snapshot.modelHash` into receipt construction, while the relay success path always passes `requestStartSnapshot.modelHash`; neither receipt-emission helper has enough state to distinguish “valid warm-swap-disabled null” from “ambiguous/corrupted request-start slot.” The existing test only covers a drain-cancelled 503 with `receiptBuilder: nil`, which is the SPEC-011 timeout path, not the AC-42 defence-in-depth path.

Suggested resolution direction: carry enough request-start provenance into receipt emission to identify an ambiguous/corrupted capture separately from warm-swap-disabled `nil`, refuse with `.modelSwapViolation` in that case, and add the AC-42 synthetic positive/negative tests.

### Finding CODE-R1-HIGH-2 — HIGH — AC-31 non-null error-receipt hash inheritance is not covered by tests

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:289-295`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:321-327`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:53-75`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:77-99`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:323-357`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:503-518`, `specs/SPEC-015-receipts.md:3469-3478`.

The HTTP error-receipt implementation threads `requestStartSnapshot.modelHash`, but the tests only exercise nil-hash fixtures and do not prove non-null warm-swap error receipts inherit the same hash a success receipt would carry.

AC-31 requires null-usage/error receipts to set `model_hash` per §M.2, including the warm-swap-on non-null hash case. The current code path appears directionally correct because both API-error and generic-error catch blocks pass the captured request-start hash into `errorReceiptHeaderResult`, but the test runtime is constructed without a `modelHash`, and the direct `errorReceiptHeader` test also passes `modelHash: nil`. A regression that replaced the error path’s hash with nil would still pass the current Step 1 tests.

Suggested resolution direction: add a warm-swap-on/non-null HTTP error-receipt test that configures a 64-lowercase-hex runtime hash, triggers `model_not_loaded`/generic inference failure after request acceptance, decodes the receipt, and asserts the error receipt’s `model_hash` equals the success-path request-start hash.

### Finding CODE-R1-HIGH-3 — HIGH — The v0.3 wire-size budget test allows receipts larger than the Step 1 contract

Source: `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift:159-180`, `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:115-123`, `specs/SPEC-015-receipts.md:1144-1160`.

The receipt-size test asserts `<= 1100` bytes even though the build prompt requires `<= 960` bytes and the locked spec projects a v0.3 envelope of approximately `<= 1025` bytes with 4096-byte hard headroom.

This is a deterministic acceptance-test gap: a receipt that exceeds the locked §3.4 projection could pass `testV03ReceiptFitsWireSizeBudget` today. The implementation also correctly enforces the 4096-byte hard cap in `RouterHandler`, but that cap is not a substitute for the Step 1 projection check because nginx headroom and the v0.3 expected envelope budget are separate constraints.

Suggested resolution direction: align the XCTest threshold with the Step 1 prompt/§3.4 budget, or explicitly document and justify any threshold above 960 with a locked-spec-compatible worst-case calculation.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 HIGH=3 MEDIUM=0 LOW=0

## Lens — SECURITY — Round 1

### Finding SECURITY-R1-HIGH-1 — HIGH — Ambiguous mid-swap receipt emission is not fail-closed

Source: `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:77-84`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:256-267`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:307-315`, `specs/SPEC-015-receipts.md:2771-2808`, `specs/SPEC-015-receipts.md:3618-3640`.

The receipt-emission layer has no fail-closed branch for the §M.2.2 “runtime cannot disambiguate which container served” condition, so an injected ambiguous/corrupted request-start hash can still flow into a signed receipt as `model_hash: null` or as whatever stale hash the caller provides.

For normal requests, the provider-status in-flight counter plus runtime drain semantics make old-container and new-container success receipts distinguishable by construction. The security issue is the explicit defence-in-depth case that v0.3 requires for future regressions: when the request-start capture is missing or corrupted during a swap-in-progress state, the provider must omit the receipt and audit `model_swap_violation` rather than sign a misleading hash/null claim. `ReceiptBuilder` faithfully signs null when asked, and the current HTTP/relay helpers do not carry an ambiguity marker, so the signer cannot distinguish an honest warm-swap-disabled null from an unsafe unknown hash.

Suggested resolution direction: represent request-start hash provenance as an explicit state (`captured(hash)`, `warmSwapDisabled`, `ambiguousSwapViolation`) instead of a bare `String?`, and make receipt emission refuse the ambiguous state before calling `ReceiptBuilder.build`.

### Finding SECURITY-R1-HIGH-2 — HIGH — Error-receipt hash binding lacks non-null security regression coverage

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:658-674`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:53-99`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:323-357`, `specs/SPEC-015-receipts.md:1701-1727`, `specs/SPEC-015-receipts.md:3469-3478`.

The implementation comments and call sites intend for error receipts to inherit the request-start `model_hash`, but the security test surface does not exercise the non-null hash case required by AC-31.

The buyer’s security claim for a null-usage provider error is that the provider signed which weights were warm when the error fired. The current tests prove tokens/output hash/signature behavior for error receipts, but only with `modelHash: nil`; they do not catch a regression where warm-swap-on error receipts silently downgrade to null or use a fresh emission-time hash. Because SPEC-015 treats error-receipt hash binding as an attestation property, this needs a deterministic non-null regression test before Step 2.

Suggested resolution direction: add a test that triggers an eligible error after a request-start snapshot with a 64-lowercase-hex hash, then verifies the signed tuple includes that exact hash and that audit records still omit hash material.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 HIGH=2 MEDIUM=0 LOW=0

## Lens — ARCHITECT — Round 1

### Finding ARCHITECT-R1-HIGH-1 — HIGH — Step 1 build-prompt acceptance coverage is incomplete

Source: `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:103-123`, `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift:81-123`, `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift:159-180`, `phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift:131-191`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:53-99`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:193-211`.

The implementation covers the core 9-field builder path, but the Step 1 “What lands” and “Tests” lists are not fully satisfied before audit closure.

The missing coverage is material to the v0.3 evolution contract: there is no golden fixture corpus under `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/` for null and non-null 9-field canonical bytes; the size test uses `<= 1100` instead of the prompt’s `<= 960`; AC-31 is not tested with a non-null warm-swap hash on error receipts; AC-42’s synthetic ambiguous mid-swap no-header path is not implemented/tested; the relay’s non-streaming receipt path is not decoded/asserted in `InferenceRelayTests`; and the v0.1/v0.2 isolated 7-field JCS regression sanity check is not present. The locked-spec line-3 diff, `RFC8785JCS.swift` diff, and `Package.swift` diff are clean, so this does not require spec/dependency redesign, but it does block Step 1’s audit gate.

Suggested resolution direction: add the missing Step 1 acceptance tests and fixtures first, then make only the implementation changes needed for AC-42 provenance/refusal to pass those tests.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 HIGH=1 MEDIUM=0 LOW=0

## Lens — CODE — Round 2

Round 1 closure check: CODE-R1-HIGH-2 is closed by the warm-swap-on non-null HTTP error receipt test; CODE-R1-HIGH-3 is closed by the `<= 1025` §3.4 assertion. CODE-R1-HIGH-1 is only partially closed: the `.ambiguous` source refuses before receipt construction, but the implementation still does not prove the signed hash is the same snapshot `ModelRuntime.complete` actually used, and the AC-42 test does not assert the required audit row.

### Finding CODE-R2-CRITICAL-1 — CRITICAL — Receipt hash capture can diverge from the generation snapshot

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:231-251`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:261-272`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-291`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:313-322`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:358-367`, `specs/SPEC-015-receipts.md:2769-2796`.

The HTTP and relay paths capture `requestStartSnapshot` outside `ModelRuntime.complete`, but `complete` immediately takes its own fresh actor-isolated snapshot and registers the in-flight request from that later snapshot, so an actor interleaving can sign hash A while generation actually ran on hash B.

SPEC-015 §M.2.2 requires every receipt to commit to "the hash of the model that started generation for this request." In the current shape, `HTTPServer` captures a snapshot at lines 238-242 and later calls `modelRuntime.complete` at line 251; `InferenceRelay` does the same at lines 286-291. `ModelRuntime.complete` then independently captures the snapshot that actually drives validation, in-flight registration, and generation at lines 363-367. Because each `await` to the actor is a separate turn, a warm-swap can complete between the caller snapshot and the `complete` snapshot. That produces exactly the locked-spec failure class: the signed tuple's `model_hash` is not necessarily the container that served the response.

Suggested resolution direction: make non-streaming use one runtime-owned request handle/snapshot for both generation and receipt binding, mirroring the streaming path's `acquireRequestHandle` / `preflight` / `stream` pattern, or have `complete` return the served `RuntimeSnapshot` alongside `CompletionResult` and bind the receipt from that returned snapshot. Add a regression test that forces a swap between caller-side snapshot capture and generation-start to prove the signed hash matches the served snapshot.

### Finding CODE-R2-HIGH-1 — HIGH — AC-42 refusal test does not prove the required audit emission

Source: `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:501-528`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:283-285`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:311-313`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:343-345`, `specs/SPEC-015-receipts.md:3618-3640`.

The new AC-42 negative test calls the helper and checks `nil`, but it does not exercise the response path that emits `receipt_omitted: model_swap_violation` into `ReceiptAudit`.

AC-42 requires two observable outcomes for the synthetic ambiguous state: no `X-MacProvider-Receipt` header and a matching audit sink row. The helper-level test proves `.ambiguous` returns no header, but the audit row is emitted by the surrounding HTTP switch statements, not by `receiptHeader` itself. A regression that forgot to call `ReceiptAudit.emitOmitted` for `.modelSwapViolation` in one of those HTTP paths would still pass the new test, leaving the Round 1 AC-42 audit-log gap open.

Suggested resolution direction: add an HTTP-level AC-42 test under `ReceiptAudit.withSink` that drives `.ambiguous` through the same response path used by non-streaming success/error handling, asserts the header is absent, and asserts the captured audit JSON has `event="receipt_omitted"` and `reason="model_swap_violation"`.

VERDICT: DESIGN ROUND NEEDED

COUNTS: CRITICAL=1 HIGH=1 MEDIUM=0 LOW=0

## Lens — SECURITY — Round 2

Round 1 closure check: SECURITY-R1-HIGH-2 is closed for HTTP by `testHTTPErrorReceiptInheritsWarmSwapHash`; SECURITY-R1-HIGH-1 is only partially closed because `.ambiguous` now refuses before signing, but the signer can still receive a stale caller-side hash that differs from the snapshot actually used for generation.

### Finding SECURITY-R2-CRITICAL-1 — CRITICAL — A swap interleaving can create a signed receipt for the wrong weights

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:238-251`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:261-272`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:286-322`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:363-367`, `specs/SPEC-015-receipts.md:2775-2796`.

The cryptographic tuple can commit to a model hash captured before generation while `ModelRuntime.complete` later generates from a different snapshot, making the signed receipt an incorrect attestation of the weights served.

This is not a verifier or canonicalization problem; the signature faithfully signs the wrong claim. The security property in §M.2.2 depends on the request-start snapshot being the same snapshot that generation uses and the same snapshot protected by SPEC-011 in-flight tracking. Here the caller-side `currentSnapshot()` and `ModelRuntime.complete`'s internal `currentSnapshot()` are separate actor operations. If a malicious or unlucky provider swap completes in the gap, the buyer receives a valid Ed25519 receipt whose `model_hash` does not identify the model that produced the output.

Suggested resolution direction: move receipt provenance into the runtime-owned in-flight handle or return the served snapshot from the generation call, then construct the receipt only from that served snapshot. Treat any mismatch between caller-intended model and served snapshot as a refusal/error before signing.

### Finding SECURITY-R2-HIGH-1 — HIGH — The defence-in-depth audit trail is not tested end-to-end

Source: `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:501-528`, `phase3-binary/Sources/macprovider-cli/ReceiptAudit.swift:74-99`, `specs/SPEC-015-receipts.md:2798-2808`, `specs/SPEC-015-receipts.md:3630-3637`.

The ambiguous-provenance test validates no receipt header but never verifies the required `receipt_omitted` audit record, so the security evidence for §M.2.2's fail-closed path is incomplete.

The audit sink intentionally does not log hash material, and the existing `ReceiptAudit` payload shape is appropriate. The missing piece is coverage: AC-42 requires the row to exist when the receipt is refused. Since `ReceiptAudit.emitOmitted` is called outside the helper, a helper-only test does not protect the operational security trail buyers/operators rely on to distinguish a deliberate no-receipt defence-in-depth refusal from a silent construction failure.

Suggested resolution direction: add an audit-sink assertion around the live ambiguous HTTP path and verify only the expected non-sensitive fields are present: `event`, `provider_id`, `request_id`, and `reason`.

VERDICT: DESIGN ROUND NEEDED

COUNTS: CRITICAL=1 HIGH=1 MEDIUM=0 LOW=0

## Lens — ARCHITECT — Round 2

Round 1 closure check: the core builder tuple, version constant, hash validation, null encoding, non-null HTTP success/error paths, and §3.4 `<= 1025` cap are present; `Package.swift`, `RFC8785JCS.swift`, and locked-spec line-3 diffs are clean. ARCHITECT-R1-HIGH-1 remains partially open because the runtime provenance boundary is still not the SPEC-011 in-flight snapshot boundary, and several Step 1 acceptance artifacts remain absent.

### Finding ARCHITECT-R2-CRITICAL-1 — CRITICAL — Step 1 models provenance as caller-side metadata instead of the runtime-owned request snapshot

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:231-251`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-291`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:322-338`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:358-367`, `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:107-112`.

The architectural boundary for `model_hash` provenance is wrong: Step 1 adds a receipt-side sum type, but it does not make the runtime's in-flight snapshot the single source of truth for non-streaming generation.

SPEC-011 already has the right abstraction in `RequestHandle`: `acquireRequestHandle` captures a `RuntimeSnapshot`, validates readiness/model, registers in-flight, and returns the snapshot that streaming later uses. The v0.3 Step 1 build prompt requires the atomic-read invariant at the runtime boundary. The new code instead lets HTTP and relay independently sample `currentSnapshot()` and then call `complete`, whose separate snapshot is the one that actually controls inference. That splits the provenance contract across layers and undermines the v0.3 evolution arc, because later verifier/coordinator steps will trust a receipt claim the provider runtime has not structurally tied to generation.

Suggested resolution direction: promote a single non-streaming request-handle API (or a `CompletionResult` plus served-snapshot return type) and route HTTP plus relay through it before Step 2. Keep `ReceiptModelHashSource` as the emission-layer refusal type, but derive it only from the runtime-owned served snapshot.

### Finding ARCHITECT-R2-HIGH-1 — HIGH — Step 1 build-prompt acceptance coverage is still incomplete

Source: `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:111-123`, `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_1_PROMPT.md:197-209`, `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift:81-123`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:501-556`, `phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift:131-191`.

The Round 2 tests cover several formerly missing behaviours, but the Step 1 acceptance list still lacks the golden JCS fixture corpus, the v0.1/v0.2 isolated 7-field canonicalization sanity check, relay receipt decoding/assertion, and an AC-42 audit-row assertion.

The build prompt explicitly requires null and non-null 9-field canonical bytes to match golden files under `Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/`; no such fixture files exist. `ReceiptBuilderTests` checks key order in-process, which is useful but does not satisfy the cross-step Swift/Go parity artifact that Step 5 is supposed to consume. `InferenceRelayTests` still validates encrypted response framing without asserting a v0.3 receipt payload, so the coordinator-WS receipt path has no decoded `model_hash` / `receipt_version` regression coverage. Finally, the AC-42 helper test does not assert the required audit row. These are deterministic acceptance gaps, not spec changes or dependency issues.

Suggested resolution direction: add the required fixture directory with null and non-null canonical bytes, consume it from the Swift builder tests, add an isolated 7-field JCS regression test proving `RFC8785JCS.swift` remained legacy-compatible, decode/assert a relay non-streaming receipt, and extend AC-42 coverage to include the audit sink.

VERDICT: DESIGN ROUND NEEDED

COUNTS: CRITICAL=1 HIGH=1 MEDIUM=0 LOW=0

## Lens — CODE — Round 3

Round 2 closure check: CODE-R2-CRITICAL-1 is closed. `ModelRuntime.completeWithServedSnapshot` now captures the runtime snapshot inside the actor turn that validates readiness/model, registers in-flight, and drives generation, then returns that same served snapshot to callers (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:394-409`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:419-472`). HTTP success receipts now derive `modelHashSource` from `servedSnapshot`, not the earlier caller pre-snapshot (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:244-261`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:271-282`). The relay success path also uses `completeWithServedSnapshot` and derives receipt provenance from `servedSnapshot` (`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-320`). CODE-R2-HIGH-1 is closed by the HTTP-level ambiguous-provenance test, which asserts no receipt header and a `receipt_omitted` / `model_swap_violation` audit row without hash leakage (`phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:501-533`).

Validation run: `cd phase3-binary && swift test --filter 'ReceiptBuilderTests|HTTPServerReceiptTests|InferenceRelayTests'` passed 35 selected tests with 0 failures.

### Finding CODE-R3-MEDIUM-1 — MEDIUM — HTTP success-path comment still describes the obsolete pre-snapshot binding

Source: `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:257-282`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:266-270`, `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_1_PROMPT.md:45-50`.

The Round 3 code correctly binds success receipts from `servedSnapshot`, but the adjacent comment says the receipt binds "the snapshot taken before inference began on line ~234," which points at the caller-side pre-snapshot.

The implementation at lines 257-261 is the important fixed behavior: `completeWithServedSnapshot` returns the generation-driving snapshot, and `resolveModelHashSource` uses that returned value. The comment at lines 266-270 now contradicts the code and the Round 2 design resolution by implying the pre-snapshot remains the success-path provenance source. The audit prompt classifies comment/code divergence that can mislead the next implementer as MEDIUM, and this is exactly the provenance boundary that caused the Round 2 critical.

Suggested resolution direction: rewrite the comment above `receiptHeaderResult` to say success receipts bind `model_hash` from `servedSnapshot`; keep the pre-snapshot comment only for warm-swap rejection validation and error/catch fallback.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=1 LOW=0

## Lens — SECURITY — Round 3

Round 2 closure check: SECURITY-R2-CRITICAL-1 is closed. The signed security claim now comes from the runtime-owned served snapshot returned by `completeWithServedSnapshot`, not a separate caller sample (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:394-409`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:419-472`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:257-282`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-320`). SECURITY-R2-HIGH-1 is closed by `testHTTPAmbiguousProvenanceEmitsReceiptOmittedAudit`, which drives `.ambiguous` through the HTTP success path and verifies no `X-MacProvider-Receipt` header, the required `receipt_omitted` / `model_swap_violation` row, `provider_id`, `request_id`, and no logged hash/signature/pubkey material (`phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:501-533`). `ReceiptBuilder` still signs exactly the 9-field tuple including `model_hash` as string or JSON null, and `.ambiguous` refuses before tuple construction (`phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:77-123`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:646-662`).

Validation run: `cd phase3-binary && swift test --filter 'ReceiptBuilderTests|HTTPServerReceiptTests|InferenceRelayTests'` passed 35 selected tests with 0 failures.

No new CRITICAL/HIGH/MEDIUM security findings found in Round 3.

VERDICT: READY TO PROCEED

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0

## Lens — ARCHITECT — Round 3

Round 2 closure check: ARCHITECT-R2-CRITICAL-1 is closed. The non-streaming runtime boundary now exposes a served-snapshot API, and HTTP plus relay success paths derive receipt provenance from that runtime-owned snapshot (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7-20`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:380-409`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:257-282`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-320`). The AC-42 audit-row part of ARCHITECT-R2-HIGH-1 is closed by the new HTTP end-to-end test (`phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:501-533`). `SPEC-015-receipts.md` line 3 remains locked at v0.3.3, and there is no diff in `RFC8785JCS.swift`, `phase3-binary/Package.swift`, or the locked SPEC-001/002/005/006/008/010/011/013 line-3 files.

Validation run: `cd phase3-binary && swift test --filter 'ReceiptBuilderTests|HTTPServerReceiptTests|InferenceRelayTests'` passed 35 selected tests with 0 failures.

### Finding ARCHITECT-R3-HIGH-1 — HIGH — Step 1 build-prompt acceptance artifacts are still incomplete

Source: `specs/BUILD_SPEC_015_v0_3_MODELHASH_IMPL_PROMPT.md:111-123`, `specs/AUDIT_SPEC_015_v0_3_IMPL_STEP_1_PROMPT.md:197-209`, `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift:81-123`, `phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift:131-191`.

Round 3 closes the runtime provenance blocker and the HTTP AC-42 audit-row gap, but it still does not land the mandatory golden fixture corpus, the isolated v0.1/v0.2 7-field JCS regression sanity check, or a decoded relay receipt assertion.

The Step 1 build prompt requires null and non-null 9-field canonical bytes to match golden files under `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/`; that fixture path is still absent, and `ReceiptBuilderTests` only performs in-process parsing/order checks. The build prompt also requires a no-regression sanity check for isolated 7-field v0.1/v0.2 canonicalization, and no such test appears in the Step 1 test surface. Finally, `InferenceRelayTests` still verifies encrypted chunk/end framing but never constructs a relay with a receipt builder/provider ID and decodes the returned v0.3 receipt, leaving the coordinator-WS-mediated receipt path without direct `receipt_version` / `model_hash` regression coverage. These are deterministic acceptance gaps against A.1, even though the core runtime architecture is now correct.

Suggested resolution direction: add the `SPEC015_v03_jcs` fixture directory with null and non-null canonical bytes and consume it from Swift tests; add an isolated legacy 7-field JCS canonicalization regression test; add an `InferenceRelayTests` non-streaming receipt test that injects a receipt builder/provider ID, overrides `completeWithServedSnapshot` with a non-null served hash, decodes the `receipt` end-frame value, and asserts `receipt_version == "3"` plus the served `model_hash`.

VERDICT: READY WITH FIX PASS

COUNTS: CRITICAL=0 HIGH=1 MEDIUM=0 LOW=0

## Lens — CODE — Round 4

Round 3 closure check: CODE-R3-MEDIUM-1 is closed. The HTTP success-path comment now explicitly says the receipt binds `model_hash` to the runtime-served snapshot returned by `completeWithServedSnapshot`, not to the pre-snapshot (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:266-274`). The pre-snapshot wording is limited to warm-swap validation and error/catch fallback where no served snapshot exists (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:233-257`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:305-347`).

Round 3 ARCHITECT-R3-HIGH-1 code-surface recheck: the 9-field builder still emits exactly the SPEC-015 §M.0 keys, validates present hashes as raw 64-char lowercase hex, maps nil to JCS null, and signs the canonical 9-field tuple (`phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:55-123`, `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:137-153`). The golden fixture tests now lock null and non-null v0.3 canonical JCS bytes by SHA-256 and byte length, and also lock the isolated v0.1/v0.2 7-field canonical byte sequence (`phase3-binary/Tests/macprovider-cliTests/JCSGoldenFixtureTests.swift:30-80`). The relay non-streaming test now injects a receipt builder/provider ID, returns a fixed served snapshot, decodes the end-frame receipt, and asserts `receipt_version == "3"`, the served `model_hash`, and the 9-key tuple shape (`phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift:195-258`).

Implementation recheck found no new CRITICAL/HIGH/MEDIUM code findings. HTTP success/error/parse-error paths thread `ReceiptModelHashSource` through the receipt helpers and refuse `.ambiguous` before construction (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:244-285`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:376-399`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:608-749`). Relay non-streaming binds from the served snapshot and refuses ambiguous provenance before building a receipt (`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-332`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:337-379`).

Validation run: `cd phase3-binary && swift test` passed 530 tests, 7 skipped, 0 failures.

VERDICT: READY TO PROCEED

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0

## Lens — SECURITY — Round 4

Round 3 security posture remains closed. The signature input is the canonical JCS tuple returned by `ReceiptBuilder.tupleObject`, now including `model_hash` as either a string or the JSON null literal and `receipt_version` as the string `"3"` (`phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:55-93`, `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:99-123`). `RFC8785JCS.swift` still has the existing `.null` and UTF-16 object-key sorting behavior and was not amended (`phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift:17-42`, `phase3-binary/Sources/macprovider-cli/RFC8785JCS.swift:51-53`).

The provenance security property is still bound to the runtime-owned served snapshot: real `ModelRuntime.completeWithServedSnapshot` captures the snapshot inside the actor path that validates readiness/model, registers in-flight, and drives generation, then returns that same snapshot to HTTP and relay receipt construction (`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:388-472`, `phase3-binary/Sources/macprovider-cli/HTTPServer.swift:257-285`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:281-320`). The `.ambiguous` defence-in-depth path refuses before tuple construction and emits `receipt_omitted: model_swap_violation`; the HTTP AC-42 test asserts no header, the audit row, and no hash/signature/pubkey leakage (`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:650-666`, `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:350-360`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:501-533`).

No new CRITICAL/HIGH/MEDIUM security findings found in Round 4.

Validation run: `cd phase3-binary && swift test` passed 530 tests, 7 skipped, 0 failures.

VERDICT: READY TO PROCEED

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=0

## Lens — ARCHITECT — Round 4

Round 3 closure check: ARCHITECT-R3-HIGH-1 is closed. The required `SPEC015_v03_jcs` fixture corpus now exists with null and non-null v0.3 fixture JSON files and locked SHA-256/length metadata (`phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/null_hash.json:1-15`, `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/non_null_hash.json:1-15`). The README documents the regeneration workflow for future Swift/Go parity use (`phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/README.md:1-26`). `JCSGoldenFixtureTests` consumes both fixture files and adds the legacy 7-field canonicalization sanity check required by SPEC-015 §M.1.5 (`phase3-binary/Tests/macprovider-cliTests/JCSGoldenFixtureTests.swift:30-80`). The relay receipt decode gap is closed by `testRelayNonStreamingEndFrameCarriesV03Receipt` (`phase3-binary/Tests/macprovider-cliTests/InferenceRelayTests.swift:195-258`).

Step 1 build-prompt coverage is now complete for the Swift provider scope: builder 9-field tuple, constant `receipt_version: "3"`, served-snapshot provenance, no `RFC8785JCS.swift` amendment, null/non-null fixture parity, AC-31 error-receipt inheritance, AC-42 refusal/audit, relay receipt decode, legacy 7-field JCS sanity, and §3.4 size checks are covered by source and tests (`phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:55-123`, `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:388-472`, `phase3-binary/Tests/macprovider-cliTests/ReceiptBuilderTests.swift:23-185`, `phase3-binary/Tests/macprovider-cliTests/HTTPServerReceiptTests.swift:480-590`, `phase3-binary/Tests/macprovider-cliTests/JCSGoldenFixtureTests.swift:30-80`). `Package.swift`, `RFC8785JCS.swift`, and the locked SPEC-001/002/005/006/008/010/011/013 files have no implementation diff.

### Finding ARCHITECT-R4-LOW-1 — LOW — SwiftPM still warns that the new fixture files are unhandled

Source: `phase3-binary/Package.swift:64-71`, `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/null_hash.json:1-15`, `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/non_null_hash.json:1-15`, `phase3-binary/Tests/macprovider-cliTests/Fixtures/SPEC015_v03_jcs/README.md:1-26`.

The new fixture files are intentionally loaded by source path in `JCSGoldenFixtureTests`, but SwiftPM reports them as unhandled files in the test target.

This is not a Step 1 acceptance blocker: `swift test` passes, the fixtures are present in the repository, and the test reads them via `#filePath` rather than `Bundle.module`. It is still minor packaging noise that will appear on every test run until the test target either declares the fixture directory as resources and loads it through `Bundle.module`, or explicitly excludes the directory while keeping the source-path loading convention.

Suggested resolution direction: in a polish pass, either add test resources and switch the fixture loader to `Bundle.module`, or add an explicit test-target exclude for the fixture directory if source-path loading is the intended house style.

Validation run: `cd phase3-binary && swift test` passed 530 tests, 7 skipped, 0 failures. The run emitted only the fixture-resource warning above.

VERDICT: READY TO PROCEED

COUNTS: CRITICAL=0 HIGH=0 MEDIUM=0 LOW=1
