# SPEC-017 v0.1.3 audit report — Round 4 (Codex, 2026-06-25T19:25:32Z)

## Summary

- 0 CRITICAL findings
- 4 MAJOR findings
- 2 MINOR findings
- 0 QUESTIONS

Round 4 focused on SPEC-017 v0.1.3 deltas after Round 3, especially the
new `partner_keys_writer` role, the §5.7 CORS preflight rule, and the §9.1
partition-inventory rewrite. The Round 3 CORS, SPEC-016 rewards, self-serve
partner-key, Deprecation-header, open-question ordering, and advisor-artifact
issues are closed or cleanly accepted. The remaining blockers are narrow
contract-consistency issues rather than a new design round.

## Category sweep

- **Category A — BUILD-prompt directive fidelity:** MAJOR findings M1, M2, and M4.
- **Category B — Endpoint contract correctness:** no new findings; §5.7 now cleanly separates preflight from credentialed GET enforcement.
- **Category C — Earnings visibility model:** MAJOR finding M4.
- **Category D — Hosting and isolation:** MAJOR findings M1 and M2; MINOR finding m1.
- **Category E — Versioning and deprecation:** MAJOR finding M4; MINOR finding m2.
- **Category F — Rollup pipeline:** MAJOR findings M2 and M3.
- **Category G — Acceptance criteria quality:** MAJOR finding M2 affects AC-9.
- **Category H — Cross-spec invariant preservation:** MAJOR finding M2.
- **Category I — Honesty about deferrals:** no findings.
- **Category J — Spec hygiene:** MINOR findings m1 and m2.

## CRITICAL findings

None.

## MAJOR findings

M1. Request-path isolation still says stats handlers may hit `stats_*` tables only

    **Location:** §1.5 C3, lines 153-154; §5.4.3, lines 756-763; §7.2.1, lines 1143-1154

    **Finding:** Round 3's DB-role wording sweep is not fully closed. §1.5 C3 still states that a stats handler "MUST hit `stats_*` tables only." That conflicts with the partner-key contract in §5.4.3, which requires request-path reads from `partner_keys` and optional `last_used_at` writes, and with §7.2.1, which grants the request-path reader SELECT on `provider_visibility` and `partner_keys`.

    **Why it matters:** Two conforming implementations could resolve the isolation rule differently: one could reject partner-key auth side-table access as a contract violation, while another could follow §7.2.1 and serve the partner projection. This is not a privacy leak or OLTP billing/session query permission, so it is not CRITICAL, but it is a MAJOR ambiguity in the isolation contract.

    **Suggested fix:** Rewrite C3 to say request handlers MUST use only the §7.2.1 request-path-readable grant set, including SPEC-017-owned side tables, and MUST NOT query billing/session/pool OLTP source tables.

M2. Rollup source grants name tables that are not locked by SPEC-002/SPEC-005

    **Location:** §7.2.2, lines 1182-1195; AC-9, lines 1686-1688; SPEC-005 §4.3-§4.8, lines 247-456; SPEC-002 §7.3, lines 2294-2308

    **Finding:** §7.2.2 now concretely grants rollup SELECT on `provider_tokens`, `sessions`, `session_events`, `billing_ledger`, and `request_log`, and says the exact source names are pinned by locked dependencies. `provider_tokens` and `request_log` have locked homes, but `billing_ledger`, `sessions`, and `session_events` are not locked source tables in SPEC-002 v1.4 or SPEC-005 v0.3. SPEC-005's locked ledger tables are `ledger_request_credits`, `ledger_operator_credits`, `ledger_payout_ready`, `ledger_reconciliation_runs`, `ledger_config_snapshots`, and `ledger_provider_identity_snapshots`. AC-9 then tests denial on `billing_ledger`, so a relation-not-found result could be confused with a permission-isolation pass while the real locked ledger tables remain untested.

    **Why it matters:** The migration and acceptance test cannot be applied mechanically against the locked dependency specs. Implementers could create new compatibility tables, skip required settlement inputs, or test the wrong isolation boundary. This is BUILD-prompt directive drift and cross-spec source ambiguity, likely to require a first-month patch if locked as written.

    **Suggested fix:** Enumerate the actual locked source tables required by the rollup, or explicitly mark the rollup-source grant list as implementation-authored and non-normative until BUILD_SPEC_017. Update AC-9 to assert denial on at least one real locked SPEC-005 ledger table, such as `ledger_request_credits`.

M3. Health `down` threshold conflicts between the endpoint contract and failure-mode text

    **Location:** §5.3, lines 641-646; §9.5, lines 1605-1612; §9.6, lines 1616-1618

    **Finding:** §5.3 says `/v1/stats/health` reports `status: "down"` when `overview` or `leaderboard_24h` is beyond the §5.8 503 budget. §9.5 defines those budgets as 120s for overview and 300s for 24h leaderboard. §9.6 instead says a missed tick reports degraded after target freshness and `down` after 2x target freshness, which is 60s for overview and 120s for 24h leaderboard.

    **Why it matters:** Partners will treat the health JSON as a machine-readable freshness contract even though the HTTP status stays 200. The current text lets two conforming implementations report different health statuses for the same stale snapshot.

    **Suggested fix:** Pick one threshold model. The least disruptive fix is to align §9.6 with §9.5's 503 budgets for `down`, while retaining the target freshness threshold for `degraded`.

M4. Bucket-boundary changes are called additive even though they change existing field semantics

    **Location:** §6.2, lines 992-1004; §8.2, lines 1318-1328; §8.3, lines 1352-1356; §11 Q1, lines 1740-1744

    **Finding:** §6.2 says the operator MAY tighten bucket boundaries without a SPEC bump if future-reserved slots such as `$$$$` or `$$$$$` are introduced through §8.2.1. Adding a new reserved bucket value can be additive, but changing the thresholds behind existing emitted values like `$`, `$$`, and `$$$` changes the meaning of an existing field. §8.3 says field-meaning changes require `/v2/*`, and Q1 keeps bucket-boundary re-anchoring as a v0.2 question.

    **Why it matters:** Partner dashboards can compare bucket labels across time. A silent threshold change would make historical and current labels incompatible while the wire shape remains the same.

    **Suggested fix:** Split the rule: new reserved bucket values may be additive under §8.2, but changing the meaning of existing bucket values requires a SPEC/changelog bump and explicit deprecation or versioning treatment.

## MINOR findings

m1. `partner_keys_writer` role count and cross-reference drift

    **Location:** §5.4.3, line 763; §7.2, lines 1131-1135; §7.2.4, lines 1227-1244; §7.2.5, lines 1246-1254

    **Finding:** §7.2 says the stats surface splits DB grants across three roles, but the section now enumerates four role surfaces once `partner_keys_writer` is included. §5.4.3 points to §7.2.5 for `partner_keys_writer`, while the role is actually specified in §7.2.4; §7.2.5 is connection-pool isolation.

    **Why it matters:** The new role itself is appropriately narrow and optional when `last_used_at` is not updated, so this is navigation and prose hygiene rather than a contract blocker.

    **Suggested fix:** Change the count to "four" or "three required roles plus optional `partner_keys_writer`", and update the §5.4.3 cross-reference to §7.2.4.

m2. RFC 9745 is cited but missing from References

    **Location:** §8.3, lines 1355-1356; §8.4, lines 1362-1374; §12, lines 1835-1836

    **Finding:** The body correctly cites RFC 9745 for the `Deprecation` header, but §12 lists only RFC 7234, RFC 8594, and RFC 2119.

    **Why it matters:** This is minor spec hygiene. The header semantics are otherwise corrected from Round 3.

    **Suggested fix:** Add RFC 9745 to §12.

## Operator questions surfaced

None beyond the existing §11 open questions.

## Round 3 closure notes

- R3 M1 is partially closed: the placeholder grant and `last_used_at` writer problems are addressed, but stale request-path isolation wording and source-table enumeration remain as M1 and M2 above.
- R3 M2 is closed: §5.7 now makes OPTIONS preflight unauthenticated and applies partner-key allowlist enforcement to credentialed GET requests.
- R3 M3 is closed: §12 now treats SPEC-016 as operator context only and §9.1a/Q13 defer rewards semantics instead of re-anchoring on payout-pipeline settlement.
- R3 M4 is closed: Q2 now separates v0.1 operator-issued partner keys from v0.2+ self-serve issuance.
- R3 m1 is accepted/closed: the spec cites the in-repo mirror, and the original `.omc` artifact is no longer required for a live reference.
- R3 m2 is closed: the `Deprecation` and `Sunset` header text now matches current header semantics, except for the missing RFC 9745 reference noted as m2 above.
- R3 m3 is closed: Q ordering and cross-references are coherent.

## Self-verification

- [x] Read every section of SPEC-017 v0.1.3 (§§1-12, ACs 1-20).
- [x] Compared SPEC-017 against the BUILD prompt's "MUST normatively pin" and "MUST explicitly defer" lists. Drift documented.
- [x] Walked each Category A through J. Categories with no findings are noted explicitly.
- [x] Severity for each finding chosen against the prompt definitions.
- [x] Location included for every finding.
- [x] Suggested fix included for each finding.
- [x] Verdict included below.

## Verdict

- READY WITH FIX PASS

SPEC-017 v0.1.3 is closer to lock and does not need another design round, but it is not ready to lock while four MAJOR contract-consistency issues remain. All four appear closable in a narrow text/schema-consistency pass.
