# Headless Mac mini runbook

This runbook covers the supported SSH-only `headless_fleet` profile for Mac
mini providers. It installs the provider and watchdog as launchd system
daemons, survives reboot without a GUI login, and is intended for rack-mounted
Minis managed entirely over SSH.

For the normal desktop/Malibu.app install, use the standard installer without
`MACPROVIDER_HEADLESS`; it installs launchd user agents in the GUI domain.

## Requirements

- macOS Apple Silicon Mac mini
- SSH access as the intended non-root fleet user
- Python 3 and Command Line Tools available on the Mac
- Passwordless `sudo` for `/bin/launchctl` if you later run
  `malibu-cli uninstall` from this account

## Install

SSH to the Mac as the non-root fleet user who should own the provider data.
Do not run the installer as root.

```bash
ssh fleet-user@MINI_HOST
MACPROVIDER_HEADLESS=1 bash install.sh
```

To name the fleet account explicitly:

```bash
MACPROVIDER_HEADLESS=1 \
MACPROVIDER_HEADLESS_USER=fleet-user \
bash install.sh
```

`MACPROVIDER_HEADLESS=1` is required. Without it the installer uses the
consumer/GUI path and installs launchd user agents, which do not match the
headless fleet topology. Omitting this flag is an operator error, not an
installer bug.

The installer:

- writes the provider and watchdog plists under
  `~/.config/macprovider/launchd`
- publishes the same plists to `/Library/LaunchDaemons`
- bootstraps both jobs in launchd's `system` domain
- records the install in `install_manifest.json` with
  `install_profile=headless_fleet` and `launchd_domain=system`

## Verify

Check local readiness:

```bash
malibu-cli status
```

Check the launchd jobs:

```bash
sudo launchctl print system/live.malibu.provider
sudo launchctl print system/live.malibu.provider-watchdog
```

Confirm the recorded install profile:

```bash
python3 - <<'PY'
import json, pathlib
p = pathlib.Path.home() / "Library/Application Support/macprovider/install_manifest.json"
manifest = json.loads(p.read_text())
print(manifest["install_profile"], manifest["launchd_domain"])
PY
```

Expected output:

```text
headless_fleet system
```

## Reboot persistence

Reboot the Mac without opening a GUI session:

```bash
sudo reboot
```

SSH back in and verify the provider is still serving:

```bash
malibu-cli status
```

The provider and watchdog must return to the same `provider_id` and
buyer-serving state with no GUI login. This is the AC-026-17/18 behavior.

## Upgrade

Headless fleet nodes do not use consumer self-update. `malibu-cli update` is
expected to skip with:

```text
reason: headless_operator_update_required
outcome: skipped
```

That message means the operator must run the signed headless installer
acceptance bundle. Do not attempt to rewrite the updater or use a GUI-domain
update path for this profile.

To upgrade:

```bash
MACPROVIDER_HEADLESS=1 \
MACPROVIDER_HEADLESS_USER="$USER" \
bash /path/to/signed-headless-installer.sh
```

Use the current signed acceptance bundle provided by Malibu operators. Do not
use `malibu-cli update` for this profile.

## Uninstall

From the same SSH fleet user:

```bash
malibu-cli uninstall
```

The command:

1. reads the install manifest
2. detects `headless_fleet` / system-domain topology
3. stops the watchdog first, then the provider
4. uses `sudo launchctl bootout system/<label>`
5. proves each system job is absent with `sudo launchctl print`
6. removes the managed LaunchDaemon plists
7. removes the install prefix, binary, logs, watchdog files, and manifest
8. preserves provider identity for safe reinstall

If sudo access is unavailable or a system job remains loaded, uninstall fails
closed and does not remove artifacts.

Do not use `launchctl bootout gui/<uid>/...` for this profile. GUI-domain
bootout cannot stop system LaunchDaemons and may report misleading success.

## Reinstall

After uninstall, install again with the same headless flags:

```bash
MACPROVIDER_HEADLESS=1 bash install.sh
```

The preserved provider identity allows reinstall without re-admission.