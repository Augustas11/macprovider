# Round 1 dispositions

Round 1 verdicts: code 0C/4H/3M/1L, security 0C/1H/1M/2L/1I, architecture 0C/1H/2M/2L.

Fixed:

- Stored, prior and provisional grants above the current probe shape (all lanes, HIGH): `ContinuousBatchingSelfCheckTarget.grantableRows` (scheduler rows capped by `exactnessProbeBound`) now replaces `maxRows` wherever a grant is served (`ContinuousBatchingSelfCheckResolution.resolve`, `ContinuousBatchingSelfCheckDriver.apply`). The key gains the route boundary (`+cb-probe-v2/route<B>`); with the decode window already in the key, that fixes the probe prompts and completion length, so stored lone outputs always match. Stored lone outputs of the wrong length are discarded anyway.
- Block rounding (code HIGH, architecture MEDIUM, security LOW): the target carries the pool's block size, and `exactnessRowCost` rounds each row up to whole blocks with checked arithmetic (nil on overflow).
- Pool-capacity bounce counted as progress (code HIGH): the hold now counts only a row reaching prefill or decode, or a prefill chunk, as progress. A bounce back to the queue lets held decode run.
- Incomplete cohort at the queue head (code HIGH): a cohort still being submitted is moved behind the first admissible row, so it never holds up a buyer. Queue-wait expiry restarts the pump.
- Probe rows beside buyer rows (code MEDIUM): a cohort row is admitted only when every occupied row is a self-check row. A cohort shortfall while a buyer request was in flight or started during the step is a yield, not `probe_shape_unmet`.
- Cohort identity (code MEDIUM, architecture and security LOW): `ContinuousBatchSelfCheckCohort {id, size}`. Admission, hold and accounting match by id, and a step counts only when it decodes the whole cohort and nothing else.
- Arithmetic overflow (code MEDIUM): checked row cost; the decode window used for the required tokens is clamped to 4096.
- CONFORMANCE anchors (architecture LOW): runner, target, cohort type and gate added.

Kept, with reasons:

- Shape-unmet precedence when a cohort both diverged and missed R (architecture MEDIUM): a divergence is a correctness result. The rows differed from their lone runs in the served path at a width of at most k, so k is not verified either way. SPEC-038 v0.3.19 item 4 now says so explicitly.
- Unauthenticated stored JSON (security MEDIUM): pre-existing design (owner-only 0600 file, `O_NOFOLLOW`, owner and mode checks on read). A same-user writer can already forge any decision on main. The new field can only cause a divergence (fail closed) or match the real lone run. Lengths are validated.
- Owner pin raising a provisional grant (security HIGH, part): pre-existing FR-CB10 provisional semantics ("keeps its configured count"). It is now capped by `grantableRows`.
- Token ids in divergence logs (security INFO): pre-existing log shape, no prompt text.
- Synthetic one-token prompts in the kernel-route test (code LOW): the test models the row-count route (`qmv`/`qmm`). Key-length routes are covered by #1974's bitwise cache tests and by the shape tests here.
