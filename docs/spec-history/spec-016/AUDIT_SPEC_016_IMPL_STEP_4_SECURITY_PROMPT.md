# IMPL audit prompt — SPEC-016 Step 4, **SECURITY REVIEW lane, round 1**

Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016
Step 4 IMPL — round 1.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_4_PROMPT.md`. HEAD: `dbf7e78`.

## Threat models

Step 4 introduces the SIGHUP-reloadable tuning namespace, the
chain-balance worker (the fake-funding detector), the §7.3
provider read endpoint, and the deploy gate. The adversary
model:

1. **Operator-key-compromised attacker with config write.** Can
   they widen `payout.tuning.confirmation_blocks` to 1 to bypass
   re-org safety, OR raise `payout.tuning.max_rows_per_run` to
   bypass cap rate-limiting? The §6.5 bound matrix is the gate.
2. **Operator-key-compromised attacker with `record-funding`
   API access.** Can they inject fake `source='manual'` rows AND
   evade the chain-balance worker drift detection? Bootstrap
   window is closed in Step 3; chain-balance worker is the next
   defense.
3. **Lying RPC.** Can one RPC fabricate balanceOf to silence the
   negative-drift PAGE?
4. **Provider with valid token but seeking another provider's
   payouts.** The §7.3 path/token mismatch is the gate.
5. **DoS via /providers/{id}/payouts spam.** Per-provider rate
   limiter is the gate.
6. **Deploy with placeholder values.** check-deploy-config.sh
   is the gate.

## High-leverage probes

### A. §6.5 SIGHUP bound bypass

1. **Out-of-bound widening.** SPEC §6.5 names bounds for every
   tuning key. Verify `validateBounds` enforces every one at
   reload time, IDENTICAL to parse time. An attacker who
   raises `confirmation_blocks` to 2 (below the 5 floor) MUST
   be rejected.
2. **Cross-field bypass.** `low_balance_threshold` MUST be
   `<= 2 × per_day_cap`. perDayCap is from the SECURITY
   namespace which is immutable post-start. Verify the
   cross-field check uses the IMMUTABLE perDayCap and not a
   live snapshot.
3. **fsnotify/runtime-debug bypass.** SPEC §6.5 normative: only
   SIGHUP. Verify NO fsnotify watcher and NO debug endpoint
   that triggers reload.
4. **SIGHUP signal hijack.** The signal handler MUST honour
   ONLY `syscall.SIGHUP`. Other signals MUST NOT trigger
   reload.
5. **Reload-mid-cycle race.** TuningProvider uses atomic.Value
   so reads are torn-free, but the runner reads it ONCE per
   cycle at top of RunOnce. Verify no struct field is read
   mid-cycle from the OLD snapshot AND another from the NEW.
6. **`payout_config_reloaded` PAGE field leakage.** Old + new
   are emitted verbatim. Verify SPKI pin values are redacted
   (via `redactSPKI` helper).

### B. §7.4 chain-balance fake-funding evasion

1. **Lying primary RPC returns inflated balanceOf.** primary
   says $10000, secondary says actual $0. Tolerance check
   fires `payout_rpc_disagreement` → skip. The fake-funding
   adversary cannot push the negative drift below tolerance.
2. **Lying primary RPC returns deflated balanceOf.** primary
   says $0, secondary says actual $1000. Same disagreement →
   skip.
3. **BOTH RPCs colluding.** Out of scope per SPEC §4.4 two-RPC
   discipline assumption.
4. **Worker SQL injection in computeExpectedBalance.** The
   hot_wallet address is bound via `?`; verify no string
   concatenation.
5. **Worker bypass via runtime config edit.** `chain_recon_interval`
   is in the security namespace (immutable). An attacker
   editing tuning cannot lengthen the cadence.

### C. §7.3 provider isolation

1. **Token-A reading provider-B's payouts.** Verify
   `tokenProvider != pathProvider` returns 403, NOT 404 or
   200.
2. **SQL injection via provider_id.** The query uses `?` bind;
   verify no string concatenation.
3. **Authorization bearer leakage in logs.** Verify the
   handler doesn't log the bearer.
4. **Cross-provider leak via cancel rows.** `is_cancel_self_transfer = 0`
   filter must be inside the SQL, not Go-side post-filter (a
   race or refactor could drop the Go check).
5. **Per-provider rate-limit bypass via parallel connections.**
   Sliding-window limiter is `sync.Mutex` locked; verify the
   lock is held across the entire prune+check+append sequence.

### D. Deploy-gate bypass

1. **Placeholder via env:NAME with unset NAME.** SPEC: env:
   indirection deferred to runtime is OK. Verify the gate
   accepts this as "ok deferred" (not HARD fail).
2. **Empty-string security field.** Verify the gate rejects
   `hot_wallet_address: ""` (missing-value class).
3. **SPKI pin malformed (non-hex).** Verify the gate rejects
   non-64-hex pins.
4. **Skip when payout.enabled=false.** Verify the entire payout
   block validation is bypassed (no false-positive on a
   coordinator that doesn't run payout).

### E. govulncheck + race tests

- `govulncheck ./...` from `phase4-coordinator/`.
- `go test -race -count=1 ./internal/payout/...`.

## OWASP Top 10 sweep

- A01 Broken Access Control: §7.3 provider-mismatch 403.
- A02 Cryptographic Failures: no new crypto in Step 4. SPKI
  pin display redacted.
- A03 Injection: SQL parameterised; deploy gate input is YAML
  text only.
- A04 Insecure Design: §6.5 bound matrix prevents tuning
  widening; chain-balance worker as fake-funding floor.
- A05 Security Misconfiguration: deploy gate rejects
  placeholders.
- A07 Authentication Failures: 401 missing bearer, 403
  provider mismatch, 429 rate-limited.
- A08 Integrity Failures: TuningProvider atomic snapshot
  prevents partial reload.
- A09 Logging Failures: §6.5 PAGE events per-key + on
  rejection.
- A10 SSRF: no user-controlled outbound URL.

## Output

Write findings to
`specs/SPEC-016-IMPL-STEP_4-security-r1-audit.md`. Standard
structure.

## Discipline

- Wall-clock target: 30-40 min.

=== END PROMPT ===
```
