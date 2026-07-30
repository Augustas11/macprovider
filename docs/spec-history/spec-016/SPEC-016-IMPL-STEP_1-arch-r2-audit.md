I did not write `specs/SPEC-016-IMPL-STEP_1-arch-r2-audit.md` because the same prompt explicitly says this lane is read-only and MUST NOT modify any file. Here is the audit content.

## Summary

Verdict: **CLEAN**. The `fc3bf56` fix-pass properly closes `[arch:1.2]` and `[arch:1.3]`, and `[arch:1.1]` is a valid SPEC-side deferral rather than a Step 1 implementation defect.

Validation passed: `go test ./internal/payout -count=1`, targeted payout r2 tests, `go test ./cmd/coordinator -run Test -count=1`, and `go test ./internal/billing -count=1`. The mutation probe was not performed because it would require temporarily editing a source file, which conflicts with the read-only constraint.

## Analysis

## Verdict (architecture review lane only)

CLEAN

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| 0 | 0 | 0 | 0 |

## r1 closures verified

| r1 ID | Status | Notes |
|-------|--------|-------|
| arch:1.1 | DEFERRED-VALIDATED | SPEC §4.5 defines `payout_attempts` without `id` or `payout_external_id`, while §4.7 queries both from `payout_attempts`; deferral correctly targets SPEC v0.1.22. |
| arch:1.2 | CLOSED | `walkImports` now DFSes `Imports`, `TestImports`, and `XTestImports`, uses `visited` for cycles, and fails on `internal/payout` or subpackages. |
| arch:1.3 | CLOSED | `setupPayout` calls `AssertPayoutRuntimeTopology` after canonical security config load and before deny-list, pause reader, address service, and mux construction. |

## Step 1 → Step 2 readiness (re-assessment)

| Row | r1 verdict | r2 verdict |
|-----|------------|------------|
| Same `*sql.DB` discipline | READY | READY |
| `payout_attempts` schema for §4.3/C3 | READY | READY |
| §4.7 reorg poll field names | FRICTION | FRICTION / DEFERRED-VALIDATED |
| `LookupPayoutAddress` | READY | READY |
| Co-residency assertion | FRICTION | READY |

## New findings

None.

## Cross-cutting architecture observations

The import-boundary guard is now architecture-grade for Step 2: it recursively walks in-module dependencies and includes external test imports. The companion payout-to-billing test is intentionally future-facing; the comment clarifies Step 1 does not yet import billing and Step 2 will make that direction concrete.

The topology hook belongs in `internal/payout/`. It is payout-domain startup policy, is invoked from `cmd/coordinator/main.go`, and avoids creating a premature `internal/topology` abstraction. Step 2 can tighten `RunnerCoResident` and `LinuxRequired` in place without reshaping the startup path.

The `existingPayoutAllowed sql.NullInt64` read is defensive rather than a schema smell. The migration defines `payout_allowed INTEGER NOT NULL DEFAULT 1 CHECK(payout_allowed IN (0,1))`, but scanning into `NullInt64` makes the rotation code robust to legacy/manual drift while preserving `1` as the fallback.

## Root Cause

Round 1’s architectural issues were guardrail gaps, not incorrect Step 1 domain modeling: the import test only checked direct imports, and the co-residency contract existed in comments but not in startup code. The remaining `[arch:1.1]` issue is rooted in SPEC drift: §4.7 names fields that §4.5 never defines.

## Recommendations

1. Proceed with Step 2 from an architecture standpoint. Keep `[arch:1.1]` tracked as SPEC v0.1.22 work before finalizing §4.7 reorg-poll implementation.
2. In Step 2, change the topology branch so `HandlerEnabled && !RunnerCoResident` becomes a fail-fast error, and set `LinuxRequired=true` when the runner is enabled.
3. When implementing §4.7, use `payout_attempts.tx_hash` or an explicit join to `ledger_payout_ready.payout_external_id`; do not implement the v0.1.21 SQL literally.

## Trade-offs

| Option | Pros | Cons |
|--------|------|------|
| Validate deferral and keep Step 1 schema unchanged | Preserves locked §4.5 schema and avoids speculative columns | Step 2 must resolve §4.7 query shape before landing reorg polling |
| Add `id` / `payout_external_id` to `payout_attempts` now | Makes the broken §4.7 query prepare | Diverges from §4.5 and duplicates identity already represented by `(payout_id, attempt_seq)` and `tx_hash` |

## References

- `phase4-coordinator/internal/payout/importgraph_test.go:46` - DFS uses `visited` as the cycle guard.
- `phase4-coordinator/internal/payout/importgraph_test.go:64` - walks normal imports.
- `phase4-coordinator/internal/payout/importgraph_test.go:69` - walks test imports.
- `phase4-coordinator/internal/payout/importgraph_test.go:74` - walks external test imports.
- `phase4-coordinator/internal/payout/topology.go:70` - topology assertion entry point.
- `phase4-coordinator/internal/payout/topology.go:83` - Linux gate is ready for Step 2.
- `phase4-coordinator/cmd/coordinator/main.go:605` - security config loaded and canonicalized before topology assertion.
- `phase4-coordinator/cmd/coordinator/main.go:615` - topology assertion is invoked before services are built.
- `phase4-coordinator/cmd/coordinator/main.go:623` - deny-list construction happens after topology assertion.

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-1-architecture-review-lane-r-2026-06-25T15-19-11-516Z.md; agent-role tools (Write/Edit) were disallowed so codex returned the report in its artifact body. Claude transcribed verbatim — no edits._
