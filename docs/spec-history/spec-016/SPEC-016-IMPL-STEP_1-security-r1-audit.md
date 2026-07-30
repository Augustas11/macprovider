# Security Review Report

**Scope:** SPEC-016 Step 1 security lane for commit `1df0235` on `impl/spec-016`: `phase4-coordinator/internal/payout/**`, payout wiring in `cmd/coordinator/main.go`, config/DSN changes, and relevant auth/token primitives.  
**Risk Level:** LOW  
**Verdict:** FIX-OPTIONALLY-BEFORE-PROCEED for one LOW hardening item; no CRITICAL / MAJOR / MEDIUM findings.

## Summary

- Critical Issues: 0
- High/Major Issues: 0
- Medium Issues: 0
- Low Issues: 1
- Secrets scan: completed on Step 1 paths and git history slice; no production secret found.
- Dependency audit: `govulncheck ./...` found 0 reachable vulnerabilities. It reported 17 unreachable module advisories in required modules, mainly `golang.org/x/crypto/ssh`, not called by this code.

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| 0 | 0 | 0 | 1 |

## Findings

[sec:1.1] [LOW] Idempotent migrations do not prove pre-existing payout schema integrity  
  Asset: Future payout-runner DB invariants that protect hot-wallet payout state.  
  Vector: A hostile local/operator-controlled DB file pre-creates SPEC-016 tables or indexes with weaker definitions before Step 1 runs. `CREATE ... IF NOT EXISTS` then skips replacement, and startup checks currently verify presence/same-DB/trigger names, not full DDL identity. This is not an immediate external exploit and Step 1 first cutover mostly moots it, but it remains a recovery/import hardening gap.  
  File: `phase4-coordinator/internal/payout/migrations.go:14` and `phase4-coordinator/internal/payout/migrations.go:51`; examples in `phase4-coordinator/internal/payout/migrations/0002_payout_attempts.sql:33`  
  Category: OWASP A05 Security Misconfiguration / A08 Integrity Failures  
  Fix: After migrations, compare critical table/index/trigger SQL from `sqlite_master` against expected normalized definitions and fail startup on drift.

```go
row := db.QueryRowContext(ctx,
    `SELECT sql FROM sqlite_master WHERE type=? AND name=?`,
    "index", "idx_pa_from_nonce_active",
)
var got string
if err := row.Scan(&got); err != nil {
    return err
}
if normalizeDDL(got) != normalizeDDL(expectedIdxPAFromNonceActiveSQL) {
    return fmt.Errorf("payout schema drift: idx_pa_from_nonce_active")
}
```

## Adversarial Probes I Ran

- Adversary A, stolen `provider_token`: verified forged/mutated signatures fail via existing payout tests and an independent ethers.js EIP-712 vector accepted by Go verifier only for the expected signer. Verified pass.
- Adversary B, decorative-field replay: nonce mutation test rejects with `signature_mismatch`; code path builds typed data from URL/body-derived `providerID`, `chain`, `nonce`, `ts_utc`, address, and hot-wallet verifying contract. Verified pass.
- Cross-provider replay: replay table is `(canonical_address, nonce)` at `0001_provider_payout_addresses.sql:22`; provider binding is load-bearing in EIP-712 input at `addresses.go:310`. Verified pass by code walk.
- EIP-55: pure lower/upper accepted, mixed-case checksum branch preserved at `eip55.go:48`. Verified pass by code walk/tests.
- RecoverCompact edge cases: `v=31/32` compressed recovery codes rejected in isolated probe; `decodeSignatureHex` enforces `{27,28}` at `eip712.go:177`. Verified pass.
- Deny-list: hot wallet as payout destination rejected before EIP-712 at `addresses.go:282`; v0.1.21 destination-side framing honored. Verified pass.
- PRAGMA durability: isolated modernc/sqlite probe opened 8 concurrent connections; all reported `PRAGMA synchronous = 2` (`FULL`). Verified pass.
- Pause behavior: existing tests cover pre-auth 503 and in-transaction TOCTOU re-check with identical `rotation_in_progress` body. Verified pass.

## Tests Run

- `go test -count=1 -race ./...` from `phase4-coordinator` PASS
- `go test -count=1 -race ./internal/payout` PASS
- `govulncheck ./...` PASS, 0 reachable vulnerabilities
- `govulncheck -show verbose ./...` PASS, confirmed only unreachable module advisories
- Targeted payout tests for EIP-712 rejection, anti-replay, deny-list, skew, pause, migrations PASS
- Independent ethers.js EIP-712 digest/signature cross-check PASS
- Isolated Go verifier accepted the ethers vector and matched digest `cc905f9e...733f8b4e` PASS

## Security Checklist

- [x] No hardcoded production secrets found in Step 1 paths
- [x] All request inputs bounded/validated for the payout registration path
- [x] Injection prevention verified: SQL uses placeholders for user inputs
- [x] Authentication/authorization verified for `provider_token` registration path
- [x] EIP-712 proof-of-possession checked against independent ethers.js behavior
- [x] Dependencies audited with `govulncheck`
- [x] OWASP Top 10 reviewed for applicable Step 1 surfaces

## What I Didn’t Review

I did not report code-style or architecture-only issues; those belong to sibling lanes. I also did not review Steps 2-4 operator/admin endpoints because they have not landed in Step 1. No repository files were modified or report file written, per the read-only lane constraint.

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-1-security-review-lane-lane--2026-06-25T15-03-51-602Z.md; agent-role tools (Write/Edit) were disallowed so codex returned the report in its artifact body. Claude transcribed verbatim — no edits._
