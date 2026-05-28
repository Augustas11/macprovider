# Mac Provider

Mac Provider is a pooled Apple Silicon inference network. Contributor
Macs run local MLX inference, connect outbound to the coordinator, and
serve buyer traffic without requiring an inbound public URL.

## Join the Network

Run this on any Apple Silicon Mac (M1 or newer, macOS 14+):

```bash
curl -fsSL https://get.streamvc.live/install.sh | bash
```

The installer will:

- Check that the Mac is Apple Silicon and has the required macOS tools.
- Pick a recommended MLX model from available RAM and let you override it.
- Ask for a stable provider handle used as your pool identity.
- Download the latest `macprovider-cli` release from GitHub Releases.
- Verify the signed checksum manifest and SHA-256 before extracting the tarball.
- Install under `~/macprovider` and set up a user-level launchd service.
- Run a local `/v1/models` check and a coordinator pool visibility check.

Security note: `curl | bash` is convenient but gives the downloaded
script control of your user account. Read the script first if you want
to inspect it:

```bash
curl -fsSL https://get.streamvc.live/install.sh -o install.sh
less install.sh
bash install.sh
```

The current release is unsigned at the macOS app-signing layer. The
installer verifies a signed release checksum manifest, then asks before
clearing the macOS quarantine attribute with
`xattr -dr com.apple.quarantine`; this is the v1 workaround until
Developer ID signing and notarization are added.

Technical readers can start with
[`SPEC-003`](specs/SPEC-003-open-onboarding.md), which defines the open
onboarding distribution flow.

## Project Context

The coordinator is hosted at `coordinator.streamvc.live`. Existing
operator-managed providers are pinned; new public installs join as
provisional providers over outbound WebSocket tunneling and can be
promoted by the operator after observation.
