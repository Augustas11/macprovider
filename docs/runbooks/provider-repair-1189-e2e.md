# Provider repair #1189 end-to-end reproduction

Incident #1189 stranded an external provider: a stale watchdog running under
the legacy label, plus a HOME ACL write barrier, plus a stale pending/rollback
marker, together blocked repaired provider software from landing even after
PR #1208 (`aee7d157`, Malibu Repair recovers stale watchdog + HOME ACL) and
PR #1228 (`16b0fa4d`, watchdog no longer owns rollback — it defers) shipped to
`main`. Before asking the real #1189 provider to download the new DMG and run
Repair, we need graduated proof that the fix actually recovers their exact
failure shape. This runbook is that fidelity ladder.

## The fidelity ladder

| Tier | What it runs | Real vs. mocked | Proves | Status |
| --- | --- | --- | --- | --- |
| T1 | `phase3-binary/dist/test/repair_1189_reproduction.test.sh` | Real macOS filesystem ACLs; launchd mocked | The four #1189 ingredients compose correctly in one sandbox HOME | Done, see below |
| T2 | Full `install.sh` transaction against a mock coordinator + offline catalog | Real installer script; coordinator and catalog stubbed | Rejoin logic end-to-end without touching the live network | Follow-up, not yet built |
| T3 | Malibu Repair button on a real, notarized DMG, on a spare canary Mac, against the live coordinator | Fully real | The actual last-mile path a sandbox cannot cover | **Required before messaging the real #1189 provider** |

Each tier only earns the claims of the tier below it. T1 passing does not mean
T2 or T3 passed. Do not message the real #1189 provider based on T1 or T2
alone.

## T1 — sandbox reproduction (this repo)

`phase3-binary/dist/test/repair_1189_reproduction.test.sh` builds ONE sandbox
`$HOME` containing all four #1189 ingredients at once:

1. The installer-inline watchdog on disk, wired to both the current
   (`live.malibu.provider-watchdog`) and legacy
   (`live.streamvc.macprovider-watchdog`) launchd labels.
2. A stale pending-autoupdate marker plus a rollback backup binary (the
   #1228 trap: an armed but unresolved update/rollback transaction).
3. A real macOS HOME ACL write barrier (`chmod +a "group:everyone allow
   write,append"` plus a `deny delete` ACE), planted with the real `chmod
   -a`/ACL syscalls — not simulated.
4. Full provider identity: `config.yaml`, `provider_id`, `wallet.json`, and a
   model weights file, fingerprinted before and after the run.

It then runs the actual functions extracted from `phase3-binary/dist/install.sh`
(`quiesce_repair_watchdogs_for_transaction`, `remediate_repair_home_write_acl`,
`validate_install_dir`) and the actual watchdog script
(`ops/macprovider-watchdog/watchdog.sh`'s installer-inline copy) — not
reimplementations — through three phases:

- **Phase A** — the stale watchdog ticks *before* repair runs, with the
  pending marker and ACL barrier both still in place. It must defer (per
  #1228): no rollback of the repaired binary, the pending marker survives, and
  the tick makes no `bootout`/`bootstrap`/`kickstart` launchctl calls. The
  sandbox gives the watchdog a resolvable, healthy-looking provider process (a
  faked `lsof` matching `provider_process_pid`'s expectations) so the tick
  takes the same "process present" path a real running #1189 provider would
  have taken, rather than an unrelated missing-process restart path that has
  nothing to do with the #1228 bug.
- **Phase B** — the real repair preflight runs: it quiesces (bootouts) *both*
  the current and legacy watchdog launchd labels, remediates the real HOME ACL
  barrier via `chmod -a`, and the test fingerprints config/provider_id/
  wallet/model bytes before and after to confirm the preflight is a pure
  precondition step that mutates nothing about the provider's identity.
- **Phase C** — the watchdog ticks again, post-repair. It must still be unable
  to undo the repair (#1228 holds after cutover, not just before it).

Real vs. mocked, precisely: filesystem ACLs (`chmod +a`/`chmod -a` on real
directories) are **real**. `launchctl` is a **PATH-resolved fake** — the test
does not set `MACPROVIDER_LAUNCHCTL`, so both the extracted repair functions
and the watchdog script pick it up exactly the way they would resolve the real
`launchctl` binary in production, just pointed at a script that logs and
returns canned output instead of talking to the real `launchd`. There is no
DMG, no Malibu.app, no GUI Repair button, and no coordinator in this tier.

Run it directly:

```bash
bash phase3-binary/dist/test/repair_1189_reproduction.test.sh
```

It requires real macOS (it SKIPs with exit 0 on any non-Darwin `uname -s`,
since it needs real filesystem ACL support) and is wired into
`make test-dist` and into the `swift-tests` CI job (`macos-15` runner) so it
runs for real on every PR that touches `phase3-binary/`.

### What T1 proves

- The four #1189 ingredients do not fight each other or produce a different
  failure shape when combined in one HOME than they do in isolation.
- The real repair functions (not test doubles of them) successfully quiesce
  both watchdog labels and remediate the ACL barrier together.
- Provider identity, config, wallet, and model bytes survive the repair
  preflight untouched.
- The #1228 no-rollback-ownership guarantee holds both before and after
  cutover under the full combined trap, not just in the isolated
  `watchdog_rollback_paths.test.sh` fixture.

### What T1 does NOT prove

- That the real, notarized DMG installer and Malibu.app Repair button perform
  the same sequence of calls as the extracted shell functions.
- That the real `launchd` behaves the way the mocked `launchctl` script
  claims it does (real `launchd` bootout/bootstrap semantics, timing, and
  failure modes are not exercised).
- That a real coordinator will actually re-admit and rejoin the repaired
  provider (no coordinator, no network, no catalog in this tier).
- Anything about the specific machine state of the real #1189 provider beyond
  the four ingredients this incident is documented to have hit.

## T2 — full install.sh transaction against a mock coordinator (follow-up, not yet built)

Run the real `install.sh` end-to-end (not just extracted functions) as a
repair transaction against a mock coordinator and an offline/local catalog, to
exercise the rejoin/re-admission logic that T1 does not touch. This closes
the gap between "the repair functions work in isolation" and "the full
installer transaction, as a real user would invoke it, gets a provider back
onto a coordinator." Not implemented as part of this change; track it before
relying on T1 alone for anything beyond the sandbox claims above.

## T3 — canary Mac, real DMG, live coordinator (required before messaging the real provider)

T3 is the last mile a sandbox cannot cover: real code signing/notarization,
the real Malibu.app GUI, the real Repair button, real `launchd`, and a real
rejoin against the **live** coordinator. It must run on a **spare canary Mac
that is NOT the real #1189 provider**.

### Preconditions

- A spare Mac (any Apple Silicon Mac not currently in the #1189 provider's
  hands) that you can freely wipe and reinstall.
- **Use a dedicated spare Mac — never a second macOS user account on a machine
  that has a live earner.** The updater targets the **global**
  `/Applications/Malibu.app` first (per
  `AutoUpdateMarker.malibuAppCandidates()`), which on a shared machine is the
  *live earner's* app, regardless of which user runs the test. During #1358
  acceptance (F1) a test run reached the live earner's `/Applications/Malibu.app`
  and was stopped **only** by POSIX permissions because the test account was
  Standard; an Administrator test account would have overwritten the live
  earner. A second user also cannot isolate unified-memory / thermal pressure:
  sustained cold model loads on an 8 GB box tripped the earner's own liveness
  watchdog. Tier-C acceptance (deliberate breakage + downgrade) must therefore
  run on separate hardware, not a second login.
- The new, notarized provider DMG build that includes both #1208
  (`aee7d157`) and #1228 (`16b0fa4d`).
- Network access to the live coordinator (`coordinator.malibu.tech`).

### Steps

1. On the canary Mac, install a provider build **predating** #1208/#1228
   (the last stable release before those two PRs) and let it fully onboard:
   confirm it appears healthy in the coordinator/provider directory.
2. Reproduce the #1189 failure shape on the canary Mac's real HOME, using the
   real primitives (not the test's extracted-function shortcuts):
   - Plant the real HOME ACL write barrier:
     `chmod +a "group:everyone allow write,append" ~` (and the matching
     `deny delete` ACE the incident showed).
   - Leave the watchdog running under the **legacy** launchd label
     (`live.streamvc.macprovider-watchdog`) if the installed build still uses
     it, or bootstrap it under that label manually if it doesn't.
   - Stage a stale `pending.json` autoupdate marker plus a rollback backup
     binary under `~/.local/share/macprovider/autoupdate/` and
     `~/.local/bin/`, matching the shape in
     `phase3-binary/dist/test/watchdog_rollback_paths.test.sh`'s fixture.
3. Confirm the canary Mac is now stuck the same way the real #1189 provider
   is: repair/update attempts fail against the ACL barrier, and the stale
   watchdog is present.
4. Download the new, notarized DMG (the one with #1208 + #1228) onto the
   canary Mac through the normal path (`get.malibu.tech/install.sh` or the
   DMG directly) — do not sideload the installer script by hand.
5. Launch Malibu.app and click the real **Repair** button in the GUI. Do not
   invoke `install.sh --repair` from a terminal for this step; the point of
   T3 is exercising the same code path a non-technical provider operator
   would.
6. Watch it through to completion.

### Acceptance criteria

T3 passes only if **all** of the following hold on the canary Mac after
Repair completes:

- The GUI Repair flow completes without requiring manual terminal
  intervention.
- The legacy watchdog launchd label is gone (or, if a compatibility bridge
  intentionally leaves it registered, it is provably inert — no rollback,
  no interference).
- The HOME ACL write barrier is gone (`ls -lde ~` shows no lingering
  `everyone allow write`/`add_file` ACE; the safe `deny delete` ACE, if any,
  may remain per the documented safe-ACL shape).
- The stale pending/rollback marker is resolved (consumed or cleanly
  quarantined by the installer/CLI transaction owner) — not silently
  rolled back by a watchdog.
- Provider identity (`provider_id`), wallet, and any downloaded model weights
  are byte-identical to before Repair ran.
- The provider **actually rejoins the live coordinator**: it shows up as
  healthy/routable in the coordinator's provider directory or admin view
  within a reasonable window after Repair finishes, and a real buyer request
  can be routed to it end-to-end.

Only once T3 passes on the canary Mac should the real #1189 provider be asked
to download the new DMG and run Repair. T1 (this repo's sandbox test) and any
future T2 give confidence the fix is directionally correct; neither is a
substitute for T3's live-coordinator rejoin proof.
