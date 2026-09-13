# Build 1 preparation-reservation rebaseline plan v3 independent review (Sol)

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol adversarial plan gate

Verdict: **BLOCK — NOT APPROVED FOR IMPLEMENTATION**

Architectural status: **BLOCK**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 0 |
| Medium | 1 |
| Low | 0 |
| Informational | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. V3
therefore fails the plan gate. The prior B1-V2-H1 and B1-V2-M1 through M5
corrections are materially closed, as are the earlier v1 corrections, but the
new v3 inventory namespace can still enter its own unrecoverable count-overflow
state through ordinary successful publications.

## Frozen review inputs

- Exact reviewed commit:
  `63d0ef47f84ae8038202ef9c74edc8705598ad15`.
- Exact base:
  `c4401f1791d593d37d68eba91af94219b26d278f`.
- Reproduced plan SHA-256:
  `2f532e05ef198cffdbec83827b1a5d8a9dfe80c73c9cae284188d3d03b3294cd`.
- Reproduced test-spec SHA-256:
  `98ad2d77465763f1db95d7190fd18333c307a74bd2567964d6ac36d5de60d291`.
- `origin/main` resolved to the stated base after `git fetch --prune origin`.
- `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` is an ancestor of the base,
  and the base is an ancestor of the reviewed commit.
- The reviewed branch changes only the v1/v2/v3 planning, test, and review
  documents. It does not change current specs, code, or the two operator
  handoffs. The handoffs reproduce SHA-256 values
  `572dea4865b578db09ba662967ec7370818b1e692e34727351137b1ae24b259d`
  and
  `5a8b35734b733692c12620986443f050a5ebc09bf21ce94207cb65207d84fcaf`.
- The v1/v2 Sol reviews, current SPEC-001/SPEC-044, AUTHORITY and CONFORMANCE,
  current catalog-economics projection, legacy durable store, existing adoption
  frame/handler, operator copy/handoff, and all v3 plan/test sections were
  inspected.

## Finding

### B1-V3-M1 — ordinary successful publications can cross the inventory ceiling and disable their own cleanup path

**Severity: Medium**

**Evidence**

- V3 caps inventory at 256 receipts
  (`reservation-rebaseline-plan-v3.md:206-215`) and makes inventory and cleanup
  unavailable at 257 objects
  (`reservation-rebaseline-test-spec-v3.md:150-167`).
- The publication sequence revalidates authority, root, cancellation, and the
  byte budget before the exclusive rename, but it does not reserve or check a
  distinct-object count slot
  (`reservation-rebaseline-plan-v3.md:202-204`).
- The 256-entry preparation-selection/history bound cannot enforce the durable
  object bound. Old v3 publications are intentionally retained across feed and
  release changes, while each new projection can remain below 256 eligible
  tuples (`reservation-rebaseline-plan-v3.md:167-169,206-217,272-274`).
- Automatic GC is rejected and the only approved deletion path selects one
  inventory-classified reclaimable identity
  (`reservation-rebaseline-plan-v3.md:219-230`). Once the 257-object state makes
  inventory/cleanup unavailable, that path cannot reduce the count.
- T09.3 explicitly accepts the wedged outcome at 257, while T09.4 tests only
  byte-budget admission. Neither test requires refusal of a new distinct
  publication while 256 objects already exist
  (`reservation-rebaseline-test-spec-v3.md:150-167`).

**Consequence**

A provider can reach the failure state without hostile filesystem mutation:
prepare small, distinct objects across successive signed releases while old v3
objects remain preserved. If the byte budget still admits the 257th object, the
worker can publish it successfully and the next projection must disable both
truthful inventory and the only provider-approved cleanup mechanism. Recovery
then requires an unspecified manual mutation, contradicting the bounded,
non-scanning recovery and managed-storage outcome inherited from B1-V1-M2.

**Required correction**

Make the object-count limit an admission invariant, not only a decoder failure
limit. Before network transfer and again immediately before exclusive
publication, atomically verify or reserve capacity for the exact distinct tuple
under the fixed operation/cleanup locks. Permit an idempotent existing identity;
permit the 256th distinct object; reject the 257th before side effects. Add tests
for 255 plus one, 256 plus an idempotent publish, 256 plus a new distinct publish,
restart/feed-release churn, and the race between cleanup and publication. Keep
257 externally seeded objects fail-closed, but specify a bounded operator
recovery route if the implementation is expected to repair that corruption.

## Prior-finding dispositions

### B1-V2-H1 — conforming prepare-before-offer authority

**Severity: None — closed.**

**Evidence:** The plan states that current SPEC-044 v0.1.1 does not authorize
local pre-offer preparation, defines a complete source/state/economics matrix
and exact non-economic copy, and requires the operator-owned SPEC-001/SPEC-044
patch to freeze R002/R003 before 6B
(`reservation-rebaseline-plan-v3.md:33-49,94-102`). T16 enumerates both sources,
all 12 admission states, all five economics states, booleans, qualification,
fit, runtime, action ID, estimate, and safety inputs, then drives the three
local-default states through the guided journey
(`reservation-rebaseline-test-spec-v3.md:234-247`). Current code still emits
local catalog rows with `prepare` unavailable and null money fields
(`ModelCatalogEconomics.swift:431-480`), confirming that the future authority
gate remains necessary rather than being silently assumed complete.

**Consequence:** No unresolved contradiction remains inside the plan. The
desired path is both specified and prevented from implementation under current
authority.

**Required correction:** None for this finding. The authority patch and the
fresh combined plan-plus-SPEC review remain mandatory.

### B1-V2-M1 — deletion intent ordering and phase recovery

**Severity: None — closed.**

**Evidence:** Durable, full-synced `phase: intent` now precedes rename; the keep
set is rechecked; `phase: tombstoned` follows the objects-parent barrier; and
every final/tombstone/phase combination has a closed recovery rule
(`reservation-rebaseline-plan-v3.md:219-230`). T10 injects every boundary and
asserts the exact durable-state table
(`reservation-rebaseline-test-spec-v3.md:169-210`).

**Consequence:** An ordinary crash no longer leaves an authorized tombstone
without a prior durable recovery record.

**Required correction:** None.

### B1-V2-M2 — unique temporary ownership and root bootstrap

**Severity: None — closed.**

**Evidence:** V3 replaces fixed temporary leaves with UUID-bound, checksummed,
generation-aware records, bounds reconciliation, distinguishes recognized
interruption from hostile objects, and publishes `root.identity` only by a
complete exclusive rename followed by a namespace barrier
(`reservation-rebaseline-plan-v3.md:155-165`). T01/T04/T08 cover partial writes,
complete temps, final conflicts, concurrency, hostile entries, config changes,
and crash recovery (`reservation-rebaseline-test-spec-v3.md:49-66,93-97,134-138`).

**Consequence:** The fixed-temp and partially created final-identity wedge from
v2 is removed.

**Required correction:** None.

### B1-V2-M3 — enforceable URLSession byte bounds

**Severity: None — closed.**

**Evidence:** V3 separates delegate-delivered, application-accepted, and staged
bytes and places normative maxima only on the last two. Server, transport, and
delegate counts remain observational; late callbacks cannot re-enter
application custody (`reservation-rebaseline-plan-v3.md:186-196`). T06/T09/T21
make the same distinction and explicitly reject a server/transport maximum
claim (`reservation-rebaseline-test-spec-v3.md:103-126,140-167,291-302`).

**Consequence:** The acceptance suite now measures only guarantees the proposed
URLSession design can enforce.

**Required correction:** None.

### B1-V2-M4 — v3 namespace and configured legacy accounting

**Severity: None — closed except for B1-V3-M1.**

**Evidence:** Publications and enumeration are confined to
`.macprovider-prepared-v3`; configured incumbent/draft legacy trees are
protected and separately accounted; unconfigured legacy remains unmanaged; and
rollback/re-upgrade preserves both stores
(`reservation-rebaseline-plan-v3.md:131-153,206-217,272-274`). T09/T10/T17/T21
exercise production-shaped mixed roots, same/other-device accounting, malformed
legacy, no-import/no-delete, rollback, and hardware evidence
(`reservation-rebaseline-test-spec-v3.md:140-210,249-251,291-302`). Current
`DurableModelArtifactStore` confirms the legacy
`<root>/<model>/<revision>/<hash>` layout that these cases must preserve
(`DurableModelArtifactStore.swift:38-48,84-117`).

**Consequence:** Normal legacy siblings no longer poison v3 inventory and v3
cleanup has no authority over them. The independent v3 object-count defect is
reported above.

**Required correction:** None beyond B1-V3-M1.

### B1-V2-M5 — cancellation acknowledgement, event ownership, and marker races

**Severity: None — closed.**

**Evidence:** The worker is the sole event producer and sequence allocator. The
cancel process takes only `cancel.lock`, writes an attempt-bound marker, and
returns a separate capped acknowledgement. The worker holds `cancel.lock`
across terminal commit, marker sweep, and operation-lock release; new attempts
use operation-then-cancel order and remove only validated prior-attempt markers
(`reservation-rebaseline-plan-v3.md:171-184`). T03/T12/T14 cover both-process
orders, late publication, terminal compaction, new attempts, exact outcomes,
event uniqueness, and Malibu rendering
(`reservation-rebaseline-test-spec-v3.md:74-91,216-228`).

**Consequence:** Cancellation cannot split the public event sequence or leave a
late marker applicable to a new attempt.

**Required correction:** None.

## V1 correction audit

| V1 finding | V3 disposition |
|---|---|
| B1-V1-H1 | Closed. The complete public grammar/schema/copy change is operator-owned, versioned, ancestry-gated, and reviewed again before 6B; no status or control frame is invented. |
| B1-V1-H2 | Closed. Canonical path, `st_dev`, `st_ino`, root-identity digest, saved-root recovery, custom/separate-volume cases, and server-side independent verification are explicit. |
| B1-V1-H3 | Closed. File/tree barriers, exclusive rename, destination-parent `fsync` plus `F_FULLFSYNC`, terminal-state ordering, cross-filesystem recovery, and real APFS abrupt-power qualification remain mandatory. |
| B1-V1-M1 | Closed. Selection has exact 64/256 limits, stable IDs, deterministic order, active pinning, eight fairness slots, starvation bounds, overflow refusal, and dispatch serialization. |
| B1-V1-M2 | Reopened only as B1-V3-M1. Byte budget, keep set, intent-first deletion, dedicated namespace, legacy protection, and provider-confirmed cleanup are sound, but successful publication lacks an object-count admission guard. |
| B1-V1-M3 | Closed. A serial production delegate, 250 ms watchdog, bounded work-loop polling, heartbeat/deadline rules, direct descriptor writes, and enforceable accepted/staged caps replace the earlier unbounded transfer design. |

## Conditional authority-gate assessment

The conditional structure is coherent. A plan can be approved before its
operator authority amendment exists when it truthfully labels the dependency,
requires the complete authority scope, proves strict ancestry, and requires a
fresh review of the plan together with the landed SPEC diff. V3 does those
things in Dependency Gates 4-6 and T18. This review does not approve the future
SPEC text and cannot unlock slice 6B.

Current evidence confirms the condition is active: SPEC-044 remains v0.1.1;
R002's closed action projection has no published-artifact cleanup action or
cancel acknowledgement, R003 disables money-motivated preparation without
trusted economics, current projection code leaves preparation unavailable, and
CONFORMANCE retains pending discovery, admission, SPEC-044, and SPEC-023-R006
evidence. None of those pending facts is misrepresented as complete by V3.

## Informational observations

### B1-V3-I1 — adoption can remain on the existing frame

The existing `ModelAdoptionAuthorityWire` carries target model, catalog
revision, artifact hash, and catalog-identity digest claims. V3 requires the
serving process to reload signed feeds and derive its configured v3 destination
before comparing those claims, so requester path/hash fields do not become
authority (`ModelSwitchingWire.swift:363-424`;
`reservation-rebaseline-plan-v3.md:236-256`;
`reservation-rebaseline-test-spec-v3.md:220-222`). No new control frame is
required by the plan.

### B1-V3-I2 — final Build 1 acceptance remains truthful

V3 keeps readiness separate from adoption, admission, routing, settlement,
positive provider credit, first listed-tier release, signed assets, updater
proof, and stable-media qualification. T21-T24 require final signed real-Mac
evidence and explicitly preserve the pending CONFORMANCE state
(`reservation-rebaseline-plan-v3.md:258-282`;
`reservation-rebaseline-test-spec-v3.md:291-349`).

## Required disposition

Add count admission/reservation to the publication contract and its tests, then
reproduce the plan/test hashes and run a fresh independent adversarial review.
Do not weaken the authority, deletion, temp recovery, URLSession, v3 namespace,
legacy protection, cancellation, adoption, or final acceptance gates. PASS
remains available only at 0 Critical, 0 High, and 0 Medium.
