# Audit — BYOM v0.2 slice 5 IMPL round 4 (final anchored round): intake pipeline after the R3 fixes (#1453)

METHOD CONSTRAINT: first-party IMPL review (privacy-critical: buyer-request aggregation; money-adjacent: catalog admission evidence and the offer-path sanction predicate). Do NOT modify or commit the worktree. Review the FULL working-tree diff `git diff origin/main -- phase4-coordinator scripts docs/runbooks specs/CONFORMANCE.json` (the working tree carries two uncommitted files, `phase4-coordinator/cmd/coordinator/main.go` and `phase4-coordinator/internal/config/config.go`, that are part of the change; review them as landed) against the governing text AS AMENDED IN THIS BRANCH (`git diff origin/main -- specs/`): SPEC-017 v0.2.1 §1.5 C5, §3.2a, §5.2b (all subsections and AC-INTAKE-1..5), §5.3, §5.4.3, §7.2.2, §9.1, §9.2, §9.5; SPEC-047 v0.1.6 R001 intake aggregate paragraph, R006, R007, R009, §4 step 10; SPEC-023 v0.10.4 §16.2(a)–(c), §16.3, §16.4, §16.7, §16.8 rules 1–9, AC-CAT-13, AC-CAT-21. Quote the code you object to with file:line. Do not read `audits/` or `.omc/`; form your own view.

## What changed since round 3
- Buyer hook fails closed without an admitted catalog (empty `CandidateRowStatuses` → nothing observed); panic log carries no payload.
- `intake.ParseUTC` (only `YYYY-MM-DDTHH:MM:SSZ`), `intake.ValidateFleetRAMJSON` and `intake.DecodeClosed` (second decode must hit EOF) shared by the rollup's period-reuse check and the handler's read-side check.
- `ModelAdmissionIntakeOfferPairs(ctx, since, until, limit)`: SQL `LIMIT`, in-memory stop; the builder asks for ceiling + 1.
- Every intake 401 (absent, unlisted, provider-bound) debits and keeps an auth-failure slot; SPEC-017 §4.3/§5.7/§5.9/AC-21 carve intake out of CORS.

## What changed since round 2 (commit after `f4e2d5a4`)
- `matchModelAdmissionOffer` returns the catalog match AND `intake_model_key` from ONE release read (one catalog snapshot, one identity set).
- `excluded_account_count` removed from the wire window; the aggregator keeps the cardinality internally for change detection.
- Every intake refusal (no key, unlisted, provider-bound) is padded with `padAuthFailureLatency` at the mux before the partner tier; OPTIONS on an enabled intake endpoint is 405 `Allow: GET, HEAD` with no `Access-Control-*` header.
- `validateIntakeRow` (closed decode with unknown fields refused, `intake.ValidateWindow`, ≤ 3 windows, eleven floors, k, reconciliation) runs before a persisted row is served; failure → `stats_stale` 503.
- Request-log test asserts the constant `error` message; generator parses retained sources and the manifest with `strict_json`; nested closed-shape assertions in the handler test.

## What changed since round 1 (all in the fix-pass commit)
- Buyer hook: eligibility = normalized key not a `listed`/`recommendable` row of the current release (`CandidateRowStatuses` on `AutotuneFeeds`), evaluated before the `ModelKnown` branch; `WithIntakeExcludedAccounts` at the buyer boundary; recover around the observer; unserved-model request-log row carries a blank model and a constant message.
- Aggregator: `WithPolicy(policyID, count)` (no account set inside the package); `Params` maxima and `principal_cap_pct ≤ 10`; `ValidateWindow`; wire drops `close_reason`/`eligible_request_total`; ≤ 3 windows; exact 30-day epochs.
- Config: `stats.intake.policy_salt` (required when enabled, env: indirection), `EligibilityPolicyID()` = HMAC-SHA-256 over the canonical set; bounds; duplicate/blank excluded accounts refused.
- Stats: `/v1/stats/intake` now routable (`trimEndpointFromPath`), every refusal 401 with one shape, no CORS headers, key-less refused before the public tier, disabled → 404 for OPTIONS too; rollup fleet histogram frozen per 30-day period (`fleetRAMCurrent`), trust-root join, `[start, end]` bound, highest-floor tie, sub-floor folded, persisted windows validated; migration 028 grants `hardware_verification_trust (provider_id, expires_at)`; canonical `methodology` strings.
- ws: offer-time `intake_model_key` (`intakeModelKeyForOffer`, column + DISTINCT pair scan on both stores), per-build `nonce`, `providerIntakeEligible` (unsanctioned AND active trust root where operated), trust category = no active root (never-trusted included), offer gate keeps v0.1.5 route-sanction scope, withdrawal ungated (R006).
- Generator: strict timestamps, 30-day/≤3 windows, closed methodology, `nonce`, fleet reconciliation, ppm floored to 50 000, `rate_class` from the artifact feed, `spec017_amendment_not_landed` refused once CONFORMANCE says SPEC-017 ≥ 0.2.1, 0600 store files, `verify` validates the manifest without a previous release.
- Runbook, CONFORMANCE (SPEC-047-R009, depends_on), spec index.

## Invariants to challenge
- Is the new eligibility predicate exactly SPEC-017 §5.2b.2 items 1–5 (authenticated gateway context; `demo:`; before-resolution rejections; excluded set; catalog-not-pool)? Can the feed snapshot be nil or stale at request time and what happens then (nothing observed vs everything observed)? Any raw-string or account retention after `Observe` returns?
- Can any path still persist or serve a sub-k / sub-floor bucket, an incomplete window, or a non-30-day window (aggregator Snapshot, rollup merge, persisted rows, handler)? Is the fleet freeze correct across restarts, period boundaries, clock skew, and a future-dated persisted histogram? Does the SQL only read the columns the grant allows?
- Auth surface: is 401-only + no-CORS + pre-tier refusal exactly implemented at the mux and the handler, including HEAD and OPTIONS, without changing any other endpoint's behavior? Timing equivalence between unlisted and non-existent keys?
- Policy id: is the derivation keyed, canonical, and never logged; does a salt or set change close the window; is the id ever computed from an un-trimmed or unsorted set?
- ws: is `intake_model_key` resolved under the release read lock from the same catalog the offer was matched against; can a pair count a provider that became eligible after the pair scan or ineligible before publication (state the linearization you find); is withdrawal truly ungated on every category while the offer gate is unchanged from v0.1.5; is the `nonce` in the closed frame everywhere (SPEC, generator, tests)?
- Generator: are the new closed-schema checks complete against the SPEC-017/SPEC-047 wire text (every key, type, ordering, bound); does the ppm grid change any threshold comparison; does the CONFORMANCE gate read the version of record correctly; are the hermetic release tests still exercising the manifest path?
- Tests: do they assert the amended AC-INTAKE-1..5, R009's list, and AC-CAT-21's v0.10.4 cases — or only the happy path?

## Lanes to report (this pass is: {{LANE}})
CRITICAL / HIGH / MEDIUM / LOW / INFO; bar 0 C / 0 H / 0 M. code-reviewer: correctness vs the SPEC text, error handling, tests. security-reviewer: privacy leakage, principal handling, auth gates, fail-closed paths, resource bounds. architect: package boundaries, lifecycle/locking, restart semantics, evidence path end to end. For each finding: severity, file:line, the quoted code, why it fails, the minimal fix.
