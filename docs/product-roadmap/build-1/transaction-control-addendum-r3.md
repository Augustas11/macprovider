# Build 1 transaction control and admission recovery addendum — revision 3

Status: DRAFT FOR INDEPENDENT PLAN REVIEW. Author-only artifact; implementation
is prohibited until the lead records approval of this exact file digest.
Applies to the Build 1 combined working diff based on prerequisite
`f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`, alongside plan-r4.md and
test-spec-r4.md. This narrowly corrects two architecture findings; it neither
qualifies the physical journey nor changes coordinator admission authority.

Supersedes rejected r2 digest
`53c6f2a431e1e4317d7fdd01f4c423d736877ab678227480d6714f04ec81edf4`.
Revision 3 removes suspended execution and the extra supervisor target, binds
configuration at the CLI's actual decode, and pins the effective journal
namespace. It preserves the accepted operation-generation and admission-gate
contracts. No runtime implementation is authorized by this artifact alone.

## Findings and outcome

`ModelCatalogTransactionCommand.recommend` in
`phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` drains the
launchd-managed incumbent before measurement. App cancellation and reconciliation
currently call `MalibuModelCLI.run`, whose `resolveExecutable(peer:)` requires a
fresh running launchd peer and matching PID code identity. A separate runner
instance does not remove this dependency. Status and cancellation therefore fail
while the transaction intentionally owns the drain, including after app restart.

`MalibuModelManagementStore.canRequestAdmission` currently gates offer, retry and
status together and excludes revoked, withdrawn and offer_rejected. An expired
probe followed by revocation can consequently prevent both readback and a fresh
offer indefinitely. Pending retries also lack a distinct app state gate.

Required outcome: status/cancel/result can address one previously authorized,
persisted transaction while its incumbent is absent, using the same trusted CLI
code and exact config. Admission status remains readable in terminal states;
new offer and retry use separate, conservative predicates. No recovery evidence
creates readiness, admission, price or settlement authority.

## Scope and existing foundations

Implementation ownership is the app model-management store/runner, narrow shared
System helpers where required, associated views/localization and Xcode tests. This revision explicitly extends
CLI command/event/action/journal contracts for generation-scoped controls and adds
a private executable snapshot plus a narrowly scoped bounded control launcher. It does not change
coordinator transitions or add external dependencies. SPEC-001 §6.14a and SPEC-044
must adopt Section D before runtime edits. The lead assigns coordinated owners
listed below; changes beyond these contracts reopen the independent plan gate.

Reuse these existing boundaries:

- `InstalledProviderMonitor.configuredProviderProgram`, its owner-private
  install-manifest parsing and configured install-directory restrictions;
  existing owner-private executable and directory-chain checks.
- `MalibuModelCLI.isSignedProviderCLI`: strict static Apple signing requirement,
  provider signing identifier/team and comparison of static/running CDHash.
- `ProviderPaths.configFile`, `ProcessEnvironmentSanitizer`, and the existing
  bounded no-follow/private-file and atomic-write patterns in ProviderConfig.
- CLI transaction journal exact UUID/target validation and CLI-owned cancellation;
  SPEC-044 transcript binding, duplicate handling and success reconciliation.

Do not pass nil peer into general `run` to enable recovery. Do not add a generic
saved-executable runner, arbitrary command list, shell, environment overrides,
credential reader for UI display, or process-kill cancellation.

## A. Capture and persist one control authorization

Introduce a versioned pending record containing the existing UUID, canonical
command target, signed model key, transaction kind, immutable operation generation, start time, timeout and cancel
intent, plus a transaction-control pin. The pin contains:

- CDHash, signing identifier and team from verified code matching the currently
  running peer; strict normalized binary version; the negotiated capability set
  and app contract identity needed for transactions/local activation.
- Section E's opaque transaction_context_sha256, plus app-local fixed config
  path, safely read file identity/SHA-256 and current user/kernel-home identity.
  The opaque digest binds the effective journal root and environment namespace
  without exposing them in the projection. Never persist config bytes/credentials.
- The configured provider path's canonical identity as a comparison-only value.
  It is never accepted as an executable location to launch.

For a new prepare/evaluate/cleanup action, first perform all existing confirmation,
row, capability and live-peer checks. Resolve the live launchd executable and
require that it agrees with the trusted configured-provider resolver; validate
strict signature, running/static CDHash and fixed config. Freeze this pin, then
atomically persist pin and pending binding together **before any mutation is
launched**. A persistence failure prevents dispatch. Revalidate the frozen code
and config at dispatch; never silently replace the pin with a newer binary.

Use one owner-private pending file under a fixed ProviderPaths app-support
subdirectory, with 0700 directory and 0600 regular file, bounded no-follow reads,
no unsafe parent chains/ACLs, atomic temporary-write/fsync/rename/directory-fsync.
Factor existing patterns narrowly. The file is local routing metadata, not
coordinator authority. Reject malformed/unknown versions, missing fields,
noncanonical UUIDs and invalid kinds. Legacy UserDefaults records without a pin
remain visible as recovery-required; they cannot acquire offline authorization
from cached peer evidence. Clear legacy storage only after the safe migration or
terminal reconciliation has durably completed. Never start another transaction
because persistence is unreadable or because an old record lacks a pin.

Config replacement/content change or symlink retarget must fail closed instead of
selecting a different CLI journal. Canonicalizing the new path and overwriting the
saved binding is forbidden. This may conservatively block controls after a
legitimate upgrade or config edit; show a localized recovery-required explanation
and retain the transaction. No automated reinstall, config rewrite, pin refresh,
or owner termination is part of this addendum.

## B. Typed, bounded transaction controls

Add a dedicated typed control API separate from general live-peer `run`:
operation enum `status`, `cancel`, `result`; persisted pending authorization;
fixed ProviderPaths; scoped output callback. No caller-supplied argv, executable,
config, journal root, environment or model overrides. It constructs only the
Section D control grammar, with the complete persisted selector.

Before each request load the safe pending record and compare UUID, canonical
target, signed model key, kind and generation with the request. Result additionally
requires evaluate_model and a matching succeeded terminal. Result without pending
authorization uses the ordinary fresh-live-peer path and exact evaluation selector
from a newly validated adoption action. No cleanup start/retry, prepare,
evaluation, adoption or offer is available through the recovery API.

Resolve CLI code independently through the existing trusted configured-provider
resolver and compare canonical identity with the pin. Repeat private-file/parent
checks, strict signature, CDHash, signing identifier/team, fixed config digest and
captured capability/app-contract compatibility checks. Do not use launchctl live
job/PID, bundled/PATH/DEBUG override, or a saved arbitrary executable path.
Captured proof is valid only for unchanged code and is never positive cached
health/readiness/admission evidence.

### Private executable snapshot and trust boundary

The operator UID is trusted, consistent with the existing owner-private
executable, config and pending-file boundary. This is not protection against
malware already executing as that UID. Ordinary concurrent updates/config edits
must nevertheless fail closed or use the already authorized immutable input.

While fresh live-peer authorization is available, safely open the configured CLI
with O_NOFOLLOW, validate owned regular executable/no unsafe ACL or parent chain,
and bounded-copy from that descriptor into an exclusive 0600 temporary file in
fixed `ProviderPaths.appSupport/ModelTransactions/executables/`. Require a
0700 private directory, one active snapshot, maximum 512 MiB file size and total
snapshot budget 1 GiB including its temporary copy; reject oversized/disk-full
copies. Check source descriptor identity/size before and after copying. Make the
completed file owner-executable (0700), verify its full strict signature,
identifier/team and CDHash against the live-peer pin, fsync it and atomically
publish under a name derived by the app from the canonical transaction UUID and
pinned CDHash. Never accept an executable path from persisted input. Directory
and snapshot reads reject symlinks, unsafe ACLs, hard links and unsafe parents.

Persist snapshot identity with pin+pending only after publication and before
owner mutation. An incomplete copy never authorizes execution. Before every
control, revalidate configured-source identity/signature/CDHash according to the
existing recovery policy, and independently validate the safe published snapshot
and its strict signature/CDHash. Source replacement before the check blocks.
Source replacement after the check can execute only the already verified private
snapshot, never replacement source bytes. Do not overwrite or refresh a snapshot
for a pending transaction after a legitimate binary upgrade. Unexpected snapshot
changes fail closed under this trusted-UID boundary.

Launch the snapshot normally; **no suspended child, supervisor executable or new
sign/embed target** is introduced. Initial owner dispatch may use the same pinned
snapshot after fresh live-peer and Section E validation; it must not re-resolve
and execute newly replaced source bytes. Long-running owners do not inherit the
short-control deadline/lifetime lock. Confirm actual signed CLI control commands
and owner commands work from the snapshot, including executable-relative resource
resolution, before acceptance. Missing resource support blocks instead of copying
unverified resources or silently falling back to another binary.

Snapshot garbage collection is app-owned and bounded: remove only verified
app-owned snapshot/temp entries that no safe pending record or active control
lock references, after terminal plus fresh projection reconciliation. Crash before
pending publication may leave at most one bounded orphan copy; next startup under
the same exclusive metadata lock safely reclaims that owned orphan. Never remove
CLI staging, weights or transaction journals through snapshot cleanup.

### Helper lifetime, lock handoff and resources

Adapt the existing bounded process/completion patterns in
ProviderCredentialHandoffRunner, without broad general-runner replacement.
Use a narrow normal posix_spawn launcher where explicit descriptor inheritance
is needed. Before spawn, acquire a nonblocking flock on a fixed owner-private
control-lock file. Never unlink/replace this lock file. Maintain safe directory
identity checks and a persistent fixed inode. Across app instances at most one
control request owns this lock. Within one app allow one active request plus one
coalesced pending cancellation intent; no unbounded queue. Cancel takes priority
over status polling once the current helper has been reclaimed.

The app inherits the **same open file description** holding flock into the CLI
at a fixed reserved descriptor using spawn file actions, with close-on-exec cleared
only for that child descriptor. The parent retains its reference until actual
child exit/reap; it never calls LOCK_UN on the shared description. The CLI validates
that descriptor's expected regular private lock-file identity before work and
retains it until process exit. The CLI must not independently open/unlock a
replacement lock file. A normal launch is atomic with descriptor inheritance:
GUI death before spawn leaves no child and releases its lock; death after spawn
leaves the child holding the inherited lock. There is no unlock/reacquire gap.
A replacement app sees busy until the child exits. Verify actual macOS flock
inheritance and last-close behavior in a real subprocess test, including GUI
SIGKILL immediately after spawn and before child argument parsing.

The spawned short CLI receives an expected parent PID only as a self-check input,
never as a signal destination, and inherits a lifetime pipe whose write end is
held only by the GUI. Before config, context or journal access, it starts an
independent ten-second monotonic deadline and a noncooperative parent-lifetime
watcher modeled on CandidateParentLifetimeGuard. EOF or a changed kernel getppid
causes immediate _exit of the helper; PID reuse cannot restore the original
kernel parent relationship. The lifetime pipe also detects graceful GUI closure.
Early argument/descriptor validation failure exits, releasing the inherited lock.
No deliberately stopped state exists that can prevent the guard from starting.
The ten-second GUI deadline starts before spawn; the child deadline starts at
its earliest app-control entry point, before config decode or blocking work.

GUI timeout, abandonment, output overflow or normal shutdown closes output
acceptance and signals only its exact directly spawned control child, then reaps
it. Use SIGTERM followed by SIGKILL with a one-second maximum grace, scheduled
so SIGKILL occurs no later than the ten-second execution cutoff (TERM at nine
seconds for deadline expiry). Keep the retained child handle and completion gate
until waitpid/termination proves exit; no saved-PID recovery signals, process-group
signals, owner/incumbent/probe signals or general mutable current-process slot.
An OS-delayed reap keeps the parent lock/reference and busy state; after GUI
failure the child's independent guard/deadline owns reclamation. Kernel process
scheduling failure is outside the application guarantee; tests assert cutoff and
reap under a functioning OS, not an impossible uninterruptible-kernel guarantee.

Drain pipes concurrently with hard caps: stdout 8 MiB, stderr 64 KiB per request;
status/cancel JSONL or partial line 64 KiB; result document 8 MiB total. Bound
read chunks and decoded event storage by the same budget. Overflow terminates the
helper and rejects the entire output; truncated JSON is never accepted. These
bounds accommodate the CLI's existing 4 MiB private journal/result read limit.
Close every descriptor/readability callback on completion, release retained tasks
and buffered data, and scope callbacks by UUID/kind/generation/request nonce.
Child watchdog/lifetime execution uses a dedicated queue independent of blocked
config/journal work or output backpressure. Control commands spawn no descendants.

A timed-out/killed helper produces uncertain status, never transaction cancellation
or success. Persist cancel intent before dispatch. CLI controls are interruptible:
OS locks release on helper exit, atomic journal replacement leaves old/new complete
records, staging cleanup is idempotent, and the next exact reconciliation verifies
publication truth. Test interruption at write/cleanup/hash boundaries. The long
transaction owner is neither killed nor given the control child's parent guard.

Cold restart loads the safe pending pin and exact generation without a live
incumbent. Busy during the old child's bounded exit is explicit. Closed event and
signed-target validation remain. Published commit winners retain succeeded with
too-late disclosure. Terminal success still requires fresh validated projection
and restored peer evidence before clearing pending or showing readiness. Complete
results feed existing adoption validation and never introduce economics on local
rows.

## C. Separate admission predicates

All three gates require a current row from the latest valid projection, exact
supported catalog target, negotiated capabilities, fresh live peer and no
conflicting operation/pending catalog transaction. None uses the offline control
exception. A prior admission-only failure must allow an explicit status refresh;
it must not permanently lock the operation state.

| Operation | Additional app gate | Authoritative behavior retained |
|---|---|---|
| Read status | Current exact supported target; allow every recognized admission state including revoked, withdrawn, offer_rejected and initial states. Do not require fit/weights predicates merely to read. | Existing CLI resolves exact candidate and reads coordinator state. No implicit offer/retry. |
| New offer | Explicit confirmation, current target locally ready and fitting, fresh initial state local_only/not_offered/offerable or terminal revoked/withdrawn/offer_rejected. Unknown/missing state is unavailable until readback. | Existing CLI builds a fresh signed offer with current evidence. Coordinator sanctions, freshness, key and generation checks remain decisive. |
| Retry | Explicit confirmation and current ready/fitting target in exactly offer_submitted, sandbox_probe_only, network_admitted_unsettled or catalog_priced. | Existing CLI requires its original pending journal, obtains fresh coordinator status and signs the bound retry envelope. Missing journal and changed/terminal status fail closed. |

Do not infer journal availability in the app or duplicate its custody. The retry
button may be offered in a recognized pending state, but absence of the CLI-owned
journal returns an explicit unavailable result and a usable status action. Do not
turn retry failure into a new offer. Do not expose new-offer/retry for
settlement_capable, unknown or network_visible_unpriced states absent a separate
contract. After each action re-read the authoritative projection; submission is
pending and never a settled-credit success. A revoked provider may attempt a
fresh offer but a continuing sanction remains rejected/unpaid.

## D. Immutable operation-generation contract and ownership

Protocol2 local activation and model_catalog_transaction_event.v1 exist only in
this unpublished Build 1 diff. Amend their proposed closed shapes directly; do
not introduce projection3/eventv2 or a new capability to preserve an unmerged
intermediate. Preserve actual landed protocol1 behavior. The existing negotiated
transaction/local-activation/adoption capability set requests:

`models catalog-economics --local-activation --json`

Its `source.projection_protocol_version: "2"` action shape adds nullable
`operation_generation`. It is a canonical lowercase UUID string for available
prepare_model/evaluate_model/cleanup_staging actions; an available
adopt_recommendation action carries its source evaluation generation even though
adoption retains its separate established transaction protocol. Other legacy
action kinds and unavailable actions have null generation. The new app cannot
fabricate a generation or recover it by choosing the newest journal. The separate
cleanup-recovery addendum's protocol2 `recoveries` entries carry this same action
shape and generation; row cleanup remains unavailable there. Recovery dispatch
binds its exact target_model_id/model_key/action tuple without a model-row merge.

The CLI reserves generation before projecting an available local action, under
its journal lock, and returns the same generation on repeated projection until
that operation is started or terminal. Initial prepare/evaluate transaction ID
and generation are separate immutable UUIDs. Each explicit cleanup attempt gets
a newly reserved generation, even when transaction ID and cleanup_staging kind
are reused. A pending reservation is not a running operation and does not replace
an active generation. A repeated start with identical tuple is idempotent and
cannot turn into a new attempt. A stale generation cannot start the next attempt.

New start grammar:

- `models prepare TARGET --transaction-id UUID --operation-generation GENERATION --confirm --json --config CONFIG`
- `models recommend-prepared TARGET --transaction-id UUID --operation-generation GENERATION --confirm --json --config CONFIG`
- `models cleanup-staging UUID --model TARGET --operation-generation GENERATION --confirm --json --config CONFIG`

New control grammar (OP is status/cancel/result):

`models transaction OP UUID --model TARGET --expected-kind KIND --operation-generation GENERATION --json --config CONFIG`

Both selector flags are required together. Allowed kinds are prepare_model,
evaluate_model and cleanup_staging; result requires evaluate_model. Model key is
validated against the selected persisted record and emitted event; target is the
canonical command model ID. Unknown/malformed/partial selectors fail nonzero
before mutation. The CLI starts its control-helper self-deadline before config
load; it does not spawn owner/probe subprocesses for any of these controls.

For generation-bound operations emit closed JSONL schema
`model_catalog_transaction_event.v1`, with every existing v1 field plus required
`operation_generation: GENERATION`. No other new fields/enums. Event sequence
is monotonic for that operation generation; replay deduplication identity is
UUID+kind+generation+sequence, and the first replayed sequence need not be one.
The complete result stays byte-preserved autotune_recommend.v1; its journal read
is authorized by the exact evaluation selector rather than rewriting that schema.

Persist journal version and operationGeneration, with events bearing the same
generation. Initial streams and each cleanup attempt retain their immutable
selector. Under the **same journal lock**, choose original versus cleanup by
expected kind, load the expected generation, validate UUID/target/kind/generation,
then and only then perform owner-loss reconciliation, artifact hashing/cleanup,
cancelRequested writes or result access. Do not inspect newest cleanup first,
preflight with a separate status read, or validate returned output after mutation.
Status/cancel for a completed original operation reads that original terminal
(and too-late truth) even after cleanup starts. If the requested older cleanup
generation is no longer retained, return unavailable without any mutation; never
fall forward to a newer generation. A retained terminal attempt can return its
own terminal without changing newer work. All owner heartbeats, cancellation
checks and terminal writes also validate their expected generation under lock.

Default protocol1 remains shape-compatible and does not gain local transaction
controls. Protocol2 actions and eventv1 require generation as part of the final
Build 1 closed contract. Flagless new transaction controls and partial selectors
fail before mutation; there is no released UUID-only control compatibility path
to preserve. Unpublished local journal/pending fixtures without a generation
remain recovery-required/non-actionable; do not synthesize a positive generation
or migrate them into authorization. Existing unrelated landed switch/adoption
protocols and their transactions remain unchanged. Generation-aware reservation
must not reuse an incomplete unversioned reservation.

Ownership after gate:

| Owner | Files/methods and responsibility |
|---|---|
| Lead/contracts | SPEC-001/SPEC-044 normative extension and governance; ModelCatalogEconomics source version/action encoding and capability negotiation integration. |
| CLI transactions owner | ModelCatalogTransactions event/record generation fields; lifecycle and exact selector enforcement in reconcile/result/check/heartbeat/terminal; calls to Section E's root-owned context helpers; generation/lifecycle/interruption tests. Do not implement a separate config reader or edit retention methods. |
| Lead CLI context owner | New ModelTransactionContext.swift: context wire decoding, safe consumed-config loader, namespace/root digest, app-control lifetime/lock validation, shared ArgumentParser option group. ModelsSubcommand/projection hooks coordinated with transaction owner. Exact interfaces below. |
| CLI durable/retention owner | Reservation/index/archive changes and immutable-generation retention integration, including cleanup generation reservation. Transaction owner specifies required selector behavior but does not edit retention/reserve/archive methods concurrently. |
| App owner | Pinned durable pending generation, private verified snapshot, typed bounded normal launcher and inherited lock handoff, protocol2/eventv1 generation parsing/dispatch, admission gate split, views/localization and Xcode tests. |

No owner begins runtime work before approval of this exact addendum and normative
contract completion. Interface disagreements or an unbounded supervision failure
reopen review instead of weakening a requirement to fit current code.

## E. Same-consumed-config and private namespace binding

SPEC-044 R010 forbids projection exposure of private config/cache paths. Respect
that boundary: add only nullable `source.transaction_context_sha256` to the final
unpublished protocol2 projection. It is a 64-character lowercase SHA-256 digest,
not raw paths, file identities, HOME, config contents or a reversible encoded
context. Available local transaction/recovery actions require a nonnull context
digest. Protocol1 omits the new field. SPEC-044 must explicitly define this opaque
field and its limited local-routing purpose before implementation; it does not
authorize readiness/economics. Root's earlier raw context-object proposal is
rejected and is not part of this revision.

The CLI internally hashes a domain-separated UTF-8 JSON context using sorted keys, no insignificant
whitespace and version (`model_transaction_context.v1`): exact standardized fixed
config path, resolved no-symlink path, file device/inode/size and SHA-256 of the
actual consumed bytes; uid and kernel-derived home; resolved canonical durable
root and `.transactions` path plus their existing directory device/inode identities;
and environment namespace `sanitized_app_v1`. Required namespace means no
MACPROVIDER_* configuration overrides, HF_HOME or HF_HUB_CACHE, with explicit
HOME matching kernel home. Only the existing sanitizer's innocuous PATH/user/
locale/temp values may remain. Do not include locale/PATH as changing journal
identity; verify they cannot override configuration/root. Never print the hashed
private fields, even on mismatch. Digest is local binding, not a secret or a
coordinator credential.

Use the same context calculation for protocol2 projection and app-bound starts/
controls. All AppConfig consumers must use the one resolved object: remove the
catalog command's current second config load on this bound path and pass the
frozen object to action/recovery producers and every nested artifact resolver.
Do not recompute a context from one load while producing actions from another. Projection may perform its already-authorized reservation/store setup
before publishing the digest, so root directory identities exist. A bound control
never creates or secures a journal to compute a digest: pure config resolution
and safe metadata reads of the existing root precede all store construction,
lock acquisition, journal opening/recovery/hash/cleanup/cancel operations. Missing
or replaced root/directory identity is unavailable. Root symlink retarget cannot
silently select a new namespace. The bound object freezes root resolution; later
operations never consult ProcessInfo environment or defaultRoot again.

For app dispatch, append `--transaction-context-fd N` to all typed new owner and
control commands. It names one inherited read-only private pipe containing at most
64 KiB of closed JSON:

```json
{
  "schema": "model_transaction_context_expectation.v1",
  "transaction_context_sha256": "64 lowercase hex",
  "config_path": "fixed app-local ProviderPaths path",
  "config_device": 1,
  "config_inode": 1,
  "config_size": 1,
  "config_sha256": "64 lowercase hex",
  "uid": 1,
  "home_directory": "kernel home"
}
```

The values are illustrative types, never literal defaults. Paths remain in
private inherited IPC/pending metadata, not source JSON, argv, logs or UI. Device,
inode, size and uid are nonnegative integers with checked native-width conversion;
size is positive and at most 1 MiB. Config bytes/credentials never enter this
object. The app constructs it from its safely captured config pin and opaque
projection digest; it cannot override the fixed config path or choose a root.
The usual `--config FIXED_CONFIG` already exists; no new private root argument
is introduced. Close the IPC write side after the one document; missing EOF,
unknown fields, invalid descriptors or oversize fail closed.

CLI execution order for every app-bound command:

1. For short controls, install the early lifetime/deadline guard and validate the
   inherited control lock first, before any config or journal work. Read the
   bounded expectation and validate exact command tuple/descriptor options.
2. Resolve the fixed supplied config path with existing private/no-follow rules;
   open once, fstat, bounded-read UTF-8 bytes, fstat again. Require unchanged owned
   regular file/no unsafe ACL/parents and expectation path/device/inode/size/hash.
   A changed file fails before touching either candidate journal.
3. Call existing `ConfigLoader.load(cli:environment:fileExists:readFile:)` with
   closures that return only that frozen verified text for the exact config path.
   ConfigLoader's YAML, kv_disk_cache and paged_kv rereads all receive identical
   captured bytes. No second filesystem read or later default ConfigLoader call.
   Retain normal YAML/environment/CLI interpretation for the allowed namespace.
4. Resolve `CachedModelArtifactResolver.forConfig` once with that AppConfig,
   explicitly validated environment and kernel home. Compute the private context
   digest with safe root metadata; compare to the expected opaque digest before
   store construction or any journal side effect. Config/environment/root mismatch
   fails even if another store contains copied UUID/kind/generation records.
5. Hand the frozen AppConfig/root to the transaction owner/store and perform the
   generation selector checks under that store's lock. Every nested operation
   uses this same bound object; no later environment/default-root re-resolution.

If normal atomic config replacement occurs after step 2, the operation either
continues using the already verified captured A bytes/root or fails a later
identity check; it never decodes replacement B. If replacement occurs after the
parent's preflight but before step 2, it fails against the expected file/hash and
context. The rule also covers initial owner dispatch, preventing the frozen pin
from authorizing a different config after confirmation. Standalone explicitly
invoked CLI operations may retain their existing non-app context route; they do
not receive the app's offline execution exception. No app code falls back to
that route after context validation failure.

Root-owned interfaces in the new CLI file (names/signatures locked by this plan):

- `ModelTransactionContextOptions: ParsableArguments` owns
  `transactionContextFD: Int32?`, `controlLockFD: Int32?`,
  `controlParentPID: Int32?`, `controlLifetimeFD: Int32?`. The latter three are
  required together only for short app controls; all are rejected on unsupported
  commands. FD options use ArgumentParser kebab-case flags.
- `ModelTransactionControlLease.start(options:) throws -> ModelTransactionControlLease`
  installs deadline/parent checks and validates inherited lock/lifetime descriptors;
  retain the returned lease until control exit. It never owns a transaction PID.
- `ModelTransactionContextLoader.load(configPath: String?, options: ModelTransactionContextOptions, environment: [String: String], homeDirectory: URL) throws -> BoundModelTransactionContext`
  implements the single-read expectation/namespace rules above. This loader does
  not open transaction journals or call store methods.
- `BoundModelTransactionContext` exposes immutable `config: AppConfig`,
  `durableRoot: URL`, `transactionRoot: URL`, `projectionDigest: String?` and the
  frozen validated namespace to its consumers. Construction is loader-owned.
  ProjectionDigest is nonnull only for a safely bound protocol2 source.
- CLI transaction owner adds `ModelCatalogTransactionStore.forContext(_ context: BoundModelTransactionContext)` and routes app start/control/projection lifecycle
  through the frozen root; it does not reimplement the context loader. Root owns
  shared argument/context and ModelsSubcommand projection hook edits; transaction
  owner edits ModelCatalogTransactions call sites only after interface handoff.

The app owner implements the closed expectation encoder/FD setup, projection
opaque-digest persistence and snapshot/launcher. Root owns CLI context code/tests;
CLI transaction owner owns exact-generation and interruption integration tests;
retention/reserve/archive ownership remains separate as specified in Section D.

## Acceptance test specification

Tests below supplement B1-T03/B1-T05/B1-T08/B1-T11. Each negative asserts no
unauthorized helper execution/owner mutation and no promoted UI authority.

| ID | Required evidence |
|---|---|
| TC-01 | Fresh signed live peer and matching configured code capture one complete pin+pending record before owner dispatch. Failed write/fsync, unsafe path and incomplete record prevent dispatch. Test crash immediately before/after rename and before owner launch. |
| TC-02 | Start evaluation, remove incumbent job/PID and expire peer evidence. Same app status and cancel use the pinned helper, reach the real/injected CLI journal and await genuine terminal; normal new prepare/evaluate/cleanup/adopt/offer remain blocked. |
| TC-03 | Recreate the store/runner from disk during drain with no saved live peer. Status and cancel for the exact pending binding succeed. Result works only after the matching successful evaluation; prepare/cleanup/failed-evaluation result requests fail. |
| TC-04 | Independently alter UUID, canonical target, model key, kind, user/home, fixed config path/content, config symlink target, pin version, capability set/app contract, signing team/identifier, signature validity or CDHash. Reject before spawn. Missing pin and legacy UserDefaults evidence cannot authorize recovery. |
| TC-05 | Tamper persisted executable path/install manifest, substitute bundled/PATH/DEBUG binary, make executable/config/parent world-writable, symlink or add unsafe ACL. Existing trusted-path rules reject it. Persisted paths never become launch inputs. |
| TC-06 | Replace configured binary before final source check: reject. Replace after check/before spawn: execute only pinned verified snapshot bytes or fail, never replacement bytes. Corrupt/retarget snapshot, unsafe permissions/signature or oversized copy fails. Actual signed CLI controls/owner work from snapshot including resources. Assert no owner/runner signals from control reclamation. |
| TC-07 | Ten-second timeout, duplicate cancellation, delayed output and restart retain UUID+kind+generation scoping. Status/cancel deduplicates exact sequence; cleanup replay can begin above one. Helper termination never becomes transaction cancellation or a synthetic terminal. |
| TC-08 | Terminal succeeded with missing/stale/invalid projection or unavailable restored peer retains pending/recovery UI. Fresh matching projection unlocks success. Postcommit cancellation discloses too late. Complete result still passes existing signed key/canonical ID adoption checks. |
| TC-09 | Hung control, lock wait, stdout/stderr/partial-line flooding and oversized result hit execution/output bounds, close descriptors and reap only the exact control helper. Repeated timeouts and concurrent status/cancel keep one CLI maximum; pending cancellation takes priority after reclamation. No owner/runner/group signals. |
| TC-10 | GUI normal exit and SIGKILL before normal spawn, immediately after spawn before CLI parsing, and during blocked work leave no stopped/orphan accumulation. Before spawn no child exists; after spawn inherited flock stays owned until early parent/deadline guard exits. Cold restart is busy until exit, then one new control proceeds. Real macOS descriptor/flock inheritance, last-close, watchdog independence and repeated crashes pass. |
| TC-11 | Capture original A, create cleanup A generation C1, then interleave original status/cancel at the journal lock. Original terminal is returned and cleanup receives zero cancel/reconcile/cleanup writes. Cleanup C1 selectors reach only C1; create retry C2 and prove delayed C1 cannot mutate C2. Wrong kind/generation fails before owner-loss reconciliation, artifact hashing, staging removal or journal write. |
| TC-12 | New action reservation repeats stable generation; cleanup retry produces a distinct generation; duplicate start is idempotent. Wrong tuple, old-owner heartbeat/terminal write and partial selector flags fail closed. Landed protocol1 remains wire-compatible; final protocol2/eventv1 require generation; flagless/partial controls cannot mutate records and controls cannot authorize pinless old fixtures. |
| TC-13 | Kill only the helper during atomic journal temp-write/rename, owned cleanup and publication hash reconciliation. Next exact selector recovers lock/journal truth and preserves incumbent/published data. No newer generation is mutated; no false cancellation/success from helper exit. |
| TC-14 | After final app config check, atomically replace private config A with valid B selecting another root containing copied exact selectors. CLI rejects before either journal is created, secured, locked, read/reconciled, hashed, cleaned or cancelled. Also replace same bytes with new inode, mutate environment override/home, replace root directory or symlink target: context mismatch fails. |
| TC-15 | Replace config after CLI safe capture. Inject all ConfigLoader rereads and assert they receive frozen A bytes; every nested resolver/store uses captured A root or fails, never B. Apply same tests to initial owner dispatch and control paths. No raw config/root/home/identity appears in projection/log/UI; only opaque context digest is added to protocol2. |
| AR-01 | Expired probe becomes coordinator revoked: status remains enabled; fresh explicitly confirmed re-offer dispatches models offer, never retry; returned pending state retains no paid claim. Then coordinator admission/pricing/settlement remain separately observed. |
| AR-02 | Read works for all recognized current-target states, including terminal and not fitting/not locally ready rows where the CLI can resolve the target; wrong/stale/noncurrent/unsupported row or missing peer is rejected. Admission failure does not disable future readback. |
| AR-03 | New-offer initial/terminal matrix and retry exact pending matrix. Reject unconfirmed, unknown/missing, wrong target and settlement-capable mutation. CLI missing pending journal or changed fresh status leaves explicit retry failure and usable status, never automatic re-offer. |
| AR-04 | Continuing sanction/revoked key, stale authority, withdrawn generation and offer rejection stay unpaid after attempted new offer. Read alone sends no offer. Positive app fixtures are labeled fixtures and do not qualify real coordinator or physical execution. |

Use injected trust/file/launcher seams for deterministic negatives, plus real
macOS subprocess tests for snapshot execution, inherited-lock lifetime, parent
death and bounded exit/reap behavior. Production identity
positive testing requires an appropriately signed test/release artifact; a DEBUG
bypass is not evidence. Record any unavailable signed integration evidence as a
gap instead of labeling the suite complete.

Run targeted ModelManagement Xcode tests while iterating, then the complete app
Xcode suite (SwiftPM is not a substitute):

```sh
xcodebuild -project phase3-binary/app/Malibu.xcodeproj \
  -scheme Malibu -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Record exact command, exit status, selected count and artifact/log path in the app
implementation report. Run affected existing signed-executable/config safety tests
and CLI pending-retry tests when integration changes warrant it; do not claim
prior runs cover these additions. Finish with full combined code, security and
architecture review: zero Critical, High or Medium findings. Independent approval
of this document is a prerequisite to implementation, not implementation evidence.
