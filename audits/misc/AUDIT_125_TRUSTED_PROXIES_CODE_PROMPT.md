# Issue #125 trusted-proxy + X-Forwarded-For — CODE-lane audit

You are the **code** lane of a three-lane audit (code / security /
architect) of the trusted-proxy + XFF refactor for issue #125. Stay
narrowly in your lane.

## Branch / commit
- Branch: `fix/coordinator-trusted-proxies-xff`
- Worktree: `../macprovider-125-trusted-proxies` (origin/main base: d27aac5)
- Files in scope (`git diff origin/main`):
  - `phase4-coordinator/internal/config/config.go` — new `ProxyConfig{TrustedProxies}` block + `TrustedProxyPrefixes()` helper + `Validate()` call.
  - `phase4-coordinator/internal/buyer/server.go` — refactored `poolCheckClientKey` to a Server method consulting `s.trustedProxies`; new `rightmostUntrustedXFF` helper + `isTrustedProxy` predicate; `WithTrustedProxies` option; constructor seeds default loopback prefixes.
  - `phase4-coordinator/internal/buyer/trusted_proxies_test.go` (NEW) — 11 tests covering the surface.
  - `phase4-coordinator/cmd/coordinator/main.go` — wires `cfg.TrustedProxyPrefixes()` into the buyer Server via a `mustParseTrustedProxies` helper.

## What this change does (operator summary — NOT the audit answer)

Issue #125. PR #124 landed a partial fix that honored X-Real-IP only when r.RemoteAddr is loopback. The remaining surface:
- Non-loopback proxy topologies (remote LB, sidecar)
- Trusted-proxy CIDR allowlist
- Chained-trusted-proxy hops via X-Forwarded-For (rightmost-untrusted)

This branch:
1. Adds `proxy.trusted_proxies` config (default `["127.0.0.0/8", "::1/128"]` preserves production behavior).
2. `poolCheckClientKey` now (a) parses r.RemoteAddr to netip.Addr; (b) consults `s.trustedProxies`; (c) if trusted, walks XFF right-to-left for the first non-trusted hop, falls back to X-Real-IP, then r.RemoteAddr; (d) if untrusted, IGNORES forwarded headers and returns r.RemoteAddr — spoof rejection.
3. Constructor seeds default loopback prefixes so existing tests + callers keep working without explicit `WithTrustedProxies`.

## Code-lane scope (apply each; stay in lane)

### CODE-1. Helper correctness
- `rightmostUntrustedXFF(header, trusted)`: walks comma-split hops right-to-left; for each hop trims whitespace, strips optional :port via net.SplitHostPort, strips lone brackets for IPv6, parses via netip.ParseAddr, returns first non-trusted hop's `addr.String()`. Trace:
  - Empty header → "" (caller falls through).
  - All hops trusted → "" (falls through to X-Real-IP).
  - Junk middle hop (e.g. "not-an-ip") → continue past it; return next-rightmost untrusted.
  - IPv6 with brackets `[2001:db8::1]:443` → SplitHostPort strips port; Trim drops residual brackets; ParseAddr succeeds.
  - Bare IPv6 `2001:db8::1` → SplitHostPort fails (no port); Trim no-op; ParseAddr succeeds.
- `isTrustedProxy(addr)`: nil-safe (returns false on empty s.trustedProxies). Confirm.
- `(s *Server).poolCheckClientKey(r)`: branch order: SplitHostPort → ParseAddr → if !trusted return host → XFF rightmost-untrusted → X-Real-IP → host. Trace each branch.

### CODE-2. Constructor / default seeding
- `NewServer` seeds `trustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("::1/128")}`. `WithTrustedProxies` REPLACES this set (uses `s.trustedProxies[:0]` to discard the default; confirm the slice mutation is safe — no aliased reference held elsewhere).
- `mustParseTrustedProxies(cfg, logger)` in main.go: returns nil on parse error after logging a warning (strictest possible posture). Trace: is "nil → no proxy trusted" the right failure mode, or should the boot fail fast?
- `Validate()` calls `TrustedProxyPrefixes()` so malformed CIDRs reject at config.Load. The same parse happens AGAIN in `mustParseTrustedProxies` — verify the duplication is intentional (defensive vs single-source-of-truth).

### CODE-3. Existing test compatibility
- `TestCatalogEndpointRateLimitedPerXRealIPBehindLoopback` (catalog_endpoints_test.go:245) constructs `NewServer` without `WithTrustedProxies`. After the refactor it depends on the constructor's default loopback seeding. Confirm the test still pins the PR #124 invariant (loopback honors X-Real-IP; direct caller cannot spoof). Run the test mentally against the new code.

### CODE-4. New test adequacy
The 11 new `TestPoolCheckClientKey_*` tests in trusted_proxies_test.go cover:
- LoopbackDefaultHonorsXRealIP, NonLoopbackTrustedProxyHonorsXFF, UntrustedProxyIgnoresXFFAndXRealIP, MultiHopXFFReturnsRightmostUntrusted, XFFTakesPriorityOverXRealIP, EmptyTrustedSetIgnoresForwardedHeaders, AllHopsTrustedFallsBackToXRealIP, AllHopsTrustedNoHeadersFallsBackToRemoteAddr, IPv6LoopbackHonored, MalformedXFFHopSkipped, UnparseableRemoteAddrFallsBack.
- Missing coverage to flag? Specifically:
  - XFF with leading/trailing whitespace + commas (`" 1.2.3.4 , 5.6.7.8 "`)?
  - Empty hop in XFF (`"1.2.3.4,,5.6.7.8"`) — does the empty-string TrimSpace + ParseAddr-fail path do the right thing?
  - XFF with only commas (`",,,"`) → "" return → fallback path?
  - X-Real-IP with attached port (`"1.2.3.4:443"`) — current code does NOT strip the port for X-Real-IP, but production nginx sets it without port. Worth a test pin or comment?

### CODE-5. Backward compatibility + isLoopbackHost retention
- `isLoopbackHost` is now unused in the rate-limit path (replaced by `isTrustedProxy`). The function is retained per the new doc comment. Grep for any remaining caller — is it actually used anywhere, or is the retention purely defensive?
- The pre-refactor `poolCheckClientKey` was a package-level function; it's now a `(s *Server)` method. Callers update: confirm both `allowPoolCheck` and `allowReceiptKeys` callsites switched to `s.poolCheckClientKey(r)`. Any other callsite (greppable)?

### CODE-6. Comment quality
- The new `poolCheckClientKey` doc block enumerates the 3-tier priority (XFF → X-Real-IP → r.RemoteAddr) and the spoof-rejection rationale. Is the wording precise enough?
- The `ProxyConfig` config-side doc block mentions the security-sensitive nature of expanding TrustedProxies. Sufficient?

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
`specs/125_TRUSTED_PROXIES_CODE_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: code lane READY TO MERGE`
