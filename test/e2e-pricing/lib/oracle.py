#!/usr/bin/env python3
"""Tier E2 oracles O1-O6 over the VM's REAL state (run on the VM as root).

  oracle.py baseline OUT.json
      snapshot the ids / digests a scenario's checks are relative to.
  oracle.py check --baseline B.json --tables T.json [--expect-snapshots N]
                  [--expect-labels A,B] [--allow-journal] [--sampler S.jsonl --o2-sequence A,B]
      print one JSON verdict {ok, oracles: {O1: {...}, ...}}; exit 0 iff ok.
  oracle.py statement ACCOUNT PERIOD OUT.json
      generate a wholesale statement (operator bearer from coordinator.env).

T.json = {"<label>": {"rows": {<row>: {prompt_rate_per_mtok, prompt_cache_hit_rate_per_mtok,
          completion_rate_per_mtok, ...}}, "card_sha256": "<sha of that release's rate-card.json>"}}
Row resolution is catalog-release.py rate_row_for (the reviewed Python port of
billing.RateFor), loaded from the file beside this one.
"""
import glob
import hashlib
import json
import os
import runpy
import sqlite3
import sys
import urllib.request

ROOT = "/opt/macprovider"
DB = "/var/lib/macprovider/request-log.sqlite"
RECORD = "/run/macprovider/coordinator-applied-config.json"
OVERLAY = "/etc/macprovider/coordinator.pearl-overlays.yaml"
YAML = ROOT + "/coordinator.yaml"
CURRENT_CARD = ROOT + "/autotune/current/rate-card.json"
BUYER = "http://127.0.0.1:8443"
CR = runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "scripts", "catalog-release.py"))
FIELDS = ("prompt_rate_per_mtok", "prompt_cache_hit_rate_per_mtok", "completion_rate_per_mtok")


def sha(b):
    return hashlib.sha256(b).hexdigest()


def fsha(p):
    try:
        return sha(open(p, "rb").read())
    except FileNotFoundError:
        return None


def db():
    con = sqlite3.connect("file:%s?mode=ro" % DB, uri=True, timeout=30)
    con.execute("PRAGMA busy_timeout=30000")
    return con


def credit_rows(rows):
    return {k: {f: int(v[f]) for f in FIELDS} for k, v in rows.items()}


def http_get(path):
    with urllib.request.urlopen(BUYER + path, timeout=10) as r:
        return r.read()


def record():
    try:
        return json.loads(open(RECORD).read())
    except (OSError, ValueError):
        return None


def cmd_baseline(out):
    con = db()
    b = {
        "max_snapshot_id": con.execute("SELECT COALESCE(MAX(id),0) FROM ledger_config_snapshots").fetchone()[0],
        "max_credit_id": con.execute("SELECT COALESCE(MAX(id),0) FROM ledger_request_credits").fetchone()[0],
        "overlay_sha256": fsha(OVERLAY),
        "yaml_sha256": fsha(YAML),
        "record": record(),
    }
    json.dump(b, open(out, "w"), indent=1, sort_keys=True)
    print(json.dumps({"baseline": out, "max_snapshot_id": b["max_snapshot_id"], "max_credit_id": b["max_credit_id"]}))


def load_tables(path):
    """Reviewed tables: the harness file plus every release ever uploaded to this
    host (label = its release_id): a table in force was one of those."""
    tables = json.load(open(path)) if path and os.path.exists(path) else {}
    for d in sorted(glob.glob(ROOT + "/autotune/releases/*/")):
        try:
            rid = json.load(open(d + "release.json"))["release_id"]
            raw = open(d + "rate-card.json", "rb").read()
        except (OSError, ValueError, KeyError):
            continue
        tables.setdefault(rid, {"rows": json.loads(raw)["rows"], "card_sha256": sha(raw)})
    return tables


def labels_of(tables, rows):
    cr = credit_rows(rows)
    return sorted(name for name, t in tables.items() if credit_rows(t["rows"]) == cr)


def label_of(tables, rows):
    m = labels_of(tables, rows)
    return "|".join(m) if m else None


def o1(con, tables, since_credit):
    bad, labels, n = [], {}, 0
    q = """
SELECT c.id, c.request_id, c.attempt_n, c.model, c.prompt_rate_per_mtok, c.completion_rate_per_mtok,
       i.config_snapshot_id, s.rate_card_json
  FROM ledger_request_credits c
  LEFT JOIN ledger_provider_identity_snapshots i
         ON i.request_id = c.request_id AND i.attempt_n = c.attempt_n
        AND (c.provider_assigned_id IS NULL OR i.provider_assigned_id = c.provider_assigned_id)
  LEFT JOIN ledger_config_snapshots s ON s.id = i.config_snapshot_id
 WHERE c.id > ? ORDER BY c.id"""
    seen = set()
    for cid, rid, att, model, pr, cr_, snap, raw in con.execute(q, (since_credit,)):
        n += 1
        if cid in seen:
            bad.append("credit %d links more than one identity row" % cid)
            continue
        seen.add(cid)
        if snap is None or raw is None:
            bad.append("credit %d (%s) has no linked config snapshot" % (cid, rid))
            continue
        rows = json.loads(raw)
        lab = label_of(tables, rows)
        if lab is None:
            bad.append("credit %d links snapshot %d whose table is no reviewed table" % (cid, snap))
            continue
        key = CR["rate_row_for"](rows, model)
        want = rows.get(key) if key else None
        if want is None or int(want["prompt_rate_per_mtok"]) != pr or int(want["completion_rate_per_mtok"]) != cr_:
            bad.append("credit %d model=%r priced %d/%d but snapshot %d (%s row %s) says %s" % (
                cid, model, pr, cr_, snap, lab, key, want and (want["prompt_rate_per_mtok"], want["completion_rate_per_mtok"])))
        labels[rid] = (lab, snap)
    return {"ok": not bad and n > 0, "credits_checked": n, "problems": bad[:20] or ([] if n else ["no new ledger credits (load generator idle?)"])}, labels


def o3(con, tables, since_snap, expect, expect_labels):
    rows = con.execute("SELECT id, rate_card_json FROM ledger_config_snapshots WHERE id > ? ORDER BY id", (since_snap,)).fetchall()
    labs = [label_of(tables, json.loads(r[1])) for r in rows]
    problems = []
    if expect is not None and len(rows) != expect:
        problems.append("expected %d new snapshot rows, found %d" % (expect, len(rows)))
    for (sid, _), lab in zip(rows, labs):
        if lab is None or (expect_labels and not set(lab.split("|")) & set(expect_labels)):
            problems.append("snapshot %d is table %s (allowed %s)" % (sid, lab, expect_labels))
    return {"ok": not problems, "new_snapshots": [{"id": r[0], "table": l} for r, l in zip(rows, labs)], "problems": problems}


def yaml_rows():
    return CR["coordinator_credit_rows"](open(YAML).read())


def o5(baseline, allow_journal):
    problems = []
    try:
        yrows = yaml_rows()
    except BaseException as exc:  # CatalogError is SystemExit-like in the tool
        yrows = None
        problems.append("cannot parse yaml rewards.rate_card: %s" % exc)
    card = json.loads(open(CURRENT_CARD).read())
    if yrows is not None and yrows != credit_rows(card["rows"]):
        problems.append("on-disk yaml rewards.rate_card != current/rate-card.json rows")
    if fsha(OVERLAY) != baseline["overlay_sha256"]:
        problems.append("overlay changed (%s -> %s)" % (baseline["overlay_sha256"], fsha(OVERLAY)))
    left = sorted(glob.glob(ROOT + "/.pricing-txn*"))
    if left and not allow_journal:
        problems.append("pricing transaction leftovers: %s" % left)
    return {"ok": not problems, "journal_entries": left, "problems": problems}


def o6(tables):
    problems = []
    if os.path.exists(ROOT + "/.pricing-txn"):
        return {"ok": True, "skipped": "transaction open"}
    try:
        served = http_get("/v1/rate-card")
    except Exception as exc:
        return {"ok": False, "problems": ["cannot GET /v1/rate-card: %s" % exc]}
    disk = open(CURRENT_CARD, "rb").read()
    rec = record() or {}
    if sha(served) != sha(disk):
        problems.append("served card %s != current/rate-card.json %s" % (sha(served)[:12], sha(disk)[:12]))
    if rec.get("signed_rate_card_sha256") not in (None, sha(served)):
        problems.append("applied record signed_rate_card_sha256 %s != served %s" % (rec.get("signed_rate_card_sha256"), sha(served)[:12]))
    if "signed_rate_card_sha256" not in rec:
        problems.append("applied record has no signed_rate_card_sha256 (pre-#1693 coordinator?)")
    lab = sorted(n for n, t in tables.items() if t.get("card_sha256") == sha(served))
    return {"ok": not problems, "served_card": sha(served), "served_table": "|".join(lab) if lab else None, "problems": problems}


def o2(con, sampler, labels, tables, sequence):
    """Monotone publication/billing order: for non-overlapping events e1 before
    e2 (e1.end < e2.start) the generation index never decreases. Events: card
    reads (label by card sha) and priced requests (label by ledger snapshot)."""
    if not sampler or not os.path.exists(sampler):
        return {"ok": True, "skipped": "no sampler log"}
    card_label = {}
    for n, t in tables.items():
        card_label.setdefault(t.get("card_sha256"), n)
    ext_to_rid = dict(con.execute("SELECT external_request_id, request_id FROM request_log WHERE external_request_id IS NOT NULL"))
    events, missing = [], 0
    for line in open(sampler):
        e = json.loads(line)
        if e["kind"] == "card":
            lab = card_label.get(e.get("sha"))
        else:
            lab = labels.get(ext_to_rid.get(e.get("external_id")), (None,))[0]
            if lab is None:
                missing += 1
                continue
        if lab is None:
            continue
        events.append((e["t0"], e["t1"], lab, e["kind"], e.get("external_id") or e.get("sha", "")[:12]))
    if len(sequence) < 2:
        return {"ok": True, "events": len(events), "skipped": "single-generation scenario"}
    idx = {}
    for i, lab in enumerate(sequence):
        idx[lab] = i
    def gen(lab):
        return max((idx.get(x, -1) for x in lab.split("|")), default=-1)
    events.sort()
    violations = []
    # max generation index among events that ENDED before each event started
    ends = sorted((t1, gen(lab), kind, ref) for (_, t1, lab, kind, ref) in events)
    j, best, best_ev = 0, -1, None
    for t0, t1, lab, kind, ref in events:
        while j < len(ends) and ends[j][0] < t0:
            if ends[j][1] > best:
                best, best_ev = ends[j][1], ends[j]
            j += 1
        g = gen(lab)
        if g < best:
            violations.append("%s %s at %.3f observed %s after %s %s (%s) completed" % (
                kind, ref, t0, lab, best_ev[2], best_ev[3], sequence[best]))
    return {"ok": not violations and bool(events), "events": len(events), "requests_without_ledger_row": missing,
            "violations": violations[:20]}


def cmd_check(args):
    baseline = json.load(open(args["--baseline"]))
    tables = load_tables(args.get("--tables"))
    con = db()
    exp = int(args["--expect-snapshots"]) if "--expect-snapshots" in args else None
    exp_labels = [x for x in args.get("--expect-labels", "").split(",") if x]
    o1v, labels = o1(con, tables, baseline["max_credit_id"])
    out = {
        "O1": o1v,
        "O2": o2(con, args.get("--sampler"), labels, tables, [x for x in args.get("--o2-sequence", "").split(",") if x]),
        "O3": o3(con, tables, baseline["max_snapshot_id"], exp, exp_labels),
        "O5": o5(baseline, "--allow-journal" in args),
        "O6": o6(tables),
    }
    out["ok"] = all(v.get("ok") for v in out.values())
    print(json.dumps(out, sort_keys=True))
    return 0 if out["ok"] else 1


def cmd_statement(account, period, out):
    env = dict(l.strip().split("=", 1) for l in open("/etc/macprovider/coordinator.env") if "=" in l and not l.startswith("#"))
    body = json.dumps({"account_id": account, "period": period}).encode()
    req = urllib.request.Request("http://127.0.0.1:8444/admin/ledger/wholesale-statements", data=body, method="POST",
                                 headers={"Authorization": "Bearer " + env["OPERATOR_KEY"], "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            status, raw = r.status, r.read()
    except urllib.error.HTTPError as exc:
        status, raw = exc.code, exc.read()
    open(out, "wb").write(raw)
    print(json.dumps({"status": status, "bytes": len(raw), "sha256": sha(raw)}))
    return 0 if status == 200 else 1


def list_gross(prompt, completion, row):
    num = prompt * int(row["prompt_rate_per_mtok"]) + completion * int(row["completion_rate_per_mtok"])
    q, r = divmod(num, 1_000_000)
    if 2 * r > 1_000_000 or (2 * r == 1_000_000 and q % 2 == 1):
        q += 1
    return q


def cmd_statement_check(account, period, out):
    """O4 / V12: generate the statement and recompute every line independently:
    status-200 rows of the account in the period, each priced at its own
    generation (linked identity snapshot, else the snapshot in effect at ts_utc),
    grouped per (model, resolved row), summed."""
    rc = cmd_statement(account, period, out)
    st = json.loads(open(out, "rb").read() or b"{}")
    con = db()
    snaps = con.execute("SELECT id, effective_at_utc, rate_card_json FROM ledger_config_snapshots ORDER BY effective_at_utc, id").fetchall()
    rows = con.execute("""
SELECT r.request_id, r.attempt_n, r.model, r.ts_utc, COALESCE(r.prompt_tokens,0), COALESCE(r.completion_tokens,0),
       (SELECT i.config_snapshot_id FROM ledger_provider_identity_snapshots i
         WHERE i.request_id = r.request_id AND i.attempt_n = r.attempt_n AND i.config_snapshot_id IS NOT NULL LIMIT 1)
  FROM request_log r WHERE r.account_id = ? AND r.status = 200 AND substr(r.ts_utc,1,7) = ?""", (account, period)).fetchall()
    by_id = {sid: json.loads(raw) for sid, _, raw in snaps}
    groups = {}
    for rid, att, model, ts, pt, ct, sid in rows:
        if sid is None:
            cand = [x for x in snaps if x[1] <= ts]
            sid = cand[-1][0] if cand else None
        if sid is None:
            groups.setdefault(model, {}).setdefault(("NO-GENERATION",), [0, 0, None])
            continue
        table = by_id[sid]
        key = CR["rate_row_for"](table, model)
        g = groups.setdefault(model, {}).setdefault((key, json.dumps(table.get(key), sort_keys=True)), [0, 0, table.get(key)])
        g[0] += pt; g[1] += ct
    problems, lines = [], {l["model"]: l for l in st.get("line_items", [])}
    for model, gs in groups.items():
        want = sum(list_gross(p, c, r) for (p, c, r) in gs.values() if r is not None)
        got = lines.get(model, {}).get("gross_credits")
        if got != want:
            problems.append("line %r gross %s != recomputed %s over %d generation group(s)" % (model, got, want, len(gs)))
    for model in lines:
        if model not in groups:
            problems.append("statement line %r has no status-200 rows" % model)
    print(json.dumps({"ok": rc == 0 and not problems, "status_ok": rc == 0, "lines": {m: {"gross": l.get("gross_credits"), "requests": l.get("request_count"),
          "groups": len(groups.get(m, {}))} for m, l in lines.items()}, "problems": problems}, sort_keys=True))
    return 0 if rc == 0 and not problems else 1


def parse(argv):
    out, i = {}, 0
    while i < len(argv):
        a = argv[i]
        if a in ("--allow-journal",):
            out[a] = True
            i += 1
        else:
            out[a] = argv[i + 1]
            i += 2
    return out


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "baseline":
        cmd_baseline(sys.argv[2])
    elif cmd == "check":
        sys.exit(cmd_check(parse(sys.argv[2:])))
    elif cmd == "statement-check":
        sys.exit(cmd_statement_check(*sys.argv[2:5]))
    elif cmd == "statement":
        sys.exit(cmd_statement(*sys.argv[2:5]))
    else:
        sys.exit("usage: oracle.py baseline|check|statement ...")
