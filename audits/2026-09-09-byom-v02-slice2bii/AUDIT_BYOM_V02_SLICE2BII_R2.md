# Audit R2 — BYOM v0.2 slice 2b-ii (release assets half, before the deploy/renewal half joined the branch)

**Diff reviewed:** the three-commit release-asset rework (`1e0dc2f0`, `949bf3b7`, `ebce81d9`) on main `bd2fc510`.
**Merge bar:** 0 CRITICAL / 0 HIGH / 0 MEDIUM across all three lanes.

## R2 verdicts

| Lane | Verdict |
|---|---|
| code-reviewer | 0 CRITICAL / 3 HIGH / 1 MEDIUM / 1 LOW |
| security-reviewer | 0 CRITICAL / 0 HIGH / 2 MEDIUM |
| architect | 0 CRITICAL / 2 HIGH / 1 MEDIUM |

All lanes confirmed the Stage A shape itself (release asset only; never a
payload member or index role; `release.json` as the binding authority) and
that R1's fleet fail-close findings are moot under it. The remaining findings
were producer-path gaps, all resolved in the commit that adds this record:

- **HIGH (code, architect; security MEDIUM):** the acceptance signer ran
  `verify-directory` on the nine-file payload, which reconstructs a four-feed
  manifest and rejects a five-feed `release.json`. Now it verifies a separate
  catalog directory holding the nine payload files plus the verified unsigned
  pair, so the pair's digest, sidecar signature, and signer equality are
  authenticated before anything is signed. Pinned by
  `test_verify_directory_needs_the_pair_beside_a_five_feed_manifest`.
- **HIGH (code, architect; security MEDIUM):** the release workflow's three
  unsigned-manifest reconstructions (promoted restore, provider-runtime
  verification, signing) listed only the six original assets, so an
  artifact-bound promotion failed the `cmp`. Each now re-derives the binding
  from the provider archive itself and appends the pair (requiring both files).
- **HIGH (code):** downstream consumers only decided presence from
  `release.json` and never checked the pair's bytes against its record. Now
  `verify-unsigned`, `build-pearl`, the promotion validator, the Pearl runtime
  verifier, and the direct publish path all require the feed's sha256 and byte
  length to equal `release.json`'s binding (tamper fixtures in the acceptance,
  promotion, and Pearl suites).
- **MEDIUM (architect):** Pearl GitHub mode accepted a present-but-unbound
  published pair; it now rejects it from the release asset list.
- **MEDIUM (code):** fixtures now carry real digest records and exercise the
  corrected producer paths; the security suite's assertion follows the
  signer's new verification directory.
- **LOW (architect):** the runbook table now carries the coordinator-deploy
  and renewal rows (both landed with the deploy/renewal half on this branch).

R3 runs all three lanes over the FULL combined diff (release assets + deploy +
renewal + these fixes).
