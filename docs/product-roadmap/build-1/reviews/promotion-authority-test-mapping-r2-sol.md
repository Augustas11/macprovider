# S2 promotion-authority admission test mapping — independent Sol review R2

Verdict: **APPROVED FOR THIS BOUNDED MAPPING GATE — 0 Critical, 0 High, 0 Medium, 0 Low.** The current T06/T10/T11 correction set closes all three Medium findings in `promotion-authority-test-mapping-r1-sol.md` without weakening the approved promotion-authority addendum or Build 1 test specification. This is test-mapping approval, not the final combined Build 1 code/security/architecture audit and not physical B1-T10/B1-T11 acceptance.

Reviewed base: `914f7cafcdbcfc1805a10f4f34167218341d5587`. The worktree HEAD remained that base while the uncommitted Build 1 implementation and tests formed the reviewed tree. `origin/main` had advanced independently and was not used as the review base. I inspected production behavior and current tests in `phase4-coordinator/internal/ws`, `internal/buyer`, their store/owner dependencies, and the existing actual-service integration composition. I did not edit production or test code; this report is the only file added by this review.

## Prior Medium dispositions

| Prior finding | Severity disposition | Evidence | Consequence | Required correction |
|---|---|---|---|---|
| S2-ADM-M1 — incomplete T11 consumer/store/replacement/interleaving mapping | **Closed (previously Medium)** | `TestArtifactRouteRejectsClosingBeforeReadback` now gives every direct resolver, direct binding, require-binding, actual default/pinned `selectProvider`, and queue-poll consumer a fresh real-WS fixture over memory and SQLite. Inputs are checked immediately before the call; direct binding asserts found-but-ineligible; the revocation-only wrapper delegates reads/non-revocation writes; ordinary and rejected revocation paths inspect exact CAS attempts and fresh latest state. `TestArtifactPaidSelectionNoDrift`, `TestArtifactRouteReplacementEventRejectsStaleRevocation`, `TestAdmissionTransportOldTimerCannotDisplaceReadmittedReplacement`, the exact callback table, representative real `closeSession`/scheduled-trust producers, and `TestArtifactRouteObservationReleasesPinsBeforeDispatch` supply the required positive, stale-CAS, old-timer, map/session, and downstream-dispatch compositions. The existing actual-service `TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation` proves first HTTP selection rejection, no inference dispatch, no payable rows/debit, and both successful and failed SQLite revocation writes. | No remaining tested-consumer, store, replacement, or downstream interleaving gap from R1. | None. Preserve the fresh-fixture and first-consumer ordering. |
| S2-ADM-M2 — simulated acknowledgment failure and incomplete graceful/overlap proof | **Closed (previously Medium)** | `TestPostRegistrationAcknowledgmentEnqueueFailureCapturesClosingSession` drives the real v1 and v2 handlers through real registration, deterministically fills the real session queue, observes empty returned IDs, and proves `closeConnection` publishes closing before raw close while the exact session is still mapped. `TestRefusedRegistrationAndPreauthCloseDoNotInvalidateIncumbent` covers incumbent isolation. `TestClosingPreservesPendingFramesAndExactlyOneGracefulClose` observes in-flight and pending text frames followed by the exact normal Close. `TestClosingRealGracefulProbeTimeoutWriterFailureOverlap` composes the real writer, real probe timeout, graceful close, writer-failure cleanup, map deletion, one timer and one close event. The latter supplies the terminal-cleanup half of the intentionally compositional empty-ID proof. | The real empty-ID regression, frame serialization, incumbent isolation, and overlapping terminal paths are now observable; the earlier helper-only false confidence is removed. | None. Keep the registration handlers and terminal writer cleanup in the fixture rather than replacing them with direct session-map setup. |
| S2-ADM-M3 — incomplete T06 contention/fault cleanup and uncertainty evidence | **Closed (previously Medium)** | `TestPromotionGuardWSAuthoritySourceLockFirst` covers the two missing WS source locks over both stores, checks prompt refusal, unchanged event/replay counts, owner mutation, and later promotion. `TestPromotionCommitFailureAndReconciliation/real-INSERT-rejection` uses an actual SQLite aborting trigger, distinct from post-insert rollback and deferred-COMMIT failure. Post-insert rollback, panic, acquired-context cancellation, COMMIT failure and ambiguous completion all install complete subordinate release witnesses and separately recheck WS authority/publication/session/pool ownership; the real complete owner chain's normal acquisition/release and every downstream contention boundary remain covered by the existing buyer, billing, pool, Tier2 and full-owner tests. Known ambiguity checks the four-event history, exact CAS/replay identity, two reconciliations and idempotent replay; unavailable reconciliation repeats without a positive claim. | A source-lock partial-acquisition leak, skipped INSERT boundary, lost release callback, or duplicate/false ambiguous completion would now fail a deterministic assertion. | None. Preserve the separation between DB-wait-without-pins and post-acquisition store faults. |

## Adversarial assessment

The tests exercise production entry points rather than success-returning availability mocks. The buyer fixture's metadata repair retains the real accepted socket and exact WS session. The pinned path enters the header-driven `selectProvider` session branch. The route/dispatch test reaches the settlement relay only after route-snapshot persistence, blocks there, and proves actual closing publication completes without waiting for downstream release. Replacement coverage is compositional: both stores reject stale revocation and restore actual selection, while the SQLite real-owner composition retains and fires the old scheduled timer around refreshed durable authority.

The T06 release evidence is also valid composition rather than a fault Cartesian product. Store fault tests prove the guarded store invokes every returned release witness on each distinct exit. Independent owner tests and the full-owner matrix prove the production buyer/feed/billing/settlement/Tier2 composite acquires, rolls back and releases its real locks. The WS fault tests additionally prove the surrounding WS and pool pins release. No requirement was weakened into a mocked positive resolver or latest-state-only assertion.

The post-registration failure test deliberately checks closing at raw-close time before cleanup removes the session. Eventual map deletion and exactly-once terminal accounting are established by the separate real writer/probe/terminal overlap test, matching R1's bounded compositional correction and avoiding an acknowledgment-failure × store/producer expansion.

## Fresh verification

All commands ran against the reviewed tree with `-race -count=1`; none selected zero tests, skipped, timed out, or reported a race.

```text
cd phase4-coordinator
go test -race ./internal/buyer -run 'Test(ArtifactRouteRejectsClosingBeforeReadback|ArtifactPaidSelectionRejectsClosingBeforeReadback|ArtifactPaidSelectionNoDrift|ArtifactRouteMissingTransportWiring|ArtifactRouteReplacementEventRejectsStaleRevocation|ArtifactRouteObservationReleasesPinsBeforeDispatch)$' -count=1 -timeout=180s
ok github.com/augstar/macprovider-coordinator/internal/buyer 12.822s

go test -race ./internal/ws -run 'Test(PromotionGuardWSAuthoritySourceLockFirst|PromotionSQLitePostInsertBoundary|PromotionCommitFailureAndReconciliation|PromotionSQLiteWriteLockWaitHoldsNoAuthorityPins|PostRegistrationAcknowledgmentEnqueueFailureCapturesClosingSession|RefusedRegistrationAndPreauthCloseDoNotInvalidateIncumbent|ClosingPreservesPendingFramesAndExactlyOneGracefulClose|ClosingRealGracefulProbeTimeoutWriterFailureOverlap|AdmissionTransportRealProducersInvalidateBuyerSelection|AdmissionTransportCallbackStateTable|AdmissionTransportOldTimerCannotDisplaceReadmittedReplacement)$' -count=1 -timeout=180s
ok github.com/augstar/macprovider-coordinator/internal/ws 7.152s

cd ../test/integration
go test -race -run '^TestBuild1PaidRouteRejectsClosingBeforeStatusRevocation$' -count=1 -timeout=180s
PASS; ok github.com/augstar/macprovider-integration 7.319s
```

## Snapshot manifest

| Path | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/promotion-authority-addendum-r3.md` | `6a5bd750addb0180f22a4cf16cc33862a2324a3010cfae66c794c568bfd5d0c4` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/implementation-S2.md` | `c7188d053efd4ba25560dc2cb4ee5d2344da3fa2bfd22a5eea31967d2f2228e5` |
| `docs/product-roadmap/build-1/reviews/promotion-authority-test-mapping-r1-sol.md` | `0590b696122d801a198c6db7c942805af449e6919d3d955bb9351035cb73d49e` |
| `docs/product-roadmap/build-1/evidence/promotion-authority-ws-t06-t10-correction-r1-sol.md` | `f559724d9d541451d3ac5cada17eb46970c1e3a49175b08609582d56be47dd1c` |
| `phase4-coordinator/internal/buyer/model_admission_transport_authority_test.go` | `811c129fa030697a78e91ab4a47c1a32516cb4dda1f14087e595829f0d6e58f3` |
| `phase4-coordinator/internal/buyer/model_admission_route_export_test.go` | `fd73e9a08186a5e442d807c9e96f2c0a167b4732f2d3a3ede98d5222f9cef3a8` |
| `phase4-coordinator/internal/ws/model_admission_transport_test.go` | `d83c5304d56af948e4987acfa7a89b7447d4ea66d2af55a13d6951972eb33b7c` |
| `phase4-coordinator/internal/ws/model_admission_guard_test.go` | `f33acd54086464f4d0c2deafd5396c26009268694cfc9045332fb8cc4dbe3713` |
| `phase4-coordinator/internal/ws/model_admission_commit_boundary_test.go` | `5466bceb51449e9ba729b22f9b2089c4517044ca378b2ad144945bf39cf4213b` |
| `phase4-coordinator/internal/ws/model_admission_sqlite_wait_test.go` | `dfc06d87b7eb309d4e72e5e4561b752b28f0634baf73bc6ef1b78fef84f2d913` |
| `phase4-coordinator/internal/ws/model_admission_transport_export_test.go` | `5c637afe26c77fdd0269371e8f993e9374e7ac61c36d8bc21841ad13f22a9658` |
| `phase4-coordinator/internal/ws/model_admission_transport_buyer_composition_test.go` | `5ffd9ce76328bfc7ce8240d6086479d0f73850480378ef635d829b5634abbbf4` |
| `test/integration/build1_closing_route_test.go` | `873bb97c04c3a7243ab55c54e037c2188a99c0966d325ddf1e8ab1bcc46c3fd0` |

## Gate disposition

| Gate | Count | Disposition |
|---|---:|---|
| Critical | 0 | Clear for this bounded mapping review |
| High | 0 | Clear for this bounded mapping review |
| Medium | 0 | **Approved** |
| Low | 0 | Clear |

The repository-wide coordinator/gateway/spec gates, final complete-diff code/security/architecture audits, and physical B1-T10/B1-T11 qualification remain separate mandatory gates. This review does not convert fixture execution into physical inference or production qualification.
