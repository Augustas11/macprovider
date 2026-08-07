#!/usr/bin/env python3
"""macprovider-monitor — lightweight Pearl-side observability (Phase 7 P2).

Polls the coordinator + gateway loopback endpoints and emits transition alerts,
plus bounded #535 provider-diagnostics failure-burst alerts, so automated
provider-removal (circuit-breaker degrade, warm-up-gate failure), repeated
auth/config/liveness failures, and pool-empty / service-down conditions surface
without a human SSHing into journals.

Zero provider load: it reads /healthz, /poolz, /admin/providers*,
/admin/hardware-trust/waiting, /v1/status only — it does NOT send inference.
(A synthetic canary can be added later if desired.)

Alerts go to stdout (captured by journald) ALWAYS, and to email if
/etc/macprovider/monitor.env provides Gmail submission creds. Run on a
systemd timer (see macprovider-monitor.timer), e.g. every 3 minutes.

Every alert carries a KIND (see ALERT_KINDS). Kinds listed in
EMAIL_MUTED_KINDS stay journal-only instead of being emailed: on a small
fleet, single-provider churn (drop / breaker / pool-idle) transitions
dominate the mail volume without carrying operator-actionable signal,
while the rare service-down kinds do. Muting is a mail-routing decision
only — journald still records every alert, and the state machine still
treats muted alerts as alerting transitions.

Config (/etc/macprovider/monitor.env, optional, KEY=VALUE lines):
  ALERT_EMAIL=augstar@gmail.com
  GMAIL_USER=augstar@gmail.com
  GMAIL_APP_PASSWORD=xxxxxxxxxxxxxxxx   # 16-char Google app password (2FA)
  EMAIL_MUTED_KINDS=provider,provider_liveness,pool,gateway_status
      # optional; this is the default. "all" mutes every kind
      # (journal-only); "none" (or an empty value) emails every kind,
      # the pre-mute behaviour.
  PROVIDER_DIAGNOSTICS_WINDOW_MINUTES=15           # optional #535 window
  PROVIDER_DIAGNOSTICS_MIN_FAILURES=3              # optional burst threshold
  EXPECTED_PROVIDER_IDS=augustass-macbook-air,air5 # optional missing-auth watch
  HARDWARE_TRUST_WAITING_ENABLED=1                # optional; poll waiting_trust
  HARDWARE_TRUST_WAITING_STALE_MINUTES=5          # email when backlog persists
"""

import json
import os
import re
import smtplib
import socket
import sys
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from email.message import EmailMessage

ENV_FILE = "/etc/macprovider/monitor.env"
STATE_FILE = os.path.join(
    os.environ.get("STATE_DIRECTORY", "/var/lib/macprovider-monitor"),
    "monitor-state.json",
)
HEALTHZ = "http://127.0.0.1:8444/healthz"
POOLZ = "http://127.0.0.1:8444/poolz"
ADMIN_PROVIDERS = "http://127.0.0.1:8444/admin/providers"
ADMIN_HARDWARE_TRUST_WAITING = "http://127.0.0.1:8444/admin/hardware-trust/waiting"
GW_STATUS = "http://127.0.0.1:9443/v1/status"
ANONYMOUS_PROVIDER_ID = "_anonymous"
STATIC_FEEDS = (
    "https://coordinator.streamvc.live/v1/rate-card",
    "https://coordinator.streamvc.live/v1/rate-card.sig",
    "https://coordinator.streamvc.live/v1/autotune-candidates",
    "https://coordinator.streamvc.live/v1/autotune-candidates.sig",
    "https://coordinator.streamvc.live/v1/demand-rank",
    "https://coordinator.streamvc.live/v1/demand-rank.sig",
)
TIMEOUT = 8
HOST = socket.gethostname()
PROVIDER_ID_PATTERN = re.compile(r"^[a-zA-Z0-9_.-]{1,64}$")

# Alert kinds. Every alert is tagged with exactly one of these so email
# routing can be decided per class instead of per severity (a single-mac
# fleet makes "pool has 0 ready providers" CRITICAL-but-routine).
KIND_PROVIDER = "provider"            # per-provider state transitions / drops
KIND_PROVIDER_DIAGNOSTICS = "provider_diagnostics"  # #535 auth/warmup/config bursts
KIND_PROVIDER_LIVENESS = "provider_liveness"  # heartbeat/reconnect churn
KIND_POOL = "pool"                    # pool ready-count emptied / recovered
KIND_GATEWAY_STATUS = "gateway_status"  # gateway self-reported idle/degraded/down
KIND_SERVICE = "service"              # coordinator/gateway endpoint unreachable
KIND_STATIC_FEED = "static_feed"      # SPEC-023 signed static feeds
KIND_HARDWARE_TRUST = "hardware_trust"  # waiting_trust backlog / new jobs
ALERT_KINDS = (
    KIND_PROVIDER,
    KIND_PROVIDER_DIAGNOSTICS,
    KIND_PROVIDER_LIVENESS,
    KIND_POOL,
    KIND_GATEWAY_STATUS,
    KIND_SERVICE,
    KIND_STATIC_FEED,
    KIND_HARDWARE_TRUST,
)
# Provider churn and liveness noise on a small fleet are journal-only by
# default; the kinds that mean "the Pearl-side services themselves are down"
# still page by email.
DEFAULT_EMAIL_MUTED_KINDS = (
    KIND_PROVIDER,
    KIND_PROVIDER_LIVENESS,
    KIND_POOL,
    KIND_GATEWAY_STATUS,
)


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


def muted_kinds(env):
    """Resolve the set of alert kinds that must NOT be emailed.

    Absent key -> DEFAULT_EMAIL_MUTED_KINDS. "all" -> every kind (email off
    entirely). "none" or an empty value -> nothing muted (pre-mute
    behaviour). Unknown names are reported to journald and ignored, so a
    typo cannot silently unmute a page or mute one.
    """
    raw = env.get("EMAIL_MUTED_KINDS")
    if raw is None:
        return set(DEFAULT_EMAIL_MUTED_KINDS)
    names = [n.strip().lower() for n in raw.split(",")]
    names = [n for n in names if n]
    if not names or names == ["none"]:
        return set()
    if "all" in names:
        return set(ALERT_KINDS)
    muted = set()
    for name in names:
        if name in ALERT_KINDS:
            muted.add(name)
        else:
            print(
                f"[WARN] ignoring unknown EMAIL_MUTED_KINDS entry {name!r} "
                f"(known kinds: {', '.join(ALERT_KINDS)})",
                flush=True,
            )
    return muted


def operator_key():
    # M3-2 / DEVE-7: pulled from systemd EnvironmentFile
    # (/etc/macprovider/coordinator.env, same file the coordinator unit
    # reads), not by regex-parsing /opt/macprovider/coordinator.yaml as
    # root. Returns "" when unset so /poolz returns 401 cleanly instead
    # of crashing the poll. See macprovider-monitor.service for the
    # EnvironmentFile= directive.
    return os.environ.get("OPERATOR_KEY", "")


def bounded_int(env, key, default, min_value, max_value):
    raw = env.get(key)
    if raw is None or raw.strip() == "":
        return default
    try:
        value = int(raw.strip())
    except ValueError:
        print(f"[WARN] ignoring invalid {key}={raw!r}; using {default}", flush=True)
        return default
    if value < min_value:
        return min_value
    if value > max_value:
        return max_value
    return value


def csv_values(raw):
    if not raw:
        return []
    return [part.strip() for part in raw.split(",") if part.strip()]


def provider_ids_from_csv(env, key, max_items):
    out = []
    for provider_id in csv_values(env.get(key, "")):
        if len(out) >= max_items:
            print(f"[WARN] ignoring extra {key} entries beyond {max_items}", flush=True)
            break
        if not PROVIDER_ID_PATTERN.match(provider_id):
            print(f"[WARN] ignoring invalid {key} entry {provider_id!r}", flush=True)
            continue
        out.append(provider_id)
    return out


def parse_utc(raw):
    if not raw or not isinstance(raw, str):
        return None
    match = re.match(r"^(.*T\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$", raw.strip())
    if not match:
        return None
    base, fraction, offset = match.groups()
    if fraction:
        fraction = (fraction[:6]).ljust(6, "0")
        iso = f"{base}.{fraction}{'+00:00' if offset == 'Z' else offset}"
    else:
        iso = f"{base}{'+00:00' if offset == 'Z' else offset}"
    try:
        return datetime.fromisoformat(iso).astimezone(timezone.utc)
    except ValueError:
        return None


def event_identity(event):
    event_id = event.get("id")
    if event_id is not None:
        return str(event_id)
    return "|".join(
        str(event.get(key, ""))
        for key in ("occurred_at", "kind", "outcome", "failure_reason", "session_id")
    )


def newest_event_identity(events):
    if not events:
        return ""
    return event_identity(events[0])


def newest_matching_event_identity(events, predicate):
    for event in events:
        if predicate(event):
            return event_identity(event)
    return ""


def recent_events(events, now, window):
    cutoff = now - window
    out = []
    for event in events:
        occurred = parse_utc(event.get("occurred_at"))
        if occurred is not None and occurred >= cutoff:
            out.append(event)
    return out


def provider_presence_map(admin_provider_list):
    providers = admin_provider_list.get("providers", [])
    out = {}
    if not isinstance(providers, list):
        return out
    for provider in providers:
        if not isinstance(provider, dict):
            continue
        provider_id = provider.get("provider_id")
        if isinstance(provider_id, str) and provider_id:
            out[provider_id] = provider
    return out


def provider_alert_words(provider_id):
    if provider_id == ANONYMOUS_PROVIDER_ID:
        return "pre-identity provider attempts", "have"
    return f"provider {provider_id}", "has"


def diagnostic_dedupe_key(provider_id, key, cursor):
    if provider_id == ANONYMOUS_PROVIDER_ID:
        return f"{key}:active"
    return f"{key}:{cursor or 'no-events'}"


def hardware_trust_waiting_alerts(env, prev_state, payload, now=None):
    """Alert on new waiting_trust jobs and a persistent backlog.

    Returns (alerts, next_state_fragment). Email is intentionally not muted for
    KIND_HARDWARE_TRUST — trust grants are operator-actionable.
    """
    now = now or datetime.now(timezone.utc)
    alerts = []
    prev = prev_state.get("hardware_trust_waiting", {}) if isinstance(prev_state, dict) else {}
    if not isinstance(prev, dict):
        prev = {}

    jobs = payload.get("waiting_trust", []) if isinstance(payload, dict) else []
    if not isinstance(jobs, list):
        jobs = []

    job_ids = []
    for job in jobs:
        if not isinstance(job, dict):
            continue
        job_id = job.get("job_id")
        if isinstance(job_id, int) or (isinstance(job_id, str) and job_id.isdigit()):
            job_ids.append(int(job_id))
    job_ids = sorted(set(job_ids))
    prev_ids = []
    for raw in prev.get("job_ids", []) if isinstance(prev.get("job_ids"), list) else []:
        try:
            prev_ids.append(int(raw))
        except (TypeError, ValueError):
            continue
    prev_ids_set = set(prev_ids)
    new_ids = [jid for jid in job_ids if jid not in prev_ids_set]

    by_id = {}
    for job in jobs:
        if isinstance(job, dict) and job.get("job_id") is not None:
            try:
                by_id[int(job["job_id"])] = job
            except (TypeError, ValueError):
                continue

    for jid in new_ids:
        job = by_id.get(jid, {})
        provider_id = job.get("provider_id", "?")
        reason = job.get("decision_reason", "?")
        approvable = job.get("approvable")
        alerts.append((
            "WARN",
            KIND_HARDWARE_TRUST,
            f"hardware_trust_waiting_new job_id={jid} provider_id={provider_id} "
            f"reason={reason} approvable={approvable}",
        ))

    first_seen_raw = prev.get("first_seen_utc")
    first_seen = parse_utc(first_seen_raw) if isinstance(first_seen_raw, str) else None
    if job_ids:
        if first_seen is None:
            first_seen = now
    else:
        first_seen = None

    stale_minutes = bounded_int(env, "HARDWARE_TRUST_WAITING_STALE_MINUTES", 5, 1, 1440)
    stale_alerted = bool(prev.get("stale_alerted"))
    if job_ids and first_seen is not None:
        age = now - first_seen
        if age >= timedelta(minutes=stale_minutes) and not stale_alerted:
            sample = ", ".join(str(jid) for jid in job_ids[:8])
            more = "" if len(job_ids) <= 8 else f" (+{len(job_ids) - 8} more)"
            alerts.append((
                "WARN",
                KIND_HARDWARE_TRUST,
                f"hardware_trust_waiting_stale count={len(job_ids)} "
                f"age_min={int(age.total_seconds() // 60)} job_ids={sample}{more}",
            ))
            stale_alerted = True
        elif not job_ids:
            stale_alerted = False
    else:
        stale_alerted = False

    next_state = {
        "job_ids": job_ids,
        "first_seen_utc": first_seen.strftime("%Y-%m-%dT%H:%M:%SZ") if first_seen else None,
        "stale_alerted": stale_alerted,
        "count": len(job_ids),
    }
    return alerts, next_state


def provider_diagnostic_alerts(env, state, admin_provider_list, events_by_provider, now=None, failed_provider_ids=None):
    """Return high-signal #535 alerts and updated dedupe state.

    The monitor keeps this heuristic intentionally narrow: alerts require
    repeated recent failures per provider, except version_unsupported which is
    immediately actionable. Sleeping/offline providers with no diagnostic burst
    remain quiet for small prebeta cohorts.
    """
    now = now or datetime.now(timezone.utc)
    window_minutes = bounded_int(env, "PROVIDER_DIAGNOSTICS_WINDOW_MINUTES", 15, 1, 1440)
    expected_window_minutes = bounded_int(env, "PROVIDER_EXPECTED_AUTH_WINDOW_MINUTES", 30, 1, 1440)
    threshold = bounded_int(env, "PROVIDER_DIAGNOSTICS_MIN_FAILURES", 3, 2, 100)
    window = timedelta(minutes=window_minutes)
    expected_window = timedelta(minutes=expected_window_minutes)
    presence = provider_presence_map(admin_provider_list)
    expected = set(provider_ids_from_csv(env, "EXPECTED_PROVIDER_IDS", 100))
    provider_ids = sorted(set(presence) | set(events_by_provider) | expected)
    prior = state.get("provider_diagnostics", {})
    failed_provider_ids = set(failed_provider_ids or [])
    next_state = {}
    alerts = []

    repeated_reasons = {
        "invalid_token",
        "invalid_auth_request",
        "warmup_failed",
        "heartbeat_stale",
        "provider_websocket_disconnected",
    }
    reconnect_reasons = {"heartbeat_stale", "provider_websocket_disconnected"}

    for provider_id in provider_ids:
        dedupe_base = prior.get(provider_id, {})
        if provider_id in failed_provider_ids:
            next_state[provider_id] = dedupe_base
            continue
        events = events_by_provider.get(provider_id, [])
        if not isinstance(events, list):
            events = []
        newest_id = newest_event_identity(events)
        next_state[provider_id] = {"newest_event": newest_id}
        recent = recent_events(events, now, window)
        recent_failures = [
            event for event in recent
            if event.get("outcome") == "failure" and event.get("failure_reason")
        ]
        reason_counts = {}
        for event in recent_failures:
            reason = str(event.get("failure_reason", ""))
            reason_counts[reason] = reason_counts.get(reason, 0) + 1

        provider_alerts = []
        subject, verb = provider_alert_words(provider_id)
        if reason_counts.get("version_unsupported", 0) >= 1:
            cursor = newest_matching_event_identity(
                recent_failures,
                lambda event: event.get("failure_reason") == "version_unsupported",
            )
            provider_alerts.append((
                "version_unsupported",
                f"{subject} {verb} version_unsupported in the last {window_minutes}m",
                cursor,
                KIND_PROVIDER_DIAGNOSTICS,
            ))
        for reason in sorted(repeated_reasons):
            count = reason_counts.get(reason, 0)
            if count >= threshold:
                cursor = newest_matching_event_identity(
                    recent_failures,
                    lambda event, expected_reason=reason: event.get("failure_reason") == expected_reason,
                )
                provider_alerts.append((
                    reason,
                    f"{subject} {verb} {count} {reason} failures in the last {window_minutes}m",
                    cursor,
                    KIND_PROVIDER_LIVENESS if reason in reconnect_reasons else KIND_PROVIDER_DIAGNOSTICS,
                ))
        reconnect_count = sum(reason_counts.get(reason, 0) for reason in reconnect_reasons)
        reconnect_reasons_at_threshold = [
            reason for reason in reconnect_reasons if reason_counts.get(reason, 0) >= threshold
        ]
        if reconnect_count >= threshold and not reconnect_reasons_at_threshold:
            cursor = newest_matching_event_identity(
                recent_failures,
                lambda event: event.get("failure_reason") in reconnect_reasons,
            )
            provider_alerts.append((
                "reconnect_loop",
                f"{subject} {verb} {reconnect_count} reconnect/liveness failures in the last {window_minutes}m",
                cursor,
                KIND_PROVIDER_LIVENESS,
            ))

        if provider_id in expected:
            accepted = [
                event for event in recent_events(events, now, expected_window)
                if event.get("kind") == "auth_accepted" and event.get("outcome") == "success"
            ]
            connected = presence.get(provider_id, {}).get("presence") == "connected"
            if not connected and not accepted:
                provider_alerts.append((
                    "expected_provider_missing_auth",
                    f"expected provider {provider_id} has no successful auth/session in the last {expected_window_minutes}m",
                    newest_id,
                    KIND_PROVIDER_DIAGNOSTICS,
                ))

        for key, message, cursor, kind in provider_alerts:
            dedupe_key = diagnostic_dedupe_key(provider_id, key, cursor)
            next_state[provider_id][key] = dedupe_key
            if dedupe_base.get(key) == dedupe_key:
                continue
            alerts.append(("WARN", kind, message))

    state["provider_diagnostics"] = next_state
    return alerts


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
    alerts = []  # (severity, kind, message)
    prev = load_state()

    # --- coordinator health + pool ---
    coord_up = True
    pool = {}
    try:
        h = get_json(HEALTHZ)
        ready = h.get("pool_ready", 0)
    except Exception as e:  # noqa: BLE001
        coord_up = False
        alerts.append(("CRITICAL", KIND_SERVICE, f"coordinator /healthz unreachable: {e}"))
        ready = None

    if coord_up:
        try:
            pz = get_json(POOLZ, bearer=operator_key())
            for p in pz.get("pool", []):
                pool[p["provider_id"]] = p.get("state", "?")
            ready = pz.get("summary", {}).get("ready", ready)
        except Exception as e:  # noqa: BLE001
            alerts.append(("WARN", KIND_SERVICE, f"/poolz read failed: {e}"))

    # --- gateway status ---
    gw_up = True
    gw_status = None
    try:
        s = get_json(GW_STATUS)
        gw_status = s.get("status")
    except Exception as e:  # noqa: BLE001
        gw_up = False
        alerts.append(("CRITICAL", KIND_SERVICE, f"gateway /v1/status unreachable: {e}"))

    # --- SPEC-023 signed static feeds (public nginx surface) ---
    static_ok = True
    static_failures = []
    for url in STATIC_FEEDS:
        try:
            probe_static_feed(url)
        except Exception as e:  # noqa: BLE001
            static_ok = False
            static_failures.append(f"{url}: {e}")

    # --- #535 provider diagnostics ---
    diagnostics_state = {"provider_diagnostics": prev.get("provider_diagnostics", {})}
    diagnostics_enabled = env.get("PROVIDER_DIAGNOSTICS_ENABLED", "1").strip().lower() not in (
        "0",
        "false",
        "no",
        "off",
    )
    op_key = operator_key()
    if coord_up and diagnostics_enabled and op_key:
        try:
            admin_list = get_json(ADMIN_PROVIDERS, bearer=op_key)
            providers = set(provider_presence_map(admin_list))
            providers.add(ANONYMOUS_PROVIDER_ID)
            providers.update(provider_ids_from_csv(env, "EXPECTED_PROVIDER_IDS", 100))
            limit = bounded_int(env, "PROVIDER_DIAGNOSTICS_EVENT_LIMIT", 50, 1, 100)
            events_by_provider = {}
            failed_provider_ids = set()
            for provider_id in sorted(providers):
                try:
                    quoted = urllib.parse.quote(provider_id, safe="")
                    detail = get_json(f"{ADMIN_PROVIDERS}/{quoted}/events?limit={limit}", bearer=op_key)
                    events = detail.get("events", []) if isinstance(detail, dict) else []
                    events_by_provider[provider_id] = events if isinstance(events, list) else []
                except Exception as e:  # noqa: BLE001
                    failed_provider_ids.add(provider_id)
                    subject, _ = provider_alert_words(provider_id)
                    alerts.append(("WARN", KIND_PROVIDER_DIAGNOSTICS, f"provider diagnostics read failed for {subject}: {e}"))
            alerts.extend(provider_diagnostic_alerts(
                env,
                diagnostics_state,
                admin_list,
                events_by_provider,
                failed_provider_ids=failed_provider_ids,
            ))
        except Exception as e:  # noqa: BLE001
            alerts.append(("WARN", KIND_PROVIDER_DIAGNOSTICS, f"provider diagnostics read failed: {e}"))
    elif coord_up and diagnostics_enabled and not op_key:
        print("[INFO] provider diagnostics alerts disabled until OPERATOR_KEY is available", flush=True)

    # --- hardware trust waiting_trust backlog (prebeta P4) ---
    hardware_trust_state = prev.get("hardware_trust_waiting", {})
    hardware_trust_enabled = env.get("HARDWARE_TRUST_WAITING_ENABLED", "1").strip().lower() not in (
        "0",
        "false",
        "no",
        "off",
    )
    if coord_up and hardware_trust_enabled and op_key:
        try:
            waiting = get_json(ADMIN_HARDWARE_TRUST_WAITING, bearer=op_key)
            ht_alerts, hardware_trust_state = hardware_trust_waiting_alerts(
                env, prev, waiting if isinstance(waiting, dict) else {},
            )
            alerts.extend(ht_alerts)
        except Exception as e:  # noqa: BLE001
            alerts.append(("WARN", KIND_HARDWARE_TRUST, f"hardware-trust waiting read failed: {e}"))
    elif coord_up and hardware_trust_enabled and not op_key:
        print("[INFO] hardware-trust waiting alerts disabled until OPERATOR_KEY is available", flush=True)

    # --- transition detection vs last poll ---
    prev_pool = prev.get("pool", {})
    prev_ready = prev.get("ready")
    prev_coord_up = prev.get("coord_up", True)
    prev_gw_status = prev.get("gw_status")
    prev_static_ok = prev.get("static_ok", True)

    # pool emptied (idle)
    if coord_up and ready == 0 and prev_ready != 0:
        alerts.append(("CRITICAL", KIND_POOL, "pool has 0 ready providers (idle) — no buyer capacity"))
    elif coord_up and ready and prev_ready == 0:
        alerts.append(("INFO", KIND_POOL, f"pool recovered: {ready} ready provider(s)"))

    # per-provider state transitions (breaker / warm-up-gate / disconnect)
    for pid, st in pool.items():
        was = prev_pool.get(pid)
        if was == st:
            continue
        if st == "unavailable":
            alerts.append(("WARN", KIND_PROVIDER, f"provider {pid} -> unavailable (breaker re-trip / warmup_failed / removed)"))
        elif st == "degraded":
            alerts.append(("WARN", KIND_PROVIDER, f"provider {pid} -> degraded (breaker trip / warm-up hold / recovery)"))
        elif st == "ready" and was in ("degraded", "unavailable"):
            alerts.append(("INFO", KIND_PROVIDER, f"provider {pid} recovered -> ready"))
    for pid, was in prev_pool.items():
        if pid not in pool and was != "unavailable":
            alerts.append(("WARN", KIND_PROVIDER, f"provider {pid} dropped from pool (was {was})"))

    # service up/down transitions
    if not coord_up and prev_coord_up:
        pass  # already alerted above
    elif coord_up and not prev_coord_up:
        alerts.append(("INFO", KIND_SERVICE, "coordinator recovered"))
    if gw_up and gw_status != prev_gw_status and gw_status in ("idle", "degraded", "down"):
        alerts.append(("WARN", KIND_GATEWAY_STATUS, f"gateway status -> {gw_status}"))
    if not static_ok and prev_static_ok:
        alerts.append(("CRITICAL", KIND_STATIC_FEED, "SPEC-023 static feeds unreachable: " + "; ".join(static_failures)))
    elif static_ok and not prev_static_ok:
        alerts.append(("INFO", KIND_STATIC_FEED, "SPEC-023 static feeds recovered"))

    # --- emit alerts ---
    # journald gets every alert regardless of email routing.
    for sev, kind, msg in alerts:
        print(f"[{sev}] ({kind}) {msg}", flush=True)
    muted = muted_kinds(env)
    emailable = [a for a in alerts if a[1] not in muted]
    suppressed = len(alerts) - len(emailable)
    if suppressed:
        print(
            f"[INFO] {suppressed} alert(s) journal-only "
            f"(EMAIL_MUTED_KINDS: {','.join(sorted(muted))})",
            flush=True,
        )
    delivery = None
    if emailable:
        delivery = send_email(env, emailable)

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
        "provider_diagnostics": diagnostics_state.get("provider_diagnostics", {}),
        "hardware_trust_waiting": hardware_trust_state,
    }
    # Muted alerts still count as alerting transitions: muting changes where
    # an alert is delivered, not whether the condition happened.
    alerting = any(sev in ("CRITICAL", "WARN") for sev, _, _ in alerts)
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
    """Attempt to deliver the non-muted alerts.

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
    # Muting makes INFO-only mail (e.g. a lone "coordinator recovered")
    # common, so the subject must be able to say INFO instead of WARN.
    severities = {s for s, _, _ in alerts}
    worst = next(s for s in ("CRITICAL", "WARN", "INFO") if s in severities)
    body = "\n".join(f"[{s}] ({k}) {m}" for s, k, m in alerts)
    msg = EmailMessage()
    msg["From"] = user
    msg["To"] = to
    msg["Subject"] = f"[macprovider {worst}] {HOST}: {alerts[0][2][:60]}"
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
