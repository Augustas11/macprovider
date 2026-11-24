"""Paired coding-quality check on the fixed nine-case workload
(scripts/revenue_benchmark/coding_agent_workload_v1.json, canonical SHA-256 pinned by
scripts/revenue_benchmark_workload.py) for catalog intake windows (#2465, #2466).

How it was run before (#2154 / PR 2173, LFM2.5 and Qwen3.8-27B intake): the workload planner,
not the revenue calculator, renders the isolated requests; one pass of all nine cases per
model, unchanged budgets, temperature 0, non-streaming, against an isolated lab serve; every
failure retained. No rubric was committed then, so this one (quality_rubric_v1.json) is frozen
before inference of either model.

  quality.py serve --port P --model ID --label L --run-id R --out raw.jsonl
      POSTs each planned request to http://127.0.0.1:P/v1/chat/completions (a loopback
      `serve --no-join`; no effort field, so the served template renders thinking off, the
      buyer default, SPEC-018-R010).
  quality.py reference --model-dir D --loader mlx-lm|mlx-vlm [--omlx-vendor] --label L --run-id R --out raw.jsonl
      The same requests through the reference package (run under its venv): the model's own
      chat template with enable_thinking=False, greedy, stop on an EOS id, the case budget.
      Used only when the lab serve cannot load the candidate; the verdict names the path, and
      both models of a pair always run the same path.
  quality.py score --raw raw.jsonl --rubric quality_rubric_v1.json --out score.json
      Applies the rubric; prints `QUALITY label=<L> passed=<n>/<cases> ...` and one
      `QUALITY_CASE` line per case.
"""
import argparse
import importlib.util
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parents[2]


def workload_module():
    spec = importlib.util.spec_from_file_location("revenue_benchmark_workload", SCRIPTS / "revenue_benchmark_workload.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def planned(run_id, label, model):
    wl = workload_module()
    doc = wl.load(1)
    return wl.identity(doc), wl.plan(doc, run_id, [{"candidate_id": label, "model": model}])


def split_reasoning(text):
    if "</think>" in text:
        head, _, tail = text.rpartition("</think>")
        return tail.strip(), head.replace("<think>", "", 1).strip()
    return text.strip(), ""


def cmd_serve(a):
    ident, rows = planned(a.run_id, a.label, a.model)
    with open(a.out, "w") as out:
        out.write(json.dumps({"kind": "meta", "path": "serve", "label": a.label, "model": a.model, "workload": ident}) + "\n")
        failed = 0
        for r in rows:
            req = urllib.request.Request(f"http://127.0.0.1:{a.port}{r['path']}", data=json.dumps(r["body"]).encode(),
                                         headers={"Content-Type": "application/json", **r["headers"]}, method="POST")
            rec = {"kind": "case", "case_id": r["case_id"], "request_id": r["request_id"], "max_tokens": r["body"]["max_tokens"]}
            t0 = time.time()
            try:
                with urllib.request.urlopen(req, timeout=a.timeout) as resp:
                    doc = json.loads(resp.read())
                ch = doc["choices"][0]
                msg = ch.get("message") or {}
                content, inline = split_reasoning(msg.get("content") or "")
                rec.update(status=200, finish_reason=ch.get("finish_reason"), content=content,
                           reasoning=(msg.get("reasoning_content") or inline), usage=doc.get("usage"))
            except urllib.error.HTTPError as e:
                rec.update(status=e.code, error=e.read().decode(errors="replace")[:2000]); failed += 1
            except Exception as e:  # a transport failure is a retained failed case, not a crash
                rec.update(status=None, error=repr(e)[:2000]); failed += 1
            rec["latency_s"] = round(time.time() - t0, 3)
            out.write(json.dumps(rec) + "\n"); out.flush()
            print(f"QUALITY_REQ {a.label} {r['case_id']} status={rec.get('status')} finish={rec.get('finish_reason')} "
                  f"completion_tokens={(rec.get('usage') or {}).get('completion_tokens')} latency_s={rec['latency_s']}", flush=True)
    return 1 if failed else 0


def eos_ids(model_dir, tokenizer):
    ids = set()
    e = getattr(tokenizer, "eos_token_id", None)
    if isinstance(e, int):
        ids.add(e)
    for extra in getattr(tokenizer, "eos_token_ids", None) or []:
        ids.add(int(extra))
    gc = os.path.join(model_dir, "generation_config.json")
    if os.path.exists(gc):
        v = json.load(open(gc)).get("eos_token_id")
        ids.update([v] if isinstance(v, int) else (v or []))
    return ids


def cmd_reference(a):
    import importlib.metadata as md
    import mlx.core as mx
    if a.loader == "mlx-lm":
        from mlx_lm import load
        from mlx_lm.models.cache import make_prompt_cache
        model, tokenizer = load(a.model_dir)
        forward = lambda ids, cache: model(ids, cache=cache)
        new_cache = lambda: make_prompt_cache(model)
        pkg = "mlx-lm"
    else:
        if a.omlx_vendor:
            # As glm53_bench_vlm.py --omlx-vendor: the oMLX glm5_next layout patch for mlx-vlm.
            from omlx.patches.mlx_vlm_glm5_next_compat import apply_mlx_vlm_glm5_next_compat_patch
            assert apply_mlx_vlm_glm5_next_compat_patch(), "oMLX glm5_next compat patch did not apply"
        from mlx_vlm import load
        model, processor = load(a.model_dir)
        tokenizer = getattr(processor, "tokenizer", processor)
        lm = model.language_model
        forward = lambda ids, cache: lm(inputs=ids, cache=cache).logits
        new_cache = lm.make_cache
        pkg = "mlx-vlm"
    stops = eos_ids(a.model_dir, tokenizer)
    ident, rows = planned(a.run_id, a.label, a.model_dir)
    with open(a.out, "w") as out:
        out.write(json.dumps({"kind": "meta", "path": "reference", "loader": a.loader, "label": a.label,
                              "model_dir": a.model_dir, "workload": ident, "eos_ids": sorted(stops),
                              "versions": {p: md.version(p) for p in ("mlx", pkg)}}) + "\n")
        for r in rows:
            prompt = tokenizer.apply_chat_template(r["body"]["messages"], add_generation_prompt=True, tokenize=False,
                                                   enable_thinking=False)
            ids = tokenizer.encode(prompt, add_special_tokens=False)
            t0 = time.time()
            cache = new_cache()
            logits = None
            for s in range(0, len(ids), 2048):
                logits = forward(mx.array([ids[s:s + 2048]]), cache)[:, -1, :]
                mx.eval(logits)
            toks, finish = [], "length"
            for _ in range(r["body"]["max_tokens"]):
                t = int(mx.argmax(logits, axis=-1).item())
                if t in stops:
                    finish = "stop"
                    break
                toks.append(t)
                logits = forward(mx.array([[t]]), cache)[:, -1, :]
            content, reasoning = split_reasoning(tokenizer.decode(toks))
            rec = {"kind": "case", "case_id": r["case_id"], "request_id": r["request_id"], "max_tokens": r["body"]["max_tokens"],
                   "status": 200, "finish_reason": finish, "content": content, "reasoning": reasoning,
                   "usage": {"prompt_tokens": len(ids), "completion_tokens": len(toks) + (finish == "stop")},
                   "latency_s": round(time.time() - t0, 3)}
            out.write(json.dumps(rec) + "\n"); out.flush()
            print(f"QUALITY_REQ {a.label} {r['case_id']} status=200 finish={finish} completion_tokens={rec['usage']['completion_tokens']} "
                  f"latency_s={rec['latency_s']}", flush=True)
    return 0


def cmd_score(a):
    rubric = json.load(open(a.rubric))
    recs = [json.loads(l) for l in open(a.raw) if l.strip()]
    meta = next((r for r in recs if r.get("kind") == "meta"), {})
    cases = {r["case_id"]: r for r in recs if r.get("kind") == "case"}
    flags = re.IGNORECASE | re.MULTILINE
    results, passed = [], 0
    for cid, rule in rubric["cases"].items():
        r = cases.get(cid)
        reasons = []
        if r is None:
            reasons.append("no_record")
        else:
            if r.get("status") != 200:
                reasons.append(f"status_{r.get('status')}")
            if r.get("finish_reason") != "stop":
                reasons.append(f"finish_{r.get('finish_reason')}")
            text = r.get("content") or ""
            if not text:
                reasons.append("empty_answer")
            reasons += [f"missing:{p[:40]}" for p in rule.get("all", []) if text and not re.search(p, text, flags)]
            reasons += [f"count<{n}:{p[:30]}" for p, n in rule.get("min_count", {}).items()
                        if text and len(re.findall(p, text, flags)) < n]
        ok = not reasons
        passed += ok
        results.append({"case_id": cid, "pass": ok, "reasons": reasons,
                        "completion_tokens": ((r or {}).get("usage") or {}).get("completion_tokens")})
        print(f"QUALITY_CASE {meta.get('label')} {cid} pass={ok} {' '.join(reasons)}".rstrip(), flush=True)
    doc = {"label": meta.get("label"), "path": meta.get("path"), "passed": passed, "cases": len(rubric["cases"]),
           "workload": meta.get("workload"), "rubric": rubric["schema"], "results": results}
    json.dump(doc, open(a.out, "w"), indent=2)
    print(f"QUALITY label={meta.get('label')} path={meta.get('path')} passed={passed}/{len(rubric['cases'])}", flush=True)
    return 0


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--model", required=True)
    s.add_argument("--timeout", type=float, default=1800)
    r = sub.add_parser("reference")
    r.add_argument("--model-dir", required=True)
    r.add_argument("--loader", choices=("mlx-lm", "mlx-vlm"), required=True)
    r.add_argument("--omlx-vendor", action="store_true")
    for p in (s, r):
        p.add_argument("--label", required=True)
        p.add_argument("--run-id", required=True)
        p.add_argument("--out", required=True)
    c = sub.add_parser("score")
    c.add_argument("--raw", required=True)
    c.add_argument("--rubric", required=True)
    c.add_argument("--out", required=True)
    a = ap.parse_args()
    sys.exit({"serve": cmd_serve, "reference": cmd_reference, "score": cmd_score}[a.cmd](a))


if __name__ == "__main__":
    main()
