R1 verification (paths below are under `phase4-coordinator/internal/billing/`):

- **CODE H1 — PARTIAL:** deletion triggers freeze verdict state at `pool_proven.go:118` and `:139`, but the unconditional evaluator update at `:398` can overwrite it.
- **CODE H2 — FIXED:** `EnsurePoolProvenRollup` preserves archived rows at `pool_proven.go:172`; the cursor-reset regression requires preservation at `pool_proven_test.go:240`.
- **SECURITY H1 — PARTIAL:** archived credits are checked live at `pool_proven.go:421`; stale verdict overwrite remains at `:398`.
- **SECURITY M1 — FIXED:** capture and evaluation writes use 200-row batches at `pool_proven.go:269` and `:381`, with a two-second transaction deadline at `:469`.
- **ARCHITECTURE H1 — PARTIAL:** atomic deletion-time capture exists, but the evaluator can overwrite its result at `pool_proven.go:398`.
- **ARCHITECTURE H2 — FIXED:** the destructive version-reset path is removed; schema initialization at `pool_proven.go:172` retains existing rows.
- **ARCHITECTURE M1 — FIXED:** refresh reads use the ten-second wrapper at `pool_proven.go:463`, including capture at `:250`/`:262` and evaluation at `:357`.

HIGH — phase4-coordinator/internal/billing/pool_proven.go:398 — **NEW:** A delayed evaluation can overwrite the deletion trigger’s frozen verdict. Read a hot verified attempt, then dispute and archive it before the evaluation write: the trigger freezes `verdict_ok=0`, but this unconditional UPDATE restores the sampled `verdict_ok=1` and `counted=1`. Subsequent refreshes preserve that incorrect archived verdict. An in-memory probe reproduced this sequence. — **Concrete fix:** guard verdict/finality updates against evidence deletion and recompute counted from the current frozen verdict inside the write transaction. Retry stale evaluations before publishing. Add a regression interleaving evaluation, dispute, archival, and evaluation write.

MEDIUM — phase4-coordinator/internal/billing/pool_proven.go:130 — **NEW:** Both deletion triggers assign a nullable predicate directly to non-null `verdict_ok` (also at `:151`). A closed payable pool attempt with a NULL label produces SQL NULL, aborting DELETE with `NOT NULL constraint failed` instead of excluding the attempt. The regular evaluator already handles this with `COALESCE` at `:419`. An in-memory probe reproduced the constraint failure. — **Concrete fix:** wrap both trigger predicates in `COALESCE(..., 0)` or `CASE WHEN ... THEN 1 ELSE 0 END`; test NULL-label archival in both deletion orders.

Validation was read-only inspection and small in-memory SQLite probes; repository suites and production timing were not run.

VERDICT: C=0 H=1 M=1 L=0