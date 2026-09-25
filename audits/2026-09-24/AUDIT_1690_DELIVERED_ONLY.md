# #1690 audit: delivered-only billing fix and rollout order (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Focus:** `git diff 92340eee HEAD`, which is commit `6d48d9cc` (delivered-only billing) plus `b6972f0d` (runbook rollout order). Cumulative context: `git diff 8b3d6313 HEAD -- phase4-coordinator phase5-gateway phase3-binary/Sources`.

**`6d48d9cc`:**
- JSON→SSE tool-call materialization now goes through `deliveredSSEAccounting`.
- Non-streaming HTTP and WS responses write and flush the body first, then record success, usage, bytes and receipt. A failed write records `buyer_cancel` over 0 bytes with no usage.
- The settlement outcome travels as declared HTTP trailers, read by the gateway (`withSettlementFinalityTrailers`, `phase5-gateway/internal/router/chat_proxy.go`).
- Usage is attributed to the rendered event that carried it.
- `consolidatedToolCallSSE` emits one synthesized usage-only event.
- Swift: unattested usage is stored as an empty object.
- LOW fixes:
  - `progressAttempt` on a provider-cancelled end
  - capped accounting buffers
  - cached tokens bound to [0, receipted prompt]
  - rotation-grace key acceptance via `ActiveReceiptPubkeyPrev`
  - the hot path zero-bills any non-native `runtime_source` (aligned with recovery)
  - a bounded rekey hold
  - SPEC-022 v0.2.2: a native non-streaming disconnect bills nothing

**`b6972f0d`:** the new rollout order.
0. Gateway v14 with trailers first. Against an old coordinator (no trailers), the gateway holds non-streaming settlements as `missing_settlement_finality_trailer` until reconcile.
1. Drain ledger recovery.
2. Coordinator.
3. CLI.
4. v2 allowlists.

**Check:**
- **CODE:** correctness and concurrency of write-then-record, trailer emission and parsing, the attribution logic, and buffer caps.
- **SECURITY / money path:**
  - Can trailers be spoofed or stripped, by a provider or anything upstream of the gateway, to alter settlement?
  - Do "success recorded after write" and trailers ever double-settle or drop settlement?
  - Can any path give free delivered output or bill undelivered output?
  - Is the rotation-grace key acceptance safe against a revoked or compromised prev key?
- **ARCH:**
  - Mixed-version safety in BOTH directions: new gateway with old coordinator (held settlements; does reconcile fully resolve them, including billing correctness?) and old gateway with new coordinator (what exactly happens to non-streaming 200s whose outcome is now only in trailers? Is that safe?).
  - Is the runbook order sufficient, and is the rollback order safe?
  - SPEC and CONFORMANCE consistency.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
