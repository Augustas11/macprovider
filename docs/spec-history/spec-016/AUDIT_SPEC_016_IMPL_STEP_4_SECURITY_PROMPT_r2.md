# IMPL audit prompt — SPEC-016 Step 4, **SECURITY REVIEW lane, round 2**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r2.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016 Step 4
IMPL — round 2.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT_r2.md`. HEAD: `dd72e0e`.

The r1 audit returned 0 CRITICAL / 1 HIGH / 3 MEDIUM / 0 LOW.
The r1 findings file is at
`specs/SPEC-016-IMPL-STEP_4-security-r1-audit.md`. Verify each
finding is closed AND look for new attack surface introduced by
the fix-pass.

## Threat model (unchanged from r1)

1. **Operator-key-compromised attacker with config write.** Can they
   widen `payout.tuning.confirmation_blocks` to 1 to bypass re-org
   safety? Can they raise `max_rows_per_run` to bypass cap
   rate-limiting? The §6.5 bound matrix is the gate — verify it's
   re-applied identically in the tuning-only loader path.
2. **Operator-key-compromised attacker with `record-funding` API
   access.** Can they inject fake `source='manual'` rows AND evade
   the chain-balance worker drift detection? Now that drift triggers
   a REAL halt, verify the halt actually prevents subsequent payout
   cycles.
3. **Lying RPC.** Can one RPC fabricate balanceOf to silence the
   negative-drift PAGE?
4. **Provider with valid token but seeking another provider's
   payouts.** The §7.3 path/token mismatch is the gate.
5. **DoS via /providers/{id}/payouts spam.** Per-provider rate
   limiter is the gate.
6. **Deploy with placeholder values.** check-deploy-config.sh is the
   gate — now with low_balance/low_native required.

## High-leverage probes (r2)

### A. Halt primitive — verify drift halt is real

1. **Negative-drift halt.** Trigger `ChainBalanceWorker` negative
   drift. Verify `runner.RequestHalt` is called. Verify the next
   `RunOnce` returns `ErrRunnerHalted` without processing rows.
   Verify the PAGE event is emitted exactly once.
2. **Halt persistence across cycles.** Once halted, subsequent
   cycles MUST also skip. Process restart is required to clear.
   Verify no admin endpoint (other than restart) clears the halt.
3. **Race: halt set mid-cycle.** RequestHalt called WHILE RunOnce is
   in flight. The current cycle should be allowed to complete (or
   abort cleanly — verify what the implementation does); the NEXT
   cycle MUST skip.
4. **Run-now bypass.** Verify admin run-now returns 409 when halted,
   not 200 with skipped cycle. The 409 body MUST name the halt
   reason so the operator runbook can act.

### B. SIGHUP tuning-only loader — verify security namespace untouched

1. **Verify `LoadPayoutTuningOnly` does NOT read payout.security.**
   Inspect the function: it must parse YAML into a struct with only
   payout.tuning.* fields. No reflection into security keys.
2. **Verify env: resolution is NOT triggered on SIGHUP.** A SIGHUP
   while `MACPROVIDER_PAYOUT_WALLET_KEK` is missing/changed MUST
   NOT cause the reload to fail. Security KEK is process-start
   only.
3. **Verify SIGHUP handler does not log security values.** Even
   under accept/reject/error paths, no security field should appear
   in log output.
4. **Bound matrix re-applied identically.** A YAML with
   `confirmation_blocks: 1` SIGHUP'd in MUST be rejected with the
   same error as parse-time validation. No drift between paths.

### C. resolveEnv payout.security coverage

1. **Each payout.security string field resolves env:** Verify
   `rpc_url_primary`, `rpc_url_secondary`, `hot_wallet_address`,
   `encrypted_wallet_path` all expand env:NAME at startup.
2. **Unset env variable.** When `env:RPC_URL_PRIMARY` is set but
   `RPC_URL_PRIMARY` env var is unset, behavior must be a HARD
   error (not silently empty). Verify.
3. **No new shell-injection surface.** Resolution code must not
   evaluate shell metacharacters; ensure pure env-variable lookup.

### D. Deploy gate

1. **low_balance_threshold + low_native_threshold required.** A
   config with `payout.enabled: true` but missing either key MUST
   HARD-fail.
2. **Zero values accepted.** `low_balance_threshold: 0` MUST pass
   (disables that probe).
3. **No regression on existing keys.** All r1 deploy-gate checks
   still fire.

### E. AST static check — verify forbidden set

1. The forbidden identifier set is genuinely defended. Try (in your
   head, not by editing the file) adding `payout.security.HotWalletAddress`
   as a reference in `config_tuning.go` — does the test catch it?
2. Selector expressions like `cfg.Security.HotWalletAddress` MUST
   be caught.
3. String literals like `"payout.security.foo"` MUST be caught.

### F. Run-now-halted 409 semantics

1. **Does 409 leak the halt reason?** The body returns reason text.
   If reason includes internal state (e.g. "drift -123456 USDC
   base units"), that's debatable info disclosure. Verify what's
   in the reason string and whether it's acceptable.
2. **Does the 409 reach the operator audit log?** The runbook
   depends on this being observable.

### G. govulncheck + race

- `govulncheck ./...` from `phase4-coordinator/`.
- `go test -race -count=1 ./internal/payout/...`.

## OWASP Top 10 sweep (r2 delta)

- **A04 Insecure Design.** Drift detection now halts the runner —
  is this gate complete? Are there OTHER paths into the payout
  cycle that bypass IsHalted?
- **A05 Security Misconfiguration.** Deploy gate now covers
  low_balance + low_native. Are there any other §6.5 fields that
  should be in the gate but aren't?
- **A08 Integrity Failures.** SIGHUP tuning-only loader: any path
  where a partial reload (some keys accepted, some rejected) could
  land?

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-security-r2-audit.md`. Standard
structure.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
