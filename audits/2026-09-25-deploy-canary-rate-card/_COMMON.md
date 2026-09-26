# Codex audit: deploy exact-byte catalog canary expects the signed rate card (#1746)

Method constraint: this is a first-party software-correctness review. Read the
source and run EXISTING tests only. Do NOT construct malformed payloads;
describe any gaps abstractly in prose.

Worktree: `/Users/augstar/macprovider-canary-ratecard`. Branch:
`fix/deploy-canary-rate-card-bytes`. Review `git diff origin/main...HEAD`.

## The change
- **The bug.** `phase4-coordinator/dist/deploy-pearl-vps.sh`
  `run_catalog_canary_mac_proof` hashes nine `catalog-release` files on the
  canary Mac, `rate-card.json` and `rate-card.json.sig` included. The
  exact-byte check after the pool-check loop built `expected` from only seven
  pinned files, so `actual != expected` was always true.
- **The fix.** `$STATIC_RATE_CARD_JSON` and `$STATIC_RATE_CARD_SIG` (the
  pinned `phase3-binary/dist/static` files) are passed to that check.
- **The test.** `check_deploy_static_feed_access.test.sh` used to require
  Tier-2 directly after the demand-rank sidecar, which encoded the gap. It now
  parses both sides and asserts the sets are equal.

## Gate
0 CRITICAL, 0 HIGH, 0 MEDIUM. Report findings with file:line, a concrete
failure scenario, and a fix. Do not manufacture findings. End with
`VERDICT: PASS` or `VERDICT: FAIL (C/H/M counts)`.
