# ISS-187 R1 — architect-lane audit prompt

Audit target: the diff on branch `fix/iss-187-mid-stream-settlement`
against `origin/main`. The change closes a SPEC-006 § 17.7 P0
money-path gap: when the gateway's normal settlement path fails
after streaming bytes have flowed to the buyer, the gateway now
writes a usage_events row via a new idempotent fallback
(`EnsureUsageEvent`) instead of silently dropping the audit row +
refunding the reservation.

## Background

SPEC-006 v0.6 § 17.7 (Quota refund and settlement matrix). Streaming
partial-stream row:

| Status | Completion tokens | Quota debited |
|---|---|---|
| 502, >0 partial stream | provider-reported actuals, else ceil(bytes_emitted/4) | prompt + actual_completion |

Phase-A scenario 05 caught the gateway emitting HTTP 200 + 13kB +
[DONE] with NO usage_events row. Buyer paid $0, provider got $0.
Root cause was not pinpointed empirically; the diff is a defensive
fix that handles the failure mode regardless of upstream cause.

SPEC-002 v1.4.2 R-3 (in the recently-merged #192) re-affirms FR-B6's
SSE envelope but doesn't go into the settlement contract — that's
SPEC-006's domain.

## Scope of this lane

You are the **architect lane**. Focus on:

- **Spec consistency vs SPEC-006 § 17.7.** Does the new fallback
  satisfy the spec's "prompt + actual_completion" debit rule for
  partial streams? Look at the fallback's TokenSource and
  CompletionTokens derivation in `settleAfterCommit`.
- **SPEC-005 § 6.9 mirror credit composition.** SPEC-005 says the
  provider gets credited via mirror reads from `usage_events`. With
  the fix, usage_events now reliably has a row → SPEC-005 mirror
  runs as expected. Without the fix, no row → no credit → provider
  underpaid. Does the fix correctly compose with the SPEC-005 mirror
  job's read path?
- **Settlement outcome vocabulary.** The fallback preserves the
  caller-supplied outcome string ("stream_truncated",
  "client_disconnect", "stream_malformed", etc.). Is the outcome
  vocabulary used consistently with SPEC-006 § 17.7's row labels?
  Any outcome strings that don't appear in the spec matrix and might
  surprise harnesses?
- **Window-date drift.** Normal-path SettleReservation uses the
  reservation row's window_date. Fallback uses
  `s.now().UTC().Format("2006-01-02")`. For a request that spans
  UTC midnight (rare but possible for long streams), the window_date
  could differ by one day. SPEC-006 says quotas are per-window-date;
  could that drift double-count or miscount toward a buyer's daily
  quota?
- **SPEC-002 v1.4.3 follow-up.** Issue #197 already collects
  v1.4.3 clauses (UUID-tolerance + cap-exhaustion + cold-start
  fallback semantics). Does this PR introduce new SPEC-006
  clarification candidates worth bundling into a similar #197-style
  follow-up?
- **Versioning.** Does this PR need a SPEC-006 minor bump (e.g.,
  v0.X.Y) to document the fallback path? Or is "the gateway MUST
  write a usage_events row for partial-stream outcomes regardless
  of reservation state" an implementation detail rather than a
  spec clause?
- **Naming.** `EnsureUsageEvent` vs `InsertUsageEvent`. Are the
  two names self-explanatory? Should the spec / addendum mention
  the fallback explicitly so a future reader understands when each
  is called?

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
specs/SPEC-006-buyer-api.md   # § 17.7 settlement matrix
specs/SPEC-005-billing.md      # § 6.9 mirror credit
```

## Scope: PR-INTRODUCED findings only

Per the locked three-lane convergence convention.

## Output format

For each finding:

- **Severity:** CRITICAL | MAJOR | MINOR | NOTE
- **Aspect:** spec | naming | versioning | cross-service | contract
- **Issue:** one-sentence statement
- **Evidence:** quote relevant code or spec
- **Recommendation:** specific change

End with:
```
Found: <N> CRITICAL, <N> MAJOR, <N> MINOR, <N> NOTE.
```

Keep response under 700 words.
