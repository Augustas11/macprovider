# Build 1 preparation-reservation rebaseline test specification v6

Status: revised acceptance specification for `reservation-rebaseline-plan-v6.md` after the blocking preparation-authority v1 review. No implementation test may be credited before the corrected, complete operator-owned authority commit in T18 lands.

Implementation baseline: `c4401f1791d593d37d68eba91af94219b26d278f`. Planning/review baseline: `f7e584499828b3d16036382848b5caa1a897cdf9`. Rejected authority candidate: `c42eea1ccfe637f0bfe3fa9939c18b26bd657434`.

Revision inputs: v5 plan SHA-256 `b20f502684856cf13e5f94e59a7fca9f64a7dd9981809e7d10a7e83934d67354`; v5 test-spec SHA-256 `d08f71feba48887a4dae446cb95b4cf874f93e0e53a5c7356dfbf8a8fe80c811`; blocking review `reviews/preparation-authority-v1-sol.md`. T18 records SHA-256 digests from the committed v6 bytes.

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
| Built CLI → production Malibu boundary | Real subprocess stdout/stderr/exit through the shipping process adapter and strict decoder |
| Real-Mac harness | MLX serving, power recovery, signed journeys/settlement/release |

## T01 — frozen public authority and strict private codecs

### T01.1 public authority inventory

At the exact T18 authority commit assert:

- read remains `models catalog-economics --json`, with no transaction-status surface;
- v1-serving CLI advertisements contain only `model_catalog_economics_v1`; v2-serving advertisements contain only `model_catalog_economics_v2` plus `models catalog-economics.v2`; dual or mismatched advertisements are invalid;
- run/cancel spellings exist only under the approved catalog-economics capability;
- progress/results use only `model_catalog_transaction_event.v1` and its seven states;
- only the worker emits events and allocates `event_sequence`;
- cancellation returns exactly the approved `model_catalog_transaction_cancel_ack.v1` shape, or the operator's explicitly substituted shape, capped at 4096 bytes and with no event sequence/terminal-success assertion;
- every v2 row carries required `candidate_id`, required verbatim SPEC-046 `provider_guidance`, and exact closed `guidance_binding` fields/source-schema/nullability/digest/freshness rules from the plan; missing, future, stale, cross-candidate, cross-source, cross-event/sequence, or mismatched guidance fails closed and Malibu renders the authoritative verdict first;
- R002/R003 contain the complete local/trusted preparation matrix, including `coordinator:not_offered`, exact `verification_status: verified`, and exact copy;
- the cancellation acknowledgement defines request echo, all five durable predicates, total first-match precedence, and exact attempt-ID nullability;
- `cleanup_targets` is bounded, complete for verified managed identities, deterministic, and retains reclaimable objects with no current catalog row;
- logical byte accounting and the truthful managed-data cleanup copy are exact and distinct from APFS physical free-space recovery;
- published and staging cleanup each have an intent/tombstone/remove state machine, exact commit point, and cancellation/recovery outcome;
- `SPEC-001-R003`, its pending CONFORMANCE entry, AUTHORITY consumers, and SPEC-044-R005 evidence/gap mapping agree;
- published cleanup is separate from `cleanup_staging`;
- no status schema, `models transactions` family, public crash/late-cancel state, or new control frame exists.

Reject unknown public fields/enums, invalid source/state/economics combinations, any non-`verified` artifact status, stale/mismatched guidance, mismatched IDs/kinds/model key, nonmonotonic worker sequences, illegal nullability, incomplete cleanup-target coverage, and oversized lines/acknowledgements.

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

- every syntactically valid acknowledgement byte-for-byte echoes the requested `transaction_id`; malformed input emits no valid acknowledgement;
- table-drive the total first-match order: matching durable terminal → `terminal`; matching nonterminal active plus exact durable marker → `already_recorded`; matching nonterminal active without exact marker → durable write then `recorded`; recognized non-current/stale transaction state → `stale`; no matching bounded state → `not_active`;
- `recorded`, `already_recorded`, and `terminal` always carry the exact non-null attempt ID; `not_active` always carries null; `stale` carries the stale attempt ID exactly when safely known and otherwise null;
- construct overlapping terminal/active/marker/history fixtures for every adjacent precedence pair and assert the first outcome wins without extra writes;
- cancel before a transaction-specific commit point returns `recorded`/`already_recorded`; worker emits exactly one `cancel_requested` and one terminal `cancelled` only after reversible cleanup;
- cancel after preparation publication or either cleanup tombstone commit may acknowledge `recorded`, but worker emits only terminal `succeeded`/`failed` and clears the marker;
- cancel that obtains `cancel.lock` after worker terminal/release returns `terminal` when the bounded terminal record matches, otherwise `stale` or `not_active` by the total table, and writes no marker;
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

After projection, vary model/revision/artifact/release/signer/feed digest/estimate, `candidate_id`, all five verbatim `provider_guidance` fields, and every `guidance_binding` field: source schema, exact source-byte SHA-256, generated time, projection sequence, coordinator event, candidate, admission source, and admission state. Test both source schemas, exact local/coordinator nullability, age at -1 second (future), 0, the exact `min(300, owner_source_max_age)` boundary, and one second beyond it. Also vary provider/config identity, root canonical path/device/inode/identity, matrix classification, and action copy version. Exercise artifact `verification_status` at `declared`, `verified`, `blocked`, missing, and unknown before projection, at dispatch, and after feed refresh. Only exact current `verified` may project or dispatch Prepare. Every stale or mismatched case fails before network/write unless the authority contract expressly preserves the tuple. Feed/guidance drift before publication blocks; drift after durable publication leaves inert bytes but cannot grant current readiness/adoption. Root changes never redirect cleanup.

## T06 — production transfer, cancellation, and byte accounting

Use a real local HTTPS server with slow multi-chunk bodies, Range/strong ETag, stalls, redirects, truncation, changed ETag, malformed Content-Range, and lying Content-Length. Instrument four separate counters:

1. server-sent bytes — observational;
2. client transport-received bytes when observable — observational;
3. delegate-delivered bytes — observational and allowed to exceed the cap;
4. application-accepted and staged bytes — normative.

### T06.1 cancel latency and heartbeat

Cancel during metadata, flowing/stalled response, verification, copy, and publish-ready. For the frozen two-second profile, use `CLOCK_MONOTONIC_RAW`: start when the cancel marker parent full-sync completes; record worker marker observation, entry to `URLSessionTask.cancel()`, and finish when the terminal `cancelled` JSONL line is flushed. Run on supported Apple Silicon with local APFS authority/staging, at most 8 MiB in at most 16 staged files, metadata or stalled-transfer phase, no publication/tombstone, no injected syscall failure, each required sync measured at no more than 250 ms, and no harness scheduler suspension. Assert observation and `task.cancel()` within 300 ms (the 250 ms contract plus exactly 50 ms measurement tolerance) and terminal flush within 2.000 seconds. Reject a run from this latency metric if any profile precondition is false; it remains covered by functional cancellation, heartbeat gap ≤10 seconds, action-timeout, and delayed-response tests. Never accept a premature terminal event before durable cleanup. Repeat enough isolated trials to report max and percentile values without broadening the bound.

Outside that profile, assert the worker checks at every bounded loop and the 250 ms watchdog, calls `task.cancel()` promptly after observation, emits worker-only cancellation events, returns the separate bounded acknowledgement, performs exact temp/resume cleanup, and publishes nothing when cancellation wins before commit. No general two-second terminal bound applies to large cleanup, scheduler starvation, fault injection, or slow durability barriers.

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

Assert inventory enumerates only v3 objects. Descriptor-relative fixtures prove the exact logical-byte algorithm: sum every accepted regular file data-fork `st_size` once with checked arithmetic; include receipt/managed metadata files inside v3 objects; count directories, allocation blocks, xattrs/resource forks, compression savings, and APFS clone sharing as zero; charge sparse, compressed, and cloned regular files by full logical `st_size`; and reject hard links, symlinks, special files, mount crossings, overflow, descriptor races, and unstable identity. Compare ordinary, sparse, compressed, cloned, and physically de-duplicated APFS fixtures with equal logical lengths: projected managed/prepared values remain logically equal while measured physical free-space changes may differ, and the UI never promises recovered capacity.

Verified same-volume configured legacy bytes charge protected/managed budget; other-device configured bytes are reported separately; unconfigured legacy is never enumerated/imported/deleted; free-space still reflects all bytes. For malformed or unmeasurable configured legacy, assert `configured_legacy_accounting_state: unavailable`; both legacy byte fields, charge, and available budget are null; every projected Prepare action and every published cleanup action is unavailable; a direct dispatch of a previously projected Prepare transaction returns the approved unavailable/stale refusal before network, staging directory creation, or any other side effect; incumbent serving remains unchanged. Any externally seeded overflow is detected with a bounded 257-entry read and makes preparation and published cleanup fail closed without truncation, deletion, or a claim that exactly 257 entries exist. Test 257, 258, and a much larger directory.

### T09.4 unique-release budget

Inject volume capacities `1570730896822`, `1570730896823`, and `1570730896824`, whose expected defaults are respectively `1099511627775`, `1099511627776`, and `1099511627776`; these are immediately below, exactly at, and immediately above the 1 TiB/70-percent crossover. Also test capacities 0, 1, 2, 3, 10, 99, 100, 101, maximum supported filesystem values, and values that make naïve `capacity * 70` overflow. Assert exactly `min(1099511627776, floor(capacity * 70 / 100))`, including non-integral floors, with checked overflow-safe arithmetic and `managed_budget_source: default`.

Exercise YAML-only, environment-only, and both-present configuration. Assert environment wins, YAML is used only when environment is absent, and the chosen valid override reports `managed_budget_source: configured`. Feed zero, negative, signed-plus, whitespace, decimal, fractional, exponent, non-integer, overflow, and `1099511627777` values at each layer; an invalid higher-precedence value fails closed and does not fall through. Accept exactly `1` and `1099511627776`.

Publish unique v3 releases with checked `charge + estimate` one byte below, exactly at, and one byte above budget. Independently set bound-volume available capacity one byte below, exactly at, and one byte above checked `2 * estimated_bytes + 1073741824`, including overflow inputs. Equality passes; one byte below free-space or one byte above budget refuses before network/staging and never deletes. Repeat restart, custom root, configured legacy charge changes, and rollback/re-upgrade.

### T09.5 object-count admission

With 255 valid objects, publish one distinct identity and assert a 256-object inventory. With 256, repeat the exact identity and assert idempotent success with no network, staging, new receipt, or count change. With 256, request a new distinct identity and assert refusal before network/staging. Repeat across restart and feed/release churn. Externally seed 257, 258, and 10,000 entries and prove the reader consumes at most 257 entries, reports only bounded overflow, disables preparation and published cleanup, and performs no rename or deletion.

### T09.6 bounded cleanup targets

For 0, 1, 255, and 256 valid managed identities, assert `cleanup_targets` contains every identity exactly once in digest order and each closed entry has exactly `artifact_identity_digest`, `display_model_id`, `model_revision`, `artifact_id`, `release_id`, nullable `model_key`, `root_identity_digest`, `receipt_sha256`, `estimated_bytes`, `keep_set_status`, nullable `protected_reason`, and `cleanup`, with all digest, nullability, byte-equality, and action-binding rules enforced. Remove selected identities from the current signed catalog and assert reclaimable entries remain reachable and actionable. Protected entries remain present but unavailable. Row-attached cleanup, if present, is byte-identical to its target entry. Malformed/overfull inventory yields no partial list or action, and enumeration remains capped at 257 observations.

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

Repeat each `intent` row with absent, exact-attempt, prior-attempt, and malformed cancellation markers. Before the commit barrier, an exact marker preserves final or restores tombstone→final, fully syncs the parent, clears intent, and produces `cancel_requested`/`cancelled`; a nonmatching marker cannot influence the cleanup. For `intent` with final absent/tombstone present and no exact marker, recovery repeats the parent barrier and advances to `tombstoned`. After the tombstone parent full-sync, every exact marker is late: recovery completes deletion and the transaction ends `succeeded` or recoverable `cleanup_failed`, never `cancelled`. Inject crash during the restoration rename and its barriers and prove the same table converges without two finals or two tombstones.

### T10.4 keep set, legacy prohibition, and no GC

Protect incumbent, configured legacy current/draft, active/prepared adoption, selected/active preparation, live worker, serve verification, and every different-root identity. Recompute before intent and before rename. Races becoming protected clear intent without rename. `cleanup_staging` rejects published targets. Instrument all delete paths: no automatic GC; no legacy/unmanaged object can be selected, renamed, receipted, or deleted.

### T10.5 staging-cleanup cancellation and recovery

Run `cleanup_staging` against one exact interrupted-attempt staging tree through its separate intent → tombstone → removed record. Its commit point is same-parent staging→tombstone rename plus parent `fsync`/`F_FULLFSYNC`. Inject cancel, crash, and retry before/after intent, rename, each parent barrier, phase update, every unlink, tombstone removal, `removed`, and record clear. Before commit, exact cancellation preserves or restores staging, retains `staging_cleanup_required`, and ends `cancelled`; after commit, it completes removal and ends `succeeded` or recoverable `cleanup_failed`, never `cancelled`. Retry uses only the recorded root/attempt/target/phase. Published, legacy, other-attempt, unrecorded, and different-root targets fail before rename/unlink.

## T11 — incumbent and forbidden mutations

Across every success/failure/cancel/cap/root/temp/bootstrap/publish/deletion/legacy case, compare config bytes/mode, current model/runtime generation, incumbent inference, provider identity/credentials, admission/routing, rate/economics, billing/settlement/reward/payout. All remain unchanged until separate adoption. Local Prepare copy never changes those facts.

## T12 — preparation/adoption/cleanup exclusion

Race dispatch, projection rewrite, adoption, serving verification, cleanup, temp recovery, and cancel terminal sweep. Assert fixed lock orders: preparation operation lock before adoption lock/socket/runtime reservation; operation lock before cancel lock for worker terminal/new attempt; cancel process takes only cancel lock. No deadlock, second worker, cross-attempt event/marker, or protected deletion.

## T13 — existing adoption handler readiness

Retain the existing `prepareModelAdoptionRequest`/result frames. Test already-loaded authority and absent-target reload. The server independently reloads signed feeds, resolves/validates its configured root, derives the v3 destination, validates root-bound receipt/hash, then compares requester claims. Reject legacy lookalike, alternate root, stale feed, malformed tree, tombstone, identity/hash/config/incumbent drift. Restart/race tests allow one authority snapshot and preserve the incumbent.

## T14 — CLI, worker events, and cancel acknowledgement

Test exact operator-approved catalog-economics read/run/cancel grammar, flags, option order, missing/extra args, TTY behavior, exit codes, stdout/stderr, and mutually exclusive capabilities. No alias or `models transactions` family is accepted.

Worker events alone must match IDs/kinds/model, monotonic sequence, timestamps, progress/heartbeat, approved codes, and one terminal. The cancel process stdout contains exactly one bounded acknowledgement object, never an event line. Test the T03 total precedence for all five outcomes, exact transaction echo, and exact nullable attempt invariants. `recorded` must not be rendered as terminal cancellation; Malibu continues the worker stream and refreshes projection. Late cancellation yields only the transaction-kind-authorized worker terminal. No status response schema exists.

Table-drive simultaneous faults across every adjacent class in the authority precedence. At minimum use these concrete higher-priority representatives and assert exact code, terminal, exit, and side-effect frontier:

| Concurrent faults | Winning code | Terminal / exit | Required side-effect boundary |
|---|---|---|---|
| stale action + operation conflict | `stale_transaction` | `failed` / 3 | no worker state, network, or staging |
| operation conflict + authority unavailable | `operation_conflict` | `failed` / 3 | no second worker or network |
| authority unavailable + unsafe filesystem | `authority_unavailable` | `failed` / 4 | no target-root write |
| unsafe filesystem + managed budget exceeded | `unsafe_filesystem_object` | `failed` / 4 | no traversal outside validated descriptors |
| managed budget exceeded + transfer failure | `managed_budget_exceeded` | `failed` / 4 | no network or staging |
| transfer failure + verification failure | `transfer_failed` | `failed` / 4 | no verification promotion/publication |
| verification failure + publication failure | `verification_failed` | `failed` / 5 | unpublished bytes only |
| publication/cleanup failure + cancel failure | `publication_failed` or `cleanup_failed`, according to transaction kind | `failed` / 5 | preserve exact recovery record |
| cancel failure + timeout | `cancel_failed` | `failed` / 5 | preserve exact marker/recovery state |
| timeout + internal failure | `timed_out` | `timed_out` / 124 | no success/publication after timeout |

Also cover every code within each class, three-way overlaps, fault-order permutations, and 1,000 randomized schedules. The corrected authority must reconcile any pre-worker event/exit ambiguity; the test fixture then asserts its exact closed mapping rather than accepting either result.

### T14.1 built CLI through production Malibu adapter

Build `malibu-cli`, launch that exact binary from Malibu's shipping process adapter, and feed its real stdout chunks, stderr bytes, process-exit status, and cancellation subprocess output through the production decoder/state reducer. Do not substitute `FakeModelCLI` or hand-authored JSON for this gate. Cover v2 read, each run terminal, all five cancellation acknowledgements, empty and nonempty stderr, JSONL split at every byte boundary, multiple lines per chunk, final line with/without the authority-approved newline behavior, process exit before/after final bytes, oversize lines, malformed/unknown v2 negatives, and v1 fallback. Compare decoded IDs, nullability, copy/guidance, error selection, UI terminal state, and projection refresh with the built CLI's source bytes.

## T15 — old-client fallback

Run the full production-boundary compatibility matrix, including the built CLI where available:

| Malibu | CLI advertisement | Expected call/result |
|---|---|---|
| v1-only | v1 only | one read; accept v1 only; no v2 mutations |
| v1-only | v2 plus exact v2 token only | no catalog-economics call; static/current-model fallback |
| v2-capable | v2 plus exact v2 token only | one read; accept v2 only; validated v2 actions enabled |
| v2-capable | v1 only | one v1 read; v1 UI; no v2 mutations |
| either | both generations advertised | no read or mutation; invalid-advertisement fallback |
| either | v2 without token, token without v2, unknown generation/token, or contradictory manifest/local-status values | no read or mutation; unavailable-warning fallback |
| either | neither supported generation | no read or mutation; existing silent static/current-model fallback |

For each row cover local Prepare, cancel acknowledgement, storage, and cleanup exposure. A v1-only decoder receiving v2 and a v2-selected decoder receiving v1 fail the whole envelope without retrying the same ambiguous command. Unknown compatible row/action additions disable only their affected feature when the selected envelope allows that behavior; an unsupported projection envelope triggers whole-projection fallback. No disk inference, hidden selector, environment override, or optimistic decode/retry occurs.

## T16 — exhaustive action-gating, journey, copy, and accessibility

Generate the Cartesian matrix of:

- `local_default` with all 12 admission states;
- `coordinator` with all 12 states;
- each `economics_state`: `trusted`, `fallback`, `stale`, `blocked`, `unavailable`;
- every owner-spec `provider_guidance.next_action` and `earning_path_class`, nullable/non-null transition reason, and valid label/meaning key;
- permitted/settlement booleans; `verification_status` `declared`/`verified`/`blocked`/missing/unknown; fit, runtime state, action model ID, estimate, safety warnings; and every valid/invalid candidate/guidance/source/freshness binding.

For every combination, assert invalid source/state/boolean/trusted combinations fail closed. Valid non-trusted combinations expose Prepare only when all local prerequisites pass, the primary artifact is exactly `verified`, and the required `candidate_id`, five-field `provider_guidance`, source digest/time/sequence-or-event, and admission binding are fresh and exact. Malibu renders the verbatim bound earning verdict/state first and never derives it. Local preparation uses exactly **Prepare locally**, **Download and verify this model for local use. This does not offer it to the network or enable earnings.**, and **Download and verify {estimated_size} for local use?** Rates, payouts, share, and demand do not motivate or accompany that action. Valid trusted catalog-priced/settlement-capable rows use only operator-approved trusted copy. Every `declared`, `blocked`, stale, unknown, or mismatched artifact/guidance source disables projection and direct dispatch.

Drive `local_default:local_only`, `local_default:not_offered`, `coordinator:not_offered`, and `local_default:offerable` through Prepare locally → evaluate → offer → adopt using only approved typed transactions; prove preparation remains available across the fresh `local_default:not_offered` ↔ `coordinator:not_offered` transition and remains reachable without economics/admission mutation. Exercise unavailable prerequisites and every matrix branch.

For preparation size formatting, test exact `estimated_bytes` values 1, 99,999,999, 100,000,000, 100,000,001, every `100,000,000 * n` boundary and boundary-plus-one selected across the range, and large values through exactly 1 TiB. Assert the displayed value is `ceil(bytes / 100000000) / 10` GB with exactly one fractional digit and never understates. Run `en_US`, a comma-decimal locale, and at least one locale using non-Latin digits, plus every shipped locale. For cleanup, assert each action `estimated_bytes` equals its target's exact logical reclaimable bytes and `{reclaimable_size}` represents that same value; exact source copy is **Remove this verified prepared model ({reclaimable_size} of managed data)? The current model and legacy model files will be kept.** No locale says or implies that APFS will recover that much physical capacity.

Run VoiceOver order/labels, keyboard, Dynamic Type, Reduce Motion, localization expansion, modal focus, background cancel, restart, child loss, worker event versus cancel-ack rendering, storage/legacy labels, and identity-specific cleanup confirmation. No path/secret/endpoint/prompt/completion leaks.

## T17 — upgrade, mixed store, rollback, and re-upgrade

Start from a production-shaped legacy root with configured incumbent/draft and extra unconfigured releases. Upgrade creates only `.macprovider-prepared-v3`; it does not alter legacy stat/hash/tree. Add mixed v3 releases, prepare/adopt where authorized, roll back to old CLI/app, then re-upgrade. At every phase legacy remains usable and untouched; v3 remains preserved/ignored during rollback and validates on re-upgrade; budgets/accounting match T09. Old R21-R27/v1/v2 planning state is never imported.

## T18 — dependency and governance gates

Fail unless:

1. `6f271245` and `c4401f17` are ancestors of implementation base.
2. One @Augustas11-owned SPEC-001/SPEC-044 commit freezes exact catalog-economics read/run/cancel spelling; mutually exclusive v1/v2 advertising and the full compatibility matrix; required verbatim `provider_guidance` plus exact candidate/source/freshness binding; event codes and total precedence; exhaustive R002/R003 local/trusted eligibility including `coordinator:not_offered` and `verification_status: verified`; copy/economics separation; worker-only sequencing; bounded cancel-ack schema, echo, predicates, precedence, nullability, and races; bounded complete cleanup targets; logical-byte accounting and truthful APFS copy; exact budgets and configuration precedence; and published/staging cleanup commit/recovery semantics.
3. It keeps the existing event schema, adds no status/control frame/public crash/late-cancel state, and does not overload `cleanup_staging`.
4. SPEC-001 §6.14b is `SPEC-001-R003` with a pending CONFORMANCE entry; AUTHORITY registers the applicable SPEC-044 consumer; R005 no longer credits the contradictory hide test and instead records the explicit gap and named future visible-local-preparation proof; SPEC versions, indexes, CONFORMANCE, #1485 ownership/copy, and source digests agree.
5. `git merge-base --is-ancestor <authority-commit> <first-6B-commit>` succeeds and commits differ.
6. SHA-256 digests are computed from and archived for the committed v6 plan and test specification; fresh independent review of those exact bytes plus the landed SPEC diff has zero Critical/High/Medium and explicitly dispositions B1-AUTH-H1/H2 and M1-M13.
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

The slice gate must include the T14.1 built-CLI-to-production-Malibu adapter test as its own named test target or xcodebuild case. Separate CLI unit tests plus `FakeModelCLI` Malibu tests do not satisfy it.

## T20 — independent review gate

Run independent code, security, and architecture lanes over the complete authority-through-implementation diff. Each lane explicitly dispositions B1-V2-H1 and M1-M5, B1-V3-M1, B1-AUTH-H1/H2 and M1-M13, plus all prior v1 findings. Any Critical/High/Medium blocks; fixes require affected tests and all full-diff lanes again.
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
| Authoritative guidance and reachable pre-offer Prepare | T01, T05, T16, T18 | Verbatim guidance/correlation plus operator R002/R003 matrix/copy commit |
| Deterministic v1/v2 compatibility | T01, T14, T15 | Mutually exclusive advertisements and built production-boundary matrix |
| Intent-first exact deletion/cancellation recovery | T10 | Published/staging boundary state/authority logs + power cases |
| Crash-safe temp/root bootstrap | T01, T04, T08 | Complete injection matrix |
| Enforceable URLSession bounds only | T06, T09, T21 | Separated counters and real transfer |
| Dedicated v3 namespace/logical accounting/legacy safety | T09, T10, T17, T21 | Algorithm fixtures and upgrade/mixed/rollback hashes |
| Reachable bounded cleanup for every v3 object | T09, T10, T16 | Complete deterministic cleanup-target projection |
| Worker-only events/cancel acknowledgement | T03, T06, T14 | Total ack precedence and randomized two-process schedules |
| Exact error precedence | T14 | Adjacent/three-way fault table with code/terminal/exit/side effects |
| Object-count admission and fail-closed overflow detection | T09, T10 | 255/256/idempotent/257 refusal, 257/258/large seeded overflow, and cleanup-race schedules |
| Prior root/selection/durability/resource/adoption gates | T02-T13 | Targeted and APFS evidence |
| Malibu copy/accessibility/fallback | T14-T17 | Built adapter/decoder, exact size/locales, and UI/accessibility results |
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
| B1-AUTH-H1 | T01, T05, T14, T16, T18 | V2 carries verbatim guidance and exact fresh candidate/source correlation; production Malibu renders it first without inference. |
| B1-AUTH-H2 | T01, T14, T15, T18 | Advertising is mutually exclusive and every old/new combination has one deterministic call/fallback result. |
| B1-AUTH-M1 | T16 | Both-source `not_offered` and its transition retain the authorized local path. |
| B1-AUTH-M2 | T05, T16 | Only exact current `verification_status: verified` can project or dispatch preparation. |
| B1-AUTH-M3 | T03, T14 | Echo, durable predicates, total first-match precedence, and nullability are exact for all acknowledgement outcomes. |
| B1-AUTH-M4 | T10 | Published and staging cleanup have explicit commit points and converge under cancel/crash/retry at every phase. |
| B1-AUTH-M5 | T09, T16, T21 | One checked logical-byte algorithm drives all values; cleanup copy does not promise APFS physical recovery. |
| B1-AUTH-M6 | T09, T10, T16 | Every verified managed identity, including catalog-orphaned objects, has one bounded target entry and accurate keep-set action. |
| B1-AUTH-M7 | T18 | `SPEC-001-R003`, CONFORMANCE, AUTHORITY consumers, R005 gap/proof, versions, and indexes agree. |
| B1-AUTH-M8 | T14, T15, T19 | Built CLI stdout/stderr/exit crosses the production Malibu adapter and decoder for all required paths. |
| B1-AUTH-M9 | T09 | Default crossover/rounding, source precedence, invalid overrides, checked overflow, and exact byte/free-space thresholds pass. |
| B1-AUTH-M10 | T09 | Unavailable legacy accounting blocks projection, stale direct dispatch, and published cleanup before side effects while serving continues. |
| B1-AUTH-M11 | T16 | Exact byte-boundary vectors and locales, including non-Latin digits, never understate preparation or mismatch cleanup bytes. |
| B1-AUTH-M12 | T06 | The two-second claim uses the exact frozen clock/profile/tolerance; all other cases use functional watchdog/heartbeat/timeout requirements. |
| B1-AUTH-M13 | T14 | Adjacent and multi-fault tables select the exact code, terminal, exit, and side-effect boundary. |

All v1 dispositions remain mandatory and are mapped in the plan.

## Stop condition

The reservation subplan is implementation-complete only when T01-T20 pass on the full final diff and independent reviews report zero Critical, High, and Medium. Build 1 is complete only when T21-T24 pass with final signed assets, accepted signed discovery/admission journeys, correctly settled positive credit, first listed-tier evidence, stable-media qualification, and updater proof. No plan, fixture, issue checkbox, prepared artifact, or slice 6 suite replaces those gates.
