## Code Review Summary

**Scope:** Complete nine-commit `origin/main...HEAD` diff, 112 changed files, and related source paths.
**Total issues:** 9 — CRITICAL: 0, HIGH: 0, MEDIUM: 2, LOW: 7.

### Issues

1. **[MEDIUM] Later hardware/OS submissions can fail to supersede old evidence**
   File: [evidence_pg.go:96](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/autotune/evidence_pg.go:96)
   **Confidence: HIGH. Introduced by this diff.**
   **Failure scenario:** Supersession requires `n.generated_at > j.generated_at`, but `generated_at` comes from the provider. A later submission reporting different hardware or OS with an equal or earlier accepted timestamp leaves the old verified evidence current. Existing tests exercise strictly later timestamps.
   **Fix:** Order submissions using coordinator-controlled job ordering, such as `id`, rather than evidence capture time. Cover equal and earlier capture timestamps.

2. **[MEDIUM] Native-MTP journey validation retains calendar expiry**
   File: [native_mtp_journey_evidence.py:487](/Users/augstar/macprovider-no-expiry/scripts/native_mtp_journey_evidence.py:487)
   **Confidence: HIGH. Pre-existing; unreconciled with the amended SPEC-048.**
   **Failure scenario:** Once serving evidence passes `expires_at`, validation rejects it with “evidence has expired.” Conformance validation calls this same validator, so unchanged qualification becomes unusable solely through age despite SPEC-048’s structural-only contract. The existing `test_expired_evidence_fails` still passes.
   **Fix:** Remove the wall-clock rejection for this evidence class, retain structural validation, and update the existing test to require acceptance past expiry.

3. **[LOW] Activation tooling still demands calendar-driven revocation renewal**
   File: [catalog-activate.sh:193](/Users/augstar/macprovider-no-expiry/scripts/ops/catalog-activate.sh:193)
   **Confidence: HIGH. Pre-existing.**
   **Failure scenario:** An aged, otherwise usable revocation batch makes `next` require publishing another batch because remaining coverage falls below the configured minimum. This preserves a renewal prerequisite after the runtime stops requiring freshness.
   **Fix:** Accept the verified existing batch for current clients; retain any legacy-client requirement explicitly where needed.

4. **[LOW] Supersession is reported as evidence expiry**
   File: [trust_revalidation.go:216](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/ws/trust_revalidation.go:216)
   **Confidence: HIGH. Pre-existing diagnostic, newly misleading.**
   **Failure scenario:** Missing or superseded evidence produces `autotune_evidence_expired`, suggesting an age cutoff that no longer exists.
   **Fix:** Use an unavailable/current-evidence diagnostic and update associated comments and assertions.

5. **[LOW] Privacy identity diagnostics still describe expiry**
   File: [privacy_authority.go:731](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/relayblind/privacy_authority.go:731)
   **Confidence: HIGH. Pre-existing.**
   **Failure scenario:** Rejection still reports `code_identity_unapproved_or_expired`; the comment at line 771 also describes expired entries withdrawing approval, although the field has been removed.
   **Fix:** Update the diagnostic and comment to describe the remaining approval predicates.

6. **[LOW] Creator-expiry snapshot assignment is now dead**
   File: [durable_store.go:4009](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/durable_store.go:4009)
   **Confidence: HIGH. Pre-existing assignment made obsolete.**
   **Failure scenario:** `RouteableExpired` still derives from `creator_agreement_expired`, which no longer becomes a routing rejection. The assignment obscures the distinction between status warnings and signed-manifest route expiry.
   **Fix:** Remove the obsolete creator-expiry assignment while preserving manifest-window expiry handling; reconcile the corresponding status projection.

7. **[LOW] Revocation-feed expiry error is unused**
   File: [NativeMTPRevocationFeed.swift:110](/Users/augstar/macprovider-no-expiry/phase3-binary/Sources/macprovider-cli/NativeMTPRevocationFeed.swift:110)
   **Confidence: HIGH. Pre-existing symbol made dead by this diff.**
   **Failure scenario:** `.expired` and its description remain after all emitting paths were removed, leaving a misleading failure state.
   **Fix:** Remove them or document an intentional compatibility reservation.

8. **[LOW] Publish-script description contradicts aged-slot serving**
   File: [publish-native-mtp-revocations.sh:7](/Users/augstar/macprovider-no-expiry/scripts/publish-native-mtp-revocations.sh:7)
   **Confidence: HIGH. Pre-existing wording.**
   **Failure scenario:** The comment still says the coordinator serves only “unexpired” slots, suggesting a missed publish stops serving.
   **Fix:** Describe selection of the newest issued, verified slot regardless of elapsed expiry.

9. **[LOW] Design documentation references deleted workflows**
   File: [openrouter-catalog-pipeline.md:39](/Users/augstar/macprovider-no-expiry/docs/design/openrouter-catalog-pipeline.md:39)
   **Confidence: HIGH. Pre-existing references invalidated by this diff.**
   **Failure scenario:** Readers are directed to the deleted scheduled signer and freshness alarms.
   **Fix:** Describe on-demand restamping and remove the deleted workflow references.

### Open Questions

None affecting the verdict.

### Positive Observations

- Revocation fallback distinguishes rejected/unreachable network feeds from local store and anchor-integrity failures.
- Runtime expiry removals preserve signatures, timestamp ordering, future-issued checks, and monotonicity protections.
- Test wiring remains intact after workflow and script deletions.
- The retained coordinator admission-window cap matches SPEC-023’s explicit mixed-version allowance.

### Validation

Passed: targeted existing Go tests for catalog verification, buyer feeds, autotune evidence, and trusted-pool lapse behavior; focused Python tests; test-wiring checker; 127 ops-guard assertions; changed shell syntax checks; `git diff --check`.

The ops-entrypoint suite was interrupted and is **not counted as passing**. Swift execution and broad CI were not run under the host restrictions. LSP and AST-grep tools were unavailable. No source edits or network access were performed.

### Recommendation

**REQUEST CHANGES.** The required **0 C/H/M** gate fails on two MEDIUM findings.

C/H/M/L = 0/0/2/7
