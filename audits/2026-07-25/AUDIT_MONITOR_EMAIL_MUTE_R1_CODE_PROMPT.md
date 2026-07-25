# AUDIT_MONITOR_EMAIL_MUTE_R1_CODE_PROMPT

You are auditing the CODE lane of a change to the Pearl-side observability
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

- Correctness of the 2-tuple → 3-tuple alert refactor: is every alert site
  tagged, and is every consumer (`print`, `alerting`, `send_email`, subject
  line, body) unpacking the new shape correctly? Any residual index-based
  access (`alerts[0][1]`) that now reads the wrong element?
- `muted_kinds()` parsing: absent key, empty value, `none`, `all`, whitespace,
  case, duplicates, unknown names, and a value like `none,service`. Is any
  input silently interpreted as "mute everything" — i.e. could an operator
  typo suppress a real page?
- State-machine interaction. Before the change: `alerting and delivery is
  False` → do not `save_state`, so the transition re-fires next poll. After:
  fully-muted rounds call `send_email` not at all, so `delivery is None` and
  state advances. Is that correct and non-lossy, or can a real alert now be
  sealed away without ever being delivered anywhere?
- Mixed rounds: some muted, some emailable, SMTP fails. What re-fires on the
  next poll, and can a muted alert be lost or duplicated as a result?
- Does the change alter any observable journald line other than by adding
  `(kind)`? Existing operator greps / runbooks keyed on the old
  `[SEVERITY] message` prefix — is back-compat of the log shape preserved or
  knowingly broken? Cite any runbook or script that greps these lines.
- Does anything here break `ops/pearl-updater/macprovider-pearl-updater-alert`,
  which shares `monitor.env`? (Note the change adds a key rather than
  removing one — confirm.)
- Test quality: does `check_monitor_email_mute_test.sh` actually fail if the
  routing regresses? Does its `main.__globals__.update(m)` stubbing prove
  real behavior, or is it self-fulfilling? Would it catch a newly added,
  untagged alert site?
- Python compatibility with the Pearl runtime (`/usr/bin/python3` on the VPS)
  and the sandboxed systemd unit.

## Output format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity: `CODE-C-1`, `CODE-H-1`,
`CODE-M-1`, `CODE-L-1`. Each finding must cite concrete repo evidence
(file:line). Do not include Critical/High/Medium findings unless they should
block the merge. The stop bar is 0 C/H/M.
