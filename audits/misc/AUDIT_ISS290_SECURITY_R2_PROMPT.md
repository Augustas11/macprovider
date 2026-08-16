## Lane: SECURITY — Round 2

## Context

R1 outcomes:
- CODE 0/1/0/1 (HIGH DOMAIN + LOW OPS.md prose)
- SEC  1/1/1/0 (CRITICAL DB chown race + HIGH parent-dir + MED DOMAIN)
- ARCH 1/1/2/0 (same CRITICAL + HIGH + 2 MED)

R1 fix-pass landed as `634de32`:
1. DB snapshot now runs ENTIRELY as macprovider under `umask 077` —
   no root chmod/chown on daemon-writable paths. Closes CRITICAL.
2. New step 2b enforces `/opt/macprovider` root:macprovider 0750
   idempotently — closes state-dependent HIGH.
3. `DOMAIN != api.malibu.tech` refused early — closes MED.
4. OPS.md step-by-step bullets rewritten to match current flow.

## Your job

SECURITY LANE round 2. Re-audit convergence and look for remaining gaps.

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

Reference (already-hardened counterpart):
- `/Users/augstar/macprovider-iss290/phase4-coordinator/dist/deploy-pearl-vps.sh`

R1→R2 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
