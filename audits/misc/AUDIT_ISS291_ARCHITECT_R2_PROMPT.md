## Lane: ARCHITECT — Round 2

## Context

R1 outcomes:
- CODE 0/0/1/2
- SEC  0/0/1/2
- ARCH 0/0/1/1 — MED: fixture coverage sampled; LOW: deploy wiring pair-shaped

R1 fix-pass `14e9bb2` (ARCH-relevant slice):
- T09 rewritten with real ISSUED_FAIL + content ordering assertion
- T09b for HAVE-first + ISSUED_OK-second ordering
- T13a-T13e cover 5 additional prior-state × primary-role combos
  (RENEW+fail-primary, EXPIRED+fail-primary, RENEW+fail-nonprimary,
  EXPIRED+fail-nonprimary, BOTH-fail)
- 84 tests, was 46

## Your job

ARCHITECT LANE round 2. Verify coverage is now adequate for the
described 32-cell matrix (HAVE/RENEW/EXPIRED/MISSING × cert-ok/fail
× primary/non-primary). The R1 LOW (deploy wiring pair-shaped)
remains — evaluate whether it should upgrade or defer.

## Files in scope

- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/lib/pearl_tls.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/test/check_pearl_tls_test.sh`
- `/Users/augstar/macprovider-iss291/phase4-coordinator/dist/deploy-pearl-vps.sh`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss291 show HEAD`
