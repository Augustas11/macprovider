#!/usr/bin/env python3
"""CB enable-gate HTTP rows on an isolated lab serve (loopback only).

phase serial  : run fixtures one at a time against a CB-off serve, save outputs.
phase cb      : against a CB-on serve run keyless, keyed first-turn, alone and
                concurrent fixtures; compare with the serial outputs; sample
                /v1/status during the concurrent burst.
"""
import json, sys, time, uuid, threading, urllib.request

def post(port, body, headers):
    req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions",
                                 data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    for k, v in headers.items():
        req.add_header(k, v)
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=600) as r:
        data = json.loads(r.read())
        return {"http": r.status, "elapsed_s": round(time.time() - t0, 3),
                "x_request_id": r.headers.get("X-Request-ID"),
                "content": data["choices"][0]["message"].get("content"),
                "reasoning": data["choices"][0]["message"].get("reasoning_content"),
                "finish_reason": data["choices"][0].get("finish_reason"),
                "usage": data.get("usage")}

def status(port):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/v1/status", timeout=10) as r:
        return json.loads(r.read())

WORDS = ("river", "copper", "lantern", "orchard", "glacier", "harbor", "violet", "meadow")
def fixtures(model):
    out = []
    for i in range(4):
        # ~700-token prompts, distinct per row, so prefill crosses the 512 step.
        filler = " ".join(f"{WORDS[(i + j) % 8]}-{i}-{j}" for j in range(160))
        out.append({"id": f"fx{i}", "body": {
            "model": model, "temperature": 0, "max_tokens": 96 + 32 * i, "stream": False,
            "messages": [{"role": "user", "content":
                f"Fixture {i}. Here is a list: {filler}\nSummarise the list in exactly three sentences, then count how many distinct colours it names."}]}})
    return out

def main():
    phase, port, model, path = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
    fx = fixtures(model)
    if phase == "serial":
        res = {f["id"]: post(port, f["body"], {"X-Request-ID": f"lab-serial-{f['id']}-{uuid.uuid4()}"}) for f in fx}
        json.dump(res, open(path, "w"), indent=1)
        print(json.dumps({k: (v["http"], v["finish_reason"], v["usage"]) for k, v in res.items()}))
        return
    serial = json.load(open(path))
    out = {}
    out["keyless"] = post(port, fx[0]["body"], {"X-Request-ID": f"lab-keyless-{uuid.uuid4()}"})
    conv = f"lab-conv-{uuid.uuid4()}"
    out["keyed_first_turn"] = post(port, fx[1]["body"], {"X-Request-ID": f"lab-keyed-{uuid.uuid4()}",
                                                          "X-MacProvider-Provider-Conversation": conv})
    out["alone"] = {f["id"]: post(port, f["body"], {"X-Request-ID": f"lab-alone-{f['id']}-{uuid.uuid4()}"}) for f in fx}
    conc, samples, done = {}, [], threading.Event()
    def run(f):
        rid = f"lab-conc-{f['id']}-{uuid.uuid4()}"
        r = post(port, f["body"], {"X-Request-ID": rid}); r["sent_request_id"] = rid; conc[f["id"]] = r
    def sampler():
        while not done.is_set():
            s = status(port)["continuous_batching"]["scheduler"]; s["t"] = round(time.time(), 2); samples.append(s); time.sleep(0.25)
    st = threading.Thread(target=sampler); st.start()
    th = [threading.Thread(target=run, args=(f,)) for f in fx]
    [t.start() for t in th]; [t.join() for t in th]; done.set(); st.join()
    out["concurrent"], out["status_samples"] = conc, samples
    rows = []
    for f in fx:
        k = f["id"]; s, a, c = serial[k], out["alone"][k], conc[k]
        rows.append({"id": k, "serial_vs_alone": (s["content"], s["reasoning"]) == (a["content"], a["reasoning"]),
                     "serial_vs_concurrent": (s["content"], s["reasoning"]) == (c["content"], c["reasoning"]),
                     "usage_serial": s["usage"], "usage_concurrent": c["usage"],
                     "usage_match": s["usage"] == c["usage"], "finish": [s["finish_reason"], a["finish_reason"], c["finish_reason"]],
                     "request_id_echo": c["x_request_id"] == c["sent_request_id"]})
    out["parity_rows"] = rows
    out["max_active_rows_sampled"] = max((x.get("active_decode_rows", 0) for x in samples), default=0)
    json.dump(out, open(path.replace(".json", "-cb.json"), "w"), indent=1)
    print(json.dumps({"keyless": [out["keyless"]["http"], out["keyless"]["finish_reason"]],
                      "keyed": [out["keyed_first_turn"]["http"], out["keyed_first_turn"]["finish_reason"]],
                      "rows": [{k: r[k] for k in ("id", "serial_vs_alone", "serial_vs_concurrent", "usage_match", "finish", "request_id_echo")} for r in rows],
                      "max_active_rows_sampled": out["max_active_rows_sampled"]}, indent=1))

main()
