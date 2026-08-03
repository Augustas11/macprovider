# IMPL audit prompt — SPEC-016 Step 2, **SECURITY REVIEW lane, round 3**

Round 3 against fix-pass commit `c761e55` on `impl/spec-016`.
Master shared context: `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`.

Fire via:

```
omc ask codex --agent-prompt security-reviewer --prompt "<this file's body>"
```

Read-only.

---

```
=== BEGIN PROMPT ===

You are the security-reviewer lane (2 of 3) auditing SPEC-016
Step 2 IMPL — round 3. Round 2 returned 0/0/1 MEDIUM/1 LOW. The
fix-pass `c761e55` addresses both. Your r3 job: verify closures
hold + run the high-leverage adversarial probe matrix one final
time.

## Shared context

See `specs/AUDIT_SPEC_016_IMPL_STEP_2_PROMPT.md`. HEAD: `c761e55`.

## r2 findings to verify CLOSED

### [sec:r2-2.1] MEDIUM — KEK zeroize on error paths

Verify `loadPayoutSigner` at cmd/coordinator/main.go:
- Production path: `defer` block immediately after
  `resolvePayoutKEK()` so the for-range-zeroize fires on ALL
  return paths (LoadLocalFileSigner success + failure).
- Dev path: `defer` block immediately after `hexDecode(rawHex)`
  so the for-range-zeroize fires on `NewLocalFileSignerFromKey`
  failure too.

Probe: simulate a wrong-KEK decrypt failure via temp wallet
file. After the function returns the error, the in-memory `kek`
slice should be all zeros (would require a debug hook to verify
in practice — code-trace sufficient for the audit).

### [sec:r2-2.2] LOW — constant-time bearer compare

Verify `operatorKeyMiddleware`:
- `subtle.ConstantTimeCompare([]byte(raw), []byte(operatorKey))`
- Length pre-check up-front so unequal-length tokens don't reach
  the constant-time path (preserves the property without
  introducing a length-leak side-channel)
- Empty raw still → 401

## Regression sweep

Re-run the high-leverage probes from r2:
- `govulncheck ./...`
- `go test -race -count=1 ./internal/payout/...`
- 8-conn PRAGMA `synchronous=FULL` static check
- TwoRPCs cold-start ±1 enforcement
- Two-RPC verifyChainSideTransfer still rejects fabricated logs
  on either side
- pollCancelOnce now ALSO rejects USDC logs on either side
  (Step 2 r2 closure)
- LoadLocalFileSigner still doesn't leak key bytes in error msgs

## Output

Write findings to `specs/SPEC-016-IMPL-STEP_2-security-r3-audit.md`.

## Discipline

CLEAN requires r2 closures VERIFIED + zero new findings.
BLOCK only on new CRITICAL or HIGH regression.

You may take up to 25 min wall-clock.

=== END PROMPT ===
```
