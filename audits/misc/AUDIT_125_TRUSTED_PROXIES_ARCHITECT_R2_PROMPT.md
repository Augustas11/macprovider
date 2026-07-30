# Issue #125 trusted-proxy + XFF — ARCHITECT-lane R2 (closure verification)

Round 1 (`specs/125_TRUSTED_PROXIES_ARCHITECT_audit.md`) returned
**0 C/H / 1 MEDIUM (M1) / 3 LOW / 0 Q — NOT READY** (the MEDIUM
held the merge gate). The author applied targeted fixes for M1 + L2
+ L3; L1 was deferred per its own framing.

## Branch / commit
- Branch: `fix/coordinator-trusted-proxies-xff`
- Worktree: `../macprovider-125-trusted-proxies`
- Read: `git diff origin/main`

## Round-1 findings to verify closure on

- **M1 (MEDIUM, gate-holding).** Trusted-proxy policy was not
  discoverable from shipped operator docs/templates.
  - Fix expected:
    - Added `proxy:` block with `trusted_proxies: ["127.0.0.0/8",
      "::1/128"]` to BOTH `phase4-coordinator/coordinator.yaml.example`
      AND `phase4-coordinator/dist/coordinator.yaml.example` (the
      production template).
    - Added a normative source-IP-derivation paragraph to
      `specs/SPEC-002-coordinator.md` under the `/v1/pool/check` 429
      response block.
    - Added a `proxy.trusted_proxies` pointer to `specs/SPEC-015-receipts.md`
      under BOTH rate-limit mentions (§10.7 `/v1/receipt-keys` and the
      `/catalog/<catalog_id>` endpoint block).
- **L1.** Buyer/WS IP-helper asymmetry is deliberate but tracked as
  boundary debt.
  - Deferred per L1's own framing ("Leave the asymmetry for this
    PR"). The new `poolCheckClientKey` doc block explicitly defers
    unification to a future shared `httpip` helper (Option A from
    L1's recommendation).
- **L2.** Trusted-proxy membership repeated inside
  `rightmostUntrustedXFF` and `(s *Server).isTrustedProxy`.
  - Fix expected: extracted to package-level pure
    `isTrustedProxy(addr, trusted)`; both callers updated.
- **L3.** Startup parse fallback weakened the config validation
  contract (silent nil-fallback on parse error).
  - Fix expected: `mustParseTrustedProxies` now `logger.Fatal()`s on
    parse error instead of returning nil. Validate already rejects
    malformed CIDRs at config.Load, so this is a fail-fast on drift.

## Audit lenses for fresh issues (apply briefly)

- The SPEC additions (SPEC-002 + SPEC-015) — are they in the right
  sections? Is the wording precise enough for an implementer
  reading the spec alone to derive the same behavior?
- The YAML examples both now have a `proxy:` block. Confirm the
  block is identical / consistent between the two templates (no
  drift between dev and prod).
- The `isTrustedProxy` extraction — package-level pure function,
  single owner. Right altitude? (Not a Server method; takes the
  prefix slice explicitly.) Any callsite missed?
- The Fatal-on-parse-error change in main.go — operationally,
  a malformed `proxy.trusted_proxies` now refuses to boot. Is that
  the right contract? (vs. the prior silent-nil-fallback.) Recall
  Validate already catches malformed CIDRs at Load; this fail-fast
  is a drift defense.

## Output format

```
CLOSURE on round-1 findings:
  M1 (MEDIUM): PASS|PARTIAL|FAIL — <one line>
  L1: noted (deferred)
  L2: PASS|PARTIAL|FAIL — <one line>
  L3: PASS|PARTIAL|FAIL — <one line>

NEW FINDINGS (round 2):
CRITICAL (N): ...
HIGH (N): ...
MEDIUM (N): ...
LOW (N): ...
QUESTIONS (N): ...
```

Use CRITICAL/HIGH/MEDIUM/LOW. Write to
`specs/125_TRUSTED_PROXIES_ARCHITECT_r2_audit.md`.

If M1 closes AND L2/L3 close AND zero NEW C/H/M, end with:
`VERDICT: architect lane READY TO MERGE`
