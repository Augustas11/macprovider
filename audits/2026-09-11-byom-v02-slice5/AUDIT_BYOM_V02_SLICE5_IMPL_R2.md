# BYOM v0.2 slice 5 IMPL audit — round 2 (2026-09-11)

Reviewed: the full working-tree diff at `f4e2d5a4` plus the two operator-committed files. Three codex lanes over `AUDIT_BYOM_V02_SLICE5_IMPL_R2_PROMPT.md`.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 3 | 0 | 1 | 0 |
| security-reviewer | 0 | 0 | 2 | 1 | 1 |
| architect | 0 | 0 | 2 | 1 | 0 |

## Findings and dispositions (fixed in the R2 fix commit)

- **`catalog_match_state` and `intake_model_key` resolved under two release reads** (code H, sec M1, arch M): `matchModelAdmissionOffer` now returns both from ONE `withReleaseRead` over one catalog snapshot and one identity set.
- **`excluded_account_count` served in a closed window object the generator rejects** (code H, sec M2): removed from the wire; the aggregator keeps the cardinality internally for change detection only; SPEC text updated.
- **Unlisted / provider-bound key 401 not in the auth-failure timing class** (code H): the mux refuses every intake refusal — no key, unlisted, provider-bound — after `padAuthFailureLatency`, before the partner tier; the handler check stays as defence in depth.
- **Enabled intake still answered CORS preflight** (arch M): OPTIONS on intake is 405 `Allow: GET, HEAD` with no `Access-Control-*` header; SPEC-017 §5.2b and AC-INTAKE-2 amended; mux test.
- **Fresh persisted row served without read-side validation** (sec L): `validateIntakeRow` (closed decode, `intake.ValidateWindow` per window, ≤ 3, eleven floors, k, reconciliation) before serving; a failing row answers the `stats_stale` 503; tests for a sub-floor bucket, a stray key, an open window, an unreconciled histogram, a sub-k class.
- **Redaction test checked `error_code` instead of `error`** (code L): both request-log helpers read `error`; the test asserts the constant message and the absence of the buyer string in both columns.
- **Intake sources parsed with `json.loads`, not the duplicate-key-rejecting parser** (arch L): `strict_json` for both retained sources and the manifest; negative test.
- **Nested closed-shape assertions missing** (sec I): the handler test asserts the exact key set of window, parameters, bucket, other_suppressed, fleet_ram, class and methodology.
