Read `audits/2026-09-24/AUDIT_1690_FINAL_COMMON.md` first.

**Lane: code correctness.** Check:
- Go concurrency and transactions in the settlement, finality and recovery paths, including how they interact with main's #1728 pending-hold recovery.
- The `usage_source` migration.
- policy-core/v2 encode/verify/replay.
- Route-time pool selection across candidate, pinned, and slot-queue paths.
- Swift actor isolation and cancellation in the loopback runtime and receipt decision.
- The SSE, timeout, and disconnect accounting.
- Test adequacy for each behavior.
- Anything the rebase conflict resolutions broke: the subcommand list, CONFORMANCE records, the AC-022-66 coverage-map key.
