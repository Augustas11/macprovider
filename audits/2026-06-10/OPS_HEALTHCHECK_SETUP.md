# External Healthcheck Setup — coordinator + gateway

Closes **QW-3 / M0-4** from `audits/2026-06-10/REPO_AUDIT.md`.

**Why this matters.** Today the only alerting on Pearl is one Gmail channel
inside `macprovider-monitor.py` running *on* the VPS it watches. If Pearl,
nginx, or the monitor itself dies, no one knows until a user complains
(audit finding **DEVE-2**). An external healthchecker on free tier fixes
this in 15 minutes.

This document is a checklist for the operator. Claude cannot register
external accounts; everything below is a human action.

---

## What we monitor

| Endpoint | URL | What it proves |
|---|---|---|
| Coordinator | `https://coordinator.streamvc.live/healthz` | Pearl up + nginx up + coordinator process up + can serve a request |
| Gateway     | `https://api.streamvc.live/healthz`         | Pearl up + nginx up + gateway process up + can serve a request |

Both must be up to serve any buyer traffic. If only the gateway is up, every
inference 502s downstream; if only the coordinator is up, no buyer can reach
it. Two distinct checks let the alert text tell you *which* component fell over.

## Provider choice — UptimeRobot

**Recommendation: UptimeRobot, free tier.**

- 50 monitors free; we use 2.
- 5-minute minimum interval on the free tier (matches our needs).
- Both email and mobile-app push notifications, free.
- Status pages free if you ever want a public one.
- Has been stable on free-tier business for ~10 years; no recent re-pricing
  surprises. Lower switching cost than healthchecks.io for two simple URL
  pings (which is what we have — we don't need cron-style "expect a ping"
  semantics; we're checking that *we* respond to a poll).
- healthchecks.io is also fine — pick it instead if you already have an
  account there. The interval and notification config below translates 1:1.

## Configuration

In UptimeRobot dashboard, **Add New Monitor** for each endpoint:

| Field | Value |
|---|---|
| Monitor Type | `HTTP(s)` |
| Friendly Name | `MacProvider coordinator` / `MacProvider gateway` |
| URL (or IP) | (see table above) |
| Monitoring Interval | **5 minutes** |
| Monitor Timeout | **30 seconds** *(UptimeRobot caps at 30s on free; close enough to 1 min for the SLO we care about. If you want the spec'd "1-minute timeout" exactly, use a paid plan or healthchecks.io free)* |
| HTTP Method | `GET` |
| Expected Status | `200` |

**Alert Contacts** (configure both):

1. **Email** — your primary inbox (the same one that already gets
   `macprovider-monitor.py` alerts; receiving on two channels for the same
   incident is intentional belt-and-suspenders).
2. **Push** — install the UptimeRobot mobile app, enable push notifications.
   Push survives email outages and is meaningfully faster on incidents that
   happen overnight.

Set alert thresholds:

- **Down threshold:** 1 failure (don't wait for "x out of y" — at our
  traffic level a single failed probe is signal worth waking up to).
- **Up notification:** enabled (so you know when the system self-recovered
  vs needs intervention).

## Verification (do this once, end-to-end)

In a maintenance window — pick a quiet slot, post the window in whatever
channel the team uses, then:

1. SSH to Pearl: `ssh pearl`
2. Stop nginx: `sudo systemctl stop nginx`
3. Wait for UptimeRobot to detect — within ~5 min for both monitors.
4. Confirm: an email arrives in your inbox; the push notification fires on
   your phone; the UptimeRobot dashboard shows both monitors red.
5. Restart nginx: `sudo systemctl start nginx`
6. Confirm: both URLs return 200 within ~30s; UptimeRobot sends the "up"
   notification within ~5 min; dashboard is green.

If any step fails, the most common cause is alert contacts not actually
saved against the monitor (UptimeRobot requires explicit per-monitor
assignment — adding a contact globally is not enough).

## Out of scope for this task

- The monitor delivery fix inside `macprovider-monitor.py:159-195` (the
  "save_state regardless of delivery" bug) — that is the in-repo half of
  M0-4 and ships separately.
- A public status page — defer to after M2-8 (OPS.md).
- Synthetic-traffic alerting (the `beta/` harness already runs synthetic
  inference; alerting on its failures is a separate larger task).

## After setup

Once both monitors are green and the verification round-trip worked:

- Save the UptimeRobot account credentials in the team password manager
  under "MacProvider ops".
- Add a line to `beta/DECISION_CRITERIA.md` noting the external check is
  live and which provider (so the next operator doesn't re-debate it).
