# Build 1 transaction control and admission recovery addendum — revision 1

Status: DRAFT FOR INDEPENDENT PLAN REVIEW. Author-only artifact; implementation
is prohibited until the lead records approval of this exact file digest.
Applies to the Build 1 combined working diff based on prerequisite
`f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`, alongside plan-r4.md and
test-spec-r4.md. This narrowly corrects two architecture findings; it neither
qualifies the physical journey nor changes coordinator admission authority.

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
System helpers where required, associated views/localization and Xcode tests.
No CLI wire format, journal schema, coordinator transition or dependency changes
are proposed. Before implementation the lead checks SPEC-001 §6.14a and SPEC-044
for any necessary normative clarification and reopens this plan if the proposal
requires a new contract rather than implementing existing recovery requirements.

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
command target, signed model key, transaction kind, start time, timeout and cancel
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

Add a dedicated typed control API, separate from general live-peer `run`:
operation enum `status`, `cancel`, `result`; persisted pending authorization;
fixed ProviderPaths; scoped output callback. No caller-supplied argv, executable,
config, journal root, environment or model overrides.

The API constructs only:

- `models transaction status UUID --model TARGET --json --config FIXED_CONFIG`
- `models transaction cancel UUID --model TARGET --json --config FIXED_CONFIG`
- `models transaction result UUID --model TARGET --json --config FIXED_CONFIG`

Status/cancel require exact persisted UUID/target/model-key/kind. Result additionally
requires evaluate_model and the matching successful evaluation terminal. Cleanup
uses the original UUID with cleanup_staging kind; its transcript stays separate
from the original operation. No cleanup start/retry, prepare, evaluation, adoption,
offer or arbitrary read command is available through this API. Result retrieval
without a persisted pending authorization continues through the normal fresh
live-peer path, such as a new projection's available adoption action.

Before every control, load the persisted authorization and compare the caller's
exact binding. Independently resolve the executable using the existing trusted
configured-provider resolver, compare its canonical identity with the pin, and
repeat owner-private checks and strict code signature validation. Require the
same CDHash, signing identifier/team and app-compatible captured capability
contract. App contract or binary upgrades do not inherit the old authorization.
Do not use launchctl live-job/PID availability, bundled/PATH/DEBUG overrides or
an arbitrary saved executable path on this recovery path. The captured capability
proof is useful only because the exact code identity remains pinned; it is not a
cached positive health, readiness or admission decision.

Close replacement between executable validation and execution for this narrowly
scoped helper: use a suspended launch (`posix_spawn` with
`POSIX_SPAWN_START_SUSPENDED`), inspect the created helper's code identity against
the frozen pin, recheck fixed config identity, then resume only the matching
helper. This platform flag exists in the macOS SDK used by this project. A failed
verification terminates/reaps only that never-resumed control helper. It must not
signal the transaction owner, incumbent or model runner. Do not broaden or rewrite
the general process runner for this change; isolate/test this control launch seam.
Known mismatches fail before spawn; a replacement race fails before helper code
runs. If this cannot be implemented reliably with the deployment target, return
to independent plan review rather than weakening the check.

Run with the existing sanitized environment and no extra model-root/config
injection. Keep the existing ten-second bounded control wait and scoped callbacks;
late output cannot change another UUID/kind or create success. Persist cancel
intent before dispatch; duplicate status/cancel remain CLI journal operations.
A timeout is uncertain and recoverable, not cancellation completion. No terminal
owner event is fabricated from helper exit, timeout, missing PID or app restart.

Cold restart loads only the safe pending file and can issue status/cancel without
a live incumbent. Successful cancellation/result parsing retains the existing
closed event schema and signed target checks. A published commit winner remains
succeeded with the too-late disclosure. Terminal success still requires a fresh
validated projection and fresh restored peer evidence before clearing pending or
showing readiness/success; a pinned binary never substitutes for either. Result
is complete recommendation evidence for the existing adoption validator and does
not display economic claims on local-only rows.

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
| TC-07 | Ten-second timeout, duplicate cancellation, delayed output, app restart and cleanup reuse of original UUID retain UUID+kind scoping. Status/cancel replay deduplicates exact sequence; cleanup retry may begin above sequence one. No kill-based cancellation or synthetic terminal. |
| TC-08 | Terminal succeeded with missing/stale/invalid projection or unavailable restored peer retains pending/recovery UI. Fresh matching projection unlocks success. Postcommit cancellation discloses too late. Complete result still passes existing signed key/canonical ID adoption checks. |
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
