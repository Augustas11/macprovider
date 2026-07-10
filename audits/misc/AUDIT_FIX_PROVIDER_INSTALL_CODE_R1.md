# Provider install/update hardening — CODE lane R1

You are auditing branch `fix/deepsec-provider-install-update` from the
CODE lane. Audit the implementation diff against `origin/main`.

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

If `phase3-binary/dist/rollback.sh` is absent, verify whether the
embedded rollback implementation in the watchdog script and installer
heredoc is behaviorally sufficient and drift-tested. Flag as MEDIUM or
higher if that choice leaves duplicated, inconsistent, or untested
rollback behavior.

## What To Verify

- Expired but otherwise valid auto-update pending markers recover from
  backup instead of being rejected before rollback.
- The CLI and watchdog agree on the pending-marker state machine and do
  not leave a half-installed binary in a state no later tick can recover.
- Unsigned release metadata cannot persist signed-policy or trust state.
- Manifest creation and uninstall readback enumerate all provider and
  watchdog launchd artifacts, binaries, symlinks, and data directories.
- Custom `--prefix` installs render the provider `WorkingDirectory`
  consistently into generated launchd plists.
- Port validation rejects non-numeric, out-of-range, and in-use values
  before writing config or plist files.
- Provider token writes use a single lock covering read-modify-replace.
- Control socket connect rejects overlong paths before the syscall.
- Shell tests exercise the shell branches they claim to cover, not just
  static greps.

## Output Format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings ordered by severity: `CODE-C-1`,
`CODE-H-1`, `CODE-M-1`, `CODE-L-1`, etc. Each finding must cite
file:line evidence and the concrete failure mode.
