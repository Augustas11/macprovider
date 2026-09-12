# Build 1 preparation-reservation rebaseline test specification v18

Status: acceptance specification for `reservation-rebaseline-plan-v18.md`, corrected after a post-v17 storage-feasibility review reopened the gate and aligned to landed authority merge `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`. No secure-storage implementation test may be credited before T18 proves its implementation descends from that landed merge and the current v18 exact bytes pass independent review. The contract-only candidate in PR #1491 must be amended to the approved v18 representation. This revision does not claim the adversarial gate passed.

Implementation and authority baseline: landed merge `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`. Historical pre-squash authority candidate evidence: `922624a7959253aae0581c6e2db22f827925072b`; it is not the current baseline or ancestry gate. Earlier implementation baseline `c4401f1791d593d37d68eba91af94219b26d278f` and planning/review baseline `f7e584499828b3d16036382848b5caa1a897cdf9` remain historical context only. Forward-current authority versions are SPEC-001 v1.9.17 and SPEC-044 v0.2.8. Formal v9 review artifact commit retained as correction input: `fa71b09c6bdcc0478a211435849cccc8c13b4460`.

Revision inputs: v17 plan SHA-256 `8ba72d27e626f1d3044d5973420c41ecdf0d318eb97665084dbe6d17c756cb95`; v17 test-spec SHA-256 `acbf19d035f2452dd59664d0da7d703316a357bcf003ac00ded6a70b4664d96b`; post-v17 storage-feasibility finding that the temp-envelope rename contradicted the exact final `root.identity` schema; landed authority evidence from `origin/main` commit `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`. T18 records the landed authority merge and SHA-256 digests from the committed v18 bytes.

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
| `ModelPreparationPrivateCodecTests` | Strict lifecycle records, durable private-state envelopes, raw root bootstrap records, failed-dispatch history, tuple, and marker/deletion phases |
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
- v1-serving CLI advertisement requires the trio selection capability `model_catalog_economics_v1`, command token `models catalog-economics.v1`, and schema companion `model_catalog_economics.v1`; v2 requires the analogous `_v2`, `.v2`, `.v2` trio. In each checked-in manifest tier the selection capability occurs in `local_status_capabilities`, the command token and schema companion occur in `command_schemas`, and existing tier prerequisites remain present; fresh local status is a flat set containing all three selected-generation values and those prerequisites. The companion alone never selects. No supported complete trio and every member removal, reserved-value addition, category misplacement, dual, mixed, conflicting, unknown-reserved, stale, or manifest/local-status-disagreeing advertisement produces only the static current-model card with no error indicator, retry, read, run, cancel, action, or economics. Unknown fatality applies only to values starting byte-for-byte with `model_catalog_economics_v`, `models catalog-economics.v`, or `model_catalog_economics.v`; unrelated values are ignored for selection. Only a valid exclusive complete trio whose projection request then fails, times out, or returns a malformed envelope produces the exact existing `model catalog unavailable` warning, code `projection_unavailable`, and retry, with no actions/economics;
- run/cancel spellings exist only under the approved catalog-economics capability;
- progress/results use only `model_catalog_transaction_event.v1` and its seven states;
- only an attached live or failure-only worker emits events and allocates `event_sequence`; after immutable projected-action identity validation and fresh attempt creation, a run process starts one total 2.000-second monotonic dispatch-lock deadline and acquires failure→cancel before semantic freshness, availability, or serialized durable conflict/history checks; stale/unavailable/already-active under that pair is recorded there, while a passing process releases cancel→failure before exactly one nonblocking `operation.lock` attempt; acquisition failure reacquires failure→cancel within the remaining deadline and revalidates precedence before recording `operation_conflict`; acquisition success creates a pre-active normal worker that, immediately after that successful acquisition, while holding operation, records a new total 2.000-second `CLOCK_MONOTONIC_RAW` deadline to acquire failure→cancel, revalidates, and only then creates `active.json`; missing the pair deadline returns exact UTF-8 stderr line `{"error_code":"dispatch_state_busy"}` plus LF, empty stdout, no event, exit 5, and no durable/state/work mutation; all locks release before event stdout, the emitting process exits 3 without reacquisition, and the next failure writer or startup recovery compacts under its ordered lock set;
- cancellation returns exactly the approved `model_catalog_transaction_cancel_ack.v1` shape, or the operator's explicitly substituted shape, capped at 4096 bytes, with six outcomes including `busy`, and with no event sequence/terminal-success assertion;
- candidate-associated rows carry the all-non-null `candidate_id`/verbatim SPEC-046 `provider_guidance`/closed `guidance_binding` group; signed-catalog-only rows carry all three as null and require exactly `economics_state: unavailable`, `rate_source: none`, admission `local_default:not_offered`, null coordinator event/observation time, false economics/settlement booleans, every money/demand field null, and no candidate action/guidance/admission/economics claim; the exact sentinel renders only in R008 `Blocked`, never `Network catalog`, `Current`, `Ready`, or `Needs preparation` without the evidence required by those sections; every one-fault sentinel deviation, partial group, cross-candidate evidence join, and forbidden-section placement is invalid;
- coordinator guidance binding mirrors a nullable event only for an exact authoritative no-event `not_offered` response and otherwise requires the source event; `local_default:not_offered` maps exactly to **Coordinator offer state is unavailable or has not been queried.**, while `coordinator:not_offered` maps exactly to **Coordinator reports no active network offer for this model.**; missing, future, stale, cross-candidate, cross-source, cross-event/sequence, mismatched guidance, **never offered** wording, or a source-swapped meaning fails closed and Malibu renders the authoritative verdict first;
- R002/R003 contain the complete local/trusted preparation matrix, including `coordinator:not_offered`, exact `verification_status: verified`, and exact copy;
- the cancellation acknowledgement defines request echo, one total 2.000-second monotonic failure→cancel pair-acquisition deadline, six outcomes including no-state-read/no-mutation `busy`, total acquired-pair first-match precedence, exact attempt-ID nullability, exit behavior, and resource bounds; a terminal failed-dispatch present at pair-acquisition linearization always returns exact `terminal`;
- `cleanup_targets` is bounded, complete for verified managed identities, deterministic, carries a required immutable receipt-bound `event_model_key`, and retains runnable reclaimable objects with nullable current `model_key` when no catalog row remains; the public v2 action object remains the closed eight-field shape and does not contain `event_model_key`; any retained row cleanup equals only the target's nested cleanup under the RFC 8785 JSON Canonicalization Scheme (JCS), each of the two action copies independently binds the enclosing target digest and estimated bytes, and the target, receipt, and private reservation event keys match before worker events emit that key as `model_key`;
- logical byte accounting and the truthful managed-data cleanup copy are exact and distinct from APFS physical free-space recovery;
- published and staging cleanup each use durable `tombstoned` phase as sole commit evidence, restore every exact-marker precommit tombstone, and permit recovery mutation only under the applicable operation→cleanup→cancel ownership;
- root identity digest covers secret nonce plus the complete canonical validated identity schema/version/path/device/inode, and every reopening lifecycle record persists the saved locator/descriptor/version/digest;
- every private object has an empty extended ACL; a new sensitive object is already open, unpublished, and owner-only before ACL stripping/empty verification and writes no sensitive byte before that proof; descriptor revalidation remains mandatory;
- `settlement_capable` maps exactly to **Eligible to earn on qualifying settled requests** in provider-facing output and never to a current-income claim;
- `local_only` maps exactly to **Retained as local inventory only; this admission state does not claim the model is prepared, installed, ready, reachable, or usable.** and never claims installation, readiness, or usability without separate validated evidence;
- the closed admission set is exactly the 12 values `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, and `revoked`, with no thirteenth or unknown value;
- row ranking uses exactly R008 section rank ascending; `provider_completion_payout_usd_per_million_tokens` descending null-last; `demand_rank` ascending null-last; `supply_deficit_score` descending null-last; `demand_weight` descending null-last; `ready_provider_count` ascending null-last; then the tagged, unsigned-32-bit-big-endian-length-prefixed canonical identity in unsigned UTF-8 order; components 2-6 are null for every nontrusted row; duplicate canonical identity rejects, while display identity, `recommendation_rank`, and locale collation never participate;
- every forward-current owner reference selects SPEC-044 v0.2.8; v0.2.7 and older versions appear only in explicitly historical records; `SPEC-001-R003`, its pending CONFORMANCE entry, AUTHORITY consumers, SPEC/version indexes and digests, and SPEC-044-R005 evidence/gap mapping agree;
- published cleanup is separate from `cleanup_staging`;
- no status schema, `models transactions` family, public crash/late-cancel state, or new control frame exists.

Reject unknown public fields/enums, invalid source/state/economics combinations, partial candidate groups, any non-`verified` artifact status, stale/mismatched guidance, mismatched IDs/kinds/event model key, nonmonotonic worker sequences, illegal nullability, incomplete cleanup-target coverage, and oversized lines/acknowledgements.

### T01.2 private codec round trips

Round-trip minimum/maximum v3 reservation/history including closed `failed_dispatch`, active, cancellation, inventory, deletion intent/tombstoned/removed, staging-cleanup intent/tombstoned/removed, root identity, publication receipt, and private-state envelopes. The envelope schema is exactly `model_catalog_private_state_envelope.v1`; its kind inventory excludes root identity and is exactly reservations, active, cancel, published inventory, and deletion. Assert its target mapping, UUID, nonnegative safe generation, canonical payload base64, payload checksum, 360000-byte outer cap, and each inner payload cap. Assert the same byte sequence is valid both as a UUID-named temp and as its durable target, with filename UUID agreement required only for the temp. Assert a raw inner lifecycle record at a durable state leaf and any envelope at `root.identity` are rejected. A `failed_dispatch` is capped at 16384 bytes and contains exactly `schema: model_catalog_failed_dispatch.v1`, transaction ID, fresh attempt ID, transaction kind, immutable projected `event_model_key`, the complete saved root locator/identity object, `tuple_sha256`, `projection_binding_sha256`, `event_sequence: 1`, `terminal_state: failed`, one of `stale_transaction`, `action_unavailable`, or `operation_conflict`, and `live_attempt: false`; it contains no live phase/counter/path/marker claim or extra field. Assert every reopening record carries canonical path, `st_dev`, `st_ino`, identity schema/version, and digest; cleanup records carry immutable `event_model_key`. Reject duplicate/unknown keys, wrong schema/kind/target/generation/root/tuple/projection, malformed UUID, invalid UTF-8, floats, negative/overflow integers, trailing bytes, noncanonical base64, checksum mismatch, and one-byte-over caps. Reject any failed-dispatch field or serialized diagnostic containing a provider identity, credential, feed body, URL, prompt, completion, raw error, path beyond the bounded private root locator, or other unbounded/private payload.

### T01.3 unique temporary recovery

For `reservations.json` including failed-dispatch append/compaction, `active.json`, `cancel.json`, `published-inventory.json`, and `deletion.json`, inject crash after unique temp create, every partial write boundary, completed write, `fsync`, `F_FULLFSYNC`, readback, byte-identical envelope rename, parent `fsync`, parent `F_FULLFSYNC`, and final reopen/readback. Assert:

- incomplete recognized temps are descriptor-validated and removed;
- complete newer envelopes finish the exact byte-identical rename/barriers and remain valid durable envelopes whose inner payload decodes under its target contract;
- valid equal/newer durable envelopes win, while a raw payload, wrong-kind envelope, or checksum-valid semantic mismatch at a durable leaf fails closed;
- at most 16 total/four-per-kind recognized temps are processed;
- entries beyond the processing caps are neither decoded nor promoted; deterministic excess cleanup derives only kind/UUID from an exact recognized filename and revalidates the descriptor before unlink;
- hostile names/types/owners/modes/links/checksums and checksum-valid binding disagreements fail closed;
- ordinary interrupted temps never permanently wedge the projection or next transaction.

### T01.4 root.identity bootstrap

Inject the same boundary crashes in `bootstrap-tmp` using the exact raw filename `root.identity.<lowercase-canonical-UUIDv4>.tmp`. Assert the temp and final contain only the byte-identical exact closed five-field `model_catalog_root_identity.v1` record and never a state envelope; no partial bytes ever appear as final `root.identity`; exactly one complete valid temp can finish exclusive rename; one incomplete recognized temp is removed and regenerated; more than one distinct complete identity temp fails closed; crash after rename repeats parent `fsync` and `F_FULLFSYNC`; valid final identity removes recognized stale temps; malformed/conflicting/descriptor-mismatched final identity fails closed. Derive the digest from a fixed canonical-encoding vector and show one-bit changes to nonce, identity version/schema, path, device, or inode change it. Repeat concurrent first projection across processes under the operation lock.

## T02 — deterministic bounded selection and fail-closed contention

Retain v2 tests at 0/1/3/64/65/128/256 and failure at 257. Permute feed order, restart processes, mutate/remove/re-add boundary rows, and run enough admitted generations to prove the eight-slot finite rotation rule. Retained unchanged tuples preserve IDs; evicted/re-entered tuples follow deterministic metadata. This proves deterministic selection for bounded admitted snapshots, not scheduler fairness under infinite arrivals. Race dispatch and projection rewrite 1,000 times under the exact projection-writer operation→failure→cancel trace: dispatch-win pins one durable active tuple; rewrite-win creates exactly one bounded terminal `failed_dispatch` record and sequence-1 failure event, with no `active.json`, live attempt, network, staging, download, publication, cleanup, adoption, or model mutation.

Race 1,000 conflicting invocations while an incumbent holds `operation.lock`, using an injected monotonic clock and deterministic lock scheduler. Every challenger validates its immutable projected identity, creates a prospective fresh attempt, starts one total 2.000-second deadline, acquires failure→cancel for its initial semantic/conflict view, then releases cancel→failure before exactly one nonblocking attempt to acquire operation. Each failed operation attempt tries to reacquire failure→cancel using only the remaining original deadline. A challenger that acquires both revalidates stale/unavailable precedence, records the winning bounded terminal within the shared 256-record/262144-byte history limits, releases cancel→failure before emitting exactly one sequence-1 terminal and exits 3 without reacquiring a lock; the next failure writer or startup recovery performs idempotent compaction under its ordered lock set. A challenger that misses either required pair deadline releases every resource and produces only the exact pre-attachment UTF-8 stderr line `{"error_code":"dispatch_state_busy"}` plus LF, empty stdout, no event, exit 5, and no state/work mutation. Hold action freshness and availability fixed for exact `operation_conflict`; separately mutate them during reacquisition for higher-precedence stale/unavailable. Force deterministic compaction and prove at most one pending record, both history caps, incumbent continuity, deadline-bounded completion, and return of locks/waiters/descriptors/threads/processes/buffers to baseline. Failure-only paths never acquire operation/cleanup/adoption/runtime/socket locks; no path takes operation while holding failure or cancel. Under continuous arrivals the acceptance claim is bounded fail-closed liveness: each invocation completes with a semantic result or typed contention result within its applicable bound, without asserting starvation freedom.

Repeat selection for every preparation classification from T16. Economics state must not perturb tuple/action ID when the operator contract says the same local artifact action remains eligible; a classification or signed target change must do so exactly as specified.

## T03 — operation, cancel, and event ownership

Fork independent worker, projection, cancel, and retry processes. Assert one live `operation.lock`, one attempt, one worker stdout stream, and one monotonic event sequence. No cancel invocation writes an event or event-sequence field.

Exercise both relative process linearizations—direct-cancel-first and competing-worker-first—at every boundary: failure-lock wait start; failure acquired/cancel pending; elapsed time immediately below and exactly at 2.000 seconds; timely complete failure→cancel acquisition; active/pending/history/terminal read; exact marker create/temp sync/rename/parent sync; acknowledgement write; worker marker read; `cancel_requested` event; cleanup; terminal state sync; worker operation→failure→cancel acquisition; marker removal; reverse release; terminal compaction; and new-attempt creation. Use an injected `CLOCK_MONOTONIC_RAW` source for deadline boundary tests and account both locks, all retries, and spurious wakeups against one total deadline.

Required outcomes:

- every syntactically valid acknowledgement byte-for-byte echoes the requested `transaction_id`; malformed input emits no valid acknowledgement;
- the direct cancel process opens failure then cancel under the exact common deadline, performs bounded read-only active/pending/history/terminal validation, may read/reuse the single requested transaction marker, remove only its validated prior-attempt value, and create/readback-validate only its current exact value, and never takes `operation.lock`/cleanup/adoption/socket/runtime locks, restores/renames/deletes a target, compacts/evicts history, advances a cleanup phase, or runs temp/root recovery;
- acquisition requires the complete failure→cancel pair while elapsed remains below 2.000 seconds; failure to obtain either by the common deadline releases everything and emits exactly one valid `busy` acknowledgement with null attempt ID, empty stderr, exit 0, and zero reads or mutations of marker, active/history, terminal, cleanup phase, temp, artifact, or operation state;
- after timely pair acquisition, table-drive the total first-match order at that linearization point: matching durable terminal in active, pending, or history → `terminal`; matching nonterminal active plus exact durable marker → `already_recorded`; matching nonterminal active without exact marker → durable exact-marker write then `recorded`; recognized non-current/stale transaction state → `stale`; no matching bounded state → `not_active`;
- `recorded`, `already_recorded`, and `terminal` always carry the exact non-null attempt ID; `not_active` and `busy` always carry null; `stale` carries the stale attempt ID exactly when safely known and otherwise null; all six valid outcomes exit 0, while malformed input/state emits no valid acknowledgement and uses the exact nonzero authority exit;
- construct overlapping terminal/active/marker/history fixtures for every adjacent precedence pair and assert the first outcome wins without extra writes;
- cancel before a transaction-specific commit point returns `recorded`/`already_recorded`; worker emits exactly one `cancel_requested` and one terminal `cancelled` only after reversible cleanup;
- cancel after preparation publication or either durable cleanup `tombstoned` phase commit may acknowledge `recorded`, but worker emits only terminal `succeeded`/`failed` and clears the marker;
- cancel that obtains the failure→cancel pair after worker terminal release returns `terminal` when the bounded terminal record matches, otherwise `stale` or `not_active` by the total table, and writes no marker;
- a matching terminal `failed_dispatch` is never cancellable: the UI exposes no cancel action and a direct cancel invocation must return only `terminal` with the exact attempt ID when that record exists at pair-acquisition linearization, never create a marker or change/compact/evict history;
- inject the cancel read between every pending temp/write/file barrier/rename/parent barrier/readback, pending-to-history replacement, terminal-history barrier, and deterministic eviction/delete step; because every writer and cancel reader holds failure→cancel, it observes one complete before-or-after generation and an existing terminal never becomes `stale`, `not_active`, or malformed;
- a marker written before terminal sweep is removed by the worker under operation→failure→cancel;
- no exact-marker write can occur after the sweep but before reverse release because worker and cancel use the same failure→cancel suffix;
- new attempt removes only a validated prior-attempt marker under operation→failure→cancel;
- stale/mismatched marker returns `stale`, never affects another attempt, and is cleaned only by the appropriate operation-owning normal/recovery path without deleting unrelated files;
- sequences have no duplicate/gap caused by cancellation and exactly one terminal event.

Hold `failure.lock`, then separately hold `cancel.lock` after allowing failure acquisition, across injected slow and stuck state/object/phase syncs. Prove one direct-cancel waiter returns `busy` at the exact shared deadline without any state read or mutation, then prove a later fresh invocation observes the worker/recovery result after release. Launch 100 direct cancel invocations against each held-lock case and assert every process exits by its own bound with one valid `busy`, no waiter/descriptor/thread/child/temp leak, and no marker/phase change. Through Malibu, issue 1,000 repeated cancel gestures for one transaction and assert at most one cancellation subprocess is live, repeats coalesce, a `busy` result permits only a fresh bounded retry, and process/resource counts return to baseline. Run 10,000 randomized schedules and restart between schedules. These bounded schedules prove deadline/resource behavior and deterministic outcomes; they do not claim scheduler fairness under continuous arrivals.

## T04 — custom roots and bootstrap crash recovery

Run projection → dispatch → transfer → publish → recovery → adoption with default, environment, and config roots. Bind canonical path, `st_dev`, `st_ino`, identity schema/version, and root-identity digest in every reopening lifecycle record/receipt. Recompute the digest over the exact validated canonical identity record including a secret 256-bit nonce and descriptor identity. Repeat with authority and artifact roots on separate APFS volumes.

Crash during root bootstrap and every private write using T01 injection. Change config/environment from root A to B afterward. Recovery must use only saved A, reconcile its recognized temp, staging, unpublished, marker, or deletion record, and leave B untouched. Test copied nonce/identity records with rewritten path/device/inode/version, symlink/path replacement, move/remount/device change, inode-reuse simulation, wrong device/inode, and restored original root. Each mismatch fails before mutation; restoring the exact original descriptor and record converges. Serving configured for B rejects A; serving configured for A independently verifies the v3 receipt/hash.

## T05 — stale IDs, tuple/feed/root drift

After projection, vary model/revision/artifact/release/signer/feed digest/estimate, `candidate_id`, all five verbatim `provider_guidance` fields, and every `guidance_binding` field: source schema, exact source-byte SHA-256, generated time, projection sequence, coordinator event, candidate, admission source, and admission state. Test local-default sequence/non-event binding; coordinator `not_offered` with null event and exact whole-response digest; event-backed coordinator `not_offered`; all other coordinator states with required non-null event; and forbidden null/non-null substitutions. For an all-null catalog-only row, attempt to attach admission/rate/demand evidence from candidate A through matching prior/newer-snapshot `model_key`, current `served_model_id`, display name, artifact ID, release ID, or feed position while the displayed row corresponds to candidate B or to no candidate. Every cross-candidate or inferred join remains at the exact catalog-only sentinel and exposes no candidate action. Duplicate canonical row identity rejects the projection before any join or rendering; duplicate `model_key` alone remains valid for distinct candidate identities, and equal raw candidate/model-key text remains distinct across the `candidate` and `catalog` tags. Test age at -1 second (future), 0, the exact `min(300, owner_source_max_age)` boundary, and one second beyond it. Also vary provider/config identity, root canonical path/device/inode/version/digest, matrix classification, and action copy version. Exercise artifact `verification_status` at `declared`, `verified`, `blocked`, missing, and unknown before projection, at dispatch, and after feed refresh. Only exact current `verified` may project or dispatch Prepare. Every stale or mismatched case fails before network/write unless the authority contract expressly preserves the tuple. Feed/guidance drift before publication blocks; drift after durable publication leaves inert bytes but cannot grant current readiness/adoption. Root changes never redirect cleanup.

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

Retain every v2 barrier: file sync/full-sync, receipt, bottom-up directories, publish-ready state, validation, exclusive rename, destination-parent sync/full-sync, active terminal sync, authority-parent sync, event emission. For the final non-cleanup marker check and publication commit, the live worker retains operation→failure→cancel without interruption across the exclusive rename, destination-parent durability barriers, terminal persistence, and readback validation, then releases cancel→failure while retaining operation as needed. The periodic operation→cancel marker poll remains read-only and cannot authorize or cross publication. Inject syscall failure and SIGKILL before/after each barrier and each lock boundary on same/separate APFS volumes. Success event remains after all durable barriers; recovery re-verifies receipt/tree; mismatched destination is preserved.

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

For 0, 1, 255, and 256 valid managed identities, assert `cleanup_targets` contains every identity exactly once in digest order and each closed entry has exactly `artifact_identity_digest`, `display_model_id`, `model_revision`, `artifact_id`, `release_id`, required immutable `event_model_key`, nullable current `model_key`, `root_identity_digest`, `receipt_sha256`, `estimated_bytes`, `keep_set_status`, nullable `protected_reason`, and `cleanup`, with all digest, nullability, byte-equality, and action-binding rules enforced. Assert each `cleanup` action and any row-attached `cleanup_published` action has exactly the public v2 closed eight-field action shape and never contains `event_model_key`. Remove selected identities from the current signed catalog and assert reclaimable entries remain reachable and actionable with current `model_key: null` while the receipt-bound `event_model_key` remains unchanged. Protected entries remain present but unavailable. When row-attached cleanup is present, compare RFC 8785 JCS UTF-8 bytes and require `row.cleanup_published` to be byte-identical to `cleanup_targets[i].cleanup`; separately require **each** copy's `artifact_identity_digest` and `estimated_bytes` to equal the unchanged enclosing target fields. The positive fixture passes.

Build distinct one-fault fixtures with the enclosing target fixed unless that enclosing field is the named mutation. Independently mutate (1) the enclosing target digest, (2) the enclosing target size, (3) only `row.cleanup_published` digest, (4) only `cleanup_targets[i].cleanup` digest, (5) only the row-side size, (6) only the target-side size, and then (7) each action copy separately for transaction kind, transaction ID, availability, every nullable field's null/non-null form, reason, timeout, and every remaining closed action field. For each field, hold the other action copy and enclosing target byte-for-byte fixed so either JCS inequality or that copy's own field invariant is the rejection reason. Next mutate the digest in both action copies identically, and separately mutate the size in both copies identically, while leaving the enclosing target unchanged; JCS equality must still hold and rejection must come only from independent enclosing-target binding. Also mutate both copies identically for each remaining field whose internal invariant permits a same-value invalid fixture, mutate canonical bytes without semantic equivalence, and attach an otherwise-valid equal action pair to another target. Because `event_model_key` is not an action field, do not create per-action event-key mutation fixtures; instead independently mutate the enclosing target `event_model_key`, mutate the verified receipt's historical event key to mismatch the target, mutate the private projected cleanup reservation's event key to mismatch the target, and run the orphan dispatch/event-correlation case that proves the matching reservation key is emitted as event `model_key`. Retain the enclosing digest/size, cross-target, action-to-action JCS, receipt-to-target, target-to-private-reservation, and orphan event-correlation sentinels.

Every fixture rejects the whole projection before confirmation, reservation creation, rename, deletion, or any other dispatch side effect, with outside-root, protected-current, configured-legacy, and legacy-tree sentinels byte-for-byte unchanged. Comparing either action copy to the enclosing target object as a whole is never the oracle: the decoder must first prove the two action copies' RFC 8785 JCS equality and independently prove each copy's digest and size binding to the enclosing target. Malformed/overfull inventory yields no partial list or action, and enumeration remains capped at 257 observations.

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

Recovery uses only recorded tuple/root/final/tombstone identity and saved root locator/descriptor/version/digest; no scan/guess. Change config/env to another root after each crash and prove original-only recovery. Instrument ownership: only worker/recovery worker holding `operation.lock`, then the cleanup lock, then `cancel.lock` may mutate cleanup recovery state, and it retains all three while mutating; direct cancellation holds failure→cancel and may validate or replace only the exact marker record.

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

## T12 — exhaustive lock graph, exclusion, and bounded liveness

Instrument every acquisition, successful custody instant, mutation interval, release, deadline, and resource teardown with a deterministic lock-trace oracle. Assert these exact complete path traces and no others:

| Path | Required trace and retention |
|---|---|
| projection writer | operation→failure→cancel; hold all from final immutable snapshot revalidation through projected-transaction reservation publication, parent full-sync, and readback; release cancel→failure→operation; speculative construction cannot publish/remove a reservation and immutable in-memory rendering uses no lock or mutation |
| initial valid run | one deadline; failure→cancel; read semantic/cancel-visible conflict view; on semantic failure mutate under both and release cancel→failure; on pass release cancel→failure before the sole nonblocking operation attempt |
| operation-conflict reporter | after failed operation attempt, reacquire failure→cancel within the remaining original deadline; revalidate and mutate under both; release cancel→failure before stdout |
| pre-active normal creation | immediately after successful nonblocking operation acquisition, retain operation, record a new total 2.000-second `CLOCK_MONOTONIC_RAW` deadline, and acquire failure→cancel; revalidate/create under all three; release cancel→failure and retain operation only for live work |
| live non-cleanup commit boundary | retain operation; acquire failure→cancel for the final exact-marker check; retain all three through the applicable publication commit and durability/readback barriers; release cancel→failure and retain operation only as needed; periodic operation→cancel polling cannot authorize or cross commit |
| next failure-only writer compaction | during its initial bounded failure→cancel custody, compact/evict/readback any earlier complete pending record before its own publication; the earlier event emitter never reacquires |
| normal terminal/history compactor and non-cleanup recovery | operation→failure→cancel; publish/readback replacement before eviction; release cancel→failure, then operation when the ordered phase is complete |
| direct cancel | one total 2.000-second deadline; failure→cancel; if incomplete pair at deadline release all and perform zero state read/mutation; with pair read bounded cancel-visible state and access only the exact marker; release cancel→failure |
| live nonterminal marker poll | retain operation; acquire/release cancel around exact active marker read; do not touch failed/terminal history |
| cleanup worker/recovery mutation | operation→cleanup→cancel; hold all through required mutation and continuous final-check-through-durable-`tombstoned`; release cancel, then cleanup after durable cleanup state; never hold failure with cleanup |
| cleanup terminal/history phase | retain operation after releasing cleanup; acquire failure→cancel; compact/readback/sweep exact marker; release cancel→failure→operation |
| adoption | operation→adoption→socket→runtime; release reverse; no failure or cleanup; any later history phase first releases adoption/socket/runtime and then uses operation→failure→cancel |

Race every path pair and assert deterministic trace order, no forbidden overlap, no reverse edge, and the exact before-or-after durable view. Required pairwise cases include direct cancel versus failed-dispatch writer and compactor; normal terminal compactor versus failed-dispatch compactor; projection writer versus direct cancel, failed writer, normal terminal, and pre-active creation; startup recovery versus direct cancel and both compactors; cleanup mutation versus cancel, projection, recovery, and cleanup terminal compaction; live marker polls versus terminal sweep; and adoption versus projection, preparation, cleanup, and terminal compaction. Inject cancellation reads between every failed pending/history create, replacement, barrier, eviction, and delete boundary. A terminal failed-dispatch existing at the direct-cancel pair-acquisition linearization point always yields `terminal` with the exact attempt and never marker/stale/not-active/malformed.

For failure-only dispatch and direct cancel, hold first failure and then cancel independently, inject spurious wakeups, and advance the injected `CLOCK_MONOTONIC_RAW` clock immediately below and exactly at 2.000 seconds. For a normal process, permit the nonblocking operation acquisition, assert that it immediately records a new total 2.000-second `CLOCK_MONOTONIC_RAW` deadline while holding operation, then independently hold failure and cancel and exercise the same below/exact boundaries under that new deadline. At timeout every path releases all acquired locks, waiters, descriptors, threads, buffers, and child/process resources; failure-only/normal pre-attachment timeout yields exact UTF-8 stderr line `{"error_code":"dispatch_state_busy"}` plus LF/empty stdout/no event/exit 5/no mutation, while direct cancel yields exact no-read/no-mutation `busy`/exit 0. Exercise operation-lock busy/free, newly stale/unavailable precedence, unlocked no-handoff crash, stdout blockage, slow sync, worker crash, recovery, cleanup precommit restoration, phase-write failure, and new-attempt creation. Under sustained arrivals prove each invocation's bounded semantic-or-typed-failure completion and fixed resource ceiling. Do not use finite completion counts to claim starvation freedom.

## T13 — existing adoption handler readiness

Retain the existing `prepareModelAdoptionRequest`/result frames. Test already-loaded authority and absent-target reload. The server independently reloads signed feeds, resolves/validates its configured root, derives the v3 destination, validates root-bound receipt/hash, then compares requester claims. Reject legacy lookalike, alternate root, stale feed, malformed tree, tombstone, identity/hash/config/incumbent drift. Restart/race tests allow one authority snapshot and preserve the incumbent.

## T14 — CLI, worker events, and cancel acknowledgement

Test exact operator-approved catalog-economics read/run/cancel grammar, flags, option order, missing/extra args, TTY behavior, exit codes, stdout/stderr, and exclusive complete categorized selection-capability/command-token/schema-companion trios. No alias or `models transactions` family is accepted.

Separate the pre-attachment boundary from semantic dispatch. Invalid syntax/framing and every one-field-invalid immutable action identity—transaction kind/ID, complete root locator/identity, tuple, projection schema/process-launch/sequence/digest, and for cleanup the target/receipt/private-reservation `event_model_key` binding—produce no valid event, no attempt, no history mutation, and the exact authority error/exit. Public action fixtures must prove that adding `event_model_key` to the closed eight-field action object is rejected as an unknown field rather than accepted as authority. For each valid immutable identity, inject stale transaction, unavailable action, operation conflict, and lock contention independently and in precedence combinations. Assert that the process generates a prospective fresh attempt, starts one total 2.000-second monotonic deadline, and acquires failure→cancel before semantic/cancel-visible checks. Stale/unavailable/already-active results are durably recorded while both are held. A passing initial check releases cancel→failure before exactly one nonblocking operation attempt; operation failure reacquires failure→cancel within the remaining original deadline, revalidates precedence, and records the winner. Immediately after operation success, the process retains operation, records a new total 2.000-second `CLOCK_MONOTONIC_RAW` deadline, and acquires failure→cancel for pre-active revalidation/creation. Missing either pair deadline on failure-only or normal paths releases every resource and produces exactly one UTF-8 stderr line `{"error_code":"dispatch_state_busy"}` plus LF, empty stdout, no event, exit 5, and no durable/state/model/network side effect; Malibu renders an actionable retry without inventing terminal state. A semantic rejection persists/readback-validates one closed pending `failed_dispatch` within the shared caps, releases every lock before exactly one matching sequence-1 `failed`, and exits 3 without reacquiring; the next failure writer or startup recovery compacts under its ordered lock set. Persistence failure emits no event and exits 5. Assert no second `active.json`, live attempt, marker, network, staging, download, publication, cleanup, adoption, socket, runtime reservation, or model/config/incumbent mutation. The incumbent remains unchanged under operation; the reporter's nonblocking attempt never waits for or acquires it.

For an eligible nonconflicting action, assert the process passes the first semantic/conflict-view check under failure→cancel, releases cancel→failure, and makes exactly one nonblocking operation attempt. Immediately on success it becomes pre-active, retains operation, records a new total 2.000-second `CLOCK_MONOTONIC_RAW` deadline, and acquires failure→cancel, then repeats semantic and conflict-visible checks. It creates the sole `active.json` only if those checks still pass; a newly stale or unavailable action instead writes the exact failed-dispatch record under operation→failure→cancel and releases every lock before stdout. Race two valid invocations at every check/release/nonblocking-attempt/revalidation/deadline boundary: at most one creates live state; a loser either completes the exact `operation_conflict` lifecycle under failure→cancel or returns pre-attachment `dispatch_state_busy` with no event/state. Inject a crash in the unlocked interval and prove there is no durable handoff claim or live attempt to recover; later invocations retain the same bounded fail-closed behavior.

For each candidate-associated non-cleanup action kind Prepare, Evaluate, Adopt, and Switch, generate positive fixtures whose private projected-transaction reservation derives immutable `event_model_key` from the projected row's non-null `model_key`, not from any cleanup target. For each kind, cover success, direct cancel before terminal, stale transaction, `action_unavailable`, `operation_conflict`, and persistence-backed `failed_dispatch`; assert the same key is present in the reservation, active record when created, history/terminal record, and every worker event `model_key`. Mutate the row `model_key` after projection and prove stale/event-binding rejection before live side effects; mutate only unrelated display/catalog fields and prove they do not change the bound key. Repeat the same state-lifecycle matrix for cleanup using the enclosing cleanup target plus verified receipt as the key source, including orphan current `model_key: null`, and assert cleanup rejects any row-model-key derivation.

Inject failure-worker crashes before each lock custody point; before temp creation; at every partial/complete pending-record temp write and sync; before/after rename, both parent barriers, pending readback, and reverse release; immediately before stdout and at every terminal-line byte; after the complete event; and at every later-writer/startup-recovery compaction acquisition/temp/write/sync/rename/parent-barrier/readback/release boundary. Pending creation, compaction, and eviction occur under failure→cancel or operation→failure→cancel. Every lock is released before stdout. After the event, the emitting process exits 3 without reacquiring; the next failure writer compacts the complete pending record during its own bounded failure→cancel custody, or startup recovery uses operation→failure→cancel. Block stdout and disconnect the app at every byte boundary to prove no lock is held and incumbent serving continues. Startup recovery handles recognized failed-dispatch state under operation→failure→cancel, finishes/compacts complete history and removes incomplete temps without replay, then releases cancel→failure. Before durable publication a retry uses a fresh attempt; after pending readback the immutable record remains terminal across every crash. Test history at 255/256 and near 262144 bytes, deterministic replacement-before-eviction and oldest-terminal removal, one pending maximum, 1,000 reporters, incumbent progress, per-invocation deadline completion, bounded resources, no deadlock/reverse edge, and no second work attempt. The UI never offers cancellation for `failed_dispatch`; direct cancel under failure→cancel returns exact `terminal` at its acquisition linearization without marker mutation.

Worker events alone must match IDs/kinds/model, monotonic sequence, timestamps, progress/heartbeat, approved codes, and one terminal. Direct cancel stdout contains exactly one bounded acknowledgement, never an event line. Test all six T03 outcomes, the common 2.000-second failure→cancel acquisition boundary, pair-acquisition linearization and total precedence, exact echo/nullability/exit/stderr behavior, and zero reads on incomplete-pair `busy`. Separately test the exact pre-attachment UTF-8 stderr bytes `{"error_code":"dispatch_state_busy"}` plus LF, empty stdout, exit 5, no event or state, resource cleanup, and Malibu actionable-retry mapping with no terminal invention. `recorded` is not terminal cancellation; cancel `busy` says only the bounded request could not acquire authority. Malibu continues attached worker streams and refreshes projection. Late cancellation yields only the transaction-kind-authorized worker terminal. No status response schema exists.

Table-drive simultaneous faults across every adjacent class in the authority precedence. At minimum use these concrete higher-priority representatives and assert exact code, terminal, exit, and side-effect frontier:

| Concurrent faults | Winning code | Terminal / exit | Required side-effect boundary |
|---|---|---|---|
| stale action + operation conflict | `stale_transaction` | `failed` / 3 | one terminal `failed_dispatch`; no live state, network, or staging |
| action unavailable + operation conflict | `action_unavailable` | `failed` / 3 | one terminal `failed_dispatch`; no live state, marker, or work side effect |
| operation conflict + authority unavailable | `operation_conflict` | `failed` / 3 | one terminal `failed_dispatch`; no second live worker or network |
| authority unavailable + unsafe filesystem | `authority_unavailable` | `failed` / 4 | no target-root write |
| unsafe filesystem + managed budget exceeded | `unsafe_filesystem_object` | `failed` / 4 | no traversal outside validated descriptors |
| managed budget exceeded + transfer failure | `managed_budget_exceeded` | `failed` / 4 | no network or staging |
| transfer failure + verification failure | `transfer_failed` | `failed` / 4 | no verification promotion/publication |
| verification failure + publication failure | `verification_failed` | `failed` / 5 | unpublished bytes only |
| publication/cleanup failure + cancel failure | `publication_failed` or `cleanup_failed`, according to transaction kind | `failed` / 5 | preserve exact recovery record |
| cancel failure + timeout | `cancel_failed` | `failed` / 5 | preserve exact marker/recovery state |
| timeout + internal failure | `timed_out` | `timed_out` / 124 | no success/publication after timeout |

Also cover every code within each class, three-way overlaps, fault-order permutations, and 1,000 randomized schedules. Every immutable-identity-valid stale/unavailable/conflict result uses the constructive failure-only lifecycle; no fixture accepts either a missing terminal on an uninterrupted invocation or an event unbound to its durable record.

### T14.1 built CLI through production Malibu adapter

Build `malibu-cli`, launch that exact binary from Malibu's shipping process adapter, and feed its real stdout chunks, stderr bytes, process-exit status, and cancellation subprocess output through the production decoder/state reducer. Do not substitute `FakeModelCLI` or hand-authored JSON for this gate. Cover v2 read, each live run terminal, all three sequence-1 `failed_dispatch` terminals with exit 3, the exact pre-attachment UTF-8 stderr line `{"error_code":"dispatch_state_busy"}` plus LF under initial/reacquisition/pre-active pair contention with empty stdout/no event/exit 5/actionable retry/no terminal invention, their crash/partial-line frontiers, all six cancellation acknowledgements including incomplete-pair deadline `busy`, orphan cleanup from T10.6, empty and nonempty stderr, JSONL split at every byte boundary, multiple lines per chunk, final line with/without the authority-approved newline behavior, process exit before/after final bytes, oversize lines, malformed/unknown v2 negatives, and v1 fallback. Compare decoded IDs, nullability, immutable event binding, conditional earning copy/guidance, error selection, UI terminal state, and projection refresh with the built CLI's source bytes. Repeated UI cancellation must never launch more than one live child for one transaction, and the UI never offers cancel for terminal failed-dispatch history.

Feed a no-newline byte stream and assert rejection at byte 16385 rather than after EOF/newline. Sustain maximum-size valid lines at faster-than-MainActor consumption for the full action timeout, plus infinite-source harness runs stopped after a fixed observation window. Measure retained partial bytes, decoded events, scheduled MainActor work, stdout retention, and stderr retention: each remains within its declared fixed byte/item cap independent of line count and elapsed duration; stdout is continuously drained and never accumulated whole. Fill the delivery queue and stderr cap, verify deterministic backpressure/coalescing/failure and truncation metadata, preserve accepted event order and terminal semantics, and prove process pipes do not deadlock when UI delivery is stalled.

At this same production boundary, load the literal checked-in current manifest
and launch the current built v1 CLI to prove its three economics values select
v1. Then exercise the new manifest loader with the current built v1 CLI, the
current manifest loader with a v2-only status fixture, and the new categorized
v2 tier with the new built v2 CLI. Reuse T15's byte-level one-fault corpus for
every member removal, reserved addition, manifest category misplacement, and
cross-surface disagreement; assert the production adapter launches zero
catalog-economics processes for each negative. Reuse T15's unrelated-value
corpus and assert every positive still launches exactly one read. A hand-built
Set that bypasses manifest JSON decoding or local-status parsing does not count
for this compatibility proof.

Allocate app refresh generation A before launching read A and B before launching read B. Test completion A→B and B→A, accepting only the latest-launched generation once B exists; launch B during A decode; dispatch an action from the last accepted projection between replies; restart the CLI so `process_launch_id` and `projection_sequence` reset; timeout A before its late reply; and restart Malibu to create a new app epoch. A late/superseded read never replaces B, while the independently attached action worker continues draining events and reaches its correct terminal state.

## T15 — old-client fallback

Define the byte-exact v1 trio as selection capability
`model_catalog_economics_v1`, command token
`models catalog-economics.v1`, and schema companion
`model_catalog_economics.v1`. Define the v2 trio analogously as
`model_catalog_economics_v2`, `models catalog-economics.v2`, and
`model_catalog_economics.v2`. For each manifest compatibility tier, require
the selection capability in `local_status_capabilities`, the command token and
schema companion in `command_schemas`, existing prerequisites
`model_status_v1`, `model_catalog_json_v1`, `service_instance_v1`, and
`status_observation_v1` in `local_status_capabilities`, and `status_request`
plus `status_response` in `control_frame_schemas`. A new Malibu manifest may
contain separate valid v1 and v2 tier entries. Each tier contains only its own
generation's reserved values; their separate presence is not a dual
advertisement. Fresh CLI local status is one flat set and must contain exactly
one generation's full trio plus the prerequisites. The selection capability
chooses the candidate generation; its command token and schema companion are
both mandatory validators, and neither companion nor command token selects
alone.

Run the full production-boundary compatibility matrix, using the checked-in
manifest bytes and built CLI status output for the current-v1 case and the
production manifest/status loaders for every case:

| Malibu | CLI advertisement | Expected call/result |
|---|---|---|
| Current v1-only Malibu | Current checked-in categorized v1 manifest tier plus current built CLI flat v1 status containing the complete three-value v1 trio | one read; accept v1 only; no v2 mutations |
| New v2-capable Malibu | Old/current built v1 CLI flat status; new manifest retains the exact categorized v1 tier beside a separate v2 tier | one v1 read; v1 UI; no v2 mutations |
| Current/old v1-only Malibu | New v2-only built CLI flat status and no v1 reserved value | no supported generation; no read/run/cancel; static current-model card only, with no error indicator, retry, action, or economics |
| New v2-capable Malibu | New categorized v2 manifest tier plus new built CLI flat v2 status containing the complete three-value v2 trio | one read; accept v2 only; validated v2 actions enabled |
| Either | Otherwise valid supported trio plus any number of values outside the three reserved prefixes | unchanged valid v1/v2 result; unrelated capability/schema/control values do not affect generation selection |
| Either | Both complete generations in flat status or one manifest tier, or one complete trio plus any reserved member of the other generation | no read/run/cancel; static current-model card only, with no error indicator, retry, action, or economics |
| Either | Any trio member alone or any two-member subset, including companion-only and command-plus-companion without selection capability | no read/run/cancel; static current-model card only, with no error indicator, retry, action, or economics |
| Either | Required manifest value moved to the wrong category, required status member removed, unknown reserved-prefix value added, mixed generation, or manifest/status generation disagreement | no read/run/cancel; static current-model card only, with no error indicator, retry, action, or economics |
| Either | Stale local status or neither supported complete trio | no read/run/cancel; static current-model card only, with no error indicator, retry, action, or economics |
| Either | One supported exclusive complete trio selected from the categorized manifest and fresh flat status, followed by request failure or timeout | exactly one negotiated read; static card plus exact `model catalog unavailable` warning, `projection_unavailable` code, and retry; no action/economics/run/cancel |
| Either | One supported exclusive complete trio selected, followed by malformed or unsupported projection envelope | exactly one negotiated read; reject whole envelope; same exact warning/code/retry; no action/economics/run/cancel and no alternate-version retry |

Run byte-level one-fault fixtures rather than combining negative classes. For
each generation, remove each of the three required members independently from
the manifest tier and flat status; add each foreign-generation member; add
unknown reserved values under each exact prefix; move the selection capability
to `command_schemas`; move the command token or schema companion to
`local_status_capabilities`; swap v1/v2 members one at a time; and introduce
each cross-surface disagreement. Mutate case, punctuation, version suffix,
ASCII byte, and a confusable Unicode byte for every reserved member. Exercise
all one- and two-member subsets, companion-only non-selection, both complete
generations in flat status, both generations within one tier, and fresh versus
stale status. For every negative assert byte-for-byte static-card
presentation, no error indicator, no retry affordance, zero read/run/cancel
subprocesses, and no action/economics exposure.

Add one unrelated capability, command-schema, and control-frame value at a time
and together to each positive v1/v2 fixture. Include unrelated values before,
between, and after reserved values in source JSON. Because their bytes do not
start with `model_catalog_economics_v`, `models catalog-economics.v`, or
`model_catalog_economics.v`, selection and the expected call/result remain
unchanged. A prefix match is byte-for-byte and case-sensitive; an unknown value
under a reserved prefix always fails closed rather than being ignored.

Separately negotiate each supported trio and inject process-launch failure,
nonzero exit, timeout, truncated JSON, invalid UTF-8, wrong schema, unknown
required enum, oversized response, and every other malformed-envelope class;
each must show exactly the existing `model catalog unavailable` warning with
`projection_unavailable` and one retry affordance, while exposing no
action/economics/run/cancel. A v1-only decoder receiving v2 and a v2-selected
decoder receiving v1 fail the whole envelope without retrying the same
ambiguous command. Unknown compatible row/action additions disable only their
affected feature when the selected envelope allows that behavior; an
unsupported projection envelope triggers whole-projection fallback. No disk
inference, hidden selector, environment override, optimistic decode/retry, or
warning on negotiation failure occurs.

### T15.1 preserved R002/R003/R004-R006 vectors

Use injectable entropy and identity sources. For 10,000 process starts, assert each `process_launch_id` is a lowercase UUID v4 produced from at least 128 CSPRNG bits, collision-free in the corpus, and changes when entropy changes while PID, host serial, MAC, host UUID, provider ID, wallet, and username remain fixed. Hold entropy fixed in a test double while changing each identity input and assert the encoded UUID does not change; static dependency/call-site inspection must show none of those identity values enters UUID derivation. Repeat the distinct action/attempt UUID rules with their required CSPRNG entropy and assert action, attempt, process, transaction, candidate, and root IDs are never reused or derived from one another.

Within one `process_launch_id`, feed sequences 0→1→2, duplicates, gaps, and 2→1: only strictly newer same-process projections advance. Restart to a new launch ID with sequence 0 and assert the CLI-session baseline resets inside the currently accepted app refresh generation; it must not override the app-owned A/B order from T14.1. Persist/restart Malibu and prove callbacks from the old app epoch are discarded.

Use a frozen wall clock for live signed rate-card ages 299, 300, and 301 seconds at max age 300; 604799, 604800, and 604801 at max age 604800; and invalid max ages 299 and 604801. Equality is fresh, one second over is stale, and an out-of-range max age makes the projection unavailable. While visible, render at ages `min(300,max_age)-1`, exactly the bound, and bound+1; the last refreshes or becomes unavailable before display. Cover valid live signed, valid static signed, missing, signature-invalid, generated-at mismatch, policy-version mismatch, unknown multiplier, stale live, fresh static fallback, and stale static fallback. Assert exact feed digests/source nullability, matching demand/candidate generation and policy when used, money-action disablement, warnings, and conservative state precedence `blocked > unavailable > stale > fallback > trusted`; stale fallback is `stale`, and unsigned/untrusted bytes never become trusted through fallback.

For rate/share math, use exact decimal/rational owner conversions and golden rows: catalog prompt/completion `2.00/4.00` with `provider_share_bps=9000` yields provider `1.80/3.60` USD per million tokens; repeat share bps `0`, `1`, `3333`, `9000`, and `10000`, zero/maximum supported rates, multiplier boundaries, below-half/exact-half/above-half ties, and checked overflow. Compare projection values to the SPEC-005 integer/round-half-even oracle and reject float-drift or a payout inconsistent with catalog rate × share. Format `0`, `0.004567`, `0.0999`, `1`, `1.005`, `9.999`, `10`, and `1234.5` in every shipped locale with at least two significant figures, explicit USD-per-1,000,000-token units, and distinct prompt/completion labels; parsing the localized result must preserve the projected value within the declared display rounding and never turn a rate into time-based income.

Build deterministic ranking fixtures for the exact operator-owned SPEC-044-R005 tuple: R008 section rank ascending (`Current`, `Ready`, `Network catalog`, `Needs preparation`, `Blocked`); exact `provider_completion_payout_usd_per_million_tokens` descending null-last; `demand_rank` ascending null-last; `supply_deficit_score` descending null-last; `demand_weight` descending null-last; `ready_provider_count` ascending null-last; then tagged canonical row identity ascending. Encode identity as separate tag and value unsigned UTF-8 byte strings, each prefixed by its unsigned 32-bit big-endian byte length, using (`candidate`, `candidate_id`) when candidate ID is non-null and (`catalog`, `model_key`) otherwise, with no normalization. Compare numeric wire values exactly, never through localized formatting, string conversion, or binary-floating-point drift. Display identity and `recommendation_rank` never participate. Use no locale collation, case folding, Unicode normalization, localized display value, or input stability as a tie-break. Reject the entire projection before rendering/actions only when canonical row identity is duplicated.

Isolate every tuple component with equal display-name/case/Unicode fixtures, null/non-null pairs, duplicate payout/rate/demand values, and rows tied on every component before canonical identity. For each component, one-fault tests reverse its direction, put null first, swap supply deficit and demand weight, apply payout or demand only to a section, add recommendation rank, add display identity, omit either identity length prefix, normalize Unicode/case, or remove the identity tag; each faulty comparator must disagree with the reference oracle on a proving fixture. Candidate rows with the same `model_key` and distinct `candidate_id` values are accepted and ordered by candidate identity. Catalog rows with the same `model_key`, or candidate rows with the same `candidate_id`, are rejected as duplicate canonical identities. A catalog and candidate identity with equal raw value remain distinct because their tags differ. Permute row, catalog, rate-card, demand-feed, and candidate-feed order exhaustively for small sets and across 10,000 seeded permutations for larger sets; repeat under `en_US`, `tr_TR`, `sv_SE`, a comma-decimal locale, a non-Latin-digit locale, every shipped locale, and every shipped RTL locale. The byte-identical accepted row set must produce the same ordered canonical-identity list in every run. For every nontrusted economics state, components 2-6 are treated as null even if disabled-context values are carried, so a locally motivated Prepare row remains in `Needs preparation` and its relative order is invariant while rate, payout, provider-share, demand rank/weight/provider count/deficit fields change. Demand may influence a trusted row only when signed rate/demand/candidate generated-at and policy versions match.

Run a seeded property suite over arbitrary valid exact numerics, null patterns, UTF-8 model/candidate identities, all five R008 sections, and trusted/nontrusted rows. Compare production sorting to a standalone reference tuple encoder and assert totality, antisymmetry, transitivity, idempotence, permutation invariance, nontrusted components-2-through-6 invariance, and duplicate-canonical-identity rejection. Shrink and archive every counterexample seed.

For action gating, use explicit positive/one-fault-negative rows. Immediate Switch requires exact `action_model_id`, verified local artifact, `fit: fits`, warm-swap available, and matching `switch_model`; deferred Switch requires the same local/fit identity, warm-swap unavailable, matching `switch_model_deferred`, and exact restart/drain/resume copy. Evaluate remains available under degraded economics only when read-only, at most 10 seconds, no bytes/download/cache/config mutation, and neutral copy; otherwise it follows preparation confirmation/progress/cancel/cleanup requirements or is unavailable. Adopt for an unprepared target is unavailable until a separate Prepare succeeds; an adopt transaction that downloads, stages, or has `estimated_bytes` follows all preparation invariants. Every available action has matching non-null kind/ID/timeout and required confirmation; every unavailable action has null kind/ID/timeout and nonempty reason. Reconcile Switch/Evaluate/Prepare/Adopt only after a matching terminal plus fresh projection, including timeout and cancellation-too-late cases.

## T16 — exhaustive action-gating, journey, copy, and accessibility

Generate the Cartesian matrix of:

- `local_default` with the exact closed 12-state set `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, and `revoked`, accepting source legality only for the three local states;
- `coordinator` with that same exact 12-state set, including the authoritative coordinator `not_offered` cases;
- each `economics_state`: `trusted`, `fallback`, `stale`, `blocked`, `unavailable`;
- every owner-spec `provider_guidance.next_action` and `earning_path_class`, nullable/non-null transition reason, and valid label/meaning key;
- permitted/settlement booleans; `verification_status` `declared`/`verified`/`blocked`/missing/unknown; fit, runtime state, action model ID, estimate, safety warnings; and every valid/invalid candidate/guidance/source/freshness binding.
- signed-catalog-only rows with no owner-source candidate, then the first snapshot that adds a matching candidate; and every partial-null candidate/guidance/binding permutation.

For every combination, assert invalid source/state/boolean/trusted combinations fail closed. Valid non-trusted candidate-associated combinations expose Prepare only when all local prerequisites pass, the primary artifact is exactly `verified`, and the required `candidate_id`, five-field `provider_guidance`, source digest/time/sequence-or-nullable-event, and admission binding are fresh and exact. Test coordinator `not_offered` both with null event bound by the exact response digest and with a real event; no synthesized event is accepted. English `local_default:not_offered` output is exactly **Coordinator offer state is unavailable or has not been queried.** and cannot assert prior offer history; English `coordinator:not_offered` output is exactly **Coordinator reports no active network offer for this model.** and asserts only current authoritative readback. Every shipped localization and accessibility label preserves the source-aware meaning. Reject **never offered**, any historical assertion from `local_default`, and either exact sentence rendered for the other source. Malibu and every provider-facing CLI human renderer map the verbatim bound `earning_path_class` first and never derive it. For `settlement_capable`, English output is exactly **Eligible to earn on qualifying settled requests**; localized and screen-reader output must preserve conditional eligibility and the qualifying-settlement condition and must never say or imply **Earning now**, current income, current traffic, an accepted request, or a settled receipt. Run the same negative semantic assertions over every shipped locale and accessibility label. Preserve the other three exact owner mappings and their order. Local preparation uses exactly **Prepare locally**, **Download and verify this model for local use. This does not offer it to the network or enable earnings.**, and **Download and verify {estimated_size} for local use?** Rates, payouts, share, and demand do not motivate or accompany that action. Valid trusted catalog-priced/settlement-capable candidate rows use only operator-approved trusted copy plus the conditional verdict. Every `declared`, `blocked`, stale, unknown, or mismatched artifact/guidance source disables projection and direct dispatch.

A catalog-only row must have runtime `catalog`, null `action_model_id`, null candidate/guidance/binding group, exact `economics_state: unavailable`, exact `rate_source: none`, admission source/state exactly `local_default:not_offered`, null coordinator event and state-observed time, both `catalog_economics_permitted` and `settlement_capable` false, null rate-card identity/catalog rates/provider-share/payout/demand fields, every action unavailable with null kind/ID/timeout and a nonempty exact reason, and no candidate earning, admission, or local-readiness claim. Preserve it through the built CLI and production Malibu view only in the exact R008 `Blocked` section. Positively assert that section before any other row or action assertion. Starting from one valid row, run distinct one-fault section-placement negatives that move the otherwise-unchanged row to `Network catalog`, `Current`, `Ready`, or `Needs preparation` without the evidence required for that section; each rejects before rendering or dispatch. Then run one-fault negatives for each alternate economics state (`trusted`, `fallback`, `stale`, `blocked`), each alternate closed rate source, coordinator admission source, every alternate admission state, non-null coordinator event, non-null observation time, each authorization boolean set true independently, each money/demand field made non-null independently, each available or candidate-dependent action, and every partial-null candidate group; each rejects the projection before rendering or dispatch. Attempt cross-candidate borrowing from every candidate-associated row in the same snapshot and prior/newer snapshots using served-model ID, display name, artifact ID, release ID, feed digest/position, admission state/event, rate row, and demand row; the catalog-only row must retain the exact sentinel. A duplicate canonical identity rejects the whole projection before rendering rather than serving as a join; duplicate model keys for distinct candidates remain valid. On the first matching validated owner-source snapshot, require all three fields to become non-null together and bind that exact candidate before trusted economics or any Prepare/Evaluate/Adopt/Switch action is possible.

Drive `local_default:local_only`, `local_default:not_offered`, `coordinator:not_offered`, and `local_default:offerable` through Prepare locally → evaluate → offer → adopt using only approved typed transactions; prove preparation remains available across the fresh `local_default:not_offered` ↔ `coordinator:not_offered` transition and remains reachable without economics/admission mutation. For `local_only`, separately fixture `needs_weights`, `needs_runtime`, `requires_preparation`, unreachable adapter/runtime, fit failure, adapter rejection, and operator-policy block. Require exactly **Retained as local inventory only; this admission state does not claim the model is prepared, installed, ready, reachable, or usable.** and reject every provider-facing string, localization, accessibility label, log, or action summary that says or implies installed or usable without separate validated readiness/runtime evidence. Exercise unavailable prerequisites and every matrix branch. Reject an unknown or purported thirteenth admission state.

For preparation size formatting, test exact `estimated_bytes` values 1, 99,999,999, 100,000,000, 100,000,001, every `100,000,000 * n` boundary and boundary-plus-one selected across the range, and large values through exactly 1 TiB. Assert the displayed value is `ceil(bytes / 100000000) / 10` GB with exactly one fractional digit and never understates. Run `en_US`, a comma-decimal locale, and at least one locale using non-Latin digits, plus every shipped locale. For cleanup, assert each action `estimated_bytes` equals its target's exact logical reclaimable bytes and `{reclaimable_size}` represents that same value; exact source copy is **Remove this verified prepared model ({reclaimable_size} of managed data)? The current model and legacy model files will be kept.** No locale says or implies that APFS will recover that much physical capacity.

Run VoiceOver order/labels, keyboard, Dynamic Type, Reduce Motion, localization expansion, modal focus, background cancel, restart, child loss, worker event versus cancel-ack rendering, storage/legacy labels, and identity-specific cleanup confirmation. No path/secret/endpoint/prompt/completion leaks.

## T17 — upgrade, mixed store, rollback, and re-upgrade

Start from a production-shaped legacy root with configured incumbent/draft and extra unconfigured releases. Upgrade creates only `.macprovider-prepared-v3`; it does not alter legacy stat/hash/tree. Add mixed v3 releases, prepare/adopt where authorized, roll back to old CLI/app, then re-upgrade. At every phase legacy remains usable and untouched; v3 remains preserved/ignored during rollback and validates on re-upgrade; budgets/accounting match T09. Old R21-R27/v1/v2 planning state is never imported.

## T18 — dependency and governance gates

Fail unless:

1. `6f271245` and `c4401f17` are ancestors of implementation base.
2. The landed authority merge is exactly `c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f`, and its SPEC-001 v1.9.17/SPEC-044 v0.2.8 bytes freeze exact catalog-economics read/run/cancel spelling; the v1 trio `model_catalog_economics_v1` / `models catalog-economics.v1` / `model_catalog_economics.v1` and analogous v2 trio; selection capability placement in manifest `local_status_capabilities`; command-token and schema-companion placement in manifest `command_schemas`; the complete trio in flat fresh local status; the existing local-status/control-frame tier prerequisites; schema-companion-alone non-selection; support for separate valid v1/v2 manifest tiers; reserved-prefix-scoped unknown rejection and unrelated-value tolerance; static-card/no-indicator/no-retry/no-call behavior for no supported trio and every removal/reserved-addition/misplacement/dual/mixed/unknown-reserved/stale/conflict/manifest-status negative; current manifest/current v1 status, new Malibu/old v1 CLI, current Malibu/new v2-only CLI fallback, and new v2 manifest/status upgrade orders; exact `model catalog unavailable`/`projection_unavailable` warning and retry only after a negotiated request fails, times out, or returns a malformed envelope; and the constructive pre-work lifecycle with immutable-action validation, a prospective fresh attempt, one total 2.000-second failure→cancel deadline before semantic and cancel-visible checks, exactly one nonblocking operation-lock attempt, operation-conflict reacquisition within the remaining original deadline, and a new total 2.000-second operation→failure→cancel deadline after successful nonblocking operation acquisition. The historical pre-squash candidate `922624a7959253aae0581c6e2db22f827925072b` may be cited only as historical review evidence, not as the current authority, implementation base, or ancestry gate. Missing either required lock yields the exact UTF-8 stderr line `{"error_code":"dispatch_state_busy"}` plus LF, empty stdout, no event, exit 5, and no mutation; semantic failure creates one exact closed pending `failed_dispatch`, releases every lock before its sequence-1 event, and exits 3 without reacquisition, while the next failure writer or startup recovery performs copy-before-delete compaction under its ordered lock set. The same authority freezes the exhaustive lock graph: projection publication, active creation, non-cleanup final marker check and commit, ordinary terminal/history mutation, and startup/recovery use operation→failure→cancel; failed-dispatch creation/compaction/eviction and every direct-cancel-visible read use failure→cancel; direct cancel uses that pair under one total 2.000-second deadline and may mutate only the exact marker; live periodic marker polling is the sole operation→cancel path and is bounded read-only; cleanup mutation uses operation→cleanup→cancel, releases cleanup after durable cleanup state, and only then may use operation→failure→cancel for terminal/history work; adoption uses operation→adoption→socket→runtime. No cleanup/failure overlap, reverse edge, post-event reacquisition, or unbounded fairness claim is permitted. Pending/history movement publishes and readback-validates replacement history before pending unlink, tolerates crash duplicates through identity deduplication, and leaves no durable gap; a terminal failed dispatch present at direct-cancel pair-acquisition linearization always returns exact `terminal`. The authority also retains the exact catalog-only `unavailable`/`none`/`local_default:not_offered` null/false/no-action sentinel placed only in exact R008 `Blocked` with `Network catalog`/`Current`/`Ready`/`Needs preparation` one-fault negatives, cross-candidate rejection, and candidate-associated all-non-null verbatim guidance binding; coordinator no-event/event-backed `not_offered` plus exact source-aware local-default/coordinator English meanings and localization/accessibility/source-swap negatives; exact **Eligible to earn on qualifying settled requests** conditional copy and no current-income claim; exact admission-only `local_only` copy with independent readiness/usability evidence; the exact 12-state admission inventory; event codes and total precedence; exhaustive R002/R003 eligibility including `verification_status: verified`; worker-only sequencing; six-outcome cancellation acknowledgement with exact echo/nullability/exit/mutation/resource rules; bounded complete cleanup targets with target-level immutable `event_model_key`, public v2 action copies that reject `event_model_key` and bind only the enclosing digest/size, RFC 8785 equality between action copies, target/receipt/private-reservation event-key mismatch negatives, orphan event-correlation proof, and separate/equal-two-copy mutation proofs; authenticated root locator/identity and already-open unpublished owner-only temp/empty-ACL-before-sensitive-byte/revalidation rules; the exact SPEC-044-R005 total ranking tuple with null order/tagged length-prefixed canonical identity/duplicate-canonical-identity rejection and nontrusted components 2-6 null; app-owned refresh generation and constant-space transport/backpressure; logical-byte accounting and truthful APFS copy; exact budgets/configuration precedence; and published/staging continuous final-check-through-durable-readback-validated-`tombstoned` cleanup semantics.
3. The plan ownership table, SPEC-044 exhaustive graph, T01/T03/T12/T14, and every negative assertion agree exactly: a failure-only worker owns one bounded failure→cancel pair for semantic-failure pending/history creation, compaction, and eviction and never owns operation/cleanup/adoption/socket/runtime authority, live work, or incumbent mutation; a direct cancel process owns one bounded failure→cancel pair for its cancel-visible snapshot and exact-marker decision and never mutates history, recovery, cleanup, artifact, model, or runtime state or owns operation/cleanup/adoption/socket/runtime authority. Any failure-only `cancel.lock` prohibition, failure-only single-lock ownership, direct-cancel `cancel.lock`-only ownership, or omitted first `failure.lock` acquisition fails this gate.
4. It keeps the existing event schema, adds no status/control frame/public crash/late-cancel state, and does not overload `cleanup_staging`.
5. SPEC-001 §6.14b is `SPEC-001-R003` with a pending CONFORMANCE entry; every forward-current reference to SPEC-044 in SPEC-001, SPEC-044 implementation/evidence text, CONFORMANCE, AUTHORITY, generated indexes, current handoffs, contract locks, and these v17 planning artifacts names v0.2.8, while references to v0.2.7 and earlier are explicitly historical changelog/review context; AUTHORITY registers the applicable SPEC-044 consumer; R005 no longer credits the contradictory hide test and instead records the explicit gap and named future visible-local-preparation proof; versions, generated indexes, CONFORMANCE, #1485 ownership/copy, committed file SHA-256 digests, and authority-review lineage all agree exactly.
6. `git merge-base --is-ancestor c8c97f6625a88fa7c83ae2b5cf4d68078409cc6f <first-6B-commit>` succeeds and commits differ.
7. SHA-256 digests are computed from and archived for the committed v17 plan and test specification; fresh independent review of those exact bytes plus the landed SPEC diff has zero Critical/High/Medium and explicitly dispositions B1-AUTH-V9-H1, B1-AUTH-V8-M1, B1-AUTH-V7-H1/H2/M1, B1-AUTH-V6-H1/H2/M1/M2, B1-AUTH-V5-H1/M1-M3, B1-AUTH-V4-H1/M1-M4, B1-AUTH-V3-H1-H3/M1-M3, B1-AUTH-H1/H2/M1-M13, B1-AUTH-V2-H1-H4/M1-M5, and the v16-to-v17 authority-base/event-model-key correction.
8. Discovery/admission journeys and `SPEC-023-R006` remain pending unless accepted signed evidence changes CONFORMANCE.

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

Run independent code, security, and architecture lanes over the complete authority-through-implementation diff. Each lane explicitly dispositions B1-STORAGE-V17-H1, B1-AUTH-V8-M1, B1-AUTH-V7-H1/H2/M1, B1-AUTH-V6-H1/H2/M1/M2, B1-V2-H1 and M1-M5, B1-V3-M1, B1-AUTH-V3-H1-H3 and M1-M3, B1-AUTH-H1/H2 and M1-M13, B1-AUTH-V2-H1-H4 and M1-M5, plus all prior v1 findings. Any Critical/High/Medium blocks; fixes require affected tests and all full-diff lanes again.
Each lane also dispositions B1-V3-M1 and verifies that the 256-object limit is an admission invariant rather than only a decoder limit.

## T21 — real-hardware preparation, storage, and incumbent journey

On supported Apple Silicon with final signed feeds/assets:

1. sustain real incumbent inference across local preparation;
2. use real throttled HTTPS and capture separately labeled server/transport/delegate/accepted/staged counters without asserting a server/transport bound;
3. repeat default/custom and separate-volume APFS roots;
4. exercise raw root/bootstrap temps, byte-identical private-state envelope temps/targets, marker, publication, and deletion boundary reboot/abrupt-power recovery;
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
| Conditional earning truth and catalog-only isolation | T01, T05, T14-T16 | Exact qualifying-settlement verdict, exact catalog sentinel with one-fault negatives, and cross-candidate negatives |
| Deterministic v1/v2 compatibility | T01, T14, T15 | Categorized complete trios, current and staged upgrade orders, byte-level removal/addition/misplacement/disagreement negatives, reserved-prefix unknown scope, unrelated-value tolerance, and built production-boundary matrix |
| Intent-first exact deletion/cancellation recovery | T03, T10, T12 | Worker-owned recovery, durable tombstoned commit, boundary logs, and power cases |
| Exhaustive lock graph and cancel-visible terminal linearization | T01-T03, T12, T14 | Exact path traces, pairwise overlaps, failure→cancel history serialization, and terminal-at-linearization result |
| Bounded dispatch/cancellation contention | T02, T03, T12, T14 | One total pair deadline, exact `dispatch_state_busy`/cancel `busy`, Malibu retry mapping, and zero resource leaks |
| Crash-safe temp/root bootstrap | T01, T04, T08 | Complete injection matrix |
| Enforceable URLSession bounds only | T06, T09, T21 | Separated counters and real transfer |
| Dedicated v3 namespace/logical accounting/legacy safety | T09, T10, T17, T21 | Algorithm fixtures and upgrade/mixed/rollback hashes |
| Reachable bounded cleanup for every v3 object | T09, T10, T14, T16 | Complete target projection, nested-action JCS/digest/size binding, and orphan event correlation through production adapter |
| Attached-worker events/cancel acknowledgement | T01-T03, T06, T14 | Constructive failed-dispatch terminals, live-worker sequence, total ack precedence, and randomized multi-process schedules |
| Exact error precedence | T14 | Adjacent/three-way fault table with code/terminal/exit/side effects |
| Object-count admission and fail-closed overflow detection | T09, T10 | 255/256/idempotent/257 refusal, 257/258/large seeded overflow, and cleanup-race schedules |
| Prior root/selection/durability/resource/adoption gates | T02-T13 | Targeted and APFS evidence |
| Malibu copy/accessibility/fallback | T14-T17 | Bounded built adapter/decoder, refresh ordering, admission-only local copy, exact rate/size/locales, and UI/accessibility results |
| Locale-independent total row order | T01, T15, T16 | Exact SPEC-044-R005 tuple/null/identity order, duplicate predicate, properties, permutations, and locale invariance |
| Zero C/H/M | T18-T20 | Governance, explicit v6 disposition, and three reviews |
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
| B1-AUTH-H2 | T01, T14, T15, T18 | Advertising uses one selected complete categorized trio and every old/new combination has one deterministic call/fallback result. |
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
| B1-AUTH-V3-M2 | T03, T12, T14 | Direct cancel's complete failure→cancel acquisition stops at one total 2.000 monotonic seconds with valid null-attempt/no-read/no-mutation `busy`; repeated direct/app attempts release all resources. |
| B1-AUTH-V3-M3 | T15, T16 | Exact total canonical-wire tuple, null order, tagged canonical identity, duplicate rejection, properties, permutations, and locales produce one order. |
| B1-AUTH-V4-H1 | T01, T15, T16, T18 | Plan, tests, and operator authority use only the exact SPEC-044-R005 tuple and canonical-identity predicate. |
| B1-AUTH-V4-M1 | T01, T05, T15, T16 | Catalog-only rows require the exact sentinel and reject every one-fault source/state/event/time/boolean/economics deviation. |
| B1-AUTH-V4-M2 | T01, T14, T16 | `local_only` copy states admission only; blocker fixtures reject installed/usable claims without independent readiness evidence. |
| B1-AUTH-V4-M3 | T09, T10, T16 | Row cleanup equals the target's nested cleanup under RFC 8785 JCS and separately binds target digest and size with one-fault negatives. |
| B1-AUTH-V4-M4 | T01, T16, T18 | Authority and tests enumerate exactly the same closed 12 admission states and reject a thirteenth. |
| B1-AUTH-V5-H1 | T01, T16, T18 | Plan, tests, operator artifact, and contract lock select the same exact `local_only` English source while readiness remains separately evidenced and blocker-tested. |
| B1-AUTH-V5-M1 | T01, T15, T16, T18 | The catalog-only unavailable sentinel renders only in exact R008 `Blocked`; one-fault placements in all four forbidden sections reject without borrowed evidence. |
| B1-AUTH-V5-M2 | T01, T16, T18 | Exact source-aware `not_offered` meanings distinguish unknown/unqueried local state from authoritative no-active-offer readback across English, localization, and accessibility outputs. |
| B1-AUTH-V5-M3 | T09, T10, T16 | Separate enclosing-target, action-side, every-other-action-field, and cross-target fixtures reject before confirmation or mutation with protected sentinels unchanged. |
| B1-AUTH-V8-M1 | T01, T03, T12, T14, T18 | The ownership table and all negative assertions assign failure-only and direct cancel the exact bounded failure→cancel pair, preserve their distinct mutation scopes, and reject every single-lock or inverted ownership variant. |
| B1-AUTH-V7-H1 | T01-T03, T12, T14, T18 | Projection, failure-only, pre-active/normal, ordinary terminal/history, recovery, direct cancel, cleanup mutation/post-cleanup terminal, marker-poll, and adoption paths have one acquisition/retention/release graph with deterministic pairwise traces and no cleanup/failure overlap. |
| B1-AUTH-V7-H2 | T03, T12, T14, T18 | All failed-dispatch pending/history creation, compaction, eviction, and cancel-visible reads use failure→cancel; injected boundary reads see complete generations and terminal-at-linearization always returns exact `terminal`. |
| B1-AUTH-V7-M1 | T02, T12, T14, T18 | One total 2.000-second failure→cancel deadline yields exact pre-attachment `dispatch_state_busy` or cancel `busy`, releases all resources, proves bounded fail-closed liveness under continuous arrivals, and makes no starvation-free claim. |
| B1-AUTH-V6-H1 | T01, T14, T15, T18 | Every negotiation-negative class is a silent static card with zero calls; only a selected trio's failed/timed-out/malformed request shows exact `model catalog unavailable`/`projection_unavailable` and retry. |
| B1-AUTH-V6-H2 | T01, T02, T14, T18 | Immutable-identity-valid invocations exercise the first failure-lock check, single nonblocking operation-lock attempt, conflict/pre-active revalidation, no-handoff crash interval, lock-free stdout, later failure-writer/startup compaction under the ordered pair/triple, and exact bounded failed-dispatch recovery without live/work side effects. |
| B1-AUTH-V6-M1 | T18 | Every forward-current owner, implementation, evidence, index, handoff, contract-lock, and planning reference selects SPEC-044 v0.2.8 with exact committed digests. |
| B1-AUTH-V6-M2 | T09, T10, T16, T18 | Each cleanup action copy is mutated separately for every field, and equal-two-copy digest/size mutations prove independent binding to the unchanged enclosing target. |
| B1-AUTH-V9-H1 | T01, T14, T15, T18 | Both generations require the exact categorized selection-capability/command-token/schema-companion trio; current v1 and staged v1/v2 upgrade orders pass; every reserved removal/addition/misplacement/mixed/cross-surface fault causes no call; unrelated values remain tolerated. |
| B1-AUTH-V2-H1 | T01, T15, T18 | The v9 correction closes generation exclusivity with an implementable three-member grammar and complete upgrade-order proof. |
| B1-AUTH-V2-H2 | T05, T16, T23 | Exact no-event coordinator `not_offered` binds by full response digest without fabrication; event-backed and transition cases remain distinct. |
| B1-AUTH-V2-H3 | T03, T10, T12, T21 | Direct cancel takes failure→cancel but retains marker-only mutation authority; cleanup recovery owns operation→cleanup→cancel; durable tombstoned phase is commit evidence and every intent tombstone is reversible. |
| B1-AUTH-V2-H4 | T01, T04, T05, T08, T21 | Complete nonce/path/descriptor/version identity is authenticated and saved in every reopening lifecycle record across drift/copy/remount/reuse cases. |
| B1-AUTH-V2-M1 | T01, T15, T16 | Catalog-only rows use the exact all-null/no-action form; candidate rows and candidate actions require the all-non-null binding. |
| B1-AUTH-V2-M2 | T09, T10, T14 | Orphan cleanup retains an immutable event model key and completes success/cancel/recovery/retry through the built production adapter. |
| B1-AUTH-V2-M3 | T14, T15 | App-owned prelaunch generation rejects inverted late reads across restart/timeout while attached action workers continue. |
| B1-AUTH-V2-M4 | T14 | Partial line, stdout, stderr, decoded queue, scheduled delivery, and backpressure remain constant-space under sustained/no-newline input. |
| B1-AUTH-V2-M5 | T08, T10, T21 | Every private component has no extended ACL; inherited ACLs are stripped only on new objects and mutation races abort before side effects. |

All v1 dispositions remain mandatory and are mapped in the plan.

## Stop condition

The reservation subplan is implementation-complete only when T01-T20 pass on the full final diff and independent reviews report zero Critical, High, and Medium. Build 1 is complete only when T21-T24 pass with final signed assets, accepted signed discovery/admission journeys, correctly settled positive credit, first listed-tier evidence, stable-media qualification, and updater proof. No plan, fixture, issue checkbox, prepared artifact, or slice 6 suite replaces those gates.
