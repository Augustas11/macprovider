# Security Review Report

**Scope:** SPEC-016 Step 2 security lane on `impl/spec-016`; audited `phase4-coordinator/internal/payout/*`, `phase4-coordinator/cmd/coordinator/main.go`, payout migrations/config. HEAD is `b49ac4d`, but audited production code is unchanged from prompt target `db5c9ba`.

**Risk Level:** HIGH

## Summary

- Critical Issues: 0
- High Issues: 3
- Medium Issues: 0
- Dependency audit: `govulncheck ./...` found 0 called vulnerabilities
- Tests: `go test -count=1 ./...` passed in `phase4-coordinator`
- Secrets scan: no production hardcoded secret literals found; git-history hits were test keys/constants
- External ethers/web3 cross-check: not run; neither `ethers`, `web3`, nor `eth_account` is installed locally

## Critical Issues

None.

## High Issues

### [sec:2.1] Abandon 24h Gas Cap Ignores Pending Cancel Gas

**Severity:** HIGH  
**Category:** OWASP A04 Insecure Design / A05 Security Misconfiguration  
**Location:** `phase4-coordinator/internal/payout/abandon.go:175`, `phase4-coordinator/internal/payout/abandon.go:282`, `phase4-coordinator/internal/payout/abandon.go:463`, `phase4-coordinator/internal/payout/migrations/0002_payout_attempts.sql:10`  
**Threat Model:** C, compromised operator key  
**Exploitability:** Remote authenticated via stolen operator key  
**Blast Radius:** Hot-wallet native gas can be burned beyond the configured 24h aggregate cap.

**Issue:** The 24h aggregate cap sums `gas_used_native_wei`, but new cancel rows are inserted with `gas_used_native_wei = NULL` and only become counted after confirmation. A stolen operator key can submit multiple cancel broadcasts while prior cancels are pending; each request sees the same undercounted aggregate.

**Remediation:**
```go
// BAD: pending cancel rows contribute NULL/zero until confirmed.
used, err := sumCancelGasLast24h(ctx, conn, s.Security.HotWalletAddress, last24h)
if used+gasEstimate > caps.CancelMaxGasNativeWeiPer24h {
    writeError(w, http.StatusUnprocessableEntity, "cancel_gas_exceeds_24h_aggregate")
    return
}

// GOOD: reserve estimated gas in the same transaction and sum used-or-reserved gas.
used, err := sumCancelGasReservationsLast24h(ctx, conn, s.Security.HotWalletAddress, last24h)
if used+gasEstimate > caps.CancelMaxGasNativeWeiPer24h {
    writeError(w, http.StatusUnprocessableEntity, "cancel_gas_exceeds_24h_aggregate")
    return
}
// INSERT ... gas_reserved_native_wei = gasEstimate
```

```sql
SELECT COALESCE(SUM(COALESCE(gas_used_native_wei, gas_reserved_native_wei)), 0)
  FROM payout_attempts
 WHERE from_address = ?
   AND is_cancel_self_transfer = 1
   AND abandoned_at_utc IS NULL
   AND updated_at_utc >= ?;
```

### [sec:2.2] Chain-Side Transfer Verification Trusts One RPC’s Logs/Sender

**Severity:** HIGH  
**Category:** OWASP A04 Insecure Design  
**Location:** `phase4-coordinator/internal/payout/runner.go:557`, `phase4-coordinator/internal/payout/runner.go:569`, `phase4-coordinator/internal/payout/runner.go:718`, `phase4-coordinator/internal/payout/runner.go:736`, `phase4-coordinator/internal/payout/runner.go:751`, `phase4-coordinator/internal/payout/rpc.go:434`  
**Threat Model:** E, lying RPC  
**Exploitability:** One malicious primary RPC when secondary agrees on minimal receipt fields  
**Blast Radius:** Ledger can mark a payout paid without independently proving the USDC `Transfer` on both RPCs.

**Issue:** `ReceiptsAgree` compares only tx hash/block/status/to. `verifyChainSideTransfer` then checks `tx.from` and `Transfer` logs from the primary receipt/tx path only. A malicious primary can fabricate sender/log data while an honest secondary returns the same minimal receipt identity but different logs.

**Remediation:**
```go
// BAD: verifies transfer proof against primary-side receipt/logs only.
if err := r.verifyChainSideTransfer(ctx, attempt, recPri); err != nil {
    return rowOutcomeFailed, err
}

// GOOD: independently verify both RPC views, then compare proofs.
proofA, err := r.verifyChainSideTransferOnRPC(ctx, attempt, recPri, r.opts.RPCs.Primary)
if err != nil { return rowOutcomeFailed, err }

proofB, err := r.verifyChainSideTransferOnRPC(ctx, attempt, recSec, r.opts.RPCs.Secondary)
if err != nil { return rowOutcomeFailed, err }

if proofA != proofB {
    r.emitRPCDisagreement(attempt.PayoutID, attempt.AttemptSeq, recPri, recSec)
    return rowOutcomeFailed, errors.New("two-RPC transfer proof mismatch")
}
```

At minimum, verify `tx.From`, `tx.To`, `tx.Input`, `tx.Nonce`, `tx.ChainID`, and exactly-one matching `Transfer` log on both RPC responses.

### [sec:2.3] Production Money-Out Path Uses Dev Plaintext Env Signer Loader

**Severity:** HIGH  
**Category:** OWASP A02 Cryptographic Failures / Secrets Management  
**Location:** `phase4-coordinator/cmd/coordinator/main.go:633`, `phase4-coordinator/cmd/coordinator/main.go:736`, `phase4-coordinator/internal/payout/signer.go:113`  
**Threat Model:** C, operator-key/host compromise  
**Exploitability:** Local host/env access or production misconfiguration  
**Blast Radius:** Hot-wallet private key exposure; possible full wallet drain.

**Issue:** Step 2 startup loads the hot-wallet private key from `MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY` via `NewLocalFileSignerFromKey`. The encrypted `LoadLocalFileSigner` + KEK path exists but is not wired. This makes a dev-only plaintext env path the only functional Step 2 signer path.

**Remediation:**
```go
// BAD: production path accepts plaintext private key from env.
rawHex := os.Getenv("MACPROVIDER_PAYOUT_WALLET_KEY_HEX_DEV_ONLY")
raw, err := hexDecode(rawHex)
signer, err := payout.NewLocalFileSignerFromKey(raw)

// GOOD: production path requires encrypted wallet + systemd credential KEK.
kekPath := filepath.Join(os.Getenv("CREDENTIALS_DIRECTORY"), "payout-wallet-kek")
kek, err := os.ReadFile(kekPath)
if err != nil { return nil, fmt.Errorf("read payout KEK: %w", err) }

signer, err := payout.LoadLocalFileSigner(
    payout.EncryptedWalletFile{Path: cfg.Payout.Security.EncryptedWalletPath, OnDiskHex: true},
    bytes.TrimSpace(kek),
)
if err != nil { return nil, fmt.Errorf("load encrypted payout signer: %w", err) }
```

Gate any dev env fallback behind an explicit non-production mode and fail closed when `payout.enabled=true` in production.

## Security Checklist

- [x] No production hardcoded secrets found
- [x] SQL injection patterns reviewed; Step 2 SQL uses parameters
- [x] EIP-1559 pre-broadcast verification reviewed
- [x] Abandon endpoint auth/caps/rate-limit reviewed
- [x] Two-RPC receipt/reorg discipline reviewed
- [x] Signer custody/error paths reviewed
- [x] Dependencies audited with `govulncheck`
- [ ] Independent ethers/web3 crypto vector cross-check completed


---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-2-security-review-lane-lane--2026-06-25T16-14-40-097Z.md._
