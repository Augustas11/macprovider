# macprovider-watchdog

External LaunchAgent that catches the silent half-open-TCP wedge of
the Mac provider's WebSocket to the coordinator. Operator-visibility
insurance for the failure mode tracked in GitHub issue #189; ships
alongside every install of `macprovider-cli` via the public
`get.streamvc.live/install.sh` flow.

## What it does

Every 60 seconds, `watchdog.sh` runs `netstat -an -p tcp` and looks
for an ESTABLISHED outbound connection from the provider process to
`coordinator.streamvc.live:443`. If none is found, it issues
`launchctl kickstart -k gui/$UID/live.streamvc.macprovider` so the
provider LaunchAgent is restarted by launchd.

It reads the provider identity from
`~/.config/macprovider/config.yaml` (the file
`macprovider-cli` itself reads) — so it generalizes across every
operator without any hardcoded provider id.

## Files

| File | Purpose |
|---|---|
| `watchdog.sh` | The poll script. Idempotent; safe to invoke repeatedly. |
| `live.streamvc.macprovider-watchdog.plist.template` | LaunchAgent template; substituted by `install.sh`. |
| `install.sh` | Idempotent installer. Invoked by both the main `get.streamvc.live/install.sh` flow and by an operator running this directory by hand. |
| `uninstall.sh` | Removes the LaunchAgent and the `~/.local/share/macprovider-watchdog` directory. |

## Operator runbook

### Install (standalone — most operators will not need this)

The watchdog is installed automatically by the main provider
installer. To re-install (or install manually if the operator skipped
it):

```bash
bash ops/macprovider-watchdog/install.sh
```

The install is idempotent: re-running it `bootout`s the previous
LaunchAgent before bootstrapping the new one.

### Inspect

The watchdog logs to `~/Library/Logs/macprovider/watchdog.log` (only
when it detects an issue or kicks the provider — healthy ticks are
silent so the log does not bloat). To see whether the LaunchAgent is
loaded:

```bash
launchctl list | grep live.streamvc.macprovider-watchdog
```

To manually fire a tick out-of-cadence:

```bash
launchctl kickstart -k gui/$UID/live.streamvc.macprovider-watchdog
```

### Uninstall

```bash
bash ops/macprovider-watchdog/uninstall.sh
```

The main provider uninstaller (`phase3-binary/dist/uninstall.sh`)
removes the watchdog too — operators only need this when they want to
remove the watchdog without removing the provider.

## Why this is operator-visibility insurance, not the fix

The underlying bug is in the Swift WebSocket reconnect loop. PR #204
landed the in-process bounded send + Darwin.exit(1) liveness watchdog
that prevents the wedge from happening at all on new builds. This
external LaunchAgent is the belt-and-suspenders safety net for
operators still on older builds, and a long-tail catch for any future
regression in the in-process protection.

## Environment overrides (advanced)

Both `install.sh` and `watchdog.sh` accept env overrides for testing:

| Variable | Default |
|---|---|
| `MACPROVIDER_WATCHDOG_DIR` | `~/.local/share/macprovider-watchdog` |
| `MACPROVIDER_CONFIG_PATH` | `~/.config/macprovider/config.yaml` |
| `MACPROVIDER_LOG_DIR` | `~/Library/Logs/macprovider` |
| `MACPROVIDER_COORDINATOR_HOST` | `coordinator.streamvc.live` |
| `MACPROVIDER_SERVICE_LABEL` | `live.streamvc.macprovider` |

These let an operator point the watchdog at a staging coordinator or
verify the install path before rolling to production.
