# Build 1 lead validation

## Gateway regression surface

Command: `cd phase5-gateway && go test ./...`
Fresh exit 0 on 2026-09-10. Nine packages reported passing tests; storage interface package reported no test files and is not counted as a passing test package. This is local Go evidence; not physical MLX or deployed acceptance.

```text
ok  	github.com/augstar/macprovider-gateway/cmd/gateway	3.574s
ok  	github.com/augstar/macprovider-gateway/cmd/relay-blind-client	1.318s
ok  	github.com/augstar/macprovider-gateway/internal/auth	0.694s
ok  	github.com/augstar/macprovider-gateway/internal/config	3.260s
ok  	github.com/augstar/macprovider-gateway/internal/relayblind	2.677s
ok  	github.com/augstar/macprovider-gateway/internal/router	40.896s
ok  	github.com/augstar/macprovider-gateway/internal/settlement/journal	0.662s
ok  	github.com/augstar/macprovider-gateway/internal/spec015contract	1.006s
?   	github.com/augstar/macprovider-gateway/internal/storage	[no test files]
ok  	github.com/augstar/macprovider-gateway/internal/storage/sqlite	5.491s
```

## Governance and static analysis

`python3 scripts/check_spec_governance.py --base-ref 914f7cafcdbcfc1805a10f4f34167218341d5587`: fresh exit 0, `SPEC governance validation passed`.

`cd phase5-gateway && go vet ./...`: fresh exit 0, no diagnostics.

## Artifact feed and legacy contracts

`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest -v scripts.tests.test_catalog_artifact_feed scripts.tests.test_byom_contract_lock`: fresh exit 0; 145 tests in 9.816s, OK. Covers shared artifact corpus, signature/release binding, generator validation, rate parity, and six legacy BYOM locks. Fixture generation is not publication or operator signing. Raw log SHA256: `1266a846680a684cbd5982039f10a7e74d25949a4355dbb8348daeee0c8e5cad`.

## Linter prerequisite

The declared `golangci-lint` tool was absent from PATH. Installed the existing Makefile-pinned v2.12.2 in an external local tool cache via `GOBIN=/Users/augstar/.cache/codex-tools/macprovider go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.12.2`, exit 0. No project dependency manifest or lock update is intended. Lint execution remains pending source freeze.

Initial coordinator lint exited0 with `0 issues` but warned that cached diagnostic paths referenced a removed unrelated worktree, so it is not treated as a clean lint gate. A fresh run with task-specific GOLANGCI_LINT_CACHE and GOCACHE is pending.

Fresh isolated coordinator lint: `GOLANGCI_LINT_CACHE=/Users/augstar/.cache/codex-tools/macprovider/build1-lint-cache GOCACHE=/Users/augstar/.cache/codex-tools/macprovider/build1-go-cache /Users/augstar/.cache/codex-tools/macprovider/golangci-lint run --config=.golangci.yml ./...` exited0. Output:

```text
0 issues.
```

## Full coordinator suite

`cd phase4-coordinator && go test ./...`: fresh exit0, 44 packages with passing tests (packages with no test files excluded). This run preceded only the subsequent test-only limiter determinism correction.

Full affected race run failed an existing wall-clock admin burst assertion; isolated reproduction also failed because requests took about75 seconds and limiter legitimately refilled. Changed authority/receipt/rate/recovery race tests passed separately. Lead changed only TestAdminRateLimitBucketConsumesFailures to use the existing injectable limiter clock, assert exact exhaustion at the actual128-token capacity, then explicitly advance1second and verify refill. No runtime limiter or economic activation changed. `go test -race ./internal/billing -run ^TestAdminRateLimitBucketConsumesFailures$ -count=1` exited0 after correction; full billing race rerun pending.

Full billing race rerun after test-only clock correction: `go test -race ./internal/billing -count=1` exited0, package passed95.141s. This closes the reproduced timing failure without modifying production rate limiting. Prior failed runs remain recorded.

After the test-only clock correction, `go vet ./...` (entire coordinator) exited0 with no diagnostics; the same isolated-cache full coordinator golangci-lint command exited0 with `0 issues.` These checks include the new test source.

### Correction integration checkpoint

After approved controlr4/retentionr4/cleanupr3/commandcompositionr3/longhashr3 gates, root normative amendments are present. Fresh `python3 scripts/check_spec_governance.py --base-ref 914f7cafcdbcfc1805a10f4f34167218341d5587` exited0 with SPEC governance validation passed. Root edited Swift files pass frontend syntax parsing only; this is not typechecking or test evidence.

Root added secure consumed-config/context loader, exact private IPC expectation, bounded control lease, protocol2 generation/recovery/context encoding, and two-phase projection orchestration. Runtime source is being integrated with CLI generation and retention types before a coordinated compile. Existing adoption XCTest trust bypass removed; signedfixture migration first48-test run had1remaining failure (2assertions); do not count that run as passed. Root found and removed a separate incorrect catalog-key/canonical-ID parity comparison, preserving full exact recommendation identity checks. Final fixture diagnosis and fresh rerun pending.

## Continued shared validation

- Fresh `git fetch origin --prune` completed; origin/main remains `914f7cafcdbcfc1805a10f4f34167218341d5587`. No unrelated worktree was modified.
- Swift15: `swift test --filter 'ModelTransactionContextTests|ModelsSubcommandTests|Build1CommandBootstrapTests'`, exit 1, compile failed on duplicate local `snapshot` in preparation seal code. No tests ran; no passing acceptance evidence. Owner renamed the seal snapshot before retry. Log: `/tmp/build1-joint-swift15.log`.
- App owner reports final full Xcode suite: 625 tests, zero failures; 119 ModelManagement tests. Exact command and source evidence in `implementation-app.md`; log `/tmp/build1-app-r4-full-final.log`. This does not establish production-signed snapshot execution, GUI-crash guardian behavior, or physical MLX acceptance.

- Swift16: same filter as Swift15, exit 1 after successful compile. 55 tests, 10 failures (5 unexpected): context 5 unexpected failures at supplied config-path equality; bootstrap 3 assertions on unavailable preparation; adoption 2 assertions despite complete config parity. Exact log `/tmp/build1-joint-swift16.log`. The secondary Swift Testing zero-selected result is not evidence.
- Follow-up diagnosis: canonical Darwin aliases differed from supplied fixture config paths. Context comparisons now normalize only the existing lexical system aliases; arbitrary symlink paths remain rejected. Adoption journal removal compared URL objects whose directory hints differed. A fresh Foundation reproduction yielded URL equality false but standardized parent-path equality true. Removal now compares standardized paths; two direct positive/foreign-parent regression tests were added. These fixes still await fresh execution.
- Retention locking concern reopened the plan gate: current whole-pass maintenance reads bounded but potentially large sidecar histories under the global lock, which can delay persisted owner heartbeats. No retention-lock-budget correction is authorized until an independent revised-plan gate passes.

- Swift17: expanded targeted command selected ModelTransactionContextTests, ModelsSubcommandTests, RecommendationAdoptionJournalPathTests, Build1CommandBootstrapTests, ModelTransactionControlLeaseTests, ModelCatalogTransactionsTests, ModelCatalogArtifactSealTests, DurableModelArtifactStoreTests, ModelCatalogTransactionRetentionTests. Exit 1: 117 tests, 11 failures (8 unexpected), 124.124s. Log `/tmp/build1-joint-swift17.log`. Fresh passing suites: adoption46, journal-path2, durable-artifact11, seal4, retention16 (39.808s), lease6 (22.939s; includes subprocess entry), with coverage boundaries in owner reports. Failures: bootstrap3 assertions, context5 unexpected, owner3 unexpected busy responses.
- Corrected diagnosis: context failure line180 is HOME equality, not supplied config-path equality. The prior supplied-path normalization was compatible but insufficient. HOME now normalizes the same lexical Darwin aliases before comparing to kernel/test home; arbitrary path changes still reject. Adoption and its foreign-parent regression both pass after the parent-path fix. Owner positive polling must boundedly retry the newly typed busy result without relaxing the deadline or negative contention assertions.

- Swift18 exact command: `swift test --filter 'ModelTransactionContextTests|Build1CommandBootstrapTests|ModelCatalogTransactionsTests' > /tmp/build1-joint-swift18.log 2>&1`, phase3-binary, exit1. 32 tests,2 failures(1 unexpected),70.734s. Owner23/23passed63.963s. Context now6/7passed with one test URL-object alias assertion; changed assertion to compare resolved filesystem locations. Bootstrap passed preparation, fresh-process discovery, actual fixture measurement and original-byte readback before a too-long UNIX socket path. Test root shortened under private `/private/tmp` with0700; no runtime control-socket limits changed. Complete bootstrap/settlement is still unproven.
- Read-only app resource feasibility found a deterministic omission: snapshot copied only CLI executable, while CandidateProviderRunner re-executes that snapshot and MLX resolves adjacent resources. This is an implementation blocker requiring a new adversarial plan gate, not merely missing hardware/signing qualification. App owner is drafting snapshot-resource custody and test contracts before code.

- Swift19 exact command: `swift test --filter 'ModelTransactionContextTests|Build1CommandBootstrapTests|ModelCatalogTransactionsTests.testOwnerHashCopyDiskTimeoutAndCleanupFailures' > /tmp/build1-joint-swift19.log 2>&1`, exit1,10tests2failures(1 unexpected),8.634s. Nine-case owner failure-composition method passed. Bootstrap completed original-byte adoption, then protected-file fixture custody rejected world-writable/symlinked `/tmp` ancestry before service startup; its generic legacy error name is keychainReadFailed, but this was protected-file validation, not a Keychain access. Short fixture root will return to secure system user-temp ancestry. Context's sole remaining assertion compared differing directory hints; expected filesystem identity now compares resolved paths, not URL objects. No runtime custody relaxation or completed service-journey claim.

- Fresh SPEC governance after retention-lock-budget normative amendment: `python3 scripts/check_spec_governance.py --base-ref 914f7cafcdbcfc1805a10f4f34167218341d5587`, exit0, SPEC governance validation passed.
- Broader integration attempt: `go test ./... -race -count=1 > /tmp/build1-integration-full-race.log 2>&1` in test/integration, exit1; root package44.740s. Root incorrectly treated this as independent of Swift source changes. Existing relay fixtures implicitly build SwiftCLI; they failed to compile partially edited retention seams (`indexCompletedEvaluation`, `primaryRecordLocked`). This overlapping-source run is failed and does not establish a behavioral regression or acceptance pass. Full integration must rerun only during coordinated Swift source freeze. Standalone companion TestBuild1CLIServiceBridge also requires parsed-Swift fixture manifest; a no-manifest skip never substitutes for composed acceptance. No test command remains running from this attempt.

## Pinned MLX resource preparation

Fresh `xcrun --find metal` and `xcrun --find metallib` located installed Metal toolchain. Existing script command `bash phase3-binary/scripts/build-mlx-metallib.sh .omx/qualification/mlx > /tmp/build1-mlx-metallib-build.log 2>&1` exited0. It compiled the checked-out pinned mlx-swift revisiondc43e62d7055353c7f99fa071a4e71d29dfddc44. Output `.omx/qualification/mlx/mlx.metallib` is130926469bytes, SHA25690c9a8af18123b2f84c17e5e85d31e356e24df69dea5639c9e4aa439a4985274. This is resource compilation evidence only; no Metal load, actual MLX expression, real-model inference, production signing or settlement qualification is implied. Output stays outside tracked sources; no library was installed or deployed.

- Swift20 exact command: `swift test --filter 'ModelTransactionContextTests|Build1CommandBootstrapTests|ModelCatalogTransactionsTests|ModelCatalogTransactionRetentionTests|ModelTransactionOwnerLifetimeGuardTests|ModelTransactionControlLeaseTests|ModelCatalogArtifactSealTests' > /tmp/build1-joint-swift20.log 2>&1`, phase3-binary, exit1. Compile38.22s;63tests3failures(2unexpected),250.325s. Context7/0passed; seal4/0; controllease6/0 in23.211s; ownerguard4/0 in44.072s (helper entry methods are not independent behavior evidence). Retention16/1 at full-capacity scheduling; owner23/1 from unsafe-classified read during concurrent replacement; bootstrap3methods/1 failure at HTTP fixture URL before offer. Log interleaves buffered stdout/stderr; incomplete tail observed while active was NOT evidence of watchdog process death. Final summary and suite completion are present.
- Bootstrap service fixture correction uses existing explicit client context to map exactly one logical HTTPS loopback origin to the actual isolated HTTP loopback service. Production URL policy is unchanged; this fixture proves no TLS qualification. Retention and read-race corrections are pending. Actual owner-watchdog integration tests currently complement primitive guard tests; expanded actual evaluation/cleanup and independent retention-contender scenarios remain pending.

## Actual pinned MLX resource probe

Root compiled an isolated Swift helper from the existing pinned MLX objects (mlx-swift dc43e62d7055353c7f99fa071a4e71d29dfddc44), without a new production target or dependency. Source, exact compiler argv, logs and result JSON are in `.omx/qualification/mlx/`. It selects GPU and evaluates MLXArray([1,2,3])*2+1, asserting [3,5,7]. Helper SHA256: `940db2da318b6bfa9932b0f4985515b433b3968e4c64ccc20c5d2f9725c542c8`.

Fresh actual execution on this M5 Mac, empty working directory, minimal environment, 30-second process deadline:
- Adjacent compiled mlx.metallib: exit 0, 1.692 seconds, `MLX_GPU_PROBE_OK values=[3.0, 5.0, 7.0]`.
- Identical helper bytes without adjacent resource: exit 255, 0.972 seconds, MLX failed to load default metallib/library not found.

Compiler exited 0 with a deprecated setDefault API warning. No timeouts. This is actual pinned MLX GPU arithmetic and a resource omission negative, not model inference, signed production CLI qualification, app payload capture acceptance, admission, or settlement. App lane must run its production capture path separately.

## Swift21 and current governance

Integration-owned `swift test --filter Build1CommandBootstrapTests`: build 31.21 seconds, selected suite 3 methods / 1 unexpected failure in 31.279 seconds, exit 1. Two helper entry methods are noops. The real journey reaches parsed preparation, measured recommendation, adoption and signed offer/status; Go fixture provider fails to reach ready in /poolz. Log `/tmp/build1-bootstrap-swift21.log`; integration lane investigates. This is not a passed bootstrap journey.

Fresh `python3 scripts/check_spec_governance.py --base-ref 914f7cafcdbcfc1805a10f4f34167218341d5587` after snapshot resource normative amendment: exit 0, SPEC governance validation passed. `git diff --check`: exit 0. Further edits require final checks again.

Probe source (isolated qualification helper, not a production entry point):

```swift
import MLX
Device.setDefault(device: .gpu)
let input = MLXArray([Float(1), Float(2), Float(3)])
let values = (input * 2 + 1).asArray(Float.self)
precondition(values == [3, 5, 7])
print("MLX_GPU_PROBE_OK values=\(values)")
```

Compiler argv and exact execution results are preserved in `mlx-resource-probe-evidence.json`; this contains public local paths and no credentials.

## Swift22 interrupted harness wait

Command: `swift test --filter 'CandidateProviderRunnerTests|ModelCatalogTransactionsTests|ModelCatalogTransactionRetentionTests|ModelTransactionContextTests|Build1CommandBootstrapTests|ModelTransactionOwnerLifetimeGuardTests|ModelTransactionControlLeaseTests|ModelCatalogArtifactSealTests'`. Build completed35.13s. The XCTest process remained stuck more than4minutes; no completed selected-suite evidence was emitted. Root sampled the owned process for1second: `Build1CommandBootstrapTests.testParsedPrepareRestartDiscoverRecommendReadbackAndOriginalAdoption` line129 (offer) → `runCommand` line229 → Foundation `waitUntilExit`. That unconditional final wait bypassed the fixture45-second polling deadline.

Root verified XCTest PID88634 had parent swift-test88302 and zero child processes, sent SIGTERM only to that owned XCTest, and the command exited1. This run is interrupted and proves no owner/retention acceptance. Sample `/tmp/build1-swift22-sample.txt`; compiler/test log `/tmp/build1-joint-swift22.log`. Integration fixes bounded harness process completion; next transaction run will exclude bootstrap. New compiler warnings in owned test captured counter are queued for a thread-safe counter correction.
Swift22 log SHA256: `7c83280b598893d01eb8ee7d79a10cee6a1bbd6966c55c71059c5760ac457a0b`.

After Swift22 interruption, buffered output showed the identity-proof negative/binding regression passed (0.002s) and one subprocess helper entry returned. The composed journey never completed; no suite or transaction acceptance passed. This does not change the interrupted overall result.

## Swift23 live component results (overall run pending)

Command: `NSUnbufferedIO=YES swift test --filter 'CandidateProviderRunnerTests|ModelCatalogTransactionsTests|ModelCatalogTransactionRetentionTests|ModelTransactionContextTests|ModelTransactionOwnerLifetimeGuardTests|ModelTransactionControlLeaseTests|ModelCatalogArtifactSealTests'`. Build23.09s; log `/tmp/build1-joint-swift23.log`. Bootstrap excluded to separate harness failure.

CandidateProviderRunner:25 selected,24 passed,1 skipped,0 failures,19.069s. Skipped `testIntegrationRealServeLifecycleWhenEnabled` requires explicit qualified provider binary/model environment; it is not acceptance evidence. New constructor fence negative passed. ArtifactSeal4/4 passed. Retention20/20 passed113.654s, including fullcapacity/mixed history/legacy1024 and receipt safety cases. This is the pre-binding implementation snapshot; the proposed new immutable binding remains unimplemented. Owner/context/guard suite results still pending.

Swift23 final result: exit1,92 selected tests,1 skipped,5 failures (1 unexpected),301.698 seconds. Owner suite26 tests/5 failures102.119s: cancellation-during-authority-fetch had no startedAt and returned queued cancelled instead of cancel_requested (two assertions); real measured success scenario returned busy, marked failed and resultUnavailable (three failures). No success claim for owner suite. Retention20/0, context7/0, controllease6/0, ownerguard4/0, seal4/0; candidate24pass/1skip. The test-only compiler counter warning is resolved in this snapshot. CLI lane traces exact pre-mutation contention boundaries before fixes; no partial-publication retry or relaxed assertions authorized. Bootstrap reruns separately with --skip-build against the same compiled snapshot.
Swift23 log SHA256 `4723379e1c23049f5c103c7224b87eee8d173eeb697d9b52cec823f07a40ae07`.

## Swift24 parsed bootstrap reaches settlement, teardown assertion fails

Integration-owned `NSUnbufferedIO=YES swift test --skip-build --filter Build1CommandBootstrapTests` used the Swift23 compiled snapshot and a180-second outer process deadline. Exit1,4 methods/1 assertion failure (0 unexpected),15.253s; two methods are subprocess helpers. Parsed preparation→recommendation→original adoption→signed offer/status→authenticated WS identity proof→retry→settlement_capable→valid receipt→exact1ledger row/buyer20/gross16/provider14→coordinator restart and bridge clean exit assertions passed. The only failing assertion was the fixture provider's `terminated` trace marker at line158. Actual teardown evidence is being investigated; full journey is NOT passed until corrected and rerun. No MLX model inference, TLS or production qualification follows from the deterministic fixture. No unbounded wait reproduced. Log `/tmp/build1-bootstrap-swift24.log`.

After approved immutable bindingr3 normative SPEC001 amendment, `python3 scripts/check_spec_governance.py --base-ref 914f7cafcdbcfc1805a10f4f34167218341d5587` exited0 (SPEC governance validation passed). Fresh `go vet ./...` from test/integration after identity proof fixture hooks exited0. Draft PR declaration in pr-body-draft.md validates against current tracked+untracked paths via validate_body; no PR opened and final HEAD-based event validation remains required after final review/commit.

## Swift25 checkpoint and interrupted owner harness

`NSUnbufferedIO=YES swift test --filter 'Build1CommandBootstrapTests|CandidateProviderRunnerTests|ModelCatalogTransactionsTests|ModelTransactionContextTests'` compiled the schema-only binding checkpoint. Bootstrap4/0 passed14.977s (one complete parsed journey, one identity negative/binding regression, two entry helpers), including exact receipt/ledger/restart and PID/group/listener teardown. This is the first complete parsed deterministic fixture pass; no model inference/TLS/production claim. The later actual evaluation owner-death test stalled in redundant Foundation waitUntilExit line878. Root1second sample confirmed the stack; verified ownedXCTest162 parent99737 had no children, sentSIGTERM only to that XCTest, overall commandexit1 interrupted. No complete owner or overall pass. CLI removed both remaining redundant post-death waits with bounded termination polls; fresh runtime evidence pending.

## Billing S1 corruption regression and fix

Independent Go review reported that losing the complete artifact extension could choose legacy rates before digest validation, and uncached verified-receipt synchronization skipped that validation. Ordinary SQL updates are blocked by the existing immutable snapshot trigger. Corruption fixtures explicitly remove that trigger ONLY in disposable test databases to simulate corrupt retained storage; production trigger is untouched. This is not a demonstrated remote-provider mutation path.

Fresh red regression `/tmp/build1-billing-stripped-red2.log` reproduced whole-extension loss acceptance in cached/uncached recovery and verified-receipt sync, including credit changing5→0 under cache fallback, and acceptance of corrupt legacy JSON. The earlier redlog only failed test setup at the immutable trigger and did not prove the reader bug.

Root fix validates every existing route's complete digest before absence may select legacy behavior, and validates uncached sync before any credit mutation. Genuinely absent legacy routes retain existing behavior. New recovery cases retain a synthetic verified-verdict fixture; synchronization cases first ingest an actual fixture-signed receipt, then corrupt storage. Neither is deployed evidence. `go test ./internal/billing -run TestArtifactAdmission -count=1` passed1.192s; `go vet ./internal/billing` passed. Full billing race suite running at `/tmp/build1-billing-stripped-full-race.log`; independentS1re-review pending. S2promotioncommit race requires its own plan gate and remains unfixed.

### S1 missing-route final billing regression

`cd phase4-coordinator && go test ./internal/billing -race -count=1` completed exit0, package104.945s. Log `/tmp/build1-billing-missing-route-full-race.log` SHA256 `ac73b799047fa3169c7e29ff2053c5393bf064c6f657c57231d6e50f0df3477b`. This includes the retained-extension and whole-missing-route recovery corrections and fault-injection tests; it is local Go evidence only. Independent S1R3 review has zero remaining C/H/M in that bounded scope; S2 and final combined reviews remain open.

### Swift26 first immutable-binding implementation check

`NSUnbufferedIO=YES swift test --filter` selected the two `testContention*` methods, `testCancellationDuringAuthorityFetchTerminatesThroughOwnerInterface`, `testRealPreparedRecommendationOwnerUsesMeasuredProbeAndRestoresLifecycle`, `testEvaluationSuccessDeltaReplaysExactEventAndOnlyCleanupBookkeeping`, and retention `testQueuedSuccessorNeverHidesCompletedResultIncludingRestartAndCleanup`. Log `/tmp/build1-joint-swift26.log`; build38.91s, test6methods4failures(1unexpected)37.635s, exit1. Contention2, exactdelta and queued-successor passed. Cancellation failed before startedAt with unsafe evidence; measured-owner test also threw unsafe evidence. Source freeze released for diagnosis; no full binding acceptance claim.

### Swift27 descriptor ownership correction

Swift27 passed7/0 in39.591s exit0, including deterministic FD-reuse regression, cancellation during authority fetch, two contention methods, exactsuccessdelta, queued successor and actual measured-owner fixture. Log SHA256 390cf923a5c45b3057ca26d974ed534acdba06ec3af7246f2f16ec0a79586bb1. This confirms focused regression only; full owner crash/migration/retirement matrix and final combined audits remain outstanding.
Command: same six-method Swift26 filter plus `ModelCatalogTransactionsTests.testFailedLockInitializationCannotCloseReusedDescriptor`, with `NSUnbufferedIO=YES`. Log `/tmp/build1-joint-swift27.log`. XCTest selected7; trailing Swift Testing zero-test runner is not counted as evidence.

### S2 billing authority owner guard

Implemented approved scalar `Store.TryPinSettlementConfig` using nonblocking read ownership and shared existing CadenceDays==0 fallback. `go test ./internal/billing -run '^TestTryPinSettlementConfig' -race -count=1 -v` passed3 top-level tests (selection has3 subcases), package1.723s, exit0. `go vet ./internal/billing` passed. Tests cover default/explicit semantics, contention with no authority/release returned, setter exclusion under exact owner mutex and reacquisition after release. Log `/tmp/build1-billing-config-guard.log` SHA256 `c25a8eee75c55d904adb12861a5ffe30070774b697d9cf17c7dbe26192b326b2`. Full S2 integration and combined audits remain outstanding.

### Swift28 interrupted scheduling correction

Lead accidentally selected Build1CommandBootstrapTests alongside the full owner/retention suites while S2 Go source edits were active. Stopped the verified owned swift-test PID28988 with SIGINT before tests; session returned130. No XCTest acceptance evidence. Log `/tmp/build1-joint-swift28.log`; compiler/test source freeze held. Swift29 replaces it with only `ModelCatalogTransactionsTests|ModelCatalogTransactionRetentionTests`. The Go-building bootstrap must wait for Go source freeze.

### Swift29 full transaction/retention matrix

`cd phase3-binary && NSUnbufferedIO=YES swift test --filter 'ModelCatalogTransactionsTests|ModelCatalogTransactionRetentionTests'` completed exit1:57methods2failures0unexpected466.985s. Owner30/0passed191.493s, including actualevaluation/binding/parsedcleanup crash matrix80.167s, actualpreparationownerdeath26.663s and measured11-scenario fixture26.615s. Retention27/2failed275.492s: fullcapacitysingle-callreservationbusy20.112s and legacy1024active-count remained1024 afterfinitepasses164.981s. Mixed>2052historypassed76.142s, actualmigrationcrashmatrixpassed3.199s. Log `/tmp/build1-joint-swift29.log` SHA256 `d3c6a128ea42931a5ce8adecb0fcc39976cc64050fffba8686560aeac7f18361`. No complete binding acceptance. Capacity test must honor approved repeatedboundedcalls; migrationvalidationplacement/per-callreceipt correction is underindependentplangate.

`cd phase4-coordinator && go build -o /tmp/build1-coordinator-guard ./cmd/coordinator` passed with newmandatorytransportcallbacks and checkedguardedauthorityinstallation. This is compileevidenceonly, no servicejourney or S2race acceptance.

### S2 real-service closing isolation and positive compatibility

Integration owner reports `cd test/integration && go test -race -run '^(TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation|TestBuild1ArtifactAdmissionSettlesThroughRealServices)$' -count=1 -v` passed2top-leveltests plus2closing subcases,0fail/0skip,8.641s; `go vet ./...` passed. Root read log SHA256 `1aed8794e41b81cf39a518bae66c6d8052a0d1c145eb5d7bc6202f6fbeca9809` at `/tmp/build1-closing-route-final-race.log`. The actual blacklist/scheduledclose test revives same-session ready state and verifies every exposed othereligibility predicate unchanged before FIRSTbuyerrequest. Both normal revocation and deniedrevocation-write cases refuse withoutdispatch/newpayablerows; priorpositiveauthority remainsinfailedrevokecase. Positivefixturejourney preserves16gross/14providercredit/restart. This is localGo fixtureinference; noactualMLX. Remaining direct/default/pinned/queued, missingwiring/replacement andserialization matrices belongWS/buyer lane.

S2 real-service final assertion extension: same2top-level+2closing-subcase race selection passed0fail/0skip9.564s after asserting no extra probe frames. Log `/tmp/build1-closing-route-final2-race.log` SHA256 `0ab13aa53bd995673d7266ed9ec71b11dc295f77e2a5ba892922c51d5478c184`. Supersedes final snapshot evidence for this narrow integration slice; full S2 owner/unit matrices remain unproved.

## Swift30 final — failed, not acceptance

Command (phase3-binary): `NSUnbufferedIO=YES swift test --filter 'ModelCatalogTransactionRetentionTests|ModelTransactionControlLeaseTests|ModelTransactionOwnerLifetimeGuardTests|ModelCatalogTransactionsTests.testActualCleanupOwnerFencePreservesOriginalTruthAndRemainingStaging'`. Exit1,44 selected XCTest methods,5 failures(1unexpected),490.899s. Log `/tmp/build1-joint-swift30.log`, SHA256 `f88da943b2c1b0e58065556050d1752356692bf83e4388f6404e04bb2d6ecb3a`.

Retention33methods/3failures407.834s: modified migration source fresh-receipt fixture expectation; full1024 capacity failed bounded progress after8attempts; legacy1024 retirement left271 after16passes. Cleanupowner1/0passed11.488s. Controllease6methods/2failures in1case28.131s: blockedreconcile helper failed reach intended boundary and cleanup path threw Cocoa4; diagnosis pending. Owner lifetime guard4/0passed. Swift Testing footer selected0 and is not evidence. No SwiftPM remains active. Source freeze released only for diagnosed fixture corrections and proposed separately gated progress-plan documentation.

Fresh `git fetch origin --prune` leaves origin/main914f7cafcdbcfc1805a10f4f34167218341d5587. `git diff --check` passed before subsequent test-only edits.

## Conformance evidence freshness

`python3 scripts/check_spec_governance.py` after the active-index normative amendment exited1 because SPEC-032-R002's historical commit no longer matches three mapped WS fixture bodies changed for provider-publication ownership. The requirement is now honestly pending current reconciliation, retaining original mappings and historical commit/signed physical evidence. No acceptance criterion, test mapping or production protection was removed. Targeted fixture race14top-level+5subtests passed; reviewed current commit evidence and applicable qualification remain pending. Existing SPEC032 is draft/partial/pending-verification, unchanged. PR declaration includes this evidence-state change.

After recording SPEC-032-R002 as pending honest current-evidence reconciliation without deleting mappings/historical artifacts, `python3 scripts/check_spec_governance.py` exited0: SPEC governance validation passed. This restores governance validity, not current conformance/physical qualification. Active-index receipt implementation authorized only after this result and normative amendment.

## Broader Go static checks

`make vet > /tmp/build1-final-go-vet.log 2>&1` exited0 across coordinator, gateway and integration. `make lint-coordinator` initially exited2 because the pinned installed tool is absent from default PATH. Retried the existing v2.12.2 binary at /Users/augstar/.cache/codex-tools/macprovider/golangci-lint with fresh task-specific GOLANGCI_LINT_CACHE and GOCACHE; result pending, session63458. No dependency installation or manifest change in this continuation. Later test corrections require appropriate fresh checks.

## Continuation: catalog gate and Swift32

`python3 scripts/check_spec_governance.py` exited 0 (session42035): SPEC governance validation passed after approved catalog-read r2 normative amendments. Catalog implementation authorized against plan e607e8d45fac124d5ebc85e6a9f6064bd803052487c8b93998e4d091984ff954 / review e2a7db3b3616403342cbcc3cc543050a2ba07a717e6cedccd34dc6c8b07e3812.

`swift test --filter ModelCatalogTransactionRetentionTests` (Swift32) exited1: 38 methods,4 assertions failed in one test,195.560s, no unexpected failures; build44.40s. Log SHA256 7b121b65ea03cf9fa09fabe2e6b454679c731901b786d3947406b6e575a176fa. Recapture test incorrectly assumed no preexisting cursor/lexical traversal after two setup reservations; corrected test awaits rerun. This is NOT a passing suite. Healthy capacity15.368s and mixed history84.279s passed; legacy1024 retired fully in six of the unchanged16 bounded passes, with first three forced8s budgets retained. Pass remaining counts1024/1024/947/475/22/0; decode counts1/1/2/1/1/1. Phase counters scan_started3/scan_completed2/cursor_published1765. Large-record worst-case progress remains separately unproven; healthy fixture no longer justifies reservation-v4 necessity by itself.

Fresh gateway `go test -count=1 ./...` exited0, router36.549s, logSHA5250399269b09a0f764a18e56478b2a912d7143d8d369825bfb7a9869a99dea2. Earlier cached invocation excluded from fresh evidence. Pinned existing golangci-lint2.12.2 with isolated GOCACHE/GOLANGCI_LINT_CACHE, `run --config=.golangci.yml ./...` coordinator exited0 (0 issues), logSHAe92606b0bf483111dff0a120c315ea165821348f31365020e2468a0059095c47. Subsequent coordinator test edits require final recheck.

## Swift35 catalog/control evidence and failed bridge export

Swift33 and34 were compilation failures and selected zero runtime tests. SHA256 respectively7c9608869c6ca87315816daec91070004cebb68f6d0ce37fc50d6331469a618e and182d483311c3ae0c2e27e77343dc7969becc432204419c2e2cc0d4b442412944. Errors fixed in owned code/tests before Swift35.

`swift test --filter 'ModelCatalogReadTests|ModelCatalogLocalInspectionTests|ModelCatalogTransactionRetentionTests.testIndexRecaptureRejectsChangedPublishedBytesWithoutLaterCursor|ModelTransactionContextTests|ModelTransactionControlLeaseTests.testCatalog'` Swift35 exited0:27methods,0failures,35.118s; compile40.56s. LogSHA1689a736e10ae8bae162bc1a80b7b3cc5b464d31308ab5e2f3195777ed2e7164. Inspection8; read7; recapture1; context7; cataloglease4. Actual canonical10MiB hash+config lasted21.038s with measuredbyteprogress/independentheartbeats. Closedprogress tests, monotonicbudget propagation, all parsed forbiddenoverrides beforeconfig/inputs, exactcontext/configreplacement guard passed. Actualchildcatalogread tests: parentdeath while another lifetimewriter remainedopen, EOFholdinglockuntilexit,10.327s prehomewatchdog, wrong/unowned/unheld/privatepermission/pipe-direction rejection. This does not prove actualapp→parser signedbridge, realMLX/model orproduction qualification. Corrected recapturetestpassed0.233s; earlier38methodfullsuite failure retained.

`BUILD1_CATALOG_BRIDGE_PHASE=export swift test --skip-build --filter ModelCatalogReadBridgeTests.testExportPersistentSignedFixtureForActualAppCaller` used Swift35 compiledbinary and FAILED:1method,1unexpected,29.078s. Candidateprovider remainedactive after fixture0.2sgrace (port/groupheld), actualevaluatetransactionfailed. No inputmanifest/applicationbridge acceptance claimed. Fixtureowner diagnosing cleanup without weakening productionstopguard. Rootdidnotkill unknownprocesses. Rawlogs copied into .omx/artifacts in durableworktree.
