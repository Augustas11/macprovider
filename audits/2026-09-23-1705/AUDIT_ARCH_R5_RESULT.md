## Raw output

```text
1. **HIGH — [server.go:4031](/Users/augstar/macprovider-1705/phase4-coordinator/internal/ws/server.go:4031)** — Registration exposes a `ready` provider before the post-registration catalog recheck.

   - Defect: `RegisterAtDetailed` publishes the provider in the registry while its initial state is `ready`; the WebSocket session is stored at line 4047. Catalog revalidation does not occur until lines 4017–4019, after `registerProviderSessionLocked` returns. During this interval, `RoutingEligible()` returns true and buyer routing can select and dispatch through the stored session.
   - Failure scenario: a hello is admitted against catalog A; catalog C publishes and finishes its sweep before registration; registration then exposes the A-bound provider as routable; a concurrent buyer request dispatches before the recheck fences it. The current test at [catalog_row_continuity_internal_test.go:83](/Users/augstar/macprovider-1705/phase4-coordinator/internal/ws/catalog_row_continuity_internal_test.go:83) checks only after registration returns and cannot observe this interval.
   - Suggested fix: register catalog-bound sessions in an unroutable pending state, store the session, revalidate against the active catalog, then atomically promote to the intended state only when valid. Add a barrier-based concurrency test that pauses after session publication and verifies buyer selection/dispatch cannot observe eligibility. This is required for the SPEC-023 claim that publication racing admission never leaves a diverged session routable.

2. **LOW — [server.go:557](/Users/augstar/macprovider-1705/phase4-coordinator/internal/ws/server.go:557)** — Compatible catalogs share one key namespace for release IDs and catalog digests.

   - Defect: release IDs and lowercase SHA-256 values are inserted into the same map, allowing one catalog’s release ID to overwrite another catalog’s digest entry.
   - Failure scenario: an operator-controlled release ID equals another retained catalog’s digest. Lookup selects the wrong catalog and the complete-envelope comparison subsequently rejects an otherwise valid provider. The checks fail closed, limiting impact to availability.
   - Suggested fix: maintain separate release-ID and digest maps, or use typed/prefixed keys.

3. **LOW — [validate_autotune_release.go:182](/Users/augstar/macprovider-1705/phase4-coordinator/cmd/coordinator/validate_autotune_release.go:182), [autotune_window.py:369](/Users/augstar/macprovider-1705/scripts/autotune_window.py:369)** — Pre-activation coverage treats row continuity as release-level evidence without checking the advertised model row.

   - Defect: the validator reports the entire row-continuity release as admitted, and coverage compares only `(release_id, sha)`.
   - Failure scenario: a provider advertises listed release A, but its selected model row differs in candidate C. Pre-activation coverage passes; after publication, the coordinator detects the row divergence and fences the provider, causing an avoidable capacity interruption.
   - Suggested fix: include model/row identity in validator output and compare it with pool entries, or count a row-continuity release as covered only after all advertised model rows have been proven equivalent. The runtime fail-closed recheck and SPEC disclosure prevent this from becoming an unsafe admission.

Validation passed: both targeted coordinator suites, the nine filtered Swift tests, `deploy_catalog_window_coverage.test.sh`, SPEC index/governance checks, and `git diff --check`. No files were edited.

VERDICT: C=0 H=1 M=0 L=2
