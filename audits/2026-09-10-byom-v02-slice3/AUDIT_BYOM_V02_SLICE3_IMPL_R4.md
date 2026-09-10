# IMPL audit R4 (closure after the independent review) — BYOM v0.2 slice 3

**Diff reviewed:** full working tree `git diff origin/main` at `b4d8…` (independent-review fix pass `aee1239c` + R4 prompt) + uncommitted `cmd/coordinator/main.go`. **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 1 H / 3 M / 1 L |
| security-reviewer | 0 C / 0 H / 1 M / 1 L |
| architect | 0 C / 0 H / 3 M |

Every finding is a consequence of the independent-review fix pass (not a reopening of earlier items); all resolved in the commit that adds this record:

- **HIGH (code) / MEDIUM (security, architect): the session pin vanished after the first mismatch.** `pinArtifactSession` compared against the CURRENT verdict's binding, which the mismatch itself cleared, so the next report could rebind to another member; a hash-less report cleared it too. Session authority now lives in its own field: `pool.Provider.IdentityPin` records the FIRST verified identity of the session (the row's primary pair, or exactly one member), is never replaced, survives every later verdict, and is reset only by a model change (warm swap, R006) or re-registration. A primary-pinned session reporting a member, and a member-pinned session reporting the primary or another member, mismatch — on the heartbeat and refresh legs. `TestArtifactSessionMemberIsPinnedAcrossHeartbeats` now covers repeated reports, a hash-less report, a refresh after the mismatch, return to the pinned member, and the primary-pinned case.
- **MEDIUM (code, architect): the buyer still named the row model id where a decision records the member's row KEY.** `byomCatalogModelKey` — asserted key, else the member's `ModelKey` for a member-bound session, else tier-2's normalized model id — drives both the admission lookup and the settlement predicate; `Member.ModelID` is still compared to the tier-2 row separately. The artifact seed helper now records the member key (`model-a-key`, distinct from the row model id `model-a`) and the success test settles through that key. (Attribution: the v0.1 row-bound path still looks events up by tier-2's model id while the CLI's `catalog_model_key` is the row key — pre-existing, non-earning in v0.1, listed for slice 4.)
- **MEDIUM (code, architect) / LOW (security): the real heartbeat leg skipped the admission-mode gate** (only hello and refresh went through the helper). The gate now lives inside `resolveArtifactIdentity`: `ModelIdentityRequest.CatalogAdmissionMode` is carried by every leg (hello, heartbeat preflight, pool heartbeat, refresh) and a non-`current`/`previous` mode binds no release. Pinned through the REAL registry heartbeat with the ws resolver installed (`update_bridge`/`legacy` unbound, `current` bound, `previous` with its own digest unbound).
- **MEDIUM (code): the missing-tier-2-material fallback returned `!marked` before the artifact check.** Every legacy fallback goes through `byomLegacyRoutingEligible` (`!marked && ArtifactIdentity == nil`); `TestArtifactBoundSessionWithoutMaterialIsExcludedFromRouting` (empty store, model absent from tier-2 → 503, no credit).
- **LOW (code): `replaceItemAt` kept an existing cache file's loose mode.** The published cache is `chmod 0600` after replacement; test republishes over a `0644` file.

Verification: `go test ./internal/artifactidentity ./internal/modelidentity ./internal/pool ./internal/pow ./internal/ws ./internal/billing ./internal/buyer ./internal/tier2 ./cmd/... -count=1` ok; `swift test --filter 'BYOMArtifactDigestTests|BYOMAdmissionTests|BYOMDiscovery|AutotuneArtifactFeedTests|BYOMEvaluation|BYOMModelAdmission'` 128 tests, 0 failures; `check_spec_governance.py` passed.

Anchored loop after the independent round: R4 findings were all consequences of the R4 fix pass itself; R5 runs the three lanes once more over the FULL working-tree diff for closure.
