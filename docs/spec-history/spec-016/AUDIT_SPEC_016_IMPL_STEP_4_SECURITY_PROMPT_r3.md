# IMPL audit prompt — SPEC-016 Step 4, **SECURITY REVIEW lane, round 3**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r3.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016 Step 4
IMPL — round 3.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r3.md`. HEAD: `fe6a699`.

The r2 audit returned 0 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW (BLOCK
MERGE). The r2 fix-pass landed at `fe6a699`. Verify r2 closure +
look for new attack surface.

## Threat model (carried from r2)

1. **Operator-key-compromised attacker.** Run-now spam now gated by
   the live `RunNowMinInterval` — verify the controller's mutex
   composition is correct and the 429 path can't be raced.
2. **Lying RPC.** Now that SPKI pins are live-read, can a SIGHUP-time
   race introduce a wrong pin temporarily?
3. **Cert-rotation observability.** Operators relying on
   `payout_config_reloaded` PAGE to drive their cert-rotation
   runbook should now get a TRUE reload (the verifier actually
   honors the new pin). Verify.
4. **DoS via /providers/{id}/payouts spam.** Unchanged from r2.
5. **Deploy gate.** Unchanged from r2.

## High-leverage probes (r3)

### A. RunNowController security

1. **Race on Allow + RunOnce.** The mutex is held across the
   timestamp check + lastAccepted update. A request that enters
   the lock during another's RunOnce should see lastAccepted as
   committed — verify it's NOT held across the actual RunOnce call
   (which is long-running). If it IS held, that's a serialization
   bug; if it's NOT, that's a TOCTOU window where a second request
   could pass the rate-limit check while RunOnce is still running.
   Determine which design is correct and verify.
2. **Event emission for failed paths.** SPEC §7.1 expects emission
   on every invocation. Verify rate-limited, halted, AND
   cycle-in-flight outcomes all emit. The rate-limited path MUST
   emit before returning 429 (auditors need the signal).
3. **No bearer in event payload.** Verify the actor field is the
   operator_key IDENTIFIER, not the secret value.
4. **No timing oracle.** The mutex serializes all requests; the
   time-to-return is partially determined by whether the prior
   request was rate-limited. Probably acceptable but worth noting.

### B. SPKI live-read security

1. **Cert-rotation race.** Operator updates the pin via SIGHUP
   while an outbound RPC is in flight (TLS handshake just
   completed). The in-flight request completes against the OLD
   pin. The next request (new handshake) verifies against the new
   pin. This is correct semantically. Verify.
2. **Connection pool retention.** If the HTTP client pools an
   established TLS connection, the verifier was only called once
   at establish-time. A SIGHUP to update the pin does NOT
   invalidate that pooled connection. Is this an integrity gap?
   Flag it. Recommended fix: close idle TLS connections on
   reload, OR document the limitation in the runbook.
3. **Empty-pin downgrade.** A SIGHUP that sets the pin to "" must
   be treated as "no pinning" — operator-explicit. Verify the
   bound matrix accepts empty AND that the verifier skips when
   empty. Otherwise a partial-config could deploy with empty pins
   that silently disable pinning.

### C. AST forbidden set thoroughness

1. **PayoutSecurityConfig reflection.** The set must match the
   actual struct fields. Pull
   `phase4-coordinator/internal/config/config.go` PayoutSecurityConfig
   and cross-check.
2. **Catch SelectorExpr too.** `cfg.Security.HotWalletAddress`
   must trip the check. Verify the AST walker traverses
   `*ast.SelectorExpr`.
3. **Catch string literals.** `"payout.security.foo"` must trip.

### D. §7.1 alert field name compliance

1. Field-name drift is now an audit risk class — log consumers and
   compliance pipelines depend on §7.1 names. Verify the fix
   matches every entry in the SPEC table 3712-3732.
2. NEW event `payout_run_now_invoked` adds `outcome` (defensive).
   Is this a violation of the §7.1 normative contract OR a
   defensive extension? Make a recommendation.

### E. govulncheck + race

- `govulncheck ./...` from `phase4-coordinator/` — fresh run.
- `go test -race -count=1 ./internal/payout/...`.

## OWASP Top 10 sweep (r3 delta)

- **A04 Insecure Design.** Run-now rate limit now enforced — verify.
  SPKI live-read closes the r2 finding — verify with the
  pool-retention caveat above.
- **A05 Security Misconfiguration.** SPKI pin reload + run-now
  now both reflect in production. Any partial-reload state where
  one tuning key landed but another didn't?
- **A08 Integrity Failures.** Connection pool may retain stale
  SPKI verification — confirm whether this is a real integrity
  gap.
- **A09 Logging Failures.** payout_run_now_invoked emit field
  contract.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-security-r3-audit.md`. Standard
structure.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
