#!/usr/bin/env python3
"""macprovider-monitor — lightweight Pearl-side observability (Phase 7 P2).

Polls the coordinator + gateway loopback endpoints and emits an alert on
STATE TRANSITIONS only (not every poll), so automated provider-removal
(circuit-breaker degrade, warm-up-gate failure) and pool-empty / service-down
conditions surface without a human SSHing into journals.

Zero provider load: it reads /healthz, /poolz, /v1/status only — it does NOT
send inference. (A synthetic canary can be added later if desired.)

Alerts go to stdout (captured by journald) ALWAYS, and to email if
/etc/macprovider/monitor.env provides Gmail submission creds. Run on a
systemd timer (see macprovider-monitor.timer), e.g. every 3 minutes.

Config (/etc/macprovider/monitor.env, optional, KEY=VALUE lines):
  ALERT_EMAIL=augstar@gmail.com
  GMAIL_USER=augstar@gmail.com
  GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx   # 16-char Google app password (2FA)
"""

import json
import os
import smtplib
import socket
import sys
import urllib.request
from email.message import EmailMessage

ENV_FILE = "/etc/macprovider/monitor.env"
STATE_FILE = os.path.join(
    os.environ.get("STATE_DIRECTORY", "/var/lib/macprovider-monitor"),
    "monitor-state.json",
)
HEALTHZ = "http://127.0.0.1:8444/healthz"
POOLZ = "http://127.0.0.1:8444/poolz"
GW_STATUS = "http://127.0.0.1:9443/v1/status"
STATIC_FEEDS = (
    "https://coordinator.streamvc.live/v1/autotune-candidates",
    "https://coordinator.streamvc.live/v1/autotune-candidates.sig",
    "https://coordinator.streamvc.live/v1/demand-rank",
    "https://coordinator.streamvc.live/v1/demand-rank.sig",
)
TIMEOUT = 8
HOST = socket.gethostname()


def load_env(path):
    env = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    except FileNotFoundError:
        pass
    return env


def operator_key():
    # M3-2 / DEVE-7: pulled from systemd EnvironmentFile
    # (/etc/macprovider/coordinator.env, same file the coordinator unit
    # reads), not by regex-parsing /opt/macprovider/coordinator.yaml as
    # root. Returns "" when unset so /poolz returns 401 cleanly instead
    # of crashing the poll. See macprovider-monitor.service for the
    # EnvironmentFile= directive.
    return os.environ.get("OPERATOR_KEY", "")


def get_json(url, bearer=None):
    req = urllib.request.Request(url)
    if bearer:
        req.add_header("Authorization", "Bearer " + bearer)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        return json.load(r)


def probe_static_feed(url):
    req = urllib.request.Request(url)
    with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
        if r.status != 200:
            raise RuntimeError(f"HTTP {r.status}")
        return r.read(65536)


def load_state():
    try:
        with open(STATE_FILE) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return {}


def save_state(state):
    os.makedirs(os.path.dirname(STATE_FILE), exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, STATE_FILE)


def main():
    env = load_env(ENV_FILE)
    alerts = []  # (severity, message)

    # --- coordinator health + pool ---
    coord_up = True
    pool = {}
    try:
        h = get_json(HEALTHZ)
        ready = h.get("pool_ready", 0)
    except Exception as e:  # noqa: BLE001
        coord_up = False
        alerts.append(("CRITICAL", f"coordinator /healthz unreachable: {e}"))
        ready = None

    if coord_up:
        try:
            pz = get_json(POOLZ, bearer=operator_key())
            for p in pz.get("pool", []):
                pool[p["provider_id"]] = p.get("state", "?")
            ready = pz.get("summary", {}).get("ready", ready)
        except Exception as e:  # noqa: BLE001
            alerts.append(("WARN", f"/poolz read failed: {e}"))

    # --- gateway status ---
    gw_up = True
    gw_status = None
    try:
        s = get_json(GW_STATUS)
        gw_status = s.get("status")
    except Exception as e:  # noqa: BLE001
        gw_up = False
        alerts.append(("CRITICAL", f"gateway /v1/status unreachable: {e}"))

    # --- SPEC-023 signed static feeds (public nginx surface) ---
    static_ok = True
    static_failures = []
    for url in STATIC_FEEDS:
        try:
            probe_static_feed(url)
        except Exception as e:  # noqa: BLE001
            static_ok = False
            static_failures.append(f"{url}: {e}")

    # --- transition detection vs last poll ---
    prev = load_state()
    prev_pool = prev.get("pool", {})
    prev_ready = prev.get("ready")
    prev_coord_up = prev.get("coord_up", True)
    prev_gw_status = prev.get("gw_status")
    prev_static_ok = prev.get("static_ok", True)

    # pool emptied (idle)
    if coord_up and ready == 0 and prev_ready != 0:
        alerts.append(("CRITICAL", "pool has 0 ready providers (idle) — no buyer capacity"))
    elif coord_up and ready and prev_ready == 0:
        alerts.append(("INFO", f"pool recovered: {ready} ready provider(s)"))

    # per-provider state transitions (breaker / warm-up-gate / disconnect)
    for pid, st in pool.items():
        was = prev_pool.get(pid)
        if was == st:
            continue
        if st == "unavailable":
            alerts.append(("WARN", f"provider {pid} -> unavailable (breaker re-trip / warmup_failed / removed)"))
        elif st == "degraded":
            alerts.append(("WARN", f"provider {pid} -> degraded (breaker trip / warm-up hold / recovery)"))
        elif st == "ready" and was in ("degraded", "unavailable"):
            alerts.append(("INFO", f"provider {pid} recovered -> ready"))
    for pid, was in prev_pool.items():
        if pid not in pool and was != "unavailable":
            alerts.append(("WARN", f"provider {pid} dropped from pool (was {was})"))

    # service up/down transitions
    if not coord_up and prev_coord_up:
        pass  # already alerted above
    elif coord_up and not prev_coord_up:
        alerts.append(("INFO", "coordinator recovered"))
    if gw_up and gw_status != prev_gw_status and gw_status in ("idle", "degraded", "down"):
        alerts.append(("WARN", f"gateway status -> {gw_status}"))
    if not static_ok and prev_static_ok:
        alerts.append(("CRITICAL", "SPEC-023 static feeds unreachable: " + "; ".join(static_failures)))
    elif static_ok and not prev_static_ok:
        alerts.append(("INFO", "SPEC-023 static feeds recovered"))

    # --- emit alerts ---
    for sev, msg in alerts:
        print(f"[{sev}] {msg}", flush=True)
    delivery = None
    if alerts:
        delivery = send_email(env, alerts)

    # Persist only when EITHER (a) the new state is non-alerting (transitions
    # to healthy save unconditionally), OR (b) at least one non-journald
    # delivery succeeded. A failed alerting-transition delivery keeps the
    # OLD state so the next 3-minute poll re-alerts as long as the
    # condition persists. Journal-only configurations behave the same way:
    # without an external delivery path, persistent alerting transitions
    # keep re-emitting to journald rather than silently sealing.
    new_state = {
        "pool": pool,
        "ready": ready,
        "coord_up": coord_up,
        "gw_status": gw_status,
        "static_ok": static_ok,
    }
    alerting = any(sev in ("CRITICAL", "WARN") for sev, _ in alerts)
    # `delivery is not False` keeps the strong "SMTP failed -> don't seal"
    # guarantee while letting journal-only mode (delivery is None) advance
    # state normally. Without an external delivery path journald IS the
    # configured sink, and blocking save_state forever would refire every
    # prior transition on every subsequent poll (not just the unfired
    # alerting transition that originally failed). The original `delivery
    # is True` gate had that flaw — flagged by the M0-4a code review.
    if not alerting or delivery is not False:
        save_state(new_state)
    else:
        print("[INFO] state not advanced; will re-evaluate next cycle", flush=True)
    return 0


def send_email(env, alerts):
    """Attempt to deliver alerts.

    Returns True on successful delivery, False if delivery was attempted
    and failed, and None if no non-journald recipient is configured (the
    alerts already landed in journald via the caller's stdout prints).
    """
    user = env.get("GMAIL_USER")
    pw = env.get("GMAIL_APP_PASSWORD")
    to = env.get("ALERT_EMAIL")
    if not (user and pw and to):
        print("[INFO] email not configured (set GMAIL_* in /etc/macprovider/monitor.env) — journal-only", flush=True)
        return None
    worst = "CRITICAL" if any(s == "CRITICAL" for s, _ in alerts) else "WARN"
    body = "\n".join(f"[{s}] {m}" for s, m in alerts)
    msg = EmailMessage()
    msg["From"] = user
    msg["To"] = to
    msg["Subject"] = f"[macprovider {worst}] {HOST}: {alerts[0][1][:60]}"
    msg.set_content(f"macprovider monitor on {HOST}\n\n{body}\n")
    try:
        with smtplib.SMTP("smtp.gmail.com", 587, timeout=TIMEOUT) as smtp:
            smtp.starttls()
            smtp.login(user, pw)
            smtp.send_message(msg)
        print(f"[INFO] emailed {len(alerts)} alert(s) to {to}", flush=True)
        return True
    except Exception as e:  # noqa: BLE001
        print(f"[WARN] email send failed: {e}", flush=True)
        print(f"SMTP failure, will retry: {e}", file=sys.stderr, flush=True)
        return False


if __name__ == "__main__":
    sys.exit(main())
