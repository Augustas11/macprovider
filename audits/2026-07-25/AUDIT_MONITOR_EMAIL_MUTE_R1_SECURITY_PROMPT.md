# AUDIT_MONITOR_EMAIL_MUTE_R1_SECURITY_PROMPT

You are auditing the SECURITY lane of a change to the Pearl-side observability
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

- Alert-suppression risk is the core security question: this change makes a
  monitoring system deliberately stop delivering some alerts. Enumerate what an
  operator loses. Can any condition that previously reached the operator's inbox
  now reach nobody at all (journald retention, no log shipper, no other sink)?
- Is the default mute set defensible, or does it hide a genuine
  availability/security signal? Specifically: `pool has 0 ready providers` is
  CRITICAL and now journal-only — argue whether a sustained (not churn) pool
  outage is still detectable, and by what.
- Config-injection and trust: `EMAIL_MUTED_KINDS` is read from
  `/etc/macprovider/monitor.env` (root:macprovider 0640). Can a value in that
  file cause anything worse than mis-routing — unbounded memory, log injection
  via unsanitized echo of the raw value into journald, format-string issues,
  or control characters written to a terminal reading the journal?
- Does the unknown-kind WARN echo attacker-influenced text into journald
  unescaped? Note `{name!r}` and assess whether that is sufficient.
- Does the change weaken the "SMTP failed -> do not seal state" guarantee that
  exists to prevent silent alert loss? Trace every path through the
  `alerting` / `delivery` gate in the new code.
- Any secret-handling regression: does the new code path log, email, or
  otherwise expose `GMAIL_APP_PASSWORD`, `ALERT_EMAIL`, or `OPERATOR_KEY`?
- Does the shared `monitor.env` contract with
  `ops/pearl-updater/macprovider-pearl-updater-alert` (strict owner/mode
  validation, `REQUIRED_KEYS`) still hold with an extra key present?
- Denial-of-notification: could a flapping provider now mask a concurrent
  real `service` alert (e.g. via state sealing or subject-line selection)?

## Output format

Start with exactly one summary line:

`VERDICT: READY | COUNTS: C=0 H=0 M=0 L=<n>`

or:

`VERDICT: NEEDS REVISION | COUNTS: C=<n> H=<n> M=<n> L=<n>`

Then list ID-prefixed findings, ordered by severity: `SEC-C-1`, `SEC-H-1`,
`SEC-M-1`, `SEC-L-1`. Each finding must cite concrete repo evidence
(file:line). Do not include Critical/High/Medium findings unless they should
block the merge. The stop bar is 0 C/H/M.
