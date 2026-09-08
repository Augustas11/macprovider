# Audit — BYOM old-client compatibility + offer-submit disablement switch (#1248, parent #1240)

METHOD CONSTRAINT (read first): this is a first-party software-correctness review of a money-adjacent coordinator change. Do NOT author or construct adversarial payloads. Evaluate by reading source and running the EXISTING tests (`cd phase4-coordinator && go test ./internal/ws -run 'ModelAdmission|BYOM|PreBYOM' -count=1`, `go test ./internal/buyer -run 'BYOM|Admission' -count=1`, `cd phase3-binary && swift test --filter BYOMAdmissionTests`). Describe any gap abstractly (field + condition) in prose.

Review the COMPLETE diff of this branch as it will land: `git diff origin/main` (three commits on `fix/1248-rollout-compat-disablement` PLUS one uncommitted file, `phase4-coordinator/cmd/coordinator/main.go`, which is part of the same change — review the working tree, not only HEAD). Review every file.

## What the change does
Epic gate #1248 requires (a) old-client compatibility evidence and (b) an "Offer submit" disablement row: a coordinator policy gate that rejects new submissions while preserving existing readback. This branch adds:
- `MACPROVIDER_MODEL_ADMISSION_SUBMISSIONS` env (`""`/`enabled`/`disabled`, anything else refuses boot) → `providerws.WithModelAdmissionSubmissionsDisabled(bool)`; when disabled, `POST /v1/provider/model-admission/offers` returns `503 submissions_disabled` after provider auth and before body parse / rate-limit accounting / store append. Status readback and withdrawals keep working on the same store. No SPEC-047 enum change (HTTP rejection codes are implementation-side).
- CLI: 404/405/503 from the admission endpoint map to `local_default` + `wait_for_coordinator` guidance in the existing `httpStatus` error path (`BYOMDiscovery.swift`); no new wire fields.
- Old-client compatibility tests: pre-BYOM provider hello/heartbeat stays pooled with the admission store wired; admission status for such a provider returns not-offered; SQLite admission schema init is additive/idempotent on a pre-BYOM DB (request-log and provider_tokens rows untouched, tokens still validate); buyer side: pre-BYOM provider stays listed in `/v1/models` and routable under enforce with route snapshot written; CLI `models admission status` against a pre-BYOM coordinator fails closed without fabricating coordinator state.
- Runbook `docs/runbooks/byom-disablement-rollback.md` rewritten to the issue's nine disablement rows, each mapped to tests or explicit N/A (synthetic probe, experimental opt-in surface: unimplemented in v0.1).

## Invariants to verify (challenge them)
- Disabled gate cannot be bypassed by any offer path (other handlers, batch, replay, dry-run); it must sit after auth so unauthenticated callers cannot probe the flag, and before any state mutation or rate-limit side effect.
- Withdrawals and status readback must remain fully functional when disabled; nothing is deleted.
- Memory and SQLite stores behave identically under the gate.
- Env parsing: unknown value fails boot; default unchanged (enabled).
- The CLI mapping of 503 to `wait_for_coordinator` must not claim or fabricate any coordinator admission state, must not change `admission_state_source` to `coordinator`, and must not leak the endpoint.
- Old-client tests must actually model a pre-BYOM payload shape (not just a current client that skips admission calls); the additive-schema test must use a DB created without the BYOM tables.
- The nine-row runbook mapping must cite tests that exist at the stated names and prove what the row claims; N/A rows must be true (grep for probe dispatch / experimental visibility sites).
- No money-path change: default paid routing / settlement predicates untouched.

## Lanes to report (this pass is: {{LANE}})
Report findings as CRITICAL / HIGH / MEDIUM / LOW / INFO. The merge bar is 0 CRITICAL, 0 HIGH, 0 MEDIUM.

- CODE: gate placement and ordering in `handleProviderModelAdmissionOffer`; error shape consistency with sibling rejection codes; option plumbing; test adequacy (do the compat tests assert the pre-BYOM shape, or would they pass with any client?); Swift mapping correctness.
- SECURITY: bypass paths; information disclosure via the 503 before auth; rate-limit accounting interaction; any state deletion; any widening of what the CLI treats as coordinator authority; secrets in runbook.
- ARCHITECTURE: is a boot-time env the right seam vs. a runtime policy in the admission store; consistency with the existing `verified_model_settlement_mode` and `WithModelAdmissionStore` switches; runbook accuracy vs code; single source of truth for rejection codes.

End with a line `VERDICT: <N> CRITICAL / <N> HIGH / <N> MEDIUM / <N> LOW / <N> INFO`. Cite file:line. Do not invent issues to fill a lane.
