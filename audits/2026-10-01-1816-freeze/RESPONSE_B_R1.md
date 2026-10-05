# #1816 freeze audit: fixer B response to round 1

Inputs: `RESULT_code_R1.md`, `RESULT_security_R1.md`, and
`RESULT_architecture_R1.md` in
`macprovider-1816-pool-models/audits/2026-10-01-1816-freeze/`, against
`e7964a233`. Fixer B owns the findings below. Settlement, receipts, the fence,
pricing at dispatch, and phase7-verify belong to fixer A. Each finding was
checked against the code before it was fixed. Where a test could show the
defect, it was written first and seen failing on `e7964a233`.

Of the 16 findings, 14 are fixed, one of them by a different mechanism
(*fixed (alt)*). Two are not fixed in code and are carried with their
reasoning (S-M4, S-M5).

**Held back by the secret-preflight hook.** The H2/H3 SIGHUP wiring in
`phase4-coordinator/cmd/coordinator/main.go` is uncommitted, together with
its reload test `cmd/coordinator/sighup_trusted_pools_reload_test.go` (that
test fails without the wiring). Both are in `.omc/fixB-uncommitted.patch`.
They must land with these commits.

## Code lane

| ID | Sev | Disposition | Where |
|---|---|---|---|
| H2 | HIGH | **Fixed.** The bounds are now one atomic snapshot that manifest acceptance, the R011 sweep, routing, the pool `/v1/models` view, and status all read. Boot stores it. An applied SIGHUP replaces it only after every other fallible reload step has succeeded, so a rejected reload changes nothing. Tightening or removing the bounds takes effect immediately. Route snapshots keep their recorded rates and bounds digest, so nothing is re-priced. SPEC-005 0.6.13 now says this. | `cmd/coordinator/trusted_pools_reload.go`; `main.go` (uncommitted); `trusted_pools_reload_test.go`, `sighup_trusted_pools_reload_test.go` (uncommitted); `specs/SPEC-005-billing.md` R015 |
| H3 | HIGH | **Fixed.** The store's owner-key map can now be swapped atomically (`Store.SetProviderOwnerPublicKeys`). The admin handler reads its keys through the store. The same reload step that applies the bounds also applies `SetProviderOwnerAccounts`, which advances the routing generation. A rotated or removed key and a removed account are therefore in force at once. An invalid key rejects the reload before anything applies. | `internal/trustpool/durable_store.go`; `trusted_pools_reload.go`; `main.go` (uncommitted) |
| M4 | MED | **Fixed.** Status claims `pool_attested_earning` only when `poolBindingEarningNow` holds at encode time. That predicate checks: the pair is not blocked or catalog-priceable; the pool is routeable and unexpired; membership and account still match (creator-owned or R016-attested); the generation is active, or the previous one with a byte-identical entry; the rates are unchanged; and the bounds contain the entry. Otherwise status reports `no_earning_path_in_v0_1` and `wait_for_coordinator`. Eight invalidations are tested before the sweep runs. The shared fixture bytes did not change. | `internal/ws/model_admission.go`, `model_admission_pool_manifest.go`; `TestPoolScopedStatusEarningReevaluatesCurrentPredicate` |
| M5 | MED | **Fixed.** Listed capacity now runs the routing predicate: ready or busy, the pool binary floor, and `poolModelRouteBinding` over the same route view routing builds. A store error counts as ineligible. | `internal/buyer/pool_model_route.go`; `TestSPEC1816PoolModelListingMatchesRoutePredicate` |
| M6 | MED | **Fixed.** A native `mlx_cache` proposal no longer emits the `runtime_allowlist` requirement or the R016 attestation requirement. MLX loopback proposals still do. | `phase3-binary/.../PoolModelProposal.swift`; `testNativeProposalOmitsLoopbackOnlyRequirements` |
| M7 | MED | **Fixed.** `configuredCoordinatorURL` and `models propose` now propagate a config load error instead of discarding it with `try?`. That covers a missing explicit `--config` or `MACPROVIDER_CONFIG`, malformed YAML, and a mistyped key. With no explicit path, a missing default file still loads the defaults. | `BYOMLiveCatalogMatcher.swift`, `ModelsSubcommand.swift`; `testExplicitConfigErrorsNeverFallBackToProduction` |

## Security lane

| ID | Sev | Disposition | Where |
|---|---|---|---|
| H4 | HIGH | **Fixed.** `BuildArtifactIdentityIndex` used to drop the artifacts of a blocked row. It now keeps every one of them as a deny pair, verified or not, and never as an identity (`artifactidentity.NewWithBlocked`, `Index.Blocked`). Pool catalog classification checks those pairs even when the feed is stale. Acceptance, bind/rebind, the sweep, and the hello exemption all go through that classification. A bound GGUF pair whose row becomes blocked is revoked with `pool_manifest_entry_revoked`. A pair that a later release drops from the feed entirely is no longer a catalog identity, so it is not tombstoned: that is the release author's decision. | `internal/artifactidentity/index.go`, `internal/buyer/artifact_identity_index.go`, `internal/ws/model_admission_pool_manifest.go`; `TestPoolManifestBlockedArtifactFeedPairDenies`, `TestBuildArtifactIdentityIndexKeepsBlockedRowArtifactsAsDenyPairs` |
| M1 | MED | **Fixed (alt).** The config object is now closed: all six keys exactly once, integers only (`!!int` tag), no unknown or duplicate keys, and min ≤ max. Each maximum must also satisfy maximum × 2^20 tokens × `rewards.global_multiplier` ppm ≤ int64. The alternative is the token count. The audit and SPEC-005 0.6.12 used the 10,000,000-token `maxBillableTokens`, which caps a rate at about 922k credits/Mtok, but the live catalog already prices `qwen3.6-27b` completion at 2,160,000. SPEC-005 0.6.13 therefore uses the largest pool `max_context_tokens` (2^20, cap 8,796,093 at 1.0). Counts above that still hit §5.3's checked arithmetic. Invalid bounds fail config load, which is fail-closed. The integration journeys' 100M test bounds became 8M. | `internal/config/config.go`; `TestTrustedPoolsPoolModelPricingBoundsClosedDecodeAndOverflow`; `specs/SPEC-005-billing.md` R015 |
| M4 | MED | **Carried; rejected as a code fix.** The finding is accurate: every canary leg comes from the canary account. A hostile account can even answer the pinned SSH session with a forced command. `/v1/pool/check` reports `provider_reported` evidence. No coordinator record ties a session to the feed bytes it fetched, because the feeds are public, unauthenticated GETs, so there is nothing server-side to bind to without new attestation work. A forged pass cannot change what deploys: signatures, the manifest, and digests are verified before install and again at load. The canary is a functional check under operator custody. The runbook now says this and gives the steps to take if that account is compromised. | `ops/runbooks/608-pearl-tier2-single-authority.md`; `ops/pearl-updater/catalog-canary-proof.py` docstring |
| M5 | MED (pre-existing) | **Carried.** A high-water mark beside the database is not cheap. The Pearl updater's own rollback restores its pre-update `coordinator.db` snapshot by design (`database-manifest.json`), so such a mark would refuse every legitimate rollback. It would also sit in the same rollback domain as the database. SPEC-042 already lists tamper-evident rollback protection as a launch blocker. The runbook now records the risk and requires re-applying every post-snapshot revocation, lifecycle change, and acceptance after any database restore. | `docs/runbooks/trusted-pool-production-launch.md` §9 |

## Architecture lane

| ID | Sev | Disposition | Where |
|---|---|---|---|
| H1 | HIGH | **Fixed.** The step 4b check now decodes every extension id and adds a `p1816` tier. It reports STOP for any target that lacks an extension found in history. An unknown extension is STOP for every tier. A Go test extracts the runbook block the same way operators run it and runs it against a real store history with extensions: v1-only, m8, and m9 return STOP with the extension named, and p1816 is replayable. A v2 history without extensions stays replayable on m9. `check4b.sh` gained a p1816 case. | `docs/runbooks/trusted-pool-production-launch.md` §9; `internal/trustpool/rollback_check_runbook_test.go`; `scripts/lab/1690-e2e/check4b.sh` |
| M3 | MED | **Fixed: fail closed and roll back.** Inside the rollback-armed `verify_rollout`, after public exact catalog admission, the updater fetches `/v1/catalog-artifacts` and `.sig` through `coordinator.malibu.tech`. A bound release must serve its exact bytes; an unbound release must serve neither. On a miss it fails with the manual nginx step named. Rollback here is safe for the fleet: it is the same point and blast radius as the existing admission check, the previous release keeps serving, and providers fall back to the compiled-in feed only for artifact-derived features. | `ops/pearl-updater/macprovider-pearl-update`; `test_public_artifact_feed_*`; `docs/runbooks/catalog-artifact-feed-release.md` |
| M4 | MED | **Fixed.** Same fix as code M4. | as code M4 |
| M5 | MED | **Fixed.** Same fix as code M5. | as code M5 |
| M6 | MED | **Fixed.** SPEC-005-R015, SPEC-022-R013, SPEC-042-R015/R016, SPEC-006-R018, and SPEC-047-R011 now map the real implementation and test anchors. Each gap lists only what is still missing: the fixer-A settlement/receipt/phase7 items, the held-back main.go wiring, open LOW items, and signed journey evidence. All six stay `pending`. | `specs/CONFORMANCE.json` |
| M7 | MED | **Fixed by narrowing.** SPEC-023 v0.22.5 §16.9 now states that the pool-proven path is not executable. The R012 aggregate, the R011 probe record, and `intake-decision.v2` do not exist, and the generator rejects v2. Operators MUST NOT author a v2 decision; graduation uses the v1 intake. The rows for SPEC-023-R026 and SPEC-047-R012 stay pending and were already accurate. The pool runbook gains §8. | `specs/SPEC-023-installer-autotune-recommend.md`; `docs/runbooks/pool-scoped-model-admission.md` |

## Gates

The gates ran on the working tree, including the uncommitted main.go wiring.

- `cd phase4-coordinator && go build ./... && go vet ./... && go test ./...`: build and vet are clean, and 45 packages pass. In the parallel run, `cmd/coordinator` failed once on `TestMoneySQLiteWALCheckpointerKeepsCheckpointingUnderSustainedWrites` (9 writes under load). That test is timing-sensitive WAL code this round did not touch. Rerun alone, the package passed, and the test passed with `-count=3`.
- `cd phase5-gateway && go test ./...`: pass.
- `cd test/integration && go test -race -count=1 ./...`: pass (3 packages). `TestTrustedPoolModelJourney` and `TestTrustedPoolModelR016NonCreatorMember` were confirmed to run, not skip.
- `make test-dist`: pass. The first run failed in `test-swift-package-lock.sh` because a local `swift build` had pruned `phase3-binary/Package.resolved` in the working tree. That is a local artifact, never committed; after restoring the file from HEAD, the rerun passed.
- Committed tree without the held-back main.go and its test: `go build ./...`, `go vet ./cmd/coordinator/`, and `go test ./cmd/coordinator/` all pass.
- `python3 -m unittest test_pearl_updater` (in `ops/pearl-updater`): 267 tests, OK (1 skipped, pre-existing).
- `swift test --filter 'BYOM|PoolModel|Config|Status'`: 695 tests, 0 failures (1 skipped, pre-existing). The Malibu app was not touched.
- `python3 scripts/gen_spec_index.py --check`: up to date.
- `python3 scripts/check_spec_governance.py --base-ref origin/main`: passed.
- `git diff --check origin/main`: clean.
