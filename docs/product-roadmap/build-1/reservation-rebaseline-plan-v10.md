# Build 1 preparation-reservation rebaseline plan v10

Status: revised after the blocked preparation-authority v5 review; **blocked before slice 6B** until the operator-owned authority and these v10 planning bytes satisfy every Dependency Gate 5 item and an independent review reaches zero Critical, High, and Medium findings. This revision does not claim that gate passed.

Implementation baseline: `c4401f1791d593d37d68eba91af94219b26d278f` (BYOM v0.2 slice 6 operator state/copy). Planning/review baseline: `f7e584499828b3d16036382848b5caa1a897cdf9` (`origin/main` reviewed on 2026-09-11). Authority revision reviewed by v5: `4196d6d9850632386130b6d658325632e4d80b38`; formal v5 review artifact commit: `02faf9a2bc47189e83894826183a12a76719a45d`.

Revision inputs: v9 plan SHA-256 `217db6fbabc76433004ee835cfb8846099d0855132cf141e2c91a3e051d8a90d`; v9 test-spec SHA-256 `245d1fd3652a5e445b525c2567517cc51e80b8e4437a91ce5e375784268d92c2`; blocking review `reviews/preparation-authority-v5-sol.md`, SHA-256 `7566693203c38f8684268c9b3665384cfce5639f90cf6a1ec8582f52e86659dd`. The v10 plan/test digests are recorded from their committed bytes at T18 rather than embedded recursively.

Authority: issue #1453 remains the execution queue. This document supersedes v9 as planning input. It does not approve, migrate, or reuse abandoned R21-R27 protocol or local development state.

## Decision

The initiating `malibu-cli` process remains the preparation worker. It owns one provider-UID-scoped, user-private authority root, holds one live kernel `flock` for the full operation, downloads and verifies only transaction-owned bytes, and publishes one immutable artifact into a dedicated v3 namespace. A second same-EUID CLI process may request cancellation through the capability-negotiated catalog-economics interface. There is no daemon, background service, database, PID authority, or post-crash worker continuation.

The worker is the sole producer and sequencer of `model_catalog_transaction_event.v1` events. The cancellation process emits no transaction event. It returns one separate, bounded, operator-approved cancellation acknowledgement whose only claim is whether an attempt-bound marker was durably recorded or the observed attempt was already terminal/inactive. Malibu continues consuming the worker stream and refreshes `models catalog-economics --json` for authoritative status.

The public read surface remains `malibu-cli models catalog-economics --json`. Schema selection is capability-exclusive and pair-complete: v1 is exactly `model_catalog_economics_v1` plus `models catalog-economics.v1`; v2 is exactly `model_catalog_economics_v2` plus `models catalog-economics.v2`. Capability-only, token-only, dual-generation, conflicting, unknown, or manifest/local-status-disagreeing advertisements are invalid and fall back without invoking the ambiguous read. Public progress/results remain SPEC-044's `model_catalog_transaction_event.v1`. There is no transaction-status schema, `models transactions` command family, public crash state, late-cancellation enum, or authority-refresh frame.

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

The state labels, meanings, earning-verdict-first order, and disclosure copy in `audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md` remain exact landed inputs except for the three exact corrections in this section that the operator-owned authority must land before implementation. The `settlement_capable` verdict is exactly **Eligible to earn on qualifying settled requests**. The `local_only` meaning is exactly **Retained as local inventory only; this admission state does not claim the model is prepared, installed, ready, reachable, or usable.** The former states conditional eligibility only; the latter states admission only. Neither may be rendered, localized, announced, or logged as evidence of current income, current traffic, an accepted request, a qualifying settled receipt, installation, readiness, or usability. Installation and usability require independently validated readiness/runtime evidence. The third correction is the source-aware pair of exact `not_offered` meanings below.

## Authoritative guidance and preparation eligibility

Candidate identity and guidance are an all-or-none group. A candidate-associated row carries non-null `candidate_id`; `provider_guidance` with exactly the SPEC-046-R003 fields `state_label_key`, `state_meaning_key`, `next_action`, nullable `transition_reason_code`, and `earning_path_class`, using owner enums verbatim; and closed `guidance_binding` with exactly `source_schema`, `source_sha256`, `source_generated_at`, nullable `source_projection_sequence`, nullable `source_coordinator_event_id`, `candidate_id`, `admission_source`, and `admission_state`. A signed-catalog-only row absent from discovery carries all three as null, uses `runtime_state: catalog` and null `action_model_id`, exposes no candidate action/guidance or local-readiness claim, and may remain visible only in the exact R008 `Blocked` section. Without the evidence required by R008 for another section, it must never render in `Network catalog`, `Current`, `Ready`, or `Needs preparation`; its signed-catalog provenance does not confer current network-catalog, readiness, or preparation evidence. It must use exactly `economics_state: unavailable`, `rate_source: none`, and the conservative admission sentinel `source: local_default`, `state: not_offered`, null `coordinator_event_id`, null `state_observed_at`, `catalog_economics_permitted: false`, and `settlement_capable: false`. Every rate-card identity, catalog rate, provider-share, payout, and demand field is null; every candidate action is unavailable with null kind/ID/timeout and a nonempty exact reason. Any alternate economics state, rate source, admission source/state, non-null event/time, true authorization boolean, or non-null money/demand value makes the projection malformed. No model key, display name, served-model ID, artifact ID, or feed-row similarity may borrow admission or economics evidence from another candidate. Any partial group is malformed. Every candidate-associated row and every Prepare/Evaluate/Adopt/Switch action requires the complete non-null group at projection and dispatch; catalog-only rows must never fabricate a candidate or guidance source.

For `local_default`, `source_schema` is `provider_byom_discovery.v1`, `source_projection_sequence` is non-null, and `source_coordinator_event_id` is null. For `coordinator`, `source_schema` is `model_admission_status.v1`, `source_projection_sequence` is null, and `source_coordinator_event_id` exactly mirrors the bound response: it may be null only when the authoritative admission state is exactly `not_offered` and that response contains no event; it is non-null for event-backed `not_offered` and every other coordinator state. The exact response digest, candidate, source, state, nullable event, and all five guidance values bind together; a null no-offer event must not be synthesized. `source_sha256` is lowercase SHA-256 over the exact validated source bytes, not a Malibu-generated join. Checked wall-clock age at v2 generation and rendering must satisfy `0 <= catalog_generated_at - source_generated_at <= min(300 seconds, owner_source_max_age)`; a future source is invalid. A missing, stale, unknown, cross-candidate, cross-source, cross-event, cross-sequence, or digest-mismatched candidate binding makes the row non-actionable and hides economics. Malibu renders the operator-owned verdict mapped from the bound `earning_path_class` and the bound state disclosure before preparation/economics copy and must not infer either from admission state, model names, rates, action availability, or observed traffic. The `settlement_capable` mapping is exactly **Eligible to earn on qualifying settled requests**; all other owner verdict mappings remain unchanged. The operator patch must approve this exact shape and exact copy before implementation.

The operator-owned English source meaning for `local_default:not_offered` is exactly **Coordinator offer state is unavailable or has not been queried.** It says nothing about prior offer history. The English source meaning for `coordinator:not_offered` is exactly **Coordinator reports no active network offer for this model.** It states only the authoritative current readback. Provider-facing renderers, localizations, accessibility labels, logs, and action summaries must preserve that source distinction, must not use **never offered**, and must not swap either sentence across sources.

The operator patch must freeze the following policy in SPEC-044 R002/R003 before implementation. An actionable candidate row must have the exact fresh candidate/guidance/source binding above, a current signed primary `mlx_safetensors` artifact whose `verification_status` is exactly `verified`, `fit: fits`, `runtime_state: needs_preparation`, non-null `action_model_id`, exact positive `estimated_bytes`, and no non-economic safety or storage block. `declared`, `blocked`, missing, unknown, or stale artifact verification fails before projection and again before dispatch.

| admission source/state | economics state | prepare classification | economics presentation | exact preparation copy |
|---|---|---|---|---|
| `local_default`: `local_only`, `not_offered`, `offerable` | `fallback`, `stale`, `blocked`, or `unavailable` | Locally motivated; `prepare_model` may be available when local prerequisites pass. | Hide rates, payouts, provider share, and demand motivation. Preserve the corrected operator-owned earning-verdict/state disclosure. | Label: **Prepare locally**. Detail: **Download and verify this model for local use. This does not offer it to the network or enable earnings.** Confirmation: **Download and verify {estimated_size} for local use?** |
| `local_default`: any state | `trusted` | Invalid projection combination. | Hide economics and disable Prepare. | Existing generic unsupported/action-unavailable copy only. |
| `coordinator`: `not_offered`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `withdrawn`, `revoked` | `fallback`, `stale`, `blocked`, or `unavailable` | Locally motivated; may be available only under the same local prerequisites and exact local copy. | Hide rates, payouts, provider share, and demand motivation. Preserve the corrected operator-owned earning verdict and bound state disclosure. | Same **Prepare locally** label/detail/confirmation. |
| Those non-priced coordinator states | `trusted` | Invalid because `catalog_economics_permitted` is false. | Hide economics and disable Prepare. | Existing unsupported/action-unavailable copy only. |
| `coordinator`: `catalog_priced`, `settlement_capable` with `catalog_economics_permitted: true` | `trusted` | Existing money-motivated preparation rules apply. | SPEC-044 trusted rate presentation is allowed. `settlement_capable` renders exactly **Eligible to earn on qualifying settled requests** and never a current-income claim. | Operator-approved trusted-economics Prepare copy. |
| `coordinator`: `catalog_priced`, `settlement_capable` | `fallback`, `stale`, `blocked`, or `unavailable` | Only the locally motivated classification may be available under local prerequisites. | Hide/neutralize economics and demand for this action. | Exact **Prepare locally** copy above. |
| Any source/state mismatch, malformed admission, or inconsistent booleans | Any | Unavailable. | Hide economics. | Existing generic unsupported/action-unavailable copy only. |

This matrix covers every legal source/state/economics combination, including both `local_default:not_offered` and `coordinator:not_offered` and the transition between them. `trusted` either follows the permitted priced path or is invalid; all four non-trusted states use the same local classification when other local safety gates pass. The local action is not described as higher-paying, network-ready, offer-ready, admission progress, or earning. A reachable handoff is therefore `local_only`/either-source `not_offered`/`offerable` → **Prepare locally** → evaluate → offer → adopt, while admission/economics remain independently authoritative.

The closed admission inventory contains exactly 12 values: `local_only`, `not_offered`, `offerable`, `offer_submitted`, `offer_rejected`, `sandbox_probe_only`, `network_visible_unpriced`, `network_admitted_unsettled`, `catalog_priced`, `settlement_capable`, `withdrawn`, and `revoked`. `local_default` may author only `local_only`, `not_offered`, and `offerable`; coordinator readback owns the network states and may also author its exact `not_offered` case. An unknown or purported thirteenth value is malformed.

### Locale-independent total row ranking

Before rendering, Malibu rejects a projection containing a duplicate canonical row identity. Duplicate `model_key` alone is not the predicate: two candidate rows may share a model key when their candidate identities differ. Malibu sorts every accepted row by the exact operator-owned SPEC-044-R005 tuple, in order:

1. R008 section rank ascending: `Current` = 0, `Ready` = 1, `Network catalog` = 2, `Needs preparation` = 3, and `Blocked` = 4.
2. `provider_completion_payout_usd_per_million_tokens` descending, null after every non-null value.
3. `demand_rank` ascending, null after every non-null value.
4. `supply_deficit_score` descending, null after every non-null value.
5. `demand_weight` descending, null after every non-null value.
6. `ready_provider_count` ascending, null after every non-null value.
7. Canonical row identity ascending by unsigned UTF-8 bytes. It is the tagged wire tuple (`candidate`, `candidate_id`) when `candidate_id` is non-null, otherwise (`catalog`, `model_key`). Tag and value are separate UTF-8 byte strings, each prefixed by its unsigned 32-bit big-endian byte length, with no Unicode or case normalization.

For every row whose `economics_state` is not `trusted`, components 2 through 6 are treated as null regardless of carried disabled-context values. All numeric comparisons use validated JSON numeric value without localized formatting, string conversion, or binary-floating-point drift. Display identity, `recommendation_rank`, locale collation, case folding, Unicode normalization, input stability, and display-string transformation never participate. The same accepted row set therefore has one order across input/feed permutations, process restarts, and locales.

## Projection compatibility matrix

Capability advertisement is mutually exclusive because the public read spelling carries no version selector.

| Malibu | CLI advertisement | Required result |
|---|---|---|
| v1-only | exact v1 capability plus exact v1 command-schema token only | Invoke read; accept only `model_catalog_economics.v1`; no v2 run/cancel/cleanup. |
| v1-only | v2 capability plus exact v2 token only | Do not invoke catalog-economics; show existing static/current-model fallback. |
| v2-capable | v2 capability plus exact v2 token only | Invoke read; accept only `model_catalog_economics.v2`; permit only validated v2 actions. |
| v2-capable | exact v1 capability plus exact v1 command-schema token only | Invoke v1 read when supported; preserve v1 UI and expose no v2 action. |
| Any | capability-only or token-only for either generation; both complete pairs; either complete pair plus any token/capability from the other generation; unknown/conflicting values; or manifest/local-status disagreement | Treat advertisement as invalid; do not invoke the ambiguous read or any mutation; use the existing fallback with the approved unavailable warning. |
| Any | neither supported capability | Do not invoke; use the existing silent legacy/static fallback. |

The authority patch must apply the same matrix independently to the local-status handshake and the built CLI's manifest, then require both sources to report the same one exclusive complete pair. There is no environment variable, hidden argument, TTY inference, or optimistic decoder retry that selects a generation.

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
2. #1485 operator state/copy landed at `c4401f1791d593d37d68eba91af94219b26d278f`. Its state inventory remains closed, but the authority patch must correct the stale 13-state count to 12 and replace the `local_only` installed/usable wording with the exact admission-only wording above before implementation.
3. `JOURNEY-PROVIDER-BYOM-DISCOVERY` remains pending in CONFORMANCE despite the issue checkbox. Network admission/settlement evidence also remains pending.
4. Current SPEC-044 v0.1.1 does not authorize locally motivated pre-offer preparation, a cancellation acknowledgement, or published-artifact cleanup/accounting. `cleanup_staging` cannot be overloaded.
5. **Hard pre-6B authority gate:** @Augustas11 must land one narrowly scoped SPEC-001/SPEC-044 patch, with authority/index updates, that freezes: (a) exact run/cancel option spelling, exclusive complete v1/v2 capability+token pairs, and all partial/dual/conflict/manifest-status negatives; (b) closed event error/warning codes and total error precedence; (c) R002/R003 locally motivated preparation eligibility, the exact catalog-only `unavailable`/`none`/`local_default:not_offered` null/false sentinel in exact R008 `Blocked` placement with forbidden-section negatives, candidate-associated all-non-null binding, cross-candidate rejection, coordinator no-event and event-backed `not_offered`, the exact source-aware `local_default:not_offered` and `coordinator:not_offered` meanings, `verification_status: verified`, exact source/freshness correlation, the exact **Eligible to earn on qualifying settled requests** conditional verdict, admission-only `local_only` copy, exact operator-owned local/trusted copy, the exact 12-state admission inventory, and economics/demand separation; (d) worker-only event sequencing plus the exact bounded cancellation-ack schema, request echo, six outcomes including `busy`, the 2.000-second monotonic cancel-lock deadline, total acquired-lock outcome precedence, nullability, exit/mutation/resource rules, marker-race semantics, and cancel-process read/marker-only authority; (e) the versioned projection/action/accounting contract for `cleanup_published_artifact`, bounded `cleanup_targets` with immutable `event_model_key`, RFC 8785 action equality and enclosing target digest/size binding, distinct one-fault enclosing-target/action-side/every-other-action-field/cross-target rejection before confirmation or mutation, managed-v3 totals, configured-legacy protected totals, logical-byte accounting, truthful APFS copy, and exact budget policy; (f) published and staging continuous `cancel.lock` ownership from final marker check through rename, both parent barriers, durable readback-validated `tombstoned`, reversible post-crash precommit restoration, and operation/cleanup/cancel recovery ownership; (g) authenticated root identity/locator persistence plus already-open unpublished owner-only temp creation, empty-ACL verification before the first sensitive byte, and descriptor revalidation; (h) the exact SPEC-044-R005 locale-independent total ranking tuple, null ordering, tagged canonical identity, and duplicate-canonical-identity rejection; and (i) app-owned refresh generation plus constant-space process transport/backpressure. It must retain `model_catalog_transaction_event.v1`, add no status or control-socket schema, and not overload `cleanup_staging`.
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

Every private authority, namespace, lock, lifecycle record, temp, staging object, unpublished object, published object, receipt, and tombstone must have no extended ACL entries. Every new sensitive object begins as an already-open, unpublished temporary entry created owner-only (`0700` directory or `0600` file). Through that descriptor the implementation strips every inherited ACL and verifies the ACL is empty before writing the first sensitive byte. Failure to strip or verify fails closed and removes only that newly created still-empty object. Existing objects carrying any extended ACL are never repaired in place and fail closed. Owner, type, mode, link count, device, inode, and empty ACL are revalidated on the same descriptor immediately before every sensitive read/write, rename, publication, restoration, unlink, or authority use; a post-validation ACL mutation therefore loses the race or aborts before the side effect. POSIX owner/mode checks remain independently mandatory.

### Secure artifact-root binding

At snapshot creation the builder resolves the existing config/environment root once, canonicalizes it, and reopens every component without symlink traversal. The canonical `root.identity` record has an explicit identity schema/version, a CSPRNG 256-bit nonce, the canonical path, and the validated descriptor `st_dev`/`st_ino`. Its digest is lowercase SHA-256 over a domain separator and an unambiguous length-prefixed canonical encoding of that complete validated record, including schema/version, secret nonce, canonical path, device, and inode; a nonce-only digest is forbidden. The nonce remains private and only the digest may enter a public projection.

Every bounded private lifecycle record that may outlive a process and need to reopen the root—reservation/history, active/selection, inventory, deletion or staging-cleanup record, receipt, and tuple—persists the saved canonical path, `st_dev`, `st_ino`, identity schema/version, and root-identity digest. Recovery reopens only that saved path and requires the descriptor plus recomputed complete-record digest to match before mutation; current config/environment, scanning, copied nonce bytes, rewritten metadata, path replacement, remount, device change, or inode reuse cannot redirect or rebind it. Serving independently resolves its configured root and verifies the receipt identity against the open descriptor.

### Reservation, tuple, and deterministic selection

The private v3 reservation and tuple retain all v2 target fields, signed primary MLX qualification, 1 TiB estimate cap, config/provider/root binding, binary framing, 64 selected entries, 256 history limit, deterministic `authority_order`, one active pin, eight oldest-wait fairness slots, unchanged-ID retention, bounded starvation, and serialized dispatch. At 257 eligible tuples Prepare is unavailable rather than silently truncated.

### Active operation and cancellation sequencing

`active.json` duplicates the full tuple/root binding and contains one attempt, private phase, counters, recorded paths, barrier progress, terminal result, and the worker's next event sequence. Public states remain only SPEC-044's seven states.

Marker protocol and locks:

1. The worker holds `operation.lock`. Only it allocates/increments event sequence and writes stdout events.
2. The cancel process takes only `cancel.lock`. Immediately before its first acquisition attempt it records `CLOCK_MONOTONIC_RAW`; acquisition is permitted only while elapsed time is strictly less than 2.000 seconds. If the lock has not been acquired when elapsed time reaches 2.000 seconds, it emits the valid `busy` acknowledgement described below and exits without reading or mutating marker, active/history, terminal, cleanup-phase, temp, artifact, or operation state. If it acquires the lock in time, it validates bounded durable state without repairing, recovering, renaming, deleting, or acquiring `operation.lock`, and if the exact attempt is nonterminal writes/reuses the attempt-bound marker durably. It returns the approved acknowledgement and releases `cancel.lock`; it emits no event. A busy operation lock never authorizes cancel-side recovery mutation.
3. The proposed acknowledgement is a single JSON object capped at 4096 bytes with exact fields `schema`, `transaction_id`, nullable `attempt_id`, `outcome`, and `observed_at`; `schema` is `model_catalog_transaction_cancel_ack.v1`, and `transaction_id` must byte-for-byte echo the syntactically valid requested ID. The closed `outcome` values are `recorded`, `already_recorded`, `terminal`, `not_active`, `stale`, and `busy`.
4. Failure to acquire `cancel.lock` before the monotonic deadline returns `busy` with `attempt_id: null`, one valid acknowledgement on stdout, empty stderr, and exit status 0. This result states only that lock custody was unavailable within the bounded call. It creates, removes, repairs, or changes nothing. After timely acquisition, bounded read-only validation applies this total first-match precedence: (1) a durable terminal active/history record for the requested transaction returns `terminal` with that record's non-null attempt ID; (2) a nonterminal active record for the requested transaction with an already-durable exact-attempt marker returns `already_recorded` with the active attempt ID; (3) a nonterminal active record for the requested transaction without that marker leaves all operation/recovery objects untouched, removes only a validated older marker when allowed, durably records the exact marker, and returns `recorded` with the active attempt ID; (4) any validated state proves that the requested transaction existed but is no longer the cancellable current attempt, including a different current attempt or mismatched prior-attempt marker, returns `stale`, with the stale attempt ID when safely known and otherwise null; (5) absence of matching active, terminal, reservation/history, or marker evidence returns `not_active` with null attempt ID. These five acquired-lock outcomes also emit one valid acknowledgement and exit 0. Malformed input or malformed/unsafe state fails with the authority's nonzero exit and emits no valid acknowledgement; it is never collapsed into `not_active` or `busy`.
5. `recorded` means only durable marker custody, not worker observation or cancellation success. `already_recorded` means that exact marker was already durable. `terminal` means the exact attempt's durable terminal record won. `stale` means bounded durable state recognizes the transaction but not as the current cancellable attempt. `not_active` means no bounded durable state recognizes it. `busy` means only that the cancel lock was not acquired before the deadline. `busy` and `not_active` always have null `attempt_id`; `stale` follows the known/unknown rule above; the other three are non-null. The operator patch must approve this exact deadline/predicate/precedence/nullability/exit contract before implementation.
6. The worker checks the marker at the 250 ms watchdog and every bounded work loop. It emits `cancel_requested` once when cancellation wins before the transaction-specific commit point, then terminal `cancelled` only after the required reversible cleanup. After the commit point it emits only `succeeded` or `failed`.
7. Before terminal compaction/releasing `operation.lock`, the worker takes `cancel.lock`, durably commits terminal state, removes an exact matching marker, releases `operation.lock` while still holding `cancel.lock`, then releases `cancel.lock`. Thus a cancel process either writes before the terminal sweep or observes the released/terminal operation and does not leave a late marker.
8. A new attempt takes `operation.lock` then `cancel.lock`, validates and removes only a stale marker bound to the prior attempt, persists the new active record, and releases `cancel.lock`. A marker can never apply across attempts.

All recovery mutation belongs to the worker/recovery-worker path after it owns `operation.lock`. Non-cleanup recovery takes `cancel.lock` next when it must inspect or sweep cancellation state. Published and staging cleanup recovery takes the cleanup lock before `cancel.lock`. These are the only nested orders: `operation.lock` → `cancel.lock` and `operation.lock` → cleanup lock → `cancel.lock`. The cancel process never inverts either order because it never takes `operation.lock` or a cleanup lock.

The cancellation acknowledgement is capped at 4096 bytes, contains no event sequence or terminal assertion, and is part of the future operator contract. Malibu permits at most one live cancellation subprocess per transaction. Repeated cancel gestures while it is live coalesce onto that request; after a `busy` result the provider may retry with a fresh bounded subprocess. Direct CLI invocations remain independently bounded by the same lock deadline and may never leave a waiter, descriptor, thread, child process, or temporary object after exit.

### App-owned refresh order and bounded process transport

Malibu allocates a monotonically increasing in-memory refresh generation before each catalog-economics process launch. A reply may update the projection/actions only when its generation is still the newest launched generation for that app session. Thus A-before-B launch accepts B then rejects late A, or accepts A provisionally only if it completes before B and replaces it when B completes. CLI `process_launch_id`, `projection_sequence`, and wall-clock `generated_at` remain envelope validation/correlation fields but never reset or override the app-owned order. App restart begins a new local generation epoch and clears old child callbacks; refresh timeout invalidates that generation's eventual reply. Superseding a read may cancel only that read process and must not cancel, detach, or suppress independently attached preparation/cleanup/action workers or their event streams.

The production process adapter incrementally decodes UTF-8 JSONL in constant bounded space. It retains no whole-worker stdout; rejects immediately when the current partial line exceeds 16384 bytes before newline; caps diagnostic stderr to one operator-approved byte limit with deterministic truncation metadata; and uses one bounded event-delivery queue with a fixed item/byte ceiling. When UI consumption is slower than pipe production, the adapter continues draining stdout/stderr into bounded decoder buffers and applies the authority-approved backpressure/coalescing/fail-closed policy without spawning an unbounded number of MainActor tasks, dropping terminal semantics, or reordering accepted events. Aggregate retained stdout, stderr, partial-line, decoded-event, and scheduled-delivery memory therefore remains constant with respect to event count and process duration.

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

Inventory enumerates only `.macprovider-prepared-v3/objects`, capped at 256 exact receipts. The v2 projection also carries a required closed top-level `cleanup_targets` array with at most 256 entries, deterministically ordered by lowercase `artifact_identity_digest`. It contains every verified managed v3 identity observed by the bounded inventory, including objects with no current catalog row. Each entry has exactly `artifact_identity_digest`, `display_model_id`, `model_revision`, `artifact_id`, `release_id`, required immutable `event_model_key`, nullable current `model_key`, `root_identity_digest`, `receipt_sha256`, exact logical `estimated_bytes`, `keep_set_status`, nullable `protected_reason`, and `cleanup`. `event_model_key` is copied from the historical model key sealed into the publication receipt and is durably copied into the cleanup reservation/active/deletion records; every cleanup event uses it as the retained event schema's non-null `model_key`. The nullable current `model_key` remains only the present catalog match and may be null for an orphan. The two digests are lowercase 64-hex; `keep_set_status` is `protected` or `reclaimable`; `protected_reason` is required exactly for `protected`; and `cleanup` uses the v2 action shape. A reclaimable entry has one available `cleanup_published_artifact` action carrying the same artifact digest, event key, and bytes; a protected entry has an unavailable action and exact reason. Missing/stale receipt identity, malformed inventory, or overflow makes the array empty/unavailable with the storage totals and actions fail closed. If a row retains `cleanup_published`, the RFC 8785 JSON Canonicalization Scheme (JCS) UTF-8 bytes of `row.cleanup_published` must be byte-identical to the JCS UTF-8 bytes of the corresponding `cleanup_targets[i].cleanup`; the comparison is action-to-nested-action, never action-to-enclosing-target. Separately, the nested action's `artifact_identity_digest` and `estimated_bytes` must equal the enclosing target fields, and its availability, transaction kind, transaction ID, timeout, reason, immutable event key, and other closed action fields must remain internally valid. Absence from the current signed catalog never makes a reclaimable v3 identity unreachable. The operator patch must approve these exact fields/enums and bindings before implementation.

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
4. While retaining `operation.lock` and the cleanup lock, take `cancel.lock` and perform the final exact-marker check. If the marker exists, durably clear intent and cancel before rename. Otherwise hold `cancel.lock` without interruption across exclusive rename of the exact v3 final leaf to its reserved tombstone sibling in the same `objects` parent, successful `fsync` and `F_FULLFSYNC` of that shared parent, persistence and full-sync of `deletion.json` as `phase: tombstoned`, and readback validation of that durable phase. Only after the readback succeeds may the worker release `cancel.lock`. The durable, readback-validated `tombstoned` phase—not rename or either parent barrier alone—is the sole deletion commit evidence and cancellation linearization boundary.
5. Descriptor-validate and unlink recorded tombstone contents, remove the tombstone, full-sync its parent, update `phase: removed`, then durably clear the record and refresh inventory.

Recovery never scans or guesses and only a recovery worker holding `operation.lock`, then the cleanup lock, then `cancel.lock` may mutate cleanup recovery state; it holds all three while doing so. With `intent`: final present/tombstone absent means an exact marker clears intent and cancels; without a marker recovery rechecks the keep set and resumes the same continuous-lock rename/barrier/durable-`tombstoned` sequence or clears protected intent. Final absent/tombstone present is always precommit: an exact marker restores tombstone to final, fully syncs the parent, clears intent, and cancels; without a marker recovery repeats both parent barriers and persists, full-syncs, and readback-validates `tombstoned` before releasing `cancel.lock`. Both present or both absent fails closed. With `tombstoned`: tombstone present resumes deletion; tombstone absent/final absent repeats parent sync then advances to `removed`; final present fails closed. With `removed`: both absent permits record clear; any target present fails closed. Every step reopens the saved root only. Legacy paths are invalid cleanup targets.

For published cleanup, cancellation wins until `phase: tombstoned` is durable. There is no live-worker marker window after the final marker check: the worker retains `cancel.lock` continuously through rename, both object-parent barriers, durable phase persistence, and phase readback. Once `tombstoned` is durable, cancellation is late: the worker or recovery completes exact deletion and emits/returns `succeeded`, or retains recoverable state and fails with `cleanup_failed`. A crash at any precommit point releases the kernel lock and may leave `intent` with final absent/tombstone present. The post-crash race is constructible and total: if cancellation acquires `cancel.lock` before recovery, it records the exact marker without mutating recovery state and later recovery restores the final; if recovery acquires the ordered operation/cleanup/cancel locks first and sees no marker, it repeats the barriers and durably readback-validates `tombstoned`, after which cancellation is postcommit. The cancel process itself never performs restoration or advances a phase.

`cleanup_staging` has an independent recorded target and uses an equivalent reversible intent → same-parent tombstone → durable `tombstoned` → removed discipline inside the attempt's staging parent. Its commit evidence is likewise the durable, readback-validated `tombstoned` phase. The worker and recovery path use the same operation/cleanup/cancel lock order and continuous `cancel.lock` hold from the final marker check through rename, parent `fsync`/`F_FULLFSYNC`, phase persistence/full-sync, and phase readback. Cancellation while phase remains `intent`, including after a crash leaves a synced rename, preserves or restores the incomplete staging tree, retains `staging_cleanup_required`, and ends `cancelled`; cancellation after durable `tombstoned` completes removal and ends `succeeded` or recoverable `cleanup_failed`, never `cancelled`. Only the operation-owning worker/recovery worker restores or advances it. A staging cleanup record cannot name a published, legacy, different-attempt, or different-root object, and published cleanup cannot name staging.

### Crash and retry semantics

Preparation crash recovery retains v2 semantics: no byte continuation after process death, exact saved-root cleanup, same-attempt live Range resume only, retry from zero on new attempt, recovery of rename/parent/active/event boundaries, preservation of conflicting destinations, and fresh projection as status. It additionally reconciles recognized unique temps, root bootstrap, cancel markers, and both cleanup kinds' phased intent/tombstone/remove records without permanent wedges. Retry resumes only the recorded transaction/root/target/phase; it never creates a second tombstone or reinterprets the current config.

## Preparation/adoption exclusion and readiness handoff

Lock order remains preparation `operation.lock` → `RecommendationAdoptionLock` → owner-only control socket → runtime reservation. Preparation holds no runtime lease during transfer. The existing adoption frame remains unchanged; the serving handler reloads signed feeds, independently derives its configured v3 destination, validates the receipt/root/hash, and treats frame path/hash only as claims.

## Slices and deliverables

### Slice 6A — authority and ownership closure

Land the single complete operator patch from Gate 5, including `SPEC-001-R003`, exclusive complete version pairs, scoped guidance binding/exact catalog-only sentinel, exhaustive R002/R003 matrix/admission-only copy and exact 12-state inventory, conditional earning verdict, bounded cancellation acknowledgement/sequencer, continuous cleanup locks, cleanup targets/action-to-nested-action JCS equality/event correlation/accounting, root/ACL/process transport rules, the exact SPEC-044-R005 ranking, and both cleanup state machines. Record exact versions/commit/owner and prove strict ancestry. Re-review this v10 plan/test plus SPEC diff to zero C/H/M.

### Slice 6B — private preparation/storage engine

Implement secure roots and unique-temp recovery, bounded selection, worker/cancel locks, transfer counters, v3 namespace, durable publication, logical-byte/legacy accounting, bounded cleanup targets, and intent-first cleanup with exact cancellation/recovery.

### Slice 6C — CLI and Malibu surface

Implement only approved grammar/schemas. Render authoritative guidance first, exact local/trusted preparation and truthful cleanup copy, worker events, cancellation acknowledgement, app-owned refresh ordering, bounded process transport, storage accounting/targets, confirmation, accessibility, and version fallback. Test the built CLI through Malibu's production process adapter and strict decoder.

### Slice 6D — existing adoption handoff

Extend only handler behavior for independent feed/v3-root/hash reload while preserving the current frame, journal, rollback, load/drain/swap, and incumbent safety.

### Slice 7 — physical qualification and release

Retain real MLX, throttled transfer, custom-root/APFS power recovery, incumbent traffic, adoption, signed journeys, settlement/positive credit, first listed tier, signed/notarized assets, byte identity, and updater proof.

## Acceptance criteria

1. The authority patch makes pre-offer local preparation reachable and conforming through required all-or-none candidate/guidance binding on candidate-associated rows, the exact catalog-only `unavailable`/`none`/`local_default:not_offered` null/false/no-action sentinel, cross-candidate rejection, exact source/freshness correlation including coordinator no-event `not_offered`, `verification_status: verified`, the exact conditional settlement-capable verdict, admission-only `local_only` wording, exact preparation copy, the exact 12-state admission inventory, and economics separation across every legal admission/economics combination.
2. V1/v2 advertisement requires one exclusive complete capability/token pair and every old/new Malibu/CLI combination has one deterministic read or fallback result; partial, dual, conflicting, or manifest/local-status-disagreeing sets cause no invocation.
3. Worker alone sequences transaction events; cancellation returns only the approved bounded acknowledgement with request echo, the 2.000-second monotonic lock deadline, six outcomes including null-attempt/no-mutation `busy`, total acquired-lock outcome precedence, exact nullability/exit behavior, bounded resources, and no late/terminal/new-attempt marker effect.
4. Unique validated temps and atomic root bootstrap recover every ordinary crash without permanent wedge.
5. URLSession guarantees only accepted/staged byte caps; cancellation observation and `task.cancel()` meet the 250 ms contract, and the optional two-second terminal bound applies only to the frozen supported profile with exact clocks, data limits, sync limits, and tolerance; delegate-delivered, transport, and server metrics are explicitly separated.
6. V3 publications/inventory stay inside the dedicated namespace; logical-byte accounting is deterministic; APFS copy does not promise physical recovery; every reclaimable object is reachable through bounded `cleanup_targets` with an immutable event model key; each retained row cleanup is JCS-byte-identical to its target's nested action and separately binds the enclosing digest and size; configured legacy artifacts are protected/accounted and no legacy object is imported or deleted.
7. Published and staging deletion intent is durable before rename; the worker holds `cancel.lock` continuously from its final marker check through rename, both parent barriers, and durable readback-validated `tombstoned`; that phase is the sole commit evidence; every post-crash `intent` tombstone remains reversibly restorable when cancellation acquires the lock before recovery; only the operation-owning worker/recovery worker mutates recovery state; and cancellation/crash/retry at every boundary has one exact non-scanning outcome.
8. Budget default, rounding, precedence, invalid overrides, checked arithmetic, and byte/free-space threshold behavior are exact; unavailable legacy accounting blocks projection and direct dispatch before side effects.
9. `SPEC-001-R003`, AUTHORITY consumers, R005 CONFORMANCE gaps/evidence, versions, indexes, and review lineage agree.
10. Built-CLI bytes traverse Malibu's production adapter/decoder for reads, run terminals, cancellation acknowledgements, constant-space chunking/partial-line/stderr/backpressure behavior, exit handling, and compatibility negatives.
11. App-owned refresh generations reject late older reads through inverted completion orders, restart, timeout, and action overlap without harming attached action workers.
12. Root identity authenticates nonce plus canonical validated identity/version and every reopening lifecycle record persists its locator/descriptor; every new private object is an already-open unpublished owner-only temp whose ACL is stripped and verified empty before its first sensitive byte; all private objects enforce descriptor revalidation across inheritance and mutation races.
13. Row ranking uses the exact SPEC-044-R005 tuple and R008 section rank, explicit null order, exact numeric comparison, final tagged length-prefixed canonical identity, duplicate-canonical-identity rejection, and components 2-6 treated as null for every nontrusted row. Display identity and recommendation rank never participate.
14. All v2 root, selection, durability, resource, incumbent, authority, adoption, compatibility, privacy, and final hardware/release gates remain in force.

## Compatibility, migration, and rollback

No old state or legacy artifact is imported. Existing configured legacy incumbent/draft trees remain in place and are protected/accounted separately. Upgrade creates the v3 namespace beside them. Rollback removes capability/UI exposure, preserves v3 and legacy bytes plus recovery state, and never runs GC. Re-upgrade validates the v3 namespace and resumes exact recovery.

## Observability and privacy

Worker event sequencing, cancel acknowledgements, app refresh generation decisions, bounded transport queue/truncation counters, transfer counter classes, temp recovery, root bootstrap, namespace inventory, legacy accounting, and deletion phases are logged through bounded redacted codes/counters. Paths, usernames, credentials, feed bodies, prompts, completions, and raw errors are excluded. Transport/server byte counts are labeled observational.

## Hardware and release requirements

Unit/SIGKILL tests cannot prove stable-media durability, real MLX usability, serving continuity, settlement, signing, notarization, or updater behavior. Slice 7 uses final signed assets on supported Apple Silicon and real APFS volumes, including abrupt-power cases. App/tarball CLI binaries must be byte-identical after packaging.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Pre-offer Prepare contradicts economics authority | Operator-owned R002/R003 matrix and exact non-economic copy before 6B. |
| Malibu derives or mis-correlates earning guidance | Required verbatim SPEC-046 guidance plus exact candidate/source/digest/freshness binding and exact conditional settlement-capable verdict. |
| Catalog-only row borrows candidate economics | The exact `unavailable`/`none`/`local_default:not_offered` null/false/no-action sentinel is mandatory; cross-candidate joins and every one-fault deviation fail closed. |
| Old/new client schema confusion | One exclusive complete v1/v2 capability+token pair and full production compatibility matrix. |
| Orphan tombstone after crash | Durable intent before rename and durable `tombstoned` commit phase with exact recovery. |
| Cleanup cancellation reports success after destructive ambiguity | Continuous final-check-through-tombstoned cancel lock, reversible post-crash precommit tombstone, worker-owned recovery, and exact published/staging state tables. |
| Root record is copied or cannot be relocated after restart | Complete authenticated nonce/path/descriptor/version digest plus saved locator in every reopening lifecycle record. |
| Late read restores stale actions | App-owned prelaunch generations reject older completion without touching action workers. |
| Event transport exhausts memory | Constant-space line/stderr buffers and one bounded delivery queue with explicit backpressure. |
| Inherited or raced ACL grants access | Already-open unpublished owner-only creation, empty-ACL proof before first sensitive byte, and descriptor revalidation before every sensitive side effect. |
| Cancel subprocess waits or accumulates indefinitely | Exact 2.000-second monotonic lock deadline, valid no-mutation `busy` result, one app child per transaction, and resource-leak tests. |
| Equal rows reorder across locales or input permutations | Exact SPEC-044-R005 tuple, explicit null ordering, tagged length-prefixed canonical identity, and duplicate-canonical-identity rejection. |
| Bootstrap/temp crash wedges root | Unique self-identifying temps, bounded recovery, atomic final identity. |
| Unenforceable network-read claim | Normative accepted/staged caps only; transport/server counts observational. |
| APFS clone/compression makes cleanup copy false | Report logical managed data only; never promise physical recovered capacity. |
| Legacy store blocks or is deleted | Dedicated v3 namespace; configured legacy protection/accounting; no import/delete. |
| Event sequence split across processes | Worker sole sequencer; cancel returns separate approved acknowledgement under cancel lock. |
| Ordinary publication exceeds inventory cap | Count admission before transfer and rename under the shared operation/cleanup lock; exact idempotence only at 256. |
| Prior root/durability/resource regressions | All v2 gates retained and dispositioned in tests. |

## Qualification blockers

- Authority patch omits any guidance binding, conditional earning verdict, exact catalog-only sentinel, version matrix, verified-artifact gate, admission-only `local_only` copy, exact 12-state inventory, matrix/copy, cancel acknowledgement/deadline/`busy`/precedence/sequencer, exact SPEC-044-R005 ranking tuple, invocation/event precedence, cleanup nested-action JCS/digest/size binding, cleanup target/accounting/continuous-lock state-machine contract, ACL creation order, governance mapping, or does not predate 6B.
- Any recognized interrupted temp/root bootstrap or deletion boundary can permanently wedge or require scanning/guessing.
- Any correctness claim bounds server/transport bytes under URLSession.
- V3 code inventories, imports, renames, receipts, or deletes a legacy object.
- A normal publication can create object 257, or count admission is not serialized with cleanup.
- Any reclaimable v3 identity lacks a bounded projected cleanup target because its catalog row disappeared.
- Any orphan cleanup target lacks a durable immutable event model key or fails success/cancel/recovery/retry through the production adapter.
- Any cancel process repairs, restores, advances, deletes, or takes `operation.lock`; any recovery path violates operation → cleanup → cancel lock order; any worker releases `cancel.lock` between final marker check and durable readback-validated `tombstoned`; or rename/barrier alone is treated as cleanup commit evidence.
- Any root-reopening lifecycle record omits the saved locator/descriptor/version/digest, or the digest excludes nonce or validated identity fields.
- Any private object accepts an extended ACL, writes sensitive bytes before empty-ACL verification on its already-open unpublished owner-only temp, or allows ACL mutation to race a sensitive side effect.
- Any cancel-lock wait reaches 2.000 monotonic seconds without a valid null-attempt/no-mutation `busy` acknowledgement and bounded process exit, or repeated cancellation leaks/accumulates app children, waiters, descriptors, threads, or temps.
- Any row sort uses display identity, recommendation rank, locale collation, binary floating point, implicit null order, or input stability as a tie-break; applies economics/demand components to a nontrusted row; or accepts duplicate canonical row identities.
- Any older read can replace a later-launched refresh, or read supersession affects an attached action worker.
- Any JSONL/stdout/stderr/partial-line/delivery path retains memory or scheduled tasks proportional to stream duration/event count.
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
| B1-AUTH-V3-H1 | Continuous cleanup cancel-lock interval and post-crash race | T03, T10, T12, T21 |
| B1-AUTH-V3-H2 | Conditional settlement-capable verdict with no current-income claim | T01, T14, T16, T18 |
| B1-AUTH-V3-H3 | Catalog-only all-null rows always nontrusted/null-money/no-action | T01, T05, T15, T16 |
| B1-AUTH-V3-M1 | Already-open unpublished owner-only temp and pre-byte empty ACL | T01, T08, T10, T21 |
| B1-AUTH-V3-M2 | Two-second monotonic cancel-lock deadline and `busy` resource bounds | T03, T12, T14 |
| B1-AUTH-V3-M3 | Canonical-wire total row ranking | T15, T16 |
| B1-AUTH-V4-H1 | Exact operator-owned SPEC-044-R005 ranking and canonical identity | T01, T15, T16, T18 |
| B1-AUTH-V4-M1 | Exact catalog-only sentinel and one-fault rejection | T01, T05, T15, T16 |
| B1-AUTH-V4-M2 | Admission-only `local_only` copy and independent readiness evidence | T01, T14, T16 |
| B1-AUTH-V4-M3 | Cleanup nested-action JCS equality and enclosing digest/size binding | T09, T10, T16 |
| B1-AUTH-V4-M4 | Exact 12-state admission inventory | T01, T16, T18 |
| B1-AUTH-V5-H1 | Exact operator-owned admission-only `local_only` English source | T01, T16, T18 |
| B1-AUTH-V5-M1 | Exact R008 `Blocked` placement for the catalog-only unavailable sentinel | T01, T15, T16, T18 |
| B1-AUTH-V5-M2 | Source-aware local-default/coordinator `not_offered` meanings | T01, T16, T18 |
| B1-AUTH-V5-M3 | Enclosing/action/cross-target destructive-cleanup rejection proof | T09, T10, T16 |
| B1-AUTH-V2-H1 | Exclusive complete v1/v2 capability+token pairs | T01, T15 |
| B1-AUTH-V2-H2 | Coordinator `not_offered` nullable-event exact binding | T05, T16, T23 |
| B1-AUTH-V2-H3 | Cancel-only marker authority; durable tombstoned commit | T03, T10, T12, T21 |
| B1-AUTH-V2-H4 | Authenticated root identity plus lifecycle locators | T01, T04, T05, T08, T21 |
| B1-AUTH-V2-M1 | Candidate all-or-none scope and catalog-only rows | T01, T15, T16 |
| B1-AUTH-V2-M2 | Cleanup target immutable event model key | T09, T10, T14 |
| B1-AUTH-V2-M3 | App-owned prelaunch refresh generation | T14, T16 |
| B1-AUTH-V2-M4 | Constant-space process transport/backpressure | T14 |
| B1-AUTH-V2-M5 | Exact empty-extended-ACL policy and races | T08, T10, T21 |

Prior v1 corrections remain covered: authority/no invented status or refresh protocol (T01/T14/T18), custom roots (T04/T05/T08/T13), APFS durable ordering (T07/T10/T21), bounded fair selection (T02/T03), published storage (T09/T10/T16/T17), and production cancellation (T06/T09/T21).

## Evidence anchors

- `docs/product-roadmap/build-1/reviews/reservation-rebaseline-plan-v2-sol.md`
- `docs/product-roadmap/build-1/reviews/preparation-authority-v1-sol.md` (reviewed from the authority worktree at candidate `c42eea1c`)
- `docs/product-roadmap/build-1/reviews/preparation-authority-v2-sol.md` (reviewed from the authority worktree at candidate `f691de4d`)
- `docs/product-roadmap/build-1/reviews/preparation-authority-v3-sol.md` (reviewed from the authority worktree at candidate `fccb813c`)
- `docs/product-roadmap/build-1/reviews/preparation-authority-v4-sol.md` (reviewed authority revision `037a3934`; artifact commit `4164d0aa`)
- `docs/product-roadmap/build-1/reviews/preparation-authority-v5-sol.md` (reviewed authority revision `4196d6d9`; artifact commit `02faf9a2`)
- `specs/SPEC-044-malibu-model-catalog-economics.md`
- `specs/SPEC-001-phase3-binary.md`
- `specs/AUTHORITY.json`
- `specs/CONFORMANCE.json`
- `audits/2026-09-11-byom-v02-handoffs/SLICE6_MALIBU_ACTIVATION_UX_HANDOFF.md`
- `audits/2026-09-11-byom-v02-handoffs/SLICE6_STATE_SURFACE_AND_COPY.md`
- `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift`
- `phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift`
- `phase3-binary/Sources/macprovider-cli/ControlSocket.swift`
