# Build 1 transaction snapshot resources — r1 plan and test addendum

Status: author proposal, no implementation authorization until independent review.
Date: 2026-09-10. Supplements transaction-control-addendum-r4.md and its accepted
single-owner, operation-generation, consumed-config and bounded control contracts.
No new runtime environment variables, public commands, dependencies, credentials,
release formats, or broader command authority are introduced.

## Known implementation defect

The current app copies only the executable in
`ModelTransactionControl.swift: authorizeCatalog`, then `runCatalog` launches that
copy for both owner and control commands. `AutotuneRecommendDependencies.runnerFactory`
constructs `CandidateProviderRunner()`; its `defaultProviderBinaryPath` uses
`Bundle.main.executablePath`. The candidate thus launches the copied executable.
`ServeCommand.run` in MacProviderCLI.swift deliberately excludes autotune candidates
from canonical-install re-execution. Restoring the incumbent still uses the
existing CLI owner lifecycle; no app restart/re-exec bypass is proposed.

The pinned mlx-swift checkout dc43e62d7055353c7f99fa071a4e71d29dfddc44
(0.31.4) has these resource rules:

- Source/Cmlx/mlx/mlx/backend/common/utils.cpp `current_binary_dir` uses dladdr
  of linked MLX code. The locally built CLI's otool dependency list contains no
  MLX dynamic library: these kernels resolve relative to the CLI image.
- Source/Cmlx/mlx/mlx/backend/metal/device.cpp `load_default_library` searches
  adjacent `mlx.metallib`, adjacent `Resources/mlx.metallib`, registered/local
  SwiftPM `mlx-swift_Cmlx.bundle` default.metallib, adjacent Resources/default,
  then the compiled METAL_PATH. The package sets METAL_PATH to relative
  `default.metallib`; failure throws `Failed to load the default metallib`.
- There is no lookup of Malibu's original configured provider installation.
  A process started from the private binary-only directory has neither adjacent
  MLX library nor its resource bundle. An accidental current-directory file or
  unrelated registered bundle is not a supported or trustworthy repair.

`phase3-binary/dist/package.sh` requires and packages adjacent mlx.metallib and
optionally the MLX/NIO bundles. `.github/workflows/release.yml` preserves that
layout in the standalone archive and copies mlx.metallib into Malibu.app's
Contents/MacOS. SelfUpdate.swift `validatedPayloadEntries` requires the library,
resource bundle, signed compatibility manifest, local compatibility files and
catalog-release files. Therefore the omission is a known executable failure in
the clean released layout, not merely an unsigned/hardware qualification gap.
Metal resource loading and measured MLX inference are separate claims.

## Fixed resource closure and trust boundary

Replace the single file with one private payload directory derived only from
canonical transaction UUID and pinned native CDHash:
`ModelTransactions/executables/<uuid>-<cdhash>/macprovider-cli`.
The complete allowed top-level member set is:

- required: macprovider-cli, mlx.metallib, compatibility-set.json,
  compatibility-set-local, catalog-release;
- optional: mlx-swift_Cmlx.bundle, swift-nio_NIOPosix.bundle,
  THIRD-PARTY-NOTICES.txt; at least one of the two known bundles must be present
  to match existing released-payload requirements.

Do not scan/copy arbitrary sibling files from an installation that also contains
operator data. Select these exact names from the existing trusted configured
provider payload directory. Unknown siblings there are not snapshot inputs.
Unknown entries *inside a selected resource tree*, and unknown entries in a
published private payload, fail closed. Do not copy another native executable,
framework, dylib, plugin, arbitrary bundle, model weights, cache, journal, config,
credentials, symlink, hard link, FIFO, socket or device.

compatibility-set-local has exactly install.sh,
provider-launch-agent.plist.template, updater-rollback.json,
watchdog-launch-agent.plist.template, watchdog.sh, matching the existing validator.
These scripts are copied as non-executable data and cannot be invoked through the
closed owner/control API. catalog-release has exactly release.json,
trusted-keys.json, tier2-catalog.json, autotune-candidates.json and its .sig,
demand-rank.json and its .sig, rate-card.json and its .sig.

Known resource bundles are data-only. Support the released flat SwiftPM layout
and Contents/Resources layout: Info.plist at root or Contents; default.metallib
at root or Contents/Resources only for MLX; PrivacyInfo.xcprivacy at root or
Contents/Resources; optional _CodeSignature/CodeResources at root or Contents.
Reject duplicate alternative locations for the same logical resource, any
CFBundleExecutable declaration, and any other bundle files/directories. Reject
Mach-O/fat native image magic in resource files. Metal library bytes are expected
GPU code, not a second native host executable. Validate the actual release bundle
fixtures against this allowlist before code freeze; a newly discovered necessary
member requires an explicit plan revision, not automatic widening.

Keep strict native CLI signature, Apple anchor/team/identifier, live PID binding,
version/capability and CDHash validation from r4. A CLI signature does not sign its
standalone adjacent resources. Standalone release.yml signs the CLI but does not
individually sign mlx.metallib; requiring an individual library signature would
reject legitimate installations. Resource custody therefore preserves the existing
trusted operator-UID, owner-private installed-payload boundary: safe fixed source,
no links/unsafe ACL/other-writable ancestors, bounded stable reads, SHA-256 pins.
A resource hash proves byte consistency, not new signing provenance. No app claim
that resource hashes, compiled library loading, or local execution grant signed
feed/coordinator/payment authority is allowed.

The compatibility-set envelope remains authenticated by the existing CLI
CompatibilitySetManifest validation and release key. It signs named catalog and
local compatibility hashes; it does not individually authenticate the metallib.
Copying the envelope/catalog bytes must not skip or replace their existing
signature, freshness, exact model and feed validation. Do not import snapshot
trusted-keys.json as a new trust root or change any feed lookup priority. The app
need not duplicate the CLI envelope parser: it safely freezes the complete
named data closure, while the CLI keeps its existing authoritative checks.
No current-directory, DYLD, MLX or other resource-path environment workaround.

## Capture, publish, pin and recovery

App owner updates only app files/helpers/tests; root owns any normative amendment.
No CLI runner/lifecycle/config interface needs to change for adjacent resource
resolution. Keep context FD198, control lease FD199 and lifetime FD200 unchanged.

1. Under existing metadata and control locks, require no pending operation and
   a fresh live peer. Resolve the trusted configured program, verify native
   identity, then select its fixed parent payload. All resource source paths are
   derived from this observed path plus the closed names, never pending input.
2. Traverse selected paths without following links. Use no-follow descriptor
   reads, fstat before/after with size/mtime/inode identity and SHA-256, and safe
   directory identities. Reject world/group write and unsafe ACLs. Source
   resources may be owner-readable 0644 as in existing releases; destination is
   private 0600. Retain source directory identities and verify them and the
   complete selected member set/bytes again before publication; a replacement,
   addition/removal or partial legitimate update fails capture rather than
   combining generations. Do not repair or chmod installation resources.
3. Stream into a sibling private `.payload-<uuid>` directory (0700), not arbitrary
   FileManager recursive copy. One native executable max 512 MiB; each resource
   max 256 MiB; all files including executable max 512 MiB per payload; max 256
   regular files, max 32 directories, depth at most 6, relative path at most 256
   UTF-8 bytes. One active payload plus its temporary copy is bounded to 1 GiB.
   Counters apply during traversal/read/write, before allocation; no unbounded
   in-memory aggregate. Disk-full/oversize/permission/IO failures do not launch.
4. Re-read/validate the destination closure and every hash; strictly verify the
   destination native signature/CDHash. Publish the directory by one same-parent
   atomic rename after fsync of every file and child directory, then fsync its
   parent. Save pin+pending atomically only after publication. Keep locks across
   the publication and pending save. On failure before pending durability remove
   only the exact validated unpublished/new payload; never touch installed files.
5. Persist pin version 2, adding closed resource inventory entries
   `{relativePath: String, size: UInt64, sha256: String}` and a sorted directory
   inventory (relative paths only). Include every resource file, including any
   bundle signing metadata, plus present/absent optional members through the
   exact directory/file inventory. Canonical sorted unique entries, no absolute
   paths/dot segments, strict bounds. Native executable still uses its separate
   r4 native identity. Pin version 1/binary-only pending records are explicitly
   blocked, never silently upgraded or rebound; they remain visible recovery
   metadata. Fresh no-pending authorization can reclaim bounded old app-owned
   binary-only or payload orphans after obtaining the control lease.
6. Every owner/control invocation checks the saved exact operation/pin, current
   configured native identity and source closure/inventory hashes, and the
   private payload inventory/hashes/signature. Changed installation resources
   block recovery just as a changed binary does; do not silently refresh a
   pending payload. Launch only derived payload/macprovider-cli, never a saved
   path. If the source changes after final check, only the frozen payload runs.
   Candidate descendants naturally choose that same executable and adjacency.
   No external-owner restart, original-install fallback or environment override.
7. Terminal plus fresh validated projection/restored peer remains mandatory.
   Completion cleanup acquires metadata and control locks and verifies the exact
   saved tuple/pin and complete payload inventory. Atomically rename the intact
   payload to the fixed sibling `.retired-<uuid>-<cdhash>`, fsync its parent, then
   atomically clear pending and fsync. Do not delete any retired contents until
   pending removal is durable. If pending clearing fails, restore the intact
   payload by rename; if the process crashes after retirement while pending
   still exists, startup verifies the complete retired inventory against that
   exact pin and renames it back before allowing controls. Both active and
   retired directories present, or any mismatch, is a blocked conflict.
   After pending removal is durable, retired deletion is bounded orphan
   maintenance: remove only inventoried/allowlisted private files and directories
   via no-follow relative operations, leaves first. Interrupted deletion leaves
   a no-pending orphan that can be resumed; it cannot strand a valid pending
   operation without its executable. Unexpected entries block deletion, never
   get traversed. No CLI artifact/journal/staging deletions are added. A missing
   active and retired payload never authorizes control execution.

Orphan maintenance is bounded to four recognized direct children in executables
(including r4 single-file snapshots, known temp forms and fixed retired forms), under both locks and
only without pending authorization. Unknown names or unsafe nodes block; no
recursive broad removeItem fallback. Validate recognized directory descendants
against the same closure, depth/count/byte/ownership/link constraints before
removal. A crash after publication and before pending durability leaves an orphan
eligible for this bounded maintenance; a crash after pending save retains the
complete frozen payload. A helper still holding the inherited lease prevents
reclamation even if the GUI has exited.

## Required tests and evidence

Tests are additive to r4; author and independent reviewer remain separate.

| ID | Required evidence |
|---|---|
| SR-01 | Released-style CLI + mandatory library + both flat/Contents resource bundle fixtures capture the exact closure; generated paths include executable basename macprovider-cli and adjacent mlx.metallib. Missing mandatory file, unknown selected descendant, arbitrary sibling bundle, duplicate logical bundle resource and CFBundleExecutable fail before spawn. Unknown unrelated source siblings are neither read nor copied. |
| SR-02 | Reject symlink/hardlink/special node at every depth, unsafe source/destination parent or ACL, foreign owner, native Mach-O disguised as data, malformed/duplicate/path-traversal inventory, version1 pin, oversize file/total, excess count/depth and disk-full injection. Production signature requirement is never replaced by a fixture bypass. |
| SR-03 | Change resource or directory identity during read, between final source check/publication, and between publication/pending save. Either reject with no dispatched owner, or launch only the wholly verified frozen generation after the final check. Source updates never refresh pending pins. Corrupt/change snapshot bytes or add an unknown member before a control: reject. |
| SR-04 | Inject crashes/failures before each file fsync, directory fsync, rename, pending save and cleanup step. Fresh startup does not dispatch from an incomplete payload. Valid pending retains payload; no-pending bounded orphan reclaim works; control flock prevents reclaim; crash after retirement restores the intact pending payload, and interrupted no-pending orphan deletion resumes without deleting installed or CLI-owned state. |
| SR-05 | Real macOS resource load without model/signing credentials: compile a tiny Metal kernel using available xcrun metal/metallib into a temporary test payload, copy through the production resource-custody helper with an explicitly injected native fixture identity, and have a separately compiled normal executable load its adjacent library through Metal's makeLibrary(URL:), resolve the named function and report success. Run from an empty unrelated cwd; binary-only and removed/corrupt-library variants fail. This proves actual compiled Metal resource loading from copied adjacency, not MLX inference or production signing. If Metal compiler is unavailable, report that exact prerequisite and retain executable negative/path tests. |
| SR-06 | Exercise actual pinned MLX lookup where local build products permit: a non-shipping standalone test helper linked to existing pinned MLX products evaluates a tiny MLXArray expression, with the real built mlx.metallib captured adjacent. Run in an isolated cwd, compare expected values; binary-only variant fails. No model weights, network, operator secrets, new package dependency or production command is needed. Compilation/resource/toolchain failure is an explicit test gap, not a pass. Never substitute a handwritten search-order model for actual MLX evaluation evidence. |
| SR-07 | Resource fixture pins cannot mint catalog authority. Preserve existing signed-envelope/catalog negative tests (bad signature, hash, stale feed, wrong target); copy of a modified trusted-keys file does not make it trusted. No new resource-path environment variable, CLI restart path, command or nil-peer owner bypass. Existing candidate lifecycle and r4 generation/context/terminal gates remain green. |
| SR-08 | Valid production-signed released CLI and complete matching installed resources run prepare/evaluate owner and status/cancel/result from the private payload, including candidate subprocess during incumbent drain/restart. This remains separate from unsigned fixture/Metal tests. The current Mac has 0 valid code-signing identities, so new signed-positive qualification is blocked until a matching signed artifact is available. No actual-model inference claim without its own evidence. |

Run targeted Xcode ModelManagement tests then the full app macOS suite. Run
new non-shipping MLX helper/Metal compilation evidence separately and record exact
commands, results and limits. Existing 625-test app pass predates this correction
and cannot qualify resource-complete snapshots. Full combined implementation
code/security/architecture audit remains mandatory after the approved fix.
