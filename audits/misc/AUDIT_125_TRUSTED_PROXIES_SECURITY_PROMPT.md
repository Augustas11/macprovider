# Issue #125 trusted-proxy + X-Forwarded-For — SECURITY-lane audit

You are the **security** lane of a three-lane audit (code / security /
architect) of the trusted-proxy + XFF refactor for issue #125. Stay
narrowly in your lane.

## Why security cares about this diff

`poolCheckClientKey` is the rate-limit key for three buyer-facing
endpoints: `/v1/pool/check`, `/v1/receipt-keys/*`, and
`/catalog/*`. The rate-limit bucket gates anti-abuse, not direct
money flow — but it IS the surface that prevents one noisy caller
from starving every other buyer's access to these endpoints.

Pre-PR-#124: bucket keyed off `r.RemoteAddr` only, which collapsed
to 127.0.0.1 for every public buyer behind nginx. PR #124 fixed the
loopback case via X-Real-IP. This branch generalizes the fix and
introduces a new threat surface — *if the trusted-proxy CIDR set is
mis-configured, attackers in those CIDRs can spoof their bucket key
by sending X-Forwarded-For / X-Real-IP themselves.*

## Branch / commit
- Branch: `fix/coordinator-trusted-proxies-xff`
- Worktree: `../macprovider-125-trusted-proxies` (origin/main base: d27aac5)
- Files in scope (`git diff origin/main`).

## Security-lane scope (apply each; stay in lane)

### SEC-1. Spoof rejection — the load-bearing security invariant
- Untrusted peer with XFF + X-Real-IP MUST be keyed on r.RemoteAddr,
  NOT the spoofed headers. Trace:
  `TestPoolCheckClientKey_UntrustedProxyIgnoresXFFAndXRealIP`
  pins this with `203.0.113.5:50000` + spoofed XFF=1.2.3.4 +
  X-Real-IP=5.6.7.8 → expected key 203.0.113.5. Confirm the helper
  honors this.
- Direct internet caller from 0.0.0.0/0 (default trusted set is
  loopback-only) MUST never have its bucket key controllable via
  headers. Confirm.
- Empty trusted-proxies set means EVERY caller is untrusted (only
  r.RemoteAddr keys). Confirm
  `TestPoolCheckClientKey_EmptyTrustedSetIgnoresForwardedHeaders`.

### SEC-2. Trust-chain integrity
- `rightmostUntrustedXFF` walks RIGHT TO LEFT. The rightmost hop is
  the one closest to the coordinator (added by the immediate-upstream
  proxy); the leftmost is the buyer's claimed IP. Walking right-to-
  left and returning the first non-trusted entry IS the standard MDN
  "rightmost-untrusted" pattern that prevents a buyer-supplied
  leftmost IP from leaking into the bucket key. Confirm:
  - If buyer sends `X-Forwarded-For: 1.2.3.4` (leftmost claimed),
    and immediate-upstream nginx prepends `, 203.0.113.99` (the real
    buyer), and final hop appends `, 127.0.0.1` (LB→coordinator),
    the trusted set is `{127.0.0.0/8, 10.0.0.0/8}`, and the chain is
    `1.2.3.4, 203.0.113.99, 127.0.0.1` — the helper returns
    203.0.113.99 (correct: the buyer-presented "1.2.3.4" is not
    admitted because 203.0.113.99 is the rightmost-untrusted).
- What if an attacker controls the LEFTMOST entry only — e.g. sends
  `X-Forwarded-For: 1.2.3.4`, nginx receives it from
  `198.51.100.42`, nginx appends 198.51.100.42 to make the chain
  `1.2.3.4, 198.51.100.42`, then forwards to coordinator at
  127.0.0.1. The trusted set is loopback-only. The rightmost-
  untrusted walk: hop[1] = 198.51.100.42 → not trusted → returned.
  CORRECT — buyer's spoofed 1.2.3.4 ignored. Confirm.

### SEC-3. Mis-configuration risk
- Operators expanding TrustedProxies to a non-actual-proxy CIDR
  (e.g. `0.0.0.0/0`) would let any caller in that CIDR spoof. The
  config comment names this as "security-sensitive". Is the warning
  prominent enough? Is there a Validate-time guard against
  obviously-wrong values (e.g. reject `0.0.0.0/0` outright)?
- Default is loopback-only. Confirm `config.Default()` returns
  `["127.0.0.0/8", "::1/128"]` and `Load` preserves it through YAML
  round-trip when `proxy.trusted_proxies` is absent.

### SEC-4. Resource-exhaustion (DoS via the rate-limit bucket map)
- The bucket maps (`poolCheckLast`, `receiptKeysLimiters`) are
  keyed on the derived client key. Pre-refactor: max ~2^32 keys
  (one per IP). Post-refactor with trusted-proxy mis-config: an
  attacker who can choose their own bucket key (via spoofed XFF in
  a trusted CIDR) could either:
  - Pin one specific key to consume all bursts for that key (no
    new bucket inflation), OR
  - Cycle through 2^32 keys to inflate the map past
    `maxEntries=4096` — but the existing eviction loop bounds the
    map size. Confirm the eviction is still bounded.
- Is the TTL-based eviction (`evictPoolCheckEntries`,
  `evictReceiptKeyEntries`) still adequate at the new keying surface?

### SEC-5. Boot-time / fail-closed behavior
- `mustParseTrustedProxies` returns nil on parse failure after a
  warning log. Nil means strictest posture (no proxy trusted) — but
  this means a mis-configured `proxy.trusted_proxies` would silently
  degrade to "X-Real-IP / X-Forwarded-For never honored", breaking
  the production loopback case. Is that the right failure mode?
  - Alternative: fail-fast at boot (panic / exit non-zero) so the
    operator notices.
  - Current `config.Validate` already rejects malformed CIDRs, so
    the helper's nil-fallback is dead-code-on-the-happy-path —
    only fires on Validate/parse drift. Acceptable?

### SEC-6. WS-side parity
- `ws.remoteIPForUnauthSemaphore` still uses the narrower
  loopback-only X-Real-IP path (NOT the new trusted-proxy CIDR
  logic). The PR comment says this is "intentionally not unified".
  Is the WS-side surface (unauth WS-handshake semaphore for M1-4
  SECU-1) at risk of the same per-buyer-bucket-collapse if an
  operator moves to a remote LB? Worth a follow-up issue?

### SEC-7. Header injection / parsing safety
- The XFF header value comes from r.Header.Get("X-Forwarded-For")
  — Go's http.Header normalizes via canonical form, so injection
  via raw header bytes shouldn't apply. Parsing via comma-split +
  TrimSpace + ParseAddr is strict. Confirm no path could panic on
  pathological input (e.g. extremely long header, deeply nested
  brackets, etc.).
- `net.SplitHostPort` on a non-host:port string returns err and the
  helper falls through. Confirm there's no path where the helper
  uses an unsanitized value as the bucket key.

## Output format

```
CRITICAL (N):
  C1. <one-line title>
      Evidence: <file:line>
      Fix:     <one-sentence fix>
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/125_TRUSTED_PROXIES_SECURITY_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: security lane READY TO MERGE`
