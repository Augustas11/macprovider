# AUDIT — BYOM v0.2 slice 4 IMPL round 2 (codex, three lanes, full working-tree diff)

Prompt: `AUDIT_BYOM_V02_SLICE4_IMPL_PROMPT.md` (ROUND 2 EXTRA). Diff: `git diff origin/main` at `bd649007` + uncommitted `cmd/coordinator/main.go`.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 4 MEDIUM / 2 LOW / 0 INFO |
| security-reviewer | 0 CRITICAL / 0 HIGH / 0 MEDIUM / 1 LOW / 1 INFO (at bar) |
| architect | 0 CRITICAL / 1 HIGH / 1 MEDIUM / 0 LOW / 0 INFO |

R1 fixes confirmed complete by all three lanes (nested release lock, lock inversion, exact-release session catalog, composite proof, nil guard, single write-lock publication).

## Findings and disposition (all fixed in `8ee2b0b9` + the selector-rename follow-up)

**HIGH — same-model heartbeat identity drift can pass compare-and-insert** (architect). The registry published a changed hash/verdict/pin before the section-protected drift evaluation appended anything, and the guard compared only candidate/head/generations. Fix: (1) the heartbeat handler applies the registry update AND the (a)/(d) evaluation under the provider's section (`heartbeatSessionEvaluationLocked`), and the registration path replaces the session + evaluates + binds under the section (`helloSessionBindingLocked`) — section → registry order kept; (2) a per-provider **session identity epoch** (`pool.Provider.ModelAdmissionSessionEpoch`, `Registry.sessionEpochs`) advances on session replacement and on every change of the identity fingerprint (model id, reported pair, verdict, pin, artifact binding, receipt keys, including the SPEC-015 pending→active commit); the buyer captures it and the guard requires it unchanged pre- and post-insert; (3) the R006(c) sweep also evaluates (a)/(d) for the bound decided candidate after `RefreshTier2HashStatuses` re-verified the session. Test: `TestModelAdmissionRouteCompareAndInsertFailsClosedOnSessionIdentityDrift`.

**MEDIUM — hello/heartbeat mutate the registry outside the section** (code). Fixed as above (both paths hold the section through registry mutation, drift evaluation and binding refresh).

**MEDIUM — served feed bytes visible before the atomic release** (code). Fix: `buyer.SetAutotuneFeeds` no longer swaps the bytes itself; the observer receives `(feeds, commit)` and `wsServer.PublishArtifactIdentitySetsWith(sets, integrity, commit)` runs the swap inside the release write-lock hold (main.go wiring). An observer that never commits leaves the previous feeds live. Test: `TestArtifactIdentityIndexRebuildsOnPublish` asserts the bytes change only on commit.

**MEDIUM — R003(ii) evaluated runtime-source policy before row recommendability** (code). Fix: (i) resolves members, then (ii) checks `recommendable` before the member source policy. Test: `TestModelAdmissionPreconditionOrderRowBeforeRuntimeSource`.

**MEDIUM — approval precedence (a)/(b) unsatisfiable as written** (code; security LOW). The closed approval body carries only the bound fields and the key, so every divergent body under a reused key is a bound-field disagreement. Fix: (a) precedes (b) in code; SPEC-047 R001 (b) and the R008 case are clarified in place (same v0.1.5 text, unreleased): a divergent approval body under a reused key is `invalid_request` under (a); the `idempotency_conflict` branch stays as defence in depth. Test updated.

**MEDIUM — R008 lifecycle interleavings** (architect). Added the epoch test above and the precondition-order test; hello/heartbeat now serialize with decisions by construction (section).

**LOW — pending timestamps parsed silently** (code): parse errors now returned with the column. **LOW — corrupt `catalog_members_json` indistinguishable from empty** (code): decode errors now fail the scan.

**INFO — `golang.org/x/crypto v0.55.0` module-level advisories, no reachable symbols** (security): carried; dependency upgrade is a separate reviewed change.

Process note: the first attempt to launch round 3 ran with an empty prompt (the governance check had rejected two new `...Locked` siblings of mapped bare-prefix selectors and broke the guarded chain); the siblings were renamed and round 3 relaunched.
