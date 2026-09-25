# #1690 audit: cancel-receipt and loopback zero-bill fixes, round 2 (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Scope:** `git diff 8b3d6313 HEAD`, cumulative. It covers the round-1 scope (`bacb4110`, `cae5830f`, `44c66b49`, `90672732`) plus the round-1 fix `75c1c691`. The round-1 brief is `audits/2026-09-24/AUDIT_1690_CANCELFIX.md`.

**Round-1 fixes in `75c1c691`:**
- **Recovery:**
  - billable only for a recorded native runtime, or a recorded known loopback runtime with reported usage, a complete enforce-mode same-runtime snapshot, durable R-12.3 authority, and a verified R006 label;
  - the authority and label checks are pre-read in `recoveryPoolAttestedRoutes` before the transaction, and the in-transaction snapshot re-read must match its digest;
  - the label source comes from the trusted-pool registry (`SetSettlementPoolLabelSource`), and is fail-closed when pools are off;
  - every unknown yields 0/0, quarantined.
- **Cancel arming** is under one lock (`retireActive`).
- **Buffered WS streaming:** a buyer cancel waits for the provider cancel receipt over an empty prefix, a provider "cancelled" end becomes `buyer_cancel` and keeps its receipt, and a torn final write records only complete events.
- **SSE:** each block is validated on a copy and recorded only after a successful buyer write.
- **Tier-2 rekey** holds while a cancelled request still owes its current-key cancel frame, bounded to 2 s + 1 s.

**Check:**
- that the round-1 findings are resolved;
- that the fixes add no regressions: deadlocks, TOCTOU between the pre-read and the transaction, rekey starvation or stalls, a cancel wait that leaks goroutines or slots;
- that native billing is unchanged;
- that no path makes an unverified loopback attempt billable or bills undelivered output.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
