# SPEC audit R2 — BYOM v0.2 slice 4 (SPEC-047 v0.1.5)

**Diff reviewed:** `git diff origin/main -- specs/` at `ba73728f` (R1 fixes `3258268d`). **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 0 H / 2 M / 2 L |
| security-reviewer | 0 C / 0 H / 1 M |
| architect | 0 C / 1 H / 2 M / 1 L |

No R1 item reopened. Resolved in the commit that adds this record:
- **HIGH (architect): candidate-catalog eligibility drift was not fail-closed** — a row-bound primary candidate could stay `settlement_capable` after its row was demoted to `listed`, blocked, or removed with an unchanged digest. R006(c): every candidate-catalog reload re-reads each `catalog_priced`/`settlement_capable` candidate's row — missing/changed key, model_id, or digest → `revoked` `catalog_row_changed`; no longer `recommendable` → `revoked` `catalog_row_ineligible`; R003(ii) now requires row existence + `recommendable` at decision time AND at route time for every BYOM attempt (row-bound primaries included).
- **MEDIUM (code, architect): a feedless row-primary member had no `artifact_id`.** Members are tagged: `source` ∈ {`candidate_row`, `artifact_feed`}; `artifact_id` and the three provenance fields are non-null exactly for feed members and null for row members (nothing synthesized; the row defines no artifact id). Listing schema updated; the decision binds the six values only for `artifact_feed` members.
- **MEDIUM (code, architect): session-binding mutations were outside the critical section.** Every binding mutation (derive at hello/offer, refresh, clear on model change/disconnect/withdrawal/revocation) now executes inside the decision critical section, so the exactly-one-session evaluation and its append see one binding set.
- **MEDIUM (security): route-time admission was not linearized with revocation.** BYOM route-time snapshot creation and persistence happen inside the decision critical section (or an equivalent atomic compare-and-insert that re-reads head and binding immediately before insert); R008 gains the snapshot-vs-revocation/withdrawal/demotion/drift/row-change/reload interleavings.
- **LOW (code, architect): grammars and codes.** `idempotency_key` `^[A-Za-z0-9_-]{1,128}$`; `provider_id` `^[a-zA-Z0-9_.-]{1,64}$` and `candidate_id` `^byom_[a-z2-7]{52}$` as the coordinator's grammars; the error-code set enumerated with HTTP statuses; a closed transition-origin matrix (operator edges; offer, withdrawal, probe, drift appenders with their reason-code sets).
- **R008** extended with eligibility drift on unchanged digest, feedless-primary serialization, and decision-vs-lifecycle races.

R3 runs all three lanes over `git diff origin/main -- specs/`.
