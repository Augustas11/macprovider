# SPEC closure pass 1 — SPEC-047 v0.1.5 rewrite (after the independent review)

**Diff reviewed:** `git diff origin/main -- specs/` at `daad64c6`. **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 2 H / 3 M / 1 L |
| security-reviewer | **0 C / 0 H / 0 M / 0 L** — at the bar (retired) |
| architect | 0 C / 3 H / 1 M |

Resolved in the commit that adds this record:
- **HIGH (code, architect): generation fencing let a decision or route insert straddle a partially installed release.** A release read-write lock: the reload holds the write side for the whole swap and publishes the generation last; decisions/approvals hold the read side across the generation re-compare + append; route-time compare-and-insert holds it across the insert; the decision event records `evaluated_release_generation`; the R006 sweeps stamp each surviving candidate's binding with `validated_release_generation`, which route time requires to equal the published generation (unreachable candidates are unroutable, not revoked, until swept).
- **HIGH (architect): per-candidate sections did not linearize cross-candidate binding ambiguity with routing.** The section is per PROVIDER (its uniqueness predicate spans the provider's candidates) and owns a binding generation bumped on every candidate event and binding mutation; route compare-and-insert conditions on it.
- **HIGH (architect): `allowed_runtime_sources` ignored.** Enforced at match (`runtime_source_not_allowed`, member flagged inadmissible), at decision (ii) and session selection (iv), and on reload (`catalog_runtime_source_disallowed`); the candidate-row member admits the SPEC-023 matrix sources for `mlx_safetensors`.
- **HIGH (code): `offer_rejected` unreachable while R008 mandated it.** R008 and its journey list now state rejection as synchronous (4xx, nothing appended) followed by a fresh accepted offer.
- **MEDIUM (code, architect): dual-control protocol was not closed.** Pending record (id grammar, digest, requester, expiry, invalidation on any event), request-replay semantics (the pending record), `model_admission_decision_approve_request.v1`, distinct-actor rule, approval re-running the full precedence against the pending record's head, concurrent approvals, and the codes `no_pending_decision` / `pending_expired` / `pending_consumed`.
- **MEDIUM (code): precedence applied R003 to every edge** — scoped to `catalog_priced`/`settlement_capable`.
- **MEDIUM (code): actor readback impossible through status v1** — the operator listing carries `last_event_actor`; status v1 exposes the reason only; R008 says so.
- **LOW (code): removed row double-assigned** — (ii) no longer names removed rows.

Closure pass 2 runs code-reviewer and architect only.
