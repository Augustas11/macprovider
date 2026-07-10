# AUDIT — ISS-211 R2 — CODE lens

## Task

R2 re-audit of the SPEC + IMPL bundle for issue #211 (coordinator
account-scoped reconciliation key). R1 returned ZERO FINDINGS on
the code lens, but R1 also surfaced one HIGH (security) and one
HIGH (architect) whose R2 fixes added new code: a hoisted upstream
bearer on the gateway, and account-scoped SQL subqueries in
`recovery.go`. Re-check those R2 deltas plus everything around
them — code-lens drift between spec and implementation.

Branch: `spec/iss-211-coordinator-account-scope`.

## R2 deltas (relative to R1)

- `phase5-gateway/internal/router/chat_proxy.go`: the upstream
  `Authorization: Bearer <UpstreamCoordinatorBearer>` is now set
  unconditionally alongside `X-MacProvider-Account` when
  `subject.AccountID != ""`. The sticky-conditional block keeps
  only `X-MacProvider-Internal-Conv`.
- `phase5-gateway/internal/router/integration_test.go`:
  `TestStrangerKeyOpenAIChatUsageFlow` Authorization assertion
  rewritten to expect `"Bearer operator-key"` and guard against
  `mp_` key leakage.
- `phase5-gateway/internal/router/server_test.go`:
  `TestStickyConversationIgnoredForDemoTraffic` updated to expect
  `X-MacProvider-Account: demo:1.2.3.4` AND a non-empty
  Authorization header.
- `phase4-coordinator/internal/billing/recovery.go`:
  orphan-detection subquery, `prior`-attempt subquery, and
  `same_request_count` subquery all now scope by
  `(account_id, request_id)` using SQLite `IS` (so NULL = NULL
  preserves legacy clustering).
- `phase4-coordinator/internal/billing/store_test.go`: new
  `TestRecoverLedger_AccountScopedRequestIDCollisionDoesNotQuarantine`.
- SPEC-002 v1.5.0 change-log additions: rollback row-level gate
  language, explorer-deferral bullet, §10 D11 refresh, the
  bearer-pairing requirement.
- SPEC-006 v0.9.1 change-log addition: bearer-pairing requirement.

## What to audit

1. Does the gateway's R2 bearer hoist match SPEC-006 v0.9.1's new
   bearer-pairing MUST? Specifically: the condition
   `if subject.AccountID != ""` gates BOTH the bearer and the
   account header — does the SPEC text claim the bearer is sent
   on EVERY forward, including when account_id happens to be
   empty (legacy gateway, weird auth path)?
2. Does `recovery.go`'s SQLite `IS` operator correctly preserve
   the pre-v1.5.0 quarantine semantics for legacy rows where
   BOTH `prior.account_id` AND `rl.account_id` are NULL? The
   adjacent legacy test
   `TestWriteHotPath_DuplicateRequestIDWithoutRetryQuarantinesAttempt`
   passing is one signal — but does the NEW recovery
   test ALSO need a parallel legacy-NULL-account_id case
   confirming legacy quarantine still fires? (i.e., is the test
   matrix complete?)
3. SQL injection / string interpolation: the recovery.go change
   adds `prior.account_id IS rl.account_id` — is this hard-coded
   SQL (yes), and are all user-controlled values still bound
   via `?`? Verify no `fmt.Sprintf` slipped in.
4. Does the SPEC-002 v1.5.0 "money-path scope" bullet still
   accurately describe what hotpath.go does after R2? (The R2
   change was to recovery.go, not hotpath.go — but cross-check
   the §11 narrative.)
5. Cross-check the gateway test changes against the production
   chat_proxy.go behavior: with the bearer hoisted, what does
   `copyForwardHeaders` do with the buyer's incoming
   `Authorization` header (e.g., a buyer-supplied
   `Authorization: Bearer evil-key`)? Does it overwrite or
   coexist? Is the order safe?
6. Any other request_log SELECT or COUNT that wasn't scoped in
   R2? (R2 covered hotpath.go and recovery.go. Are there more?)

## Severity bar

Report ONLY CRITICAL / HIGH / MEDIUM. Each finding:
```
SEVERITY: ...
TITLE: ...
FILE: <path:line>
DETAIL: ...
SUGGESTED FIX: <minimal>
```

If zero findings, respond exactly: `ZERO FINDINGS`.

## Out of scope

- The R1 findings already addressed (assume R1 disposition
  is correct unless you find something NEW the R2 fixes broke).
- The deferred explorer surface enrichment.
- Style nits.
