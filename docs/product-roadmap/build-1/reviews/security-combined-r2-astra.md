# Build 1 combined security audit — R2 Astra

- Reviewer: independent native Astra high security lane; no runtime authorship.
- Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
- Worktree/branch: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, `codex/product-build-1`.
- Scope: combined changed and untracked Build 1 CLI/app/coordinator/contracts/integration sources against that base, with existing routing/receipt/recovery callers.
- Method: static source/diff review and supplied evidence; no reviewer-run tests/services or runtime edits.
- Status: **combined static security pass complete: 0 CRITICAL, 0 HIGH, 2 MEDIUM, 1 LOW. NOT a final gate or a zero-finding approval.** The two runtime findings remain open. Retention capacity scheduling and S2 test/private-seam work were explicitly still open at audit start. Exact final delta review is required.

## B1-SEC-M1 — MEDIUM — actual app arguments disable bound local activation

**Evidence.** `phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:2343` builds every catalog-economics invocation with `--ctl-socket-path paths.controlSocket.path`, then adds `--local-activation` when negotiated. In `phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift:500`, creation of the prepared transaction context requires `localActivation` and **nil ctlSocketPath**, alongside the other forbidden overrides. The actual app arguments necessarily take the nil prepared branch. Because local activation is true, modelsConfig also becomes nil rather than using the standalone configuration path. The setup, local actions, recoveries and final bound context all remain absent (lines 508–547).

**Consequence / threat scope.** The ordinary Malibu Build 1 entry point cannot receive the context or transaction actions needed to prepare/evaluate a model or enumerate cleanup recovery. This is a deterministic integration/availability failure, not a provider identity or payment escalation. The CLI's fail-closed override rejection is the intended security boundary; removing that check would weaken the fix.

**Required correction.** Make the actual bound app projection use only its fixed config/context authority, removing the redundant socket override, or explicitly specify and review exact captured-config equivalence if an override is necessary. Keep the standalone projection behavior separate. Add coverage that passes the actual app-produced argument array through the real parsed CLI command and asserts a nonempty bound context and correct actions/recovery, plus refusal of mismatched overrides. Direct CLI command tests and mocked app JSON responses do not prove this composition.

**Disposition.** Open. Root independently confirmed both producer and consumer and accepted a correction handoff. No corrected source has been approved in this report.

## B1-SEC-M2 — MEDIUM — timed-out projection leaves full-hash child work alive

**Evidence.** The new `DurableModelDiscovery.swift:33–36` calls `ModelArtifactVerifier.inspectCanonicalArtifact(directory:)` without a deadline for each exact prepared target. `ModelsSubcommand.swift:526` awaits that discovery before emitting the catalog projection. The verifier defaults to nil deadline and reads every file in chunks (`AutotuneRecommend.swift:4298–4375`); task cancellation checks cannot cancel an independently running CLI process when no cancellation is delivered.

The same projection then calls `makeModelCatalogLocalActions` in `ModelCatalogTransactions.swift`, which independently invokes `canonicalArtifactHash` without a deadline for each prepared target before allowing evaluate/adopt actions. Both full-hash paths must be covered by the correction; fixing only discovery does not bound this command.

The actual app read deadline is ten seconds (`ModelManagement.swift:1669`). `runCatalogRead` at lines 2303–2327 finishes only its UI continuation on timeout. It does not cancel the running CLI, reap it, or retain a request-wide child reservation. `MalibuModelCLI.run` at lines 1311–1401 continues waiting for the real Process exit. Its cancellation holder stores one weak current Process and does not serialize starts. After timeout, refresh reports projection_unavailable and permits a subsequent refresh. Fresh projection is also mandatory before a terminal transaction can clear pending state (lines 2149–2158).

**Consequence / threat scope.** Whenever full discovery hashing takes longer than ten seconds, the app rejects its eventual result. Repeated refreshes can leave overlapping full-model scans/CLI children consuming disk and CPU, and terminal transaction recovery cannot finish without a fresh projection. The control-helper ten-second lease and long-owner heartbeat watchdog do not govern this plain catalog-economics child. This is a local resource/availability issue; no remote exploit, measured physical-model duration, or payment/trust bypass is claimed. The source path is established statically; a slow-read runtime reproduction remains required.

**Required correction.** Define and implement ownership for the complete projection read lifecycle: bounded resource work, exact child cancellation/exit observation and no overlapping replacement child while prior work remains alive. Preserve truthful unavailable/incomplete state on expiry and preserve current full verification before readiness; do not relabel a partial or stale hash as verified. Ensure real model sizes can produce a usable projection through a reviewed design rather than merely extending the UI timer. Cover slow hash/resource reads, timeout then repeated refresh, exact child exit, late reply suppression, and terminal recovery after preparation through the actual app/CLI path.

**Disposition.** Open; a separate reviewed correction is required. Root confirmed the code path. This is distinct from transaction retention capacity scheduling.

## B1-SEC-L1 — LOW — incidental dependency lockfile pruning remains in the diff

**Evidence.** `phase3-binary/Package.resolved` removes 15 pinned transitive package entries without a corresponding `Package.swift` dependency change. Root confirmed this is incidental SwiftPM pruning and that no dependency change is authorized or intended.

**Consequence / required correction.** This adds unrelated dependency-resolution churn to the reviewed release diff. Restore the exact HEAD lockfile after the final Swift runs and exclude the restored churn from the final source manifest. No dependency upgrade, malicious package, or exploitable supply-chain change was demonstrated.

**Disposition.** Open cleanup acknowledged by root; no reviewer runtime edits.

## Prior security findings and current limits

S1's retained-route recovery integrity correction was accepted only for its bounded six-file billing snapshot in `go-security-s1-r3-astra.md`. Ordinary route UPDATE is protected by the existing immutable SQLite trigger; negative corruption fixtures intentionally bypass that trigger only in disposable databases. No provider remote mutation was demonstrated. The whole-route-missing case with retained verdict now fails closed, while genuine no-route/no-verdict legacy stays compatible.

S2's promotion authority work is under combined review here. Inspected code pins exact session publication/closing state, pool identity/exclusions/sanction state, feed and billing generations, settlement config and Tier2 material through serialized decision durability. Positive status readback rechecks latest event and current authority. Test/private-seam work remained ongoing, so prior S1 acceptance cannot establish S2 or combined acceptance.

Fixtures with signed feeds/receipts and real local services are useful composition evidence. They are not physical MLX measurements, production deployments, or the unresolved hardware journey.

## Audit-start source inventory SHA-256

This captures every changed/untracked file under runtime/test/spec roots at audit start (112 files). It identifies the starting review inventory, not a claim that concurrent later edits were reviewed or a substitute for the end-of-pass source comparison below.

```text
3214cee41e5fb4ec7c26164b4536688bc6f2287b3323d490beb9283a5e7c9562  phase3-binary/Package.resolved
f9605c97d5728634492c7aaaebfeac52bc184ae00546640e79072464bdf4d994  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
91fd91b8d769a5bd50a7ac3caa80eb30b63f8fbd0fb12081cbdc074bf7684df9  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
e6f4dca9377bcafb6fb16e75c669ad9430422e4d1e332192a6dfbd544b4aab4e  phase3-binary/Sources/macprovider-cli/BYOMPendingOfferJournal.swift
42f1c3ed58d2200cdfa92965895348432bfe4f064716e208051e8df6b58f6241  phase3-binary/Sources/macprovider-cli/CandidateParentLifetimeGuard.swift
263c61fff359c3e4c11cf188918dcbe9af800590642095c42eeb40f24b0de268  phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift
0e0745c05c681895dbc8b18c0898259bb92c31ea4e55de536bc3c5de2696fa0b  phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift
e7f5b9da2ec4be6ab9baa7713318fc34a0524c8796de42c116f4901e53a7f3a6  phase3-binary/Sources/macprovider-cli/DurableModelDiscovery.swift
921bd69a4da1b8b72e51da9de0a9953d742f7f4c5367ebaf649ccbe0b3205d04  phase3-binary/Sources/macprovider-cli/HTTPServer.swift
c240942ca1a32720c1292ae534b688ec49fb66cd6cbde82e04123d5ab39c8e70  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
3e7ac61544517c306bb0b21fdf4ebcad53d6dc53ce5a86cb1b781c14f7a02396  phase3-binary/Sources/macprovider-cli/ModelCatalogArtifactSeal.swift
397817cebf43cd56b6c6e007d679e8ea22b9de3bc4b61a840b6845040aff06b7  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
ea320282dc712518936efa88eac0e4b28bcf232dda738739609b7678e3c8d0aa  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionArchive.swift
923493e28d749859f686d2cd0b2af4d2735c7f8546bd80bbfe28d2f3816464b5  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift
df84197a779b94cde8ab6cd51ba5678d8888304a0ca92d16af202b7dfcd92d15  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift
afede2efc30cb131643ed188e4ce660d42395beed765382768eb52618e5ac5ba  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift
224ae2eb6245076a15ff4d0f2a6ac56ecacf5734ee43d5575798a6abc9ec757b  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift
3fdf995460882e8752016aa0679fcdb7668e484d5433b14ec6e74dcbe53d52bc  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift
04bc959b8317fb94688b02e325817c143c47f1ae1b73f5767ebb25d40745e93e  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
b02a178be9fa36c0c27487e972717d90dd4c724d76006ca9d5729114f371301c  phase3-binary/Sources/macprovider-cli/ModelCommandExecutionContext.swift
dc5a867aaab1fc85b1e4822a9c3c9ffed16b3a701f94e4add79466d78f548377  phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift
5d794a9aa75a6172b0c4a7c4f68be96e432ce34788896b3d80bbd7ec0b6de71c  phase3-binary/Sources/macprovider-cli/ModelTransactionOwnerLifetimeGuard.swift
23a5bfaf95b99fa0b3e11d810d5ad1a7c03434d05e343c877a0e86d632342f7e  phase3-binary/Sources/macprovider-cli/ModelsAdmissionRetry.swift
01d1a5a54ca96a6cbae7fddb8e7a22bb46dd00db396acf7411feef90e309230f  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
81de37151afb80fd95c047bfb819442c80b10cd2c69c0c4d6132eba237efaabb  phase3-binary/Sources/macprovider-cli/RecommendationAdoptionJournal.swift
c2ac8d7b98887b2209100bd9e800a13d4a6fa7cedd57a7b2102e11239d08398c  phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift
8f6f215e68d1e41c95c036cfa48738059b14e6e116946533845db416d1fcdb41  phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift
aac1bfba84cf2b8f0aa3e0058364a9aa07d456e69db2219ac8f55373863c8751  phase3-binary/Tests/macprovider-cliTests/BYOMPendingOfferJournalTests.swift
7cbf20be076a163647156af881a368487199f8104138e547f540dbde2ced938d  phase3-binary/Tests/macprovider-cliTests/Build1CommandBootstrapTests.swift
1abc95e845aa825ea61299315326a5af15bbd3c0659e9b7d2cb68cd0cce3bd15  phase3-binary/Tests/macprovider-cliTests/Build1CommandFixtureInputs.swift
dbc19b10d7dd7dbeaa5e8ec2cac7cc72953b63119e2cdec92dc755959cb76fd3  phase3-binary/Tests/macprovider-cliTests/Build1CommandFixtureInputsTests.swift
5158189f74f395e1e65bfc5f91347b9c6d56aadb1164562198c641b1e9d3aefb  phase3-binary/Tests/macprovider-cliTests/Build1FixtureProvider.swift
18a932288985143d2819c8e18181715b2e171c8ebae4bce76bd39b5277900511  phase3-binary/Tests/macprovider-cliTests/Build1LocalServiceBridge.swift
8a836f9cc117a0e9bcee9504ceb090d630fa831b213f151a0a4b43a8fb6890b6  phase3-binary/Tests/macprovider-cliTests/CandidateParentLifetimeGuardTests.swift
f2475fd2bf2ea0fa0157b77f0f3afabbe6a2b495e37ec7393b24a6366d9c29a5  phase3-binary/Tests/macprovider-cliTests/CandidateProviderRunnerTests.swift
18026e88030413d4fa057e70c16c7c04e593fe6dede4ac0674132db1525af3c8  phase3-binary/Tests/macprovider-cliTests/DurableModelArtifactStoreTests.swift
4f5044289ec115f836471b1d7f5514a0ca4e4320d1dbedb1c58c7c980b218b56  phase3-binary/Tests/macprovider-cliTests/DurableModelDiscoveryTests.swift
9163f417f44d929c7c9e3d378ebe687fb6ab339454e61d00ecc5b7e236a6dbfd  phase3-binary/Tests/macprovider-cliTests/ModelCatalogArtifactSealTests.swift
ba5b7b981d2c4c45f37dfdf22b5c41e53b1b6cbf31f424847613a25317e77a54  phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift
84647cb28c20dead2718d1ad99d6655eae4f9df8b9cd7d10c9b96a3f94c4c2b8  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionFixtureWrites.swift
c37096a3893e8084c453ece62f4ff02aacd23bc5b08c2494e437f1a5f5f5a0fc  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift
c28666e1cd88f357d98c08c44c5b9eb5899a856a0b080c18fc387a4c645f8ff0  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift
2cde36eceb49607eb206784abbc069ed6b50a3668dc16a938f69580ee2c64878  phase3-binary/Tests/macprovider-cliTests/ModelTransactionContextTests.swift
987400238cfdcd468c69dcebbfcc60f144069dc2b6b146801e8f2083b146a5ae  phase3-binary/Tests/macprovider-cliTests/ModelTransactionControlLeaseTests.swift
030fe5233568833323ab0f45cccd97eaae7af4f4299a33cc73a0b7c2339207ef  phase3-binary/Tests/macprovider-cliTests/ModelTransactionOwnerLifetimeGuardTests.swift
1c604ca805bb14f091db33d438f72eb26e25b8b696c9864c99fc4e2abe215219  phase3-binary/Tests/macprovider-cliTests/ModelsAdmissionRetryTests.swift
6b21e2d710f237287243a8400332dcd151fb0f00d03e31da8cefba61986474d1  phase3-binary/Tests/macprovider-cliTests/ModelsSubcommandTests.swift
a19619c4450d208c9950132059726a1421785653a9442990382393ff8170628a  phase3-binary/Tests/macprovider-cliTests/RecommendationAdoptionJournalPathTests.swift
12505b4c3acfc38ac14b393e97a8cc26e642da7d2e77114d6e9b78ae24b5a9d5  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
d58e93591efd68cdfdc36818e5cac84cbe23e4140f07074ae060033d2f1d7d98  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift
5a98a8d2e963a97789514adef788298b5fc966e7e6aef6605819bbbddc359398  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionControl.swift
0caefc0546bc5433ae718fed718a0aafa0da31417224b113000fa25419facb6c  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionPayload.swift
f11ecc5074ffc7f8bbd617e3f7c5872778c0ea861acf4a733e62c20d5d1c3a4b  phase3-binary/app/Sources/Malibu/ModelManagement/ModelTransactionRequest.swift
5314cf4664e3624f0740b0032f19db2c50cdfbacbcd15672c006277322fdc602  phase3-binary/app/Sources/Malibu/ModelManagement/RecommendationManagement.swift
ed349d9b79104fea56863db7b476f2e7086ece83203c32b71e19c3ab7144ff58  phase3-binary/app/Sources/Malibu/Resources/MalibuFeature.xcstrings
0651a6561ca428d1e8a404c6cac7351423c24af24c9b0d5e1b9b3a6c136e8227  phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
dc94845a00212cd25a2ce8f2a45d4861ac70d92d125717d50224ea27041c0517  phase3-binary/app/Sources/Malibu/System/InstalledProviderMonitor.swift
c88fd0644c37fb29572bdbf51739d565e31cb288c9a5f292208a4b6a02709b73  phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift
31e78d166f9e5313e25b510b91eca4763fc16757c8e40ffedf18391a8c52e1f2  phase4-coordinator/cmd/coordinator/main.go
10825911f104422c290eb248022d77ecde936fe2f342a4fe5d22a3da5d7c5896  phase4-coordinator/internal/billing/artifact_admission.go
db468bd2a062b54f1205f0fe2c5d77455fefe86ad116abd640a86c59dfb5244a  phase4-coordinator/internal/billing/artifact_admission_test.go
2c6228c2e97b15e6a1c3ee7b4db6c14270787a65a089df52f9092a4018b7b05b  phase4-coordinator/internal/billing/quarantine_test.go
95c68af6ea5bbf11df33e57e8ff6060d7bbc118ea6b277c3dd5a2d1dda59e3ae  phase4-coordinator/internal/billing/recovery.go
2cc705c4a1f4137cc25b22aa317ddf30f303a7c27bae8bb221a8d8fef53d2597  phase4-coordinator/internal/billing/route_snapshot.go
513a494dac0d40ba4e2dbebff7403e3bf79965dc84e9cadb78517767882c98d5  phase4-coordinator/internal/billing/settlement_config_guard_test.go
3045601f3ecb054788a84e0e724c64d5e9da082236d6cead1288fece13effb78  phase4-coordinator/internal/billing/settlement_receipts.go
948fbf20898caa962476c80b33cf6c9002fafd61b46749002edfccdb4114384c  phase4-coordinator/internal/billing/store.go
d3b38484d8a932ca12ccdf2fff1c1039f5a17ddc09614fd33e8567a52ebe391c  phase4-coordinator/internal/buyer/autotune_feeds.go
89d2672ca3237399619e8878c1e85bbc42ffd51b8a54cac74e72dca2aab63858  phase4-coordinator/internal/buyer/billing_recorder.go
5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549  phase4-coordinator/internal/buyer/model_admission.go
aa568bb750e4387e8f1f6b35305b7e5fee32c8ec0bf7431c58020fcfa4b05b15  phase4-coordinator/internal/buyer/model_admission_authority.go
c1d22a2a145250057d47728b5e84a6fc8c84d451764769f86de8fbd06fffd3ca  phase4-coordinator/internal/buyer/model_admission_authority_test.go
93367426a48dded21057484c19413075fdbb6189fab07cbb82bee82adbbb1200  phase4-coordinator/internal/buyer/model_admission_guard.go
135b0038e30f093d6aac9dbd798eb9fef54488017dd982e0b18219fcc5c9d7b3  phase4-coordinator/internal/buyer/model_admission_guard_additional_test.go
09242070eca6cebe3cd732829b9d14df3a9ec3d06f4a762ef08746d1b329d73f  phase4-coordinator/internal/buyer/route_snapshot.go
4f3b330034bb681af0189054ff7a488da34566d148aa118c4b14247ceb798d0d  phase4-coordinator/internal/buyer/server.go
82dbf9d6347feb66631517aa5f624cca566066834579aaaadf6061fcd15ff39d  phase4-coordinator/internal/pool/model_admission_guard.go
d41a0f99e1c689ed5b87a85e15fd3b02823ba3038e001acdc1190c124c3e28e7  phase4-coordinator/internal/pool/model_admission_guard_test.go
ae5bf954eebe696966aa31aeced01e35f572866d33c264fc0d9d1f4cdfe1e4a2  phase4-coordinator/internal/pool/provider.go
9185b925a1c42e981d9cb42ffc7f6ced5e7cca9ea827df7374ecba38c31fab18  phase4-coordinator/internal/tier2/catalog.go
89e26e7f95a98569d3e195126bef510c133f4e00e4317bb211e4812c9c797b21  phase4-coordinator/internal/tier2/model_admission_guard.go
9028fcc113ed9786208a855b24ab016676490ff50c3109ea2f031590a40ae5d6  phase4-coordinator/internal/tier2/model_admission_guard_test.go
101fce3f1c2ceb9511700f59b0ab1c98c3ec5f1aee10bcd1097ec79aa38157e7  phase4-coordinator/internal/ws/admin_endpoints.go
b4862c66aeb9f76a853c8fece8e697d83ffb66df62ab0c0324a95d56ddd0e18b  phase4-coordinator/internal/ws/admin_hardware_trust.go
0dcdc86a7856d5c901d2eba14497e5e7fe9ea83096524e97d2eff79a20291f4d  phase4-coordinator/internal/ws/admission_canary_harness_test.go
5ea9af7dd2035b6ff1d9dde57ad3bc143d68ed5b95fa24b90be8436271d884cd  phase4-coordinator/internal/ws/admission_ceiling_drift_test.go
29ccde75f132363c31f0a306bf5dcf7ca4cf56b2f0302a92fb4706633d48363b  phase4-coordinator/internal/ws/model_admission.go
4a9fd8ff1f2dfc5bc2ce20305d3138b179dda68cfc6d61eca8939455110c85d1  phase4-coordinator/internal/ws/model_admission_authority.go
6019b4f0d05767dc719cc993b681a2203c718060c1b62e3c98816a405580b86c  phase4-coordinator/internal/ws/model_admission_authority_test.go
60888730c37460325b1195f0859d37a9fbaa6cef092ad703a3c5e7d9d7fb9fe0  phase4-coordinator/internal/ws/model_admission_commit.go
dbad7d6814806cd43c1deb7a8062e7f0c8968f90c5cfd2d551bc7ed1c54c0e3a  phase4-coordinator/internal/ws/model_admission_commit_boundary_test.go
d61e6dde5b4f0f3f320439d87150b62c265eab7788627d3e22aa018a574dfb8c  phase4-coordinator/internal/ws/model_admission_guard_test.go
544a83057993ae3a256a0b76fceda9f13d1df02c968fd0533a41c3718dbb50b2  phase4-coordinator/internal/ws/model_admission_probe_test.go
7a50600bab47602180b09eb99a6e4158cc7d4b7c042bca5187477d42f3c8a229  phase4-coordinator/internal/ws/model_admission_retry.go
e551eac5f7f0085c080f2c8841fda318203cd42ddff0bf35e8f54d70adc3a692  phase4-coordinator/internal/ws/model_admission_transport.go
7bac6834d4dfb57111a3ac4ce1a85bc622870894eb29a0aa37a4865627efa38b  phase4-coordinator/internal/ws/model_admission_transport_test.go
4bc56dc79f4eb0f691e5425295b34eac4a5323cb72e1c7f466e4c4ec3e02f1d7  phase4-coordinator/internal/ws/relay.go
ff38f9a545c08e2705f90c07326342040723675a7b6e3b77bcd150ed287f4299  phase4-coordinator/internal/ws/server.go
bdb403ae37919b7f9c7a8472bdb9661977c7e2de4e6839c411e7811419ce63ed  phase4-coordinator/internal/ws/spec032_strict_admission_matrix_journey_test.go
228c4e82feb98b8c993e4e2d5035ecdc1046b4cf4bfa013dd7a248774f387962  phase4-coordinator/internal/ws/trust_revalidation.go
9d75f45f4739fe1d81921bb43fa629335967a12a4e165875469aacea4b628432  phase4-coordinator/internal/ws/trust_revalidation_test.go
89f2eaccc8d380a0e79ee99930d704f04894391e9b749befa249650d712c4f7a  specs/CONFORMANCE.json
a151ad8eac3a8fbd449fc82cdbe01a85de178e5aa609a9a514cbbe1999f9f397  specs/README.md
952fb91808fca6784823970ed07ed75621622509e5abbdd51e8df5441bca12aa  specs/SPEC-001-phase3-binary.md
d9b3542a3226ad50280af4c1f7bb956847a7c471a9806471901834bbfa1ea5e8  specs/SPEC-044-malibu-model-catalog-economics.md
56ef0c44d6865821a74eee9cb20486358d71fba27ecc4cf6753927d00e504244  specs/SPEC-047-network-model-admission.md
726a3cc640fbca368314dd14995b90597ed6f5cfd237d11905da201a1e9dba6e  specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md
405a32ab227798ec05f619e2a3e57f9227f172ed955b65b18ebc1743142c60f0  test/integration/build1_artifact_journey_test.go
83c8b28ef0078b15b2d6a16a8d3b3c098fbee4a1414feec88b9d444575eb4551  test/integration/build1_cli_bridge_test.go
873bb97c04c3a7243ab55c54e037c2188a99c0966d325ddf1e8ab1bcc46c3fd0  test/integration/build1_closing_route_test.go
8114ef52d6522d1888c49be407ca1a612ac1849ef2d55b261318830b546c3cac  test/integration/build1_transport_test.go
db64abc20609af21c9c3769316d38df83f9c3562f7273ad48984b0f714f6dfdf  test/integration/harness_test.go
```

## Combined boundary assessment

The review followed the complete changed runtime flow, with targeted adversarial inspection of its tests and existing callers. No additional supported CRITICAL/HIGH/MEDIUM issue was found in the inspected admission, pricing, route, receipt, retry-journal, transaction-evidence or executable-custody paths. This is a static finding count, not a claim of exhaustive input coverage or reviewer-executed tests.

- **Identity and economics:** provider offers, discovery names, local preparation and measurements remain advisory. The coordinator resolves the exact primary model/hash/algorithm against signed candidate/artifact release and signer, current provider/session identity, qualified Tier2 material and independently loaded billing configuration. Explicit prompt/cache/completion rates, multiplier and provider share are captured; provider-proposed prices do not replace them. Missing/stale/cross-release/wrong-signer evidence fails the positive path.
- **Promotion and routing:** the guarded memory/SQLite decision paths acquire serialized authority after database acquisition and hold it through decision durability. The inspected guards pin resolver/session publication, exact session closing and identity, pool exclusions/sanctions, feed/config publication and Tier2 material. Local close producers publish monotonic closing before delayed transport teardown. Buyer default, pinned and queued selection recheck exact-session availability, including when status revocation persistence fails. Latest positive readback checks current authority, rather than replaying an old positive as current truth. Concurrency tests/private seams changed during this review; final evidence remains separately required.
- **Accounting and recovery:** route digest construction preserves legacy encoding when the extension is absent and binds the complete extension when present. Captured rates/config are validated against artifact evidence and used for the attempt. The corrected reader verifies an existing full snapshot before legacy dispatch; whole missing route with any retained receipt verdict fails closed. The uncached receipt path validates before usage/credit mutation. These corruption defenses supplement the existing immutable route trigger; they do not demonstrate an ordinary remote provider mutation route.
- **Local evidence and authority:** a captured fixed configuration and pinned private stores determine the opaque context. Original operation generation/origin, immutable success/result/seal commitments and retirement certificates are validated rather than reconstructed from current artifacts. Historic publication metadata does not claim current full-hash readiness. Generation-less legacy history does not gain new action authority. Retry journaling retains the original signed envelope before transport, requires current matching identity/readiness, and preserves undecodable unresolved evidence.
- **Process and parser boundaries:** bound transaction control validates the signed configured executable and complete private resource snapshot, fixed context and exact selector/generation. Pending records do not authorize an arbitrary executable path or a restored PID kill. Snapshot disposal uses a bounded safe subset separate from complete execution validation. Closed wire parsing and size/path checks were inspected across admission, projection and transaction surfaces. These protections do not govern the plain projection child identified in M2.

The normative basis includes SPEC-047 R001/R003/R006/R007/R008 (current coordinator authority, serialized promotion, immutable route/receipt provenance, mutation authentication and evidence matrix), SPEC-044 economics/local-action separation and transaction custody, and SPEC-001 transaction history/control/retirement requirements. Plan r4, test-spec r4 and the approved addenda listed in the gate log were used as constraints; their approval does not approve this implementation.

## Validation evidence and limits

No tests, builds, services or physical inference were launched by this reviewer, as assigned. Prior supplied coordinator/gateway, WS/buyer/billing race and actual-service fixture results are useful evidence for their respective snapshots; none establishes later source or test deltas automatically. The parsed Swift/service fixture uses deterministic model bytes and fixture inputs, invokes actual parsed commands and real local admission/receipt/ledger services, and checks the expected 20 buyer / 16 gross / 14 provider accounting. It constructs its own CLI arguments, so it did not catch M1's actual app composition. It does not establish physical MLX inference, release signing/resource acceptance, production qualification or B1-T10.

Inspected concurrency tests cover pre-insertion expiry, exact expiry, post-insertion rollback/panic, post-commit expiry/readback, pin release, database wait without authority pins, both promotion states in memory/SQLite, actual close/scheduled-close producers, and route rejection before revocation. They also include a test-only buyer bridge into actual default/pinned/queue/selectProvider paths. Final S2 negative coverage and race logs must be assessed against the final complete test/private-seam snapshot, not inferred from the source design.

The remaining required review is the complete combined delta after M1/M2 corrections, retention scheduling changes, final S2 tests and incidental lockfile restoration. All three final audit lanes and the expressly required acceptance evidence remain open.

## End-of-pass source comparison

The audit-start manifest above remains the exact runtime snapshot reviewed: **no runtime source byte changed at the end-of-pass comparison**. The ending inventory has 115 files. Five pre-existing test files changed and three test files were added. Some current test bodies were inspected as described above, but the following concurrent deltas are not represented as a completed final test-coverage gate. Their current SHA-256 values supplement the starting manifest; unchanged files retain the hashes above. After this comparison, root amended SPEC-001 for the independently approved active-index receipt design; that normative delta and its future runtime implementation require final review and are not approved by this pass.

```text
6039d85db7aaf3464150135e81cd10c585c98a1c0cfd14051d97d21bbb883cb4  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift
1f7c42dc6c36ba47614cbcc28c0e2c3416aef84cbe406ac5839553c767c7cf13  phase3-binary/Tests/macprovider-cliTests/ModelTransactionControlLeaseTests.swift
2214a94b06fd44c07eb3b22f992580914ccf409056bef90c61ddcb42ab69ea4a  phase4-coordinator/internal/buyer/model_admission_route_export_test.go
02da2eb0481a46b9937dd8d258284a86390055c57cd2aa32de492cd6e797e15f  phase4-coordinator/internal/buyer/model_admission_transport_authority_test.go
8d30d91148ec4cc79eac1284f252ef3a9bbfe0219e0670b876d518ab435a0980  phase4-coordinator/internal/ws/model_admission_guard_test.go
38f2452ff4a4641ed7cfacc17c441ff2df3c3b7c5649d4a23ac08ec7275bb6e2  phase4-coordinator/internal/ws/model_admission_readback_race_test.go
4360b032dc9cf729fcafdfd57f507ee3cc8f17781179aecb4480e9fa13d50acf  phase4-coordinator/internal/ws/model_admission_transport_test.go
b6f228949247146076270b4091cf570f70a4048510586bbedd0c825a99bbd885  phase4-coordinator/internal/ws/trust_revalidation_test.go
```

This comparison includes the pending Package.resolved churn because it was still present at observation time. Root has committed to restoring it; the final manifest must be regenerated after that restoration.

Closing contract/document observations (the new SPEC-001 active-index receipt delta is explicitly pending review):

```text
aa00cd438460244c127c2110b2a54bcf9fe0b493d455db59bcd48c792446b08d  specs/SPEC-001-phase3-binary.md
a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d  docs/product-roadmap/build-1/plan-r4.md
20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be  docs/product-roadmap/build-1/test-spec-r4.md
2bb39f87ea43de5ce6296e4a385cfee6019eafe1003b39c11a60f9058687f9e5  docs/product-roadmap/build-1/reviews/gate-log.md
```

The app owner has produced catalog-read-lifecycle-addendum-r1.md for M1/M2. This report does not review or approve that separate plan, its implementation, or future evidence.
