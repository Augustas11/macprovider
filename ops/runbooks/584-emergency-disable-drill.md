# #584 Pearl emergency-disable drill paper

Use this runbook only to prove the production canary kill switch works end-to-end
on Pearl **without** re-enabling the scheduled canary, creating enable gates, or
starting `canary-buyer.timer`.

Issue: https://github.com/Augustas11/macprovider/issues/584  
Related code: `test/e2e/canary-buyer/emergency-disable.sh`  
Exception: `exc-canary-disabled-enable-gate` (must remain **active** after this drill)

## Hard stop conditions

Stop without improvising if any of these is true:

- an operator has not approved this exact drill (approver + UTC timestamp recorded);
- anyone proposes creating `/etc/macprovider-canary-buyer/enabled`,
  `/etc/macprovider/canary-buyer.enabled`, or enabling `canary-buyer.timer`;
- `pool.canary_enabled` would be flipped to `true`;
- the drill would issue buyer traffic, qualification load, or a full probe replay;
- the host under test is not Pearl production (this paper is Pearl-scoped);
- evidence would include raw buyer/operator tokens or other secrets.

This drill **never** authorizes production re-enable. Re-enable remains a separate
reviewed go/no-go + timer flip after physical baselines land.

## Pre-conditions (observe only)

Record UTC timestamps and command output for each:

```bash
systemctl is-enabled canary-buyer.timer || true
systemctl is-active canary-buyer.timer || true
systemctl is-active canary-buyer.service || true
test ! -e /etc/macprovider-canary-buyer/enabled; echo "enable_gate_a_absent=$?"
test ! -e /etc/macprovider/canary-buyer.enabled; echo "enable_gate_b_absent=$?"
test -e /var/lib/macprovider-canary-buyer/DISABLED; echo "disabled_present=$?"
# coordinator overlay observation (read-only)
# pool.canary_enabled must be false
```

Expected baseline before the drill (2026-07-22 ground truth):

| Check | Expected |
|-------|----------|
| timer enabled | `disabled` or `not-found` |
| timer active | `inactive` / `unknown` |
| service active | `inactive` |
| both enable gates | **absent** |
| `DISABLED` sentinel | **present** |
| `pool.canary_enabled` | `false` |

If the timer is already disabled and `DISABLED` is present, the drill still
proves the script is **idempotent** and leaves the same fail-closed posture.

## Operator approval record

Before any mutation, record all of:

- approver and UTC timestamp;
- Pearl host identity;
- absolute path to the reviewed `emergency-disable.sh` (repo SHA or installed
  digest);
- statement: “one shot drill; no canary enable; no timer flip; no buyer load”;
- artifact destination directory (operator-local, mode `0700`).

Use the approval comment URL as the evidence cross-link on issue #584.

## Execute (exactly once)

```bash
ART="/var/tmp/macprovider-584-emergency-disable-$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p -m 700 "$ART"
# capture pre-state
{
  date -u +%Y-%m-%dT%H:%M:%SZ
  systemctl is-enabled canary-buyer.timer 2>&1 || true
  systemctl is-active canary-buyer.timer 2>&1 || true
  systemctl is-active canary-buyer.service 2>&1 || true
  ls -la /etc/macprovider-canary-buyer/enabled \
         /etc/macprovider/canary-buyer.enabled \
         /var/lib/macprovider-canary-buyer/DISABLED 2>&1 || true
} >"$ART/pre.txt"

# Install/use the reviewed script from the signed tree or repo checkout.
sudo /opt/macprovider-canary-buyer/emergency-disable.sh \
  >"$ART/disable.out" 2>"$ART/disable.err"
echo $? >"$ART/disable.exit"

{
  date -u +%Y-%m-%dT%H:%M:%SZ
  systemctl is-enabled canary-buyer.timer 2>&1 || true
  systemctl is-active canary-buyer.timer 2>&1 || true
  systemctl is-active canary-buyer.service 2>&1 || true
  ls -la /etc/macprovider-canary-buyer/enabled \
         /etc/macprovider/canary-buyer.enabled \
         /var/lib/macprovider-canary-buyer/DISABLED 2>&1 || true
  # optional: sha256 of installed units/scripts for drift evidence
} >"$ART/post.txt"
```

## PASS criteria (all required)

1. Exit code `0` from `emergency-disable.sh`.
2. stdout contains `class=emergency_disabled` and `scheduler_stopped=true`.
3. `DISABLED` exists at `/var/lib/macprovider-canary-buyer/DISABLED` after the run.
4. Both historical enable gates remain **absent**.
5. `canary-buyer.timer` is not enabled and not active.
6. `canary-buyer.service` is not active.
7. No buyer token, operator token, or probe attempt file was created by the drill.
8. `pool.canary_enabled` remains `false` (read-only check).

## FAIL / abort

- Non-zero exit, or `class=emergency_disable_failed`.
- Timer or service still active/enabled after the script.
- Any enable gate created during the drill.
- Any attempt to “fix forward” by starting the timer.

On FAIL: leave the host fail-closed (`DISABLED` present, timer disabled). Do **not**
retry automatically. File a new approved attempt with a new artifact directory.

## Evidence to post on #584

Post a **minimized** issue comment (no secrets) with:

- approval URL + UTC;
- repo / installed script identity (path + SHA-256 if available);
- PASS/FAIL table for the eight criteria above;
- redacted pre/post excerpts (unit states + gate presence only);
- absolute artifact path on Pearl (operator retention, not the public issue).

## Hermetic stand-in (no Pearl required)

The software controls for this drill are already covered by:

```bash
bash test/e2e/canary-buyer/run-canary.test.sh
```

That suite proves:

- emergency sentinel returns distinct no-load status `20` before credentials;
- `emergency-disable.sh` creates the sentinel, removes the enable gate, and
  fails closed if systemd/launchd units remain active;
- scheduled paths never amplify load after disable.

Hermetic PASS does **not** close the Pearl physical drill gate. It only proves
the scripts are safe to run when an operator approves the Pearl shot.

## Explicit non-goals

- Re-enabling `canary-buyer.timer`
- Creating enable gates
- Flipping `pool.canary_enabled`
- Qualification load, full fleet probes, or #540 AEAD buyer series
- Clearing `exc-canary-disabled-enable-gate`
