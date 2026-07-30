# SPEC-016 Step 4 — security-review lane, r1 audit

Codex run: `codex-impl-audit-prompt-spec-016-step-4-security-review-lane-round-2026-06-25T18-52-24-447Z.md`
HEAD: `dbf7e78`
Branch: `impl/spec-016`

## Verdict

**BLOCK MERGE** — 0 CRITICAL / 1 HIGH / 3 MEDIUM / 0 LOW. **Risk: HIGH.**

Verification:
- `govulncheck ./...`: no called vulnerabilities; 17 module vulns
  reported as not called.
- `go test -race -count=1 ./internal/payout/...`: passed.
- `go test -count=1 ./cmd/coordinator ./internal/config`: passed.
- Scoped secrets/source-history scan: no hardcoded production
  secrets found.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 1 |
| MEDIUM   | 3 |
| LOW      | 0 |

## Findings

### [sec:r1-1] HIGH — Negative chain-balance drift does not actually halt the runner

- Category: A04 Insecure Design / A08 Integrity Failures
- Files: `phase4-coordinator/cmd/coordinator/main.go:868`,
  `phase4-coordinator/internal/payout/reconcile.go:416`
- Exploitability: operator-key-compromise prerequisite;
  fake-funding detector is the §7.4 floor.
- Blast radius: runner can continue payout cycles after the §7.4
  fake-funding detector emits PAGE.

`ChainBalanceWorker` invokes
`haltRunner("payout_chain_balance_drift_negative")`, but the
production wiring only logs `payout_runner_halt_requested`; it does
not call `runner.Stop`, set a halt flag, pause runtime flags, or
otherwise prevent the next payout cycle. SPEC §7.4 says drift beyond
tolerance MUST halt the runner.

**Fix sketch:**
```go
chainWorker, err := payout.NewChainBalanceWorker(db, rpcs, chainCfg, func(reason string) {
    logger.Error().Str("event", "payout_runner_halt_requested").Str("reason", reason).Send()
    haltCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
    defer cancel()
    _ = runner.Stop(haltCtx)
}, logger)
```

…and prevent restart until operator clears the halt flag.

### [sec:r1-2] MEDIUM — SIGHUP reload accepts snapshots that consumers never read

- Category: A05 Security Misconfiguration / A08 Integrity Failures
- Files: `phase4-coordinator/cmd/coordinator/main.go:733`, `:752`,
  `:839`, `:1272`; `phase4-coordinator/internal/payout/runner.go:262`
- Exploitability: operator/config-write path; creates misleading
  accepted-reload audit trail.
- Blast radius: runtime continues with startup tuning values despite
  `payout_config_reloaded`.

`TuningProvider.Reload` updates an atomic snapshot, but
runner/reaper/reorg/address services are constructed from
`cfg.Payout.Tuning.*` values and do not read
`TuningProvider.Snapshot()` per cycle. No production `Snapshot()`
consumers outside the provider itself.

Converges with [code:r1-1] and [arch:4.2].

### [sec:r1-3] MEDIUM — Deploy gate omits required low-balance tuning keys

- Category: A05 Security Misconfiguration
- Files: `phase4-coordinator/dist/check-deploy-config.sh:373`;
  config fields at `phase4-coordinator/internal/config/config.go:169`
- Blast radius: missing thresholds default to `0`, disabling §6.2
  balance alerts while the gate still passes.

The deploy gate validates six tuning keys and SPKI pins, but omits
`low_balance_threshold` and `low_native_threshold`.

**Fix:** add the two keys to the required-tuning-keys loop.

### [sec:r1-4] MEDIUM — Gate accepts payout `env:NAME` values that runtime does not resolve

- Category: A05 Security Misconfiguration
- Files: gate at `phase4-coordinator/dist/check-deploy-config.sh:330`;
  resolver only handles auth/OAuth at
  `phase4-coordinator/internal/config/config.go:622`; RPC use at
  `phase4-coordinator/cmd/coordinator/main.go:695`
- Blast radius: example `rpc_url_primary: env:...` can pass the gate
  but boot with literal `env:...` RPC URLs.

The deploy gate says payout fields may defer through `env:NAME`, and
the example uses that for RPC URLs, but `Config.resolveEnv()` does not
expand payout security fields.

**Fix:** extend `Config.resolveEnv()` to walk `payout.security.*`
string fields and apply the env-indirection rule.

## OWASP Top 10 sweep

| Control | Status |
|---------|--------|
| A01 Broken Access Control | OK — provider token/path mismatch returns 403; query is provider-scoped. |
| A02 Cryptographic Failures | OK — SPKI reload logging redacts pins. |
| A03 Injection | OK — SQL uses bind parameters for provider ID and hot wallet. |
| A04 Insecure Design | **HIGH** finding on drift detection not halting runner. |
| A05 Security Misconfiguration | **MEDIUM** deploy-gate gaps found. |
| A06 Vulnerable Components | OK — `govulncheck ./...` no called vulns. |
| A07 Auth Failures | OK — 401/403 paths correct; no bearer logging. |
| A08 Integrity Failures | **MEDIUM** SIGHUP accepted snapshot not consumed. |
| A09 Logging Failures | Partial — reload success/reject logs exist; halt log exists but lacks enforcement. |
| A10 SSRF | OK — no user-controlled outbound URL introduced. |

## Recommendation

BLOCK MERGE on [sec:r1-1] HIGH. The other three MEDIUMs are
fix-then-proceed.
