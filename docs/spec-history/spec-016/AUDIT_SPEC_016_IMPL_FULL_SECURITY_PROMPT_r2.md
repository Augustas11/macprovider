# IMPL audit prompt — SPEC-016 FULL implementation, **SECURITY REVIEW lane, r2**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r2.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing the FULL
SPEC-016 implementation — round 2.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r2.md`. HEAD: `3b41c0d`.
r1 found 1 HIGH + 1 LOW; both closed in fix-pass.

## r1 closure verification

### [full-sec:r1-1] payout RPC URL validation

Walk `validatePayoutRPCURL` in internal/config/config.go and
`validate_payout_rpc_url` in dist/check-deploy-config.sh. Verify:
- BOTH enforce: https-only, no userinfo, no loopback/private/
  link-local/unspecified IP literals.
- The runtime caller (`Validate()` in config.go) rejects when
  primary == secondary hostname (case-insensitive).
- The deploy gate also rejects same-hostname when both URLs are
  inline literals (not env: indirected).
- Hostnames pass through (DNS not resolved at config-validation time;
  SPKI pin is the runtime trust root).
- Edge cases:
  - `https://0.0.0.0:8545` — rejected as unspecified
  - `https://10.0.0.1:8545` — rejected as private
  - `https://[::1]:8545` — rejected as loopback (IPv6)
  - `https://user:pass@host.com` — rejected as userinfo
  - `http://host.com` — rejected as non-https
- The deploy gate handles env:NAME values correctly (defer to
  runtime when env var unset; resolve + validate when set).
- The deploy gate's distinct-host check skips when either URL is
  env:NAME (defers correctly).

### [full-sec:r1-2] signer zeroize defer

Walk LoadLocalFileSigner in signer.go. Verify:
- `defer func() { for i := range pt { pt[i] = 0 } }()` is placed
  IMMEDIATELY after a successful `gcm.Open` (before the length
  check) so the malformed-length error path also wipes pt.
- The success path no longer has a redundant in-line zeroize loop.
- secp256k1.PrivKeyFromBytes(pt) is called before defer fires
  (defer runs at function return — verify the privkey is
  constructed and the function returns the privkey-backed signer
  before pt is wiped).

## New security probes

### A. Halt-state security composition

The r1 fix added IsHalted gates at 4 chain-write sites. Verify:
- An attacker who can call RequestHalt mid-cycle cannot use the
  halt as a partial-write attack — i.e. the gate at
  allocateBuildSignBroadcast lands AFTER the BEGIN IMMEDIATE
  COMMIT, so the attempt row persists (no half-written state)
  but no broadcast happens. The next non-halted cycle replays via
  rebroadcastAndPoll. Is this safe under repeated halt/unhalt
  attacks? (The runner halt is process-local atomic.Bool; clearing
  requires process restart, so an attacker who can call RequestHalt
  cannot also clear it without operator action.)
- The chain-balance worker calls RequestHalt with reason
  "payout_chain_balance_drift_negative". The reason is included
  in payout_runner_halted_skipping_rows + payout_admin_invoked_
  while_halted emits. Verify no secret leaks via the reason string.

### B. validatePayoutRPCURL bypass attempts

Try to find a URL that should be rejected but isn't:
- IPv6 link-local: `https://[fe80::1]/`
- IPv4-mapped IPv6 loopback: `https://[::ffff:127.0.0.1]/`
- DNS rebinding via hostname that resolves to loopback at runtime
  (not detected at config time — SPKI pin is the defense; verify
  the SPKI pin failure mode is documented as the intended TLS-time
  check).
- Unicode confusables in hostname (`https://googlе.com` with
  Cyrillic е) — out of scope for URL validation; SPKI is the trust.
- Userinfo with encoded characters: `https://%75ser:pass@host/`
- `http://host.com?proto=https` — URL parser rejects via scheme check.

### C. Admin halt-bypass observability

Walk `withHaltObservability` + `Runner.EmitAdminInvokedWhileHalted`.
Verify:
- The endpoint name passed in is hardcoded per route (not user-
  controlled), so no injection into the emit.
- The reason field comes from `Runner.HaltReason()` which is
  set only by RequestHalt — not user-controlled.
- The wrapper does NOT mutate request/response bodies.

### D. Migration ADD COLUMN regex

Walk `addColumnStmt` regex in migrations.go. Verify:
- The regex does NOT match commented-out ALTER statements (e.g. a
  `-- ALTER TABLE x ADD COLUMN y` comment shouldn't trigger a
  PRAGMA lookup).
- The regex does NOT match an ALTER inside a string literal.
- The regex captures table + column names correctly for the
  identifier grammar SQLite accepts.

### E. govulncheck + race + secrets scan

- `govulncheck ./...` from `phase4-coordinator/`
- `go test -race -count=1 ./...`
- Secret-leak pattern scan across the r1 fix-pass surface — any
  new log line with `Bearer`, hex private key, raw signed tx?

### F. OWASP Top 10 deltas

For r1 changes, re-evaluate:
- A05 Security Misconfiguration (URL validation closed → PASS)
- A10 SSRF (URL validation closed → PASS)
- A02 Cryptographic Failures (signer zeroize closed → PASS)
- A04 Insecure Design (halt-mid-cycle closed)

## Output

Write findings to `specs/SPEC-016-IMPL-FULL-security-r2-audit.md`.
Standard structure. If 0/0/0/0 — declare CONVERGENT.

## Discipline

- Verify r1 closures hold. Probe for bypass paths.
- Wall-clock target: 25-35 min.

=== END PROMPT ===
```
