# AUDIT_SPEC_015_V0_4_SECURITY_PROMPT

You are auditing `specs/SPEC-015-receipts.md` from the SECURITY lane.

Audit target: v0.4 deltas only, centered on the new `0.4.0-draft` header
and §N "Settlement-capable receipts". Treat v0.1/v0.2/v0.3 locked history as
fixed unless a v0.4 clause contradicts it.

Controlling context:

- `specs/SPEC-015-receipts.md`
- `specs/BUILD_SPEC_015_v0_4_SETTLEMENT_RECEIPTS_PROMPT.md`
- SPEC-022 v0.1.4 requirements quoted or referenced by §N

Lock bar: 0 critical, 0 high, 0 medium.

Focus:

- Provider cheating: wrong model, wrong hash, wrong request, wrong attempt,
  wrong account, wrong provider, wrong receipt key, wrong terminal state,
  wrong route snapshot, wrong usage.
- Replay, late receipt, idempotency, first-terminal selection, and deadline
  quarantine.
- Streaming partial-output manipulation, failover overlap, and double charge.
- Provider-only usage abuse.
- Audit/storage leakage of raw prompts, outputs, receipt signatures, public
  keys, raw receipt envelopes, bearer tokens, receipt private keys, or
  provider-private state.
- Unknown/future receipt version handling and legacy receipt non-payability.
- Whether any wording would allow SPEC-022 positive money movement before the
  v0.4 profile is locked and implemented.

Output format:

`VERDICT: READY` if 0/0/0. Otherwise `VERDICT: NEEDS REVISION` with counts
and ID-prefixed findings (`SEC-C-1`, `SEC-H-1`, `SEC-M-1`, etc.). Cite SPEC
text and concrete repo/spec evidence.
