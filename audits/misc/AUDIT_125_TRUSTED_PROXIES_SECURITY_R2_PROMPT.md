# Issue #125 trusted-proxy + XFF — SECURITY-lane R2 (closure verification)

Round 1 (`specs/125_TRUSTED_PROXIES_SECURITY_audit.md`) returned
**0 C/H/M / 2 LOW / 1 Q — READY TO MERGE**. The author applied
targeted fixes.

## Branch / commit
- Branch: `fix/coordinator-trusted-proxies-xff`
- Worktree: `../macprovider-125-trusted-proxies`
- Read: `git diff origin/main`

## Round-1 findings to verify closure on

- **L1.** X-Real-IP fallback stored a trusted header value WITHOUT
  IP parsing / canonicalization.
  - Fix expected: X-Real-IP is now parsed via `netip.ParseAddr`;
    success returns `addr.String()` (canonical form), failure falls
    through to r.RemoteAddr. Port-bearing values (`1.2.3.4:8080`)
    fail to parse and fall through.
- **L2.** `Validate` accepted universal trusted-proxy CIDRs
  (`0.0.0.0/0`, `::/0`).
  - Fix expected: `TrustedProxyPrefixes` now rejects prefixes with
    `Bits() == 0` at parse time; `Validate` rejects them at startup.
    Config-side tests added.
- **Q1.** WS unauth semaphore parity — flagged as a follow-up
  question. The new poolCheckClientKey doc comment explicitly defers
  unification to a future shared `httpip` helper. No fix in this
  PR; verify the deferral is documented.

## Audit lenses for fresh issues (apply briefly)

- Does the X-Real-IP canonical-form change introduce any spoof
  surface? E.g. an attacker who sends a different non-canonical form
  of an IP they want to share a bucket with — but addr.String() is
  injective on valid IPs (only one canonical form per IP), so all
  representations of the SAME IP collapse to the same key (good —
  this is actually a hardening).
- Default-route rejection: `0.0.0.0/0` and `::/0` (both Bits() == 0)
  rejected. Any OTHER class of "obviously unsafe" prefix? E.g.
  `0.0.0.0/1` covers half the IPv4 space. Should the rejection
  threshold tighten further (e.g. require >=/8), or is the
  default-route guard sufficient?
- Validate failure modes: `mustParseTrustedProxies` in main.go now
  Fatals on parse error. Defensive against drift between Validate
  and TrustedProxyPrefixes. Confirm.

## Output format

```
CLOSURE on round-1 findings:
  L1: PASS|PARTIAL|FAIL — <one line>
  L2: PASS|PARTIAL|FAIL — <one line>
  Q1: noted (deferred to follow-up)

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/125_TRUSTED_PROXIES_SECURITY_r2_audit.md`.

If all addressed findings closed AND zero NEW C/H/M, end with:
`VERDICT: security lane READY TO MERGE`
