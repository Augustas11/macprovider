# Issue #125 trusted-proxy + X-Forwarded-For — ARCHITECT-lane audit

You are the **architect** lane of a three-lane audit (code / security /
architect) of the trusted-proxy + XFF refactor for issue #125. Stay
narrowly in your lane.

The architect lens cares about: module boundaries, single source of
truth, abstraction altitude, coupling, future-evolution constraints,
cross-spec consistency, anti-pattern entrenchment.

## Branch / commit
- Branch: `fix/coordinator-trusted-proxies-xff`
- Worktree: `../macprovider-125-trusted-proxies` (origin/main base: d27aac5)
- Files in scope (`git diff origin/main`).

## What this change does (operator summary — NOT the audit answer)

Issue #125 generalizes PR #124's loopback-only X-Real-IP fix to:
1. Configurable trusted-proxy CIDR set via `proxy.trusted_proxies`.
2. X-Forwarded-For rightmost-untrusted-hop parsing for chained
   trusted proxies.
3. Spoof rejection for untrusted callers (forwarded headers ignored).

## Architect-lane scope (apply each; stay in lane)

### ARCH-1. Module boundaries — config / buyer / WS
- The new `ProxyConfig` lives in `config.Config` (top-level).
  `TrustedProxyPrefixes()` parses to `[]netip.Prefix`. The buyer
  Server consumes it via `WithTrustedProxies(prefixes)`.
- The PARALLEL `ws.remoteIPForUnauthSemaphore` (admission semaphore
  for unauth WS handshakes; M1-4 SECU-1) still implements the narrow
  loopback-only X-Real-IP path. The diff preserves this asymmetry.
  Is that intentional, or is the WS-side helper now stale?
- If both sides should share a helper, where should it live?
  - Option A: `internal/httpip` new package — both buyer + ws import.
  - Option B: move ws helper into a shared utility under
    `internal/sqliteutil`-style mid-level package.
  - Option C: leave both narrow; document the asymmetry with a
    pointer.
- Recommend the right resolution. (Author's note: the comment in
  the new poolCheckClientKey doc block explicitly defers a future
  unify-PR; verify the comment is adequate.)

### ARCH-2. Abstraction altitude of the new helpers
- `rightmostUntrustedXFF(header, trusted)`: package-level function;
  takes a string + a slice. Pure function — easy to test in
  isolation.
- `isTrustedProxy(addr)`: `(s *Server)` method, but takes only
  `s.trustedProxies`. Could be a pure function too. Is the method
  receiver right, or should it be a package-level
  `isTrustedProxy(addr, trusted)`?
- `poolCheckClientKey(r)`: `(s *Server)` method, consumes `r` and
  `s.trustedProxies`. Method-on-Server is appropriate because the
  derived key feeds Server-owned state (the rate-limit buckets).

### ARCH-3. Config shape
- New top-level `proxy` block in `config.Config`. Could have lived
  under `listen` (ListenConfig) since it's listener-policy. Could
  have lived under a new `security` block grouping spoof-related
  settings. Recommend if a different home would be more discoverable.
- Default value `["127.0.0.0/8", "::1/128"]` — sane default. Does
  the SPEC documentation (SPEC-002 or SPEC-005) call out this
  policy anywhere? Should it?

### ARCH-4. Future-evolution constraints
- The current shape assumes a single trusted-proxy CIDR set per
  coordinator. If a future deployment has multiple proxy tiers
  (e.g. CDN → LB → nginx → coordinator), the rightmost-untrusted
  walk handles it as long as ALL hops are in the trusted set.
  Does that scale, or is per-hop trust required (i.e. "trust the LB
  but NOT the CDN")?
- The current shape returns a single bucket key (string) per
  request. If a future feature wants per-CIDR aggregate buckets
  (issue #125 option (c)), the helper would need to return a
  prefix-aware key. Is the current return-string-only shape a
  premature commitment?

### ARCH-5. New surface area cost
- ~233 lines added across config + buyer + main. Roughly:
  - config.go: 60 lines (ProxyConfig + TrustedProxyPrefixes + Validate call)
  - server.go: 110 lines (rightmostUntrustedXFF + isTrustedProxy + ProxyOption + constructor wiring + poolCheckClientKey rewrite)
  - trusted_proxies_test.go: 175 lines (11 new tests)
  - main.go: 19 lines (mustParseTrustedProxies + WithTrustedProxies wiring)
- Is the surface area worth it for an issue rated LOW (production case
  was already covered by PR #124's partial fix)? Or should this PR
  scope shrink — e.g. ship the trusted-proxy CIDR config + the
  loopback-only XFF preservation, defer the multi-hop XFF + spoof
  test matrix to a follow-up?

### ARCH-6. Cross-spec consistency
- Does SPEC-002 (coordinator) or SPEC-005 (billing) document the
  rate-limit policy on these endpoints? Is the new trusted-proxy
  surface worth a normative note? The endpoints in question
  (`/v1/pool/check`, `/v1/receipt-keys/*`, `/catalog/*`) are
  documented in SPEC-002 v1.4 + SPEC-015 v0.3 — does either spec
  call out the per-source rate-limit primitive, and if so, should
  it be updated to reference `proxy.trusted_proxies`?

### ARCH-7. Doc-trail / audit ledger
- Should `audits/2026-06-10/REMAINING_WORK.md` (or any other
  ledger) be updated to reflect this fix?

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
`specs/125_TRUSTED_PROXIES_ARCHITECT_audit.md`.

If 0 CRITICAL/HIGH/MEDIUM, end with:
`VERDICT: architect lane READY TO MERGE`
