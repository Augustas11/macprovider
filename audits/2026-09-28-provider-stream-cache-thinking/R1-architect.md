# R1 architect audit — provider streaming cleanup rewrite, receipt binding, MLX cache clear, preserve_thinking

Scope: full `git diff origin/main...HEAD -- phase3-binary/` across commits
`01ac80d01` and `d5febeb97`, with surrounding provider, relay, receipt,
coordinator, and normative-spec code read for the affected contracts.

Method: source review plus existing tests only. No malformed payloads were
constructed.

## Findings

### HIGH — streaming cleanup rewrite leaves the normative canonical-byte contract contradictory

Files/lines: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4677-4683`,
`:6418-6420`; `phase3-binary/Tests/macprovider-cliTests/StreamingEmitterCleanupRewriteTests.swift:44-55`;
`specs/SPEC-018-agentic-tool-calling.md:401,949`;
`specs/SPEC-019-structured-output.md:417-425,1004-1011`.

Failure condition: a valid tokenizer decode first exposes text with a cleanup
rewrite and later exposes the rewritten cumulative prefix. For example, the
buyer can receive the immutable deltas `"It "`, `"'s"`, `" fine"`, whose
concatenation is `"It 's fine"`, while the final parsed/non-streaming content is
`"It's fine"`. The new tests intentionally prove this distinction. Streaming
`CompletionResult.content` and continuous-batch completion content now use the
delivered concatenation, so settlement and structured-stream validation are
internally consistent, but SPEC-018 still requires streaming concatenation to
equal the non-streaming canonical output byte-for-byte and SPEC-019 AC-V2-7
requires the same assistant content bytes. SPEC-018 §3.10 also retains a broad
non-Harmony byte-identity promise. This is a normal valid-text condition, not a
malformed-request case.

Fix: amend SPEC-018 §3.10/§8.4 and SPEC-019 AC-V2-7 plus its v0.2 validation
paragraph to make the immutable buyer-delivered concatenation the explicit
streaming/settlement content domain, and to state the deterministic cleanup
rewrite exception to stream/non-stream byte parity. Keep
`SerialStreamingTextEmitter.emittedContent` / the continuous-batch equivalent
as the single source for streaming output, structured validation, and the
streaming receipt. SPEC-015 §N.5 already defines streaming receipt content as
the delivered `delta.content` concatenation and does not require a text change.
SPEC-001 only defines the SSE/WS wire shape and termination, so it does not
need a normative change for this rewrite.

### MEDIUM — receipt binding is structurally correct but lacks a full delivery-to-coordinator proof

Files/lines: `phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:898-910,943-956,1093-1124,1196-1210`;
`phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4670-4684,6418-6424`;
`phase3-binary/Sources/macprovider-cli/InferenceRelay.swift:1643-1649`;
`phase4-coordinator/internal/buyer/settlement_output.go:122-190`.

Failure condition: a future change at any boundary between emitter output,
relay batching, receipt construction, or coordinator settlement tracking can
make the signed `content` field differ from the bytes actually delivered while
the current unit suites continue to pass. The provider signs
`completion.content`; the relay's cancellation path separately derives
`deliveredContent` from successfully enqueued/sent frames; and the coordinator
reconstructs content from received SSE deltas. Existing tests cover these
pieces independently, including cleanup-emitter concatenation, relay
cancellation with a fixed fake stream, and batcher delivery accounting, but no
test drives an actual cleanup-rewrite stream through the relay, extracts the
provider's signed settlement output, and compares its `output_hash` with the
coordinator tracker over the exact emitted SSE frames. Tool rows, structured
terminal errors, and continuous-batch completion are likewise not covered by
that combined assertion.

Fix: add a valid-fixture integration proof that runs serial and
continuous-batch streaming through the relay, records the actual buyer-visible
SSE content/tool fragments, parses the provider settlement receipt, feeds those
same fragments to the coordinator settlement tracker, and asserts identical
settlement content, finish/tool-call fields, prefix byte counts, and
`output_hash` for successful and buyer-cancelled streams. Keep error/structured
terminal cases receipt-less where the existing terminal contract requires it.

### LOW — the incremental cleanup pipeline has no complete upstream-equivalence oracle

Files/lines: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4141-4174,4221-4225`;
`phase3-binary/Tests/macprovider-cliTests/ContinuousBatchToolStructuredRowTests.swift:626-649,651-739`.

Failure condition: a future `mlx-swift-lm` or tokenizer pin changes the
`clean_up_tokenization_spaces` rule set, replacement order, or a rule that
crosses token boundaries. The provider's incremental decoder hardcodes ten
replacement stages and currently tests representative punctuation, apostrophe,
UTF-8, and contraction cases, but does not compare every rule and composition
against the full upstream decode/cleanup result. The re-anchoring logic can
therefore remain locally self-consistent while emitting a different delivered
text from the dependency's intended cleanup semantics, which would also change
the signed settlement content.

Fix: add a table-driven valid-token fixture for every cleanup rule and
cross-boundary composition, using the full tokenizer cleanup result as the
oracle for the incremental decoder; make the fixture part of the dependency
pin-bump checklist so cleanup-rule changes require an explicit review of the
streaming and settlement byte contract.

## Verified architectural areas

- `preserve_thinking` plumbing mirrors `enable_thinking`: capability detection
  is template-byte based, target capability maps are keyed by artifact hash,
  warm-switch resolution updates the live flag, snapshots carry it, and the
  serial, speculative, continuous-batch, preflight, and stream prompt paths
  pass both flags. `templateAdditionalContext` emits `preserve_thinking` only
  when the template also supports `enable_thinking`. The added prompt-context
  and same-model/different-artifact warm-switch tests pass.
- `Memory.clearCache()` is placed immediately after `TokenIterator` or
  `SpeculativeTokenIterator` initialization on the three serve paths covered
  by the change; continuous batching is intentionally untouched. The current
  MLX dependency implementation protects cache clearing with its evaluation
  lock, so this audit found no current concurrency-safety defect. The helper,
  cleanup, prompt-context, continuous-batch, and coordinator settlement tests
  executed for this audit passed; `git diff --check` is clean.
- No current CRITICAL finding, no demonstrated signed-receipt/content mismatch,
  and no usage-accounting defect was found in the reviewed paths. The
  cancellation path fails closed when delivery is incomplete or tool output
  makes the delivered content unknown.

VERDICT: 0 CRITICAL, 1 HIGH, 1 MEDIUM, 1 LOW
