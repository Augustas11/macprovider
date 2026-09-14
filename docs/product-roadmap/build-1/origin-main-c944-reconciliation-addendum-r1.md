# Build 1 origin/main c944 reconciliation addendum r1

Status: proposed; implementation is blocked until an independent GPT-5.6 Sol
review reports zero Critical, High, and Medium findings.

## Repository and trigger

- Build 1 worktree base: `914f7cafcdbcfc1805a10f4f34167218341d5587`.
- Current `origin/main`: `c9445561e4fe00a073926ff2ab0fdb0536d00e37`.
- Trigger: PR #1469 landed the SPEC-010 R007 GGUF settlement-identity slice after
  Build 1 implementation began.
- Stop condition: the Build 1 diff is replayed on c944, preserves upstream
  artifact identity and settlement evidence, retains the approved Build 1
  authority/recovery behavior, and passes the tests below. This addendum does
  not authorize deployment, economic activation, release, or the separate
  unlanded BYOM slice 4 branch.

## Normative compatibility contract

1. Preserve c944's verified-member model: a listed and recommendable artifact
   feed member may provide settlement identity; GGUF is not rejected merely for
   being non-primary.
2. Preserve c944's six-field immutable artifact evidence and its all-or-none
   persistence, route snapshot, receipt, and settlement validation.
3. Preserve c944's session artifact pinning, exact pair resolution, provenance
   freshness, and fail-closed missing-material behavior.
4. Replay Build 1's authority lock, CAS, retry, revocation, closing-session,
   pricing, and durable-catalog changes over those contracts. Generalize these
   checks over the selected verified member; do not restore primary-only
   SnapshotManifest authority.
5. Preserve the approved catalog-read CC08 binding of all four signed feed
   selections and the selected row's exact model ID, revision, digest, source,
   and size. This is compatible with verified GGUF members and must remain so.
6. Remove the local SPEC-010 R007 pending tombstone and every statement that
   PR #1469 is unmerged. Accept c944's normative implementation and conformance
   entries as the new base.
7. Restore c944's dependency pins exactly. Build 1 does not change dependencies.
8. Do not incorporate or assume the unlanded
   `feat/byom-v02-slice4-decision-path` branch.

## Required design decisions

### Identity domains

Keep four identities distinct through promotion, routing, and settlement:

- the provider wire/settlement pair: canonical artifact algorithm plus member
  hash;
- the candidate row model ID/hash used for Tier2 eligibility and rate lookup;
- the artifact ID and feed provenance used to prove verified membership; and
- the economics `model_key` used to select the authoritative rate.

Fixtures must deliberately give these fields different values. Direct
row-bound primary MLX uses snapshot-manifest identity and no six-value artifact
extension. A feed-derived primary or non-primary member carries the complete
six-value extension. A merely listed member remains non-paid.

### Serialized compatibility

New snapshots and receipts use the normative sixth key
`candidate_catalog_sha256`. Historical c944 records using
`artifact_candidate_catalog_sha256` retain a distinct decode and digest-
recompute path over their original key set. The decoder rejects both spellings
together, partial evidence, disagreement with the authenticated binding, and
unknown schema versions. It never rewrites historical snapshots or reconstructs
the value from a current feed. The migration is additive and legacy admission
events never acquire artifact authority by inference.

### Feed/index publication and locking

The coordinator publishes one immutable artifact-authority generation containing
the four verified feed selections, exact release/digests/signers, the derived
member index, and a monotonically increasing generation. The feed observer
builds and validates the next object before acquiring the Build 1 admission-
authority publication lock; the lock swaps the whole object once. Promotion
preparation captures that object and its generation. Commit, status refresh,
route snapshot, retry, and settlement compare the same generation and exact
member/provenance. Catalog replacement clears paid eligibility before the new
generation becomes observable. Lock order remains authority publication,
session publication/session writer, pool provider pin, then store CAS; no feed
callback may acquire these locks in reverse.

### Provider ownership and retry

`cloneProviderSnapshot` deep-copies `ArtifactIdentity`, its nested member and
provenance, and `IdentityPin`; `sameAdmissionProvider` compares their complete
values. No prepared guard retains a pointer owned by the mutable pool. GGUF
retry reopens the local file without following substitutions, verifies device,
inode, size and digest under the existing deadline, and rejects changed bytes
before reusing an offer signature or positive event.

### Event and preparation scope

Use one additive admission-event schema/version for Build 1 fields. Preserve
c944 event IDs and replay/CAS behavior; old events decode but cannot be upgraded
to rich authority. Build 1's preparation command remains deliberately limited
to its supported primary MLX artifact. That UX restriction does not narrow the
network settlement contract for coordinator-verified GGUF or other listed and
recommendable feed members.

## Exact overlap and ownership

The dirty Build 1 tree and c944 overlap in 15 paths:

- `phase3-binary/Sources/macprovider-cli/BYOMDiscovery.swift`
- `phase3-binary/Tests/macprovider-cliTests/BYOMAdmissionTests.swift`
- `phase4-coordinator/cmd/coordinator/main.go`
- `phase4-coordinator/internal/billing/route_snapshot.go`
- `phase4-coordinator/internal/billing/settlement_receipts.go`
- `phase4-coordinator/internal/buyer/autotune_feeds.go`
- `phase4-coordinator/internal/buyer/model_admission.go`
- `phase4-coordinator/internal/buyer/route_snapshot.go`
- `phase4-coordinator/internal/buyer/server.go`
- `phase4-coordinator/internal/pool/provider.go`
- `phase4-coordinator/internal/ws/model_admission.go`
- `phase4-coordinator/internal/ws/server.go`
- `specs/CONFORMANCE.json`
- `specs/README.md`
- `specs/SPEC-047-network-model-admission.md`

Synthetic three-way application predicts textual conflicts in eight paths:
`BYOMDiscovery.swift`, billing `route_snapshot.go`, buyer `autotune_feeds.go`,
buyer `model_admission.go`, buyer `server.go`, WS `model_admission.go`, WS
`server.go`, and `specs/CONFORMANCE.json`. Root owns reconciliation. No agent
may resolve these files independently while another lane is editing them.

## Phased procedure

1. Freeze all Build 1 source writers. Restore `phase3-binary/Package.resolved`
   from c944. Run diffcheck and a secret/path hygiene scan.
2. Create a local Lore-protocol checkpoint commit so the complete uncommitted
   Build 1 state is recoverable. Do not push it.
3. Rebase that checkpoint onto c944. For each conflict, start from c944's
   artifact-identity shape and replay only the independently approved Build 1
   behavior. Never choose a whole-file side for the eight predicted conflicts.
4. Remove superseded tombstones/narrative and regenerate or hand-reconcile
   governance indexes according to repository tooling. Review the exact diff
   from c944, including files added by c944 that Build 1 does not modify.
5. Run targeted compatibility tests, then Build 1 focused tests, then the
   broader Swift, coordinator, gateway, integration, vet, lint, governance, and
   Xcode gates. Restore `Package.resolved` again after the last Swift command.
6. Run fresh complete-diff GPT-5.6 Sol code, security, and architecture audits.
   Fix and repeat until every lane reports zero Critical, High, and Medium.

## Verification specification

Targeted c944 preservation:

- Swift `BYOMArtifactDigestTests` and affected `BYOMAdmissionTests`.
- Go artifact identity index tests.
- Billing artifact-evidence digest, all-or-none, and changed/missing-evidence
  tests.
- Buyer six-value settlement, missing binding, route-time fail-closed,
  missing-material, and secondary-MLX negative tests.
- Pool session pinning/reset tests.
- WS exact-member, complete-evidence, and canonical-algorithm tests.

Targeted Build 1 preservation:

- The approved T06/T10/T11 buyer, WS, and closing-route race selections.
- Signed authority, drift, retry, CAS, revocation, settlement, catalog-read
  CC01-CC09, catalog lifecycle CR01-CR13, app bridge, and executable bootstrap
  selections recorded by the Build 1 test specification.
- `python3 scripts/check_spec_governance.py --base-ref origin/main` and the PR
  governance declaration validator against the final c944-based diff.

Negative acceptance requires rejection of incomplete or substituted six-field
evidence, unlisted or stale feed members, changed session pins, missing material,
stale authority heads, closing/revoked sessions, rate/model drift, corrupt
catalog evidence, and unsupported models. A provider assertion, primary flag,
or successful preparation alone must not authorize paid settlement.

The reconciled acceptance meanings are:

- B1-T01 adds exact-pair index uniqueness, verified/listed/recommendable state,
  feed/index generation, and wrong-release/signer cases.
- B1-T02 scopes non-primary rejection only to the primary-MLX preparation
  command and adds GGUF digest deadline and file-replacement negatives.
- B1-T07 has direct-row primary and feed-derived member positive arms, with
  each authority mutation applied to both relevant arms.
- B1-T08 adds feed/index replacement, member/pin replacement, catalog-clear,
  and changed-file retry races.
- B1-T09 separates member and row hashes and proves canonical plus historical
  sixth-key digest handling, direct-row exemption, and feed-derived inclusion.
- B1-T10 remains a bounded physical primary-MLX journey and cannot qualify
  GGUF/member computation or settlement.
- B1-T11 preserves artifact hashes through retry, recomputes GGUF bytes, and
  proves coordinator-owned member/feed and rate authority.
- B1-T12 adds computed GGUF cache/file-identity changes while retaining HF
  durable deduplication and symlink protections.

B1-T03, T04, T05, T06, T13, and T14 retain their approved meanings but receive
fresh regression runs when shared implementation or fixtures change.

## Rollback and observability

The pre-rebase checkpoint commit is the rollback anchor. On an ambiguous
semantic conflict, abort the rebase and return to that anchor; do not guess.
Reconciliation evidence records the old base, new base, conflict resolutions,
file hashes, exact commands/results, selected/pass/fail/skip counts, and any
remaining physical or operator qualification blocker. No production telemetry
or operator state is changed by this procedure.

## Non-goals and blockers

- No implementation from unlanded BYOM slice 4.
- No economic activation, deployment, release, merge, payout, or enforcement.
- No claim that deterministic fixtures establish physical MLX computation.
- Physical signed-feed preparation through real MLX inference and settlement
  remains a separate qualification blocker.
