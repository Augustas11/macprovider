# Build 1 promotion authority correction — author addendum R1

Status: **DRAFT FOR INDEPENDENT ASTRA REVIEW; NOT IMPLEMENTATION APPROVAL.**
Author scope: S2 in `reviews/go-security-current-r1-astra.md`, supplementing
approved `plan-r4.md` / `test-spec-r4.md` B1-T07/B1-T08. This document neither
self-approves the design nor closes S2. Implementation waits for an independent
Astra review of this exact document with 0 Critical/High/Medium findings.

Inspected checkout: `codex/product-build-1`, HEAD/base
`914f7cafcdbcfc1805a10f4f34167218341d5587`, including its existing uncommitted
Build 1 implementation on 2026-09-10. The base commit alone does not identify
that dirty implementation. This author changed only this document. Other
agents own concurrent changes; notably the lead owns billing S1.

## Outcome and bounded contract

An artifact promotion may persist `catalog_priced` or `settlement_capable`
only when one serialized decision validates the same live authority that the
append uses. Admission withdrawal/reoffer/revocation remains protected by
the existing tuple and expected-event CAS. A mutation that completes before
the guarded decision must be visible to it; a mutation overlapping a successful
decision may serialize after it, but cannot alter the authority between its
last validation and durable commit. Each promotion boundary gets its own guard.

Offer, retry (including replay), and status responses must represent a fresh
coordinator observation. An earlier positive event is historical evidence,
not a promise that the provider will remain live after that observation.
Never hold an authority lock while writing an HTTP response. Later route/status
revalidation and immutable settlement validation remain mandatory and unchanged
in strength; this correction does not make a response a paid-routing token.

No global economic activation, sanction exemption, trust-tier change, rate
fallback, new dependency, new provider wire field, production access, physical
conformance claim, or modification of prior settled records is authorized.

## Source evidence and actual owners

Paths below are relative to `phase4-coordinator/`. These are observed current
code facts; the protocol in the next section is proposed work.

| Authority / resource | Current owner and gap | Required correction boundary |
|---|---|---|
| Latest offer, event identity and transition | `internal/ws/model_admission.go`: memory `appendCoordinatorModelAdmissionEvent` holds `memoryModelAdmissionStore.mu`; SQLite equivalent uses `sqliteutil.Transact` and compares `ExpectedCurrentEventID`. Replay resolution precedes CAS. Neither store owns live authority. | Keep existing CAS/replay semantics; add a guarded path for artifact-positive decisions, including replay validation before presenting a replay as current. |
| Provider/session tuple, readiness, receipt key, admission exclusions and canary sanctions | `internal/pool/provider.go`: `Registry.mu`; `Resolve` and `Conn` return after releasing it. `RegisterAtDetailed`, removal, heartbeat/state updates, receipt publication, `SetAdmissionGateFlags` and individual exclusion setters, `SetBenchmarkQuarantine`, `recordCanaryResult`, `LoadCanarySanctions` and `ClearCanarySanction` mutate under it. | A pool-owned guard must read the current provider, connection presence and sanctions under that same lock and retain it until the decision completes. Include all fields consumed by the resolver and exact probed tuple. Ordinary activity counters must not become new eligibility requirements. |
| Actual WS transport availability | `internal/ws/server.go`: `sessions` is a `sync.Map`; `sessionFor` checks registry membership and stored-session presence, but does not call `isOpen`. `internal/ws/relay.go`: `providerSession.close` publishes `closedCh` and `closed` under `writeMu`, before registry deletion may happen. | Guard stored session identity and its open state. Centralize all production session map store/delete sites behind one WS-owned map guard, and pin `writeMu` for the selected session during commit. Registry connection presence alone is insufficient. |
| Signed feed bundle | `internal/buyer/autotune_feeds.go`: `autotuneFeedsMu`, `WithAutotuneFeeds`, `SetAutotuneFeeds`, snapshot getter. Bundle contains byte slices; copying the struct does not copy those bytes. | Pin the owner's read lock through commit; take owned copies on publication/snapshot as needed so caller-retained slices cannot mutate the validated bundle outside the lock. |
| Effective rewards and snapshot ID | `internal/buyer/server.go`: `billingMu`, `WithBilling`, `WithBillingSnapshotID`, `SetBillingConfig`, `billingState`. Rewards contain a rate map, so the returned struct is not an immutable deep copy. | Pin the exact store/config/snapshot tuple; copy mutable map members at the ownership boundary. Old immutable billing snapshot existence is not evidence that it remains the effective snapshot. |
| Settlement enforcement | `internal/billing/store.go`: `settlementMu`, `SetSettlementConfig`, `SettlementConfig`; `buyer.settlementEnforceMode` reads this separately. | Lead-owned tiny lock-held read/guard API if needed. S2 author/implementation lane must not independently edit billing files. Guard this live mode too; pinning buyer `billingMu` alone misses it. |
| Independent Tier2 material | `internal/tier2/catalog.go`: default catalog is an atomic pointer; each catalog also owns mutable `st` under `Catalog.mu`; both `ConfigureDefaultStrict` pointer replacement and `Configure`/`ConfigureStrict` in-place publication exist. | Pin the default pointer with a new package-private publication RW mutex and the selected catalog's state lock. Wrap every default-pointer publication, including test reset helpers. Pinning only the old catalog permits replacement. Loading/verifying a proposed catalog stays outside publication locks. |
| Resolver installation | `internal/ws/model_admission_authority.go`: setter/read getter release `modelAdmissionAuthorityMu` before work. | Guard replacement/disablement of the installed authority service; a previously selected callback is not permanently authoritative. |
| SQLite transaction ownership | `internal/sqliteutil/transact.go`: reserve connection, `BEGIN IMMEDIATE`, callback, then `COMMIT`; callback-local defers run **before** commit. | Admission guarded append must retain the acquired release function outside the transaction callback until `Transact` has committed or rolled back. All transaction statements use the reserved connection. |

`cmd/coordinator/main.go` reload currently publishes Tier2, buyer billing,
settlement config, WS catalog and buyer feeds in separate steps. This plan does
not turn all reload work into a new global transaction. Any intermediate bundle
must independently pass every existing release/rate/reference consistency check;
otherwise promotion remains pending. File verification, billing reload work and
wire probing must not run while holding the commit guard.

## Selected correction: owner locks around the serialized append

Use existing authority owner locks plus narrow missing publication locks,
not a new global authority coordinator and not a second unguarded resolver call.
Retain the read-only resolver for routing; add an internal prepared-authority
result for promotion with immutable evidence and a non-serializable,
coordinator-owned guard factory. Provider data cannot construct that factory.

1. Run the bounded authenticated wire probe and full authority resolution outside
   the critical section. Capture owned authority values: exact provider/session
   and receipt tuple; candidate/artifact/rate byte identities and proofs;
   effective billing store/config ID and signed units; Tier2 pointer/material;
   enforcement mode; original probe time and authority expiration. Do not extend
   the probe lease when revalidating. Preserve independently loaded Tier2 and
   `VerifyArtifactAdmissionConfig` checks. This stage does not authorize append.
2. Enter the admission store's write serialization first: memory mutex, or a
   reserved SQLite connection and successful `BEGIN IMMEDIATE`. DB connection
   waits and write-lock waits therefore hold **no pool/feed/config locks**.
   Keep all existing transition checks and event CAS inside this serialization.
3. Attempt to pin authority owners without blocking: use `TryRLock`/`TryLock`
   with immediate release of all acquired locks on failure. Fixed acquisition
   order: WS resolver installation; WS session-map publication; selected session
   `writeMu`; registry; buyer feeds; buyer billing tuple; billing settlement mode;
   Tier2 default publication; selected Tier2 catalog state. Release in reverse.
   An unavailable lock yields pending/retryable authority, not spin/retry under
   the SQLite write lock. This avoids waiting on an existing inverted writer
   order, including pool callbacks into WS/Tier2. There is no blocking owner-lock
   acquisition while another owner lock or admission write transaction is held.
   Session-map publication helpers hold their new lock only around the map
   operation; they must release it before registry mutation, `session.close`,
   network IO or callbacks. Existing lock-free map readers may remain lock-free;
   only the guarded promotion reader needs to pin publication. Do not introduce
   a blocking map getter under the registry's buyer-serving callback.
4. Under all pins, compare captured authority to lock-held current views and
   rerun the complete current eligibility checks. Do not call `Resolve`, `Conn`,
   `CanarySanctions`, `billingState`, `SettlementConfig`, `SnapshotMaterial`, or
   any other locking getter recursively. Supply private lock-held snapshot
   helpers; compare owned immutable values, not aliased slices/maps. Validate
   stored **open** WS session, exact probed generation/identity, ready/busy state,
   current exclusions/sanctions, no pending receipt rotation, and all existing
   catalog/rate/material predicates. A current bundle that differs from the
   resolved evidence is rejected; rebuilding evidence requires leaving this
   transaction and resolving again. The same rule applies to resolver replacement.
5. Recheck real clock/context immediately before the event insertion. Use the
   minimum probe/feed/reference expiry as an operation deadline; already expired
   or canceled input rejects before a write. Append the exact prepared evidence
   with expected event CAS, keeping every pin through successful SQLite COMMIT
   or rollback (memory: through actual append). A callback-local `defer release`
   is specifically forbidden because `sqliteutil.Transact` commits afterward.
   No second DB connection, full resolver, signature/file IO, wire traffic,
   callbacks into pool mutations, or network response is allowed in this region.
6. Release guards and transaction resources on every path. Perform final fresh
   response observation as described below. If elapsed time exhausts the lease
   during durable completion, suppress a positive response and revoke/read back;
   never treat an expired historical event as current capability. The guard
   serializes mutable authority; it does not stop wall-clock time or external
   physical disconnection that the coordinator has not yet observed.

The guarded store capability is mandatory for artifact-positive runtime appends.
If a supplied store does not implement it, promotion stays pending; there must
be no silent fallback to ordinary `AppendModelAdmissionDecision`. Protect the
ordinary append path against introducing an unguarded artifact-positive decision.
Legacy catalog paths and non-positive decisions retain existing behavior.
Adapt fixture seeding to explicit test helpers or a real fixture guard rather
than introducing an exported production bypass.

An implementation may split helpers into small owner-local files. It must not
change the generic SQLite transaction helper's behavior for every caller merely
to implement this admission-specific guard. A release closure owned outside
`Transact` is sufficient. The default target for the guarded local INSERT/COMMIT
is a 250 ms context budget, reduced by request/authority deadlines; this is an
availability budget, not a claim that Go cancellation can preempt a stalled OS
or that a failed COMMIT response proves no durable write occurred.

## Response, replay, failure and recovery

Use one fresh-current-response path for offer, retry and status, including
original-offer replay, retry replay, promotion failure, and rate-limit early
return from a retry. Do not echo the selected pre-probe event on append/CAS
failure. Reload the latest event under store serialization and validate positive
artifact evidence under the same owner pins. Capture the response observation
while serialized, then release before JSON/network IO. A subsequent overlapping
mutation may occur after that observation; subsequent route/status must reject
it. Do not advertise the commit timestamp as a fresh observation timestamp if
the observation occurred later.

If current positive evidence is invalid, attempt the existing CAS revocation,
then read the winning latest event. On a revocation race, retry read/validation
at most once; if still contended or unreadable, return a transport error with no
positive capability body. Do not fabricate a demotion event ID or return an
older `catalog_priced` state whose authority just failed. A still-valid lower
state may be returned only after this fresh observation. Retry journal completion
records its historical outcome as before; replay response uses the current
observation and must not re-probe or append duplicate positive transitions.
Release the current-read serialization before calling an ordinary store append,
or use a private same-transaction append helper; never recursively acquire the
memory store mutex or a second SQLite connection to perform that revocation.

Guard contention/authority change before insertion rolls back without reserving
decision replay keys or appending an event. Existing provider offer/retry
reservation rules and bounded probe throttles stay intact. A failed DB write,
context cancellation, panic, or uncertain COMMIT result releases pins only after
transaction cleanup. Do not retry a positive write blindly: reconcile by latest
event/idempotency identity and freshly validate; failure to establish a known
outcome returns an error. A restarted process has no usable old live session;
persisted positive records must revalidate against the new session and existing
immutable evidence. Historical events remain for audit; no deletion/repricing.

## Normative confirmation and required wording

SPEC-047 v0.1.4 already requires commit-time current authority checks and
expected-event concurrency control in the R001/R003/R006 clarification. This
fix confirms that contract; it does not need a new state, tier, authority source,
SPEC-010 identity amendment, SPEC-022 snapshot extension or provider schema.

Before runtime implementation, lead should add this precise clarification to
that SPEC-047 paragraph and extend its R008 tests (with the normal version/index
update):

> For artifact-derived promotion, validation and event commitment MUST be
> serialized against mutation of the current provider/session and receipt
> authority, exclusions/sanctions, effective billing/enforcement configuration,
> authenticated feed bundle, and independent reference material. An admission
> event compare-and-swap alone, or a fresh authority read whose protection ends
> before the append commits, is insufficient. Time-bounded authority MUST be
> valid at the serialized decision and MUST NOT be represented as current after
> its expiry. Offer, retry and status readback, including replay, MUST validate
> the latest positive outcome as a current observation; inability to establish
> current authority MUST return non-paid state or a transport error without a
> positive capability claim. Later routing and settlement checks remain required.

R008 must explicitly require deterministic races before each of the two
promotion appends and during guarded commitment for session replacement/close,
exclusion/sanction, billing/enforcement, feed and reference replacement; include
response/replay readback and rollback tests. The clarification describes logical
serialized decisions; it must not claim perpetual response validity or weaken
the existing lease/probe check to validation solely at probe time.

## Exact test addendum (required, not yet executed)

Use channel barriers/test hooks that expose real resolve, guard-acquisition,
append and commit boundaries. Never use `Sleep` to order the race. Hooks are
unexported/test-scoped and cannot change production authority. Run each storage
case with `runAdmissionStores` (memory and SQLite); exercise actual offer and
retry HTTP handlers with authenticated fixture identities. Signed feed/config
cases use the existing buyer fixture loader and real prepared authority service,
not a resolver that returns a caller-built success regardless of live state.

| ID / suggested test | Setup and deterministic interleaving | Required assertions |
|---|---|---|
| S2-T01 `TestPromotionRejectsAuthorityDriftBeforeCommit` | Cartesian cases: target `catalog_priced` / `settlement_capable`; entry offer / retry; store memory / SQLite. Pause after resolution, before store guard. Mutate separately: replace assigned session, remove session, close stored WS session without registry removal, not-ready state, each exclusion flag, pending/new receipt key, canary sanction, effective config ID/rates, enforce→observe, signed feed replacement, Tier2 singleton replacement, Tier2 in-place replacement, resolver removal. Resume. | No new target-positive event or its replay-key reservation. HTTP response is freshly valid lower state, revoked state, or explicit error; never stale positive. Assert complete event history and latest state, not just response. On second boundary a previously valid catalog event may remain historical, but cannot be returned positive after authority drift. |
| S2-T02 `TestPromotionPinsAuthorityThroughCommit` | Same two boundaries/stores; pause immediately after guarded validation and, for SQLite, after insert before COMMIT. Start each real mutable-owner operation from T01. Use owner-entry/owner-acquired barriers. Release commit. | Mutator cannot complete authority publication while pins are held; successful promotion precedes mutation. Pins survive return from the transaction callback through actual COMMIT. After mutation, fresh response/status and paid-route selection reject the old authority. A successful event before later invalidation is permitted historical evidence. |
| S2-T03 `TestPromotionCASWinnerReadback` | Pause after resolution; withdrawal, reoffer with fresh tuple, or revocation wins event write; repeat while first promotion succeeds and second is pending. Include exact positive replay after a newer withdrawal. | Newer event remains latest; no stale overwrite; offer/retry return the winning current event or error. No replay path bypasses current-response validation; probe count does not increase on exact replay. |
| S2-T04 `TestPromotionAuthoritySnapshotOwnership` | Publish feeds/rewards, mutate caller-retained byte slices/maps after publication; concurrently attempt replacement through real setters. | Retained aliases cannot mutate owner's accepted authority; setter replacement is serialized. `go test -race` remains clean. Unchanged signed rates match exact integer units; no default-rate fallback. |
| S2-T05 `TestPromotionAuthorityExpiry` | Fake clock at just-before and exactly-at probe/feed/reference expiry; advance while waiting for SQLite write access, between promotion boundaries, and after insertion/before return. | Expired input before the serialized insertion writes no positive event; exactly-at expires. Durable-but-now-expired evidence is never returned positive; recovery/readback refuses it. Original probe deadline is never extended by recheck. |
| S2-T06 `TestPromotionGuardContentionAndCleanup` | Hold each owner write lock before guard attempt; occupy SQLite connection/write transaction separately; inject insert failure, COMMIT failure/uncertainty, canceled context and panic through a guarded test store. | No owner locks held during DB acquisition/wait; Try-lock failure promptly rolls back without loops or events. All pins release on every path; subsequent mutation/promotion succeeds. Reconciliation handles known committed result exactly once and unknown result without positive claim. |
| S2-T07 `TestPromotionLockOrderAndAvailability` | Concurrent registration, heartbeat/receipt update, canary result (including buyer-serving callback), session close/delete, feed reload and Tier2/default reload while repeatedly promoting. Keep separate provider doing ordinary registry reads. | No deadlock/race; bounded guard attempts and selected test count proven. Measure guard-held duration and prove DB wait excluded. Force a pending writer to catch recursive RWMutex read deadlocks. Long durable commit latency is reported, not hidden as a passing 250 ms budget. |
| S2-T08 `TestAdmissionReadbackAfterPromotionRace` | Pause offer/retry after successful promotion, then mutate authority before final observation. Repeat original-offer replay, retry replay, throttled retry and status. Cause revoke CAS conflict then store error. | Fresh response rejects drift on every handler path; retry reservation remains idempotent. No positive body on unavailable current readback, no invented coordinator event ID, no repeated synthetic probe. Later paid route remains fail-closed. |
| S2-T09 `TestAdmissionGuardCompatibilityAndReopen` | No drift positive journey; unsupported guarded-store capability; valid legacy record; reopen SQLite with persisted artifact event but no matching live session. | Two positive transitions exactly once with byte-exact evidence and CAS chain. Missing capability leaves pending. Existing legacy digests/states unchanged. Reopen never grants session authority from disk alone. Existing real-service fixture still settles its expected captured-rate amounts once. |

Implementation verification: targeted S2 tests with `-race -count=1` for
`./internal/ws ./internal/buyer ./internal/pool ./internal/tier2` and the affected
billing guard tests owned by the lead; report exact selected tests. Then run
coordinator `go test ./...`, `go vet ./...`, `make lint-coordinator`, existing
gateway tests/vet and affected integration fixture, plus SPEC governance checks.
Zero-selected/skipped/interrupted runs do not pass. Tests in this document have
not been run because this is a plan-only author task.

## Ownership, material design risks and acceptance gate

S2 implementer owns WS promotion/store/response/session-guard work, buyer
authority/feed/config ownership, pool read guard, Tier2 publication guard, and
their focused tests. Lead owns SPEC/governance edits, production wiring,
integration and any billing settlement-config guard API; coordinate exact file
ownership before editing. Do not modify the lead's S1 recovery/credit fix.

Material risks requiring independent review:

- **Global registry read-lock during local durability:** avoiding connection and
  BEGIN waits prevents the obvious convoy, but slow INSERT/COMMIT can still delay
  registry mutations and WS close. The 250 ms context is not a hard OS bound.
  If realistic contention tests fail the budget, stop and revise the design;
  do not silently hold the pool lock through a full resolver/DB wait or release
  it before COMMIT. A broader per-provider fencing design would require another
  independent plan gate, not ad hoc implementation.
- **Incomplete ownership inventory:** raw session `sync.Map` writes, unguarded
  Tier2 pointer publication, caller-aliased feed/config data or an unpinned
  settlement mode can reopen S2. Search every assignment/store/delete and getter
  call during implementation review. Existing registry callbacks and recursive
  read locks make a naive nested-lock callback unsafe; try-lock plus lock-held
  views is essential.
- **Temporal/observation limits:** physical disconnect before the coordinator
  learns it is outside the guard. Time expiry remains independently enforced;
  an event valid when ordered can be expired when durability returns. Responses
  must suppress that capability. No transport response can promise future live
  availability after its final observation.
- **Process boundary:** these owners are in-process authority. This is not a
  distributed fencing protocol for two coordinators sharing session ownership.
  Do not claim multi-writer deployment safety without separate architecture and
  database authority design.
- **Partial promotion / commit uncertainty:** failure at the second append must
  not echo a stale first positive result. Guarded fresh readback and bounded CAS
  recovery are required, including uncertain durable outcomes.

Acceptance requires the independent exact-document Astra 0C/H/M gate before
implementation, fresh passing tests above, no unguarded artifact-positive append
or stale replay response path, preserved later fail-closed routing/settlement,
and independent complete combined-diff code/security/architecture audits with
0 Critical/High/Medium findings. The author provides no self-approval. Physical
and production acceptance remain separate, unchanged Build 1 obligations.
