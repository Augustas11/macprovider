# PR #1945 Codex audit round 3

Head ad5d90bd2. All three lanes 0 C/H/M. Carried LOWs: disclosure text defined in three modules; k_anonymity_min equality-only type check in the pool-proven frame parser.

=================== architecture
```text
Architecture gate: **PASS — 0 CRITICAL, 0 HIGH, 0 MEDIUM; 1 carried LOW** at `ad5d90bd2`, reviewing the complete `origin/main...HEAD` diff.

- **LOW — Duplicated disclosure vocabulary (carried).** [policy.go:85](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/trustpool/policy.go:85). A future text change can make policy/status disagree with buyer disclosure or gateway validation. Buyer/gateway duplication is **pre-existing**; this PR adds another definition. **Fix:** share coordinator constants and verify gateway agreement through a common contract fixture.

R1/R2 fixes verified: complete-response draining, exact probe-policy validation, verified-label counting, cached owner/entry resolution, deadline rejection before publication, current-policy refresh currency, source chronology, type-exact re-derivation, independently released reference-counted probe holds, and memory-store newest-by-evaluation-time selection.

Billing and trustpool retain ownership of their queries despite the shared database handle. Existing coordinator wiring supplies the sources and refresh lifetime. SPEC/CONFORMANCE changes agree with the implementation. SPEC-047-R003’s global loopback exclusion and SPEC-023 §16.9’s separate recommendable-promotion requirements remain structurally enforced.

Validation: **17 targeted existing Go tests and all 22 intake-manifest tests passed**. Coverage still lacks actual overlapping HTTP-handler execution, refresh-loop integration, and deadline expiry during final aggregation. `git diff --check origin/main...HEAD` passed.

No files edited, live hosts contacted, or new malformed payloads constructed.

C/H/M/L = 0/0/0/1
```

=================== security
```text
Security gate: **PASS — 0 C/H/M, 1 carried LOW**, reviewing the complete `origin/main...HEAD` diff at `ad5d90bd2`.

- **LOW — Carried disclosure-text duplication.** [policy.go:85](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/trustpool/policy.go:85). Independent definitions can drift, making creator policy/status disagree with buyer or gateway disclosure. Buyer/gateway duplication is **pre-existing**; this PR adds another definition. **Fix:** share coordinator constants and verify gateway agreement with a common contract fixture.

Round 1 and 2 fixes verified: independently released probe holds, evaluation-time ordering, complete-response draining, exact probe-policy validation, verified-label accounting, cached owner resolution, deadline rejection, source chronology, and type-exact retained-value comparison.

No additional owner-count inflation, probe-record forgery or cross-pair linkage, provider-endpoint dereference, operator-access bypass, or global paid-routing/loopback-settlement bypass found. Graduation remains listing-only.

Validation passed: targeted existing WS, billing, trustpool, and buyer tests; all **22 intake-manifest tests**. Coverage still lacks concurrent HTTP-handler and refresh-loop integration tests, and deadline expiry during final aggregation.

No files edited, live hosts contacted, or malformed payloads constructed.

C/H/M/L = 0/0/0/1
```

=================== code
```text
CODE gate passes at `ad5d90bd2`: no CRITICAL, HIGH, or MEDIUM findings. Reviewed the complete `origin/main...HEAD` diff and verified the R1/R2 fixes.

1. **LOW — Integer type not enforced.** [catalog-release.py:4697](/Users/augstar/macprovider-catalog-graduation/scripts/catalog-release.py:4697)
   `k_anonymity_min` uses equality-only validation, accepting a floating-point value equal to 3 despite the integer requirement. Suppression floors remain enforced, but closed-schema validation weakens. **Fix:** apply `_intake_int` before comparing with the fixed floor; add regression coverage. The analogous validation pattern is **pre-existing**; this validator is new.

2. **LOW — Disclosure-text duplication, carried R1 finding 5.** [policy.go:85](/Users/augstar/macprovider-catalog-graduation/phase4-coordinator/internal/trustpool/policy.go:85)
   A future text update can leave policy/status disclosure inconsistent with buyer/gateway disclosure. Buyer/gateway duplication is **pre-existing**; this PR adds another definition. **Fix:** share coordinator constants and verify gateway agreement through a common fixture.

Validation passed: 17 focused existing Go tests, all 22 intake-manifest tests, and diff whitespace checking. Coverage still lacks concurrent HTTP-handler integration, a complete refresh pass, and deadline expiry during final aggregation. Global loopback exclusion remains enforced.

No source edits or live-host access.

C/H/M/L = 0/0/0/2
```
