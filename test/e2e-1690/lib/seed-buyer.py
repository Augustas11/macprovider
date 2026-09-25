#!/usr/bin/env python3
"""Insert one active buyer account + API key into the gateway SQLite DB (same
HMAC-SHA256 key hash as phase5-gateway/internal/auth/keys.go and the E1
harness seedGatewayAccountAndKey). Prints the full key on stdout only."""
import base64, datetime, hashlib, hmac, os, sqlite3, sys
db, secret = sys.argv[1], sys.argv[2]
account = "acct_e2e_" + os.urandom(4).hex()
key = "mp_" + base64.urlsafe_b64encode(os.urandom(32)).decode().rstrip("=")
now = datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00", "Z")
con = sqlite3.connect(db)
con.execute("INSERT INTO accounts(account_id, status, quota_class, concurrency_class, created_at) VALUES(?, 'active', 'default', 'default', ?)", (account, now))
con.execute("INSERT INTO api_keys(key_id, account_id, key_hash, key_hash_prefix, status, created_at) VALUES(?, ?, ?, ?, 'active', ?)",
            ("key_" + os.urandom(16).hex(), account, hmac.new(secret.encode(), key.encode(), hashlib.sha256).digest(), key[:12], now))
con.commit()
print(key)
