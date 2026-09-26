#!/usr/bin/env python3
"""#1690 post-fix probe: N long native streams through the lab gateway.
Per stream it records only flags about the delivered text (never the text):
length, non-ASCII count, U+FFFD count, finish reason; then joins the
coordinator verdict via request_log. Lab only."""
import http.client, json, os, pathlib, sqlite3, sys, time, uuid
LAB = pathlib.Path(os.environ["LAB"])
key = (LAB / "keys" / "buyer-key-acct-lab-1690-buyer").read_text().strip()
out = []
for i in range(int(sys.argv[1]) if len(sys.argv) > 1 else 12):
    rid = str(uuid.uuid4())
    body = {"model": "mlx-community/Qwen2.5-0.5B-Instruct-4bit", "max_tokens": 700, "stream": True, "stream_options": {"include_usage": True},
            "messages": [{"role": "user", "content": f"Write a detailed story of about 600 words about a lighthouse keeper and a storm. (ref {rid[:8]})"}]}
    c = http.client.HTTPConnection("127.0.0.1", 19110, timeout=600)
    c.request("POST", "/v1/chat/completions", json.dumps(body), {"Authorization": f"Bearer {key}", "Content-Type": "application/json", "X-Request-ID": rid})
    r = c.getresponse()
    text, finish, frames_with_fffd = "", None, 0
    for line in r.read().decode("utf-8", errors="replace").splitlines():
        if line.startswith("data: {"):
            d = json.loads(line[6:])
            for ch in d.get("choices") or []:
                piece = (ch.get("delta") or {}).get("content") or ""
                frames_with_fffd += "�" in piece
                text += piece
                finish = ch.get("finish_reason") or finish
    out.append({"rid": rid, "status": r.status, "finish": finish, "chars": len(text), "utf8_bytes": len(text.encode()),
                "non_ascii": sum(ord(ch) > 127 for ch in text), "fffd": text.count("�"), "frames_with_fffd": frames_with_fffd})
time.sleep(8)
db = sqlite3.connect(f"file:{LAB / 'db' / 'coordinator.db'}?mode=ro", uri=True)
for o in out:
    ids = [x[0] for x in db.execute("SELECT request_id FROM request_log WHERE external_request_id = ?", (o["rid"],))]
    v = [db.execute("SELECT settlement_outcome, reason FROM settlement_receipt_verdicts WHERE request_id = ?", (i,)).fetchone() for i in ids]
    b = [db.execute("SELECT usage_canonical_json FROM settlement_attempt_outputs WHERE request_id = ?", (i,)).fetchone() for i in ids]
    o["verdict"] = v
    o["delivered_output_bytes"] = [json.loads(x[0]).get("delivered_output_bytes") if x else None for x in b]
    print(json.dumps(o))
