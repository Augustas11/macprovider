# Build 1 reservation/preparation authority v2 formal adversarial review

Date: 2026-09-12

Reviewer lane: independent Sol formal authority/feasibility gate

Verdict: **BLOCK**

Finding count: **0 Critical, 4 High, 5 Medium, 0 Low**

The acceptance gate requires zero Critical, High, and Medium findings. The
authority correction does not meet that gate. This review uses repository
evidence only and treats the supplied implementation ancestry as a future T18
promotion check, not as a present planning defect.

## Reviewed immutable inputs

- Base: `origin/main` =
  `f7e584499828b3d16036382848b5caa1a897cdf9`.
- Pinned plan revision:
  `050921df1092ed2ee3d96178beca556b6366ad6a`.
- `reservation-rebaseline-plan-v6.md` SHA-256:
  `a682d6b7caade4540e56f042d6ba9d70731af493a56abaa78c6fff18fede9678`.
- `reservation-rebaseline-test-spec-v6.md` SHA-256:
  `1c56872db5855b91916661bd2672f4a903300762db3ba390ca1227271b73cb89`.
- Authority revision:
  `f691de4d12250b97d86d91be7333d29db1ee5f20`.
- Cumulative authority diff:
  `origin/main...f691de4d12250b97d86d91be7333d29db1ee5f20`, including
  SPEC-001, SPEC-044, `AUTHORITY.json`, `CONFORMANCE.json`, the generated spec
  index, and the preserved v1 review.

The authority history is linear from the pinned base. The landed BYOM Slice 5
and Slice 6 prerequisite commits are ancestors of the authority revision.

## Findings

### B1-AUTH-V2-H1 — High — The pinned plan and tests still accept an incomplete v1 advertisement

**Evidence.** SPEC-044-R001 at
`specs/SPEC-044-malibu-model-catalog-economics.md:94` and SPEC-001-R003 at
`specs/SPEC-001-phase3-binary.md:3269-3277,3318-3325` require the complete v1
pair `model_catalog_economics_v1` plus `models catalog-economics.v1`. Partial,
dual, or conflicting advertisement must fall back without a catalog-economics
call. The pinned plan instead defines `v1 capability only` as sufficient at
`reservation-rebaseline-plan-v6.md:61,64`. T01 states that a v1-serving CLI
contains only `model_catalog_economics_v1` at
`reservation-rebaseline-test-spec-v6.md:42`, and T15 accepts `v1 only` at
`:297,300` without requiring the command-schema token.

**Consequence.** The acceptance corpus can approve an implementation that
violates both owner requirements and invokes an ambiguous v1 surface. The
preserved v1 High finding on deterministic version selection is therefore not
resolved end to end.

**Required correction.** Make every plan and test matrix name and require the
exact v1 capability/token pair. Add explicit capability-only, token-only,
dual-generation, and manifest/local-status disagreement negatives for both
generations. A read is allowed only after one exclusive complete pair.

### B1-AUTH-V2-H2 — High — The required `coordinator:not_offered` journey cannot form a valid guidance binding

**Evidence.** The v2 amendment requires every coordinator-sourced binding to
carry a non-null `source_coordinator_event_id` at
`specs/SPEC-044-malibu-model-catalog-economics.md:123-131`. The same authority
requires `coordinator:not_offered` preparation and release evidence at
`:325-333,610-614`. SPEC-047-R002 permits a nullable coordinator event in the
status schema, and production deliberately returns `coordinator_event_id: nil`
when the coordinator has no offer event at
`phase4-coordinator/internal/ws/model_admission.go:2440-2455`; existing old-client
and disablement tests preserve that behavior.

**Consequence.** A valid, authoritative no-offer status is necessarily rejected
as malformed by SPEC-044's own correlation rules. The required source-transition
and coordinator-no-offer acceptance branches cannot pass without fabricating an
event or violating SPEC-047. The former v1 M1 correction is incomplete.

**Required correction.** Either permit null specifically for an authoritative
coordinator `not_offered` response with no event and bind the exact response
digest/candidate/source, or amend SPEC-047 and coordinator persistence to mint a
durable genesis event with migration, compatibility, rollback, and transition
tests. Test both no-event and event-backed coordinator states.

### B1-AUTH-V2-H3 — High — Cleanup cancellation recovery can commit a deletion that cancellation reached before the commit barrier

**Evidence.** Published cleanup defines its commit point as rename followed by
the parent `fsync` and `F_FULLFSYNC`, and says cancellation before that barrier
wins (`specs/SPEC-044-malibu-model-catalog-economics.md:446-469`). After a crash
with phase `intent`, final absent, and tombstone present, recovery treats an
absent exact marker as permission to repeat the barrier and advance to
`tombstoned` (`:471-482`). More seriously, the cancel process must perform that
recovery *before* creating a new marker; with no preexisting marker it performs
the parent barriers and advances `tombstoned` itself (`:484-495`). Thus a cancel
request arriving after the rename but before the original barrier makes the
deletion irreversible instead of winning. The same defect is copied to staging
cleanup at `:497-511`.

The recovery mutation also has no safe lock contract. Cleanup owns the
operation/cleanup lock before `cancel.lock` (`:446-456`), while cancel-side
recovery is specified only under `cancel.lock` (`:484-491`). Acquiring the
operation lock afterward reverses the order and can deadlock; mutating without
it races a live worker. The pinned plan says the cancel process takes only
`cancel.lock` (`reservation-rebaseline-plan-v6.md:199-206`), and T12 freezes that
rule (`reservation-rebaseline-test-spec-v6.md:256-258`). Finally, SPEC-044-R012
asks for marker creation after the parent barrier but before the attempted
`tombstoned` phase write (`:618-620`), while the protocol requires the worker to
hold `cancel.lock` across that whole interval (`:453-458`), so the stated test
state is prohibited.

**Consequence.** A timely cancel can cause destructive deletion, crash recovery
can race or deadlock, and one mandatory release vector is unconstructible under
the normative locking rules. The former M4 is not resolved and is escalated
because the corrected text authorizes an irreversible side effect.

**Required correction.** Establish one durable, observable linearization state
that distinguishes precommit rename from committed tombstone. Cancel-side
recovery must preserve the global operation/cleanup-then-cancel lock order; if
the operation lock is busy, the cancel process may only validate state and
durably record the exact marker. Define whether an `intent` tombstone is always
restored when cancellation arrives, or make a durable `tombstoned` state the
commit evidence. Rework R012/T10/T12 and inject cancel/crash at rename, each
parent barrier, phase persistence, lock handoff, and recovery.

### B1-AUTH-V2-H4 — High — Root identity is self-locating and does not authenticate the descriptor identity

**Evidence.** SPEC-044 defines `root_identity_digest` as a hash of only a domain
and random nonce, while canonical path, `st_dev`, and `st_ino` are stored *only*
inside `root.identity` within that root
(`specs/SPEC-044-malibu-model-catalog-economics.md:181-193`). Recovery must reopen
the saved canonical path, but no outside lifecycle record is authorized to keep
that locator. The pinned plan/tests require canonical path, device, inode, and
digest in every reservation/active/receipt/deletion record and recovery of saved
root A after configuration changes to root B
(`reservation-rebaseline-test-spec-v6.md:109-115`). The new digest also excludes
the path/device/inode it is meant to distinguish: copying the nonce and rewriting
the unauthenticated record for another descriptor preserves the digest, and can
preserve downstream artifact identity.

**Consequence.** After restart or configuration drift, recovery cannot locate
the authoritative old root without trusting current configuration or scanning.
A copied/rebound root record can retain the same digest, defeating stale-action,
receipt, cleanup, and cross-root separation. The required copied-record,
remount, and restored-root acceptance claims are not provable.

**Required correction.** Persist the saved canonical path, device, inode, and
digest in each private bounded lifecycle record that must reopen the root. Define
the digest over a canonical encoding of the validated `root.identity` bytes plus
descriptor device/inode, or authenticate the complete record with authority held
outside the managed root. Retain nonce entropy and projection privacy. Test
config drift, copied records with rewritten metadata, remount/device change,
inode reuse, path replacement, and restoration.

### B1-AUTH-V2-M1 — Medium — Mandatory guidance fields make catalog-only rows unrepresentable

**Evidence.** SPEC-044 requires every v2 row to carry non-null `candidate_id`,
`provider_guidance`, and a binding to one SPEC-046/SPEC-047 candidate source
(`specs/SPEC-044-malibu-model-catalog-economics.md:113-154`). The landed Slice 6
builder intentionally emits catalog-only rows for signed catalog entries absent
from local discovery
(`phase3-binary/Sources/macprovider-cli/ModelCatalogEconomics.swift:298-327,431-480`).
Those rows have no SPEC-046 candidate ID: candidate IDs are defined from a
discovered runtime source and served-model reference. SPEC-044 still describes
the network catalog and an uninstalled catalog model as part of the intended
experience (`:659-670`).

**Consequence.** A conforming v2 builder must omit existing catalog-only rows or
fabricate BYOM candidate/guidance identity. Either result breaks an existing
catalog journey or violates the owner schemas. The v1 H1 correction was applied
too broadly beyond candidate-associated rows.

**Required correction.** Require candidate/guidance binding only on
candidate-associated/local-prepare rows and define exact nullability and action
behavior for catalog-only rows, or add an owner-authorized catalog-only guidance
source and schema. Preserve a built-CLI catalog-only regression vector.

### B1-AUTH-V2-M2 — Medium — Orphan cleanup targets cannot satisfy the retained event correlation contract

**Evidence.** `cleanup_targets` must include every verified object, including an
object with no current catalog row, and its current `model_key` is nullable
(`specs/SPEC-044-malibu-model-catalog-economics.md:201-220`). A reclaimable orphan
must still have an available cleanup action. The retained event schema requires
every event to match the invoked transaction's non-null `model_key` (`:353-366`).
SPEC-001's exact run grammar supplies only transaction ID
(`specs/SPEC-001-phase3-binary.md:3280-3288`), and the top-level cleanup action
does not provide another immutable event key. T09.6 proves exposure but does not
run an orphan target through worker events
(`reservation-rebaseline-test-spec-v6.md:193-197`).

**Consequence.** The authority requires an orphan cleanup to be reachable while
providing no conforming value for its event `model_key`. An implementation must
invent a key, emit a mismatching event, or leave the action unusable. Former M6
remains open at execution time.

**Required correction.** Add a required immutable historical/event model key to
each cleanup target and its durable reservation, distinct from the nullable
current catalog match, or amend the retained event contract with an equally
closed correlation field. Run orphan cleanup through success, cancel, recovery,
retry, and the built production adapter.

### B1-AUTH-V2-M3 — Medium — Cross-process projection ordering permits a late older read to replace newer actions

**Evidence.** SPEC-044-R002 says a new random `process_launch_id` resets the
ordering baseline and discards older in-flight comparisons
(`specs/SPEC-044-malibu-model-catalog-economics.md:96`). Each CLI invocation gets
an unrelated UUID (`ModelCatalogEconomics.swift:255-268`), and Malibu launches a
new process per read. Two overlapping reads therefore have incomparable IDs.
The landed app currently rejects a late older process by `generated_at`
(`phase3-binary/app/Sources/Malibu/ModelManagement/ModelManagement.swift:1890-1910`),
which contradicts the reset rule. The v6 acceptance spec contains no inverted
completion-order vector for this boundary.

**Consequence.** Following the authority can let a slow old read overwrite a
newer projection and reintroduce stale actions/rates; preserving the landed
guard violates the authority.

**Required correction.** Freeze an app-owned request generation allocated
before process launch, or serialize/cancel superseded reads while preserving
attached action workers. Test A-before-B launch with both A/B completion orders,
CLI restart, refresh timeout, and action dispatch between replies.

### B1-AUTH-V2-M4 — Medium — JSONL transport has a per-line cap but no aggregate memory or backpressure contract

**Evidence.** SPEC-044 caps each event line at 16,384 bytes
(`specs/SPEC-044-malibu-model-catalog-economics.md:353-355`), and T14.1 tests
oversize lines and arbitrary chunking
(`reservation-rebaseline-test-spec-v6.md:287-289`). Neither freezes aggregate
stdout/stderr retention, an overlong partial line before newline, event rate, or
delivery-queue backpressure. The shipping adapter appends all stdout/stderr,
retains an unbounded partial line, and enqueues one MainActor task per line
(`ModelManagement.swift:1123-1169,1237-1303`).

**Consequence.** A bounded-time worker can still cause unbounded memory and task
growth or hang UI delivery while the pipe must continue draining. Passing the
line-size test does not prove the requested resource bound.

**Required correction.** Specify constant-space incremental UTF-8/JSONL
decoding, rejection as soon as a partial exceeds the line cap, bounded stderr,
no whole-worker stdout retention, and a bounded delivery queue/backpressure
policy that continues draining. Add sustained maximum-rate and no-newline tests.

### B1-AUTH-V2-M5 — Medium — The test suite requires ACL rejection without a normative ACL policy

**Evidence.** Root and private-state authority specifies owner, type, mode, link
count, no-follow traversal, and descriptor identity, but does not define extended
ACL acceptance or inheritance. T08 requires wrong-ACL rejection for every
sensitive authority, lock, state, artifact, receipt, tombstone, and legacy path
(`reservation-rebaseline-test-spec-v6.md:150-154`). Mode `0700`/`0600` alone does
not exclude a macOS extended ACL grant.

**Consequence.** Implementations and tests can disagree on which ACL is wrong,
and an inherited grant can survive creation while every stated mode check
passes. The security acceptance claim has no deterministic oracle.

**Required correction.** Define the exact extended-ACL policy for every private
component, including inherited ACLs and creation-time strip-versus-reject
behavior, and require descriptor-based verification. Add inherited and
post-validation ACL mutation cases.

## Preserved v1 finding disposition

| Preserved finding | Disposition in this gate |
|---|---|
| H1 guidance/candidate correlation | Candidate-associated binding is specified, but the correction creates M1 and conflicts with coordinator no-event status in H2. Not fully closed. |
| H2 deterministic v1/v2 selection | Authority text is corrected; pinned plan/test still accept incomplete v1. Open as H1. |
| M1 coordinator `not_offered` | Open as H2. |
| M2 verified-artifact prerequisite | Closed textually and covered by the matrix/release vectors. |
| M3 cancellation acknowledgement outcomes | Closed textually. |
| M4 cleanup cancellation/recovery commit point | Open and escalated as H3. |
| M5 exact reclaimable-byte filesystem definition | Closed textually. |
| M6 orphan/no-catalog cleanup reachability | Projection exposure is closed; execution correlation remains open as M2. |
| M7 governance mismatches | Closed; validators pass and SPEC-001-R003 is mapped. |
| M8 built CLI to production Malibu wire test | Closed prospectively by T14.1/T15; execution remains a future implementation gate. |
| M9 budget/precedence exact tests | Closed prospectively. |
| M10 legacy accounting blocks preparation | Closed prospectively. |
| M11 localized size calculations | Closed prospectively. |
| M12 cancellation completion bound | Closed textually for the qualified profile. |
| M13 event error precedence | Closed prospectively. |

## Fresh verification evidence

The following read-only checks ran against the pinned authority worktree unless
another worktree is named:

```text
git rev-parse HEAD
=> f691de4d12250b97d86d91be7333d29db1ee5f20

git -C /Users/augstar/macprovider-poc rev-parse origin/main
=> f7e584499828b3d16036382848b5caa1a897cdf9

sha256sum reservation-rebaseline-plan-v6.md reservation-rebaseline-test-spec-v6.md
=> a682d6b7caade4540e56f042d6ba9d70731af493a56abaa78c6fff18fede9678
=> 1c56872db5855b91916661bd2672f4a903300762db3ba390ca1227271b73cb89

git diff --check origin/main...HEAD
=> exit 0

python3 scripts/gen_spec_index.py --check
=> canonical specs: 47; index is up to date; exit 0

python3 scripts/gen_spec_index.py --lint
=> exit 0

python3 scripts/check_spec_governance.py --base-ref origin/main
=> SPEC governance validation passed; exit 0

PYTHONDONTWRITEBYTECODE=1 python3 -m unittest \
  scripts.tests.test_spec_governance scripts.tests.test_spec_pr_declaration
=> Ran 61 tests in 91.420s; OK

cd phase3-binary && swift test --filter ModelCatalogEconomicsTests
=> Executed 8 tests, 0 failures; exit 0

cd phase4-coordinator && go test ./internal/ws -run \
  'TestModelAdmissionStatusForPreBYOMProviderReturnsNotOffered|TestModelAdmissionSubmissionsDisabledRejectsSubmitAndPreservesReadback' \
  -count=1
=> ok github.com/augstar/macprovider-coordinator/internal/ws; exit 0

python3 -m json.tool specs/AUTHORITY.json
python3 -m json.tool specs/CONFORMANCE.json
=> both exit 0
```

The Swift test caused SwiftPM to rewrite `phase3-binary/Package.resolved`; that
generated change was restored before this artifact was staged. No plan, test
specification, authority spec, code, governance file, or generated index is
modified by this review commit.

## Gate result

**BLOCK.** Correct all four High and five Medium findings, regenerate governance
surfaces if owner requirements change, update the pinned plan and test spec, and
run another independent cumulative authority gate. The eventual T18 ancestry
check remains expected pending evidence from the first implementation commit.
