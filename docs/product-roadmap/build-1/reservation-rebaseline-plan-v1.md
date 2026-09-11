# Build 1 preparation-reservation rebaseline plan v1

Status: fresh plan; implementation is gated on reconciliation with the active BYOM v0.2 slice 6 handoff (#1485).

Baseline: `4bbb7eedde40759b56a6d42f82aacb8461adff95` (`origin/main` after BYOM v0.2 slice 5 merged and the slice 6/7 handoff briefs landed on 2026-09-11).

Authority: issue #1453 is the current execution queue. This document replaces the abandoned Build 1 reservation design as a planning input only. It does not approve, migrate, or reuse any R21-R27 protocol or local development state.

## Decision

The initiating `malibu-cli` process is the preparation worker. It owns one provider-UID-scoped, user-private authority root, holds one live kernel `flock` for the full operation, downloads and verifies only its transaction-owned staging, and publishes an immutable content-addressed durable artifact once. A second CLI process may read status or write the exact cancellation marker. There is no daemon, background service, database, or post-crash continuation.

Preparation ends at durable local readiness. It never edits provider configuration, changes the current runtime, changes admission or routing, displays or grants economics, submits an offer, or creates settlement evidence. After readiness, a fresh projection may hand the exact artifact to the existing recommendation-adoption lock, journal, and warm-swap protocol. If the running provider does not already know that target, the only permitted live refresh is a narrow request over the existing owner-only control socket; the serving process reloads signed authority and re-hashes the durable artifact itself before adding in-memory readiness authority.

This design deliberately does not hold `ModelRuntime`'s five-minute prepared reservation or fifteen-minute active reservation while transferring multi-gigabyte model bytes. Those short leases begin only in the existing post-readiness adoption path (`ModelRuntime.swift:729-739`, `:1642-1733`).

## Product outcome and boundary

The reservation subplan delivers one part of the original Build 1 outcome: a provider can select a supported catalog model, see exact size and trust disclosure, prepare its primary MLX artifact safely, cancel before publication, retry after interruption, and obtain locally verified readiness while the incumbent keeps serving.

It does not own the already landed signed artifact feed, BYOM intake, offer/admission decisions, paid routing, settlement, or release evidence. It composes with them as follows.

| Original Build 1 outcome | Current owner and status | Reservation-subplan contribution |
|---|---|---|
| Select a supported catalog model | Signed artifact-feed qualification landed in BYOM slice 2c. `QualifiedArtifactFeed` binds selected bytes, signer, release, and candidate catalog (`AutotuneArtifactFeed.swift:500-525`, `:554-574`). | Preserve up to 64 exact projected preparation tuples and stable action IDs. |
| Prepare one primary MLX artifact safely | Missing at this baseline. Existing catalog rows expose preparation as unavailable (`ModelCatalogEconomics.swift:423-427`). | CLI worker, isolated staging, cancellation, bounded state, verification, and publish-once readiness. |
| Understand pricing and admission | BYOM slices 0-5 own signed feeds, intake, catalog matching, decisions, and truthful non-earning states. | No economics or admission mutation. The action remains local and non-economic. |
| Progress through authoritative admission | Slice 4 code is landed; issue #1453 slice 7 still owns signed admission journey evidence and final conformance. | After preparation/adoption, return to the existing BYOM offer/status/decision workflow. |
| Execute actions in Malibu | Issue #1453 slice 6 owns provider schemas, CLI action commands/status/copy, Malibu controls, and copy. | Supply the local transaction engine only after the slice 6 contract is locked. |
| One real Mac serves a correctly settled request | Issue #1453 slice 7. | Provide the prepared primary artifact used by that physical journey; preparation success alone cannot pass it. |

Feed, admission, and settlement work already landed or owned by BYOM must not be copied into this subplan. In particular, the reservation layer does not parse coordinator rate feeds, append admission decisions, or touch the coordinator/gateway money path.

## User journeys

### J1 — prepare while the incumbent serves

1. Malibu requests a fresh CLI projection.
2. The projection shows a signed, verified, primary `mlx_safetensors` artifact, exact trust source, exact `estimated_bytes`, fit result, and a typed `prepare_model` transaction ID.
3. The provider confirms the size and trust source.
4. Malibu invokes `malibu-cli models transactions run <transaction-id> --json`.
5. The worker emits a closed event stream at least every ten seconds, downloads into its own staging tree, verifies the signed tuple, copies into an unpublished durable temporary tree, and publishes once.
6. The terminal event says local readiness succeeded. A fresh projection confirms readiness. The current config and running model remain byte-for-byte and identity-for-identity unchanged.

### J2 — cancel, fail, or interrupt

1. Malibu invokes `malibu-cli models transactions cancel <transaction-id> --json` while metadata, download, verification, or copy is active.
2. The cancel command writes one exact attempt-bound marker. The worker observes it at every bounded loop and immediately before publication.
3. Before publication, the worker returns `cancelled` and removes only the recorded staging and unpublished temporary tree. If cleanup fails, it returns `staging_cleanup_required` and blocks a later operation until exact cleanup succeeds.
4. If the process crashes, the kernel releases the flock. The next status or run marks the attempt `interrupted`; it does not resume partial bytes. A retry uses a new attempt ID, cleans only the recorded unpublished paths, and starts again.
5. If the exclusive publication already committed, cancellation is too late and the exact published artifact remains. The terminal result is `succeeded` with `cancellation_too_late`, never a false `cancelled`.

### J3 — adopt after readiness

1. A fresh projection re-qualifies the current signed candidate/artifact feed and re-hashes the durable destination.
2. When the running provider already carries the exact target authority, the CLI enters the existing `RecommendationAdoptionLock`/journal/control-socket flow (`RecommendationAdoptionJournal.swift:97-124`, `ModelsSubcommand.swift:1066-1127`).
3. When the running provider lacks the exact authority, the CLI may request `refresh_prepared_artifact_authority.v1` on the existing control socket. The server authenticates the same effective UID (`ControlSocket.swift:1388`, `:2061-2069`), independently reloads signed authority, derives the durable location, and verifies the canonical artifact hash. The requester's identity assertion or path is never authoritative.
4. An accepted refresh only adds an in-memory target authority. The separate adoption transaction still checks the incumbent, takes its short runtime reservation, updates config through its journal, loads the model, drains, and atomically swaps. Existing atomic swap preserves the incumbent until commit (`ModelRuntime.swift:1482-1503`, `:1613-1638`).

### J4 — old client or unavailable capability

An app or CLI that does not advertise the slice 6 preparation capability renders the existing static/current-model fallback and cannot run preparation. Unknown schemas, unknown fields, stale IDs, mismatched tuples, or unsupported transaction kinds make only the affected action unavailable. They do not alter the incumbent or fall through to legacy `models browse`/`models list` behavior.

## Ownership and trust boundaries

| Component | Owns | Must not own |
|---|---|---|
| Projection builder | Qualified current feed, row-to-reservation tuple, stable IDs, readiness readback | Downloads, app-local heuristics, admission mutation |
| Initiating CLI worker | Flock, active attempt, staging, verification, exclusive publication, events | Background survival, config, live runtime, offer/admission/economics |
| Cancel/status CLI | Bounded readback; exact cancel marker | Killing the worker, deleting arbitrary files, changing active tuple |
| Malibu | Confirmation, process invocation, event rendering, cancel/status invocation, fresh projection | Filesystem access, feed verification, inferred action availability |
| Serving CLI | Existing owner-only socket, signed-authority reload, durable re-verification, adoption and warm swap | Trusting requester paths/hashes, downloading during adoption |
| Coordinator/BYOM | Offer, decision, routing, admission, settlement authority | Local preparation custody |

The trust boundary is the effective POSIX UID. Every process with the same EUID is intentionally allowed to inspect status and request cancellation; another UID is refused by filesystem ownership/mode checks and by the existing control-socket peer check. This is an explicit local-user boundary, not a claim of isolation between same-UID processes.

## Dependency gates

1. PR #1481 merged as `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a`. It lands the slice 5 intake mechanism, generator, coordinator surfaces, tests, and monthly release runbook. It does not land preparation UX, the first evidenced listed-tier production release, the settlement journey, or provider release evidence. Slice 5 advances the queue to 5/7; it does not unblock final Build 1 acceptance. `specs/CONFORMANCE.json` still keeps SPEC-023-R006 pending until the first listed-tier release and signed prerequisite evidence exist.
2. The landed #1481 overlap with the abandoned dirty Build 1 branch is now reconciled as owned by main. Do not salvage old-branch edits to these eight paths:
   - `phase4-coordinator/cmd/coordinator/main.go`
   - `phase4-coordinator/internal/buyer/autotune_feeds.go`
   - `phase4-coordinator/internal/buyer/server.go`
   - `phase4-coordinator/internal/ws/model_admission.go`
   - `phase4-coordinator/internal/ws/server.go`
   - `specs/CONFORMANCE.json`
   - `specs/README.md`
   - `specs/SPEC-047-network-model-admission.md`
3. This clean reservation plan consumes the landed slice 5 baseline but does not modify or duplicate its coordinator, generator, intake, or SPEC-017/SPEC-023/SPEC-047 implementation.
4. The handoff at `4bbb7eed` says the existing SPEC-044 typed-transaction contracts are frozen and slice 6 (#1485) is client-side Swift work with no SPEC-authority change. Therefore this plan must implement `model_catalog_economics.v1`, `model_catalog_transaction_event.v1`, and the existing closed `prepare_model`/`cleanup_staging` action grammar without amending SPEC-001, SPEC-044, SPEC-046, or SPEC-047. Reconcile file ownership and the exact provider-visible admission-state set with #1485 before editing overlapping Swift files. Operator-provided non-earning disclosure strings are a required input for Malibu copy and must not be invented.
5. Slice 7 (#1486) remains the physical-hardware, signed-evidence, conformance, and release gate for `JOURNEY-NETWORK-MODEL-ADMISSION`. The actual `specs/CONFORMANCE.json` baseline also keeps `JOURNEY-PROVIDER-BYOM-DISCOVERY` pending despite issue #1453 marking slice 1 complete; Build 1 may not claim that journey from the issue checkbox. Current CONFORMANCE rows are authoritative and both missing signed journey results remain qualification blockers (`specs/CONFORMANCE.json:7359-7862`).

## Dependency graph

```text
landed slice 2c signed artifact feed
                |
landed slice 5 intake (#1481); old dirty overlap rejected
                |
                v
slice 6A: reconcile #1485 ownership + operator copy input
                |
     +----------+-----------+
     |                      |
     v                      v
6B reservation/state    6C Malibu/CLI action wiring
     |                      |
     +----------+-----------+
                v
6D serve-side authority refresh + existing adoption handoff
                |
                v
slice 7 real MLX + discovery/admission journeys + settlement + release
```

No implementation slice may bypass 6A. Slice 7 may not infer readiness or settlement from unit fixtures.

## Normative local contracts

These implementation details refine the already frozen SPEC-044 v1 action/event contracts. They do not create a new public schema or authorize a SPEC amendment. Any incompatibility discovered during the plan or implementation audit blocks the work and returns to the relevant SPEC owner rather than changing authority inside slice 6.

### Authority root and filesystem profile

Root: `~/.config/macprovider/model-preparation-v1/`, exactly one per effective UID.

```text
model-preparation-v1/             0700, owner EUID, local filesystem, no ACL
  operation.lock                  0600 regular file, one live flock
  reservations.json               0600, <= 131072 bytes
  active.json                     0600, <= 32768 bytes, one operation record
  cancel.json                     0600, <= 4096 bytes, zero or one marker
  staging/<transaction>/<attempt>/ 0700, exact active-attempt ownership
```

Open directories by descriptor with `O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW`; require owner EUID, exact mode, local filesystem, no mount transition, and no extended ACL. Open files with `O_NOFOLLOW|O_CLOEXEC`; require regular file, owner EUID, link count one, exact mode, and bounded size. Use the established protected-custody pattern (`ProviderCredentialStore.swift:177-288`, `:380-405`, `:525-614`) without placing preparation data in the credential namespace.

Every JSON write uses a fixed, same-directory temporary leaf, `O_CREAT|O_EXCL`, full write, `fchmod`, `fsync(file)`, bounded validation, atomic `renameat` (or `renameatx_np(RENAME_EXCL)` for create-only publication), then `fsync(directory)`. After a crash, the next lock owner may remove only that exact temporary leaf after descriptor-based owner/type/link/mode validation; an unexpected object blocks the operation. Unknown fields, duplicate keys, floats, negative integers, invalid UTF-8, trailing bytes, and over-limit input fail closed.

### Reservation snapshot

`reservations.json` is `model_preparation_reservations.v1`. Its exact top-level fields are `schema`, `provider_uid`, `provider_id`, `config_identity_sha256`, `generated_at`, `generation`, and `reservations`. It contains at most 64 entries and 131072 bytes. `provider_uid` is an unsigned 32-bit integer; `generation` is an integer in `0...9007199254740991`. Timestamps are UTC RFC3339 seconds with `Z`.

Each entry has exactly `transaction_id`, `transaction_kind`, `tuple_sha256`, and `target`. `transaction_id` is a lowercase UUID; `transaction_kind` is only `prepare_model`. `target` has exactly:

```text
model_key, model_id, model_revision, artifact_id,
runtime_format, hash_algorithm, artifact_hash,
source_kind, source_repo_id, source_revision,
release_id, candidate_catalog_sha256,
artifact_feed_sha256, artifact_feed_signer_key_id,
estimated_bytes
```

Build 1 accepts only a qualified primary artifact with `runtime_format=mlx_safetensors`, `hash_algorithm=macprovider.snapshot-manifest.v1`, `source_kind=huggingface_revision`, `source_repo_id == model_id`, immutable 40-lowercase-hex `source_revision == model_revision`, `verification_status=verified`, and primary hash equal to the signed candidate row (`AutotuneArtifactFeed.swift:80-89`, `:318-328`, `:421-435`). `estimated_bytes` is required and must be `1...1099511627776` (1 TiB). Text fields are UTF-8, contain no control/NUL characters, and use these byte caps: provider, model, and repo IDs 256; model key, release ID, and signer ID 128; artifact ID 64; source kind/runtime/hash algorithm 64. `provider_id` is nonempty; `artifact_id` retains SPEC-023's `^[a-z0-9][a-z0-9-]{0,63}$` grammar. Digests are exactly 64 lowercase hexadecimal characters. `config_identity_sha256` is SHA-256 of the exact securely opened current config bytes, whose preparation read is capped at 1048576 bytes; preparation never rewrites those bytes.

`tuple_sha256` is SHA-256 of `"model-preparation-tuple-v1\0"` followed by every target/binding field in the order above plus `provider_uid`, `provider_id`, and `config_identity_sha256`. Integers use unsigned big-endian fixed width; byte strings use unsigned 32-bit big-endian length followed by UTF-8 bytes; hex digests contribute decoded 32-byte values. This binary framing is the sole digest codec. Malibu never computes it.

For an unchanged complete tuple, projection refresh preserves its UUID. A new tuple receives a lowercase UUID v4 from at least 128 bits of CSPRNG input. A tuple change creates a new UUID and removes the old entry. The snapshot writer takes `operation.lock` briefly when no operation is active. While the worker holds the lock, projection is read-only and may expose only the frozen entries. A missing/corrupt snapshot may be rebuilt only when no live or interrupted operation exists; otherwise all preparation actions fail closed.

### Active operation slot

`active.json` is `model_preparation_operation.v1`, one record only, and at most 32768 bytes. It duplicates the complete target tuple so a projection refresh cannot change an in-flight operation. Exact fields are `schema`, `transaction_id`, `attempt_id`, `tuple_sha256`, `provider_uid`, `provider_id`, `config_identity_sha256`, `target`, `state`, `phase`, `started_at`, `updated_at`, `deadline_at`, `bytes_completed`, `files_completed`, `cancel_observed`, `publish_committed`, `terminal_error_code`, and `terminal_warning_code`.

`attempt_id` is a fresh lowercase UUID on every retry. `state` is `running`, `cancel_requested`, `cancelled`, `succeeded`, `failed`, `timed_out`, or `interrupted`. `phase` is `reserved`, `metadata`, `downloading`, `verifying_staging`, `copying_durable`, `publish_ready`, `published`, `cleanup`, or `terminal`. The action deadline is `1...1800` seconds, matching SPEC-044-R002. Counters are integers in `0...9007199254740991`. Error and warning enums are closed by slice 6.

The initiating process acquires `operation.lock` with `LOCK_EX|LOCK_NB` before creating or replacing this record and retains the file descriptor until terminal state and cleanup are durable. A second run receives `operation_busy`. Status distinguishes a live worker (flock unavailable) from a crashed worker (flock acquirable). Wall-clock timestamps are display/audit fields only; the live worker enforces its deadline with monotonic elapsed time. There is no PID, worker record, lease heartbeat authority, or liveness inference from timestamps.

The proposed command grammar is exactly `malibu-cli models transactions run <transaction-id> --json`, `status <transaction-id> --json`, and `cancel <transaction-id> --json`. `run` remains attached as the worker and writes the existing `model_catalog_transaction_event.v1` JSON-lines family; there is no detach/background flag. `status` and `cancel` are separate short-lived CLI processes. Unknown flags, absent IDs, or extra positional arguments fail before state access.

### Cancellation marker

`cancel.json` is `model_preparation_cancel.v1`, at most 4096 bytes, with exactly `schema`, `transaction_id`, `attempt_id`, `tuple_sha256`, `provider_uid`, `provider_id`, `config_identity_sha256`, and `requested_at`. `models transactions cancel` first reads the bounded active record, requires the caller EUID/provider context and every identity field to match, and atomically writes the marker. Repeated identical requests are idempotent. A stale or mismatched marker is never applied to another attempt.

The worker checks the marker before and after each metadata request, each file transfer, each hash/copy chunk no larger than 8 MiB, and immediately before the publication rename. The cancel process does not acquire the live operation flock, signal/kill the worker, or delete files.

### Artifact work bounds

One attempt may process at most 4096 regular files, tree depth 32, and 1024 UTF-8 bytes per relative path. Symlinks, hard links, devices, sockets, FIFOs, sparse-file logical-size overflow, `..`, absolute paths, control characters, case-fold collisions, duplicate normalized paths, cross-device/mount traversal, and aggregate bytes above `estimated_bytes` are rejected. The verified aggregate regular-file size must equal `estimated_bytes`. Every read and copy loop is chunked at no more than 8 MiB and checks cancellation/deadline between chunks. Metadata responses and decoded JSON retain the existing bounded HTTP/parser policy; slice 6 must add explicit 4096-sibling and 131072-byte metadata-body gates if the existing downloader cannot prove them.

Before transfer, free space must be at least `2 * estimated_bytes + 1073741824`, calculated with checked unsigned arithmetic. This covers staging plus unpublished durable copy and 1 GiB reserve. Failure is `insufficient_disk_space`, without deleting any durable artifact.

### Publish-once durable artifact

The final destination remains the existing content-addressed durable path derived from `(model_id, model_revision, artifact_hash)` (`DurableModelArtifactStore.swift:38-59`). Preparation must not call `gcInactive` (`:121-158`). General durable GC is unused and outside this design.

The worker copies verified staging to a transaction-derived unpublished sibling under the final destination's parent, validates every entry again, computes the canonical snapshot hash and byte/file totals, fsyncs all files and directories, then publishes with `renameatx_np(..., RENAME_EXCL)`. The destination is never replaced.

If the destination already exists, the worker securely opens and re-verifies it. An exact tuple/hash/size match is idempotent success. Any mismatched content, file type, ownership, link count, or size is `durable_destination_conflict`; the worker preserves the destination and incumbent and never deletes or repairs it. Once the exclusive rename succeeds, `publish_committed=true` is irreversible for the transaction. No automatic process removes a successfully published durable artifact.

### Crash and retry semantics

The design promises interrupted-and-retry, not continuation.

| Crash point | Next status/run behavior |
|---|---|
| Before active record | No operation exists; start normally. |
| After active record, before staging | Acquire released flock, mark `interrupted`, remove no bytes, retry with new attempt. |
| During download/verify/copy | Mark `interrupted`; validate and remove only the exact paths named by the active tuple/attempt; start from zero. |
| Immediately before publication | Destination absent means interrupted cleanup/retry. |
| Rename committed, state not updated | Re-verify exact destination; return idempotent `succeeded`; never resume or republish. |
| Destination exists but mismatches | Fail closed with `durable_destination_conflict`; preserve all durable bytes. |
| Cleanup fails | Persist `staging_cleanup_required`; block another operation until exact cleanup succeeds. |

Only `staging/<transaction>/<attempt>` and its exact unpublished durable sibling may be removed. No unbounded directory scan is an authority mechanism. `cleanup_staging` accepts only the transaction ID currently retained in `active.json` and uses the recorded attempt/tuple to derive both paths.

## Preparation/adoption exclusion and readiness handoff

Slice 6 extends the existing adoption entrypoint with the provider-UID `operation.lock` as its outermost local model-mutation guard. Lock order is always:

```text
provider-UID operation.lock
  -> RecommendationAdoptionLock (config-path lock)
  -> owner-only control socket
  -> ModelRuntime prepared/active adoption reservation
```

Preparation holds only the first lock. Adoption takes the first lock for its existing transaction and then the established guards. Status and cancel take neither long-lived lock. This proves preparation and adoption cannot overlap without making the multi-gigabyte transfer consume a runtime lease.

`refresh_prepared_artifact_authority.v1` is allowed only after publication and only if `ModelRuntime.targetAuthorities` lacks the exact target (`ModelRuntime.swift:726-730`). Its request carries `transaction_id` and `tuple_sha256` only. The serving process:

1. authenticates the peer EUID through the existing socket;
2. independently loads the current signed candidate/artifact authority;
3. resolves the tuple by digest and derives the durable path itself;
4. opens the tree with no-follow rules and recomputes `macprovider.snapshot-manifest.v1`;
5. adds the target to in-memory authority only when every field agrees.

The response is a closed `prepared_artifact_authority_refresh_result.v1` with transaction ID, tuple digest, `accepted`, and a closed nullable reason. It carries no path or feed bytes. Failure leaves the provider running and directs the user to refresh/restart; it never authorizes adoption from a worker assertion. This is the only new live-runtime preparation message.

## Slices and deliverables

### Slice 6A — frozen-contract and ownership reconciliation

- Amend SPEC-001 §6.14a for `models transactions run|status|cancel` and strict taxonomy.
- Map every local field and transition to the frozen SPEC-044-R002/R003/R006/R007/R011 schemas and precedence; do not add public fields or enum values in this slice.
- Confirm SPEC-046 discovery/evaluation copy can direct a qualified candidate to preparation without claiming evaluation, admission, or earnings, using only operator-provided strings.
- Confirm SPEC-047 consumes readiness only through later offer/runtime evidence and grants no state from preparation.
- Record the #1485 file-ownership boundary before edits. Keep AUTHORITY/CONFORMANCE and both pending journey rows unchanged unless a separate authority-owned change and signed evidence land.
- Independent SPEC code/security/architecture review: 0 Critical, 0 High, 0 Medium.

### Slice 6B — provider-UID authority and publish engine

- Add the bounded reservation, active, and cancellation codecs/stores using existing secure filesystem patterns.
- Add stable multi-row projection IDs and exact tuple revalidation.
- Refactor the existing isolated prefetch/download/hash/copy functions rather than duplicating network or identity logic (`AutotuneRecommend.swift:3362-3401`, `:3641-3684`).
- Add chunk cancellation, resource caps, exact cleanup, exclusive durable publication, and idempotent destination verification.
- Do not use general durable GC.

### Slice 6C — CLI and Malibu action surface

- Add `models transactions run|status|cancel` and closed JSON/event output.
- Make `prepare_model` available only for an exact slice 6 reservation; leave other actions unavailable unless already executable.
- Add Malibu confirmation, progress, delayed-response, cancel, cleanup-required, terminal, and fresh-projection reconciliation.
- Preserve the static old-CLI fallback and forbidden-earnings-copy tests. Existing app logic currently offers only switch/evaluate and must be changed only here (`ModelManagement.swift:2648-2682`).

### Slice 6D — adoption handoff

- Enforce the common outer operation lock around existing adoption.
- Add the single optional serve-side re-verifying refresh message and tests.
- Reuse `RecommendationAdoptionJournal` atomic journal and recovery; do not move preparation state into it (`RecommendationAdoptionJournal.swift:136-165`, `:205-226`).
- Prove readiness is followed by a fresh projection and separate adoption; never combine download and warm swap.

### Slice 7 — physical qualification and release

- Run the actual selected primary MLX artifact on a supported physical Apple Silicon Mac.
- Capture and operator-sign the full SPEC-046 discovery journey and SPEC-047 admission journey, including the settlement-capable case.
- Execute route-time identity, receipt, usage, ledger, settlement, and positive provider-credit assertions under the existing SPEC-005 formulas.
- Promote CONFORMANCE only from accepted signed evidence.
- Qualify the signed app/CLI assets and updater with `docs/runbooks/provider-cli-release-verification.md`, including byte identity of embedded and standalone CLI binaries.

## Acceptance criteria

1. At least three projected eligible rows retain distinct stable transaction IDs across unchanged projections; any bound-field change invalidates only its old ID.
2. Exactly one run holds the operation slot across processes; all competitors fail `operation_busy`, and a kernel-released crash can be reconciled.
3. Preparation accepts only one qualified verified primary MLX tuple and rejects stale ID, tuple drift, provider ID/config identity mismatch, wrong UID, non-primary artifact, wrong revision/hash/source/runtime, and missing or stale feed authority.
4. The worker never mutates config, runtime identity, admission, routing, rates, rewards, settlement, or the incumbent durable artifact.
5. Cancellation is terminal before publication in every phase. At the exclusive rename boundary the result is exactly cancelled-before-commit or succeeded-after-commit, with no missing or half-published artifact.
6. Crash handling never claims byte continuation. Retry cleans only exact unpublished paths and either starts from zero or recognizes an already published exact destination.
7. All JSON/filesystem/network/tree/counter limits are enforced at the first byte/item over the stated cap, with zero partial authority.
8. Exclusive publication is idempotent for matching content and refuses to replace, delete, or adopt a mismatched destination.
9. Preparation and recommendation adoption are mutually exclusive under the common outer lock. No 5/15-minute `ModelRuntime` reservation spans preparation.
10. Live authority refresh, when needed, is same-EUID, bounded, path-free, and accepted only after the serving process independently reloads signed authority and hashes the durable tree.
11. Malibu never makes a row actionable from app-local inference, never kills a worker to cancel, never declares success without a terminal event plus fresh projection, and preserves the old-client fallback.
12. Slice 7 proves the real artifact on real Apple Silicon through both signed journeys and correctly settled positive credit. Fixtures alone cannot satisfy final acceptance.
13. Every implementation slice passes fresh targeted tests, Swift tests, applicable Xcode/app tests, governance checks, and independent code/security/architecture reviews with 0 Critical, 0 High, and 0 Medium findings.

The executable test matrix is in `reservation-rebaseline-test-spec-v1.md`.

## Compatibility, migration, and rollback

- There is no migration of unreleased R21-R27 reservation, VFS, database, receipt, worker, or journal formats. Unknown development state under any old root is ignored by production capability discovery and is never imported.
- A malformed `model-preparation-v1` root blocks preparation only. It cannot block existing serving, recommendation, discovery, admission status, or settlement.
- Older apps and CLIs do not advertise/consume the new capability and retain current behavior. A newer app paired with an older CLI renders the static current-model fallback. A newer CLI paired with an older app may expose commands but performs no hidden work.
- Rollback disables advertisement of new preparation actions. In-flight work must be cancelled or allowed to reach a terminal state before replacing the CLI. Published durable artifacts remain inert and are not automatically garbage-collected. Existing config and runtime need no rollback because preparation never touched them.
- If a release is rolled back after the new root exists, old binaries ignore it. Re-enabling the same schema may re-verify an exact published destination; incompatible future schema versions fail closed rather than downgrade.

## Observability and privacy

- `model_catalog_transaction_event.v1` remains the provider-visible event family required by SPEC-044-R002. Each JSON line is capped at 16384 bytes, has matching transaction/kind/model key, monotonic sequence, UTC timestamp, closed state, bounded progress, and redacted closed error/warning codes.
- Active work emits a progress event at least every ten seconds. Malibu marks it delayed after 30 seconds without progress but keeps cancellation available until terminal/deadline.
- `models transactions status` emits one closed response capped at 16384 bytes with `schema: "model_catalog_transaction_status.v1"`. Its exact fields are `schema`, `transaction_id`, `attempt_id`, `transaction_kind`, `model_key`, `tuple_sha256`, `state`, `phase`, `live`, `bytes_completed`, `bytes_expected`, `files_completed`, `files_expected`, `cleanup_required`, `publish_committed`, `terminal_error_code`, `terminal_warning_code`, and `observed_at`; nullable and state-dependent invariants are frozen in slice 6A. It never emits absolute paths, usernames, tokens, feed bodies, model file names, or raw errors.
- Local stderr may name closed stage/error codes and transaction ID. It must not print provider tokens, home paths, URLs with credentials, raw manifests, or source response bodies.
- Tests expose injectable state-transition and publication-boundary hooks only in test builds. Production has no hidden IPC or debug bypass.

## Hardware and release requirements

- Unit/integration filesystem tests run on macOS 14+ on a local APFS volume because `flock`, `renameatx_np(RENAME_EXCL)`, no-follow descriptor traversal, and durability semantics are part of the contract.
- Slice 7 requires a physical supported Apple Silicon Mac, a signed release candidate, the actual signed primary MLX artifact selected from the release, enough free disk for the stated two-copy reserve, a live coordinator/gateway with settlement enforcement, a receipt key, and operator access to capture/sign/promote both journeys.
- The acceptance Mac should include a <=16 GB fleet-representative machine when the selected catalog row supports it. If the actual artifact cannot prepare, load, serve, and settle within its declared fit and 1800-second preparation deadline, Build 1 remains unqualified; caps are not raised to make the test pass.

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Same-UID process cancels work | Explicit same-UID trust boundary; exact transaction/attempt/tuple marker prevents accidental cross-attempt cancellation. |
| Crash leaves partial bytes | One active record names every removable path; released flock triggers interrupted reconciliation; no continuation claim. |
| Destination race or corruption | Same-parent unpublished tree, full re-verification, `RENAME_EXCL`, and mismatch preservation. |
| Feed changes during download | Revalidate the complete tuple immediately before publication; stale tuple fails and a new reservation is required. |
| Long download blocks adoption | Deliberate mutual exclusion protects local model mutation; no runtime lease is held. Status/cancel remain available. |
| State grows without bound | Two bounded JSON records, one marker, one active operation, 64 reservations; no per-worker or per-attempt journal set. |
| Runtime trusts local claim | Serve reloads signed authority and hashes the destination itself over the existing owner-only socket. |
| Cleanup deletes useful model | Delete only the exact active attempt's unpublished paths; never call general durable GC and never remove a published destination. |
| UI overstates readiness/earning | Terminal plus fresh projection required; preparation does not change admission/economics and forbidden-copy tests remain release gates. |

## Qualification blockers

Build 1 is not complete while any of these is true:

- Any implementation attempts to revive old dirty edits in the eight #1481-owned paths or to change the landed slice 5 authority.
- Slice 6 overlaps #1485 without an explicit file-ownership reconciliation, or provider admission-state/copy inputs are unresolved for the affected Malibu surface.
- Any stated cap, cancellation phase, cross-process race, crash boundary, malicious filesystem case, or destination mismatch lacks executable coverage.
- The common preparation/adoption exclusion or serve-side independent verification is absent.
- Any independent full-diff code, security, or architecture lane reports a Critical, High, or Medium finding.
- Malibu/CLI old-client capability fallback or exact copy tests fail.
- Either signed SPEC-046 discovery or SPEC-047 admission journey is missing.
- The real MLX/hardware/receipt/settlement/positive-credit journey is not captured from the signed release candidate.

## Explicit non-goals and rejected designs

- No root daemon, launch daemon, helper tool, Mach service, XPC service, privileged broker, or new long-lived process.
- No SQLite database, custom VFS, WAL, broker CAS, page budget, or storage engine.
- No signed local receipts, local signing key, witness chain, maintenance lease, or operator-destruction protocol.
- No worker records, PID/pidversion authority, reconnect protocol, per-worker files, or 1024-entry journal.
- No migration or compatibility bridge for unreleased R21-R27 formats.
- No automatic durable artifact garbage collection. The existing `gcInactive` is not used.
- No preparation-time config edit, symlink promotion, runtime swap, admission decision, pricing conversion, offer submission, route eligibility, or settlement claim.
- No GGUF preparation in Build 1; the reservation supports only the primary MLX artifact.
- No post-crash continuation or partial-download resume claim. A clean retry is the supported recovery.

The rejected R27 review is historical negative evidence only: `reservation-search-progress-r27-plan-sol.md`, SHA-256 `e8c1a80479c6185202201b38f30dbc019ef80ca5aefe0e3f4efd8e7d75419be3`, verdict BLOCK with 6 High and 3 Medium findings. Its root/XPC/SQLite/VFS/signed-witness/worker-record design is not an input contract and grants no approval to this plan.

## Evidence anchors

- Signed primary feed identity and qualification: `phase3-binary/Sources/macprovider-cli/AutotuneArtifactFeed.swift:4-20`, `:80-89`, `:421-435`, `:500-525`.
- Existing isolated incumbent-preserving prefetch: `phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:3641-3684`.
- Existing durable copy and its current non-atomic/delete-capable limitations: `phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift:84-121`.
- Existing filesystem safety patterns: `phase3-binary/Sources/macprovider-cli/ProviderCredentialStore.swift:177-288`, `:380-405`, `:525-614`.
- Existing adoption lock and atomic bounded journal: `phase3-binary/Sources/macprovider-cli/RecommendationAdoptionJournal.swift:97-165`, `:205-226`.
- Existing runtime adoption reservation and atomic warm swap: `phase3-binary/Sources/macprovider-cli/ModelRuntime.swift:729-739`, `:1482-1638`, `:1642-1755`.
- Existing same-EUID control socket: `phase3-binary/Sources/macprovider-cli/ControlSocket.swift:1388`, `:2061-2069`.
- Missing CLI projection actions and Malibu prepare execution: `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift:423-427`; `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:2648-2682`.
- Current normative action/preparation rules: `specs/SPEC-044-malibu-model-catalog-economics.md:88-102`.
- Current discovery no-hidden-mutation and journey gate: `specs/SPEC-046-provider-byom-discovery.md:78-127`.
- Current admission and signed journey gate: `specs/SPEC-047-network-model-admission.md:86-151`.
