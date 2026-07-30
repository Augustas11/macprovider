# SPEC-016 IMPL Step 1 — codex ARCHITECTURE REVIEW lane, round 1

## Verdict (architecture review lane only)

FIX-THEN-PROCEED

## Counts

| CRITICAL | MAJOR | MEDIUM | LOW |
|----------|-------|--------|-----|
| 0 | 1 | 2 | 0 |

## Findings

[arch:1.1] [MAJOR] §4.7 reorg-poll query does not match the Step 1 attempt schema  
  What: SPEC §4.7’s normative reorg-poll SQL selects `id` and `payout_external_id` from `payout_attempts` (`specs/SPEC-016-payout-pipeline.md:1896`), and later says the orphaned tx hash lives in `payout_external_id` (`specs/SPEC-016-payout-pipeline.md:1938`). Step 1’s §4.5 schema has no `id` or `payout_external_id`; it uses PK `(payout_id, attempt_seq)` plus `tx_hash` (`phase4-coordinator/internal/payout/migrations/0002_payout_attempts.sql:10`, `:19`, `:30`). A literal Step 2/4 implementation of the §4.7 query fails at prepare time.  
  Trade-off: The current schema correctly matches §4.5 and avoids duplicating tx identity, but the v0.1.21 §4.7 wording now gives Step 2 an unimplementable query shape.  
  Suggestion: Before Step 2, amend §4.7 to query `payout_id, attempt_seq, tx_hash` from `payout_attempts`, or explicitly join `ledger_payout_ready.payout_external_id` if that is the intended canonical field.

[arch:1.2] [MEDIUM] Import-boundary test does not catch transitive `billing -> payout` imports  
  What: `TestImportGraph_BillingDoesNotImportPayout` calls `go/build.Import` and checks only `pkg.Imports` plus `pkg.TestImports` (`phase4-coordinator/internal/payout/importgraph_test.go:17`, `:30-34`). Those are direct imports, so `billing -> helper -> payout` would not trip the test, despite SPEC §4.1 requiring `billing/` never import `payout/` (`specs/SPEC-016-payout-pipeline.md:833-849`). Current `go list -deps ./internal/billing` does not show `internal/payout`, so this is a guardrail gap, not a current dependency violation.  
  Trade-off: The current test is fast and simple, but weaker than the architecture contract.  
  Suggestion: Replace it with recursive package loading or `go list -deps`-backed checking for `github.com/augstar/macprovider-coordinator/internal/payout`.

[arch:1.3] [MEDIUM] Co-residency startup assertion is absent in Step 1  
  What: SPEC §3.3 requires startup assertion that handler and runner are co-resident (`specs/SPEC-016-payout-pipeline.md:625-629`), and the build prompt includes a Step 1 AC that split-runner config fails fast (`specs/BUILD_SPEC_016_PAYOUT_IMPL_PROMPT.md:394-395`). The code comments say co-residency assertions live in `main.go` (`phase4-coordinator/internal/payout/addresses.go:97-100`), but `setupPayout` only migrates/asserts/init/mounts (`phase4-coordinator/cmd/coordinator/main.go:580-629`) and there is no deployment-mode or runner-process assertion yet.  
  Trade-off: Deferring avoids inventing a fake runner check before Step 2, but leaves no Step 1 architectural hook that forces Step 2 to preserve co-residency.  
  Suggestion: Add an explicit `AssertPayoutRuntimeTopology` hook in `setupPayout` and make Step 2 wire runner presence/Linux/co-process checks through it before the handler can be enabled.

## Step 1 → Step 2 readiness assessment

READY: Same `*sql.DB` discipline. `requestlog.OpenStore` opens the shared DB (`phase4-coordinator/internal/requestlog/store.go:56`), billing uses `reqLogStore.DB()` (`phase4-coordinator/cmd/coordinator/main.go:89`), and payout uses the same handle (`phase4-coordinator/cmd/coordinator/main.go:317`, `:576`).

READY: `payout_attempts` supports Step 2 §4.3 insert and v0.1.21 C3 amount check: `amount_base_units`, nonce, signed tx, confirm fields, cancel marker, and both partial unique indexes are present (`0002_payout_attempts.sql:10-59`).

FRICTION: §4.7 reorg poll field names are inconsistent with that schema; see [arch:1.1].

READY: `LookupPayoutAddress` is suitable as the cross-package read-side mirror, not the runner SELECT. The runner should implement SPEC §4.3’s `effective_address` CASE internally (`addresses.go:131-142`; SPEC lines `878-897`).

FRICTION: Co-residency assertion is not seeded; see [arch:1.3].

## SPEC drift catalog (architecture-side only)

- SPEC §4.7 references `payout_attempts.id` / `payout_attempts.payout_external_id`, but §4.5 and migration `0002` define neither.
- SPEC §3.3 / BUILD Step 1 require a startup co-residency assertion, but Step 1 currently has only comments and no executable check.

## What I didn't review

I did not report code-style or security findings. I also did not do a cryptographic EIP-712 adversarial review; that belongs to the sibling security lane.

## Cross-cutting architecture observations

The global DSN `synchronous(FULL)` choice is architecturally correct for this single shared DB design (`phase4-coordinator/internal/sqliteutil/dsn.go:17-25`). A separate payout DB would break the same-DB transaction assumptions in SPEC §4.8a/§4.8b.

Targeted validation: `go test ./internal/payout` passed from cache; `go list -deps ./internal/billing` showed no current `internal/payout` dependency.

---

_Persisted by Claude session from codex artifact codex-impl-audit-prompt-spec-016-step-1-architecture-review-lane-l-2026-06-25T15-03-00-547Z.md; agent-role tools (Write/Edit) were disallowed so codex returned the report in its artifact body. Claude transcribed verbatim — no edits._
