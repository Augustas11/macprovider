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

LANE: SECURITY / MONEY-PATH REVIEW (settlement integrity)
Focus:
1. Can any path still produce a signed SPEC-015 receipt (v0.3 or v0.4
   settlement) for a completion served by a runtime whose
   `isSettlementReceiptEligible` is false? Consider relay complete/stream,
   buyer-cancel-after-completion, HTTP success, the HTTP streaming trailer,
   null-usage error receipts, and parse-error receipts.
2. Can any path mark a non-owner completion (continuous-batching replay
   waiter, duplicate, not-eligible) as `.eligibleOwner`, so two receipts
   settle for one generation?
3. Does any omission reason or audit row leak prompt/output hashes,
   signatures or key material (SPEC-015 §11 forbids this)?
4. Does the change weaken any existing fail-closed guard, e.g. §M.2.2
   ambiguous provenance, settlement-metadata binding, or relay-blind
   exclusion?
5. Is the stated non-goal (CLI guard, not a trust boundary) documented
   honestly in code comments and the SPEC? Flag anything that overclaims.
