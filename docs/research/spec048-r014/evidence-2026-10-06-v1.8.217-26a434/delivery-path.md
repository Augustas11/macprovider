# Native-MTP admission sidecar: production, signing, delivery (v1.8.217)

This note answers how a native-MTP admission sidecar is produced, signed, and
delivered to a production provider. Line numbers are at the release commit
`71f22d36c3ef11c99d3572f63bb0283f73f19aa5` (tag `v1.8.217`). Any sidecar this
rehearsal generated is rehearsal-only.

## What the released provider requires

A released `serve --native-mtp auto` admits the tuple only when all of the
following hold:

1. **A sidecar file sits next to the model bundle.** `native-mtp-admission.json`
   and `native-mtp-admission.json.sig` must be in the model bundle root (the
   parent of the target snapshot directory) or in the target directory itself.
   The lookup is in `ModelRuntime.swift:8715-8725` and
   `MacProviderCLI.swift:1170-1177`. Config keys
   `native_mtp_admission_sidecar_path` and
   `native_mtp_admission_signature_path` can override the path.
   `NativeMTPAdmissionSidecar.swift:2666-2669` leaves these files out of the
   snapshot manifest, so placing them in the model directory does not change
   the artifact hash.
2. **The sidecar is signed by the static-feed key.** The keyring is fixed to
   `AutotuneStaticInputs.defaultTrustedPublicKeys` with required key
   `AutotuneStaticInputs.keyID` (`ModelRuntime.swift:2528-2531`). That key id
   is `bakedCatalogSignerKeyID ?? "streamvc-autotune-static-v5"`
   (`AutotuneRecommend.swift:1821`). A release build can't inject a different
   keyring or build identity: the injection exists only under
   `#if DEBUG || MACPROVIDER_LAB_HARNESS` (`ModelRuntime.swift:2532-2536`).
3. **The sidecar's release must match the provider's signed catalog release.**
   `resolveNativeMTPArtifactAuthority` (`MacProviderCLI.swift:1135-1184`)
   requires the sidecar `release_id` to equal the provider's signed catalog
   release and its signed artifact feed. It also requires exactly one
   verified primary artifact identity with the served model hash.
   `NativeMTPAdmissionSidecar.swift:1345-1346` rejects a release-id mismatch.
4. **The sidecar must match the running binary.**
   `nativeMTPAdmissionMatchesRunningBuild` (`ModelRuntime.swift:9117-9129`)
   compares the sidecar's provider revision, SPEC-023 source commit, build
   digest, live executable CDHash, and MLX fork revision with the running
   binary. The running identity comes from the installed signed compatibility
   set, the executable's SHA-256, and the live process CDHash
   (`ModelRuntime.swift:8554-8580`). A sidecar therefore admits exactly one
   signed release build: for 217, CDHash `df44bcf4…` and SHA-256 `a6ea51d7…`.
5. **The emergency-revocation feed must load.** The feed is fetched before the
   sidecar is parsed (`ModelRuntime.swift:8732-8753`). The origin is hard-coded
   to `https://coordinator.malibu.tech/v1/`
   (`NativeMTPRevocationFeed.swift:218`), at
   `native-mtp-revocations.<signer-key-id>.json` plus `.sig` (`:337-357`). The
   load tries the network first and falls back to a Keychain-anchored cache
   (`:359-391`). If the feed is unreachable and nothing is cached, the provider
   rejects with `revocation_state_unavailable`.

## How a sidecar is produced and signed today

- **Generation:** `scripts/native_mtp_admission_sidecar.py build --tuple
  <tuple-input> --release <release-input>` renders canonical unsigned bytes
  and prints `native_mtp_admission_tuple_sha256` (`build` at :321,
  `admission_tuple_sha256` at :311). It never reads a key (docstring :1-24).
- **Signing:** this is an operator step with the static-feed private key,
  following the `sign_one` procedure in `scripts/resign-autotune-static.sh:111`
  (CryptoKit Ed25519 over the canonical bytes). The detached signature is
  `{"alg":"ed25519","key_id":…,"signature":…}`.
- **Committed tuple input:** the only one is
  `docs/research/spec048-r015/evidence-2026-10-02-a3b-formal/admission-tuple-input.json`.
  It is not usable for v1.8.217:
  - it carries all-zero evidence placeholders, which the generator refuses
    (`records/production-generator-rehearsal.json`);
  - it binds runtime revision `ef4ff856…`, but 217 pins `b1811029…`;
  - it binds the superseded benchmark policy `30934c07…`.
- **Lab harness:** the hidden `native-mtp-hardware-e2e` command writes its own
  sidecar signed by an ephemeral key (`NativeMTPHardwareE2ECommand.swift:645-720`).
  It loads that sidecar through the production serve-path loader with an
  injected keyring, and only a lab build can do that. This rehearsal's
  `records/lab-native-mtp-admission.json` is that file.

## How it would reach a production provider

**There is no delivery path in v1.8.217.**

- **No code writes the sidecar.** Searching the v1.8.217 sources, scripts,
  installer, and coordinator finds only readers of `native-mtp-admission.json`.
  Nothing writes it: not `install.sh`, not the model downloader, not autotune
  `--apply`, not the updater.
- **The release doesn't ship it.** The v1.8.217 release assets have no sidecar
  member. The catalog-release bundle contains `autotune-candidates`,
  `autotune-artifacts`, `rate-card`, `demand-rank`, `tier2-catalog`,
  `continuous-batching-policy`, and `trusted-keys`.
- **The coordinator doesn't serve the revocation feed.** `phase4-coordinator`
  has no route for it, and both
  `https://coordinator.malibu.tech/v1/native-mtp-revocations.streamvc-autotune-static-v5.json`
  and the `-v4` URL return HTTP 404 (`records/revocation-feed-probe.json`).

Even with a correctly signed sidecar placed by hand next to the model, a
released provider would still fail closed at the revocation step. The SPEC-048
R013 wording ("bound to one immutable SPEC-023 `release_id` and SPEC-010
model/artifact member") points to a signed catalog-release member resolved by
the SPEC-023 artifact feed. No such member type exists yet.

## The one unblock

Production enablement needs a defined delivery path. The intended form is a
SPEC-023 catalog-release member: the sidecar and its signature, signed by the
static-feed key, published with the catalog release, and materialized next to
the model bundle by the same verified path that installs the artifact feed.
The coordinator must also publish the signed emergency-revocation feed at
`/v1/native-mtp-revocations.<key>.json`. Until both exist, no released
provider can admit any native-MTP tuple.
