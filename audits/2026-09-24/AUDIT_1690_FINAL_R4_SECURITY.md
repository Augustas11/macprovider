# #1690 final audit: round 4, SECURITY lane only

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine. Review by reading the source and the diff only.

**Scope.** The FULL diff `git diff origin/main...HEAD`. The common brief (`AUDIT_1690_FINAL_COMMON.md`) and the lane brief (`AUDIT_1690_FINAL_LANE_SECURITY.md`) apply. The CODE and ARCH lanes passed in round 3.

**New since round 3:** commit `b7a1c462`. The pool expiry sweeper (`phase4-coordinator/internal/billing/pool_settlement_expiry_sweep.go`) now uses keyset paging by (deadline, verdict id, snapshot id). Its cursor wraps across passes, failing rows back off per row (1 min doubling to 1 h), and each pass is hard-capped at 100 finalizations. Lab rig builds use a single HEAD export and refuse dirty trees.

**Also on the branch since round 2:** M7 buyer engine selection (commits "M7a/M7b/M7c"). The `X-MacProvider-Engine-Select` header is resolved in the gateway. Internally it travels as `X-MacProvider-Internal-Engine`, honoured only on gateway-authenticated requests. The coordinator filters by the derived runtime class on all selection paths. Non-native engines are selectable only on pools that allowlist them, and `engine_unavailable` / `invalid_engine_selection` fail closed.

**Check:**
- that the round-3 MEDIUM is resolved: no starvation, the cap holds, identity filtering is unchanged, and there is no double-finalization;
- that M7 introduces no way for a buyer or provider to force paid routing of an external engine outside an allowlisting pool route, spoof the internal engine header, or bypass the derived-class filter on any selection path.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
