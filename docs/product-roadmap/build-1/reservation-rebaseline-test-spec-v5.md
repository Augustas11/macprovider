# Build 1 preparation-reservation rebaseline test specification v5

Status: acceptance specification for `reservation-rebaseline-plan-v5.md`. No implementation test may be credited before the complete operator-owned authority commit in T18 lands.

Baseline: `c4401f1791d593d37d68eba91af94219b26d278f`.

## Test rules

- Use unique temporary authority/artifact roots. Do not touch operator config, models, feeds, credentials, or a running provider except the controlled T21-T24 qualification environment.
- Keep public projection/event/cancellation-ack tests separate from private persistence tests.
- Every failure captures locks, root/namespace state, deletion/temp/marker state, config hash, incumbent identity, worker event stream, cancellation acknowledgement when invoked, and fresh projection.
- Production delegate/watchdog code drives transfer tests. Server/transport counters are observational; only application-accepted and staged counters have normative caps.
- SIGKILL proves process ordering only. Stable-media claims require real APFS reboot and abrupt-power evidence.
- Skipped, timed-out, interrupted, or unavailable runs are not passes.

## Proposed test surfaces

| Surface | Coverage |
|---|---|
| `ModelPreparationPrivateCodecTests` | Strict records, unique temp/root bootstrap, tuple, marker/deletion phases |
| `ModelPreparationSelectionTests` | 64/65/128/256 fairness, churn, restart, dispatch races |
| `ModelPreparationRootTests` | Custom roots, identity, v3 namespace, legacy coexistence |
| `ModelPreparationTransferTests` | Real throttled HTTP, delegate/watchdog, counters, resume/cancel |
| `ModelPreparationDurabilityTests` | Publish barriers, intent-first deletion, recovery, APFS hooks |
| `ModelPreparationInventoryTests` | V3-only inventory, configured legacy accounting/protection, budget |
| `ModelPreparationIntegrationTests` | Locks, worker event sequence, cancel acknowledgements/races |
| `ModelAdoptionIntegrationTests` | Existing frame, independent feed/v3-root/hash readiness |
| `ModelCatalogEconomicsTests` | Exhaustive preparation matrix and approved storage/action schemas |
| Malibu UI/accessibility tests | Exact copy, reachability, event/ack handling, fallback |
| Real-Mac harness | MLX serving, power recovery, signed journeys/settlement/release |

## T01 — frozen public authority and strict private codecs

### T01.1 public authority inventory

At the exact T18 authority commit assert:

- read/status remains `models catalog-economics --json`;
- run/cancel spellings exist only under the approved catalog-economics capability;
- progress/results use only `model_catalog_transaction_event.v1` and its seven states;
- only the worker emits events and allocates `event_sequence`;
- cancellation returns exactly the approved `model_catalog_transaction_cancel_ack.v1` shape, or the operator's explicitly substituted shape, capped at 4096 bytes and with no event sequence/terminal-success assertion;
- R002/R003 contain the complete local/trusted preparation matrix and exact copy;
- published cleanup is separate from `cleanup_staging`;
- no status schema, `models transactions` family, public crash/late-cancel state, or new control frame exists.

Reject unknown public fields/enums, invalid source/state/economics combinations, mismatched IDs/kinds/model key, nonmonotonic worker sequences, illegal nullability, and oversized lines/acknowledgements.

### T01.2 private codec round trips

Round-trip minimum/maximum v3 reservation, active, cancellation, inventory, deletion intent/tombstoned/removed, root identity, publication receipt, and unique-temp records. Reject duplicate/unknown keys, wrong schema/kind/target/generation/root/tuple, malformed UUID, invalid UTF-8, floats, negative/overflow integers, trailing bytes, checksum mismatch, and one-byte-over caps.

### T01.3 unique temporary recovery

For `reservations.json`, `active.json`, `cancel.json`, `published-inventory.json`, and `deletion.json`, inject crash after unique temp create, every partial write boundary, completed write, `fsync`, `F_FULLFSYNC`, readback, rename, parent `fsync`, and parent `F_FULLFSYNC`. Assert:

- incomplete recognized temps are descriptor-validated and removed;
- complete newer temps finish the exact rename/barrier;
- valid equal/newer durable targets win;
- at most 16 total/four-per-kind recognized temps are processed;
- hostile names/types/owners/modes/links/checksums fail closed;
- ordinary interrupted temps never permanently wedge the projection or next transaction.

### T01.4 root.identity bootstrap

Inject the same boundary crashes in `bootstrap-tmp`. Assert no partial bytes ever appear as final `root.identity`; a complete temp can finish exclusive rename; an incomplete recognized temp is removed and regenerated; crash after rename repeats the parent barrier; valid final identity removes stale recognized temps; malformed/conflicting final identity fails closed. Repeat concurrent first projection across processes under the operation lock.

## T02 — deterministic bounded selection without starvation

Retain v2 tests at 0/1/3/64/65/128/256 and failure at 257. Permute feed order, restart processes, mutate/remove/re-add boundary rows, and run enough generations to prove the eight-slot fairness bound. Retained unchanged tuples preserve IDs; evicted/re-entered tuples follow deterministic metadata. Race dispatch and rewrite 1,000 times: dispatch-win pins one durable active tuple; rewrite-win returns approved stale/action-unavailable with zero side effects.

Repeat selection for every preparation classification from T16. Economics state must not perturb tuple/action ID when the operator contract says the same local artifact action remains eligible; a classification or signed target change must do so exactly as specified.

## T03 — operation, cancel, and event ownership

Fork independent worker, projection, cancel, and retry processes. Assert one live `operation.lock`, one attempt, one worker stdout stream, and one monotonic event sequence. No cancel invocation writes an event or event-sequence field.

Exercise both orders at every boundary: cancel-lock acquire; active read; marker create/temp sync/rename/parent sync; acknowledgement write; worker marker read; `cancel_requested` event; cleanup; terminal state sync; worker cancel-lock acquire; marker removal; operation-lock release while cancel lock held; terminal compaction; and new-attempt creation.

Required outcomes:

- cancel before terminal returns `recorded`/`already_recorded`; worker emits exactly one `cancel_requested` and one terminal `cancelled` when pre-publication;
- cancel after durable publication may acknowledge `recorded`, but worker emits only terminal `succeeded`/`failed` and clears the marker;
- cancel that obtains `cancel.lock` after worker terminal/release returns `terminal` or `not_active` and writes no marker;
- a marker written before terminal sweep is removed by the worker;
- no write can occur after the sweep but before lock release because worker holds `cancel.lock` across operation-lock release;
- new attempt removes only a validated prior-attempt marker under operation→cancel lock order;
- stale/mismatched marker returns `stale`, never affects another attempt, and is cleaned without deleting unrelated files;
- sequences have no duplicate/gap caused by cancellation and exactly one terminal event.

Run 10,000 randomized schedules and restart between schedules.

## T04 — custom roots and bootstrap crash recovery

Run projection → dispatch → transfer → publish → recovery → adoption with default, environment, and config roots. Bind canonical path, `st_dev`, `st_ino`, and root-identity digest in every record/receipt. Repeat with authority and artifact roots on separate APFS volumes.

Crash during root bootstrap and every private write using T01 injection. Change config/environment from root A to B afterward. Recovery must use only saved A, reconcile its recognized temp, staging, unpublished, marker, or deletion record, and leave B untouched. Test symlink/path replacement, move/remount, copied identity, inode-reuse simulation, wrong device/inode, and restored original root. Serving configured for B rejects A; serving configured for A independently verifies the v3 receipt/hash.

## T05 — stale IDs, tuple/feed/root drift

After projection, vary model/revision/artifact/release/signer/feed digest/estimate, provider/config identity, root canonical path/device/inode/identity, matrix classification, and action copy version. Dispatch fails before network/write unless the authority contract expressly preserves the tuple. Feed drift before publication blocks; drift after durable publication leaves inert bytes but cannot grant current readiness/adoption. Root changes never redirect cleanup.

## T06 — production transfer, cancellation, and byte accounting

Use a real local HTTPS server with slow multi-chunk bodies, Range/strong ETag, stalls, redirects, truncation, changed ETag, malformed Content-Range, and lying Content-Length. Instrument four separate counters:

1. server-sent bytes — observational;
2. client transport-received bytes when observable — observational;
3. delegate-delivered bytes — observational and allowed to exceed the cap;
4. application-accepted and staged bytes — normative.

### T06.1 cancel latency and heartbeat

Cancel during metadata, flowing/stalled response, verification, copy, and publish-ready. Assert marker observation and `task.cancel()` within 250 ms, supported-profile completion within 2 seconds, heartbeat gap ≤10 seconds, worker-only cancellation events, separate bounded acknowledgement, exact temp/resume cleanup, and no publication before commit.

### T06.2 cap crossing

Shape callbacks below, at, and above remaining capacity. The first callback revealing excess causes immediate cancellation; the worker accepts at most the remaining prefix, stages no more than accepted, discards later callbacks, and never publishes. Assert `accepted_application_bytes <= estimated_bytes` and `staged_bytes <= accepted_application_bytes`. Do **not** fail on any server-sent, transport-received, or delegate-delivered maximum. Test early declared-length refusal before body acceptance.

### T06.3 resume custody

All partial/resume metadata remains under the v3 attempt directory. Same live attempt resumes only a fully synced prefix with exact ETag/range/hash. Changed/missing ETag, malformed range, crash, or new attempt deletes recorded partial/resume data and restarts from zero. Shared cache/cookies/credentials and opaque URLSession resume data remain unused.

### T06.4 late callbacks and terminal races

After cancel/deadline/cap, deliver additional callbacks before URLSession acknowledgement. They may increment observational delivered/transport counters but cannot increment accepted/staged counters or emit events. Race these callbacks with worker terminal sweep, late cancel marker, and new attempt; assert no cross-attempt write/event/marker effect.

## T07 — macOS publication barrier matrix

Retain every v2 barrier: file sync/full-sync, receipt, bottom-up directories, publish-ready state, validation, exclusive rename, destination-parent sync/full-sync, active terminal sync, authority-parent sync, event emission. Inject syscall failure and SIGKILL before/after each on same/separate APFS volumes. Success event remains after all durable barriers; recovery re-verifies receipt/tree; mismatched destination is preserved.

On expendable APFS media, run ordinary reboot and externally controlled abrupt-power cases at each acknowledged barrier. Label reboot, abrupt power, SIGKILL, and injection separately; only abrupt power supports stable-media claims.

## T08 — malicious filesystem and recoverable-temp matrix

For authority root, v3 namespace, root identity, locks, private targets/temps, staging/unpublished/objects, receipt, deletion record/tombstone, and configured legacy path, test symlink, hard link, FIFO/socket/device, wrong owner/mode/ACL/link count, oversize, descriptor swap, mount transition, collisions, traversal, 4097th path, depth 33, and unexpected object.

Distinguish recognized interrupted unique temps from hostile unexpected siblings. Recognized incomplete temps recover per T01; hostile objects fail closed. No case touches an outside sentinel, legacy tree, other v3 object, or incumbent.

## T09 — bounded state, counters, v3 inventory, and budget

### T09.1 state/input caps

Exercise 10,000 attempts and assert one active/cancel/deletion record, 64 selected actions, 256 history/v3 objects, and every byte/count cap. Feed one-over inputs for reservation/inventory 262145, active 65537, cancel 4097, deletion 32769, event 16385, cancel ack 4097, metadata 131073, config 1048577, file/sibling 4097, path 1025, depth 33, estimate 1 TiB+1, accepted/staged estimate+1, deadline 1801, and integer 9007199254740992.

### T09.2 counter separation

For exact, one-over, huge-callback, redirect, retry, and late-callback cases assert independent monotonic counters. Only accepted/staged caps are pass/fail invariants. Preserve observational server/transport/delivered measurements without converting them into requirements.

### T09.3 managed v3 and configured legacy accounting

Construct:

- empty root;
- one configured valid legacy incumbent in the production `<root>/<model>/<revision>/<hash>` layout;
- configured legacy incumbent plus draft;
- unconfigured legacy siblings;
- 1, 255, 256, and externally seeded 257 v3 objects;
- mixed legacy/v3 near budget and filesystem-free-space boundaries;
- configured legacy tree on another device;
- malformed configured legacy tree.

Assert inventory enumerates only v3 objects; verified same-volume configured legacy bytes charge protected/managed budget; other-device configured bytes are reported separately; unconfigured legacy is never enumerated/imported/deleted; free-space still reflects all bytes; malformed configured legacy blocks cleanup/accounting but not incumbent serving. Any externally seeded overflow is detected with a bounded 257-entry read and makes preparation and published cleanup fail closed without truncation, deletion, or a claim that exactly 257 entries exist. Test 257, 258, and a much larger directory.

### T09.4 unique-release budget

Publish unique v3 releases to exact budget and one byte over. Over-budget blocks before download and never deletes. Repeat restart, custom root, configured legacy charge changes, and rollback/re-upgrade.

### T09.5 object-count admission

With 255 valid objects, publish one distinct identity and assert a 256-object inventory. With 256, repeat the exact identity and assert idempotent success with no network, staging, new receipt, or count change. With 256, request a new distinct identity and assert refusal before network/staging. Repeat across restart and feed/release churn. Externally seed 257, 258, and 10,000 entries and prove the reader consumes at most 257 entries, reports only bounded overflow, disables preparation and published cleanup, and performs no rename or deletion.

## T10 — publication and intent-first cleanup

### T10.0 publication/cleanup count race

Race the 256th distinct publication against provider-confirmed cleanup at every lock boundary for 1,000 schedules. Both use the common operation/cleanup lock. Each execution linearizes as cleanup then publication, publication then cleanup, or one closed refusal, and finishes with at most 256 objects. At 256 objects, race an idempotent publication and cleanup of another object; the exact target remains idempotent and no duplicate slot is consumed. Inject an external same-UID object between the early count check and pre-rename recheck and prove rename is refused, leaving a recorded unpublished tree and never object 257.

### T10.1 fresh/idempotent/conflicting publish

Fresh publish follows T07 into `.macprovider-prepared-v3/objects/<tuple>`. Exact existing v3 receipt/hash is idempotent with no network/copy/rename. Mismatch is preserved and blocks. A matching-looking legacy tree is never treated as a v3 destination.

### T10.2 deletion boundary state machine

For one reclaimable v3 identity, inject crash/failure at:

1. before/after `deletion.json phase=intent` temp create/write/file barriers/rename/parent barriers;
2. after durable intent, before second keep-set check;
3. before/after same-parent final→tombstone exclusive rename;
4. before/after objects-parent `fsync` and `F_FULLFSYNC`;
5. before/after durable phase update to `tombstoned`;
6. before/after every descriptor-relative unlink and tombstone removal;
7. before/after parent barriers, `removed` phase, record clear, and inventory refresh.

At each point assert exact durable record phase plus final/tombstone existence. No durable tombstone may exist without at least durable `intent`. `tombstoned` may be recorded only after the parent full-sync barrier.

### T10.3 exact recovery table

Test all combinations authorized by the plan:

| durable phase | final | tombstone | result |
|---|---:|---:|---|
| none | yes | no | no cleanup authority; preserve final |
| `intent` | yes | no | recheck keep set, resume rename or clear intent |
| `intent` | no | yes | repeat parent barrier, advance `tombstoned` |
| `intent` | yes | yes | fail closed |
| `intent` | no | no | fail closed |
| `tombstoned` | no | yes | resume exact deletion |
| `tombstoned` | no | no | repeat parent barrier, advance `removed` |
| `tombstoned` | yes | any | fail closed |
| `removed` | no | no | clear record |
| `removed` | any present | any present | fail closed |

Recovery uses only recorded tuple/root/final/tombstone identity; no scan/guess. Change config/env to another root after each crash and prove original-only recovery.

### T10.4 keep set, legacy prohibition, and no GC

Protect incumbent, configured legacy current/draft, active/prepared adoption, selected/active preparation, live worker, serve verification, and every different-root identity. Recompute before intent and before rename. Races becoming protected clear intent without rename. `cleanup_staging` rejects published targets. Instrument all delete paths: no automatic GC; no legacy/unmanaged object can be selected, renamed, receipted, or deleted.

## T11 — incumbent and forbidden mutations

Across every success/failure/cancel/cap/root/temp/bootstrap/publish/deletion/legacy case, compare config bytes/mode, current model/runtime generation, incumbent inference, provider identity/credentials, admission/routing, rate/economics, billing/settlement/reward/payout. All remain unchanged until separate adoption. Local Prepare copy never changes those facts.

## T12 — preparation/adoption/cleanup exclusion

Race dispatch, projection rewrite, adoption, serving verification, cleanup, temp recovery, and cancel terminal sweep. Assert fixed lock orders: preparation operation lock before adoption lock/socket/runtime reservation; operation lock before cancel lock for worker terminal/new attempt; cancel process takes only cancel lock. No deadlock, second worker, cross-attempt event/marker, or protected deletion.

## T13 — existing adoption handler readiness

Retain the existing `prepareModelAdoptionRequest`/result frames. Test already-loaded authority and absent-target reload. The server independently reloads signed feeds, resolves/validates its configured root, derives the v3 destination, validates root-bound receipt/hash, then compares requester claims. Reject legacy lookalike, alternate root, stale feed, malformed tree, tombstone, identity/hash/config/incumbent drift. Restart/race tests allow one authority snapshot and preserve the incumbent.

## T14 — CLI, worker events, and cancel acknowledgement

Test exact operator-approved catalog-economics run/cancel grammar, flags, option order, missing/extra args, TTY behavior, exit codes, stdout/stderr, and capabilities. No alias or `models transactions` family is accepted.

Worker events alone must match IDs/kinds/model, monotonic sequence, timestamps, progress/heartbeat, approved codes, and one terminal. The cancel process stdout contains exactly one bounded acknowledgement object, never an event line. Test all five proposed/approved outcomes and nullable attempt invariants. `recorded` must not be rendered as terminal cancellation; Malibu continues the worker stream and refreshes projection. Late cancellation yields only worker `succeeded`/`failed`. No status response schema exists.

## T15 — old-client fallback

Cross-test old/new CLI/Malibu combinations for local Prepare, cancel ack, storage accounting, and cleanup capabilities. Unsupported clients make no call and render existing fallback. Unknown compatible additions disable only their feature; unsupported projection envelope triggers whole-projection fallback. No disk inference occurs.

## T16 — exhaustive action-gating, journey, copy, and accessibility

Generate the Cartesian matrix of:

- `local_default` with all 12 admission states;
- `coordinator` with all 12 states;
- each `economics_state`: `trusted`, `fallback`, `stale`, `blocked`, `unavailable`;
- permitted/settlement booleans, artifact qualification, fit, runtime state, action model ID, estimate, and safety warnings.

For every combination, assert invalid source/state/boolean/trusted combinations fail closed. Valid non-trusted combinations expose Prepare only when all local prerequisites pass, using exactly **Prepare locally**, **Download and verify this model for local use. This does not offer it to the network or enable earnings.**, and **Download and verify {estimated_size} for local use?** Rates, payouts, share, and demand do not motivate or accompany that action. Valid trusted catalog-priced/settlement-capable rows use only operator-approved trusted copy. The landed wire earning verdict/state copy remains first and authoritative.

Drive at least `local_only`, `not_offered`, and `offerable` through Prepare locally → evaluate → offer → adopt using only approved typed transactions; prove it is reachable without economics/admission mutation by preparation. Exercise unavailable prerequisites and every matrix branch.

Run VoiceOver order/labels, keyboard, Dynamic Type, Reduce Motion, localization expansion, modal focus, background cancel, restart, child loss, worker event versus cancel-ack rendering, storage/legacy labels, and identity-specific cleanup confirmation. No path/secret/endpoint/prompt/completion leaks.

## T17 — upgrade, mixed store, rollback, and re-upgrade

Start from a production-shaped legacy root with configured incumbent/draft and extra unconfigured releases. Upgrade creates only `.macprovider-prepared-v3`; it does not alter legacy stat/hash/tree. Add mixed v3 releases, prepare/adopt where authorized, roll back to old CLI/app, then re-upgrade. At every phase legacy remains usable and untouched; v3 remains preserved/ignored during rollback and validates on re-upgrade; budgets/accounting match T09. Old R21-R27/v1/v2 planning state is never imported.

## T18 — dependency and governance gates

Fail unless:

1. `6f271245` and `c4401f17` are ancestors of implementation base.
2. One @Augustas11-owned SPEC-001/SPEC-044 commit freezes exact catalog-economics run/cancel spelling, event codes, exhaustive R002/R003 local/trusted eligibility and copy/economics separation, worker-only sequencing, bounded cancel-ack schema/outcomes/races, separate published cleanup action/projection, v3/legacy accounting fields, and budget policy.
3. It keeps the existing event schema, adds no status/control frame/public crash/late-cancel state, and does not overload `cleanup_staging`.
4. AUTHORITY, SPEC versions, indexes, CONFORMANCE, and #1485 ownership/copy agree.
5. `git merge-base --is-ancestor <authority-commit> <first-6B-commit>` succeeds and commits differ.
6. Fresh independent review of this exact v5 plan and test specification plus the landed SPEC diff has zero Critical/High/Medium.
7. Discovery/admission journeys and `SPEC-023-R006` remain pending unless accepted signed evidence changes CONFORMANCE.

Archive commits, hashes, ancestry, governance/spec-index output, and review artifacts.

## T19 — slice 6 test commands

```bash
cd phase3-binary && swift test --filter ModelPreparationPrivateCodecTests
cd phase3-binary && swift test --filter ModelPreparationSelectionTests
cd phase3-binary && swift test --filter ModelPreparationRootTests
cd phase3-binary && swift test --filter ModelPreparationTransferTests
cd phase3-binary && swift test --filter ModelPreparationDurabilityTests
cd phase3-binary && swift test --filter ModelPreparationInventoryTests
cd phase3-binary && swift test --filter ModelPreparationIntegrationTests
cd phase3-binary && swift test --filter ModelAdoptionIntegrationTests
cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
cd phase3-binary && swift test
make test-dist
make test
make vet
```

Run the current repository xcodebuild Malibu command on a named supported destination, governance/spec validators, secret scan, release tests, and `git diff --check`. Record exact command/commit/environment/result. Proposed test targets are deliverables, not claims they already exist.

## T20 — independent review gate

Run independent code, security, and architecture lanes over the complete authority-through-implementation diff. Each lane explicitly dispositions B1-V2-H1 and M1-M5 plus all prior v1 findings. Any Critical/High/Medium blocks; fixes require affected tests and all full-diff lanes again.
Each lane also dispositions B1-V3-M1 and verifies that the 256-object limit is an admission invariant rather than only a decoder limit.

## T21 — real-hardware preparation, storage, and incumbent journey

On supported Apple Silicon with final signed feeds/assets:

1. sustain real incumbent inference across local preparation;
2. use real throttled HTTPS and capture separately labeled server/transport/delegate/accepted/staged counters without asserting a server/transport bound;
3. repeat default/custom and separate-volume APFS roots;
4. exercise root/bootstrap unique-temp, marker, publication, and deletion boundary reboot/abrupt-power recovery;
5. upgrade from a configured production legacy incumbent, create v3 releases, prove legacy preservation/accounting, and perform confirmed v3-only cleanup;
6. adopt through the existing handler's independent v3-root/feed/hash validation and prove load/drain/swap/inference.

Signed evidence records hardware, OS/APFS/volumes, commits/assets/feed digests, controller logs, identities/hashes, counter classes, requests, and redacted timings.

## T22 — pending SPEC-046 discovery journey

Capture/promote signed `JOURNEY-PROVIDER-BYOM-DISCOVERY` evidence including opaque/catalog match, ladder/timing/redaction, restart, and negatives. Issue checkbox/local tests do not pass it.

## T23 — pending SPEC-047 admission and settlement journey

Capture/promote signed `JOURNEY-NETWORK-MODEL-ADMISSION` for the prepared/adopted identity through offer, decision, route visibility, accepted buyer request, receipt, settlement, and positive provider credit. Preparation never substitutes.

## T24 — first listed-tier and signed release qualification

Cut/evidence the first listed-tier release required by `SPEC-023-R006`. Build final app/tarball, sign/notarize/staple/package, prove embedded CLI byte identity, run prior-stable updater, and verify shipped capabilities, matrix, event/ack, custom-root/v3/legacy preparation/adoption. Do not patch immutable releases.

## Acceptance matrix

| Claim | Primary tests | Final evidence |
|---|---|---|
| Conforming reachable pre-offer Prepare | T16, T18 | Operator R002/R003 matrix/copy commit |
| Intent-first exact deletion recovery | T10 | Boundary state/authority logs + power cases |
| Crash-safe temp/root bootstrap | T01, T04, T08 | Complete injection matrix |
| Enforceable URLSession bounds only | T06, T09, T21 | Separated counters and real transfer |
| Dedicated v3 namespace/legacy safety | T09, T10, T17, T21 | Upgrade/mixed/rollback hashes |
| Worker-only events/cancel acknowledgement | T03, T06, T14 | Randomized two-process schedules |
| Object-count admission and fail-closed overflow detection | T09, T10 | 255/256/idempotent/257 refusal, 257/258/large seeded overflow, and cleanup-race schedules |
| Prior root/selection/durability/resource/adoption gates | T02-T13 | Targeted and APFS evidence |
| Malibu copy/accessibility/fallback | T14-T17 | UI/accessibility results |
| Zero C/H/M | T18-T20 | Governance and three reviews |
| Real MLX/power recovery | T21 | Signed physical-Mac evidence |
| Discovery conformance | T22 | Accepted signed journey |
| Admission/settlement/credit | T23 | Accepted signed journey/ledger |
| First listed tier/signed updater | T24 | Manifest, hashes, notarization, updater |

## Finding disposition

| v2 finding | Corrective tests | Pass condition |
|---|---|---|
| B1-V2-H1 | T16, T18 | Complete operator-approved source/state/economics matrix makes the guided path reachable and separates local preparation from economics. |
| B1-V2-M1 | T10 | Durable intent precedes rename; tombstoned phase follows parent barrier; every state has exact recovery. |
| B1-V2-M2 | T01, T04, T08 | Unique temps and atomic identity bootstrap recover every injected ordinary crash without wedge. |
| B1-V2-M3 | T06, T09, T21 | Only accepted/staged bytes are capped; delivered/transport/server metrics remain observational. |
| B1-V2-M4 | T09, T10, T17, T21 | V3 inventory is namespace-only; configured legacy is protected/accounted and never imported/deleted. |
| B1-V2-M5 | T03, T06, T14 | Worker owns all events; cancel returns approved ack; terminal/late/new-attempt races leave no stale marker. |
| B1-V3-M1 | T09, T10 | The 256th distinct object is allowed, the 257th is refused before side effects, idempotent publication remains available, and cleanup races cannot cross the cap. |

All v1 dispositions remain mandatory and are mapped in the plan.

## Stop condition

The reservation subplan is implementation-complete only when T01-T20 pass on the full final diff and independent reviews report zero Critical, High, and Medium. Build 1 is complete only when T21-T24 pass with final signed assets, accepted signed discovery/admission journeys, correctly settled positive credit, first listed-tier evidence, stable-media qualification, and updater proof. No plan, fixture, issue checkbox, prepared artifact, or slice 6 suite replaces those gates.
