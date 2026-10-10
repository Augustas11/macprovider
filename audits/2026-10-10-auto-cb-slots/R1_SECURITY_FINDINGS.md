
codex
Security gate **FAILS: 1 MEDIUM finding**. Reviewed the complete four-commit diff and relevant callers locally; no edits, builds, or network calls.

1. **MEDIUM — Isolation qualification skips production row counts.**  
   [ContinuousBatchingSelfCheck.swift:169](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:169) uses the throughput calibration ladder: 2–8, 12, 16, etc. Line 181 treats the highest passing rung as `verifiedSlots`, while [ContinuousBatchScheduler.swift:4449](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchScheduler.swift:4449) forwards the actual current row count.
   
   **Exploit scenario:** A grant of 12 permits nine, ten, or eleven concurrent rows without qualifying those shapes. A buyer can control overlapping requests and reach a row-count-specific isolation defect that the self-check never exercised. This is an admission gap; no actual kernel leak was demonstrated.
   
   **Fix:** Check every integer depth through the maximum grant. Require a contiguous passing prefix, update the regression that currently expects skipped depths, and invalidate cached decisions produced by the sparse check. The sparse throughput ladder is pre-existing; its use as an isolation authorization is new.

2. **LOW — Store validation happens after a potentially blocking open.**  
   [ContinuousBatchingSelfCheck.swift:426](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:426) opens the path before checking its type and owner.
   
   **Exploit scenario:** If an operator places the config in a directory writable by another local user, that user can create `cb-self-check.json` as a FIFO. `open(O_RDONLY)` blocks before `fstat` can reject it, hanging startup or the driver. The default private-directory deployment limits exposure.
   
   **Fix:** Open with `O_NONBLOCK | O_NOFOLLOW`, then validate the descriptor; verify the parent directory’s ownership and write permissions. Bound file size before decoding. New finding.

3. **INFO — Revocation suppression remains possible by accepted policy.**  
   [ContinuousBatchingSignedPolicy.swift:586](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSignedPolicy.swift:586) substitutes empty coverage on fetch failure; [ModelRuntime.swift:10005](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:10005) substitutes an empty MTP revocation set when loading fails.
   
   **Scenario:** Feed suppression can keep an otherwise revoked tuple eligible when its revocation is unavailable. This implements the explicit “absent = no revocations” decision and is not counted as a blocking defect. A known verified revocation of the selected tuple is enforced.
   
   **Fix:** Document this threat acceptance. A persistent signed deny set would strengthen it without introducing feature expiry, if policy is later changed.

4. **INFO — Near-tie acceptance is a heuristic, not proof against every leak.**  
   [ModelRuntime.swift:4516](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:4516) checks other rows’ alone-token IDs at the first divergence; [ContinuousBatchingSelfCheck.swift:687](/Users/augstar/macprovider-auto-slots/phase3-binary/Sources/macprovider-cli/ContinuousBatchingSelfCheck.swift:687) accepts the row when that divergence passes.
   
   **Scenario:** Cross-row contamination that selects an allowed top-two token without matching another row’s checked token—or affects the continuation after an accepted tie—can escape this heuristic. This matches the requested rule; no concrete scheduler leak was established.
   
   **Fix:** Describe the limitation accurately; independent same-prefix continuation checks could strengthen detection.

No additional findings in bounded heartbeat parsing, admin serialization, MTP admission signature/artifact checks, or public secret/ops-internal leakage. Stored grants remain clamped to scheduler rows; same-user cache tampering is within the existing operator trust boundary.

C/H/M/L = 0/0/1/1
hook: Stop
hook: Stop
hook: Stop Completed
hook: Stop Completed
