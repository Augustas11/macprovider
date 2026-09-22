# Audit lane: ARCHITECTURE REVIEW — issue #1616 recovery hardening

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

This is an ARCHITECTURE lane. Focus on boundaries and contracts, not style.

- **Local-status contract.** `buyer_serving_hold` is a new field on
  `/v1/status` gated by a new `buyer_serving_hold_v1` capability, and
  SPEC-001 is bumped to 1.9.19 with normative text. Is the capability the
  right mechanism here, is the SPEC text consistent with what the code emits
  in every branch (donor mode, offline fallback, not-ready, unknown), and is
  `network_state`/`buyer_serving_authority` still unambiguously the
  authority? Is the field's presence consistent — it lives inside the
  `if let catalogStatus` block; is that the right scope?
- **Where diagnostics live.** Installed identity and the hardware-evidence
  outcome were added to the plain `doctor` report, NOT to the SPEC-035
  `doctor report --json` diagnostics schema (`malibu.provider-diagnostics.v2`).
  Is that the right home, or does splitting operator diagnostics across two
  surfaces create a contract problem? Should SPEC-035 have been amended?
- **New persistence surface.** `~/.config/macprovider/last-hardware-evidence.json`
  is a new file in a directory the install transaction snapshots and rolls
  back. Should it be part of the transaction snapshot/rollback set, or is
  leaving it outside correct for a diagnostics breadcrumb? Does it need
  retention/rotation? Does it duplicate state already owned by
  `last-recommendation.json` or `AutotuneProbeCache`?
- **Installer transaction invariants.** The E2 repair runs BEFORE
  `begin_install_transaction` records service-active state, deliberately
  removing an unrecoverable precondition rather than relaxing the fail-closed
  guard. Is that the right layering? Does it weaken any documented rollback
  invariant? Is doing it for all four labels (provider, legacy provider,
  watchdog, legacy watchdog) coherent, or does one of them need different
  treatment?
- **Deliberate non-changes.** Distinguishing `waiting_trust` from `pending`
  was NOT done because the deployed CLI validates the evidence response with
  an exact key-set match, so any new field or changed status string breaks the
  fleet. Verify that reasoning against the code, and say whether the chosen
  path (defer to a request-schema version + fleet floor) is right.

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
