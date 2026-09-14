# Product Build 1 reconciliation with `origin/main` `c9445561`

Date: 2026-09-10  
Reviewer lane: independent GPT-5.6 Sol reconciliation analysis  
Worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`  
Build 1 base/HEAD at inspection: `914f7cafcdbcfc1805a10f4f34167218341d5587`  
Advanced `origin/main`: `c9445561e4fe00a073926ff2ab0fdb0536d00e37`  
Upstream change: merged PR #1469, GGUF settlement identity / SPEC-010 v1.7 R007  

## Verdict

Build 1 must be replayed onto `c9445561`; its current dirty diff must not be
merged or mechanically rebased as if PR #1469 were unrelated. The changes are
compatible in purpose, but they overlap at the identity, admission, routing,
route-snapshot, settlement, feed-reload, and normative-contract boundaries.

The safe result keeps the complete upstream SPEC-010-R007 implementation as
the identity foundation, then layers Build 1's stronger coordinator-owned
authority capture, promotion serialization, retry, durable discovery, billing
capture, and UI/CLI work over it. Every Build 1 path that currently says or
implements "primary only" must be split into two distinct concepts:

1. Build 1 may still prepare and demonstrate one exact primary MLX artifact as
   its bounded product journey.
2. Network identity, paid admission, routing, and settlement must accept the
   selected SPEC-010-R007 expected-identity member, including a verified GGUF
   member, when all SPEC-010, SPEC-023, SPEC-047, Tier2, billing, session,
   receipt, and immutable-evidence predicates hold.

This is a reconciliation report, not an implementation acceptance. No test was
run against a reconciled tree because no reconciled tree exists yet.

## Inspection evidence

The worktree had 54 tracked modifications and 84 untracked paths at inspection.
The branch was exactly one commit behind `origin/main`, and the merge base of
the dirty branch HEAD and `origin/main` was `914f7caf`. The upstream commit
changes 47 paths and adds 3,781 lines while removing 126.

There are exactly 15 paths changed both by PR #1469 and by the tracked Build 1
diff. A temporary-index three-way application of the 54 tracked Build 1 changes
onto `c9445561` produced eight textual conflicts and 46 textual clean applies.
The temporary index did not update the worktree. A clean textual apply is not a
semantic verdict; seven of the directly overlapping paths apply textually but
still need contract-aware composition.

No `d-inference` source was inspected.

## Upstream foundation that must be retained

PR #1469 is now the source of truth for these capabilities:

- `phase3-binary/Sources/macprovider-cli/BYOMArtifactDigest.swift` computes
  `macprovider.gguf-file.v1` over opened GGUF bytes with deadline, file-identity,
  and cache protections. `BYOMDiscovery.swift` uses that resolver for Ollama
  discovery, evaluation, and submission-time revalidation.
- `phase4-coordinator/internal/modelidentity/identity.go` recognizes the GGUF
  algorithm as a canonical SPEC-010 wire pair.
- `phase4-coordinator/internal/artifactidentity/index.go` builds the exact,
  release-bound `(hash_algorithm, hash) -> (model_key, artifact_id)` index with
  uniqueness, verification status, runtime status, signer, release, candidate
  catalog, and freshness provenance.
- `phase4-coordinator/internal/buyer/artifact_identity_index.go` derives that
  index from authenticated autotune feeds at boot and reload.
- `phase4-coordinator/internal/pool/provider.go` carries the current
  `ArtifactIdentity` and the first-verified session `IdentityPin`, preserves the
  pin across heartbeats, and resets it on model change or registration.
- `phase4-coordinator/internal/ws/server.go` resolves and verifies the exact
  member under the admitted release and installs/rebuilds the artifact index.
- `phase4-coordinator/internal/buyer/model_admission.go` separates the member
  identity from the candidate-row/Tier2 lookup identity and permits only a
  fresh `recommendable` member to settle.
- `phase4-coordinator/internal/billing/route_snapshot.go` and
  `settlement_receipts.go` carry and recover six immutable artifact-provenance
  values and reject missing, partial, or changed member evidence.
- `specs/SPEC-010-model-catalog.md` v1.7 R007, SPEC-023 v0.10.3, and SPEC-047
  v0.1.4 supersede the prior primary-only settlement interpretation.

Do not reimplement these features from Build 1's older-base assumptions. Use
the upstream index, binding, pin, canonical-algorithm, route helper, and digest
resolver directly.

## Exact direct overlap map

| Path | Upstream symbols/contract | Build 1 symbols/intent | Disposition |
|---|---|---|---|
| `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift` | `BYOMModelAdmissionError`, `BYOMOfferSubmissionBuilder.makePackage`, `BYOMModelAdmissionRuntime.submit`, `BYOMDiscoveryEnvironment`, `BYOMDiscoveryRunner`, `BYOMEvaluationLimits`, `BYOMEvaluationRunner`, `BYOMOllamaDiscovery` add GGUF hashing, deadlines, cache location, exact digest matching, and submit-time file revalidation. | Adds `missingRetryTuple`, `BYOMOfferRetryBuilder`, pending-offer journaling, durable artifact root, local inspection, catalog discovery, and expanded `BYOMCatalogMatcher`/MLX discovery. | **Text conflict; compose.** Keep upstream digest resolver and every Ollama path. Replay journal/retry/durable/catalog work. A retry must preserve the original signed tuple and artifact hashes but must also repeat upstream file-identity/digest validation before resubmission. Pass `artifactDigests` through both ordinary and catalog discovery factories. |
| `phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift` | Adds GGUF offer submission coverage and recording-client support. | Adds retry, ambiguous-result journal, corrupt-journal, confirmation, status, withdrawal, and compatibility tests. | **Textually clean; retain both.** Refactor shared fixtures only after both suites run. Add a retry test where the GGUF file changes after the original offer; no retry may post stale artifact evidence. |
| `phase4-coordinator/cmd/coordinator/main.go` | Builds the boot artifact index, injects it into WS, and rebuilds or disables it on feed reload. | Wires billing snapshot generation, model-admission authority ownership, and transport/session invalidation. | **Textually clean; semantically compose.** Preserve boot and SIGHUP index wiring and Build 1 authority/transport wiring. Establish a deterministic construction order and fail closed until the feed bytes, catalog, index, and Build 1 authority view name one generation. |
| `phase4-coordinator/internal/billing/route_snapshot.go` | Adds the six R007 fields, `ArtifactDerived`, `validateArtifactEvidence`, canonical algorithm validation, and digest coverage. | Embeds `*ArtifactAdmissionEvidence`, flattens its richer fields into the snapshot digest, and binds rates/session/receipt/expiry. | **Text conflict; redesign once.** Keep one canonical representation. Preserve upstream all-six-or-none/member-pair behavior while extending it with Build 1's immutable billing/session fields. Do not emit duplicate JSON keys or two sources of truth. Resolve the serialized candidate-catalog key discrepancy described below before migration code is written. |
| `phase4-coordinator/internal/billing/settlement_receipts.go` | Recovers all six R007 values before digest recomputation and settlement verification. | Recovers the richer embedded evidence, verifies captured billing config/rates, and rejects whole-extension loss. | **Textually clean; semantically compose.** Settlement must first verify the historical snapshot using its original schema/key spelling, then validate the captured Build 1 extension without consulting current feeds. Preserve upstream changed/missing evidence rejection and Build 1 legacy/corruption handling. |
| `phase4-coordinator/internal/buyer/autotune_feeds.go` | Adds the post-publish observer used to rebuild the R007 identity index outside the feed lock. | Clones feed bytes, tracks `autotuneFeedsGeneration`, and includes additional admission-authority verification state. | **Text conflict; compose.** Preserve clone ownership, generation increments, and the observer. A positive authority must not combine newly published feed bytes with the previous artifact index. Publish a shared generation/provenance or make the mismatch observable and fail closed. |
| `phase4-coordinator/internal/buyer/model_admission.go` | Adds `byomMaterialHash`, `byomCatalogModelKey`, `byomExpectedIdentity`, `byomArtifactPredicate`, member-aware lookup/routing, recommendable/fresh gates, and six-field snapshot binding. | Revalidates stored `ArtifactAdmissionEvidence`, revokes drift, records richer snapshot evidence, and handles offers arriving after WS registration. | **Text conflict; compose around upstream helpers.** Build 1 must stop comparing only `ModelHash == ExpectedModelHash` under snapshot-manifest. Resolve the selected member via `Provider.ArtifactIdentity`; use the row hash only for Tier2 material/rate lookup; bind the member pair and provenance into admission and settlement. |
| `phase4-coordinator/internal/buyer/route_snapshot.go` | Uses the member pair for the route identity, the row hash for Tier2 material, requires artifact-derived admission evidence, and reports the session verdict for member routes. | Retains per-attempt richer artifact authority for billing/settlement. | **Textually clean; semantically compose.** The per-attempt record must be copied from the already validated selected member plus coordinator-owned billing/session authority. Do not replace the upstream member/row distinction. |
| `phase4-coordinator/internal/buyer/server.go` | Adds `autotuneFeedsObserver` beside feed state. | Adds billing/feed authority generations, cloned snapshots, test clock, and transport closure hooks. | **Text conflict; retain all owner state.** Review lock order across billing, feeds, index, pool, WS session, Tier2, and SQLite before enabling positive promotion. |
| `phase4-coordinator/internal/pool/provider.go` | Adds `ArtifactIdentity`, `IdentityPin`, `ModelIdentityResolver`, registration pinning, heartbeat pin enforcement, and member-aware projections. | Routes all publications through `cloneProviderSnapshot` and adds admission serialization hooks. | **Textually clean; semantically adapt.** Deep-copy or otherwise immutably own both new pointer fields in Build 1 snapshots. Include their complete identity/provenance/pin values in authority equality checks. Never allow a stale shallow pointer to pass a commit guard. |
| `phase4-coordinator/internal/ws/model_admission.go` | Makes trusted expected algorithms canonical, adds six member fields to paid/settlement predicates and bindings, and accepts canonical offer artifact-hash keys. | Persists `RuntimeSource` and rich `ArtifactAdmissionEvidence`, adds guarded CAS/retry semantics, current readback, clone ownership, and positive-event checks. | **Text conflict; compose.** `modelAdmissionEventHasTrustedCatalogAuthority`, event replay digesting, SQLite migration/scanning, `ModelAdmissionSettlementPredicate`, and `ModelAdmissionSettlementBindingForRouteSnapshot` must all agree on the selected R007 member. Preserve legacy row-bound events and snapshots without inferring new authority. |
| `phase4-coordinator/internal/ws/server.go` | Owns the artifact index, drops it before catalog swaps, performs member resolution/verification across hello, heartbeat, refresh, pool views, and policy gates. | Owns admission authority callbacks/generations, session publication, closing/teardown serialization, and retry endpoints. | **Text conflict; highest runtime risk.** Preserve upstream `SetArtifactIdentityIndex`, `resolveArtifactIdentity`, `verifyModelIdentity`, and every member-aware call site. Bind Build 1 promotion and teardown guards to the same exact `ArtifactIdentity`/`IdentityPin` session state and feed generation. |
| `specs/CONFORMANCE.json` | Replaces R007 with real implementation/test mappings while retaining `pending`/`DECISION_REQUIRED`. | Replaces R007 with an empty structured tombstone because #1469 was unmerged, and updates Build 1 mappings/version selectors. | **Text conflict; drop the tombstone.** Start with the c944 R007 row unchanged, then add honest Build 1 mappings. Do not promote R007 from `pending`; the landed row still has no journey evidence. |
| `specs/README.md` | Records SPEC-010 1.7, SPEC-023 v0.10.3, and SPEC-047 0.1.4. | Records SPEC-001 1.9.9, SPEC-044 0.1.2, SPEC-047 0.1.4, but still lists SPEC-010 1.6 and SPEC-023 v0.10.2. | **Textually clean; regenerate after specs.** Preserve the upstream 010/023 versions and add Build 1's final versions. Do not hand-merge stale counts. |
| `specs/SPEC-047-network-model-admission.md` | v0.1.4 delegates expected-identity eligibility to SPEC-010 R007 and allows any qualified verified member; feed-derived primary entries also require the six-value record. | Independently claims v0.1.4 and adds retry, coordinator-owned promotion, serialization, and immutable billing evidence while retaining primary-only wording. | **Semantic version collision.** Keep upstream v0.1.4. Replay the Build 1 additions as a subsequent revision, expected to be v0.1.5 if no newer version lands, and rewrite every primary-only normative statement in terms of the selected expected-identity member. |

## Local material that must be dropped rather than replayed

1. Drop the local empty `SPEC-010-R007` conformance tombstone and its rationale
   that PR #1469 is unmerged. Retain c944's concrete implementation/test
   selectors, `pending` state, and `DECISION_REQUIRED` gap.
2. Drop the local SPEC-047 v0.1.4 version claim and the carried primary-only
   restriction in R001/R003 and the new Build 1 authority clarification. The
   authority/retry/serialization content remains useful, but it must be
   rewritten as a post-c944 revision without contradicting R007.
3. Drop stale Build 1 prose saying SPEC-010 is v1.6, SPEC-023 is v0.10.2, PR
   #1469 is active/unmerged, or SPEC-023 makes settlement primary-only. At
   minimum this affects `plan-r4.md`, `test-spec-r4.md`,
   `qualification-blockers.md`, `reviews/gate-log.md`,
   `implementation-contracts.md`, and `pr-body-draft.md`. Older review artifacts
   may remain historical if clearly labeled superseded; current gate/status
   artifacts must not present the old state as current.
4. Drop the local deletion of 15 SwiftPM pins from
   `phase3-binary/Package.resolved`. It is unrelated to Build 1 behavior and
   would undo the dependency lock restored on main. No new dependency is
   authorized.
5. Drop any local duplicate base implementation of the six R007 values. Build
   1 may extend the record with release, candidate signer, rates, billing
   snapshot, session, receipt key, and expiry values, but the member pair and
   feed provenance must have one canonical owner derived from the upstream
   binding.
6. Drop local reason/domain names that encode primary-only truth, such as
   `primary_artifact_authority_verified`, where they would be used for a valid
   GGUF or secondary member. Introduce a member-neutral revisioned domain/reason
   only if persisted digest compatibility is explicitly handled.

Do not drop Build 1's pending-offer journal, bounded retry, durable discovery,
CLI/app preparation transactions, coordinator-owned authority capture,
promotion CAS/serialization, transport invalidation, captured-rate validation,
legacy snapshot protections, or integration tests. Those are additive behavior
that must be replayed and adapted.

## Contract reconciliation

### SPEC-010 R007

The local tombstone is wholly obsolete. The final conformance row must start
from c944's eight implementation selectors and nine test selectors. Build 1 can
add its authority, persistence, retry, and end-to-end settlement selectors, but
must not delete the upstream index, WS resolution, buyer settlement, billing,
or Swift digest selectors. `pending` remains correct until qualifying journey
evidence and the owner decision close the gap.

The implementation must preserve all four R007 boundaries:

- Compute GGUF identity from the exact local bytes; never trust a manifest
  locator or runtime label as the digest.
- Resolve a verified member only through the exact release-bound feed and
  globally unique pair.
- Pin the first verified session identity; later missing/mismatched/stale
  evidence cannot silently replace the pin.
- Bind and reverify all six feed-derived values in the immutable route record.

Build 1 adds more authority predicates; none may weaken or replace those four.

### SPEC-023 v0.10.3

Pricing remains model-key scoped while runtime identity may be any qualified
member of that key. Tier2 lookup therefore uses the candidate row identity, but
the provider wire pair and route evidence use the selected member identity.
`listed` may be catalog matched but must stop at `network_visible_unpriced`;
paid admission requires `recommendable`. Feed freshness and release/signer
binding must be rechecked at positive admission and route time.

Build 1's preparation UX may intentionally reject non-primary targets in its
current bounded release. That is a local action capability, not a statement
that non-primary members are ineligible for network settlement. Tests and UI
copy must make this distinction explicit.

### SPEC-047 post-v0.1.4

The Build 1 retry and coordinator-authority additions are normative and should
be replayed as a new revision after the landed v0.1.4. Rewrite:

- "exact primary model/hash/algorithm" as the exact selected R007 expected
  identity, while separately requiring the corresponding candidate row and
  Tier2 material;
- `artifact_id` as the exact selected feed member;
- `artifact_hash`/`artifact_hash_algorithm` as the selected member's canonical
  pair and current session pair;
- the primary-only all-six table text so every feed-derived member, including
  the feed's primary member, carries the values; only direct row-bound primary
  identity is exempt;
- test requirements so both primary row and GGUF/member paths exercise every
  Build 1 authority and race predicate.

The existing Build 1 clauses for immutable captured rates, wrong signer,
cross-release substitution, historical snapshot preservation, CAS, feed/rate/
session/receipt/exclusion serialization, expiry, retry, and teardown remain
valid after this generalization.

## Blocking serialized-field discrepancy

This is a concrete upstream implementation/spec mismatch, not an inference:

- c944 SPEC-047 names the exact sixth serialized field
  `candidate_catalog_sha256`.
- c944 `billing.RouteSnapshot` and its settlement binding serialize
  `artifact_candidate_catalog_sha256` through
  `ArtifactCandidateCatalogSHA256`.
- Build 1's `ArtifactAdmissionEvidence` uses the normative
  `candidate_catalog_sha256`.

A naïve merge can emit both fields, accept one while digesting the other, or
change the recomputed digest of a c944-format historical snapshot. Resolve this
before settling any reconciled artifact attempt. The safest schema procedure is:

1. Choose `candidate_catalog_sha256` for new records because that is the exact
   owner-spec spelling.
2. Preserve a distinct decoder/recompute path for an already stored c944-format
   record containing `artifact_candidate_catalog_sha256`; verify its digest
   over its original key before normalizing it for in-memory checks.
3. Reject records containing both spellings, partial evidence, or a value that
   disagrees with the authenticated binding.
4. Never rewrite an old snapshot or reconstruct the missing value from current
   feeds.
5. Add fixtures for canonical, historical c944 spelling, both-spelling,
   missing, and changed-value cases. If operators can prove no c944 snapshots
   were ever persisted, record that operational evidence; do not assume it.

This issue should be resolved either in the Build 1 PR with an explicit SPEC/
compatibility note or in a prerequisite fix merged before Build 1. It must not
be hidden inside a field rename.

## Runtime and concurrency risks

### Critical integration risks

**Dual identity authority.** Build 1's current
`ResolveModelAdmissionAuthority` requires `mlx_cache`,
`macprovider.snapshot-manifest.v1`, `ModelHash == ExpectedModelHash`, and the
primary artifact. If replayed unchanged, a valid GGUF member verified by c944
will fail Build 1 promotion/revalidation. If those checks are merely removed,
provider assertions could gain authority. The replacement must consume
`Provider.ArtifactIdentity`, verify its member/provenance and session pin, and
use upstream member/row helper semantics.

**Feed/index publication split.** Upstream publishes feed bytes, then invokes
an observer outside the feed lock to rebuild the WS index. Build 1 independently
captures a cloned feed generation for promotion. During reload, a promotion
could otherwise combine a new feed generation with an old index, or a new index
with old prepared authority. Include the index release/feed digest in the
prepared authority and commit guard, or publish a composite immutable
generation. Any transition window must be non-paid.

**Snapshot schema and digest compatibility.** The field discrepancy above plus
Build 1's flattened richer evidence can change digest bytes. Digest verification
must be schema-aware and historical; Go struct round-tripping is insufficient
unless it preserves the original key set exactly.

### High integration risks

**Shallow pointer ownership.** Upstream adds pointer-valued
`ArtifactIdentity` and `IdentityPin`; Build 1's `cloneProviderSnapshot` does not
currently clone them, and `sameAdmissionProvider` does not compare them. A
prepared/guarded admission could observe a changed binding through a shared
pointer or fail to notice a replacement. Add immutable ownership and exact
comparison tests before relying on the guard.

**Retry of changed local bytes.** Build 1 correctly preserves the original
offer tuple and artifact hashes. Upstream separately recomputes GGUF identity at
initial submit. The reconciled retry must perform the same opened-file identity
and digest check; otherwise it can replay a valid signature for bytes no longer
present.

**Event persistence and replay domains.** Build 1 persists runtime source and
rich evidence and includes more values in positive-event behavior. Upstream
adds canonical algorithms and member fields to predicates but states that
admission events themselves carry no artifact evidence. Decide the combined
event schema once, migrate SQLite additively, and ensure coordinator event IDs,
generated replay keys, old-event readback, and CAS semantics remain stable.
Never infer rich authority for a legacy event.

**Member versus row key confusion.** The member hash/algorithm is the provider
wire and settlement identity; the candidate row hash/model ID is the Tier2 and
rate lookup identity; `model_key` is the economics key. Tests must use values
that differ so an accidental equality cannot conceal a swap.

### Moderate integration risks

- `SetAutotuneCatalog` intentionally drops the old member index before reload.
  Build 1 status/readback must report non-paid during this interval and must not
  revive a stored positive event using cached rich evidence.
- `settlement_receipts.go`, `buyer/route_snapshot.go`, `pool/provider.go`, and
  `main.go` apply textually but depend on conflicted types and owner ordering.
  Treat them as manual semantic merges.
- Current Build 1 tests named `PrimaryArtifact...` encode useful primary
  coverage but do not prove member behavior. Retain them as the direct-row arm
  and add a GGUF/member arm rather than renaming fixtures without changing data.
- Historical Build 1 review approvals were issued against the pre-c944
  contract. They remain evidence about their reviewed slice, not approval of
  the reconciled combined diff.

## Mandatory plan-compatibility gate

A new reviewed plan-compatibility addendum is mandatory before resolving the
eight conflicted implementation files. This follows from the existing Build 1
gate in `test-spec-r4.md` (independent plan approval precedes implementation)
and from the material contract change introduced by c944: the approved plan's
primary-only settlement premise is no longer true. Conflict resolution here is
architecture and behavior selection, not a mechanical merge.

The addendum must be paired with an updated test-spec revision and must decide,
before source edits:

- the selected-member versus candidate-row/Tier2/rate identity model;
- the canonical and historical sixth-field spellings and digest handling;
- feed/index/authority generation publication and lock order;
- ownership/comparison of `ArtifactIdentity` and `IdentityPin` in promotion
  guards;
- event/snapshot persistence compatibility and retry-time GGUF revalidation;
- which Build 1 preparation surfaces remain deliberately primary-MLX-only
  without narrowing the network settlement contract.

An independent plan reviewer must accept that addendum at zero Critical, High,
and Medium findings before conflicted implementation is changed. Existing r4
approval remains useful for unaffected transaction/UI work, but it cannot
authorize the new R007 choices. The normative spec reconciliation may be
drafted as input to the gate; it should not be represented as final or used to
drive implementation until the compatibility decision is approved.

The acceptance-test IDs whose criteria must be revised by that gate are exact:

| Acceptance ID | Required compatibility change |
|---|---|
| **B1-T01** | Add artifact-identity index uniqueness, verified/listed/recommendable status, release/freshness, feed/index generation, and wrong-release/signer cases. Retain all existing feed negatives. |
| **B1-T02** | Keep non-primary rejection explicitly scoped to the Build 1 **preparation command**. Remove any implication that this rejects non-primary network settlement. Add GGUF digest deadline/file-replacement protection where discovery supplies offer evidence. |
| **B1-T07** | Replace the single "exact primary" positive matrix with direct-row primary and feed-derived GGUF/member arms. Each authority mutation must run against both relevant arms; listed members remain non-paid. |
| **B1-T08** | Add races for feed/index generation replacement, member/pin replacement, catalog swap index clearing, and retry after local GGUF byte/inode change, in addition to withdrawal/reoffer/revocation and existing authority-owner races. |
| **B1-T09** | Exercise member hash versus row hash separation, the exact six-field spelling/migration, direct-row primary exemption, feed-derived primary/member inclusion, and immutable digest verification for historical c944 and Build 1 records. |
| **B1-T10** | The physical journey may remain one actual MLX primary journey, but its acceptance wording must say it proves that bounded arm only. It cannot be cited as coverage of GGUF/member settlement; separate fixture and/or physical evidence must be labeled accurately. |
| **B1-T11** | Preserve exact artifact hashes through offer/status/retry, recompute GGUF bytes before retry, and prove the bootstrap settlement uses coordinator-resolved member/feed authority rather than provider catalog or rate assertions. |
| **B1-T12** | Extend durable discovery identity tests to cover the upstream computed GGUF digest/cache semantics and file-identity changes without weakening existing HF/durable dedup and symlink protections. |

**B1-T03, B1-T04, B1-T05, B1-T06, B1-T13, and B1-T14 do not need their
acceptance meaning changed solely because c944 landed.** Their suites still need
fresh regression runs if their implementation files or shared fixtures change
during replay. B1-T13 remains the isolation gate for all new test keys, feed
fixtures, and coordinator endpoints.

## Required test reconciliation

Retain and rerun all tests mapped by c944's `SPEC-010-R007` conformance row,
including exact-pair index resolution, feed index construction, WS member
verification, GGUF settlement/no-binding refusal, six-field snapshot digest and
all-or-none checks, and Swift byte-digest/discovery tests.

Also retain the broader c944 regressions:

- `TestSettlementRejectsChangedOrMissingRecordedArtifactEvidence`
- `TestBYOMArtifactMemberRouteTimeGatesFailClosed`
- `TestArtifactBoundSessionWithoutMaterialIsExcludedFromRouting`
- `TestSecondaryMLXMemberWithoutAdmissionEvidenceNeverSettles`
- `TestGGUFAdmissionPredicateRequiresCompleteArtifactEvidence`
- `TestArtifactSessionMemberIsPinnedAcrossHeartbeats`
- `TestIdentityPinIsSeededAtRegistrationAndResetByAnyModelChange`
- offer parsing keyed by canonical artifact algorithms
- stale/release/provenance index tests and PoW member-drift tests

Replay Build 1's artifact authority, route recheck, settlement config, promotion
commit-boundary, transport teardown, retry/journal, expiry, contention, and
integration tests. Generalize their fixtures into at least these two positive
arms and matching negatives:

1. direct row-bound primary MLX using snapshot-manifest identity;
2. feed-derived non-primary GGUF using `macprovider.gguf-file.v1`, a distinct
   member hash, the candidate row hash for Tier2, and all six feed values.

Add or adapt tests for:

- any canonical algorithm accepted by rich `ArtifactAdmissionEvidence.Validate`;
- listed member matched but never priced/settled;
- stale/replaced/wrong-release/wrong-signer member rejected at promotion,
  route, and settlement;
- feed/index generation mismatch during SIGHUP;
- `ArtifactIdentity` and `IdentityPin` mutation/replacement caught at commit;
- GGUF bytes changed or inode replaced between offer and retry;
- canonical versus historical sixth-field spelling and digest preservation;
- direct-row primary with no six-value extension versus feed-derived primary
  with the extension;
- distinct member hash, row hash, model ID, artifact ID, and model key through
  real buyer route and receipt-verified exactly-once settlement;
- legacy admission event/snapshot readback does not acquire R007 authority;
- Build 1's real-service integration test settles a member without provider-
  asserted catalog or rate authority.

Suggested focused commands after compilation succeeds:

```bash
cd phase3-binary && swift test --filter BYOMArtifactDigestTests
cd phase3-binary && swift test --filter BYOMAdmissionTests
cd phase4-coordinator && go test ./internal/artifactidentity ./internal/billing ./internal/buyer ./internal/pool ./internal/ws ./internal/pow
cd test/integration && go test -race -count=1 -run 'TestBuild1(ArtifactAdmissionSettlesThroughRealServices|PaidRouteRejectsClosingBeforeStatusRevocation|CLIServiceBridge)'
```

Then run the repository gates appropriate to the final combined diff:

```bash
cd phase3-binary && swift test
make test-coordinator
make test-integration
make test-dist
make vet
make lint-coordinator
```

Never count a pre-reconciliation run, interrupted run, or fixture-only success
as evidence for the reconciled branch.

## Governance and documentation updates

1. Base all governance checks on the then-current `origin/main`, starting with
   c944, not `914f7caf`.
2. Keep c944's SPEC-010 1.7, SPEC-023 v0.10.3, and SPEC-047 v0.1.4 files and
   conformance mappings. Version the Build 1 SPEC-047 amendment after 0.1.4.
3. Regenerate `specs/README.md` and any authority/conformance indexes after the
   final spec edits; do not preserve the local stale 010/023 rows.
4. Update `pr-body-draft.md`. The declaration currently omits SPEC-010 and
   SPEC-023 even though the final behavior consumes R007 identity and SPEC-023
   feed provenance. The final declaration should include at least
   `SPEC-010-R007`, the applicable SPEC-023 artifact-feed/freshness requirements,
   and the reconciled SPEC-047 R001/R003/R006/R008 authority/test changes,
   alongside existing Build 1 requirements. Keep `model-catalog-identity`,
   `network-model-admission`, `billing-settlement-formula`, and
   `verified-model-settlement` authority domains; add the installer/autotune
   feed domain if required by the validator's current authority map.
5. Validate the exact final PR body with
   `scripts/check_spec_pr_declaration.py` and run
   `scripts/check_spec_governance.py --base-ref origin/main`. Do not reuse the
   earlier passing governance result from before #1469.
6. Update `qualification-blockers.md`, current gate logs, acceptance status,
   plan r4, and test spec r4 to distinguish the bounded Build 1 primary-MLX
   journey from platform-wide R007 member settlement.
7. Re-run the required full combined code, security, and architecture audit
   lanes against the complete diff from c944 (or a later main) to the final
   tree. Prior slice approvals do not satisfy the zero Critical/High/Medium
   combined-diff gate.

## Ordered safe integration procedure

1. **Freeze evidence.** Before touching the dirty worktree, record its HEAD,
   tracked patch, untracked manifest, and checksums in a private local recovery
   location. Check the manifest for secrets and keep operator material outside
   all worktrees. Do not use `git clean`, reset, or an implicit stash that can
   lose the 84 untracked paths.
2. **Create a clean reconciliation worktree.** Fetch/prune and create a fresh
   hidden MacProvider task worktree and branch from the exact current
   `origin/main` (at least c944). Keep the dirty Build 1 worktree as read-only
   recovery evidence until the replay is complete.
3. **Confirm the upstream baseline.** Run the focused c944 R007 Swift and Go
   tests before replay. This separates an upstream failure from a Build 1
   integration failure.
4. **Pass the plan-compatibility gate.** Draft the contract/schema/concurrency
   addendum and revised acceptance matrix described above. Obtain independent
   zero-Critical/High/Medium plan approval before editing any of the eight
   conflicted implementation files.
5. **Reconcile normative contracts.** Preserve SPEC-010 1.7 and SPEC-023
   v0.10.3; write the Build 1 SPEC-047 additions as the next revision with
   member-neutral language; remove the R007 tombstone; regenerate indexes; run
   governance checks. Resolve the sixth-field spelling and legacy interpretation
   here, before code selects a schema.
6. **Replay independent Build 1 UI/storage work in bounded groups.** Bring over
   transaction storage, retention, local catalog reads, app/CLI views, and
   tests that do not touch R007 seams. Restore upstream `Package.resolved`
   exactly. Compile and test each group.
7. **Compose Swift BYOM discovery.** Start from c944's `BYOMDiscovery.swift` and
   `BYOMArtifactDigest.swift`. Add durable discovery/catalog inspection and
   pending-offer/retry features through the upstream digest interfaces. Run
   digest, discovery, admission, retry, journal, and transaction tests.
8. **Adopt upstream coordinator identity types unchanged.** Wire
   `artifactidentity.Index`, `Binding`, `Provider.ArtifactIdentity`, and
   `IdentityPin` through Build 1 clones and guards. Add ownership/equality tests
   before changing positive admission.
9. **Generalize the Build 1 authority resolver.** Build the rich authority from
   the exact upstream member binding plus separately verified row/Tier2,
   billing, session, receipt, sanction, lease, probe, and feed generation.
   Retain a direct-row primary arm. Remove primary-only algorithm/runtime
   assumptions only when their replacement predicates are present.
10. **Unify feed/index publication and promotion serialization.** Ensure boot,
   SIGHUP, catalog swap, feed observer, prepared authority, CAS, and teardown
   share a verifiable generation/provenance boundary. Exercise reload and lock
   ordering under race tests.
11. **Define one snapshot/event persistence schema.** Compose upstream six-
    value binding with Build 1's richer immutable record, implement explicit
    old-schema decoding/digest verification, and make SQLite migration additive.
    Run round-trip, corruption, wrong-signer, cross-release, extension-loss,
    legacy, and retry/replay tests before buyer routing.
12. **Compose buyer routing and settlement.** Start with c944's member-aware
    helpers and add Build 1 current-authority rechecks, revocation, captured
    rates, and transport availability. Validate member/row/key separation with
    intentionally distinct fixture values and real receipt settlement.
13. **Run focused and full gates.** Run the commands above, then all changed-
    surface static checks. Update acceptance evidence only with fresh results
    from the reconciled commit.
14. **Audit and review the landable diff.** Confirm
    `git log origin/main..HEAD` contains only this task, validate the final PR
    declaration, and run independent code, security, and architecture review on
    the full c944-to-final diff. Land only with 0 Critical, 0 High, and 0 Medium
    findings; carry Low/Info explicitly.
15. **Retire recovery state only after merge.** After merge and canonical-main
    synchronization, remove clean obsolete worktrees and prune. Keep no operator
    keys, payout material, or signing material in either worktree.

## Stop conditions for reconciliation

Reconciliation is not complete until all of the following are true:

- no local R007 tombstone or current "#1469 unmerged" claim remains;
- specs and code agree on the exact six serialized field names and historical
  digest handling;
- primary-row and feed-member identities both pass positive and negative
  admission/routing/settlement tests;
- Build 1 guards own and compare `ArtifactIdentity` and `IdentityPin`;
- retry cannot submit stale GGUF bytes;
- feed/index generation mismatch is proven non-paid;
- SPEC/governance validators pass against the new base;
- Swift, coordinator, integration, dist, vet, and applicable lint gates pass;
- the final combined code, security, and architecture audits report zero
  Critical, High, and Medium findings.
