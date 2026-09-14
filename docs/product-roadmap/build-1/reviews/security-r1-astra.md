# Build 1 security audit — revision 1 (preliminary)

Verdict: **CHANGES REQUIRED; final security acceptance withheld.** Initial snapshot findings: **0 Critical, 0 High, 3 Medium**. A candidate correction for M1 appeared during review; closure requires the final stable delta and its regression evidence.

## Scope and snapshot

Reviewed base/HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587`. The leader identifies this tree as equivalent to the approved dependency `f5edeaebfb6c712a2cb6dced9020c8c78ed1053e`. Scope includes the complete tracked and untracked Build 1 implementation, Swift CLI/app contracts and tests, coordinator admission/billing/WS, and real-service integration harness. Read AGENTS.md, CLAUDE.md, approved plan-r4/test-spec-r4, retry-journal-addendum-r2, storage-test-addendum-r1 and their approval records. No implementation edits, operator custody access, restricted upstream source access, production actions or subagents were used.

Initial 54-file manifest SHA-256: `8e9b7958d1bc80736998fcffafe7da0090820c6eefe5e847c1d31a8fac39b506`. The digest is SHA-256 over compact JSON of sorted `[relative_path, file_sha256]` pairs, excluding `docs/product-roadmap/`. The exact manifest is below. This is a captured inventory, **not a claim that concurrent edits were frozen**. Changes arrived during review, including billing recovery, signed-offer reconciliation and CLI tests. A later observed inventory had digest `33233f8c7a04655393c564445e13ff8a17248bd2fcbc7f8bdf00977bc9c0f85c`; it is not a final approved snapshot.

## Findings

### M1 — Current exclusion state can be ignored by artifact authority resolution

**Severity:** Medium. **Confidence:** High from direct control flow. **Status:** Initial defect; candidate patch observed, not finally closed.

**Evidence:** `phase4-coordinator/internal/buyer/model_admission_authority.go:26` resolves a live provider, but the original identity comparison covered only selected model/catalog/receipt fields and checked only `live.State`. The authority predicates used `p.PendingReceiptPubkey`, `p.AuthState`, `p.BenchmarkQuarantined`, `p.AdmissionCeilingExcluded`, `p.AdmissionEvidenceStale` and `p.AdmissionSandboxed` from the caller's earlier selection. Registry exclusion setters can change those gates without changing the compared identity. The original authority matrix changed its local `p`, so it did not exercise a live-registry mutation against a stale caller selection.

**Consequence:** A provider selected before a current-session exclusion/rotation can still obtain an authoritative promotion or binding when this resolver runs after the exclusion. This violates SPEC-047-R001/R003/R006's current-authority requirement; fresh identity alone is insufficient.

**Required correction and evidence:** After checking exact selection/session identity, evaluate all mutable authority using the current registry snapshot. Tests must retain an old selected provider, mutate the actual registry independently for every exclusion and pending-key gate, and assert refusal. Keep session/hash/catalog/key drift negative cases. During review a `p = live` plus mutable-gate recheck appeared at lines 52–57; inspect the complete final change and run the new registry-mutation tests before closure.

### M2 — Transaction setup follows unvalidated root/ancestor symlinks before writing

**Severity:** Medium. **Confidence:** High from direct filesystem control flow. **Status:** Open at reviewed implementation.

**Evidence:** `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift:138` calls `RecommendationAdoptionJournalStore.secureDirectory(root)`. That helper (`RecommendationAdoptionJournal.swift:251`) first recursively creates the directory, then validates/chmods only the leaf. A `.transactions` leaf below a symlinked durable root or ancestor is therefore created/used through the link. `DurableModelArtifactStore.validateNoSymlinkAncestors` starts at the durable root and validates only that leaf and descendants; it never checks ancestors above the root. `ensureRoot` also recursively creates/chmods before whole-chain validation.

**Reproduction shape:** Configure a durable root `<private>/link/models`, with `link` pointing to a separate existing directory. A catalog action reservation writes into the link destination; preparation can subsequently publish there because the durable root itself is an ordinary directory after ancestor traversal. A root symlink also permits reservation-side effects before the later durable-store rejection. This needs no malicious model bytes. Durable discovery separately rejects symlinked ancestors, making preparation/publication and readback disagree. Existing transaction tests cover staging/record symlinks, and the durable store's existing ancestor test covers descendants beneath its root, not the root's parent chain.

**Consequence:** CLI-owned journals, staging, permissions and cleanup can affect paths outside the intended canonical artifact boundary. This violates the approved contained-storage/no-symlink contract and can make the UI report an unrecoverable preparation outcome after external-path writes.

**Required correction and evidence:** Validate the complete existing ancestor chain before any mkdir/chmod/write, rejecting operator-controlled links while deliberately accounting for immutable macOS aliases. Anchor traversal and mutations to directory descriptors (or provide equivalent race-safe containment); preserve ownership/mode checks. Add root-symlink and ancestor-symlink tests covering action reservation, prepare/publication, status/cancel and cleanup, asserting no outside creation, chmod or deletion. Do not rely only on a post-write canonical-path comparison.

### M3 — Fresh status responses can advertise expired settlement authority

**Severity:** Medium. **Confidence:** High from composed server/CLI/app flow. **Status:** Open at reviewed implementation.

**Evidence:** `phase4-coordinator/internal/ws/model_admission.go`'s `handleProviderModelAdmissionStatus` loads the last stored event and immediately emits it. `modelAdmissionStatusResponseFromEvent` attaches a fresh generated timestamp, but does not validate the new artifact evidence's probe expiry, authority expiry or current session. The only drift revocation is in buyer `byomRouteSnapshotBinding`, which runs during buyer eligibility/routing. `ModelCatalogEconomics.swift:603` treats a matching coordinator `settlement_capable` status as current pricing/settlement permission without interpreting evidence expiry. `ModelManagement.swift:3119` then states that coordinator settlement eligibility is confirmed when rate bytes remain fresh.

**Reproduction shape:** Promote an artifact candidate, advance beyond its ten-minute probe lifetime (or disconnect/replace the bound session), and call only the provider status/economics path before any buyer catalog/routing request. The endpoint continues to return `settlement_capable` with a new response timestamp. The app can retain trusted economics/eligibility copy even though the next route-time check would revoke that event.

**Consequence:** Provider-facing authority is stale while presented as fresh and settlement eligible. Actual route-time refusal is useful defense, but does not satisfy SPEC-047-R006's visible drift/revocation or the approved truthful admission readback contract.

**Required correction and evidence:** Revalidate artifact-derived paid status against current session/authority/probe expiry before returning it, persist a CAS-protected demotion/revocation on drift, and return the actual current event. A refusal or unavailable response must not be converted into old paid eligibility. Preserve the closed status schema and legacy interpretation. Add authenticated status-endpoint tests for expired probe, disconnected/replaced session, excluded current provider and stale feed/rates without first exercising buyer routes; verify the CLI/app suppress paid eligibility on the resulting readback.

## Positive evidence and limits

- Signed feeds enter authority through the verified loader marker and exact-byte digests; primary artifact/source/revision/hash, signer/release, independent Tier2 material, explicit effective rates and receipt-key identity are checked. Provider assertions do not directly populate immutable artifact authority.
- New admission decisions carry expected-current-event compare-and-append protection; immutable evidence is distinct from the existing Tier2 catalog digest.
- Artifact extension fields participate in canonical route-snapshot hashing, require consistent complete values, and preserve legacy all-absent interpretation. Captured pricing is checked against immutable billing configuration; later recovery edits were inspected but require final validation.
- The pending-offer journal uses bounded private files, signed-envelope validation, directory-descriptor traversal, bounded lock stripes, atomic writes, generation checks and a cross-candidate count lock. Retry remains server-authorized. Concurrent refinements to original-envelope retention and repository-root rejection require final delta review.
- Local preparation/measurement/adoption uses typed confirmed commands and explicit nonpaid disclosure. The app separately requires a terminal transaction and refreshed model state before success. Preparation does not silently adopt configuration.
- New real-service integration coverage is explicitly a signed fixture with deterministic provider output. It does not prove real MLX execution or physical acceptance.

Fresh command run by this reviewer:

```text
go test ./internal/buyer ./internal/ws ./internal/billing -run 'TestPrimaryArtifact|TestSignedAdmissionRetry|TestArtifactAdmission' -count=1
exit 0
buyer: 0.787s
ws: 0.673s
billing: 0.926s
```

These targeted suites passed but do not establish the missing adversarial cases above. Sources changed concurrently; this test result is not final-tree certification. No full Swift/Xcode/integration/hardware suite was run by this reviewer. The leader's exact final test evidence and independent final delta review remain required. Physical B1-T10 stays unproven independently of fixture success.

## Initial exact file manifest

```text
3214cee41e5fb4ec7c26164b4536688bc6f2287b3323d490beb9283a5e7c9562  phase3-binary/Package.resolved
e39be672187ab91fe1331c55a6de7579141f1f7ec945482c5ab6d995cddb1d7e  phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift
d6d0b0b29e36e84e4f52301408207d7721a7d0911fbab5dd2582fce2917efb48  phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift
2b7ac597f61fd1697e095274f903527eba6987a14d402d8dc3294c4a41f4c3ca  phase3-binary/Sources/macprovider-cli/BYOMPendingOfferJournal.swift
42f1c3ed58d2200cdfa92965895348432bfe4f064716e208051e8df6b58f6241  phase3-binary/Sources/macprovider-cli/CandidateParentLifetimeGuard.swift
30e760c9caf91eef949ed223c8be8b0a67f21015d291ecd0ddec93883701e514  phase3-binary/Sources/macprovider-cli/CandidateProviderRunner.swift
1ac0e2ba9a52197fa9bf98101b5e7ddfd459cb8e37a10fc7a865f3958d4ce71d  phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift
e7f5b9da2ec4be6ab9baa7713318fc34a0524c8796de42c116f4901e53a7f3a6  phase3-binary/Sources/macprovider-cli/DurableModelDiscovery.swift
921bd69a4da1b8b72e51da9de0a9953d742f7f4c5367ebaf649ccbe0b3205d04  phase3-binary/Sources/macprovider-cli/HTTPServer.swift
c240942ca1a32720c1292ae534b688ec49fb66cd6cbde82e04123d5ab39c8e70  phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift
31ccee1efc22b153e78ef70dd1e652d362d407de199449ef4ad174a95845533f  phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift
b331986124de7215db4da26aa4228e32890fbd1f5a99872ac08672a019b42599  phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift
973a452f68f5c0afcff59efba7a0816ba12a7dfd28e31025ac508a4fe7e8b5be  phase3-binary/Sources/macprovider-cli/ModelsAdmissionRetry.swift
8fb190b38dfda46a03315fe64a4404e60a8cb07c3d6568de3124850b2d55ccc5  phase3-binary/Sources/macprovider-cli/ModelsSubcommand.swift
c2ac8d7b98887b2209100bd9e800a13d4a6fa7cedd57a7b2102e11239d08398c  phase3-binary/Tests/macprovider-cliTests/AutotuneRecommendTests.swift
e2d5af06636c4636f699ca51958f0e56a8ef8efee41e443f6c086174a45708d3  phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift
d76cd9f312224f74d492a6e23a2efbf84d88bf65956a514c3db8878305a8257d  phase3-binary/Tests/macprovider-cliTests/BYOMPendingOfferJournalTests.swift
e85544b852d9083d7eb581539dc9307f1d55bd7a47549fc7683d4469650c6837  phase3-binary/Tests/macprovider-cliTests/CandidateParentLifetimeGuardTests.swift
3ea7c38c5bc67511a64b31f20fbd37717c87c8858a020a60e861a67d229dd97b  phase3-binary/Tests/macprovider-cliTests/DurableModelArtifactStoreTests.swift
4f5044289ec115f836471b1d7f5514a0ca4e4320d1dbedb1c58c7c980b218b56  phase3-binary/Tests/macprovider-cliTests/DurableModelDiscoveryTests.swift
1a452feafbe8d350444d0a837d3fab6d67f11169f28ae9d8c903a46138d3b5b5  phase3-binary/Tests/macprovider-cliTests/ModelCatalogEconomicsTests.swift
41b7c917ff093dcc4d49b688b7638b661ec5bfcf7b7ed2c657c9412f1ad1356c  phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionsTests.swift
8372989fe154890f9b9a9643bbfbb31fdfd8cb4e7d20f2cbf4fa194a609effe8  phase3-binary/Tests/macprovider-cliTests/ModelsAdmissionRetryTests.swift
d0535a1a70f85d0c5fbc94a28337c4e683348f1dc33d925b39571b96505e0d57  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift
245d61ee91f555d4c4e102cd620ab5b603d522a03d9d7684cb39ba125342a4eb  phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagementViews.swift
5314cf4664e3624f0740b0032f19db2c50cdfbacbcd15672c006277322fdc602  phase3-binary/app/Sources/Malibu/ModelManagement/RecommendationManagement.swift
a9d8e87cb70109be4b651340825d93fd04aaa07ad0a5ea195ab77c2cb30b5c9a  phase3-binary/app/Sources/Malibu/Resources/MalibuFeature.xcstrings
0651a6561ca428d1e8a404c6cac7351423c24af24c9b0d5e1b9b3a6c136e8227  phase3-binary/app/Sources/Malibu/Resources/MalibuModelCapabilities.json
f9fc564c1b70d9ffa81ae20d871440b10eab66fa3769aa5ee0fe2ac7bcf04556  phase3-binary/app/Tests/MalibuTests/ModelManagementTests.swift
f0518cfc02120082b1de14a9f69afb6f540910d3d31b8b843ea5defbd2c9384d  phase4-coordinator/cmd/coordinator/main.go
9f991e0b62e38d468ce866f8ac5ef65dc45cc7f62ed1cbdcb7bd0398d669d39d  phase4-coordinator/internal/billing/artifact_admission.go
35273e11a5f3846e63d2ee193a7782d860d6bd80552b6c5580c55419d7e592ba  phase4-coordinator/internal/billing/artifact_admission_test.go
2cc705c4a1f4137cc25b22aa317ddf30f303a7c27bae8bb221a8d8fef53d2597  phase4-coordinator/internal/billing/route_snapshot.go
551bd54becd302f42cc88d0310b1bab247e7a88a8db7bf07e5ee2fc5e2823fbd  phase4-coordinator/internal/billing/settlement_receipts.go
898f16a533db9868777226799f282e7db5fd8b4a378c1ca4a653f65d2449988a  phase4-coordinator/internal/buyer/autotune_feeds.go
3f1ab45f7ce7b2ea08c3d7a5a3e8cd6edacc3795746caddf173c9dc480a97a16  phase4-coordinator/internal/buyer/billing_recorder.go
5dbd8410db9a2b699bfe1fbfddc7ba8ebbe53e32dc2b76f316d4ad0c44603549  phase4-coordinator/internal/buyer/model_admission.go
5822274024c45422c5756f5cee9241118b6b3f527bb33fba81a0524036b9cad5  phase4-coordinator/internal/buyer/model_admission_authority.go
bf361dbfe948a9c44e8425742e98154182e95c02397661625d6f4c1ea9f825f2  phase4-coordinator/internal/buyer/model_admission_authority_test.go
09242070eca6cebe3cd732829b9d14df3a9ec3d06f4a762ef08746d1b329d73f  phase4-coordinator/internal/buyer/route_snapshot.go
0f62e308cf1245448e03953bd75ea38c42cd11151510b517448b3dfa796046a4  phase4-coordinator/internal/ws/model_admission.go
3f2f0d61b9aee70d91aa07926a614096ae20c7a49ff3bbddf4d916294be4f468  phase4-coordinator/internal/ws/model_admission_authority.go
4c488e637ef538a01da94149443901192ec86af1f5556733246da98b097a8e36  phase4-coordinator/internal/ws/model_admission_authority_test.go
9edd8750696c67ec42e4f4d1dc9b5508240519cfd4a8d24c6614660c1ccde4f4  phase4-coordinator/internal/ws/model_admission_retry.go
03dc78cd089dc3f9b0d9755f7e84c4c978c63cb37067915f2e5dab7b9109d175  phase4-coordinator/internal/ws/server.go
89f2eaccc8d380a0e79ee99930d704f04894391e9b749befa249650d712c4f7a  specs/CONFORMANCE.json
a151ad8eac3a8fbd449fc82cdbe01a85de178e5aa609a9a514cbbe1999f9f397  specs/README.md
d8ad069ea43dc65ee1020239fcf54249c3a1d1e84f98e4ed340a5a30808abdaf  specs/SPEC-001-phase3-binary.md
e480f34b097a03d16d64ccc27c98b9d8f0b8bf78b33033d2e51f31f2eb95983b  specs/SPEC-044-malibu-model-catalog-economics.md
42c8bcc9d71984741714e0f2c77aef1fc609424e35459b30517f20ea228b8522  specs/SPEC-047-network-model-admission.md
726a3cc640fbca368314dd14995b90597ed6f5cfd237d11905da201a1e9dba6e  specs/design/BUILD_SPEC_953_MALIBU_MODEL_SWITCHING.md
619b75a455ed4711fc42b4a81a08df1b77487418079e5450e9e1951b088fb5c1  test/integration/build1_artifact_journey_test.go
8114ef52d6522d1888c49be407ca1a612ac1849ef2d55b261318830b546c3cac  test/integration/build1_transport_test.go
54c0f169fb52a4dbbc39fb4d6fff3f8150b4a52545af34d07d8868aff64dfa89  test/integration/harness_test.go
```

