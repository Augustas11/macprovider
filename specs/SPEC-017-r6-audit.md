# SPEC-017 v0.1.5 audit report — Round 6 (Codex, 2026-06-25T19:42:31Z)

## Summary

- 0 CRITICAL findings
- 1 MAJOR finding
- 1 MINOR finding
- 0 QUESTIONS

Round 6 focused on v0.1.5's closure of Round 5 blockers. Round 5 M1 is closed: `method_not_allowed` is now in the §5.9 closed code vocabulary and AC-21 verifies the 405 envelope. Round 5 M2 is closed as stated: `stats_rollup` now has `SELECT, INSERT, UPDATE, DELETE` on the rollup-owned stats tables, so §9.3 incremental merge and §9.4 drift detection can read existing snapshots.

The remaining blocker is a separate PostgreSQL grant gap: roles that insert into `BIGSERIAL` tables are not granted sequence usage. This is narrow and fixable in one pass; no design round is needed.

## Category sweep

- **Category A — BUILD-prompt directive fidelity:** MAJOR finding M1. The role/migration contract is not mechanically sufficient for the audit-row and late-event writes the spec pins.
- **Category B — Endpoint contract correctness:** no findings. Overview, leaderboard, health, error envelope, CORS, stale-503, partner projection, exact-nullability, and 405 handling are coherent.
- **Category C — Earnings visibility model:** no findings. Bucketed default, opt-in exact, same-Origin uniformity, audit table, legal copy, and operator override direction remain coherent.
- **Category D — Hosting and isolation:** MAJOR finding M1. The DB grant split preserves request-path isolation but omits required sequence privileges for insert-capable roles.
- **Category E — Versioning and deprecation:** no findings. `/v1` path versioning, additive/breaking rules, RFC 9745 `Deprecation`, RFC 8594 `Sunset`, and changelog location are internally consistent.
- **Category F — Rollup pipeline:** no findings beyond M1's grant impact on `stats_late_events`. Cadence, late-event correction, all-time reconciliation, freshness, failure modes, and cutover backfill are defined.
- **Category G — Acceptance criteria quality:** MINOR finding m1. AC numbering is contiguous AC-1 through AC-21 and the named surfaces are covered.
- **Category H — Cross-spec invariant preservation:** no CRITICAL findings. `/v1/stats/*` does not collide with SPEC-002 paths; SPEC-005 work-$ math is not redefined; SPEC-006 envelope compatibility is explicitly disclaimed; SPEC-014 v0.9 is not a lock gate; SPEC-016 v0.1.19 remains pinned while rewards semantics are deferred to §9.1a/Q13.
- **Category I — Honesty about deferrals:** no findings. v0.2+ deferrals and §11 questions are explicit and do not hide a newly pinned v0.1 decision.
- **Category J — Spec hygiene:** no findings. Dependency versions match current line-3 versions; no literal `TBD` appears; the in-repo advisor mirror exists. The original `.omc/artifacts/ask/...` path requested for reading is absent from this worktree, but the spec cites the in-repo mirror at `specs/SPEC-017-advisor-round-2026-06-25.md`, which exists.

## CRITICAL findings

None.

## MAJOR findings

M1. Insert-capable roles lack PostgreSQL sequence privileges for `BIGSERIAL` tables

    **Location:** §6.5 lines 1094-1107; §7.2.2 lines 1244-1266; §7.2.3 lines 1282-1288; §9.1 lines 1534-1542

    **Finding:** §9.1 defines `stats_late_events.id BIGSERIAL`, and §7.2.2 grants `stats_rollup` `INSERT` on `stats_late_events`. §6.5 defines `provider_visibility_audit.id BIGSERIAL`, and §7.2.3 grants `provider_portal` `INSERT` on `provider_visibility_audit`. In PostgreSQL, `BIGSERIAL` creates a backing sequence, and `INSERT` using the default `nextval(...)` requires `USAGE` (or equivalent) on that sequence. v0.1.5 grants table privileges only; it does not grant `USAGE` on `stats_late_events_id_seq` or `provider_visibility_audit_id_seq`.

    **Why it matters:** An implementation following the normative grants literally will fail at runtime when the rollup records an old late event or when the SPEC-014 v0.9 portal toggle writes its required audit row. This is a MAJOR migration-contract gap: it does not leak earnings or widen request-path OLTP access, but it makes two pinned behaviors mechanically non-executable and would force an implementation patch immediately.

    **Suggested fix:** Add explicit sequence grants beside the existing table grants, e.g. `GRANT USAGE, SELECT ON SEQUENCE stats_late_events_id_seq TO stats_rollup;` and `GRANT USAGE, SELECT ON SEQUENCE provider_visibility_audit_id_seq TO provider_portal;`. If the implementation uses identity columns or explicit IDs instead, pin that alternative so the table DDL and grants remain executable as written.

## MINOR findings

m1. AC-13 permits a preflight status that §5.7 no longer permits

    **Location:** §5.7 lines 895-898; §10 AC-13 lines 1776-1778

    **Finding:** §5.7 normatively says `OPTIONS /v1/stats/*` returns `204` with an empty body. AC-13 says `OPTIONS /v1/stats/leaderboard` returns `204 (or 200)`, which weakens the implementation check relative to the contract.

    **Why it matters:** The wire contract itself is clear, so this is not a partner-facing ambiguity. The acceptance test is looser than the spec and could let an implementation report AC-13 green while violating the exact preflight status.

    **Suggested fix:** Change AC-13 to require `204` only, or change §5.7 if the operator intentionally wants to allow `200`.

## Operator questions surfaced

None beyond the existing §11 open questions.

## Round 5 closure notes

- R5 M1 closed: §5.9 lines 951-960 includes `method_not_allowed` for HTTP 405, and AC-21 lines 1809-1812 verifies the envelope and `Allow` header.
- R5 M2 closed: §7.2.2 lines 1248-1258 grants `stats_rollup` `SELECT, INSERT, UPDATE, DELETE` on the rollup-owned stats tables, matching §9.3 and §9.4 read needs.
- R5 m1 closed: §7.2.1 line 1227 now points at §7.2.5 for connection isolation.
- R5 m2 closed: §12 lines 1920-1923 cites the advisor mirror once without the duplicate parenthetical.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.5 (§§1-12, ACs 1-21).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented.
- [x] Walked each Category A through J. Categories with no findings are noted explicitly.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location included for every finding.
- [x] Suggested fix included for the MAJOR finding.
- [x] Verdict included below.

## Verdict

- READY WITH FIX PASS

SPEC-017 v0.1.5 does not need another design round, but it should not lock while the pinned PostgreSQL grants cannot execute the audit-row and late-event writes. The fix is narrow: add the missing sequence privileges (or pin an equivalent no-sequence DDL strategy), then re-run a focused confirmation round.
