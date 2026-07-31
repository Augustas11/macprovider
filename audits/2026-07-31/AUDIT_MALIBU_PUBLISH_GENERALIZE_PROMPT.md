# Codex audit — generalize Malibu download promotion off the v1.8.39 freeze

Read the full diff `/Users/augstar/macprovider-poc/scratchpad/malibu-publish-fulldiff.patch` and the changed files under `/Users/augstar/macprovider-malibu-publish-generalize/`. Report findings only (C/H/M/L/INFO, file:line, concrete failure scenario); do NOT edit.

## Context (money-path, signature-enforced, install-breaking-if-wrong release infra)
The Malibu download promotion was hard-locked to the one-time v1.8.39 Sparkle bootstrap. This change lifts the tag-locks so any stable vX.Y.Z can be promoted to download.malibu.tech, ships a COMMITTED frozen bridge appcast (`scripts/dist/malibu-frozen-bridge-appcast.xml`, sha `94ecf575...`, pinned as a constant in `install-malibu-publication.sh`) for non-v1.8.39 so the `/appcast.xml → .malibu-current/appcast.xml` symlink keeps resolving, keeps appcast GENERATION frozen, and wires the signed acceptance-candidate (`acceptance-candidate.json[.sig]`, produced by `acceptance-candidate.yml`, ecdsa-p256) into publish + the remote root install helper so it lands in the promoted `.malibu-releases/<id>/` dir under the same atomic/immutable checks. The install path `die 4`s without a valid acceptance-candidate.

## Focus
1. **Remote root helper `install-malibu-publication.sh`**: the acceptance-candidate present/absent gating (non-v1.8.39 requires the pair, v1.8.39 forbids it), name/mode/owner/symlink checks, inclusion in the atomic `.malibu-current` swap + immutable `cmp` set. Any path that promotes a dir MISSING a valid acceptance-candidate, or that breaks the atomicity/rollback.
2. **Frozen appcast pin**: the constant `FROZEN_APPCAST_SHA256` vs the committed file — any drift risk not covered by `test-malibu-bootstrap-bridge.sh`; the deliberately-SKIPPED Sparkle enclosure-vs-DMG cross-check for non-v1.8.39 (replaced by a byte-compare to the committed appcast) — is that a real integrity gap?
3. **Tag-lock lifts** in publish-malibu-latest-dmg.sh / verify-malibu-publication-set.sh / verify-malibu-bootstrap-publication.sh / release.yml: any check weakened beyond the intended tag-equality removal? Does the non-v1.8.39 path still bind dmg + manifest + provenance + checksums as strongly as v1.8.39?
4. **release.yml**: the generalized publish step gates on `prerelease == 'false'` but skips (::notice::) when the acceptance-candidate isn't in the build workspace (it's produced ~24h post-build). Is the skip fail-safe (never publishes an un-accepted release), and is there any path where it publishes without the acceptance-candidate?
5. Anything that could break installs for ALL users (die-4, broken symlink, wrong sha) if this promoted a real release.

Note: 3 assertion updates in `test-release-security-posture.sh` are intentionally NOT yet applied (classifier-gated); that test currently fails at line 735 — do not report that as a code defect, but DO assess whether the intended new assertions are the right ones.
