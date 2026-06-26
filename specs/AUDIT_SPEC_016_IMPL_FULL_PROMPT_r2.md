# IMPL audit prompt — SPEC-016 FULL IMPLEMENTATION, shared context, **r2**

This is the r2 holistic / cross-step re-audit covering the SPEC-016
implementation on `impl/spec-016` after the r1 fix-pass landed at
commit `3b41c0d`. The r1 round returned 2 HIGH + 4 MEDIUM + 2 LOW
(arch 0/0/0/1/0, code 0/2/3/1, security 0/1/0/0/1); all 7 substantive
findings + both LOWs were closed in the r1 fix-pass commit.

This r2 round must:

1. **Verify every r1 finding is actually closed.** For each
   `[full-{code,sec,arch}:r1-N]` finding, walk the fix at HEAD
   and confirm the SPEC invariant the finding cited is now
   enforced.
2. **Catch defects introduced BY the r1 fix-pass.** Each closure
   touched a new authority layer; the audit pattern is "each
   round catches the next 'is this primitive used at the right
   authority layer?' question that the prior fix-pass exposed"
   (per `[[audit-cycles-are-design-discovery]]`).
3. **Look for cross-step defects that only emerge after the r1
   changes.** Examples: does the new IsHalted gate inside
   allocateBuildSignBroadcast leave broadcast bytes persisted
   without an associated runner cleanup path? Does the new
   `withHaltObservability` wrapper interact correctly with the
   `RunNowController` halt-block? Does `validatePayoutRPCURL`
   leave a deploy gate / runtime gate semantics mismatch?

## What r1 closed

### HIGH

| Tag | One-line closure | Files |
|-----|------------------|-------|
| `[full-code:r1-1]` | both-RPC depth in pollCancelOnce + pollAndConfirm | `runner.go:813`, `runner.go:1146` |
| `[full-code:r1-2]` | IsHalted gate at row-loop + before allocate/broadcast/rebroadcast/claim | `runner.go:504`, `runner.go:893`, `runner.go:740`, `runner.go:1212` |
| `[full-sec:r1-1]` | validatePayoutRPCURL helper + deploy gate URL probe | `config.go::validatePayoutRPCURL`, `check-deploy-config.sh::validate_payout_rpc_url` |

### MEDIUM

| Tag | One-line closure | Files |
|-----|------------------|-------|
| `[full-code:r1-3]` | admin halt-bypass policy via withHaltObservability wrapper + Runner.EmitAdminInvokedWhileHalted | `mux.go::withHaltObservability`, `runner.go::EmitAdminInvokedWhileHalted` |
| `[full-code:r1-4]` | stripExistingColumnAlters + columnExists pre-check in Migrate | `migrations.go::stripExistingColumnAlters` |
| `[full-code:r1-5]` | TestE2E_RegisterThroughClaim through ServePayoutAddress | `runner_e2e_test.go` |
| `[full-arch:r1-1]` | LinuxRequired=true in setupPayout + topology_test.go gate regression | `main.go:683`, `topology_test.go::TestAssertPayoutRuntimeTopology_LinuxRequiredGate` |

### LOW

| Tag | One-line closure | Files |
|-----|------------------|-------|
| `[full-code:r1-6]` | gofmt -w | `config.go` |
| `[full-sec:r1-2]` | defer-zeroize in LoadLocalFileSigner | `signer.go:140` |

## Branch + commit under audit

- Branch: `impl/spec-016`
- HEAD: `3b41c0d impl(016): FULL-r1 fix-pass — close 3H + 4M + 2L convergent findings`
- Diff base: `main`
- Step audits: per-Step convergence already verified at r1 prompt.

## SPEC under audit

- `specs/SPEC-016-payout-pipeline.md` v0.1.21 LOCKED at commit `f0152c0`

## Implementation surface

Same surface as r1 (see `specs/AUDIT_SPEC_016_IMPL_FULL_PROMPT_r1.md`)
plus the r1 fix-pass deltas. The deltas are concentrated in:

- `phase4-coordinator/cmd/coordinator/main.go` (LinuxRequired flip)
- `phase4-coordinator/dist/check-deploy-config.sh` (RPC URL probe)
- `phase4-coordinator/internal/config/config.go` (validatePayoutRPCURL)
- `phase4-coordinator/internal/payout/migrations.go` (ADD COLUMN
  guard via PRAGMA table_info)
- `phase4-coordinator/internal/payout/mux.go` (withHaltObservability)
- `phase4-coordinator/internal/payout/runner.go` (both-RPC depth,
  halt gates at 4 sites, EmitAdminInvokedWhileHalted)
- `phase4-coordinator/internal/payout/signer.go` (defer zeroize)
- `phase4-coordinator/internal/payout/runner_e2e_test.go` (new e2e)
- `phase4-coordinator/internal/payout/topology_test.go` (LinuxRequired
  gate regression)

## Lane-specific prompts

- `specs/AUDIT_SPEC_016_IMPL_FULL_CODE_PROMPT_r2.md`
- `specs/AUDIT_SPEC_016_IMPL_FULL_SECURITY_PROMPT_r2.md`
- `specs/AUDIT_SPEC_016_IMPL_FULL_ARCH_PROMPT_r2.md`

All three lanes are **read-only**. Codex MUST NOT modify any
implementation file. Findings go into `specs/SPEC-016-IMPL-FULL-{lane}-r2-audit.md`.

## Severity guidance (unchanged from r1)

- **CRITICAL** — money-path defect or data-loss class
- **HIGH** — confirmed exploitable security defect or observable
  production correctness defect
- **MEDIUM** — confirmed bug not directly observable in production
  but breaks an audit invariant
- **LOW** — cosmetic / docs / minor consistency

## Per-lane BLOCK rule

Each lane must return 0/0/0/X (LOWs OK) to declare CONVERGENT.
Anything ≥ MEDIUM triggers a fix-pass + r3.

## Output format

Each lane writes findings to its own file:
- `specs/SPEC-016-IMPL-FULL-code-r2-audit.md`
- `specs/SPEC-016-IMPL-FULL-security-r2-audit.md`
- `specs/SPEC-016-IMPL-FULL-arch-r2-audit.md`

Standard structure. Tag findings `[full-{lane}:r2-N]`. Reference
the prior `[full-{lane}:r1-N]` it regresses if applicable.

## Discipline

- Cross-step focus + verify r1 closures actually hold.
- Wall-clock target: 25-35 min (smaller surface than r1).
- Read-only.
