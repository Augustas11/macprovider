# IMPL audit prompt — SPEC-016 Step 4, **SECURITY REVIEW lane, round 5**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r5.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 2) auditing SPEC-016 Step 4
IMPL — round 5. Architecture lane CONVERGED at r4.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r5.md`. HEAD: `bc1409f`.

The r4 audit returned 0/0/1/1 — BLOCK MERGE on the convergent
MEDIUM (with code). r4 fix-pass landed at `bc1409f`. Verify
closure + look for new attack surface + confirm no regression.

## High-leverage probes (r5)

### A. r4 closure verification

1. **[sec:r4-1] CONVERGENT MEDIUM — YAML-load failure structured emit.**
   Verify `startPayoutSIGHUPListener` YAML-load error emits the
   §7.1 field set:
   - `key=yaml_parse` (literal, not a leaked YAML path)
   - `attempted_value=config_load_failed` (literal, NOT raw YAML)
   - `bound` (e.g. "valid payout.tuning YAML")
   - `actor=operator_key:coordinator` (or similar non-bearer)
   - `ts_utc` RFC3339Nano
   - `severity=PAGE`
   Verify no path emits the raw YAML body (would leak secrets from
   `payout.security.*` or `auth.*` sections that share the file).

2. **[sec:r4-2] LOW — runbook §6 corrections.** Verify:
   (a) "<new 64-hex-char SHA-256 SPKI>" replaces "<new base64 SHA-256>"
   (b) openssl command produces the correct hex output
   (c) Clear language about `CloseIdleConnections` only draining
       idle conns; in-flight RPCs may complete on old TLS session

### B. No regressions of r1-r3 security closures

Spot-check each closure file:
- r1: payout-runbook hot-wallet provisioning + key rotation
- r1: deploy gate keys (low_balance, low_native)
- r1: payout env:NAME resolution
- r2: RunNowController rate-limit + payout_run_now_invoked event
- r2: SPKI pin live-read at TLS verify time
- r2: AST forbidden set exact identifiers
- r3: CloseIdleConnections + SIGHUP wiring
- r3: payout_config_reloaded / _rejected §7.1 field names (bound
  violation path)

### C. New attack surface in the r4 delta

1. **BoundViolationError rename.** New `Actor` field on the struct.
   Verify no code path stores a bearer / token / sensitive value in
   `Actor`. It should be a stable identifier (`operator_key:coordinator`).
2. **YAML-load failure emit.** Sanitized literal in `attempted_value`
   was the audit recommendation. Verify the implementation matches.
3. **Tests.** New tests use `httptest` + fake transports. Verify the
   test fixtures don't accidentally hardcode any prod credentials.

### D. govulncheck + race + secrets scan

- `govulncheck ./...` from `phase4-coordinator/`.
- `go test -race -count=1 ./internal/payout/...`.
- Secrets scan over the r4 fix-pass: `git show bc1409f` and grep for
  patterns like `BEGIN PRIVATE KEY`, hex strings of length 64+
  (potential keys), `password=`, `token=`, etc.

### E. OWASP Top 10 sweep — r5 delta

- A02 Cryptographic Failures: SPKI runbook encoding corrected
  (LOW closed).
- A05 Security Misconfiguration: runbook in-flight RPC semantics
  documented (LOW closed).
- A08 Software/Data Integrity Failures: BoundViolationError shape
  change preserves the §7.1 wire contract.
- A09 Logging Failures: YAML-load failure now emits structured
  fields per §7.1 (MEDIUM closed). Verify no raw YAML body in any
  log path.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-security-r5-audit.md`. Standard
structure.

**If 0/0/0/0 — declare CONVERGENT.** This is the FINAL audit round
before PR-open.

## Discipline

- Wall-clock target: 25-35 min.

=== END PROMPT ===
```
