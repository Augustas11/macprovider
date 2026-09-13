# Build 1 preparation-reservation rebaseline test specification v1

Status: executable acceptance design for `reservation-rebaseline-plan-v1.md`; no test in this document is credited until the slice 6 implementation exists and the command has been run fresh against the reviewed diff.

Baseline: `4bbb7eedde40759b56a6d42f82aacb8461adff95`.

## Test rules

1. Tests exercise production entrypoints and codecs. Test-only hooks may pause a real phase or inject an I/O result; they may not replace authority checks, hashing, filesystem validation, exclusive rename, flock, or control-socket peer validation with a positive mock.
2. Every command must select at least one test. A skipped, timed-out, interrupted, fixture-only, or zero-test run is not a pass.
3. Race tests use separate processes, not only Swift tasks. Crash tests send `SIGKILL` to the actual worker and prove the kernel lock is released.
4. Filesystem tests run on a local APFS volume. Malicious-path tests verify the target outside the authority root is unchanged.
5. The incumbent proof captures config bytes, current model ID/hash, active durable path identity, control-socket status, and a successful inference before and after the tested preparation edge.
6. Slice 7 uses the signed release candidate and actual MLX weights. Synthetic miniature trees prove mechanics only.

## Proposed test surfaces

| Surface | File |
|---|---|
| Reservation/state/cancel codecs and secure store | `phase3-binary/Tests/macprovider-cliTests/ModelPreparationAuthorityTests.swift` |
| Download, verification, cancellation, publication | `phase3-binary/Tests/macprovider-cliTests/ModelPreparationWorkerTests.swift` |
| Projection/action tuples and old-client fallback | `phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift` |
| CLI process/race/crash behavior | `phase3-binary/Tests/macprovider-cliTests/ModelPreparationCommandTests.swift` plus `test/e2e/model-preparation/` |
| Adoption exclusion and runtime refresh | `phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift`, `ModelRuntimeSwapTests.swift`, `ModelRuntimeHashTests.swift`, `ControlSocketTests.swift` |
| Malibu behavior/copy | `phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift` |
| Physical signed journey | `test/e2e/byom/` plus signed journey capture/build/promote scripts |

Names below are acceptance names. Implementations may group cases, but the named assertions and boundaries remain independently observable.

## T01 — frozen authority and exact codecs

### T01.1 reservation snapshot round trip

Construct the maximum valid 64-row `model_preparation_reservations.v1` snapshot with all string fields at their byte caps and total bytes at or below 131072. Encode, read through the production bounded reader, decode, re-encode, and assert:

- exact closed top-level and row field sets;
- `provider_uid`, `provider_id`, and `config_identity_sha256` survive unchanged;
- every recomputed binary-framed tuple digest equals `tuple_sha256`;
- all 64 transaction IDs are distinct lowercase UUIDs;
- integers contain no decimal/exponent form;
- encoded bytes are deterministic for the same value.

At 65 entries, 131073 bytes, any string one byte over its cap, empty provider ID, artifact ID outside `^[a-z0-9][a-z0-9-]{0,63}$`, `estimated_bytes` 0 or 1099511627777, generation 9007199254740992, duplicate key, duplicate transaction ID, duplicate tuple under different IDs, unknown field, invalid UTF-8, trailing byte, float, negative integer, non-UTC timestamp, uppercase digest, or malformed/non-v4 UUID, the complete snapshot is rejected and no action is advertised.

### T01.2 active and cancellation codecs

Round-trip the maximum 32768-byte active record and 4096-byte cancellation record. Mutate each binding field independently and prove the marker is rejected without changing active state. Reject a second operation record, unknown state/phase/error/warning, counter overflow, terminal/nonterminal field contradiction, and `publish_committed=true` before phase `published`.

### T01.3 digest golden vectors

Check in at least three independent vectors: ordinary ASCII, maximum-length fields, and non-ASCII-but-valid UTF-8. Produce the expected SHA-256 using the production Swift codec and an independent standard-library script implementing the domain prefix, big-endian integers, length framing, and decoded hex fields. A field reorder, omitted empty field, Unicode normalization, or decimal integer encoding must change the digest or fail decode as specified.

## T02 — stable multiple-row reservations

With three qualified primary MLX rows A/B/C, generate five projections in one process and two projections after process restart. Assert A/B/C keep three distinct stable transaction IDs and exact tuple digests. Reorder feed rows and assert IDs remain bound by tuple, not array position.

Then mutate one field at a time for B: provider UID, provider ID, config identity, model key, model ID, revision, artifact ID, runtime format, hash algorithm, hash, source kind/repo/revision, release ID, candidate digest, artifact-feed digest, signer ID, and estimated bytes. Each mutation invalidates B's old ID and creates a new ID while A/C remain stable. Running any old ID returns `stale_transaction` before staging creation.

Negative eligibility cases prove no reservation is emitted for non-primary, `declared`, `blocked`, GGUF, wrong source kind, non-MLX runtime, primary/candidate hash disagreement, stale feed, signer disagreement, missing feed, missing size, size above cap, does-not-fit row, and malformed catalog identity.

## T03 — one active operation and kernel lock

Launch 32 independent CLI processes through a barrier with valid IDs for distinct rows. Pause the winner after durable active-state creation. Assert:

- exactly one process holds `operation.lock` and enters `running`;
- exactly one `active.json` record exists;
- 31 processes return `operation_busy` without staging, cancel marker, durable temp, config, or runtime effects;
- repeated status processes can read the same live transaction without acquiring/releasing the worker's flock;
- a second projection remains read-only and preserves the frozen reservation snapshot while the lock is held.

Repeat with the same transaction ID, different transaction IDs, mixed run/status/cancel calls, and an adoption process. The preparation/adoption result must have exactly one mutation owner under the common outer lock.

## T04 — process crash and retry, without continuation

For each phase `reserved`, `metadata`, `downloading` (after at least one full file and mid-file), `verifying_staging`, `copying_durable`, `publish_ready`, and immediately after exclusive rename but before active-state update:

1. run the real CLI worker in a child process;
2. pause at the production phase hook;
3. record exact active tuple/attempt and current bytes;
4. send `SIGKILL`;
5. prove another process can acquire the kernel flock;
6. invoke status, then retry the same stable transaction ID.

Before publication, status becomes `interrupted`, the exact old staging/unpublished paths are removed, the new attempt ID differs, and byte counters restart from zero. Instrument the test HTTP server to prove the first file is requested again; no resume header or partial state is adopted as completed work.

After publication, retry securely re-verifies the destination and returns idempotent success without another download, copy, or rename. Inject cleanup failure and prove `staging_cleanup_required` persists and all new runs remain blocked until `cleanup_staging` succeeds for the exact retained transaction.

## T05 — stale IDs, tuple drift, and provider mismatch

Create a valid reservation, then independently change the current signed release, candidate digest, feed digest, signer, primary artifact tuple, provider ID, config identity, and test EUID context before run. Each case fails before network/staging work with a distinct closed code and leaves the reservation snapshot available for refresh.

Change the feed during a paused download. Immediately before publication, the worker revalidates current authority and refuses the stale tuple. The fully downloaded staging is cleaned or reported by exact cleanup; no durable destination appears. Re-stamp the release with identical artifact content but a different release/digest: the old reservation is stale, a fresh reservation gets a new ID, and its run recognizes an already published exact artifact only after current authority validates it.

Substitute an active record from provider P2 into P1's context and a cancellation marker from P2 into P1's attempt. Both fail closed; no cross-provider state, staging, or durable bytes are touched.

## T06 — cancellation in every phase

For `metadata`, each file-download boundary, mid-download chunk, `verifying_staging`, mid-hash chunk, `copying_durable`, mid-copy chunk, `publish_ready`, and `cleanup`:

- pause the worker;
- invoke the production cancel command from a second process;
- assert the marker contains the exact transaction ID, attempt ID, tuple digest, provider UID, provider ID, config identity digest, and bounded timestamp;
- release the worker;
- assert event order `running -> cancel_requested -> cancelled` and monotonically increasing sequence;
- assert no published destination, unchanged incumbent, and exact staging cleanup.

Run duplicate identical cancels concurrently and prove idempotent acceptance. Run wrong transaction, prior attempt, modified tuple, wrong provider, wrong UID, oversized/unknown-field marker, and a marker pre-seeded before the active record; prove the worker ignores/refuses them and does not cancel.

## T07 — cancellation around publication

Use a real `renameatx_np(RENAME_EXCL)` publication with barriers immediately before and immediately after the syscall.

- Cancel-before: marker is durable before the final pre-rename check. Rename is never called, terminal state is `cancelled`, and destination is absent.
- Cancel-after: rename returns success before the marker is durable. Terminal state is `succeeded`, `publish_committed=true`, warning is `cancellation_too_late`, and destination verifies exactly.
- Concurrent edge: repeat at least 1000 iterations with scheduler jitter. Every result belongs to exactly one of those two outcomes; there is no cancelled-plus-destination, succeeded-plus-missing-destination, partial tree, replacement, or nonterminal state.
- Crash edge: kill after rename and before state write; retry returns the same successful readiness after full destination verification.

## T08 — malicious filesystem matrix

For root, staging parent, transaction leaf, active/cancel/reservation files, durable parent, unpublished tree, and final destination, test:

- symlink at each component;
- wrong owner fixture where CI privilege permits, otherwise a dedicated helper/user test on the release Mac;
- modes 0777, 0755, 0700/0600 in the wrong position, group/world write bits;
- extended ACL;
- hard-linked state file or artifact member;
- FIFO, socket, device, directory-as-file, file-as-directory;
- mount transition/cross-device publish;
- path replacement between open and operation;
- absolute path, `..`, NUL/control, 1025-byte path, depth 33, case-fold collision, normalization collision;
- sparse file whose logical size exceeds the bound;
- 4097th file and aggregate byte 1 over `estimated_bytes`;
- malicious fixed temp leaf (wrong owner/type/link/mode) and pre-existing publish sibling.

Every case fails closed through the production descriptor path. Assert an outside sentinel and every published durable artifact are byte-identical before/after. No test may use path-only `FileManager` validation as the authority oracle.

Separately, leave a valid owner-only regular fixed temp leaf by crashing its writer. The next operation-lock owner must validate and remove only that exact leaf during interrupted reconciliation; it must not scan for similarly named files.

## T09 — bounded reads, state, and resource caps

Provide streaming inputs that stop only after the reader rejects:

- reservations byte 131073;
- active byte 32769;
- cancel byte 4097;
- event/status line byte 16385;
- metadata decoded byte 131073;
- securely opened config byte 1048577;
- sibling 4097;
- tree file 4097;
- relative path byte 1025;
- depth 33;
- estimated byte 1099511627777;
- aggregate regular-file byte `estimated_bytes + 1`;
- deadline second 1801 and first monotonic instant after the 1800-second deadline;
- counter/integer 9007199254740992.

Measure that rejection uses bounded memory and does not read a deliberately infinite/slow body past its cap. Verify an interrupted operation retains one active record, not a growing journal. Run 10000 sequential successful/idempotent/cancelled attempts and assert the authority root still contains only the fixed lock, snapshot, active record, optional marker during a live attempt, and at most one exact staging/unpublished pair. Successfully published artifacts are not deleted or scanned by automatic GC.

## T10 — publish-once idempotence and destination protection

### T10.1 fresh publish

Prepare a multi-file tree through the real downloader/canonical hasher. Assert file count, aggregate bytes, canonical manifest hash, modes, ownership, fsync sequence instrumentation, exclusive rename, and fresh readiness projection.

### T10.2 exact existing destination

Run the same current tuple again. Assert zero network requests, zero staging copy, zero rename, complete secure re-verification, and `succeeded` with the same final identity.

### T10.3 mismatched destination

Pre-create the final destination with one independently varied defect: wrong byte, missing file, extra file, wrong mode, symlink, hard link, wrong size, wrong canonical hash, wrong ownership, or non-directory. Assert `durable_destination_conflict`, no deletion/repair/replacement, exact before/after destination digest, and unchanged incumbent.

### T10.4 no durable GC

Publish A, prepare B, cancel C, and adopt B. Assert A/B remain present after projection, status, cancellation, retry, adoption, provider restart, and cleanup of C. Instrument `DurableModelArtifactStore.gcInactive` and fail the test if preparation calls it.

## T11 — incumbent and all forbidden mutations remain unchanged

For success, each cancellation phase, each injected download/hash/copy/state/fsync/rename error, disk full, timeout, stale authority, malicious filesystem refusal, crash, and destination conflict, compare:

- exact config file bytes and stat identity where applicable;
- `models status` current model ID/hash/runtime state;
- serving artifact path/manifest;
- successful inference response from the incumbent;
- admission status/event head;
- coordinator provider binding and buyer model visibility;
- rate/economics projection fields;
- ledger, usage, settlement, reward, and payout row counts.

Only a successful later adoption may change config/runtime. Preparation itself must produce zero differences in every listed authority outside its private state and new durable artifact.

## T12 — preparation/adoption mutual exclusion

Run the Cartesian set of preparation phases against adoption lock acquisition, journal recovery, runtime prepare, runtime apply, runtime finalize, and runtime cancel.

- If preparation owns `operation.lock`, adoption fails/bounds as busy before taking `RecommendationAdoptionLock` or a runtime reservation.
- If adoption owns the outer lock, preparation fails `operation_busy` before active state/staging.
- Status and exact cancellation remain responsive while preparation holds the lock.
- Lock acquisition order is observed as operation -> recommendation lock -> control socket -> runtime reservation; inject waits at each subordinate boundary and prove no reverse acquisition/deadlock.
- Measure `preparedAdoptionReservationID` as nil for the full download/hash/copy period. It may become non-nil only after readiness, fresh projection, and explicit adoption.

Preserve existing adoption rollback/recovery assertions in `ModelsSubcommandTests`; the new outer lock cannot weaken them.

## T13 — serve-side runtime authority refresh

### T13.1 refresh unnecessary

When the running provider already has the exact target authority, readiness proceeds directly to existing adoption. Assert no refresh frame is sent.

### T13.2 accepted refresh

Start serve without the target in `targetAuthorities`, publish it, and send `refresh_prepared_artifact_authority.v1` containing only transaction and tuple digests. Through the real control socket, assert:

- peer has the same EUID;
- server reloads current signed candidate/artifact feed through production qualification;
- server derives the path and hashes the tree itself;
- response binds the request IDs and says accepted;
- only in-memory target readiness changes; current model/config/admission/economics do not;
- later existing adoption rechecks incumbent and exact runtime authority and atomically swaps.

### T13.3 refusal matrix

Refuse another EUID, unknown field/frame, oversized frame, requester-supplied path, requester-supplied feed/hash identity, stale transaction, tuple drift, feed unavailable/stale/signer mismatch, non-primary target, missing/mutated destination, wrong canonical hash, wrong ownership/type/mode, provider/config mismatch, and concurrent release change. Each refusal leaves target authority/current runtime unchanged.

### T13.4 refresh race

Race refresh with artifact mutation, feed publication, provider shutdown, and adoption. The server either accepts one completely reverified generation or refuses. It never installs mixed-generation or requester-derived authority. Existing same-EUID tests around `ControlSocket.swift:1388` and `:2061-2069` remain green.

## T14 — CLI event/status protocol

For success, failure, timeout, cancellation, interrupted reconciliation, cleanup required, idempotent existing destination, and cancellation too late, assert:

- stdout is JSON lines only under `--json`;
- exact schema/kind/transaction/model binding;
- sequence begins at 0 or the slice 6 locked value and increases by exactly one;
- UTC timestamps do not go backwards;
- active gaps never exceed ten seconds;
- progress counters are monotonic and never exceed expected values;
- exactly one terminal event occurs;
- status agrees with durable active state and publication evidence;
- stderr is redacted and contains no home path, URL credential, token, response body, or file manifest.

Run parser negatives for each exact `models transactions run|status|cancel <transaction-id> --json` form: missing ID, malformed ID, extra positional input, unknown option, wrong transaction kind, and unsupported schema. Each must exit nonzero before state or network access. Status must use the closed `model_catalog_transaction_status.v1` field set and reject byte 16385 or any unknown field.

Kill the invoking Malibu-owned process only in a negative test and prove that process death becomes `interrupted`; it is not treated as a valid cancellation request.

## T15 — old-client capability fallback

Test four pairings: old app/old CLI, old app/new CLI, new app/old CLI, and new app/new CLI with capability disabled.

- Old behavior remains the static current-model card with no preparation action or error banner attributable merely to absence.
- Unknown transaction/action/schema/enum/field makes the affected action unsupported; it never falls back to legacy browse/list execution.
- A malformed projection preserves the current card and shows the existing generic unavailable/retry state.
- No pairing starts a hidden download, accesses the preparation root from Malibu, or infers readiness from `estimated_gb`/cache presence.

Run the exact pre-slice-6 compatibility fixtures checked into `ModelManagementTests` and `ModelCatalogEconomicsTests`, then the new capability matrix.

## T16 — Malibu slice 6 user experience and copy

Through the real Malibu process launcher/decoder boundary, verify:

- a qualified row displays signed trust source, exact download bytes in localized units, fit, non-earning state, and confirmation before run;
- three rows keep their actions bound to their distinct transaction IDs through sorting/filtering/refresh;
- progress, indeterminate heartbeat, 30-second delayed response, cancellation, cleanup-required, cancelled, failure, timeout, success, and cancellation-too-late are accessible and localized;
- Malibu invokes the exact run/status/cancel command and never deletes a path or signals a process for cancellation;
- success remains pending until a terminal event and a fresh projection reports exact readiness;
- a fresh projection that no longer contains the tuple turns success into a truthful stale/retry state;
- offer/adopt stays unavailable until its own exact slice 6 action is returned;
- forbidden copy tests reject `earns`, `higher-paying`, buyer-routable, verified computation, catalog-priced, or settlement-capable claims based only on discovery/evaluation/preparation.

Exercise VoiceOver labels, keyboard navigation, Dynamic Type, progress announcement throttling, and every shipped localization. If no RTL locale ships, record that release fact as SPEC-044 permits.

## T17 — migration, compatibility, and rollback

Place opaque sentinel bytes named as R21-R27 SQLite/VFS databases, journals, worker records, receipts, and roots beside or under their historical development paths. Do not add an old-format decoder or reproduce an old schema. Start the production slice 6 CLI and assert it does not read, import, rename, delete, sign, or migrate any sentinel. It uses only `model-preparation-v1`.

Place an unknown schema in the new root. Preparation fails `unsupported_preparation_state`; existing serve, models status/list/browse, recommendation adoption recovery, BYOM discover/evaluate/offer/status/withdraw, and settled inference continue.

Rollback test:

1. publish one prepared artifact with the new CLI;
2. reach no active operation;
3. run the previous stable CLI/app;
4. assert they ignore the new root and continue serving the incumbent;
5. restore the new CLI;
6. assert it re-verifies the published artifact under current signed authority;
7. assert no automatic durable GC occurred.

Attempt binary replacement during a live operation and prove release tooling blocks or requires terminal drain; it may not silently orphan a worker.

## T18 — dependency and governance gates

Before any implementation review, record:

- fetched `origin/main` and implementation base;
- PR #1481 merge commit and current slice 5 conformance state, including the still-unproven first listed-tier release;
- reconciliation disposition that treats main as authoritative for the eight exact overlapping paths named in the plan;
- exact SPEC-001/044/046/047 versions, the `4bbb7eed` slice 6/7 handoff commit, #1485 file-ownership disposition, and operator-provided copy input provenance;
- AUTHORITY/CONFORMANCE validation results;
- diff showing no imported R21-R27 code/state format;
- `git log origin/main..HEAD` limited to the slice.

Run:

```bash
python3 scripts/check_spec_governance.py --base-ref origin/main
python3 scripts/gen_spec_index.py --check
git diff --check
```

Use the repository's actual supported arguments if `gen_spec_index.py --check` differs at implementation time; record the exact command and output. A red `spec-index / check` blocks the slice.

## T19 — slice 6 test commands

The implementation PR must provide filters that select every new case. The minimum fresh gate is:

```bash
cd phase3-binary
swift test --filter ModelPreparationAuthorityTests
swift test --filter ModelPreparationWorkerTests
swift test --filter ModelPreparationCommandTests
swift test --filter ModelCatalogEconomicsTests
swift test --filter ModelsSubcommandTests
swift test --filter ModelRuntimeSwapTests
swift test --filter ModelRuntimeHashTests
swift test --filter ControlSocketTests
swift test
```

```bash
cd phase3-binary/app
xcodegen generate
xcodebuild -project Malibu.xcodeproj -scheme Malibu -destination 'platform=macOS' test
```

```bash
bash test/e2e/model-preparation/run.sh
make test-dist
make vet
```

If the app has a repository wrapper for Xcode tests at implementation time, use it in addition to or in place of the raw command and record the exact invocation. No historical baseline pass substitutes for these runs.

## T20 — independent review gate

After all implementation fixes are combined, freeze the exact base-to-head diff and run three independent cold-context lanes:

1. code/correctness review;
2. security/privacy/filesystem review;
3. architecture/authority/lifecycle review.

Each lane reviews the full final diff, contracts, test evidence, and rollback. Pass condition is exactly 0 Critical, 0 High, and 0 Medium across all lanes. Apply fixes, rerun relevant tests, and re-review until the gate passes. Low/Informational findings may be carried only with explicit rationale and owner. The rejected R27 review or its historical test counts grant no credit.

## T21 — slice 7 real-hardware preparation and incumbent journey

On a physical supported Apple Silicon Mac using the signed release candidate and the actual selected primary MLX artifact:

1. record hardware model class, RAM, macOS/APFS version, free disk, signed app/CLI identities, release ID, candidate/artifact feed digests/signers, model key/ID/revision/artifact/hash/size, and incumbent model/hash;
2. obtain at least three projected reservations and prove stable IDs across restart;
3. prepare the non-current target while issuing incumbent inference before, during, and after transfer;
4. cancel once during transfer and prove the incumbent and durable destination are unchanged;
5. retry from zero, publish, restart status/projection, and prove exact readiness;
6. when necessary, exercise real serve-side authority refresh, then use the existing adoption transaction;
7. serve a real prompt from the adopted MLX container and record model/hash/runtime identity;
8. repeat a mismatched-destination refusal without modifying either model.

The actual artifact must respect the 1800-second action deadline and disk formula. If it does not, Build 1 remains blocked; do not replace it with a tiny fixture or raise the cap in the evidence run.

## T22 — missing SPEC-046 discovery journey

Run the full production `JOURNEY-PROVIDER-BYOM-DISCOVERY` driver required by SPEC-046-R008 (`specs/SPEC-046-provider-byom-discovery.md:127`), including:

- one MLX-cache candidate, one loopback runtime candidate, and one opaque endpoint candidate;
- one adapter failure;
- one evaluated but not network-admitted candidate;
- `local_only`, `offerable`, and `not_offered` ladder states;
- preparation-required copy and the successful prepared readiness transition;
- read-only discovery, bounded evaluation, no hidden download/config mutation, path/token/content redaction, and forbidden-earnings copy.

Capture, build, preflight, operator-sign, and promote through the existing journey evidence scripts. Do not mark SPEC-046 conformant from local unit/E2E output alone.

## T23 — missing SPEC-047 admission and settlement journey

Continue from the actual prepared/adopted runtime and execute the complete `JOURNEY-NETWORK-MODEL-ADMISSION` matrix required by SPEC-047-R008 (`specs/SPEC-047-network-model-admission.md:135-151`): rejected opaque endpoint; sandbox-only; network-visible unpriced; catalog-matched but not settlement-capable; novel non-catalog with no earning path; synchronous rejection followed by fresh acceptance; drift revocation; withdrawn fresh re-entry; and settlement-capable catalog-verified case with required dual control.

For the final case, prove on the real request:

- live session serves the exact admitted artifact member;
- route-time snapshot binds candidate catalog and artifact-feed evidence;
- buyer routing remains closed before settlement-capable and opens only after it;
- receipt key, request/response hashes, usage, and receipt verify;
- SPEC-005 formulas are unchanged;
- gateway usage and coordinator request log join on the authoritative request identity;
- exactly the expected billing, ledger, settlement, rewards, and payout rows appear;
- provider credit is positive under enforcement and no unrelated row changes.

Capture, operator-sign, build, preflight, and promote the journey. A preparation success, synthetic probe, or separate settlement fixture cannot substitute for this composed evidence.

## T24 — signed release and updater qualification

Run `docs/runbooks/provider-cli-release-verification.md` after both journeys pass:

- final signing, notarization, stapling, and packaging;
- SHA-256 byte identity of the `macprovider-cli` inside Malibu.app and the standalone tarball;
- previous-stable updater to the candidate;
- old-client capability fallback before update and slice 6 UI/action behavior after update;
- no `codesign --force --deep` repair;
- immutable new release rather than patching a public release.

Only evidence from these final assets may close Build 1.

## Acceptance matrix

| Claim | Tests | Final evidence |
|---|---|---|
| Stable multiple-row exact reservations | T01-T02 | T21 |
| One live operation across processes | T03 | T21 |
| Crash means interrupted-and-retry | T04 | T21 restart/readback |
| Stale/provider/tuple mismatch fails closed | T05 | T21 |
| Cancellation in all phases and publication race | T06-T07 | T21 transfer cancel |
| Malicious filesystem and cap enforcement | T08-T09 | APFS release-Mac subset |
| Publish-once idempotence and mismatch protection | T10 | T21 |
| Incumbent/config/admission/economics unchanged | T11 | T21-T23 |
| Preparation/adoption exclusion | T12 | T21 |
| Serve re-verifies live authority | T13 | T21 when needed |
| CLI/app protocol, UX, copy, old client | T14-T17 | T21, T24 |
| Governance and zero C/H/M review | T18-T20 | Frozen review records |
| Missing discovery journey | T22 | Signed promoted evidence |
| Missing admission/settlement journey | T23 | Signed promoted evidence |
| Signed app/CLI/updater release | T24 | Release assets and hashes |

## Stop condition

The reservation subplan is implementation-complete only when T01-T20 pass on the final slice 6 diff with zero independent Critical/High/Medium findings. Build 1 is complete only when T21-T24 also pass using the final signed assets and both signed journey results are accepted in CONFORMANCE. Slice 5, slice 6, local fixtures, or a prepared artifact by itself cannot satisfy that stop condition.
