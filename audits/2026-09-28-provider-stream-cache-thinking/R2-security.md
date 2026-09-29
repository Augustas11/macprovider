# Audit R2 — security lane

Scope: full `git diff origin/main...HEAD -- phase3-binary/`, with surrounding
relay, HTTP, receipt-builder, coordinator settlement, and specification code
reviewed as needed. This is a source-and-existing-test proof review; no
malformed payloads were constructed.

## Findings

### HIGH — continuous-batching tool arguments can be signed from a different byte sequence than the buyer received

Files: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4054-4074,
4219-4226, 4292-4325, 4613-4623`; `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1151-1159`;
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1335-1351, 1384-1401`;
`phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift:367-420`.

Failure condition: a cleanup-enabled continuous-batching tool row reaches a
valid tool-call argument containing one of the deterministic cleanup patterns
after the incremental decoder has already returned its provisional text. The
CB state feeds that provisional text to `SerialStreamingTextEmitter`, so the
buyer can receive an argument fragment that is not a prefix of the final
cumulative decode. Finalization parses `toolCalls` from the cumulative decode,
and `openAIFallbackDeltas` intentionally emits nothing when the streamed
argument is not a prefix of the final argument. The provider nevertheless
continues to build the receipt from `completion.toolCalls`. Therefore the
receipt's `settlement_output_v1.tool_calls[].function.arguments` can differ
from the concatenation of the delivered tool-call deltas. The coordinator's
stream tracker will reject this as `output_hash_mismatch`, preventing positive
settlement, but the provider has still issued a receipt that does not bind the
buyer-visible bytes and valid tool rows can systematically fail settlement.

Fix: make the tool-call argument stream and receipt use one authoritative byte
sequence. Either keep cleanup-sensitive argument text on the cumulative decode
path until it is prefix-safe, or validate the accumulated delivered argument
bytes against the finalized `toolCalls` before success. On any non-prefix or
other mismatch, terminate/fail closed and omit the settlement receipt; do not
sign the cumulative final arguments while leaving the earlier deltas on the
wire. Add an existing-fixture test with a valid cleanup-sensitive tool
argument, exercising both direct HTTP and relay/continuous-batching receipt
construction and asserting that delivered argument concatenation equals the
signed settlement output.

The added cleanup golden tests do not cover this condition: their batched
golden case has no final tool call, and the tool-call test uses arguments that
do not cross a cleanup rewrite. The current tests all passed, including the
new Swift settlement suite and the shared Go golden settlement test.

### INFO — non-normative SPEC-018 design notes still state whole-response byte parity

Files: `specs/design/spec-018/DESIGN_SPEC_018_v0_2_04_STREAMING.md:8-10,34-39,67-69`;
`specs/design/spec-018/SPEC-018-v0_2-design-synthesis.md:263-274,297-300`.

These design-input documents still describe streaming concatenation as
byte-identical to the non-streaming response without the now-normative
SPEC-015 §N.5 / SPEC-018 §3.10 cleanup exception. The locked SPEC-018 §3.10
and §8.4 text, SPEC-019 AC-V2-7, and SPEC-015 §N.5 are internally consistent:
tool-call arguments retain byte parity, while buyer-delivered assistant content
is authoritative and cleanup-enabled streams may retain only deterministic
cleanup-deleted spaces. This is not a current settlement bypass, but stale
design wording can reintroduce the wrong receipt-content assumption in a later
implementation. Narrow those notes to tool-call argument parity and the
cleanup exception when the design documents are next revised.

## Closed R1 checks and security conclusions

- Normal serial and continuous-batching assistant content now flows into
  `CompletionResult.content` from the emitted deltas, and `ReceiptBuilder`
  hashes that value after the shared settlement normalization. The new Swift/Go
  golden fixture confirms the same delivered-content hash on both sides.
- Stop holdback and structured-output validation use the buyer-visible
  accumulator; structured failures do not reach successful receipt construction.
- Tool-call assistant content suppression remains fail-closed. The issue above
  concerns tool-call argument bytes after a tool call has already been opened,
  not cleanup text bypassing the delimiter suppression.
- Relay cancellation signs only a known delivered prefix; unknown delivery,
  tool-call cancellation, and unattested loopback usage omit settlement rather
  than signing an unverifiable prefix.
- `Memory.clearCache()` is guarded by MLX's cache lock and clears recycled
  buffers, not active arrays. The source provides no evidence that concurrent
  rows can observe another row's active inference data; no security finding was
  raised for this change.

Validation run:

- `cd phase3-binary && swift test --filter StreamingSettlementBindingTests` — 5 passed.
- `cd phase3-binary && swift test --filter 'StreamingEmitterCleanupRewriteTests|ContinuousBatchToolStructuredRowTests|NativeToolCallStreamEmitterTests|ModelRuntimeStructuredOutputTests|StreamingValidationFailureTests'` — 61 passed.
- `cd phase3-binary && swift test --filter 'ReceiptBuilderTests|StreamingUTF8BoundaryTests|InferenceRelayStructuredOutputTests|StreamingIdleTimeoutValidatesBufferTests'` — 21 passed.
- `cd phase4-coordinator && go test ./internal/buyer -run TestSettlementStreamCleanupRewriteGoldenBindsDeliveredBytes -count=1` — passed.
- `git diff --check origin/main...HEAD -- phase3-binary/` and `-- specs/` — clean.

VERDICT: 0 CRITICAL, 1 HIGH, 0 MEDIUM, 0 LOW
