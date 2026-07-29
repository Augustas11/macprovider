# SPEC-023 autotune static-feed signing keys

## What's in this directory

- `autotune-static-v5.public.base64` — bridge public key staged for the
  next static-feed signer rotation. It is trusted by bridge builds but
  does not sign the current live feed in this PR.
- `autotune-static-v4.public.base64` — current live static-feed public key,
  base64 of the 32-byte raw Curve25519 (Ed25519) **public** key. Also baked verbatim into
  [`AutotuneRecommend.swift`](../../../Sources/macprovider-cli/AutotuneRecommend.swift)
  as `autotune_static_json_ed25519_v4`. Committing the public key here
  makes it easy to spot rotations in `git log`.
- `autotune-static-v3.public.base64` — prior public key retained for
  audit/history only.
- This README.

The **private** key is deliberately NOT committed. See "Where the
private key lives" below.

The signing script that consumes the private key is
[`scripts/resign-autotune-static.sh`](../../../../scripts/resign-autotune-static.sh).

## Where the private key lives

The signer looks for the private key in this order for the selected
`AUTOTUNE_STATIC_KEY_ID`:

1. `$AUTOTUNE_STATIC_PRIVATE_KEY_PATH` — explicit env override.
2. `$AUTOTUNE_STATIC_V4_PRIVATE_KEY_PATH` — legacy v4 explicit env override.
3. `$HOME/.config/macprovider/keys/autotune-static-<version>.private.base64`
   — the operator's local default. Expected `chmod 0600`.

The script refuses to run if the key file is world-readable (permissions
wider than `0600`/`0400`) — see `scripts/resign-autotune-static.sh` for
the exact check.

## Security posture — trust model at runtime

The runtime verification model relies on:

1. **Provider clients** ship the baked v4 public key in
   `AutotuneRecommend.swift`. They fetch the signed feed from
   `https://coordinator.streamvc.live/v1/rate-card`,
   `https://coordinator.streamvc.live/v1/demand-rank` and
   `https://coordinator.streamvc.live/v1/autotune-candidates` (URL
   hardcoded in
   [`AutotuneRecommend.swift`](../../../Sources/macprovider-cli/AutotuneRecommend.swift))
   and verify each `.sig` sidecar against the baked pubkey.
2. **The private key** is held only by the operator running
   `scripts/resign-autotune-static.sh` locally. It never enters
   git, CI logs, or `coordinator.streamvc.live`.
3. **Deployment** copies the freshly-signed `rate-card.json`,
   `autotune-candidates.json`, `demand-rank.json`, their `.sig` sidecars,
   and the release-bound signed `tier2-catalog.json` to Pearl VPS via
   `phase4-coordinator/dist/deploy-pearl-vps.sh`; the coordinator buyer
   mux serves them under `/v1/rate-card`, `/v1/demand-rank`, and
   `/v1/autotune-candidates`.

Additional defenses in depth:

- Model artifacts are SHA-pinned by `model_sha256` in the catalog. The
  client verifies the downloaded HuggingFace revision against that SHA.
  Even a legitimate signer cannot swap in a novel binary — only a
  slower already-existing HF model.
- Rate-card / earnings signals are now signed by this detached Ed25519 feed
  before the CLI accepts live bytes for paid recommendation. TLS remains the
  transport layer; the sidecar is the feed integrity boundary.
- If verification fails at runtime (bad sig, wrong keyID, network
  partition), the client falls back to the compiled-in baked static inputs
  and emits the relevant fallback/integrity warning.

## Rotation history

| Version | keyID                          | Rotated on | Reason                                                                                                                                                                                                     |
|---------|--------------------------------|-----------:|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| v2      | `streamvc-autotune-static-v2`  | 2026-07-01 | Initial SPEC-023 signed-feed release. Private key held by operator.                                                                                                                                        |
| v3      | `streamvc-autotune-static-v3`  | 2026-07-03 | v1.7.10 rotation. Fresh keypair generated to accompany the M-Base-realistic `min_sustained_tps` catalog cuts. Private key kept off-repo per standard operational practice; only the public key ships here. |
| v4      | `streamvc-autotune-static-v4`  | 2026-07-06 | Issue 411 rotation. The local v3 private key was unavailable, so the Nemotron feed update rotates to v4 and commits freshly signed static sidecars. Private key remains off-repo at the v4 path above. |
| v5      | `streamvc-autotune-static-v5`  | 2026-07-26 | Issue 744 bridge key staged because the local v4 private key was unavailable for future provenance catalog signing. This PR trusts v5 as `bridge` while production continues to publish the v4-signed feed. First v5-signed feed activation is a separate rollout after bridge adoption. |

## Generating a fresh key

```
swift -e '
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
print("PRIVATE=" + key.rawRepresentation.base64EncodedString())
print("PUBLIC="  + key.publicKey.rawRepresentation.base64EncodedString())
'
```

`openssl genpkey -algorithm ed25519 …` works too, but produces a
PKCS8-wrapped PEM; extract the raw 32-byte key with:

```
openssl pkey -in v4.pem -outform DER | tail -c 32 | base64
```

The Curve25519 wrapper the client uses accepts raw 32-byte keys, not
PEM/DER, so the extraction step is required if you generate via OpenSSL.

## Rotation procedure (v4 → v5 bridge)

Trusted release keys are declared in
`phase3-binary/catalog/autotune/trusted-keys.json`. Provider and coordinator
verifiers resolve the sidecar `key_id` through a keyring; they do not replace a
single global key during rotation.

1. Generate v5 through the approved recoverable signer or escrow process.
2. Store the private key outside git with at least two authorized recovery
   holders. Write the raw local signing export, when required, to
   `~/.config/macprovider/keys/autotune-static-v5.private.base64` with mode 0600.
3. Add the v5 public key to `trusted-keys.json` with status `bridge`. Keep v4
   `active`.
4. Generate, test, and release provider and coordinator builds that trust both
   v4 and v5 while production continues to publish v4.
5. Confirm the supported client floor has the bridge build.
6. Set `AUTOTUNE_STATIC_KEY_ID=streamvc-autotune-static-v5` and
   `AUTOTUNE_STATIC_PRIVATE_KEY_PATH=<secure-v5-export>` when signing the first
   v5 release. `scripts/resign-autotune-static.sh` refuses a private key that
   does not derive the declared public key.
7. Run `make verify-autotune-catalog`, full Swift/Go tests, and Pearl staged
   verification before activation.
8. Keep v4 in the keyring through the compatibility window. Retire it only
   after old-client usage is below the supported floor and rollback no longer
   requires v4 publication.

Never publish v5-only as the first rotation step: v4-only clients would reject
the feed and fragment the fleet again.
