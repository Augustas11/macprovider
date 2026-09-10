# SPEC audit R3 — BYOM v0.2 slice 4 (SPEC-047 v0.1.5)

**Diff reviewed:** `git diff origin/main -- specs/` at `bf12b068` (R2 fixes). **Bar:** 0 C / 0 H / 0 M.

| Lane | Verdict |
|---|---|
| code-reviewer | 0 C / 1 H / 4 M / 1 L |
| security-reviewer | **0 C / 0 H / 0 M** / 1 L / 1 I — at the bar (lane retired; its LOW is closed below) |
| architect | 0 C / 0 H / 3 M / 1 L |

Resolved in the commit that adds this record:
- **HIGH (code): "several live sessions" is unreachable** — the registry keeps one active session per provider id (a new hello replaces it). R003(iv) now states that invariant: the provider's single live session must be bound, pinned `hash_verified` for a recorded member, with a receipt key; `ambiguous_sessions` removed; R008 covers none/one/replacing hello.
- **MEDIUM (code): idempotency lookup outside the critical section** could turn a concurrent duplicate into `stale_head`. The whole sequence (idempotency lookup + reservation, preconditions, head compare, append) executes under the section; concurrent same-key outcomes are stated and tested.
- **MEDIUM (code, architect) / LOW (security): reason sets overlapped.** Operator reasons must be outside every reserved internal set (`synthetic_probe_` prefix, drift codes) or the request is `invalid_request`; the sole-caller sentence is scoped to operator-origin decisions; R008 requires each reserved reason to be rejected via the operator endpoint.
- **MEDIUM (code): disconnect and receipt-key loss had no transition.** R006(d): receipt-key loss on a bound `settlement_capable` session → `revoked` `receipt_key_unavailable`; disconnect is explicitly not a durable transition (binding cleared; unroutable until a new hello rebinds and re-verifies).
- **MEDIUM (code): `served_model_drift` did not exist.** One code, `runtime_identity_drift`, for both the served-model-id and identity-verdict predicates (what the existing path emits).
- **MEDIUM (architect): the row tuple the comparisons consume was not recorded.** The offer event records `catalog_row_model_id` and `catalog_row_model_sha256` read from the authenticated candidate catalog (listed in `model_admission_offer_list.v1`); R003(ii)/R006(c) compare against them; R008 tests each field changing independently.
- **MEDIUM (architect): the v0.1.3 "exactly ONE (model_key, artifact_id)" sentence contradicted null row-member artifact ids** — qualified: feed matches resolve to `(model_key, artifact_id)`; a row-primary match resolves to the row key with its canonical pair and a null `artifact_id`.
- **LOW (code, architect): "Two drift sources" enumerated three** → "The following drift sources" (now a–d).

R4 runs the code-reviewer and architect lanes only (security at bar, never re-fired) over `git diff origin/main -- specs/`. This is the fourth anchored round; if it does not meet the bar the SPEC goes to an independent cold-context round rather than R5.
