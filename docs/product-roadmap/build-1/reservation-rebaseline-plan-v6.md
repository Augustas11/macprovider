# Build 1 preparation-reservation rebaseline plan v6

Status: revised after the blocked preparation-authority v1 review; **blocked before slice 6B** until a corrected operator-owned authority patch satisfies every Dependency Gate 5 item and an independent review reaches zero Critical, High, and Medium findings.

Implementation baseline: `c4401f1791d593d37d68eba91af94219b26d278f` (BYOM v0.2 slice 6 operator state/copy). Planning/review baseline: `f7e584499828b3d16036382848b5caa1a897cdf9` (`origin/main` reviewed on 2026-09-11). Rejected authority candidate: `c42eea1ccfe637f0bfe3fa9939c18b26bd657434`.

Revision inputs: v5 plan SHA-256 `b20f502684856cf13e5f94e59a7fca9f64a7dd9981809e7d10a7e83934d67354`; v5 test-spec SHA-256 `d08f71feba48887a4dae446cb95b4cf874f93e0e53a5c7356dfbf8a8fe80c811`; blocking review `reviews/preparation-authority-v1-sol.md`. The v6 plan/test digests are recorded from their committed bytes at T18 rather than embedded recursively.

Authority: issue #1453 remains the execution queue. This document supersedes v5 as planning input. It does not approve, migrate, or reuse abandoned R21-R27 protocol or local development state.

## Decision

The initiating `malibu-cli` process remains the preparation worker. It owns one provider-UID-scoped, user-private authority root, holds one live kernel `flock` for the full operation, downloads and verifies only transaction-owned bytes, and publishes one immutable artifact into a dedicated v3 namespace. A second same-EUID CLI process may request cancellation through the capability-negotiated catalog-economics interface. There is no daemon, background service, database, PID authority, or post-crash worker continuation.

The worker is the sole producer and sequencer of `model_catalog_transaction_event.v1` events. The cancellation process emits no transaction event. It returns one separate, bounded, operator-approved cancellation acknowledgement whose only claim is whether an attempt-bound marker was durably recorded or the observed attempt was already terminal/inactive. Malibu continues consuming the worker stream and refreshes `models catalog-economics --json` for authoritative status.

The public read surface remains `malibu-cli models catalog-economics --json`. Schema selection is capability-exclusive: a v1-serving CLI advertises only `model_catalog_economics_v1`; a v2-serving CLI advertises only `model_catalog_economics_v2` plus `models catalog-economics.v2`. A dual advertisement or capability/token mismatch is invalid and falls back without invoking the ambiguous read. Public progress/results remain SPEC-044's `model_catalog_transaction_event.v1`. There is no transaction-status schema, `models transactions` command family, public crash state, late-cancellation enum, or authority-refresh frame.

Preparation ends at durable local readiness. It does not edit provider configuration, change the running model, change admission or routing, grant economics, submit an offer, or create settlement evidence. Adoption remains separate through the existing recommendation-adoption lock, journal, `prepareModelAdoptionRequest`, and warm swap. If the serving process lacks a prepared target, that existing handler independently reloads signed feed authority, resolves its own configured root and v3 namespace, and hashes the durable target before accepting it.

## Product outcome and boundary

The reservation subplan lets a provider prepare a qualified catalog artifact for local use before offer/admission when the operator-owned SPEC-044 R002/R003 amendment permits it, while presenting exact non-economic copy. It also retains the trusted-economics preparation path for rows whose admission/economics authority permits it. Both paths use the same verified bytes and local engine; their eligibility and presentation are explicitly distinct.

| Original Build 1 outcome | Current owner and status | Reservation-subplan contribution |
|---|---|---|
| Select a supported catalog model | Signed artifact-feed qualification is landed. | Deterministically reserve at most 64 exact preparation tuples with stable IDs and starvation-free rotation. |
| Guided prepare → evaluate → offer → adopt | #1485 requires a reachable pre-offer path; current SPEC-044 R002/R003 blocks money-motivated preparation without trusted economics. | Require an operator-owned locally motivated preparation class with exact eligibility/copy, or remove the action until authority permits it. |
| Prepare safely | Missing from baseline. | Same-EUID worker, isolated v3 namespace, secure roots, bounded transfer, cancellation, durability, recovery, inventory, and confirmed cleanup. |
| Understand pricing/admission | BYOM and SPEC-044/046/047 own truth and copy. | Local preparation never changes admission/economics and never uses money/demand as motivation. |
| One real Mac serves a correctly settled request | Slice 7 (#1486). | Supply verified bytes; readiness alone cannot pass Build 1. |

The state labels, meanings, earning-verdict-first order, and disclosure copy in `audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md` remain exact landed inputs.

## Authoritative guidance and preparation eligibility

The v2 row must carry the authoritative candidate disclosure without reconstruction. Each row adds required `candidate_id`; required `provider_guidance` with exactly the SPEC-046-R003 fields `state_label_key`, `state_meaning_key`, `next_action`, nullable `transition_reason_code`, and `earning_path_class`, using the owner-spec enums verbatim; and required closed `guidance_binding` with exactly `source_schema`, `source_sha256`, `source_generated_at`, nullable `source_projection_sequence`, nullable `source_coordinator_event_id`, `candidate_id`, `admission_source`, and `admission_state`. `source_schema` is `provider_byom_discovery.v1` for `local_default` or `model_admission_status.v1` for `coordinator`; `source_sha256` is lowercase SHA-256 over the exact validated source bytes, not a Malibu-generated join.

For `local_default`, `source_projection_sequence` is non-null and `source_coordinator_event_id` is null. For `coordinator`, `source_projection_sequence` is null and `source_coordinator_event_id` is the non-null event ID carried by the bound status. The row candidate ID, admission source/state/event, and all five guidance values must byte-for-byte equal the bound source. Checked wall-clock age at v2 generation and rendering must satisfy `0 <= catalog_generated_at - source_generated_at <= min(300 seconds, owner_source_max_age)`; a future source is invalid. A missing, stale, unknown, cross-candidate, cross-source, cross-event, cross-sequence, or digest-mismatched binding makes the row non-actionable and hides economics. Malibu renders the bound earning verdict and state disclosure before preparation/economics copy and must not infer either from admission state, model names, rates, or action availability. The operator patch must approve this exact shape or a demonstrably equivalent closed composition protocol before implementation.

The operator patch must freeze the following policy in SPEC-044 R002/R003 before implementation. A valid row must have the exact fresh candidate/guidance/source binding above, a current signed primary `mlx_safetensors` artifact whose `verification_status` is exactly `verified`, `fit: fits`, `runtime_state: needs_preparation`, non-null `action_model_id`, exact positive `estimated_bytes`, and no non-economic safety or storage block. `declared`, `blocked`, missing, unknown, or stale artifact verification fails before projection and again before dispatch.

| admission source/state | economics state | prepare classification | economics presentation | exact preparation copy |
|---|---|---|---|---|
| `local_default`: `local_only`, `not_offered`, `offerable` | `fallback`, `stale`, `blocked`, or `unavailable` | Locally motivated; `prepare_model` may be available when local prerequisites pass. | Hide rates, payouts, provider share, and demand motivation. Preserve the landed earning-verdict/state disclosure. | Label: **Prepare locally**. Detail: **Download and verify this model for local use. This does not offer it to the network or enable earnings.** Confirmation: **Download and verify {estimated_size} for local use?** |
| `local_default`: any state | `trusted` | Invalid projection combination. | Hide economics and disable Prepare. | Existing generic unsupported/action-unavailable copy only. |
| `coordinator`: `not_offered`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `withdrawn`, `revoked` | `fallback`, `stale`, `blocked`, or `unavailable` | Locally motivated; may be available only under the same local prerequisites and exact local copy. | Hide rates, payouts, provider share, and demand motivation. Preserve wire earning verdict and state disclosure. | Same **Prepare locally** label/detail/confirmation. |
| Those non-priced coordinator states | `trusted` | Invalid because `catalog_economics_permitted` is false. | Hide economics and disable Prepare. | Existing unsupported/action-unavailable copy only. |
| `coordinator`: `catalog_priced`, `settlement_capable` with `catalog_economics_permitted: true` | `trusted` | Existing money-motivated preparation rules apply. | SPEC-044 trusted rate presentation is allowed; settlement/earning copy still follows the wire state. | Operator-approved trusted-economics Prepare copy. |
| `coordinator`: `catalog_priced`, `settlement_capable` | `fallback`, `stale`, `blocked`, or `unavailable` | Only the locally motivated classification may be available under local prerequisites. | Hide/neutralize economics and demand for this action. | Exact **Prepare locally** copy above. |
| Any source/state mismatch, malformed admission, or inconsistent booleans | Any | Unavailable. | Hide economics. | Existing generic unsupported/action-unavailable copy only. |

This matrix covers every legal source/state/economics combination, including both `local_default:not_offered` and `coordinator:not_offered` and the transition between them. `trusted` either follows the permitted priced path or is invalid; all four non-trusted states use the same local classification when other local safety gates pass. The local action is not described as higher-paying, network-ready, offer-ready, admission progress, or earning. A reachable handoff is therefore `local_only`/either-source `not_offered`/`offerable` → **Prepare locally** → evaluate → offer → adopt, while admission/economics remain independently authoritative.

## Projection compatibility matrix

Capability advertisement is mutually exclusive because the public read spelling carries no version selector.

| Malibu | CLI advertisement | Required result |
|---|---|---|
| v1-only | v1 capability only | Invoke read; accept only `model_catalog_economics.v1`; no v2 run/cancel/cleanup. |
| v1-only | v2 capability plus exact v2 token only | Do not invoke catalog-economics; show existing static/current-model fallback. |
| v2-capable | v2 capability plus exact v2 token only | Invoke read; accept only `model_catalog_economics.v2`; permit only validated v2 actions. |
| v2-capable | v1 capability only | Invoke v1 read when supported; preserve v1 UI and expose no v2 action. |
| Any | both v1 and v2 capabilities, v2 without its token, token without v2, or any unknown/contradictory pair | Treat advertisement as invalid; do not invoke the ambiguous read or any mutation; use the existing fallback with the approved unavailable warning. |
| Any | neither supported capability | Do not invoke; use the existing silent legacy/static fallback. |

The authority patch must apply the same matrix to the local-status handshake and the built CLI's manifest. There is no environment variable, hidden argument, TTY inference, or optimistic decoder retry that selects a generation.

If @Augustas11 approves a different ordering or copy, the landed authority replaces this proposed matrix before 6B and both documents must be reconciled and re-reviewed. Slice 6 cannot choose silently.

## User journeys

### J1 — locally prepare before offer

1. Malibu obtains a fresh catalog-economics projection.
2. A valid pre-offer row exposes `prepare_model` under the locally motivated matrix and exact non-economic copy.
3. The provider confirms exact size and signed trust source.
4. Malibu invokes the operator-approved run mode under `models catalog-economics`; the attached worker emits the event stream.
5. The worker publishes durably into the v3 namespace and emits `succeeded` only after durable local state.
6. Malibu refreshes the projection, then the separate evaluate/offer/adopt transactions proceed under their owner specs. Preparation itself did not offer or enable earnings.

### J2 — cancel, fail, or recover

1. Malibu invokes the operator-approved cancellation mode.
2. The cancel process serializes marker mutation with `cancel.lock`, durably writes an attempt-bound marker when still applicable, and returns one bounded cancellation acknowledgement. It emits no transaction event.
3. The worker alone emits `cancel_requested` and `cancelled` before publication, or the existing terminal `succeeded`/`failed` after the commit point.
4. On crash, a later projection/invocation performs private recovery. No public crash state exists. Stale markers and uniquely named interrupted-write temporaries are reconciled under exact locks and identities.

### J3 — adopt after readiness

A fresh projection requalifies feeds and verifies the v3 artifact. The existing adoption request handler reloads signed feeds when authority is absent, independently derives its configured root/v3 destination, validates the root-bound receipt and hash, and responds through the existing frame. Requester path/hash claims do not select the target.

### J4 — inspect and reclaim storage

The approved projection reports v3 managed bytes and separately protected configured-legacy bytes. No automatic GC runs. A provider-confirmed published cleanup may tombstone only one reclaimable v3 identity after a durable deletion intent and keep-set recheck. Legacy artifacts are never imported, renamed, or deleted.

### J5 — old client or unavailable capability

Clients without the approved capability keep the existing fallback. Unknown schemas/enums or invalid matrix combinations disable only the affected action/row. They do not mutate the incumbent or fall through to legacy commands.

## Ownership and trust boundaries

| Component | Owns | Must not own |
|---|---|---|
| Projection builder | Signed authority, eligibility matrix, exact root/tuple, selection, readiness/accounting | Downloads, app heuristics, admission mutation |
| Worker | Operation lock, event sequence, transfer, staging, publication, terminal marker sweep | Background survival, config/runtime/admission/economics |
| Cancel process | Brief cancel lock, exact marker, bounded acknowledgement | Transaction events, worker kill, file deletion, terminal claims |
| Malibu | Confirmation, worker event rendering, cancel acknowledgement rendering, projection refresh | Event merging, filesystem reads, inferred eligibility/status |
| Serving CLI | Existing socket/frame, independent feed/root/destination/hash verification, adoption | Trusting requester path/hash, downloading during adoption |
| Cleanup worker | Durable intent, tombstone phase, exact delete/recovery | Automatic GC, legacy deletion, keep-set deletion |

The trust boundary remains the effective POSIX UID. Another UID fails ownership/mode and socket peer checks.

## Dependency gates

1. PR #1481 merged at `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a`; the first listed-tier release and `SPEC-023-R006` evidence remain pending.
2. #1485 operator state/copy landed at `c4401f1791d593d37d68eba91af94219b26d278f` and remains unchanged.
3. `JOURNEY-PROVIDER-BYOM-DISCOVERY` remains pending in CONFORMANCE despite the issue checkbox. Network admission/settlement evidence also remains pending.
4. Current SPEC-044 v0.1.1 does not authorize locally motivated pre-offer preparation, a cancellation acknowledgement, or published-artifact cleanup/accounting. `cleanup_staging` cannot be overloaded.
5. **Hard pre-6B authority gate:** @Augustas11 must land one narrowly scoped SPEC-001/SPEC-044 patch, with authority/index updates, that freezes: (a) exact run/cancel option spelling and mutually exclusive v1/v2 advertisement plus the complete compatibility matrix; (b) closed event error/warning codes and total error precedence; (c) R002/R003 locally motivated preparation eligibility, both-source `not_offered`, `verification_status: verified`, required verbatim `provider_guidance`, exact candidate/source/freshness correlation, exact operator-owned local/trusted copy, and economics/demand separation; (d) worker-only event sequencing plus the exact bounded cancellation-ack schema, request echo, total outcome precedence, nullability, and marker-race semantics; (e) the versioned projection/action/accounting contract for `cleanup_published_artifact`, bounded `cleanup_targets`, managed-v3 totals, configured-legacy protected totals, logical-byte accounting, truthful APFS copy, and exact budget policy; and (f) published and staging cleanup cancellation commit points plus intent/tombstone/remove recovery. It must retain `model_catalog_transaction_event.v1`, add no status or control-socket schema, and not overload `cleanup_staging`.
6. The same patch assigns SPEC-001 §6.14b stable requirement ID `SPEC-001-R003`, adds its pending CONFORMANCE entry, registers SPEC-001/Malibu as the applicable SPEC-044 consumer in AUTHORITY, and replaces the contradictory R005 hide-test mapping with an explicit gap plus the named future visible-local-preparation proof.
7. T18 proves this authority commit is a strict ancestor of the first 6B implementation commit. The revised plan and landed SPEC diff must pass fresh zero-C/H/M review before 6B.
8. Slice 7 remains the signed physical-hardware, discovery/admission, settlement, first-listed-release, signed-assets, and updater gate.

## Dependency graph

```text
landed feeds/#1481 + #1485 copy at c4401f17
                         |
                         v
6A operator patch: R002/R003 local Prepare matrix + invocation/events
 + cancel acknowledgement/sequencer + published cleanup/accounting
                         |
             +-----------+-----------+
             |                       |
             v                       v
6B v3 namespace/root/transfer   6C Malibu projection,
publish/inventory/cleanup       exact copy/events/cancel ack
             |                       |
             +-----------+-----------+
                         v
6D existing adoption handler independent reload/root/hash
                         |
                         v
slice 7 signed real-Mac journeys, settlement, release, updater
```

## Normative local contracts

All records below are private implementation state, not public CLI/control schemas.

### Authority root and artifact namespace

```text
~/.config/macprovider/model-preparation-v3/  0700
  operation.lock                            0600, live worker flock
  cancel.lock                               0600, marker/terminal serialization
  reservations.json                         0600, <=262144
  active.json                               0600, <=65536
  cancel.json                               0600, <=4096
  published-inventory.json                  0600, <=262144
  deletion.json                             0600, <=32768
  state-tmp/                                 0700, bounded unique write temps

<bound-artifact-root>/.macprovider-prepared-v3/ 0700
  root.identity                             0600, atomic complete record
  bootstrap-tmp/                            0700, bounded unique identity temps
  work/staging/<transaction>/<attempt>/     0700
  work/unpublished/<transaction-attempt>/   0700
  objects/<tuple-sha256>/                    immutable v3 publications only
  objects/.tombstone-<cleanup-transaction>/  same-parent deletion target only
```

The existing legacy layout outside `.macprovider-prepared-v3` is never treated as v3 inventory, imported, receipted, renamed, repaired, or deleted.

### Crash-safe root identity and private state writes

Every write uses a unique CSPRNG UUID leaf, such as `state-tmp/<record>.<writer-uuid>.tmp`, never a fixed temp. The temp contains record kind, target leaf, writer UUID, generation, complete payload, and payload SHA-256. It is descriptor-validated, fully written, `fsync`/`F_FULLFSYNC` synced, re-read, atomically renamed over the private target where replacement is allowed, then the parent is fully synced.

Recovery under `operation.lock` enumerates only the reserved temp directories, capped at 16 entries total and four per record kind. Names, owner, mode, type, link count, target kind, UUID, generation, and checksum must agree. A complete temp newer than the durable target may finish rename and parent sync; an incomplete/truncated temp is removed after descriptor validation; a valid durable target wins over equal/older temps. Unexpected names or objects fail closed as hostile, while recognized interrupted-write temps never permanently wedge the root. After reconciliation, excess recognized stale temps are removed deterministically.

`root.identity` is also atomic: create a uniquely named complete temp inside `bootstrap-tmp`, sync and validate it, exclusively rename to `root.identity`, then full-sync the namespace directory. If a crash leaves only a partial recognized temp, recovery removes it and retries. If it leaves a complete temp and no final, recovery completes the rename/barrier. If final exists and validates, it is authoritative and recognized temps are removed. If final is malformed, wrong-owner/type/link/mode, or conflicts with a complete temp identity, fail closed. Crash after rename simply repeats the directory barrier. No incomplete bytes are ever created at the final identity leaf.

### Secure artifact-root binding

At snapshot creation the builder resolves the existing config/environment root once, canonicalizes it, reopens every component without symlink traversal, and records canonical path, `st_dev`, `st_ino`, and root-identity digest in every reservation, active/selection/inventory/deletion record, receipt, and tuple. Crash recovery reopens only the saved canonical path and requires all identities; changed config/environment cannot redirect it. Serving independently resolves its configured root and verifies the receipt identity against the open descriptor.

### Reservation, tuple, and deterministic selection

The private v3 reservation and tuple retain all v2 target fields, signed primary MLX qualification, 1 TiB estimate cap, config/provider/root binding, binary framing, 64 selected entries, 256 history limit, deterministic `authority_order`, one active pin, eight oldest-wait fairness slots, unchanged-ID retention, bounded starvation, and serialized dispatch. At 257 eligible tuples Prepare is unavailable rather than silently truncated.

### Active operation and cancellation sequencing

`active.json` duplicates the full tuple/root binding and contains one attempt, private phase, counters, recorded paths, barrier progress, terminal result, and the worker's next event sequence. Public states remain only SPEC-044's seven states.

Marker protocol and locks:

1. The worker holds `operation.lock`. Only it allocates/increments event sequence and writes stdout events.
2. The cancel process takes `cancel.lock`, reads the bounded active record, and if the exact attempt is nonterminal writes/reuses the attempt-bound marker durably. It returns the approved acknowledgement and releases `cancel.lock`; it emits no event.
3. The proposed acknowledgement is a single JSON object capped at 4096 bytes with exact fields `schema`, `transaction_id`, nullable `attempt_id`, `outcome`, and `observed_at`; `schema` is `model_catalog_transaction_cancel_ack.v1`, and `transaction_id` must byte-for-byte echo the syntactically valid requested ID. The closed `outcome` values are `recorded`, `already_recorded`, `terminal`, `not_active`, and `stale`.
4. Under `cancel.lock`, after bounded recovery and validation, the cancel process applies this total first-match precedence: (1) a durable terminal active/history record for the requested transaction returns `terminal` with that record's non-null attempt ID; (2) a nonterminal active record for the requested transaction with an already-durable exact-attempt marker returns `already_recorded` with the active attempt ID; (3) a nonterminal active record for the requested transaction without that marker removes only a validated older marker, durably records the exact marker, and returns `recorded` with the active attempt ID; (4) any validated state proves that the requested transaction existed but is no longer the cancellable current attempt, including a different current attempt or mismatched prior-attempt marker, returns `stale`, with the stale attempt ID when safely known and otherwise null; (5) absence of matching active, terminal, reservation/history, or marker evidence returns `not_active` with null attempt ID. Malformed/unsafe state fails the command and emits no valid acknowledgement; it is never collapsed into `not_active`.
5. `recorded` means only durable marker custody, not worker observation or cancellation success. `already_recorded` means that exact marker was already durable. `terminal` means the exact attempt's durable terminal record won. `stale` means bounded durable state recognizes the transaction but not as the current cancellable attempt. `not_active` means no bounded durable state recognizes it. Only `not_active` always has null `attempt_id`; `stale` follows the known/unknown rule above; the other three are non-null. The operator patch must approve this exact predicate/precedence/nullability contract before implementation.
6. The worker checks the marker at the 250 ms watchdog and every bounded work loop. It emits `cancel_requested` once when cancellation wins before the transaction-specific commit point, then terminal `cancelled` only after the required reversible cleanup. After the commit point it emits only `succeeded` or `failed`.
7. Before terminal compaction/releasing `operation.lock`, the worker takes `cancel.lock`, durably commits terminal state, removes an exact matching marker, releases `operation.lock` while still holding `cancel.lock`, then releases `cancel.lock`. Thus a cancel process either writes before the terminal sweep or observes the released/terminal operation and does not leave a late marker.
8. A new attempt takes `operation.lock` then `cancel.lock`, validates and removes only a stale marker bound to the prior attempt, persists the new active record, and releases `cancel.lock`. A marker can never apply across attempts.

The cancellation acknowledgement is capped at 4096 bytes, contains no event sequence or terminal assertion, and is part of the future operator contract.

### URLSession transfer and enforceable byte bounds

Production uses an ephemeral serial `URLSessionDataDelegate`, direct descriptor writes to the attempt root, a 250 ms cancellation/deadline watchdog, and heartbeats at least every ten seconds. Same-attempt Range resume requires a fully synced prefix, private resume metadata, exact strong ETag, and Content-Range. New attempts restart from zero; URLSession opaque resume data is not retained.

The optional two-second cancellation qualification is precisely scoped and must be frozen by the authority patch if retained. Its monotonic start is completion of the cancel marker's parent full-sync; observation is the worker's validated marker read; transport cancellation is entry to `URLSessionTask.cancel()`; and completion is flush of terminal `cancelled` JSONL. The supported profile is a scheduled worker on supported Apple Silicon with a local APFS authority/staging volume, a metadata or stalled-transfer phase, no publication/tombstone, at most 8 MiB across 16 staging files, no injected syscall fault, every required sync completing within 250 ms, and no harness-induced scheduler suspension. Under that profile marker observation and `task.cancel()` must occur within 250 ms plus a declared 50 ms measurement tolerance, and terminal `cancelled` within 2.000 seconds of the start. Outside that profile only the 250 ms watchdog/loop check, heartbeat, action timeout, and truthful delayed-response behavior are normative; the worker must never emit terminal state before durable cleanup to meet timing.

The normative counters are distinct:

- `delegate_delivered_bytes`: bytes passed by URLSession to delegate callbacks; observed, may exceed the signed cap because transport/framework buffering is outside this design's control;
- `accepted_application_bytes`: the prefix admitted by the worker after cancellation/deadline/cap checks; MUST NOT exceed `estimated_bytes`;
- `staged_bytes`: successfully written transaction-owned bytes; MUST NOT exceed accepted bytes or `estimated_bytes`.

On a callback that would cross the aggregate cap, the worker accepts/writes only the remaining permitted prefix or none, immediately calls `task.cancel()`, discards later callback data, and fails without publication. Transport-received and server-sent byte metrics are observational only, carry no normative maximum, and cannot pass or fail correctness except to show test conditions. Content-Length excess still cancels before body acceptance when known.

### Artifact work bounds and space admission

Retain v2 limits: 4096 regular files/siblings, depth 32, 1024-byte relative paths, 131072-byte metadata, 1 MiB config, 16384-byte event line, no traversal/symlink/hardlink/special/sparse overflow/collision/cross-device entry, exact aggregate expected size, 8 MiB hash/copy chunks, and checked `2 * estimated_bytes + 1 GiB` free-space reserve. The operator patch freezes the v3 managed-storage budget, including checked formula boundaries and configuration precedence.

All displayed and budgeted prepared-data byte counts use one logical-byte algorithm. Starting from the already identity-checked root descriptor, walk only recorded relative descendants with no-follow descriptor operations, enforce the path/file/depth caps, require same-device owner-approved regular files with link count one, and add each accepted file's logical data-fork `st_size` exactly once using checked unsigned arithmetic. Directories contribute zero. Receipt and managed metadata regular files inside a v3 object are included; filesystem allocation blocks, directory implementation bytes, xattrs/resource forks, compression savings, and APFS clone sharing are excluded. Sparse, compressed, and cloned regular files are therefore charged by full logical `st_size`, subject to the same estimate and aggregate caps. A hard link, symlink, special file, mount crossing, overflow, race, or unstable descriptor identity makes managed inventory invalid or configured-legacy accounting unavailable before action dispatch. V3 published, reclaimable, action `estimated_bytes`, configured-legacy, charge, and available-budget values all derive from that same algorithm.

The UI calls this value **managed prepared data** and never promises physical capacity recovery. The exact cleanup confirmation source becomes **Remove this verified prepared model ({reclaimable_size} of managed data)? The current model and legacy model files will be kept.** Deleting an APFS clone or compressed file may free fewer physical bytes; filesystem admission separately reads current available capacity from the bound volume immediately before transfer and compares it to the checked free-space formula.

The default budget is exactly `min(1099511627776, floor(volume_capacity_bytes * 70 / 100))`, implemented with checked arithmetic that cannot overflow before division. A configured positive integer from `MACPROVIDER_MODEL_PREPARATION_BUDGET_BYTES` takes precedence over YAML `model_preparation_budget_bytes`; either configured value must be `1...1099511627776`, and an invalid higher-precedence value fails closed rather than falling through. The projection reports `managed_budget_source` from the selected valid source. Byte-budget admission requires checked `managed_budget_charge_bytes + estimated_bytes <= global_managed_budget_bytes`; free-space admission independently requires `available_capacity_bytes >= 2 * estimated_bytes + 1073741824`, all with checked unsigned arithmetic.

### Publish-once durable artifact and object-count admission

Publication occurs only under `.macprovider-prepared-v3/objects/<tuple-sha256>`. The 256-object ceiling is an admission invariant. Under the common operation/cleanup lock, before any network transfer the worker performs a bounded inventory read and classifies the target as an exact existing identity, a new identity with a free count slot, or refused. An exact existing identity may proceed idempotently. A new identity is allowed only when the verified object count is at most 255; its active record durably reserves that one slot while the worker retains the lock. At 256 objects, a new identity fails before network or staging side effects.

Immediately before exclusive rename, the worker repeats the bounded inventory and exact-target check under the same retained lock. The reserved publication may create only the 256th object. If an external same-UID mutation consumed the slot, or inventory is malformed/overfull, publication fails closed and preserves the unpublished tree for exact recovery; it never creates a 257th object. Cleanup uses the same lock, so cleanup and publication serialize without a count race.

After count admission, publication retains the exact v2 durability sequence: fully verify and `fsync`/`F_FULLFSYNC` every file; write receipt; bottom-up sync directories; durably record publish-ready; revalidate authority/root/cancel/byte budget/object slot; exclusive `renameatx_np(..., RENAME_EXCL)` from v3 unpublished to v3 objects; `fsync` and `F_FULLFSYNC` destination parent; durably persist terminal success; then emit `succeeded`. Cross-filesystem authority recovery uses the verified v3 receipt as source of truth. SIGKILL is process-only evidence; abrupt-power qualification remains required.

### V3 inventory and configured legacy protection

Inventory enumerates only `.macprovider-prepared-v3/objects`, capped at 256 exact receipts. The v2 projection also carries a required closed top-level `cleanup_targets` array with at most 256 entries, deterministically ordered by lowercase `artifact_identity_digest`. It contains every verified managed v3 identity observed by the bounded inventory, including objects with no current catalog row. Each entry has exactly `artifact_identity_digest`, `display_model_id`, `model_revision`, `artifact_id`, `release_id`, nullable current `model_key`, `root_identity_digest`, `receipt_sha256`, exact logical `estimated_bytes`, `keep_set_status`, nullable `protected_reason`, and `cleanup`. The two digests are lowercase 64-hex; `keep_set_status` is `protected` or `reclaimable`; `protected_reason` is required exactly for `protected`; and `cleanup` uses the v2 action shape. A reclaimable entry has one available `cleanup_published_artifact` action carrying the same artifact digest and bytes; a protected entry has an unavailable action and exact reason. Missing/stale receipt identity, malformed inventory, or overflow makes the array empty/unavailable with the storage totals and actions fail closed. Row cleanup actions, if retained, must be identical projections of the corresponding top-level entry; absence from the current signed catalog never makes a reclaimable v3 identity unreachable. The operator patch must approve these exact fields/enums or an equivalently closed bounded target contract before implementation.

Storage projection separates:

- `managed_v3_published_bytes` and `managed_v3_reclaimable_bytes`;
- `configured_legacy_protected_bytes`, measured descriptor-relatively from the configured incumbent/draft artifact trees outside the v3 namespace;
- `managed_budget_charge_bytes = managed_v3_published_bytes + same-volume configured_legacy_protected_bytes`;
- global budget and available managed budget.

Configured legacy artifacts are always protected from v3 cleanup, even when accounting is unavailable. Same-volume verified configured legacy bytes charge the managed budget; configured legacy bytes on another device are reported separately and do not charge the v3-root budget. Any unconfigured legacy object remains unmanaged: v3 does not enumerate, import, modify, or delete it. Filesystem free-space checks naturally include all legacy/unmanaged consumption. A malformed or unmeasurable configured legacy tree makes its protected accounting unavailable, sets both legacy byte fields plus charge and available budget to null, and blocks projected Prepare, direct preparation dispatch before network/staging, and published cleanup. It never blocks incumbent serving or causes deletion.

Mixed legacy/v3 roots therefore remain usable: v3 inventory cannot fail on a normal legacy sibling because it never enumerates outside its namespace. Rollback ignores but preserves the v3 namespace; re-upgrade validates it in place without importing legacy.

An externally seeded overflow is corruption, not a state production may create. Inventory reads at most 257 entries solely to detect `count > 256`; they do not claim that the 257th observed entry is the last entry. Any detected overflow disables preparation and all published cleanup and requires out-of-band operator diagnosis. Production does not truncate, guess, or expose a repair action for an overfull namespace. This exceptional corruption path is distinct from ordinary provider recovery and must never be represented as a successful or recoverable product state.

### Provider-confirmed published cleanup

Automatic GC remains rejected. Cleanup targets one reclaimable v3 identity only. The exact deletion sequence is:

1. Under fixed locks, recompute the keep set and derive exact final/tombstone leaves.
2. Persist and full-sync `deletion.json` with `phase: intent`, cleanup transaction, tuple/receipt/root identity, final leaf, tombstone leaf, and expected byte/file totals **before rename**.
3. Recompute the keep set. If target became protected, durably clear intent and stop.
4. Exclusively rename the exact v3 final leaf to its reserved tombstone sibling in the same `objects` parent; full-sync that shared parent.
5. Update and full-sync `deletion.json` to `phase: tombstoned` only after the parent barrier.
6. Descriptor-validate and unlink recorded tombstone contents, remove the tombstone, full-sync its parent, update `phase: removed`, then durably clear the record and refresh inventory.

Recovery never scans or guesses. With `intent`: final present/tombstone absent means recheck keep set then resume or clear; final absent/tombstone present means repeat the parent barrier and advance to `tombstoned`; both present or both absent fails closed. With `tombstoned`: tombstone present resumes deletion; tombstone absent/final absent repeats parent sync then advances to `removed`; final present fails closed. With `removed`: both absent permits record clear; any target present fails closed. Every step reopens the saved root only. Legacy paths are invalid cleanup targets.

For published cleanup, the commit point is the final-to-tombstone rename followed by successful `fsync` and `F_FULLFSYNC` of the shared `objects` parent. Before that barrier, cancellation wins: if no rename occurred, clear intent; if the rename occurred but its parent barrier has not committed, rename the descriptor-validated tombstone back to the exact final leaf, fully sync the parent, clear intent, and emit `cancel_requested` then `cancelled`. After that barrier, cancellation cannot produce `cancelled`; the worker or recovery must advance through `tombstoned` and `removed`, complete exact deletion, and emit/return `succeeded`, or retain recoverable state and fail with `cleanup_failed`. A crash at `intent` with final absent/tombstone present consults the exact-attempt durable cancel marker: a matching pre-commit marker restores final; absent/nonmatching cancellation repeats the parent barrier and commits tombstoning. Recovery never reports cancellation after the durable tombstone barrier.

`cleanup_staging` has an independent recorded target and uses the same reversible intent → same-parent tombstone → removed discipline inside the attempt's staging parent. Its commit point is its tombstone rename plus parent full-sync. Cancellation before that point preserves or restores the incomplete staging tree, retains `staging_cleanup_required`, and ends `cancelled`; cancellation after that point completes removal and ends `succeeded` or recoverable `cleanup_failed`, never `cancelled`. A staging cleanup record cannot name a published, legacy, different-attempt, or different-root object, and published cleanup cannot name staging.

### Crash and retry semantics

Preparation crash recovery retains v2 semantics: no byte continuation after process death, exact saved-root cleanup, same-attempt live Range resume only, retry from zero on new attempt, recovery of rename/parent/active/event boundaries, preservation of conflicting destinations, and fresh projection as status. It additionally reconciles recognized unique temps, root bootstrap, cancel markers, and both cleanup kinds' phased intent/tombstone/remove records without permanent wedges. Retry resumes only the recorded transaction/root/target/phase; it never creates a second tombstone or reinterprets the current config.

## Preparation/adoption exclusion and readiness handoff

Lock order remains preparation `operation.lock` → `RecommendationAdoptionLock` → owner-only control socket → runtime reservation. Preparation holds no runtime lease during transfer. The existing adoption frame remains unchanged; the serving handler reloads signed feeds, independently derives its configured v3 destination, validates the receipt/root/hash, and treats frame path/hash only as claims.

## Slices and deliverables

### Slice 6A — authority and ownership closure

Land the single complete operator patch from Gate 5, including `SPEC-001-R003`, mutually exclusive version advertisement, required verbatim guidance binding, exhaustive R002/R003 matrix/copy, cancellation acknowledgement/sequencer, cleanup targets/accounting, and both cleanup state machines. Record exact versions/commit/owner and prove strict ancestry. Re-review this v6 plan/test plus SPEC diff to zero C/H/M.

### Slice 6B — private preparation/storage engine

Implement secure roots and unique-temp recovery, bounded selection, worker/cancel locks, transfer counters, v3 namespace, durable publication, logical-byte/legacy accounting, bounded cleanup targets, and intent-first cleanup with exact cancellation/recovery.

### Slice 6C — CLI and Malibu surface

Implement only approved grammar/schemas. Render authoritative guidance first, exact local/trusted preparation and truthful cleanup copy, worker events, cancellation acknowledgement, projection refresh, storage accounting/targets, confirmation, accessibility, and version fallback. Test the built CLI through Malibu's production process adapter and strict decoder.

### Slice 6D — existing adoption handoff

Extend only handler behavior for independent feed/v3-root/hash reload while preserving the current frame, journal, rollback, load/drain/swap, and incumbent safety.

### Slice 7 — physical qualification and release

Retain real MLX, throttled transfer, custom-root/APFS power recovery, incumbent traffic, adoption, signed journeys, settlement/positive credit, first listed tier, signed/notarized assets, byte identity, and updater proof.

## Acceptance criteria

1. The authority patch makes pre-offer local preparation reachable and conforming through required verbatim `provider_guidance`, exact candidate/source/freshness binding, `verification_status: verified`, both-source `not_offered`, exact copy, and economics separation across every legal admission/economics combination.
2. V1/v2 advertisement is mutually exclusive and every old/new Malibu/CLI combination has one deterministic read or fallback result; ambiguous capability/token sets cause no invocation.
3. Worker alone sequences transaction events; cancellation returns only the approved bounded acknowledgement with request echo, total outcome precedence, exact nullability, and no late/terminal/new-attempt marker effect.
4. Unique validated temps and atomic root bootstrap recover every ordinary crash without permanent wedge.
5. URLSession guarantees only accepted/staged byte caps; cancellation observation and `task.cancel()` meet the 250 ms contract, and the optional two-second terminal bound applies only to the frozen supported profile with exact clocks, data limits, sync limits, and tolerance; delegate-delivered, transport, and server metrics are explicitly separated.
6. V3 publications/inventory stay inside the dedicated namespace; logical-byte accounting is deterministic; APFS copy does not promise physical recovery; every reclaimable object is reachable through bounded `cleanup_targets`; configured legacy artifacts are protected/accounted and no legacy object is imported or deleted.
7. Published and staging deletion intent is durable before rename, the tombstone barrier is the exact commit point, phase follows that barrier, and cancellation/crash/retry at every boundary has one exact non-scanning outcome.
8. Budget default, rounding, precedence, invalid overrides, checked arithmetic, and byte/free-space threshold behavior are exact; unavailable legacy accounting blocks projection and direct dispatch before side effects.
9. `SPEC-001-R003`, AUTHORITY consumers, R005 CONFORMANCE gaps/evidence, versions, indexes, and review lineage agree.
10. Built-CLI bytes traverse Malibu's production adapter/decoder for reads, run terminals, cancellation acknowledgements, chunking, exit/stderr handling, and compatibility negatives.
11. All v2 root, selection, durability, resource, incumbent, authority, adoption, compatibility, privacy, and final hardware/release gates remain in force.

## Compatibility, migration, and rollback

No old state or legacy artifact is imported. Existing configured legacy incumbent/draft trees remain in place and are protected/accounted separately. Upgrade creates the v3 namespace beside them. Rollback removes capability/UI exposure, preserves v3 and legacy bytes plus recovery state, and never runs GC. Re-upgrade validates the v3 namespace and resumes exact recovery.

## Observability and privacy

Worker event sequencing, cancel acknowledgements, transfer counter classes, temp recovery, root bootstrap, namespace inventory, legacy accounting, and deletion phases are logged through bounded redacted codes/counters. Paths, usernames, credentials, feed bodies, prompts, completions, and raw errors are excluded. Transport/server byte counts are labeled observational.

## Hardware and release requirements

Unit/SIGKILL tests cannot prove stable-media durability, real MLX usability, serving continuity, settlement, signing, notarization, or updater behavior. Slice 7 uses final signed assets on supported Apple Silicon and real APFS volumes, including abrupt-power cases. App/tarball CLI binaries must be byte-identical after packaging.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Pre-offer Prepare contradicts economics authority | Operator-owned R002/R003 matrix and exact non-economic copy before 6B. |
| Malibu derives or mis-correlates earning guidance | Required verbatim SPEC-046 guidance plus exact candidate/source/digest/freshness binding. |
| Old/new client schema confusion | Mutually exclusive v1/v2 advertisement and full production compatibility matrix. |
| Orphan tombstone after crash | Durable intent before rename and post-parent-barrier phase update. |
| Cleanup cancellation reports success after destructive ambiguity | Exact published/staging commit points and intent/tombstone/remove recovery table. |
| Bootstrap/temp crash wedges root | Unique self-identifying temps, bounded recovery, atomic final identity. |
| Unenforceable network-read claim | Normative accepted/staged caps only; transport/server counts observational. |
| APFS clone/compression makes cleanup copy false | Report logical managed data only; never promise physical recovered capacity. |
| Legacy store blocks or is deleted | Dedicated v3 namespace; configured legacy protection/accounting; no import/delete. |
| Event sequence split across processes | Worker sole sequencer; cancel returns separate approved acknowledgement under cancel lock. |
| Ordinary publication exceeds inventory cap | Count admission before transfer and rename under the shared operation/cleanup lock; exact idempotence only at 256. |
| Prior root/durability/resource regressions | All v2 gates retained and dispositioned in tests. |

## Qualification blockers

- Authority patch omits any guidance binding, version matrix, verified-artifact gate, matrix/copy, cancel acknowledgement/precedence/sequencer, invocation/event precedence, cleanup target/accounting/state-machine contract, governance mapping, or does not predate 6B.
- Any recognized interrupted temp/root bootstrap or deletion boundary can permanently wedge or require scanning/guessing.
- Any correctness claim bounds server/transport bytes under URLSession.
- V3 code inventories, imports, renames, receipts, or deletes a legacy object.
- A normal publication can create object 257, or count admission is not serialized with cleanup.
- Any reclaimable v3 identity lacks a bounded projected cleanup target because its catalog row disappeared.
- Any malformed configured legacy state permits projected or direct preparation dispatch.
- Any acceptance test uses a hand-authored projection in place of the required built-CLI-to-production-Malibu boundary proof.
- Any prior custom-root, selection, APFS durability, keep-set, real HTTP, final signed journey/settlement/first-listed-release/release/updater gate is weakened or missing.

## Explicit non-goals and rejected designs

- No daemon/helper/XPC/database/PID/witness chain/post-crash worker continuation.
- No transaction status schema, `models transactions` family, public crash/late-cancel enum, or new control frame.
- No cancellation event from the cancel process and no cross-process event sequence allocator.
- No automatic GC, legacy import/migration/receipt retrofit, legacy deletion, broad scan, or `cleanup_staging` overload.
- No server-sent or transport-read byte maximum claim under URLSession.
- No admission/economics/routing/settlement mutation and no weakening of final signed gates.

## Finding disposition

| v2 finding | v3 section | Proving tests |
|---|---|---|
| B1-V2-H1 | Preparation eligibility and copy matrix; Dependency Gate 5 | T16, T18 |
| B1-V2-M1 | Provider-confirmed cleanup intent/phase/recovery | T10 |
| B1-V2-M2 | Crash-safe root identity and private state writes | T01, T04, T08 |
| B1-V2-M3 | URLSession transfer and enforceable byte bounds | T06, T09, T21 |
| B1-V2-M4 | Authority namespace; v3 inventory and configured legacy protection | T09, T10, T17, T21 |
| B1-V2-M5 | Active operation and cancellation sequencing | T03, T06, T14 |
| B1-V3-M1 | Publish-once object-count admission; fail-closed external overflow | T09, T10 |
| B1-AUTH-H1 | Authoritative guidance and preparation eligibility | T01, T05, T15, T16, T18 |
| B1-AUTH-H2 | Projection compatibility matrix | T01, T14, T15, T18 |
| B1-AUTH-M1/M2 | Exhaustive matrix and verified artifact prerequisite | T05, T16 |
| B1-AUTH-M3 | Total cancellation acknowledgement predicates | T03, T14 |
| B1-AUTH-M4 | Published/staging cleanup commit and recovery | T10 |
| B1-AUTH-M5/M6 | Logical-byte algorithm, truthful copy, bounded cleanup targets | T09, T10, T16, T21 |
| B1-AUTH-M7 | SPEC-001-R003 and governance alignment | T18 |
| B1-AUTH-M8 | Built CLI through production Malibu boundary | T14, T15, T19 |
| B1-AUTH-M9/M10 | Exact budgets and unavailable-legacy blocking | T09 |
| B1-AUTH-M11 | Exact localized size boundaries | T16 |
| B1-AUTH-M12 | Authority-bounded cancellation timing only | T06 |
| B1-AUTH-M13 | Table-driven event-error precedence | T14 |

Prior v1 corrections remain covered: authority/no invented status or refresh protocol (T01/T14/T18), custom roots (T04/T05/T08/T13), APFS durable ordering (T07/T10/T21), bounded fair selection (T02/T03), published storage (T09/T10/T16/T17), and production cancellation (T06/T09/T21).

## Evidence anchors

- `docs/product-roadmap/build-1/reviews/reservation-rebaseline-plan-v2-sol.md`
- `docs/product-roadmap/build-1/reviews/preparation-authority-v1-sol.md` (reviewed from the authority worktree at candidate `c42eea1c`)
- `specs/SPEC-044-malibu-model-catalog-economics.md`
- `specs/SPEC-001-phase3-binary.md`
- `specs/AUTHORITY.json`
- `specs/CONFORMANCE.json`
- `audits/2026-09-11-byom-v02-handoffs/SLICE6_MALIBU_ACTIVATION_UX_HANDOFF.md`
- `audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md`
- `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift`
- `phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift`
- `phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
