# Audit record R5 — independent review (`/code-review ultra` on PR #1452), 2026-09-09

After four anchored codex rounds (R1–R4, 0 CRITICAL / 0 HIGH at R4 with the seven R4 MEDIUMs fixed), closure was delegated to an independent multi-agent cloud review of the PR instead of a fifth codex round.

| Finding | Severity | Resolution |
|---|---|---|
| §16.8 `intake-decision.json` closed schema unsatisfiable: no `*_absent_reason` field for three nullable signals; no valid `admission_clause`/`fit_clause`/`signals` for `promote_recommendable` entries (§16.3 says promotion is an operator decision no signal produces) | normal | Schema now carries a per-signal `*_absent_reason` (`demand_rank_absent_reason`, `distinct_provider_offer_absent_reason`, `unmatched_model_request_absent_reason`, `fleet_fit_absent_reason`, each non-null iff its value is null) and a `promotion` object; rule 2 and rule 6 scoped to `admit_listed`, new rule 6a defines the promotion entry (`signals`/clauses null, `promotion` = listed_days_elapsed ≥ min, rate_class, rate_row_resolved, rate-card-source digest, demand_rank_recommendable, demand-rank digest, bench provenance ≠ omlx_seeded, operator reference); same closed key set for both actions with an action-fixed null pattern; AC-CAT-21 extended with null-signal and promotion cases; second example entry added. |
| §3.3.1 rule 3 duplicated phrase ("maps each `rate_class` mapping each `rate_class`") | nit | Fixed. |
| Changelog point 6 range `AC-CAT-1..AC-CAT-17` stale (spec defines through AC-CAT-21) | nit | Fixed. |
| CONFORMANCE R004–R006 gap rationale still called #1240 a placeholder while `gap.issue` already pointed at #1453 | nit | Rationale now reads "Owner is the BYOM v0.2 epic (issue #1453)." |

Verdict after fixes: no open findings. SPEC-023 v0.10.0 lock date set to 2026-09-09. Carried, pre-existing: SPEC-047-R002 duplicated MUST-list; `phase7-verify` `x/text` advisory.
