# #1690 audit: rebase onto #1716, resolution review (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

The #1690 branch (previously audit-clean at 0 C/H/M on all lanes) was rebased onto `origin/main`, which now includes #1716 (Qwen3.6 continuous batching, commit `36946873`). Review ONLY the conflict resolutions and semantic reconciliation, not the whole epic again. Compare the rebased branch with the pre-rebase branch using `git range-diff 5793b844^..`, or inspect the files below at HEAD against both parents.

**What changed in the resolution:**
- **`phase3-binary/Sources/macprovider-cli/HTTPServer.swift`:**
  - #1716's `ClientDisconnectState` (set in `channelInactive`) is now the single disconnect signal driving `shouldCancel`.
  - #1690's duplicate `ResponseWriter.isClientConnected` probe was removed.
  - #1690's `PeerCloseMonitor` is kept only as a read pump, installed only when `HTTPServerPipelineHandler` is present, so macOS NIO observes a peer close during an in-flight response.
  - Cancel is always `failed: false`. If the buyer is gone, nothing is written and the audit row is `pre_token_cancel` or `write_failed`. If the socket is open, #1716's `buyer_cancelled` terminal is sent (499 pre-stream).
  - Receipts are marked issued only after a confirmed final write.
- **`DisconnectProbeRuntime`** (a #1716 test runtime) now declares `settlementRuntimeSource` (nil), as #1690 M5 requires.
- **`beta/DECISION_CRITERIA.md`:** #1690's entry is renumbered 247 → 248 (main's #1721 took 247).
- **SPEC-015 line 4** dependency now reads `SPEC-001 v1.9.24`.
- **`specs/CONFORMANCE.json`** union-merged, ASCII-only.

**Reconciliation note from the rebasing agent:** `audits/2026-09-24/REBASE_1716_RECONCILIATION.md`.

**Check:**
- that #1716's continuous-batching semantics are fully preserved: batched output, hybrid cache, lifecycle, memory cap, stop tokens, queue pressure, and its disconnect tests' intent;
- that #1690's semantics are preserved: per-request receipt eligibility, the loopback runtimes, the relay batching lock, cancel receipts bound to delivered output, non-streaming cancel on disconnect;
- that the single disconnect mechanism has no race, double-cancel, missed cancel, or false provider failure, and no receipt for undelivered output;
- that no conflict hunk silently dropped either side's logic.

**Lanes:**
- **CODE:** correctness and concurrency.
- **SECURITY:** receipt, money-path and trust effects.
- **ARCH:** mixed-version, SPEC and CONFORMANCE consistency.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
