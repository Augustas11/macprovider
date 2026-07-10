## Lane: SECURITY — Round 1

## Context

#290 ports the coordinator deploy hardening (PR #289, 8 audit rounds)
to `phase5-gateway/dist/deploy-pearl-vps.sh` for symmetry.

R1 IMPL landed as `656abee`. Changes:

1. Per-deploy `$DEPLOY_TMP` staging via `umask 077 && mktemp -d`
   with unconditional EXIT-trap cleanup.
2. Binary + `.prev` installed as `root:macprovider 0750` (was
   `macprovider:macprovider 0755`).
3. Bypass tombstone via remote `mktemp` under `umask 077` instead
   of predictable `/tmp/last-deploy-bypass.json`.
4. DOMAIN + EMAIL validated up front.
5. Rollback docs updated in printed rollback + OPS.md.
6. bash 3.2 compat verified.
7. OPS.md TODO line removed.

## Your job

SECURITY LANE round 1. This is a security-sensitive deploy script.
Key focus areas:

- Verify all threat classes closed by #244 R5 CRITICAL are equally
  closed on this side: SCP race, .prev ownership, tombstone predictable
  path.
- Are there gateway-specific paths NOT covered by the #244 template?
  (E.g. gateway.db snapshot, nginx site path.)
- EXIT-trap correctness: is DEPLOY_TMP guaranteed cleaned up?
- Any bash 3.2 compat issue?
- Any gateway-specific gap the coordinator template didn't address?

Standard severity-graded findings.

## Files in scope

- `/Users/augstar/macprovider-iss290/phase5-gateway/dist/deploy-pearl-vps.sh`
- `/Users/augstar/macprovider-iss290/OPS.md`

Reference (already-hardened counterpart):
- `/Users/augstar/macprovider-iss290/phase4-coordinator/dist/deploy-pearl-vps.sh`

R0→R1 diff: `git -C /Users/augstar/macprovider-iss290 show HEAD`
