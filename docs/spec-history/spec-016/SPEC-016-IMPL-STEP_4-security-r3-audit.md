# SPEC-016 Step 4 — security-review lane, r3 audit

Codex run: security-reviewer lane, round 3
HEAD: `fe6a699`
Branch: `impl/spec-016`

## Verdict

**BLOCK MERGE** — 0 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW. **Risk: HIGH.**

The r2 HIGH on run-now contract is closed; the r2 MEDIUMs are closed
too. But r3 found a new HIGH: SPKI live-read works at handshake but
`http.Transport` keeps idle TLS connections for 90s, so SIGHUP'd pin
changes don't invalidate pooled sessions. Operators get false
"reload accepted" evidence.

Verification:
- `govulncheck ./...`: no called vulnerabilities; 17 vulnerable
  required modules not reached by code.
- `go test -race -count=1 ./internal/payout/...`: passed.
- Secrets scan: no production credentials found.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 1 |
| MEDIUM   | 1 |
| LOW      | 0 |

## Findings

### [sec:r3-1] HIGH — SPKI reload does not invalidate pooled TLS connections

- Category: OWASP A08 Integrity Failures / A02 Cryptographic Failures
- Files: `phase4-coordinator/internal/payout/rpc.go:143`,
  `phase4-coordinator/cmd/coordinator/main.go:1310`
- Exploitability: remote, requires stale already-established RPC TLS
  connection plus old/compromised endpoint or key condition.
- Blast radius: a lying RPC can keep serving over an
  already-verified pooled connection after operators believe a new
  SPKI pin is live.

`makeSPKIPinVerifier` correctly live-reads the pin per TLS
handshake, and empty pin explicitly disables pinning. But
`http.Transport` keeps idle TLS connections for 90s
(`IdleConnTimeout: 90 * time.Second`), and the SIGHUP reload path
updates `TuningProvider` without closing RPC idle connections. The
next RPC may reuse a connection verified under the OLD pin, so
`payout_config_reloaded` overstates cert-rotation enforcement.

**Fix:** expose `CloseIdleConnections()` on the RPC client, and
call it after an accepted SPKI pin reload:

```go
type HTTPRPCClient struct {
    URL        string
    HTTPClient *http.Client
    transport  *http.Transport
}

func (c *HTTPRPCClient) CloseIdleConnections() {
    if c != nil && c.transport != nil {
        c.transport.CloseIdleConnections()
    }
}
```

Wire in the SIGHUP handler: after `TuningProvider.Reload` returns
nil AND the changed-keys set includes either SPKI pin field, call
`rpcs.Primary.CloseIdleConnections()` and
`rpcs.Secondary.CloseIdleConnections()`.

### [sec:r3-2] MEDIUM — `payout_config_*` reload events drift from §7.1 field contract

- Category: OWASP A09 Security Logging and Monitoring Failures
- Files: `phase4-coordinator/internal/payout/config_tuning.go:215`,
  `phase4-coordinator/cmd/coordinator/main.go:1345`
- Exploitability: operational/audit failure, authenticated operator
  path.
- Blast radius: alert consumers and cert-rotation runbooks can miss
  or misparse reload/reject details.

SPEC §7.1 (line 3730) requires `payout_config_reloaded` fields:
`key, old_value, new_value, actor, ts_utc`. Implementation emits
`key, old, new, ts_utc, severity` (missing `actor`; uses `old/new`
instead of `old_value/new_value`).

Rejected reloads (line 3731) require `key, attempted_value, bound,
actor, ts_utc`. Implementation emits only event/severity/message
and omits `key, attempted_value, bound, actor`. YAML-load failure
path emits even less.

Converges with [code:r3-2].

**Fix:** see [code:r3-2] — rename fields, pass actor, return
structured bound errors for rejected reloads.

## R2 Finding Closure

| R2 finding | Status | Evidence |
|------------|--------|----------|
| [sec:r2-1] HIGH — run-now contract | CLOSED | RunNowController centralises rate-limit + event emit + halt-race |
| [sec:r2-2] MEDIUM — AST forbidden set | CLOSED | Exact identifiers enumerated |

## OWASP Top 10 sweep (r3 delta)

| Control | Status |
|---------|--------|
| A02 Cryptographic Failures | **HIGH** — TLS pool retention |
| A04 Insecure Design | OK — run-now rate limit enforced, drift halt enforced |
| A05 Security Misconfiguration | OK — deploy gate complete; SPKI reload partial; pin reload + run-now both reflect in production where the next handshake happens |
| A08 Integrity Failures | **HIGH** — pool retention enables stale TLS verification |
| A09 Logging Failures | **MEDIUM** — payout_config_* field drift |

## Security Checklist

- [x] No production hardcoded secrets found.
- [x] Dependency audit run: `govulncheck ./...`.
- [x] Race check run: `go test -race -count=1 ./internal/payout/...`.
- [x] Run-now rate limit race reviewed: timestamp commit is
  mutex-protected before `RunOnce`; no TOCTOU spam window found.
- [x] Run-now actor payload reviewed: emits `actor="operator_key"`,
  not bearer secret.
- [x] SPKI live-read verified per handshake; pooled connection
  retention remains HIGH.
- [x] Empty SPKI pin behavior verified as explicit no-pinning mode.
- [x] AST forbidden set checked against `PayoutSecurityConfig`;
  exact fields are covered and selectors/string literals are caught.
- [x] OWASP Top 10 evaluated; relevant deltas are A02/A08 (HIGH) and
  A09 (MEDIUM) above.
- [x] `payout_run_now_invoked.outcome` assessed as acceptable
  defensive extension because §7.1 defines a minimum field set.

## Recommendation

BLOCK MERGE on [sec:r3-1] HIGH. The MEDIUM is fix-then-proceed.
