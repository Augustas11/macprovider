# Build 1 full architecture review — r1 Astra

Verdict: BLOCKED — preliminary snapshot. 0 Critical, 0 High, 4 Medium, 0 Low.

Base: `914f7cafcdbcfc1805a10f4f34167218341d5587` (same tree as the approved dependency). Review covers tracked and untracked Build 1 implementation, specs, and tests, with the approved plan-r4/test-spec-r4 and retry/storage/corrupt-journal addenda. Other agents were editing during review. The manifest below records the final read snapshot; a complete correction/delta review is required before a clean architecture gate. This review makes no physical MLX or production qualification claim.

## M1 — Draining the incumbent removes the authority required to cancel its measurement transaction

Evidence: `ModelCatalogTransactions.swift` recommendation starts `ProviderDrainer` and drains the launchd-managed incumbent; `ProviderConflictDetector.swift:222` implements that drain as `launchctl bootout`. `ModelManagement.swift` sends transaction cancellation and status through `MalibuModelCLI.run(peer: peerEvidence)`. Its `resolveExecutable` requires a fresh live peer, a running launchd Program path, and a matching live service PID/code identity (`ModelManagement.swift:1331–1370`). `refresh` replaces peer evidence during the pending transaction, including unavailable evidence after bootout.

Consequence: the intended running measurement has removed its own app cancellation/status dependency. The displayed cancel action fails before spawning the CLI, even though the UUID journal remains cancellable. App restart during drain has the same problem. The 30-minute owner deadline is not an acceptable substitute for explicit cancellation. This breaks plan-r4 bootstrap lifecycle and B1-T03/T05/T14.

Required correction: a narrowly typed transaction-control API for status/cancel/result, with launch-time verified executable custody retained across app restart. Capture and atomically persist the original verified code identity/CDHash and UUID/target/kind/config binding before launching the transaction. Resolve only the existing trusted configured-provider executable path, revalidate signature and unchanged identity, and enforce exact command/binding allowlists. Do not accept a saved arbitrary executable path, a different config after symlink retarget, or a broad nil-peer mutation fallback. Missing custody, replacement/invalid signature, and mismatched UUID/config must fail closed with explicit recovery status. New prepare/evaluate/adopt/offer still require fresh live-peer authorization.

Required tests: cancel/status after the incumbent disappears; cold app restart while it remains drained; same verified executable succeeds without live PID; substituted binary/signature/config/UUID/target/kind and disallowed mutation commands are rejected before spawn. Review the focused control-custody addendum independently before implementation.

## M2 — Terminal admission states have no executable app recovery path

Evidence: `ModelManagement.swift:1911–1916` makes `canRequestAdmission` false for revoked, withdrawn, and offer_rejected, and reuses it for submission, retry, and status refresh. `ModelManagementViews.swift:305–321` disables all three buttons using that same predicate. Coordinator `modelAdmissionProviderTransitionAllowed` explicitly permits fresh offers from these states. Artifact admission's ten-minute probe expiry can produce ordinary route-time revocation (`buyer/model_admission.go`).

Consequence: a routine authority expiry or terminal failure leaves the active prepared model with all admission/status controls disabled. The app cannot perform the server-supported fresh re-offer or even refresh that admission. This violates actionable recovery and makes the completed bootstrap journey transiently usable only until revocation.

Required correction: separate read-status, new-offer, and retry predicates. Permit readback for terminal states; permit explicitly confirmed fresh offers from the server-supported initial/terminal states; permit exact-tuple retry only for pending states. Keep coordinator sanctions, current-key checks, fresh evidence, journal reconciliation, and state CAS authoritative. Do not automatically withdraw or retry revoked state.

Required tests: terminal-state readback, confirmed fresh re-offer, pending-only retry, and active-to-revoked expiry followed by executable recovery controls.

## M3 — Retry ignores the configured admission identity store

Evidence: `ModelsAdmissionRetry.swift:49–60` builds `BYOMModelAdmissionRuntime` with the configured credential factory but omits `identityStore`. Its initializer defaults to `KeychainReceiptKeyStore` (`BYOMDiscovery.swift:1822`). Offer/status/withdraw explicitly pass `ProviderCredentialStoreFactory.receiptKeyStore(for: resolved.config)`.

Consequence: a file-isolated provider can submit an offer but cannot retry using its configured admission key; retry consults the operator default Keychain instead. This breaks config ownership parity and the explicitly isolated B1-T11/B1-T13 journey. It can also select a different identity and be rejected after a misleading pending-offer workflow.

Required correction: use the same resolved-config identity factory as the other admission commands. Keep retry's discovery matcher freshness behavior aligned with the shared command matcher rather than bypassing warning gates.

Required tests: CLI/runtime construction with isolated configured identity storage, restart of pending offer, unchanged protected tuple and fresh signature, and proof the default Keychain identity is never consulted.

## M4 — Catalog polling eventually exhausts permanent transaction reservations

Evidence: `ModelCatalogTransactionStore.reserve` counts all JSON records and throws at 1024 before checking reusable reservations. It reuses only unstarted records younger than 1800 seconds. `makeModelCatalogLocalActions` calls reserve for available actions for every supported target on each catalog refresh. Neither reservation, completion nor staging cleanup reclaims expired reservation records.

Consequence: routine catalog polling creates new abandoned reservations every half hour (or on feed identity changes), until every new prepare/evaluate action becomes permanently unavailable. Even valid reusable reservations become inaccessible at the cap. There is no supported recovery command to reclaim this quota, so bounded storage becomes a permanent usability failure.

Required correction: introduce a bounded, lock-protected reclamation policy for expired never-started reservations (or an equivalent bounded reusable reservation pool), and check valid reuse before enforcing new-allocation capacity. Preserve active owner records, unresolved cleanup, committed publication/recovery evidence, and usable measured recommendation results. Do not delete arbitrary journal or artifact paths to recover capacity.

Required tests: repeated refresh beyond the reservation lifetime, at-cap valid reuse, expired unstarted cleanup, and preservation of started/active/recovery/usable-result records and unrelated files.

## Architecture observations and evidence limits

- The core split is appropriate: exact signed primary identity permits local preparation; an existing measured candidate runner produces adoption evidence; provider-signed offers do not mint paid authority. Coordinator promotion resolves current session/feed/rate/reference/receipt predicates and uses expected-current-event append guards.
- Captured artifact/candidate digests remain distinct from the Tier2 catalog digest. The additive optional route-snapshot extension binds explicit rates and billing-config identity; legacy snapshots retain the absent-extension path. New settlement uses captured authority rather than today’s mutable feed.
- Corrupt retry-journal withdrawal intentionally preserves unrecoverable bytes and blocks subsequent local replacement. This is an approved explicit limitation, not recovered authority.
- Fixture integration evidence establishes real service transport, SQLite persistence/restart and accounting, but not the complete executable CLI bootstrap or actual MLX acceptance. Public artifact feed unavailability and absent qualified physical reference evidence leave B1-T10/B1-T11 physical claims unproven; Xcode 16.4 release qualification is separately absent.
- Package.resolved currently has broad pin removals without a manifest change; ensure generated build-state churn is excluded or intentionally justified before final snapshot review.
- This lane performed source/contract/test inspection and cross-file execution tracing. It did not rerun suites concurrently with author/lead verification and does not count their results as independently executed here.

## Snapshot

Captured UTC: 2026-09-10T06:17:47.905372+00:00

Manifest SHA-256: `5f676fa3e500f41b983633ff09b0e6272c8897cbb773ff66c4ccc18770ae6e1a`

```text
3214cee41e5fb4ec7c26164b4536688bc6f2287b3323d490beb9283a5e7c9562  phase3-binary/Package.resolved
e39be672187ab91fe1331c55a6de7579141f1f7ec945482c5ab6d995cddb1d7e  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
91fd91b8d769a5bd50a7ac3caa80eb30b63f8fbd0fb12081cbdc074bf7684df9  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
e6f4dca9377bcafb6fb16e75c669ad9430422e4d1e332192a6dfbd544b4aab4e  phase3-binary/Sources/macprovider-cli/BYOMPendingOfferJournal.swift
42f1c3ed58d2200cdfa92965895348432bfe4f064716e208051e8df6b58f6241  phase3-binary/Sources/macprovider-cli/CandidateParentLifetimeGuard.swift
30e760c9caf91eef949ed223c8be8b0a67f21015d291ecd0ddec93883701e514  phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift
a4d7c212e1ab5697c240b899f71a09e377ec7bafe5fee6ae8cbc87a1d184a94a  phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift
e7f5b9da2ec4be6ab9baa7713318fc34a0524c8796de42c116f4901e53a7f3a6  phase3-binary/Sources/macprovider-cli/DurableModelDiscovery.swift
921bd69a4da1b8b72e51da9de0a9953d742f7f4c5367ebaf649ccbe0b3205d04  phase3-binary/Sources/macprovider-cli/HTTPServer.swift
c240942ca1a32720c1292ae534b688ec49fb66cd6cbde82e04123d5ab39c8e70  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
31ccee1efc22b153e78ef70dd1e652d362d407de199449ef4ad174a95845533f  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
a271127c23fdd9a0be37b4e3a4d56172b288726b2f2c5e7570d43f708669a3f5  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
db8d5f70e9a4fa3aa12141f62de510d4d4dd677f1a091f365a881ad10f4a54cc  phase3-binary/Sources/macprovider-cli/ModelsAdmissionRetry.swift
8fb190b38dfda46a03315fe64a4404e60a8cb07c3d6568de3124850b2d55ccc5  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
c2ac8d7b98887b2209100bd9e800a13d4a6fa7cedd57a7b2102e11239d08398c  phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift
8f6f215e68d1e41c95c036cfa48738059b14e6e116946533845db416d1fcdb41  phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift
aac1bfba84cf2b8f0aa3e0058364a9aa07d456e69db2219ac8f55373863c8751  phase3-binary/Tests/macprovider-cliTests/BYOMPendingOfferJournalTests.swift
e85544b852d9083d7eb581539dc9307f1d55bd7a47549fc7683d4469650c6837  phase3-binary/Tests/macprovider-cliTests/CandidateParentLifetimeGuardTests.swift
18026e88030413d4fa057e70c16c7c04e593fe6dede4ac0674132db1525af3c8  phase3-binary/Tests/macprovider-cliTests/DurableModelArtifactStoreTests.swift
4f5044289ec115f836471b1d7f5514a0ca4e4320d1dbedb1c58c7c980b218b56  phase3-binary/Tests/macprovider-cliTests/DurableModelDiscoveryTests.swift
1a452feafbe8d350444d0a837d3fab6d67f11169f28ae9d8c903a46138d3b5b5  phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift
433983c79711fe09a8576db3226cc7ae725aac7dff505084c64d46639ebd7f34  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift
fa8755fd843660ea49f689b8e8ff548ecf3f9d6a9298c62be062ab361dce77d9  phase3-binary/Tests/macprovider-cliTests/ModelsAdmissionRetryTests.swift
d0535a1a70f85d0c5fbc94a28337c4e683348f1dc33d925b39571b96505e0d57  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
245d61ee91f555d4c4e102cd620ab5b603d522a03d9d7684cb39ba125342a4eb  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift
5314cf4664e3624f0740b0032f19db2c50cdfbacbcd15672c006277322fdc602  phase3-binary/app/Sources/Malibu/ModelManagement/RecommendationManagement.swift
a9d8e87cb70109be4b651340825d93fd04aaa07ad0a5ea195ab77c2cb30b5c9a  phase3-binary/app/Sources/Malibu/Resources/MalibuFeature.xcstrings
0651a6561ca428d1e8a404c6cac7351423c24af24c9b0d5e1b9b3a6c136e8227  phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
f9fc564c1b70d9ffa81ae20d871440b10eab66fa3769aa5ee0fe2ac7bcf04556  phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift
f0518cfc02120082b1de14a9f69afb6f540910d3d31b8b843ea5defbd2c9384d  phase4-coordinator/cmd/coordinator/main.go
d9bb77bd5a1cccf5bb8ae924204a80ab17060156391c6c96abdf786c93b1c17c  phase4-coordinator/internal/billing/artifact_admission.go
2d7bc85d9d9cf4c47627c76b752ac069619aada6f84f4b09b7a84643c8d2bd3d  phase4-coordinator/internal/billing/artifact_admission_test.go
95c68af6ea5bbf11df33e57e8ff6060d7bbc118ea6b277c3dd5a2d1dda59e3ae  phase4-coordinator/internal/billing/recovery.go
2cc705c4a1f4137cc25b22aa317ddf30f303a7c27bae8bb221a8d8fef53d2597  phase4-coordinator/internal/billing/route_snapshot.go
8ef7fd08e8d0c25fe3c01d4efb0a55adace67a1b12c7accc646b56b64e809533  phase4-coordinator/internal/billing/settlement_receipts.go
898f16a533db9868777226799f282e7db5fd8b4a378c1ca4a653f65d2449988a  phase4-coordinator/internal/buyer/autotune_feeds.go
89d2672ca3237399619e8878c1e85bbc42ffd51b8a54cac74e72dca2aab63858  phase4-coordinator/internal/buyer/billing_recorder.go
5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549  phase4-coordinator/internal/buyer/model_admission.go
36776909256a4bb1ee0531efe157f185fa103163a7c8f9164968a1b01b75b94a  phase4-coordinator/internal/buyer/model_admission_authority.go
e9aeebde04fa0db5132854ad7b822a217a730447851e4f612c6d9d50bbbeb080  phase4-coordinator/internal/buyer/model_admission_authority_test.go
09242070eca6cebe3cd732829b9d14df3a9ec3d06f4a762ef08746d1b329d73f  phase4-coordinator/internal/buyer/route_snapshot.go
379913f313ecef918883bf554f90f582a880c3efa49079e622bd5f5f6d29117d  phase4-coordinator/internal/ws/model_admission.go
c634f7b5c0671b65528d25636743718e1d1bc3a23b5849b055239ea5bf9cf39b  phase4-coordinator/internal/ws/model_admission_authority.go
77eec1de1add7e7d8565191e10f252bb4082236860fa2bb0dad2f148eab661b7  phase4-coordinator/internal/ws/model_admission_authority_test.go
9edd8750696c67ec42e4f4d1dc9b5508240519cfd4a8d24c6614660c1ccde4f4  phase4-coordinator/internal/ws/model_admission_retry.go
03dc78cd089dc3f9b0d9755f7e84c4c978c63cb37067915f2e5dab7b9109d175  phase4-coordinator/internal/ws/server.go
89f2eaccc8d380a0e79ee99930d704f04894391e9b749befa249650d712c4f7a  specs/CONFORMANCE.json
a151ad8eac3a8fbd449fc82cdbe01a85de178e5aa609a9a514cbbe1999f9f397  specs/README.md
d8ad069ea43dc65ee1020239fcf54249c3a1d1e84f98e4ed340a5a30808abdaf  specs/SPEC-001-phase3-binary.md
e480f34b097a03d16d64ccc27c98b9d8f0b8bf78b33033d2e51f31f2eb95983b  specs/SPEC-044-malibu-model-catalog-economics.md
42c8bcc9d71984741714e0f2c77aef1fc609424e35459b30517f20ea228b8522  specs/SPEC-047-network-model-admission.md
726a3cc640fbca368314dd14995b90597ed6f5cfd237d11905da201a1e9dba6e  specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md
28399c32e97fc64249b9953580cef1986cb743df5b58c11d2acf377b9d35e022  test/integration/build1_artifact_journey_test.go
8114ef52d6522d1888c49be407ca1a612ac1849ef2d55b261318830b546c3cac  test/integration/build1_transport_test.go
54c0f169fb52a4dbbc39fb4d6fff3f8150b4a52545af34d07d8868aff64dfa89  test/integration/harness_test.go
```
