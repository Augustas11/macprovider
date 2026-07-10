# AUDIT_SPEC_015_v0_4_IMPL_STEP_2_ADVERSARIAL_PROMPT

You are auditing Step 2 of the SPEC-015 v0.4 implementation in
`/Users/augstar/macprovider-impl-spec-015-v0-4` using the Claude subscription
CLI, not an API.

Scope:

- `implementation-notes-spec-015-v0-4.md` Step 2.
- `specs/SPEC-015-receipts.md` §N.2.
- `specs/SPEC-022-verified-model-settlement.md`.
- `phase4-coordinator/internal/billing/jcs.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/store.go`
- `phase4-coordinator/internal/tier2/catalog.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/buyer/server.go`
- Step 2 tests in `phase4-coordinator/internal/billing/` and
  `phase4-coordinator/internal/buyer/`.

Adversarially verify whether a buyer, provider, catalog reload, reconnect,
retry, or streaming/failover path could produce a route snapshot that later
lets SPEC-022 settle money against the wrong model, wrong provider key, wrong
prompt, wrong attempt, or mutable route decision.

Required checks:

1. Try to find a dispatch path that contacts a receipt/catalog-covered provider
   without first persisting a snapshot.
2. Try to find a retry/failover path where `attempt_n` skips, repeats, or no
   longer matches the later request-log/ledger attempt identity.
3. Try to find a mutation path where catalog rotation, provider reconnect, key
   rotation, or policy reload changes evidence after the route decision.
4. Try to find prompt canonicalization drift versus provider-side
   `PromptCanonicalizer.swift`, especially tool calls, optional fields,
   numeric values, and Unicode normalization.
5. Try to find any loophole where a v0.3/legacy receipt or provider-only claim
   becomes settlement-capable.

Return:

- Verdict: READY or NEEDS REVISION.
- Counts: critical / high / medium.
- Findings with file and line references.
