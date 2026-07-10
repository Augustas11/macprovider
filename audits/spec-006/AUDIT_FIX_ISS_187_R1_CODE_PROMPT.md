# ISS-187 R1 — code-lane audit prompt

Audit target: the diff on branch `fix/iss-187-mid-stream-settlement`
against `origin/main`. The change implements SPEC-006 § 17.7 by
adding an idempotent fallback path to `settleAfterCommit` — when
`SettleReservation` fails after bytes have flowed, the gateway now
INSERTs a usage_events row directly via the new `EnsureUsageEvent`
storage method (INSERT OR IGNORE on the PK).

## Scope of this lane

You are the **code lane**. Focus on:

- **Idempotency.** `EnsureUsageEvent` uses `INSERT OR IGNORE` on
  the request_id PK. If a usage_events row already exists (e.g.,
  via the normal settle path that succeeded), the fallback's
  INSERT OR IGNORE silently no-ops. Is that the right behavior?
  Could there be a path where the normal-settle's row has
  different/incorrect data than the fallback's intended data, and
  the silent no-op masks a real discrepancy?
- **Error handling.** When `SettleReservation` fails AND
  `EnsureUsageEvent` fails, the code refunds and returns. Is the
  refund still correct here? The reservation might not exist at
  all (settle_error="quota reservation not found") — refund is a
  no-op. But for `status != 'active'`, refund could now mutate a
  settled row to refunded. Is that ever wrong?
- **Storage interface contract.** `UsageStore.EnsureUsageEvent` is
  newly added. Any test fixtures or mock implementations of
  `UsageStore` outside the diff also need this method or they
  won't compile. Search for `UsageStore` and `InsertUsageEvent` —
  do any non-real-storage implementations exist that need
  updating?
- **`Server.settleAfterCommit` signature.** It still takes
  prompt/completion individually; `EnsureUsageEvent` derives
  TotalTokens via `prompt + completion`. Is that derivation
  correct in all callers? Compare to `SettleReservation`'s
  internal `normalizeSettlementTokens` logic.
- **window_date derivation.** The fallback uses
  `s.now().UTC().Format("2006-01-02")`. The original SettleReservation
  used the reservation row's window_date. Could these diverge for
  edge cases (request crosses UTC midnight)? Look for any
  reconciliation-side join that would break if the window_date
  differs by a day.
- **Test coverage.**
  - `TestStreamingSettlementFallbackWritesUsageEventOn
    MissingReservation` — new test that DELETEs the reservation
    mid-stream and asserts the fallback wrote the row. Is the
    timing race solid (50ms sleep + 50-attempt poll for the
    reservation)? Could the test be flaky on slow CI runners?
  - Existing tests using `settleAfterCommit` paths
    (TestStreamingMidStreamProviderDisconnect, etc) — do they
    still pass and still cover their original invariants?
  - Demo-token path: `subject.DemoIdentity != ""` triggers
    `SettleDemoReservation` in the normal path. The fallback uses
    `EnsureUsageEvent` which inserts a `demo_identity` field. Is
    the fallback symmetric with the demo flow? Should there be a
    separate `EnsureDemoUsageEvent` (no — demo_usage_events is a
    secondary table; the primary usage_events insert is enough
    for SPEC-006 §17.7 audit). Confirm.
- **Logging shape.** The diff emits one `slog.Error` for the
  normal-settle failure, then either a `slog.Warn` (fallback
  succeeded) or a second `slog.Error` (fallback also failed).
  Is the log shape useful for an oncall reading logs?

Out of scope for this lane:

- **Security lane:** retriability, double-billing, attack surface.
- **Architect lane:** SPEC-006 § 17.7 wording match, SPEC-005
  mirror credit, settlement matrix consistency.

## Files in the diff

```
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
phase5-gateway/internal/storage/interfaces.go
phase5-gateway/internal/storage/sqlite/store.go
```

Useful command:
```
git diff origin/main -- phase5-gateway/
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Issue:** one-sentence problem statement
- **Evidence:** quote relevant code
- **Recommendation:** specific change

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 700 words.
