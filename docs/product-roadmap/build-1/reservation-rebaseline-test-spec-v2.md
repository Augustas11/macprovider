# Build 1 preparation-reservation rebaseline test specification v2

Status: acceptance specification for `reservation-rebaseline-plan-v2.md`. Tests may be implemented only after the operator-owned authority commit required by T18 lands.

Baseline: `c4401f1791d593d37d68eba91af94219b26d278f`.

## Test rules

- All fixtures use unique temporary authority and artifact roots with explicit EUID ownership. No test touches the operator's real config, model store, credentials, feeds, or running provider unless T21-T24 explicitly designate a controlled qualification Mac.
- Public decoders remain closed. Tests distinguish private persistence records from the public `model_catalog_economics.v1` projection and `model_catalog_transaction_event.v1` stream.
- Every failure assertion includes filesystem state, lock state, config hash, incumbent identity, public terminal event when one is authorized, and fresh projection result.
- Fake clocks cover wall/monotonic boundaries; deterministic barrier hooks cover process ordering. SIGKILL proves crash behavior only. Real reboot/power interruption on APFS is required for stable-media claims.
- Cancellation and deadline tests use production delegate/watchdog code, not a test-only transfer loop.
- A skipped, timed-out, interrupted, or unavailable test is not a pass.

## Proposed test surfaces

| Surface | Coverage |
|---|---|
| `ModelPreparationPrivateCodecTests` | Strict local codecs, tuple/root identity, selection history, golden vectors |
| `ModelPreparationSelectionTests` | 64/65/128/256 bounds, fairness, churn, restart, dispatch races |
| `ModelPreparationRootTests` | Config/environment roots, descriptor identity, different volumes, replacement/recovery |
| `ModelPreparationTransferTests` | Real throttled HTTP, delegates, watchdog, caps, Range resume, custody |
| `ModelPreparationDurabilityTests` | Tree barriers, exclusive rename, cross-filesystem recovery, tombstones |
| `ModelPreparationInventoryTests` | Bounded accounting, keep set, budgets, unique releases, cleanup recovery |
| `ModelPreparationIntegrationTests` | Locks, projection/actions/events, cancellation, incumbent invariants |
| `ModelAdoptionIntegrationTests` | Existing request handler feed reload, identical-root proof, warm swap |
| `ModelCatalogEconomicsTests` | Existing projection/action schema, authority-approved extension, copy/gating |
| Malibu unit/UI/accessibility tests | Confirmation, event rendering, refresh, exact operator copy, fallback |
| Real-Mac qualification harness | APFS power/reboot, MLX serving, journeys, settlement, signed assets/updater |

## T01 — frozen public authority and strict private codecs

### T01.1 public contract inventory

At the exact authority commit from T18, assert:

- projection read remains `malibu-cli models catalog-economics --json`;
- row actions use the authority-approved `prepare_model`, `cleanup_staging`, and separately approved published-cleanup kind;
- progress/results use only `model_catalog_transaction_event.v1` and its seven existing public states;
- no transaction-status schema, `models transactions` command family, extra public crash state, late-cancellation enum, or new control-socket refresh frame exists;
- `cleanup_staging` cannot select or delete a published artifact.

Golden public fixtures reject unknown fields/enums, mismatched transaction ID/kind/model key, non-monotonic event sequence, illegal nullability, and malformed timestamps. A malformed affected event/row fails locally without rejecting another valid row.

### T01.2 private record round trips

Round-trip the exact v2 reservation, active, cancellation, root identity, inventory, and deletion records at minimum/maximum legal sizes. Reject duplicate/unknown keys, floats, negative/overflow integers, invalid UTF-8, trailing bytes, wrong schema, wrong EUID/provider/config/root binding, over-limit collections, and records one byte above each cap.

### T01.3 tuple and identity golden vectors

Check independently generated golden digests for every field boundary, Unicode byte length, integer framing, decoded hex, config hash, canonical root path, `st_dev`, `st_ino`, and root-identity digest. Mutating any single byte changes `tuple_sha256`. Different textual paths that initially resolve to the same descriptor canonicalize to one binding; path replacement after binding never aliases it.

## T02 — deterministic bounded selection without starvation

### T02.1 64 and below

For 0, 1, 3, and 64 eligible tuples, feed permutations, process restarts, and stable config/root identities produce the same selected identities and UUIDs. One tuple mutation replaces only its ID. Removal and re-entry follow the exact fairness rules.

### T02.2 65 eligible tuples

Build 65 signed eligible rows in every input permutation. Assert exactly 64 actions, identical slot order, one deterministic eviction, preserved IDs for unchanged retained entries, and selection of the waiting tuple within the stated fairness bound. Repeat through 20 successful generations and restart between generations.

### T02.3 128 eligible tuples and churn

For 128 tuples, record every generation until each tuple is selected. Assert no continuously eligible tuple exceeds `ceil((128-56)/8)+1` generations without selection, fairness selection is deterministic, and the 56 retention-priority seats keep unchanged IDs. Mutate/remove/add rows on both sides of the cutoff, reorder input, and restart. Assert only specified selection/ID changes.

### T02.4 maximum history and overflow

At 256 eligible tuples, prove every continuously eligible tuple enters within the documented bound and state remains capped. At 257, the projection makes preparation unavailable rather than silently dropping an untracked tuple, while other catalog data remains renderable.

### T02.5 dispatched action race

Place a barrier between dispatch validation and active-record persistence while a projection rewrite tries to evict the same ID. Exercise both lock orders 1,000 times. If dispatch wins, `active.json` is durable and the tuple remains pinned. If rewrite wins, invocation produces the authority-approved stale/action-unavailable failure with zero filesystem/network side effects. No third outcome, duplicate worker, or ID reuse is allowed.

## T03 — one active operation and kernel lock

Fork independent processes. The first takes the live flock and persists one active attempt. Concurrent run, inventory cleanup, and adoption requests obey the fixed lock order and cannot create a second active/deletion record. Projection reads are bounded and do not infer liveness from timestamps or PID.

Kill the owner at every private phase. The kernel releases the flock. A new process performs private recovery and emits no invented public crash state. Until exact recovery finishes, the prepare action is unavailable and existing warning/action fields describe the block.

## T04 — custom-root crash recovery

### T04.1 environment and config roots

Run the full projection → dispatch → download → publish → projection lifecycle with the default root, `MACPROVIDER_MODEL_ARTIFACT_ROOT`, and `model_artifact_root`. Assert each reservation/active/tuple/inventory record binds canonical path, `st_dev`, `st_ino`, and identity digest.

### T04.2 changed inputs after crash

Crash with unpublished bytes in root A. Change environment and config to root B before recovery. Recovery must ignore B, reopen only the saved canonical A path without symlink traversal, validate all identity fields, and remove/resume only A's recorded unpublished object. B remains byte-for-byte untouched. Repeat with A and B on different APFS volumes.

### T04.3 root moved, replaced, or remounted

After crash, replace the saved path with a directory having the same mode/owner and seeded lookalike files; test symlink replacement, mount change, different `st_dev`, different `st_ino`, copied identity record, and inode-reuse simulation. Every mismatch blocks cleanup/publication. Restoring the original directory at the original canonical path permits recovery; supplying a new config path never does.

### T04.4 serving root mismatch

Prepare in A, then start the server configured for A and for B. A may verify readiness after independent feed reload/hash. B must reject the existing adoption request result without reading requester paths or searching other roots.

## T05 — stale IDs, tuple drift, and authority drift

After projection, independently change each of model revision, artifact hash, release ID, signer, candidate/feed digest, estimated bytes, provider ID, config bytes, canonical root path, root device/inode, and identity digest. Dispatch must fail before network or durable writes. A fresh projection issues a new action ID only where authority still permits it.

Expire/revoke the signed feed during download, verification, before rename, after rename/before parent sync, and before adoption. Pre-linearization drift prevents publish. Post-linearization drift may leave inert bytes but cannot report actionable readiness or grant adoption without current authority.

## T06 — production transfer cancellation and deadline

Use a real local HTTPS test server that serves a multi-chunk file slowly, records bytes sent, supports Range plus strong ETag, can stall, truncate, redirect, mutate ETag, lie in `Content-Length`, and return malformed `Content-Range`. Use production `URLSessionDataDelegate` and watchdog. Retain the existing bounded redirect, response-body, and parser policies; no retry or redirect may reset aggregate accounting.

### T06.1 cancellation latency and heartbeat

During metadata, a flowing response, a stalled response, verification, durable copy, and publish-ready, write the real attempt-bound cancellation marker from a second process. Assert marker observation and `task.cancel()` call within 250 ms, terminal completion within 2 seconds in the supported test profile, event heartbeat gaps no longer than 10 seconds, `cancel_requested` then `cancelled` before the durable boundary, and no publication.

### T06.2 callback/write bounds

Deliver delegate callbacks above and below 1 MiB. Assert processing is split into at most 1 MiB quanta, cancel/deadline/cap checks occur before every quantum, staged writes never exceed the signed aggregate cap, and the server sends at most cap plus one callback quantum. At the first callback crossing the cap, cancellation occurs before any excess byte is written.

### T06.3 temporary and resume custody

Assert URLSession shared cache/cookies/credentials and opaque resume data are unused. All partial and resume metadata live under the recorded attempt root with correct descriptors/modes. A transient disconnect with unchanged strong ETag resumes within the same attempt from the fully synced offset. Wrong/missing ETag, wrong range, process crash, or new attempt deletes recorded partial/resume metadata and restarts from zero.

### T06.4 deadline and callback termination

Advance monotonic time across deadline during flow and stall. Assert task cancellation within one watchdog interval, public `timed_out`, no wall-clock dependence, bounded descriptor/session shutdown, and no callback writes after terminal state.

## T07 — cancellation and failure at every publication barrier

Instrument exact barriers: each file `fsync`; each file `F_FULLFSYNC`; publication-receipt write/sync; every bottom-up directory `fsync`/`F_FULLFSYNC`; private publish-ready write; pre-rename validation; exclusive `renameatx_np(RENAME_EXCL)`; destination-parent `fsync`; destination-parent `F_FULLFSYNC`; active terminal file sync; authority-parent sync; event emission.

For each barrier, inject syscall failure before and after completion and run process-level SIGKILL. Assert:

- no success event before all artifact and authority barriers complete;
- cancellation before rename yields cancelled and exact cleanup;
- destination collision is never overwritten;
- failure before destination-parent stable-media sync remains recovery-required and never trusts terminal state alone;
- failure after destination-parent stable-media sync verifies the final receipt/hash, repairs active state, and yields ready on a fresh projection;
- failure after durable active state but before event is observed through projection, with no invented event replay/status schema.

Run the matrix with authority/artifact roots on one APFS volume and separate APFS volumes.

## T08 — malicious filesystem and root-identity matrix

For authority root, artifact root, root identity, lock, JSON files, staging components, unpublished/final trees, inventory, and tombstone, test symlink, hard link, FIFO, socket, device, wrong owner, wrong mode, ACL, excessive link count, oversized file, swapped descriptor target, mount transition, case-fold collision, Unicode normalization collision, dot/absolute traversal, 4097th path, depth 33, and unexpected sibling.

Every case fails closed before unrelated deletion. Saved-path recovery never follows changed environment/config. Cleanup removes only descriptor-validated recorded leaves. Tests record no secret/path-bearing public output.

## T09 — bounded state, transfer, inventory, and budget

### T09.1 local state caps

Exercise 10,000 success/cancel/fail/recovery attempts. Assert one active record, one cancel marker, one deletion record, at most 64 selected actions, at most 256 selection-history/inventory identities, and every byte-size cap. Terminal compaction cannot erase evidence needed for exact recovery.

Feed streaming inputs that exceed each cap by exactly one: reservation/inventory 262145 bytes, active 65537, cancel 4097, deletion 32769, event line 16385, metadata 131073, config 1048577, sibling/file count 4097, path 1025 bytes, depth 33, estimate 1 TiB + 1, aggregate `estimated_bytes + 1`, deadline 1801 seconds, and integer `9007199254740992`. Rejection must use bounded memory and stop reading an infinite/slow body at the cap.

### T09.2 aggregate transfer cap

Serve multiple files whose declared and actual totals hit exactly `estimated_bytes`, exceed by one byte, and exceed by one callback quantum. Assert the exact cap succeeds; excess cancels before excess disk write; early Content-Length excess cancels before body acceptance; cumulative redirects/retries/ranges cannot reset accounting.

### T09.3 unique-release budget

Publish distinct verified identities for successive releases until the global budget has one byte remaining, reaches exactly zero, and would exceed by one byte. Assert totals use verified inventory, exact-fit is allowed with reserve satisfied, over-budget preparation is unavailable before download, and no automatic artifact deletion occurs. Repeat on a custom root and after restart.

### T09.4 inventory overflow and unexpected objects

Enumerate 256 valid identities, 257 valid identities, and 256 plus an unexpected object. At 256 totals are exact. Overflow or an unexpected object makes totals/cleanup unavailable and preserves every artifact; it never truncates into a misleading reclaimable number.

## T10 — publish-once, accounting, and identity-safe cleanup

### T10.1 fresh and existing destination

Fresh publication follows the exact T07 order. An exact pre-existing final receipt/hash yields idempotent ready after verification without overwrite. A mismatched, incomplete, symlinked, or unverified destination blocks with zero mutation.

### T10.2 stable-media recovery

On an expendable APFS qualification volume, use an external controller to force reboot and lab power interruption immediately after each acknowledged barrier from T07. On reboot, an independent verifier checks directory entry, receipt, hashes, active state, and projection. Evidence labels ordinary reboot, abrupt power interruption, SIGKILL, and injected syscall failure separately. Only abrupt-power cases support the stable-media claim.

### T10.3 keep set

Create identities for incumbent runtime, configured current path, prepared/active adoption, selected and active preparation, live worker, serving verification, unreferenced reclaimable, and same hash/revision under a different root. Inventory marks every protected identity and only the exact unreferenced same-root identity reclaimable. Each keep-set race inserted immediately before tombstone rename aborts cleanup.

### T10.4 provider-confirmed published cleanup

Without provider-confirmed authority-approved `cleanup_published_artifact`, no deletion occurs. With confirmation, select one identity and prove same-parent exclusive tombstone rename, parent full sync, durable deletion record, descriptor-relative unlink, tombstone removal, final parent full sync, record clear, and refreshed totals. `cleanup_staging` rejects the same target.

### T10.5 deletion crash recovery

Crash before tombstone rename, after rename, after deletion-record sync, during every child unlink, after tombstone removal, and before inventory refresh. Recovery uses only the saved original root binding and exact tombstone. It never deletes a newly created final leaf, another release, another root, or a now-protected identity. Repeat across restart and config/environment root change.

### T10.6 no automatic durable GC

Publish A, prepare B, cancel C, adopt B, and leave D reclaimable. Assert A, B, and D remain after projection, cancellation, retry, adoption, provider restart, budget refusal, and staging cleanup. Instrument `DurableModelArtifactStore.gcInactive` and every published-delete entrypoint; fail if any path runs without an approved, provider-confirmed `cleanup_published_artifact` for the exact reclaimable identity.

## T11 — incumbent and forbidden mutations remain unchanged

Across success, cancellation, timeout, network failure, feed drift, cap failure, custom-root mismatch, barrier failure, cleanup, and crash recovery, snapshot before/after:

- provider config bytes and mode/owner;
- current model and runtime generation;
- incumbent request availability and in-flight result;
- provider identity/credentials;
- offer/admission/routing state;
- coordinator/gateway/billing/settlement state;
- payout and reward records.

All remain identical until a separately authorized adoption transaction. Preparation and published cleanup emit no earning, admission, routing, receipt, or credit evidence.

## T12 — preparation/adoption mutual exclusion

Race preparation dispatch, snapshot rewrite, adoption start, server verification, published cleanup, and recovery at each lock boundary. Assert the fixed preparation-lock then adoption-lock/socket/runtime-reservation order, no deadlock, and no config/root/tuple drift under a worker. Preparation does not hold runtime reservations during transfer. Cleanup cannot tombstone a target after adoption or serve verification pins it.

## T13 — existing prepare-adoption handler readiness

### T13.1 authority already loaded

Use the existing `prepareModelAdoptionRequest`/result frames. An already known exact target follows current behavior and does not reload unnecessarily.

### T13.2 absent target reload

Prepare an artifact after the server starts. Send the existing request. The serving process independently reloads signed feeds, validates signer/release/catalog bindings, resolves and descriptor-validates its own configured artifact root, derives the destination from signed identity, compares the publication receipt's root identity with the open root, hashes the complete artifact, and responds through the existing result frame. It treats the frame path/hash as claims only after derivation; the requester cannot choose the root or destination.

### T13.3 refusal matrix

Reject different canonical root, `st_dev`, `st_ino`, root identity, config/provider identity, model/revision/artifact/release/feed/signer binding, stale/revoked/invalid feed, malformed tree, hash/receipt mismatch, owner/mode/ACL/link issue, concurrent tombstone, and incumbent drift. The incumbent continues serving.

### T13.4 restart and race

After server restart, repeat independent reload/verification. Race feed replacement, root config change, cleanup, and adoption. Exactly one authority snapshot wins; no stale in-memory readiness, new frame, or search of alternate roots occurs.

## T14 — CLI projection, invocation, cancellation, and event protocol

Test the exact operator-approved grammar under `models catalog-economics`, including option order, required `--json`/JSON-lines form, missing/extra arguments, unknown flags, TTY/non-TTY behavior, exit codes, stdout/stderr separation, and capability advertisement. No unapproved alias or `models transactions` command is accepted.

Run/cancel uses only closed `model_catalog_transaction_event.v1`. Assert matching IDs/kinds/model key, monotonic sequences, timestamps, progress nullability, heartbeat, terminal uniqueness, cancel precedence, and authority-approved error/warning codes. A late cancellation produces only `succeeded` or `failed`; Malibu then refreshes the projection. Status is always a fresh projection, never a separate response schema.

Cap each public event line at 16384 bytes. Malibu marks progress delayed after 30 seconds without an event but keeps the authority-approved cancellation control available until a terminal event or deadline; delayed UI state is not transaction authority.

## T15 — old-client capability fallback

Cross-test old/new CLI and Malibu combinations. Without the approved prepare capability, Malibu makes no invocation, shows existing static/current-model fallback, and does not infer readiness or cleanup from disk. Unknown compatible projection/event additions affect only the relevant feature. An unsupported projection envelope causes the documented whole-projection fallback.

## T16 — Malibu slice 6 UX, copy, and storage controls

For every admission state in the landed #1485 operator table, render every discovered candidate, lead with the exact earning-verdict line selected from the wire `earning_path_class`, then render the exact state label/meaning and required disclosure. Deliberately disagree wire values with the table's expected mapping and assert the wire verdict wins and a diagnostic is raised.

Prepare shows exact size/trust and confirmation, streams progress/accessibility announcements without excessive frequency, allows cancellation only through the typed CLI interface, and refreshes the projection after every terminal event or child-process loss. Published cleanup shows approved total/protected/reclaimable/budget values, requires identity-specific provider confirmation, and never maps to `cleanup_staging`. Unknown actions/enums disable only the affected control.

Run VoiceOver labels/order, keyboard navigation, Dynamic Type, Reduce Motion, localization expansion, modal focus, cancellation while backgrounded, app restart, and CLI child termination. Public copy exposes no path, secret, prompt, completion, or endpoint.

## T17 — migration, compatibility, and rollback

Place abandoned R21-R27, v1 planning-state, corrupt, future-version, and malicious files beside clean v2 roots. They are not imported, deleted, or used as authority. Upgrade creates only the v2 root and approved capability.

Rollback disables capability/UI actions but preserves published bytes and exact tombstone/staging recovery. A compatible recovery CLI can finish cleanup. Rollback never changes config/runtime/admission and never runs automatic GC. Re-upgrade reconstructs bounded inventory safely under default and custom roots.

## T18 — dependency and governance gates

The test fails unless all conditions hold:

1. `c4401f17` and merged #1481 commit `6f271245` are ancestors of the implementation base.
2. The exact operator-owned SPEC-001/SPEC-044 patch names @Augustas11, updates required authority indexes, freezes catalog-economics invocation/cancellation grammar, closed event errors/warnings, and the separate published-cleanup projection/action/version.
3. The authority patch keeps the existing event schema, adds no status schema/control frame/public crash state/late-cancel enum, and does not overload `cleanup_staging`.
4. `AUTHORITY.json`, SPEC versions, generated indexes, and CONFORMANCE ownership agree.
5. `git merge-base --is-ancestor <authority-commit> <first-6B-implementation-commit>` succeeds and the two commits differ. Authority added in the same or a later implementation commit fails.
6. #1485 operator state/copy file is unchanged by reservation implementation.
7. `JOURNEY-PROVIDER-BYOM-DISCOVERY`, `JOURNEY-NETWORK-MODEL-ADMISSION`, and `SPEC-023-R006` remain pending unless accepted signed evidence independently changes CONFORMANCE.

Archive commit IDs, file hashes, ancestry output, spec-index output, and governance validator output.

## T19 — slice 6 test commands

Run the narrow tests while iterating, then the complete relevant gates:

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

Run the repository's current xcodebuild test command for Malibu.app on a named supported macOS destination. Run `git diff --check`, spec/governance validators, secret scanning, and release-path tests. Record exact command, commit, environment, duration, and result. Do not claim absent test targets already exist; these are required implementation deliverables.

## T20 — independent review gate

After all slice 6 code/tests/docs are complete, review the complete diff from the authority-approved base through the working tree in three independent native-agent lanes:

- code correctness and concurrency;
- security, filesystem custody, URLSession, cancellation, and secrets;
- architecture, authority, custom roots, durability, resources, adoption, and rollback.

Each lane must explicitly disposition B1-V1-H1, H2, H3, M1, M2, and M3 against the exact v2 sections/tests. Any Critical, High, or Medium finding blocks implementation. Fixes trigger full-diff rerun of all lanes and affected tests.

## T21 — real-hardware preparation, durability, and incumbent journey

On a controlled supported Apple Silicon Mac using final signed candidate/artifact feeds and release-candidate CLI/app:

1. Start the incumbent and sustain real inference traffic with at least one request spanning preparation.
2. Prepare a real multi-shard primary MLX artifact through a throttled HTTPS path; capture delegate callback/cancellation/heartbeat/cap evidence without sensitive paths.
3. Repeat on default and custom APFS roots, including a separate APFS volume from the authority root.
4. Execute the T10.2 reboot/power-interruption matrix with an external controller and independent post-boot verifier. Keep SIGKILL evidence separate.
5. Verify publish receipt/hash and readiness after recovery, then adopt through the existing handler's independent feed reload/root/hash path.
6. Prove incumbent success during preparation, no config change before adoption, valid MLX load after adoption, drain/atomic swap, and valid post-swap inference.
7. Exercise provider-confirmed cleanup for an unreferenced unique release and prove every live identity survives.

Signed evidence records hardware class, OS/filesystem/volume layout, exact commits/assets/feed digests, barrier case, external controller log, request results, hashes, and redacted timing.

## T22 — pending SPEC-046 discovery journey

Capture and promote the signed `JOURNEY-PROVIDER-BYOM-DISCOVERY` evidence required by current CONFORMANCE, including opaque endpoint, catalog match, ladder/timing/redaction, restart, and negative matrices. The #1453 issue checkbox is not proof. Local tests alone cannot pass T22.

## T23 — pending SPEC-047 admission and settlement journey

Capture and promote signed `JOURNEY-NETWORK-MODEL-ADMISSION` evidence for the prepared/adopted identity through offer, operator decision, route visibility, accepted buyer request, correct receipt, settlement, and positive provider credit. Verify catalog/rate/admission identity joins and negative states. Preparation readiness cannot substitute for this evidence.

## T24 — first listed-tier and signed release qualification

Cut and evidence the first listed-tier release required by `SPEC-023-R006` on the approved cadence. Build final Malibu.app and standalone tarball, codesign/notarize/staple/package, compare SHA-256 byte identity of embedded `macprovider-cli`, run the prior-stable updater path, and verify capabilities/projection/events/custom-root preparation/adoption from shipped assets. Do not patch immutable public releases.

## Acceptance matrix

| Required claim | Primary tests | Final evidence |
|---|---|---|
| Frozen authority and no invented public protocol | T01, T14, T18 | Authority commit and ancestry record |
| Stable bounded selection without starvation | T02, T03 | 65/128/256/churn/dispatch logs |
| Secure custom-root identity and recovery | T04, T05, T08, T13 | Cross-volume and serving-root evidence |
| Production cancellation/transfer bounds | T06, T09 | Throttled HTTP + real-Mac trace |
| macOS durable publish ordering | T07, T10 | Injected, SIGKILL, reboot, and abrupt-power evidence labeled separately |
| Bounded published storage and safe cleanup | T09, T10, T16, T17 | Unique-release budget and tombstone recovery |
| Incumbent and forbidden state unchanged | T11, T12, T13 | Before/after hashes and traffic results |
| Malibu copy, accessibility, and fallback | T14-T17 | UI/accessibility results using `c4401f17` copy |
| Zero Critical/High/Medium implementation findings | T18-T20 | Three final full-diff reviews |
| Real MLX serving and power-loss recovery | T21 | Signed physical-Mac evidence |
| Discovery conformance | T22 | Accepted signed journey |
| Admission/settlement/positive credit | T23 | Accepted signed journey and ledger evidence |
| First listed tier and signed updater release | T24 | Manifest, asset hashes, notarization, updater result |

## Finding disposition

| v1 finding | Corrective tests | Pass condition |
|---|---|---|
| B1-V1-H1 | T01, T14, T18, T20 | Operator authority predates 6B; only approved projection/event surfaces exist. |
| B1-V1-H2 | T04, T05, T08, T13 | All lifecycle/serving steps bind and prove the original root across input/volume changes. |
| B1-V1-H3 | T07, T10, T21 | Full tree/parent/authority ordering survives injected failure and real abrupt power interruption. |
| B1-V1-M1 | T02, T03 | 65/128/256 rows are deterministic, starvation-free, and dispatch-serialized. |
| B1-V1-M2 | T09, T10, T16, T17 | Budget/totals are bounded; confirmed cleanup is keep-set-safe and crash-recoverable. |
| B1-V1-M3 | T06, T09, T21 | Production delegate/watchdog meets callback, latency, cap, custody, and resume rules. |

## Stop condition

The reservation subplan is implementation-complete only when T01-T20 pass on the complete final slice 6 diff and all three independent reviews report zero Critical, High, and Medium findings. Build 1 is complete only when T21-T24 also pass with final signed assets, accepted signed discovery/admission journey evidence, correctly settled positive credit, first listed-tier release evidence, stable-media qualification, and updater proof. No local fixture, issue checkbox, prepared artifact, or green slice 6 suite can replace those gates.
