# AUDIT — BYOM v0.2 slice 4 IMPL independent cold-context review (3 Claude reviewer lanes, neutral prompt, audit records withheld)

Reviewed: full working-tree diff at `0bb731ba` + uncommitted `cmd/coordinator/main.go`, after the anchored codex loop closed at four rounds (security at bar since R2, architect at bar at R4).

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 0 HIGH / 4 MEDIUM / 6 LOW / 0 INFO |
| security-reviewer | 0 CRITICAL / 1 HIGH / 2 MEDIUM / 4 LOW / 5 INFO |
| architect | 0 CRITICAL / 2 HIGH / 1 MEDIUM / 4 LOW / 6 INFO |

The cold-context round found what the anchored loop could not: two HIGHs on the append side of the money path and a set of contract/defence-in-depth gaps.

## HIGH — fixed
- **Dual control defeatable with two actor ids sharing one secret** (security, architect). `distinctOperatorActors` counted ids; `authorizedProviderAuthPolicyOperator` returned the first matching entry in random map order, so one secret could request AND approve. Fix: `dual_control_unavailable` now uses `providerAuthPolicyDualControlAvailable()` (the `/admin/hardware-trust/approve` predicate: ≥2 entries, valid actors, non-empty pairwise-distinct secrets), and a bearer matching more than one entry is refused (`invalid_operator_token`, logged `internal_bearer_ambiguous`) — this also hardens the hardware-trust surface. Runbook states it. Test: `TestModelAdmissionOperatorDualControlSecretsAndReservedKeys`.
- **Provider could pre-empt coordinator drift-revocation / operator decision request ids** (architect HIGH; code + security MEDIUM). Provider `idempotency_key` is stored verbatim as `request_id` in the same `UNIQUE(provider_id, request_id)` index as `coordinator_<state>_<digest>` (deterministic from provider-known inputs) and `operator_decision_<candidate>_<key>`, making a squatted key turn the coordinator's R006 revocation into a swallowed replay conflict. Fix: (1) offer/withdrawal validators reject `coordinator_`/`operator_`-prefixed `idempotency_key` and `nonce` (`reservedModelAdmissionToken`); (2) operator/approval request ids use `:` separators, outside the provider grammar, so no collision is representable. Test: same.

## MEDIUM — fixed
- **`validated_release_generation` gate inert before the first publication** (code, security): generation started at 0 and an unvalidated binding also carried 0. Fix: `NewServer` seeds the generation at 1 (0 = never validated), the guard refuses a 0 generation or a 0 validated stamp; the buyer re-checks `allowed_runtime_sources` for a feed member and `mlx_cache` for a row member at route time, and a record with no bound member source never settles.
- **Release read lock held across the SQLite route-snapshot insert** (code MEDIUM, architect LOW): the insert now runs outside the hold; pre-check under one read hold (generation captured), insert, post-check under a fresh read hold (same generation, head, binding generation) plus the registry re-read (binding, epoch, validated generation).
- **Legacy decided records skipped by the sweep** (architect MEDIUM, security INFO): a decided candidate with no recorded match (pre-v0.1.5) is now revoked `catalog_row_changed` by the first sweep (logged `model_admission_legacy_record_revoked`); it could never bind or route anyway; re-entry is a fresh signed offer.
- **Stale artifact feed causes terminal revocation on reload** (code): spec-conformant (SPEC-047-R001 "Match" and R006(b) list a stale set as "no usable set"; SPEC-023 §3.7.6 rules 4–5 make a stale-feed session unverified, so R006(a) revokes regardless). Carried as designed; the runbook now states that the 14-day feed freshness is load-bearing and points at the renewal runbook.

## LOW / INFO — fixed
- Replacement hello evaluates (a)/(d) against BOTH the prior binding's candidate and the newly derived one (code LOW).
- CONFORMANCE R006 evidence names the production `helloSessionBindingLocked` / `heartbeatSessionEvaluationLocked` (code, architect LOW).
- One `.previous-target` resolver: `loadPreviousAutotuneCatalog` uses `buyer.PreviousAutotuneReleaseTarget` (code LOW).
- Operator rate-limiter evicts empty windows (code, security LOW).
- `ConsumePendingModelAdmissionDecision` removed from the store interface (dead, wall-clock) — consumption is only the atomic approval append; the handler owns expiry/consumed checks with the server clock (code LOW, architect INFO).
- 405 responses use the closed envelope with 400 `invalid_request` (code, security, architect LOW).
- A no-op binding refresh (heartbeat) no longer advances the binding generation (security LOW).
- Drift revocations carry no bound-member/six-value/evaluated-generation fields (architect INFO); `resolveModelIdentityVerdict` doc corrected (architect INFO); `byomBoundMemberMatchesSession` default branch fails closed (security INFO); runbook notes the kill switch does not cover operator endpoints (security INFO).

## Carried (documented in the PR body)
- `model_admission_store_error` (500) is outside R001's closed error list: an infrastructure failure code; a SPEC editorial note is the right home (code, security LOW).
- A staged Tier-2 catalog can outlive a reload aborted by a later step (fail-closed: old material stays live; re-staged by the next SIGHUP); `reloadCoordinatorConfig` is conformance-mapped and untouched (security LOW, code open question).
- A provider with any admission record and no binding is excluded from default paid routing (pre-existing v0.1 semantics, fail-closed) (architect LOW).
- Offer-time match runs under the release read lock before the section (recorded provenance may be one generation old; identity is content-anchored and re-resolved at decision time) (code/architect INFO).
- Offer listing truncates at the candidate cap without a marker (closed schema) (security INFO). `tier2` release publisher is a package global (architect INFO). `feedIntegrityFailed` = "current set build failed" (security INFO).
