# Provider install/update hardening — SECURITY lane R1

You are auditing branch `fix/deepsec-provider-install-update` from the
SECURITY lane. Audit the implementation diff against `origin/main`.
Security bar for this wave is strict: target `0 LOW` as well as
`0 C/H/M`, because this change touches local destructive filesystem
operations and update trust state.

## Scope

- `phase3-binary/Sources/macprovider-cli/AutoUpdater.swift`
- `phase3-binary/Sources/macprovider-cli/AutoUpdateMarker.swift`
- `phase3-binary/Sources/macprovider-cli/SelfUpdate.swift`
- `phase3-binary/Sources/macprovider-cli/UninstallCommand.swift`
- `phase3-binary/Sources/MacProviderCore/ProviderTokenPersist.swift`
- `phase3-binary/app/Sources/Malibu/Agent/ControlSocketClient.swift`
- `phase3-binary/dist/install.sh`
- `phase3-binary/dist/uninstall.sh`
- `ops/macprovider-watchdog/watchdog.sh`
- `ops/macprovider-watchdog/install.sh`
- `ops/macprovider-watchdog/uninstall.sh`
- `ops/macprovider-watchdog/live.streamvc.macprovider-watchdog.template.plist`
- New/changed tests under `phase3-binary/Tests`, `phase3-binary/app/Tests`,
  and `phase3-binary/dist/test`.

If `phase3-binary/dist/rollback.sh` is absent, verify that rollback is
still single-source enough for security review: no inconsistent path
validation, no looser embedded copy, and no untested fallback branch.

## Security Invariants

- No path outside a canonicalized allowlist reaches `rm -rf`, including
  traversal, symlink, missing-path, or custom-prefix cases.
- Auto-update state transitions are recoverable after crash, sleep, or
  restart; malformed markers may be quarantined, but expired valid
  markers must restore from backup.
- Rollback only uses trusted marker fields after validating canonical
  paths, backup derivation, regular-file status, size, hash, and mode.
- A watchdog health verdict cannot be produced by an unrelated local
  process or by coordinator TCP reachability alone.
- Uninstall unloads all launchd labels tracked in the manifest before
  deleting files; missing-manifest fallback covers legacy provider and
  watchdog locations.
- Release-metadata policy or trust flags cannot be set from unsigned
  metadata.
- Concurrent token writes serialize and cannot silently drop another
  writer's key.
- Socket paths longer than the platform `sun_path` capacity fail before
  `connect`, with no silent truncation.
- Checked-in plist templates do not contain developer-machine absolute
  paths or resolved user paths.

## Output Format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=0`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings ordered by severity: `SEC-C-1`,
`SEC-H-1`, `SEC-M-1`, `SEC-L-1`, etc. Each finding must cite
file:line evidence and the concrete exploit or data-loss path.
