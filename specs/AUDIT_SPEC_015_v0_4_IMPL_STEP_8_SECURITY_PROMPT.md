# AUDIT_SPEC_015_v0_4_IMPL_STEP_8_SECURITY_PROMPT

You are the Codex security audit lane for SPEC-015 v0.4 implementation Step 8.

Scope: read-only audit of Step 8 integration acceptance. Do not modify files.

Security invariants:

1. Acceptance evidence must not accidentally bless SPEC-022 buyer debit,
   provider-positive settlement, payout readiness, or gateway money movement.
2. AC-43 through AC-71 evidence must fail closed for malformed tuples, replay
   context, model/hash mismatch, route-policy mismatch, missing/cross-checked
   usage gaps, overlap/double-credit risk, late receipts, future/legacy receipt
   versions, wrong signature algorithm, and wrong receipt key.
3. Redaction evidence must ensure raw receipt envelopes, raw signatures, raw
   receipt public keys, raw prompts, raw outputs, bearer tokens, receipt private
   keys, account scopes, and provider-private state are not exposed in
   audit/verdict/operator rows.
4. Buyer/product disclosure evidence must preserve the v0.4 limitation:
   provider-reported model hash is checked against the route-time catalog
   snapshot, but malicious-provider self-measurement falsification is not
   detected.
5. Step 8 must not introduce new production attack surface, network calls, or
   hidden dependency on external services.

Report only exploitable or trust-impacting findings, plus material missing
tests. Use severity Critical, High, Medium, Low. Include file/line evidence,
attack scenario, and exact remediation. End with counts:
critical/high/medium/low.
