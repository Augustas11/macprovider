# BYOM v0.2 slice 5 SPEC closure — pass 1 (2026-09-11)

Reviewed: `git diff origin/main -- specs/` at `f4e2d5a4` (after the independent cold-context review's fix pass). Three codex lanes over `AUDIT_BYOM_V02_SLICE5_SPEC_CLOSURE_PROMPT.md`.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 0 | 4 | 1 | 0 |
| security-reviewer | 0 | 0 | 3 | 1 | 0 |
| architect | 0 | 0 | 5 | 1 | 0 |

Every finding was restatement drift left behind by the fix pass — the governing rules were right, a nearby example, change-log line, table or metadata block still said the old thing. Fixed in `539e1b87`:

- `eligibility_policy_id` still described as random in the §5.2b Types paragraph and "not a function of the account ids" in AC-INTAKE-4 (all lanes): `window_id` is CSPRNG; `eligibility_policy_id` is the §5.2b.2 salted HMAC; the AC says "not dictionary-testable without the salt".
- SPEC-023 change-log formula and example still exact ppm (all lanes): grid formula in the change log; example `300000`.
- SPEC-023 §16.6 "requests the fleet could not serve" (arch): catalog wording.
- SPEC-047 "100 000 events" / "event ceiling" vs the DISTINCT-pair rule (arch, sec): pairs everywhere.
- SPEC-047 inline `depends_on` lacked SPEC-014 and `implementation_status` disagreed with CONFORMANCE (arch, code): aligned.
- SPEC-047 `created_at` shorthand and the change-log's `catalog_matched` restatement (code L, sec L): `created_at_utc`; counted from `intake_model_key` regardless of match state.
- Disabled intake `404` `bad_request` vs the error table (arch L, code M): the `bad_request` row now states the 404 unknown-endpoint use.
