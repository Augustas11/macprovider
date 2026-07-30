# Security Review Report

**Scope:** SPEC-016 Step 2 security r2 review for `phase4-coordinator` payout Step 2 code. Requested fix-pass was `3653516`; current checkout is `d6e7717`, and `3653516..HEAD` contains only r2 prompt files, no production code changes.  
**Risk Level:** MEDIUM  
**Output note:** I did not write `specs/SPEC-016-IMPL-STEP_2-security-r2-audit.md` because the prompt explicitly says this run is read-only and must not modify files.

## Summary

- Critical Issues: 0
- High Issues: 0
- Medium Issues: 1
- Low Issues: 1
- r1 HIGH closures: verified closed
- BLOCK status: no block; no new CRITICAL or HIGH regression found

## r1 Closures Verified

- `[sec:2.1]` 24h gas cap reservation: PASS. `ServeAbandon` performs the cap check inside `BEGIN IMMEDIATE`, inserts `gas_reserved_native_wei`, and `sumCancelGasLast24h` sums `COALESCE(gas_used_native_wei, gas_reserved_native_wei)` for non-abandoned cancels. Evidence: [abandon.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/abandon.go:153), [abandon.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/abandon.go:177), [abandon.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/abandon.go:284), [abandon.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/abandon.go:483).
- `[sec:2.2]` both-RPC chain verification: PASS. Both receipts must target USDC, both tx inputs must match expected calldata, both `from` values must equal the hot wallet and agree, and both log arrays must contain exactly one matching `Transfer`. Evidence: [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:911), [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:933), [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:940), [runner.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/runner.go:961).
- `[sec:2.3]` production signer wiring: PASS with one medium hardening finding below. Production requires encrypted wallet path plus KEK; dev plaintext key path requires explicit `dev_mode=true`; config rejects production enabled with missing encrypted wallet path. Evidence: [main.go](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:816), [config.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/config/config.go:994).

## Medium Issues

### 1. KEK is not zeroized on signer-load error paths

**Severity:** MEDIUM  
**Category:** OWASP A02 Cryptographic Failures / Secrets Management  
**Location:** [main.go](/Users/augstar/macprovider-poc/phase4-coordinator/cmd/coordinator/main.go:822)  
**Exploitability:** Local memory disclosure after startup failure  
**Blast Radius:** KEK material may remain in process heap longer than necessary if wallet loading fails after KEK resolution.  
**Issue:** `loadPayoutSigner` zeroizes `kek` only after `LoadLocalFileSigner` succeeds. If wallet read/decrypt/parse fails, the function returns before wiping the resolved KEK. Same pattern exists for dev key bytes after `NewLocalFileSignerFromKey` errors.

**Remediation:**
```go
// BAD
kek, err := resolvePayoutKEK()
if err != nil {
    return nil, err
}
signer, err := payout.LoadLocalFileSigner(wallet, kek)
if err != nil {
    return nil, err
}
for i := range kek {
    kek[i] = 0
}

// GOOD
kek, err := resolvePayoutKEK()
if err != nil {
    return nil, err
}
defer func() {
    for i := range kek {
        kek[i] = 0
    }
}()
signer, err := payout.LoadLocalFileSigner(wallet, kek)
if err != nil {
    return nil, err
}
```

## Low Issues

### 1. Operator key comparison is not constant-time

**Severity:** LOW  
**Category:** OWASP A07 Identification and Authentication Failures  
**Location:** [mux.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/mux.go:164)  
**Exploitability:** Remote but noisy timing side channel  
**Blast Radius:** If practically exploitable, an attacker could recover the operator bearer and reach `/admin/payout/*`; gas and runner controls are still capped/gated.  
**Issue:** `raw != operatorKey` uses normal string comparison. For bearer secrets on admin endpoints, use constant-time comparison after length normalization.

**Remediation:**
```go
// BAD
if raw == "" || raw != operatorKey {
    writeError(w, http.StatusUnauthorized, "unauthorized")
    return
}

// GOOD
if raw == "" ||
    subtle.ConstantTimeCompare([]byte(raw), []byte(operatorKey)) != 1 {
    writeError(w, http.StatusUnauthorized, "unauthorized")
    return
}
```

## Regression Probe Matrix

- EIP-712 provider proof: PASS via `go test ./internal/payout -run TestVerifyEIP712 -count=1`.
- `govulncheck ./...`: PASS, 0 reachable vulnerabilities.
- Step 2 package regression: PASS via `go test ./...` in `phase4-coordinator`.
- Two-RPC cold-start ±1: PASS via targeted `TestTwoRPCs_ColdStartNonceSync`.
- M4 chain-nonce race hook: PASS static. Production construction does not set `SleepAfterPostCommitLeaseReread`; zero value applies.
- 8-conn PRAGMA `synchronous=FULL`: static + existing unit evidence only. `WithPragmas` sets `synchronous(FULL)` in the DSN and `TestAssertPragmas_RejectsRelaxedSynchronous` passes; I did not create a temporary multi-connection probe file in this read-only run.
- Migration tamper check: PASS static. If `payout_schema_applied` row is deleted, `Migrate` re-executes `ALTER TABLE ... ADD COLUMN` and fails fast at SQLite duplicate-column layer. `payout_schema_applied` is correctly not in `AssertSameDB`’s money-path pin list.

## Tests Run

- `go test ./internal/payout ./internal/config ./cmd/coordinator`
- `go test ./...` from `phase4-coordinator`
- `go test ./internal/payout -run 'TestVerifyEIP712|TestTwoRPCs_ColdStartNonceSync|TestAssertPragmas|TestRunner_AbortsOnLeaseLost|TestRunner_HappyPath|TestAbandon' -count=1`
- `go test ./internal/payout -run 'TestMigrate_Idempotent' -count=1`
- `govulncheck ./...`
- Secrets scan over current production paths plus bounded git-history grep: no production hardcoded credentials found; hits were symbolic config names, docs, and test fixtures.

## Security Checklist

- [x] No hardcoded production secrets found
- [x] Dependency audit completed
- [x] Injection prevention reviewed for Step 2 SQL and RPC paths
- [x] Authentication/authorization reviewed for admin and provider surfaces
- [x] Both-RPC lying-primary closure verified
- [x] 24h cancel gas cap reservation closure verified
- [ ] KEK/dev-key zeroization covers error paths
- [ ] Operator bearer compare is constant-time
tokens used
241 177

```

## Concise summary

Provider completed successfully. Review the raw output for details.

## Action items

- Review the response and extract decisions you want to apply.
- Capture follow-up implementation tasks if needed.

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-2-security-review-lane-round-2026-06-25T16-38-40-847Z.md._
