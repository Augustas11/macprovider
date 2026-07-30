# Security Review Report

**Scope:** SPEC-016 FULL implementation security r2 audit on branch `impl/spec-016`; implementation target `3b41c0d` with prompt-only HEAD `09163b6`. Reviewed `phase4-coordinator/internal/config/config.go`, `phase4-coordinator/dist/check-deploy-config.sh`, `phase4-coordinator/internal/payout/signer.go`, `phase4-coordinator/internal/payout/runner.go`, `phase4-coordinator/internal/payout/mux.go`, `phase4-coordinator/internal/payout/reconcile.go`, `phase4-coordinator/internal/payout/rpc.go`, and `phase4-coordinator/internal/payout/migrations.go`.
**Risk Level:** MEDIUM
**Convergence:** NOT CONVERGENT - 0 Critical / 0 High / 1 Medium / 0 Low.

## Summary

- Critical Issues: 0
- High Issues: 0
- Medium Issues: 1
- Low Issues: 0
- r1 security closure status: `[full-sec:r1-1]` CLOSED, `[full-sec:r1-2]` CLOSED.
- Required validation: `govulncheck ./...` from `phase4-coordinator/` found no called vulnerabilities; `go test -race -count=1 ./...` from `phase4-coordinator/` passed; `bash phase4-coordinator/dist/test/check_deploy_config_test.sh` passed 44/44.
- Secrets scan: targeted scan across the r1 fix-pass surface found no hardcoded production secrets and no new log line leaking `Bearer`, raw private keys, raw signed transactions, or signed tx bytes. Matches were comments, field names, auth extraction, and explicit "do not log raw_signed_tx" guard text.

## Critical Issues (Fix Immediately)

None.

## High Issues

None.

## Medium Issues

### 1. [full-sec:r2-1] ADD COLUMN Scanner Matches Comments And String Literals

**Severity:** MEDIUM
**Category:** A04 Insecure Design / migration parser trust boundary
**Location:** `phase4-coordinator/internal/payout/migrations.go:24`, `phase4-coordinator/internal/payout/migrations.go:127`
**Exploitability:** Local/trusted migration author only; not remotely exploitable because migrations are embedded application assets.
**Blast Radius:** Future migration files can trigger unintended `PRAGMA table_info` lookups and, if the referenced table+column already exists, `stripExistingColumnAlters` can rewrite text that is not an executable `ALTER TABLE` statement. A comment rewrite is mostly harmless; a string-literal rewrite can corrupt a future migration body before execution.
**Issue:** The r2 probe required `addColumnStmt` to avoid commented-out `ALTER TABLE ... ADD COLUMN ...` text and quoted string literals. The current implementation applies a raw regexp over the full SQL body:

```go
var addColumnStmt = regexp.MustCompile(`(?is)\bALTER\s+TABLE\s+([A-Za-z_][A-Za-z0-9_]*)\s+ADD\s+COLUMN\s+([A-Za-z_][A-Za-z0-9_]*)\b`)
```

Focused probe result:

```text
MATCH table=x col=y :: -- ALTER TABLE x ADD COLUMN y TEXT;
MATCH table=x col=y :: SELECT 'ALTER TABLE x ADD COLUMN y TEXT';
MATCH table=payout_attempts col=gas_reserved_native_wei :: ALTER TABLE payout_attempts ADD COLUMN gas_reserved_native_wei INTEGER NULL;
```

**Remediation:**

```go
// BAD: scans comments and string literals as if they were executable SQL.
matches := addColumnStmt.FindAllStringSubmatchIndex(body, -1)

// GOOD: scan only executable top-level statements, skipping comments and
// quoted strings before applying the ALTER TABLE recognizer.
func executableSQLStatements(body string) []string {
	var out []string
	var b strings.Builder
	inSingle, inDouble, inLineComment := false, false, false

	for i := 0; i < len(body); i++ {
		ch := body[i]
		next := byte(0)
		if i+1 < len(body) {
			next = body[i+1]
		}

		if inLineComment {
			if ch == '\n' {
				inLineComment = false
				b.WriteByte(ch)
			}
			continue
		}
		if !inSingle && !inDouble && ch == '-' && next == '-' {
			inLineComment = true
			i++
			continue
		}
		if ch == '\'' && !inDouble {
			inSingle = !inSingle
		} else if ch == '"' && !inSingle {
			inDouble = !inDouble
		}
		b.WriteByte(ch)
		if ch == ';' && !inSingle && !inDouble {
			out = append(out, b.String())
			b.Reset()
		}
	}
	if strings.TrimSpace(b.String()) != "" {
		out = append(out, b.String())
	}
	return out
}
```

Then apply `addColumnStmt` only to statements whose trimmed prefix begins with `ALTER TABLE`, or replace the regexp path with a small SQL tokenizer that preserves original byte ranges while ignoring comments and quoted strings.

## r1 Closure Verification

### [full-sec:r1-1] payout RPC URL validation - CLOSED

- Runtime `Validate()` rejects missing RPC URLs and calls `validatePayoutRPCURL` for both primary and secondary at `phase4-coordinator/internal/config/config.go:1069` and `phase4-coordinator/internal/config/config.go:1073`.
- Runtime validation enforces `https`, rejects userinfo, rejects loopback/private/link-local/unspecified IP literals, and leaves hostnames unresolved for TLS/SPKI trust at `phase4-coordinator/internal/config/config.go:1280`.
- Runtime distinct-host validation uses `strings.EqualFold(priURL.Hostname(), secURL.Hostname())` at `phase4-coordinator/internal/config/config.go:1077`.
- Deploy gate resolves `env:NAME` values when set, defers unset env refs to runtime, mirrors URL validation, and checks same-host only when both raw values are inline literals at `phase4-coordinator/dist/check-deploy-config.sh:333` and `phase4-coordinator/dist/check-deploy-config.sh:396`.
- Bypass probes on the deploy gate rejected `https://0.0.0.0:8545`, `https://10.0.0.1:8545`, `https://[::1]:8545`, `https://[fe80::1]/`, `https://[::ffff:127.0.0.1]/`, userinfo including encoded-userinfo, `http://host.com`, and `http://host.com?proto=https`.
- Hostnames, including the unicode-confusable hostname probe, pass through by design; runtime TLS/SPKI is the documented trust root. `phase4-coordinator/internal/payout/rpc.go:191` returns `SPKI pin mismatch` on wrong leaf SPKI when pinning is configured.

### [full-sec:r1-2] signer zeroize defer - CLOSED

- `LoadLocalFileSigner` places the zeroize defer immediately after successful `gcm.Open` at `phase4-coordinator/internal/payout/signer.go:140`, before the malformed-length check at `phase4-coordinator/internal/payout/signer.go:155`.
- The function constructs `secp256k1.PrivKeyFromBytes(pt)` at `phase4-coordinator/internal/payout/signer.go:158`; the deferred wipe fires on function return after the signer is constructed. No redundant inline success-path wipe remains.

## New Security Probes

### A. Halt-State Security Composition - PASS

- Fresh allocation/broadcast gate lands after the `BEGIN IMMEDIATE` transaction commit and post-commit `SelfFence`, but before `BroadcastBoth`, at `phase4-coordinator/internal/payout/runner.go:1126` through `phase4-coordinator/internal/payout/runner.go:1155`.
- Persisted-byte rebroadcast gate lands after `SelfFence` and before `BroadcastBoth` at `phase4-coordinator/internal/payout/runner.go:789` through `phase4-coordinator/internal/payout/runner.go:800`.
- Claim gate lands before `ClaimPayoutReady` at `phase4-coordinator/internal/payout/runner.go:1297`.
- Repeated halt attacks cannot clear halt in-process; `IsHalted` is backed by process-local `atomic.Bool`, and code comments/documentation require operator restart to clear it at `phase4-coordinator/internal/payout/runner.go:207`.
- `payout_chain_balance_drift_negative` is a hardcoded reason emitted by the chain-balance worker at `phase4-coordinator/internal/payout/reconcile.go:457`; the reason logged by runner/admin observability is not secret-bearing.

### B. validatePayoutRPCURL Bypass Attempts - PASS

- IPv6 link-local and IPv4-mapped IPv6 loopback were rejected by deploy gate probes.
- DNS rebinding via hostname is intentionally out of config-time scope; SPKI pinning is the TLS-time defense.
- Unicode confusables are intentionally out of URL validation scope; SPKI pinning is the trust root.
- Encoded userinfo and fake HTTPS query parameters were rejected.

### C. Admin Halt-Bypass Observability - PASS

- Endpoint names passed to `withHaltObservability` are route-local string literals at `phase4-coordinator/internal/payout/mux.go:335`, `phase4-coordinator/internal/payout/mux.go:343`, `phase4-coordinator/internal/payout/mux.go:348`, `phase4-coordinator/internal/payout/mux.go:353`, and `phase4-coordinator/internal/payout/mux.go:355`.
- `withHaltObservability` only checks `runner.IsHalted()`, emits observability, and calls `next`; it does not read or mutate request/response bodies at `phase4-coordinator/internal/payout/mux.go:380`.
- Reason comes from `Runner.HaltReason()`, set only by `RequestHalt`, at `phase4-coordinator/internal/payout/runner.go:191` and `phase4-coordinator/internal/payout/runner.go:218`.

### D. Migration ADD COLUMN Regex - FAIL

See `[full-sec:r2-1]`.

### E. govulncheck + race + secrets scan - PASS

- `govulncheck ./...`: no vulnerabilities found in called code; 0 called vulnerabilities, 0 imported-package vulnerabilities, 17 required-module vulnerabilities not called.
- `go test -race -count=1 ./...`: passed all `phase4-coordinator` packages.
- Targeted r1 surface secret scan: no hardcoded production secrets or newly leaked bearer/private-key/raw-signed-tx log lines found.

### F. OWASP Top 10 Deltas

- A01 Broken Access Control: PASS for reviewed deltas. Admin endpoints remain operator-key protected; route names used in halt observability are hardcoded.
- A02 Cryptographic Failures: PASS. Signer plaintext is wiped via defer after successful decrypt; SPKI pinning remains the runtime trust root for hostname RPC URLs.
- A03 Injection: PASS for URL and log-injection probes; no user-controlled endpoint name in halt observability. Migration SQL scanner issue is tracked under A04 because migrations are trusted embedded assets, not user input.
- A04 Insecure Design: MEDIUM finding `[full-sec:r2-1]` for raw regex scanning of SQL comments/string literals.
- A05 Security Misconfiguration: PASS for payout RPC URL validation closure.
- A06 Vulnerable Components: PASS for called code via `govulncheck`.
- A07 Authentication Failures: PASS for reviewed deltas; operator-key middleware uses constant-time comparison and halt observability does not weaken auth.
- A08 Integrity Failures: PASS for reviewed deltas; embedded migrations are the relevant trust boundary, with `[full-sec:r2-1]` as a parser robustness gap.
- A09 Logging/Monitoring Failures: PASS. Halt and admin-while-halted events include static/non-secret reason and endpoint fields; no raw signed tx/private key/bearer leaks found.
- A10 SSRF: PASS for payout RPC URL validation closure; hostnames defer to SPKI by design.

## Security Checklist

- [x] No hardcoded production secrets found in reviewed r1 surface
- [x] All reviewed payout RPC inputs validated for https/userinfo/internal-IP literals
- [x] Injection prevention verified for reviewed URL/log surfaces
- [x] Authentication/authorization verified for reviewed admin halt-observability route deltas
- [x] Dependencies audited with `govulncheck ./...`
- [x] Race suite passed with `go test -race -count=1 ./...`
- [ ] Migration `ADD COLUMN` scanner ignores comments and quoted string literals
