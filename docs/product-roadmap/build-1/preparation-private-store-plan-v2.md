# Build 1 preparation private store plan v2


**Superseded by v3 after independent Sol review. Do not implement from v2.**
Base revision: `4f388d67e23f9aa02a386aef60b225632a722b11` (`origin/main` after PR #1504).
Branch/worktree: `codex/build1-preparation-runtime-v2` in `/Users/augstar/.codex/worktrees/macprovider/build1-preparation-runtime-v2`.
Scope: Build 1 local preparation storage foundation only. This plan does not implement catalog-feed download, transaction worker execution, Malibu UX, coordinator admission, settlement, physical Mac acceptance, or production qualification.

## Current implementation classification

| Requested Build 1 outcome | Current landed state at base | Classification for this slice | Evidence |
| --- | --- | --- | --- |
| Verified feed consumption with signer/release/freshness checks and safe baked fallback | BYOM/artifact feed producer and coordinator intake have landed through PR #1481, and open PRs #1495/#1497 cover adjacent BYOM journey/UX work. The local provider runtime still lacks the complete self-service Prepare transaction path. | Out of scope for this slice except preserving fields carried by `ModelPreparationContracts`. | `specs/SPEC-023-installer-autotune-recommend.md`, `specs/SPEC-047-network-model-admission.md`, open PRs #1495/#1497. |
| Trusted artifact preparation with size disclosure, staging, integrity checks, cancellation and adoption | PR #1504 landed strict contract/codec types, including root identity, reservations, active, cancel marker, staging sources, publication receipt/inventory, cleanup, terminal history, and failed-dispatch records. No descriptor-safe private store or runtime worker uses these records on `main`. | Missing. This slice implements only descriptor-safe bootstrap/read/write/recovery primitives and tests for the seven private envelope kinds. | `phase3-binary/Sources/macprovider-cli/ModelPreparationContracts.swift`; absent `ModelPreparationPrivateStore.swift`; `docs/product-roadmap/build-1/preparation-contracts-1491-rebase-handoff.md`. |
| Authoritative model identity, pricing and settlement admission | Coordinator admission state machine and BYOM intake are active work, but positive settlement-capable proof and physical admission journey are not part of this local private-store slice. | Out of scope; must remain unaffected. | `specs/SPEC-047-network-model-admission.md`; PR #1495 open. |
| Executable provider UX with truthful readiness/economics states | Model catalog/economics projection code exists, but the local Prepare runtime backing is not connected. | Out of scope; plan must not add UX claims. | `phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift`, `ModelsSubcommand.swift`. |
| Correctly settled physical Mac request | No fresh physical acceptance evidence in this branch. | Blocked later; do not claim. | Build 1 roadmap and PR #1504 handoff. |

## User journeys covered by this slice

1. Provider starts a future Prepare action for the first time. The CLI can create a private authority directory, lock files, artifact namespace skeleton, and `root.identity` with owner-only permissions. The result is a root locator that later records can bind to.
2. A future projection/worker writes one bounded private state record under the required lock custody. The store validates the contract payload, wraps it in a seven-kind envelope, writes it through an owner-only temp file, fsync/fullsyncs and renames, then readback-validates the final bytes before reporting success.
3. A future cancel/status/recovery reader opens a final state file by descriptor, validates owner/mode/type/link count/name/root identity/envelope/kind/leaf/checksum/payload, and returns only the validated payload bytes.
4. Startup sees temp files from an interrupted write. It never promotes temps into authoritative state, including bootstrap/root-identity temps. It may remove only individually safe stale recognized state temps after a complete bounded scan proves the directory is within budget and has no unknown or hostile siblings. If the scan budget is exceeded, recovery fails closed and removes nothing. Final state remains the only readable authority unless a fresh authorized writer reconstructs it from independent durable evidence in a later slice.
5. Hostile or drifted filesystem state is present: symlink roots, swapped files, wrong modes, FIFOs, hard links, extended ACLs, unknown temp names, envelope-kind mismatch, root locator drift, and payload/leaf/checksum mismatches. The store fails closed and preserves incumbent final bytes.

## Ownership boundaries

- Swift local store ownership: new files under `phase3-binary/Sources/macprovider-cli/ModelPreparationSecureFilesystem.swift` and `ModelPreparationPrivateStore.swift`, with focused tests under `phase3-binary/Tests/macprovider-cliTests/ModelPreparationPrivateStoreTests.swift` and `ModelPreparationRootTests.swift`.
- Contract ownership: use the PR #1504 public API in `ModelPreparationContracts.swift`; change it only for small helper exposure required by the store, and reopen plan review if any wire shape or normative contract changes.
- Runtime ownership: no `ModelsSubcommand`, `ModelCatalogEconomics`, `MacProviderCLI`, `CandidateProviderRunner`, or Malibu app behavior changes in this slice unless the plan is revised and re-reviewed.
- Coordinator/admission/billing ownership: no Go service changes in this slice.
- Active adjacent work: PR #1495 and #1497 remain separate BYOM journey/UX work; this slice must not alter their surfaces.

## Dependency graph

1. `ModelPreparationContracts` seven-kind envelope and payload validators from PR #1504.
2. `ModelPreparationSecureFilesystem` descriptor helpers: canonical path, owner-only directory/file creation, no symlink traversal, descriptor/name revalidation, bounded reads, fsync/fullsync, atomic same-parent rename, ACL/link count checks.
3. `ModelPreparationPrivateStore` bootstrap and lock custody: constructor takes two explicit absolute URLs, `authorityRoot` and `artifactRoot`. Bootstrap opens and validates both descriptor chains; authority root owns only private control files and locks (`operation.lock`, `failure.lock`, `cancel.lock`, `state-tmp`); artifact root owns only the managed artifact namespace (`.macprovider-prepared-v3`, `objects`, `work/staging`, `work/unpublished`) and durable raw `root.identity`. `LockCustody` captures the authority-root descriptor identity and the artifact-root descriptor identity/root digest observed during bootstrap, and every write/read/recovery call must prove the supplied custody, root locator, authority descriptor, artifact descriptor, and state payload all belong to that same tuple before any mutation.
4. Store record API: write/read seven private envelope kinds with generation monotonicity, payload validation, root-binding validation for root-bearing payloads, exact leaf/kind matching, and readback validation.
5. Conservative temp recovery: bounded scan, safe recognized-temp cleanup only, no promotion, no state reconstruction.
6. Later slices may compose worker transfer/publication/cancel/adoption only after this store passes audit.

## Normative contracts for this slice

- Private state leaves are exactly: `reservations.json`, `active.json`, `cancel.json`, `published-inventory.json`, `deletion.json`, `staging-sources.json`, and `failed-dispatch-pending.json`, mapped to the seven `ModelPreparationPrivateStateEnvelopeKind` cases and the PR #1504 byte caps.
- `root.identity` is not an envelope. It is raw canonical `ModelPreparationRootIdentityRecord` bytes at `artifacts/.macprovider-prepared-v3/root.identity`, with mode `0600`, link count one, no extended ACL, and bound to the opened artifact root descriptor's canonical path, `st_dev`, and `st_ino`.
- All private directories and lock files are owner-only (`0700` dirs, `0600` files), opened with no symlink following where the platform allows, and revalidated by descriptor and parent/name before use. Sensitive new files, including bootstrap identity temps and state envelope temps, are created already open and unpublished, have inherited ACLs stripped, are descriptor-verified as owner-only, ACL-empty, regular, link-count-one, and zero-length before the first sensitive byte, and are revalidated before rename/use. If that pre-byte verification fails, no sensitive bytes are written and only the newly created empty object may be removed.
- A write requires live lock custody for the authority root and the matching artifact root/root locator. This slice may acquire all three lock files together only for bootstrap and generic store writes; it must not claim this is the final worker lock graph for dispatch/cancel/cleanup/adoption.
- Writes are same-parent temp-to-final operations: create unique pre-byte-verified temp, write all bytes, fsync/fullsync temp, rename over/into target only after generation and incumbent checks, fsync/fullsync parent, reopen/readback final and validate exact bytes. Store-level writes reject generation `0`; durable generations start at `1` and must increase strictly over an existing final.
- Temp files are not commit evidence. Startup/recovery never promotes a temp, even if it is newer and checksum-valid, and this rule includes `bootstrap-tmp/root.identity.*.tmp`. Recovery may remove safe stale state temps only after descriptor/name validation and a complete bounded directory scan that proves the directory is within budget; it must leave hostile, unknown, semantically invalid, or over-budget temp sets in place and fail closed with no mutation.
- Reads never repair logical state. They may complete final parent/readback validation as part of verifying an already-final file, but this slice will avoid cleanup-object recovery and any worker replay.
- The store must preserve incumbent serving state, provider configuration, coordinator admission, pricing, billing, rewards, and model runtime. It only creates or updates files under the configured preparation authority and artifact namespace.

## Phased changes

Phase A — secure filesystem helper
- Add descriptor-safe directory/file helpers adapted from the old draft but revised for v22 rules.
- Expose deterministic error descriptions for tests without leaking secrets.
- Implement macOS `fcntl(F_FULLFSYNC)` best-effort after `fsync`; on non-Darwin test platforms, compile only where Swift package already targets Darwin/macOS.

Phase B — root bootstrap
- Add `ModelPreparationPrivateStore.bootstrap()` and `bootstrapWithLockCustody()`.
- Create authority and artifact namespace skeleton, lock files, and raw `root.identity`.
- Never promote `root.identity` from bootstrap temp bytes. If final `root.identity` is absent and any bootstrap temp or other namespace evidence exists, bootstrap fails closed and preserves bytes. Bootstrap may create a fresh `root.identity` only when the namespace is new/empty of authoritative or ambiguous bootstrap evidence. Reject envelope bytes, malformed raw bytes, hostile temps, symlink roots, ACLs, hard links, and root drift.

Phase C — seven-kind record storage
- Implement `writeRecord(kind:payload:generation:rootLocator:lockCustody:)` and `readRecord(kind:rootLocator:)`.
- Support all seven envelope kinds from PR #1504; remove the old five-kind gate.
- Enforce strict payload validation through `ModelPreparationPrivateStateEnvelope`, root locator agreement for root-bearing records, monotonic generation, exact leaf/kind/filename binding, final readback, and no mutation on failure.

Phase D — conservative temp recovery
- Implement `recoverStateTemps(rootLocator:lockCustody:)` as bounded cleanup only.
- Remove empty/stale recognized state temp files only when a full scan is within budget and every sibling is known/safe; cap per-invocation recognized temp processing, and fail closed with no mutation on unknown, hostile, semantic-mismatch, or over-budget temp sets without promoting any temp.
- Return a report with removed temp names and zero promoted/completed entries; this makes the no-promotion rule visible in tests.

Phase E — durable artifact handoff notes
- Update handoff docs with validation evidence and limits.
- Do not wire CLI commands or UI actions in this slice.

## Acceptance criteria

- Focused Swift tests pass for root bootstrap, seven-kind write/read, generation monotonicity, root drift, symlink/ACL/hardlink/FIFO rejection, envelope/leaf/kind mismatch, temp no-promotion recovery, incumbent-byte preservation, and byte caps.
- `swift test --filter ModelPreparationPrivateStoreTests`, `swift test --filter ModelPreparationRootTests`, and `swift test --filter ModelPreparationPrivateCodecTests` pass locally. If broad `swift test` is too slow or environment-sensitive, report it separately and rely on PR CI for the full Swift lane.
- `git diff --check origin/main` passes.
- Independent Sol code, security, and architecture reviews of the complete diff report zero Critical, High, and Medium findings before PR creation/merge.
- The PR description states this is storage foundation only and does not claim self-service Build 1 acceptance, physical Mac qualification, paid admission, catalog pricing, or settlement.

## Negative tests

- Symlink artifact root and symlink ancestor do not create `.macprovider-prepared-v3` at the symlink target and do not mutate outside sentinels.
- Existing `root.identity` with envelope bytes, malformed nonce, wrong path/device/inode, mode wider than `0600`, hard link count greater than one, or extended ACL rejects without rewriting.
- Attempted raw payload at a state leaf rejects; envelope with wrong `record_kind`, wrong `target_leaf`, wrong filename, wrong checksum, wrong generation, unknown kind, extra/duplicate keys, or payload for another schema rejects.
- All seven record kinds have exact cap enforcement. Oversized payloads and oversized envelopes fail before replacing final bytes.
- Generation zero rejects. Generation equal/lower than current final rejects without replacing final bytes; generation one greater succeeds only with a valid payload.
- Unknown temp names, FIFOs, symlinks, directories, over-cap temp bytes, semantic root mismatch, kind/leaf mismatch, valid raw bootstrap temp without final root identity, and more than the bounded recognized-temp allowance fail closed and preserve final/temp bytes.
- Recovery proves no temp promotion: a valid newer temp plus older final leaves the final readable and returns no completed/promoted entry.
- Store APIs cannot be used with closed lock custody or custody from a different authority root.

## Migrations and compatibility

- This slice does not migrate old five-kind draft state or public BYOM data. If such files are present, the store rejects/quarantines by failing closed and preserving bytes.
- The new files live under a v3 preparation namespace and authority directory. Legacy model artifacts and current serving config remain untouched.
- Rollback to a CLI without this store sees inert private files. It must not be asked to repair or delete them.
- Future migration from rejected drafts requires a separate supervised plan with independent proof of staging source or published receipt/root identity.

## Rollback

- Code rollback removes the ability to create/read these private records but leaves owner-only private files inert.
- A failed write preserves the previous final bytes or absence. Temp leftovers are diagnosable and not authoritative.
- No coordinator, billing, admission, provider identity, runtime config, or model-serving rollback is needed for this slice.

## Observability

- This slice adds no production metrics and no user-visible success claims.
- Test-only recovery reports list removed temp leaves and deliberately no promoted leaves.
- Future worker slices may add JSON transaction events using `ModelPreparationTransactionEvent`; this slice must not emit transaction events.

## Hardware requirements

- Local unit tests require macOS/Darwin filesystem semantics for `openat`, `flock`, `fsync`, ACL checks, and `F_FULLFSYNC` best effort.
- No 64 GB+ Mac, real MLX inference, production coordinator, Docker, or operator secrets are required.
- Physical Mac Build 1 acceptance remains later: preparation → valid admission → correctly settled request must be proven on real hardware after CLI/runtime/coordinator slices land.

## Finding resolutions from v1

- H-1 resolved: removed `root.identity` temp promotion; bootstrap temps are ambiguous evidence and never root authority.
- M-1 resolved: specified constructor roots and the invariant binding lock custody, authority descriptor, artifact descriptor, root locator, and payload roots.
- M-2 resolved: required before-first-sensitive-byte ACL stripping/verification and negative tests for inherited ACL parents.
- M-3 resolved: over-budget temp recovery now fails closed and mutates nothing.
- L-1 resolved: store generations start at 1; generation 0 is rejected.
- L-2 resolved: codec tests are required targeted acceptance.

## Explicit non-goals

- No artifact download, resume, hash verification over downloaded weights, publication receipt creation, cleanup worker, direct cancel CLI, Malibu button, model switch/adoption, route registration, admission transition, settlement, reward, payout, release signing, notarization, or production enforcement.
- No broad changes to BYOM PR #1495/#1497 surfaces.
- No promise that a prepared file is runnable, admitted, priced, settlement-capable, or earning.
