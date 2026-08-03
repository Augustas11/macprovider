**Read-only note:** I did not write `specs/SPEC-016-IMPL-STEP_3-security-r1-audit.md` because the supplied reviewer contract is read-only.

## Summary

- Critical Issues: 1
- High Issues: 1
- Medium Issues: 1
- Low Issues: 0

Validation run:

- `go test -race -count=1 ./internal/payout/...` passed.
- `govulncheck ./...` reported 0 called vulnerabilities.
- Secrets scan found no hardcoded production secret, but did find runtime secret logging in `lease.go`.
- `git diff --check origin/main...HEAD -- phase4-coordinator/internal/payout phase4-coordinator/cmd/coordinator/main.go phase4-coordinator/internal/config` reports `funding.go:454: new blank line at EOF`.

## Critical Issues

### 1. Manual funding bootstrap window can be reopened after DROP+UPDATE+CREATE

**Severity:** CRITICAL  
**Category:** A04 Insecure Design / A01 Broken Access Control  
**Location:** [funding.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/funding.go:185), [funding.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/funding.go:210), [0003_payout_runner_state.sql](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/migrations/0003_payout_runner_state.sql:18)  
**Exploitability:** Authenticated compromised operator-key holder with raw DB write, matching the prompt threat model.  
**Blast Radius:** Can re-enable `source='manual'` after bootstrap, record fake hot-wallet funding, and bypass the intended both-RPC confirmation requirement.

**Issue:** `serveManual` verifies the three trigger names exist and then checks `payout_bootstrap_complete = 0` inside one `BEGIN IMMEDIATE` transaction. This prevents a concurrent DROP between the count and insert, but it does not detect a completed prior sequence: drop `trg_prs_bootstrap_one_way`, reset `payout_bootstrap_complete` to `0`, recreate the trigger, then call `source='manual'`. At request time, count is again `3`, so the fake manual funding path can pass.

**Remediation:**
```go
// BAD: trigger presence + mutable flag only.
err = conn.QueryRowContext(ctx, `
SELECT count(*) FROM sqlite_master
 WHERE type='trigger'
   AND name IN ('trg_prs_bootstrap_one_way',
                'trg_pa_bootstrap_flip',
                'trg_pa_bootstrap_flip_insert')`).Scan(&triggerCount)

err = conn.QueryRowContext(ctx,
    `SELECT payout_bootstrap_complete FROM payout_runner_state WHERE id = 1`,
).Scan(&bootstrapComplete)

// GOOD: keep the trigger check, but also bind manual funding closure to
// durable payout history inside the same transaction.
var confirmedExists int
err = conn.QueryRowContext(ctx, `
SELECT EXISTS(
    SELECT 1
      FROM payout_attempts
     WHERE confirmed_at_utc IS NOT NULL
     LIMIT 1
)`).Scan(&confirmedExists)
if err != nil {
    writeError(w, http.StatusInternalServerError, "internal_error")
    return
}

if bootstrapComplete != 0 || confirmedExists != 0 {
    if bootstrapComplete == 0 && confirmedExists != 0 {
        s.log.Error().
            Str("event", "payout_invariant_violation").
            Str("where", "bootstrap_flag_reopened").
            Str("severity", "PAGE").
            Send()
    }
    writeError(w, http.StatusUnprocessableEntity, "bootstrap_complete")
    return
}
```

## High Issues

### 2. ERC-20 `uint256` funding amount parser silently truncates high bits

**Severity:** HIGH  
**Category:** A03 Injection/Data Validation / A04 Insecure Design  
**Location:** [funding.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/funding.go:350), [funding.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/funding.go:373)  
**Exploitability:** Requires fabricated or malformed receipt data accepted by both RPC views, or future token/chain assumptions where oversized values appear.  
**Blast Radius:** A `Transfer` value larger than `uint64` can be accepted as a smaller requested amount if its low 64 bits match.

**Issue:** `uint256FromData` takes only the last 8 bytes of the ABI `uint256`. A 32-byte value like `2^64 + 1` is decoded as `1`, so `verifyFundingReceipt` can accept a mismatched transfer amount.

**Remediation:**
```go
// BAD
logValue := uint256FromData(lg.Data)
if logValue != uint64(req.AmountBaseUnits) {
    return fmt.Errorf("transfer log value %d != request amount %d", logValue, req.AmountBaseUnits)
}

// GOOD
if len(lg.Data) != 32 {
    return fmt.Errorf("transfer log value must be 32 bytes, got %d", len(lg.Data))
}
got := new(big.Int).SetBytes(lg.Data)
want := big.NewInt(req.AmountBaseUnits)
if got.Cmp(want) != 0 {
    return fmt.Errorf("transfer log value %s != request amount %d", got.String(), req.AmountBaseUnits)
}
```

## Medium Issues

### 3. Lease-loss logging exposes full runtime lease tokens

**Severity:** MEDIUM  
**Category:** A02 Cryptographic Failures / Secrets Management / A09 Logging Failures  
**Location:** [lease.go](/Users/augstar/macprovider-poc/phase4-coordinator/internal/payout/lease.go:206)  
**Exploitability:** Requires log access; impact increases if logs are centralized or visible outside the coordinator host.  
**Blast Radius:** Exposes `holder_token` values used for runner self-fencing and lease ownership checks.

**Issue:** `Heartbeat` logs `local_holder_token` and `observed_holder_token` in full on lease loss. Other paths correctly log only `holder_token_prefix`.

**Remediation:**
```go
// BAD
Str("local_holder_token", state.HolderToken).
Str("observed_holder_token", observedToken).

// GOOD
Str("local_holder_token_prefix", tokenPrefix(state.HolderToken)).
Str("observed_holder_token_prefix", tokenPrefix(observedToken)).

func tokenPrefix(s string) string {
    if len(s) <= 8 {
        return s
    }
    return s[:8]
}
```

## OWASP Coverage

- A01 Broken Access Control: Step 3 routes are in `step3PathTable` and wrapped with `operatorKeyMiddleware`; bootstrap reopen remains a critical access-control/design gap.
- A02 Cryptographic Failures: no new Step 3 crypto; operator actor is fixed non-secret label `operator_key:coordinator`; lease token logging is a medium secret-handling issue.
- A03 Injection: SQL inspected is parameterized; no string-built SQL found in Step 3 paths. Amount parsing validation has the high `uint256` truncation issue.
- A04 Insecure Design: critical bootstrap-window reopen issue.
- A05 Security Misconfiguration: production config validates `pause_resume_min_interval >= 1s`; service rejects negative interval.
- A06 Vulnerable Components: `govulncheck ./...` found 0 called vulnerabilities.
- A07 Authentication Failures: Step 3 uses same constant-time bearer middleware; empty bearer rejected.
- A08 Integrity Failures: CAS update clauses include `AND emitted_to_log = 0`; audit/outbox at-most-once emit is intact.
- A09 Logging Failures: audit reaper exists and passed race tests; lease token leakage remains.
- A10 SSRF: no user-controlled outbound URL in reviewed Step 3 endpoints.

## Security Checklist

- [x] No hardcoded production secrets found
- [x] Dependency audit completed
- [x] Operator-key auth checked on all 4 Step 3 routes
- [x] SQL parameterization checked
- [x] CAS emit discipline checked
- [ ] Manual bootstrap reopening fully prevented
- [ ] ERC-20 `uint256` amount parsing rejects overflow/truncation
- [ ] Runtime lease tokens are not logged in full

**Verdict:** BLOCK until the CRITICAL manual-bootstrap reopening issue is fixed. The `uint256` truncation should be fixed in the same security pass because it is directly in the §4.9 money-path receipt verifier.


---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-security-review-lane-round-2026-06-25T17-25-48-517Z.md._
