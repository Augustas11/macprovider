# Build 1 preparation private store test specification v1


**Superseded by v2 after independent Sol review. Do not implement from v1.**
Base revision: `4f388d67e23f9aa02a386aef60b225632a722b11`.
Scope: focused tests for `ModelPreparationSecureFilesystem` and `ModelPreparationPrivateStore` only.

## Test groups

### T1 root bootstrap and identity

- `testBootstrapCreatesPrivateV3NamespaceAndStableRootIdentity`: bootstrap twice; assert stable locator, `0700` directories, `0600` lock files and `root.identity`, namespace leaves `objects`, `work/staging`, `work/unpublished`, and raw root identity bytes that decode as `ModelPreparationRootIdentityRecord` but not as a private envelope.
- `testBootstrapRejectsExistingRootIdentityWithExtendedACL`: add extended ACL to `root.identity`; bootstrap rejects and preserves bytes.
- `testBootstrapRejectsEnvelopeBytesAtRootIdentity`: replace root identity with a valid private envelope; bootstrap rejects and preserves bytes.
- `testBootstrapRejectsSymlinkRootWithoutMutatingOutsideSentinel`: artifact root is a symlink to a real directory with sentinel; bootstrap rejects and sentinel/target namespace are unchanged.
- `testBootstrapRejectsRootIdentityDeviceInodeOrPathDrift`: mutate identity path/device/inode/digest fields independently; bootstrap rejects without repair.
- `testBootstrapDoesNotPromoteValidRootIdentityTemp`: place a syntactically valid raw `root.identity.<uuid>.tmp` in `bootstrap-tmp` while final `root.identity` is absent; bootstrap rejects, returns no root locator, and preserves temp bytes without creating final identity.

### T2 secure filesystem rejection cases

- Existing authority/artifact path component as symlink, FIFO, regular file where directory expected, wrong owner-mode, hard-linked file, or extended ACL rejects before creating children.
- Private child file open revalidates parent/name/descriptor; replacing a checked regular file with FIFO/symlink between stat and open is rejected.
- New sensitive temp creation under a parent with inheritable ACL strips the inherited ACL, verifies by descriptor that the still-open temp is zero-length, regular, owner-only, ACL-empty, and link-count-one before writing, then writes. Inject a pre-byte ACL verification failure and assert no sensitive bytes are written and only the new empty temp is removed.
- Reads enforce max byte caps and reject empty files where empty is not allowed.

### T3 seven-kind write/read

For each `ModelPreparationPrivateStateEnvelopeKind`:

- Construct a minimal valid payload using the PR #1504 contract constructors.
- `writeRecord` with generation 1 under live lock custody writes an envelope at the exact target leaf; `readRecord` returns the exact payload bytes.
- Durable bytes decode as `ModelPreparationPrivateStateEnvelope`, not as the raw payload; envelope `record_kind`, `target_leaf`, generation, payload SHA and payload bytes match.
- Target file is `0600`, link count one, no extended ACL.
- A raw payload written directly at the target leaf rejects on read.
- Envelope with wrong kind/leaf/checksum/payload schema rejects on read and leaves bytes unchanged.

### T4 generation and custody

- Generation `0` rejects. Equal generation and lower generation writes reject without replacing the final envelope.
- Next generation writes succeed and read back new payload.
- Write with closed lock custody rejects.
- Write with lock custody from a different authority root rejects.
- Write with a matching authority lock custody but different artifact root/root locator rejects before creating a temp.
- Failure during payload validation, generation check, temp write, fsync/fullsync, rename, parent barrier or readback preserves incumbent bytes; injected failures use test seams if needed.

### T5 root binding

- Root-bearing payloads (`reservations`, `active`, `published_inventory`, `deletion`, `staging_sources`, `failed_dispatch_pending`, and `cancel` when it contains a root locator) reject when the API root locator differs from the payload root.
- Non-root-bearing payloads, if any remain after implementation, are listed explicitly and do not bypass envelope validation.
- Mutating root path, device, inode, identity version, or digest independently fails closed on write/read/recovery.

### T6 conservative temp recovery

- A valid newer state temp plus valid older final is not promoted; recovery reports no completed/promoted entries and final remains old.
- Empty recognized temps and stale recognized temps may be removed only after final validation and safe descriptor checks; report removed leaf names.
- Unknown temp names, FIFOs, symlinks, directories, over-cap bytes, wrong filename UUID, kind/leaf mismatch, checksum mismatch, duplicate-key payload, and semantic root mismatch cause recovery to throw and preserve every final/temp byte.
- With more than the allowed recognized-temp budget, recovery fails closed, removes nothing, and never reconstructs state from the prefix. If any hostile unknown sibling exists, recovery fails closed.

### T7 no authority escalation

- Bootstrap/write/read/recovery does not modify provider config, active runtime config, coordinator admission state, billing stores, rewards, or any path outside configured authority/artifact roots. The test fixture uses distinct authority and artifact roots and asserts that cross-pair lock/root mismatches fail before mutation. Tests place sentinel files in those locations and assert byte identity.
- The store exposes no public CLI action and emits no `model_catalog_transaction_event.v1` events.

## Commands

Targeted local commands:

```bash
cd phase3-binary && swift test --filter ModelPreparationRootTests
cd phase3-binary && swift test --filter ModelPreparationPrivateStoreTests
cd phase3-binary && swift test --filter ModelPreparationPrivateCodecTests
git diff --check origin/main
```

Broader PR/CI expectations:

- `phase3-binary (swift test)` in CI.
- Existing repo CI gates remain required before merge.

## Acceptance evidence boundaries

Passing these tests proves only local private store bootstrap/read/write/recovery behavior. It does not prove artifact download integrity, model readiness, runtime adoption, coordinator admission, settlement, rewards, or physical Build 1 acceptance.
