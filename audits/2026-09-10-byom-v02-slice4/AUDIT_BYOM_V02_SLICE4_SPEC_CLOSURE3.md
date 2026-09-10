# SPEC closure pass 3 — SPEC-047 v0.1.5 (code-reviewer + architect)

**Diff reviewed:** `git diff origin/main -- specs/` at `8e7bdc00`. **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 0 H / 1 M / 1 L |
| architect | 0 C / 2 H / 1 M |

Resolved in the commit that adds this record:
- **HIGH (architect): release publication was not one atomic authority** — the closure-2 permission for an early Tier-2 swap contradicted the locked publication, and the read lock covered only the append. Now: ONE immutable release snapshot (catalogs, feeds, per-release identity sets, Tier-2 material, generation) staged and swapped under the write lock as one act; the read lock spans the whole decision evaluation, offer matching, session verification, and route compare-and-insert; R006(c) no longer permits an early Tier-2 swap. (Implementation: the reload's Tier-2 configure stages material that the ws publication promotes atomically.)
- **HIGH (architect): cross-candidate appends could outrun the binding generation** — every append origin (offer, validator, withdrawal, probe, operator, drift) now acquires the provider section before reading candidate state and holds it through append, pending invalidation, generation increment, and binding refresh — one linearization point.
- **MEDIUM (code, architect): approval binding and replay** — path/body id equality and binding to the stored pending values (`invalid_request`), canonical approval-body digest under (`pending_decision_id`, `idempotency_key`) with `idempotency_conflict` before pending/head checks, and explicit approval precedence (a)–(g).
- **LOW (code): pending-response values** defined for every `model_admission_decision.v1` field of an initial `settlement_capable` request.
- R008 extended for each.

Closure pass 4 runs code-reviewer and architect only. Loop status: independent round → closure 1 (5 H) → 2 (2 H) → 3 (2 H) → this fix; if pass 4 is not at the bar the remaining concurrency contract is escalated to the operator as a design decision rather than iterated further.
