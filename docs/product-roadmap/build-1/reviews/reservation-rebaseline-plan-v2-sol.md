# Build 1 preparation-reservation rebaseline plan v2 independent review (Sol)

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol adversarial plan gate

Verdict: **BLOCK — NOT APPROVED FOR IMPLEMENTATION**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 1 |
| Medium | 5 |
| Low | 0 |
| Informational | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. The v2
plan and test specification therefore fail the gate. The hard pre-6B authority
gate is valid in principle, but it does not cure contracts that its required
authority patch does not cover. No slice 6B implementation may start.

## Frozen review inputs

- Exact reviewed commit: `1b011cfda04ae539106ccb82957e8abb35c5af5f`.
- Exact base: `c4401f1791d593d37d68eba91af94219b26d278f`.
- Reproduced plan SHA-256:
  `76ff9dfc07832f1b1b01af5483cc3fde647f536b7c700c1ea7bc5850df11ca9a`.
- Reproduced test-spec SHA-256:
  `68ce34367c79bf935754692b33fd779d87ac34fd28641078d61b74369a7cc15d`.
- The prior v1 Sol review, current SPEC-001/SPEC-044 authority,
  `AUTHORITY.json`, `CONFORMANCE.json`, current Swift projection, durable-store,
  adoption-frame and handler code, issues #1453/#1481/#1485/#1486, and the
  landed operator copy at `c4401f17` were inspected.
- `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` is an ancestor of the base, and
  the landed copy file is unchanged in the reviewed branch.
- On the review Mac's APFS-backed temporary directory, both `fsync` and
  `fcntl(F_FULLFSYNC)` returned success for an opened directory descriptor.
  Directory full-sync is therefore not rejected here as mechanically
  impossible. Apple's `fsync(2)`/`fcntl(2)` documentation still describes the
  stable-media request as storage-dependent; the plan correctly keeps abrupt
  power qualification separate from SIGKILL.

## Findings

### B1-V2-H1 — the guided prepare-before-offer journey still has no conforming action-gating authority

**Severity: High**

**Evidence**

- The operator handoff requires a guided `prepare -> evaluate -> offer -> adopt`
  flow and shows `local_only`, `not_offered`, and `offerable` candidates
  (`SLICE6_MALIBU_ACTIVATION_UX_HANDOFF.md:13-16,30-36`; operator copy
  `SLICE6_STATE_SURFACE_AND_COPY.md:12-25,39-52`).
- Current SPEC-044-R002 permits `economics_state: trusted` only when
  `admission.catalog_economics_permitted` is true; a `local_default` admission
  source must set that field false (`SPEC-044-malibu-model-catalog-economics.md:90`).
- Current SPEC-044-R003 defines `prepare` as money-motivated and requires all
  money-motivated actions to be disabled when economics is not trusted
  (`SPEC-044-malibu-model-catalog-economics.md:92`). Thus the pre-offer rows
  central to the handoff cannot expose `prepare_model` under current authority.
- V2 nevertheless makes an available `prepare_model` action the entry to J1
  and claims the reservation subplan enables supported catalog preparation
  (`reservation-rebaseline-plan-v2.md:21-28,35-42`).
- Dependency Gate 5 limits the future authority patch to invocation/cancellation
  spelling, event errors/warnings, and published-storage cleanup exposure. It
  does not require operator disposition of R002/R003 preparation gating
  (`reservation-rebaseline-plan-v2.md:81-88`). T18 repeats that incomplete
  scope (`reservation-rebaseline-test-spec-v2.md:255-267`).

**Consequence**

Even after the required 6A patch lands, an implementer must either suppress
Prepare for every pre-offer local row and fail the operator's guided journey, or
expose it contrary to frozen SPEC-044 economics gating. The plan's authority
gate can therefore pass while the core product flow remains nonconforming.

**Required correction**

Add an explicit operator-owned disposition of SPEC-044-R002/R003 to the 6A
gate. Freeze whether a locally motivated preparation is permitted before
catalog economics/admission, the exact conditions and copy that distinguish it
from a money-motivated action, or revise the journey order so preparation is
not offered until existing authority permits it. Extend T16/T18 to cover every
`admission.source`, `admission.state`, and `economics_state` combination and
prove the chosen flow is both reachable and authority-conformant.

### B1-V2-M1 — cleanup makes the tombstone durable before persisting the only recovery record

**Severity: Medium**

**Evidence**

- Cleanup renames the final leaf to a transaction-bound tombstone, full-syncs
  the parent, and only then persists `deletion.json`
  (`reservation-rebaseline-plan-v2.md:247-259`).
- A crash after the parent barrier but before `deletion.json` is durable leaves
  a durable tombstone with no recorded tombstone authority. The active record
  contract records preparation staging/unpublished leaves, not the deletion
  tombstone (`reservation-rebaseline-plan-v2.md:189-193`).
- Recovery promises to resume only a *recorded* tombstone, while broad scans and
  unexpected inventory objects fail closed (`reservation-rebaseline-plan-v2.md:245,249,259,350-357`).
- T10.5 injects exactly the after-rename crash but assumes recovery can identify
  the tombstone; it does not identify a pre-rename durable intent record that
  makes this possible (`reservation-rebaseline-test-spec-v2.md:181-187`).

**Consequence**

A routine crash can strand a renamed artifact outside the published namespace,
with no authoritative record that permits completion or restoration. Inventory
then fails closed on the unexpected object and can block preparation/cleanup
indefinitely.

**Required correction**

Persist and full-sync a tuple/root/leaf-bound deletion intent before rename,
then record the post-rename phase after the parent barrier. Define recovery for
every intent/rename/barrier combination without scanning or guessing. Make T10
assert both on-disk state and the exact recovery authority at each boundary.

### B1-V2-M2 — root-identity and fixed temporary-file bootstrap crashes can permanently wedge the authority root

**Severity: Medium**

**Evidence**

- Existing artifact roots receive `root.identity` through exclusive creation
  followed by writes and full-sync (`reservation-rebaseline-plan-v2.md:143-156`).
  A crash after create and before the complete record/barrier can leave an
  existing truncated file that a later `O_EXCL` bootstrap cannot replace.
- Every private state update likewise uses a fixed same-directory temporary
  leaf with `O_CREAT|O_EXCL` before rename
  (`reservation-rebaseline-plan-v2.md:139-141`). A crash can leave that fixed
  leaf present.
- The recovery table covers active staging, publication, and deletion, but does
  not define validation/removal or completion of incomplete identity/state
  temporaries (`reservation-rebaseline-plan-v2.md:233-245`). T08 treats an
  unexpected sibling as a fail-closed condition rather than a recoverable
  interrupted write (`reservation-rebaseline-test-spec-v2.md:141-145`).

**Consequence**

An ordinary crash during first projection or any private state update can make
all later projections and transactions unavailable even though no hostile
filesystem change occurred. The provider has no typed recovery path.

**Required correction**

Define crash-safe bootstrap and stale-temp recovery. Use uniquely named,
descriptor-validated temporaries with a durably recorded phase, or specify how
an exact fixed temporary is proven to belong to the interrupted write before it
is removed. Add crash injection after create, every partial write, file barrier,
rename, and parent barrier for `root.identity` and every private state file.

### B1-V2-M3 — the URLSession test claims a server-byte bound the client cannot enforce

**Severity: Medium**

**Evidence**

- The plan splits each delivered `Data` callback into 1 MiB disk-write quanta,
  then claims server-observed bytes are bounded by the signed cap plus one such
  quantum (`reservation-rebaseline-plan-v2.md:199-205`).
- Splitting an already delivered callback bounds application writes; it does not
  set URLSession's callback size or bound transport/framework buffering. Apple
  documents that `didReceive` may be called repeatedly with data already
  received, and `cancel()` returns immediately while delegate messages may
  still arrive before cancellation is acknowledged.
- T06.2 requires the local server to have sent no more than cap plus one 1 MiB
  quantum, which is not an invariant controlled by the proposed delegate
  (`reservation-rebaseline-test-spec-v2.md:106-124`).

**Consequence**

The implementation can correctly prevent excess durable writes yet fail an
unachievable acceptance test due to socket/framework buffering. Conversely, a
passing shaped-server test would not prove the claimed production network-read
bound. B1-V1-M3 is therefore not fully discharged.

**Required correction**

Limit the normative guarantee to bytes accepted into the application and bytes
written to staging, and record transport bytes as observational evidence only.
If a network-read bound is mandatory, use a transport API with explicit
backpressure/read sizing and specify its kernel-buffer assumptions. T06/T09
must distinguish server sent, client transport received, delegate delivered,
and staged bytes.

### B1-V2-M4 — the bounded inventory has no compatibility rule for the existing durable store

**Severity: Medium**

**Evidence**

- The current production store derives artifact paths as
  `<root>/<model>/<revision>/<artifact-sha256>` and publishes verified trees
  without the v2 publication receipt
  (`DurableModelArtifactStore.swift:38-48,84-117`).
- V2 derives destination identity from the tuple hash and accepts inventory
  objects only under the new exact grammar with a v2 receipt; one unexpected
  object fails the entire inventory (`reservation-rebaseline-plan-v2.md:215-229,247-255`).
- Global budget admission depends on truthful inventory before download
  (`reservation-rebaseline-plan-v2.md:209-214`).
- Migration tests cover abandoned R21-R27/v1 planning state, but not a normal
  provider root containing the currently configured pre-v2 durable artifact
  (`reservation-rebaseline-test-spec-v2.md:249-253`).

**Consequence**

Upgrading a real provider with an existing valid durable artifact can make
inventory and budget unavailable, blocking preparation and cleanup. Treating
the incumbent tree as unexpected also leaves the main incumbent-preservation
claim untested on the actual upgrade shape.

**Required correction**

Freeze one compatibility rule: isolate v2 publications in a dedicated
namespace while separately accounting/protecting the configured legacy tree,
or define a descriptor-safe, non-destructive recognition/import receipt for
existing verified artifacts. Add upgrade tests with current-store artifacts,
configured incumbents, mixed legacy/v2 releases, count/budget boundaries, and
rollback/re-upgrade.

### B1-V2-M5 — cancellation has no single owner for the public event sequence

**Severity: Medium**

**Evidence**

- A second CLI process durably writes `cancel.json` without taking the worker's
  exclusive lock, while the public contract requires one monotonic event
  sequence and `cancel_requested` followed by a terminal event
  (`reservation-rebaseline-plan-v2.md:11,44-50,195-205`).
- The plan does not state whether the cancellation CLI emits
  `cancel_requested`, whether the worker is the sole event producer, how the
  cancellation invocation acknowledges success, or how a late marker is
  removed after the worker has already compacted terminal state.
- T14 asserts monotonic sequences and terminal uniqueness but does not freeze
  an emitter/sequence-allocation protocol across the two processes
  (`reservation-rebaseline-test-spec-v2.md:229-235`). Dependency Gate 5 asks
  for option spelling and error/warning precedence, not this ownership rule.

**Consequence**

Conforming implementations can produce duplicate/out-of-order event sequences,
emit no cancellation acknowledgement, or leave an exact but stale marker that
affects the next attempt. Malibu cannot reliably merge two process streams.

**Required correction**

Make the worker the sole event sequencer and define the cancellation command's
separate bounded acknowledgement, or freeze a durable cross-process sequence
allocation protocol. Specify the late-write/terminal-compaction race and stale
marker cleanup. Add two-process tests for every ordering around marker create,
worker observation, durable publication, terminal compaction, and a new attempt.

## Prior-finding disposition

| v1 finding | v2 result |
|---|---|
| B1-V1-H1 | **Still blocked.** The future authority-commit gate is sound, but its required scope omits the R002/R003 action-gating contradiction in B1-V2-H1 and the cancellation sequencing contract in B1-V2-M5. |
| B1-V1-H2 | **Substantially corrected, not closed.** Complete root binding and saved-path recovery are specified; root-identity bootstrap crash recovery remains missing in B1-V2-M2. |
| B1-V1-H3 | **Corrected.** Files/tree, exclusive rename, destination-parent barrier, authority-state ordering, separate-filesystem recovery, and power-loss qualification are now explicit. |
| B1-V1-M1 | **Corrected.** The 64/256 selection rules, deterministic tie breaks, starvation bound, persisted history, overflow behavior, and dispatch serialization are testable. |
| B1-V1-M2 | **Still blocked.** Budget and keep-set design are present, but tombstone recovery ordering and existing-store compatibility remain incomplete in B1-V2-M1/M4. |
| B1-V1-M3 | **Still blocked.** Delegate/watchdog/staged-byte bounds are concrete, but the claimed server-byte bound is not enforceable by that design (B1-V2-M3). |

## Informational observations

### B1-V2-I1 — a plan may validly pass while implementation remains hard-gated on future authority

There is no inherent defect in approving a design document whose implementation
gate requires a later operator authority commit, provided the document labels
the state accurately, the required authority scope is complete, ancestry is
machine-checked, and the combined plan/SPEC is reviewed again before code. V2
does all but the complete-scope requirement identified above. This review's
BLOCK is caused by substantive gaps, not merely by the authority commit being
future work.

### B1-V2-I2 — economics and final Build 1 acceptance remain truthfully bounded

V2 continues to state that preparation is local and non-economic, preserves
the incumbent until separate adoption, and does not substitute readiness for
signed discovery/admission, settlement, positive credit, first listed-tier,
signed assets, notarization, updater, or real-hardware evidence. Those final
boundaries are sound but do not offset the blocking findings.

## Required disposition

Revise the plan and test specification without weakening the existing safety or
final Build 1 gates. Expand the operator authority patch scope for preparation
gating and cancellation sequencing; repair deletion and bootstrap recovery
ordering; state enforceable URLSession bounds; and cover the existing durable
store upgrade shape. Reproduce hashes and run a fresh independent adversarial
review. PASS remains available only at 0 Critical, 0 High, and 0 Medium.
