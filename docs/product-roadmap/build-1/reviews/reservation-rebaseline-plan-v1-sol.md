# Build 1 preparation-reservation rebaseline plan v1 independent review (Sol)

Date: 2026-09-11

Reviewer: independent native GPT-5.6 Sol adversarial plan gate

Verdict: **BLOCK — NOT APPROVED FOR IMPLEMENTATION**

## Gate result

| Severity | Count |
|---|---:|
| Critical | 0 |
| High | 3 |
| Medium | 3 |
| Low | 0 |
| Informational | 2 |

The pass condition is exactly zero Critical, High, and Medium findings. The
plan and test specification therefore fail the implementation gate. No finding
or acceptance requirement is waived, weakened, or downgraded.

Architecture status: **BLOCK**. Code/security recommendation: **REQUEST
CHANGES**.

## Frozen review inputs

- Exact reviewed commit:
  `111687dc745888077d1d6bec9bc733c2224f24bd`
- Exact parent/base:
  `4bbb7eedde40759b56a6d42f82aacb8461adff95`
- Reproduced plan SHA-256:
  `a21d786b23033d06aafffc941ed8af55bd8b536dda3264e176637fc5bc9857a1`
- Reproduced test-spec SHA-256:
  `e7d5aa52bfee2950fb3d9602c3f3f1d9c3bd5fdbafdaaa5535104c17743af861`
- Reproduced rejected R27 review SHA-256:
  `e8c1a80479c6185202201b38f30dbc019ef80ca5aefe0e3f4efd8e7d75419be3`
- R27 review source commit: `8444d4d0cf999f00d355664911ebacbf3f16366a`
  (`codex/product-build-1`); its verdict was BLOCK with 0 Critical, 6 High,
  3 Medium, 1 Low, and 2 Informational findings.
- Historical roadmap inspected at
  `/private/tmp/macprovider-roadmap/.omx/plans/product-roadmap-422fc2f1.md`;
  it records baseline `422fc2f13fc62c1ff8987522f822d9ef856e4a96` and makes a real-Mac,
  correctly settled request the Build 1 acceptance boundary.
- Issue #1453 was inspected in its current open state. It assigns slice 6 to
  #1485 and slice 7 to #1486.
- PR #1481 was reproduced as merged commit
  `6f2712453ee7995d2be4b2fd9ac4d8e98b5bf78a` and is an ancestor of the review
  base. The review base is the slice 6/7 handoff commit whose parent is #1481.
- Both handoff documents under `audits/2026-09-11-byom-v02-handoffs/`, current
  `specs/AUTHORITY.json`, and current `specs/CONFORMANCE.json` were inspected.
  SPEC-044-R001..R012, SPEC-046-R001..R008, SPEC-047-R001..R009, and the two
  signed journeys remain pending at this baseline.
- The reviewed commit adds only the two plan documents. `git diff --check`
  passed before this review artifact was written.

## Findings

### B1-V1-H1 — the plan requires new public protocols while declaring the governing contracts frozen and slice 6 free of SPEC-authority changes

**Severity: High**

**Evidence**

- The plan says its details refine frozen SPEC-044 contracts, create no new
  public schema, and must return to the SPEC owner if incompatibility is found
  (`reservation-rebaseline-plan-v1.md:90,118-120`).
- It nevertheless adds three provider-visible commands, a new closed
  `model_catalog_transaction_status.v1` response, a new
  `prepared_artifact_authority_refresh_result.v1` control response, and new
  terminal/error/warning semantics including `interrupted` and
  `cancellation_too_late` (`reservation-rebaseline-plan-v1.md:164,168,219-227,298-300`).
- Slice 6A simultaneously instructs implementation to amend SPEC-001 §6.14a
  while adding no public fields or enum values (`reservation-rebaseline-plan-v1.md:231-238`).
- Current SPEC-001's exact command taxonomy contains `models list`, `switch`,
  `adopt-recommendation`, `browse`, `discover`, `evaluate`, `offer`, and
  `admission`; it contains no `models transactions` family
  (`specs/SPEC-001-phase3-binary.md:3164-3200`).
- Current SPEC-044-R002 closes action kinds and the transaction event schema and
  states. It does not define a transaction-status schema or the new runtime
  refresh frames (`specs/SPEC-044-malibu-model-catalog-economics.md:90`).
- The authoritative #1485 handoff calls slice 6 client-side implementation over
  frozen contracts with no SPEC-authority change, says the transactions already
  exist, and requires any needed SPEC touch to return to the operator
  (`audits/2026-09-11-byom-v02-handoffs/SLICE6_MALIBU_ACTIVATION_UX_HANDOFF.md:4-11,18-28,43-48`).
- T18 records versions and ownership but does not require the missing owner-approved
  authority changes to land before 6B, and T20 reviews the implementation after
  the contradiction has already been crossed
  (`reservation-rebaseline-test-spec-v1.md:292-312,345-353`).

**Consequence**

There is no conforming implementation path. An implementer must either ship
provider-visible commands/frames/enums absent from the frozen authority, modify
SPEC authority contrary to the slice handoff, or silently reinterpret existing
closed schemas. Capability negotiation, old-client behavior, Malibu decoding,
and the serve control protocol can then disagree even while T01-T20 pass against
one implementation's invented interpretation.

**Required correction**

Before implementation, obtain the named authority owners' disposition and land
one reviewed contract change that freezes the exact command grammar, capability
and manifest tokens, request/status/event schemas, every state/error/warning
enum and precedence rule, and both directions of the control-socket refresh
frame. Update #1485 ownership and the handoff to match that decision. If the
operator keeps slice 6 as no-SPEC-change work, remove the new protocols and
compose only from already frozen commands. Make T18 fail unless the authority
commit and ownership record predate 6B, then independently review the revised
plan and SPEC diff at the zero-C/H/M gate.

### B1-V1-H2 — supported custom artifact roots are absent from reservation and crash-recovery authority

**Severity: High**

**Evidence**

- The exact reservation target contains model/feed identity and size but no
  resolved durable-artifact root, root identity, or filesystem identity
  (`reservation-rebaseline-plan-v1.md:141-156`). `active.json` only duplicates
  that target (`:160-166`).
- Publication derives the destination from the existing durable store, cleanup
  derives an unpublished sibling from the active tuple/attempt, and serve-side
  refresh independently derives a destination (`reservation-rebaseline-plan-v1.md:182-204,219-225`).
- The current product supports `MACPROVIDER_MODEL_ARTIFACT_ROOT` and a
  `model_artifact_root` config override. `DurableModelArtifactStore.defaultRoot`
  consumes the environment override
  (`phase3-binary/Sources/macprovider-cli/DurableModelArtifactStore.swift:11-20`),
  config loading applies it
  (`phase3-binary/Sources/MacProviderCore/Config.swift:468,537-557`), and both
  artifact resolution and serve startup overlay the resolved config root
  (`phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:3552-3585`;
  `phase3-binary/Sources/macprovider-cli/MacProviderCLI.swift:1779-1786`).
- The authority root is separately fixed under the user's configuration area,
  so its active record survives changes to the artifact-root environment or
  config (`reservation-rebaseline-plan-v1.md:122-137`).
- T04 assumes the next process can derive and delete the exact old unpublished
  paths, T08 mentions the durable parent generically, and T13 assumes the server
  derives the same path. None varies a custom root between projection, run,
  crash recovery, status/cleanup, serve startup, and refresh
  (`reservation-rebaseline-test-spec-v1.md:73-94,118-137,205-228`).

**Consequence**

Two same-EUID processes can legitimately resolve different durable roots. A
crash followed by a config/environment change cannot locate the old unpublished
tree from `active.json`; cleanup may inspect a different root while orphaning
multi-gigabyte bytes. Preparation can publish successfully into root A while the
serving process derives root B and refuses readiness, or a retry can recognize a
different pre-existing destination than the attempt actually created. The
claimed exact cleanup, readiness, and cross-process stable identity are therefore
not true for a supported configuration.

**Required correction**

Define one securely resolved artifact-root authority for the complete
transaction lifecycle. Bind a non-secret canonical root identity and its opened
filesystem identity (`st_dev` plus a stable descriptor-validated root identity)
into the reservation, active record, tuple digest, unpublished-path derivation,
cleanup, status, and refresh. Persist enough authority to reopen only the
original root after a crash; do not follow a newly supplied path to delete old
bytes. Define how the serving process proves it uses the identical root without
trusting a requester path. Add cross-process tests for config and environment
overrides, root changes between every lifecycle step, different local volumes,
symlink/path replacement, and recovery of the original unpublished tree.

### B1-V1-H3 — the publish linearization point is not durably ordered on macOS

**Severity: High**

**Evidence**

- The plan says files and directories are fsynced and then the unpublished tree
  is published with `renameatx_np(..., RENAME_EXCL)`; it does not require a sync
  of the destination parent after the rename
  (`reservation-rebaseline-plan-v1.md:182-188`).
- It immediately treats rename success as irreversible `publish_committed=true`
  and says a crash after rename is recovered as success
  (`reservation-rebaseline-plan-v1.md:188,194-202`).
- The active state is stored under a different authority root and, with a custom
  artifact root, may be on a different filesystem. The plan defines no ordered
  durability barrier between the published directory entry and the later
  succeeded state.
- T07 uses process barriers around the syscall and `SIGKILL`; that proves process
  race behavior, not directory-entry durability. T10.1 asks only for unspecified
  "fsync sequence instrumentation," and T21 only restarts status/projection
  (`reservation-rebaseline-test-spec-v1.md:109-116,160-176,355-368`).

**Consequence**

A process can record or emit durable success while the destination parent has
not durably committed the rename. A host crash or power loss can therefore
leave `active.json` saying published/succeeded with no final artifact, or expose
an artifact entry without a durably ordered terminal record. This violates the
publish-once readiness promise and the exact cancelled-before/succeeded-after
boundary.

**Required correction**

Specify the macOS durability protocol and its sole linearization point: sync the
complete unpublished tree, perform the exclusive rename, sync the destination
parent after rename using the required macOS durability primitive (including
`F_FULLFSYNC` where the promise includes stable-media power-loss durability),
then and only then persist `publish_committed`/`succeeded` and emit success.
Define recovery when any barrier fails, including separate authority/artifact
filesystems. Extend T07/T10 with injected failure and reboot/power-loss-grade
recovery at every file sync, directory sync, rename, post-rename parent sync,
active-state sync, and event boundary; `SIGKILL` alone is insufficient.

### B1-V1-M1 — the 64-reservation ceiling has no deterministic admission or eviction rule

**Severity: Medium**

**Evidence**

- `reservations.json` permits at most 64 entries and preserves UUIDs for complete
  unchanged tuples, but the plan never says which 64 eligible tuples are kept
  when the current signed catalog projects 65 or more
  (`reservation-rebaseline-plan-v1.md:139-158`).
- Acceptance requires stable, distinct IDs, while the product surface can reorder
  and filter rows (`reservation-rebaseline-plan-v1.md:270-274`;
  `reservation-rebaseline-test-spec-v1.md:53-59,259-270`).
- T01 only rejects an already encoded 65-entry snapshot. T02 exercises three
  rows and feed reordering. No test constructs 65+ simultaneously eligible rows,
  checks the projection's bounded selection, or tests churn at the ceiling
  (`reservation-rebaseline-test-spec-v1.md:30-59`).

**Consequence**

Independent implementations can reject the whole projection, truncate in input
order, evict previously stable actions, or choose different rows after a feed
reorder. The claimed stable action identity and affected-row-only invalidation
then fail exactly when the catalog grows beyond the fixed snapshot capacity.

**Required correction**

Freeze a deterministic, authority-derived selection and eviction algorithm for
more than 64 eligible tuples, including tie breakers, preservation priority for
unchanged IDs, and behavior for a currently displayed or dispatched action.
Add 65-, 128-, and boundary-churn tests across input reorder, restart, one-row
mutation/removal, dispatch racing snapshot rewrite, and re-entry after eviction.

### B1-V1-M2 — total published-artifact consumption is unbounded and has no safe operator recovery path

**Severity: Medium**

**Evidence**

- Each attempt is capped and requires free space for two copies plus reserve,
  but a successfully published durable artifact is never automatically removed
  (`reservation-rebaseline-plan-v1.md:176-188`).
- Rollback leaves every published artifact inert, and explicit non-goals reject
  durable garbage collection (`reservation-rebaseline-plan-v1.md:288-294,337-347`).
- The risk table calls state bounded by counting only the two JSON records, one
  marker, and 64 reservations, omitting the content-addressed artifacts that can
  accumulate once per changed model revision/hash (`reservation-rebaseline-plan-v1.md:312-322`).
- T09's 10,000 attempts are successful/idempotent/cancelled without requiring
  unique published identities. T10.4 affirmatively retains A and B. T16 exposes
  cleanup-required only for staging, not safe removal of unused published
  artifacts (`reservation-rebaseline-test-spec-v1.md:139-159,174-176,259-272`).

**Consequence**

Normal signed catalog evolution can consume unbounded disk on the provider Mac.
Once space is exhausted, the product offers no typed, identity-safe way to
explain or reclaim unused published artifacts; manual path deletion is the only
recovery despite the plan deliberately hiding paths and rejecting broad scans.
The claimed bounded-resource behavior and provider-recoverable UX are incomplete.

**Required correction**

Keep automatic GC rejected, but define a bounded inventory/accounting contract
and an explicit provider-confirmed cleanup transaction for artifacts proven not
to be the incumbent, configured path, active/prepared adoption target, or an
in-flight publication. Define total/available/reclaimable bytes and bounded
enumeration, crash-safe deletion, custom-root handling, and rollback behavior.
Test many unique releases through the budget boundary, current/adoption races,
partial deletion crashes, and exact no-delete protection for all live identities.

### B1-V1-M3 — cancellation has no bounded observation point inside a multi-gigabyte network transfer

**Severity: Medium**

**Evidence**

- The worker checks cancellation before and after each file transfer, but the
  stated 8 MiB chunk rule applies to hash/copy loops, not to bytes arriving
  inside one network transfer (`reservation-rebaseline-plan-v1.md:170-178`).
- The current downloader awaits `URLSession.download` for a complete file and
  checks its deadline before and after that await; it has no production progress
  delegate or cancellation-marker callback inside the file transfer
  (`phase3-binary/Sources/macprovider-cli/AutotuneRecommend.swift:3206-3285,3362-3394`).
- The current downloader also supports URLSession resume data within an attempt,
  so a refactor must distinguish permitted transient-network resume from the
  plan's crash/retry-from-zero promise (`AutotuneRecommend.swift:3211-3230,3288-3340`).
- T06 asks for a mid-download chunk cancellation and T09 asks the reader to stop
  at the first excess byte, but neither the plan nor test spec defines the
  production network callback, maximum network chunk/latency, task-cancellation
  acknowledgement, URLSession temporary-file custody, or resume-data disposal
  that makes those assertions executable
  (`reservation-rebaseline-test-spec-v1.md:96-107,139-159`).

**Consequence**

A single safetensors shard can transfer for minutes while cancel/status events
remain stale and while bytes exceed the signed estimate. Implementations can
pass boundary tests with a test hook yet fail to observe a real cancellation or
byte cap until URLSession returns the complete file. Temporary download/resume
bytes can also escape the transaction-owned staging and exact-cleanup model.

**Required correction**

Define the production URLSession delegate/streaming contract: bounded progress
callbacks, cancellation-marker and monotonic-deadline checks during transfer,
immediate task cancellation at the first byte over the aggregate cap, heartbeat
emission, response/content-length rules, custody and cleanup of URLSession temp
and resume data, and the exact distinction between same-attempt transient resume
and post-crash retry from zero. T06/T09 must use a real throttled HTTP transfer
with a multi-chunk large file and prove bounded cancellation latency, byte reads,
disk writes, heartbeat cadence, task termination, and zero unrecorded partials.

## Test-matrix assessment

T01-T24 are broad and preserve the correct final boundary: unit fixtures cannot
replace the real signed Apple Silicon, discovery, admission, settlement, credit,
and release evidence in T21-T24. They also correctly retain the current
CONFORMANCE blockers and do not credit #1453 checkboxes as signed proof.

They do not prove the six blocked claims above. T18-T20 cannot legalize missing
authority; T04/T08/T13 omit cross-process custom-root identity; T07/T10 test
process races without a post-rename durable-order contract; T01/T02 do not cover
selection above 64 rows; T09 does not bound unique durable publications; and
T06/T09 name a mid-transfer result without specifying the production mechanism
that can observe it.

## Informational observations

### B1-V1-I1 — the rebaseline cleanly rejects the unneeded R27 architecture

The new plan does not reuse the root daemon, XPC service, SQLite/VFS, signed
local witness chain, worker records, PID authority, maintenance lease, or
destructive operator protocol that made R27 unimplementable. The historical
review hash and 6 High / 3 Medium counts reproduce exactly. None of those old
findings is carried as a false positive against this smaller design.

### B1-V1-I2 — economics and final acceptance boundaries remain truthful

The plan consistently keeps preparation local and non-economic, does not grant
admission/routing/settlement authority, preserves the incumbent until separate
adoption, and requires signed SPEC-046/SPEC-047 journeys plus real settled
positive-credit evidence from final release assets. Current CONFORMANCE confirms
those journey rows remain pending. These strengths do not offset the blocking
authority, lifecycle, durability, resource, and test gaps above.

## Required disposition

Revise the plan and test specification without weakening any existing
acceptance criterion. Resolve all six findings, freeze the exact authority and
#1485 ownership boundary before implementation, reproduce new hashes, and run a
fresh independent adversarial plan review. PASS remains available only at
0 Critical / 0 High / 0 Medium.
