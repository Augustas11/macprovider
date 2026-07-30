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
5. Verify the Malibu artifact against the standalone provider tarball:

```bash
bash scripts/verify-malibu-release-artifacts.sh \
  Malibu-vX.Y.Z.dmg \
  --provider-tarball macprovider-cli-vX.Y.Z-darwin-arm64.tar.gz
```

6. Verify local updater acceptance from the previous stable CLI:

```bash
macprovider-cli update --check
macprovider-cli update
macprovider-cli --version
macprovider-cli status --advanced
```

If the updater returns `embedded_cli_mismatch`, the release is not
production-verified. Keep the coordinator recommendation on the previous
stable version and cut a new release with matching artifacts.

## What not to count as release proof

- matching `macprovider-cli --version`
- matching codesign designated-requirement text
- Gatekeeper acceptance alone
- notarization/stapling alone
- simple local chat/completions curl
- product-specific Buzz smoke tests
