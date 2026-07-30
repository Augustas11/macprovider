# Audit: ISS-165 R5 security lens — verify R4 closures

R4 returned 0/1/1/0. R5 verifies on `b7221a7`.

## R4 sec findings to verify

- **HIGH** (convergent w/ code): keyset query lacked matching
  index + scan-ceiling off-by-one. Fix: migration 0013 + chunkLimit
  clamp.
- **MEDIUM**: no build-time CI sync for event names across SPEC
  §7.1 + §9 + runbook. Fix: deferred to v0.2 via Appendix B note
  (`#165 R4 sec MEDIUM closure`).

## What I want (R5 security lens)

Final convergence pass. Expect 0/0/0/N.

- Adversarial inflation now bounded by index + ceiling? With the
  partial index in place, `EXPLAIN QUERY PLAN` should report a
  direct index scan; verify the assertion.
- The CI-sync MEDIUM was deferred to v0.2. Is that an acceptable
  trade-off, or is the drift risk high enough to demand a
  per-release manual checklist?
- Any other money-path security defect introduced by the R4 fixes?

Severity + Convergence line. NO FIX PASS on 0/0/0/N.
