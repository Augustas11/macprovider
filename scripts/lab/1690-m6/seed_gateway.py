#!/usr/bin/env python3
"""Seed the lab gateway DB with one active buyer account and API key.

Boots the lab gateway once so it runs its own migrations, stops it, then
inserts the account and an HMAC-SHA256 hashed key (the scheme of
phase5-gateway/internal/auth/keys.go). The full key is written only to
LAB/keys/buyer-key (0600). Noninteractive; lab paths only.
"""
import base64
import hashlib
import hmac
import json
import os
import pathlib
import secrets
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone

LAB = pathlib.Path(os.environ.get("LAB", "/Users/a1/lab-1690-m6"))
ACCOUNT = sys.argv[1] if len(sys.argv) > 1 else "acct-lab-1690-buyer"
DB = LAB / "db" / "gateway.db"


def main():
    s = json.loads((LAB / "keys" / "secrets.json").read_text())
    proc = subprocess.Popen([str(LAB / "bin" / "gateway"), "-config", str(LAB / "run" / "gateway.yaml")],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        deadline = time.time() + 10
        while time.time() < deadline:
            try:
                with sqlite3.connect(DB) as db:
                    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='accounts'").fetchone():
                        break
            except sqlite3.Error:
                pass
            time.sleep(0.1)
        else:
            sys.exit("gateway did not create its schema")
    finally:
        proc.terminate()
        proc.wait(timeout=10)
    now = datetime.now(timezone.utc).isoformat()
    key = "mp_" + base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
    digest = hmac.new(s["key_hash_secret"].encode(), key.encode(), hashlib.sha256).digest()
    with sqlite3.connect(DB) as db:
        db.execute("INSERT OR IGNORE INTO accounts(account_id, status, quota_class, concurrency_class, created_at) VALUES(?, 'active', 'default', 'default', ?)",
                   (ACCOUNT, now))
        db.execute("INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at) VALUES(?, ?, ?, ?, 'active', ?)",
                   ("key_" + secrets.token_hex(16), ACCOUNT, digest, key[:12], now))
    out = LAB / "keys" / f"buyer-key-{ACCOUNT}"
    out.write_text(key + "\n")
    out.chmod(0o600)
    print(f"seeded account={ACCOUNT} key_prefix={key[:12]}")


if __name__ == "__main__":
    main()
