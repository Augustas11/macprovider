# AUDIT_MONITOR_EMAIL_MUTE_R1_ARCHITECT_PROMPT

You are auditing the ARCHITECT lane of a change to the Pearl-side observability
monitor in this repository (branch `fix/monitor-email-mute-provider-churn`).

## Audit target — the FULL fix as it will land

```
git diff origin/main -- phase4-coordinator/dist/monitor phase4-coordinator/dist/test/check_monitor_email_mute_test.sh
```

Files:

- `phase4-coordinator/dist/monitor/macprovider-monitor.py`
- `phase4-coordinator/dist/monitor/README.md`
- `phase4-coordinator/dist/test/check_monitor_email_mute_test.sh` (new)

Related unchanged context you should read:

- `phase4-coordinator/dist/monitor/macprovider-monitor.service` / `.timer`
- `phase4-coordinator/dist/test/check_monitor_sandbox_test.sh`
- `phase4-coordinator/dist/deploy-pearl-vps.sh` (monitor.env perms block)
- `ops/pearl-updater/macprovider-pearl-updater-alert` (a SEPARATE tool that
  reads the same `/etc/macprovider/monitor.env` and requires the keys
  `ALERT_EMAIL`, `GMAIL_USER`, `GMAIL_APP_PASSWORD`)

## What the change does and why

The monitor runs on a 3-minute systemd timer and emails every alerting state
transition. On the current single-Mac fleet, provider churn dominates: Pearl
journald shows 237 emailed alerts in 7 days, ~95% of them
`provider … dropped from pool`, `pool has 0 ready providers`, and
`gateway status -> idle`. The operator asked for those to stop while real
service-down alerts keep arriving.

The change tags every alert with a KIND and routes email per kind:
`provider`, `pool`, `gateway_status` are journal-only by default; `service`
and `static_feed` still email. `EMAIL_MUTED_KINDS` in
`/etc/macprovider/monitor.env` overrides (`all` / `none` / explicit list).

Lock bar: 0 critical, 0 high, 0 medium.

## Focus

- Is per-kind mail routing the right abstraction, or is this a rate-limiting /
  deduplication / flap-damping problem wearing a filter's clothes? The observed
  pattern is one Mac oscillating; argue which mechanism actually matches the
  failure mode, and whether the chosen one will still be right when the fleet
  has 20 providers instead of 1.
- Default-off vs config-off: the change hardcodes a default mute set in the
  script AND allows `EMAIL_MUTED_KINDS` to override it. Is a code-level default
  correct here, or should Pearl's `monitor.env` carry the whole policy so the
  routing decision is an ops artifact rather than a source-tree constant?
  Consider that `monitor.py` is redeployed by `deploy-pearl-vps.sh` while
  `monitor.env` is not overwritten.
- Kind taxonomy: are the five kinds the right cut? Is `gateway_status` really
  distinct from `service`? Does `pool` belong with `provider`? Will a future
  alert have no natural home, or force a wrong one?
- Layering: alert classification, routing policy, and delivery now all live in
  one 300-line script with no unit-test seam other than `runpy`. Is that
  proportionate to the problem, or is a seam warranted?
- Observability of the suppression itself: is the `N alert(s) journal-only`
  line enough for an operator to later reconstruct what was withheld and why?
  Is there a discoverability trap where someone debugging "why no email"
  cannot find the knob?
- Does the README/docstring accurately describe the shipped behavior, including
  the state-sealing consequence of muting? Any doc/code drift?
- Coupling to `ops/pearl-updater/macprovider-pearl-updater-alert` through the
  shared env file: is growing `monitor.env` into a multi-consumer config the
  right direction, and is the new key namespaced clearly enough?
- Reversibility: how does the operator restore the old behavior, and is that
  path documented and testable?

## Output format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity: `ARCH-C-1`, `ARCH-H-1`,
`ARCH-M-1`, `ARCH-L-1`. Each finding must cite concrete repo evidence
(file:line). Do not include Critical/High/Medium findings unless they should
block the merge. The stop bar is 0 C/H/M.
