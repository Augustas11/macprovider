R1 verification across all three lanes:

| R1 finding | Status | Evidence |
|---|---|---|
| Architecture HIGH: stale state at archival | PARTIAL | `phase4-coordinator/internal/billing/pool_proven.go:118` adds deletion-time freezing, but the unconditional update at `:398` can overwrite it. |
| Architecture HIGH: version reset loses archived attempts | FIXED | `phase4-coordinator/internal/billing/pool_proven.go:172` preserves existing rows; `pool_proven_test.go:240` requires archived contributions to survive cursor reset. |
| Architecture MEDIUM: refresh queries lack 10-second limits | FIXED | `phase4-coordinator/internal/billing/pool_proven.go:463` bounds refresh reads; `specs/CONFORMANCE.json:11865` documents that boundary. |
| Code HIGH: missing evidence preserves stale counts | PARTIAL | Delete triggers freeze current verdicts, but `phase4-coordinator/internal/billing/pool_proven.go:398` permits stale evaluation writes afterward. |
| Code HIGH: reset loses archived contributions | FIXED | No destructive version reset remains; preservation is tested at `phase4-coordinator/internal/billing/pool_proven_test.go:240`. |
| Security HIGH: stale verdicts and archived-credit bypass | PARTIAL | Live credit checks at `phase4-coordinator/internal/billing/pool_proven.go:421` fix the credit bypass; the verdict overwrite remains. |
| Security MEDIUM: oversized writer transactions | FIXED | Capture/evaluation writes use 200-row batches at `phase4-coordinator/internal/billing/pool_proven.go:269` and `:381`, with two-second transaction contexts at `:469`. |

HIGH — phase4-coordinator/internal/billing/pool_proven.go:398 — **NEW in the anchor diff:** An overlapping refresh can permanently overwrite retention’s frozen verdict. Evaluation reads hot evidence, releases the reader, and later writes verdict/finality unconditionally. Between those operations, a label can become disputed and retention can freeze that dispute and delete the evidence. The delayed update restores the earlier verified verdict; subsequent archived evaluations preserve it and continue counting the payable credit. An in-memory probe reproduced frozen `(verdict_ok=0, counted=0)` becoming `(1,1)`. — **Concrete fix:** guard evaluation writes against deletion-time state changes using a revision/freeze marker, then re-read and evaluate conflicts before publishing. Archived credit updates must preserve the frozen verdict/finality. Add a deterministic read–dispute–archive–write regression.

MEDIUM — phase4-coordinator/internal/billing/pool_proven.go:130 — **NEW in the anchor diff:** Both delete triggers assign a nullable predicate directly into `verdict_ok INTEGER NOT NULL`. A payable, closed verdict with a NULL pool label produces NULL. Deleting a verdict with non-empty `pool_id`, or deleting its snapshot first while the verdict remains, raises `NOT NULL constraint failed` and aborts the deletion transaction. The ordinary evaluation correctly uses `COALESCE`; the triggers do not. Exact rendered SQL reproduced the failure for both triggers. — **Concrete fix:** wrap both trigger verdict expressions in `COALESCE(..., 0)` and test NULL labels under both deletion orders.

Otherwise, retained credit tombstones support live payability checks, and the first deleted evidence row freezes the verdict while both rows exist. Cursor reset preserves archived contributions. AUTOINCREMENT prevents deleted snapshot IDs being reused; the handle wiring falls back to the writer when the route-read store is absent.

R012 explicitly specifies a per-query timeout, so the five-minute maintenance budget does not itself require an amendment now that refresh reads are individually bounded. The ceiling and snapshot publication checks remain intact. CONFORMANCE’s mapping is accurate, but its frozen-state claim needs the race correction above.

Validation used local source inspection and in-memory SQLite probes. No files were edited, no network commands ran, and production timing was not measured.

VERDICT: C=0 H=1 M=1 L=0