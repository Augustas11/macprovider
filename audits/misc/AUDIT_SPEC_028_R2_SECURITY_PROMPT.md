# AUDIT_SPEC_028_R2_SECURITY_PROMPT

You are auditing `specs/SPEC-028-mlx-speculative-decoding.md` from the SECURITY lane.

Audit target: SPEC-028 v0.2-draft only. Treat the current branch as a
research/spec branch: do not propose executable code, and do not audit unrelated
repository changes.

Controlling context:

- `specs/SPEC-028-mlx-speculative-decoding.md`
- `docs/research/spec-decode-integration-2026-07.md`
- `specs/SPEC-001-phase3-binary.md`
- `specs/SPEC-010-model-catalog.md`
- `specs/SPEC-011-operator-pushed-warm-swap.md`
- `specs/SPEC-013-cli-autotune.md`
- `specs/SPEC-015-receipts.md`
- `phase4-coordinator/internal/billing/settlement_verifier.go`
- `phase3-binary/Sources/macprovider-cli/ReceiptBuilder.swift`
- `phase3-binary/Sources/MacProviderCore/ChatCompletionRequest.swift`

Lock bar: 0 critical, 0 high, 0 medium.

Focus:

- Does SPEC-028 preserve SPEC-015 v0.4 settlement receipt usage strictness and
  avoid new money/accounting ambiguity?
- Does provider telemetry avoid leaking buyer prompts, output content,
  account identity, request IDs, or receipt-sensitive state?
- Does the draft model configuration create a supply-chain or remote-code risk
  beyond the current target model loading posture, and if so does the SPEC name
  the required guard?
- Are tokenizer mismatch, prompt-cache rewind failure, Qwen divergence, and
  stochastic-output risks handled fail-closed enough for buyer correctness?
- Does warm-swap behavior avoid stale draft/target pairing that could create
  unverifiable target model claims?
- Does heartbeat/status telemetry create a coordinator trust or routing hazard
  before a coordinator-side SPEC consumes it?
- Are disabled-mode and fallback semantics precise enough that failures cannot
  silently alter buyer-visible outputs or receipts?

Output format:

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity:

- `SEC-C-1`, `SEC-H-1`, `SEC-M-1`, `SEC-L-1`, etc.
- Each finding must cite the SPEC section and concrete repo/spec evidence.
- Do not include Critical/High/Medium findings unless they should block LOCK.
- Low findings may be left for later; the stop bar is 0 C/H/M.
