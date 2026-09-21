# Audit lane: CODE REVIEW — issue #1616 recovery hardening

Repo: macprovider. Worktree: `/Users/augstar/macprovider-1616-recovery`,
branch `fix/1616-install-recovery-hardening`, base `origin/main` (32c78fe1), rebased.

Review the FULL fix diff as it will land:

```
git -C /Users/augstar/macprovider-1616-recovery diff origin/main...HEAD
```

## What the change is

Four proved gaps from epic #1616 (provider install/reinstall/recovery UX):

1. **Finding B** — `malibu-cli doctor` now reports the signed installed
   identity (`compatibility_set_id`, envelope sha256, release version,
   provider-cli version, catalog release id, manifest path) read from the
   signed `compatibility-set.json` beside the installed binary.
   `--version` is deliberately NOT changed: `install.sh` and `package.sh`
   compare its output by exact string equality.
2. **buyer_serving_hold** — `/v1/status` now carries the coordinator's
   machine-readable reason for withholding buyer routing, behind a new
   `buyer_serving_hold_v1` local-status capability. `HTTPServer.handleStatus`
   switched from `CoordinatorReadinessClient.fetch` (Bool?) to
   `fetchReadiness` (keeps the hold).
3. **Hardware-evidence outcome record** — new
   `HardwareEvidenceOutcomeStore` persists the last submission outcome to
   `~/.config/macprovider/last-hardware-evidence.json`; `doctor` reports it.
4. **Finding E2** — `install.sh` gains
   `release_dangling_launchd_registration`, called from
   `begin_install_transaction` before the service-active probes, to release a
   launchd registration whose plist file is gone.

## What to look for

- Correctness of the `fetchReadiness` switch in `HTTPServer.handleStatus`:
  is the buyer-serving hold-through state machine (`applyCoordinatorBuyerServing`,
  `CoordinatorBuyerServingHold.resolve`) behaviourally identical to before?
  Is `buyer_serving_hold` ever reported when the verdict is held-true through
  an indeterminate probe? Is the `async let` → `await` restructuring still
  concurrent, or did it serialise a previously-parallel fetch?
- `DoctorRunner.resolveInstalledIdentity`: does the reported
  `compatibility_set_manifest_path` always name the file the identity was
  actually read from? `expectedVersion: nil` +
  `allowProviderVersionMismatch: true` — is any admission/trust decision made
  off this value, or is it display-only? Would a `swift build` binary with no
  signed set degrade cleanly?
- `HardwareEvidenceOutcomeStore`: atomic-replace correctness (fsync before
  rename, temp cleanup on every path, EINTR handling), behaviour when the
  parent directory is missing/hostile, and that a failed write never fails the
  submission it describes.
- `install.sh` `release_dangling_launchd_registration`: `set -euo pipefail`
  correctness (AND/OR lists, `|| print_rc=$?`, pipefail on the
  `launchctl | head` pipeline), quoting, and that every non-repairable path
  returns 0 and leaves the service loaded so the existing `die 70` guard still
  fires. Check the four call sites pass the right
  (plist file, launchd path, expected program, legacy program) tuples —
  especially the watchdog and legacy-watchdog ones.
- Test adequacy: do the new tests actually pin the behaviour claimed, or
  could they pass with the fix reverted?

## Round 2 — what changed since your last pass

Your previous pass on this branch reported MEDIUM findings. All of them were
fixed; review the FULL fix diff again as it will land, not only the delta:

- `buyer_serving_hold` is now clamped to the COMPUTED `networkState`, not the
  caller's verdict, so donor/unverified/not-ready states report null.
- `hardwareEvidenceEndpoint` rejects URLs with userinfo; transport failures
  report `transport error (URLError code N)` instead of interpolating the
  error, so a URL can no longer reach the persisted reason.
- Both watchdog dangling-repair call sites now pass `$WATCHDOG_PATH` as a
  third accepted executable; the installer test asserts on the CALL SITES.
- The hold projection is a named static
  `RouterHandler.reportableBuyerServingHold(readiness:resolvedBuyerServing:)`
  taking `Readiness`, unit-tested across every verdict.
- `DoctorRunner.resolveInstalledIdentity` takes the install authority and
  public key explicitly and is tested against signed fixtures (canonical
  precedence, launched fallback, manifest path, absent, untrusted signature).
- Evidence store: parent must not be group/world-writable, record must be
  exactly 0600 on read, parent directory fsynced after rename.

Re-verify these specifically, and re-check the whole diff for anything the
fixes introduced. Report only defects that remain.

## Bar

Report CRITICAL / HIGH / MEDIUM / LOW / INFO with file:line. The gate is
0 CRITICAL, 0 HIGH, 0 MEDIUM. Do not propose redesigns; report defects.
