Verdict: **REQUEST CHANGES.** The core pool-scoped route-and-pay design is sound and reasonably minimal, but two compatibility failures and several surface/operability inconsistencies prevent freeze.

## Findings

1. **HIGH — NEW: rollback preflight falsely approves coordinators that cannot replay #1816 manifests**

   Files: [trusted-pool-production-launch.md:521](/Users/augstar/macprovider-1816-pool-models/docs/runbooks/trusted-pool-production-launch.md:521), [trusted-pool-production-launch.md:583](/Users/augstar/macprovider-1816-pool-models/docs/runbooks/trusted-pool-production-launch.md:583), [manifest.go:266](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/poolmanifest/manifest.go:266)

   Defect: step 4b inspects only policy-core encoding and `runtime_allowlist`. It decodes but discards extension IDs and bodies. The `m9` tier predates SPEC-042 0.0.38 and rejects both #1816 extensions.

   Failure: accept a manifest containing `pool_model_entries/v1` and only `llamacpp_loopback`; run the rollback check for `m9` → `VERDICT: replayable`; start the old coordinator → history reconstruction rejects the unknown extension and startup fails.

   Fix: collect every extension ID and add extension capabilities to each rollback tier. Any accepted R015/R016 extension must produce `STOP` for pre-#1816 targets. Add a replay regression using an accepted extension-bearing snapshot.

2. **HIGH — NEW: the standalone verifier cannot verify valid #1816 pool-model receipts**

   Files: [route_snapshot.go:213](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/billing/route_snapshot.go:213), [settlement.go:157](/Users/augstar/macprovider-1816-pool-models/phase7-verify/internal/verify/settlement.go:157), [settlement.go:650](/Users/augstar/macprovider-1816-pool-models/phase7-verify/internal/verify/settlement.go:650)

   Defect: the coordinator’s digest now conditionally includes `expected_model_hash_source`, pool-model identity/rates/bounds, generation and member-account provenance. `phase7-verify` neither represents nor canonicalizes those fields.

   Failure: a valid native or loopback pool-model attempt settles with the coordinator’s route digest; `phase7-verify` recomputes the catalog-only shape → `route_snapshot_digest_mismatch`.

   Fix: implement the complete conditional pool-manifest preimage in `phase7-verify`, exactly matching `billing.RouteSnapshot.Value()`. Add golden fixtures for legacy/catalog, native pool-model and loopback pool-model receipts.

3. **MEDIUM — NEW: Pearl updater can report successful activation while the public artifact feed is unreachable**

   Files: [catalog-artifact-feed-release.md:76](/Users/augstar/macprovider-1816-pool-models/docs/runbooks/catalog-artifact-feed-release.md:76), [macprovider-pearl-update:5326](/Users/augstar/macprovider-1816-pool-models/ops/pearl-updater/macprovider-pearl-update:5326), [macprovider-pearl-update:5357](/Users/augstar/macprovider-1816-pool-models/ops/pearl-updater/macprovider-pearl-update:5357)

   Defect: nginx activation is manual, while updater admission verifies only `/v1/autotune-release` metadata. It never fetches the public artifact JSON and signature endpoints. The later external live-release gate catches this, but only after the updater has accepted the rollout.

   Failure: omit the nginx locations; coordinator loads and advertises the bound feed; updater admission and provider canary pass; `/v1/catalog-artifacts` remains 404 and provider artifact-derived features fail.

   Fix: inside the rollback-armed updater transaction, fetch public artifact bytes and signature, verify exact release digests and signer binding, and fail/rollback before reporting rollout success.

4. **MEDIUM — NEW: status claims current earning eligibility from a historical binding alone**

   Files: [model_admission.go:2731](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission.go:2731), [SPEC-047:184](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-047-network-model-admission.md:184)

   Defect: every pool-scoped `catalog_priced` event emits `pool_attested_earning`. R010 permits that claim only while all current route predicates hold.

   Failure: an R016 attestation is removed, the pool freezes, bounds change, or an entry becomes unroutable before the asynchronous sweep appends revocation; routing fails closed, but provider status still says it earns.

   Fix: compute guidance from the same current pool-route predicate used by selection. Emit the non-earning value whenever membership, lifecycle, entry, binding, attestation, bounds or settlement prerequisites no longer hold.

5. **MEDIUM — NEW: `/v1/models` overstates pool-model provider capacity**

   Files: [pool_model_route.go:447](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:447), [pool_model_route.go:497](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:497), [pool_model_route.go:144](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/buyer/pool_model_route.go:144), [SPEC-006:2777](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-006-buyer-api.md:2777)

   Defect: listing counts ready/busy members with matching pool/model/runtime/hash, while routing additionally requires current event, generation, rates, bounds, release, receipt-key and creator/R016 predicates. Yet SPEC-006 defines `provider_count` as eligible providers.

   Failure: revoke a member’s R016 attestation while its session remains ready and bound-looking; `/v1/models` reports capacity, but the next request returns `pool_no_eligible_member`.

   Fix: derive counts through the full current routeability predicate, or expose zero capacity until that predicate succeeds.

6. **MEDIUM — NEW: CONFORMANCE contradicts the implementation**

   Files: [CONFORMANCE.json:10267](/Users/augstar/macprovider-1816-pool-models/specs/CONFORMANCE.json:10267), [CONFORMANCE.json:10282](/Users/augstar/macprovider-1816-pool-models/specs/CONFORMANCE.json:10282), [CONFORMANCE.json:10312](/Users/augstar/macprovider-1816-pool-models/specs/CONFORMANCE.json:10312), [CONFORMANCE.json:10374](/Users/augstar/macprovider-1816-pool-models/specs/CONFORMANCE.json:10374)

   Defect: R015 says pricing bounds and settlement are absent; R013 says route snapshots lack pool provenance; R015/R016 say no extension codecs exist; R018 says the buyer/gateway surface is absent. Those statements are false in this branch, while implementation/test selectors remain empty.

   Failure: governance tooling and reviewers report `CODE_BUG` for implemented work and cannot distinguish actual missing evidence—probe records and signed journeys—from nonexistent code.

   Fix: map the real implementations and tests and rewrite each gap to list only current deficiencies. Keep requirements pending where signed evidence is absent.

7. **MEDIUM — NEW: the specified global-catalog graduation path is not executable**

   Files: [SPEC-023:3727](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-023-installer-autotune-recommend.md:3727), [catalog-release.py:4098](/Users/augstar/macprovider-1816-pool-models/scripts/catalog-release.py:4098), [catalog-release.py:4732](/Users/augstar/macprovider-1816-pool-models/scripts/catalog-release.py:4732), [model_admission_pool_manifest.go:387](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/ws/model_admission_pool_manifest.go:387)

   Defect: R026 defines pool-proven intake, but the coordinator produces no R012 aggregate or probe digest, and the release generator supports only `macprovider.intake-decision.v1`.

   Failure: a model reaches the paid-request/provider thresholds; the operator authors a v2 pool-proven intake decision → generator rejects it, while no conforming aggregate or probe record exists to cite.

   Fix: implement the durable probe record, R012 aggregate, v2 intake schema, retained-source validation and pool-proven decision tests before claiming graduation support.

8. **LOW — NEW: the operator runbook rejects catalog states that the normative design intentionally accepts**

   Files: [pool-scoped-model-admission.md:133](/Users/augstar/macprovider-1816-pool-models/docs/runbooks/pool-scoped-model-admission.md:133), [SPEC-042:380](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-042-pool-control-plane.md:380)

   Defect: the runbook says any artifact already in the global catalog is rejected. R015 accepts `candidate` and `listed` matches; only `recommendable`/priceable and `blocked` matches are rejected.

   Failure: a creator sees a legitimate `listed` row and discards the proposal, preventing pool earning during graduation.

   Fix: document the precise tier/runtime rule and the later `recommendable` supersession behavior.

9. **LOW — NEW: the pool-model runbook assigns buyer disclosure to the wrong authority**

   Files: [pool-scoped-model-admission.md:12](/Users/augstar/macprovider-1816-pool-models/docs/runbooks/pool-scoped-model-admission.md:12), [SPEC-043:130](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-043-trusted-pool-creator-onboarding.md:130), [SPEC-006:1944](/Users/augstar/macprovider-1816-pool-models/specs/SPEC-006-buyer-api.md:1944)

   Defect: the runbook identifies SPEC-043-R014 as buyer disclosure authority. R014 explicitly delegates buyer API, pricing and headers to SPEC-006-R018 and owns only creator/launch disclosure.

   Failure: a future buyer-surface amendment lands in SPEC-043/runbook without updating the actual SPEC-006 contract or gateway implementation.

   Fix: cite SPEC-006-R018 for buyer disclosure and SPEC-043-R014 only for creator, reviewed-artifact and launch promises.

10. **LOW — NEW: validation vocabulary is duplicated across three implementations**

   Files: [PoolModelProposal.swift:194](/Users/augstar/macprovider-1816-pool-models/phase3-binary/Sources/macprovider-cli/PoolModelProposal.swift:194), [pool_setup.py:116](/Users/augstar/macprovider-1816-pool-models/scripts/lab/1690-m6/pool_setup.py:116), [model_entries.go:47](/Users/augstar/macprovider-1816-pool-models/phase4-coordinator/internal/poolmanifest/model_entries.go:47)

   Defect: runtime/format mappings, field lists and ID grammar are independently duplicated in Swift, Python and Go.

   Failure: a later runtime or field amendment updates coordinator acceptance but not the CLI/lab copy; tooling rejects valid entries or emits proposals the coordinator cannot accept.

   Fix: keep Go acceptance authoritative and add one versioned golden-vector corpus consumed by all three implementations, limiting CLI/lab validation to UX-level preflight.

## Architecture that holds

- Policy-core v2 extensions are a small, appropriate mechanism; v1 and extension-free v2 bytes remain stable.
- Catalog route snapshots omit the new source and pool fields, preserving the existing canonical preimage.
- Pool identity, pricing and settlement ownership is cleanly split across SPEC-042, SPEC-005, SPEC-022 and SPEC-047.
- The immutable-snapshot settlement fence across ordinary manifest rotation is correctly separated from durable membership, delegation, attestation and freeze revocations.
- Old CLIs fail artifact-derived features closed, and old artifact-feed coordinator rollback is separately guarded.
- The SPEC-046/047 evidence demotions themselves are honest: historical signed evidence is retained without redating, and requirements remain pending after selector changes. The problem is the stale new #1816 ledger rows, not those demotions.

No files were edited. This was a static full-diff and cross-consumer audit; resource-intensive local suites were not run under the MacProvider host boundary.

TOTALS: C=0 H=2 M=5 L=3 I=0