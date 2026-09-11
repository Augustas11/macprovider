# Build 1 preparation-reservation rebaseline test specification v8

Status: revised acceptance specification for `reservation-rebaseline-plan-v8.md` after the blocking preparation-authority v3 review. No implementation test may be credited before the corrected, complete operator-owned authority commit in T18 lands.

Implementation baseline: `c4401f1791d593d37d68eba91af94219b26d278f`. Planning/review baseline: `f7e584499828b3d16036382848b5caa1a897cdf9`. Blocked authority candidate: `fccb813cfa02fba5bc7aec71ee23bccb4619429b`.

Revision inputs: v7 plan SHA-256 `033d57a69f0c754051625d1c628fcf9a5f8e9f89ae07ba05e76a8a02d1bb841a`; v7 test-spec SHA-256 `2c404fb012831440b89a1004bbc278f827c0c82885f845c8fe114a97e0950d43`; blocking review `reviews/preparation-authority-v3-sol.md`. T18 records SHA-256 digests from the committed v8 bytes.

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
| Built CLI → production Malibu boundary | Real subprocess stdout/stderr/exit through the constant-space shipping process adapter, strict decoder, bounded queue, and app-owned refresh generation |
| Real-Mac harness | MLX serving, power recovery, signed journeys/settlement/release |

## T01 — frozen public authority and strict private codecs

### T01.1 public authority inventory

At the exact T18 authority commit assert:

- read remains `models catalog-economics --json`, with no transaction-status surface;
- v1-serving CLI advertisements contain exactly `model_catalog_economics_v1` plus `models catalog-economics.v1`; v2-serving advertisements contain exactly `model_catalog_economics_v2` plus `models catalog-economics.v2`; capability-only, token-only, dual, conflicting, unknown, or manifest/local-status-disagreeing advertisements are invalid;
- run/cancel spellings exist only under the approved catalog-economics capability;
- progress/results use only `model_catalog_transaction_event.v1` and its seven states;
- only the worker emits events and allocates `event_sequence`;
- cancellation returns exactly the approved `model_catalog_transaction_cancel_ack.v1` shape, or the operator's explicitly substituted shape, capped at 4096 bytes, with six outcomes including `busy`, and with no event sequence/terminal-success assertion;
- candidate-associated rows carry the all-non-null `candidate_id`/verbatim SPEC-046 `provider_guidance`/closed `guidance_binding` group; signed-catalog-only rows carry all three as null, are always nontrusted with every money/demand field null, and expose no candidate action/guidance/admission/economics claim; every partial group and every cross-candidate evidence join is invalid;
- coordinator guidance binding mirrors a nullable event only for an exact authoritative no-event `not_offered` response and otherwise requires the source event; missing, future, stale, cross-candidate, cross-source, cross-event/sequence, or mismatched guidance fails closed and Malibu renders the authoritative verdict first;
- R002/R003 contain the complete local/trusted preparation matrix, including `coordinator:not_offered`, exact `verification_status: verified`, and exact copy;
- the cancellation acknowledgement defines request echo, the 2.000-second monotonic lock-acquisition deadline, six outcomes including no-mutation `busy`, total acquired-lock first-match precedence, exact attempt-ID nullability, exit behavior, and resource bounds;
- `cleanup_targets` is bounded, complete for verified managed identities, deterministic, carries a required immutable receipt-bound `event_model_key`, and retains runnable reclaimable objects with nullable current `model_key` when no catalog row remains;
- logical byte accounting and the truthful managed-data cleanup copy are exact and distinct from APFS physical free-space recovery;
- published and staging cleanup each use durable `tombstoned` phase as sole commit evidence, restore every exact-marker precommit tombstone, and permit recovery mutation only under operation→cancel ownership;
- root identity digest covers secret nonce plus the complete canonical validated identity schema/version/path/device/inode, and every reopening lifecycle record persists the saved locator/descriptor/version/digest;
- every private object has an empty extended ACL; a new sensitive object is already open, unpublished, and owner-only before ACL stripping/empty verification and writes no sensitive byte before that proof; descriptor revalidation remains mandatory;
- `settlement_capable` maps exactly to **Eligible to earn on qualifying settled requests** in provider-facing output and never to a current-income claim;
- row ranking uses the exact canonical-wire total tuple, explicit null order, final unique `model_key`, duplicate rejection, and no locale collation;
- `SPEC-001-R003`, its pending CONFORMANCE entry, AUTHORITY consumers, and SPEC-044-R005 evidence/gap mapping agree;
- published cleanup is separate from `cleanup_staging`;
- no status schema, `models transactions` family, public crash/late-cancel state, or new control frame exists.

Reject unknown public fields/enums, invalid source/state/economics combinations, partial candidate groups, any non-`verified` artifact status, stale/mismatched guidance, mismatched IDs/kinds/event model key, nonmonotonic worker sequences, illegal nullability, incomplete cleanup-target coverage, and oversized lines/acknowledgements.

### T01.2 private codec round trips

Round-trip minimum/maximum v3 reservation, active, cancellation, inventory, deletion intent/tombstoned/removed, staging-cleanup intent/tombstoned/removed, root identity, publication receipt, and unique-temp records. Assert every reopening record carries canonical path, `st_dev`, `st_ino`, identity schema/version, and digest; cleanup records carry immutable `event_model_key`. Reject duplicate/unknown keys, wrong schema/kind/target/generation/root/tuple, malformed UUID, invalid UTF-8, floats, negative/overflow integers, trailing bytes, checksum mismatch, and one-byte-over caps.

### T01.3 unique temporary recovery

For `reservations.json`, `active.json`, `cancel.json`, `published-inventory.json`, and `deletion.json`, inject crash after unique temp create, every partial write boundary, completed write, `fsync`, `F_FULLFSYNC`, readback, rename, parent `fsync`, and parent `F_FULLFSYNC`. Assert:

- incomplete recognized temps are descriptor-validated and removed;
- complete newer temps finish the exact rename/barrier;
- valid equal/newer durable targets win;
- at most 16 total/four-per-kind recognized temps are processed;
- hostile names/types/owners/modes/links/checksums fail closed;
- ordinary interrupted temps never permanently wedge the projection or next transaction.

### T01.4 root.identity bootstrap

Inject the same boundary crashes in `bootstrap-tmp`. Assert no partial bytes ever appear as final `root.identity`; a complete temp can finish exclusive rename; an incomplete recognized temp is removed and regenerated; crash after rename repeats the parent barrier; valid final identity removes stale recognized temps; malformed/conflicting final identity fails closed. Derive the digest from a fixed canonical-encoding vector and show one-bit changes to nonce, identity version/schema, path, device, or inode change it. Repeat concurrent first projection across processes under the operation lock.

## T02 — deterministic bounded selection without starvation

Retain v2 tests at 0/1/3/64/65/128/256 and failure at 257. Permute feed order, restart processes, mutate/remove/re-add boundary rows, and run enough generations to prove the eight-slot fairness bound. Retained unchanged tuples preserve IDs; evicted/re-entered tuples follow deterministic metadata. Race dispatch and rewrite 1,000 times: dispatch-win pins one durable active tuple; rewrite-win returns approved stale/action-unavailable with zero side effects.

Repeat selection for every preparation classification from T16. Economics state must not perturb tuple/action ID when the operator contract says the same local artifact action remains eligible; a classification or signed target change must do so exactly as specified.

## T03 — operation, cancel, and event ownership

Fork independent worker, projection, cancel, and retry processes. Assert one live `operation.lock`, one attempt, one worker stdout stream, and one monotonic event sequence. No cancel invocation writes an event or event-sequence field.

Exercise both orders at every boundary: cancel-lock wait start; elapsed time immediately below and exactly at 2.000 seconds; timely cancel-lock acquire; active read; marker create/temp sync/rename/parent sync; acknowledgement write; worker marker read; `cancel_requested` event; cleanup; terminal state sync; worker cancel-lock acquire; marker removal; operation-lock release while cancel lock held; terminal compaction; and new-attempt creation. Use an injected `CLOCK_MONOTONIC_RAW` source for deadline boundary tests.

Required outcomes:

- every syntactically valid acknowledgement byte-for-byte echoes the requested `transaction_id`; malformed input emits no valid acknowledgement;
- the cancel process opens only `cancel.lock`, performs read-only bounded validation plus exact marker create/reuse/stale-marker removal, and never takes `operation.lock`, restores/renames/deletes a target, advances a cleanup phase, or runs temp/root recovery;
- acquisition before elapsed 2.000 seconds proceeds under `cancel.lock`; failure to acquire when elapsed reaches 2.000 seconds emits exactly one valid `busy` acknowledgement with null attempt ID, empty stderr, exit 0, and zero reads or mutations of marker, active/history, terminal, cleanup phase, temp, artifact, or operation state;
- after timely acquisition, table-drive the total first-match order: matching durable terminal → `terminal`; matching nonterminal active plus exact durable marker → `already_recorded`; matching nonterminal active without exact marker → durable write then `recorded`; recognized non-current/stale transaction state → `stale`; no matching bounded state → `not_active`;
- `recorded`, `already_recorded`, and `terminal` always carry the exact non-null attempt ID; `not_active` and `busy` always carry null; `stale` carries the stale attempt ID exactly when safely known and otherwise null; all six valid outcomes exit 0, while malformed input/state emits no valid acknowledgement and uses the exact nonzero authority exit;
- construct overlapping terminal/active/marker/history fixtures for every adjacent precedence pair and assert the first outcome wins without extra writes;
- cancel before a transaction-specific commit point returns `recorded`/`already_recorded`; worker emits exactly one `cancel_requested` and one terminal `cancelled` only after reversible cleanup;
- cancel after preparation publication or either durable cleanup `tombstoned` phase commit may acknowledge `recorded`, but worker emits only terminal `succeeded`/`failed` and clears the marker;
- cancel that obtains `cancel.lock` after worker terminal/release returns `terminal` when the bounded terminal record matches, otherwise `stale` or `not_active` by the total table, and writes no marker;
- a marker written before terminal sweep is removed by the worker;
- no write can occur after the sweep but before lock release because worker holds `cancel.lock` across operation-lock release;
- new attempt removes only a validated prior-attempt marker under operation→cancel lock order;
- stale/mismatched marker returns `stale`, never affects another attempt, and is cleaned without deleting unrelated files;
- sequences have no duplicate/gap caused by cancellation and exactly one terminal event.

Hold `cancel.lock` across injected slow and stuck object/phase syncs. Prove one waiter returns `busy` at the exact deadline without mutation, then prove a later fresh invocation observes the worker/recovery result after release. Launch 100 direct cancel invocations against the held lock and assert every process exits by its own bound with one valid `busy`, no waiter/descriptor/thread/child/temp leak, and no marker/phase change. Through Malibu, issue 1,000 repeated cancel gestures for one transaction and assert at most one cancellation subprocess is live, repeats coalesce, a `busy` result permits only a fresh bounded retry, and process/resource counts return to baseline. Run 10,000 randomized schedules and restart between schedules.

## T04 — custom roots and bootstrap crash recovery

Run projection → dispatch → transfer → publish → recovery → adoption with default, environment, and config roots. Bind canonical path, `st_dev`, `st_ino`, identity schema/version, and root-identity digest in every reopening lifecycle record/receipt. Recompute the digest over the exact validated canonical identity record including a secret 256-bit nonce and descriptor identity. Repeat with authority and artifact roots on separate APFS volumes.

Crash during root bootstrap and every private write using T01 injection. Change config/environment from root A to B afterward. Recovery must use only saved A, reconcile its recognized temp, staging, unpublished, marker, or deletion record, and leave B untouched. Test copied nonce/identity records with rewritten path/device/inode/version, symlink/path replacement, move/remount/device change, inode-reuse simulation, wrong device/inode, and restored original root. Each mismatch fails before mutation; restoring the exact original descriptor and record converges. Serving configured for B rejects A; serving configured for A independently verifies the v3 receipt/hash.

## T05 — stale IDs, tuple/feed/root drift

After projection, vary model/revision/artifact/release/signer/feed digest/estimate, `candidate_id`, all five verbatim `provider_guidance` fields, and every `guidance_binding` field: source schema, exact source-byte SHA-256, generated time, projection sequence, coordinator event, candidate, admission source, and admission state. Test local-default sequence/non-event binding; coordinator `not_offered` with null event and exact whole-response digest; event-backed coordinator `not_offered`; all other coordinator states with required non-null event; and forbidden null/non-null substitutions. For an all-null catalog-only row, attempt to attach admission/rate/demand evidence from candidate A through matching prior/newer-snapshot `model_key`, current `served_model_id`, display name, artifact ID, release ID, or feed position while the displayed row corresponds to candidate B or to no candidate. Every cross-candidate or inferred join remains nontrusted, nulls all money/demand fields, and exposes no candidate action; duplicate exact `model_key` values within one projection reject the projection before any join or rendering. Test age at -1 second (future), 0, the exact `min(300, owner_source_max_age)` boundary, and one second beyond it. Also vary provider/config identity, root canonical path/device/inode/version/digest, matrix classification, and action copy version. Exercise artifact `verification_status` at `declared`, `verified`, `blocked`, missing, and unknown before projection, at dispatch, and after feed refresh. Only exact current `verified` may project or dispatch Prepare. Every stale or mismatched case fails before network/write unless the authority contract expressly preserves the tuple. Feed/guidance drift before publication blocks; drift after durable publication leaves inert bytes but cannot grant current readiness/adoption. Root changes never redirect cleanup.

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

For authority root, v3 namespace, root identity, locks, private targets/temps, staging/unpublished/objects, receipt, deletion record/tombstone, and configured legacy path, test symlink, hard link, FIFO/socket/device, wrong owner/mode/link count, oversize, descriptor swap, mount transition, collisions, traversal, 4097th path, depth 33, and unexpected object.

For every private component, create an ancestor default/inherited ACL granting a named second user, then verify each new directory/file is created owner-only as an already-open, unpublished temporary entry. Through that same descriptor, strip the inherited ACL and verify zero extended entries before the first sensitive byte. Inject failure before strip, during strip, and during empty-ACL verification; only the newly created still-empty object may be removed, and no sensitive bytes may be observed by the second user or remain on disk. Existing objects with access, deny, inherited, or mixed extended ACL entries fail closed without in-place repair. Race ACL insertion after initial validation and immediately before each sensitive read/write, state rename, publication, final↔tombstone rename, restoration, unlink, or authority use; same-descriptor owner/type/mode/link/device/inode/ACL revalidation must abort before the side effect and leave outside sentinels unchanged. Mode-only `0700`/`0600` success is insufficient.

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

For 0, 1, 255, and 256 valid managed identities, assert `cleanup_targets` contains every identity exactly once in digest order and each closed entry has exactly `artifact_identity_digest`, `display_model_id`, `model_revision`, `artifact_id`, `release_id`, required immutable `event_model_key`, nullable current `model_key`, `root_identity_digest`, `receipt_sha256`, `estimated_bytes`, `keep_set_status`, nullable `protected_reason`, and `cleanup`, with all digest, nullability, byte-equality, and action-binding rules enforced. Remove selected identities from the current signed catalog and assert reclaimable entries remain reachable and actionable with current `model_key: null` while the receipt-bound `event_model_key` remains unchanged. Protected entries remain present but unavailable. Row-attached cleanup, if present, is byte-identical to its target entry. Malformed/overfull inventory yields no partial list or action, and enumeration remains capped at 257 observations.

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

At each point assert exact durable record phase plus final/tombstone existence. No tombstone may exist without at least durable `intent`. The rename and both successful parent barriers remain reversible while durable phase is `intent`; `tombstoned` may be recorded only after the barriers and its own file/rename/parent durability sequence. Only durable `tombstoned` is commit evidence.

### T10.3 exact recovery table

Test all combinations authorized by the plan:

| durable phase | final | tombstone | result |
|---|---:|---:|---|
| none | yes | no | no cleanup authority; preserve final |
| `intent` | yes | no | recheck keep set, resume rename or clear intent |
| `intent` | no | yes | exact marker restores final; otherwise recovery worker repeats barriers and durably advances `tombstoned` |
| `intent` | yes | yes | fail closed |
| `intent` | no | no | fail closed |
| `tombstoned` | no | yes | resume exact deletion |
| `tombstoned` | no | no | repeat parent barrier, advance `removed` |
| `tombstoned` | yes | any | fail closed |
| `removed` | no | no | clear record |
| `removed` | any present | any present | fail closed |

Recovery uses only recorded tuple/root/final/tombstone identity and saved root locator/descriptor/version/digest; no scan/guess. Change config/env to another root after each crash and prove original-only recovery. Instrument ownership: only worker/recovery worker holding `operation.lock`, then the cleanup lock, then `cancel.lock` may mutate cleanup recovery state, and it retains all three while mutating; cancellation holds only `cancel.lock` and may validate/write a marker.

Repeat each `intent` row with absent, exact-attempt, prior-attempt, and malformed cancellation markers. Before the worker's final marker check, an exact marker preserves final and produces `cancel_requested`/`cancelled`; a nonmatching marker cannot influence cleanup. Instrument the live worker and prove it holds `cancel.lock` without interruption from that final check through final→tombstone rename, objects-parent `fsync`, objects-parent `F_FULLFSYNC`, every `tombstoned` temp/write/file barrier/rename/parent barrier, and readback validation. A concurrent cancel cannot write a marker anywhere inside that interval and observes only the resulting durable phase after acquiring the lock. Only after durable readback-validated `tombstoned` is every new marker postcommit: deletion completes with `succeeded` or recoverable `cleanup_failed`, never `cancelled`.

For every crash injected after rename or either parent barrier but before durable readback-validated `tombstoned`, prove the kernel releases `cancel.lock` and leaves reversible `intent`. Exercise both post-crash acquisition orders: cancellation-first durably records the exact marker without mutating the phase, then recovery acquires operation→cleanup→cancel, restores tombstone→final, fully syncs the parent, clears intent, and emits `cancel_requested`/`cancelled`; recovery-first sees no marker, repeats both parent barriers, durably persists/full-syncs/readback-validates `tombstoned` while holding all locks, and makes any later cancellation postcommit. Inject crashes throughout both paths and prove convergence without two finals or two tombstones. Do not construct or accept a live-worker marker write after the final check and before durable `tombstoned`.

### T10.4 keep set, legacy prohibition, and no GC

Protect incumbent, configured legacy current/draft, active/prepared adoption, selected/active preparation, live worker, serve verification, and every different-root identity. Recompute before intent and before rename. Races becoming protected clear intent without rename. `cleanup_staging` rejects published targets. Instrument all delete paths: no automatic GC; no legacy/unmanaged object can be selected, renamed, receipted, or deleted.

### T10.5 staging-cleanup cancellation and recovery

Run `cleanup_staging` against one exact interrupted-attempt staging tree through its separate intent → tombstone → durable `tombstoned` → removed record. Its commit evidence is durable readback-validated `tombstoned`. Prove worker/recovery holds operation→cleanup→cancel locks continuously from the final marker check through rename, parent `fsync`/`F_FULLFSYNC`, every phase-write durability step, and phase readback. Inject cancel, crash, and retry before/after intent, rename, each parent barrier, every phase-write durability step, every unlink, tombstone removal, `removed`, and record clear. No live-worker cancel-lock handoff vector is valid. For every precommit crash leaving `intent`, run cancellation-first restoration and recovery-first durable-commit orders exactly as T10.3. Cancellation-first preserves or restores staging, retains `staging_cleanup_required`, and ends `cancelled`; after durable `tombstoned`, cleanup ends `succeeded` or recoverable `cleanup_failed`, never `cancelled`. Retry uses only the recorded root/attempt/target/phase. Published, legacy, other-attempt, unrecorded, and different-root targets fail before rename/unlink.

### T10.6 orphan cleanup event correlation

Publish a row, seal its historical model key as `event_model_key`, then remove it from every current catalog/candidate source so projected current `model_key` is null. Dispatch its cleanup transaction and assert every queued/running/cancel/terminal event uses the immutable non-null `event_model_key` and matches the durable reservation/active/deletion records. Cover success, precommit cancel/restoration, crash before and after durable `tombstoned`, recovery, idempotent retry, and failure. Repeat through the built CLI and production Malibu adapter; the orphan remains visible/actionable by target identity and its events never invent a replacement key or borrow another row's key.

## T11 — incumbent and forbidden mutations

Across every success/failure/cancel/cap/root/temp/bootstrap/publish/deletion/legacy case, compare config bytes/mode, current model/runtime generation, incumbent inference, provider identity/credentials, admission/routing, rate/economics, billing/settlement/reward/payout. All remain unchanged until separate adoption. Local Prepare copy never changes those facts.

## T12 — preparation/adoption/cleanup exclusion

Race dispatch, projection rewrite, adoption, serving verification, published/staging cleanup, precommit restoration, temp recovery, durable tombstoned phase persistence, and cancel terminal sweep. Assert fixed lock orders: preparation/cleanup/recovery operation lock before adoption lock/socket/runtime reservation; cleanup worker/recovery takes operation→cleanup→cancel and holds the full set throughout recovery mutation and the final-check-through-tombstoned critical section; cancel process takes only cancel lock and never recovery-mutates. Include operation-lock busy/free, cancel before the final check, cancel blocked throughout the continuous lock interval, 2.000-second cancel-lock timeout to no-mutation `busy`, phase-write failure, worker crash, cancellation-first versus recovery-first post-crash acquisition, and new-attempt creation. No deadlock, second worker, cross-attempt event/marker, protected deletion, cancel-side phase change, or leaked waiter/process/resource.

## T13 — existing adoption handler readiness

Retain the existing `prepareModelAdoptionRequest`/result frames. Test already-loaded authority and absent-target reload. The server independently reloads signed feeds, resolves/validates its configured root, derives the v3 destination, validates root-bound receipt/hash, then compares requester claims. Reject legacy lookalike, alternate root, stale feed, malformed tree, tombstone, identity/hash/config/incumbent drift. Restart/race tests allow one authority snapshot and preserve the incumbent.

## T14 — CLI, worker events, and cancel acknowledgement

Test exact operator-approved catalog-economics read/run/cancel grammar, flags, option order, missing/extra args, TTY behavior, exit codes, stdout/stderr, and exclusive complete capability/token pairs. No alias or `models transactions` family is accepted.

Worker events alone must match IDs/kinds/model, monotonic sequence, timestamps, progress/heartbeat, approved codes, and one terminal. The cancel process stdout contains exactly one bounded acknowledgement object, never an event line. Test all six T03 outcomes, the 2.000-second monotonic acquisition boundary, the acquired-lock total precedence, exact transaction echo, exact nullable attempt invariants, and exact exit/stderr behavior. `recorded` must not be rendered as terminal cancellation; `busy` must render only that the bounded cancellation request could not acquire authority and may be retried, never terminal success/failure or worker observation. Malibu continues the worker stream and refreshes projection. Late cancellation yields only the transaction-kind-authorized worker terminal. No status response schema exists.

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

Build `malibu-cli`, launch that exact binary from Malibu's shipping process adapter, and feed its real stdout chunks, stderr bytes, process-exit status, and cancellation subprocess output through the production decoder/state reducer. Do not substitute `FakeModelCLI` or hand-authored JSON for this gate. Cover v2 read, each run terminal, all six cancellation acknowledgements including deadline `busy`, orphan cleanup from T10.6, empty and nonempty stderr, JSONL split at every byte boundary, multiple lines per chunk, final line with/without the authority-approved newline behavior, process exit before/after final bytes, oversize lines, malformed/unknown v2 negatives, and v1 fallback. Compare decoded IDs, nullability, conditional earning copy/guidance, error selection, UI terminal state, and projection refresh with the built CLI's source bytes. Repeated UI cancellation must never launch more than one live child for one transaction.

Feed a no-newline byte stream and assert rejection at byte 16385 rather than after EOF/newline. Sustain maximum-size valid lines at faster-than-MainActor consumption for the full action timeout, plus infinite-source harness runs stopped after a fixed observation window. Measure retained partial bytes, decoded events, scheduled MainActor work, stdout retention, and stderr retention: each remains within its declared fixed byte/item cap independent of line count and elapsed duration; stdout is continuously drained and never accumulated whole. Fill the delivery queue and stderr cap, verify deterministic backpressure/coalescing/failure and truncation metadata, preserve accepted event order and terminal semantics, and prove process pipes do not deadlock when UI delivery is stalled.

Allocate app refresh generation A before launching read A and B before launching read B. Test completion A→B and B→A, accepting only the latest-launched generation once B exists; launch B during A decode; dispatch an action from the last accepted projection between replies; restart the CLI so `process_launch_id` and `projection_sequence` reset; timeout A before its late reply; and restart Malibu to create a new app epoch. A late/superseded read never replaces B, while the independently attached action worker continues draining events and reaches its correct terminal state.

## T15 — old-client fallback

Run the full production-boundary compatibility matrix, including the built CLI where available:

| Malibu | CLI advertisement | Expected call/result |
|---|---|---|
| v1-only | exact v1 capability + `models catalog-economics.v1` token only, equal in manifest/status | one read; accept v1 only; no v2 mutations |
| v1-only | v2 plus exact v2 token only | no catalog-economics call; static/current-model fallback |
| v2-capable | v2 plus exact v2 token only | one read; accept v2 only; validated v2 actions enabled |
| v2-capable | exact v1 capability + `models catalog-economics.v1` token only, equal in manifest/status | one v1 read; v1 UI; no v2 mutations |
| either | both complete generations, or one complete pair plus either member of the other | no read or mutation; invalid-advertisement fallback |
| either | v1 capability-only, v1 token-only, v2 capability-only, v2 token-only, unknown/mixed generation/token, or contradictory values | no read or mutation; unavailable-warning fallback |
| either | manifest and local status each show a valid pair but disagree on generation, or either surface is partial/dual/stale | no read or mutation; unavailable-warning fallback |
| either | neither supported generation | no read or mutation; existing silent static/current-model fallback |

For each row cover local Prepare, cancel acknowledgement, storage, and cleanup exposure. A v1-only decoder receiving v2 and a v2-selected decoder receiving v1 fail the whole envelope without retrying the same ambiguous command. Unknown compatible row/action additions disable only their affected feature when the selected envelope allows that behavior; an unsupported projection envelope triggers whole-projection fallback. No disk inference, hidden selector, environment override, or optimistic decode/retry occurs.

### T15.1 preserved R002/R003/R004-R006 vectors

Use injectable entropy and identity sources. For 10,000 process starts, assert each `process_launch_id` is a lowercase UUID v4 produced from at least 128 CSPRNG bits, collision-free in the corpus, and changes when entropy changes while PID, host serial, MAC, host UUID, provider ID, wallet, and username remain fixed. Hold entropy fixed in a test double while changing each identity input and assert the encoded UUID does not change; static dependency/call-site inspection must show none of those identity values enters UUID derivation. Repeat the distinct action/attempt UUID rules with their required CSPRNG entropy and assert action, attempt, process, transaction, candidate, and root IDs are never reused or derived from one another.

Within one `process_launch_id`, feed sequences 0→1→2, duplicates, gaps, and 2→1: only strictly newer same-process projections advance. Restart to a new launch ID with sequence 0 and assert the CLI-session baseline resets inside the currently accepted app refresh generation; it must not override the app-owned A/B order from T14.1. Persist/restart Malibu and prove callbacks from the old app epoch are discarded.

Use a frozen wall clock for live signed rate-card ages 299, 300, and 301 seconds at max age 300; 604799, 604800, and 604801 at max age 604800; and invalid max ages 299 and 604801. Equality is fresh, one second over is stale, and an out-of-range max age makes the projection unavailable. While visible, render at ages `min(300,max_age)-1`, exactly the bound, and bound+1; the last refreshes or becomes unavailable before display. Cover valid live signed, valid static signed, missing, signature-invalid, generated-at mismatch, policy-version mismatch, unknown multiplier, stale live, fresh static fallback, and stale static fallback. Assert exact feed digests/source nullability, matching demand/candidate generation and policy when used, money-action disablement, warnings, and conservative state precedence `blocked > unavailable > stale > fallback > trusted`; stale fallback is `stale`, and unsigned/untrusted bytes never become trusted through fallback.

For rate/share math, use exact decimal/rational owner conversions and golden rows: catalog prompt/completion `2.00/4.00` with `provider_share_bps=9000` yields provider `1.80/3.60` USD per million tokens; repeat share bps `0`, `1`, `3333`, `9000`, and `10000`, zero/maximum supported rates, multiplier boundaries, below-half/exact-half/above-half ties, and checked overflow. Compare projection values to the SPEC-005 integer/round-half-even oracle and reject float-drift or a payout inconsistent with catalog rate × share. Format `0`, `0.004567`, `0.0999`, `1`, `1.005`, `9.999`, `10`, and `1234.5` in every shipped locale with at least two significant figures, explicit USD-per-1,000,000-token units, and distinct prompt/completion labels; parsing the localized result must preserve the projected value within the declared display rounding and never turn a rate into time-based income.

Build deterministic ranking fixtures for the exact total tuple from the plan: `bucket_rank` ascending (`current`, non-current locally ready trusted, recommended/high-demand fitting, needs-preparation, remaining visible catalog/blocked); bucket-1 exact provider completion payout descending with null last; bucket-2 recommendation rank ascending, demand rank ascending, demand weight descending, supply-deficit score descending, and ready-provider count ascending with every null after every non-null; exact `display_model_id` unsigned UTF-8 bytes ascending; nullable exact `candidate_id` bytes ascending with null last; and exact required `model_key` bytes ascending as the final unique key. Compare numeric wire integers/rationals exactly, never through binary floating point. Use no locale collation, case folding, Unicode normalization, localized display value, or input stability as a tie-break. Reject the entire projection before rendering/actions when exact `model_key` is duplicated.

Isolate every tuple component with equal-display-name/case/Unicode fixtures, null/non-null pairs, duplicate payout/rate/demand values, and rows tied on every component before `model_key`. Permute row, catalog, rate-card, demand-feed, and candidate-feed order exhaustively for small sets and across 10,000 seeded permutations for larger sets; repeat under `en_US`, `tr_TR`, `sv_SE`, a comma-decimal locale, a non-Latin-digit locale, every shipped locale, and every shipped RTL locale. The byte-identical accepted row set must produce the same ordered `model_key` list in every run. Missing/stale/fallback/blocked economics carries its localized warning and cannot rank from rate/share/demand. Every component unauthorized for a bucket is normalized to null. A v2 locally motivated Prepare row remains in Needs preparation and its relative order is invariant while only rate, payout, provider-share, demand rank/weight/provider count/deficit fields change. Demand may influence a trusted row only when signed rate/demand/candidate generated-at and policy versions match.

For action gating, use explicit positive/one-fault-negative rows. Immediate Switch requires exact `action_model_id`, verified local artifact, `fit: fits`, warm-swap available, and matching `switch_model`; deferred Switch requires the same local/fit identity, warm-swap unavailable, matching `switch_model_deferred`, and exact restart/drain/resume copy. Evaluate remains available under degraded economics only when read-only, at most 10 seconds, no bytes/download/cache/config mutation, and neutral copy; otherwise it follows preparation confirmation/progress/cancel/cleanup requirements or is unavailable. Adopt for an unprepared target is unavailable until a separate Prepare succeeds; an adopt transaction that downloads, stages, or has `estimated_bytes` follows all preparation invariants. Every available action has matching non-null kind/ID/timeout and required confirmation; every unavailable action has null kind/ID/timeout and nonempty reason. Reconcile Switch/Evaluate/Prepare/Adopt only after a matching terminal plus fresh projection, including timeout and cancellation-too-late cases.

## T16 — exhaustive action-gating, journey, copy, and accessibility

Generate the Cartesian matrix of:

- `local_default` with all 12 admission states;
- `coordinator` with all 12 states;
- each `economics_state`: `trusted`, `fallback`, `stale`, `blocked`, `unavailable`;
- every owner-spec `provider_guidance.next_action` and `earning_path_class`, nullable/non-null transition reason, and valid label/meaning key;
- permitted/settlement booleans; `verification_status` `declared`/`verified`/`blocked`/missing/unknown; fit, runtime state, action model ID, estimate, safety warnings; and every valid/invalid candidate/guidance/source/freshness binding.
- signed-catalog-only rows with no owner-source candidate, then the first snapshot that adds a matching candidate; and every partial-null candidate/guidance/binding permutation.

For every combination, assert invalid source/state/boolean/trusted combinations fail closed. Valid non-trusted candidate-associated combinations expose Prepare only when all local prerequisites pass, the primary artifact is exactly `verified`, and the required `candidate_id`, five-field `provider_guidance`, source digest/time/sequence-or-nullable-event, and admission binding are fresh and exact. Test coordinator `not_offered` both with null event bound by the exact response digest and with a real event; no synthesized event is accepted. Malibu and every provider-facing CLI human renderer map the verbatim bound `earning_path_class` first and never derive it. For `settlement_capable`, English output is exactly **Eligible to earn on qualifying settled requests**; localized and screen-reader output must preserve conditional eligibility and the qualifying-settlement condition and must never say or imply **Earning now**, current income, current traffic, an accepted request, or a settled receipt. Run the same negative semantic assertions over every shipped locale and accessibility label. Preserve the other three exact owner mappings and their order. Local preparation uses exactly **Prepare locally**, **Download and verify this model for local use. This does not offer it to the network or enable earnings.**, and **Download and verify {estimated_size} for local use?** Rates, payouts, share, and demand do not motivate or accompany that action. Valid trusted catalog-priced/settlement-capable candidate rows use only operator-approved trusted copy plus the conditional verdict. Every `declared`, `blocked`, stale, unknown, or mismatched artifact/guidance source disables projection and direct dispatch.

A catalog-only row must have runtime `catalog`, null `action_model_id`, null candidate/guidance/binding group, `economics_state` other than `trusted`, null rate-card identity/catalog rates/provider-share/payout/demand fields, every action unavailable with null kind/ID/timeout and a nonempty exact reason, and no candidate earning, admission, or local-readiness claim. Preserve it through the built CLI and production Malibu view only as a nontrusted Network catalog discovery row. Reject each partial group. Attempt cross-candidate borrowing from every candidate-associated row in the same snapshot and prior/newer snapshots using served-model ID, display name, artifact ID, release ID, feed digest/position, admission state/event, rate row, and demand row; the catalog-only row must remain nontrusted/null-money/no-action. An exact duplicate `model_key` rejects the whole projection before rendering rather than serving as a join. On the first matching validated owner-source snapshot, require all three fields to become non-null together and bind that exact candidate before trusted economics or any Prepare/Evaluate/Adopt/Switch action is possible.

Drive `local_default:local_only`, `local_default:not_offered`, `coordinator:not_offered`, and `local_default:offerable` through Prepare locally → evaluate → offer → adopt using only approved typed transactions; prove preparation remains available across the fresh `local_default:not_offered` ↔ `coordinator:not_offered` transition and remains reachable without economics/admission mutation. Exercise unavailable prerequisites and every matrix branch.

For preparation size formatting, test exact `estimated_bytes` values 1, 99,999,999, 100,000,000, 100,000,001, every `100,000,000 * n` boundary and boundary-plus-one selected across the range, and large values through exactly 1 TiB. Assert the displayed value is `ceil(bytes / 100000000) / 10` GB with exactly one fractional digit and never understates. Run `en_US`, a comma-decimal locale, and at least one locale using non-Latin digits, plus every shipped locale. For cleanup, assert each action `estimated_bytes` equals its target's exact logical reclaimable bytes and `{reclaimable_size}` represents that same value; exact source copy is **Remove this verified prepared model ({reclaimable_size} of managed data)? The current model and legacy model files will be kept.** No locale says or implies that APFS will recover that much physical capacity.

Run VoiceOver order/labels, keyboard, Dynamic Type, Reduce Motion, localization expansion, modal focus, background cancel, restart, child loss, worker event versus cancel-ack rendering, storage/legacy labels, and identity-specific cleanup confirmation. No path/secret/endpoint/prompt/completion leaks.

## T17 — upgrade, mixed store, rollback, and re-upgrade

Start from a production-shaped legacy root with configured incumbent/draft and extra unconfigured releases. Upgrade creates only `.macprovider-prepared-v3`; it does not alter legacy stat/hash/tree. Add mixed v3 releases, prepare/adopt where authorized, roll back to old CLI/app, then re-upgrade. At every phase legacy remains usable and untouched; v3 remains preserved/ignored during rollback and validates on re-upgrade; budgets/accounting match T09. Old R21-R27/v1/v2 planning state is never imported.

## T18 — dependency and governance gates

Fail unless:

1. `6f271245` and `c4401f17` are ancestors of implementation base.
2. One @Augustas11-owned SPEC-001/SPEC-044 commit freezes exact catalog-economics read/run/cancel spelling; exclusive complete v1/v2 capability+token pairs and every partial/dual/conflict/manifest-status negative; catalog-only all-null/nontrusted/null-money/no-action rows, cross-candidate rejection, and candidate-associated all-non-null verbatim guidance binding; coordinator no-event/event-backed `not_offered`; exact **Eligible to earn on qualifying settled requests** conditional copy and no current-income claim; event codes and total precedence; exhaustive R002/R003 eligibility including `verification_status: verified`; worker-only sequencing and cancel-process marker-only authority; 2.000-second monotonic cancel-lock deadline; six-outcome cancel-ack schema including no-mutation/null-attempt/exit-0 `busy`, echo, acquired-lock predicates/precedence, nullability, and resource bounds; bounded complete cleanup targets with immutable `event_model_key`; authenticated root locator/identity and already-open unpublished owner-only temp/empty-ACL-before-sensitive-byte/revalidation rules; exact locale-independent total ranking tuple with null order/final unique key/duplicate rejection; app-owned refresh generation and constant-space transport/backpressure; logical-byte accounting and truthful APFS copy; exact budgets/configuration precedence; and published/staging continuous final-check-through-durable-readback-validated-`tombstoned` cancel-lock/recovery semantics.
3. It keeps the existing event schema, adds no status/control frame/public crash/late-cancel state, and does not overload `cleanup_staging`.
4. SPEC-001 §6.14b is `SPEC-001-R003` with a pending CONFORMANCE entry; AUTHORITY registers the applicable SPEC-044 consumer; R005 no longer credits the contradictory hide test and instead records the explicit gap and named future visible-local-preparation proof; SPEC versions, indexes, CONFORMANCE, #1485 ownership/copy, and source digests agree.
5. `git merge-base --is-ancestor <authority-commit> <first-6B-commit>` succeeds and commits differ.
6. SHA-256 digests are computed from and archived for the committed v8 plan and test specification; fresh independent review of those exact bytes plus the landed SPEC diff has zero Critical/High/Medium and explicitly dispositions B1-AUTH-V3-H1-H3/M1-M3, B1-AUTH-H1/H2/M1-M13, and B1-AUTH-V2-H1-H4/M1-M5.
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

Run independent code, security, and architecture lanes over the complete authority-through-implementation diff. Each lane explicitly dispositions B1-V2-H1 and M1-M5, B1-V3-M1, B1-AUTH-V3-H1-H3 and M1-M3, B1-AUTH-H1/H2 and M1-M13, B1-AUTH-V2-H1-H4 and M1-M5, plus all prior v1 findings. Any Critical/High/Medium blocks; fixes require affected tests and all full-diff lanes again.
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
| Conditional earning truth and catalog-only isolation | T01, T05, T14-T16 | Exact qualifying-settlement verdict, null-money catalog rows, and cross-candidate negatives |
| Deterministic v1/v2 compatibility | T01, T14, T15 | Exclusive complete pairs, partial/dual/disagreement negatives, and built production-boundary matrix |
| Intent-first exact deletion/cancellation recovery | T03, T10, T12 | Worker-owned recovery, durable tombstoned commit, boundary logs, and power cases |
| Bounded cancellation contention | T03, T12, T14 | Exact monotonic deadline, valid `busy`, repeated waiters, and zero resource leaks |
| Crash-safe temp/root bootstrap | T01, T04, T08 | Complete injection matrix |
| Enforceable URLSession bounds only | T06, T09, T21 | Separated counters and real transfer |
| Dedicated v3 namespace/logical accounting/legacy safety | T09, T10, T17, T21 | Algorithm fixtures and upgrade/mixed/rollback hashes |
| Reachable bounded cleanup for every v3 object | T09, T10, T14, T16 | Complete target projection and orphan event correlation through production adapter |
| Worker-only events/cancel acknowledgement | T03, T06, T14 | Total ack precedence and randomized two-process schedules |
| Exact error precedence | T14 | Adjacent/three-way fault table with code/terminal/exit/side effects |
| Object-count admission and fail-closed overflow detection | T09, T10 | 255/256/idempotent/257 refusal, 257/258/large seeded overflow, and cleanup-race schedules |
| Prior root/selection/durability/resource/adoption gates | T02-T13 | Targeted and APFS evidence |
| Malibu copy/accessibility/fallback | T14-T17 | Bounded built adapter/decoder, refresh ordering, exact rate/size/locales, and UI/accessibility results |
| Locale-independent total row order | T15, T16 | Exact tuple/null/byte order, duplicate rejection, permutations, and locale invariance |
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
| B1-AUTH-V3-H1 | T03, T10, T12, T21 | Worker/recovery holds cancel lock continuously from final marker check through rename, barriers, and durable tombstoned readback; only post-crash cancellation-first/recovery-first races remain. |
| B1-AUTH-V3-H2 | T01, T14, T16, T18 | `settlement_capable` renders exact conditional qualifying-settlement eligibility in every provider surface/locale and never current-income copy. |
| B1-AUTH-V3-H3 | T01, T05, T15, T16 | Every all-null catalog-only row is nontrusted with null money/demand and no candidate action; cross-candidate evidence never authorizes it. |
| B1-AUTH-V3-M1 | T01, T08, T10, T21 | Each new sensitive object is already-open, unpublished, owner-only, and verified ACL-empty before its first sensitive byte, then revalidated. |
| B1-AUTH-V3-M2 | T03, T12, T14 | Lock acquisition stops at 2.000 monotonic seconds with valid null-attempt/no-mutation `busy`; repeated direct/app attempts release all resources. |
| B1-AUTH-V3-M3 | T15, T16 | Exact total canonical-wire tuple, null order, final unique key, duplicate rejection, permutations, and locales produce one order. |
| B1-AUTH-V2-H1 | T01, T15 | Both generations require their exclusive complete capability/token pair; every partial, dual, mixed, and manifest/status disagreement causes no call. |
| B1-AUTH-V2-H2 | T05, T16, T23 | Exact no-event coordinator `not_offered` binds by full response digest without fabrication; event-backed and transition cases remain distinct. |
| B1-AUTH-V2-H3 | T03, T10, T12, T21 | Cancel takes only cancel lock and records; recovery owns operation→cancel; durable tombstoned phase is commit evidence and every intent tombstone is reversible. |
| B1-AUTH-V2-H4 | T01, T04, T05, T08, T21 | Complete nonce/path/descriptor/version identity is authenticated and saved in every reopening lifecycle record across drift/copy/remount/reuse cases. |
| B1-AUTH-V2-M1 | T01, T15, T16 | Catalog-only rows use the exact all-null/no-action form; candidate rows and candidate actions require the all-non-null binding. |
| B1-AUTH-V2-M2 | T09, T10, T14 | Orphan cleanup retains an immutable event model key and completes success/cancel/recovery/retry through the built production adapter. |
| B1-AUTH-V2-M3 | T14, T15 | App-owned prelaunch generation rejects inverted late reads across restart/timeout while attached action workers continue. |
| B1-AUTH-V2-M4 | T14 | Partial line, stdout, stderr, decoded queue, scheduled delivery, and backpressure remain constant-space under sustained/no-newline input. |
| B1-AUTH-V2-M5 | T08, T10, T21 | Every private component has no extended ACL; inherited ACLs are stripped only on new objects and mutation races abort before side effects. |

All v1 dispositions remain mandatory and are mapped in the plan.

## Stop condition

The reservation subplan is implementation-complete only when T01-T20 pass on the full final diff and independent reviews report zero Critical, High, and Medium. Build 1 is complete only when T21-T24 pass with final signed assets, accepted signed discovery/admission journeys, correctly settled positive credit, first listed-tier evidence, stable-media qualification, and updater proof. No plan, fixture, issue checkbox, prepared artifact, or slice 6 suite replaces those gates.
