#!/usr/bin/env python3
"""Classify recent runs of one scheduled workflow for ops-alarm-watch.yml.

Reads `gh run list --json databaseId,event,status,conclusion,createdAt,url`
output and prints one line: `success` or `alarm<TAB><reason>`.

It raises what the in-run alarm job cannot see (#1920):
  - the latest completed scheduled/dispatched run was cancelled, timed out,
    failed to start, or needs action (a renewal cancelled while waiting on
    the production-release approval never reaches its own alarm job);
  - a run has been waiting (environment approval) or queued longer than
    --max-waiting-hours, or in progress longer than --max-running-hours;
  - no run was created within --max-age-hours (GitHub disables schedules on
    inactive repositories, and a disabled schedule fails silently).
A plain `failure` is left to the workflow's own alarm job to avoid two issues
for one failure.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import pathlib
import sys

WATCHED_EVENTS = {"schedule", "workflow_dispatch"}
WAITING = {"waiting", "queued", "pending", "requested"}
ABNORMAL = {"cancelled", "timed_out", "startup_failure", "action_required", "stale"}


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=dt.timezone.utc)


def classify(runs: list[dict], now: dt.datetime, max_waiting_h: float,
             max_running_h: float, max_age_h: float, stale_only: bool = False) -> tuple[str, str]:
    runs = [r for r in runs if r.get("event") in WATCHED_EVENTS]
    runs.sort(key=lambda r: r["createdAt"], reverse=True)
    if not runs or (now - parse_time(runs[0]["createdAt"])).total_seconds() / 3600 > max_age_h:
        return "alarm", f"no scheduled or dispatched run in the last {max_age_h:g}h; is the schedule disabled?"
    if stale_only:
        return "success", ""
    for run in runs:
        age_h = (now - parse_time(run["createdAt"])).total_seconds() / 3600
        status = run.get("status")
        if status in WAITING and age_h > max_waiting_h:
            what = "waiting for environment approval" if status == "waiting" else status
            return "alarm", f"run {run.get('url', run.get('databaseId'))} has been {what} for {age_h:.1f}h"
        if status == "in_progress" and age_h > max_running_h:
            return "alarm", f"run {run.get('url', run.get('databaseId'))} has been in progress for {age_h:.1f}h"
    completed = [r for r in runs if r.get("status") == "completed"]
    if completed and completed[0].get("conclusion") in ABNORMAL:
        run = completed[0]
        return "alarm", f"latest run {run.get('url', run.get('databaseId'))} concluded {run['conclusion']}"
    return "success", ""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("runs_json", type=pathlib.Path)
    parser.add_argument("--max-waiting-hours", type=float, default=1.0)
    parser.add_argument("--max-running-hours", type=float, default=3.0)
    parser.add_argument("--max-age-hours", type=float, required=True)
    parser.add_argument("--stale-only", action="store_true",
                        help="only check that runs keep happening (for alarms that cancel superseded runs)")
    parser.add_argument("--now", help="RFC3339 UTC override for tests")
    args = parser.parse_args(argv)
    now = parse_time(args.now) if args.now else dt.datetime.now(dt.timezone.utc)
    runs = json.loads(args.runs_json.read_text(encoding="utf-8"))
    if not isinstance(runs, list):
        print("runs JSON must be a list", file=sys.stderr)
        return 2
    result, reason = classify(runs, now, args.max_waiting_hours, args.max_running_hours,
                              args.max_age_hours, args.stale_only)
    print(result if not reason else f"{result}\t{reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
