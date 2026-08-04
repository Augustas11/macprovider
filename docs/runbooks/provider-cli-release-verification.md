# Provider CLI release verification

This runbook covers release/updater correctness only. Keep product-specific
smokes, such as Buzz tool-schema/null behavior, in a separate QA checklist.

## Hard release invariants

- The standalone tarball CLI and the Malibu.app embedded CLI must be the same
  bytes after final signing, notarization, stapling, and packaging.
- The updater must accept the release from the previous stable CLI.
- Candidate workflow success is not production verification.
- Public release assets are immutable; do not patch a bad release in place.

## Candidate release gate

Run the candidate workflow from `main`:

```bash
gh workflow run release.yml \
  --ref main \
  -f version=vX.Y.Z \
  -f candidate=true \
  -f prerelease=false \
  -f provider_admission_policy=strict_post_migration
```

Pre-approval evidence:

- build job succeeds
- arm64 verification succeeds
- `sign_publish` parks for approval

Protected candidate evidence, if intentionally approved for a dry-run signing
check:

- `Verify Malibu release cryptographic bindings` ran
- `scripts/verify-malibu-release-artifacts.sh` compared the Malibu embedded
  CLI with the standalone provider tarball

Do not approve candidate `sign_publish` unless intentionally testing protected
publication/signing behavior.

## Production release gate

1. Create the signed annotated tag on the intended `main` commit.
2. Run `release.yml` with `candidate=false`.
3. Approve the production-release environment only from the owner account.
4. After publication, download the immutable assets and verify checksums and
   signatures.
5. Treat the coordinator rollout as two phases:
   - before publication, the signed feed bytes, keyring, and coordinator
     health version are checked while the recommendation may remain on the
     previous stable CLI;
   - after publication and the immutable byte-identity check, have the Pearl
     owner bump `recommended_binary_version` to the published CLI, then
     dispatch `verify-live-coordinator-release-rollout.yml`. That workflow
     requires the exact post-publication gate before publishing the
     append-only discovery transport.
6. Verify the Malibu artifact against the standalone provider tarball:

```bash
bash scripts/verify-malibu-release-artifacts.sh \
  Malibu-vX.Y.Z.dmg \
  --provider-tarball macprovider-cli-vX.Y.Z-darwin-arm64.tar.gz
```

7. Verify local updater acceptance from the previous stable CLI:

```bash
macprovider-cli update --check
macprovider-cli update
macprovider-cli --version
macprovider-cli status --advanced
```

If the updater returns `embedded_cli_mismatch`, the release is not
production-verified. Keep the coordinator recommendation on the previous
stable version and cut a new release with matching artifacts.

## Hardware-evidence schema rollout ordering

The `hardware_evidence.autotune.v2` envelope is coupled to provider CLI
`v1.8.82` or newer. Roll it out in this order:

1. Deploy the coordinator handler/verifier that accepts the v2 protocol and
   leave `proof_of_weights.require_autotune_hello_gate` disabled.
2. Publish and install the signed provider release, then run the real-Mac
   autotune benchmark and confirm the resulting job reaches `verified`.
3. Confirm a joined canary is routable with the exact model/artifact and
   catalog-row bindings before enabling the strict hello gate or raising a
   hard binary floor.

The checked-in coordinator examples remain on the previous stable
recommendation (`1.8.81`) until the signed `1.8.82` provider assets are
published and the embedded CLI byte-identity check passes. The v2 handler may
be deployed ahead of that release, but the coordinator must not advertise an
unpublished version. Once the v2 handler is active, v1 hardware-evidence
submissions are no longer accepted for refresh; those providers must upgrade
to the signed v1.8.82 release before they can renew admission evidence.

The release workflow's staged version-cohesion exception is bound to the exact
`--staged-candidate=1.8.82` release. A later release must update both the
previous-stable and staged-candidate values; the guard rejects an unbound
candidate.

After immutable publication, deploy Pearl's recommendation update, then
dispatch `.github/workflows/verify-live-coordinator-release-rollout.yml` with
the public tag. The workflow verifies the immutable GitHub release, requires
the live coordinator to advertise the exact release, publishes the signed
append-only discovery transport, and proves anonymous discovery from the new
CLI.

Do not enable the strict gate while the fleet still contains providers that
cannot produce v2 evidence. A coordinator deployment that has not yet
accepted v2 must remain on the previous provider recommendation.

## What not to count as release proof

- matching `macprovider-cli --version`
- matching codesign designated-requirement text
- Gatekeeper acceptance alone
- notarization/stapling alone
- simple local chat/completions curl
- product-specific Buzz smoke tests
