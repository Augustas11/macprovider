# AUDIT_SPEC_015_v0_4_IMPL_STEP_7_SECURITY_PROMPT

You are the Codex security audit lane for SPEC-015 v0.4 implementation Step 7.

Scope: read-only audit of the current worktree diff for product disclosures
and redacted receipt diagnostics. Do not modify files.

Security invariants:

1. Buyer/product disclosures must not imply hardware attestation,
   malicious-provider resistance, private inference, or detection of a provider
   falsifying its own loaded-model hash measurement.
2. Provider-facing diagnostics must be scoped to the authenticated provider
   subject and must not leak other providers' receipt verdicts.
3. Operator diagnostics remain operator-key-only through existing admin auth.
4. Diagnostic responses must not expose raw receipt envelopes, raw receipt
   public keys, raw signatures, raw prompts, raw outputs, bearer tokens,
   receipt private keys, account scopes, or provider-private state.
5. Exposed values should be reason codes, stable digests, fingerprints,
   timestamps, and request/attempt identifiers needed for support triage.
6. Added queries must not create a practical denial-of-service vector through
   unbounded diagnostics response size or table scans on hot provider paths.

Report only exploitable or trust-impacting findings, plus material missing
tests. Use severity Critical, High, Medium, Low. Include file/line evidence,
attack scenario, and exact remediation. End with counts:
critical/high/medium/low.
