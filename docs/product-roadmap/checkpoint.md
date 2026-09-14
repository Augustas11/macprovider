# Product roadmap execution checkpoint

## Authority and baseline

Requested sequence: Builds 1–4 independently planned, Astra adversarially approved,
implemented and audited; Build 5 assessment only; Build 6 excluded. No merging,
deployment, releases, enforcement/economic activation, payments, hardware purchases,
or operator-secret changes are authorized.

Fresh fetch on 2026-09-10 returned origin/main
`422fc2f13fc62c1ff8987522f822d9ef856e4a96`, identical to the historical roadmap.
The original roadmap is preserved in `historical-roadmap.md`; its test reports
remain historical. Canonical checkout was clean. Other sessions' worktrees were
inventoried and left untouched.

Build 1 workspace: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`,
branch `codex/product-build-1`, created from fetched origin/main.
Read repository AGENTS.md and CLAUDE.md before writing artifacts.

## Dependencies

PR #1468 (`feat/byom-v02-slice2c-cli-artifact-feed`) was initially open and is now merged; see the ancestry evidence below.
Inspected head: `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`.
It implements signed artifact-feed consumption and has ongoing CI. Its previous
review records and CI are not fresh local acceptance evidence. Build 1 planning
accounts for this exact dependency without duplicating it. Dependency commits
were imported by fast-forward after plan approval. The current per-build diff starts at merged commit 914f7caf. This session performed no merge to main.

## Current stage

Build 1 plan-r4/test-spec-r4 independently approved by native GPT-6 Astra high,
zero C/H/M/L. Earlier rejection rounds and final exact digests are preserved in
reviews. Implementation is active: contracts complete, CLI transactions,
durable discovery/retry journal, app UX, coordinator authority, and integration
lanes. Lead owns economics projection and retry command integration. No final
implementation audit or physical acceptance has passed. Retry journal material
addendum-r2 independently approved zero C/H/M/L; earlier r1 rejected Medium.
Do not claim implementation complete from source presence or baseline tests.

Builds 2–4 await their sequential per-build loops. Build 5 awaits assessment.

## Fresh environment evidence

- macOS 26.5 (25F71), Apple M5, 34,359,738,368 bytes RAM (32 GiB).
- Xcode 26.6 (17F113); Swift 6.3.3; shell Go 1.26.4 (repo requires 1.26.6;
  verify automatic toolchain selection in modules before tests).
- Repo release lock verification requires Xcode 16.4, absent from /Applications.
  Local Swift tests use 26.6 and cannot prove that release-toolchain gate.
  SwiftPM pruned conditional dependencies from Package.resolved during baseline
  resolution; the task restored the original lock bytes immediately. No
  dependency update is intended or permitted by that generated change.
- Initial Docker daemon check failed: socket absent. Docker.app exists and
  `open -a Docker` succeeded; subsequent docker info reports server 29.7.2.
- Worktree filesystem reported 86 GiB available. Large downloads need bounded
  disk/memory checks. Model cache directory names include Llama 3.2 1B/3B,
  Qwen2.5 Coder 1.5B/7B, and Qwen3 8B; names alone do not prove complete or
  trusted artifacts. Durable store contains a Qwen3 8B directory. No physical
  inference run yet.
- `/Users/augstar/projects/malibu` exists; its code/instructions have not yet
  been inspected, so its integration state remains unknown.

## Resumption

Complete Build1 lanes, freeze Swift inputs before combined tests (one earlier
broader run was interrupted by concurrent source edits, not passed), integrate
all interfaces, run targeted/full appropriate gates and independent complete
code/security/architecture audits. Current authoritative details live in
plan-r4, test-spec-r4 and approved retry-journal-addendum-r2. Hardware
qualification remains pending. Produce acceptance/PR handoff before Build2.

## Prerequisite landed during implementation

PR #1468 merged at 2026-09-10T05:49:43Z as `914f7cafcdbcfc1805a10f4f34167218341d5587`. Fresh GitHub state confirms MERGED; `git diff --stat f5edeaebfb6c712a2cb6dced9020c8c78ed1053e origin/main` is empty. The task branch was soft-reset to that identical tree (no worktree files changed), removing duplicate prerequisite history. Build 1 final diff/audits now use 914f7caf as base. Original plan approval remains tied to the identical f5edeaeb tree; this is ancestry alignment, not a design change.

## Continuing verification checkpoint

Latest pre-correction app suite:617 passed; gateway full test packages and vet passed; SPEC governance passed; Python artifact/legacy contracts145 passed. Real-service SQLite fixture race3 passed with exact20-token debit/16gross/14provider credits and restart/replay, no MLX. Details in per-lane implementation reports and validation-lead.md. Swift final suite not passed yet; last combined167 run had1 failure and1 skip, active corrections/testing remain.

Independent security/architecture audits underway, not approved. Findings under correction: stale selected provider vs live registry restrictions; status freshness after probe expiry/disconnect; artifact transaction root ancestor symlink mutation; app cancellation/status unavailable while measurement drains launchd incumbent. The latter architecture change requires transaction-control focused plan gate before implementation. Corrupt journal recovery r2 approved; implementation preserves undecodable bytes and blocked retry/new offer after authoritative withdrawal.

Public read-only artifact feed/signature endpoints returned404; candidate feed/signature200. See qualification-blockers.md and public-feed-preflight.json. Physical B1-T10 remains unproven, and no fixture evidence substitutes. No Build1 commit/PR yet; Builds2–5 not started. Continue all safely executable work.

## Review correction loop in progress

Three preliminary implementation audits are durable: security-r1 (3Medium), architecture-r1 (4Medium), code-r1 (2Medium). No implementation audit gate passed. Go runtime corrections and retry config identity factory are present; CLI ancestor path hardening and new owner negatives tested. Fresh Swift6 selected466 had1skip+1fixture failure (HTTP URL rejected); fixture corrected. Swift7 selected owner/retry13 passed. Full Swift still pending.

Focused plan rounds: corrupt-journal r2 approved and implemented. Owner-testability r1 rejected3Medium, r2 approved exact5141587df7e9749947830649f579653d463fdd6fbe4940fa460baee1c9dd8bad; CLI owner implementing realprober fixture/resultcommit recovery. App transaction-control r1 rejected2Medium (unbounded helper, stale kind/generation); app author draftingr2, no implementation yet. Retention r1 rejected1Medium (permanent protected-record cap); durable author draftingr2 active index preserving directUUID evidence. Cleanup r1 rejected1Medium (wire/identity ambiguity); lead r2 separate protocol2 recoveries proposed, under independent review and awaiting exact controlgeneration contract.

Full coordinator ordinary go test ./... passed; full coordinator isolated-cache lint0issues passed. Billing full race initially failed existing clock-dependent rate limit assertion, isolated reproduced; root test-only correction freezes existing limiter clock and explicitly checks refill. Targeted race passed14.970s; fullbilling race rerun active. Runtime untouched by test correction. No new project dependencies; declared lint tool installed outside repo.

## Latest continuation checkpoint

Full billing race passed95.141s after the deterministic test clock correction; coordinator vet and isolated-cache lint passed again. Swift owner subprocess-death tests passed16/16, including reserved/started/publication-intent/published/preterminal boundaries. A real process/prober fixture run is active; this is deterministic integration evidence, not MLX hardware qualification.

Cleanup recovery r3 is independently approved0C/H/M and waits on transaction-control approval before combined implementation. App control r2 rejected2Medium (suspended orphan and consumed-config binding); r3 in preparation. Retention r4 (caa5fe5ea845651312680cb5ceebf59b9c3e82d0490525d561f01a89165221dc) under independent review, fixing mutable cleanup invalidation through immutable success commitment. Command composition r1 rejected1Medium because initial catalog-economics reservation was omitted; r2 in preparation. No runtime implementation of these pending designs is authorized until their gates pass.

Lead owns forthcoming secure CLI consumed-config/context binding and wire/SPEC integration; app owner owns app snapshot/runner/recovery; CLI owner owns transaction lifecycle/real owner tests; durable lane owns gated retention/index/pointers; integration lane owns parsed command composition fixtures. Preserve these shared-file boundaries.

## Approved correction implementation resumed

Controlr4 approved0C/H/M/L at exact3bd808b21557a22a979446f300b22a2013f1717f06670c616ee9c858877679e3; root normativeSPEC001/044 amendments written before runtime authorization. App and retention/CLI correction owners may implement approved boundaries after sharedSwift freeze. Commandcompositionr3 baked-fixture inputs approved5cd2f3d1daabcd14fa746a50587844a4938999307555bf576dea6490d019fdfe. Root discover/offer/adopt now share explicit command context and adoption DEBUG authority bypass removed; integration owns signedrollbackfixture migration. Swift12 owner19/19 passed49.86sec, actual ownerSIGKILL midSSE cleanschild/listener, refreshedstalerate/preresultcancel/postcommittruth negatives pass. ModelsSubcommandTests targeted migration run active, sourcefreeze held by integration.

## Current checkpoint after Swift19 (supersedes prior live-status paragraphs)

Base and freshly fetched origin/main remain914f7caf; all Build1 edits remain uncommitted in codex/product-build-1. No PR, merge, deployment, economic activation or Build2 advancement. Historical approved plan/test digests and correction rounds remain in build-1/reviews/gate-log.md.

App final pre-resource-correction Xcode suite625/0 passed. Swift17 lease6/0, adoption46/0, journalpath2/0, durable11/0, seal4/0, retention16/0; whole117 selected failed11(8unexpected). Swift18 owner23/0passed; whole32 selected failed2. Swift19 targeted10 failed2, with9-case owner failure method passing; bootstrap now reaches measured preparation/recommendation/readback/adoption before fixture custody setup failure. Root has fixed context expected-path assertion; integration shortened fixture root within private user temp to satisfy both custody and socket limits. These final corrections await next run. No Swift process currently running.

Retention-lock-budget-r2 independentlyapproved0C/H/M at65266d7773402d9e4309291aedec354d813fd2e0e9883a16a7b93fbd6a4bfe21; SPEC001 normative amended before authorization. Durable lane implements receipt/CAS/lock-budget changes; CLI lane integrates terminal/index/heartbeat fences; security lane owns new independent8s-fence/10s-exit ownerguard/process tests. Source freeze released for this implementation; coordinate all lanes before next Swift compile.

New known code gap: binary-only app snapshot omits adjacentMLX resources. Snapshot-resources-r1 rejected2Medium (preflight outside control deadline; partial orphan cleanup recovery). App author preparesr2; no resource correction implementation authorized yet. Distinguish this deterministic gap from absent signing identity and physical qualification. Existing0755 durable roots are deliberately rejected by app-bound private-root setup; no permission migration was approved or performed.

Root owns Context/ModelsSubcommand/ModelsAdmissionRetry and SPEC/evidence integration. No temporary diagnostic logging remains. New status/retry use the shared explicit internal command context with unchanged production defaults. Adoption DEBUG authority bypass remains removed. Remember restore Package.resolved to HEAD after final SwiftPM execution; it is currently pruned by local toolchain and is not an intended dependency change.

Next: complete approved retention implementation + tests; review resource-r2 until0C/H/M then implement; get parsed bootstrap through actual localGo services; full appropriate Swift/Xcode/Go/governance checks; NEW independent complete-diff code/security/architecture reviewers (currentsecurity authoredlease/ownerguard) before acceptance report/Lorecommit/draftPR. Physical signed feed/defaultbakedfeed absence, signed snapshot and realMLX settlement remain unproven qualification. Then continue sequentialBuilds2–4 andBuild5assessmentonly.

## Fresh remote activity during correction work

Latest `git fetch origin --prune` still reports origin/main914f7cafcdbcfc1805a10f4f34167218341d5587. GitHub open PR list contains #1074 (docs/929-spec021-v04, MALIBU reward hardening) and #894 (fix/889-spec039p2, SPEC039 Phase2/FR-PKV10). They remain unmerged; inspect relevant content during Builds3/5 without treating it as landed. No new Build1 overlap was listed.

Snapshot-resources-r2 now approved0C/H/M and app implementation authorized after SPEC044 amendment. Pinned MLX metallib compiled locally (resource-only evidence in validation-lead.md). Swift20 completed63tests3failures: bootstrapfixture URL, retentioncapacity scheduling, concurrentrecordread. Context7/0, controllease6/0, ownerguard4/0passed; finalcombinedgate stillopen. CLI/durable fixingbounded scheduling/readrace +expandingactualowner tests. Immutable-retirement-binding addendum is being drafted before any new persistence authority. Sources currentlyunfrozen, no Swift or Go tests running.

## Current continuation

Immutable-retirement-binding r1 independent review: 0 Critical/High, 3 Medium (terminal cleanup recovery, unprovable historical bytes, missing new binding indistinguishable from legacy). Author revises r2; persistence implementation not authorized. CLI/durable sources frozen for integration-owned Swift21 bootstrap command test. App implements approved resource r2 and owns its Xcode checks. Root actual pinned MLX GPU arithmetic passes with metallib and fails without it; production app capture and real-model settlement remain unproven. Constructor publication fence extension is approved as enforcement of the existing contract, queued until Swift21 completes.

Swift22 combined run is active, lead-owned session84771, `/tmp/build1-joint-swift22.log`: CandidateProviderRunnerTests, ModelCatalogTransactionsTests, ModelCatalogTransactionRetentionTests, ModelTransactionContextTests, Build1CommandBootstrapTests, ModelTransactionOwnerLifetimeGuardTests, ModelTransactionControlLeaseTests, ModelCatalogArtifactSealTests. All CLI source owners acknowledged freeze. Constructor/config/log setup fences and exact contention assertion included. Integration fixture now signs actual WS challenge with the previously enrolled protected identity, no key export. App full resource-correction Xcode suite runs separately. Immutable binding r2 remains documentation only.

App resource correction full Xcode suite passed638/0, including13 resource tests and actual copied Metal/MLX arithmetic (no resource test skips). App source is frozen; report implementation-app.md SHA55782296feb1f3d4d0fae2e4fd1bda35c3d3a628b463e422caa5ce98518b80b9, full log SHA9528c99383b5d8e0c01e0b084889b43564e1656dff7a96efc3b7dac80892809e. Signed production CLI/model journey remains unqualified. Swift22 compiled35.13s and is still running; no result claim yet.

Immutable-retirement-binding-r2 proposed SHA8ba51963aa0af266ef74030fa43fdeadd2d6ab09a64f7ce76362372ea078d0dc; independent Astra architecture review active. R2 freezes exact cleanup terminal delta, disallows historical binding regeneration, and proposes origin/index references plus retained retirement certificate for archived checks. New persistence remains unauthorized pending gate. Source freeze continues during Swift22.

Swift22 interrupted exit1: test harness stuck in Process.waitUntilExit at bootstrap offer with no child processes remaining; root verified process ownership then stopped only its XCTest. No owner/retention result. Freeze released for integration bounded process-wait fix and CLI test counter warning correction. Next root run excludes bootstrap. Binding r2 review ongoing, possible migration progress/certificate schema issues reported but formal gate pending.

Binding r2 review returned0C/H2M: durable migration progress/classification/completion and explicit non-evaluation certificate schemas. Author drafting r3 docs only; gate not passed. Integration bounded process-wait fix is stable; root transaction-only rerun next after CLI helper duplicate-wait removal.

Swift23 finishedexit1:92tests1skip5failures301.698s. Retention20/0; owner26/5 in2cases (initial authority-fetch start missing; actual measured successbusy beforecommit); context7/0, controllease6/0, ownerguard4/0, seal4/0, candidate24pass1skip. CLI source freeze released for exact contention diagnosis; no partialbundle retry. Integration owns imminent --skip-build bootstrap againstSwift23 compiledbinary; no compile whileCLIedits. Bindingr3 stillunderAstrareview; no bindingruntimecode.

Swift24 bootstrap skip-build completed15.253s exit1,4methods1assertionfailure: actual full parsed service journey reached correctvalidreceipt/ledger20-16-14/restart/bridgeexit; missing fixtureterminatedmarkeronly. Integration diagnosingactualteardown; fulljourneyunpassed. CLI scopedbusyboundaryfixunderway. Bindingr3reviewstillpending.

Bindingr3 approved0C/H/M/L and SPEC001§6.14b amended before runtimeauthorization. Durable lane implementsorigin/migration/index/certificates/archive; CLI ownsterminaldelta/replay/writerfences afterbusyfix. ExplicitsharedAPIcoordination underway, noSwiftPM untilrootfreeze. New independentAstra app-security-current-r1 preliminarylane reviews stableapp source; itdoesnotreplacefinalcombinedaudits. Freshgovernance+integrationvetpassed; PRbodydraftprepared/locallydeclarationvalidated, noPR/commit/push.

Current: Swift25 interruptedexit1 afterbootstrap4/0pass14.977s; actualevaluationowner-test redundantwait confirmedsample, killedonlyownedXCTest afterzerochildrenverification. CLI boundedhelperfixdone andbindingintegrationresumed; durableorigin/migration/indeximplementationresumed. NoSwiftPMcurrently. RootS1billingfix+newcorruptiontests green1.192s, fullbillingraceactive session1374; billingvetpassed. NormalSQLimmutabilityprotected; testsdroptriggeronlyindisposableDBtoexercisecorruptstorage. S2promotionfixplan author/root/build1_promotion_fix_plan active, noimplementationuntilAstra gate. AppM1/L1fixsourcefrozen, freshXcodefull+appsecurityr2reviewactive; exact10filemanifestSHA12be3a3ad277944b795c0350ff80b83158c35bf6a37750e2adf37eb6f6964c1c. GoS1re-reviewactive. Finalcombinedgatesstillpending.

## Resumed verification checkpoint

S1 recovery correction independently accepted in go-security-s1-r3-astra.md: zero remaining C/H/M within S1 only. Fresh final S1 billing race passed104.945s; log /tmp/build1-billing-missing-route-full-race.log SHA256 ac73b799047fa3169c7e29ff2053c5393bf064c6f657c57231d6e50f0df3477b. App full641/0 and app-security-current-r2 zeroC/H/M/L remain unchanged. S2promotionR1 rejected1Medium: local raw socket close/scheduling bypasses proposed session availability guard. Author revisesR2; no S2runtime implementation. Bindingr3 initial implementation frozen for targeted compile, legacy/full-capacity fixture adaptations and new full matrix remain outstanding. Build1 acceptance and combined audit gates remain open; Builds2–5 not yet advanced.

Swift26 completedexit1:6methods4failures1unexpected37.635s afterbuild38.91s. Contention2/exactdelta/queued-successor passed; cancellation owner failedbeforestart unsafeevidence and measuredownerthrewunsafe. CLI/durablefixing withinapprovedr3; noSwiftPMactive. PromotionR2 SHA494a93e351df87e1cdd4617eee8e0e1dd0912a9299a512300ba33a684eded6f5 undernativeAstrahighreview; runtimeS2notauthorized. Freshoriginmainunchanged914f7caf.

Swift27 passed7/0 in39.591s exit0, including deterministic FD-reuse regression, cancellation during authority fetch, two contention methods, exactsuccessdelta, queued successor and actual measured-owner fixture. Log SHA256 390cf923a5c45b3057ca26d974ed534acdba06ec3af7246f2f16ec0a79586bb1. This confirms focused regression only; full owner crash/migration/retirement matrix and final combined audits remain outstanding. CLI/durable Sources unfrozen to finish required matrix. NoSwiftPMactive. S2promotionR3 authoring afterR2read-sideavailabilityMedium.

S2promotionR3 APPROVED nativeAstrahigh0C/H/M/L; exact6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4. SPEC047 normative+R008 amended and governancepassed beforeimplementation. /root/build1_promotion_fix_plan ownsWS/buyer; /root/build1_authority_owner_guards owns pool/Tier2; rootowns billing/cmd/integration. BillingTryPinSettlementConfig implemented, race3tests+vetpassed1.723s. NoS2acceptanceyet. Swiftownerscompletingmatrix, noSwiftPMcurrently.

Swift29 finishedexit1:57methods2retentionfailures466.985s; owner30/0passed191.493s. NoSwiftPMrunning. Durablemayfixapprovedsame-generationrefs/finitecapacityfixture; migration-receipt-budget-r1 SHAa8d22c7680f7eaa026966615eda86c51a53350154b0fe910ac859eda918bb49b underindependentAstrareviewbeforechangedplacement/cache. GoWS/buyerruntimefrozen andtestmatrixbeingwritten; pool/Tier2slice149top-level+54subtests racepassed/vetpassed. Rootmainwiredtransportcallbacks/readiness/Set(resolve,prepare)checkederror; coordinatorbuildpassed. IntegrationowneraddsactualserviceT11blacklist/grace/readyrevival routeproof. NoB1acceptance/PR/commit yet.

## Concurrent artifact identity work — unmerged

Fresh read-only worktree/PR inventory found `feat/byom-v02-slice3-gguf-settlement-identity`, head `1d82e1b181dfb91516106994750705d8883b6b5f`, merge-base914f7caf, with active uncommitted changes in its separate worktree. Its runbook/commit scope is GGUF and non-primary artifact identity/settlement binding; it overlaps BYOMDiscovery, coordinator WS/buyer/pool/billing and SPEC047 files. No open PR for that branch was listed (only1074/894). It is NOT landed and NOT a prerequisite silently incorporated here. Current Build1 remains approved primary-MLX self-service scope with non-primary failclosed coverage. Preserve that worktree and re-fetch/check overlap before final Build1 PR; later landing may require explicit reconciliation/review. No source or state was changed there.

Swift30 active root session50901 `/tmp/build1-joint-swift30.log`, selection `ModelCatalogTransactionRetentionTests|ModelTransactionControlLeaseTests|ModelTransactionOwnerLifetimeGuardTests|ModelCatalogTransactionsTests.testActualCleanupOwnerFencePreservesOriginalTruthAndRemainingStaging`. CLI/durableSources/tests frozen. Migration-receipt-budget-r1 approved0C/H/M/L, SPEC001 clarified+governancepassed beforeimplementation; newretentionmatrix33methods ready butunrun. Rootmainbuild+vetpassed. Additionalbuyertestlane3top-level16subcases ready awaitingWSownerfreeze; fullS2testmatrixstillunderway. Integrationfinal2racepassed2top-level2subcases9.564s. NoBuild1handoffyet.

## Continued verification — Swift30 failures and S2 parallel test ownership

Swift30 retention suite completed33 tests with3 failures407.834s: fresh receipt fixture incorrectly expected modified source bytes to remain valid; full-capacity reservation failed to advance after eight bounded attempts; legacy migration/retirement left271 of1024 records after approved finite passes. Entire selected run still active (root session50901); cleanup-owner test passed11.488s. No pass claim for retention. Durable owner is drafting a separately gated correction for bounded progress; faster decode alone must not substitute for a progress argument or weaken validation/acceptance. Runtime edits remain frozen until run completion and plan approval.

S2 private clock/boundary seams implemented under approved T05/T06 testability, default wallclock preserved. WS owner retains expiry/store failure/actual closure producers/routes. Integration owner now owns only new model_admission_readback_race_test.go for T03/T08/T09. Owner-guard lane repairs existing non-model_admission WS fixtures through real registry publication after intentional Provider alias isolation. Full prior WS/buyer nonrace: buyer passed9.640s, WS failed28.592s; fixes are not yet full-suite acceptance. Independent combined security review has started against an exact recorded snapshot; remaining source/test corrections require final rereview.

Swift30 FINAL exit1,44tests5failures1unexpected490.899s; logSHA256 f88da943b2c1b0e58065556050d1752356692bf83e4388f6404e04bb2d6ecb3a. Retention33/3fail; cleanupowner1/0pass; controllease6/2fail in1case; ownerguard4/0pass. No active SwiftPM. CLI owner diagnoses lease fixture; durable corrects wrong source-byte expectation and drafts structural bounded-progress plan before runtime edits. Final combined audits/handoff remain open.

## Additional combined findings and next gates

Swift31 corrected lease fixture passed6/6 in23.411s, exit0; noXCTest remained. Fixture now uses real reserveOperation/receipt commits instead of protected generated pre-migration raw records. CLI report retains exact command/evidence. NoSwiftPMactive.

Combined security review security-combined-r2-astra.md records B1-SEC-M1: actualapp injects --ctl-socket-path, which excludes prepared local transaction context/actions at parsed CLI guard; B1-SEC-M2:10s catalogread continuation timeout leaves full-hash child alive, and localactions rehash independently. Appauthor writes catalog-read-lifecycle plan before runtime correction; final641app result predates corrections and cannot prove those missing producer paths. Package.resolved pruning remains incidental and must be restoredexactHEAD afterSwiftPM.

Native Astra architecture reviews retention-active-index-receipt-r1 SHA17780883c2a224ba7d07f76ee96d03463cf930e9eb479286c22b74b9d6b367b6. This narrowly addresses legacy retirement repeated-index decode; separate reservation-search design author owns docs only, preserves8s/finite8calls/reuse correctness. S2 HTTP teardown test addendum SHA0b4c178cf0ac083d2295d4d05478d89470a50343580679b81284b87bad9bce35 awaits independentgate before testimplementation: HTTP530/redirect buyerproducer is unreachable for same WSTunneled artifact dispatch, so reachable realHTTPproducer→realWSclose proof is composed with unchanged realartifactconsumer rejection tests. No single-fixture claim is permitted.

Active-index receipt runtime authorized after nativeAstra0C/H/M/L review and rootSPEC001amendment; governance finalpassed (session4364). Durableowner implements only this approved slice. Reservationclassificationv4addendumR1 SHA dd3b085d42949a77b7f77bcb78112c81c209460a1781baa498380b353255a035 underarchitectureplanreview, notimplemented. CatalogreadlifecycleR1 SHA9d98dbf4ea3acd639005ec04f1275e68197ce5158dd9e9b8a2f40eb5b58cb16d underindependentappsecurityplanreview, notimplemented. S2HTTPcompositionaddendum approved0C/H/M/L and testonly implementation delegated ownerguards; remaining T11 realcallbacks/freshstates stayspromotionowner. NoSwiftPMactive; Swiftretentionsources nowunfrozen forapprovedimplementation.

S2readback finalrace3parents/59leaves passed19.830s; approvedHTTPcomposition1parent/2subcasesracepassed2.023s, exactlogs/hashesinimplementationreports. T11realWS35freshfixturematrix passesinitialnonrace; finalfocusedraceowner77102 found just-before1ms realbudget testexpectationfailure, fixqueuedafterrun. GoSources/testsfrozenforcurrentchecks; rootmakevetpassed; isolatedlint63458running. NoSwiftPMactive; durableimplementsapprovedindexreceipt. CatalogreadR1rejected1Mediumcompatibility; reservationR1rejected3Mediumtransition/migration/oldwriter details; bothauthorsreviseR2docs only.

## Active continuation: approved catalog implementation and max-shape measurement

Build1 only; Builds2–4 not begun,5 assessment later. Fresh fetch/prune unchanged origin/main914f7cafcdbcfc1805a10f4f34167218341d5587. Related GGUF branch now openPR1469, UNMERGED, not assumed landed/incorporated. No taskcommit/PR/push/merge/deploy.

Catalog-read r2 independent gate0C/H/M plus SPECgovernancePASS. App owner implementing ownedrunner/codec/negotiation/realchildtests. Root added ModelCatalogRead.swift (parsedoptions/sharedmonotonicbudget/events), ModelCatalogReadCommand.swift (quick/verify orchestration, oneinspection, finalauthority+placement, completeinventory, responsepreflight), early readlease in ModelTransactionContext.swift, result-read/options/capabilities and shared helperbudget propagation. Capturedconfig validates original metadata/inode/ctime atfinalization without rereading/rebinding. New contexttest intentionally rejects replacement perapprovedcontract. New test-only actualhashprogress callback defaults nilproduction, no flags/environment bypass. All runtime additions pending fresh tests and independent combinedaudits.

Swift32 retention38methods failed4assertions in1newrecapturetest195.560s; healthycapacity15.368s/mixedhistory84.279s/legacy1024 fullyretiredwithin6of16passes passed. Recaptureassertion setup/order corrected. Swift33 compileFAILED inspectionowner scope/escapingcallback errors;fixed. Swift34 productioncompiled; testcompileFAILED privatecursorreference;fixed test-only viaactualJSONlastID. Neither33nor34 executedtests. Root preparingSwift35 coherent targetedrun.

ReservationR4 structuralfallbackplan approved0C/H/M SHA3bb911a0793f569226c9ca103e3607f9563e864fb688dbb5a57e0594d6071b21; review0a311a1aca39c60953943f43e47f6a2adc506bff736bddfe003fda69fb05ddbf. No v4runtime authorized yet. Smallerindexfixpasseshealthycase; durableowner implementingmeasurementONLY exact1024×4MiBprimaries, productionvalidorigins/records,6natural8scalls (terminal-last/queued-last), resourcebound12GiBfree/600ssetup. MethodSHA33e130ae641b711907eec4b5b5ec50e7953ce5093933ba7bd0ef4aa11a6f95e5 rootreviewed. Actualresults determine necessity, no fabricateddelay.

S2integration HTTP635 first-raceFAILED fixturetail races; actualafterProbecompletionbarrier fixed. Full635racePASS206.657s beforeadditionalexacthistoryassertions. Exactassertionmatrixrace active /tmp/build1-http-teardown6-final-race.log session31802, ownerintegration. Promotionowner newT01/T02 actualownerHTTP480nonracePASS14.358s; tighterhistory+racerunpending. Authorityowner T07simultaneousallowners8roundsdraft/testpending. RuntimeGo unchanged/frozen; finalentirecoordinator checks/audits stillrequired.

CLIbridge owner catalog_inspection nowowns NEWbridgefixturetests plusminimalBootstrapTests internalfixtureContext parameter. Two-phasepersistentfixture: actualsignedproducer input.json thenXcodecaptureactualstorecaller argv toapp-argv.json thenrealCLIparse/run samearrays/genuineFD199/200. Actualcontextinode/hash means nohand-authoredreplacementargs/dummycontext. Appownercoordinates. RootownsCLIreadtests/controlleasetestextensions and CLIimplementation. NoSwiftPM byagents.

Latest: Swift35 targeted27/0PASS35.118s (actual21s hash +13.417s fourreadlease tests), rawlog .omx/artifacts/build1-catalog-swift35.log. Exportphase with samecompiledbinary FAILED29.078s atactualcandidateevaluatecleanup0.2s port/groupheld; bridgeownerdiagnosing, input.json notready/appCR01skipremainsNOTPASS. Swift36 maximumshape measurement now running/compiling, session in live tools, log /tmp/build1-capacity-swift36.log; code testrestoredunderTests. RuntimeSourcesfrozen forpreliminaryindependentAstra CLIcatalogreview agent build1_catalog_preliminary; this is NOTfinalcombinedgate. App129targeted tests0fail1CR01skip reported, fullsuitepending. Integration667race includesnormal+fullqueuecloseSessionfinalsnapshot pending. T07allowners8roundsracePASS7.316s, detailedcountsownerreport. New source-specificexpirytestlaneauthorityowner; promotionownerProbeExpiresAtcases/T01T02all-signed480 pendingrace.

## Current Build 1 status after model-routing update

The user explicitly directed that all subagents from this point use GPT-5.6
Sol. The just-started Astra catalog reviewer was interrupted before producing a
review; new independent lanes use GPT-5.6 Sol. Earlier completed Astra records
remain historical evidence and are not relabeled.

Implementation is substantially present, but Build 1 remains incomplete. The
fresh consolidated admission teardown/readback matrix passed under `-race` in
212.263 seconds; no failure, skip, or data-race marker appears in the log. The
current catalog-read implementation has four unresolved Medium preliminary
findings and cannot enter final combined audit until its new correction plan is
independently accepted and implemented. Separate admission test-mapping review
also identified bounded coverage gaps that require final disposition.

Swift36 did not measure reservation starvation. It failed after 602.827 seconds
with `setupDeadline`, reaching 512 of 1,024 exact 4 MiB records at 550.186
seconds. No reserve-operation measurement call ran, so the failed setup is not
positive or negative evidence for the structural fallback. A test-plan-only r2
correction is being prepared before another run.

The corrected signed catalog bridge export freshly passed one selected test in
48.527 seconds after a 12.69-second build, with zero failures or skips. It wrote
`.omx/qualification/catalog-read/input.json` (29,079 bytes, SHA-256
`30d2efbb6d1dddeb257d13a4406880e29a01f8b653f67422b3acb6feabc96d94`).
Actual app argument capture and unchanged-argument CLI replay remain pending.

## Continued gate checks

Build1 remains in implementation verification. Transport matrix667 race passed230.274s; separate38 throttled retries passed12.414s. Native architecture lane checks exact T01–T11 mapping, including T11 persistence/closure axes; no final gate claimed. App652 tests0fail1 required bridge skip remains partial; final process fixes3 targeted tests passed. CLI preliminary review found4 Medium issues in missing-primary completeness, recovery inventory ordering, nested shared budgets, and actual-economics output preflight. Correction plan is being authored before changed runtime implementation. Swift36 maximum-shape measurement is still active; bridge export follows. Earlier export failure was signed fixture demand-row absence, now corrected in test data but not rerun.

Raw evidence copied to durable worktree `.omx/artifacts/`:
- `build1-http-teardown9-final667-race.log` SHA-256 `d979ec5667f862fa3e996bf065eea1f44ce55323655d968c55bc82fe338e6f32`
- `build1-http-teardown10-throttle-race.log` SHA-256 `f5c3b01d7491b97cd027443df9a807fd314a6a5cd32a0a651a70ebef1427ee17`
- `build1-app-read-process-final.log` SHA-256 `5b3229dcee1af041ce0821894141d88681ef5990485e1099c25d0b37cb37a8e9`
- `s2-owner-signed-final-race.json` SHA-256 `bab977a284d26aa09939652b0446b4fe9c0b33b87c15fb9acf65fbdf6039d765`
- `build1-source-expiry-race.json` SHA-256 `614843d754bd332d1d4b6d526fd295cc7402d91676e0b01de03991fcd0358ef5`
- `build1-owner-stress-race-final.json` SHA-256 `3516b48347af46959ac62dd5ea29c5efb7112c4fc845d1d7946d0d726e3fa969`
