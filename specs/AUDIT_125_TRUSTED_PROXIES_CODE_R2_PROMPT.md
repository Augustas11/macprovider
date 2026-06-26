# Issue #125 trusted-proxy + XFF — CODE-lane R2 (closure verification)

Round 1 (`specs/125_TRUSTED_PROXIES_CODE_audit.md`) returned
**0 C/H/M / 4 LOW / 0 Q — READY TO MERGE**. The author applied
targeted fixes for 3 of the 4 LOWs + most of the cross-lane LOWs.
Verify closure + flag any NEW issue introduced.

## Branch / commit
- Branch: `fix/coordinator-trusted-proxies-xff`
- Worktree: `../macprovider-125-trusted-proxies`
- Read: `git diff origin/main`

## Round-1 findings to verify closure on

- **L1.** `ProxyConfig` comment referenced a nonexistent config test
  (`TestDefaultProxyConfigTrustsLoopbackOnly`).
  - Fix expected: either remove the test-name claim or actually add the
    test. The author DID add the test (config_test.go) and updated the
    comment to drop the dangling reference.
- **L2.** `rightmostUntrustedXFF` comment said
  `netip.ParseAddrPort` but the code uses `net.SplitHostPort`.
  - Fix expected: comment updated.
- **L3.** XFF edge cases (whitespace, empty hops, only commas) not
  pinned by tests.
  - Fix expected: new tests added in trusted_proxies_test.go.
- **L4.** X-Real-IP accepts raw string including value-with-port.
  - Fix expected: X-Real-IP now parsed via `netip.ParseAddr` →
    canonical `addr.String()`; port-bearing or junk values fall
    through to r.RemoteAddr. (This also closes the security-lane L1.)

## Audit lenses for fresh issues (apply briefly)

- The new X-Real-IP `netip.ParseAddr` canonicalization changes the
  bucket key for any pre-existing test or production case that
  passed an X-Real-IP value that ParseAddr-doesn't-accept. The
  TestCatalogEndpointRateLimitedPerXRealIPBehindLoopback existing
  test uses bare IP literals — confirm it still passes.
- The package-level `isTrustedProxy(addr, trusted)` refactor (was a
  `(s *Server)` method) — both callers updated? grep for any stale
  `s.isTrustedProxy`.
- New config-side tests in config_test.go — do they exercise the
  Validate path AND the TrustedProxyPrefixes path?

## Output format

```
CLOSURE on round-1 findings:
  L1: PASS|PARTIAL|FAIL — <one line>
  L2: ...
  L3: ...
  L4: ...

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/125_TRUSTED_PROXIES_CODE_r2_audit.md`.

If all findings closed AND zero NEW C/H/M, end with:
`VERDICT: code lane READY TO MERGE`
