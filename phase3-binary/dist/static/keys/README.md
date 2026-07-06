# SPEC-023 autotune static-feed signing keys

## What's in this directory

- `autotune-static-v4.public.base64` — base64 of the 32-byte raw
  Curve25519 (Ed25519) **public** key. Also baked verbatim into
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

The signer looks for the private key in this order:

1. `$AUTOTUNE_STATIC_V4_PRIVATE_KEY_PATH` — explicit env override.
2. `$HOME/.config/macprovider/keys/autotune-static-v4.private.base64`
   — the operator's local default. Expected `chmod 0600`.

The script refuses to run if the key file is world-readable (permissions
wider than `0600`/`0400`) — see `scripts/resign-autotune-static.sh` for
the exact check.

## Security posture — trust model at runtime

The runtime verification model relies on:

1. **Provider clients** ship the baked v4 public key in
   `AutotuneRecommend.swift`. They fetch the signed feed from
   `https://coordinator.streamvc.live/static/*` (URL hardcoded in
   [`AutotuneRecommend.swift`](../../../Sources/macprovider-cli/AutotuneRecommend.swift))
   and verify each `.sig` sidecar against the baked pubkey.
2. **The private key** is held only by the operator running
   `scripts/resign-autotune-static.sh` locally. It never enters
   git, CI logs, or `coordinator.streamvc.live`.
3. **Deployment** copies the freshly-signed `autotune-candidates.json`
   / `demand-rank.json` and their `.sig` sidecars to Pearl VPS via
   `phase4-coordinator/dist/deploy-pearl-vps.sh`; nginx serves them
   under `/static/`.

Additional defenses in depth:

- Model artifacts are SHA-pinned by `model_sha256` in the catalog. The
  client verifies the downloaded HuggingFace revision against that SHA.
  Even a legitimate signer cannot swap in a novel binary — only a
  slower already-existing HF model.
- Rate-card / earnings signals come from
  `https://coordinator.streamvc.live/v1/rate-card` (TLS-signed by
  LetsEncrypt), not from this signed feed. This keypair does not
  govern provider earnings.
- If verification fails at runtime (bad sig, wrong keyID, network
  partition), the client falls back to the compiled-in baked catalog
  in `AutotuneRecommend.swift` and stays online.

## Rotation history

| Version | keyID                          | Rotated on | Reason                                                                                                                                                                                                     |
|---------|--------------------------------|-----------:|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| v2      | `streamvc-autotune-static-v2`  | 2026-07-01 | Initial SPEC-023 signed-feed release. Private key held by operator.                                                                                                                                        |
| v3      | `streamvc-autotune-static-v3`  | 2026-07-03 | v1.7.10 rotation. Fresh keypair generated to accompany the M-Base-realistic `min_sustained_tps` catalog cuts. Private key kept off-repo per standard operational practice; only the public key ships here. |
| v4      | `streamvc-autotune-static-v4`  | 2026-07-06 | Issue 411 rotation. The local v3 private key was unavailable, so the Nemotron feed update rotates to v4 and commits freshly signed static sidecars. Private key remains off-repo at the v4 path above. |

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

## Rotation procedure (for future v4 → v5)

1. Generate a fresh keypair as above.
2. Write PRIVATE to `~/.config/macprovider/keys/autotune-static-v5.private.base64`,
   `chmod 0600`. Do NOT commit.
3. Add `autotune-static-v5.public.base64` and leave earlier public keys
   for audit/history.
4. Update `AutotuneRecommend.swift`:
   `keyID = "streamvc-autotune-static-v5"`,
   `autotune_static_json_ed25519_v5 = "<new pubkey>"`,
   `publicKeyBase64 = autotune_static_json_ed25519_v5`.
5. Update tests: replace all `streamvc-autotune-static-v4` occurrences
   with `-v5` and the pubkey constant name.
6. Update `scripts/resign-autotune-static.sh`: `KEY_ID`, default key
   path, and `AUTOTUNE_STATIC_V*_PRIVATE_KEY_PATH` env var name.
7. Run `scripts/resign-autotune-static.sh` to produce fresh v5-signed
   sidecars.
8. `swift test` — full suite must pass.
9. Add a rotation-history row above.
10. Ship in a version bump; deploy to Pearl.
