# #1690 final audit: round 2 addendum

**Scope.** The FULL diff `git diff origin/main...HEAD` at the current HEAD. The common brief (`AUDIT_1690_FINAL_COMMON.md`) still applies.

**Changes since round 1:**
- The round-1 fixes in `35fb3767` (security and architecture) and `88824c71` (code). The per-finding resolutions are in the commit messages. The key changes:
  - exact-revision registry authorization
  - on-call republish
  - `coordinator pool-rollback-preflight` plus a billing-DB compatibility floor
  - gateway schema v14 accepting `pool_operator_attested` finality
  - full-verifier manifest acceptance
  - active-window policy projection
  - loopback completions without complete upstream usage never sign
  - relay batching under a lock
  - receipt-arrival preservation
  - retryable authority errors
  - slot-queue recovery
  - cancel receipts bound to delivered output
  - non-streaming disconnect cancel
- The M6 lab-found integration fixes: WS-tunneled hello declares `runtime_source`; a pinned loopback model binds its signed catalog row envelope.
- Legacy HTTP disconnect detection (`PeerCloseMonitor` in `HTTPServer.swift`).
- The M6 lab rig (`scripts/lab/1690-m6/`) and evidence (`docs/runbooks/runtime-agnostic-m6-lab-e2e-evidence-2026-09-24.md`). The lab e2e passes on this code: paid path, fail-closed cases, and 12 concurrent streams.

**Check:**
- that each round-1 finding is truly resolved and the fixes introduced no regression;
- the new rollback/compat mechanisms;
- the lab rig (it must never touch a live provider);
- the KNOWN ITEM (report its severity and the correct fix): a pending coordinator attempt left by gateway-side retries that the gateway refunded is never read again, so its pending record never closes and `pool-rollback-preflight` stays at exit 3 indefinitely.

Report only real defects at their true severity.
