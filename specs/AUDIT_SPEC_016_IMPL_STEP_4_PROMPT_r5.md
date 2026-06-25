# IMPL audit prompt — SPEC-016 Step 4, **r5 shared context (code + security only)**

Architecture lane declared **CONVERGENT** at r4. Only code + security
re-audit at r5. Per [[feedback-codex-only-audits]] discipline.

Master shared-context block for the round-5 fan-out:
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_CODE_PROMPT_r5.md`
- `specs/AUDIT_SPEC_016_IMPL_STEP_4_SECURITY_PROMPT_r5.md`

Both lanes are **read-only**.

## Round history

| Round | Code | Security | Arch | Verdict |
|-------|------|----------|------|---------|
| r1 | 0/2/3/1 | 0/1/3/0 | 1/2/1/2 | BLOCK |
| r2 | 0/1/3/0 | 0/1/1/0 | 0/2/0/0 | BLOCK |
| r3 | 0/1/3/1 | 0/1/1/0 | 0/1/1/0 | BLOCK |
| r4 | 0/0/4/1 | 0/0/1/1 | **0/0/0/0** | **arch CONVERGENT**; code COMMENT; security BLOCK MERGE |

## What changed between r4 and r5 (fix-pass commit `bc1409f`)

### CONVERGENT MEDIUM closure [code:r4-1] / [sec:r4-1]

`startPayoutSIGHUPListener` YAML-load failure path now emits the
structured `payout_config_reload_rejected` field set per SPEC §7.1:
`key=yaml_parse, attempted_value=config_load_failed, bound, actor,
ts_utc, severity=PAGE`. Sanitized literal used in `attempted_value`
to prevent secret leakage. New unit test
`TestEmitRejected_YAMLParseFailure_EmitsStructuredS71Fields`.

### MEDIUM closures (code-only)

- **[code:r4-2]** — `payout_chain_balance_rpc_disagreement` event
  now includes `hot_wallet`. New
  `TestChainBalanceWorker_RPCDisagreementEmitsHotWallet`.
- **[code:r4-3]** — new `TestHTTPRPCClient_CloseIdleConnections`
  (nil-receiver guard + real-transport drain) +
  `TestSIGHUPCloseIdleComposition` (table-driven: SPKI change → both
  closed; non-SPKI change → neither).
- **[code:r4-4]** — new
  `TestRunner_RunOnce_StaleProducerUsesLiveSnapRunInterval` —
  seeds stale row at 31m (between live threshold 30m and startup
  threshold 180m); asserts stale row produced. Regression-locks
  the [arch:r3-4.1] fix.

### LOW closures

- **[code:r4-5]** — `BoundViolationError` fields renamed:
  `Key→Field`, `AttemptedValue→Attempted`; new `Actor` field. Wire
  contract emit names (`key, attempted_value`) unchanged per §7.1.
- **[sec:r4-2]** — payout-runbook §6 corrected: SPKI encoding
  "<new 64-hex-char SHA-256 SPKI>" (not base64); openssl command
  updated; `CloseIdleConnections` in-flight RPC semantics clarified.

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `bc1409f impl(016): Step 4 r4 fix-pass — final convergence closures`
- Step 4 is the LAST step. After r5 convergence, the single PR opens.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit
  `f0152c0`.

## What the r5 lane MUST check

1. **r4 closure verification.** For each of the 6 r4 findings, verify
   the fix matches SPEC and is fully closed.
2. **No regressions of r1/r2/r3/r4 closures.** Walk the audit-history
   linked files in `specs/SPEC-016-IMPL-STEP_4-*-r*-audit.md` and
   spot-check each finding is still closed.
3. **§7.1 field set drift sweep — final pass.** Walk every Step 4
   event in `specs/SPEC-016-payout-pipeline.md:3712-3732` and
   verify the implementation emits the §7.1-mandated fields.
4. **PR-opening readiness.** If your lane returns 0/0/0/0, declare
   CONVERGENT and confirm the PR-readiness matrix is OK.

## Severity guidance + BLOCK rule (unchanged)

- CRITICAL — money-path defect or data-loss class.
- MAJOR — confirmed bug observable in production.
- MEDIUM — confirmed bug not directly observable but breaks audit
  invariant.
- LOW — cosmetic / docs / minor consistency.

BLOCK only on: new CRITICAL, regression of an r1/r2/r3/r4 finding, or
a SPEC normative violation a future step cannot unwind.

## Output format

Each lane writes findings to its own file:
- `specs/SPEC-016-IMPL-STEP_4-code-r5-audit.md`
- `specs/SPEC-016-IMPL-STEP_4-security-r5-audit.md`

Standard structure: Verdict, counts, one section per finding with
`[code:r5-X.Y]` / `[sec:r5-X.Y]` label + severity + evidence
(file:line) + recommended fix.

**If the lane returns 0/0/0/0, declare CONVERGENT in the output
file.**
