# Active BYOM slice 4 overlap assessment

Date: 2026-09-10  
Assessment mode: read-only repository analysis; this report is the only file created.  
Build 1 worktree: `/Users/augstar/.codex/worktrees/macprovider/product-build-1`  
Build 1 HEAD: `914f7cafcdbcfc1805a10f4f34167218341d5587` with the existing uncommitted Build 1 implementation.  
Active slice worktree: `/Users/augstar/macprovider-byom-v02-slice4`  
Active slice branch/current head: `feat/byom-v02-slice4-decision-path` at `d1ce1a64fbab5eb9330183cf849eea61d77bd1bd`.  
Comparison base: `origin/main` at `c9445561e4fe00a073926ff2ab0fdb0536d00e37`.  
Scope boundary: no source, spec, test, or either worktree's existing files were modified; the prohibited external source tree was not inspected.

## Assessment snapshots

- **Prior snapshot:** `bf12b068a7f4543a3629a9fe3d641dbb12e4ccee`, assessed in
  the first version of this report; report SHA-256
  `46b8764ff797d1c0137a2d4704569337fd600885af982bf866dcdca147e665c5`.
- **Current snapshot:** `d1ce1a64fbab5eb9330183cf849eea61d77bd1bd`, three commits
  after the prior snapshot (`0a6b60a7`, `48fd54ef`, `d1ce1a64`). These commits
  add R3/R4 corrections to SPEC-047 and the SPEC-010 v1.8 composite-proof
  clarification. They change the affected admission gate details described
  below, but do not change the top-level conclusion that an unmerged branch is
  not current Build 1 authority.

## Question and conclusion

The question is whether the unmerged slice 4 SPEC-047 v0.1.5 / SPEC-010 v1.8
proposal changes Build 1's scope or gates, and which Build 1 work remains valid
without assuming that proposal lands.

**Conclusion:** the active branch does not presently reopen Build 1 because it
is not part of `origin/main`: it has no PR, changes only five audit/prompt
documents and four spec/index files, contains no runtime implementation, keeps
SPEC-047 in `draft` / pending conformance, and has not changed the applicable
merged contract. Build 1 must therefore not implement or claim v0.1.5/v1.8 as
authority on the branch's existence alone.

If v0.1.5 lands before Build 1 is frozen for review, it **materially reopens the
coordinator admission portion** of the Build 1 plan and implementation gate.
The affected scope is Build 1 phases 5-6 and tests B1-T07, T08, T09, the
admission portion of T10/T11, plus the S2 promotion-authority addendum, the
SPEC-010/SPEC-047 composite-proof reconciliation, and the combined
code/security/architecture audit. It does not require restarting the whole
Build 1 plan: local preparation, durable artifact transactions, catalog read,
recommendation/adoption, app presentation, and their non-admission tests remain
independent.

Build 1 already has a separate, current reconciliation obligation: its worktree
is based on `914f7caf`, one commit behind `origin/main`, and
`acceptance-status.md` explicitly says merged `c9445561` (slice 3 GGUF
settlement identity) must be reconciled before final regression, audit, commit,
or PR preparation. The slice 4 proposal compounds that existing gate because it
is based on `c9445561` and assumes the slice 3 identity-set semantics. It did not
create the already-open slice 3 reconciliation.

## Ranked synthesis

| Rank | Finding | Severity | Confidence | Consequence | Action |
|---:|---|---|---|---|---|
| 1 | v0.1.5 replaces Build 1's provider-triggered automatic positive promotion with an operator decision path as the sole production caller for `catalog_priced` / `settlement_capable` decisions. | HIGH if merged; no present merged defect | High | Current Build 1 offer/retry flow can call `promoteModelAdmission` after the synthetic probe and append both positive states. That would violate the proposed transition-origin contract. | Do not import the unmerged API now. If it lands, reopen the bounded admission plan and replace the positive-state trigger with the closed operator decision and offer-list endpoints; preserve synthetic probes only for their allowed non-settlement transitions. |
| 2 | v0.1.5 requires offer-time two-path catalog resolution, a durable tagged member set, and an exact row/release tuple, while Build 1 currently discards the signed `artifact_hashes` after request verification and persists one selected authority tuple. | HIGH if merged | High | The current event/store schema cannot represent `catalog_match_state`, multiple `catalog_members`, feedless `candidate_row` members, recorded row identity, the offer's exact release tuple, or an unmatched offer with a coordinator-derived null catalog key. Promotion, retry, persistence/migration, listing, drift, and route binding would all need reconciliation. | If merged, add a plan/test addendum before changing event storage. Preserve every resolved member and its source/provenance plus the authenticated row/release tuple at offer append; never reinterpret the provider-asserted key as catalog identity. Reconcile this together with landed SPEC-010 R007 non-primary identity support and v1.8 composite proof. |
| 3 | v0.1.5 defines one decision serialization domain covering idempotency lookup/reservation, decision preconditions/head append, every session-to-candidate binding mutation, feed/catalog reloads, drift, and BYOM route-snapshot persistence. Build 1's guard is narrower. | HIGH if merged | High | Build 1 serializes a positive decision append with live owner pins, but offer/withdrawal append, reload/drift handling and route-snapshot insert are not under the same admission serialization. `recordRouteSnapshot` validates BYOM authority and later calls `InsertRouteSnapshot`; there is no atomic head/binding reread immediately before that insert. The new head also makes replacement hello and receipt-key loss explicit drift producers. | If merged, reopen concurrency architecture and B1-T08/T09. Either introduce the named critical section or prove an equivalent atomic compare-and-insert spanning the exact v0.1.5 mutation set. Add concurrent same-key outcomes and hello/receipt/release drift cases, then rerun all interleaving/race and immutable-snapshot tests. |
| 4 | The active branch is a reviewed proposal, not current authority or implementation evidence. | MEDIUM | High | Treating it as landed would make Build 1 depend on an unmerged branch and unimplemented endpoints. The new head now contains R3 and R4 audit records, but R4 says the anchored loop is closed with a required independent cold-context review still outstanding. | Continue against the pinned merged contract. At final source freeze, fetch/recheck `origin/main`, the active branch/PR and cold-review state, and the actual SPEC-010/SPEC-047 versions. Use merged evidence only. |
| 5 | Build 1 and slice 4 have direct textual conflicts in the same normative paragraphs and generated indexes. | MEDIUM if merged | High | Both change `specs/SPEC-047-network-model-admission.md`, `specs/CONFORMANCE.json`, and `specs/README.md`; both edit R003/R008 and the v0.1.4/v0.1.5 history. A mechanical merge could drop Build 1's immutable-evidence/release-test requirements or slice 4's decision/member-set requirements. | Perform a manual three-way normative reconciliation and regenerate/check indexes. Do not choose one whole-file side. Re-run spec governance and the SPEC-047 contract locks on the resolved document. |
| 6 | Most Build 1 client/product work and several safety foundations do not depend on v0.1.5's operator decision shape. | INFO | High | These lanes can continue without creating an unmerged dependency. Some admission tests will remain reusable as lower-level invariants even if their final orchestration changes. | Continue the independent work listed below; keep final acceptance claims tied to the merged contract at review time. |

## Exact contract and implementation overlap

### Direct file overlap

At current head `d1ce1a64`, the active branch differs from `c9445561` in exactly
nine files:

- five new audit/prompt records under `audits/2026-09-10-byom-v02-slice4/`;
- `specs/SPEC-010-model-catalog.md`;
- `specs/SPEC-047-network-model-admission.md`;
- `specs/CONFORMANCE.json` (SPEC-010 `1.7` -> `1.8` and SPEC-047
  `0.1.4` -> `0.1.5`);
- `specs/README.md` (the corresponding generated version rows).

Build 1 directly edits three of those files: SPEC-047, CONFORMANCE, and README.
Its current SPEC-047 edits add
the pending-offer retry, coordinator-owned promotion predicates, the all-or-none
six-field immutable artifact record, concurrency requirements, legacy snapshot
preservation, and expanded R008 artifact-promotion tests. Slice 4 edits the
same R003 and R008 regions and therefore cannot be merged by accepting either
whole paragraph unchanged.

SPEC-010 is not a direct dirty-file collision in the Build 1 worktree, but it
is part of Build 1's already-required reconciliation with `c9445561`. The new
v1.8 sentence explicitly separates the two halves of a non-primary composite
proof: Tier2 row material proves catalog row/pricing identity, while the
member's hash is proven only by its six immutable SPEC-047 values. The branch
labels this a clarification of slice 3 behavior, not a new runtime behavior.

### Behavioral overlap

1. **Decision origin and API.** Active SPEC-047 lines 107 and 149 define
   `POST /admin/model-admission/decisions` and
   `GET /admin/model-admission/offers` and make the operator request the one
   production caller for the positive admission decisions. Build 1 currently
   registers provider offer/retry/withdraw/status routes in
   `phase4-coordinator/internal/ws/server.go:1437-1440`, but has no model
   admission operator decision/list routes. Its
   `maybeRunModelAdmissionSyntheticProbeForOffer` calls
   `promoteModelAdmission` (`server.go:4232-4252`), and retry does the same for a
   pending positive candidate (`model_admission_retry.go`).

2. **Offer-time identity.** Active SPEC-047 lines 111 and 123 require every
   signed offered pair to resolve at offer time through independent primary-row
   and artifact-feed paths, with the matched member set stored on the offer
   event. Build 1 accepts and signs `artifact_hashes`
   (`model_admission.go:1711-1733`, `1789-1809`) but
   `verifyModelAdmissionOffer` constructs a `ModelAdmissionEvent` without those
   hashes or a resolved member set (`1553-1616`). The event type has neither
   `catalog_match_state` nor `catalog_members` (`71-103`).

   At `d1ce1a64`, the offer event must also record
   `catalog_row_model_id`, `catalog_row_model_sha256`, `catalog_release_id`,
   `catalog_candidate_sha256`, and `catalog_signer_key_id`. Later decision and
   route checks compare both that exact offer release and the selected member;
   a compatible-previous session or rotated-release offer fails with
   `catalog_release_mismatch`.

3. **Identity cardinality.** Active v0.1.5 carries forward merged SPEC-010 R007:
   primary plus GGUF or other verified members of one key can be recorded, and
   the exact verified live-session member is chosen at settlement-capable
   decision time. Build 1's current positive admission predicate and route
   snapshot remain single-primary shaped: `modelAdmissionEventHasTrustedCatalogAuthority`
   requires `macprovider.snapshot-manifest.v1`
   (`model_admission.go:991-1005`), and buyer route snapshot validation also
   requires that algorithm (`internal/buyer/route_snapshot.go:59-65`,
   `internal/buyer/model_admission.go:150-163`). This is already inconsistent
   with merged `c9445561`; v0.1.5 makes the required member-set representation
   explicit rather than creating the underlying slice 3 mismatch.

   SPEC-010 v1.8 R004 now makes the proof split explicit: row material proves
   the row and pricing key, while only the recorded six-field member evidence
   proves a non-primary member hash. Build 1's final B1-T07/T09 evidence must
   demonstrate that neither digest is accepted as proof of the other.

4. **Session-to-candidate binding.** Active SPEC-047 line 123 requires a
   coordinator-derived binding of candidate id, resolved key, and current event
   id; it is derived at hello/offer, refreshed on each event, cleared on
   withdrawal/revocation/model change/disconnect, and ambiguity binds nothing.
   Build 1 uses `pool.Provider.ModelAdmission*` markers and otherwise searches
   latest events by served reference or catalog key
   (`internal/buyer/model_admission.go:49-108`). That lookup is useful
   fail-closed compatibility logic, but it is not the proposed explicit binding
   lifecycle and event-id equality contract.

5. **Serialization and snapshot finality.** Build 1's guarded append holds the
   model-admission store serialization and pins current resolver, session,
   registry, feed, billing, settlement and Tier2 owners through positive event
   insertion/transaction completion
   (`internal/ws/model_admission_commit.go:14-85`,
   `model_admission_authority.go:78-167`, and
   `model_admission.go:243-304` / `648-735`). This is a strong compatible
   foundation. Active v0.1.5 is broader: offer/binding mutations, reload drift,
   and route-snapshot creation must share the decision critical section. Build
   1 currently calls `requireBYOMRouteSnapshotBinding`, builds the snapshot, and
   then calls `InsertRouteSnapshot` separately
   (`internal/buyer/route_snapshot.go:77-152`).

6. **Drift and tests.** Build 1 already has live authority revalidation,
   transport-closing publication, CAS revocation, owner pin tests, and extensive
   promotion/route tests. Active lines 131 and 135 add exact drift reasons and
   sweeps for identity verdict, feed provenance, catalog row identity/status,
   decision-vs-reload/session races, offer listing, closed schemas, and
   byte-for-byte unchanged provider status. Existing tests are useful evidence,
   but they do not satisfy the new R008 matrix or endpoint contract.

   The current head additionally requires: idempotency lookup and key
   reservation inside the critical section; reserved/disjoint operator,
   validator, probe and drift reason sets; `offer_submitted` -> `offer_rejected`
   validator events; replacement hello evaluated against the prior binding
   before publishing the new one; `receipt_key_unavailable`; disconnect as a
   binding clear without a durable transition; and exact offer/session release
   equality. These sharpen B1-T07/T08/T09 and the admission portion of T11.

## What can proceed without assuming slice 4 lands

The following work remains within Build 1's current approved outcome and can
continue against `c9445561`:

- Swift CLI and Malibu app work for catalog read, durable model discovery,
  prepare/cancel/cleanup transactions, measured prepared-only recommendation,
  explicit local adoption, restart recovery, progress, and truthful
  non-economic presentation.
- Durable artifact storage, retention, cleanup, ownership/lifetime protection,
  local inspection, transaction journaling, migration safety, and their tests.
- Provider-signed offer/status/withdraw/retry envelope validation, replay/CAS
  safety, abuse bounds, and the unchanged `model_admission_status.v1` client
  contract. Do not make successful retry imply automatic positive promotion in
  new product assertions.
- Settlement storage, all-or-none immutable provenance, old-snapshot digest
  compatibility, receipt verification, exactly-once accounting, and fail-closed
  routing/billing checks. Keep row proof and member proof as separate fields and
  predicates; member-representation-specific admission wiring must still
  reconcile merged slice 3 and any later v0.1.5.
- Owner-local copy/pin APIs, monotonic WS closing publication, exact-session
  availability, fail-closed missing-capability behavior, and tests showing
  mutations cannot invalidate a committed authority decision. These foundations
  are compatible with the stricter proposed critical section even though they
  do not implement it by themselves.
- Existing focused and broad regression runs for the unchanged surfaces. Keep
  their evidence labels local/current and rerun the admission subset after any
  normative reconciliation.

Work that should **not** claim finality until the merged contract is known:

- final source freeze or combined audit for coordinator positive admission;
- approval of the automatic offer/retry-to-`settlement_capable` orchestration as
  the production decision path;
- final admission event/store schema, offer-validator behavior, or migration
  freeze;
- final B1-T07/T08/T09 and admission portions of T10/T11 acceptance;
- final SPEC-010/SPEC-047/CONFORMANCE/README resolution, governance
  declaration, commit, or PR diff.

This is not a request to pause Build 1. It is a boundary on what can be treated
as final. Immediately before final regression/audit/PR preparation, compare the
Build 1 diff with fresh `origin/main`. If v0.1.5 has not landed, audit the Build
1 admission implementation against merged v0.1.4 plus the already-required
slice 3 reconciliation. If v0.1.5 has landed, write and independently approve a
bounded admission-plan/test addendum, reconcile the implementation surfaces
above, and rerun the affected race, integration, governance, and three-lane
combined-diff gates.

## Evidence versus inference

**Evidence**

- Active branch `d1ce1a64` is seven commits ahead of `c9445561` and its diff is
  limited to the nine files listed above; no runtime implementation is present.
- Active SPEC-047 v0.1.5 lines 107, 111, 123, 131, 135 and 149 directly define
  the operator caller, offer-time member set, decision/session/snapshot critical
  section, live drift, release tests and implementation step.
- Active SPEC-010 v1.8 R004 lines 1041-1065 directly defines the composite
  row/member proof and states that the two proof halves are not substitutes.
- Build 1 plan revision 4 lines 27 and 163-190 places positive promotion and
  immutable settlement evidence in its coordinator lanes; test spec lines
  14-18 maps the relevant T07-T11 gates.
- Build 1 acceptance status lines 13-17 and 41-68 keeps those gates open and
  explicitly requires reconciliation with merged `c9445561` before final work.
- The Build 1 source locations cited in the overlap section directly show its
  present automatic promotion, event shape, single-primary predicate, narrower
  guard and separate snapshot insert.

**Inference**

- Because v0.1.5 changes the authorized production caller, persisted identity
  shape, exact-release binding, drift origins and serialization boundary,
  landing it before Build 1 would require a substantive bounded plan/test
  revision rather than a test-only addendum.
- Because the invariant goals remain fail-closed paid admission, immutable
  route evidence and exactly-once verified settlement, the non-admission lanes
  and several owner/safety foundations remain valid and need not be restarted.

**Unknowns / limits**

- The repository does not establish whether or when the active branch will get
  a PR, its required independent cold-context review, implementation, or merge.
- This assessment does not assert that the proposed v0.1.5 contract is final or
  that its future implementation will use the same internal architecture as
  Build 1.
- No runtime tests were run because the requested task was read-only contract
  overlap analysis; existing Build 1 test reports were treated as evidence with
  their recorded limitations.
