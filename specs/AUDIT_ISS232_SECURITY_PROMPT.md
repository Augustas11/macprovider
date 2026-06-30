## Lane: SECURITY

## Context

Auditing fix for issue [#232](https://github.com/Augustas11/macprovider/issues/232). Fix landed as commit `2f31941` on branch `fix/iss232-fallback-overbill-corroboration` in worktree `/Users/augstar/macprovider-iss232/`.

### Trust-gap closed

PR #229 R5 + PR #286 made the gateway outcome label a trust gate: gateway claims "stream_truncated" → reconciler skips overbill check. A malicious gateway could hide real overbill behind a fallback label.

### The fix

Use `buyer.Result.SawTerminator` (the harness's own observation that the SSE stream ended cleanly with `data: [DONE]`) as a corroboration check:

- Fallback outcome + `SawTerminator=false` → suppress (corroborated truncation; preserves R5 behavior on legitimate F-8 cases).
- Fallback outcome + `SawTerminator=true`  → flag (gateway claims truncation but buyer saw clean stream → trust-gap detected).

## Your job

SECURITY LANE: focus on attack surface. Specifically:

- Is `SawTerminator=true` actually a reliable trust signal? Can a malicious/buggy gateway control whether the buyer sees `data: [DONE]` (e.g., by injecting one at the end before truncating, or by manipulating proxy buffering)? If yes, the corroboration check could be defeated.
- Can a malicious BUYER set `SawTerminator=true` to force I1 false-positives on legitimate fallback pairs? (Threat model: malicious buyer trying to discredit a legitimate gateway.) Is the harness fully trusted relative to the gateway?
- Are there race/ordering scenarios where a partial stream could end with `[DONE]` despite genuine truncation upstream (e.g., gateway buffers some content then upstream times out — does gateway emit `[DONE]` before settling fallback)?
- Does the helper `fallbackOverbillSuppressed` introduce any new way to bypass overbill detection that didn't exist before?

Also general Go security review — bounds, nil derefs, integer overflow in token sums.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/reconcile/ledger_test.go`
- `/Users/augstar/macprovider-iss232/test/network-harness/internal/buyer/result.go` (for SawTerminator definition)
- For the gateway side (does the gateway emit `[DONE]` on fallback paths?):
  - `/Users/augstar/macprovider-iss232/phase5-gateway/internal/router/chat_proxy.go`

Diff: `git -C /Users/augstar/macprovider-iss232 show HEAD`
