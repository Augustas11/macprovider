# SPEC-016 FULL IMPLEMENTATION — r3 CONVERGENCE

All three audit lanes have returned 0 CRITICAL / 0 HIGH / 0 MEDIUM
across all rounds; the user's stop criterion (`untill 0 critical/
high/medium bugs found`) is satisfied.

## Final verdicts

| Lane | Round | Verdict |
|------|-------|---------|
| Code | r3 | 0/0/0/1 — APPROVE / CONVERGENT (LOW gofmt closed in same commit) |
| Security | r3 | 0/0/0/0 — CONVERGENT |
| Architecture | r2 | 0/0/0/0 — CONVERGENT (not re-fired at r3) |

## Round-by-round arc

| Round | Code | Security | Arch |
|-------|------|----------|------|
| r1 | 0/2/3/1 — REQUEST CHANGES | 0/1/0/1 — NOT CONVERGENT | 0/0/1/0 — BLOCK |
| r2 | 0/1/1/0 — REQUEST CHANGES (regression of r1-1) | 0/0/1/0 — NOT CONVERGENT | **0/0/0/0 — CONVERGENT** |
| r3 | **0/0/0/1 — APPROVE** (LOW gofmt) | **0/0/0/0 — CONVERGENT** | not re-fired |

## Convergent fix arc

Each round caught the next "is this primitive at the right
authority layer?" question, exactly the `[[audit-cycles-are-
design-discovery]]` pattern.

### r1 fix-pass (commit `3b41c0d`)

**HIGH**
1. `[full-code:r1-1]` — both-RPC depth in pollCancelOnce +
   pollAndConfirm. SPEC §4.3 step 7 requires both heads at
   depth >= ConfirmationBlocks; the original implementation
   only read primary.
2. `[full-code:r1-2]` — IsHalted gate at row-loop top + 3
   chain-write sites (allocate/rebroadcast/claim). The halt
   primitive was process-local but only enforced pre-cycle.
3. `[full-sec:r1-1]` — validatePayoutRPCURL + deploy-gate URL
   probe. The §4.4 two-RPC trust root was unconstrained.

**MEDIUM**
4. `[full-code:r1-3]` — withHaltObservability wrapper +
   Runner.EmitAdminInvokedWhileHalted. Admin endpoints had no
   documented bypass policy.
5. `[full-code:r1-4]` — stripExistingColumnAlters PRAGMA
   pre-check. Migrations 0010 + 0012 were not crash-safe across
   rerun.
6. `[full-code:r1-5]` — TestE2E_RegisterThroughClaim covers
   register → ready → broadcast → confirm → claim through the
   HTTP §3.3 handler.
7. `[full-arch:r1-1]` — LinuxRequired:true in setupPayout. SPEC
   §6.3 was enforced by signer.go comments, not the topology
   authority.

**LOW** (closed in same pass)
- `[full-code:r1-6]` gofmt
- `[full-sec:r1-2]` signer defer-zeroize

### r2 fix-pass (commit `90e3dbf`)

**HIGH (regression of r1-1 caught by r2)**
1. `[full-code:r2-1]` — confirmedDepth bool. The r1 fix assigned
   recPri/recSec at the TOP of every poll iteration, so a
   deadline expiry with non-nil shallow receipts passed the
   nil-only post-loop guard. r2 fix-pass tracks an explicit bool
   that gates the irreversible markConfirmedStandalone +
   ClaimPayoutReady.

**MEDIUM**
2. `[full-code:r2-2]` — TestRunner_PollAndConfirm_RejectsShallow
   Secondary regression test. The test that would have caught
   r2-1 is now in the corpus.
3. `[full-sec:r2-1]` — buildExecutableMask helper. The
   addColumnStmt regex naively scanned `--` comments and `'`/`"`
   string literals; mask now skips them before applying the
   regex.

### r3 fix-pass (commit `<this commit>`)

**LOW**
- `[full-code:r3-1]` — gofmt drift in r2-touched
  internal/payout/migrations.go (comment-only). Closed in same
  commit as this convergence summary.

## What this audit cycle proved

The repeated pattern (per `[[audit-cycles-are-design-discovery]]`):

1. r1 audit caught the original SPEC-compliance gaps the per-Step
   audits couldn't see (cross-step trust roots, holistic event
   field-set sweep, FULL PR-readiness).
2. r1 fix-pass exposed the next placement question (variable
   assignment site for both-RPC depth, comment-vs-quote handling
   in the migration regex).
3. r2 caught both — the r2 HIGH (`[full-code:r2-1]`) is the most
   important catch of the entire cycle: a HIGH money-path
   regression introduced BY the r1 closure, caught by the next
   round of the same loop, with a test that would have caught it
   in r1 added to the corpus.
4. r3 verified r2 closures actually hold + caught the one
   remaining LOW.

## Branch + commit at convergence

- Branch: `impl/spec-016`
- Worktree: `/Users/augstar/macprovider-poc-spec016-audit/`
- HEAD at r3 convergence: `<this commit>` (LOW gofmt + this
  convergence summary)
- Diff base: `main`

## PR-open next steps

Per the single-PR consolidation plan in commit `92c8672` +
Step 4 r8 convergence summary (`specs/SPEC-016-IMPL-STEP_4-r8-
convergence.md`):

1. Push `impl/spec-016` to origin (per `[[git-identity-rule]]` —
   plain `git push origin impl/spec-016` routes to Augustas11
   automatically).
2. Open the single PR for SPEC-016 covering Step 1 + Step 2 +
   Step 3 + Step 4 IMPL.
3. File ONE tracking issue per `[[tracking-issue-scope-control]]`
   covering the deferred [arch:4.5] LOW Step 3 advisories
   (ProduceStaleOutboxRows LIMIT + chronic single-RPC outage
   telemetry).
4. After PR squash-merges, `git reset --hard origin/main` per
   `[[pr-merge-workflow-rule]]`.

## Validation at convergence

- `go build ./...` from `phase4-coordinator/`: PASS
- `go test -count=1 ./...` from `phase4-coordinator/`: PASS (21 packages)
- `go test -race -count=1 ./internal/payout/...`: PASS
- `gofmt -l phase4-coordinator/internal/payout/` `cmd/coordinator/`
  `internal/config/`: clean on SPEC-016 surface
- `govulncheck ./...`: no called vulnerabilities

SPEC-016 FULL implementation CONVERGED on 2026-06-26 across 3
audit rounds + per-Step convergences (Step 1: 2 rounds, Step 2: 4
rounds, Step 3: 3 rounds, Step 4: 8 rounds; total: 20 round-passes
across the cycle).
