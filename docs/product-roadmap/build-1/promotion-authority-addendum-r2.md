# Build 1 promotion authority correction — author addendum R2

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

R2 disposition: `reviews/promotion-authority-r1-astra.md` reviewed R1 digest
`67e3fe8157337bcb40f8fbe6901ca4d3d5966691efaca606195bc96861d44147` and
reported **PROMO-ARCH-M1 (Medium), changes required**. This revision proposes
closing that gap with the transport publication inventory, protocol and real
producer tests below. **Disposition: addressed by author proposal; pending
independent re-review, not reviewer-closed.** R1 and its review remain unchanged.
No runtime implementation is authorized by this revision.

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
| Actual WS transport availability | `internal/ws/server.go`: `sessions` is a `sync.Map`; `sessionFor` checks registry membership and stored-session presence, but does not call `isOpen`. `internal/ws/relay.go`: `providerSession.close` publishes `closedCh` and `closed` under `writeMu`, before registry deletion may happen. | Guard stored session identity and its monotonic availability state (`closing` as well as terminal `closed`). Every local post-registration close or committed-close schedule must first publish ineligibility under that same `writeMu`, as detailed below; preserve the writer for graceful Close frames. Centralize all production session map store/delete sites behind one WS-owned map guard, and pin `writeMu` for the selected session during commit. Registry connection presence alone is insufficient. |
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

## Local transport invalidation inventory and protocol (PROMO-ARCH-M1)

The following inventory comes from all non-test `internal/ws` close and timer
sites plus the cross-package registry-connection close in `internal/buyer`,
not only the paths cited in the review. Locations refer to the inspected
implementation; implementation review must repeat the search because line
numbers will move. `rows.Close` and HTTP response-body closure are unrelated
resources. No production transport producer may rely on eventual read-loop
cleanup to make its local close visible to promotion or fresh readback.

| Producer / current location | Current ordering and R2 requirement |
|---|---|
| `server.go:3514` `closeSession` and callers at 1329 (legacy model-hash deadline), 1987/2616 (post-registration ack failure), 5649 (invalid model identity); `se_liveness.go:152`; `canary_correlation.go:477` | Publish closing at entry before enqueuing the graceful Close frame, either immediate raw close fallback or arming the 100 ms close timer. The timer closes only its captured session's socket. Calling terminal `session.close()` first is forbidden: it closes the writer channel and loses graceful delivery. |
| `server.go:5890` `handleProviderWriteFailure` | Publish closing before callback/rekey recovery work and before raw `conn.Close`; then existing terminal close, map deletion and unavailable-state update outside the publication lock. Repeated calls are idempotent. |
| `server.go:5949` `monitorHeartbeat` | When the existing inactivity/no-active-relay predicates choose teardown, publish closing for the exact captured session before raw close. Do not wait for `handleDisconnect`. Routine heartbeat ticker creation is not itself a committed-close decision. |
| `relay.go:302` `runWriter` failure | Once a write fails, publish closing before completing that failed frame to waiting callers, `failAll`, raw socket close and `onWriteFailure` callback. No IO/callback under the publication lock. The callback may repeat publication harmlessly. |
| `relay.go:386` `writeProbe` timeout | When the timeout branch wins, publish closing before raw close/terminal close. Arming a probe timer alone does not invalidate a potentially successful probe. A failed writer-result branch is already covered by `runWriter` publication before delivering that result. |
| `server.go:4068` `handleDrainStatus` complete | A valid `complete` frame can arrive without a prior `starting` frame. Publish closing for the exact session before close even when the registry still says ready; never assume the earlier draining transition happened. |
| `server.go:6382` `handleBlacklist` | Publish closing before arming the one-minute hard-close timer; retain existing drain frame and policy state updates outside the lock. The captured session remains ineligible even if a later state update tries to mark it ready. |
| `admin_endpoints.go:195` operator reject; `admin_hardware_trust.go:468` `disconnectProviderForTrustRevocation`; `trust_revalidation.go:317` `disconnectAdmittedSessionForTrustRevalidation` | Publish closing before arming each 200 ms callback to `closeSession`. Current prior `MarkState(draining)` is useful exclusion but is not a substitute for monotonic closing because later state changes exist. Preserve drain/Close sequencing and exact old-session identity. |
| `server.go:5106` `CloseAllProviderSessions`; `server.go:5860` `handleDisconnect` | Terminal `session.close()` itself must first publish closing under `writeMu`. Existing channel closure, map deletion and final raw close remain ordered; network close and `failAll` occur outside the lock. Disconnect's later grace timer only removes an already-ineligible registry session; it does not schedule first socket invalidation. |
| `relay.go:1065` `failTier2Rekey`; 1331 `closeProviderForTier2SessionFailure` (including AEAD failure wrapper); 1495 unencrypted response chunk; 1739 encrypted-frame NAK failure | These currently mark unavailable and delete the map before raw close. Keep exact-session registry/map invalidation as an earlier fence; also route terminal close through monotonic publication, with no close or callback under a publication/promotion pin. Do not add a new blocking acquisition of `rekeyMu` from a holder of `writeMu`; release publication lock before existing rekey cleanup. |
| `server.go:3406` `registerProviderSession` closes old socket | The successful registry replacement has already made the old assigned session ineligible under the pool owner lock. That exact old socket may close after replacement; it cannot affect the new session. Do not resolve by provider ID alone and mark the replacement closing. Refused registration did not replace the incumbent. |
| `server.go:5652` no-session fallback in `fenceInvalidModelIdentity` | If no exact stored session exists, guarded promotion cannot qualify it; existing hash invalidation precedes fallback close. If an exact session exists, use `closeSession` and its publication. Map absence is only a valid exception when registration of that same session cannot subsequently publish it; do not infer this from a transient read before registration. |
| `internal/buyer/server.go:8502` `closeProviderConn`, called by `handleProviderFailure` for HTTP 530 and redirects | This also obtains and closes the provider's registry connection. Prior `MarkState(unavailable)` is reversible and not a permanent invalidation fence. Route this production close through a WS-owned exact-session invalidation/close callback, which publishes closing before raw close. Wire the callback before enabling guarded artifact promotion; preserve existing unavailable/recovery policy rather than changing all legacy failures to registry removal. Missing callback must prevent enabling the artifact promotion capability, not permit an unguarded raw-close fallback for a promotable session. |
| `server.go:1561` deferred `handleConn` socket close / `readProviderLoop` exit | Deferred post-auth `handleDisconnect` currently runs before the outer raw close. Preserve that order, and publish closing for the exact registered session immediately on known read-loop termination before diagnostic callbacks/return. Pre-auth exits have no registered session. Capture registration identity/session explicitly where needed; do not rely on a later provider-ID lookup that can select a replacement. |
| `server.go:1472/1479/1495` unauthenticated rejection close timers; `Server.close` and handshake failures before successful registration | These sockets are never published as promotable sessions and are outside the session guard. Preserve their pre-auth Close-frame behavior. Post-registration callers must use the session-aware helper; audit every `s.close(conn, ...)` call against the successful registration point. |

Selected implementation semantics:

1. Add a monotonic session-owned **closing/ineligible** publication separate
   from terminal writer shutdown. A proposed `closingCh` (closed once while
   holding `writeMu`, guarded by a lock-held boolean) permits a lock-free
   availability observation for existing pool callbacks. `closedCh` retains its
   terminal shutdown meaning. Guarded promotion/readback checks both under
   `writeMu`; the lock-free `isOpen`/availability predicate returns false after
   either publication. Never reset closing on heartbeat, state update, operator
   recovery or timer cancellation; a replacement must be a new assigned session.
2. A proposed `beginClosing` acquires **only** the selected session's `writeMu`,
   publishes ineligibility and releases it. A lock-held variant lets terminal
   `close()` publish and close its channels without recursively locking. No
   registry/map/DB/rekey lock, network close/write, timer scheduling, logging,
   event recorder, `failAll` or external callback runs under this publication
   lock. A teardown may wait for a promotion holding `writeMu`; the promotion
   must retain its existing nonblocking try-lock order, so teardown never waits
   for admission serialization while holding `writeMu`.
3. Every unconditional/scheduled local teardown in the table calls that
   publication before raw close or arming its closure timer, unless an earlier
   exact-session registry replacement/removal or guarded map removal already
   permanently excludes it. Use one session-aware scheduling/close helper where
   that removes duplicated ordering risk. Publication does not close `writeCh`
   or set terminal `closed`: graceful Close frames and existing drain/control
   frames still use the single writer and retain their grace intervals.
   This correction need not reject every existing enqueue during graceful
   draining; it rejects admission and availability while preserving the established
   transport drain behavior. New paid routing still uses its existing gates.
4. No network IO happens while the caller holds authority pins. A graceful close
   publisher releases `writeMu`, enqueues its already-built Close frame through
   the existing writer, then arms the grace timer outside locks. Queue-full or
   already-terminal outcomes still schedule/perform the existing hard-close
   cleanup; they never restore eligibility. Existing one-time terminal channel
   closure and close-event deduplication remain intact. Concurrent hard failure
   may prevent graceful delivery, as today; the normal writable grace path must
   still deliver a valid Close frame before the scheduled hard close.
5. A closure timer captures the exact session pointer/socket, never resolves the
   then-current session by provider ID. Once publication completed, the timer
   may perform socket IO without reacquiring promotion pins: no future positive
   guard can pass for that session, and any earlier guard completed before the
   publication. Thus no already-armed close timer can invalidate the socket
   inside a subsequently successful guarded promotion. Timers for probe checks,
   heartbeat checks and warmup readiness are not unconditional close schedules;
   their teardown branch must publish when it decides to close.
6. A producer that completed local invalidation before acquisition must be
   observed even with registry/map/read-loop cleanup paused. If invalidation
   starts while a guard holds the session pin, it serializes afterward; do not
   close the socket or arm its definite-close timer while awaiting publication.
   An external peer/network failure not yet observed remains outside local
   serialization, but known read/write failure is not that exception.

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
   stored **available (neither closing nor closed)** WS session, exact probed generation/identity, ready/busy state,
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
> before the append commits, is insufficient. Coordinator-owned session
> teardown MUST publish session ineligibility under the same serialization
> before closing or committing to a scheduled closure of its socket, unless
> an earlier serialized invalidation already excludes that exact session.
> Graceful transport shutdown MUST NOT defer admission invalidation until
> eventual reader cleanup. Time-bounded authority MUST be
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
| S2-T01 `TestPromotionRejectsAuthorityDriftBeforeCommit` | Cartesian cases: target `catalog_priced` / `settlement_capable`; entry offer / retry; store memory / SQLite. Pause after resolution, before store guard. Mutate separately: replace assigned session, remove session, close stored WS session without registry removal, each real local/scheduled teardown producer in S2-T10, not-ready state, each exclusion flag, pending/new receipt key, canary sanction, effective config ID/rates, enforce→observe, signed feed replacement, Tier2 singleton replacement, Tier2 in-place replacement, resolver removal. Resume. | No new target-positive event or its replay-key reservation. HTTP response is freshly valid lower state, revoked state, or explicit error; never stale positive. Assert complete event history and latest state, not just response. On second boundary a previously valid catalog event may remain historical, but cannot be returned positive after authority drift. |
| S2-T02 `TestPromotionPinsAuthorityThroughCommit` | Same two boundaries/stores, including real local/scheduled teardown producers in S2-T10; pause immediately after guarded validation and, for SQLite, after insert before COMMIT. Start each real mutable-owner operation from T01. Use owner-entry/owner-acquired barriers. Release commit. | Mutator cannot complete authority publication while pins are held; successful promotion precedes mutation. Pins survive return from the transaction callback through actual COMMIT. After mutation, fresh response/status and paid-route selection reject the old authority. A successful event before later invalidation is permitted historical evidence. |
| S2-T03 `TestPromotionCASWinnerReadback` | Pause after resolution; withdrawal, reoffer with fresh tuple, or revocation wins event write; repeat while first promotion succeeds and second is pending. Include exact positive replay after a newer withdrawal. | Newer event remains latest; no stale overwrite; offer/retry return the winning current event or error. No replay path bypasses current-response validation; probe count does not increase on exact replay. |
| S2-T04 `TestPromotionAuthoritySnapshotOwnership` | Publish feeds/rewards, mutate caller-retained byte slices/maps after publication; concurrently attempt replacement through real setters. | Retained aliases cannot mutate owner's accepted authority; setter replacement is serialized. `go test -race` remains clean. Unchanged signed rates match exact integer units; no default-rate fallback. |
| S2-T05 `TestPromotionAuthorityExpiry` | Fake clock at just-before and exactly-at probe/feed/reference expiry; advance while waiting for SQLite write access, between promotion boundaries, and after insertion/before return. | Expired input before the serialized insertion writes no positive event; exactly-at expires. Durable-but-now-expired evidence is never returned positive; recovery/readback refuses it. Original probe deadline is never extended by recheck. |
| S2-T06 `TestPromotionGuardContentionAndCleanup` | Hold each owner write lock before guard attempt; occupy SQLite connection/write transaction separately; inject insert failure, COMMIT failure/uncertainty, canceled context and panic through a guarded test store. | No owner locks held during DB acquisition/wait; Try-lock failure promptly rolls back without loops or events. All pins release on every path; subsequent mutation/promotion succeeds. Reconciliation handles known committed result exactly once and unknown result without positive claim. |
| S2-T07 `TestPromotionLockOrderAndAvailability` | Concurrent registration, heartbeat/receipt update, canary result (including buyer-serving callback), session close/delete, feed reload and Tier2/default reload while repeatedly promoting. Keep separate provider doing ordinary registry reads. | No deadlock/race; bounded guard attempts and selected test count proven. Measure guard-held duration and prove DB wait excluded. Force a pending writer to catch recursive RWMutex read deadlocks. Long durable commit latency is reported, not hidden as a passing 250 ms budget. |
| S2-T08 `TestAdmissionReadbackAfterPromotionRace` | Pause offer/retry after successful promotion, then mutate authority before final observation, including the real teardown producers in S2-T10 with cleanup paused. Repeat original-offer replay, retry replay, throttled retry and status. Cause revoke CAS conflict then store error. | Fresh response rejects drift on every handler path; retry reservation remains idempotent. No positive body on unavailable current readback, no invented coordinator event ID, no repeated synthetic probe. Later paid route remains fail-closed. |
| S2-T09 `TestAdmissionGuardCompatibilityAndReopen` | No drift positive journey; unsupported guarded-store capability; valid legacy record; reopen SQLite with persisted artifact event but no matching live session. | Two positive transitions exactly once with byte-exact evidence and CAS chain. Missing capability leaves pending. Existing legacy digests/states unchanged. Reopen never grants session authority from disk alone. Existing real-service fixture still settles its expected captured-rate amounts once. |

### S2-T10 — real local teardown producers and graceful transport regression

Add `TestPromotionLocalTeardownProducerSerialization` and
`TestAdmissionReadbackLocalTeardownProducerSerialization`, extending T01/T02/T08
with the actual production functions in the transport inventory. Required core
subtests: `closeSession` (including both its grace timer and hard-close fallback),
`monitorHeartbeat` stale/no-active-relay decision, `runWriter` write error,
`handleProviderWriteFailure`, `writeProbe` timeout, and `handleDrainStatus`
complete without starting. Add scheduled producer subtests for blacklist,
operator reject, trust revocation and admitted-trust revalidation, and terminal
producer subtests for shutdown, disconnect/read-loop exit and each Tier2 raw-close
site. Add a buyer fixture subtest invoking real `handleProviderFailure` for
HTTP 530 and redirect with the injected real WS close function; allow a ready
state update between the old unavailable mark and close to expose the original
gap, then prove monotonic closing prevents positive observation. Missing close
callback must refuse guarded artifact-service installation. Direct
`session.close()` tests or a mock guard cannot substitute for these producers.
For scheduling sites the test must invoke the real caller that arms the timer,
not call its eventual closure callback in isolation.

- Run the core producer matrix at both promotion boundaries, offer and retry,
  across memory and SQLite. Also run fresh offer/retry/status and replay readback
  with a previously valid positive event. Keep read-loop cleanup behind a barrier
  so the registry remains ready and the exact session remains stored wherever
  the real producer does not intentionally invalidate those first. Observe actual
  publication/close/timer-armed events through test hooks and a recording `net.Conn`.
- In the invalidate-first ordering, wait for publication and producer completion
  or its definite-close timer to be armed, then release promotion/readback.
  Assert no positive event/response; advance a held warmup/state update to ready
  to prove that closing is monotonic and cannot be erased by readiness. Do not
  release eventual cleanup to make the assertion pass.
- In the guard-first ordering, pause after authority validation and at SQLite
  post-insert/pre-COMMIT. Start the real teardown producer, wait for a hook just
  before it attempts publication, and confirm neither the socket close nor a
  definite-close timer has occurred. Release commit; wait for publication, then
  assert subsequent guarded observation excludes the exact session even before
  registry/map cleanup. This ordering may leave a historical positive event
  committed before invalidation; it must not grant a later positive observation.
- Inject ticker/timeout delivery and closure scheduling behind unexported
  package-local seams that production defaults to the existing Go clock/timers;
  no sleeps, production wire flags or bypass of heartbeat predicates. A writer
  connection that deterministically returns an error drives `runWriter`. A
  blocked write plus controlled timeout drives `writeProbe`; verify error-result
  publication ordering and that a successful probe never marks closing merely
  because its timer was created. Tests inspect the real scheduled callback.
- Add `TestClosingPreservesGracefulCloseFrame`: real session writer, readable
  framed connection, call real `closeSession`, hold its timer, decode exactly
  one normal-path Close frame/code/reason before allowing hard close. Assert
  closing is already visible while the frame is queued/draining, terminal
  `closedCh` retains its previous meaning, and no socket IO occurs while the
  close caller owns publication pins. Existing in-flight/drain frames remain
  serialized, with no direct concurrent socket writer.
- Add `TestClosingDuplicateAndOldSessionIsolation`: overlapping graceful close,
  writer failure, timeout and terminal cleanup; ensure no send-on-closed-channel
  panic, channel double close or duplicate terminal cleanup/event. Replace the
  provider session before an old timer fires: only the captured old socket closes,
  replacement stays available. Refused registration/pre-auth close must not mark
  an incumbent closing. Cover bounded full-queue fallback without revival.
- Rerun the repository's existing writer, write-probe, close/control frame,
  heartbeat, blacklist/reject, hardware-trust and Tier2/rekey tests under `-race`.
  Capture actual guard-held duration under T06/T07; graceful compatibility does
  not waive the stop-and-revise rule for durability-induced lock stalls.

Implementation verification: targeted S2 tests with `-race -count=1` for
`./internal/ws ./internal/buyer ./internal/pool ./internal/tier2` and the affected
billing guard tests owned by the lead; report exact selected tests. Then run
coordinator `go test ./...`, `go vet ./...`, `make lint-coordinator`, existing
gateway tests/vet and affected integration fixture, plus SPEC governance checks.
Zero-selected/skipped/interrupted runs do not pass. Tests in this document have
not been run because this is a plan-only author task.

## Ownership, material design risks and acceptance gate

S2 implementer owns WS promotion/store/response/session-guard and all inventoried local teardown/scheduling work, buyer
authority/feed/config ownership, pool read guard, Tier2 publication guard, and
their focused tests. Lead owns SPEC/governance edits, production wiring,
integration and any billing settlement-config guard API; coordinate exact file
ownership before editing. Do not modify the lead's S1 recovery/credit fix.

Proposed lead-owned billing API after approval:
`func (s *Store) TryPinSettlementConfig(defaultCfg SettlementConfig) (effective SettlementConfig, release func(), ok bool)`.
It calls `settlementMu.TryRLock`; failure returns `ok=false`, nil release and
zero config. Success copies the scalar config, uses `defaultCfg` when
`s.settlement.CadenceDays == 0` exactly as `SettlementConfig` does, and returns
the matching unlock closure. The caller releases exactly once; it must not call
the locking getter while pinned. Lead tests successful/default selection,
contention, setter exclusion until release and reacquisition after release.
This is the only billing source API proposed here; S1 files stay untouched.

For the cross-package transport producer, use a constructor-only buyer option
carrying `func(providerID, assignedID, reason string) error`, implemented by WS
and wired by the lead before admission authority installation. The WS function
pins the exact captured stored session only long enough to publish closing,
releases all locks, then closes that socket and preserves existing cleanup.
It must not substitute the provider's newer assigned session. Absence of an
exact session may be treated as already excluded only with the permanent
absence/registration condition in the inventory. This option is required when
installing the guarded artifact service, is not runtime-swappable, and does not
expose a provider-controlled close capability.

Material risks requiring independent review:

- **Global registry read-lock during local durability:** avoiding connection and
  BEGIN waits prevents the obvious convoy, but slow INSERT/COMMIT can still delay
  registry mutations and WS close. The 250 ms context is not a hard OS bound.
  If realistic contention tests fail the budget, stop and revise the design;
  do not silently hold the pool lock through a full resolver/DB wait or release
  it before COMMIT. A broader per-provider fencing design would require another
  independent plan gate, not ad hoc implementation.
- **Incomplete ownership inventory:** raw/scheduled socket close before closing publication, raw session `sync.Map` writes, unguarded
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
