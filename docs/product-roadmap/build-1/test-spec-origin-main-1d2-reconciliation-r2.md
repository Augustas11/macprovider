# Build 1 test specification — origin/main 1d2 reconciliation r2

Status: **PROPOSED; no test in this document has been run by this artifact**.
This specification pairs with `origin-main-1d2-reconciliation-plan-r2.md` at
exact base `1d2c930bad81704dd0acc0322226725d8b64aceb`. An independent GPT-5.6
Sol review of the exact pair must report zero Critical, High, and Medium
findings before source or test implementation.

The dirty source snapshot remains based at
`914f7cafcdbcfc1805a10f4f34167218341d5587`. The separate R4 reservation gate
and current-main/slice-5 checkpoints are prerequisites, not assumed outcomes.

## Evidence rules

Every run records command, working directory, base/head SHA, selected/pass/fail/
skip counts, duration, exit status, tool/runtime version, and log SHA-256. A
zero-selected, skipped, interrupted, timed-out, historical, or fixture-only run
cannot pass current integration, Xcode, physical MLX, release, Docker, deployed,
or production acceptance.

Use isolated temporary config, cache, artifact, journal, HMAC, identity,
database, and service roots. Fail if a test opens or mutates operator-default
roots, nonlocal endpoints, Keychain operator items, payout material, secrets, or
production-installed provider state. Scan logs for credentials, keys, raw signed
feeds/envelopes/receipts, account scope, local paths/file identity, journal
contents, buyer prompts/outputs, and payout data.

Each normative test records the governing SPEC selector and proves that the
selector selected at least one test. Concurrency tests run under `-race` where
applicable. Swift CLI tests and generated Xcode MalibuTests are separate
evidence. Docker-dependent integration is blocked unless the daemon is ready.

## Test matrix

### 1D2-R2-T01 — recovery snapshot, exact base, and continuing origin checks

Before replay, verify the private backup ref resolves to 914f7, `git bundle
verify` succeeds, tracked/untracked manifests reproduce the dirty tree, and
recovery permissions are `0700`/`0600`. Reject operator-secret names, `.env`,
private/payout keys, build products, caches, and unrelated session files.

Record `origin/main`, merge base, slice-5 HEAD and dirty path/hash manifest, plus
per-build/cumulative diffs at: after Phase 0; before replay; before every SPEC or
governance edit; before every overlapping implementation commit; before full
audits; after audit fixes; and immediately before PR create/update. A test
fixture advances origin at each checkpoint. Require the automation to stop
writes, preserve the branch, create/rebase a fresh hidden worktree, regenerate
manifests, inspect landed semantics, and reopen the plan gate for material
changes. A clean textual merge cannot auto-pass. When slice 5 stays unmerged,
prove its committed and dirty files are absent from the Build 1 diff.

### 1D2-R2-T02 — landed 1d2 authority baseline

Run fresh race tests for coordinator `internal/artifactidentity`, `internal/tier2`,
`internal/pool`, `internal/buyer`, and `internal/ws`, with actual selection of
SPEC-047 R001/R003/R006/R008. Prove coherent release publication, exact member
matching, probe ceiling at `network_admitted_unsettled`, expected-head CAS,
pending dual control, session/binding drift, release sweeps, route postcheck, and
historical six-field evidence. Repeat after reconciliation without weakening
error precedence or changing positive-origin semantics.

### 1D2-R2-T03 — verified live feed and compiled fallback

Drive actual CLI discovery/recommend/prepare composition with a fresh signed
candidate/artifact pair. Freeze candidate release, policy, generated-at, body
digest, signer, model key, artifact ID/hash/algorithm/format/runtime source,
primary designation, and positive size through target selection.

Reject corrupt/truncated body, bad/unknown/revoked/wrong signer, candidate/feed
signer disagreement, cross-release pair, future/stale/expired timestamp, wrong
policy, duplicate/unknown/missing/wrong-typed JSON field, ambiguous member,
candidate row mismatch, and transport truncation before download or mutation.
The compiled fallback succeeds only under its exact signer/release/freshness and
candidate binding; network failure cannot turn an invalid response into trusted
fallback or current network authority.

### 1D2-R2-T04 — exact actionable size contract

For live and compiled sources, preparation is available only when authenticated
`size_bytes` is an integer in the supported range and greater than zero. Prove
CLI JSON, confirmation text, Malibu.app display, reservation input, and final
byte counter equal the signed-feed value exactly.

Table-drive absent, null, zero, negative, fractional, string, overflow, and
cross-artifact size; HTTP `Content-Length` absent/smaller/larger; chunked transfer;
early EOF; exact length; and one byte over at early and final chunks. Failure
before action creates no journal, staging directory, reservation, durable index,
config, offer, or incumbent mutation. A stream mismatch removes only owned
staging and reports a typed non-ready result. Unknown size remains visible only
as browse/unavailable and cannot be confirmed by CLI or app.

### 1D2-R2-T05 — target eligibility and primary MLX identity

From empty cache/store, select one supported primary MLX artifact. Reject
blocked/declared-only row, unsupported runtime/format, unknown model, insufficient
RAM/profile, non-primary Build 1 prepare target, provider path, wrong revision/
hash, and hashes spanning model keys. None changes active/prepared state,
configuration, offer, or admission.

Preserve already-landed coordinator matching/settlement for valid non-primary
members under the complete SPEC-010 R007 evidence. This preservation does not
make non-primary preparation a supported action or allow it to borrow primary
assertions/price.

### 1D2-R2-T06 — successful preparation and durable recovery

Run actual CLI confirmation → metadata resolution → exact-size reservation →
owned staging → download → full digest/manifest verification → fsync/atomic
publication → durable readback. Verify containment/no-follow, free-space checks,
bounded progress sequence/heartbeat, one durable terminal outcome, and no
incumbent overwrite. Remove HF cache and restart; discover the same path-free
candidate, revision, hash, size, and readiness without duplicate entry.

Inject downloader, digest, copy, fsync, rename, journal, quota, ENOSPC/EDQUOT,
and readback failures. Every failure is typed, non-ready, and recoverable.

### 1D2-R2-T07 — cancellation, crash, cleanup, and incumbent preservation

Cancel at metadata, before first byte, midstream, after download, hashing,
durable copy, immediately before publish, and immediately after publish. Crash
at every journal/filesystem boundary. Cover duplicate cancel, SIGINT, reconnect,
poll deadline, concurrent same/different target, and prepare/adopt race.

Before commit, incumbent config/runtime/active artifact/admission/route
eligibility are byte-identical. After commit, cancel returns `too_late` and the
artifact is prepared inactive. Cleanup never follows symlinks or deletes active,
prepared, rollback, journal-referenced, or foreign files. Cleanup failure yields
a resumable action without falsely claiming cancellation.

### 1D2-R2-T08 — adoption and local candidate runner

Use complete prefetched artifacts with the real candidate runner/recommendation
path and a downloader spy that must remain uncalled. Missing/corrupt prepared
bytes fail before runner creation. Benchmark values come from runner output.
Memory pressure, timeout, cancel, child crash, and malformed output preserve the
prior lifecycle/config. Explicit adoption uses lock/journal/drain/swap/rollback
and revalidates bytes immediately before activation.

### 1D2-R2-T09 — store-enforced closed transition origin

Compile and runtime-check the production API surface. No generic memory/SQLite
method callable by WS, buyer, billing, app, or a same-package helper accepts a
free-form positive state. The raw persistence append is private to the closed
transition service. The authenticated operator principal type cannot be
constructed outside its owner package; zero/forged/mismatched capabilities fail.

Table-drive direct calls for offer, withdrawal, probe, drift, status adapter,
prepared artifact, signed provider assertion, dirty `promoteModelAdmission`,
buyer resolver, test publisher, stale replay, and arbitrary helper. None can
append `catalog_priced` or `settlement_capable`. Closed methods reject targets/
reasons outside their enum. Search/AST tests fail on production
`promoteModelAdmission`, parallel `SetModelAdmissionAuthority`, raw positive SQL,
or automatic probe target above unsettled.

All positive test setup drives authenticated operator endpoints. Any special
seed utility is confined to `_test.go`, absent from production archives/symbols,
and cannot be imported by production packages.

### 1D2-R2-T10 — operator decision, atomic dual control, restart, and replay

For catalog pricing, require one valid named operator plus exact head, candidate,
row/member set, release, Tier2, explicit catalog-key rate, and session checks.
For settlement capability, first request appends no positive event and creates
one durable pending record. A distinct authenticated operator approves only
after full fresh re-evaluation.

For memory and SQLite, instrument barriers before pending read, after read,
before event insert, after insert, before consume, and commit/response. Kill or
fail at each boundary. The only durable outcomes are: old head plus unconsumed
pending, or one settlement-capable event plus consumed pending. Never event
without consumption, consumption without event, two events, reopened pending,
or same-actor approval. Restart and concurrent approvers converge to that rule.

Reject invalid/no offer, stale head, illegal edge, ambiguous/member change,
release/Tier2/rate change, listed/nonrecommendable row, wrong runtime, stale
session, key loss, same actor, expiry, invalidated/consumed pending, conflicting
idempotency, and revocation/disconnect/reload races. Credential errors do not
reveal other token existence.

### 1D2-R2-T11 — exact transport replay versus fresh re-evaluation

Persist the canonical signed outbound offer/retry envelope before first send.
Test byte-identical retransmission with the same request ID, timestamp, nonce,
idempotency key, payload digest, signature, and bytes after: crash before send;
coordinator persistence before response; response before local outcome journal;
and local journal fsync. Identical sequential/concurrent requests return the
stored result/pending record and create no extra probe, event, rate-window use,
or mutation. Split-key or same-key/different-payload conflicts fail.

Separately invoke explicit bounded re-evaluation. It preserves provider,
candidate, served model, member/digest, and other protected offer tuple fields,
but uses fresh request identity, timestamp, nonce, idempotency key, digest, and
signature. It rechecks current head/session/release/member/rate authority and may
produce a new allowed outcome. Concurrent distinct-fresh retries are governed
by rate/CAS rules and are never labeled idempotent replay. CLI/app recovery must
choose exact replay only for uncertain delivery and require explicit action for
fresh re-evaluation.

### 1D2-R2-T12 — release/provider/decision/pricing lock graph

Under `-race`, pause release staging/publication, provider section, registry,
release read, event/pending operations, transition service, price resolution,
route insert/postcheck, readiness read, and settlement activity read. Preserve:
provider section → registry → release read; release write completes before
sweep; route insert holds neither provider section nor release lock; operator
auth precedes admission locks; atomic event/pending mutation uses one store
critical section/transaction; price resolution completes before dispatch; and
settlement/read activity uses no live authority lock/accessor.

Race reload, heartbeat, disconnect, withdrawal, revocation, operators,
settlement receipt, config reload, readiness/activity pagination, SQLite busy,
and context expiry. Require one coherent event/route/price/ledger outcome or
typed no-charge failure, bounded completion, all locks released, and no leaks or
reentrant callback.

### 1D2-R2-T13 — immutable authoritative BYOM price contract

Give catalog model ID, exact catalog model key, request model, served model,
provider assertion, artifact ID/hash, primary row hash, non-primary member hash,
normalized alias, and `default` deliberately different rates. Only an exact
explicit rate entry for the accepted `catalog_model_key` may create a new BYOM
route. Missing key, absent exact rate, normalization-only match, default-only
match, mismatched candidate/event/member, or zero/invalid contract field fails
before dispatch and creates no route, provider attempt, ledger credit, or buyer
charge.

Freeze independent canonical bytes/digest for `byom_price_contract.v1` with
model key, config snapshot id/hash, formula version, unit, prompt/cache/completion
rates, multiplier, provider share, and max-billable-token cap. Assert it is in
the immutable route digest and repeated by direct ledger key/digest fields.
Mutate each field, canonical bytes, digest, direct column, or ledger copy; receipt
credit/recovery/reconciliation fails closed or quarantines according to the
governing SPEC before money movement.

Change current rate card, multiplier, share, default, release, catalog, keyring,
and session after route insertion. Instrument all live accessors to panic during
receipt settlement/replay; the captured contract still produces the same exact
debit/provider credit once. Verify prompt-cache rate and max-token boundary,
rounding, overflow, partial/error/cancel outcomes, delayed/duplicate receipt,
and cap failure. Before-route drift blocks dispatch. Route postcheck failure is
pre-dispatch no-charge.

For non-BYOM and historical rows, run golden current `RateFor` normalization/
default behavior and settlement with no new contract. Prove no old route JSON,
digest, receipt, or ledger row is rewritten/backfilled.

### 1D2-R2-T14 — historical route/evidence compatibility

Load unmodified no-extension and c944 six-field SQLite fixtures. Preserve empty
artifact evidence for the former and exact six keys/spelling
`artifact_candidate_catalog_sha256` for the latter. Reconstructed canonical
bytes/digest equal stored values and migrations do not rewrite them.

Create a current six-field route plus price contract, restart every store, and
settle/replay from immutable evidence. Reject partial/unknown evidence, dual
legacy/current spelling, wrong model key, member, receipt tuple, price contract,
or policy. Confirm no dirty 24-field `artifact_admission.v2` record is emitted.

### 1D2-R2-T15 — sanitized provider readiness v2

Authenticate with provider token A and query candidate A. In one consistent
store snapshot, prove states: no offer; unsettled; catalog-priced; valid pending
second operator; pending expired; pending invalidated by new head, withdrawal,
revocation, release/session/member drift; pending consumed to settlement-capable;
and store unavailable. Pending true requires exact candidate/tuple/evaluated
head and unexpired/unconsumed/uninvalidated record. Restart preserves truth.

Freeze the exact success field set from the plan and reject server/client
unknown fields, duplicates, wrong/null types, and missing fields. Provider B,
buyer credentials, shared operator key, and unauthenticated requests
cannot read A. Response and logs contain no pending ID, request/digest,
requesting/approving actor, reason, credential, operator config, or other
candidate. Assert the closed sanitized approval states `not_pending`,
`awaiting_second_operator`, `operator_review_expired`,
`operator_review_invalidated`, and `unknown` at their exact cases. Freeze exact
v1 response bytes/schema unchanged. Old/capability-
missing CLI/app renders approval `unknown`, never pending or positive.

### 1D2-R2-T16 — provider settlement activity v1

Seed two providers, multiple candidates, and more than 100 attempts. Freeze the
exact response/entry fields, explicit nulls, `credit_unit=credits`, null credits
for open rows, non-negative integer credits only for terminal rows, and closed
settlement-state grammar. Query with provider token and descending keyset pages
at limits 1, 2, 100. Freeze `observed_through_id` on page one and repeat it on
later pages while concurrent newer rows arrive. Prove no gaps,
duplicates, reordering, cross-provider/candidate/account leakage, cursor scope
escape, offset scan, or unbounded JSON parse. Malformed/stale/foreign cursor and
limit 0/101 fail with closed errors. Missing auth is 401; disabled/unavailable
token authority/store is 503; bad candidate/cursor/limit is 400; no rows is an
empty 200 page. `EXPLAIN QUERY PLAN` uses the provider/activity-id index; cap-one
database operation completes without nested cursor deadlock.

Assert `activity_id` equals the immutable route-snapshot row id and a freshly
inserted route appears pending before a verdict row exists. Entries distinguish
receipt pending, verified-but-credit-not-reconciled
inconsistent/unavailable, `settled_verified`, quarantined, and zero-settled.
Only a closed valid verified receipt plus a matching ledger credit reconciled to
receipt-bound usage and the price-contract digest yields `settled_verified` and
provider credits. The weekly batching `settled` and `settlement_id` columns are
neither required nor exposed. Test
delayed receipt, duplicate, reversal/quarantine, reconciliation, missing ledger,
wrong provider/candidate/key/digest, restart, and freshness watermark. Admission
status alone produces no activity or settled state. The schema never reports
weekly batching, withdrawal, payout, USDC payment, or transferable funds, and excludes buyer
identity/content, account scope, receipt/signature bytes, paths, and operators.

### 1D2-R2-T17 — truthful CLI and Malibu.app composition

Run SwiftPM command tests and generated Xcode MalibuTests. Prove executable
prepare/status/cancel/cleanup/adopt/offer/admission-status/exact-replay/fresh-
reevaluation/withdraw/readiness/activity with independent capability negotiation.
Cover positive exact size, browse-only unknown size, accessibility/localization,
malformed/nonmonotonic JSONL, CLI restart, >30-second response, refresh timeout,
late terminal recovery, pagination, and old CLI.

Prepared, active, unsettled, catalog-priced, awaiting second operator,
settlement-capable, request receipt pending, request settled with credits,
quarantined, and unknown are distinct. Catalog economics show source/freshness
and never imply eligibility. Request settlement never says paid out/withdrawable.
Operator actions are absent. Stale/error states never become ready, idle, or
earning.

### 1D2-R2-T18 — drift, expiry, unsupported, and GGUF local proof

Table-drive compatible/incompatible release, same-content restamp, member change,
feed-integrity failure, signer/release expiry, row status, Tier2 disagreement,
runtime disallow, model/hash drift, session replacement, key loss, withdrawal,
sanction, and probe expiry. New routes either bind exact valid state/price or
fail typed and unpaid. Sweeps use only closed reasons and never grant positive
state.

For GGUF retry, persist no path/file identity on wire. Reopen no-follow and
compare locator, device/inode/size/mode/owner/link/high-precision mtime/ctime (or
the final separately approved stronger identity), then recompute digest under
deadline. Reject any mismatch, symlink, missing/partial/unknown journal, digest,
or advisory-cache-only proof before network mutation. Legacy records may
status/reconcile/withdraw but cannot acquire missing proof or paid authority.

### 1D2-R2-T19 — exact R4 prerequisite and closure

Before dependent preparation replay, enumerate every
`phase3-binary/{Sources/macprovider-cli,Tests/macprovider-cliTests}/ModelCatalogTransaction*`
file. It must match the twelve canonical paths and hashes in the paired plan at
the rejected baseline. Fail on missing, additional, renamed, symlinked, or
hash-mismatched file. Recompute that manifest after every R4 correction.

Require a later final R4 record with zero-C/H/M plan review, exact plan/test/
review hashes, isolated implementation commit and tree, full closure manifest,
fresh targeted logs, and zero-C/H/M code/security/architecture audit hashes.
Verify each object independently and confirm `git diff` matches the manifest.
Run every final migration, retention, transaction, cancellation, quota, crash,
real-death, filesystem, and max-shape test with nonzero selection. Current R10's
failed review and the historical 79 passes must fail this gate. Reopen Build 1
if final R4 ownership, commit point, capacity, cancellation, or recovery differs
from this plan.

### 1D2-R2-T20 — governance, slice-5, broad checks, and full audits

On 1d2, retain SPEC-010 v1.8, SPEC-047 v0.1.5, and landed selectors. If slice 5
lands at any mandated checkpoint, exercise the stop/rebase/reinspect/re-gate
flow and preserve its final SPEC-017/SPEC-023/SPEC-047/intake semantics and
selectors. If unmerged, assert none of its committed or dirty implementation is
copied. Run governance generation/check, all changed selectors, and PR
declaration validation. Reject zero selection, version collision, index drift,
or language claiming deployment, production/economic activation, physical
qualification, or intake authority for positive admission.

After targeted success run full Swift tests, generated Xcode MalibuTests,
coordinator/gateway Go tests and changed-path race tests, `go vet`, coordinator
lint, builds, Docker/PostgreSQL integration when available, dist/release/feed
corpus tests, and secret/dependency/path scans. Three independent GPT-5.6 Sol
lanes review the exact complete rebased diff for code, security, and architecture.
Fix and repeat until each has zero Critical/High/Medium; disposition every
Low/Info. Re-run the origin checkpoint after audit fixes and before PR.

### 1D2-R2-T21 — isolated executable end-to-end journey

With isolated services and deterministic provider fixture, run actual CLI/app:

`discover positive-size target → prepare → status → adopt → offer → unsettled
probe → authenticated catalog-priced decision → sanitized pending read →
distinct approval → settlement-capable read → buyer request → immutable price
contract → receipt persistence → receipt-bound credit reconciliation → provider activity read`.

Repeat cancellation/reconnect, coordinator and CLI restart, exact lost-response
replay, fresh re-evaluation, delayed receipt, pagination, release reload, and
rate/model drift. Assert exact route/price/ledger snapshots, one debit/credit,
and truthful app states. This is local integration, not physical MLX. Mark
Docker-dependent evidence blocked if unavailable.

### 1D2-R2-T22 — physical Mac actual MLX and settlement qualification

On a suitable physical Apple Silicon Mac, record sanitized chip, RAM, macOS,
Swift, MLX/runtime, provider binary, model key, artifact ID/hash/algorithm/size,
feed/release/signer, Tier2/reference, coordinator/gateway, and database context.
Using actual supported primary MLX weights and executable CLI/app actions, run:

`fresh signed feed → positive-size confirmation → preparation/integrity →
adoption → signed offer → unsettled probe → authenticated catalog-priced
decision → distinct settlement approval → actual MLX request → immutable exact-
key price evidence → receipt → one verified receipt-bound credit reconciliation → provider readback`.

Also run corrupt artifact, cross-release feed, stale signature, absent/invalid
size, early/overflow stream, cancellation before/after commit, reconnect/replay,
fresh reevaluation, rate/model drift, unsupported model, and non-primary prepare
rejection. Before-commit cancellation preserves serving state; after commit
leaves prepared inactive.

Pass requires fresh actual inference and settlement evidence. If hardware, model
bytes, signed release, Tier2/reference, isolated services, identities, or any
other prerequisite is missing, record it and leave this **BLOCKED / UNPROVEN**.
Release signing/notarization/distribution, deployed-service evidence, production
enforcement, payout, and production qualification remain separate.

## Acceptance ledger

| Product claim | Required tests | Local status at specification time | Qualification status |
|---|---|---|---|
| Verified feed/fallback and exact actionable size | T03–T05 | Pending fresh implementation/run | Release distribution separate |
| Trusted cancellation-safe preparation/adoption | T06–T08, T19 | Blocked on R4 zero-finding gate | T22 physical required |
| Store-enforced positive origin and dual control | T02, T09–T12 | Landed handler baseline; store correction pending | Production enforcement unauthorized |
| Exact catalog-key pricing and immutable settlement | T13–T14, T21 | Missing on 1d2; pending | T22 actual MLX settlement required |
| Truthful provider readiness and request settlement read | T15–T17, T21 | Missing on 1d2; pending | Payout/payment excluded |
| Compatibility, replay, recovery, active-work safety | T01, T07, T11–T14, T18–T20 | Pending | Release/deployment rollback unproven |
| Physical Build 1 acceptance | T22 | Fixtures cannot pass | Blocked until every named prerequisite runs |

Implementation completion, local verification, hardware verification, release
qualification, deployed-service evidence, and production qualification are
reported independently. Nothing in this specification authorizes merge,
release, deployment, production enforcement, rewards, payouts, spending, or
operator-secret changes.
