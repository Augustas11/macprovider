# Retention lock budget r1 — independent architecture gate

Verdict: **CHANGES REQUIRED — 0 Critical, 0 High, 1 Medium, 0 Low.** The zero-C/H/M implementation gate is not met.

Reviewed the proposed plan and actual store/owner call graph, read-only except this report. No source edits, subagents, production actions or new test executions. This is a plan feasibility review, not implementation or physical acceptance. Base: `914f7cafcdbcfc1805a10f4f34167218341d5587`. Review snapshot: 2026-09-10T07:40:11.419203+00:00. Sources are actively evolving; this report covers the hashes below and requires a final delta review after implementation.

Exact reviewed proposal SHA-256: `5464a6e317052e2845cd0f3a409296748596dca93ece867dc6614e94c5ab29a2`.

## RETENTION-LOCK-M1 — distinguish allocation and legacy evidence from generated active-operation receipts

**Severity:** Medium. **Confidence:** High.

**Evidence:** `retention-lock-budget-r1.md:17–23` defines the receipt as holding an exact selector, directs acquisition of the selected UUID owner lock, and requires active membership plus exact operation generation at final CAS. Line 31 applies that outside-lock flow to allocating-intent recovery. The inherited retention r4 contract, lines 36–38, permits an allocating intent with no primary record to be removed only when every non-index UUID path remains absent. Its legacy commitment exception and required tests explicitly permit safely validated resolved legacy records without `operationGeneration` to retire without creating a generation-scoped pointer. Neither case can supply the generic generated selector.

The actual `ModelCatalogTransactions.swift:138–155,194–200` owner-lock path opens `.owner-<uuid>` with `O_CREAT`, so using the proposed generic owner acquisition on an empty allocating intent creates the very evidence whose absence is required. The inode must never be deleted. Current `ModelCatalogTransactionRetention.swift:176–196` allocation recovery deliberately tests `includeOwner: true`; current reservation publishes allocating intent, primary, then active phase at lines 220–236. The existing allocation crash test at `ModelCatalogTransactionRetentionTests.swift:43–56` expects recovery after all three boundaries. Current maintenance also supports resolved generation-less evaluations by omitting pointer indexing rather than fabricating a generation (`ModelCatalogTransactionRetention.swift:268–271`).

**Consequence:** A literal common-receipt implementation permanently protects otherwise recoverable empty intents after creating their owner files. Requiring an actual generation selector also prevents retirement of supported legacy history; a full migrated legacy journal remains at capacity. Relaxing these checks ad hoc during implementation would silently change the approved recovery/authority contract. The architecture must specify the narrow distinctions before the gate passes.

**Required correction:** Define closed internal receipt/transition variants and their preconditions, without changing wire selectors or fabricating generation authority:

- Generated active-operation mutation: exact primary/cleanup selector, active phase, current index generation, pinned owner and captured-byte observations as proposed.
- Allocating-intent recovery: canonical index UUID plus captured `allocating` phase/index generation; an absent-primary case carries only required no-follow absence observations and never creates an owner inode. Under the short journal CAS, recheck the exact intent and all absences before removing it. A safely present untouched queued primary uses validated exact bytes and the existing owner/sidecar absence rules before activation. Preserve serialization of a live allocator's intent → primary → active publication so recovery cannot remove an in-flight allocation between those writes. Any preexisting owner or ambiguous evidence retains the slot under the inherited policy.
- Supported resolved legacy retirement: owner-protected exact canonical UUID/validated historical record bytes and membership CAS, with explicitly absent generation accepted only by the existing historical-format policy. No generated selector, recommendation pointer, action or success commitment is synthesized.
- State explicitly that archived pointer validation and healthy direct historical reads use read-only original evidence and do not require active membership. The final pointer/body placement checks still apply; archived evidence cannot authorize a new mutation or bypass fresh adoption authority.

**Required tests:** Preserve the real subprocess allocation crash matrix and add assertions that empty-intent recovery leaves `.owner-<uuid>` absent; existing owner/unsafe sidecars remain protected. Race recovery against a live allocation at each durable boundary. Migrate and retire 1,024 supported generation-less resolved legacy records, then allocate a new generated operation; preserve every historical byte, reject unsupported legacy evidence, and prove no generation-scoped pointer/action was invented. Retain archived pointer lookup and direct historical read tests after these receipt variants are introduced. These are explicit closures of inherited requirements, not permission to replace them.

## Nonblocking design assessment and implementation obligations

The outside-lock bulk validation followed by pinned-descriptor identity/size/nanosecond mtime/ctime checks and index-generation CAS is feasible within the stated trusted-UID boundary. The digest must remain tied to the exact bytes read from a stable opened descriptor, including before/after read stability; supported atomic replacement invalidates placement. Short final metadata checks are not a claim against privileged metadata forgery. No artifact metadata receipt may replace full current artifact verification, measured execution, signature/freshness checks or economic authority.

The inspected call graph confirms the bulk-lock problem: reservation and maintenance, allocation recovery, cleanup enumeration, completion/reconciliation indexing, previous-pointer validation and final recommendation reads all require the proposed seam changes. Pointer-before-retirement ordering, preservation of committed terminal truth when indexing fails, generation recapture after unlocked work, canonical nonblocking multi-owner ordering, cursor fairness, and explicit projection-unavailable on an incomplete pass preserve the approved architecture. Bootstrap enumeration outside the global lock is viable only with the proposed stable bootstrap lock, unchanged directory observation, and universal initialization gate for supported mutations; no reconstruction of initialized history is permitted.

The watchdog must cover prepare, evaluate and explicit cleanup owners, not only the runner heartbeat. Current cleanup has a separate blocking heartbeat loop (`ModelCatalogTransactions.swift:953–975`); current runner now uses a wall-clock five-second check and defer-based heartbeat cancellation (`:594–616`), so the proposal's old tick/pre-terminal-cancel description is partly stale. Monotonic fsync acknowledgment, eight-second fencing and an independent ten-second exit remain unimplemented in the inspected source. Preserve committed publication truth across interrupted writes; test the mutation fence at actual write/publication boundaries. The existing short-control dispatch timer (`ModelTransactionContext.swift:342–371`) and candidate kernel-parent guard are useful seams but do not themselves prove this owner contract. Verify child release and incumbent lifecycle handling, including the existing pipe-driven launchd restoration guard, without claiming restoration succeeded merely because the owner exited. Ordinary user cancellation remains the CLI transaction protocol.

Required test 2 should distinguish the expressly allowed bounded active-index/format decoding from forbidden primary/result/seal bulk parsing and loops under the global lock; an unqualified ban on all JSON parsing would contradict the plan's bounded index re-read. All hostile storage, process-exit, deadline, history and corruption tests remain required. None were run for this document-only gate. Fixture timing evidence cannot close B1-T10 physical MLX/settlement acceptance.

## Exact review snapshot

The following file hashes identify the inspected inputs. Snapshot manifest SHA-256: `ee79616cd450df02a2ac3e4c6f5b3efe57f90cee3615894e0f5934964328263c`.

| File | SHA-256 |
|---|---|
| `docs/product-roadmap/build-1/retention-lock-budget-r1.md` | `5464a6e317052e2845cd0f3a409296748596dca93ece867dc6614e94c5ab29a2` |
| `docs/product-roadmap/build-1/plan-r4.md` | `a5c7a56a68d3ea111289b122cd0a44d41aa4690900ed6f4b6257cf75c3c36e0d` |
| `docs/product-roadmap/build-1/test-spec-r4.md` | `20f4def1bee633ba3077d59b0dca1ed5e24397d387350a68e78dc04245bef8be` |
| `docs/product-roadmap/build-1/transaction-retention-addendum-r4.md` | `caa5fe5ea845651312680cb5ceebf59b9c3e82d0490525d561f01a89165221dc` |
| `docs/product-roadmap/build-1/long-hash-control-addendum-r3.md` | `19286de938b886e788792ec0d2f3d8e9ec019f8ba26501e400c78d953659db4e` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionRetention.swift` | `8977729e96b2828641d8ded82279be62d9b9728aea40310132c587bc9663f35f` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactions.swift` | `e74b19b37159da4897199da0295f856454372b719920687964ece9010efad51a` |
| `phase3-binary/Sources/macprovider-cli/ModelCatalogTransactionStorage.swift` | `eee2d11a4942ce270322e755118bed424b1d2687025295487f68439eb38b1607` |
| `phase3-binary/Sources/macprovider-cli/ModelTransactionContext.swift` | `2c42b60f04519f68871889a678d6175276cd62b630cc5983bb87086cd5dbb50f` |
| `phase3-binary/Sources/macprovider-cli/CandidateParentLifetimeGuard.swift` | `42f1c3ed58d2200cdfa92965895348432bfe4f064716e208051e8df6b58f6241` |
| `phase3-binary/Sources/macprovider-cli/ProviderConflictDetector.swift` | `de1b6478ebe27c078bf0f39ed9333e156834d70308b7514ad3d8d10527fff34e` |
| `phase3-binary/Tests/macprovider-cliTests/ModelCatalogTransactionRetentionTests.swift` | `38ceec90183a065f1962a5001c88501e117620592b325ad59669b121d6570e8c` |
