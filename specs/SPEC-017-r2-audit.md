# SPEC-017 v0.1.1 audit report — Round 2 (Codex, 2026-06-25T19:03:09Z)

## Summary
- 2 CRITICAL findings
- 5 MAJOR findings
- 2 MINOR findings
- 0 QUESTIONS

Round 2 focused on whether v0.1.1 closed the round-1 findings without introducing new drift. The round-1 CRITICALs are structurally addressed: table schemas now exist, partner-key lifecycle is specified, and `provider_visibility` is a SPEC-017-owned side table. The remaining blockers are mostly introduced or exposed by that fix pass: the partner-key token format is internally inconsistent, `rewards` dollars cite a SPEC-016 semantic that does not exist, CORS has contradictory public-vs-401 behavior, and the DB grant inventory contradicts the table inventory.

## Category sweep

| Category | Result |
|---|---|
| A BUILD-prompt directive fidelity | Findings C1, C2, M1, M3 |
| B Endpoint contract correctness | Findings C1, M1, M5 |
| C Earnings visibility model | Finding M2; no new exact-dollar privacy leak found |
| D Hosting and isolation | Finding M3 |
| E Versioning and deprecation | Finding m2 |
| F Rollup pipeline | Findings C2, M3, M5 |
| G Acceptance criteria quality | No gap in AC-1 through AC-16 contiguity; added AC-17 through AC-20 are deterministic, but depend on fixes below |
| H Cross-spec invariant preservation | Findings C2, M4 |
| I Honesty about deferrals | No new deferral-hiding finding |
| J Spec hygiene | Findings m1, m2 |

## CRITICAL findings

C1. Partner-key token format is internally inconsistent
    **Location:** §3.7 lines 263-270; §5.4.2 lines 655-661; AC-17 lines 1454-1458
    **Finding:** §3.7 defines a partner key as "`mpk_` prefix + 32 url-safe base64 chars" but then says the total is 33 chars. That arithmetic is wrong: a 4-character prefix plus 32 characters is 36. §5.4.2 then says issuance generates 32 random bytes and url-safe-base64-encodes them, which produces a much longer token than 32 encoded characters. AC-17 only verifies the hash operation and does not settle which token string is valid.
    **Why it matters:** Partner keys are the only authenticated partner surface. Two conforming implementations could issue and validate different token lengths, breaking partner onboarding, CORS allowlisting, rate-limit keying, and revocation tests. This is partner-client/auth breakage, not cosmetic prose.
    **Suggested fix:** Pick one contract and make §3.7, §5.4.2, and AC-17 match. For example: raw token is `mpk_` plus unpadded base64url of 32 random bytes, total length 47 characters; or raw token is `mpk_` plus 32 base64url characters generated from 24 random bytes, total length 36 characters.

C2. `rewards` dollar semantics cite SPEC-016, but SPEC-016 v0.1.19 does not define a rewards split
    **Location:** header line 5; §5.2 lines 468-487 and 513-527; §9.1 lines 1216-1221; §12 lines 1555-1558; SPEC-016 §5.1 lines 2865-2871
    **Finding:** SPEC-017 says SPEC-016 v0.1.19 defines `rewards` dollar semantics, and the leaderboard exposes `earnings_rewards_usd` / `earnings_rewards_bucket`. But SPEC-016 §5.1 is only "Gas on the operator": it says Base gas is not deducted from `provider_credits` and that providers receive exactly `provider_credits` USDC base units. It does not define network incentive rewards, a work-vs-rewards split, or a source table/column for `earnings_rewards_usd`.
    **Why it matters:** The leaderboard's money split is a public contract. Without a normative rewards source, one implementation could set rewards to zero, another could map all payout-ready provider credits to rewards, and another could infer a network-incentive ledger that no locked spec defines. They would all serve syntactically valid but economically incompatible JSON.
    **Suggested fix:** Either cite the actual locked source for network-incentive rewards, or define `earnings_rewards_usd` as absent/deferred in v0.1. If rewards are not yet normatively sourced, remove the rewards fields from v0.1 or mark them future-reserved without emitting values.

## MAJOR findings

M1. CORS behavior for non-allowlisted partner-key origins is contradictory
    **Location:** §5.4.1 lines 636-639; §5.4.3 lines 677-679; §5.7 lines 754-760
    **Finding:** §5.4.1 says an empty `allowed_origins` array means no Origin restriction. §5.4.3 says if `allowed_origins` is non-empty and the Origin is not listed, the handler returns 401. §5.7 then says all other origins receive `Access-Control-Allow-Origin: *` plus the public projection, while also saying an auth header from a non-allowlisted Origin is rejected with 401. A request with a valid key from a disallowed browser origin cannot both receive a 200 public projection and a 401 error.
    **Why it matters:** This is the partner browser embedding path. Implementers will diverge on whether a valid key falls back to public data, hard-fails, or works when `allowed_origins` is empty. The result is predictable partner confusion and first-month patch pressure.
    **Suggested fix:** Define one branch table: absent key, invalid key, valid key with no Origin, valid key with allowlisted Origin, valid key with non-allowlisted Origin, and valid key with empty `allowed_origins`.

M2. Scope text still implies portal-only authenticated stats fields
    **Location:** §1.1 lines 39-42; §1.5 C1 lines 112-114; §6.4 lines 906-920
    **Finding:** §1.1 says the portal is a consumer whose "same-origin authenticated views see additional fields." Later sections correctly say no field may exist for one consumer's UI convenience and `/v1/stats/leaderboard` must not inspect `Origin` or create a portal projection. The old same-origin-special wording survived the round-1 M2 fix.
    **Why it matters:** The audit constraints require one contract for console, portal, and partners, with partner-key projection as the single exception. Leaving "portal authenticated views see additional fields" in the mission reopens the exact ambiguity §6.4 tries to close.
    **Suggested fix:** Reword §1.1 to say the portal consumes this contract for public network stats, while own-provider exact earnings come from SPEC-014-owned surfaces.

M3. `stats_reader` grant list contradicts the table inventory exact-match rule
    **Location:** §7.2 lines 1015-1035; §9.1 lines 1173-1177 and 1246-1254
    **Finding:** §9.1 says every `stats_*` and `stats_components_health` table is defined there and the handler grant list in §7.2 MUST match this inventory exactly. But §7.2 grants `provider_visibility`, which is not part of the §9.1 inventory, and excludes `stats_late_events`, which is a `stats_*` table defined in §9.1. §7.2 then explains those exceptions, contradicting the "exactly" rule.
    **Why it matters:** DB-role isolation is one of the core safety invariants. The intended boundary may be correct, but the current wording is not mechanically checkable: auditors cannot tell whether "all stats_*" or "only request-path read tables" is the controlling grant policy.
    **Suggested fix:** Split the inventories explicitly: request-path readable tables granted to `stats_reader`, rollup-internal tables denied to handlers, and SPEC-017 side tables needed for projection. Remove "exactly" unless the lists really match.

M4. Error envelope is not structurally compatible with SPEC-006's public error shape
    **Location:** §5.9 lines 785-813; SPEC-006 §5.2 lines 886-900; header line 5
    **Finding:** SPEC-017 claims SPEC-006 as the public-surface error-envelope dependency, but §5.9 defines `{"error":{"code","message","retry_after_seconds?"}}`. SPEC-006's envelope includes `error.message`, `error.type`, and `error.code`, with `type` drawn from a closed vocabulary. Omitting `type` is a semantic shape difference, not just field ordering.
    **Why it matters:** Partners likely reuse the buyer API's public-surface parser and error taxonomy. A different envelope under another `/v1/*` public surface creates avoidable client branching and weakens the dependency claim.
    **Suggested fix:** Either add SPEC-006-compatible `error.type` values to SPEC-017 errors, or explicitly state SPEC-017 intentionally uses a narrower error envelope and stop citing SPEC-006 for envelope compatibility.

M5. Leaderboard `stale_after` semantics do not match the cache headers
    **Location:** §5.2 lines 461-465 and 529-545; §5.8 lines 767-780; §9.5 lines 1344-1353
    **Finding:** The leaderboard example for `window: "7d"` has `generated_at = 18:14` and `stale_after = 18:18`, but the public leaderboard headers say `Cache-Control: max-age=60, s-maxage=60`. Unlike §5.1, §5.2 never defines whether `stale_after` means cache expiry, target staleness, or 503 budget. For 7d, the example is neither +60s cache TTL nor the +5min target staleness nor the +30min 503 budget.
    **Why it matters:** `stale_after` is a partner-facing freshness hint. If it is not mechanically tied to either cache TTL or freshness SLA, clients will display stale/fresh states differently and operators will get support noise when edge cache and body metadata disagree.
    **Suggested fix:** Add a leaderboard field rule for `stale_after` and update the example. Pick one source, preferably `generated_at + Cache-Control s-maxage` if it is meant to mirror §5.1.

## MINOR findings

m1. Required advisor artifact path is still absent from this worktree
    **Location:** §12 lines 1558-1559; filesystem path `.omc/artifacts/ask/codex-i-m-designing-a-public-network-stats-api-for-macprovider-a-d-2026-06-25T18-18-42-442Z.md`
    **Finding:** The checked-in mirror `specs/SPEC-017-advisor-round-2026-06-25.md` exists and contains the four locked picks, but the `.omc/artifacts/ask/...` source path named by the audit prompt is absent in this worktree. The spec now references the mirror, so this is no longer the round-1 broken-citation blocker, but the source-artifact path remains non-reproducible for a fresh reviewer following the prompt literally.
    **Why it matters:** Minor auditability gap only; the mirror preserves the needed content.
    **Suggested fix:** Either commit the `.omc` artifact, or make the audit prompt and SPEC cite only the checked-in mirror.

m2. Deprecation/Sunset header citation is imprecise after RFC 9745
    **Location:** §8.4 lines 1151-1160
    **Finding:** §8.4 attributes both `Deprecation` and `Sunset` header patterning to RFC 8594. RFC 8594 defines `Sunset`; the `Deprecation` header and `rel="deprecation"` link relation are now specified by RFC 9745, whose syntax is a structured-field date such as `Deprecation: @1688169599`, not `Deprecation: true`.
    **Why it matters:** This is protocol hygiene, not a v0.1 blocker. Header examples tend to get copied directly into implementation and docs, so stale citation/syntax should be cleaned before public documentation.
    **Suggested fix:** Cite RFC 8594 for `Sunset`, cite RFC 9745 for `Deprecation` and `rel="deprecation"`, and use an RFC 9745 structured-field date if the deprecation effective date is known.

## Operator questions surfaced

None beyond existing §11 Q1-Q12.

## Verdict
- READY WITH FIX PASS

v0.1.1 closed the round-1 architectural blockers, but it is not ready to lock while partner-key format, rewards-source semantics, CORS behavior, and grant inventory remain contradictory. These look closable in a narrow v0.1.2 pass; no new design round is required unless the operator decides the `rewards` split has no locked source yet.

## Self-verification
- [x] Read every section of SPEC-017 v0.1.1 (§§1-12, ACs 1-20).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented.
- [x] Walked each Category A through J. Categories without direct findings are marked in the category sweep.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location (section number and line range where applicable) on every finding.
- [x] Suggested fix for CRITICAL findings.
- [x] Verdict included.
