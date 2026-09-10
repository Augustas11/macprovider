# SPEC closure pass 2 — SPEC-047 v0.1.5 (code-reviewer + architect; security retired at bar)

**Diff reviewed:** `git diff origin/main -- specs/` at `6beaa3b9`. **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 1 H / 1 M |
| architect | 0 C / 1 H / 2 M / 1 L / 1 I |

Resolved in `05de8e96` (the record itself landed one commit earlier, `cb370b53`, from a chain whose patch step had aborted on an over-broad guard — that commit carries audit files only):
- **HIGH (both): residual "candidate's section" wording** in R003, R006, §4 and the change log contradicted R001's per-provider section — every reference now names the provider's decision critical section (verified by a grep guard in the patch; R001's pre-existing "per-provider/per-candidate state machine" phrase describes the state machine, not the section).
- **MEDIUM (architect): approval idempotency** — approvals replay in their own (`pending_decision_id`, `idempotency_key`) namespace: an identical-key retry answers the committed response (`replayed: true`); a distinct-key approval of a consumed record is `pending_consumed`.
- **MEDIUM (architect): dual control unavailable** — fewer than two configured operator actors refuse the initial `settlement_capable` request synchronously with `dual_control_unavailable` (no pending record); code added to the closed set.
- **MEDIUM (code) / LOW (architect): `runtime_source_allowed` per member was unrepresentable** — the per-member record is dropped; inadmissible members are excluded and not recorded; an offer left with no admissible pair is `unmatched` / `runtime_source_not_allowed`.
- Added (implementability, not a lane finding): the R006(c) sweep re-evaluates R003 (i)–(iii), so the reload's Tier-2 catalog swap may precede the write-locked swap (the coordinator's reload function is a conformance-mapped fragment that cannot be edited); a Tier-2 material change revokes with `catalog_row_changed`.
- **INFO (architect):** the route-time compare-and-insert needs one composite conditional-persist API across the admission store, the registry binding, and the snapshot insert — noted for the IMPL.

Closure pass 3 runs code-reviewer and architect only.
