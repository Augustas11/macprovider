# Independent cold-context review — BYOM v0.2 slice 3 (after the anchored loop closed at IMPL R3)

**Why:** the anchored three-lane loop reached 0/0/0 at R3, and the standing lesson (`feedback-cold-context-review-finds-outside-diff-contracts`) is that an anchored loop validates its own narrative and misses contracts outside the diff. Three Claude reviewer lanes (code-reviewer, security-reviewer, architect; opus; neutral prompts naming only the diff and the SPEC sections, forbidden from reading the audit records) reviewed the full working-tree diff at `1d82e1b1` + uncommitted `main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 1 H / 4 M / 3 L / 2 I |
| security-reviewer | 0 C / 0 H / 0 M / 5 L / 5 I |
| architect | 0 C / 1 H / 4 M / 7 L / 11 I |

Both HIGHs were outside-diff contract breaks the anchored loop could not see — exactly the failure mode the lesson names. Every C/H/M and every LOW that has a code-level answer is resolved in the commit that adds this record; what is carried is stated.

## HIGH — resolved
- **H (architect): the coordinator rejected the `artifact_hashes` key the CLI now sends.** `validModelAdmissionToken` allowed only `[A-Za-z0-9_-]`; `macprovider.gguf-file.v1` carries dots, so every GGUF `models offer` would have 400'd (`invalid model admission evidence`). The keys are SPEC-010-R002 algorithm names — a closed set — so the validator now requires `modelidentity.CanonicalAlgorithm(key)`. Pinned at the CLI→coordinator boundary by `TestModelAdmissionOfferArtifactHashesAreKeyedByCanonicalAlgorithm` (both canonical names accepted; `gguf`, `sha256`, the weights-manifest name, uppercase digests rejected).
- **H (code): model-key namespace crossing.** `Member.ModelKey` is the candidate ROW key (`openai/gpt-oss-20b`); the session compared it against `lower(hello.ModelID)`, which is the row's `model_id` (`mlx-community/...`), and `ModelAdmissionCatalogModelKey` has no production writer — so no production session could ever resolve a member, and the buyer prerequisite compared the same two namespaces. `artifactidentity.Member` now carries the row's normalized `ModelID`; the ws resolver requires `member.ModelID == lower(req.ModelID)` and, when the session asserted a key, `asserted == member.ModelKey` (R007(c)); `byomSettlementPrereqsReady` requires `material.CatalogModelKey == member.ModelID` plus the same asserted-key agreement. SPEC-010-R007(c) now states the row/model-id rule. Tests: ws (resolves with no asserted key; other model id fails, with or without a key; disagreeing key fails), buyer (`TestBYOMArtifactMemberRouteTimeGatesFailClosed` "other row" / "asserted key disagrees"), index builder (members carry the row model id).

## MEDIUM — resolved
- **(architect) R001/R006 gained unimplemented MUSTs while staying `conformant`.** Narrowed to what ships: the secondary-member verify/report and warm-swap legs are scoped to "when a runtime path selects" one (R007(e)), explicitly not the v1.7 CLI, which selects/reports/swaps primary rows only. No CONFORMANCE state change needed.
- **(architect) `scripts/verify-tier2-live.sh` closed allow-list of `model_hash_algorithm`** would fail the acceptance cohort on a legitimate GGUF-verified provider. Accepts both canonical algorithms.
- **(architect) compatible-previous releases get no artifact identity, unstated/untested.** Correct fail-closed behaviour (only the current release's feed is loaded); now stated in R004 as amended and pinned in the ws test (previous-release GGUF pair → mismatch; primary path unaffected).
- **(architect M4 / code M / security INFO) AC-CAT-7(i) asserted a hello leg the CLI cannot produce.** Scoped: the GGUF pair is reported in the offer (`artifact_hashes`) now and in hello once a serving runtime path binds a GGUF file (R007(e)); SPEC-023 v0.10.3 change-log point 4.
- **(code) a verified member without a SPEC-047 admission record was route-eligible but unsettleable** (every request 500'd at the snapshot instead of the session being excluded). `byomDefaultPaidRoutingEligible` now returns false for any session with `ArtifactIdentity` and no artifact-derived binding (or no admission store). `TestSecondaryMLXMemberWithoutAdmissionEvidenceNeverSettles` now asserts exclusion (503, no snapshot, no credit).
- **(code) `Member.RuntimeStatus` recorded but never enforced.** `byomSettlementPrereqsReady` requires `recommendable` (SPEC-023 §3.7.4 / AC-CAT-7(iii)); `TestBYOMArtifactMemberRouteTimeGatesFailClosed` "listed row".
- **(code M / architect L4 / security L5) offer-path hashing unbounded.** `artifactEvidence(for:environment:deadline:)`; `models offer` hashes under `BYOMModelAdmissionRuntime.artifactHashBudgetSeconds` (600 s, deliberately more generous than the 60 s probe budget); expiry fails the offer closed with the new `artifactHashingTimedOut` reason and records nothing. Test in `BYOMArtifactDigestTests`.

## LOW — resolved
- (architect L1) SPEC-023 v0.10.0 change-log points 8–9 annotated as historical.
- (architect L2 / security I3) the six artifact fields on `ModelAdmissionPaidRoutingPredicate` are conversion scaffolding, now documented as such: admission events carry no artifact evidence, and member drift within a session is handled by **session pinning** — `pool.pinArtifactSession` (heartbeat and refresh paths) turns a later report resolving to a different member, the primary included, into a mismatch for the same model id (R007(b) "session authority", now stated in R007(c)); a model change rebinds. `TestArtifactSessionMemberIsPinnedAcrossHeartbeats`.
- (architect L3) one tier-2 material derivation for routing eligibility and the snapshot: `byomMaterialHash`.
- (architect L6) stale index logs `artifact_identity_index_stale` once per refresh, distinguishable from provider drift.
- (architect L7) `SetAutotuneCatalogWithArtifactIndex` removed; `SetAutotuneCatalog` drops the index and the feed-publish observer installs the replacement — one lifecycle.
- (code L1 / security L2) only a validated catalog envelope binds a release: `admittedCandidateCatalogSHA256` blanks the digest for `update_bridge`/`legacy`/other modes on the hello and heartbeat legs. Tested.
- (code L2) the pathname `GGUFArtifactDigest.compute(fileURL:)` entry point (identity-unbound) removed; only the descriptor path exists.
- (code L3 / architect INFO) `Index.BoundTo` is exact-string, like `Resolve`. Tested (upper-case and padded digests do not bind).
- (security L1) `hash_artifact` drift for an artifact-bound session is checked against the bound member's digest instead of being suppressed. `TestEvaluateHeartbeatChecksArtifactBoundSessionAgainstItsMember`.
- (security L4) the digest cache's advisory-only role documented at the lookup.
- (security I1 / architect INFO) CONFORMANCE R007 implementation pointer names `verifyModelIdentity` (the R007 entry point), not the v1.6 shim.

## Carried (documented, no code change)
- (security L3 / architect L5) On a release with no artifact feed a hello naming `macprovider.gguf-file.v1` is parsed as a canonical pair (R002) and verdicted `mismatch` rather than closed at parse as in v1.6. Fail-closed for money on every path; R007's opening sentence now says exactly this. Closing it at parse would also close a GGUF heartbeat inside the SIGHUP window (index momentarily nil), which is worse.
- (code INFO) a secondary snapshot-manifest snapshot with none of the six values is indistinguishable at settlement from a row-bound primary; unreachable (insert-side guard + digest omission), noted for slice 4 which may add an explicit marker.
- (security I4) `Package.resolved` is a local build artifact and is restored from `origin/main` before every commit.
- Slice-4 inputs (architect): nothing writes `ModelAdmissionEvent.ExpectedCatalogModelHash{,Algorithm}` or `pool.Provider.ModelAdmissionCatalogModelKey` in production yet — the decision path must set them from the resolved member; the offer's `artifact_hashes` is signed and validated but not yet consulted for identity (needs an offer-shaped resolver, or the three checks lifted out of `resolveArtifactIdentity`); `Member.RuntimeStatus` now gates settlement but the decision path still needs the `listed`→`network_visible_unpriced` predicate; compatible-previous releases will need a keyed set of indexes if artifact identity must survive rollover windows.

Verification: `go vet ./...`; `go test ./internal/artifactidentity ./internal/modelidentity ./internal/pool ./internal/pow ./internal/ws ./internal/billing ./internal/buyer ./internal/tier2 ./cmd/... -count=1` ok; `swift test --filter 'BYOMArtifactDigestTests|BYOMAdmissionTests|BYOMDiscovery|AutotuneArtifactFeedTests|BYOMEvaluation|BYOMModelAdmission'` 128 tests, 0 failures; `check_spec_governance.py` passed; `bash -n scripts/verify-tier2-live.sh`.

A closure pass (three codex lanes, R4) runs over the FULL working-tree diff before the PR.
