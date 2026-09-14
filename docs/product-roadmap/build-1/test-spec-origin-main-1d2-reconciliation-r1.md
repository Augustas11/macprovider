# Build 1 test specification — origin/main 1d2 reconciliation r1

Status: **PROPOSED; no tests in this document have been run**. This specification
pairs with `origin-main-1d2-reconciliation-plan-r1.md` at exact base
`1d2c930bad81704dd0acc0322226725d8b64aceb`. An independent GPT-5.6 Sol plan
review must report zero Critical, High, and Medium findings before source or
test implementation begins.

The frozen dirty source tree remains at HEAD
`914f7cafcdbcfc1805a10f4f34167218341d5587`. The separate R4 reservation
correction is a prerequisite gate, and the unmerged slice-5 intake branch is an
explicit compatibility dependency, not part of this test scope.

## Evidence rules

Every run records command, working directory, base/head SHA, selected/pass/fail/
skip counts, duration, exit status, tool/runtime version, and log SHA-256. A
zero-selected, skipped, interrupted, timed-out, fixture-only, or historical run
does not pass a criterion that requires current integration, Xcode, physical
MLX, release assets, Docker, deployed services, or production evidence.

Tests use isolated temporary config, cache, artifact, journal, HMAC, identity,
database, and service roots. They fail if an operator-default root, nonlocal
endpoint, Keychain operator item, payout material, or repository secret path is
opened or mutated. Logs are scanned for secrets, signed envelopes, raw feeds,
local model paths, inode/file-identity data, and journal contents.

## Test matrix

### 1D2-T01 — recovery checkpoint and clean integration base

Before replay, prove the private backup ref resolves to the frozen source HEAD,
`git bundle verify` succeeds, tracked/untracked manifests reproduce the frozen
tree, and private recovery directories/files are `0700`/`0600`. Reject manifests
containing operator-secret names, `.env`, private keys, payout files, build
products, package caches, or unrelated session work. Prove the integration
worktree was created from exact `1d2c930` under
`/Users/augstar/.codex/worktrees/macprovider/`, while the dirty source worktree
and slice-5 worktree remain unchanged. Each replay slice must have a file and
commit manifest that distinguishes its per-build diff from cumulative upstream
or dependency history.

### 1D2-T02 — landed authority baseline

Run the fresh `origin/main` race suites for coordinator
`internal/artifactidentity`, `internal/tier2`, `internal/pool`, `internal/buyer`,
and `internal/ws`. Require actual selection of the landed R001/R003/R006/R008
tests. Assert:

- release publication exposes one coherent current/compatible catalog, Tier2,
  artifact-set, integrity verdict, and generation;
- offer match records exact row/member content and rejects ambiguous or
  cross-model hashes;
- automatic synthetic probe ends at `network_admitted_unsettled`;
- operator decisions use expected-head CAS;
- `settlement_capable` first creates a pending record and requires a distinct
  unexpired approver;
- hello/heartbeat/reload/disconnect update binding/session epochs and revoke on
  defined drift; and
- route compare-and-insert rejects stale event, binding generation, session
  epoch, or release generation.

The reconciled branch must pass the same tests without changing their expected
positive-decision origin or weakening exact error precedence.

### 1D2-T03 — verified feed and fallback consumption

Exercise actual CLI recommendation/discovery/prepare command composition with a
valid freshly signed candidate/artifact feed pair. Prove exact candidate release,
policy, generated-at, body digest, signer key ID, model key, artifact ID, hash
algorithm, hash, format, runtime source, and primary designation reach target
selection.

Table-drive corrupt body, corrupt signature, unknown signer, wrong trusted
signer, revoked signer, mismatched candidate/artifact signer, cross-release
pair, future generated-at, expired/stale feed, wrong policy, duplicate JSON key,
unknown/missing/wrong-typed closed-schema field, ambiguous member, candidate row
hash mismatch, and response truncation. Every arm disables preparation before
network download or local mutation and reports a typed reason.

Exercise the compiled fallback independently. It succeeds only for its exact
compiled trust/release/freshness contract and same candidate binding. Nil,
expired, corrupt, cross-release, or signer-incompatible fallback stays
unavailable. Network failure must not convert an invalid response into a trusted
fallback or claim current network authority.

### 1D2-T04 — target eligibility and identity

From an empty HF cache and clean durable store, select one exact supported
primary MLX artifact. Reject blocked/declared-only rows, unsupported runtime or
format, unknown model, wrong minimum RAM/profile, non-primary target for the
Build 1 prepare action, provider-supplied path, mismatched revision/hash, and
two artifacts whose hashes span model keys. Confirm these failures do not alter
configuration, active runtime, durable index, journal, offer state, or paid
admission.

Also prove the landed coordinator's existing non-primary artifact-member support
continues to match and settle when its full SPEC-010 R007/SPEC-047 evidence is
valid. This is a preservation test, not a claim that the new provider prepare
action supports every member. A prepared unsupported or non-primary artifact
cannot bypass the operator decision path.

### 1D2-T05 — successful primary MLX preparation

Run the executable CLI command through confirmation, metadata resolution,
download, staging, full-byte integrity verification, durable publication, and
fresh readback. Assert:

- confirmation names target, artifact source/signer, expected bytes or explicit
  unknown size, and long-running behavior;
- free-space accounting is bounded and checked before and during mutation;
- staging is inside the transaction-owned root with no-follow/containment;
- no active/prepared artifact is overwritten before the atomic commit point;
- every progress stream has valid monotonic sequence, heartbeat at the specified
  bound, and one durable terminal outcome; and
- restart with the HF cache removed discovers the same path-free candidate ID,
  exact revision/hash/readiness, and no duplicate entry.

Downloader, digest, copy, fsync, rename, journal, and readback failure injection
must return a typed non-ready state and leave durable truth recoverable.

### 1D2-T06 — cancellation, crash, cleanup, and incumbent preservation

Cancel at metadata, before first byte, mid-download, after download, during
hashing, during durable copy, immediately before publication, and immediately
after publication. Crash/restart at every journal and filesystem boundary.
Exercise duplicate cancel, reconnect, status polling, deadline expiry, SIGINT,
concurrent prepare of the same/different target, and prepare racing adoption.

Before the publication commit, the incumbent config, active model, runtime
process, active artifact, admission head, and paid route eligibility are
byte-for-byte unchanged. After commit, cancel returns `too_late`, the new artifact
is prepared but inactive, and readback converges to terminal truth. Cleanup
removes only transaction-owned staging and never follows symlinks or deletes
active, prepared, rollback, or journal-referenced content. Permission/disk-full
cleanup failures expose a resumable typed action without claiming cancellation
completed.

### 1D2-T07 — explicit adoption and offer lifecycle

Use the prepared artifact to run the real local candidate runner/recommendation
path with a complete prefetched map. A downloader spy must remain uncalled;
missing/corrupt prepared bytes fail before runner creation. Benchmark values must
come from the runner, not catalog thresholds. Memory pressure, cancellation,
timeout, child crash, and malformed output restore the prior lifecycle and never
apply configuration.

After explicit confirmation, exercise existing adopt lock/journal/drain/swap/
rollback. Then submit a provider-signed offer and run status/retry/withdraw. The
provider wire contains canonical model/member identity and no local path or file
identity. A missing or old journal cannot duplicate a live offer; idempotent retry
uses fresh signature/timestamp/nonce only under the existing protocol. Preparation
or adoption never advances the coordinator beyond the result of the real offer
and bounded unsettled probe.

### 1D2-T08 — CLI and Malibu.app truthfulness

Run SwiftPM command tests and the generated Xcode MalibuTests. Prove executable
dispatch for prepare, status, cancel, cleanup, adopt, offer, admission status,
retry, and withdraw with capability negotiation. Cover exact-size and unknown-
size confirmation, accessibility/localization, malformed/nonmonotonic JSONL,
CLI restart, a response delayed beyond 30 seconds, refresh timeout, late terminal
recovery, and old CLI behavior.

Prepared, active, network-admitted-unsettled, catalog-priced, pending second
approval, settlement-capable, revoked, and paid/settled are distinct view states.
Catalog economics show source/freshness and do not imply provider eligibility.
An operator-only action is never shown as a provider button. Unknown/stale/error
states are not rendered as readiness, idleness, or earning.

### 1D2-T09 — positive-transition origin and bypass rejection

Instrument every append origin and table-drive direct store calls, dirty
`promoteModelAdmission` equivalents, buyer authority resolvers, test publishers,
prepared artifacts, successful probes, signed provider assertions, status
adapters, stale event replay, and same-package helpers. None may append
`catalog_priced` or `settlement_capable` outside the landed authenticated
operator request/approval functions. Static/search tests fail if the reconciled
production call graph contains `promoteModelAdmission`, installs a parallel
`SetModelAdmissionAuthority` positive preparer, or changes the automatic probe
target above `network_admitted_unsettled`.

Provider tokens, buyer keys, shared malformed credentials, and one operator
identity cannot invoke or approve the operator path. Exercise auth and
idempotency error precedence without disclosing whether another token exists.

### 1D2-T10 — operator decision and dual-control matrix

For `catalog_priced`, prove one authorized operator can append only after exact
head, row, member set, catalog status, Tier2 material, release generation, and
price-key predicates pass. For `settlement_capable`, first request creates no
positive event, then a distinct actor approves only after full re-evaluation of
head, session epoch, runtime source, exact member, receipt key, release and
expiry.

Reject no offer, stale head, invalid edge, unmatched/ambiguous member, changed
row or artifact set, incompatible/rejected release, listed/nonrecommendable row,
wrong runtime source, absent/stale session, receipt-key loss, same actor, pending
expiry, consumed/invalidated pending, conflicting idempotency key, concurrent
decisions, and release/heartbeat/disconnect/revocation races. Identical requests
replay the original event or pending record without re-authorizing changed facts.

### 1D2-T11 — release/provider/decision lock graph

Run under `-race` with deterministic barriers at release staging/publication,
provider-section entry, registry resolve/set, release read, decision lookup,
pending create/consume, CAS append, binding refresh, reload sweep, disconnect,
and error returns. Prove the exact graph from the paired plan:

- provider section → registry → release read for decision and binding paths;
- release write publication completes before any provider sweep begins;
- route insertion takes no provider section and performs the store insert outside
  a release read hold; and
- receipt settlement takes no release/provider authority lock and calls no live
  authority accessor.

Race reload, heartbeat, disconnect, offer withdrawal, revocation, two operator
decisions, second approval, cancellation, SQLite busy/error, and context expiry.
The result is one coherent committed event/route or a typed non-paid failure.
All locks release, no callback re-enters an owner, no goroutine leaks, and later
operations complete within deterministic bounds.

### 1D2-T12 — historical and immutable evidence compatibility

Load unmodified no-extension and c944-created SQLite fixtures. For no-extension,
preserve empty artifact evidence. For c944, require exactly the historical six
keys and spelling `artifact_candidate_catalog_sha256`; reconstructed canonical
bytes and SHA-256 must equal stored values. Do not rewrite either fixture.

Create a current landed six-value route from an artifact-derived session, restart
all stores, and settle/replay solely from immutable route and billing snapshots.
Instrument current feed, index, keyring, catalog, session and rate accessors to
fail if called. Mutate individually the stored canonical bytes, digest, artifact
feed digest, artifact ID/hash/algorithm/signer, candidate digest, selected model
key, receipt tuple, price, or policy version; every mutation fails closed before
credit. Unknown/partial evidence and both legacy/current catalog-hash spellings
in one object are rejected. No `macprovider.artifact_admission.v2` 24-field row
is emitted or required.

### 1D2-T13 — authoritative pricing and settlement

Use deliberately different catalog model ID, catalog model key, artifact ID,
primary row hash, non-primary member hash, provider-asserted key, and rate-card
keys. Instrument Tier2 and signed/effective rate lookup. Tier2 receives the
admitted row identity; billing receives only the coordinator-resolved model key.
Attractive malicious rates under every other identifier are ignored.

For a valid current route, the signed receipt settles once with exact expected
buyer debit, provider credit, fee/share/multiplier/cap behavior, and immutable
price/version/unit. Test delayed receipt, restart, duplicate receipt, replay,
wrong signer/key, wrong request/attempt/provider/model/member/digest/prompt/output
range, missing receipt, cap overflow, rate change after route, catalog re-stamp,
model/runtime drift after route, and route postcheck failure. Rate/model drift
before route blocks dispatch; after immutable insertion it cannot change the
captured price or authorize a different request.

### 1D2-T14 — drift, expiry, release, and unsupported cases

Table-drive current-to-compatible and current-to-incompatible releases, same
content re-stamp, changed member content, artifact-feed integrity failure,
signer/release expiry, row status change, Tier2 disagreement, runtime-source
disallow, provider model/hash change, session replacement, receipt-key loss,
withdrawal, sanction, and probe expiry. New routes must either bind the exact
still-valid state or fail with a typed non-paid result; reload sweeps append only
the closed landed drift reasons and re-stamp compatible content without granting
a new positive state.

Unsupported and provider-only models may remain local/sandbox/unpriced according
to their existing contract but never gain catalog price or settlement capability.
Non-primary members retain only the already landed SPEC-010 R007 path and cannot
borrow primary preparation assertions, a different release, or another model's
price.

### 1D2-T15 — GGUF retry local-proof compatibility

For an original GGUF offer, persist the strict local private journal and send no
path/file identity on wire. Restart and retry unchanged bytes: reopen no-follow,
compare canonical locator plus device/inode/size/high-precision mtime/ctime (or
the final approved complete identity), recompute digest under deadline, preserve
the protected offer tuple, and create fresh protocol replay material.

Reject bytes, locator, symlink target, device/inode, size/timestamps, missing
file, digest, deadline, partial/unknown journal, and advisory-cache-only proof
before network mutation. Legacy records may status/reconcile/withdraw as their
contract permits but cannot gain missing proof or paid authority. This test does
not broaden the supported primary-MLX prepare journey.

### 1D2-T16 — R4 reservation prerequisite

Before preparation replay, verify the exact approved R4 correction plan/review
digests and zero Critical/High/Medium result. Run its targeted migration,
retention, transaction, cancellation, quota, crash, and max-shape tests with
actual selected counts. Then run independent code/security/architecture review
over that isolated slice. If the final implementation differs materially from
the dependency assumed by the Build 1 plan, stop and reopen the Build 1 plan
gate. The historical 79-test pass alone does not satisfy this criterion.

### 1D2-T17 — local executable journey

In isolated services with PostgreSQL and a deterministic provider fixture, run
actual CLI/app command surfaces end to end:

`discover → prepare → status → adopt → offer → unsettled probe → operator
catalog-priced decision → settlement pending → distinct approval → admission
readback → buyer request → receipt persistence → settlement readback`.

Repeat with cancellation/reconnect, coordinator restart, CLI restart, delayed
receipt, release reload, and rate/model drift. Assert exact route and billing
snapshots, one debit/credit, and truthful app state. This is integration evidence,
not physical MLX qualification. Docker-dependent evidence is marked blocked if
the Docker daemon is unavailable; it is never reported as passed.

### 1D2-T18 — slice-5 and governance compatibility

On exact `1d2c930`, governance must retain SPEC-010 v1.8 and SPEC-047 v0.1.5 plus
their landed R001/R003/R006/R008 selectors. If slice 5 lands first, rebase and
prove its SPEC-017 v0.2.1, SPEC-023 v0.10.4, SPEC-047 v0.1.6 (or final landed
versions), intake endpoint selectors, privacy bounds, and implementation remain
unchanged by Build 1. If slice 5 remains unmerged, prove no Build 1 file or commit
contains its untracked intake implementation and document the dependent-branch
relationship.

Run governance generation/check, selector execution, and the PR declaration
validator against the complete diff. Fail on hand-edited index drift,
zero-selected selector, version collision, or language claiming deployment,
physical qualification, production enforcement, economic activation, or intake
authority for automatic admission.

### 1D2-T19 — broad local gates and complete-diff audits

After targeted success, run:

- full `swift test` for `phase3-binary`;
- generated Xcode MalibuTests for the app;
- coordinator and gateway Go tests, race tests for changed concurrency paths,
  `go vet`, coordinator lint, and builds;
- cross-service integration with an available Docker/PostgreSQL runtime;
- affected dist, release-script, artifact-feed corpus, and governance checks; and
- dependency/secret/path scans appropriate to executable, money-path, auth,
  schema, release, and UI changes.

Three independent GPT-5.6 Sol reviewers inspect the exact complete diff as it
will land in code, security, and architecture lanes. Each finding records
severity, evidence, consequence, and required correction. Fix and repeat all
affected checks/reviews until the combined result is zero Critical, High, and
Medium. Low/Info findings require an explicit disposition.

### 1D2-T20 — physical Mac, actual MLX, and settlement qualification

On a suitable physical Apple Silicon Mac, record sanitized chip, RAM, macOS,
Swift, MLX/runtime, provider binary, exact model key, artifact ID/hash/algorithm,
feed/release/signer, Tier2/reference, coordinator/gateway, and database context.
Using actual supported primary MLX weights and executable CLI/app actions, run:

`fresh signed feed → confirmed preparation → full integrity verification →
explicit adoption → signed offer → unsettled probe → authenticated operator
catalog-priced decision → distinct settlement-capable approval → actual MLX buyer
request → receipt persistence → verified one-time settlement and balance delta`.

Also run corrupt artifact, cross-release feed, stale signature, cancellation
before commit, cancellation after commit, reconnect/recovery, rate drift, model/
hash drift, unsupported model, and non-primary-preparation rejection on the
physical setup. Before-commit cancellation must preserve the serving model;
after-commit cancellation must leave it prepared but inactive.

This criterion passes only with fresh actual inference and settlement evidence.
If suitable model bytes, signed release, justified Tier2/reference inputs,
hardware, isolated services, or identities are unavailable, record the exact
blocker and leave the criterion **BLOCKED / UNPROVEN**. Release signing,
notarization, distribution, deployed-service checks, and production
qualification remain separate and cannot be inferred from this local run.

## Acceptance ledger

| Product claim | Required tests | Local software status | Hardware/production status |
|---|---|---|---|
| Verified feed consumption and safe fallback | T03–T04 | Pending fresh run | Release distribution separately unproven |
| Trusted, cancellation-safe primary MLX preparation | T05–T07, T16 | Pending R4 gate and fresh run | T20 required |
| Executable truthful CLI/app | T07–T08, T17 | Pending Swift/Xcode/integration | Physical UI journey required by T20 |
| Operator-origin, dual-control paid admission | T02, T09–T11 | Landed baseline; reconciled diff pending | Production enforcement not authorized |
| Exact identity, pricing, and settlement | T12–T14, T17 | Pending combined integration | Actual MLX settlement required by T20 |
| Compatibility and recovery | T01, T06, T12, T15, T18 | Pending | Release/deployment rollback unproven |
| Build 1 physical acceptance | T20 | Fixtures cannot pass it | Blocked until all named prerequisites run |

Implementation completion, local verification, physical hardware verification,
release qualification, deployed-service evidence, and production qualification
must be reported as independent states. No row in this ledger authorizes merge,
release, deployment, production enforcement, rewards, or payouts.
