# Build 1 S2 pool and Tier2 owner guards

Implemented in the shared `codex/product-build-1` worktree, based on
`914f7cafcdbcfc1805a10f4f34167218341d5587` plus the existing Build 1 changes.
Scope: owner-local pool/Tier2 APIs and tests only. Approved authority design:
`promotion-authority-addendum-r3.md`, SHA-256
`6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4`.
This report is implementation evidence, not independent audit approval or
production acceptance.

## Changes

- `phase4-coordinator/internal/pool/model_admission_guard.go` adds
  `Registry.TryPinModelAdmissionProvider(providerID, assignedID)`. It uses
  `TryRLock`, requires both exact identities, matching registry indices and a
  connected registry socket, and returns the current owned provider value,
  persisted positive-canary-sanction observation and one release function.
  Failure returns no release function. Eligibility remains the caller's policy;
  activity counters do not become new eligibility conditions. No callbacks or
  locking getters run during this API.
- `pool/provider.go` publishes an owned provider after registration's existing
  normalization, receipt staging and sanction application. The caller's initial
  normalized entry remains available for WS setup; later caller mutations cannot
  change the registry's admission scalars or receipt buffers. Existing provider
  snapshot return sites and the buyer-serving callback receive owned mutable
  metadata. The legacy encrypted-stream `Tier2Session` pointer retains its
  existing separate ownership; the admission-only view omits it and the socket.
- `tier2/model_admission_guard.go` adds
  `TryPinSnapshotMaterial(expected, modelID, reportedHash)`. It tries the default
  publication read lock, requires pointer identity, then tries selected catalog
  state. Current material uses the same lock-held extraction as the existing
  getter. Every failure releases acquired pins; success releases state then
  publication. Hash-status eligibility checks remain the caller's obligation.
- `tier2/catalog.go` centralizes every default pointer store behind the
  publication mutex, including initialization, test default publication and
  `ResetForTest`. Catalog load/signature work and reload guard callbacks remain
  outside publication locks. Existing in-place Configure/ConfigureStrict state
  mutexes are retained.

The owner APIs are nonblocking acquisitions only. Callers must retain their
successful pins through commit/rollback and release exactly once. These APIs do
not themselves implement admission serialization, SQLite cleanup, transport
availability, or a durability latency bound; those are the cooperating lanes.

## Verification

All commands below ran from `phase4-coordinator`. Pool/Tier2 source and test
imports were checked for WS/buyer dependencies; neither package imports those
active implementation packages. Only isolated owner-package checks ran here.

Final frozen-source command:

```sh
go test -race -count=1 -json ./internal/pool ./internal/tier2 > /tmp/build1-owner-guards-tests.json
go vet ./internal/pool ./internal/tier2
```

Both exited 0. JSON event counts distinguish top-level tests from subtests:

| Package | Top-level tests passed | Subtests passed | Skipped | Package elapsed |
|---|---:|---:|---:|---:|
| pool | 80 | 28 | 0 | 1.769 s |
| tier2 | 69 | 26 | 0 | 2.610 s |

The five newly added top-level tests are
`TestModelAdmissionProviderPinOwnershipAndContention`,
`TestModelAdmissionProviderPublicationOwnsInput`,
`TestModelAdmissionProviderPinSerializesRealMutators`,
`TestModelAdmissionCatalogPinContentionAndCleanup`, and
`TestModelAdmissionCatalogPinSerializesPublications`. They contain 19 subtests.

They cover caller-retained provider identity/state/receipt aliases; Resolve,
Snapshot, state-update and buyer-serving callback receipt ownership; exact
session/missing-connection rejection; owner write contention; pending-writer
nonrecursive acquisition; real state, heartbeat, receipt publication, exclusion,
quarantine, sanction load/clear, canary result, removal and registration
replacement mutators; real default reload, reset/test publication and in-place
Configure/ConfigureStrict publication. Tests detect an actual pending RWMutex
writer using TryRLock, rather than assuming a goroutine has reached its owner
lock. Deadlines bound failure; there are no sleeps. Existing package tests also
pass under the race detector.

Earlier targeted command:
`go test -race -count=1 -v ./internal/pool ./internal/tier2 -run '^TestModelAdmission(Provider|Catalog)'`.
Its first run failed because a new test fixture incorrectly assumed fresh
registration immediately published a receipt key. The fixture was corrected to
invoke real ApplyStateUpdate (the existing publication contract); the targeted
rerun passed. Subsequent final full-package runs include the added heartbeat,
receipt and callback ownership cases. No interrupted or zero-selected run is
reported as passing.

`gofmt` was applied to the six modified/new owner files. `git diff --check` for
the owner paths passed. Coordinator-wide tests, WS/buyer promotion matrices,
SQLite post-insert/pre-COMMIT duration tests, governance checks and combined-diff
code/security/architecture reviews remain lead/cooperating-lane obligations.
No claim is made here about the 250 ms durable-commit budget.

## Approved real HTTP teardown composition

Only new WS test files `model_admission_buyer_failure_test.go` and `model_admission_fixture_export_test.go` changed. From phase4-coordinator: `go test -race -count=1 -timeout=90s -json -run '^TestBuyerHTTPFailurePublishesRealWSClosing$' ./internal/ws`. Finalexit0,1top-level+2subtests,zero skips/failures,2.023s. Log `/tmp/build1-http-failure-transport.json` SHA256 `2cb5bbd1554ad6cd1c22d97ff494d825963e526a59bcf9c7d2afb25c9fdf0d23`. Initial fixture assumption unavailable-to-ready failed; corrected via real permitted Busy-to-Ready updates without changing runtime.

Actual public buyer HTTP530/302 reaches upstream once, never follows redirect; exact callback/reason once after unavailable mark. Real WS closing publishes before socket Close despite registry ready and retained exact session, with map/writeMu pins released before socket I/O. Read/close callback absence refuses artifact-authority readiness. Terminal502 emits no successful receipt/outcome. This proves approved composition A; it is not a same-request artifact HTTP journey or completion of all T11 paths.

## S2-T07 simultaneous owner stress

Added only `phase4-coordinator/internal/ws/model_admission_owner_stress_test.go`
for this test slice; shared signed fixture and test-only production WS bridges
are owned by the promotion lane. No runtime changes. Test source SHA-256:
`233f8018672a3e654d3d07babf4fd68d06622d7a759a06d5c7bb1f482d851ffb`.

Final command, from `phase4-coordinator`:

```text
go test -race -count=1 -timeout=90s -json -run '^TestPromotionLockOrderAndAvailabilityAllOwners$' ./internal/ws > /tmp/build1-owner-stress-race-final.json
```

Exit 0; package 7.316 seconds; 1 top-level test plus 10 subtests (2 store groups
and 8 executed round leaves), zero failures/skips. JSON SHA-256:
`3516b48347af46959ac62dd5ea29c5efb7112c4fc845d1d7946d0d726e3fa969`.
Each of memory/SQLite executes four rounds against real verified signed feeds,
independent signed Tier2 catalog, persisted billing configuration and actual
stored WS session. Actual full production promotion first reaches
settlement_capable as a positive authority control.

Each round then holds the complete production WS/registry/buyer/billing/Tier2
pin and starts ten real mutation lanes: fresh independent provider registration,
target heartbeat, target receipt rotation/publication, canary failure including
the actual buyer-serving callback, feed reload, billing config publication,
settlement mode change, in-place Tier2 reload, default Tier2 replacement and
actual session close/delete. Registration and receipt publication must succeed;
heartbeat/state/canary results must report the current session. All ten lanes
must complete after release, and none may complete under the held pin.

A failed real Registry.TryPin while the known read pin is retained proves an
actual pending registry writer; goroutine-start notifications alone are not the
contention proof. Sixteen competing complete guards per round must refuse in
under 250 ms. Independently, eight actual promotion attempts, 32 ordinary reads
for another provider, and four public buyer requests run concurrently with
owner mutations and all finish within bounded waits. The candidate remains
network_admitted_unsettled, old full authority cannot pin, and the deleted WS
session stays unavailable. Public routes require exact HTTP 503 and either
`byom_non_settlement_unavailable` or `no_provider_available` (the canary/state
exclusion can precede the authority exclusion), with no success choices/receipt;
authentication, parsing or arbitrary error responses do not pass.

Totals: 80 successful/current mutation lane completions, 128 contended guard
refusals, 64 concurrent production promotion attempts, 256 ordinary registry
reads, 32 denied concurrent public requests and 8 observed actual buyer-serving
callback invocations. Measured deliberately held full pins were 222.375–660.291
microseconds. These measurements cover the test's pin-hold interval, not SQLite
fsync latency. DB-wait exclusion and durable commit timing remain the separately
owned S2-T06/store boundary evidence; this slice makes no universal 250 ms durable
commit guarantee and does not serve a successful inference request.

Earlier runs: initial race passed in 4.529 seconds; concurrency/exact-route
assertions passed in 4.711 seconds. Tightening API return assertions exposed four
legitimate registration refusals (old receipt key racing the separate receipt
rotation), producing a failed 3.578-second run retained at
`/tmp/build1-owner-stress-registration-refusal.json`. The registration lane now
uses its own fresh provider/session/connection while target receipt rotation
remains real; final successful/current assertions are retained. One command was
mistakenly invoked from the repository root and exited before tests because no
Go module exists there; it is not counted as a test run. `gofmt` and scoped
`git diff --check` passed. Combined final audits/gates remain lead-owned.
