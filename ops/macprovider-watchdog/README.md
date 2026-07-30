# macprovider-watchdog

External LaunchAgent that observes the installed Mac provider process
and runs auto-update rollback recovery. It ships alongside every
install of `macprovider-cli` via the public
`get.streamvc.live/install.sh` flow.

## What it does

Every 60 seconds, `watchdog.sh` checks that exactly one installed
`macprovider-cli` process is running and that the provider's local
`/v1/health` endpoint responds successfully. If either check fails, it
logs the condition and leaves restart ownership to the main
`live.streamvc.macprovider` LaunchAgent's `KeepAlive` policy. This is
intentional: #520 made the companion watchdog observer-only so there is
one routine runtime manager for the provider singleton. Coordinator TCP
state is logged as advisory only; another process reaching the
coordinator is not treated as proof that the provider is healthy.

The watchdog still runs auto-update rollback recovery. A rollback may
bootstrap/kick the main provider label after restoring the prior binary
so the restored executable takes effect; that is a bounded recovery
action, not routine liveness ownership.

It reads the provider identity from
`~/.config/macprovider/config.yaml` (the file
`macprovider-cli` itself reads) — so it generalizes across every
operator without any hardcoded provider id.

## Files

| File | Purpose |
|---|---|
| `watchdog.sh` | The poll script source (installed as `macprovider-health-monitor`). Idempotent; safe to invoke repeatedly. |
| `live.streamvc.macprovider-watchdog.template.plist` | LaunchAgent template; substituted by `install.sh`. |
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
when it detects an issue or performs rollback work — healthy ticks are
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

## Why this is observer visibility, not runtime ownership

The provider process owns in-process liveness checks, and the main
`live.streamvc.macprovider` LaunchAgent owns routine restarts through
`KeepAlive`. This external LaunchAgent records local-health evidence for
operators and performs bounded auto-update rollback recovery, but it does
not kickstart the provider for normal liveness failures.

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
