# #1690 M8 audit: round 2 addendum

**READ-ONLY.** Do NOT run builds, package resolves, or tests on this machine.

**Focus diff:** `git diff f44e5ef6 HEAD`, which is M8 plus its round-1 fix commit `ed2474cd`. The common brief (`AUDIT_1690_M8_COMMON.md`) applies.

**Round-1 fixes to verify** (the findings files are not on the branch; this is the summary):
- **CODE H1:** `discoverIncludingMLXLM` / `evaluateIncludingMLXLM` extend discovery and evaluation to mlxlm without editing evidenced runner bodies.
- **CODE H2:** `models offer` resolves the target (candidate ID, served ref, or display name) before dispatch, so the generic `submitOffer` can never build a hashless mlxlm offer.
- **CODE H3 / SECURITY M1:** `proxy()` re-validates `identityIsValid()` and the `/v1/models` binding before every upstream call, streaming included.
- **CODE M4:** hashing uses one `O_NOFOLLOW` descriptor per file, with size, inode, mtime and ctime checked before and after the read, and the listing re-read at the end. The digest format is unchanged.
- **ARCH M1:** SPEC-023 v0.17.1. The release generator and the release-dir verifier refuse `mlxlm_loopback` artifacts while `ARTIFACT_FEED_CONSUMER_FLOOR` is below v0.17.0.

**Check:**
- that each round-1 finding is resolved;
- that the fixes introduced no new defects;
- that M8 still upholds the common-brief invariants.

Report only real defects at their true severity. End with `VERDICT: <c> CRITICAL / <h> HIGH / <m> MEDIUM / <l> LOW`.
