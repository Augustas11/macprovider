### Round-1 CODE findings

| Finding | Status | Evidence |
|---|---|---|
| 1. Evidence supersession ordering | **FIXED** | Uses coordinator job IDs; older capture-timestamp regression passes. |
| 2. Journey evidence calendar expiry | **FIXED** | Wall-clock rejection removed; past-expiry test passes. |
| 3. Activation requires revocation renewal by age | **FIXED** | Any served slot satisfies the step. |
| 4. Supersession reported as expiry | **FIXED** | Diagnostic is `autotune_evidence_not_current`. |
| 5. Privacy identity expiry diagnostic | **FIXED** | Diagnostic and authority comment updated. |
| 6. Dead creator-expiry snapshot assignments | **FIXED** | Removed from both projections. |
| 7. Unused Swift `.expired` | **FIXED** | Explicitly documented as reserved. |
| 8. Publish-script “unexpired” description | **FIXED** | Describes aged-slot serving. |
| 9. Deleted workflow references in design document | **FIXED** | Describes on-demand restamping. |

## Code Review Summary

**Scope:** Complete ten-commit `origin/main...HEAD` diff, 114 changed paths and related source.
**Total new issues:** 2 — CRITICAL: 0, HIGH: 0, MEDIUM: 0, LOW: 2.

### Issues

1. **[LOW] Residual source comments contradict the implemented policy**
   **Confidence: HIGH.**

   - [config.go:1144](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/config/config.go:1144) says removing an identity withdraws approval. Release-derived approval can remain. This comment is **introduced by this diff**.
   - [durable_store.go:2910](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/durable_store.go:2910) says an on-call lapse must stop routing. **Pre-existing**, now obsolete.
   - [creator_selfserve_promotion_test.go:177](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/creator_selfserve_promotion_test.go:177) still says renewal pauses the pool. **Pre-existing**, now contradicting the test.
   - [durable_store.go:4056](/Users/augstar/macprovider-no-expiry/phase4-coordinator/internal/trustpool/durable_store.go:4056) retains the deleted `earliestDeadline` description above `EffectiveGeneration`.

   **Failure scenario:** Maintainers follow obsolete withdrawal or routing guidance, or misread the remaining function.
   **Fix:** Qualify configuration-only withdrawal, update lapse/renewal descriptions, and remove the orphan comment.

2. **[LOW] Revocation specifications overstate when native MTP remains off**
   Files: [SPEC-023:3652](/Users/augstar/macprovider-no-expiry/specs/SPEC-023-installer-autotune-recommend.md:3652), [SPEC-048:1368](/Users/augstar/macprovider-no-expiry/specs/SPEC-048-native-mtp-serving.md:1368)
   **Confidence: HIGH. Introduced by this diff.**

   **Failure scenario:** The text says native MTP stays off only when no verified body has ever been accepted. Local store failures and cache/anchor-integrity failures still propagate and invoke `onUnavailable`, even after prior acceptance. SPEC-023’s preceding paragraph correctly retains that boundary.

   **Fix:** Describe unavailable state as lacking a usable authenticated state, including store/integrity failures; distinguish those failures from network/body rejection, which falls back to verified cache.

### Open Questions

None affecting the verdict.

### Positive Observations

- No remaining wall-clock cutoff found on the listed runtime artifacts.
- Signature, structural ordering, future-issued and monotonicity protections remain.
- Network rejection fallback preserves verified revocations; store and anchor failures still propagate.
- CONFORMANCE honestly moves SPEC-032-R002 to pending without rebinding historical evidence.

### Validation

Passed targeted existing offline Go tests covering catalogs, evidence supersession, aged revocation serving, pool lapse/renewal behavior, privacy approval, reward projection and drift.

Also passed:

- Three selected Python tests covering aged journey evidence and approval behavior.
- `python3 scripts/check-test-wiring.py` — 151 test files wired.
- `bash scripts/test-renew-autotune-static-feed.sh`.
- Changed Go files are gofmt-clean.

Swift execution, hardware checks and broad CI were not run under the host restrictions. LSP/AST-grep tools were unavailable. Full-diff whitespace checking reports Markdown trailing spaces in committed round-1 reports.

### Recommendation

**COMMENT — the required 0 C/H/M CODE gate passes.** Two low-severity wording findings remain. No source edits or network access performed.

C/H/M/L = 0/0/0/2
