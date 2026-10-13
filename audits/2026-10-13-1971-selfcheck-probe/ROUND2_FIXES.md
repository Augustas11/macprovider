# Round 2 dispositions

Round 2 verdicts: code 0C/2H/1M/2L, security 0C/0H/2M/0L/1I, architecture 0C/0H/1M/1L. All lanes verified the round-1 fixes.

Fixed:

- Crash before any serial baseline read as `serial_baseline_unavailable` (code HIGH): with nothing verified and no measurement, `decide` returns `crashed_at_<k>` (or `probe_shape_unmet_at_<k>`) before the serial-baseline guard. `reconcile` therefore treats it as a correctness result and a prior grant is not kept. Test: `testCrashBeforeAnySerialBaselineRevokesAPriorGrant`.
- Tokenizer result count (code MEDIUM): `exactnessPrompts` requires one tokenized prompt per length before zipping, and otherwise fails closed with `probeShapeUnmet`.
- Stored `alone_outputs` lengths (code LOW): reused only at the completion length; otherwise recomputed.
- Stored `probe_alone_outputs` binding (security MEDIUM): each is bound to the SHA-256 of its prompt (`probe_prompt_sha256s`) and reused only for that prompt, at the probe completion length, with non-negative tokens (`reusableLoneOutputs`). The store is read only when its mode grants nothing to group or others (`0o077`); it has always been written 0600. Tests: `testStoredProbeLoneOutputsAreReusedOnlyForTheirOwnPrompts`, `testStoreIgnoresAFileReadableByOtherUsers`.
- R wording (architecture LOW): SPEC now says the window is counted up to 4096, matching the code.

Kept, with reasons:

- `probe_shape_unavailable` terminal (architecture MEDIUM): it is not terminal. That branch stores `ladderBound = maxSlots` (1) with `verifiedSlots` 1, so `ladderBoundGrew` is true as soon as the current bound reaches 2 (the same path as the existing single-row decision under a queue limit of 1). Test: `testProbeShapeUnavailableRerunsWhenTheShapeFits`.
- Cohort tokens counted per scheduler step rather than per backend forward (code HIGH): this is the intended contract. #1971 asks for the probe to measure the served execution, meaning the split forwards, so that a large grant is verified as it will run. The unit the scheduler serves for k rows is one decode step over the FR-CB2 split of those rows. Counting per forward would demand a single forward of k rows above the bound, an execution that never serves. A step counts only when it decodes every row of the cohort and no other row, so native-MTP rows, other cohorts and buyer rows never count. Cohort rows have equal completion lengths and no stop sequences, so none finishes mid-window ahead of the others. A backend that serializes rows serves them serially too, and the probe then verifies that serial execution. The doc comment and SPEC item 2 state this.
- Buyer delayed by an in-flight probe hop (security MEDIUM): pre-existing behaviour of the #1947 self-check, not introduced here. A buyer is not admitted beside self-check rows (FR-CB11). The self-check yields within 100 ms and cancels its rows. `cancel` ends a running decode window at the next step (`decodeWindowControl.markCancelled`), so the wait is at most one decode step or one prefill iteration (`maxPrefillTokensPerIteration`, 2048 tokens), the same bound as before. The new cohort gate adds no wait: an incomplete cohort is moved behind admissible rows.
- `routeKeyBoundary` uses a fixed GQA shape (code LOW): every served model is GQA. The boundary only places prompt lengths, and the probe's verdict does not depend on it. Large devices (`d`/`s`) switch at 1024 for MHA and GQA alike.
- Token ids in divergence logs (security INFO): pre-existing log shape, no prompt text.
