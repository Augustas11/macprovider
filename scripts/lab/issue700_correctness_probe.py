#!/usr/bin/env python3
"""MLX_ENGINE_UPGRADE_MATRIX model-row correctness probe for a lab provider.

Talks to an already-running `macprovider-cli serve --no-join` instance on
loopback and checks the Gemma 4 MoE row or the GPT-OSS plain/reasoning/tools
rows. Correctness only: no throughput is measured or reported.

usage: issue700_correctness_probe.py --port N --family gemma4|gpt_oss --out FILE
Exit 0 when every check passes, 1 otherwise.
"""
import argparse
import json
import re
import sys
import urllib.error
import urllib.request

# Control/channel tokens that must never reach buyer-visible content.
LEAK_PATTERNS = {
    "gemma4": [r"<turn\|>", r"<\|turn>", r"<end_of_turn>", r"<start_of_turn>", r"<eos>", r"<bos>", r"<\|channel", r"<channel\|>"],
    "gpt_oss": [r"<\|channel\|>", r"<\|message\|>", r"<\|start\|>", r"<\|end\|>", r"<\|return\|>", r"<\|call\|>", r"<\|constrain\|>",
                r"\banalysis\b<", r"assistantfinal", r"assistantanalysis"],
}


def post(port, body, stream=False, timeout=600):
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        if not stream:
            return json.loads(resp.read())
        chunks = []
        for raw in resp:
            line = raw.decode().strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            chunks.append(json.loads(data))
        return chunks


def leaks(family, text):
    return [p for p in LEAK_PATTERNS[family] if text and re.search(p, text)]


class Probe:
    def __init__(self, port, family, model):
        self.port, self.family, self.model = port, family, model
        self.results = []

    def body(self, messages, **kw):
        b = {"model": self.model, "messages": messages, "temperature": 0, "max_tokens": kw.pop("max_tokens", 128)}
        b.update(kw)
        return b

    def check(self, name, ok, **evidence):
        self.results.append({"check": name, "pass": bool(ok), **evidence})
        print(f"{'PASS' if ok else 'FAIL'} {name} {json.dumps(evidence)[:400]}", flush=True)

    def ask(self, messages, **kw):
        r = post(self.port, self.body(messages, **kw))
        ch = r["choices"][0]
        return r, ch["message"], ch.get("finish_reason"), r.get("usage", {})

    def ask_stream(self, messages, **kw):
        chunks = post(self.port, self.body(messages, stream=True, stream_options={"include_usage": True}, **kw), stream=True)
        content, finish, usage, deltas = "", None, {}, 0
        tool_deltas = []
        for c in chunks:
            if c.get("usage"):
                usage = c["usage"]
            for ch in c.get("choices", []):
                d = ch.get("delta", {})
                if d.get("content"):
                    content += d["content"]
                    deltas += 1
                if d.get("tool_calls"):
                    tool_deltas.extend(d["tool_calls"])
                if ch.get("finish_reason"):
                    finish = ch["finish_reason"]
        return content, finish, usage, deltas, tool_deltas

    # ---- shared rows -------------------------------------------------
    def greedy_and_eos(self):
        msgs = [{"role": "user", "content": "What is the capital of France? Answer in one short sentence."}]
        r1, m1, f1, u1 = self.ask(msgs)
        r2, m2, f2, u2 = self.ask(msgs)
        c1 = m1.get("content") or ""
        self.check("load_and_generate", "paris" in c1.lower(), content=c1, usage=u1)
        self.check("greedy_deterministic", c1 == (m2.get("content") or "") and u1.get("completion_tokens") == u2.get("completion_tokens"),
                   second=m2.get("content"))
        self.check("eos_stop", f1 == "stop" and 0 < u1.get("completion_tokens", 0) < 128, finish_reason=f1,
                   completion_tokens=u1.get("completion_tokens"))
        self.check("no_control_token_leak", not leaks(self.family, c1), leaked=leaks(self.family, c1))
        pt, ct, tt = u1.get("prompt_tokens"), u1.get("completion_tokens"), u1.get("total_tokens")
        self.check("usage_consistent", isinstance(pt, int) and pt > 0 and isinstance(ct, int) and tt == pt + ct, usage=u1)
        return c1, u1

    def stream_parity(self, ref_content, ref_usage):
        msgs = [{"role": "user", "content": "What is the capital of France? Answer in one short sentence."}]
        content, finish, usage, deltas, _ = self.ask_stream(msgs)
        self.check("stream_matches_nonstream",
                   content == ref_content and finish == "stop" and usage.get("completion_tokens") == ref_usage.get("completion_tokens")
                   and usage.get("prompt_tokens") == ref_usage.get("prompt_tokens"),
                   stream_content=content, finish_reason=finish, usage=usage, content_deltas=deltas)

    def max_tokens(self):
        msgs = [{"role": "user", "content": "Write a long essay about the history of the Roman Empire."}]
        # Harmony spends the first tokens in the hidden analysis channel, so the
        # budget must reach the final channel for a `length` finish.
        budget = 400 if self.family == "gpt_oss" else 24
        _, m, f, u = self.ask(msgs, max_tokens=budget)
        gen = u.get("macprovider_generated_completion_tokens", u.get("completion_tokens"))
        self.check("max_tokens_length", f == "length" and gen == budget, finish_reason=f, usage=u)
        content, f2, u2, deltas, _ = self.ask_stream(msgs, max_tokens=budget)
        gen2 = u2.get("macprovider_generated_completion_tokens", u2.get("completion_tokens"))
        self.check("max_tokens_length_stream", f2 == "length" and gen2 == budget and content == (m.get("content") or ""),
                   finish_reason=f2, usage=u2, content_deltas=deltas)
        if self.family == "gpt_oss":
            # SPEC-018 fail-closed: a budget exhausted inside the analysis
            # channel (no terminated final frame) must be a 502, not a 200.
            try:
                self.ask(msgs, max_tokens=24)
                self.check("analysis_exhausted_fail_closed", False, status=200)
            except urllib.error.HTTPError as e:
                body = e.read().decode(errors="replace")
                self.check("analysis_exhausted_fail_closed", e.code == 502, status=e.code, body=body[:300])

    def stop_string(self):
        msgs = [{"role": "user", "content": "Count from 1 to 30, separated by commas and spaces, nothing else."}]
        budget = 1200 if self.family == "gpt_oss" else 200
        _, full, _, _ = self.ask(msgs, max_tokens=budget)
        full_c = full.get("content") or ""
        _, m, f, u = self.ask(msgs, max_tokens=budget, stop=["12"])
        c = m.get("content") or ""
        self.check("stop_string", f == "stop" and "12" not in c and "11" in c and full_c.startswith(c),
                   content=c, finish_reason=f, usage=u, unstopped_prefix=full_c[:80])
        # multi-token stop string
        _, m2, f2, u2 = self.ask(msgs, max_tokens=budget, stop=["15, 16"])
        c2 = m2.get("content") or ""
        self.check("stop_string_multitoken", f2 == "stop" and "16" not in c2 and "14" in c2, content=c2, finish_reason=f2, usage=u2)
        content, f3, u3, _, _ = self.ask_stream(msgs, max_tokens=budget, stop=["12"])
        self.check("stop_string_stream", f3 == "stop" and content == c, stream_content=content, usage=u3)
        # Billing parity: the same request must report the same completion_tokens
        # streamed and non-streamed. Engine-independent (provider stop path).
        self.check("stop_string_completion_tokens_parity", u3.get("completion_tokens") == u.get("completion_tokens"),
                   nonstream_completion_tokens=u.get("completion_tokens"), stream_completion_tokens=u3.get("completion_tokens"))

    # ---- gpt-oss rows -----------------------------------------------
    def gpt_oss_reasoning(self):
        msgs = [{"role": "user", "content": "A train leaves at 3:15 pm and the trip takes 2 hours 50 minutes. What time does it arrive? Give only the time."}]
        _, m, f, u = self.ask(msgs, max_tokens=1024)
        c = m.get("content") or ""
        gen, vis = u.get("macprovider_generated_completion_tokens"), u.get("completion_tokens")
        self.check("reasoning_final_extracted", "6:05" in c and f == "stop" and not leaks(self.family, c), content=c, finish_reason=f)
        self.check("reasoning_accounting", isinstance(gen, int) and isinstance(vis, int) and gen > vis > 0, usage=u)
        content, f2, u2, _, _ = self.ask_stream(msgs, max_tokens=1024)
        self.check("reasoning_stream_parity", content == c and u2.get("completion_tokens") == vis
                   and u2.get("macprovider_generated_completion_tokens") == gen, stream_content=content, usage=u2)

    def gpt_oss_tools(self):
        tools = [{"type": "function", "function": {
            "name": "get_weather", "description": "Get the current weather for a city",
            "parameters": {"type": "object", "properties": {"city": {"type": "string"}, "unit": {"type": "string", "enum": ["c", "f"]}},
                           "required": ["city"]}}}]
        msgs = [{"role": "user", "content": "What's the weather in Vilnius in celsius? Use the tool."}]
        _, m, f, u = self.ask(msgs, max_tokens=512, tools=tools)
        calls = m.get("tool_calls") or []
        args = {}
        if calls:
            try:
                args = json.loads(calls[0]["function"]["arguments"])
            except Exception as e:  # noqa: BLE001 - evidence only
                args = {"_parse_error": str(e), "_raw": calls[0]["function"]["arguments"]}
        content = m.get("content") or ""
        self.check("tool_call", f == "tool_calls" and len(calls) == 1 and calls[0]["function"]["name"] == "get_weather"
                   and str(args.get("city", "")).lower() == "vilnius" and not leaks(self.family, content),
                   finish_reason=f, tool_calls=calls, content=content, usage=u)
        s_content, f2, _, _, tdeltas = self.ask_stream(msgs, max_tokens=512, tools=tools)
        s_args = "".join((d.get("function") or {}).get("arguments") or "" for d in tdeltas)
        s_name = next(((d.get("function") or {}).get("name") for d in tdeltas if (d.get("function") or {}).get("name")), None)
        self.check("tool_call_stream_parity", f2 == "tool_calls" and s_name == "get_weather"
                   and calls and s_args == calls[0]["function"]["arguments"],
                   finish_reason=f2, tool_name=s_name, args=s_args)
        # Tool-history turn: ToolPromptRenderer has no Harmony profile, so the
        # current contract is a fail-closed 400 before inference runs.
        if calls:
            follow = msgs + [
                {"role": "assistant", "content": None, "tool_calls": calls},
                {"role": "tool", "tool_call_id": calls[0].get("id", "call_0"), "content": json.dumps({"temp_c": 7, "sky": "cloudy"})},
            ]
            try:
                self.ask(follow, max_tokens=512, tools=tools)
                self.check("tool_history_turn_fail_closed", False, status=200)
            except urllib.error.HTTPError as e:
                err = json.loads(e.read() or b"{}").get("error", {})
                self.check("tool_history_turn_fail_closed",
                           e.code == 400 and err.get("code") == "unsupported_modelID_for_multi_turn" and err.get("inference_ran") is False,
                           status=e.code, code=err.get("code"))

    def step(self, fn, *args):
        try:
            return fn(*args)
        except Exception as e:  # noqa: BLE001 - recorded as a failing check
            body = e.read().decode(errors="replace")[:300] if isinstance(e, urllib.error.HTTPError) else None
            self.check(f"{fn.__name__}_exception", False, error=repr(e), body=body)
            return None

    def run(self):
        ref = self.step(self.greedy_and_eos)
        if ref:
            self.step(self.stream_parity, *ref)
        self.step(self.max_tokens)
        self.step(self.stop_string)
        if self.family == "gpt_oss":
            self.step(self.gpt_oss_reasoning)
            self.step(self.gpt_oss_tools)
        return all(r["pass"] for r in self.results)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--family", choices=["gemma4", "gpt_oss"], required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    with urllib.request.urlopen(f"http://127.0.0.1:{a.port}/v1/models", timeout=30) as resp:
        models = json.loads(resp.read())
    model = models["data"][0]["id"]
    p = Probe(a.port, a.family, model)
    try:
        ok = p.run()
    except Exception as e:  # noqa: BLE001 - recorded as a failing check
        p.check("probe_exception", False, error=repr(e))
        ok = False
    with open(a.out, "w") as fh:
        json.dump({"model": model, "family": a.family, "pass": ok, "checks": p.results}, fh, indent=1)
    print("ROW", "PASS" if ok else "FAIL", model)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
