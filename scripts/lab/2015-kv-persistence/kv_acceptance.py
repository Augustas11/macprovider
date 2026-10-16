#!/usr/bin/env python3
"""#2015 / PR #2025 Studio acceptance driver (lab only; never shipped).

Called by studio-kv-acceptance.sh once per lab serve session, then once for the
verdict. Talks only to the lab loopback port. Every request is sequential,
greedy (temperature 0) and carries its own X-Request-ID, so serve-log lines can
be attributed by order. Conversation keys are lab-only strings; the persisted
ones use the direct-HTTP synthetic namespace (conv:kvs-synth:), the hot-only
comparators use a non-synthetic key, which the disk tier never persists.
"""
import argparse
import http.client
import json
import os
import random
import socket
import re
import statistics
import sys
import time
import uuid

WINDOW_BYTES = 1 << 30          # SPEC-037 v0.2 write admission: 1 GiB / 60 s
MAX_ENTRY_BYTES = 2 << 30       # FR-KVP11 default max_entry_bytes
CODEC_V2 = "kvsurv-codec-v2"
SYSTEM = "You are a concise assistant. Answer in one short sentence."
WORDS = ("river stone market lantern copper meadow harbor signal orchard canyon "
         "ledger timber velvet glacier compass ember quarry falcon thistle beacon "
         "archive saddle pepper granite violet tunnel ribbon marble cedar walnut "
         "anchor bramble cobalt dune feather garnet hollow island jasper kettle "
         "linen mosaic nectar oyster pillar quartz raven summit tundra umber "
         "willow yarrow zephyr basin cinder delta fable grove harvest ivory").split()


def say(msg):
    print(f"[{time.strftime('%H:%M:%SZ', time.gmtime())}] 2015-kv: {msg}", file=sys.stderr, flush=True)


def load_state(path):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {"run": uuid.uuid4().hex[:10], "sessions": {}}


def save_state(path, state):
    with open(path, "w") as f:
        json.dump(state, f, indent=1, sort_keys=True)


def document(seed, tokens):
    rng = random.Random(seed)
    words = max(200, int(tokens / 1.35))
    paras, n = [], 0
    while n < words:
        k = min(80, words - n)
        paras.append(f"Paragraph {len(paras) + 1}: " + " ".join(rng.choice(WORDS) for _ in range(k)) + ".")
        n += k
    return "\n\n".join(paras)


class ServeLog:
    def __init__(self, path):
        self.path = path
        self.offset = self._size()

    def _size(self):
        try:
            with open(self.path, "rb") as f:
                f.seek(0, 2)
                return f.tell()
        except FileNotFoundError:
            return 0

    def mark(self):
        self.offset = self._size()
        return self.offset

    def since(self, offset):
        with open(self.path, "rb") as f:
            f.seek(offset)
            return f.read().decode("utf-8", "replace").splitlines()


def kv_fields(line):
    return dict(re.findall(r"(\w+)=(\S+)", line))


class Lab:
    def __init__(self, port, log_path, state):
        self.port = port
        self.log = ServeLog(log_path)
        self.state = state
        self.run = state["run"]
        self.doc_tokens = int(os.environ.get("DOC_TOKENS", "6000"))
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        conn.request("GET", "/v1/status")
        self.model = json.loads(conn.getresponse().read())["model"]
        conn.close()
        self.writes = []  # (end_time, bytes) of persisted turns, for write pacing

    # -- keys and prompts --------------------------------------------------
    def key(self, kind, name):
        if kind == "synth":
            return f"conv:kvs-synth:2015-{self.run}-{name}"
        if kind == "hot":
            return f"conv:hot2015-{self.run}-{name}"
        return None

    def t1_messages(self, seed, q1, mutate=False):
        doc = document(seed, self.doc_tokens)
        if mutate:
            doc = "Paragraph 0: this document was revised before the first paragraph.\n\n" + doc
        return [{"role": "system", "content": SYSTEM},
                {"role": "user", "content": f"Document:\n{doc}\n\nQuestion: {q1}"}]

    def t2_messages(self, seed, q1, reply1, q2, mutate=False):
        return self.t1_messages(seed, q1, mutate) + [
            {"role": "assistant", "content": reply1},
            {"role": "user", "content": q2}]

    # -- one streamed request ----------------------------------------------
    def chat(self, messages, key=None, max_tokens=64, stop=None, cancel_after=None):
        rid = f"lab2015-{uuid.uuid4().hex[:16]}"
        body = {"model": self.model, "messages": messages, "stream": True, "temperature": 0,
                "top_p": 1, "seed": 7, "max_tokens": max_tokens}
        if stop:
            body["stop"] = stop
        headers = {"Content-Type": "application/json", "X-Request-ID": rid}
        if key:
            headers["X-MacProvider-Provider-Conversation"] = key
        offset = self.log.mark()
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=600)
        t0 = time.monotonic()
        conn.request("POST", "/v1/chat/completions", json.dumps(body), headers)
        sock = conn.sock
        resp = conn.getresponse()
        if resp.status != 200:
            raise RuntimeError(f"HTTP {resp.status}: {resp.read()[:400]!r}")
        text, reasoning, finish, usage, ttft, chunks, cancelled = [], [], None, None, None, 0, False
        while True:
            raw = resp.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            obj = json.loads(data)
            usage = obj.get("usage") or usage
            for ch in obj.get("choices") or []:
                delta = ch.get("delta") or {}
                piece = (delta.get("content") or "") + (delta.get("reasoning_content") or "")
                if piece:
                    if ttft is None:
                        ttft = (time.monotonic() - t0) * 1000
                    chunks += 1
                    text.append(delta.get("content") or "")
                    reasoning.append(delta.get("reasoning_content") or "")
                finish = ch.get("finish_reason") or finish
            if cancel_after is not None and chunks >= cancel_after:
                cancelled = True
                break
        total = (time.monotonic() - t0) * 1000
        if cancelled:
            # Client disconnect: drop the socket mid-stream.
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            resp.close()
        conn.close()
        time.sleep(1.0 if not cancelled else 5.0)
        lines = self.log.since(offset)
        tele = {}
        for ln in lines:
            if '"kv_cache_request_completed"' in ln and rid in ln:
                try:
                    tele = json.loads(ln[ln.index("{"):])
                except ValueError:
                    pass
        u = usage or {}
        cached = tele.get("cached_prompt_tokens")
        if cached is None:
            cached = max(u.get("cached_prompt_tokens") or 0,
                         (u.get("prompt_tokens_details") or {}).get("cached_tokens") or 0)
        conv = [kv_fields(ln) for ln in lines if "event=conv_cache" in ln]
        disk = [kv_fields(ln) for ln in lines if "event=kv_disk_cache" in ln]
        return {
            "request_id": rid,
            "text": "".join(text), "reasoning": "".join(reasoning), "finish_reason": finish,
            "prompt_tokens": tele.get("prompt_tokens", u.get("prompt_tokens")),
            "completion_tokens": tele.get("completion_tokens", u.get("completion_tokens")),
            "cached_prompt_tokens": cached, "ttft_ms": ttft, "total_ms": total,
            "cancelled": cancelled, "conv_cache": conv, "kv_disk": disk,
            "disk_hit": [d for d in disk if d.get("code") == "disk_hit"],
        }

    # -- persisted-write bookkeeping -----------------------------------------
    def wait_commit(self, offset, timeout=60):
        """Wait for the cold write outcome of the turn that just finished."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for ln in self.log.since(offset):
                if "code=disk_write_committed" in ln or "code=disk_write_skipped" in ln \
                        or "action=capture_skipped" in ln:
                    f = kv_fields(ln)
                    f["outcome"] = ("committed" if "disk_write_committed" in ln
                                    else "skipped" if "disk_write_skipped" in ln else "capture_skipped")
                    if f["outcome"] == "committed":
                        self.writes.append((time.monotonic(), int(f.get("serialized_bytes", "0"))))
                    return f
            time.sleep(0.5)
        return {"outcome": "none"}

    def pace(self):
        """Keep decoded snapshots under the 1 GiB / 60 s write window."""
        if not self.writes:
            return
        last = self.writes[-1][1]
        while True:
            now = time.monotonic()
            recent = [(t, b) for t, b in self.writes if now - t < 61]
            if sum(b for _, b in recent) + last <= 0.9 * WINDOW_BYTES or not recent:
                return
            time.sleep(max(1.0, 61 - (now - recent[0][0])))


SCEN = {
    # name: (seed, q1, q2, t1 kwargs)
    "main": (11, "What is the first word of Paragraph 3?", "What is the last word of Paragraph 5?", {"max_tokens": 64}),
    "stopseq": (12, "Reply with exactly this text and nothing else: alpha, beta, gamma, delta, epsilon",
                "Repeat your previous reply.", {"max_tokens": 64, "stop": ["gamma"]}),
    "length": (13, "Describe every paragraph of the document in detail.",
               "Now answer in one sentence: what is the first word of Paragraph 2?", {"max_tokens": 12}),
}
DIV = (14, "What is the first word of Paragraph 3?", "What is the last word of Paragraph 5?")
CANCEL = (15, "Write a long essay that discusses every paragraph of the document.")
TTFT_Q = ("What is the first word of Paragraph 2?", "What is the first word of Paragraph 4?")


def brief(r):
    return (f"cached={r['cached_prompt_tokens']} prompt={r['prompt_tokens']} ttft_ms={r['ttft_ms'] and round(r['ttft_ms'])}"
            f" total_ms={round(r['total_ms'])} finish={r['finish_reason']} disk_hit={len(r['disk_hit'])}")


def session(name, args):
    state = load_state(args.state)
    lab = Lab(args.port, args.log, state)
    n = int(os.environ.get("TTFT_CONVERSATIONS", "4"))
    s = state["sessions"].setdefault(name, {})
    s["started"] = time.time()
    ttft_seeds = [100 + i for i in range(n)]

    if name == "off1":
        for i, seed in enumerate(ttft_seeds):
            r = lab.chat(lab.t1_messages(seed, TTFT_Q[0]), lab.key("synth", f"off-{i}"), max_tokens=32)
            s[f"ttft{i}_t1"] = r
            say(f"off1 conv{i} turn1 {brief(r)}")
        s["control_main_t1"] = lab.chat(lab.t1_messages(SCEN["main"][0], SCEN["main"][1]), None, **SCEN["main"][3])
    elif name == "off2":
        for i, seed in enumerate(ttft_seeds):
            reply1 = state["sessions"]["off1"][f"ttft{i}_t1"]["text"]
            r = lab.chat(lab.t2_messages(seed, TTFT_Q[0], reply1, TTFT_Q[1]), lab.key("synth", f"off-{i}"), max_tokens=32)
            s[f"ttft{i}_t2"] = r
            say(f"off2 conv{i} turn2 (miss expected) {brief(r)}")
        s["control_main_t1"] = lab.chat(lab.t1_messages(SCEN["main"][0], SCEN["main"][1]), None, **SCEN["main"][3])
    elif name == "on1":
        def persisted(label, messages, **kw):
            lab.pace()
            r = lab.chat(messages, lab.key("synth", label), **kw)
            r["write"] = lab.wait_commit(lab.log.offset, timeout=60)
            say(f"on1 {label} turn1 {brief(r)} write={r['write'].get('outcome')} "
                f"bytes={r['write'].get('serialized_bytes')} write_ms={r['write'].get('write_ms')} "
                f"codec={r['write'].get('codec_id')} detail={r['write'].get('detail') or r['write'].get('reason')}")
            return r
        for i, seed in enumerate(ttft_seeds):
            s[f"ttft{i}_t1"] = persisted(f"on-{i}", lab.t1_messages(seed, TTFT_Q[0]), max_tokens=32)
        for sc, (seed, q1, q2, kw) in SCEN.items():
            h1 = lab.chat(lab.t1_messages(seed, q1), lab.key("hot", sc), **kw)
            h2 = lab.chat(lab.t2_messages(seed, q1, h1["text"], q2), lab.key("hot", sc), max_tokens=64)
            s[f"{sc}_hot_t1"], s[f"{sc}_hot_t2"] = h1, h2
            say(f"on1 {sc} hot turn2 {brief(h2)}")
            s[f"{sc}_t1"] = persisted(sc, lab.t1_messages(seed, q1), **kw)
        s["div_t1"] = persisted("div", lab.t1_messages(DIV[0], DIV[1]), max_tokens=64)
        # Cancellation: hot key (resend in this process) and persisted key
        # (checked after the restart).
        hc = lab.chat(lab.t1_messages(CANCEL[0], CANCEL[1]), lab.key("hot", "cancel"), max_tokens=400, cancel_after=8)
        s["cancel_hot_cancelled"] = hc
        s["cancel_hot_resend"] = lab.chat(lab.t1_messages(CANCEL[0], CANCEL[1]), lab.key("hot", "cancel"), max_tokens=48)
        say(f"on1 cancel hot resend {brief(s['cancel_hot_resend'])}")
        lab.pace()
        off = lab.log.mark()
        sc_ = lab.chat(lab.t1_messages(CANCEL[0], CANCEL[1]), lab.key("synth", "cancel"), max_tokens=400, cancel_after=8)
        time.sleep(10)
        sc_["write"] = next((dict(kv_fields(l), outcome="committed") for l in lab.log.since(off)
                             if "code=disk_write_committed" in l), {"outcome": "none"})
        s["cancel_cancelled"] = sc_
        say(f"on1 cancel persisted key cancelled after {sc_['total_ms']:.0f} ms write={sc_['write']['outcome']}")
        s["last_write_at"] = time.time()
    elif name == "on2":
        on1 = state["sessions"]["on1"]
        s["first_request_at"] = time.time()
        for i, seed in enumerate(ttft_seeds):
            reply1 = on1[f"ttft{i}_t1"]["text"]
            r = lab.chat(lab.t2_messages(seed, TTFT_Q[0], reply1, TTFT_Q[1]), lab.key("synth", f"on-{i}"), max_tokens=32)
            s[f"ttft{i}_t2"] = r
            say(f"on2 conv{i} turn2 (cold restore expected) {brief(r)} decrypt_ms={[d.get('decrypt_ms') for d in r['disk_hit']]}")
        for sc, (seed, q1, q2, kw) in SCEN.items():
            msgs = lab.t2_messages(seed, q1, on1[f"{sc}_t1"]["text"], q2)
            s[f"{sc}_cold_t2"] = lab.chat(msgs, lab.key("synth", sc), max_tokens=64)
            say(f"on2 {sc} cold turn2 {brief(s[f'{sc}_cold_t2'])}")
        dmsgs = lab.t2_messages(DIV[0], DIV[1], on1["div_t1"]["text"], DIV[2], mutate=True)
        s["div_cold_t2"] = lab.chat(dmsgs, lab.key("synth", "div"), max_tokens=64)
        say(f"on2 divergent turn2 {brief(s['div_cold_t2'])}")
        s["cancel_cold_resend"] = lab.chat(lab.t1_messages(CANCEL[0], CANCEL[1]), lab.key("synth", "cancel"), max_tokens=48)
        say(f"on2 cancel resend {brief(s['cancel_cold_resend'])}")
        # Fresh references in the same process (no key: no cache of any tier).
        for sc, (seed, q1, q2, kw) in SCEN.items():
            msgs = lab.t2_messages(seed, q1, on1[f"{sc}_t1"]["text"], q2)
            s[f"{sc}_fresh_t2"] = lab.chat(msgs, None, max_tokens=64)
        s["div_fresh_t2"] = lab.chat(dmsgs, None, max_tokens=64)
        s["cancel_fresh_t1"] = lab.chat(lab.t1_messages(CANCEL[0], CANCEL[1]), None, max_tokens=48)
        s["control_main_t1"] = lab.chat(lab.t1_messages(SCEN["main"][0], SCEN["main"][1]), None, **SCEN["main"][3])
    else:
        raise SystemExit(f"unknown session {name}")
    s["ended"] = time.time()
    save_state(args.state, state)


def verdict(args):
    state = load_state(args.state)
    S = state["sessions"]
    off1, off2, on1, on2 = S["off1"], S["off2"], S["on1"], S["on2"]
    n = sum(1 for k in on2 if k.startswith("ttft") and k.endswith("_t2"))
    checks, info = [], {}

    def check(cid, ok, detail):
        checks.append({"id": cid, "pass": bool(ok), "detail": detail})

    # D: determinism preconditions (otherwise equality checks are not meaningful).
    det = [off1["control_main_t1"]["text"] == off2["control_main_t1"]["text"] == on2["control_main_t1"]["text"]]
    det += [on1[f"{sc}_hot_t1"]["text"] == on1[f"{sc}_t1"]["text"] for sc in SCEN]
    inconclusive = not all(det)
    info["determinism"] = det

    # (a) cold restore after restart, kvsurv-codec-v2 on the hybrid model.
    hot, cold, fresh = on1["main_hot_t2"], on2["main_cold_t2"], on2["main_fresh_t2"]
    check("A1 main write committed with codec v2", on1["main_t1"]["write"].get("outcome") == "committed"
          and on1["main_t1"]["write"].get("codec_id") == CODEC_V2, on1["main_t1"]["write"])
    check("A2 cold restore hit at the hot boundary", cold["disk_hit"] and cold["cached_prompt_tokens"]
          and cold["cached_prompt_tokens"] == hot["cached_prompt_tokens"]
          and cold["prompt_tokens"] == hot["prompt_tokens"],
          {"cold_cached": cold["cached_prompt_tokens"], "hot_cached": hot["cached_prompt_tokens"],
           "prompt": cold["prompt_tokens"], "disk_hit": cold["disk_hit"], "conv_cache": cold["conv_cache"]})
    check("A3 cold continuation == hot continuation", cold["text"] == hot["text"]
          and cold["completion_tokens"] == hot["completion_tokens"], {"cold": cold["text"], "hot": hot["text"]})
    check("A4 cold == fresh wherever hot == fresh", cold["text"] == fresh["text"] or hot["text"] != fresh["text"],
          {"fresh": fresh["text"], "hot_equals_fresh": hot["text"] == fresh["text"]})
    hits = [on2[f"ttft{i}_t2"] for i in range(n)]
    check("A5 every repeat-prefix conversation restored cold", all(h["disk_hit"] and h["cached_prompt_tokens"] for h in hits),
          [(h["cached_prompt_tokens"], len(h["disk_hit"])) for h in hits])

    # (b) stop-sequence, length and cancellation boundaries; divergent prefix.
    def boundary(sc):
        h, c, f = on1[f"{sc}_hot_t2"], on2[f"{sc}_cold_t2"], on2[f"{sc}_fresh_t2"]
        cc = c["cached_prompt_tokens"] or 0
        aligned = cc in (h["cached_prompt_tokens"] or 0, 0) and cc < (c["prompt_tokens"] or 0)
        correct = (c["text"] == h["text"]) if cc else (c["text"] == f["text"])
        return aligned and correct, {"t1_finish": on1[f"{sc}_t1"]["finish_reason"], "t1_text": on1[f"{sc}_t1"]["text"],
                                     "write": on1[f"{sc}_t1"]["write"].get("outcome"), "cold_cached": cc,
                                     "hot_cached": h["cached_prompt_tokens"], "cold": c["text"], "hot": h["text"],
                                     "fresh": f["text"]}
    ok, d = boundary("stopseq")
    check("B1 user stop sequence boundary", ok and on1["stopseq_t1"]["finish_reason"] == "stop"
          and "gamma" not in on1["stopseq_t1"]["text"], d)
    ok, d = boundary("length")
    check("B2 max_tokens (length) boundary", ok and on1["length_t1"]["finish_reason"] == "length", d)
    check("B3 model stop token (natural EOS) boundary = main", on1["main_t1"]["finish_reason"] == "stop"
          and all(c["pass"] for c in checks if c["id"].startswith(("A2", "A3"))),
          {"main_t1_finish": on1["main_t1"]["finish_reason"]})
    fr = on2["cancel_fresh_t1"]
    for cid, r in (("B4 cancel then resend (hot)", on1["cancel_hot_resend"]),
                   ("B5 cancel, restart, resend (cold)", on2["cancel_cold_resend"])):
        check(cid, r["text"] == fr["text"] and (r["cached_prompt_tokens"] or 0) < (r["prompt_tokens"] or 0),
              {"cached": r["cached_prompt_tokens"], "prompt": r["prompt_tokens"], "text": r["text"], "fresh": fr["text"],
               "cancelled_write": on1["cancel_cancelled"]["write"].get("outcome")})
    dv, df = on2["div_cold_t2"], on2["div_fresh_t2"]
    check("B6 divergent prefix recomputes", not dv["cached_prompt_tokens"] and dv["text"] == df["text"],
          {"cached": dv["cached_prompt_tokens"], "conv_cache": dv["conv_cache"], "text": dv["text"], "fresh": df["text"]})

    # (c) repeat-prefix latency and storage, disk tier off vs on.
    t_off = [off2[f"ttft{i}_t2"]["ttft_ms"] for i in range(n)]
    t_on = [on2[f"ttft{i}_t2"]["ttft_ms"] for i in range(n)]
    net_off = [off1[f"ttft{i}_t1"]["total_ms"] + t_off[i] for i in range(n)]
    net_on = [on1[f"ttft{i}_t1"]["total_ms"] + t_on[i] for i in range(n)]
    info["ttft_ms_off"], info["ttft_ms_on"] = t_off, t_on
    info["turn1_total_ms_off"] = [off1[f"ttft{i}_t1"]["total_ms"] for i in range(n)]
    info["turn1_total_ms_on"] = [on1[f"ttft{i}_t1"]["total_ms"] for i in range(n)]
    info["ttft_ratio_on_off"] = statistics.median(t_on) / statistics.median(t_off)
    check("C1 cold-restore TTFT below prefix-miss TTFT (median)", statistics.median(t_on) < statistics.median(t_off),
          {"median_on_ms": statistics.median(t_on), "median_off_ms": statistics.median(t_off)})
    check("C2 net per conversation (turn1 total + turn2 TTFT) lower with disk on",
          statistics.median(net_on) < statistics.median(net_off),
          {"median_on_ms": statistics.median(net_on), "median_off_ms": statistics.median(net_off)})
    writes = [on1[k]["write"] for k in on1 if isinstance(on1[k], dict) and "write" in on1[k]]
    sizes = [int(w["serialized_bytes"]) for w in writes if w.get("outcome") == "committed"]
    try:
        with open(f"{args.out}/on1-kv-status.json") as f:
            st = json.load(f)
    except (OSError, ValueError):
        st = {}
    info["entry_bytes"] = sizes
    info["write_ms"] = [int(w["write_ms"]) for w in writes if w.get("write_ms")]
    info["decrypt_ms"] = [int(d["decrypt_ms"]) for h in hits for d in h["disk_hit"] if d.get("decrypt_ms")]
    prompt_tokens = [on1[f"ttft{i}_t1"]["prompt_tokens"] or 0 for i in range(n)]
    if sizes and all(prompt_tokens):
        info["bytes_per_prompt_token"] = statistics.median(sizes[:n]) / statistics.median(prompt_tokens)
    check("C3 storage bounded", st.get("status") == "ok" and st["entry_count"] <= st["max_entries"]
          and st["total_bytes_used"] <= st["max_bytes"] and sizes and max(sizes) <= MAX_ENTRY_BYTES
          and not any(w.get("detail") == "write_budget" for w in writes),
          {k: st.get(k) for k in ("entry_count", "max_entries", "bytes_used", "total_bytes_used", "max_bytes")}
          | {"max_entry_bytes_seen": max(sizes) if sizes else None})
    gap = on2["first_request_at"] - on1["last_write_at"]
    info["restart_gap_s"] = gap

    result = "INCONCLUSIVE" if inconclusive and not all(c["pass"] for c in checks) else (
        "PASS" if all(c["pass"] for c in checks) else "FAIL")
    out = {"result": result, "checks": checks, "info": info}
    with open(f"{args.out}/verdict.json", "w") as f:
        json.dump(out, f, indent=1, sort_keys=True, default=str)
    for c in checks:
        say(f"{'PASS' if c['pass'] else 'FAIL'} {c['id']}")
    say(f"ttft median on/off = {statistics.median(t_on):.0f}/{statistics.median(t_off):.0f} ms "
        f"(ratio {info['ttft_ratio_on_off']:.2f}); entry MiB {[round(b / 2**20) for b in sizes]}; "
        f"restart gap {gap:.0f}s; determinism {det}")
    say(f"RESULT={result}")
    return {"PASS": 0, "FAIL": 1, "INCONCLUSIVE": 3}[result]


def main():
    p = argparse.ArgumentParser()
    p.add_argument("phase", choices=["off1", "off2", "on1", "on2", "verdict"])
    p.add_argument("--port", type=int)
    p.add_argument("--log")
    p.add_argument("--state", required=True)
    p.add_argument("--out")
    a = p.parse_args()
    if a.phase == "verdict":
        sys.exit(verdict(a))
    session(a.phase, a)


if __name__ == "__main__":
    main()
