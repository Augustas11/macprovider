#!/usr/bin/env python3
"""Runbook section 9 gateway rollback step 4: export every row written after
the snapshot timestamp from accounts, account_identities, api_keys,
api_key_events, quota_reservations, usage_events, demo_usage_events and the
wallet_session* tables ("their created_at, settled_at or equivalent timestamp
is after the snapshot's") as INSERT OR REPLACE statements.
Usage: gw-rollback-export.py <gateway.db> <snapshot ISO UTC> <out.sql>"""
import sqlite3, sys
db, ts, out = sys.argv[1:]
c = sqlite3.connect("file:%s?mode=ro" % db, uri=True)
tables = ["accounts", "account_identities", "api_keys", "api_key_events", "quota_reservations", "usage_events", "demo_usage_events"]
tables += [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table' AND name LIKE 'wallet_session%' ORDER BY name")]
TS_COLS = ("created_at", "settled_at", "updated_at", "revoked_at", "consumed_at", "last_used_at", "expires_at_seen")
lines, summary = ["BEGIN;"], []
def q(v):
    if v is None: return "NULL"
    if isinstance(v, (int, float)): return str(v)
    if isinstance(v, bytes): return "X'%s'" % v.hex()
    return "'" + str(v).replace("'", "''") + "'"
for t in tables:
    cols = [r[1] for r in c.execute("PRAGMA table_info(%s)" % t)]
    if not cols:
        summary.append("%s: absent" % t); continue
    tcols = [x for x in cols if x in TS_COLS or x.endswith("_at")]
    if not tcols:
        summary.append("%s: NO timestamp column, cannot select post-snapshot rows" % t); continue
    # timestamps are RFC3339 text; compare lexically on the normalized prefix
    where = " OR ".join("(%s IS NOT NULL AND %s <> '' AND substr(%s,1,19) > substr(?,1,19))" % (x, x, x) for x in tcols)
    rows = c.execute("SELECT %s FROM %s WHERE %s" % (",".join(cols), t, where), [ts] * len(tcols)).fetchall()
    for r in rows:
        lines.append("INSERT OR REPLACE INTO %s(%s) VALUES(%s);" % (t, ",".join(cols), ",".join(q(v) for v in r)))
    summary.append("%s: %d rows (by %s)" % (t, len(rows), ",".join(tcols)))
lines.append("COMMIT;")
open(out, "w").write("\n".join(lines) + "\n")
print("\n".join(summary))
