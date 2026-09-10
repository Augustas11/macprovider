# AUDIT — BYOM v0.2 slice 4 IMPL round 1 (codex, three lanes, full working-tree diff)

Prompt: `AUDIT_BYOM_V02_SLICE4_IMPL_PROMPT.md`. Diff under review: `git diff origin/main` on `feat/byom-v02-slice4-decision-path` at `HEAD` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 2 HIGH / 5 MEDIUM / 2 LOW / 0 INFO |
| security-reviewer | 0 CRITICAL / 1 HIGH / 2 MEDIUM / 2 LOW / 1 INFO |
| architect | 0 CRITICAL / 2 HIGH / 2 MEDIUM / 1 LOW / 0 INFO |

## Findings and disposition (all fixed in the follow-up commit unless noted)

**HIGH — nested release read lock deadlocks against a queued publisher** (code, security, architect). `generation()` took the release `RWMutex` again inside `withReleaseRead` (decision, approval, binding refresh, route guard); Go's writer-preferred RWMutex then blocks the nested read behind a queued SIGHUP publisher. Fix: `releaseSnapshotState.generationLocked()` for every caller already under the release lock; no nested read remains. Test: `TestModelAdmissionDecisionCompletesWithQueuedPublisher` (test hook `onReadLocked` queues a publisher behind the reader).

**HIGH — release→registry lock inversion** (security, architect). `settlementSessionMemberLocked` and the route guard resolved the registry under the release read lock while `RefreshTier2HashStatuses` / heartbeat hold the registry and take the release lock (registry→release). Fix: the live session is read from the registry BEFORE the release read lock (decision, approval, guard); no registry access remains under the release lock; the guard's post-insert binding re-read happens after the release hold.

**HIGH — compare-and-insert not atomic against appends** (code). An append could land between the guard's compare and the insert. Fix: the guard re-reads the head, the binding generation and (after the release hold) the registry binding AFTER the insert too; any difference fails the attempt closed — the immutable snapshot stands, nothing is dispatched/settled (R008 "the attempt fails closed or the immutable snapshot stands"). Appends stay serialized by the provider section, which the route path never takes. Test: `TestModelAdmissionRouteCompareAndInsertFailsClosedOnConcurrentAppend`.

**HIGH — compatible-previous session catalog selected by stale admission mode** (architect). `settlementSessionMemberLocked` used `CatalogAdmissionMode == "current"` to pick the active catalog; after a re-stamp the mode is stale and a release-B row proof could be combined with a release-A session member. Fix: `resolveProviderCatalogIn(provider, current, compatible)` resolves the session's EXACT release id (shared with `resolveProviderCatalog`); the head's row tuple is compared against that release. Test: `TestModelAdmissionSettlementRequiresSessionReleaseRowTuple` (re-stamp keeps settling; changed row digest → no bound member).

**MEDIUM — release read lock must span precedence (1)–(5)** (code, architect). Fix: decision and approval evaluate (1)–(5) / (a)–(g) inside ONE `withReleaseRead` hold (`evaluateModelAdmissionDecisionLocked`, `evaluateModelAdmissionApprovalLocked`); the binding refresh runs after the hold, still under the section.

**MEDIUM — feed-integrity flag published separately from the release** (code, security LOW, architect). Fix: `PublishArtifactIdentitySets` takes the write lock once; staged-catalog consumption, the integrity outcome, the catalog / identity sets / Tier-2 / generation swap all happen under that one hold (`publishReleaseLocked`).

**MEDIUM — pending replay rebuilt from the current head** (code). Fix: the pending record persists `admission_state`, `served_model_ref`, `catalog_model_key` (memory + SQLite columns, idempotent ALTER); a replay answers from the record only.

**MEDIUM — nil route guard = weaker money path** (code; security/architect LOW). Fix: a buyer composed with an admission store but no guard fails every BYOM-bound route closed (`ErrModelAdmissionRouteStale`); the buyer unit tests wire an explicit `testRouteGuard`.

**MEDIUM — offer's asserted `runtime_source` used as a live-session fact** (security). Fix: until SPEC-010-R007(e), R003(iv) binds only when the recorded `runtime_source` is `mlx_cache` AND the pinned member is a `macprovider.snapshot-manifest.v1` member (row or feed); a GGUF/loopback member never binds. Test: `TestModelAdmissionStaleFeedAndRuntimeSourceAtDecisionTime`.

**MEDIUM — feed freshness not enforced at match / decision / settlement** (security). Fix: `usableIdentitySetLocked` (present AND fresh) is the only set the feed path, R003(i)–(iii) and R003(iv) resolve in; a stale set resolves nothing (`no_artifact_match` at match, `catalog_match_stale` / `catalog_artifact_feed_changed` at decision and sweep). Test: same.

**MEDIUM — R008 concurrency matrix not implemented** (code). Added: queued-publisher decision, two concurrent first-seen requests with one key (one append + one replay), guard vs racing append / moved binding generation / second candidate for the same row, exact-release row tuple, stale feed, runtime-source restriction. Not covered deterministically: decision-vs-reload interleaving beyond the queued-publisher case (the sweep re-stamps the survivor — asserted), staged-integrity atomicity (structural: one write-lock hold).

**LOW — pending invalidation error discarded on stale_head** (code). Fix: propagated as a store error.
**LOW — gofmt** (code). Fix: `internal/autotune/catalog.go` formatted (the pre-existing `HighestClaimedTier` indentation is corrected in passing).
**INFO — method errors bypass the JSON envelope** (security). Fix: `405` now uses the closed envelope.
