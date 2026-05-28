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
