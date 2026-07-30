# SPEC-016 Step 4 — security-review lane, r5 audit

Codex run: security-reviewer lane, round 5
HEAD: `bc1409f`
Branch: `impl/spec-016`

## Verdict

**CONVERGENT** — 0 CRITICAL / 0 HIGH / 0 MEDIUM / 0 LOW. **Risk: LOW.**

The r4 BLOCK MERGE finding is closed; all prior-round security
closures verified intact; no new attack surface in the r4 delta.

Verification:
- `govulncheck ./...`: no called vulnerabilities; 17 module vulns
  reported as not called.
- `go test -race -count=1 ./internal/payout/...`: passed.
- `git show bc1409f` secrets scan: no production secrets. One
  64-hex match is the existing deterministic payout test key
  fixture, not a prod credential.

## R4 Closure Verification

| R4 finding | Status | Evidence |
|------------|--------|----------|
| [sec:r4-1] MEDIUM YAML-load failure structured emit | CLOSED | `main.go:1353` SIGHUP load failures emit `payout_config_reload_rejected` with `key=yaml_parse, attempted_value=config_load_failed, bound=valid payout.tuning YAML, actor=operator_key:coordinator, ts_utc, severity=PAGE`. No production path emits raw YAML body. |
| [sec:r4-2] LOW SPKI runbook | CLOSED | `payout-runbook.md:262` documents 64-hex SHA-256, OpenSSL pipeline emits hex, line 290 correctly states `CloseIdleConnections` drains only idle conns while in-flight RPCs may complete on old TLS session. |

## R1–R3 closure spot-check (no regressions)

- r1: payout-runbook hot-wallet provisioning + key rotation: OK
- r1: deploy gate keys (low_balance, low_native): OK
- r1: payout env:NAME resolution: OK
- r2: RunNowController rate-limit + payout_run_now_invoked event: OK
- r2: SPKI pin live-read at TLS verify time: OK
- r2: AST forbidden set exact identifiers: OK
- r3: CloseIdleConnections + SIGHUP wiring: OK
- r3: payout_config_reloaded / _rejected §7.1 field names (bound
  violation path): OK

## OWASP Top 10 sweep

| Control | Status |
|---------|--------|
| A01 Broken Access Control | OK — no new route/auth surface in r4 delta |
| A02 Cryptographic Failures | OK — SPKI encoding + rotation semantics corrected |
| A03 Injection | OK — no dynamic SQL/command construction introduced |
| A04 Insecure Design | OK — prior run-now + drift-halt closures remain intact |
| A05 Security Misconfiguration | OK — deploy gate/runbook checks remain closed |
| A06 Vulnerable Components | OK — govulncheck found no called vulns |
| A07 Auth Failures | OK — actor labels are non-bearer identifiers |
| A08 Integrity Failures | OK — SPKI live-read + idle-pool drain remain wired |
| A09 Logging Failures | OK — YAML-load rejection now satisfies §7.1 |
| A10 SSRF | OK — no user-controlled outbound URL path introduced |

## Security Checklist

- [x] No hardcoded production secrets
- [x] All reviewed inputs validated or bounded
- [x] Injection prevention verified for reviewed paths
- [x] Authentication/authorization spot-checked
- [x] Dependencies audited
- [x] r4 security findings verified closed
- [x] No r1-r3 security closure regression found

## Recommendation

CONVERGENT. Security lane has no remaining defects.

Note: code lane r5 found 2 HIGH defects unrelated to security
namespace (money-path event field-set drift on
`payout_insufficient_funds` and `payout_daily_cap_tripped`).
Those are SPEC §7.1 logging gaps, not security defects per OWASP.
Once code lane closes its r5 findings, all three lanes will be
CONVERGENT.
