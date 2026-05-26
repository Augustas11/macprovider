#!/usr/bin/env python3
"""
Companion host-telemetry script for Phase 2 contributors.

Polls CPU%, RAM%, and (optionally) the foreground app name every N seconds,
logging to ~/.macprovider/host.sqlite. Run this in a third tmux pane on
the contributor's Mac.

Usage:
    python companion.py                   # default: poll every 60s
    python companion.py --interval 10     # poll every 10s
    python companion.py --with-app         # also capture foreground app name
"""

from __future__ import annotations

import argparse
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import psutil

DB_DIR = Path.home() / ".macprovider"
DB_PATH = DB_DIR / "host.sqlite"

SCHEMA = """
CREATE TABLE IF NOT EXISTS host_metrics (
    ts_utc TEXT PRIMARY KEY,
    cpu_pct REAL,
    ram_pct REAL,
    foreground_app TEXT
);
"""

_running = True


def _handle_signal(signum, frame):
    global _running
    _running = False


def get_foreground_app() -> str | None:
    try:
        result = subprocess.run(
            ["osascript", "-e",
             'tell application "System Events" to get name of first process whose frontmost is true'],
            capture_output=True, text=True, timeout=2,
        )
        if result.returncode == 0:
            return result.stdout.strip() or None
    except (subprocess.TimeoutExpired, OSError):
        pass
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description="Host telemetry for macprovider contributors")
    ap.add_argument("--interval", type=int, default=60, help="polling interval in seconds (default: 60)")
    ap.add_argument("--with-app", action="store_true", help="capture foreground app name (off by default for privacy)")
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, _handle_signal)
    signal.signal(signal.SIGINT, _handle_signal)

    DB_DIR.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(DB_PATH))
    conn.executescript(SCHEMA)
    conn.commit()

    print("companion: logging to {} every {}s".format(DB_PATH, args.interval))

    while _running:
        cpu = psutil.cpu_percent(interval=1)
        ram = psutil.virtual_memory().percent
        app = get_foreground_app() if args.with_app else None
        ts = datetime.now(timezone.utc).isoformat(timespec="seconds")

        conn.execute(
            "INSERT OR REPLACE INTO host_metrics (ts_utc, cpu_pct, ram_pct, foreground_app) VALUES (?, ?, ?, ?)",
            (ts, cpu, ram, app),
        )
        conn.commit()
        print("companion: {} cpu={:.1f}% ram={:.1f}% app={}".format(ts, cpu, ram, app or "(skipped)"))

        # Sleep in small increments so SIGTERM is handled promptly
        remaining = args.interval - 1  # -1 because cpu_percent(interval=1) already waited 1s
        while remaining > 0 and _running:
            step = min(remaining, 1)
            time.sleep(step)
            remaining -= step

    conn.close()
    print("companion: stopped cleanly")
    return 0


if __name__ == "__main__":
    sys.exit(main())
