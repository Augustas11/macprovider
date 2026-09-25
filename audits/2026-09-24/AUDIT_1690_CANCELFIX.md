# #1690 audit: cancel-receipt and loopback zero-bill fixes (all three lanes)

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Scope:** `git diff 8b3d6313 90672732`, four commits on top of a CI-green, audit-clean head.
1. **`bacb4110`, buyer-cancel alignment.**
   - Relay: after a `buyer_disconnected` cancel, a one-time slot keeps the provider's cancelled end frame routable (`ws/relay.go`).
   - Coordinator: waits up to 2 s for that frame, records `buyer_cancel` over the bytes the buyer actually received, and ingests the receipt into `attempt.SettlementReceipt`. Provider usage is used only if the receipt's delivered-bytes equal the buyer-delivered prefix (`buyer/server.go`).
   - CLI: a streaming cancel receipt binds only the actually-sent content, and no receipt is signed if a tool call had started (`InferenceRelay.swift`).
   - This fixes pre-existing main bugs: the streaming `buyer_cancel` vs `normal_done` mismatch, and cancel receipts being dropped.
2. **`cae5830f`, loopback zero-bill at the source** (`billing/hotpath.go`). A loopback attempt is `pool_operator_attested` only when the pool runtime reported BOTH prompt and completion tokens, per SPEC-022 R-12. Otherwise: 0 credit, 0 debit, no operator row, quarantined as `loopback_runtime_not_settlement_eligible`. This fixes a real leak: a cancelled loopback stream created a live byte-estimate provider credit counted by the stats, leaderboard and explorer.
3. **`44c66b49`, the same rule in ledger recovery.**
   - A new nullable `runtime_source` column on the provider identity row, written by the hot path and read by recovery.
   - Attested loopback requires reported usage plus a readable, digest-checked, enforce-mode snapshot with the same runtime and every R-12.1 member.
   - All other loopback, and anything with a missing snapshot or unknown runtime, fails closed at 0/0 and is quarantined.
   - Native pricing is unchanged.
   - Pre-migration identity rows (no runtime recorded) fail closed.
4. **`90672732`:** runbook step 0 drains ledger recovery on the old coordinator before the deploy.

**Check:**
- **CODE:** correctness and concurrency of the 2 s wait, the relay slot lifecycle (leaks, reuse, races with other end frames or cancels), and the migration.
- **SECURITY / money path:**
  - Can a provider or buyer manipulate the cancel path to get free delivered output, bill undelivered output, or make an unverified loopback attempt billable?
  - Is the zero-bill rule complete across the hot path, recovery, and any other ledger writer?
  - Does native billing change in any way?
- **ARCH:**
  - mixed-version safety of the new identity column and of the relay protocol change (old CLI/new coordinator and the reverse);
  - the 2 s wait's effect on pool revocation and latency;
  - the SPEC and CONFORMANCE consistency of the new behavior.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
