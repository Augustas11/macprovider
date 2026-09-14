# Build 1 transaction control and admission recovery addendum — revision 2

Status: DRAFT FOR INDEPENDENT PLAN REVIEW. Author-only artifact; implementation
is prohibited until the lead records approval of this exact file digest.
Applies to the Build 1 combined working diff based on prerequisite
`f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`, alongside plan-r4.md and
test-spec-r4.md. This narrowly corrects two architecture findings; it neither
qualifies the physical journey nor changes coordinator admission authority.

Supersedes rejected r1 digest
`a2a11024b493bc20c7b842c424f1f0788f37e8d55b6fd55401b23728b495cde5`.
The independent r1 review identified unbounded helper resources and a CLI stream
selection race. Sections B/D and TC-07/09–13 below close those two findings at
plan level; no runtime implementation is authorized by this artifact alone.

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
a narrowly scoped app-bundled control supervisor executable. It does not change
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
- Fixed current `ProviderPaths.configFile` standardized path and resolved identity,
  a SHA-256 digest of its bounded safely read contents, and current user/home
  identity. Do not persist config bytes or any credentials.
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

### Helper execution and resource contract

A ten-second UI continuation race is insufficient. Use one dedicated
`MalibuTransactionControl` supervisor executable built/signed inside Malibu.app,
with an early non-UI entry point and a fixed typed request protocol. This
supervisor is part of the app's trusted installed code, not a separately
configured provider or arbitrary executable. Production resolves it only from
the running app bundle and validates its signing/team and enclosing bundle
identity. Add it to the existing Xcode build/sign/embed path without dependencies;
release validation must cover the nested signature without force/deep signing.
Tests can inject a launcher; unsigned DEBUG success cannot qualify production.

The supervisor starts an independent monotonic ten-second watchdog before
creating any CLI child. It reads exactly one bounded typed request (at most
64 KiB) through an inherited private pipe, loads the fixed pending file itself,
and performs the same pin checks. It holds a nonblocking OS file lock at a fixed
owner-private app-support control-lock path across the complete request lifetime.
Across app instances there may be at most one lock-owning supervisor/CLI pair;
a contender returns busy and never spawns a CLI. In-process the store allows one
request and one coalesced pending cancellation intent, with no unbounded queue.
Cancellation is persisted and dispatched after an in-flight status helper has
been reclaimed; status polling cannot starve that cancellation.

The supervisor, not the GUI, creates the CLI with
`POSIX_SPAWN_START_SUSPENDED`, verifies the actual child CDHash/signing identity
against the frozen pin, rechecks fixed config, and resumes only that exact child.
Known mismatches fail before spawn; replacement races fail before resume. A GUI
crash during suspension therefore leaves a live supervisor/watchdog able to
reclaim the child. CLI parent-lifetime requirements apply only to this short
control child; the long-running transaction owner remains independent.

The supervisor observes EOF on its dedicated GUI lifetime pipe. GUI exit/crash,
explicit request abandonment, a ten-second deadline, output overflow or signing
failure closes output delivery and terminates **only the directly spawned CLI
control child**. No process-group signal, guessed PID, general runner mutable
current-process slot, owner/incumbent/probe signal or file deletion is allowed.
Hold/reap that child without permitting PID reuse; use an immediate SIGKILL when
forced reclamation is required, then waitpid, close every pipe/descriptor, release
the control lock and exit. An OS-delayed reap retains the lock/busy state rather
than permitting another helper. The ten-second bound is the execution cutoff;
no new helper is admitted until the prior child is actually reaped. The GUI also
retains its exact supervisor child handle and reaps it on normal completion/exit.
An independent watchdog thread/queue cannot be blocked by pipe reads, hashing,
lock acquisition or waitpid. The supervisor itself must not perform CLI journal
work or spawn descendants other than the one CLI child.

Drain stdout/stderr concurrently with hard caps: stdout 8 MiB per invocation,
stderr 64 KiB, individual JSONL/partial line 64 KiB for status/cancel, and result
8 MiB total (the existing complete recommendation parser remains authoritative).
On overflow stop parsing and reclaim the child; do not truncate a document and
accept it. Limit decoded event storage by the same byte budget, use bounded read
chunks, and discard stale callbacks keyed by UUID/kind/generation/request nonce.
The stdout bound accommodates the CLI's existing 4 MiB private journal/result
read limit without allowing arbitrary buffering. Closed descriptors and completed
request tasks cannot retain output after timeout. Use the existing sanitized
environment with no extra config/model-root variables.

Supervisor start/IPC timeout before child creation also ends at ten seconds and
spawns nothing further. On cold app restart, the old supervisor sees EOF and
reclaims its child; a new request may briefly receive busy until the lock is
released. If the supervisor unexpectedly dies, the GUI reclaims/reaps the known
child where available; the CLI control entry point additionally starts its own
independent ten-second self-deadline before config/journal access, providing a
finite fallback after resume. A supervisor crash while its child is suspended is
a distinct failure mode: implementation must demonstrate a bounded OS/process
supervision mechanism for that case before acceptance, or return to this plan
gate. It must not claim GUI-crash tests prove arbitrary supervisor-crash safety.

The CLI control process can be interrupted during reconciliation: lock release is
OS-owned; journal writes use atomic replacement; owned staging removal is
idempotent and publication truth remains verified on the next exact reconciliation.
Tests must interrupt at write/cleanup/hash boundaries and show subsequent controls
recover safely. Never infer cancelled or succeeded from a killed helper. Persisted
cancel intent remains uncertain until genuine CLI terminal output arrives.

Cold restart can use only the safe pending pin and Section D selector without a
live incumbent. The closed transcript and exact signed target checks remain.
Published commit winners retain succeeded/too-late disclosure. Terminal success
still needs a fresh validated projection and fresh restored peer before clearing
pending or showing readiness. Complete results go to the existing adoption
validator and cannot introduce economic claims for local-only rows.

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
| CLI transactions owner | ModelCatalogTransactions event/record generation fields; start/cleanup/control grammar; modelCatalogTransactionRead, reconcile/result/check and owner heartbeat/terminal exact-selector enforcement; helper self-deadline and interruption tests. Coordinate edits before touching shared methods. |
| CLI durable/retention owner | Reservation/index/archive changes and immutable-generation retention integration, including cleanup generation reservation. Transaction owner specifies required selector behavior but does not edit retention/reserve/archive methods concurrently. |
| App owner | Pinned durable pending generation, typed runner/supervisor build target and lifetime/resource bounds, protocol2/eventv1 generation parsing/dispatch, admission gate split, views/localization and Xcode tests. |

No owner begins runtime work before approval of this exact addendum and normative
contract completion. Interface disagreements or an unbounded supervision failure
reopen review instead of weakening a requirement to fit current code.

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
| TC-06 | Swap binary between static preflight and suspended launch. Child identity mismatch prevents resume and reaps only that helper. Matching identity resumes. Config retarget/change before resume fails. Assert owner/runner PID receives no signal. |
| TC-07 | Ten-second timeout, duplicate cancellation, delayed output and restart retain UUID+kind+generation scoping. Status/cancel deduplicates exact sequence; cleanup replay can begin above one. Helper termination never becomes transaction cancellation or a synthetic terminal. |
| TC-08 | Terminal succeeded with missing/stale/invalid projection or unavailable restored peer retains pending/recovery UI. Fresh matching projection unlocks success. Postcommit cancellation discloses too late. Complete result still passes existing signed key/canonical ID adoption checks. |
| TC-09 | Hung control, lock wait, stdout/stderr/partial-line flooding and oversized result hit execution/output bounds, close descriptors and reap only the exact control helper. Repeated timeouts and concurrent status/cancel keep one CLI maximum; pending cancellation takes priority after reclamation. No owner/runner/group signals. |
| TC-10 | GUI normal exit and SIGKILL before/after suspended spawn/resume cause independent supervisor cleanup within the execution bound; cold restart observes busy until reaping, then recovers. Exercise supervisor startup failure and watchdog independence. Explicitly prove or block on the suspended-child/supervisor-crash case; do not count only normal-exit tests. |
| TC-11 | Capture original A, create cleanup A generation C1, then interleave original status/cancel at the journal lock. Original terminal is returned and cleanup receives zero cancel/reconcile/cleanup writes. Cleanup C1 selectors reach only C1; create retry C2 and prove delayed C1 cannot mutate C2. Wrong kind/generation fails before owner-loss reconciliation, artifact hashing, staging removal or journal write. |
| TC-12 | New action reservation repeats stable generation; cleanup retry produces a distinct generation; duplicate start is idempotent. Wrong tuple, old-owner heartbeat/terminal write and partial selector flags fail closed. Landed protocol1 remains wire-compatible; final protocol2/eventv1 require generation; flagless/partial controls cannot mutate records and controls cannot authorize pinless old fixtures. |
| TC-13 | Kill only the helper during atomic journal temp-write/rename, owned cleanup and publication hash reconciliation. Next exact selector recovers lock/journal truth and preserves incumbent/published data. No newer generation is mutated; no false cancellation/success from helper exit. |
| AR-01 | Expired probe becomes coordinator revoked: status remains enabled; fresh explicitly confirmed re-offer dispatches models offer, never retry; returned pending state retains no paid claim. Then coordinator admission/pricing/settlement remain separately observed. |
| AR-02 | Read works for all recognized current-target states, including terminal and not fitting/not locally ready rows where the CLI can resolve the target; wrong/stale/noncurrent/unsupported row or missing peer is rejected. Admission failure does not disable future readback. |
| AR-03 | New-offer initial/terminal matrix and retry exact pending matrix. Reject unconfirmed, unknown/missing, wrong target and settlement-capable mutation. CLI missing pending journal or changed fresh status leaves explicit retry failure and usable status, never automatic re-offer. |
| AR-04 | Continuing sanction/revoked key, stale authority, withdrawn generation and offer rejection stay unpaid after attempted new offer. Read alone sends no offer. Positive app fixtures are labeled fixtures and do not qualify real coordinator or physical execution. |

Use injected trust/file/launcher seams for deterministic negatives, plus a bounded
macOS child-launch test for suspend/identity/resume behavior. Production identity
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
