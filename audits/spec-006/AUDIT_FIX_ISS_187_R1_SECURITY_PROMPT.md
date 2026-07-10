# ISS-187 R1 — security-lane audit prompt

Audit target: the diff on branch `fix/iss-187-mid-stream-settlement`
against `origin/main`. The change adds an `EnsureUsageEvent`
fallback path in `settleAfterCommit` so the gateway writes a
usage_events row even when `SettleReservation` fails. Before this
change, a SPEC-006 § 17.7 settlement failure refunded the
reservation and silently dropped the audit row — buyer paid
nothing, provider got nothing.

## Scope of this lane

You are the **security lane**. Focus on:

- **Forged usage_events.** The fallback `EnsureUsageEvent` does
  NOT consult the reservation row. Can an attacker make the
  gateway write a usage_events row WITHOUT having gone through
  ReserveQuota first? If yes — does the rest of the code path
  ensure `subject.AccountID` is authenticated before reaching
  `settleAfterCommit`? Trace from `handleChatCompletions` down to
  the new fallback.
- **Buyer over-charging.** The fallback uses
  `gateway_estimated` for `token_source` and `ceil(emitted / 4)`
  for completion tokens (per estimateStreamingCompletionTokens).
  Could an attacker (a malicious provider, or compromised
  coordinator) make the gateway over-estimate token counts and
  over-charge a buyer? Look at the `emitted` counter — what
  bounds it? Does it cap at `max_tokens` per the buyer's
  original request?
- **Buyer under-charging via collision.** The pre-existing PK
  collision (issue #196 — gateway `usage_events.request_id` is a
  global PK, not account-scoped) interacts with the new
  `INSERT OR IGNORE`. A cross-account collision now produces a
  SILENT NO-OP (where before it might have been an explicit
  error). Does the new behavior make #196 worse?
- **Audit-log injection.** The fallback `slog.Warn`/`slog.Error`
  paths include `subject.AccountID`, `requestID(r)`, and
  err.Error() strings. Could a malicious upstream-coordinator
  error string contain newlines or control characters that would
  break log parsing? (slog handles escaping, but worth
  confirming.)
- **Race in the test.** `TestStreamingSettlementFallback...` runs
  a goroutine that polls quota_reservations every 2ms, then
  DELETEs the row mid-stream. Could this test's structure expose
  a real race in the gateway (e.g., between settlement-tx-begin
  and settlement-tx-commit, a row delete could leave the
  transaction in a weird state)? Not a code-blocker for the PR
  but worth flagging.
- **window_date derivation.** Fallback computes
  `s.now().UTC().Format("2006-01-02")`. If `s.now` is
  attacker-influenced (it isn't in production, but in tests it
  uses fixedNow), could window_date be manipulated to escape
  rate-limit windows?

Out of scope for this lane:

- **Code lane:** idempotency semantics, signature consistency.
- **Architect lane:** SPEC alignment.

## Files in the diff

```
phase5-gateway/internal/router/chat_proxy.go
phase5-gateway/internal/router/server_test.go
phase5-gateway/internal/storage/interfaces.go
phase5-gateway/internal/storage/sqlite/store.go
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention. The pre-existing
gateway PK collision is tracked in [#196](https://github.com/Augustas11/macprovider/issues/196).
The pre-existing gateway-side Idempotency-Key dedupe gap is tracked
in [#200](https://github.com/Augustas11/macprovider/issues/200). Drop any
re-finding of those from your output and add a one-line NOTE
referencing the issue.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **File:line(s):** exact reference
- **Threat model / attack surface:** one-sentence statement
- **Evidence:** quote relevant code
- **Recommendation:** specific change

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 700 words.
