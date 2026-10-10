All six round-2 findings are **FIXED**. No regression was identified in the R3 changed lines.

Paths below are under `phase4-coordinator/internal/billing/`. Each finding was **NEW in R2**, not pre-existing.

| R2 finding | Status and evidence | Regression |
|---|---|---|
| Architecture HIGH — stale evaluation overwrites frozen verdict | **FIXED** — `pool_proven.go:435` requires both evidence rows to exist inside the write transaction. The fallback at `:453` preserves frozen verdict/finality. Regression coverage: `pool_proven_test.go:251`. | None identified |
| Code HIGH — same archival race | **FIXED** — guarded update at `pool_proven.go:432`; zero affected rows take the frozen-state fallback at `:452`. | None identified |
| Security HIGH — same archival race | **FIXED** — deletion and guarded evaluation writes serialize on SQLite’s writer; missing either evidence row prevents the stale verdict update (`pool_proven.go:435`). | None identified |
| Architecture MEDIUM — NULL label aborts deletion | **FIXED** — shared predicate uses `COALESCE(..., 0)` at `pool_proven.go:96`; both triggers consume it at `:157` and `:172`. Both deletion orders are covered at `pool_proven_test.go:304`. | None identified |
| Code MEDIUM — same NULL-label failure | **FIXED** — the non-null predicate excludes NULL labels rather than violating `verdict_ok`’s constraint (`pool_proven.go:96`). | None identified |
| Security MEDIUM — snapshot trigger traverses provider history | **FIXED** — credit lookup supplies the settlement scope, followed by the verdict’s complete unique key (`pool_proven.go:115`). Verdict-delete capture uses the payable snapshot index (`:133`). Plan coverage: `pool_proven_test.go:343`. | None identified |

Previously resolved findings remain fixed: archived contributions survive cursor reset (`pool_proven.go:309`), archived credits remain checked through the live payable view (`:478`), writes remain capped at 200 rows with two-second transaction contexts (`:415`, `:525`), and refresh reads retain ten-second contexts (`:519`).

The retention fit remains sound: the first evidence deletion freezes verdict/finality while both rows exist; subsequent deletion preserves that state. #1909 retains credit tombstones and requires closed finality before deletion. Its compatibility floor and incremental vacuum do not conflict with these changes; snapshot AUTOINCREMENT prevents deleted IDs from being reused.

Writer fallback remains correctly wired when route reads are absent (`internal/ws/model_admission_pool_proven.go:72`). R012 specifies a **query timeout**, so the five-minute maintenance budget needs no amendment: individual reads remain bounded, and failed refreshes preserve the published snapshot. The ceiling, publication checks, startup refresh, cadence, and CONFORMANCE mapping remain intact.

Validation: read-only source review and passing in-memory SQLite probes of the exact evaluation updates and rendered capture plans, including either/both evidence rows absent. No scans or temporary B-trees appeared in those plans. Go tests and production deadline/writer-contention measurements were not run. No edits or network commands occurred.

VERDICT: C=0 H=0 M=0 L=0