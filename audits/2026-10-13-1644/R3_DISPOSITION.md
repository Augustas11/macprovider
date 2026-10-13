# Round 3 (final) disposition (#1644 cross-provider scoring)

Round 3 verdicts: code H3 M1; security M2; architecture M4. The three-round cap
is reached, so the fixes below were applied after the final round and have not
been re-audited. The 0/0/0 gate was therefore not met by an audit round.

| Finding | Lane | Disposition |
| --- | --- | --- |
| Known checks share the pair window | code H | Fixed: failed known checks count only as split answers; the double-scored window holds pair measurements only. Test: `TestScorerTrackerKnownChecksDoNotDiluteOrForgePairWindow`. |
| FR-24 effects not persisted with the transition; exclusion write failure lost on restart | code H, arch M | Fixed for exclusions: a failed write keeps the in-memory exclusion (the conservative side) and is retried every sweep until durable. Scorer agreement and known sequences describe the scorers, not the verified key, so they stay valid when the verified key's commit fails. |
| `max_per_hour` resets on restart | code H | Fixed: the engine counts the last hour's `cip_` requests in the request log at start. Test: `TestComputeScoringHourlyBoundSurvivesRestart`. |
| Engine lock held across the transition commit | code M | Mitigated: the commit runs under a 5 s context bound, so a blocked write cannot stall the scheduler indefinitely. Per-key transition serialization is carried. |
| Scorer withholding leaves verification inconclusive | security M | Mitigated: a scorer silent for 8 consecutive jobs rests for one hour, so selection moves on to other operators' scorers. Requiring passing evidence before an unverified provider routes is carried: it would add an onboarding gate the campaign brief excludes. |
| Durable state unbounded | security M | Fixed: durable unverified/passing rows idle 30 days are deleted hourly; adverse rows stay. Test: `TestScoringStorePruneAndRecentRequests`. |
| Bad private corpus is fatal when disabled | arch M | Fixed: the corpus loads only when scoring is enabled; an unusable corpus stops scheduling (logged) and never stops serving. |
| Operator lookup failure retried every sweep | arch M | Fixed: one-minute negative cache and the key moves to its next cadence slot. Test: `TestComputeScoringOperatorLookupFailureBacksOff`. |
| Honest cross-chip acceptance and real substitution detection unproven | arch M | Carried as the merge blocker: hardware validation on real Macs with a catalog model and a substituted model, then confirm or recalibrate the cold prior. CONFORMANCE stays pending. |
