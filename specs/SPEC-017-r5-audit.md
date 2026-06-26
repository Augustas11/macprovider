# SPEC-017 v0.1.4 audit report — Round 5 (Codex, 2026-06-25T19:35:50Z)

## Summary

- 0 CRITICAL findings
- 2 MAJOR findings
- 2 MINOR findings
- 0 QUESTIONS

Round 5 focused on v0.1.4's closure of Round 4 blockers. Round 4 M1 is closed: the request-path grant set now consistently includes `stats_*`, `partner_keys`, and `provider_visibility` while excluding billing/session/pool OLTP. Round 4 M2 is closed as to OLTP source-table drift: §7.2.2 no longer normatively names nonexistent locked dependency tables, and AC-9 tests real SPEC-005 v0.3 ledger tables. Round 4 M3 is closed: §5.3 and §9.6 now share the target-staleness/degraded and 503-budget/down model. Round 4 M4 is closed: §6.2 and §8.2/§8.3 now split additive new bucket values from breaking threshold changes.

The remaining blockers are narrow wire/grant consistency issues introduced or exposed by the v0.1.4 text. No new architectural design round is needed.

## Category sweep

- **Category A — BUILD-prompt directive fidelity:** MAJOR finding M2. The BUILD prompt requires a mechanically usable role/migration contract; the rollup role's current grants do not satisfy the rollup behavior pinned in §9.3/§9.4.
- **Category B — Endpoint contract correctness:** MAJOR finding M1. All other endpoint schema, window/sort/limit, exact-nullability, CORS, HEAD/OPTIONS, stale-503, and partner projection checks are coherent.
- **Category C — Earnings visibility model:** no findings. Bucketed default, opt-in exact, same-Origin uniformity, audit table, legal copy, and operator override direction are coherent. Round 4 bucket-additivity issue is closed.
- **Category D — Hosting and isolation:** MAJOR finding M2; MINOR finding m1. Round 4 source-grant drift is closed, but the `stats_rollup` owned-table grant set is still insufficient for the specified incremental/reconcile behavior.
- **Category E — Versioning and deprecation:** no findings. The RFC 9745 `Deprecation` and RFC 8594 `Sunset` examples are internally consistent; 2026-06-22 was a Monday and 2026-12-25 is a Friday.
- **Category F — Rollup pipeline:** MAJOR finding M2. Cadence, late-event, all-time, freshness, failure-mode, and partial-history text otherwise has a defined home.
- **Category G — Acceptance criteria quality:** no blocking findings. AC-1 through AC-20 are contiguous; v0.1.4 has more than the prompt's stale "AC-1 through AC-16" reference because later rounds added deterministic checks for partner keys, revoked-key timing, provider-visibility default, and operator-exact override.
- **Category H — Cross-spec invariant preservation:** no CRITICAL findings. SPEC-002 mount paths do not collide; SPEC-005 work-$ settlement is not redefined; SPEC-006 envelope compatibility is explicitly disclaimed; SPEC-014 v0.9 is not a lock gate; SPEC-016 v0.1.19 remains the pinned payout-pipeline context while rewards semantics are deferred to §9.1a/Q13.
- **Category I — Honesty about deferrals:** no findings. The explicit v0.2+ deferrals remain outside v0.1, and §11 questions do not hide a newly pinned v0.1 decision.
- **Category J — Spec hygiene:** MINOR finding m2. Dependency versions match current line-3 versions; no literal `TBD` appears; the in-repo advisor mirror exists.

## CRITICAL findings

None.

## MAJOR findings

M1. 405 responses have no legal v0.1 error code

    **Location:** §4.3 lines 402-404; §5.9 lines 928-950

    **Finding:** §4.3 requires every non-GET/HEAD/OPTIONS request to return `405 Method Not Allowed` with `Allow: GET, HEAD, OPTIONS`. §5.9 then says every non-2xx response except 304 MUST use the exact error envelope and defines a closed v0.1 code vocabulary: `bad_request`, `unauthorized`, `rate_limited`, `stats_stale`, and `internal`. No code maps to 405.

    **Why it matters:** Two conforming implementations cannot satisfy both clauses mechanically. One may invent `method_not_allowed` and violate the closed vocabulary; another may return 405 with `bad_request` or `internal`, giving partner clients misleading semantics. This is a wire-contract ambiguity likely to require a first implementation patch.

    **Suggested fix:** Add `method_not_allowed` with HTTP 405 to the §5.9 closed code table and add a matching AC, or explicitly define 405 as `bad_request` if the operator wants no new code. The former is cleaner.

M2. `stats_rollup` cannot read the stats tables it must incrementally merge and reconcile

    **Location:** §7.2.2 lines 1221-1257; §7.2.5 lines 1301-1307; §9.3 lines 1618-1629; §9.4 lines 1642-1646

    **Finding:** §7.2.2 normatively grants `stats_rollup` `INSERT, UPDATE, DELETE` on the owned `stats_*`, `stats_components_health`, and `stats_late_events` tables, but no `SELECT` on those same tables. §7.2.5 says the rollup job uses the `stats_rollup` connection pool. §9.3 requires incremental merge for `30d`/`all`, and §9.4 requires comparing the rebuilt value with the incremental snapshot to detect >0.5% drift. Those behaviors need read access to existing stats rows or an explicit alternative read path, neither of which is granted.

    **Why it matters:** The current migration is syntactically valid, but not mechanically sufficient for the rollup algorithm the spec pins. An implementer following the grant set literally will fail at runtime or quietly widen grants outside the spec. This is a MAJOR isolation-contract gap, not CRITICAL, because it does not permit request-path OLTP access or leak earnings by itself.

    **Suggested fix:** Grant `SELECT` on the rollup-owned stats tables to `stats_rollup`, while keeping `partner_keys` and `provider_visibility_audit` denied. If the operator wants a write-only rollup role, §9.3/§9.4 must define how merge/reconcile reads happen without violating §7.2.5's role separation.

## MINOR findings

m1. Request-path OLTP deny note points at the wrong isolation subsection

    **Location:** §7.2.1 lines 1210-1217; §7.2.5 lines 1299-1307

    **Finding:** §7.2.1 says OLTP-table denial is enforced by connection isolation in §7.2.4, but §7.2.4 is the optional `partner_keys_writer` role. Connection-pool isolation is §7.2.5.

    **Why it matters:** The grant rule itself is clear; this is navigation drift after the Round 4 role-count fix.

    **Suggested fix:** Change the cross-reference to §7.2.5.

m2. References section repeats the advisor-artifact description

    **Location:** §12 lines 1902-1906

    **Finding:** The advisor artifact entry names the same "codex advisor round establishing the four locked decisions" twice, once across lines 1902-1905 and again on line 1906.

    **Why it matters:** The in-repo advisor mirror exists and the citation is usable, so this is only spec hygiene.

    **Suggested fix:** Delete the duplicate trailing parenthetical on line 1906.

## Operator questions surfaced

None beyond the existing §11 open questions.

## Round 4 closure notes

- R4 M1 closed: §1.5 C3, §4.2, §5.4.3, and §7.2.1 now consistently identify the request-path-readable grant set instead of saying "`stats_*` only."
- R4 M2 closed as to locked-dependency table drift: §7.2.2 leaves OLTP source reads to IMPL-time enumeration, and AC-9 now uses real SPEC-005 v0.3 tables (`ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`).
- R4 M3 closed: §5.3 and §9.6 now agree that degraded means beyond §9.5 target staleness and down means beyond the §5.8 503 budget.
- R4 M4 closed: §6.2, §8.2, and §8.3 now distinguish additive new bucket values from breaking threshold re-anchoring.
- R4 m1 mostly closed: role count and §5.4.3 cross-reference are fixed; m1 above is a separate remaining cross-reference in §7.2.1.
- R4 m2 closed: RFC 9745 appears in §12.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.4 (§§1-12, ACs 1-20).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented.
- [x] Walked each Category A through J. Categories with no findings are noted explicitly.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location included for every finding.
- [x] Suggested fix included for each MAJOR finding.
- [x] Verdict included below.

## Verdict

- READY WITH FIX PASS

SPEC-017 v0.1.4 does not need another design round, but it should not lock with two MAJOR consistency gaps open. Both appear closable in a narrow text/migration pass: add a 405 error-code mapping, and grant or otherwise define rollup read access for the stats tables used by incremental merge and reconciliation.
