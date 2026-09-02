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

## Damaged-provider repair candidate scope

A candidate that changes updater, watchdog, or launchd repair logic is not
proof that an already-running older coordinator autoupdate can heal itself. The
first coordinator-recommended hop still runs the already-installed binary's
updater code. Keep the checked-in and live coordinator recommendation on the
previous stable version until a separate promoted-rollout gate proves that
first-hop path from the previous stable.

For damaged-provider acceptance, run the candidate through a path that executes
the candidate payload directly, such as a pinned installer or acceptance-update
flow. Required evidence:

- `whoami` on the remote Mac is the expected provider user.
- Preflight records the current and legacy provider/watchdog launchd labels
  without printing provider IDs, tokens, or secrets.
- Post-repair `/v1/status` reports the target binary version and a fresh
  `serve` service instance.
- The canonical `live.malibu.provider` and `live.malibu.provider-watchdog`
  launchd services are loaded, and legacy labels are absent.
- The public coordinator recommendation remains on the previous stable until
  this evidence is reviewed.

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
malibu-cli update --check
malibu-cli update
malibu-cli --version
malibu-cli status --advanced
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
recommendation (`1.8.82`) until the signed `1.8.88` provider assets are
published and the embedded CLI byte-identity check passes. The v2 handler may
be deployed ahead of that release, but the coordinator must not advertise an
unpublished version. Once the v2 handler is active, v1 hardware-evidence
submissions are no longer accepted for refresh; those providers must upgrade
to a signed v1.8.82-or-newer release before they can renew admission evidence.

The release workflow derives its staged version-cohesion exception from the
checked-in coordinator `latest_binary_version` and the CLI source version via
`scripts/release-staged-version-policy.sh`. A later release must update the
checked-in coordinator examples to the previous stable recommendation; the
workflow no longer carries per-release hardcoded previous/candidate literals.

After immutable publication, deploy Pearl's recommendation update, then
dispatch `.github/workflows/verify-live-coordinator-release-rollout.yml` with
the public tag. The workflow verifies the immutable GitHub release, requires
the live coordinator to advertise the exact release, publishes the signed
append-only discovery transport, and proves anonymous discovery from the new
CLI.

Do not enable the strict gate while the fleet still contains providers that
cannot produce v2 evidence. A coordinator deployment that has not yet
accepted v2 must remain on the previous provider recommendation.

## Curl-channel install.sh republish (MANDATORY on release)

The Malibu app bundles its own signed `install.sh`, but the public one-liner
`curl -fsSL https://get.malibu.tech/install.sh | bash` is served as a **static
file on the coordinator host** (`/var/www/get/install.sh`). Cutting a release
updates the app bundle and the release assets but does **not** republish this
static file, so it drifts stale silently — it once lagged ~2 weeks, serving an
installer without the python3-CLT guard or the donor-join fix.

On every release that changes `phase3-binary/dist/install.sh`, after immutable
publication:

1. Back up the current served file, then copy the released `dist/install.sh`
   into the webroot (preserve `root:root 0755`):

   ```bash
   ts=$(date -u +%Y%m%dT%H%M%SZ)
   ssh pearl "cp -p /var/www/get/install.sh /var/www/get/install.sh.bak-$ts"
   scp phase3-binary/dist/install.sh pearl:/tmp/install.sh.new
   ssh pearl "install -o root -g root -m 0755 /tmp/install.sh.new /var/www/get/install.sh && rm -f /tmp/install.sh.new"
   ```

2. Verify parity from a clean checkout of the release tag:

   ```bash
   bash scripts/check-install-sh-parity.sh   # exits 0 only when served == released
   ```

The scheduled `.github/workflows/install-sh-parity-alarm.yml` runs this check
every 6 hours against the latest release tag and FAILS (notifying) on drift, so
a missed republish surfaces within a quarter day instead of stranding new
installs. Treat a red parity alarm as a release step that did not complete.

## What not to count as release proof

- matching `malibu-cli --version`
- matching codesign designated-requirement text
- Gatekeeper acceptance alone
- notarization/stapling alone
- simple local chat/completions curl
- product-specific Buzz smoke tests
