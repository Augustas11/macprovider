# AUDIT_SPEC_015_v0_4_IMPL_STEP_2_SECURITY_PROMPT

You are auditing Step 2 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4`.

Audit as the Codex security lane. Do not edit files.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 2.
- `specs/SPEC-015-receipts.md` §N.2 and trust caveats.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/jcs.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/tier2/catalog.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 2 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Required checks:

1. Snapshot rows do not persist raw provider public keys, private keys, bearer
   tokens, raw prompts, raw outputs, or production secrets.
2. `provider_receipt_key_id` is derived as `ed25519-sha256:<64 lowercase hex>`
   over the raw 32-byte Ed25519 public key and invalid key lengths do not
   produce settlement-capable snapshots.
3. Route snapshot persistence cannot be silently rewritten for the same
   `(account_scope, request_id, attempt_n, provider_id)` identity.
4. A provider cannot get contacted on a covered route after snapshot digest,
   catalog material, prompt hash, or DB persistence fails.
5. The implementation does not treat v0.1/v0.2/v0.3 receipts as
   settlement-capable and does not wire SPEC-022 buyer debit/provider credit.
6. Product/security claims remain honest: this binds provider-reported model
   hash to route-time catalog expectation but does not prove a malicious
   provider cannot falsify local model measurement.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
