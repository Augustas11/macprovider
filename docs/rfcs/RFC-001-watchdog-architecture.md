# RFC-001: Long-term watchdog architecture

- Status: **Draft (for adversarial review)**
- Issue: #1203 (design child of #1200; epic #1184)
- Author: provider-platform
- Date: 2026-08-29
- Supersedes design intent of: none
- Depends on landed work: #1204 / PR #1208 (`aee7d157`, Repair recovers stale
  watchdog + HOME ACL barrier), #1202 / PR #1228 (`16b0fa4d`, watchdog no longer
  owns update/rollback authority)

> This RFC decides the **long-term** shape of provider liveness supervision. It
> proposes no executable change. Any behavior change lands only via an explicit
> follow-up code PR that cites this RFC.

## 1. Problem & context

Incident #1189 stranded an external provider: a **stale watchdog under an old
label kept acting as a second update/rollback owner** and prevented repaired
provider software from landing, while a local HOME ACL barrier blocked the
recovery write. The immediate fixes landed:

- P0 (#1204): Malibu Repair now tolerates the ACL barrier, quiesces stale
  watchdog authority, and replaces the stack while preserving identity.
- P1 (#1202): the watchdog **no longer owns update/rollback** — on a pending
  autoupdate marker it now defers to the transaction owner
  (`ops/macprovider-watchdog/watchdog.sh:476-489`).

Those closed the acute failure. This RFC answers the remaining structural
question #1200 deferred here: **do we still need a separate, mutable background
watchdog process at all, or can the platform be simplified** — and if we keep
one, what is the smallest defensible thing it may do, so this failure class
cannot recur.

## 2. Inventory — what the watchdog does today (post-#1202)

Verified in `ops/macprovider-watchdog/watchdog.sh` (565 lines) and
`live.malibu.provider-watchdog.template.plist`. The agent is a **periodic
LaunchAgent** (`StartInterval 60`, `RunAtLoad`, `ProcessType Background`) — a
probe that runs each minute and exits, **not** a `KeepAlive` daemon.

| # | Job | Mechanism | Mutation? | Notes |
|---|---|---|---|---|
| J1 | **Restart a wedged provider** | `launchctl kickstart -k` when armed, `/v1/health` fails, and `/v1/status` recommends restart, outside cooldown (`:516-538`) | yes (restart) | The core irreplaceable job: provider PID is *alive* but not serving. |
| J2 | **Restart an exited provider** | `kickstart` when launchd has no validated PID and no active lease (`:501-513`, the `missing_validated_pid` path) | yes (restart) | **Redundant today:** the provider LaunchAgent already ships `KeepAlive` (see below), so this is a *second* exit-restart authority, not the only one. |
| J3 | **Boot-scoped arming** | Arms only after one local `/v1/health` success in the current boot; stores boot id in `ARMED_FILE` (`:540-548`, re-disarms on reboot) | yes (marker file) | Prevents killing a cold-cache model load (10–20 min) after reboot. |
| J4 | **Startup/maintenance lease grace** | Honors a signed lifecycle lease → bounded grace (`:216-236`, `:506-518`) | no | Cold-load / maintenance window protection. |
| J5 | **Operator-pause protection** | Respects `operator_paused` / `state==paused_by_operator` (`:205-214`) | no | Never restarts a deliberately paused provider. |
| J6 | **Restart cooldown** | `provider_restart_cooldown_active` throttles kicks (`:445-455`) | no | Anti-restart-storm. |
| J7 | **Coordinator-connection observation** | Logs a warning on no ESTABLISHED TCP; **advisory only, never kicks** (`:557-563`) | no | Post-fix: coordinator reachability is not a restart trigger. |
| J8 | **Autoupdate recovery** | **Defers** to the transaction owner on a pending marker; skipped for headless/system-domain topologies (`:476-489`) | **no (post-#1202)** | Authority already removed; this RFC proposes to lock that in normatively. |

**Decomposition (the key move):** every job is one of two kinds.

- **Liveness supervision** — J1, J2, J3, J4, J5, J6: *keep the provider serving,
  restart it if it stops or wedges, without fighting legitimate cold-load / pause
  windows.* Pure liveness. Its only mutation is **restart**.
- **Update/rollback authority** — J8: *rewrite provider artifacts.* Already
  removed from the watchdog (#1202); belongs solely to the installer/CLI/Malibu
  transaction owner.

The incident was caused entirely by the second kind leaking into a stale
background component. The first kind never caused #1189.

**Baseline correction — exit-restart is already double-owned.** The provider
service is *not* supervised only by the watchdog. The installer already renders
`KeepAlive` on the provider LaunchAgent today —
`KeepAlive{SuccessfulExit:false}` with `ThrottleInterval 10` for the
`consumer_user` profile
(`phase3-binary/dist/install.sh` `render_plist` ≈`:10278-10289`, `:10334`;
`phase3-binary/dist/compatibility-set-assets/provider-launch-agent.plist.template:18-23`,
`:37`), and `KeepAlive{true}` for the headless profile
(`install.sh` ≈`:10287`). The split (launchd `KeepAlive` owns routine
exit-restart; the watchdog does **not** restart for routine health) is already
normative in `specs/SPEC-025-native-mac-app.md:180-182` (v0.8). So today there
are **two** exit-restart authorities for the same process: launchd `KeepAlive`
*and* the watchdog's `missing_validated_pid` kickstart (J2,
`ops/macprovider-watchdog/watchdog.sh:504-513`). This RFC's proposed change to
exit-restart is therefore **not** "add `KeepAlive`" (it exists) but "**remove the
watchdog's redundant J2 exit-restart**" so launchd is the single exit-restart
owner.

## 3. The two hard constraints any option must satisfy

1. **Some wedge classes need an out-of-process prober.** A provider can be *alive
   but not serving*. This is not one uniform class:
   - The provider already carries an **in-process heartbeat watchdog** that
     *exits* the process on a heartbeat/runtime stall
     (`phase3-binary/Sources/macprovider-cli/CoordinatorClient.swift` heartbeat
     watchdog task ≈`:280`, exit hook ≈`:430`, timeout/cancel ≈`:3943`), which
     lets launchd `KeepAlive` restart it. That is **complementary partial
     coverage** for stalls the process can still detect from inside itself.
   - An **out-of-process** observer is strictly necessary only for the
     **process-wide-freeze class**: a hard deadlock or blocked syscall where the
     in-process watchdog can no longer run its own check, so nothing inside the
     CLI can exit or restart the CLI.
   - A distinct and nastier case is **listener-alive / model-dead**: the HTTP
     listener still answers, so `/v1/health` returns HTTP 200 while the model
     thread is dead. An external `/v1/health` probe **cannot** catch this. It
     requires a **model-thread-advanced liveness token** the provider surfaces in
     `/v1/status` (a monotone counter / token-age the prober can compare across
     ticks). This resolves Open Question #1, and the recommendation's wedge-prober
     value **depends on that token existing** — without it the prober cannot
     distinguish a served-but-dead provider from a healthy one.
2. **The headless fleet has no GUI.** Many providers run without Malibu.app
   ever launching (`MACPROVIDER_HEADLESS=1`, SSH/system-domain installs). Any
   design that parks liveness duties in the Malibu app supervises nothing on
   those nodes.

These two constraints are what make this a real decision rather than a cleanup.

## 4. Options considered

### Option A — Keep a watchdog, reduced authority (status quo post-#1202)
A separate periodic agent that restarts on exit *and* wedge, with update/rollback
authority already fenced out.

- **Handles:** app-closed, CLI wedge, cold load (lease + boot-arm), coordinator
  outage (advisory), operator pause, headless, system-domain.
- **Loses:** nothing functionally.
- **Cost / risk:** a mutable shell component still exists — the thing #1200
  worried about. It writes marker files and can `kickstart`. Its worst historical
  behavior (self-restoring stale plist / artifacts) is *already* removed, but the
  component itself remains a surface.

### Option B — launchd `KeepAlive` + CLI self-reported health
Delete the watchdog; rely on launchd to restart the provider, and have the CLI
drive its own health.

- **Fatal gap:** `KeepAlive` restarts on **process exit only**. launchd has **no
  application-level health probe**: its filesystem-oriented triggers
  (`KeepAlive` dictionary keys, `WatchPaths`, `QueueDirectories`) fire on path or
  exit state, and **none of them evaluates `/v1/health`**. A wedged-but-alive
  provider (J1) is therefore **never** restarted. To bridge this with a launchd
  path trigger you would need a *separate trusted writer* to drop a liveness
  token on disk — which is, functionally, the prober this option was trying to
  delete. The in-process heartbeat watchdog covers only stalls the process can
  still detect from inside itself; a hard deadlock cannot run its own self-check.
  This **loses J1**, the one job that motivated the out-of-process watchdog.
- **Also loses:** J3/J4 cold-load grace (`KeepAlive` + `ThrottleInterval` only
  rate-limits restarts; it cannot distinguish a legitimate 10–20 min cold load
  from a wedge), and J5 operator-pause (would require the provider to exit
  cleanly on pause and launchd `Disabled` toggling — more moving parts, not
  fewer).
- **Verdict:** rejected. It is simpler only because it drops the hardest,
  most valuable behavior.

### Option C — Fold all duties into Malibu / installer / CLI, no separate mutable background component
No standalone supervisor; the app/installer own everything.

- **Fatal gap (constraint 1):** self-supervision paradox for the hard-freeze
  class — nothing restarts the CLI when the CLI is deadlocked. (The provider's
  in-process heartbeat watchdog helps for *detectable* stalls by exiting into
  launchd `KeepAlive`, but it cannot cover a process-wide freeze, which is
  exactly the class an external prober exists for.)
- **Fatal gap (constraint 2):** the headless fleet has no Malibu.app running to
  hold the duty.
- **Verdict:** rejected as a *complete* solution. Its *good idea* — "no
  self-restoring mutable component, single transaction owner for updates" — is
  already realized by #1202 and is preserved in the recommendation below.

## 5. Recommendation — **Option A, hardened into a split supervisor**

Keep an out-of-process supervisor because constraints 1–2 make it
**architecturally necessary**, but shrink it to the irreducible liveness core and
let launchd own the part launchd is actually good at:

1. **launchd `KeepAlive` owns exit/crash restart (J2) — and already does.**
   Native, Apple-maintained, no script, cannot go stale or be ACL-blocked. The
   provider LaunchAgent **already renders** `KeepAlive` today
   (`consumer_user`: `KeepAlive{SuccessfulExit:false}` + `ThrottleInterval 10`;
   headless: `KeepAlive{true}` — `install.sh` `render_plist`;
   `provider-launch-agent.plist.template:18-23,37`). The proposed change is
   therefore **not** to add `KeepAlive` — it exists — but to **remove the
   watchdog's redundant J2 exit-restart** (`watchdog.sh:504-513`, the
   `kickstart_provider "missing_validated_pid"` path) so launchd is the *single*
   exit-restart owner instead of one of two. **Retain the existing
   `KeepAlive{SuccessfulExit:false}` + `ThrottleInterval 10`** by profile; do
   **not** invent a `Crashed`+`SuccessfulExit` combination — the current keys
   already cover exit/crash restart. Any follow-up must also preserve the
   SPEC-020 R-3.8 one-shot updater choreography — the updater helper is
   deliberately `KeepAlive:false` / `LaunchOnlyOnce:true`
   (`specs/SPEC-020-provider-autoupdate.md:594-595`) and must not be swept into a
   blanket `KeepAlive` change to the provider service.
2. **A minimal wedge-prober owns health restart (J1, J3–J6).** The retained
   agent does exactly one mutating thing: `launchctl kickstart -k` when armed +
   `/v1/health` fails + `/v1/status` recommends + not paused + outside cooldown.
   It keeps boot-arming, lease grace, operator-pause, and cooldown. It writes
   **only** its boot-arm/cooldown markers. It performs **no** artifact writes,
   **no** update, **no** rollback — normatively, not just by current
   convention.
3. **Update/rollback authority stays with the transaction owner (J8),** exactly
   as #1202 established. The supervisor may *observe and report* a pending
   marker; it may never act on one.
4. **The supervisor is installer-owned and non-self-restoring.** It must not be
   able to reinstall or roll back *itself* or its plist; only the
   installer/Repair path writes the supervisor. This directly forecloses the
   #1189 mechanism (a stale supervisor resurrecting itself).

This is strictly smaller than today's watchdog (exit-restart moves to launchd;
authority is normatively nil) while preserving every failure-mode J1–J7. It
rejects B (keeps wedge detection) and rejects C's completeness (keeps an
out-of-process prober for headless) while adopting C's single-owner-for-updates
principle.

### Failure-mode matrix

| Failure mode | A (rec.: launchd + wedge-prober) | B (KeepAlive only) | C (fold into app) |
|---|---|---|---|
| App/GUI closed | ✅ prober independent of GUI | ✅ | ❌ headless has no app |
| Provider process exits/crashes | ✅ launchd KeepAlive | ✅ | ⚠️ only if app running |
| **CLI wedged (alive, not serving)** | ✅ prober via `/v1/health` | ❌ **not detected** | ❌ self-supervision paradox |
| Cold model load (10–20 min) | ✅ lease + boot-arm | ❌ KeepAlive may fight it | ⚠️ needs re-implementation |
| Coordinator outage | ✅ advisory, no kick | ⚠️ irrelevant/none | ⚠️ needs re-implementation |
| Update interrupted | ✅ transaction owner | ⚠️ undefined | ✅ single owner |
| Rollback | ✅ transaction owner only | ⚠️ undefined | ✅ single owner |
| Operator pause | ✅ honored | ❌ needs extra plumbing | ⚠️ needs re-implementation |
| Headless provider | ⚠️ agent runs headless, but wedge/exit **restart target is wrong domain** [^domain] | ✅ | ❌ |
| System-domain install | ⚠️ autoupdate-skip is coded, but **kickstart/print use the GUI domain** [^domain] | ✅ | ❌ |

[^domain]: **The wedge/exit restart hardcodes the GUI domain.** Both the
    PID-probe (`watchdog.sh:131`) and the restart (`watchdog.sh:460`) target
    `gui/$(id -u)/$LABEL`, but the headless provider is a **system**
    LaunchDaemon `system/live.malibu.provider` (`install.sh:199,235-244`).
    `MACPROVIDER_LAUNCHD_DOMAIN=system` only gates *autoupdate deferral*
    (`autoupdate_recovery_supported`, `watchdog.sh:487`) — it does **not** switch
    the kickstart/print domain. So on headless/system-domain nodes the prober's
    `launchctl print`/`kickstart` address no live service and liveness
    supervision does not actually act. A follow-up must make the restart target
    **domain-aware** before these cells can be ✅. Note also that
    `specs/SPEC-020-provider-autoupdate.md:31-35` (v0.1.12) declares
    **system-domain headless autoupdate/rollback an explicit unsupported
    boundary**, so headless liveness supervision and headless update/rollback are
    two separate gaps, not one.

## 6. Migration plan (avoid another stranded cohort)

The #1189 lesson is that a **stale supervisor under an old label** keeps acting.
Migration must therefore *neutralize old authority*, not merely install new.

1. **Label inventory & takeover.** Enumerate every historical supervisor label
   (current `live.malibu.provider-watchdog`; legacy pre-rebrand
   `live.streamvc.macprovider-watchdog` and any earlier). Migration must
   `bootout` each legacy label and `bootstrap` the new one. The window to close
   is **WEDGE-restart only**, not exit-restart: launchd `KeepAlive` on the
   *provider* service keeps owning exit-restart continuously **across a
   watchdog-label swap** (the provider service is not rebooted by the swap), so
   the only supervision that actually lapses while labels are exchanged is the
   out-of-process **wedge** prober. Resolve the double-kick / no-prober risk
   (Open Question #4) with a short **hand-off lease**: the outgoing label yields
   a bounded, transaction-owned lease and the incoming label refuses to kick
   until it holds it — this bounds the no-wedge-prober window explicitly rather
   than assuming `bootout`-then-`bootstrap` is atomic. It is **not** atomic
   today: repair quiesces the old/legacy watchdogs (`install.sh:12507`) in a
   phase separate from `install_watchdog`, which reclaims labels, writes files,
   and bootstraps (`install.sh:11059`); a **reboot or failure between those
   phases** can leave either no wedge-prober or a stale label. The migration
   contract must therefore be **reboot-resumable** (a persisted transaction
   marker that resumes the hand-off on next boot) and must carry **per-phase
   post-reboot tests**, not only quiesce/reject tests.
2. **Deliver the swap by profile — a single carrier re-strands one cohort.** The
   supervisor swap must reach *both* profiles, and they have **different**
   delivery paths:
   - **`consumer_user`:** land it through the ACL-tolerant **Malibu Repair**
     path (#1204) so homes with the HOME ACL barrier can still receive it. This
     path requires a bundled Malibu.app payload (`MACPROVIDER_BUNDLED_APP`), so
     it is viable only where Malibu.app can run.
   - **`headless_fleet`:** by this RFC's own §3 constraint 2 these nodes have
     **no Malibu.app**, so Malibu Repair cannot reach them and fails closed.
     Deliver the swap to headless nodes via an **SSH-invoked `install.sh` repair**
     with `MACPROVIDER_REPAIR_EXISTING_INSTALL=1` (`install.sh:21`), which
     replaces the stack in place without a GUI carrier.

   A **single Malibu-Repair rollout re-strands every headless node** — exactly
   the #1189 failure shape one layer up. Migration is not complete until the
   headless SSH carrier ships alongside it.
3. **Neutralize before replace.** Quiesce the old label's authority (as P0
   already does) *before* installing the split supervisor, so an old agent can't
   fight the new one during the swap.
4. **Idempotent & reversible-forward only.** Re-running migration converges; it
   never rolls the supervisor backward to a legacy label.
5. **Legacy-label kill-switch.** A signed, transaction-owned contract is the
   *only* thing that may (re)authorize a legacy label; absent it, legacy labels
   stay booted-out permanently.

## 7. Telemetry required to prove fleet recovery

Recovery must be observable from the coordinator, not by SSH (the #1189 blind
spot). Building on #1278 (heartbeat hardware/version refresh + autoupdate-event
ingest):

- **Supervisor action events:** emit `{provider, ts, action=restart, reason ∈
  {exit, wedge}, boot_id, cooldown_state, seq, service_instance}` on the
  heartbeat uplink so the coordinator can see *why* a node restarted and prove
  wedge-recovery worked. The sequence/instance fields let the coordinator
  correlate a kickstart with the *specific* provider instance that came back.
- **Post-restart sustained-serving dwell:** report how long the provider stayed
  in `serving` after a restart (a dwell counter reset on each restart). A restart
  followed by a short dwell and another restart is a **flap**; without a dwell
  metric a node that flaps restart → brief healthy heartbeat → wedge → restart
  looks healthy in aggregate. This makes a **restart-loop flap** observable, not
  just a single recovery.
- **Deep-liveness token-age signal:** surface the age of the model-thread
  liveness token (the token from §3 / `/v1/status`) on the heartbeat. A rising
  token age with a still-`serving` HTTP surface is the listener-alive/model-dead
  wedge that `/v1/health` cannot see; reporting it makes an **undetected wedge**
  observable coordinator-side even before the prober acts.
- **Supervisor topology beacon:** report which supervisor label + version is
  active, so a stale legacy label anywhere in the fleet is visible instead of
  silent (would have surfaced #1189 fleet-wide on day 0).
- **Autoupdate-deferral events:** when the prober observes a pending marker and
  defers, report it — so a stuck transaction owner is distinguishable from a
  healthy node.
- **Acceptance signal:** a node that was wedged returns to `serving` with a
  `reason=wedge` restart event, a **sustained-serving dwell above threshold**,
  and no accompanying artifact-write event — proving liveness recovery happened,
  *held*, and involved *no* rollback authority.

**Keep this a separate telemetry contract.** These supervisor/liveness signals
must **not** be smuggled into `last_autoupdate_event`. SPEC-020's event model is
autoupdate-specific, its watchdog is barred from mutating update/rollback state
(`SPEC-020:628`), and coordinator-side aggregation is explicitly deferred
(`SPEC-020:1393`). A follow-up must declare a **new supervisor telemetry
contract** (its own event type / schema) rather than overloading the autoupdate
event, so liveness reporting stays independent of signed-artifact and rollout
semantics.

## 8. Rejected alternatives (summary)

- **Pure launchd `KeepAlive` (Option B):** loses hard-wedge detection (J1) and
  cold-load grace; simpler only by dropping the hardest value. Rejected.
- **Fold-into-app (Option C):** self-supervision paradox + headless fleet has no
  app. Rejected as a complete solution; its single-owner-for-updates principle is
  adopted.
- **Keep today's watchdog unchanged:** acceptable but leaves exit-restart in a
  shell component launchd could own natively, and leaves "no artifact writes" as
  convention rather than a normative guarantee. The recommendation is strictly
  smaller and harder to regress.

## 9. Open questions (for reviewers)

1. **Resolved (pending a dependency).** There *is* a hard-wedge class the
   external `/v1/health` probe cannot catch — listener-alive / model-dead, which
   answers HTTP 200 while the model thread is dead (§3). The resolution is to
   require a **model-thread-advanced liveness token surfaced in `/v1/status`**
   (a monotone counter / token-age). The recommendation's wedge-prober value
   **depends on this token existing**; a follow-up must add it before the prober
   can claim to cover this class.
2. **Closed.** launchd `KeepAlive` fires **only on process exit**, and both a
   cold model load (10–20 min) and an operator pause **keep the process alive**,
   so exit-restart cannot fight cold-load grace or pause — the two never race.
   Exit-restart therefore does *not* need to move back into the prober.
   *Caveat:* this holds only while pause and cold-load keep the process alive. If
   a *future* implementation ever expresses operator-pause as a **clean process
   exit**, the headless profile's `KeepAlive{true}` would fight it — such a
   design would have to transactionally `Disable` the launchd job instead of
   exiting, and is out of scope here.
3. **Open.** Should the wedge-prober be rewritten off shell (a signed, minimal
   binary) to remove the "mutable script on disk" surface entirely, or is a
   Repair-owned/non-self-restoring shell script sufficient?
4. **Resolved.** `bootout`-then-`bootstrap` is **not** atomic (§6.1), so a bare
   swap is unsafe. Use a short **transaction-owned hand-off lease** plus a
   reboot-resumable migration marker; the incoming label refuses to kick until it
   holds the lease, bounding the no-wedge-prober window (exit-restart is
   unaffected because launchd `KeepAlive` owns it across the swap).

## 10. Acceptance-criteria mapping (#1203)

- ✅ Names recommended architecture (§5) and rejected alternatives (§4, §8).
- ✅ Separates provider-uptime needs from update/rollback authority (§2 two-axis
  decomposition; §5.2–5.3).
- ✅ Migration safety for current and legacy labels (§6).
- ✅ Telemetry to prove fleet recovery (§7).
- ✅ No executable behavior change in this issue; changes land via cited
  follow-up PRs only (header + §5 framing).
