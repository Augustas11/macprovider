# Audit R2 — architect

Scope: full `origin/main...HEAD` diff under `phase3-binary/`, with surrounding
receipt, coordinator settlement, and normative specification code read as
needed. Existing targeted Swift and Go tests were run; no malformed payloads
were constructed.

## Findings

### HIGH — native tool-call arguments are outside the cleanup re-anchoring and receipt source of truth

Files: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:8246-8258`,
`:8366-8413`; `phase3-binary/Sources/macprovider-cli/OutputCanonicalizer.swift:55-74`;
`phase3-binary/Sources/macprovider-cli/HTTPServer.swift:1335-1351,1384-1390`.

Failure condition: a valid declared Qwen/Llama tool call is streamed through a
tokenizer with cleanup enabled, and a string-valued argument contains one of
the deterministic cleanup rewrite pairs across cumulative decode snapshots
after an argument fragment has already been delivered. `SerialStreamingTextEmitter`
re-anchors assistant/content deltas, but `NativeToolCallStreamEmitter` still
uses prefix-only `delta(from:to:)` for arguments. Once cleanup changes the
already-emitted argument prefix, later fragments are dropped. The final
fallback also refuses the full argument because it is no longer prefixed by
the recorded fragment. `CompletionResult.toolCalls` nevertheless retains the
fully parsed final arguments, and `HTTPServer` signs those final tool calls
while the buyer received only the shorter concatenation. This can produce a
stream final-close failure and, independently, a signed receipt whose
`tool_calls` material differs from buyer-delivered tool-call bytes.

Fix: give native tool extraction and streaming one cleanup-disabled/raw
decoded argument source, and derive both the streamed argument fragments and
`CompletionResult.toolCalls`/receipt tool-call material from that same
canonical argument accumulator. Keep cleanup re-anchoring scoped to visible
assistant content. Add valid cleanup-sensitive argument coverage through the
serial and continuous-batch emitters and the receipt/relay path.

### MEDIUM — SPEC-019 still imports and cites the superseded SPEC-018 version

File: `specs/SPEC-019-structured-output.md:4,51,164,1032,1178-1200,1298,1633-1636,1748`.

Failure condition: SPEC-019 is versioned v0.2.6 and now adopts the v0.2.10
cleanup-rewrite content domain, but its dependency declaration, precondition,
active error-frame references, response-cap references, and implementation
anchors continue to name SPEC-018 v0.2.4. A consumer following the declared
dependency can therefore apply the older exact-parity wording while reading
the newer SPEC-019 cleanup exception, leaving the normative dependency graph
internally inconsistent.

Fix: update the active SPEC-019 dependency/precondition and normative
cross-references to SPEC-018 v0.2.10 and refresh the locked revision/
implementation anchors. Keep historical audit/design notes explicitly
historical rather than presenting v0.2.4 as the current precondition.

### LOW — preserve-thinking capability state is not normalized against the enable-thinking capability

Files: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:7029-7031,7083-7096,7119-7135,7694-7703`.

Failure condition: a target template containing `preserve_thinking` but not
`enable_thinking` is recorded as
`templateSupportsPreserveThinking == true` in the target map and runtime
snapshot. The current prompt helper safely emits no context because it guards
on `supportsThinkingToggle`, so the present request path does not leak the
flag. However, the public snapshot and warm-switch capability state do not
represent the stated capability contract (“both markers”), leaving a future
caller or diagnostic able to treat preserve-thinking as independently
supported.

Fix: compute and store preserve-thinking capability as
`hasPreserveThinkingMarker && hasThinkingToggleMarker` for configured and
warm-switch targets, and test that a preserve-only target resolves false in
the snapshot as well as in prompt context.

## R1 closure and specification consistency

- The R1 HIGH canonical-byte contradiction is closed for ordinary assistant
  content: SPEC-018 §3.10/§8.4 and SPEC-019 AC-V2-7 now name the immutable
  buyer-delivered content concatenation as the stream/validation/settlement
  domain, while SPEC-015 §N.5 already defines streaming settlement content as
  the delivered delta concatenation. SPEC-001 has no conflicting streaming
  parity rule requiring an amendment.
- The R1 receipt-binding gap is closed for ordinary serial and continuous-batch
  content by `emittedContent`, the Swift golden fixture, and the Go settlement
  tracker test. The HIGH tool-call finding above remains because tool-call
  fragments still bypass that same delivered-byte binding.
- The cleanup-rule oracle covers all ten replacement patterns and two-/three-way
  split boundaries for the serial content emitter. The new Swift/Go fixture
  confirms the shared settlement hash for the representative cleanup rewrite.
  It does not exercise the native tool-argument cleanup case or the complete
  HTTP/relay/receipt integration path.
- Preserve-thinking is threaded through preflight, serial, speculative, and
  continuous-batch prompt construction, runtime snapshots, and warm-switch
  target resolution. The LOW finding is the remaining capability-state
  normalization issue, not a current prompt-emission leak.
- SPEC-018 §8.4 correctly keeps tool-argument concatenation byte-exact even
  while allowing the narrower cleanup exception for assistant content. That
  distinction is consistent with SPEC-015 §N.5, but exposes the HIGH runtime
  gap above.

## Verification

Passed:

- `git diff --check`
- `cd phase3-binary && swift test --filter StreamingEmitterCleanupRewriteTests`
- `cd phase3-binary && swift test --filter StreamingSettlementBindingTests`
- `cd phase3-binary && swift test --filter ModelRuntimePromptContextTests`
- `cd phase3-binary && swift test --filter NativeToolCallStreamEmitterTests`
- `cd phase4-coordinator && go test ./internal/buyer -run 'TestSettlementStreamCleanupRewriteGoldenBindsDeliveredBytes' -count=1`

The repository remained clean after removing the package-resolution change
generated by the Swift test invocation.

VERDICT: 0 CRITICAL, 1 HIGH, 1 MEDIUM, 1 LOW
