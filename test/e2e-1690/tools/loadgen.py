#!/usr/bin/env python3
"""#1690 e2e buyer traffic through nginx (https://api.malibu.tech -> gateway).

Kinds (each request carries a client X-Request-ID "<run>-<kind>-<n>"):
  ns     non-streaming, body fully read
  st     streaming, read to [DONE]
  st_dc  streaming, disconnect after --dc-events SSE data events
  ns_dc  non-streaming, send, then close the socket before any response
         byte (the fake provider delays non-streaming responses)
  ns_over non-streaming with max_tokens=16 < the 20 tokens the fake returns
         (the gateway answers 502 invalid_provider_usage)
Writes one JSON line per request to --out and prints a summary line.
"""
import argparse, concurrent.futures, http.client, json, socket, ssl, sys, time, uuid

ap = argparse.ArgumentParser()
ap.add_argument("--run", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--key-file", default="/root/e2e/buyer-api-key")
ap.add_argument("--host", default="api.malibu.tech")
ap.add_argument("--port", type=int, default=443)
ap.add_argument("--plain", action="store_true", help="plain HTTP (direct to the gateway)")
ap.add_argument("--model", default="meta-llama/llama-3.2-3b-instruct")
ap.add_argument("--mix", default="ns=4,st=4,st_dc=2,ns_dc=2")
ap.add_argument("--workers", type=int, default=4)
ap.add_argument("--dc-events", type=int, default=3)
ap.add_argument("--ns-dc-after", type=float, default=0.4)
ap.add_argument("--header", action="append", default=[], help="extra request header Name:Value")
a = ap.parse_args()
key = open(a.key_file).read().strip()
ctx = ssl.create_default_context()


def conn():
    if a.plain:
        return http.client.HTTPConnection(a.host, a.port, timeout=120)
    return http.client.HTTPSConnection(a.host, a.port, timeout=120, context=ctx)


def body(stream, rid, max_tokens=64):
    # rid in the prompt: identical bodies would be folded by the gateway id-less dedupe
    return json.dumps({"model": a.model, "stream": stream, "max_tokens": max_tokens,
                       "messages": [{"role": "user", "content": "say hello (e2e-1690 %s)" % rid}]}).encode()


EXTRA = dict(h.split(":", 1) for h in a.header)


def headers(rid):
    h = {"Authorization": "Bearer " + key, "Content-Type": "application/json", "X-Request-ID": rid}
    h.update(EXTRA)
    return h


def one(kind, n):
    # The gateway only honours a UUID-shaped X-Request-ID; the run/kind label
    # travels in the evidence file (and in the prompt).
    rid = str(uuid.uuid4())
    rec = {"rid": rid, "run": a.run, "kind": kind, "label": "%s-%s-%03d" % (a.run, kind, n), "t0": time.time()}
    try:
        if kind == "ns_dc":
            raw = socket.create_connection((a.host, a.port), timeout=30)
            s = raw if a.plain else ctx.wrap_socket(raw, server_hostname=a.host)
            b = body(False, rid)
            req = ("POST /v1/chat/completions HTTP/1.1\r\nHost: %s\r\nAuthorization: Bearer %s\r\n"
                   "Content-Type: application/json\r\nX-Request-ID: %s\r\n%sContent-Length: %d\r\n\r\n") % (a.host, key, rid, "".join("%s: %s\r\n" % kv for kv in EXTRA.items()), len(b))
            s.sendall(req.encode() + b)
            time.sleep(a.ns_dc_after)
            s.close()
            rec["status"] = "client_closed"
            return rec
        c = conn()
        stream = kind.startswith("st")
        # ns_over: max_tokens below what the provider returns (20 tokens), so the
        # gateway rejects the provider usage and answers 502.
        c.request("POST", "/v1/chat/completions", body=body(stream, rid, 16 if kind == "ns_over" else 64), headers=headers(rid))
        r = c.getresponse()
        rec["status"] = r.status
        rec["resp_request_id"] = r.getheader("X-Request-ID")
        if not stream:
            data = r.read()
            rec["bytes"] = len(data)
            try:
                rec["usage"] = json.loads(data).get("usage")
            except Exception:
                rec["body"] = data[:300].decode("utf-8", "replace")
            c.close()
            return rec
        events, usage, done = 0, None, False
        while True:
            line = r.readline()
            if not line:
                break
            line = line.strip()
            if not line.startswith(b"data:"):
                continue
            payload = line[5:].strip()
            if payload == b"[DONE]":
                done = True
                break
            events += 1
            try:
                obj = json.loads(payload)
                if obj.get("usage"):
                    usage = obj["usage"]
            except Exception:
                pass
            if kind == "st_dc" and events >= a.dc_events:
                rec["disconnected_after_events"] = events
                c.sock.shutdown(socket.SHUT_RDWR)
                c.close()
                break
        rec.update(events=events, usage=usage, done=done)
        return rec
    except Exception as e:
        rec["error"] = "%s: %s" % (type(e).__name__, e)
        return rec
    finally:
        rec["t1"] = time.time()


jobs = []
for part in a.mix.split(","):
    k, v = part.split("=")
    jobs += [(k, i) for i in range(int(v))]
out = []
# ns_over runs alone after the concurrent batch, so it always reaches a free
# provider slot (with 4 workers every slot can be busy and the coordinator
# answers 503 no_provider_available instead of exercising the 502 path).
late = [j for j in jobs if j[0] == "ns_over"]
with concurrent.futures.ThreadPoolExecutor(a.workers) as ex:
    for rec in ex.map(lambda j: one(*j), [j for j in jobs if j[0] != "ns_over"]):
        out.append(rec)
if late:
    time.sleep(2.5)
for j in late:
    out.append(one(*j))
with open(a.out, "a") as f:
    for rec in out:
        f.write(json.dumps(rec, sort_keys=True) + "\n")
summary = {}
for rec in out:
    k = "%s:%s" % (rec["kind"], rec.get("status", rec.get("error", "?")))
    summary[k] = summary.get(k, 0) + 1
print(json.dumps({"run": a.run, "requests": len(out), "by_kind_status": summary,
                  "errors": [r["label"] + " " + r["error"] for r in out if "error" in r][:5]}, sort_keys=True))
