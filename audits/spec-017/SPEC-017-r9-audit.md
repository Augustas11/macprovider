# SPEC-017 v0.1.8 audit report — Round 9 (Codex, 2026-06-26T05:14:45Z)

## Summary
- 0 CRITICAL findings
- 2 MAJOR findings
- 0 MINOR findings
- 0 QUESTIONS

## CRITICAL findings

None.

## MAJOR findings

M1. Stale partner-key burst contract contradicts the v0.1.8 hard-limit model
    **Location:** §5.4.1, lines 917-918; §5.4.1, lines 951-953; §5.4.2, line 968; §5.6, lines 1105-1117
    **Finding:** The v0.1.8 rate-limit reconciliation says the prior burst semantics are dropped and that both public and partner tiers are hard per-minute limits with no burst absorption. However, the partner-key table still normatively includes `rate_limit_burst INT DEFAULT 1200`, the field rules still say `rate_limit_burst` is a per-key per-endpoint limit that the API must clamp to, and the issuance command still accepts `--burst 1200`.
    **Why it matters:** Two conforming implementations could resolve the partner-key limit differently: one would 429 the 601st keyed request in a minute, while another would honor the retained burst field and allow additional traffic. That is a rate-limit policy ambiguity and likely first-month patch.
    **Suggested fix:** Remove `rate_limit_burst` from the v0.1 partner-key schema, field rules, and issuance command, or explicitly restore partner burst semantics in §5.6 with deterministic 429 behavior and an acceptance criterion.

M2. Authorization-bearing nginx bypass leaves invalid bearer traffic without a specified limiter
    **Location:** §5.4.3, lines 990-998; §5.4.3, lines 1016-1025; §5.6, lines 1123-1146; AC-18, lines 2282-2293
    **Finding:** §5.6 requires the public nginx limiter to ignore every request carrying an `Authorization` header so valid partner-key traffic is not throttled at the edge. But §5.4.3 requires invalid, unknown, revoked, and disallowed-origin bearer requests to perform the same key hash lookup and then return 401. The spec does not assign those failed bearer requests to the public per-IP limiter, a partner per-key limiter, or a separate auth-failure limiter.
    **Why it matters:** A stream of syntactically bearer-shaped but invalid requests can bypass the edge public limiter and force application/database auth work. That makes the rate-limit policy enforceable for anonymous traffic and successful partner traffic, but under-specified for failed bearer traffic.
    **Suggested fix:** Specify a deterministic limiter for Authorization-present requests that do not produce a valid partner projection, such as an in-process IP+endpoint auth-failure bucket that preserves the timing-equivalence rule, and add an AC proving repeated invalid bearer requests are bounded without leaking key existence.

## MINOR findings

None.

## Operator questions surfaced

None beyond the open questions already listed in SPEC-017 §11.

## Category sweep

- **Category A — BUILD-prompt directive fidelity:** No missing, semantically drifted, or weakened MUST-pin clauses found. The r9 findings are internal v0.1.8 rate-limit contradictions, not missing BUILD-prompt coverage.
- **Category B — Endpoint contract correctness:** Overview, leaderboard, health, error envelope, projection shape, `exact_earnings*` null-vs-float semantics, and HEAD/OPTIONS are deterministic. M1 and M2 cover the remaining rate-limit/auth edge ambiguity.
- **Category C — Earnings visibility model:** No findings. Bucketed default, combined-bucket disclosure, opt-in exact flow, same-origin uniformity, audit-row requirement, legal posture, and operator exact-to-bucketed override direction are internally consistent.
- **Category D — Hosting and isolation:** No mount-path, DB role, connection-pool, process-recover, or import-graph findings. M2 covers the nginx Authorization-aware keying gap.
- **Category E — Versioning and deprecation:** No findings. URL path versioning is sole version surface; RFC 9745 `Deprecation`, RFC 8594 `Sunset`, and `Link: rel="sunset"` usage are coherent for v0.1.
- **Category F — Rollup pipeline:** No findings. Shape C makes all-time rebuild executable under the locked §7.2.2 grants, with Shapes A/B correctly treated as non-default options requiring future grant widening or a v0.2 spec change.
- **Category G — Acceptance criteria quality:** AC-1 through AC-21 are contiguous and cover the named surfaces. M1 and M2 imply a targeted AC update is needed for the final rate-limit semantics.
- **Category H — Cross-spec invariant preservation:** No findings. `/v1/stats/*` does not collide with SPEC-002 v1.4 paths, SPEC-017 does not redefine SPEC-005 work settlement math or SPEC-016 reward semantics, SPEC-006 header handling is not extended, and the SPEC-014 v0.9 UI handoff is clean.
- **Category I — Honesty about deferrals:** No findings. §11 open questions remain genuine, and v0.2+ deferrals are stated as out of scope rather than quietly decided.
- **Category J — Spec hygiene:** No findings. Version-of-record, change-log convention, dependency versions, RFC-2119 usage, no-TBD check, and locked-decision citation are acceptable; the advisor source artifact is mirrored in-repo as §12 states.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.8 (§§1-12, ACs 1-21).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented where found.
- [x] Walked each Category A through J. Categories with no findings are noted explicitly.
- [x] Severity for each finding chosen against the requested definitions.
- [x] Location included on every finding.
- [x] Suggested fix included for each finding. No CRITICAL findings were found.
- [x] Verdict included below.

## Verdict

- READY WITH FIX PASS

The remaining issues are narrow rate-limit contract contradictions introduced around the v0.1.8 hard-limit/keying cleanup. They should be closable in a focused spec pass without reopening the locked architecture decisions.
