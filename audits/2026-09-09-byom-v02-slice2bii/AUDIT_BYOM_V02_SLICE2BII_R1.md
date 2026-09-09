# Audit R1 — BYOM v0.2 slice 2b-ii: artifact feed as a release asset

**Branch:** `feat/byom-v02-slice2bii-artifact-feed-release-assets` (off main; rebased onto `bd2fc510` after slice 2b merged)
**Date:** 2026-09-09 / 2026-09-10
**Prompt:** `audits/2026-09-09-byom-v02-slice2bii/AUDIT_BYOM_V02_SLICE2BII_PROMPT.md`
**Authority:** SPEC-023 v0.10.0 §3.7.2 (fallback = snapshot compiled into the CLI), §3.7.6 rule 6, §3.7.8 Stage A.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R1 verdicts (first shape: pair as provider-payload member + artifact-index roles)

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 4 HIGH / 1 MEDIUM / 1 LOW |
| security-reviewer | 0 CRITICAL / 0 HIGH / 3 MEDIUM / 0 LOW / 1 INFO |
| architect | 0 CRITICAL / 1 HIGH / 3 MEDIUM / 1 LOW |

## What R1 established — a design correction, not a patch

The first shape put the pair inside the provider payload's `catalog-release/`
and added it as optional `compatibility-artifact-index` roles. The lanes showed
both are Stage A violations of exactly the class §3.7.8 exists to prevent:

- **Architect HIGH.** The deployed Swift updater requires the artifact index's
  EXACT seventeen roles (`CompatibilitySetManifest.swift`) and validates the
  index before preparing an update; a nineteen-role index fail-closes every
  installed updater before the new binary can run.
- **Code HIGHs.** The installer's `validate_staged_entries`, the Tier-2
  provider-artifact validators (release preflight and published-release
  verification), and the promotion validator all enforce the exact nine-name
  `catalog-release/` set or a fixed inventory; an eleven-member tarball is
  rejected on every one of them.
- **Security MEDIUMs / code+architect MEDIUMs.** Binding decisions were taken
  from secondary metadata (`pearl-release.json` keys, supplied index mappings)
  rather than from `release.json`; Pearl GitHub mode never downloaded the
  pair; fixtures never ran an artifact-bound release through the real paths.

## Resolution (second shape — this branch as pushed for R2)

The pair is a **GitHub release asset only**, bound by `release.json` (the sole
authority) and `pearl-release.json` `catalog.files`, and the CLI's fallback is
the snapshot compiled into the binary (§3.7.2; slice 2c bakes it):

- Reverted to main: `compatibility-artifact-index.py` (seventeen roles stay
  exact), `package.sh` (the tarball never carries the pair), the artifact-index
  test.
- Provider-payload validators (`acceptance-candidate-metadata.py`
  `validate-provider-payload`, `compatibility-set-manifest.py`
  `validate_payload_artifacts`) keep the exact nine names and name the pair
  explicitly when they see it ("not a provider-payload member at Stage A").
- Acceptance path: the unsigned build boundary (`verify-unsigned`) is exact in
  both directions — an artifact-bound provider archive (its archived
  `catalog-release/release.json` binds the feed) must be accompanied by the
  pair as unsigned inputs, a rate-card-bound one must not be;
  `acceptance-candidate.yml` captures them from the candidate checkout;
  `sign-acceptance-candidate.sh` installs them from the verified unsigned
  inputs and appends them to `release_assets` (checksums, provenance,
  `release-assets.txt`) — never to the artifact-index mappings.
- `release.yml` (direct publish path): the pair is copied from
  `phase3-binary/dist/static/` into the release assets and bound in
  `pearl-release.json` `catalog.files` when `release.json` binds it; no tar
  member cases, no index arguments. Every shell run block in both workflows
  passes `bash -n`; the release posture test's exact capture-step constant is
  regenerated.
- `verify-acceptance-promotion.py`: inventory and Pearl catalog set widened
  exactly when the accepted `release.json` binds the feed; an unbound pair in
  the selector is named.
- `verify-pearl-runtime-release.sh`: binding read from `release.json`;
  `pearl-release.json` must agree in both directions; GitHub mode downloads
  (and requires) the pair exactly when bound.
- `catalog-release.py status`: a new pending row names the coordinator deploy
  (`deploy-pearl-vps.sh` stages nine files, and `verify-directory` rejects a
  five-feed `release.json` beside them), and the pending-surface test probes
  it; runbook rows corrected (payload row "resolved: not a member").

## Validation after the rework

- All fourteen release/acceptance/Pearl/gate/catalog shell suites: ok
- `scripts.tests.test_catalog_artifact_feed` + `test_spec_governance`: 181 tests, OK
- `catalog-release.py verify`: committed release unchanged
- `bash -n` over all 51 workflow run blocks: 0 errors
- `git diff --check`: clean

R2 re-fires all three lanes on the reworked diff.
