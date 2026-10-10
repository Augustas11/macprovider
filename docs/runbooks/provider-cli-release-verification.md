# Provider CLI release verification

## Pearl compatibility gate before fleet recommendation

For each signed provider CLI release recommended to the fleet, read the exact
`compatibility_set_id` from its verified signed manifest. Before advancing the
advertised recommendation, ensure Pearl's running compatibility policy admits
that identity and `compatibility_set.target_id` names that same release.

Admission (SPEC-002-R004) needs no per-release edit: the coordinator admits
every well-formed release identity from the `target_id` repository, at any
version, and every session receives the recommended set and
`latest_binary_version` so its updater moves forward. The only routing block
is `compatibility_set.revoked_ids`, exact identities: a revoked build stays
connected update-only (never routed) and still receives the recommendation.
Revocation matches the identity a provider reports; it is a routing fence,
not a binary ban. `accepted_ids` and `first_hop_bridge_ids` still parse but
are ignored (startup warning). A hello whose `binary_version` differs from its
set's version is rejected (`provider_binary_version_mismatch`).

One-time revocation seed: every published release below v1.8.207 that ships
`compatibility-set.json` is listed in
`phase4-coordinator/dist/compatibility-revoked-ids.txt`, regenerated with
`GH_TOKEN=$(gh auth token -u Augustas11) python3
scripts/legacy-compatibility-revocations.py generate --below 1.8.207` (each id
is the release's signed `compatibility_set_id`, cross-checked against the
tag's commit) and checked offline by `... check`. After the
repository-admission runtime ships, `cli-release.sh` step `revocation_seed`
(`next --run`: `_revoke-seed`, one restart) adds any missing seed id to Pearl's
`revoked_ids` and is done when `/healthz` lists them all. Those releases stay
connected update-only and auto-update. A seed id that is the current target
cannot be revoked, so it is deferred (the step is done with a note) and the
same step revokes it once `recommendation_bump` has moved the target off it. Fleet recommendation still requires the
matching target: a binary recommendation of 223 with compatibility target 207
fails the consumer updater's exact manifest-target comparison.

`pearl_accepted_ids` is a read-only check that the running policy admits the
candidate. The policy is read from `/healthz` (`compatibility_policy_mode`
`repository`, target, revocations) and must equal the applied config; any
difference blocks every Pearl-mutating step. A coordinator runtime that
reports no mode predates repository admission: the train then points at the
runtime release (`scripts/ops/pearl-runtime.sh`), never at an `accepted_ids`
edit. The Pearl edit is the `scripts/ops/cli-release.sh` step that
`next --run` executes:
`recommendation_bump` (`latest_binary_version` and `target_id` to the
release). It prints the expected downtime first, holds
the live-ops lock and both Pearl locks, edits `coordinator.yaml` in place with
an anchored transform, backs it up under `/root/macprovider-backups`,
validates the new file with the running coordinator's binary, user and exact
environment, restarts the coordinator (`latest_binary_version` does not
reload on SIGHUP), waits for `/healthz`, checks that the restarted coordinator logged the on-disk
config as its boot config, and records the step. `recommendation_bump` is
complete only when `/healthz` recommends the release AND the applied
`compatibility_set.target_id` names it. When the requested edit is already on
disk but the running coordinator never applied it (a run stopped before its
restart), the step validates and restarts instead of reporting success. Nobody
pastes a restart. Publication or a healthy advertised version alone does not
prove that the new provider compatibility set is accepted and targeted; the
`registrations` gate reads the running coordinator's applied config.


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
5. Verify the signed provider code identity (issue #1842). The release signs
   the CLI's `cdhash`, `TeamIdentifier`, and signing `Identifier` into
   `pearl-release.json` as `provider_code_identity`, derived from the shipped
   tarball bytes. Check it against the binary you actually downloaded:

```bash
openssl dgst -sha256 \
  -verify ops/pearl-updater/release-signing-public.pem \
  -signature pearl-release.json.sig pearl-release.json
mkdir cli-check && tar -xzf macprovider-cli-vX.Y.Z-darwin-arm64.tar.gz \
  -C cli-check macprovider-cli
shasum -a 256 cli-check/macprovider-cli
codesign -d --arch arm64 -vvv cli-check/macprovider-cli 2>&1 |
  grep -E '^(CDHash|TeamIdentifier|Identifier)='
python3 -c 'import json; print(json.dumps(json.load(open("pearl-release.json"))["provider_code_identity"], indent=2))'
```

   `binary_sha256` must equal the `shasum` output, `slices[0].code_cdhash`
   must equal `CDHash=`, `team_id` must equal `TeamIdentifier=`, and
   `signing_identifier` must equal `Identifier=` (`live.malibu.provider.cli`).
   Any mismatch means the release is not verified. Pearl approves the
   verified identity for the privacy class through
   `scripts/ops/cli-release.sh` step `privacy_release_identity`, which stages
   this `pearl-release.json` in `privacy_class.release_code_identities.metadata_dir`
   (see `docs/runbooks/privacy-class-beta-operations.md` "Approved code
   identities"). Only when a config entry is needed instead, emit it from the
   verified metadata rather than copying values by hand:

```bash
python3 scripts/provider-code-identity.py --emit-approved-identity \
  --pearl-release-json pearl-release.json
```

   The command checks the signature against
   `ops/pearl-updater/release-signing-public.pem` before it prints anything,
   and prints only public identity values. Drop the `binary_version` line to
   approve the exact cdhash without pinning the version string.
6. Treat the coordinator rollout as two phases:
   - before publication, the signed feed bytes, keyring, and coordinator
     health version are checked while the recommendation may remain on the
     previous stable CLI;
   - after publication and the immutable byte-identity check, run the
     `recommendation_bump` step (`scripts/ops/cli-release.sh next --run`) to
     move the recommendation to the published CLI, then its
     `verify_live_rollout` step dispatches
     `verify-live-coordinator-release-rollout.yml`. That workflow
     requires the exact post-publication gate before publishing the
     append-only discovery transport.
7. Verify the Malibu artifact against the standalone provider tarball:

```bash
bash scripts/verify-malibu-release-artifacts.sh \
  Malibu-vX.Y.Z.dmg \
  --provider-tarball macprovider-cli-vX.Y.Z-darwin-arm64.tar.gz
```

8. Verify local updater acceptance from the previous stable CLI:

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

Byte-parity is necessary but not sufficient. The served installer can match the
latest tag and still be unable to resolve an installable release (observed
#1574/#1588: v1.8.123 `latest_release_tag()` used `?per_page=30`, leading
prereleases hid the stable tag, the resolver died 3, and `checksums.txt`
404'd while parity stayed green). The scheduled
`.github/workflows/install-sh-consumer-health-alarm.yml` fetches the served
`install.sh`, runs that copy's `latest_release_tag()` against the live
unauthenticated GitHub API (the view a fresh host gets — do not use `gh` /
`GITHUB_TOKEN`), and asserts `checksums.txt` plus a `darwin-arm64` platform
asset return HTTP 200. Run it locally with
`bash scripts/check-install-sh-consumer-health.sh`. A red health alarm with
green parity means the curl channel is serving a broken resolver; fix the
installer, cut the next stable CLI, and republish.

## Release mirror byte identity (download.malibu.tech, #1737)

Macs that cannot reach GitHub (mainland China) install and update from
`https://download.malibu.tech/releases/<tag>/`. The mirror is untrusted
transport: `checksums.txt.sig` stays the only authority, so a wrong mirror byte
fails closed, but it also strands those Macs. Stable releases run
`scripts/publish-release-mirror.sh --tag <tag>` as a non-blocking
post-publication step in `release.yml` and `promote-acceptance-candidate.yml`.
It refuses any asset whose SHA-256 differs from GitHub's asset digest, writes the
updater index at `releases/index/<tag>.json` (outside the tag directory, which
holds only GitHub assets, including one named `release.json`), and re-downloads every served file to compare hashes.

1. Confirm the step passed in the release run. It is `continue-on-error`, so a
   failure does not turn the release red, but the Pearl updater gate
   (`PEARL_UPDATER_RELEASE_MIRROR_GATE=required`) will then refuse to advance
   `latest_binary_version`, and that refusal also holds any catalog,
   rate-card, or admission-policy change in the same Pearl update. Check Pearl
   free space first (`df -h /var/www/malibu-download`); each release adds
   about 90 MB. If it failed, rerun it:
   ```bash
   GH_TOKEN=... MALIBU_DOWNLOAD_SSH_KEY=~/.ssh/<operator-ssh-key> \
     bash scripts/publish-release-mirror.sh --tag vX.Y.Z
   ```
2. Spot-check byte identity against GitHub from any host:
   ```bash
   tag=vX.Y.Z; a=checksums.txt
   cmp <(curl -fsSL "https://github.com/Augustas11/macprovider/releases/download/$tag/$a") \
       <(curl -fsSL "https://download.malibu.tech/releases/$tag/$a")
   ```
3. When the coordinator's `latest_binary_version` advances to the tag, move the
   advisory pointer. The CLI release train does it: `scripts/ops/cli-release.sh`
   step `mirror_latest` is pending while the served `releases/latest.json` names
   another tag, and `next --run` executes `bash scripts/publish-release-mirror.sh
   --tag vX.Y.Z --promote-latest` under the live-ops lock (it needs
   `MALIBU_DOWNLOAD_SSH_KEY` in the ops env and refuses without it). The script
   refuses unless `coordinator.malibu.tech/healthz` already advertises the tag,
   and never moves `latest.json` backwards.

A published `/releases/<tag>/` is immutable: a rerun is a no-op when the bytes
match and an error otherwise. Do not edit it in place; cut a new release.
The one exception is a tag seeded before the index moved out of the tag
directory (a generated `release.json` in place of the GitHub asset). Move that
directory aside on Pearl (`sudo mv /var/www/malibu-download/releases/<tag>
/var/www/malibu-download/releases/<tag>.old-layout`), rerun the publisher for
the tag, and confirm `releases/<tag>/release.json` matches `checksums.txt`.
v1.8.123 was migrated this way on 2026-09-25.

## China supply acceptance boundary

`MACPROVIDER_MODEL_MIRRORS` configures fallback sources; it does not force the
first snapshot to bypass Hugging Face. When Hugging Face is reachable, the CLI
tries it first. A successful download with that variable set therefore proves
nothing about the mirror by itself.

For the China supply acceptance run:

1. Start with no target snapshot in either the Hugging Face cache or the
   MacProvider durable store, and record that state before launching the CLI.
2. Install a resolver-level deny boundary for GitHub, Hugging Face, their API,
   raw-content, object, CDN, LFS, Xet and CAS hosts. Verify the boundary before
   and after the run, and restore the resolver configuration byte-identically.
   `HTTP_PROXY` / `HTTPS_PROXY` are not a sufficient boundary: URLSession and
   Network.framework traffic may bypass them.
3. Keep strict TLS verification enabled. The model mirror must use a publicly
   trusted certificate or an approved machine trust configuration; never use
   `-k` or weaken system TLS to complete the test.
4. Capture the mirror's access log and provider connection endpoints. A pass
   requires the manifest and every file, including the full weight payload, to
   arrive through the approved mirror and the adopted snapshot to reproduce the
   signed catalog `model_sha256`. Small-file requests followed by a stalled
   weight download are partial evidence, not a pass.
5. Do not implement a launchd safety check as `launchctl list | grep -q ...`
   under `set -o pipefail`: `grep -q` may exit early and make `launchctl` fail
   with SIGPIPE. Capture `launchctl list` first, then search the captured text.

The released-run gate still applies: only a reviewed, signed CLI may join the
live coordinator. A local or ad-hoc build stays isolated with `--no-join`.

## What not to count as release proof

- matching `malibu-cli --version`
- matching codesign designated-requirement text
- Gatekeeper acceptance alone
- notarization/stapling alone
- simple local chat/completions curl
- product-specific Buzz smoke tests
