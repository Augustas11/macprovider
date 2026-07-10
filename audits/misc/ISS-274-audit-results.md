# ISS-274 — Codex audit results

Single-round convergence. Three-lane codex audit (CODE, SECURITY, ARCHITECT) on commit `0e4dce2`, fix-pass committed afterwards.

## Round 1 — 2026-06-30

| Lane      | C/H/M/L/INFO | Verdict           |
|-----------|--------------|-------------------|
| CODE      | 0/0/0/1/0    | ACCEPT — 0 C/H/M  |
| SECURITY  | 0/0/0/1/1    | ACCEPT — 0 C/H/M  |
| ARCHITECT | 0/0/0/2/2    | ACCEPT — 0 C/H/M  |

All three lanes converged on R1. Per [[feedback-skip-accepted-audit-lanes]], no R2 needed.

### LOWs absorbed (2)

- **CODE LOW-1** — `IssueToken` and `MintAdmissionTokenAndPairOT` trimmed `provider_id` BEFORE validation, while WS paths validate as-received. Fix: validate raw input first. Added whitespace-rejection regression tests to `internal/auth/iss274_provider_id_validator_test.go`.
- **ARCH LOW-1** — `pool.Provider.SortKey` documented the format but not the no-slash precondition. Fix: SortKey docstring now points to `config.ValidateProviderID` and names both ProviderID and AssignedID delimiter constraints.

### LOWs deferred (3)

- **SEC LOW-1** — `MintPairOTRefresh` trusts a DB-loaded `provider_id` without re-validating; could pollute `pair_ots` / `pair_ot_mint_log` / `provider_ownership`. Auditor confirms NOT reachable via SortKey collision today (WS parsers reject the bad ID upstream and token/hello mismatch closes the connection). Out of scope for #274 — files a separate validator-drift gap.
- **ARCH LOW-2** — SPEC documents (SPEC-001 / SPEC-002 / SPEC-003 / SPEC-010) do not yet name the expanded validator contract. Auditor recommends spec follow-up; defer to follow-up.
- **ARCH INFO-4** — Legacy slash-containing self-serve IDs would self-DoS on next connect. Auditor notes "likely low blast radius because installer-generated UUIDs and pinned config IDs already satisfy the regex." Operator pre-deploy SQL audit covered by separate ops runbook process.

### INFOs

- **SEC INFO-1** — Test gaps for zero-width / RTL characters. Implementation is safe (regex restricts to ASCII), no change needed.
- **ARCH INFO-3** — Confirms `internal/config` is the least-coupled home for the shared validator.

## Validation

```
go test ./... -count=1 -- all 20 coordinator packages green
go vet ./... -- clean
gofmt -l on touched files -- clean
```

R1 fix-pass commit: TBD (will be added to PR).
