# PR #1945 Codex audit round 1

Base origin/main, head 007596a3a. Fixed in the following commit; LOW 5 (disclosure text defined in buyer, gateway and trustpool) is carried.

=================== code
```text
Gate fails: **3 MEDIUM, 1 LOW** findings in the complete `origin/main...HEAD` diff at `007596a3a`. All are introduced by this PR.

1. **MEDIUM — Offer-time probe can race the binding sweep.** [model_admission.go:2212](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission.go:2212)  
   The offer is durably visible before its probe finishes. A concurrent sweep can bind it with null or older evidence; the handler’s subsequent evaluation does nothing for the same manifest generation. This breaks R011’s probe-before-bind ordering. **Fix:** coordinate in-flight offer probes with binding evaluation, then link evidence and bind atomically. Add a concurrency regression.

2. **MEDIUM — Decoding does not enforce the fixed probe policy.** [model_admission_probe_evidence.go:153](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission_probe_evidence.go:153)  
   A canonical stored record with the current policy ID but different prompt digest, expected-answer digest, seed, or token bound passes validation. R012 can subsequently count its passing result as current-policy evidence. **Fix:** validate the exact policy constants on decoding and cover each mismatch with regression tests.

3. **MEDIUM — Future-dated pool-proven evidence is accepted.** [catalog-release.py:4767](/Users/augstar/macprovider-catalog-graduation/scripts/catalog-release.py:4767)  
   The age check rejects sources older than 24 hours but accepts a frame generated after the intake decision. Such evidence cannot establish what was available at decision time. **Fix:** require `frame_generated <= release_generated`, then apply the maximum-age check.

4. **LOW — Recorded pool-proven values lack strict type validation.** [catalog-release.py:4775](/Users/augstar/macprovider-catalog-graduation/scripts/catalog-release.py:4775)  
   Key validation followed by Python dictionary equality can accept a numeric `suppressed` field equal to the retained boolean. **Fix:** validate every recorded field’s JSON type before comparing it with the derived value.

Existing targeted Go tests passed for probes, pool-proven aggregation/counting, accepted-core replay, and policy/status disclosure. All **22 `IntakeDecisionManifestTest` tests passed**. These tests do not cover the findings above; refresh-pass integration and actual timeout coverage also remain limited.

No files edited, live hosts contacted, or malformed payloads constructed.

C/H/M/L = 0/0/3/1
```

=================== security
```text
Security gate: **FAIL — 1 MEDIUM, 1 LOW.**

- **MEDIUM — resource amplification in aggregate builds.** [model_admission_pool_proven.go:203](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission_pool_proven.go:203), owner lookup at line 155. Every native attempt calls the registry’s full `Snapshot`, copying membership maps and model entries under its read lock. With 100,000 counted attempts and 256 entries in one pool, one build can copy 25.6 million entries, plus repeatedly reconstruct membership. The loop ignores context cancellation, so the query timeout does not interrupt this work. A creator’s valid paid traffic can drive recurring coordinator CPU/allocation pressure. **Fix:** cache one owner-resolution snapshot per pool per build, index accepted entries, and check cancellation during processing and before publication. The snapshot implementation is pre-existing; its per-attempt amplification is new.

- **LOW — future source timestamps bypass retention ordering.** [catalog-release.py:4767](/Users/augstar/macprovider-catalog-graduation/scripts/catalog-release.py:4767). When the retained frame’s `generated_at` exceeds the intake decision’s `generated_at`, the age is negative and passes validation. A backdated decision can therefore cite later traffic and probe evidence. Digest equality preserves byte identity but does not enforce chronology. **Fix:** require source age between zero and 24 hours inclusive, with an existing-suite regression test for future-dated sources.

Validation: 22 intake-manifest tests passed; all 12 selected Go tests for the new surfaces passed; three existing catalog/loopback routing guard tests passed. No files edited or live hosts contacted. No additional provider identity-inflation, endpoint-dereference, access-control, or global-settlement bypass found.

C/H/M/L = 0/0/1/1
```

=================== architecture
```text
Architecture gate: **FAIL — 3 MEDIUM, 2 LOW findings** across the complete `origin/main...HEAD` diff.

1. **MEDIUM — Probe result can be evaluated before buffered output is consumed.** [model_admission_probe_evidence.go:502](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission_probe_evidence.go:502)  
   The relay queues chunks and its terminal notification on separate channels (`relay.go:2062`). When both are ready, the select can receive `Done` first and persist a result from incomplete text. A correct response can become `fail`; a buffered continuation can also be omitted from evaluation. **Fix:** retain the terminal result, drain the chunk channel to closure, then evaluate the complete response. The analogous pattern is pre-existing in other probe helpers; this PR introduces it into graduation evidence. The existing probe test passed 20 runs but does not establish correctness for this scheduling condition.

2. **MEDIUM — Unverified pool attribution contributes to graduation.** [pool_proven.go:76](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/billing/pool_proven.go:76)  
   The predicate excludes only `label_disputed`, admitting both NULL and `unverified` labels. A payable native pool attempt whose label comparison is missing or unverified can therefore increase graduation counts. SPEC-042-R006 explicitly excludes those statuses from pool-scoped accounting (`SPEC-042-pool-control-plane.md:218`). **Fix:** require `PoolLabelStatusVerified`, cover NULL/unverified exclusion, and reconcile SPEC-047-R012’s wording. The specification conflict is pre-existing; this query newly implements it.

3. **MEDIUM — An expired snapshot build can still replace the previous snapshot.** [model_admission_pool_proven.go:258](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission_pool_proven.go:258)  
   After the final evidence query, grouping, sorting and encoding proceed without checking the build context. If source reads finish near the deadline and subsequent processing crosses it, the pointer swap still publishes the snapshot. R012 inherits R009’s requirement that a job exceeding the timeout retain the previous snapshot; CONFORMANCE also claims this behavior. **Fix:** check cancellation during substantial processing and immediately before publication. Existing tests cover source errors and the ceiling, but not deadline expiry during final processing.

4. **LOW — Refresh currency ignores probe-policy identity.** [model_admission_probe_evidence.go:627](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/ws/model_admission_probe_evidence.go:627)  
   Refresh reads the latest record across policies, whereas graduation reads passing records under the current policy. After a policy upgrade, a recent old-policy pass can postpone the new-policy probe for seven days while graduation has no qualifying evidence. **Fix:** make refresh currency policy-aware, treating a missing current-policy record as due. This is an evolution gap; the present single-policy deployment is unaffected.

5. **LOW — Disclosure vocabulary gains another independent definition.** [policy.go:85](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/trustpool/policy.go:85)  
   The text already exists independently in buyer routing and gateway validation. Changing one copy can make policy/status disagree with buyer disclosure or gateway validation. **Fix:** share coordinator constants and add a cross-module contract fixture covering gateway agreement. Duplication between buyer and gateway is pre-existing; this PR adds another copy.

The SPEC-047-R003 global loopback exclusion remains structurally enforced. Pool evidence is rejected on `promote_recommendable`, whose duration, rate, provenance and operator checks remain separate.

Validation passed: six targeted Python consumer tests, targeted Go tests across ws/billing/trustpool/buyer, 20 probe-result repetitions, and diff whitespace checking. No files edited or live hosts contacted.

C/H/M/L = 0/0/3/2
```
