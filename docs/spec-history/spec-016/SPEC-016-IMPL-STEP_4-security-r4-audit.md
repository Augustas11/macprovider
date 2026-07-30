# SPEC-016 Step 4 - security-review lane, r4 audit

Codex run: security-reviewer lane, round 4
Requested implementation HEAD: `6eb49c0`
Audited worktree HEAD: `58f8340` (`58f8340` only adds r4 audit prompts; `git diff --name-only 6eb49c0..HEAD` shows prompt files only)
Branch: `impl/spec-016`

## Verdict

**BLOCK MERGE** - 0 CRITICAL / 0 HIGH / 1 MEDIUM / 1 LOW. **Risk: MEDIUM.**

The r3 HIGH for SPKI pool retention is closed in code: the RPC client live-reads pins at TLS handshake time, accepted SPKI changes return changed keys, and the SIGHUP handler drains both HTTP idle pools. The run-now correlation, halt-race test, and chain-balance event rename are also closed.

One r3 logging issue is not fully closed: `LoadPayoutTuningOnly` failures in the SIGHUP handler still bypass the structured `payout_config_reload_rejected` field set required by SPEC §7.1. There is also a LOW operator-runbook accuracy issue in the SPKI rotation section.

Verification:
- `govulncheck ./...` from `phase4-coordinator/`: no called vulnerabilities; 17 vulnerable required modules are not reached by code.
- `go test -race -count=1 ./internal/payout/...` from `phase4-coordinator/`: passed.
- Secrets/log scan over the r4-relevant payout paths and recent git patches: no bearer, KEK, wallet private key, or RPC URL plaintext found in the new SIGHUP rejection emit paths. SPKI values are redacted to an 8-character prefix.

## Counts

| Severity | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH     | 0 |
| MEDIUM   | 1 |
| LOW      | 1 |

## Findings

### [sec:r4-1] MEDIUM - YAML/load-failure reload rejection omits the required audit fields

- Category: OWASP A09 Security Logging and Monitoring Failures
- Location: `phase4-coordinator/cmd/coordinator/main.go:1353`
- Related good path: `phase4-coordinator/internal/payout/config_tuning.go:360`
- SPEC: `specs/SPEC-016-payout-pipeline.md:3731`
- Exploitability: local/operator path; requires a malformed or unreadable coordinator YAML and SIGHUP.
- Blast radius: operators and alert consumers cannot reliably classify rejected reloads, including failed SPKI rotations, because the rejection event lacks `key`, `attempted_value`, `bound`, `actor`, and `ts_utc`.

`TuningProvider.emitRejected` now emits the correct structured event for bound violations and for non-bound errors that reach that helper. However the SIGHUP handler returns earlier when `config.LoadPayoutTuningOnly(configPath)` fails. That path emits only `event=payout_config_reload_rejected` and `severity=PAGE` plus the zerolog error/message. It does not emit the §7.1 field set and does not set `key=yaml_parse` or `actor=operator_key:coordinator`.

This leaves [sec:r3-2] only partially closed. It is not a secret leak in the reviewed path: `LoadPayoutTuningOnly` returns read/YAML/bounds errors, not config contents. The issue is audit schema drift during a security-relevant reload failure.

Remediation:

```go
// BAD: schema-incomplete rejection event.
if err != nil {
    log.Error().Err(err).
        Str("event", "payout_config_reload_rejected").
        Str("severity", "PAGE").
        Msg("payout tuning SIGHUP reload: LoadPayoutTuningOnly failed; live value retained")
    continue
}

// GOOD: use the same §7.1 field contract for loader/YAML failures.
if err != nil {
    tsUTC := time.Now().UTC().Format(time.RFC3339Nano)
    log.Error().Err(err).
        Str("event", "payout_config_reload_rejected").
        Str("key", "yaml_parse").
        Str("attempted_value", "config_load_failed").
        Str("bound", "valid payout.tuning YAML").
        Str("actor", "operator_key:coordinator").
        Str("ts_utc", tsUTC).
        Str("severity", "PAGE").
        Msg("payout tuning SIGHUP reload: LoadPayoutTuningOnly failed; live value retained")
    continue
}
```

Use a sanitized `attempted_value` as above; do not log raw YAML contents because the full coordinator file can contain secret-bearing fields outside `payout.tuning`.

### [sec:r4-2] LOW - SPKI rotation runbook documents the wrong pin encoding and overstates pool-drain semantics

- Category: OWASP A05 Security Misconfiguration / A02 Cryptographic Failures
- Location: `phase4-coordinator/dist/payout-runbook.md:274`
- Related code/spec: `phase4-coordinator/internal/payout/config_tuning.go:160`, `specs/SPEC-016-payout-pipeline.md:3654`
- Exploitability: operator error during RPC certificate/SPKI rotation.
- Blast radius: following the runbook can produce a rejected pin reload or inaccurate expectations about active connections during rotation.

The implementation and SPEC require SPKI pins to be a 64-hex-character SHA-256 string or empty. The runbook tells operators to set `"<new base64 SHA-256>"`, which the implementation rejects. The same section says "all subsequent RPC calls perform fresh TLS handshakes"; code correctly calls `CloseIdleConnections`, but active in-flight RPCs are not closed and can complete under the old handshake. That in-flight behavior is acceptable, but the runbook should say it plainly.

Remediation:

```yaml
# BAD
payout:
  tuning:
    rpc_url_primary_pin_spki:   "<new base64 SHA-256>"
    rpc_url_secondary_pin_spki: "<new base64 SHA-256>"

# GOOD
payout:
  tuning:
    rpc_url_primary_pin_spki:   "<new 64-hex-char SHA-256 SPKI>"
    rpc_url_secondary_pin_spki: "<new 64-hex-char SHA-256 SPKI>"
```

Also update the prose to say that SIGHUP closes idle RPC connections; RPCs already in flight when SIGHUP lands may finish on the old TLS session, while the next connection after pool drain handshakes against the live pin.

## R3 Closure Verification

| Probe | Status | Evidence |
|-------|--------|----------|
| A. SPKI close-idle correctness | CODE CLOSED / DOC LOW | `NewHTTPRPCClient` stores `transport` and `CloseIdleConnections` drains it (`rpc.go:120`, `rpc.go:175`). Pin verifier calls `pinFn()` per handshake and skips pinning on empty pin (`rpc.go:191`). SIGHUP calls close on both concrete HTTP RPCs when either SPKI key is in `changedKeys` (`main.go:1393`). Runbook has the LOW issue above. |
| A. Empty-pin reload | CLOSED | `emitReloaded` appends the SPKI key when old pin differs from empty new pin (`config_tuning.go:338`), so the handler closes idle pools for disabling pinning too. |
| A. Multiple SIGHUPs | CLOSED | Signal handling is single-goroutine/sequential; each reload compares `old := p.Snapshot()` to the candidate before atomic store (`config_tuning.go:277`). |
| B. Reload event fields | PARTIAL | Success and bound-violation paths emit `key`, values, `actor`, `ts_utc`, `severity` (`config_tuning.go:305`, `config_tuning.go:360`). Loader/YAML failure path remains schema-incomplete; see [sec:r4-1]. |
| C. Run-now run_id correlation | CLOSED | `Runner.RunOnce` emits `payout_run_started/finished` with one `runID` and returns it (`runner.go:363`, `runner.go:376`, `runner.go:460`). `ServeRunNow` replaces the provisional ID with `cycleRunID` before emitting accepted/error outcomes (`runnow.go:170`). Row events receive the same `runID` through `processRow`, `payout_paid`, `payout_failed`, and `payout_capped` paths. |
| D. Halt-race coverage | CLOSED | `runnerExecutor` includes `IsHalted`, `HaltReason`, `RunOnce` (`runnow.go:24`). The fake returns `IsHalted=false` and `RunOnce=ErrRunnerHalted`; the test asserts 409 and `runner_halted` body (`runnow_test.go:337`). Production path falls back to concrete `*Runner` (`runnow.go:82`). |
| E. Chain-balance event rename | CLOSED | Chain-balance emits `payout_chain_balance_rpc_disagreement` with chain-balance fields (`reconcile.go:404`). SPEC §7.1 `payout_rpc_disagreement` remains the payout-row receipt schema (`SPEC-016-payout-pipeline.md:3726`). BetterStack runbook lists the new event (`payout-runbook.md:136`). |
| F. govulncheck + race | PASSED | `govulncheck ./...`: no called vulnerabilities. `go test -race -count=1 ./internal/payout/...`: passed. |
| G. Secrets/log scan | PASSED | No bearer, KEK, wallet private key, or RPC URL plaintext found in new SIGHUP rejection emits. `redactSPKI` truncates SPKI log values (`config_tuning.go:382`). |

## OWASP Top 10 Sweep

| Category | Assessment |
|----------|------------|
| A01 Broken Access Control | No new unauthenticated route surface in r3 fix-pass. Run-now remains operator-admin path and logs actor labels, not bearer values. |
| A02 Cryptographic Failures | LOW documentation issue only: code enforces 64-hex SPKI and drains idle pools; runbook says base64. |
| A03 Injection | No SQL/command/template injection introduced in the reviewed delta. Reload path uses YAML parsing and structured config values, not dynamic query construction. |
| A04 Insecure Design | SPKI live-read plus pool drain is a reasonable design for accepted reloads; in-flight old-handshake completion is acceptable if documented. |
| A05 Security Misconfiguration | LOW runbook misconfiguration risk for SPKI encoding. |
| A06 Vulnerable Components | `govulncheck ./...` found no called vulnerabilities. |
| A07 Identification/Auth Failures | No password/session/JWT changes in scope. Operator actor fields are labels such as `operator_key:coordinator`, not bearer secrets. |
| A08 Software/Data Integrity Failures | r3 HIGH is code-closed: accepted SPKI changes force fresh handshakes after idle-pool drain. |
| A09 Logging/Monitoring Failures | MEDIUM: loader/YAML SIGHUP failures still emit schema-incomplete `payout_config_reload_rejected`. |
| A10 SSRF | No user-controlled outbound URL path introduced. RPC URLs remain startup security config, not SIGHUP tuning. |

## Security Checklist

- [x] No hardcoded production secrets found in reviewed paths or recent patches.
- [x] No bearer / KEK / wallet plaintext found in the new SIGHUP rejection emit paths.
- [x] Dependency audit run: `govulncheck ./...`.
- [x] Race check run: `go test -race -count=1 ./internal/payout/...`.
- [x] Injection prevention reviewed for the r4 delta.
- [x] Authentication/authorization reviewed for run-now and reload actors.
- [x] SPKI pin rotation, empty-pin reload, and idle-pool drain reviewed.
- [x] `payout_config_reloaded` success field set reviewed.
- [ ] `payout_config_reload_rejected` is complete for all paths; loader/YAML failure remains [sec:r4-1].
- [ ] SPKI operator runbook is fully accurate; encoding/in-flight wording remains [sec:r4-2].

## Recommendation

Do not declare CONVERGENT yet. Fix [sec:r4-1] before merge because it is a direct SPEC §7.1 logging invariant miss on a security-relevant reload path. Fix [sec:r4-2] in the same pass because it is small and prevents operator error during SPKI rotation.
