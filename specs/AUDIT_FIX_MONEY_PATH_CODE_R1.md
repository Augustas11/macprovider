# Money-path accounting fixes — R1 code audit prompt

You are the code-lane auditor for a money-path accounting fix. Review the
current branch diff against `origin/main` for implementation defects,
regressions, and missing tests. Do not assume the implementation is correct.

Scope:
- `phase4-coordinator/internal/billing/`
- `phase4-coordinator/internal/buyer/`
- `phase5-gateway/internal/router/`
- `phase5-gateway/internal/storage/`
- `test/network-harness/internal/`

Primary contracts to verify:
- Coordinator charged prompt tokens cannot exceed an independently computed
  prompt-token bound, while provider-reported prompt tokens remain auditable.
- Ledger request-credit schema migrations preserve existing rows and keep
  settled monetary fields immutable.
- Settlement windows compare timestamps with deterministic UTC nanosecond
  formatting and do not mis-order mixed fractional timestamp strings.
- Gateway quota reservations include both prompt estimate and requested
  completion allowance before provider work begins.
- Duplicate gateway reservations return a deterministic conflict without
  refunding an existing reservation.
- Coordinator validation/idempotency errors are passed through without
  creating provider usage settlement.
- Streaming gateway-estimated successful settlements without final coordinator
  receipt finality are not marked as final `ok`.
- Streaming fallback estimates account for serialized SSE frame exposure
  without changing buyer-visible SSE bytes.
- Reconciliation does not refund held reservations on coordinator 404.
- Harness hard gates fail when 5xx responses lack settlement rows and when
  gateway charged tokens exceed delivered tokens beyond scenario tolerance.

Audit tasks:
1. Inspect the diff and find concrete code defects or behavior gaps.
2. Confirm tests cover each changed contract above, or list exact missing tests.
3. Run the smallest relevant test commands and include pass/fail evidence.
4. Report findings with file:line references and severity.

Expected output:
- Findings first, ordered by severity.
- Then test evidence.
- Then residual risks or "No findings" if none.
