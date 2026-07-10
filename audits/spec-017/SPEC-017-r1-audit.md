# SPEC-017 v0.1 audit report — Round 1 (Codex, 2026-06-25T18:37:57Z)

## Summary
- 3 CRITICAL findings
- 10 MAJOR findings
- 5 MINOR findings
- 2 QUESTIONS

SPEC-017 v0.1 has the right four locked pillars, but it is not ready to lock. The blocking issues are concentrated in BUILD-prompt fidelity: the stats table shapes are absent, the partner-key contract is not actually specified, and the earnings-visibility storage target assumes a provider table that the locked specs do not provide.

## Category sweep

| Category | Result |
|---|---|
| A BUILD-prompt directive fidelity | Findings C1, C2, M6, M8, M10 |
| B Endpoint contract correctness | Findings M1, M3, M5, M7, M8 |
| C Earnings visibility model | Finding C3, M2, q1 |
| D Hosting and isolation | Finding M4, m3 |
| E Versioning and deprecation | Findings M7, m4 |
| F Rollup pipeline | Findings C1, M3, M4, M6, M9 |
| G Acceptance criteria quality | Findings M1, M5, m3 |
| H Cross-spec invariant preservation | Findings C3, M8, M10 |
| I Honesty about deferrals | Finding M6, q2 |
| J Spec hygiene | Findings M10, m1, m2, m4, m5 |

## CRITICAL findings

C1. `stats_*` table shapes are not normatively defined
    **Location:** BUILD prompt §4 lines 56-65; SPEC-017 §7.2 lines 764-778; §9.1 lines 879-890
    **Finding:** The BUILD prompt requires v0.1 to define the `stats_*` table shapes and refresh cadence. SPEC-017 defines cadences and grants `stats_reader` access to table names, but it never defines the table schemas: columns, types, keys, uniqueness, generated-at storage, or how the JSON fields map to table columns.
    **Why it matters:** Two conforming implementations could create incompatible Postgres schemas and still claim to satisfy the spec. The handler contract also depends on these tables for isolation from billing/session OLTP, so the missing schema weakens the central safety invariant.
    **Suggested fix:** Add a normative storage subsection with table definitions for every `stats_*` table used by §5 and §9, including generated-at columns, row keys, indexes, and JSON-field source mapping.

C2. Partner-key issuance/storage/rotation is missing and the table reference is broken
    **Location:** BUILD prompt §5 lines 67-72; SPEC-017 §3.7 lines 238-243; §5.5 lines 574-585; §5.6 lines 596-602
    **Finding:** The BUILD prompt requires partner-key format, issuance procedure, storage location, rotation policy, rate limit, and the stable list of unlocked fields. SPEC-017 gives a token prefix and mentions a new `partner_keys` table, but the cited `§5.3` is the health endpoint, not a table definition. The spec also references `partner_keys.allowed_origins`, `id`, and `label` without defining the schema, issuance authority, hash/secret storage, revocation, or rotation behavior.
    **Why it matters:** The partner-key projection is the one allowed schema superset. Without a complete key contract, browser CORS, revocation, logging redaction, cache keying, and per-key rate limiting are under-specified and likely to drift in the first implementation.
    **Suggested fix:** Add a partner-key contract section with table shape, hashed-token storage, operator issuance flow, rotation/revocation semantics, allowed-origin validation, and the exact partner-only fields from §5.2.

C3. Earnings visibility is pinned to a non-existent `providers` table
    **Location:** SPEC-017 §1.5 C6 lines 112-115; §3.6 lines 232-236; §6.1 lines 653-665; §6.3 lines 687-696; SPEC-016 §3.1 lines 347-350; SPEC-002 §7.3 lines 2294-2308
    **Finding:** SPEC-017 requires a shared `providers.public_earnings_mode` column and a SQL update against `providers`. Locked SPEC-016 says there is no `providers` table today; provider identity lives in `provider_tokens` and the in-memory pool. Locked SPEC-002 defines `provider_tokens`, not a canonical `providers` table.
    **Why it matters:** This is unimplementable as written without inventing a new provider table or changing locked storage assumptions. Because §6.1 also defines the default for all existing providers, the missing storage target makes the privacy-default invariant ambiguous at cutover.
    **Suggested fix:** Replace `providers.public_earnings_mode` with a new SPEC-017-owned side table keyed by `provider_id`, or explicitly file and defer a locked-spec candidate that creates the provider table. Preserve the default-to-bucketed migration semantics.

## MAJOR findings

M1. Overview field count is internally inconsistent
    **Location:** SPEC-017 §5.1 lines 326-340; §5.1.1 lines 393-408; AC-1 lines 964-966
    **Finding:** The overview example and schema table define 14 `network.*` fields, including both `avg_tokens_per_request` and `models_serving`. AC-1 says all 13 `network.*` fields must be present.
    **Why it matters:** Clients will treat the field list as contract surface. A 13-vs-14 mismatch is exactly the kind of schema ambiguity that creates private console patches or partner parsing bugs.
    **Suggested fix:** Decide whether the schema has 13 or 14 fields, then make §5.1, §5.1.1, and AC-1 match exactly.

M2. Same-origin exact-dollar wording reintroduces portal-special ambiguity
    **Location:** SPEC-017 §2.3 lines 163-170; §6.4 lines 700-708
    **Finding:** §2.3 says same-origin authenticated portal views see exact `$` for the logged-in provider's own row regardless of mode. §6.4 later says the stats endpoint has no special behavior for `Origin: portal.streamvc.live` and the portal must use SPEC-014 surfaces for own-provider exact earnings.
    **Why it matters:** The audit constraints require same-origin behavior to be uniform on `/v1/stats/leaderboard`. The current text leaves room for one implementation to add a portal-only exact-dollar branch while another keeps the endpoint uniform.
    **Suggested fix:** Reword §2.3 to say the portal gets own-provider exact earnings from SPEC-014-owned surfaces, not from a special stats projection.

M3. Leaderboard stale-503 budgets conflict and cite a missing section
    **Location:** SPEC-017 §5.7 lines 613-617; §9.1 lines 886-889; §9.4 lines 921-927
    **Finding:** §5.7 says leaderboard 503 happens at `2×` the refresh cadence from `§4.4`, but there is no §4.4. Applying `2×` to §9.1 gives 24h=120s, 7d=10m, 30d=60m, all=12h. §9.4 instead pins 24h=300s, 7d=30m, 30d=4h, all=24h.
    **Why it matters:** Staleness is a partner-facing reliability contract. Two conforming implementations could return 503 hours apart for the same stale snapshot.
    **Suggested fix:** Make §5.7 point at §9.4 and use the exact table budgets, or make §9.4 derive mechanically from the cadence table.

M4. `stats_reader` grants do not match the rollup table inventory
    **Location:** SPEC-017 §7.2 lines 764-778; §9.1 lines 879-890; §9.2 lines 902-906
    **Finding:** The grant list includes `stats_health`, which is not listed in the §9.1 cadence table. §9.2 introduces `stats_late_events`, but §7.2 does not grant or explicitly deny access to it.
    **Why it matters:** The DB isolation contract must be mechanically checkable. A mismatch between the table inventory and role grants creates migration drift and makes AC-9 too narrow to prove the intended boundary.
    **Suggested fix:** Align §7.2 with the final table inventory after C1 is fixed, and state whether `stats_late_events` is readable by handlers or rollup-only.

M5. `304 Not Modified` is required only in AC-12 and conflicts with the error-envelope rule
    **Location:** SPEC-017 §5.1 lines 376-389; §5.8 lines 622-647; AC-12 lines 997-999
    **Finding:** AC-12 requires conditional GET support with `304 Not Modified`, but the endpoint response sections do not define 304 behavior. §5.8 says every non-2xx response must use the JSON error envelope, which is incompatible with a normal 304 no-body response.
    **Why it matters:** Cache behavior is part of the public HTTP contract. Implementers need to know whether 304 is a first-class success-like cache response or forbidden by the non-2xx envelope rule.
    **Suggested fix:** Add 304 to each cacheable endpoint's response contract and exempt 304 from the JSON error envelope, or remove AC-12.

M6. Full-backfill policy is both decided and still open
    **Location:** BUILD prompt open Q7 lines 146-147; SPEC-017 §9.6 lines 942-954; §11 Q7 lines 1043-1045
    **Finding:** The prompt says backfill on cutover is an open question. §9.6 nevertheless says `30d` and `all` MUST be populated from full historical OLTP before public endpoints are enabled, while §11 Q7 asks whether full backfill must be a hard gate or partial history is acceptable.
    **Why it matters:** This is deferral drift. It also changes operational launch shape: a hard full-history gate is much heavier than the operator's recent bias toward thin, reversible shipping.
    **Suggested fix:** Either move the full-backfill decision out of v0.1 and keep only the `partial_history_since` escape hatch, or remove Q7 and justify the hard gate explicitly.

M7. Additive-change policy permits enum changes that the body treats as closed
    **Location:** SPEC-017 §5.2 lines 468-475; §5.8 lines 636-647; §8.2 lines 843-848
    **Finding:** §8.2 says new buckets and new error codes may ship without a version bump. §5.2 defines bucket values as a closed set (`"$"`, `"$$"`, `"$$$"`, `"-"`), and §5.8 defines the error-code vocabulary as closed for v0.1.
    **Why it matters:** Adding a new enum value is not always additive for generated clients, validators, or partner dashboards. This would predictably force a v0.2 patch after clients build against the closed sets.
    **Suggested fix:** Treat new enum values as potentially breaking unless explicitly reserved, or add forward-compatible `unknown_*` handling rules to v0.1.

M8. `X-Stats-Generated-At` is not specified for every endpoint as required by the BUILD prompt
    **Location:** BUILD prompt §3 lines 47-52; SPEC-017 §5.1 lines 376-385; §5.2 lines 500-513; §5.3 lines 552-556
    **Finding:** The BUILD prompt requires response headers including `X-Stats-Generated-At` for each endpoint. SPEC-017 defines it only for `/overview`; `/leaderboard` and `/health` omit it even though both bodies carry generated-at data.
    **Why it matters:** Generated-at is the cache/debug hook partners will use when stale data appears. Omitting it on the scrape-attractive leaderboard weakens the public contract.
    **Suggested fix:** Add `X-Stats-Generated-At` to leaderboard and health, or explicitly state why those endpoints are exempt from the BUILD-prompt header list.

M9. Several numeric thresholds are pinned without rationale
    **Location:** SPEC-017 §6.2 lines 667-685; §7.5 lines 816-819; §9.2 lines 902-909; §9.3 lines 913-917
    **Finding:** The spec pins bucket boundaries, a 5% OLTP CPU replica trigger, a 48h late-event lookback, nightly rebuild timing, and a 0.5% all-time drift alert threshold without explaining why those numbers are appropriate for the current beta network.
    **Why it matters:** The severity rubric calls unjustified numeric thresholds MAJOR. These thresholds shape privacy disclosure, operator burden, and false-positive/false-negative alert behavior.
    **Suggested fix:** Add short rationale for each threshold or move the value to an open question/operator config where v0.1 cannot justify it.

M10. The dependency header contains a literal `TBD`
    **Location:** SPEC-017 line 5
    **Finding:** The `Depends on:` line cites `SPEC-016 v0.1.19` but then says "locked version TBD — re-pin at SPEC-017 v0.1 LOCK time." The required audit hygiene says v0.1 deferrals must not use literal `TBD`; dependency versions should match each dependency's line 3 at audit time.
    **Why it matters:** Line 3/5 headers are the version-of-record machinery in this repo. A `TBD` in the dependency line makes the lock target ambiguous even though SPEC-016 is currently v0.1.19 in this worktree.
    **Suggested fix:** Remove the `TBD` phrase and cite SPEC-016 v0.1.19 cleanly, or move any future re-pin concern into an operator question.

## MINOR findings

m1. Locked-decision advisor artifact citation is broken
    **Location:** SPEC-017 line 3; §12 lines 1079-1080
    **Finding:** The spec cites `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md`, but that file is not present anywhere in this worktree.
    **Why it matters:** The locked Q1-Q4 decision citation is not auditable by a fresh reviewer.
    **Suggested fix:** Add the artifact, correct the path, or cite a checked-in decision-log entry instead.

m2. Health status cross-reference points to a non-existent rollup section
    **Location:** SPEC-017 §5.3 lines 544-548
    **Finding:** `status` references "§4.1 of the rollup spec" even though this spec's rollup freshness table is §9.4 and there is no separate rollup spec cited.
    **Why it matters:** Minor auditability issue, but status semantics should point to the actual SLA table.
    **Suggested fix:** Replace the reference with §9.4.

m3. Import-graph AC does not cover the full forbidden set
    **Location:** SPEC-017 §7.6 lines 821-832; AC-16 lines 1009-1010
    **Finding:** §7.6 forbids imports from billing, explorer, ws, and most auth. AC-16 verifies only billing and explorer.
    **Why it matters:** The AC under-verifies a boundary the spec otherwise makes mechanically enforceable.
    **Suggested fix:** Extend AC-16 to include `internal/ws` and disallowed `internal/auth` imports.

m4. Sunset example has the wrong weekday
    **Location:** SPEC-017 §8.4 lines 858-866
    **Finding:** The example `Sunset: Tue, 25 Dec 2026 00:00:00 GMT` uses an RFC-style HTTP date, but December 25, 2026 is a Friday, not Tuesday.
    **Why it matters:** Cosmetic, but examples for protocol headers should be syntactically correct.
    **Suggested fix:** Use a real RFC 8594/RFC 7231 HTTP date with matching weekday, or use a placeholder date without a weekday claim.

m5. SPEC-014 auth cross-reference is a placeholder
    **Location:** SPEC-017 §6.3 lines 692-696
    **Finding:** The portal endpoint "MUST require provider authentication (SPEC-014 §authn)", but SPEC-014 uses numbered auth sections, not a `§authn` anchor.
    **Why it matters:** Minor reference hygiene issue that slows cross-spec verification.
    **Suggested fix:** Cite SPEC-014 §2.1/§2.2 or the exact future SPEC-014 v0.9 candidate section when it exists.

## Operator questions surfaced

q1. Does partner-key exact-dollar exposure need separate consent language?
    **Location:** SPEC-017 §5.2 lines 494-498; §6.6 lines 730-737
    **Question:** The partner-key projection intentionally surfaces exact `$` for all providers, including bucketed providers. §6.6 consent copy describes exact earnings becoming visible to "anyone, including partners' websites" when the provider opts in, but it does not tell bucketed providers that operator-issued partner keys still expose exact figures. Is that legal posture intentional and sufficient?

q2. Is `frontdoor/console/index.html` the intended Network Statistics consumer?
    **Location:** `frontdoor/console/index.html` lines 1178-1315; SPEC-017 §5.1 lines 320-408
    **Question:** The current console dashboard source renders local browser usage (`Requests`, `Tokens used`, `Avg latency`, `This week`) and pool status/model tags, not the network overview widget described in the BUILD prompt. Should SPEC-017 cover this actual file, or is there another Network Statistics widget/source not present in the required path?

## Verdict
- READY WITH FIX PASS

The locked architecture does not need a design reset, but v0.1 cannot lock until the missing storage/key contracts and the provider-visibility storage boundary are fixed. The remaining MAJOR issues look narrow enough for a focused v0.1.1 pass.

## Self-verification
- [x] Read every section of SPEC-017 v0.1 (§§1-12, ACs 1-16).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented.
- [x] Walked each Category A through J. Categories without direct findings are marked in the category sweep.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location on every finding.
- [x] Suggested fix for CRITICAL findings.
- [x] Verdict included.
