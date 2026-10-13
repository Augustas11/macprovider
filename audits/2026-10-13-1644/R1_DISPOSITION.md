# Round 1 disposition (#1644 cross-provider scoring)

Round 1 verdicts: code C1 H4 M2; security C2 H3 M8 L2; architecture H3 M3 L1.

| Finding | Lane | Disposition |
| --- | --- | --- |
| Hold invalidates a ready payout and strands settled credits | code C, security C, arch H | Fixed. The R-16 predicate withholds only `settled = 0` credits; settled credits are never withheld, so payout revalidation is untouched (SPEC-022 R-16.2/R-16.3). Settled-flag trigger keeps the rollup exact. Test: `TestComputeIntegrityHoldLeavesSettledCreditsAndRaisesCompatFloor`. |
| Rollback to a pre-R-16 coordinator bypasses holds | security C | Fixed. Billing compatibility contract 5, recorded in the transaction that writes the first hold (SPEC-022 R-16.8). |
| Partial double-scoring advances state | code H, arch H | Fixed. A measurement counts only when every selected scorer answered validly; otherwise inconclusive. Test: `TestComputeScoringPartialEscalationIsInconclusive`. |
| Hold, suspension and state can diverge | code H, security H, arch M | Fixed. Hold action and state commit in one transaction on the shared database; suspension is published only after commit; failure rolls back and retries. Test: `TestComputeScoringTransitionIsAtomic`. |
| Startup fails open | code H, security H | Fixed. Scoring store and engine failures are fatal at coordinator start; state loads even with the kill switch off. |
| Slot queue keeps suspended providers | code H | Fixed in `SlotQueueEligible` (`ServingCapable` is a frozen conformant fragment of SPEC-032-R001 and is not edited). |
| Public corpus fingerprintable | security H | Fixed within scope: private coordinator-only corpus via `compute_integrity.scoring.corpus_path` (startup warning while the public fallback is used), and per-request phrasing variation so no request repeats a corpus entry verbatim. |
| Scorer-controlled text reaches logs | security H | Fixed. Parse errors return a closed category; nothing scorer-supplied is logged. |
| Coordinator does not enforce FR-21 bounds | security M, arch H | Fixed in `ParseComputeScoreResult` (prompt/scored token caps, log-prob floor, zero aggregates for non-ok). |
| Output not bound to the selected session | security M | Fixed. Dispatch pins `X-MacProvider-Session`; the session's model and manifest are re-checked before scoring. |
| Expired results accepted | security M | Fixed. Pending requests carry an absolute deadline checked on receipt. |
| Known-sequence cadence skippable | security M | Fixed. Counted per scoring job sent; scorer/sequence pairs chosen together. |
| `cip_` probes reach intake | security M | Fixed. Intake ignores `cip_` accounts; verifiable keys require a catalog-verified hash. |
| Response size and cardinality | security M, arch M | Fixed: 32 KiB output bound before scoring; per-sweep scorer index by (model, manifest); pruning of schedule and operator-key caches for departed providers; ledger index on (provider_id, model, ts_utc). Key states stay by design (a failed key must survive a disconnect); they are bounded by provider x model keys. |
| Admin clears not failure-atomic | security M | Fixed. Clear goes through the transactional transition; scorer clear deletes durably before memory. |
| operator_id caller-asserted | security M | Kept as an operator-asserted label under the shared operator credential, matching SPEC-022 quarantine resolutions; validation tightened to 64 chars of `[A-Za-z0-9._@-]`; documented in FR-25. |
| Swift scoring not exclusive with buyer inference | code M | SPEC clarified: the job holds one slot of the serial permit exactly like a serial buyer request, one job at a time per provider. |
| Reason/metric labels outside the closed sets | code M, arch M, arch L | Fixed in SPEC: `in_band_streak` added to the reason set; scorer splits counted as verification outcome `split`, no longer as an inconclusive reason. |
| Provider DTO shows release metadata | security L | Fixed: provider projection omits released_by and release_reason. |
| Provider endpoint reveals configuration before auth | security L | Carried: pre-existing handler order, unchanged by this diff. |
