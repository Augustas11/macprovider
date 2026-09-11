# Build 1 preparation-reservation rebaseline plan v2

Status: revised plan; **blocked before slice 6B** until the operator-owned authority patch in Dependency Gate 5 lands and an independent review reaches zero Critical, High, and Medium findings.

Baseline: `c4401f1791d593d37d68eba91af94219b26d278f` (`origin/main` after the BYOM v0.2 slice 6 operator state/copy deliverable landed on 2026-09-11).

Authority: issue #1453 remains the execution queue. This document supersedes the v1 reservation plan as planning input. It does not approve, migrate, or reuse the abandoned R21-R27 protocol or local development state.

## Decision

The initiating `malibu-cli` process remains the preparation worker. It owns one provider-UID-scoped, user-private authority root, holds one live kernel `flock` for the full operation, downloads and verifies only transaction-owned bytes, and publishes one immutable content-addressed artifact. A second same-EUID CLI process may request cancellation through the same capability-negotiated catalog-economics transaction interface. There is no daemon, background service, database, PID authority, or post-crash worker continuation.

The only public read surface is the existing `malibu-cli models catalog-economics --json` projection with `schema: "model_catalog_economics.v1"` or a later operator-approved compatible version. The only public progress/result surface is SPEC-044's existing `model_catalog_transaction_event.v1`. This plan adds no public transaction-status schema, no `models transactions status/run/cancel` command family, no public `interrupted` state, no `cancellation_too_late` enum, and no authority-refresh request/response frame.

Preparation ends at durable local readiness. It never edits provider configuration, changes the running model, changes admission or routing, grants economics, submits an offer, or creates settlement evidence. Adoption remains a separate use of the existing recommendation-adoption lock, journal, `prepareModelAdoptionRequest`, and warm-swap protocol. If the serving process lacks the target after preparation, its existing prepare-adoption handler must independently reload signed feed authority, resolve the configured durable root, and hash the durable target before accepting it. No requester-supplied path or new control-socket schema becomes authority.

The design deliberately does not hold `ModelRuntime`'s short prepared or active reservation while transferring model bytes. Those leases begin only inside the existing post-readiness adoption path.

## Product outcome and boundary

The reservation subplan lets a provider select a supported catalog model, see exact size and trust disclosure, prepare the primary MLX artifact safely, cancel before the durable publication boundary, recover after a crash, inspect readiness through a fresh catalog-economics projection, and keep the incumbent serving throughout.

| Original Build 1 outcome | Current owner and status | Reservation-subplan contribution |
|---|---|---|
| Select a supported catalog model | Signed artifact-feed qualification is landed. | Deterministically reserve at most 64 exact preparation tuples with stable action IDs and starvation-free overflow rotation. |
| Prepare one primary MLX artifact safely | Still missing from the baseline. | Same-EUID CLI worker, isolated staging, bounded transfer callbacks, exact-root custody, cancellation, verification, and publish-once readiness. |
| Understand pricing and admission | BYOM slices 0-5 own feeds, intake, matching, decisions, and truthful non-earning states. | No economics or admission mutation. Preparation is local and non-economic. |
| Execute actions in Malibu | #1485 operator copy is landed at `c4401f17`; client implementation remains governed by SPEC-044 and the handoff. | Supply the local preparation engine only after the narrow authority patch freezes invocation and cleanup exposure. |
| One real Mac serves a correctly settled request | Slice 7 (#1486). | Supply the verified prepared artifact; preparation success alone cannot pass Build 1. |

Feed, admission, settlement, and copy work already landed or owned by BYOM must not be duplicated. The state labels, meanings, earning-verdict-first order, and disclosure copy in `audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md` are inputs, not text for slice 6 to reinterpret.

## User journeys

### J1 — prepare while the incumbent serves

1. Malibu obtains a fresh capability-negotiated `models catalog-economics --json` projection.
2. A row shows a qualified primary `mlx_safetensors` artifact, signed source, exact `estimated_bytes`, fit result, and an available typed `prepare_model` action.
3. The provider confirms size and trust source.
4. Malibu invokes the operator-approved transaction mode under `models catalog-economics`; the attached CLI worker emits only `model_catalog_transaction_event.v1` JSON lines.
5. The worker downloads into its recorded staging tree, verifies the frozen tuple, builds and fully syncs an unpublished durable tree, exclusively renames it, fully syncs the destination parent, persists terminal local state, and only then emits `succeeded`.
6. Malibu refreshes `models catalog-economics --json`. The row reports ready/present through existing fields. Config bytes and live runtime identity remain unchanged.

### J2 — cancel, fail, or recover

1. Malibu requests cancellation using the operator-approved cancellation mode on the same catalog-economics transaction interface.
2. The worker observes the exact attempt-bound marker through the transfer watchdog, every bounded hash/copy loop, and immediately before exclusive rename.
3. Before the durable publication boundary, the public stream is `cancel_requested` then `cancelled`; the worker removes only recorded staging, resume metadata, and the unpublished durable tree.
4. After a worker crash, the next projection or invocation acquires the released lock and performs private recovery. No public `interrupted` event exists. Until recovery finishes, the row exposes no prepare action and uses existing `staging_cleanup_required`/`action_unavailable` signaling as applicable.
5. If publication is already durable, cancellation resolves only as existing terminal `succeeded` or `failed`. Malibu refreshes the projection to learn the authoritative ready state. There is no `cancellation_too_late` enum or copy.

### J3 — adopt after readiness

1. A fresh projection re-qualifies current signed candidate/artifact feeds and verifies the durable target under the same bound root identity.
2. The CLI enters the existing `RecommendationAdoptionLock`/journal/control-socket path.
3. The existing `prepareModelAdoptionRequest` handler first tries its current authority. If the target is absent, the serving process itself reloads signed feed files through its configured trust path, resolves its own artifact root, proves that root identity equals the prepared tuple's recorded identity, derives the destination, and hashes the canonical artifact. It then accepts or rejects through the existing result frame.
4. Adoption still checks the incumbent, takes short runtime reservations, journals config mutation, loads, drains, and atomically swaps. Preparation never grants runtime authority by itself.

### J4 — old client or unavailable capability

An app or CLI without the approved capability renders the existing fallback and cannot prepare or clean published artifacts. Unknown projection/event schemas, fields, enums, stale IDs, mismatched tuples, or unsupported actions make only the affected row or transaction unavailable. They never fall through to legacy commands or mutate the incumbent.

### J5 — inspect and reclaim published storage

The projection reports bounded storage totals only after the operator-owned cleanup contract lands. It never removes published artifacts automatically. A provider may confirm an identity-safe `cleanup_published_artifact` action for a named immutable release. The worker re-evaluates the keep set under lock, deletes only the selected content-addressed identity through a crash-recoverable tombstone, and refreshes totals.

## Ownership and trust boundaries

| Component | Owns | Must not own |
|---|---|---|
| Projection builder | Qualified feeds, exact root binding, row-to-reservation tuple, bounded selection, readiness/inventory readback | Downloads, app heuristics, admission mutation |
| Initiating CLI worker | Operation lock, active attempt, URLSession task, staging, verification, durable barriers, events | Background survival, config, runtime, offer/admission/economics |
| Cancellation CLI | Exact bounded attempt marker through approved transaction mode | Killing the worker, deleting files, changing tuple or root |
| Malibu | Confirmation, attached process/event rendering, cancellation request, projection refresh | Filesystem access, feed verification, inferred status/action eligibility |
| Serving CLI | Existing owner-only socket, independent feed reload, identical-root proof, durable hash, adoption/warm swap | Trusting requester paths/hashes or downloading during adoption |
| Published cleanup worker | Bounded inventory, keep-set proof, exact tombstone/delete/recovery | Automatic GC, broad deletion, incumbent/adoption/in-flight deletion |
| Coordinator/BYOM | Offer, decision, routing, admission, settlement authority | Local preparation custody |

The local trust boundary is the effective POSIX UID. Same-EUID processes may inspect the projection and request cancellation. Another UID is refused by ownership/mode checks and the existing control-socket peer check. This does not claim isolation between same-UID processes.

## Dependency gates

1. PR #1481 merged as `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a`. It landed slice 5 intake, generator, coordinator surfaces, tests, and the monthly release runbook. The first evidenced listed-tier production release remains pending; `SPEC-023-R006` remains pending in `specs/CONFORMANCE.json`.
2. The operator-owned #1485 state surface and disclosure copy landed at `c4401f1791d593d37d68eba91af94219b26d278f`. Slice 6 must use those exact strings and wire-first earning verdict behavior.
3. `JOURNEY-PROVIDER-BYOM-DISCOVERY` remains pending in CONFORMANCE despite the issue checkbox. `JOURNEY-NETWORK-MODEL-ADMISSION` and settlement-capable real-hardware proof also remain pending. Issue state is not conformance evidence.
4. SPEC-044 v0.1.1 currently freezes `models catalog-economics --json`, the `model_catalog_economics.v1` projection, action kinds including `prepare_model` and `cleanup_staging`, and `model_catalog_transaction_event.v1`. `cleanup_staging` is only for staging and must not delete published artifacts.
5. **Hard pre-6B authority gate:** @Augustas11 must land one narrowly scoped SPEC-001/SPEC-044 contract patch, with updated AUTHORITY/CONFORMANCE indexes as required, before implementation begins. The patch must freeze: (a) the exact run and cancellation option spelling under the capability-negotiated `models catalog-economics` command; (b) the closed event error/warning codes and precedence needed by prepare/cancel; and (c) the minimal versioned projection/action addition for bounded published-storage totals and provider-confirmed `cleanup_published_artifact`. It must keep `model_catalog_transaction_event.v1`, add no status schema or control-socket frame, and must not overload `cleanup_staging`. If the owner declines any part, that part is removed from implementation rather than invented locally.
6. T18 must prove the authority commit is an ancestor of the first slice 6B implementation commit and that ownership was operator-approved. A same-commit or later authority edit fails the gate.
7. Slice 7 remains the signed physical-hardware, discovery/admission journey, settlement, release-asset, and updater gate.

## Dependency graph

```text
landed signed artifact feed + #1481 intake
                    |
                    v
#1485 copy landed at c4401f17
                    |
                    v
6A: one operator-owned invocation/error/cleanup authority patch
                    |
          +---------+----------+
          |                    |
          v                    v
6B root-bound prepare      6C Malibu projection,
engine + inventory         events, copy, controls
          |                    |
          +---------+----------+
                    v
6D existing adoption request handler reload + identical-root proof
                    |
                    v
slice 7 signed real-Mac journeys, settlement, release, updater
```

## Normative local contracts

These contracts are private persistence details. They are not CLI schemas, capability tokens, or control-socket frames. Unknown or invalid local records fail closed and surface only through existing or operator-approved public projection/event fields.

### Authority root and filesystem profile

Default authority root: `~/.config/macprovider/model-preparation-v2/`, exactly one per EUID.

```text
model-preparation-v2/                  0700, owner EUID, no extended ACL
  operation.lock                      0600 regular file, one live flock
  reservations.json                   0600, <= 262144 bytes
  active.json                         0600, <= 65536 bytes, one operation
  cancel.json                         0600, <= 4096 bytes, zero or one marker
  published-inventory.json            0600, <= 262144 bytes
  deletion.json                       0600, <= 32768 bytes, zero or one tombstone

<bound-artifact-root>/                 descriptor-validated custom/default root
  .macprovider-preparation-v2/
    staging/<transaction>/<attempt>/  0700, exact attempt custody
    unpublished/<transaction-attempt> 0700, recorded unpublished tree
```

Open directories by descriptor with `O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW`; require the effective owner, exact mode, expected `st_dev`, and no extended ACL. Open files with `O_NOFOLLOW|O_CLOEXEC`; require regular type, owner, link count one, exact mode, and size cap. All JSON decoders reject duplicate/unknown keys, invalid UTF-8, floats where integers are required, negative or out-of-range integers, and trailing bytes.

Private state writes use a fixed same-directory temporary leaf created with `O_CREAT|O_EXCL`, full write, `fchmod`, `fsync`, `F_FULLFSYNC`, bounded readback, atomic rename, then directory `fsync` and `F_FULLFSYNC`. Failure of a stable-media barrier is a failed write; a weaker sync is never reported as durable success.

### Secure artifact-root binding

The root resolution order remains the product's existing config/environment contract, but it is evaluated only when a new reservation snapshot is built. The builder resolves the chosen path once, obtains a canonical absolute path, then reopens every component descriptor-relatively without following symlinks. The final directory must be owner-controlled and writable. The builder records this non-secret binding:

```text
artifact_root_canonical_path
artifact_root_st_dev
artifact_root_st_ino
artifact_root_identity_sha256
```

`artifact_root_identity_sha256` hashes a securely created, mode-0600, single-link `root.identity` record inside the artifact root plus the descriptor's `st_dev` and `st_ino`. The record contains a schema tag and 256 bits of CSPRNG identity; it grants no authority and may be disclosed only as a digest. Existing roots receive the record under an exclusive create and full-sync sequence before reservations are emitted.

Every reservation, active record, selection-history entry, published inventory entry, deletion tombstone, and tuple digest includes the complete binding. After a crash, recovery ignores changed environment/config input. It reopens only `artifact_root_canonical_path` saved in `active.json`, component by component with no symlink traversal, and requires exact `st_dev`, `st_ino`, and identity digest. Replacement, remount, inode reuse with a different identity record, or unavailable volume blocks deletion/publication and exposes existing cleanup/action-unavailable signaling. It never follows a new root to find or delete old bytes.

Serving readiness is valid only when the serving process independently resolves its configured root and proves all four binding fields identical before hashing the destination. A prepared artifact in root A is not authority for a server configured to root B.

### Reservation snapshot and tuple

`reservations.json` is a private `model_preparation_reservations.v2` document with provider EUID, provider ID, current config-byte SHA-256, artifact-root binding, generation, at most 64 selected entries, and bounded selection history for at most 256 currently eligible tuple digests. Each selected entry contains a lowercase UUID transaction ID, `prepare_model`, tuple digest, selection metadata, and the frozen target:

```text
model_key, model_id, model_revision, artifact_id,
runtime_format, hash_algorithm, artifact_hash,
source_kind, source_repo_id, source_revision,
release_id, candidate_catalog_sha256,
artifact_feed_sha256, artifact_feed_signer_key_id,
estimated_bytes, complete artifact-root binding
```

Build 1 accepts only a qualified, verified, primary `mlx_safetensors` artifact using `macprovider.snapshot-manifest.v1`, an immutable 40-lowercase-hex Hugging Face revision equal to the model revision, and the signed primary artifact hash. `estimated_bytes` is required and is `1...1099511627776`. Digests are 64 lowercase hex. Text and identifier caps remain those in v1; config reads are capped at 1 MiB and never rewritten.

`tuple_sha256` is SHA-256 of `"model-preparation-tuple-v2\0"` followed by the complete target, provider EUID/ID, config SHA-256, and all four root-binding fields in the listed order. Integers are fixed-width unsigned big-endian; strings are 32-bit-length-prefixed UTF-8; digests contribute decoded bytes. This is the only tuple codec. Malibu never computes it.

### Deterministic selection above 64

Eligibility is derived only from the signed qualified rows. Define `authority_order` as ascending `(model_key UTF-8 bytes, model_revision, artifact_id, artifact_hash, artifact_root_identity_sha256, tuple_sha256)`. Snapshot generation runs under `operation.lock` and uses these exact rules:

1. A currently active or atomically dispatched tuple is pinned first and consumes one slot.
2. Eight fairness slots, or all remaining slots when fewer than eight remain, go to eligible non-pinned tuples with the oldest `last_selected_generation`; never-selected tuples sort first, then `authority_order` breaks ties.
3. Remaining slots retain eligible unchanged selected entries in prior slot order, preserving their transaction IDs.
4. Any remaining capacity is filled by `authority_order`. New selections receive UUID v4 IDs; eviction removes the action ID but keeps bounded fairness metadata.
5. Selection history is pruned deterministically to the 256 currently eligible tuples with the oldest wait priority first. More than 256 eligible preparation tuples makes preparation unavailable for the projection and raises existing projection/action-unavailable signaling; it does not truncate an unaccounted set.

The eight fairness slots prevent unchanged-ID priority from starving new or previously evicted tuples: with `N <= 256`, every continuously eligible non-pinned tuple is selected within `ceil((N-56)/8)+1` successful projection generations. Feed input order and process restart do not affect selection. A dispatched run and snapshot rewrite serialize on `operation.lock`: if dispatch wins, it validates and persists `active.json` before unlock and the tuple is pinned; if rewrite evicts first, dispatch returns an operator-approved stale/action-unavailable event without side effects and Malibu refreshes.

### Active operation slot

`active.json` is private `model_preparation_operation.v2`. It duplicates the tuple and root binding and stores transaction/attempt IDs, private phase, counters, monotonic-deadline basis, recorded staging/unpublished leaf names, cancel observation, barrier progress, and terminal result. Private recovery phases may include `needs_recovery`; they are never emitted as a new public event state.

The worker takes `LOCK_EX|LOCK_NB`, validates the selected tuple and current signed feeds, persists `active.json`, and retains the descriptor through durable terminal state and cleanup. Another run receives the operator-approved busy error. Wall time is display/audit only; the deadline uses monotonic elapsed time and remains within SPEC-044's 1...1800 seconds.

### Cancellation marker and public state

The cancellation marker binds transaction ID, attempt ID, tuple digest, provider/config identity, root identity, and request time. The cancel process writes it durably but does not take or break the worker lock. Public states use only `queued`, `running`, `cancel_requested`, `cancelled`, `succeeded`, `failed`, and `timed_out`. After the publication linearization point, cancellation returns `succeeded` when the artifact is verified present or `failed` if recovery cannot establish it; a fresh projection is the status source.

### URLSession transfer and cancellation contract

Production transfer uses an ephemeral `URLSession` with a serial `URLSessionDataDelegate`, no shared cache/cookie/credential storage, and no unowned download-task temporary file. Each response is written directly to the attempt's descriptor-opened staging partial. The response callback requires HTTPS, the expected host/revision URL policy, 200 for a new file or 206 with an exact `Content-Range` and unchanged strong ETag for same-attempt resume. A declared length that would exceed the tuple's aggregate remaining bytes cancels before accepting body data.

The delegate splits each delivered `Data` value into at most 1 MiB write quanta. Before each quantum it checks the monotonic deadline, exact cancellation marker, per-file/aggregate byte counts, and destination descriptor identity. If the next quantum crosses `estimated_bytes`, it calls `task.cancel()` before writing any excess byte. URLSession may already have buffered one callback, so server-observed bytes are bounded by the cap plus one 1 MiB callback quantum; durable staged bytes never exceed the signed cap.

A watchdog on the same serial state machine checks cancellation/deadline at least every 250 ms even when the server stalls, calls `task.cancel()` within 250 ms of observing a durable marker, and emits a heartbeat at least every 10 seconds. The worker requires the cancellation completion callback within 2 seconds in the supported local/network test profile; otherwise it invalidates the session, closes the staging descriptor, and fails closed without publication.

Transient retry within the same live attempt may resume only from the fully synced staged byte offset plus private resume metadata containing URL, strong ETag, expected length, and prefix hash. The metadata is inside the attempt directory and full-synced before the Range request. URLSession opaque resume data is never retained. After process crash or a new attempt ID, recovery deletes the partial and resume record after exact-root validation and restarts from byte zero.

### Artifact work bounds and space admission

One attempt permits at most 4096 regular files, depth 32, 4096 siblings, and 1024 UTF-8 bytes per relative path. It rejects absolute/dot/control components, symlinks, hard links, devices, sockets, FIFOs, sparse-file logical-size overflow, cross-device traversal, case-fold collisions, and Unicode-normalization collisions. Metadata bodies and decoded metadata are capped at 131072 bytes; config reads remain capped at 1048576 bytes; public event lines are capped at 16384 bytes. The verified aggregate logical size must equal `estimated_bytes`. Hash/copy loops use at most 8 MiB buffers and cancellation/deadline checks per buffer. Network writes use the stricter 1 MiB quantum.

Before transfer, checked unsigned arithmetic requires at least `2 * estimated_bytes + 1073741824` free bytes on the bound root for staging, unpublished copy, and the original 1 GiB reserve. Before durable copy, the same calculation subtracts already verified staging and already allocated unpublished bytes without double counting. Both checks must also fit within the global published budget. The default global published budget is the lesser of 1 TiB and 70% of the root volume capacity; its exact default/config source is part of the operator-owned cleanup contract. The projection reports total published, protected, and reclaimable bytes only through that approved contract.

### Publish-once durable artifact — macOS ordering

Destination identity is derived from the bound root and tuple hash. The unpublished sibling name is derived from transaction and attempt IDs and recorded in `active.json`; user input never supplies a path.

The exact publication sequence is:

1. Create and verify every regular file under the unpublished tree. For each file, write fully, verify canonical hash/size, call `fsync`, then `fcntl(F_FULLFSYNC)`, and close successfully.
2. Create a tuple-bound publication receipt inside the tree. Walk every directory bottom-up by descriptor; reject unexpected entries; call `fsync` then `F_FULLFSYNC` on every directory, ending with the unpublished-tree descriptor.
3. Persist private phase `publish_ready` in the authority root using its full-sync protocol.
4. Recheck cancellation, deadline, signed tuple, root binding, free-space/budget, destination absence, and active attempt.
5. Call `renameatx_np(source_parent_fd, unpublished_leaf, destination_parent_fd, final_leaf, RENAME_EXCL)`. No replace fallback is allowed. This exclusive rename is the visibility point, but not yet the durable-success point.
6. Call `fsync(destination_parent_fd)` and `fcntl(destination_parent_fd, F_FULLFSYNC)`. Successful completion is the sole durable publication linearization point.
7. Persist `publish_committed=true` and terminal private success under the authority root, including its file and parent full-sync barriers. Only after that completes emit public `succeeded`.

The artifact and authority roots may be on different filesystems. The protocol does not claim cross-filesystem atomicity. If failure/crash occurs before step 6 succeeds, no success is emitted; recovery validates either the recorded unpublished tree or exact final receipt/hash and retries the missing barrier. If step 6 succeeded but step 7 did not, recovery treats the final artifact as the source of truth, independently verifies it, durably repairs `active.json`, then allows the projection to report ready. If step 7 succeeded but the event was not emitted, a fresh projection reports ready; events are not replayed through a new status schema. A terminal record can never be used to report ready without re-opening the bound root and verifying the final artifact.

SIGKILL tests prove process ordering only. Stable-media claims require the reboot/power-loss-grade tests in the companion specification on real APFS volumes, including separate authority and artifact volumes.

### Crash and retry semantics

| Crash or barrier point | Recovery behavior |
|---|---|
| Before durable active record | No operation exists; dispatch starts normally. |
| After active record, during metadata/download/verification | Acquire the released flock; reopen only the saved root binding; remove recorded staging/resume/unpublished bytes; retry with a fresh attempt from byte zero. |
| During same-attempt transient transfer | The live worker may Range-resume only from its fully synced prefix and matching ETag. |
| Before exclusive rename | Exact cleanup/retry; no public crash state. |
| Rename visible, destination-parent barrier incomplete | Verify receipt/tree and retry the parent stable-media barrier; emit no success. |
| Destination-parent barrier complete, active state incomplete | Verify final artifact, durably repair private success, expose readiness through a fresh projection. |
| Active success durable, event absent | Fresh projection reports ready; do not replay an invented status/event protocol. |
| Existing destination mismatches | Preserve it, fail closed, and never repair or replace it. |
| Cleanup or deletion incomplete | Expose existing cleanup/action-unavailable signaling and resume only recorded objects under the saved root. |

### Published inventory and provider-confirmed cleanup

Automatic GC remains rejected. Inventory is bounded to 256 verified content-addressed published identities per root. Enumeration is descriptor-relative, accepts only the exact store grammar and publication receipt, accounts apparent and allocated bytes without following links, and fails the entire inventory closed on an unexpected object or count overflow. Projection totals are:

- `total_published_bytes`: all verified published identities;
- `protected_bytes`: the keep set;
- `reclaimable_bytes`: verified total minus protected;
- `global_budget_bytes`: the configured/default cap;
- `available_budget_bytes`: max(0, budget minus total).

The keep set is recomputed under the operation/adoption locks immediately before deletion and includes: the incumbent runtime identity; configured current artifact; every active or prepared adoption target; every selected/active preparation tuple and unpublished publication; every transaction with a live event worker; and the target being verified by the serving process. Identity comparison includes tuple hash, artifact hash, release/revision, and exact root binding.

After explicit provider confirmation, `cleanup_published_artifact` may select only one reclaimable immutable identity. It first renames the final leaf exclusively to a transaction-bound tombstone in the same parent, full-syncs the parent, records `deletion.json` durably, recursively unlinks only descriptor-verified contents, removes the tombstone, full-syncs the parent, clears the record, and refreshes inventory. A crash before rename leaves the artifact. A crash after rename resumes only the recorded tombstone under the original bound root. A keep-set race before rename aborts; adoption/serve cannot claim a tombstoned target. Rollback disables the action but preserves published data and any tombstone recovery capability.

## Preparation/adoption exclusion and readiness handoff

Preparation holds only the provider-UID preparation lock. Adoption takes that preparation lock first, then the existing `RecommendationAdoptionLock`, owner-only control socket, and runtime prepared/active reservation. Neither long-lived lock is held during an unrelated projection read. This preserves the outer exclusion order and prevents config, tuple, or root identity from changing beneath adoption without holding a multi-gigabyte transfer under runtime leases.

`prepareModelAdoptionRequest` retains its existing wire shape. The serving handler's new behavior is internal: when the requested target is absent from current in-memory authority, it reloads current signed feeds, validates signer/release/catalog bindings, resolves and descriptor-validates its own configured root, derives the content-addressed destination from signed identity, verifies the publication receipt's root identity against that open root, and hashes the final artifact. It treats the frame's existing target path and hash as claims to compare only after independent derivation; they never choose the root or destination. If the existing frame and signed feeds cannot identify the target without trusting the supplied path, implementation is blocked for operator disposition; slice 6 must not add a frame.

## Slices and deliverables

### Slice 6A — authority and ownership closure

- Land the single operator-owned SPEC-001/SPEC-044 patch from Dependency Gate 5.
- Record exact authority commit, owner, versions, grammar, capability, event codes, cleanup projection/version, and #1485 file ownership.
- Demonstrate the authority commit predates all 6B implementation commits.
- Run independent plan/SPEC review to zero Critical/High/Medium before 6B.

### Slice 6B — root-bound preparation and storage engine

- Private codecs, exact root binding, deterministic 64-entry selection, operation lock, cancellation marker, URLSession delegate/watchdog, verification, space/budget admission, durability barriers, recovery, bounded inventory, and tombstone cleanup.
- No public schemas beyond the approved projection/action extension and existing event stream.

### Slice 6C — CLI and Malibu surface

- Implement only the approved `models catalog-economics` invocation/cancel spelling.
- Render projection rows, storage totals, confirmations, SPEC-044 events, current #1485 operator copy, accessibility, old-client fallback, and refresh-after-terminal behavior.
- Malibu never reads local preparation files or derives status.

### Slice 6D — existing adoption handoff

- Extend the existing prepare-adoption handler to reload signed feeds and hash an absent target under an identical independently resolved root.
- Preserve the current request/result frame, adoption lock/journal, config rollback, load/drain/swap, and incumbent safety.

### Slice 7 — physical qualification and release

- Real signed feed, multi-shard MLX transfer, cancellation, custom-root/reboot recovery, incumbent traffic, adoption, discovery/admission journeys, correctly settled request, positive credit, signed app/CLI assets, byte-identity, notarization, and updater proof.

## Acceptance criteria

1. Only the existing catalog-economics projection and transaction event family expose prepare state; no status schema, transaction command family, public interrupted state, late-cancel enum, or new control frame exists.
2. The operator authority patch predates implementation and precisely freezes invocation, cancellation, event codes, and published cleanup exposure.
3. At most 64 actions are selected deterministically; unchanged IDs are prioritized without starving continuously eligible rows; dispatch races have one serialized outcome.
4. Every lifecycle record binds canonical root path, `st_dev`, `st_ino`, and root-identity digest; config/environment/root/volume changes cannot redirect recovery or deletion.
5. The production transfer observes cancellation/deadline every 250 ms, emits heartbeat within 10 seconds, never writes beyond the signed aggregate cap, and retains resume data only inside the live attempt.
6. Public `succeeded` is impossible before full tree sync, exclusive rename, destination-parent stable-media sync, and durable terminal local state.
7. Crash/reboot recovery is defined and tested at every barrier on same and separate APFS volumes; SIGKILL evidence is labeled process-only.
8. Preparation success leaves config, incumbent, admission, routing, economics, settlement, and secrets unchanged.
9. Serving independently reloads signed authority, proves identical root, and hashes the durable artifact through the existing adoption frame before readiness is accepted.
10. Published inventory is bounded and truthful; automatic GC does not run; confirmed cleanup cannot delete any keep-set identity and resumes exact tombstone deletion after crash.
11. The #1485 landed operator copy is rendered verbatim and wire earning state remains authoritative.
12. Final Build 1 acceptance still requires signed real-hardware discovery and admission journeys, a correctly settled request with positive credit, first listed-tier release evidence, and final signed release/updater proof.

## Compatibility, migration, and rollback

This is additive behind capability negotiation. Existing projections without the operator-approved transaction/cleanup capability continue unchanged. Old Malibu builds remain static. There is no migration from abandoned R21-R27 or v1 planning-state files; unrecognized private roots remain inert and are never auto-imported.

Rollback removes prepare/cleanup capability advertisement and UI controls. It does not delete published artifacts, staging, tombstones, or change config/runtime. A compatible CLI must remain able to finish exact recovery before full removal. Published artifacts remain inert unless separately adopted.

## Observability and privacy

Public output is limited to approved projection fields and event fields. Logs may contain transaction/attempt IDs, tuple hash, root-identity digest, phases, bounded counters, barrier names, and error codes. They must not contain canonical paths, usernames, home paths, URLs with credentials, tokens, prompts, completions, private feed bytes, or secret material.

Metrics include preparation duration/outcome by phase, cancellation observation latency, delegate callback size, cap cancellation, sync/rename failure, recovery branch, inventory totals/count, cleanup result, and root mismatch. Cardinality is bounded; raw model/repo/provider IDs are not metric labels.

## Hardware and release requirements

Unit and SIGKILL tests cannot establish stable-media durability, real MLX usability, serving continuity, settlement, codesigning, notarization, or updater behavior. Slice 7 must use final signed assets on supported Apple Silicon and real APFS volumes. Malibu.app and standalone tarball `macprovider-cli` binaries must be byte-identical after signing/packaging, and the previous stable release must update successfully.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Public contract drift | One operator-owned pre-6B patch; T18 ancestry proof; no locally invented schemas/frames/enums. |
| Custom-root redirection | Persist canonical path plus descriptor and random root identity; reopen saved path only; identical-root serving proof. |
| False durable success | Full tree sync, exclusive rename, destination-parent `F_FULLFSYNC`, durable active state, then event. |
| Cross-filesystem partial ordering | Artifact receipt is source of truth; recovery repairs authority state; no cross-filesystem atomicity claim. |
| Stable IDs starve new rows | Eight deterministic fairness slots with bounded wait and dispatch pinning. |
| Transfer ignores cancel/cap | Data delegate, 1 MiB quanta, 250 ms watchdog, immediate cancel-before-excess-write. |
| Published storage exhaustion | Global budget, bounded verified inventory, explicit reclaimable totals and provider-confirmed identity-safe cleanup. |
| Cleanup races adoption/serve | Recompute keep set under fixed lock order; same-parent tombstone; exact crash recovery. |
| Preparation implies earnings | Existing admission/economics owner specs and landed operator copy remain authoritative. |

## Qualification blockers

- The single authority patch is absent or does not predate 6B.
- Independent plan/SPEC or final implementation audit has any Critical, High, or Medium finding.
- Any custom-root lifecycle step depends on current environment/config rather than the saved binding.
- Any durable-success path omits a required file/directory/destination-parent stable-media barrier.
- Real throttled HTTP, 65/128/churn, unique-release budget, deletion-crash, or power-loss tests are missing.
- `JOURNEY-PROVIDER-BYOM-DISCOVERY`, `JOURNEY-NETWORK-MODEL-ADMISSION`, the first listed-tier release, settlement, signed assets, or updater evidence remains pending.

## Explicit non-goals and rejected designs

- No daemon/root helper/XPC service, SQLite/VFS, PID/heartbeat authority, signed local witness chain, or post-crash continuation.
- No `models transactions` command family, transaction status schema, public interrupted state, cancellation-too-late enum, or new authority-refresh frame.
- No coordinator, billing, routing, admission, payout, rate-card, or settlement mutation.
- No arbitrary URL/model download, app-side signature verification, or requester-authoritative path/hash.
- No automatic published-artifact GC, broad filesystem scan, path-based manual deletion, or `cleanup_staging` overload.
- No weakening of final signed physical-hardware and release gates.

## Finding disposition

| v1 finding | v2 disposition | Proving tests |
|---|---|---|
| B1-V1-H1 | Decision; Dependency Gates 4-6; Public state; Adoption handoff; Slice 6A | T01, T14, T18, T20 |
| B1-V1-H2 | Secure artifact-root binding; tuple; recovery; serving handoff | T04, T05, T08, T13 |
| B1-V1-H3 | macOS publish-once durability; cross-filesystem recovery | T07, T10, T21 |
| B1-V1-M1 | Deterministic selection above 64 and serialized dispatch | T02, T03 |
| B1-V1-M2 | Artifact bounds/budget; published inventory and confirmed cleanup | T09, T10, T16, T17 |
| B1-V1-M3 | URLSession transfer and cancellation contract | T06, T09, T21 |

## Evidence anchors

- `specs/SPEC-044-malibu-model-catalog-economics.md`
- `specs/SPEC-001-phase3-binary.md`
- `specs/AUTHORITY.json`
- `specs/CONFORMANCE.json`
- `audits/2026-09-11-byom-v02-handoffs/SLICE6_MALIBU_ACTIVATION_UX_HANDOFF.md`
- `audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md`
- `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift`
- `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift`
- `phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
- `phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift`
- `phase3-binary/Sources/macprovider-cli/RecommendationAdoptionJournal.swift`
- `docs/product-roadmap/build-1/reviews/reservation-rebaseline-plan-v1-sol.md`
