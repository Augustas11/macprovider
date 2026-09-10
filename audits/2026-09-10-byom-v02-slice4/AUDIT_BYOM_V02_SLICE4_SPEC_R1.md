# SPEC audit R1 — BYOM v0.2 slice 4 (SPEC-047 v0.1.5 production decision path)

**Diff reviewed:** `git diff origin/main -- specs/` at `43679c29`. **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 3 H / 3 M / 1 L / 3 I |
| security-reviewer | 0 C / 0 H / 2 M / 3 L |
| architect | 0 C / 0 H / 5 M |

Converged findings, all resolved in the commit that adds this record:
- **HIGH (code) / MEDIUM (architect) / LOW (security): "exactly one resolved member" rejected a legitimate primary-plus-GGUF offer.** Every pair now resolves independently; a match requires every resolved pair to belong to ONE key and records the member SET; the served member is selected by the live session's verified pair at `settlement_capable` decision time (never by counting). New closed reasons `artifact_hashes_span_keys`, `no_artifact_match`; `catalog_artifact_feed_integrity_failure` reserved for real set duplication.
- **MEDIUM (security, architect): offer-time matching removed SPEC-010's independent primary-row path.** Two paths restated verbatim from SPEC-010-R007(b): row-bound primary (no feed, no provenance) and feed path; feed failure resolves nothing on the feed path only; R006 revokes feed-path members only, row-bound primaries are governed by row authority (`catalog_row_changed` on a changed row).
- **HIGH (code) / MEDIUM (architect) / LOW (security): `model_admission_status.v1` was both closed and extended.** v1 is now explicitly unchanged; new closed schemas `model_admission_decision.v1` and `model_admission_offer_list.v1` with exact field lists, ordering, cap, query validation, and the existing error envelope; provider-facing match visibility deferred to a later versioned schema.
- **HIGH (code): idempotent replay contradicted the head compare.** Precedence fixed: idempotency first (identical canonical request → original event regardless of head; divergent reuse → `idempotency_conflict`), then head compare + append as one unit.
- **MEDIUM (code): no linearization point.** A coordinator decision critical section serializes precondition evaluation, head compare, append, drift processing, and feed reload.
- **MEDIUM (architect) / MEDIUM (security): release rotation / pair-only drift could mix provenance.** Decisions require the IDENTICAL provenance tuple per recorded feed-path member (`catalog_match_stale` otherwise → fresh offer); reload drift compares the tuple, not the pair; an unusable set after reload revokes feed-path admissions.
- **MEDIUM (code, architect) / LOW (security): session-to-candidate binding had no lifecycle.** Coordinator-derived binding defined: derived at hello and at offer append from the candidate whose latest non-terminal event resolves to the row whose `model_id` the session serves (zero → none, ≥2 → none + `ambiguous_candidates`); refreshed on every event, cleared on withdrawal/revocation/model change/disconnect; route time requires event-id equality with the latest event and a `settlement_capable` state; `settlement_capable` requires exactly one bound verified session.
- **MEDIUM (code): R008 lacked the new promotion gates** — added.
- **LOW (code): CONFORMANCE encoding churn** — the file is restored to origin/main with only the SPEC-047 version line changed.

R2 runs all three lanes over `git diff origin/main -- specs/`.
