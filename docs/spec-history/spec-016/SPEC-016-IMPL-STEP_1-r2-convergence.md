# SPEC-016 IMPL Step 1 — round 2 CONVERGED

Three-lane parallel codex audit fan-out converged at round 2.

## Final scoreboard

| Lane         | r1 result      | r2 result | Final verdict |
|--------------|----------------|-----------|---------------|
| Code         | 1 C / 0 M / 1 Md / 0 L → BLOCK | 0 / 0 / 0 / 0 → CLEAN | code:1.1 CLOSED · code:1.2 CLOSED |
| Security     | 0 / 0 / 0 / 1 L → FIX-OPTIONALLY | 0 / 0 / 0 / 0 → CLEAN | sec:1.1 deferred to Appendix B |
| Architecture | 0 / 1 M / 2 Md / 0 L → FIX-THEN-PROCEED | 0 / 0 / 0 / 0 → CLEAN | arch:1.1 deferred to SPEC v0.1.22 · arch:1.2 CLOSED · arch:1.3 CLOSED |

**Step 1 audit loop CONVERGED at 0 CRITICAL / 0 MAJOR / 0 MEDIUM across all three lanes combined.**

The audit-loop discipline at
`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md` §3 +
`[[feedback-build-audit-loop]]` is satisfied. Step 1 IMPL is
green to proceed to Step 2 on the same `impl/spec-016` branch.

## Round-by-round narrative

### Round 1

Three lanes fired in parallel via `omc ask codex --agent-prompt
{code-reviewer,security-reviewer,architect}` against Step 1 IMPL
commit `1df0235` (SPEC v0.1.21 LOCKED).

**Code lane (BLOCK).** Two findings:

- `[code:1.1] CRITICAL` — rotation handler at `addresses.go:408`
  unconditionally set `payout_allowed=1`; a compliance-disabled
  provider could rotate and silently re-enable themselves. Real
  money-out gate bypass.
- `[code:1.2] MEDIUM` — `DecodeNonce32` accepted both `0x` and
  `0X` but the anti-replay storage key was derived from the
  request-side string, splitting the same signed nonce into two
  PK rows.

**Security lane (FIX-OPTIONALLY).** Zero critical / major /
medium across the full adversarial probe matrix. The single LOW
was a defensive-coding suggestion: detect schema drift on
`CREATE … IF NOT EXISTS` migrations. Independent ethers.js
EIP-712 cross-check vector was accepted by the Go verifier
(digest `cc905f9e...733f8b4e` matched). 8-connection PRAGMA
probe confirmed all connections run `synchronous=FULL=2`.

**Architecture lane (FIX-THEN-PROCEED).** Three findings:

- `[arch:1.1] MAJOR` — SPEC v0.1.21 §4.7 reorg-poll query
  references `payout_attempts.id` and `payout_external_id`, but
  §4.5 schema (Step 1's migration) defines neither. **SPEC drift,
  not IMPL code drift.** A Step 2 author writing the literal
  query would hit a "no such column: id" error at prepare time.
- `[arch:1.2] MEDIUM` — `TestImportGraph_BillingDoesNotImportPayout`
  walked only direct imports (`pkg.Imports + pkg.TestImports`).
  A `billing → helper → payout` chain would slip past silently.
- `[arch:1.3] MEDIUM` — Co-residency assertion advertised in
  `addresses.go:97-100` code comment but never implemented —
  comment was a lie.

### Round 1 fix-pass (commit `fc3bf56`)

- `[code:1.1]` — closed. Existing `payout_allowed` is now read
  inside `BEGIN IMMEDIATE`; rotation returns 409
  `payout_not_allowed` when disabled; UPDATE preserves the
  existing flag (no hardcoded `1`). Regression tests:
  `TestServePayoutAddress_RotationPreservesPayoutAllowed_Zero`
  + `_One`.
- `[code:1.2]` — closed. Canonical anti-replay key is now
  `"0x" + hex.EncodeToString(nonce32[:])` derived from decoded
  bytes. Regression test:
  `TestServePayoutAddress_NonceCanonicalisation_0XReplayDefeated`.
- `[arch:1.2]` — closed. `importgraph_test.go` rewritten to DFS
  the in-module dependency graph including `XTestImports`.
  Companion `TestImportGraph_PayoutToBillingPermitted` as
  future-proofing assertion for Step 2's `ClaimPayoutReady` call
  site.
- `[arch:1.3]` — closed. New `topology.go` with
  `PayoutRuntimeTopology` struct + `AssertPayoutRuntimeTopology`
  hook. `setupPayout` invokes it BEFORE building any service.
  Step 2 will tighten `RunnerCoResident=true` + `LinuxRequired=true`.
  Regression tests: `TestAssertPayoutRuntimeTopology_*` (4 cases).
- `[arch:1.1]` — deferred to SPEC v0.1.22 candidate
  (`specs/SPEC-016-IMPL-STEP_1-r1-deferrals.md`). Operator-side
  SPEC author resolves before Step 2 IMPL begins reorg-poll
  query work.
- `[sec:1.1]` — deferred to SPEC-016 Appendix B (operator
  hardening backlog).

### Round 2

Three lanes re-fired against fix-pass commit `fc3bf56` (SPEC
v0.1.21 unchanged). All three returned CLEAN at 0 / 0 / 0 / 0.

**Code lane.** Verified both r1 closures at exact line numbers:

- `addresses.go:410` — SELECT now includes `payout_allowed`.
- `addresses.go:381` — nonce insert ordering correct.
- `addresses.go:433` — 409 short-circuit on `payout_allowed=0`.
- `addresses.go:444` — UPDATE preserves the existing flag.
- `addresses.go:347` — canonical nonce key from decoded bytes.

Test corpus pass: `go test`, `go vet`, `go test -race`, full
coordinator suite, `git diff --check`. No new findings, no
regressions.

**Security lane.** Re-ran the highest-leverage adversarial
probes against the fix-pass tip:

| Probe                                     | Verdict |
|-------------------------------------------|---------|
| Adversary A: stolen token vs disabled row | PASS — 409, no mutation |
| Compliance-gate race posture              | PASS — txn-scoped |
| Nonce rollback side-channel               | PASS — 409 burns nothing (legitimate retry liveness preserved) |
| `0x` / `0X` nonce replay                  | PASS — anti-replay table holds one row |
| `hex.EncodeToString` lowercase guarantee  | PASS — stdlib invariant |
| Empty hot-wallet pin startup              | PASS — fail-fast before listener |
| Malformed hot-wallet pin startup          | PASS — EIP-55 rejects |
| Independent ethers.js EIP-712 vector      | PASS — digest matched |
| 8-conn PRAGMA `synchronous=FULL`          | PASS — all FULL=2 |
| TOCTOU pause re-check                     | PASS — 503 inside txn |
| Hot-wallet self-payment denial            | PASS — `deny.go:46` |
| `v=0/1` signature rejection               | PASS — `eip712.go:177` |

`govulncheck ./...` — 0 reachable vulnerabilities.

**Architecture lane.** Verified all three r1 outcomes:

- `arch:1.1` — DEFERRED-VALIDATED. Codex confirmed SPEC §4.5 vs
  §4.7 column-name drift, validated the deferral target (SPEC
  v0.1.22 amendment).
- `arch:1.2` — CLOSED. `walkImports` DFS-es `Imports`,
  `TestImports`, AND `XTestImports`; uses `visited` for cycles.
- `arch:1.3` — CLOSED. Topology assertion invoked at the right
  point in the startup sequence (after `LoadSecurityConfig`,
  before `NewDenyList` / mux construction).

Step 1 → Step 2 readiness matrix flipped to all READY (with the
§4.7 SPEC drift carried as deferred-validated).

## Forward-looking notes for Step 2

The architecture lane recommended two Step 2 tightenings that
the topology hook already accommodates:

1. Change the `HandlerEnabled && !RunnerCoResident` branch in
   `topology.go:90` from "no error" to a fail-fast error when
   Step 2's runner is wired.
2. Set `LinuxRequired=true` in `setupPayout` when the runner is
   enabled (the `topology.go:83` Linux gate is already in
   place; the call site just needs to flip the bool).

The security lane noted that future Step 3's rate-limit
implementation must preserve §3.3's 429 requirement; the 409
nonce-rollback behavior validated here is rate-limit-sensitive.

## Audit artifacts

Persisted findings (committed):

- `specs/SPEC-016-IMPL-STEP_1-code-r1-audit.md` · 1 CRITICAL + 1 MEDIUM
- `specs/SPEC-016-IMPL-STEP_1-security-r1-audit.md` · 0 / 0 / 0 / 1 LOW
- `specs/SPEC-016-IMPL-STEP_1-arch-r1-audit.md` · 0 / 1 MAJOR / 2 MEDIUM / 0
- `specs/SPEC-016-IMPL-STEP_1-r1-deferrals.md` · arch:1.1 + sec:1.1 deferrals
- `specs/SPEC-016-IMPL-STEP_1-code-r2-audit.md` · 0 / 0 / 0 / 0 CLEAN
- `specs/SPEC-016-IMPL-STEP_1-security-r2-audit.md` · 0 / 0 / 0 / 0 CLEAN
- `specs/SPEC-016-IMPL-STEP_1-arch-r2-audit.md` · 0 / 0 / 0 / 0 CLEAN
- `specs/SPEC-016-IMPL-STEP_1-r2-convergence.md` · this file

Source codex artifacts under `.omc/artifacts/ask/`:

- `codex-impl-audit-prompt-spec-016-step-1-code-review-lane-lane-1-of-2026-06-25T15-01-42-077Z.md`
- `codex-impl-audit-prompt-spec-016-step-1-security-review-lane-lane--2026-06-25T15-03-51-602Z.md`
- `codex-impl-audit-prompt-spec-016-step-1-architecture-review-lane-l-2026-06-25T15-03-00-547Z.md`
- `codex-impl-audit-prompt-spec-016-step-1-code-review-lane-round-2-r-2026-06-25T15-19-08-478Z.md`
- `codex-impl-audit-prompt-spec-016-step-1-security-review-lane-round-2026-06-25T15-22-25-683Z.md`
- `codex-impl-audit-prompt-spec-016-step-1-architecture-review-lane-r-2026-06-25T15-19-11-516Z.md`

## Commit chain

```
HEAD  e3d6dba spec(016): Step 1 r2 audit prompts — 3 parallel codex lanes
      fc3bf56 impl(016): Step 1 r1 fix-pass — close 1 CRITICAL + 3 MEDIUMs
      2ca290a spec(016): Step 1 audit r1 findings — 3 parallel codex lanes
      85ec22a spec(016): Step 1 audit — split into 3 parallel codex lanes
      6b7a73f spec(016): Step 1 audit prompt — rebase onto SPEC v0.1.21
      f0152c0 spec(016): v0.1.20→v0.1.21 — Claude r20 cross-check + codex r21/r22
      1df0235 impl(016): Step 1 — schema + §3 address registration + §3.2 EIP-712
```

## Next action

Per `specs/BUILD_SPEC_016_STEP_2_CONTINUATION_PROMPT.md`: fork a
fresh session for Step 2 IMPL on the same `impl/spec-016`
branch. The continuation prompt is the cold-start brief; Step 2
covers §4.3 runner cycle + §4.6 nonce/abandon endpoint per the
master IMPL prompt §2.

**Do NOT push and do NOT open the PR yet.** The single PR opens
once after Step 4's audit converges per the consolidation plan
in commit `92c8672`.
