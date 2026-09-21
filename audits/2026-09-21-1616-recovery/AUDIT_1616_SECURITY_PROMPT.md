# Audit lane: SECURITY REVIEW — issue #1616 recovery hardening

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

This is a SECURITY lane. Ignore style. Focus on:

- **Terminal / log injection.** `doctor` prints the installed identity, the
  compatibility-set manifest path, and the persisted hardware-evidence reason
  to an operator's terminal. Trace every one of those strings to its source.
  Can coordinator-controlled or attacker-influenced text reach the terminal
  with C0/C1 control bytes, including the single-byte CSI U+009B? Is the
  bound on reason length enforced on BOTH write and read? Is the JSON output
  safe to pipe into `jq` and into a log collector?
- **Trust boundary of the identity read.** `resolveInstalledIdentity` loads a
  signed manifest with `expectedVersion: nil` and
  `allowProviderVersionMismatch: true`. Confirm this value is display-only and
  is never used for admission, update eligibility, catalog trust, or any
  serve-time decision. If it leaks into a decision path, that is CRITICAL.
  Confirm signature verification is still performed (publicKeyPEM passed).
- **New on-disk state.** `HardwareEvidenceOutcomeStore` writes
  `~/.config/macprovider/last-hardware-evidence.json`. Check: O_NOFOLLOW on
  open, owner check, regular-file check, mode 0600 on create AND enforced on
  read, rejection of group/world-writable files, size bound, temp-file
  predictability and cleanup, and TOCTOU between lstat and open. Does the
  record persist anything sensitive (tokens, provider credentials, coordinator
  URLs with credentials, hardware identity hashes)? The reason strings
  originate partly from coordinator responses and partly from `"\(error)"` on
  a URLError — check what a URLError description can contain.
- **install.sh privilege and destructive action.**
  `release_dangling_launchd_registration` calls `launchctl bootout`, possibly
  via `sudo` in headless/system-domain installs. Confirm it cannot be induced
  to unload a service that is not ours: are the label, launchd-reported plist
  `path =`, and `program =` all pinned, is an ambiguous multi-line print
  rejected, and is the 64KiB inspection bound enforced? Can a symlink,
  a hostile `$HOME`, or a crafted launchctl print output defeat the checks?
  Can the new pre-transaction bootout destroy state that the rollback path
  would otherwise have restored?
- **Fleet/back-compat safety.** The new `buyer_serving_hold` status field and
  `buyer_serving_hold_v1` capability: does any existing strict decoder
  (Malibu app, journey harnesses, golden-frame fixtures) reject unknown
  fields or an unknown capability token?

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
