**Scope:** SPEC-016 Step 3 security r2 audit for `impl/spec-016`, implementation commit `6044056`. Current HEAD is `5c8920f`, which only adds r2 audit prompt files over `6044056`. Reviewed `phase4-coordinator/internal/payout/*`, payout migrations, and `cmd/coordinator/main.go`.

**Risk Level:** LOW  
**Verdict:** CLEAN for r2 discipline: r1 security closures verified; no new CRITICAL/HIGH found.  
**Read-only note:** I did not write `specs/SPEC-016-IMPL-STEP_3-security-r2-audit.md` because the supplied reviewer contract says read-only.

## Summary

- Critical Issues: 0
- High Issues: 0
- Medium Issues: 0
- Low Issues: 1

Validation:
- `govulncheck ./...` from `phase4-coordinator/`: PASS, 0 called vulnerabilities.
- `go test -race -count=1 ./internal/payout/...`: PASS.
- Targeted high-confidence secrets scan in working tree and relevant git history: PASS, no hardcoded key/token formats found.
- `git diff --check 6044056..HEAD`: PASS.

## Closure Verification

- `[sec:1]` CLOSED. `serveManual` runs trigger count, bootstrap flag read, and confirmed-attempt `EXISTS` inside the same `BEGIN IMMEDIATE`; rejects when `payout_bootstrap_complete != 0 || confirmedExists != 0`; emits `payout_invariant_violation where=bootstrap_flag_reopened` on flag reset plus confirmed row. Evidence: `funding.go:178`, `funding.go:193`, `funding.go:237`, `funding.go:247`.
- `[sec:2]` CLOSED. Receipt verification requires `len(lg.Data) == 32`, rejects non-zero bytes `0..23`, then `big.Int.SetBytes` compares against `req.AmountBaseUnits`. Evidence: `funding.go:397`.
- `[sec:3]` CLOSED. Lease-lost logging uses `tokenPrefix` for local and observed holder tokens; helper truncates to 8 chars. Evidence: `lease.go:213`, `lease.go:321`.

## Low Issues

### 1. Confirmed-attempt sentinel query is semantically correct but not index-backed

**Severity:** LOW  
**Category:** A05 Security Misconfiguration / performance hardening  
**Location:** `phase4-coordinator/internal/payout/funding.go:237`, `phase4-coordinator/internal/payout/migrations/0002_payout_attempts.sql:41`  
**Exploitability:** Authenticated operator endpoint only; no direct security bypass.  
**Blast Radius:** Manual-funding rejection can scan `payout_attempts` on post-bootstrap calls.

**Issue:** The query intentionally checks any confirmed attempt, including abandoned rows:

```sql
SELECT EXISTS(
    SELECT 1 FROM payout_attempts
     WHERE confirmed_at_utc IS NOT NULL
     LIMIT 1
)
```

The existing index is partial on `confirmed_at_utc IS NOT NULL AND abandoned_at_utc IS NULL`, so SQLite cannot use it for the broader “any confirmed ever” invariant. `EXPLAIN QUERY PLAN` confirmed a table scan for the current query.

**Remediation:**
```sql
-- GOOD: preserves the security invariant, including abandoned rows.
CREATE INDEX IF NOT EXISTS idx_pa_any_confirmed
    ON payout_attempts(confirmed_at_utc)
 WHERE confirmed_at_utc IS NOT NULL;
```

## Adversarial Probe Results

- Bootstrap DROP+UPDATE+CREATE with confirmed row: rejected via `confirmedExists`.
- Re-attack with deleted confirmed rows: residual risk. This fix does not close raw runtime deletion of payout history; per prompt, treat as defended elsewhere by SPEC §4.8a startup sentinel/asymmetry and SPEC §7.4 reconciliation alarm.
- Idempotency empty header and empty `tx_hash`: fails; empty `tx_hash` returns `400 missing_field`. Empty header with non-empty `tx_hash` returns `422 idempotency_key_mismatch`.
- Uppercase tx hash idempotency: accepted case-insensitively via `strings.EqualFold`; stored lowercase.
- Lying RPC overflow: `2^192 + amount` rejected by high-byte check. `2^63-1` accepts if data matches. `2^64-1` is not representable as request `int64`; verifier rejects by compare for any representable request. Constant `24 == 32 - 8`, exactly the high bytes above uint64.
- ReorgPoller lifecycle: `Stop` cancels and waits on `done`; no leak found. Start-Stop-Start on the same instance is intentionally unsupported/undefined because `started` and `stopOnce` are not reset; production constructs and starts once.
- Stale-outbox producer: CAS `NULL -> now` plus outbox insert happen in one `BEGIN IMMEDIATE`; unique index prevents duplicate `(payout_id, attempt_seq, stale_started_at_utc)`.
- Snapshot immutability: `observed_*` columns are only set on orphan insert; resolve path mutates only resolution fields.
- Shutdown partial timeout: lease release requires both `runnerClean && pollerClean`; runner clean plus poller stuck does not release.

## OWASP Coverage

- A01 Broken Access Control: Step 3 admin routes use operator-key middleware and path-table parity.
- A02 Cryptographic Failures: no new raw secret exposure; lease token logging redacted.
- A03 Injection: reviewed SQL paths are parameterized; receipt amount parsing hardened.
- A04 Insecure Design: r1 bootstrap-reopen class closed for retained confirmed history.
- A05 Security Misconfiguration: one LOW indexing/perf hardening note.
- A06 Vulnerable Components: `govulncheck` found 0 called vulnerabilities.
- A07 Auth Failures: operator bearer comparison is constant-time with length check.
- A08 Integrity Failures: CAS claim patterns preserved for audit/outbox emits.
- A09 Logging Failures: required PAGE/WARN surfaces present for reviewed closures.
- A10 SSRF: no user-controlled outbound URL in reviewed Step 3 endpoints.

## Security Checklist

- [x] No hardcoded secrets
- [x] All reviewed inputs validated
- [x] Injection prevention verified
- [x] Authentication/authorization verified
- [x] Dependencies audited
- [x] r1 CRITICAL/HIGH/MEDIUM security closures verified
- [x] No new CRITICAL/HIGH regressions found



---

_Persisted from codex artifact codex-impl-audit-prompt-spec-016-step-3-security-review-lane-round-2026-06-25T17-46-39-300Z.md._
