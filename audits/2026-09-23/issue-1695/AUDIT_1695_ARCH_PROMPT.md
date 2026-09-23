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

LANE: ARCHITECTURE REVIEW
Focus:
1. Is a nonisolated protocol requirement with no default the right seam for
   explicit eligibility, given the repo's documented rule that actor-protocol
   extension defaults shadow sync witnesses? Will a future loopback conformer
   be forced to decide?
2. Is it coherent to have two gates, runtime eligibility plus per-completion
   disposition? Do the error-receipt paths (no completion) pass the right
   disposition? Is the precedence between the new reason and
   `non_settling_replay` well defined?
3. SPEC-015 v0.4.8 amendment: is it consistent with §6.4, §11, §N (v0.4
   settlement) and the ReceiptOmissionReason enum in ReceiptAudit.swift? Is
   the version bump propagated (CONFORMANCE.json, specs/README.md index)? Is
   anything normative missing, or contradicted by another SPEC-015 section
   or SPEC-046/047?
4. Does the `RelayBlindFixtureRuntime` visibility change (private to internal)
   or the new shared test fixture file cause coupling problems?
5. Cross-boundary: does the new `receipt_omitted` reason string need
   coordinator/gateway/verifier decoders or schemas updated? Grep
   phase4-coordinator, phase5-gateway and phase7-verify for enums of
   receipt_omitted reasons.
