METHOD CONSTRAINT (read first): this is a first-party software-correctness and
proof review of our own code. Do NOT author or construct malformed payloads or
exploit strings. Evaluate by reading source and running EXISTING tests
(`cd phase3-binary && swift test --filter <Name>`). Describe any gap abstractly
(field + condition) in prose. Do NOT inspect any `d-inference` source.

Repository worktree: /Users/augstar/macprovider-1695 (branch
fix/1695-explicit-receipt-eligibility). Review the FULL fix diff as it will
land: `git diff origin/main...HEAD` (single commit). Read surrounding code as
needed.

Issue #1695 (parent #1690 Step 1): provider-CLI receipt eligibility was
implicit. `CompletionResult.settlementDisposition` and
`HTTPServer.receiptHeaderResult` defaulted to `.eligibleOwner`, and
`InferenceRelay.buildReceiptHeader` signed whenever the disposition was
`.eligibleOwner`, whatever the runtime. So `OllamaLoopbackRuntime` (SPEC-046
`ollama_loopback`, non-earning) signed receipts bound to its GGUF digest; only
the coordinator's buyer-serving hold stood in the way. An adversarial verifier
also found `ModelRuntime.validateStructuredStreamingCompletion` rebuilt the
completion without the disposition. That turned a continuous-batching replay
waiter (`.nonSettlingReplay`) back into `.eligibleOwner`.

The fix:
- `ModelRuntimeServing` requires `nonisolated var isSettlementReceiptEligible:
  Bool` with no protocol-extension default. Native `ModelRuntime` is true;
  `OllamaLoopbackRuntime` and `RelayBlindFixtureRuntime` are false and return
  `.notEligible` completions.
- Relay and HTTP builders (success, streaming trailer, null-usage error
  receipt) omit with the new `runtime_not_settlement_eligible` before signing.
- `settlementDisposition` has no default. Native sites pass `.eligibleOwner`
  explicitly, and the structured-streaming rebuild forwards it.
- SPEC-015 v0.4.8 amendment (specs/SPEC-015-receipts.md, CONFORMANCE.json
  version, README index).

Stated non-goal: this is a CLI accident guard, NOT a security boundary. A
patched CLI can self-declare eligibility; the coordinator gate is the control.
Native catalog receipts MUST NOT change behavior or be gated on SPEC-047
admission rows.

Output format: list findings, each with severity CRITICAL / HIGH / MEDIUM /
LOW / INFO, file:line, a concrete failure scenario, and a suggested fix. Only
report MEDIUM or higher when you can name a concrete path in this code where
behavior is wrong. End with exactly one line:
`VERDICT: <C> CRITICAL, <H> HIGH, <M> MEDIUM, <L> LOW`.

LANE: CODE REVIEW (correctness)
Focus:
1. Find every `CompletionResult(` construction in phase3-binary/Sources. Is
   each disposition correct for its path? Pay particular attention to
   continuous-batching owner/replay waiters, the speculative paths, structured
   validation rebuilds, the idle-timeout synthetic result, and
   `withModelHashObservedIfMissing`. Is any disposition still dropped or reset
   anywhere?
2. Are all receipt-signing call sites gated: relay complete/stream/cancel
   (InferenceRelay), and HTTP success/stream-trailer/error/parse-error plus the
   legacy `receiptHeader` helper (HTTPServer)? Check ordering against existing
   omission reasons (no_keypair, pre_v1_6_binary, model_swap_violation,
   pre_token_cancel, streaming_request) and audit-event emission (exactly one
   receipt_omitted per request, no duplicates, no missing rows).
3. Native behavior regression: is anything a native MLX request would sign
   today now omitted, or the reverse?
4. Test adequacy: do the new tests (ReceiptEligibilityTests,
   InferenceRelayTests / HTTPServerReceiptTests additions) cover complete and
   stream on both relay and HTTP for each conformer, the error path, and the
   laundering regression? Does anything pass vacuously?
5. Swift concurrency: are the nonisolated protocol requirement and the
   witnesses sound under strict concurrency?
