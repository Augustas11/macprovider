# Build 1 Malibu app implementation evidence

Status: implementation complete; full combined code/security/architecture review
remains the lead's gate. This report contains deterministic app-test evidence,
not hardware, live admission, settlement, or release qualification.

Date: 2026-09-10. Implementation base: prerequisite `f5edeaeb` (PR #1468).
Owner scope: `phase3-binary/app/`; this report was separately authorized by the
lead. No CLI, coordinator, gateway, spec, dependency, or secret changes were made
by this lane.

## Result

Malibu negotiates `model_catalog_transactions_v1`,
`model_catalog_local_activation_v1`, and the existing adoption capability before
requesting `models catalog-economics --local-activation --json`. Only that
negotiation accepts projection protocol `2`; protocol `1` and legacy advisory
recommendations preserve their conservative behavior.

Authenticated non-economic preparation, measured prepared-only evaluation, and
transaction-owned cleanup use exact typed targets, transaction IDs, and immutable
operation generations. Cleanup recovery entries occupy a separate section and
never become catalog rows or admission authority.
Confirmation names the target, signed catalog trust source for preparation,
known size or explicit unavailable size, and local implications. Cleanup instead
names CLI-owned staging and does not claim currently available feed authority.
App code never downloads, deletes staging, or kills a mutation process.

The closed JSONL reader checks UUID, kind, signed model key, schema, field types,
progress shape, and monotonic sequence. Exact repeated events are deduplicated;
conflicting replay and foreign targets fail closed. Private atomically persisted UUID/key/target/kind/generation and executable/config
authorization support restart recovery. Cancellation goes through the independent
CLI control invocation. A 30-second progress gap produces delayed-response copy,
while cancellation remains visible. CLI-owned deadlines remain authoritative;
the app requests cancellation at the advertised deadline. Read-only projection,
status, and recommendation-result waits are bounded to 10 seconds without
terminating an active mutation. A successful operation requires terminal truth
and a newer accepted projection; timeout/failure preserves pending recovery.
Cancellation after commit is disclosed. A cancelled/failed transaction can
reconcile even when its target no longer appears in the fresh catalog.

A successful evaluation retrieves the complete `autotune_recommend.v1` through
`models transaction result`. Local validation binds the signed catalog key in
`recommended_model` and `serve_config.model` to the canonical model ID in
`serve_config.model_catalog_model_id`. No recommendation bytes are rewritten.
The legacy `isActionable` remains false; a separately negotiated local eligibility
path requires measured/ready evidence, safe configuration, fresh typed adoption
availability, and matching evaluation UUID. Fresh authenticated fallback warnings
may remain eligible; stale, integrity, and safety warnings do not. After restart,
the typed adoption action can restore the original result by evaluation UUID.
Explicit activation passes the unchanged document through stdin to the existing
CLI lock/journal/runtime adoption protocol and reconciles its catalog-key runtime
identity. Rate/demand/ranking copy from this result is suppressed.

Activated rows expose provider-signed offer, admission status, and confirmed
qualification retry through existing CLI custody. Local readiness, coordinator
admission, catalog pricing, settlement eligibility, and settled credit are
separate UI statements. A settlement-eligibility label requires fresh trusted
projection authority and still discloses the request/receipt/settlement gate.
The app never claims that submitting an offer or completing a local operation
has settled credit.

## Changed files

- `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift`:
  capability negotiation, v2 row validation, typed transactions, recovery,
  bounded reads, exact local recommendation binding, and signed admission UI
  command dispatch.
- `phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift`:
  private pending/snapshot persistence, strict production signing identity, config
  identity expectation, typed controls, inherited flock/lifetime descriptors, and
  bounded subprocess output/deadline/reaping.
- `phase3-binary/app/Sources/Malibu/System/InstalledProviderMonitor.swift`:
  reuse the existing safe directory ACL predicate for private parent validation.
- `phase3-binary/app/Sources/Malibu/ModelManagement/RecommendationManagement.swift`:
  opt-in local key/canonical-ID validation and local eligibility; legacy advisory
  behavior retained.
- `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift`:
  confirmation, progress/cancellation/status controls, local activation,
  admission offer/status/retry, and economic-claim suppression.
- `phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json`:
  two negotiated feature tiers.
- `phase3-binary/app/Sources/Malibu/Resources/MalibuFeature.xcstrings`:
  English localization entries for new controls, states, and confirmations.
- `phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift`:
  15 additional tests, including a labeled deterministic app/CLI composition
  fixture and transport/recovery negatives.

## Verification

Toolchain: Xcode 26.6, build `17F113`, native macOS destination.

Final command from the task worktree root:

```sh
xcodebuild -project phase3-binary/app/Malibu.xcodeproj \
  -scheme Malibu -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Final result: **exit 0; 617 tests, 0 failures**, including **111
ModelManagementTests, 0 failures**. Final full suite completed at
`2026-09-10 14:06:07 +0800`. Local log:
`/tmp/build1-app-full-xcode.log`. Xcode result bundle basename:
`Test-Malibu-2026.09.10_14-05-29-+0800.xcresult`.

Iteration evidence: initial unchanged 96-test ModelManagement baseline passed;
expanded 109-test selected suite passed; an earlier 615-test full suite passed.
Adding the cancelled-target-disappears regression exposed one failure in a
617-test run: restart reconciliation omitted the fresh incumbent model display.
The pending-transaction refresh now records that fresh peer observation before
reconciliation. The final 617-test full rerun above passed after the fix. Earlier
failed runs are not counted as successful evidence.

`git diff --check -- phase3-binary/app` passed. Both changed resource JSON files
parsed successfully with `python3 -m json.tool`.

The new tests cover negotiation/version fallback, null economic/demand fields,
explicit confirmation including known/unknown size, command arguments, malformed
and mismatched events, conflicting/nonmonotonic replay, delayed response,
CLI-owned cancellation, restart and too-late cancellation, terminal-plus-fresh
projection, read timeout and late recovery, missing target after cancellation,
scoped cleanup, signed key/canonical target binding, fallback-versus-stale/safety
warnings, result restoration, unchanged stdin adoption, and offer/status/retry
composition. Existing legacy tests remained enabled.

## Remaining qualification gaps

- The app fixtures do not execute actual CLI downloads, MLX benchmarks,
  production credentials, coordinator admission, requests, receipts, or ledger
  settlement. They do not prove B1-T10 physical acceptance or replace CLI,
  coordinator, gateway, and actual SQLite integration evidence (approved storage addendum).
- Preparation and the measured-evaluate/adopt/offer chain are covered by separate
  deterministic app fixtures; a real no-cache/no-admission end-to-end journey
  remains the lead's integration/hardware gate.
- Xcode 26.6 evidence does not replace required Xcode 16.4 release qualification;
  code signing, notarization, packaged binary identity, and updater paths were
  not exercised.
- Localized copy and accessibility controls/hints were implemented; manual
  VoiceOver and visual acceptance were not performed by this lane.
- The combined independent code/security/architecture audit and any resulting
  fixes remain pending under the lead. No approval is implied by this report.

## Transaction control r4 and cleanup recovery r3

The app slice implements the independently approved control addendum r4 and
separate cleanup recovery r3. Available local actions and every event require a
canonical operation generation; protocol 1 rejects the new fields. A cleanup
attempt uses its recovery entry's exact UUID, target, key, kind, and generation.
Unknown recovery fields, conflicting entries, malformed generations, and available
row cleanup actions fail closed.

New owners require a fresh authenticated live provider. Before launch, the app
captures the signing identity/CDHash, version/capabilities, manifest digest,
config identity/hash, and opaque CLI context digest; publishes a private verified
snapshot; and atomically saves the pin with pending metadata. Status, cancellation,
and result controls recover this exact binding without a live incumbent. They
revalidate the configured source, snapshot signature, capability contract, config,
and saved operation. Missing or changed authorization remains blocked. The app
never executes a path selected by pending metadata.

The helper launches normally using posix_spawn. Context JSON uses read-only FD
198, the inherited exclusive control.lock file description FD 199, and the parent
lifetime read pipe FD 200. Source descriptors are CLOEXEC duplicates at or above
210; child dup2 actions publish only the destination descriptors. Control lock
location is ~/Library/Application Support/Malibu/ModelTransactions/control.lock,
owned 0600 in the owned 0700 directory. Last close releases the lease; the app
never explicitly unlocks a live child's inherited file description.

Private context JSON uses schema model_transaction_context_expectation.v1 and
transaction_context_sha256, config_path, config_device, config_inode, config_size,
config_sha256, uid, home_directory. The source projection carries only the opaque
digest. No raw private paths are rendered or added to projection fields.

Controls are limited to one concurrent helper across app instances and a
10-second deadline. stdout is bounded to 8 MiB, stderr to 64 KiB, a JSONL line to
64 KiB, and delivered lines to 8192. Timeout/overflow terminates and reaps only
the directly spawned control helper; mutation owners are never signaled. A
retained output pipe cannot extend the deadline after the helper exits. UI
cancellation queues behind an in-flight control and retains the exact binding.
CLI early parent/deadline protection and consumed-config validation belong to
the root's CLI context implementation and its independent evidence.

Admission readback remains available in recognized terminal states. Initial and
terminal states permit a fresh explicitly confirmed offer; qualification retry
is restricted to pending states and still depends on the CLI journal. Readback
failure does not permanently disable subsequent status refresh.

The app's production-signed snapshot positive remains unqualified: the lead's
read-only `security find-identity -v -p codesigning` reported **0 valid identities**.
No matching production-signed new CLI can be produced locally from that state.
Unsigned real-process tests and fixture pins do not substitute for this evidence.
TC-01 publication crash injection, TC-06 signed snapshot/resource execution, and
TC-10 GUI-crash/early CLI guardian composition are not established by the app
fixtures; CLI guardian and integration evidence must be assessed separately by
the lead. The earlier hardware/release/VoiceOver qualification gaps still apply.

Final post-addendum verification (2026-09-10):

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Result: **TEST SUCCEEDED — 625 tests, 0 failures**, 34.070 seconds reported
suite duration. Full log: `/tmp/build1-app-r4-full-final.log`. This run includes
the final live PID signature check, private snapshot cleanup, SIGPIPE-safe
context write, and retained-output-pipe deadline regression. The focused r4
ModelManagement suite previously passed 118 tests; the final full suite includes
119 ModelManagement tests. The earlier full r4 run passed 624 tests before that
last regression was added. These are Xcode macOS app tests, not SwiftPM substitutes.
Both resource JSON documents parse; `git diff --check -- phase3-binary/app` passes.
The generated ignored Xcode project includes the new source; tracked project.yml
already includes Sources/Malibu recursively, so regeneration retains it.

## Resource snapshot correction (approved snapshot-resources-r2)

The earlier binary-only snapshot had a deterministic MLX resource omission. It
was not merely a missing signed/hardware qualification. The approved r2 resource
correction now copies a complete fixed private payload: native CLI, adjacent
mlx.metallib, known MLX/NIO data bundles, and the named compatibility/catalog data
closure. Candidate execution continues using that frozen executable; no original
installation restart or environment lookup bypass was added.

Additional app files are ModelTransactionPayload.swift (closed inventory,
streaming copy, resource checks and deletion-only traversal) and
ModelTransactionRequest.swift (single retained worker, deadline/revocation and
completion ownership). ModelTransactionControl.swift now publishes/validates the
payload directory and pin version 2, transfers the existing lease to controls,
and retires intact payloads before removing pending metadata. Retired no-pending
payloads are reclaimed during bounded maintenance before a new capture. Version
1 pins remain blocked. Test fixtures use an explicitly injected native identity
only for low-level retirement tests; production CLI authorization always invokes
the strict native signing check.

Resource SHA-256 pins freeze the existing owner-private installed bytes; they do
not create signing provenance or feed authority. Native code identity and the
CLI's existing signed-envelope/catalog/adoption checks remain distinct. Active
payload execution/restoration requires complete exact inventory/hashes; partial
copies/retired orphans use a separate safe-subset deletion predicate only when
private pending is absent and fixed locks/root identities are checked.

The ten-second app control deadline includes off-main resource preflight. A
blocked filesystem/Security call retains one visible busy worker and its exact
leases; expiration rejects late dispatch and output rather than accumulating
workers or closing another thread's descriptors. Capture has a separate
30-second budget. Cancellation intent queues while validation is busy and is
persisted inside the control request before CLI dispatch. Long owners release
the validation lease after spawn and never inherit the short-control lifetime
or receive app termination signals. Uncertain pending publication is retained
for exact reconciliation; terminal-plus-fresh-projection still gates completion.

Focused command after the implementation and crash/recovery regressions:

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  test -only-testing:MalibuTests/ModelManagementTests \
  -only-testing:MalibuTests/ModelTransactionResourceTests
```

Passed **132 tests, 0 failures** (119 existing ModelManagement + 13 resource
checks). Log `/tmp/build1-app-resources-tests5.log`, SHA-256
`469e9407adc7822f8f256c9cff7d0b41aaac97978331282e411fe87a9545535c`.
Earlier compile/assertion failures were corrected and are not counted as passes.
Tests cover the named closure, ignored unrelated source siblings, copy mutation,
native/metadata injection, symlink/hardlink/sparse oversize, closed inventory,
interruption at every fixture copy member, safe partial disposal, pending/root
conflicts, intact-retirement recovery and rejection of partial restoration. A
real open resource read paused beyond ten seconds proves responsive timeout,
one retained busy worker/lease, no late authorization, and subsequent reclamation.

Actual resource execution evidence is now available, with explicit limits:

- The Xcode test compiles a tiny Metal kernel with installed xcrun metal/metallib,
  copies it through the production resource-custody helper and loads the copied
  library using Metal, resolving snapshot_resource_probe. Removing the copied
  library fails. This proves compiled resource loading, not model inference.
- The lead compiled a non-shipping helper against pinned mlx-swift commit
  dc43e62d7055353c7f99fa071a4e71d29dfddc44. The app test copies that helper and
  the real built library through production scan/copy/revalidation, then starts
  the copied helper through the bounded subprocess runner. Actual GPU arithmetic
  `[1,2,3] * 2 + 1` returns `[3,5,7]`. No model weights, network or operator
  credentials are used. Removing the copied library makes complete inventory
  validation fail. The lead separately ran the same binary in an empty cwd
  without its library and observed MLX library-not-found (exit 255).
- Helper `.omx/qualification/mlx/macprovider-cli` SHA-256:
  `940db2da318b6bfa9932b0f4985515b433b3968e4c64ccc20c5d2f9725c542c8`.
  Actual library `.omx/qualification/mlx/mlx.metallib` SHA-256:
  `90c9a8af18123b2f84c17e5e85d31e356e24df69dea5639c9e4aa439a4985274`.
  Root-owned compile commands, source and baseline/negative results are in
  `.omx/qualification/mlx/`; no qualification artifacts were added to product.

This supersedes the earlier resource-load gap, but it does **not** qualify an
actual production-signed CLI snapshot, a full prepared-model recommendation,
incumbent drain/restart, B1-T10 hardware journey or settled provider credit.
Zero valid signing identities still blocks producing a matching new signed CLI
locally. Exhaustive real process death at every fsync/kernel boundary, actual
signed payload layouts, and full combined audit remain independent gates; the
fault-injected app fixtures must not be presented as those qualifications.

Final full post-resource Xcode verification:

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

**TEST SUCCEEDED — 638 tests, 0 failures**, 44.816 seconds reported suite duration.
Log `/tmp/build1-app-resources-full.log`. This includes all 13 resource tests,
including the actual Metal/MLX tests with qualification artifacts present (no
resource qualification skip). Both app resource JSON documents parse, and app
`git diff --check` passes. No new concurrency/compiler warnings were observed in
these helpers; pre-existing app warnings remain. The generated ignored Xcode
project includes both new helpers; tracked project.yml already includes their
source directory recursively.

Final full log SHA-256: `9528c99383b5d8e0c01e0b084889b43564e1656dff7a96efc3b7dac80892809e`.

## App security review corrections — 2026-09-10

Resolved APP-SEC-M1 and APP-SEC-L1 from
`reviews/app-security-current-r1-astra.md` within the approved snapshot-resource
r2 durability/completeness contract. No CLI or normative contract changes.

- Pending clear now holds both fixed locks even for an absent-record retry and
  requires a successful pending-parent fsync before reporting completion. An
  extant exact pending record requires an intact active or retired payload;
  missing both fails closed. If unlink succeeds but its persistence barrier
  fails, the intact retired payload is retained and restoration of the exact
  pending record is attempted. Restoration failure never permits disposal.
- Orphan maintenance independently establishes durable pending absence under
  the same metadata/control locks before touching any payload member. Capture
  uses the already-locked entry point; completion uses the same production
  clear path without the former pathname-absence shortcut. The default client
  `finishCatalog` supplies that local custody operation. Existing state-machine
  fakes explicitly fake custody; resource tests exercise production clear.
- Every selected complete bundle requires one allowed `Info.plist` layout.
  Missing metadata remains admissible only to the separate disposal predicate.
  Both known bundles have flat/Contents positive and missing-metadata negative
  fixtures. The executable-metadata/native-code negative test retains valid
  metadata between assertions so missing metadata cannot mask its native check.

Three added resource tests inject the post-unlink/pre-parent-sync failure,
verify intact-retired/exact-pending recovery through a fresh load, model app
death at the unlink boundary, reject retry completion and independent orphan
maintenance while the barrier fails, then permit successful durable completion
and disposal. They also cover missing-both-payload rejection and bundle metadata
layouts. These are deterministic syscall-boundary fixtures, not a real storage
power-loss experiment or production-signed CLI qualification.

Targeted command:

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
  test -only-testing:MalibuTests/ModelManagementTests \
  -only-testing:MalibuTests/ModelTransactionResourceTests
```

**TEST SUCCEEDED — 135 tests, 0 failures** (119 state-machine + 16 resource),
19.229 seconds reported suite duration. Log
`/tmp/build1-app-security-fix-tests.log`. A subsequent test-only correction
restored valid bundle metadata between native-resource negative assertions;
the full run below validates that final source.

Frozen source canonical `hash  relative-path\n` manifest is
`/tmp/build1-app-security-fix-manifest.txt`, SHA-256
`12be3a3ad277944b795c0350ff80b83158c35bf6a37750e2adf37eb6f6964c1c`,
covering the same ten changed app files as the independent security report,
including all three untracked helper sources. Independent re-review is pending.

Final full command (same macOS Debug destination and signing flags):

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

**TEST SUCCEEDED — 641 tests, 0 failures**, 53.229 seconds reported suite
duration. Full log `/tmp/build1-app-security-fix-full.log` SHA-256
`e11aafa80db2fe094996d67e65136148d9d5d9db94b87f158ba6f94f95824375`. Targeted log SHA-256
`3976c217243517e9e6a44686509dbcccdf8eea5a811cd9ea2cd1a28d1191154a`. All 16 resource tests ran,
including actual copied Metal/MLX resource checks; no qualification skip.
App `git diff --check` passes. The earlier production-signed CLI, actual-model
journey and final combined-audit limitations remain unchanged. App source frozen.

## Catalog read lifecycle correction — verification in progress

Implements approved `catalog-read-lifecycle-addendum-r2.md` (SHA-256
`e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954`).
Earlier source-freeze statements above describe their dated slices; the catalog
read slice is not frozen until its cross-CLI argv fixture and final checks run.

The app requires explicit `model_catalog_read_lifecycle_v1` support together
with the existing local-activation tiers. Same-version peers without that
capability, older peers, partial support and stale evidence do not spawn a
catalog/list/browse/result fallback. The UI shows update/repair or fresh-status
guidance and preserves pending transaction recovery. Protocol-1 standalone
compatibility remains a CLI responsibility.

`ModelCatalogRead.swift` owns a separate request reservation, worker, fixed read
lock and direct child PID through observed exit/reaping. Deadlines include
executable preflight; abandoned preflight cannot spawn later. Timeout/cancellation
revokes the request, closes its lifetime writer, sends TERM only to its owned
reader, then KILL after one second if necessary. The slot and lock survive the
UI timeout until reclamation. Mutation owners and short transaction-control
workers are separate. The app forwards fixed read-lock/lifetime FDs 199/200.

Actual refresh arguments omit the incompatible socket override and use quick
mode. Existing local files show an explicit Verify local files action, never a
false missing-files/prepare shortcut. Target verification has a 1,800-second
request budget, a ten-second first-event limit, a 15-second event-stall limit,
and a 60-second byte-stall limit after observed byte advancement. The CLI owns
its independent hashing-start and nonhash-phase limits. The app displays
measured bytes and delayed progress, and offers Stop verification. A closed
JSONL parser requires exact request/target/key, monotonic sequence/bytes, complete
validated target projection, EOF and zero exit before readiness. Output limits
are 8 MiB total stdout, 64 KiB stderr and 1 MiB per verify event, at most 4,096
events. Recommendation evidence is passed unchanged to the existing validator.

A successful prepare/evaluate terminal is followed by quick context projection
and one explicit target verification; that completed fresh verified projection
is the reconciliation gate. Incomplete reads preserve pending custody and clear
unavailable catalog/recovery views. Cancelled/failed/cleanup terminals use quick
projection. Local verification adds no admission, pricing or settlement claim.

Current Xcode command:

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

First full run: **652 tests, 0 failures, 1 skipped**, reported suite duration
86.910 seconds. Log `/tmp/build1-app-read-full1.log`, SHA-256
`bf88429f53e729912e1ccf4ea6ee5716a45e9ad511ca4a3f19018aa437234609`.
The skipped test is the required app-to-real-CLI argv bridge, waiting for its
isolated signed input fixture; this is not completion of CR-01 or the full gate.
Two subsequent defensive FD/PID failure-path fixes still require the final run.

Real compiled macOS helper fixtures prove the default ten-second quick timeout,
late-output rejection, TERM-ignoring child KILL/reaping with retained slot/lock,
preflight abandonment with no late spawn, and a single verification lasting over
20 seconds with byte progress. Malformed/truncated/repeated/wrong-request,
nonzero-after-completed, trailing and oversized output fail closed. Clock-policy
fixtures cover accepted/heartbeat/byte-stall boundaries. These helper fixtures
exercise app process ownership and codec behavior; they do not claim real model
hash throughput, inference, production signing, or full hardware qualification.

The CR-01 Xcode test drives the real store caller through the production owned
runner and records arrays at `onSpawn`, into ignored
`.omx/qualification/catalog-read/app-argv.json`. It consumes actual producer
JSON and context from the CLI lane's persistent `input.json` without rewriting
identity or freshness evidence. The CLI lane consumes those unchanged argv
arrays with real ArgumentParser and genuine fixture descriptors. Final artifact
hashes and zero-skip results are recorded below; remaining cross-lane
qualification stays with its respective owners.

## Catalog read app caller capture and final Xcode verification

Completed 2026-09-10 using Xcode 26.6 build 17F113 on the native arm64 macOS
destination. The signed CLI producer input already existed and was consumed by
the actual app store caller. No app compatibility defect appeared, so this lane
made no further app source change.

The focused capture command was:

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test \
  -only-testing:MalibuTests/ModelManagementTests/testActualCatalogCallerCapturesSpawnArgumentsForCLIParserBridge
```

Result: **TEST SUCCEEDED — 1 test, 0 failures, 0 skipped**. The XCTest result
summary independently reports one passed test and zero failed, skipped, or
expected-failure tests. Result bundle:
`Test-Malibu-2026.09.10_19-15-40-+0800.xcresult`. Retained log:
`.omx/artifacts/build1-catalog-app-capture-sol.log`, SHA-256
`61b0965e32cca90f67a5d812c606f26d251fb224cd77cf1a7d4fef1f97c09d1b`.

The complete app command was:

```bash
xcodebuild -project phase3-binary/app/Malibu.xcodeproj -scheme Malibu \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO test
```

Result: **TEST SUCCEEDED — 652 tests, 0 failures, 0 skipped**, 82.380 seconds
reported suite duration. The result bundle summary independently reports 652
passed tests and zero failed, skipped, or expected-failure tests. This includes
130 `ModelManagementTests` and all 16 `ModelTransactionResourceTests`; the
actual copied Metal/MLX resource checks ran. Result bundle:
`Test-Malibu-2026.09.10_19-16-22-+0800.xcresult`. Retained log:
`.omx/artifacts/build1-app-full-sol.log`, SHA-256
`116168ae85046565aa290fbb232bfc971fc93b18bd13d01e63d108e7269c28d4`.

The full suite reran the caller capture and left the final replay handoff. The
input and output SHA-256 values are:

```text
30d2efbb6d1dddeb257d13a4406880e29a01f8b653f67422b3acb6feabc96d94  .omx/qualification/catalog-read/input.json
3bfb0747977954ae1ef6c3b71f083fc8f80155919faf059eb9c6a1ee6a19d3f1  .omx/qualification/catalog-read/app-argv.json
```

The final `app-argv.json` has schema
`malibu_catalog_read_argv_fixture.v1`, contains the actual `quick`, `verify`,
and `result` arrays (14, 18, and 23 arguments), and contains no
`--ctl-socket-path`. Its config path, target model ID, model key, context digest,
transaction ID, and operation generation match `input.json` exactly. The
machine-readable verification record is
`.omx/qualification/catalog-read/app-capture-verification.json`.

This completes the app capture and zero-skip Xcode lane only. The CLI replay,
combined independent audits, hardware journey, production signature, release,
admission, request/receipt, settlement, and Build 1 approval gates remain with
their respective owners.
