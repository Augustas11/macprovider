# phase3-binary

This package builds `macprovider-cli`, the Apple Silicon provider binary
for Mac Provider. The distribution layer in `dist/` publishes a
darwin-arm64 tarball and installs it as a user-level service.

## Join the Network

For a public provider install on any Apple Silicon Mac (M1 or newer,
macOS 14+):

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
```

The installer:

- Downloads `macprovider-cli-vX.Y.Z-darwin-arm64.tar.gz` from GitHub
  Releases.
- Verifies `checksums.txt.sig`, then verifies the release tarball
  against `checksums.txt`.
- Installs the binary and resource bundles under `~/macprovider`.
- Selects a default MLX model from RAM: 3B for 8 GB, 7B for 16 GB, 14B
  for 24 GB or higher.
- Persists a stable provider handle in `~/.config/macprovider/`.
- Renders `dist/launchd-plist-template.plist` into
  `~/Library/LaunchAgents/live.streamvc.macprovider.plist`.
- Starts the provider with `--coordinator
  wss://coordinator.streamvc.live/ws/provider`.

## Distribution Files

- `dist/install.sh`: public curl-pipe-bash installer.
- `dist/uninstall.sh`: removes the user-level install, launchd plist,
  and logs.
- `dist/launchd-plist-template.plist`: launchd template populated by
  the installer.
- `dist/package.sh`: operator packaging script wrapped by the release
  workflow.

The public installer is intentionally independent of local build output:
it assumes the matching release tarball already exists on GitHub
Releases.

## Trust Caveat

The current binary is unsigned at the macOS app-signing layer.
`install.sh` verifies the signed checksum manifest and SHA-256 before
extracting, then asks before clearing the macOS quarantine attribute.
This keeps the v1 install path working while Developer ID signing
remains an open SPEC-003 operator question.

## Provider economics (earnings, payouts, lifecycle)

Quick reference for Mac owners running `macprovider-cli`:

- **Default provider share:** 90% of gross credits per request.
- **Rate card (default):** 500,000 credits / 1 M prompt tokens; 1,000,000 credits / 1 M completion tokens.
- **Minimum payout threshold:** 500,000 credits (config: `settlement.min_payout_credits`).
- **Settlement cadence:** weekly, every Monday 00:00 UTC (config: `settlement.cadence_days = 7`).
- **Balance check:** `GET /providers/{id}/earnings` with `Authorization: Bearer <provider_token>`.
- **Sleep behavior:** the binary holds `caffeinate -dimsu` to prevent idle system sleep; lid-close still drops the WebSocket (binary reconnects automatically on wake).
- **Reaping:** coordinator closes idle WebSocket connections after 90 s of no inbound frames (heartbeat or inference chunk); default `pool.heartbeat_miss_threshold_s = 90`.
- **Pinning:** promotional tier is operator-discretionary; no automatic promotion path exists today.

See `audits/2026-06-10/PROVIDER_ECONOMICS.md` for the full reference with
source citations, the complete credit formula, worked example, earnings
endpoint response shape, and lifecycle detail.
