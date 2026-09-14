# Build 1 test specification — origin/main 1d2 reconciliation r3

Status: **PROPOSED; no test in this document has been run by this artifact**.
This specification pairs with
`origin-main-1d2-reconciliation-plan-r3.md` at exact base
`1d2c930bad81704dd0acc0322226725d8b64aceb`. An independent GPT-5.6 Sol review
of the exact pair must report zero Critical, High, and Medium findings before
source or test implementation.

The dirty Build 1 worktree remains based at
`914f7cafcdbcfc1805a10f4f34167218341d5587`. The rejected R4 implementation,
current origin, and exact active Slice 5 snapshot are prerequisites and cannot
be assumed as landed.

## Evidence rules

Every run records command, working directory, base/head SHA, complete source and
test manifest digest, selected/pass/fail/skip counts, duration, exit status,
runtime/tool versions, fixture manifest, and complete log SHA-256. A
zero-selected, skipped, interrupted, timed-out, historical, or fixture-only run
cannot pass current integration, Xcode, physical MLX, release, Docker, deployed,
or production acceptance.

Use isolated temporary config, cache, artifact, journal, cursor-key, identity,
database, and service roots. Fail if tests access operator-default roots,
Keychain operator items, payout material, nonlocal endpoints, production
provider state, or secrets. Scan logs for credentials, grant handles, keys,
cursor plaintext, raw feeds/envelopes/receipts, account scope, paths/file
identity, journals, buyer prompts/outputs, and payout data.

Each normative test records a governing SPEC selector and proves nonzero
selection. Go concurrency tests run under `-race`. SwiftPM CLI and generated
Xcode MalibuTests are separate. Docker integration is blocked unless the daemon
is ready.

## Test matrix

### 1D2-R3-T01 — recovery, exact base, and active-work checkpoints

Verify the private backup ref resolves to 914f7, the bundle verifies, tracked/
untracked manifests reproduce the source tree, permissions are 0700/0600, and
secret/build/cache/unrelated paths are absent. Restore package-lock provenance.

Independently reproduce the R3 Slice 5 snapshot: HEAD `72eeaec7cf80e3f8c1f71d1754c57c87417038e8`, merge base
`1d2c930...`, five commits, 18 dirty tracked, 13 untracked, 40 cumulative
paths, and manifest digest `f6cddfeb50603df2f0db00e2210ce3d0098a03e060284f39a98c725c80683527`. Compare every path/hash/state, not
only counts. Repeat after fetch/prune at every checkpoint named in the plan.
Advance origin, edit a Slice 5 byte, add/remove/rename a path, and change its
HEAD independently. Unmerged Slice 5 movement must refresh the timestamped
dependency manifest without invalidating the exact 1d2 docs-only gate or
interfering with that session. It blocks only an overlapping source slice.
Landing Slice 5, changing a planned shared path before replay, or changing its
authority/schema/owner/lock/test contract must preserve the integration branch,
regenerate impact and per-build/cumulative manifests, and reopen the affected
plan gate. A non-overlapping change records the new snapshot and permits other
approved work to continue. Prove Build 1 neither modifies the Slice 5 worktree
nor copies its dirty/untracked content. Shared-file implementation remains
blocked until the named prerequisite/landed/abandoned disposition is recorded.

### 1D2-R3-T02 — landed 1d2 authority baseline

Freshly run race tests for `internal/artifactidentity`, `internal/tier2`,
`internal/ws` admission/operator/pending/release/route logic,
`internal/buyer`, `internal/pool`, and billing route/receipt paths. Freeze golden
bytes for old event/pending rows, status v1, no-extension routes, c944 six-field
routes, and legacy ledger behavior. Prove 1d2 operators/dual control are the
only current production positive origin while documenting the generic store API
as the correction target. Historical green runs do not satisfy this test.

### 1D2-R3-T03 — signed-feed producer, server, release, and fallback

Regenerate the artifact feed from exact release inputs and verify canonical
bytes, signature/key ID, body hash, candidate/primary member, release/version
compatibility, expiry/freshness, positive integer size, headers, cache rules,
atomic publication, and app/tarball baked byte identity. Test current/previous
key rollover, cross-release feeds, stale/not-yet-valid signatures, truncated/
duplicate/unknown JSON, non-JCS, redirect/cross-origin/downgrade, HTTP cache
poisoning, partial release, and mismatched catalog/member/size. An invalid live
response never promotes fallback in the same refresh; fallback is eligible only
under the explicit network-unavailable policy and its own release checks.

### 1D2-R3-T04 — provider parser, source choice, and size authority

Use independent feed encoders and real CLI parser/actions. Accept only the
trusted signer/release/freshness/candidate/member and safe integer
`size_bytes > 0`. Missing, zero, negative, fractional, exponent, string,
overflow, unsafe-JCS, duplicate, and mismatched values remain browse-only and
create no transaction, staging, reservation, config, journal, or offer. Prove
live/fallback provenance and UI economics/readiness do not imply admission.

### 1D2-R3-T05 — discovery and unsupported/non-primary handling

Test clean install, incumbent, prepared inactive, adopted, stale/corrupt local
artifact, supported primary MLX, non-primary member, GGUF, unknown runtime,
listed/nonrecommendable row, and incompatible release. Only supported primary
MLX has prepare/adopt actions. Discovery is path-free and bounded; provider
assertions never become trusted model or price identity.

### 1D2-R3-T06 — exact-size durable preparation

Run real local metadata → capacity reservation → owned staging → streaming →
full digest/manifest verification → fsync/atomic publish → durable readback.
Assert the declared byte ceiling independently of Content-Length/chunking,
including early EOF and one-byte overflow. Inject downloader, digest, copy,
fsync, rename, journal, quota, ENOSPC/EDQUOT, and readback failure. Every failure
is typed, non-ready, recoverable, and preserves the incumbent.

### 1D2-R3-T07 — cancellation, crash, cleanup, and replay journal

Cancel/crash at every journal/filesystem boundary before/after publication,
including duplicate cancel, SIGINT, reconnect, polling deadline, concurrent
same/different target, and prepare/adopt race. Before commit all incumbent
state is byte-identical; after commit cancel is `too_late` and the artifact is
prepared inactive. Cleanup proves ownership and never follows symlinks or
deletes active/prepared/rollback/journal/foreign files.

Persist outbound offer before send. Exact lost-response replay reproduces every
byte and creates no second probe/event/window mutation. Explicit fresh
re-evaluation changes request ID, timestamp, nonce, idempotency key, digest,
signature, and bytes while preserving protected tuple fields and rechecking
current authority. Conflicting replay and concurrent fresh retries fail under
closed CAS/rate rules.

### 1D2-R3-T08 — adoption and candidate runner

Use complete prefetched artifacts and a downloader spy that must remain
uncalled. Missing/corrupt bytes fail before runner creation. Runner output alone
supplies benchmark values. Test memory pressure, timeout, cancel, child crash,
malformed output, and drain/swap/rollback failures; the prior lifecycle/config
is preserved. Revalidate bytes immediately before activation.

### 1D2-R3-T09 — compiler-enforced transition-store boundary

External-package compile fixtures import `ws`, `buyer`, `billing`, `pool`,
`auth`, and `modeladmission`. Assert none can construct a concrete store, raw
event transaction, arbitrary positive command, actor-bearing command, or call a
method accepting `Event`, SQL executor, arbitrary state, or arbitrary actor.
`go doc`/API inventory must show only the exact service constructor and closed
methods from the plan. A new helper file in package `ws` must fail to find raw
positive mutation. Production archive/symbol and dependency scans must contain
no old `AppendModelAdmissionDecision`, `CASAppendModelAdmissionDecision`,
`AppendModelAdmissionApproval`, `promoteModelAdmission`, raw positive INSERT,
or test seeder.

Runtime-table every caller: offer, withdrawal, probe, lifecycle drift, status
adapter, artifact preparation, signed provider assertion, buyer resolver,
release publisher, stale replay, arbitrary WS helper, and app/CLI. None can
create `catalog_priced` or `settlement_capable`. Closed constructors reject
wrong targets/reasons.

Issue real auth grants and test nil, zero, fabricated bytes, expired,
wrong-purpose, wrong-request-digest, copied pointer sequential/concurrent replay,
and already-consumed grants. All fail before mutation. The valid grant works
once only. WS has issuer but not verifier; modeladmission has verifier but no
credential parser. Test dependency graph for that separation and import-cycle
absence. Positive test setup uses authenticated HTTP operator endpoints only;
test-only raw seed code is confined to the trusted package's `_test.go` files.

### 1D2-R3-T10 — dual control, atomicity, restart, and deterministic readiness

Drive catalog-priced and settlement-capable decisions through named operator
HTTP endpoints. First settlement request creates one pending and no positive
event; a distinct operator approves after fresh head/session/release/member/
key/rate checks. Barrier and kill tests before/after pending read, grant consume,
event insert, pending consume, commit, and response prove only old head plus
unconsumed pending or one positive event plus consumed pending can persist.
Memory/SQLite, restart, lost response, and concurrent approvers converge.

Create multiple pending histories for one candidate: active, expired,
invalidated-by-current-head, invalidated-by-other-head, consumed, later active,
equal timestamps/different IDs, and records outside retention. Assert the exact
R3 precedence, one-active constraint, 24-hour boundaries, invariant violation →
unknown, later-active priority, and memory/SQLite/restart parity. Reject same
actor, stale head, illegal edge, expiry, consumed/invalidated pending, session/
release/member/key/rate drift, and conflicting idempotency without leaking actor
or credential facts.

### 1D2-R3-T11 — release/provider/decision lock graph

Under `-race`, pause release staging/publication, provider section/registry,
release read, grant issue/consume, event/pending transaction, route price
reservation, postcheck, dispatch event append, provider acceptance, receipt,
and activity read. Preserve provider section → registry → release-read; operator
auth before admission locks; one memory mutex/SQLite transaction for approval;
no provider/release lock during billing I/O; no callback under billing DB lock;
and no live authority accessor during settlement/activity. Race reload,
heartbeat, disconnect, withdrawal, revocation, operators, config reload,
receipt, activity pages, SQLite busy, and context expiry. Require bounded
completion, coherent outcomes, released locks, and no leaks/deadlocks.

### 1D2-R3-T12 — single persisted pricing authority

Create config snapshots A and B whose IDs, hashes, exact rates, cache rates,
completion rates, shares, multipliers, formula versions, caps, and all three freshness
thresholds all differ. Barriers at validation, snapshot insert/commit, memory
publication, route selection, row read, contract construction, route insert,
and postcheck must yield a contract reproduced wholly from exactly A or B.
Independently strict-decode canonical config bytes, recompute the full hash, and
derive the expected contract; never use the contract under test as oracle.

Corrupt/miss/duplicate config rows; mutate canonical bytes/hash/types/unknown
keys; cross-wire ID/hash; remove exact key while leaving normalized/default
keys; inject reload failure before/after commit. Route reservation must fail
pre-dispatch with no route/dispatch/attempt/charge/credit unless one complete
valid persisted row can be selected. Assert `BYOMRouteIdentity` cannot carry any
economic input and a caller cannot separately supply a snapshot ID or rate.

### 1D2-R3-T13 — route/dispatch/acceptance crash matrix

For a valid exact-key contract, kill/fail at route insert, route-reserved event,
each route postcheck, serialization, before first socket byte, mid-write, after
write completion, before/after provider acceptance verification, acceptance
append, first output, response terminal, and recovery. Assert the exact legal
dispatch event chain, CAS/idempotency, prior-state digest, tuple binding, and
closed failure reason.

A live bare route is `dispatch_pending`; restart recovery closes a pre-write
orphan as no-charge `pre_dispatch_aborted`. Failed postcheck, failure-before-
write, write-started/completed without valid acceptance, invalid/wrong-session/
provider/candidate/model/route acceptance, old provider lacking capability, and
crash uncertainty never become `receipt_pending`, never auto-resend, and create
no debit/credit. Only a valid
signed `request_accepted.v1` on the selected connection permits receipt waiting.
Test a valid signed `request_rejected.v1` as terminal/no-charge and reject a
forged, wrong-tuple, or post-acceptance rejection. Duplicate identical
acceptance/rejection is idempotent; changed bytes conflict. Preserve legacy/
non-BYOM protocol and route digests byte-for-byte.

### 1D2-R3-T14 — immutable settlement pricing and compatibility

Give catalog model ID/key, request/served/provider model, artifact/row/member
hashes, normalized alias, and default distinct rates. Only exact accepted
catalog key can reserve a BYOM route. Freeze independent contract bytes/digest
and assert route digest/direct columns/ledger/reconciliation references.
Mutate every field, direct column, canonical bytes, digest, usage, or join;
settlement fails closed.

After route insertion change current rate card, multiplier, share, formula,
cap, freshness policy, release, catalog, keyring, and session. Instrument all
live accessors to panic during hot path, receipt, recovery, reconciliation, and
replay. The immutable route contract computes the same bounded debit/provider
credit once. Test cache rate, rounding, overflow, cap edge, partial/error/cancel,
delayed/duplicate receipt. Load historical no-extension and c944 six-field
fixtures; bytes/digests remain exact, no backfill occurs, no dirty 24-field
envelope appears, and non-BYOM `RateFor` normalization/default behavior remains.

### 1D2-R3-T15 — readiness v2 and auth error matrix

Freeze exact readiness success fields/nullability and strict client parsing.
Test no offer, unsettled, priced, active pending, exact expiry boundaries,
invalidated-by-current-head within/after retention, unrelated head change,
consumed approval, multiple-history precedence, invariant violation, and store
failure. Response/logs contain no pending ID, digest, actor, reason, credential,
other candidate/provider, or operator configuration. Provider B, buyer token,
shared operator key, and unauthenticated clients cannot read A.

For readiness and activity independently inject: tokens disabled; validator
nil; read-only capability missing; missing bearer; invalid, revoked, and expired
bearer; validation deadline; backend error; admission store error; billing store
error. Assert the exact R3 status/code/body and redacted logs. A backend error is
never 401. Freeze existing status-v1 response and error bytes unchanged,
including its historical validator-error mapping. Old/capability-missing clients
render unknown rather than pending/positive.

### 1D2-R3-T16 — exhaustive provider activity, opaque pagination, and freshness

Generate table tests directly from the R3 precedence table, then independently
seed every valid and invalid tuple. Assert exact provider/scope/request/attempt/
route/candidate/key/contract/verdict/ledger/reconciliation joins, latest
monotonic generation, reversal/quarantine precedence, zero terminal state, and
the sole `settled_verified` case. Seed duplicates, missing rows, wrong hashes,
cross-scope/provider/candidate references, mismatched amount, negative/overflow,
bad generation, and valid receipt without reconciliation; expected results are
closed exactly as specified. Weekly batching fields cannot alter or appear in
the response.

Seed two providers, multiple candidates, >100 routes, and concurrent inserts.
First-page grammar accepts only candidate+limit; continuation accepts only
cursor+limit. Test limits 1/2/100, empty/end pages, fixed high-water traversal,
no gaps/duplicates/reordering, random public activity IDs, no global row IDs,
and indexed bounded queries under `MaxOpenConns(1)`. Tamper every cursor byte;
truncate, replay, expire, rotate keys, restart, use unknown generation, switch
provider/candidate/schema, and enumerate arbitrary ciphertext. Every invalid
case returns indistinguishable `400 invalid_cursor`, leaks no existence/scope,
and cannot change the filter. Previous key works only through 15-minute TTL.

At exact dispatch/receipt/reconciliation stale thresholds assert `fresh` then
`stale_open`; terminal rows stay terminal. Freeze authoritative started,
last-transition, snapshot-observed timestamps and integer age. Test week-old
open route, delayed verdict, delayed reconciliation, restart, clock boundary,
and local cached last-known response after 503. Refresh cannot make old state
fresh. Admission alone produces no activity. No response says payout,
withdrawable, USDC/payment, current earning, confirmed idleness, or transferable
funds and no buyer content/scope/receipt bytes/signatures/paths/operators leak.

### 1D2-R3-T17 — truthful CLI and Malibu.app composition

Run SwiftPM command tests and generated Xcode MalibuTests separately. Exercise
real prepare/status/cancel/cleanup/adopt/offer/exact-replay/fresh-reevaluation/
withdraw/readiness/activity and pagination with independent capability
negotiation. Cover positive/unknown size, malformed/nonmonotonic JSONL, CLI
restart, >30-second response, timeout, late terminal, auth backend unavailable,
cursor expiry/restart, accessibility, localization, and old CLI.

Prepared, active, unsettled, priced, awaiting second operator,
settlement-capable, dispatch pending, pre-dispatch aborted, provider rejected,
dispatch unknown, receipt pending,
reconciliation pending, request settled with credits, zero, quarantined,
reversed, stale, last-known, and unknown are distinct. Economics never imply
eligibility; request settlement never says paid/withdrawable; operator actions
are absent.

### 1D2-R3-T18 — drift, expiry, unsupported, and local GGUF retry proof

Table-drive release compatibility/restamp, member/feed/signer/row/Tier2/runtime/
model/hash/session/key/sanction/probe changes and withdrawal/revocation. New
routes bind exact current identity/price or fail typed and unpaid. Sweeps use
closed negative reasons only.

GGUF retry reopens one no-follow private file and checks the separately approved
complete identity plus recomputed digest under deadline. Reject mismatch,
symlink, missing/partial/unknown journal, advisory-cache-only proof, or leaked
path/file identity before network mutation. Legacy records may read/reconcile/
withdraw but cannot gain missing proof or paid authority.

### 1D2-R3-T19 — exact R4 prerequisite

Reproduce the R2 twelve-path/hash baseline and fail on missing/additional/
renamed/symlinked/mismatched transaction files. Require a later final R4 plan,
test, zero-C/H/M review, isolated implementation commit/tree, full closure
manifest, fresh nonzero targeted logs, real-death/filesystem/max-shape evidence,
and zero-C/H/M code/security/architecture audits. The rejected implementation's
79 historical passes cannot satisfy this gate. Reopen Build 1 if final R4
ownership, capacity, commit, cancellation, or recovery differs.

### 1D2-R3-T20 — governance, Slice 5, broad checks, and audits

Retain 1d2 SPEC-010 v1.8/SPEC-047 v0.1.5 and selectors until a current
checkpoint determines the successor. If Slice 5 lands, rebase/reinspect/re-gate
and preserve its SPEC-017/SPEC-023/SPEC-047/intake contracts. If it remains a
dependency, require an exact committed reviewed base and distinguish per-Build1
from cumulative diff. If abandoned, record owner disposition and begin from
fresh origin. Never copy its dirty files. Run governance generation/check,
changed selectors, and PR declaration validation; reject index/version drift or
activation/qualification claims.

After targeted success run full Swift, generated Xcode MalibuTests,
coordinator/gateway/integration Go and changed-path race tests, vet, lint,
builds, Docker/PostgreSQL integration when available, dist/release/feed corpus,
and secret/dependency/path scans. Three independent GPT-5.6 Sol code, security,
and architecture lanes review the exact full rebased diff. Fix/repeat to zero
Critical/High/Medium and disposition all Low/Info. Resnapshot after fixes and
before PR.

### 1D2-R3-T21 — isolated executable end-to-end journey

With isolated services and deterministic provider, run actual CLI/app:

`discover positive-size target → prepare → adopt → offer → unsettled probe →
authenticated priced decision → deterministic readiness → distinct approval →
settlement capable → buyer request → atomic route/price reserve → postcheck →
signed provider acceptance → receipt → exact reconciliation → opaque paginated
provider activity`.

Repeat cancellation, reconnect, coordinator/CLI restart, exact replay, fresh
re-evaluation, route/dispatch crash points, delayed receipt/reconciliation,
cursor rotation/expiry, release reload, and rate/model drift. Assert one route,
one accepted dispatch, immutable price evidence, one debit/credit, exact state
oracle, and truthful age/last-known UI. This is local integration, not physical
MLX. Docker-dependent evidence is blocked if unavailable.

### 1D2-R3-T22 — physical Mac actual MLX qualification

On suitable Apple Silicon, record sanitized chip/RAM/macOS/Swift/MLX/runtime,
provider binary, exact model/artifact/feed/release/signer/Tier2/reference, service,
and database context. Using actual supported primary MLX weights and executable
CLI/app actions, run the complete T21 journey through actual inference and one
verified receipt-bound credit reconciliation/readback.

Also run corrupt artifact, cross-release/stale feed, invalid size, early/
overflow stream, cancellation before/after commit, reconnect/replay, fresh
re-evaluation, rate/model drift, unsupported/non-primary model, acceptance-frame
tamper, and delayed receipt. Pass requires fresh inference and settlement
evidence. If hardware, model bytes, signed release, Tier2/reference, isolated
services/identities, or any prerequisite is absent, record it and leave this
**BLOCKED / UNPROVEN**. Release signing/notarization/distribution, deployed
services, production enforcement, rewards, payouts, and production
qualification remain separate and unauthorized.

## Acceptance ledger

| Claim | Required tests | Local state at specification time | Qualification |
|---|---|---|---|
| Verified feed/fallback and exact size | T03–T05 | Pending fresh replay/run | Release distribution separate |
| Cancellation-safe preparation/adoption | T06–T08/T19 | Blocked on R4 gate | T22 physical required |
| Structurally closed positive authority | T02/T09–T11 | Generic 1d2 API requires correction | Enforcement activation unauthorized |
| One persisted exact-key price and accepted dispatch | T12–T14/T21 | Missing on 1d2 | T22 actual MLX required |
| Truthful readiness/activity/freshness | T10/T15–T17/T21 | Missing on 1d2 | Payout/payment excluded |
| Recovery/compatibility/active-work safety | T01/T07/T11–T20 | Pending | Release/deployment unproven |
| Physical Build 1 journey | T22 | Fixtures cannot pass | Blocked until all prerequisites run |

Implementation completion, local verification, hardware verification, release
qualification, deployed-service evidence, and production qualification are
reported independently. Nothing here authorizes merge, release, deployment,
economic activation, rewards, payouts, spending, or operator-secret changes.
