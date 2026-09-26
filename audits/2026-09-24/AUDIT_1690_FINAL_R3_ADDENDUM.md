# #1690 final audit: round 3 addendum

**Scope.** The FULL diff `git diff origin/main...HEAD` at the current HEAD. The common brief still applies.

**New since round 2:** commit `78fedd87`.
- **Lab rig PID identity guard:** `scripts/lab/1690-m6/pidguard.sh`. It verifies pid, start time, uid, command line and lab dir before any signal, and has a hard denylist for live-provider paths.
- **Isolated lab builds:** built from a `git archive` copy under the lab dir. The worktree is never mutated, and the build refuses when the tree is dirty.
- **Coordinator sweeper:** `billing.SweepExpiredPoolSettlementVerdicts` finalizes expired pending pool verdicts through `RecordMissingSettlementReceipt`, bounded at 100 per pass and running every 60 s. It yields to buyer traffic, stays independent of the pool feature flag, and is idempotent with #1728 recovery. SPEC-022 R-12.8 and runbook section 9 are updated.

**Check:**
- that the three round-2 findings (`audits/2026-09-24/` R2 addendum; findings summarized above) are resolved;
- that the sweeper is safe on the money path: it only ever touches expired pool verdicts, never live or non-pool ones, has no double-finalization race with a concurrent finality read or #1728 recovery, and handles load correctly;
- that the round-1 fixes still hold.

Report only real defects at their true severity.
