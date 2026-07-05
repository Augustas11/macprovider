# Provider install/update hardening — ARCHITECT lane R1

You are auditing branch `fix/deepsec-provider-install-update` from the
ARCHITECT lane. Audit the implementation diff against `origin/main`.

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

If `phase3-binary/dist/rollback.sh` is absent, decide whether keeping
rollback embedded in watchdog/install surfaces is an acceptable
architecture for this PR, or whether the plan requires a shared helper
to avoid future drift.

## Architecture Questions

- Is the documented update state machine complete enough for future
  maintainers to reason about CLI and watchdog recovery together?
- Are the install manifest fields sufficient for current provider,
  watchdog, custom-prefix, and legacy uninstall paths without becoming
  a fragile registry of unrelated state?
- Does the watchdog's new health model use the correct source of truth:
  installed provider process plus local provider health, with coordinator
  reachability only advisory?
- Are shell-delivered fixes and compiled Swift fixes clearly separated
  so release cadence is understandable and does not need flags?
- Is the prefix/port/plist templating approach consistent across the
  installer, standalone watchdog installer, checked-in templates, and
  uninstallers?
- Is the token-write locking boundary at the right layer, or should it
  move to a broader config-store abstraction?
- Are tests placed at the right level for the risk: unit tests for Swift
  contracts, shell tests for installer/uninstaller/watchdog branches,
  and drift checks for embedded scripts?

## Output Format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings ordered by severity: `ARCH-C-1`,
`ARCH-H-1`, `ARCH-M-1`, `ARCH-L-1`, etc. Each finding must cite
file:line evidence and the concrete maintenance or product risk.
