# SPEC-016 Step 4 — security-review lane, r2 audit

Codex run: `security-reviewer` lane, round 2
HEAD under audit: `dd72e0e`
Branch: `impl/spec-016`

## Verdict

**BLOCK MERGE** — 0 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW. **Risk: HIGH.**

The r1 HIGH drift-halt defect is closed: negative drift now calls
`runner.RequestHalt`, the halt flag persists for the process lifetime,
subsequent `RunOnce` calls return `ErrRunnerHalted` before selecting
rows, and admin run-now returns `409 runner_halted` with the halt reason.

However, Step 4 still misses the SPEC §4.2 admin `run-now` rate-limit
gate. This is a money-path operational DoS control explicitly required
by SPEC-016 and should block PR-open.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 1 |
| MEDIUM   | 1 |
| LOW      | 0 |

## Findings

### [sec:r2-1] HIGH — `/admin/payout/run-now` does not enforce `run_now_min_interval` or emit `payout_run_now_invoked`

**Category:** A04 Insecure Design / A05 Security Misconfiguration / A09 Logging Failures

**Location:** `specs/SPEC-016-payout-pipeline.md:861`; `phase4-coordinator/internal/payout/mux.go:160`; `phase4-coordinator/internal/payout/mux.go:235`; `phase4-coordinator/internal/payout/mux.go:324`; `phase4-coordinator/cmd/coordinator/main.go:917`

**Exploitability:** Remote, authenticated with operator key.

**Blast Radius:** An operator-key-compromised attacker can tight-loop synchronous payout cycles, consuming coordinator CPU, SQLite work, and RPC quota. The in-flight mutex prevents overlap, but it does not enforce the required 429 cooldown between completed invocations. Operators also lose the required `payout_run_now_invoked` audit signal for successful, rate-limited, in-flight, or halted attempts.

**Issue:** SPEC §4.2 requires `/admin/payout/run-now` to be rate-limited by `payout.tuning.run_now_min_interval` and to return 429 when called sooner than the interval. It also requires every invocation to emit `payout_run_now_invoked`. The implementation validates and hot-reloads `RunNowMinInterval`, but no handler reads it. All Step2/Step3/Step4 mux handlers check only `IsHalted()` and then call `Runner.RunOnce()`.

**Remediation:**

```go
// BAD: no cooldown check, no invocation audit event.
r.With(auth).Post("/admin/payout/run-now", func(w http.ResponseWriter, req *http.Request) {
    if opts.Runner.IsHalted() {
        writeJSON(w, http.StatusConflict, map[string]any{
            "error": "runner_halted",
            "reason": opts.Runner.HaltReason(),
        })
        return
    }
    if err := opts.Runner.RunOnce(req.Context()); err != nil {
        writeError(w, http.StatusConflict, "cycle_in_flight_or_failed")
        return
    }
    writeJSON(w, http.StatusOK, map[string]any{"ok": true})
})

// GOOD: centralize the handler and gate it with the live tuning snapshot.
type RunNowLimiter struct {
    mu   sync.Mutex
    last time.Time
}

func (l *RunNowLimiter) Allow(now time.Time, minInterval time.Duration) bool {
    l.mu.Lock()
    defer l.mu.Unlock()
    if !l.last.IsZero() && now.Sub(l.last) < minInterval {
        return false
    }
    l.last = now
    return true
}

func runNowHandler(opts Step2MuxOptions, limiter *RunNowLimiter, log zerolog.Logger) http.HandlerFunc {
    return func(w http.ResponseWriter, req *http.Request) {
        now := time.Now().UTC()
        minInterval := opts.RunNowMinInterval
        if opts.Tuning != nil {
            minInterval = opts.Tuning.Snapshot().RunNowMinInterval
        }

        outcome := "accepted"
        defer func() {
            log.Info().
                Str("event", "payout_run_now_invoked").
                Str("outcome", outcome).
                Str("ts_utc", now.Format(time.RFC3339Nano)).
                Send()
        }()

        if !limiter.Allow(now, minInterval) {
            outcome = "rate_limited"
            writeError(w, http.StatusTooManyRequests, "rate_limited")
            return
        }
        if opts.Runner.IsHalted() {
            outcome = "runner_halted"
            writeJSON(w, http.StatusConflict, map[string]any{
                "error":  "runner_halted",
                "reason": opts.Runner.HaltReason(),
            })
            return
        }
        if err := opts.Runner.RunOnce(req.Context()); err != nil {
            outcome = "cycle_in_flight_or_failed"
            writeError(w, http.StatusConflict, "cycle_in_flight_or_failed")
            return
        }
        writeJSON(w, http.StatusOK, map[string]any{"ok": true})
    }
}
```

Add tests that two authenticated `run-now` calls inside the configured
interval return `200` then `429`, that the interval source follows
`TuningProvider.Snapshot()`, and that `payout_run_now_invoked` is logged
for 200, 409, 429, and in-flight 409 outcomes.

### [sec:r2-2] MEDIUM — AST guard for the tuning/security split omits current security identifiers

**Category:** A05 Security Misconfiguration / A08 Software and Data Integrity Failures

**Location:** `phase4-coordinator/internal/payout/config_tuning_test.go:180`; `phase4-coordinator/internal/config/config.go:62`

**Exploitability:** Future regression guard failure; not directly exploitable in the current code because `config_tuning.go` does not currently reference these fields.

**Blast Radius:** A later edit could add a SIGHUP-reload path dependency on `payout.security.rpc_url_primary`, `rpc_url_secondary`, `per_payout_cap_usdc_base_units`, or `per_day_cap_usdc_base_units` and still pass `TestTuningStaticCheck_NoSecurityNamespaceReference`.

**Issue:** The static check is now AST-based, and it does catch `HotWalletAddress`, `cfg.Security.HotWalletAddress`, and string literals containing `payout.security.`. But its forbidden identifier set is incomplete. It includes non-exact names such as `PerDayCap` and `PerPayoutCap`, while Go AST identifiers are exact names (`PerDayCapUSDCBaseUnits`, `PerPayoutCapUSDCBaseUnits`). It also omits `PayoutSecurityConfig`, `RPCURLPrimary`, and `RPCURLSecondary`.

**Remediation:**

```go
// BAD: non-exact names do not match ast.Ident values.
forbiddenIdents := map[string]bool{
    "SecurityConfig": true,
    "PerDayCap":     true,
    "PerPayoutCap":  true,
}

// GOOD: include the exact current PayoutSecurityConfig type and field names.
forbiddenIdents := map[string]bool{
    "PayoutSecurityConfig":                 true,
    "SecurityConfig":                       true,
    "HotWalletAddress":                     true,
    "RPCURLPrimary":                        true,
    "RPCURLSecondary":                      true,
    "PerPayoutCapUSDCBaseUnits":            true,
    "PerDayCapUSDCBaseUnits":               true,
    "ChainReconInterval":                   true,
    "ChainReconToleranceUSDCBaseUnits":     true,
    "DevMode":                              true,
    "EncryptedWalletPath":                  true,
    "EncryptedWalletOnDiskHex":             true,
    "PauseResumeMinInterval":               true,
    "CancelMaxTipMultiplier":               true,
    "CancelMaxGasNativeWei":                true,
    "CancelMaxGasNativeWeiPer24h":          true,
    "AbandonRatePerHour":                   true,
}
```

If the import graph allows a test-only helper, generate this set from
the security struct definition instead of maintaining a handwritten list.

## R1 Finding Closure

| R1 Finding | Status | Evidence |
|------------|--------|----------|
| [sec:r1-1] negative drift does not halt runner | CLOSED | `ChainBalanceWorker` calls `haltRunner("payout_chain_balance_drift_negative")` at `reconcile.go:448`; production wires that to `runner.RequestHalt` at `main.go:894`; `RunOnce` returns `ErrRunnerHalted` at `runner.go:321`; `TestRunnerHalted_Skips_Cycle` passed. |
| [sec:r1-2] SIGHUP snapshots not consumed | CLOSED | Runner snapshots tuning at cycle start (`runner.go:348`); addresses read live cooling-off (`addresses.go:108`); reorg poller reads live poll window (`reorg.go:74`); reaper reads live stale age (`reaper.go:58`). |
| [sec:r1-3] deploy gate omits low-balance keys | CLOSED | Gate requires `low_balance_threshold` and `low_native_threshold` at `check-deploy-config.sh:376`; deploy-gate test suite passed. |
| [sec:r1-4] payout security `env:NAME` values not resolved | CLOSED | `resolveEnv` covers all four payout security strings at `config.go:735`; `TestLoadResolvesPayoutSecurityEnvFields` passed. |

## OWASP Top 10 Sweep

| Control | Status |
|---------|--------|
| A01 Broken Access Control | OK — provider payouts endpoint validates bearer token, enforces token/path provider match, and queries by provider ID. |
| A02 Cryptographic Failures | OK for r2 delta — SIGHUP loader does not touch wallet KEK/security fields; SPKI pin logging remains redacted. |
| A03 Injection | OK — reviewed payout SQL uses bind parameters for provider IDs, hot wallet addresses, and limits. Env resolution uses `os.Getenv`, not shell evaluation. |
| A04 Insecure Design | **HIGH** — run-now DoS cooldown required by SPEC §4.2 is missing. Drift halt design is otherwise closed. |
| A05 Security Misconfiguration | **HIGH/MEDIUM** — run-now tuning value is validated/reloadable but unenforced; AST guard set is incomplete. |
| A06 Vulnerable Components | OK — `govulncheck ./...` reported no called vulnerabilities. |
| A07 Auth Failures | OK — run-now remains operator-key authenticated; provider payouts return 401/403 as expected. |
| A08 Integrity Failures | MEDIUM — future SIGHUP security/tuning split regression could evade the incomplete AST identifier set. Current SIGHUP loader itself is tuning-only. |
| A09 Logging Failures | HIGH component — `payout_run_now_invoked` required by SPEC §4.2 is not emitted for run-now invocations, including halted 409 responses. |
| A10 SSRF | OK — no new user-controlled outbound URL path; payout security RPC URLs resolve only from startup config/env. |

## Verification

- `go test -race -count=1 ./internal/payout/...` from `phase4-coordinator/`: passed.
- `go test -count=1 ./internal/config ./cmd/coordinator ./internal/payout` from `phase4-coordinator/`: passed.
- `bash dist/test/check_deploy_config_test.sh` from `phase4-coordinator/`: passed, 44/44.
- `govulncheck ./...` from `phase4-coordinator/`: no called vulnerabilities; 17 module vulnerabilities reported as not called.
- Targeted tests passed:
  - `TestChainBalanceWorker_DriftNegativeCallsHalt`
  - `TestRunnerHalted_Skips_Cycle`
  - `TestRunNow_Returns409WhenHalted`
  - `TestTuningStaticCheck_NoSecurityNamespaceReference`
  - `TestTuningProvider_ReloadBoundViolationRetainsLiveValue`
  - `TestValidateBounds_AllFields`
  - `TestValidateBounds_CrossField_LowBalanceVsPerDayCap`
  - `TestLoadResolvesPayoutSecurityEnvFields`
  - `TestLoadFailsClosedOnEmptyEnv`
- Scoped source secrets scan: no production credentials found; hits were examples, test literals, env placeholders, or documentation.
- Git-history secret scan was run with a broad token/secret regex and was noisy because the repository intentionally contains token/auth terminology and diffs; no high-confidence production secret pattern was identified in the scoped follow-up scan.

## Security Checklist

- [x] No hardcoded production secrets found in scoped source scan.
- [x] Dependency audit run with `govulncheck`.
- [x] Injection prevention reviewed for changed payout/config paths.
- [x] Authentication/authorization reviewed for provider payouts and admin run-now.
- [x] SIGHUP tuning-only loader verified not to resolve payout security env values.
- [x] Drift halt verified to block subsequent payout cycles.
- [ ] Admin run-now rate limit enforced.
- [ ] `payout_run_now_invoked` emitted for every run-now invocation.
- [ ] AST forbidden identifier set covers every current `PayoutSecurityConfig` type/field name.
