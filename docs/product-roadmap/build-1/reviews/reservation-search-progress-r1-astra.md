# Reservation search progress R1 — independent architecture plan gate

Verdict: **REJECTED — 0 Critical, 0 High, 3 Medium, 0 Low.** No implementation authorization.

Exact proposal SHA-256: `dd3b085d42949a77b7f77bcb78112c81c209460a1781baa498380b353255a035` (`reservation-search-progress-addendum-r1.md`). Independent native GPT-6 Astra, high reasoning. Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Reviewed current uncommitted code in `/Users/augstar/.codex/worktrees/macprovider/product-build-1`, the author's analysis, immutable binding r3, separately approved active-index receipt r1 and the existing test contract. Only this report was written; no runtime edits or tests were performed.

Origin-bound immutable classifications are a plausible direction. The plan correctly identifies that a rotating cursor cannot prove absence, preserves multiple matching candidates, and separates healthy eight-call qualification from maximum-shape cooperative-I/O tests. However, its explicitly unresolved transition and migration questions are executable authority decisions. They cannot be deferred to implementation under a zero-severity gate.

## RSP-ARCH-M1 — Pending departure lacks an executable owner/recovery contract

**Severity: Medium.**

**Evidence:** The proposal's first-departure section references a pending intent before primary publication, allows recovery of its exact prospective primary, and explicitly leaves orphan-start recovery unresolved. Current `ModelCatalogTransactions.swift:481–520` reads the historical primary first and attempts owner acquisition only when `historical.startedAt != nil`; a queued primary therefore follows the no-owner branch. `run` at 642–667 checks for an unstarted primary, obtains the owner, creates its lifetime guard, writes running through `update`, acknowledges durable start, then launches work. `update` at 336–347 uses generic contention retry; `retryBeforeMutation` at 359–372 is the existing separate mechanism for preventing replay after a durability bundle starts.

**Consequence:** Death after pending-index publication but before the running primary leaves a queued-looking historical record and a pending intent that blocks reservation. The current reconciliation route does not acquire the owner for this state. Blindly replaying the intent through the ordinary start path risks launching work under recovery rather than the original live owner's authorization. Publishing running and returning without defining orphan resolution can strand the pending generation or misreport progress. Generic update retry also cannot safely reinterpret a partially published transition as a new transform. Queued cancellation currently writes without holding the UUID owner, so applying the new owner requirement uniformly also needs an explicit start/cancel race rule.

**Required correction:** Specify a closed pending-departure state machine and integrate it with reservation, run, status/cancel and all first-departure writers. Define the durable intent's exact fields, exclusive file name, immutable pending-byte identity, publication order, and behavior for every old/new primary and left/index combination. Consult pending state before making owner decisions from `startedAt`. A viable bounded correction is exact-owner recovery that completes only the frozen durable transition, never launches a worker, and routes an ownerless published start through the existing truthful interrupted-owner outcome with normal result/seal/binding checks. Distinguish that from a still-live owner finishing its own start. Prevent generic retries after the first publication and define where durable heartbeat acknowledgment is permitted. Preserve cancellation behavior when the competing start owns the UUID.

**Required tests:** Actual child death and thrown failure before/after pending reference, prospective primary, left and final index; invoke real status/cancel and reservation afterward, including the old-primary-still-queued case. Assert finite resolution or the explicitly defined protected state, no worker launch, no invented success, no duplicate reservation and no heartbeat acknowledgment from recovery/index activity. Exercise live start versus queued cancellation and ensure immutable pending bytes are never regenerated from a new transform.

## RSP-ARCH-M2 — Migration writer interlock and frozen-decision lifecycle are not selected

**Severity: Medium.**

**Evidence:** The migration section alternately permits writers that publish departure metadata for classified entries or suggests returning busy to mutating operations during a classification cut. It does not select a complete interlock, and allows either unchanged membership or an unspecified reconciliation at v4 installation. It also says a writer race leaves a pending decision for a fresh capture, while its WAL rule requires recovery of exact frozen pending bytes. Current mutations include generic commit, first start/cancel, queued expiry (`ModelCatalogTransactionRetention.swift:406–417`), success binding/index/terminal publication (`ModelCatalogTransactionBindings.swift:195–232,263–281`), cleanup and direct result/artifact publication. These are not all one writer seam. The lifetime guard fences after eight seconds without its own durable heartbeat and exits after ten (`ModelTransactionOwnerLifetimeGuard.swift:9–10,35–47,70–82`).

**Consequence:** A migration-wide busy policy over repeated bounded calls can suppress a live owner's heartbeat and trigger termination. A merely per-call cut permits writers between calls; frozen membership/classification can then disagree with subsequent writes unless every writer participates in a defined durable protocol. Reclassifying an already-persisted pending decision after a racing mutation breaks the promised immutable negative proof. Refusing changed evidence forever without a selected recovery/abort rule can prevent migration and reservation indefinitely. Publishing v4 after an unspecified membership reconciliation risks omitting a competing allocation or losing departure authority.

**Required correction:** Choose one complete writer/interlock protocol, with a concrete call-site inventory and explicit treatment of already-running owners, heartbeats, cancellation, result/terminal publication, retirement and allocation. It must preserve short-control and owner-lifetime guarantees without retaining global/all-UUID locks across calls. Define the durable migration phases, exact source and prefix fields, pending class/left bytes and observations, preparation publication, completion intent and exact installed-v4 digest. A capture invalidated **before** pending publication can be retried; a durable pending decision needs its own defined immutable recovery or conservative failure transition, not silent reclassification. Select unchanged frozen membership or specify the full reconciliation algorithm and its CAS; do not leave that authority choice open. Missing acknowledged class/left evidence must not be recreated by rebaselining a current primary.

**Required tests:** Real owner heartbeat/start/cancel/commit/cleanup/retirement versus migration, including pauses spanning call boundaries and the owner fence interval. Death at prepared source, pending, class, left, acknowledgment, finalizing index and completion. Mutate source membership/reference/primary before pending, after pending and after acknowledgment and assert the distinct prescribed outcomes. Prove prior large bodies are not rescanned and the final membership/reference set is exactly the authorized set. Preserve the original healthy fixture's unresolved bytes rather than obtaining progress by terminalizing its records.

## RSP-ARCH-M3 — Older binaries do not reject the proposed incomplete-migration state

**Severity: Medium.**

**Evidence:** The proposal requires older binaries to reject both v4 and incomplete reservation migration, but keeps a v3 active index while `.reservation-migration` is populated and provides no earlier negotiated format transition. The current pre-change implementation is a concrete counterexample: `initializeLegacyRetention` at `ModelCatalogTransactionRetention.swift:95–102` opens the existing retention index; `loadActiveIndexLocked` at 144–160 accepts the existing format plus v2/v3. `initializeBindingMigration` at `ModelCatalogTransactionMigration.swift:207–217` recognizes completed binding migration. None consults `.reservation-migration`. Final v4 rejection follows the existing closed schema, but incomplete-migration rejection does not.

**Consequence:** A still-running or restarted prior binary can mutate the v3 journal while new code has persisted classification decisions. It can omit departure metadata and participate in allocation/retirement outside the new interlock. Tests that only feed the old reader the final v4 index do not prove the earlier window is safe. Documentation asking operators to use a compatible binary does not implement the stated fail-closed format contract.

**Required correction:** Design an early durable compatibility fence that the relevant prior binaries actually reject before any reservation classification becomes authoritative, with explicit crash ordering and new-binary recovery. For example, use a validated change in an existing mandatory closed format surface, provided actual old writers revalidate it before their final mutation; prove that property rather than assume it. Integrate the fence with M2's handling of live owners. Specify which released/development binaries are supported or rejected and retain all new metadata on rollback. If an operational exclusion is proposed instead, it is a material contract change requiring explicit review, not an implied exception to this plan.

**Required tests:** Run the actual supported old binary/read-write surfaces against initial, prepared, partial-classification, finalizing and completed states, including a writer paused before the new fence then resumed. Assert no primary/index/sidecar mutation after the fence. Test crashes around fence publication and compatible restart without deleting metadata or downgrading to v3.

## Preserved acceptance and further design constraints

The healthy fixture remains eight reservation calls within 64 seconds, each with its original eight-second budget; it must preserve 1,023 unresolved originals and reclaim the exact cancelled slot. The independently approved index-receipt correction remains separate. No change to pass counts, fixture size or reuse predicates is authorized by this review.

Maximum-shape tests should state a concrete cooperative latency profile and show completed classifications persist across calls. Current `ModelTransactionFileEvidence` restarts capture after budget expiry; a single primary whose complete validation cannot fit any one call cannot gain progress merely from a prefix cursor. The revised design/tests must state that per-record feasibility assumption or design resumable evidence capture with unchanged final identity/content verification. This is not a request to promise arbitrary 4 GiB throughput within 64 seconds. New allocation's 65,536-byte bound also requires the promised derivation from actual accepted authority fields, rather than an unrelated tighter input limit.

Permanent negative authority must validate exact class/origin/index/left relationships without trusting a tuple hash alone, weakening missing-file behavior or rereading every historical primary. Post-left rollback of a primary or removal of an optional index reference must not erase a retained immutable exclusion. Preserve legacy/protected distinctions, all prior binding/retirement/cancellation/cleanup outcomes and full combined audits. The current required tests identify these areas, but cannot substitute for the three missing protocols above.

## Snapshot manifest

SHA-256 values from the inspected shared-worktree snapshot:

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/reservation-search-progress-addendum-r1.md` | `dd3b085d42949a77b7f77bcb78112c81c209460a1781baa498380b353255a035` |
| `docs/product-roadmap/build-1/reservation-search-progress-analysis-r1.md` | `b548a92fc4cf2ffdf1711d65fb66b331c6d586a15077e1c678ac37c743bdf168` |
| `docs/product-roadmap/build-1/retention-active-index-receipt-r1.md` | `17780883c2a224ba7d07f76ee96d03463cf930e9eb479286c22b74b9d6b367b6` |
| `docs/product-roadmap/build-1/immutable-retirement-binding-r3.md` | `ab9179ecc17c31c733ad21705b7ad0a8db2b99d8739eb7ec8d892a06bb7318f8` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `04bc959b8317fb94688b02e325817c143c47f1ae1b73f5767ebb25d40745e93e` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `224ae2eb6245076a15ff4d0f2a6ac56ecacf5734ee43d5575798a6abc9ec757b` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionBindings.swift` | `923493e28d749859f686d2cd0b2af4d2735c7f8546bd80bbfe28d2f3816464b5` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionMigration.swift` | `afede2efc30cb131643ed188e4ce660d42395beed765382768eb52618e5ac5ba` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionEvidence.swift` | `df84197a779b94cde8ab6cd51ba5678d8888304a0ca92d16af202b7dfcd92d15` |
| `phase3-binary/Sources/macprovider-cli/ModelTransactionOwnerLifetimeGuard.swift` | `5d794a9aa75a6172b0c4a7c4f68be96e432ce34788896b3d80bbd7ec0b6de71c` |
