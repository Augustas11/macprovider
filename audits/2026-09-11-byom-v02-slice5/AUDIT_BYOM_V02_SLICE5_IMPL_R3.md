# BYOM v0.2 slice 5 IMPL audit — round 3 (2026-09-11)

Reviewed: the full working-tree diff at `20b1a21a` plus the two operator-committed files. Three codex lanes over `AUDIT_BYOM_V02_SLICE5_IMPL_R3_PROMPT.md`.

| Lane | C | H | M | L | I |
|---|---|---|---|---|---|
| code-reviewer | 0 | 0 | 3 | 1 | 0 |
| security-reviewer | 0 | 0 | 1 | 2 | 0 |
| architect | 0 | 0 | 2 | 2 | 0 |

## Findings and dispositions (fixed in the R3 fix commit)

- **Empty catalog-status map made every request unmatched** (code M): the hook fails closed — no admitted catalog, nothing observed; SPEC-017 §5.2b.2 item 5 + AC-INTAKE-3; test.
- **Current-period malformed histogram reused and health marked OK** (code M, arch M): `fleetRAMCurrent` validates with the shared `intake.ValidateFleetRAMJSON` (closed decode, floors, k, reconciliation, one timestamp form, 30 days) before reuse; the handler uses the same validator.
- **`time.Parse(RFC3339)` accepted offsets and fractions on read-back** (code M): `intake.ParseUTC` accepts only `YYYY-MM-DDTHH:MM:SSZ`; used by `Complete`, `ValidateWindow`, the rollup and the handler; tests.
- **Pair ceiling enforced after unbounded store work** (sec M, arch M): `ModelAdmissionIntakeOfferPairs(ctx, since, until, limit)` — SQL `LIMIT`, in-memory stop — the builder asks for ceiling + 1; SPEC-047 states the store-level ceiling; test.
- **`decodeClosed` trailing check used `More()`** (code L, arch L): second decode must return `io.EOF`; moved to `intake.DecodeClosed`; test.
- **Panic payload logged** (sec L): the recover logs a constant message only.
- **Disabled intake still runs the rollup component and reports health** (arch L): by design — SPEC-017 §5.2b.7 keeps the nine-component health schema and the row while the endpoint is disabled; carried as documented.
