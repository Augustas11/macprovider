# Codex re-audit (round 2) — verify the two fixes

Read the full diff `/Users/augstar/macprovider-poc/scratchpad/malibu-publish-fulldiff.patch` and the changed files under `/Users/augstar/macprovider-malibu-publish-generalize/`. Report findings only (C/H/M/L/INFO, file:line); do NOT edit.

Round-1 findings being verified:
1. (HIGH) acceptance-candidate placed without validation → FIX: `publish-malibu-latest-dmg.sh` now calls `acceptance-candidate-metadata.py verify` (ECDSA P-256, schema/channel, checksums.txt sha binding, 5m–24h non-expiry, tag/candidate_commit/compatibility_set_id pinned to this release) BEFORE any Pearl staging/transfer/swap; dies on failure. New negative test `test-malibu-acceptance-candidate-prepublish.sh`.
2. (MEDIUM) constant cache-bust key → FIX: `verify-malibu-bootstrap-publication.sh` now uses the per-release DMG sha (non-v1.8.39).

VERIFY:
- Is the acceptance-candidate validation truly BEFORE any remote transfer/swap, fail-closed, and does it actually bind tag+commit+checksums+expiry+signature (not just presence)? Any bypass (e.g. v1.8.39 branch, missing-file path, or the remote helper still trusting unvalidated bytes)?
- Is the per-release cache key correct and collision-free across releases?
- Any NEW defect introduced by these two edits (arg plumbing, quoting, the new test's stubs hiding a real gap)?
- Known/ignore: the 3 classifier-gated `test-release-security-posture.sh` assertions are intentionally not yet applied (that test fails at line 735) — not a code defect.

If 0 C/H/M, say so explicitly.
