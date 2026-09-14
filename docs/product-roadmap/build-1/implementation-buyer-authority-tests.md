# Build 1 S2 additional buyer authority tests

Test-only slice under the approved `promotion-authority-addendum-r3.md` contract.
Owned file: `phase4-coordinator/internal/buyer/model_admission_guard_additional_test.go`.
No runtime source, existing fixture/test source, dependencies, operator state or
production behavior was changed by this slice.

The new external `buyer_test` tests reuse `primaryAdmissionFixture`: real signed
feed files and loader, independent signed Tier2 material, registered provider
with real receipt publication, and persisted billing snapshot. They call the
actual `PrepareModelAdmissionAuthority` and returned production `TryPin`, not a
success-returning mock resolver. The fixture's existing transport callback is a
registry observation; real WS closing/availability producer validation remains
in the WS owner's separate test lane.

## Covered cases

- `TestPreparedBuyerAuthorityOwnsPublishedInputs` (2 subtests): constructor and
  setter publication each own all eight feed/signature byte slices and the
  rewards rate map. Corrupting caller-retained bytes and removing its explicit
  model rate after publication leaves freshly resolved exact integer evidence
  unchanged and pinnable. Only the independently refreshed probe timestamp is
  excluded from evidence comparison.
- `TestPreparedBuyerAuthorityRejectsCompletedMutation` (7 subtests): real feed
  and billing generation publication, missing effective snapshot ID, changed
  effective rates, enforce-to-observe settlement change, default Tier2 reload
  and in-place Tier2 replacement reject prior prepared authority. Identical
  valid feed/billing republication requires preparation again and then recovers;
  invalid replacements fail fresh preparation.
- `TestPreparedBuyerAuthorityPinsRealOwnerMutation` (7 subtests): the same actual
  mutations cannot complete while the production prepared pin is held. A second
  production `TryPin` observes the actual pending writer as its synchronization
  barrier; goroutine launch alone is not treated as reaching the owner lock.
  Mutations complete after release and the earlier preparation is then rejected.
  No sleeps are used. Five-second failure deadlines and the command timeout
  bound failures; this test does not measure durable SQLite commit latency.

Missing transport-capability cases and actual admission/response/SQLite/WS
producer matrices remain owned by the WS/buyer implementation lane. This slice
must not be read as completing those matrices or the full S2 acceptance gate.

## Fresh evidence

The WS/buyer owner explicitly confirmed buyer runtime and existing test source
freeze before this command. New test source was also frozen for the run.
From `phase4-coordinator`:

```sh
go test -race -count=1 -timeout=60s -json -run '^TestPreparedBuyerAuthority' ./internal/buyer > /tmp/build1-buyer-authority-additional-tests.json
git diff --check -- internal/buyer/model_admission_guard_additional_test.go
```

Both commands exited 0. Parsed Go JSON reports **3 top-level tests and 16
subtests passed**, **0 skipped**, **0 failed**; package elapsed **7.792 seconds**.
No failed or interrupted test run occurred in this additional slice. `gofmt`
was applied before the run. Complete buyer/coordinator checks and combined-diff
independent audits remain lead obligations.
