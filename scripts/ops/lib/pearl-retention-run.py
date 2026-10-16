#!/usr/bin/env python3
"""Sent over SSH by scripts/ops/pearl-runtime.sh PEARL_RUNTIME_TASK=retention-run
(`next --run`): one on-demand settlement-evidence retention run through the
coordinator's operator route (SPEC-022 R-15, #1793), on Pearl's loopback.

  python3 - run --config C --overlay O --unit U --proc /proc --admin-url URL
                --wait-max-s N --poll-s N --nightly-utc HH:MM

It resolves auth.operator_key the way the coordinator does (overlay over
base; env:NAME from the running coordinator's own environment), POSTs
/admin/ledger/settlement-evidence-retention/run, and waits (bounded) for the
report of this run at ?report=last. The key is never printed or put in argv.
It refuses, starting nothing, in the ten minutes before the nightly run and
when the route reports a run in progress (the nightly retention or ledger
rollup share its single-flight lock). Prints one JSON object with the report
fields the ops entry point records; nothing else from the report.
"""
import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

RUN_PATH = "/admin/ledger/settlement-evidence-retention/run"
REPORT_PATH = "/admin/ledger/settlement-evidence-retention?report=last"
# Report fields recorded by the ops entry point, with their JSON types.
FIELDS = {
    "status": str, "stop_reason": str, "deleted_requests": int, "backlog_drained": bool,
    "laps_completed": int, "last_lap_overdue_requests": int, "last_lap_eligible_requests": int,
    "last_lap_completed_at_utc": str, "started_at_utc": str, "finished_at_utc": str, "error": str,
}
SAFE = re.compile(r"^[A-Za-z0-9 _.:,;=()/+-]{0,200}$")


class Refused(Exception):
    pass


def utc(text):
    """The coordinator's RFC 3339 UTC text (fraction optional) as
    (datetime, nanoseconds within the second), or None."""
    m = re.match(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.(\d{1,9}))?Z$", text if isinstance(text, str) else "")
    if not m:
        return None
    t = datetime.datetime.strptime(m.group(1), "%Y-%m-%dT%H:%M:%S").replace(tzinfo=datetime.timezone.utc)
    return t, int((m.group(2) or "0").ljust(9, "0"))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """The operator key goes to the loopback admin URL only, never a redirect."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


def nightly_window(now, hhmm):
    h, m = (int(x) for x in hhmm.split(":"))
    start = now.replace(hour=h, minute=m, second=0, microsecond=0)
    if start < now - datetime.timedelta(minutes=10):
        start += datetime.timedelta(days=1)
    return start - datetime.timedelta(minutes=10) <= now < start


def operator_key(args):
    import yaml

    def key_of(path):
        with open(path) as f:
            doc = yaml.safe_load(f) or {}
        return str(((doc.get("auth") or {}) if isinstance(doc, dict) else {}).get("operator_key") or "")

    ref = key_of(args.overlay) or key_of(args.config)
    if not ref.startswith("env:"):
        if not ref:
            raise Refused("auth.operator_key is not set in the coordinator config")
        return ref
    pid = subprocess.run(["systemctl", "show", "-p", "MainPID", "--value", args.unit],
                         capture_output=True, text=True, timeout=15).stdout.strip()
    if not pid.isdigit() or pid == "0":
        raise Refused("the coordinator unit has no main process")
    with open(os.path.join(args.proc, pid, "environ"), "rb") as f:
        env = dict(e.decode().split("=", 1) for e in f.read().split(b"\0") if b"=" in e)
    key = env.get(ref[4:], "")
    if not key:
        raise Refused("auth.operator_key names an environment variable the running coordinator does not have")
    return key


def call(opener, method, url, key):
    req = urllib.request.Request(url, method=method, headers={"Authorization": "Bearer " + key})
    try:
        with opener.open(req, timeout=30) as resp:
            return resp.status, resp.read(1 << 20)
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(1 << 16)


def error_code(body):
    try:
        d = json.loads(body or b"{}")
    except ValueError:
        return ""
    e = d.get("error") if isinstance(d, dict) else None
    code = e.get("code") if isinstance(e, dict) else e
    return code if isinstance(code, str) and SAFE.match(code) else ""


def run(args):
    now = datetime.datetime.now(datetime.timezone.utc)
    if nightly_window(now, args.nightly_utc):
        raise Refused("the nightly retention run starts at %s UTC; start an on-demand run outside the ten minutes before it"
                      % args.nightly_utc)
    key = operator_key(args)
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    base = args.admin_url.rstrip("/")
    # The route returns no run id. This run's report is the first one that
    # started after the previous report and at or after this instant, at full
    # precision on Pearl's own clock (the coordinator's clock): an older report
    # can never be taken for it. Another run that won the lock in the gap
    # would be a real run that also finished after the POST.
    previous = None
    code, body = call(opener, "GET", base + REPORT_PATH, key)
    if code == 200:
        try:
            previous = utc(json.loads(body).get("started_at_utc"))
        except (ValueError, AttributeError):
            previous = None
    elif code != 404:
        raise RuntimeError("the report route answered HTTP %d" % code)
    now = datetime.datetime.now(datetime.timezone.utc)
    t0 = (now.replace(microsecond=0), now.microsecond * 1000)
    code, body = call(opener, "POST", base + RUN_PATH, key)
    reason = error_code(body)
    if code == 409 and reason == "retention_busy":
        raise Refused("a retention or ledger rollup run is in progress (the nightly job or another on-demand run); nothing was started")
    if code == 409 and reason == "retention_disabled":
        raise Refused("billing.retention.enabled is false on Pearl; nothing was started")
    if code == 503:
        raise Refused("settlement evidence retention is not configured on Pearl; nothing was started")
    if code != 202:
        raise RuntimeError("the run route answered HTTP %d %s" % (code, reason))
    sys.stderr.write("retention run started at %s; waiting for its report (at most %d s)\n"
                     % (t0[0].strftime("%Y-%m-%dT%H:%M:%SZ"), args.wait_max_s))
    deadline = time.monotonic() + args.wait_max_s
    while True:
        code, body = call(opener, "GET", base + REPORT_PATH, key)
        if code == 200:
            try:
                report = json.loads(body)
            except ValueError:
                report = {}
            started = utc(report.get("started_at_utc") if isinstance(report, dict) else None)
            if started is not None and started >= t0 and (previous is None or started > previous) \
                    and report.get("finished_at_utc"):
                return report, key
        elif code != 404:
            raise RuntimeError("the report route answered HTTP %d" % code)
        if time.monotonic() > deadline:
            raise RuntimeError("no report for this run within %d s; it may still be running or another run "
                               "took the lock first: read the coordinator journal, do not retry blindly" % args.wait_max_s)
        time.sleep(args.poll_s)


def summary(report, key):
    out = {}
    for name, kind in FIELDS.items():
        v = report.get(name)
        if kind is int and isinstance(v, int) and not isinstance(v, bool):
            out[name] = v
        elif kind is bool and isinstance(v, bool):
            out[name] = v
        elif kind is str and isinstance(v, str):
            # Errors may quote paths or anything else: never the key, and
            # only terminal-safe text.
            v = v.replace(key, "REDACTED") if key else v
            out[name] = v if SAFE.match(v) else "(unprintable)"
    return out


def main(argv):
    p = argparse.ArgumentParser()
    p.add_argument("cmd", choices=["run"])
    p.add_argument("--config", required=True)
    p.add_argument("--overlay", required=True)
    p.add_argument("--unit", required=True)
    p.add_argument("--proc", default="/proc")
    p.add_argument("--admin-url", required=True)
    p.add_argument("--wait-max-s", type=int, required=True)
    p.add_argument("--poll-s", type=int, default=30)
    p.add_argument("--nightly-utc", default="03:00")
    args = p.parse_args(argv)
    try:
        if not re.match(r"^([01][0-9]|2[0-3]):[0-5][0-9]$", args.nightly_utc):
            raise Refused("--nightly-utc must be HH:MM")
        print(json.dumps(summary(*run(args)), sort_keys=True))
    except Refused as exc:
        sys.stderr.write("pearl-retention-run: REFUSED: %s\n" % exc)
        sys.exit(3)
    except Exception as exc:
        msg = str(exc) if isinstance(exc, RuntimeError) else type(exc).__name__
        sys.stderr.write("pearl-retention-run: FAILED: %s\n" % msg)
        sys.exit(1)


if __name__ == "__main__":
    main(sys.argv[1:])
