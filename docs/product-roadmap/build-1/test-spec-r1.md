# Build 1 test specification — revision 1

Pairs with plan-r1.md at base 422fc2f13fc62c1ff8987522f822d9ef856e4a96 and
prerequisite f5edeaebfb6c712a2cb6dced9020c8c78ed1053e. No tests have run yet.

| ID | Claim and evidence required |
|---|---|
| B1-T01 | Feed conformance: fresh valid feed and safe baked fallback; corrupt body/signature, duplicate keys, wrong concurrently trusted signer, release mismatch, future/expired/stale feed and candidate hash mismatch all fail closed for artifact operations. Run prerequisite Swift/Go/Python corpus. Nil baked feed remains unavailable. |
| B1-T02 | Transaction: positive prepare exact primary artifact with size/trust confirmation, progress <=10s, terminal event and fresh readiness. Reject unconfirmed, wrong target/UUID, missing authority, blocked/declared/non-primary/unsupported entries. Assert config/runtime/incumbent hashes unchanged. |
| B1-T03 | Cancellation at metadata, mid-download, hash and durable copy; race immediately before/after publication; crash at every journal boundary; duplicate cancel/reconnect; concurrent prepare/adopt. Before commit no incumbent change; after commit terminal truth and too-late disclosure. No process-kill cancellation. |
| B1-T04 | Corrupt bytes, symlink/path escape, partial download, timeout, disk full, cleanup permission failure and orphan recovery. Remove only owned staging, preserve active and journal-referenced data, expose retry/cleanup. Catalog/feed changes before commit reject publication. |
| B1-T05 | App Xcode tests: exact typed dispatch, confirmation including unknown size, preparation without economics claims, localization/accessibility, old CLI fallback, malformed/mismatched/nonmonotonic events, CLI restart, 30s delayed response, cancellation visibility, terminal plus fresh projection before success, refresh timeout and late recovery. |
| B1-T06 | Prepared-only adoption tests: existing lock/journal/rollback suite and a prepared target adopted successfully; no hidden downloads, no rate-driven action from stale economics. |
| B1-T07 | Coordinator authority matrix: valid exact primary session/catalog/rate/reference/receipt evidence yields catalog_priced then settlement_capable. Independently remove or mutate each predicate: provider-only assertion, listed/nonprimary/hash/runtime/model drift, stale rate, wrong price units, missing Tier2 reference, old session, revoked key, sanction, expired probe. Each remains non-paid or revokes. |
| B1-T08 | Concurrency: withdrawal/reoffer, generation change and revocation racing promotion/routing cannot reuse prior decision. Event preconditions and immutable snapshot provenance checked; no stale promotion overwrite. |
| B1-T09 | Settlement: real PostgreSQL coordinator/gateway harness; route snapshot binds exact model, rate and six artifact fields; signed valid receipt settles expected buyer debit/provider credit once. Tamper each field, wrong release/signer, rate/model drift, missing/incompatible receipt, replay and cap overflow fail. Preserve old plaintext snapshots/digests and paid routing tests. |
| B1-T10 | Physical Mac journey: executable discovery -> confirmed preparation with actual hash -> adoption -> fresh coordinator admission -> actual MLX buyer request -> receipt persistence -> verified settlement and expected accounting. Record commands, model/artifact/runtime/chip/RAM, request/receipt identifiers, balances and sanitized evidence. No fixture substitutes. |

Target suites: macprovider-cliTests AutotuneArtifactFeedTests,
DurableModelArtifactStoreTests, AutotuneRecommendTests, ModelCatalogEconomicsTests,
ModelsSubcommandTests and new transaction tests; MalibuTests ModelManagementTests
through Xcode; coordinator ws/buyer/billing/catalogbind/tier2; gateway router;
test/integration; Python artifact-feed corpus. Verify actual selected test count.

After targeted success run full Swift test, applicable Xcode app suite, coordinator
and gateway Go tests/vet, coordinator lint and integration with a ready Docker
daemon; run SPEC governance and affected dist/script checks. Capture exact commands,
exit statuses, test counts and failures. Interrupted, skipped, zero-selected and
historical tests never count as passed. Physical and production evidence remain
separate columns. No deployed services are exercised in this task.

Independent Astra plan approval precedes implementation. Afterwards independent
code/security/architecture lanes inspect the complete diff including prerequisite
and migrations; all Critical/High/Medium findings require correction and rerun.
Hardware blocker leaves B1-T10 unproven even if every fixture test passes.
