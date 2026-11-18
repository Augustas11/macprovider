#!/usr/bin/env python3
"""Streaming OpenAI-compatible client for the parity grid (stdlib only).

usage: provider_client.py --port PORT --model MODEL --model-name NAME --out ours.jsonl
                          [--grid grid.json] [--trials 3] [--rows 1,4]
                          [--max-context N] [--no-stream-options] [--label provider]
                          [--turns 1|2] [--conversation-header] [--turn2-history content|verbatim]
                          [--trials-by-rows 4=1]

Sends the same chat messages as reference_mlxlm.py (prompts.build_messages) to
http://127.0.0.1:PORT/v1/chat/completions with stream=true, temperature=0.
A cell with N rows sends N requests at once (one thread each), row r using
prompt row r, so concurrent rows never share a prompt prefix.

Per trial it writes one "row" line per request and one "aggregate" line.
decode_tps = (completion_tokens - 1) / (t_last - t_first), where t_first and
t_last are the arrival times of the first and last generated delta (content or
reasoning_content: a model that streams its output as reasoning is timed the
same way) and completion_tokens is the usage frame's
macprovider_generated_completion_tokens when present, else completion_tokens.
`text` is content only; reasoning deltas are kept in `reasoning_text`.

--turns 2 adds, after each turn-1 trial, one turn-2 row per prompt row: the messages are
[user1 (the same long prompt), assistant1 (this provider's turn-1 text), user2 (prompts.FOLLOWUP)].
Turn-1 rows then carry turn=1, turn-2 rows turn=2 plus `assistant1` (the history the reference
replays, see prompts.load_assistant1) and cached_prompt_tokens; every row record (both turns, and
--turns 1 too) also gains `conversation_key_sent`. Turn-2 ttft_s times the turn-2
request only. Turn 2 has no aggregate line. --turns 1 writes the records it always did.
A turn-2 request goes out when turn 1 succeeded with any output; a reasoning-only turn 1 gives
assistant1 "" (content mode), which is what a client that drops reasoning sends.

--conversation-header sends `X-MacProvider-Provider-Conversation: <id>` on both turns of a
(trial, row) conversation, one random id per conversation: a direct-HTTP `serve --no-join`
keys its prefix cache only on that header. Every row record carries conversation_key_sent.
--turn2-history verbatim re-sends the turn-1 assistant message with reasoning_content (the
streamed reasoning text) next to content; content (default) sends content only. Turn-2 rows
record turn2_history.

request_tps = completion_tokens / (t_last - t0), t0 the request start: the
request-level output tok/s (TTFT and decode tok/s are its two parts). Each row
also records queue_ms (usage.macprovider_queue_ms) and its start and last-token
times relative to the trial's first request start (start_offset_s,
t_last_offset_s). The aggregate line holds aggregate_tps = total completion
tokens / (last token of the last row - first request start), the trial's
honest throughput whether its rows were batched or queued, and
decode_overlap_rows (1: the rows were served one after another).
"""
import argparse
import hashlib
import http.client
import json
import os
import statistics
import sys
import threading
import time
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import compare  # noqa: E402
import prompts  # noqa: E402


def iter_sse_data(lines):
    """Yield the payload of each `data:` field from an iterable of SSE byte/str lines.

    Stops after `[DONE]`. Comment lines (":") and other fields are ignored.
    """
    for raw in lines:
        line = raw.decode("utf-8") if isinstance(raw, bytes) else raw
        line = line.rstrip("\r\n")
        if not line.startswith("data:"):
            continue
        payload = line[5:].lstrip(" ")
        if payload == "[DONE]":
            return
        yield payload


def consume_stream(lines, clock=time.perf_counter):
    """Fold a chat.completion.chunk SSE stream into one result dict."""
    text = []
    reasoning = []
    t_first = t_last = None
    chunks = 0
    finish = None
    usage = None
    error = None
    for payload in iter_sse_data(lines):
        now = clock()
        try:
            obj = json.loads(payload)
        except ValueError:
            error = f"bad SSE json: {payload[:120]}"
            continue
        if "error" in obj:
            error = obj["error"]
            continue
        if obj.get("usage"):
            usage = obj["usage"]
        for choice in obj.get("choices") or []:
            delta = choice.get("delta") or {}
            piece = delta.get("content")
            thought = delta.get("reasoning_content")
            if piece or thought:
                if t_first is None:
                    t_first = now
                t_last = now
                chunks += 1
            if piece:
                text.append(piece)
            if thought:
                reasoning.append(thought)
            if choice.get("finish_reason"):
                finish = choice["finish_reason"]
    return {
        "text": "".join(text),
        "t_first": t_first,
        "t_last": t_last,
        "chunks": chunks,
        "finish": finish,
        "usage": usage,
        "reasoning_text": "".join(reasoning),
        "reasoning_chars": sum(len(x) for x in reasoning),
        "error": error,
    }


def completion_tokens_of(usage):
    if not usage:
        return None
    generated = usage.get("macprovider_generated_completion_tokens")
    return generated if generated is not None else usage.get("completion_tokens")


def run_request(port, model, messages, max_tokens, stream_options=True, timeout=1800, host="127.0.0.1",
                headers=None, extra=None):
    """`headers` adds request headers; `extra` adds request fields (reference_omlx.py: explicit
    neutral sampling knobs)."""
    body = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": 0,
        "stream": True,
        **(extra or {}),
    }
    if stream_options:
        body["stream_options"] = {"include_usage": True}
    t0 = time.perf_counter()
    conn = http.client.HTTPConnection(host, port, timeout=timeout)
    try:
        conn.request("POST", "/v1/chat/completions", body=json.dumps(body).encode(),
                     # The provider batches only requests that carry a stable id.
                     headers={"Content-Type": "application/json", "Accept": "text/event-stream",
                              "X-Request-ID": uuid.uuid4().hex, **(headers or {})})
        resp = conn.getresponse()
        if resp.status != 200:
            detail = resp.read(2000).decode("utf-8", "replace")
            return {"error": f"http {resp.status}: {detail}", "t0": t0, "t_end": time.perf_counter()}
        result = consume_stream(iter(resp.readline, b""))
    except (OSError, http.client.HTTPException) as exc:
        return {"error": f"{type(exc).__name__}: {exc}", "t0": t0, "t_end": time.perf_counter()}
    finally:
        conn.close()
    result["t0"] = t0
    result["t_end"] = time.perf_counter()
    return result


def row_record(res, base, first_chunk_tokens=1, cell_t0=None):
    """Turn a run_request result into a JSONL row record.

    decode_tps = (completion_tokens - first_chunk_tokens) / (t_last - t_first): the
    tokens that arrived after the first delta over the time they took. Our provider
    streams one token per delta (first_chunk_tokens = 1). With cell_t0 (the earliest
    request start of the trial) the record carries start_offset_s and t_last_offset_s,
    from which compare.py computes a multi-row trial's aggregate tok/s and overlap.
    """
    usage = res.get("usage") or {}
    ct = completion_tokens_of(usage)
    t_first, t_last, t0 = res.get("t_first"), res.get("t_last"), res["t0"]
    span = (t_last - t_first) if t_first is not None and t_last is not None else 0.0
    text = res.get("text", "")
    error = res.get("error")
    if error is None and not usage:
        error = "no usage frame (server may not honor stream_options)"
    offsets = {}
    if cell_t0 is not None:
        offsets = {"start_offset_s": round(t0 - cell_t0, 4),
                   "t_last_offset_s": round(t_last - cell_t0, 4) if t_last is not None else None}
    return {
        **base,
        **offsets,
        "queue_ms": usage.get("macprovider_queue_ms"),
        "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": ct,
        "generated_completion_tokens": usage.get("macprovider_generated_completion_tokens"),
        "cached_prompt_tokens": usage.get("cached_prompt_tokens"),
        "provider_generation_ms": usage.get("macprovider_generation_ms"),
        "decode_tps": (round((ct - first_chunk_tokens) / span, 3)
                       if ct and ct > first_chunk_tokens and span > 0 else None),
        "ttft_s": round(t_first - t0, 4) if t_first is not None else None,
        "request_tps": round(ct / (t_last - t0), 3) if ct and t_last is not None and t_last > t0 else None,
        "total_s": round(res["t_end"] - t0, 4),
        "chunks": res.get("chunks"),
        "finish": res.get("finish"),
        "reasoning_chars": res.get("reasoning_chars", 0),
        "reasoning_text": res.get("reasoning_text", ""),
        "usage": usage or None,
        "error": error,
        "text": text,
        "sha256": hashlib.sha256(text.encode()).hexdigest(),
        "_t_first": t_first,
        "_t_last": t_last,
    }


def aggregate_record(records, base):
    """One trial's summary line (compare.trial_metrics over its row records).

    aggregate_tps = total completion tokens / (last token of the last row - first request
    start); decode_span_tps = sum(ct - 1) / (max t_last - min t_first), the earlier
    aggregate, kept for reference; decode_overlap_rows = the most rows decoding at one
    instant (1: served one after another).
    """
    ok = [r for r in records if r["error"] is None and r["_t_first"] is not None and r["completion_tokens"]]
    per_row = [r["decode_tps"] for r in records]
    span_tps = None
    if len(ok) == len(records) and ok:
        span = max(r["_t_last"] for r in ok) - min(r["_t_first"] for r in ok)
        tokens = sum(r["completion_tokens"] - 1 for r in ok)
        span_tps = round(tokens / span, 3) if span > 0 else None
    valid = [x for x in per_row if x is not None]
    req = [r.get("request_tps") for r in records]
    timing = compare.trial_metrics(records)
    return {
        **base,
        "kind": "aggregate",
        "aggregate_tps": timing["aggregate_tps"],
        "wall_s": timing["wall_s"],
        "decode_span_tps": span_tps,
        "decode_overlap_rows": timing["decode_overlap_rows"],
        "serial_service": timing["serial_service"],
        "queue_s_max": timing["queue_s_max"],
        "queue_s_median": timing["queue_s_median"],
        "per_row_tps": per_row,
        "per_row_request_tps": req,
        "per_row_queue_ms": [r.get("queue_ms") for r in records],
        "per_row_min_tps": min(valid) if valid else None,
        "per_row_median_tps": round(statistics.median(valid), 3) if valid else None,
        "completion_tokens_sum": sum(r["completion_tokens"] or 0 for r in records),
        "errors": [r["error"] for r in records if r["error"]],
    }


CONVERSATION_HEADER = "X-MacProvider-Provider-Conversation"


def conversation_headers(conversation_ids, r):
    return {CONVERSATION_HEADER: conversation_ids[r]} if conversation_ids else None


def run_concurrent(port, model, builders, max_tokens, stream_options, conversation_ids=None):
    """One request per builder at once (one thread each); builders[r]() returns row r's messages or None.

    With conversation_ids row r sends the conversation header with conversation_ids[r]."""
    results = [None] * len(builders)
    barrier = threading.Barrier(len(builders))

    def worker(r):
        messages = builders[r]()
        barrier.wait()
        results[r] = (run_request(port, model, messages, max_tokens, stream_options,
                                  headers=conversation_headers(conversation_ids, r))
                      if messages is not None else None)

    threads = [threading.Thread(target=worker, args=(r,)) for r in range(len(builders))]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    return results


def run_turn2(port, model, model_name, ctx, max_tokens, rows, trial, stream_options, label, turn1_records,
              conversation_ids=None, history="content"):
    """Turn-2 rows for one trial: [user1, assistant1 = our turn-1 text, follow-up], sent after turn 1.

    Only the turn-2 request is timed. A row whose turn 1 failed or gave no output is recorded as an
    error. history "verbatim" adds the turn-1 reasoning as reasoning_content to assistant1.
    """
    texts = [(r.get("text") or "") if r["error"] is None and (r.get("text") or r.get("reasoning_text")) else None
             for r in turn1_records]
    reasoning = [(r.get("reasoning_text") or "") if history == "verbatim" else None for r in turn1_records]
    builders = [(lambda r=r: prompts.build_turn2_messages(ctx, r, texts[r], reasoning[r])
                 if texts[r] is not None else None)
                for r in range(rows)]
    results = run_concurrent(port, model, builders, max_tokens, stream_options, conversation_ids)
    base = {
        "side": "provider", "label": label, "model": model_name,
        "cell": prompts.cell_key(model_name, ctx, max_tokens, rows), "ctx_target": ctx,
        "max_tokens": max_tokens, "rows": rows, "trial": trial, "turn": 2,
        "conversation_key_sent": bool(conversation_ids), "turn2_history": history,
    }
    records = []
    for r, res in enumerate(results):
        if res is None:
            res = {"error": "turn 1 produced no output; no turn-2 request", "t0": 0.0, "t_end": 0.0}
        rec = row_record(res, {**base, "kind": "row", "row": r})
        rec["assistant1"] = texts[r]
        rec.pop("_t_first")
        rec.pop("_t_last")
        records.append(rec)
    return records


def run_cell(port, model, model_name, ctx, max_tokens, rows, trial, stream_options, label, turns=1,
             conversation_header=False, turn2_history="content"):
    # One id per (trial, row) conversation, shared by its turn 1 and turn 2.
    conversation_ids = ["conv:" + uuid.uuid4().hex for _ in range(rows)] if conversation_header else None
    results = run_concurrent(port, model, [(lambda r=r: prompts.build_messages(ctx, r)) for r in range(rows)],
                             max_tokens, stream_options, conversation_ids)
    base = {
        "side": "provider",
        "label": label,
        "model": model_name,
        "cell": prompts.cell_key(model_name, ctx, max_tokens, rows),
        "ctx_target": ctx,
        "max_tokens": max_tokens,
        "rows": rows,
        "trial": trial,
        **({"turn": 1} if turns == 2 else {}),
        "conversation_key_sent": conversation_header,
    }
    cell_t0 = min(res["t0"] for res in results)
    records = [row_record(res, {**base, "kind": "row", "row": r}, cell_t0=cell_t0) for r, res in enumerate(results)]
    agg = aggregate_record(records, base)
    for rec in records:
        rec.pop("_t_first")
        rec.pop("_t_last")
    if turns == 2:
        records += run_turn2(port, model, model_name, ctx, max_tokens, rows, trial, stream_options, label,
                             records[:rows], conversation_ids, turn2_history)
    return records, agg


def main(argv=None):
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--model", required=True, help="value sent as the request `model` field")
    ap.add_argument("--model-name", required=True, help="grid model name; must match the reference")
    ap.add_argument("--out", required=True)
    ap.add_argument("--grid", default=os.path.join(here, "grid.json"))
    ap.add_argument("--trials", type=int)
    ap.add_argument("--rows", help="comma list overriding grid rows, e.g. 1,4")
    ap.add_argument("--max-context", type=int)
    ap.add_argument("--no-stream-options", action="store_true")
    ap.add_argument("--label", default="provider")
    ap.add_argument("--turns", type=int, choices=(1, 2), default=1,
                    help="2: after each turn-1 trial send turn 2 (turn-1 text as assistant history + a "
                         "short follow-up) and record it with turn=2 (TTFT, cached_prompt_tokens)")
    ap.add_argument("--conversation-header", action="store_true",
                    help=f"send {CONVERSATION_HEADER} (one id per trial and row) on every turn")
    ap.add_argument("--turn2-history", choices=("content", "verbatim"), default="content",
                    help="verbatim: the turn-2 assistant message also carries the turn-1 reasoning_content")
    ap.add_argument("--trials-by-rows", default="",
                    help="comma list ROWS=TRIALS overriding --trials for cells of that row count, e.g. 4=1")
    args = ap.parse_args(argv)

    grid = prompts.load_grid(args.grid)
    if args.rows:
        grid["rows"] = [int(x) for x in args.rows.split(",")]
    trials = args.trials or grid.get("trials", 3)
    trials_by_rows = {int(k): int(v) for k, v in (x.split("=") for x in args.trials_by_rows.split(",") if x)}
    stream_options = not args.no_stream_options

    warm = run_request(args.port, args.model, prompts.build_messages(200, 9999),
                       grid.get("warmup_tokens", 32), stream_options)
    if warm.get("error"):
        print(f"warmup failed: {warm['error']}", file=sys.stderr)
        return 2

    failures = 0
    with open(args.out, "a") as out:
        for ctx, max_tokens, rows in prompts.expand_cells(grid, args.max_context):
            for trial in range(trials_by_rows.get(rows, trials)):
                records, agg = run_cell(args.port, args.model, args.model_name, ctx, max_tokens,
                                        rows, trial, stream_options, args.label, args.turns,
                                        args.conversation_header, args.turn2_history)
                for rec in records + [agg]:
                    out.write(json.dumps(rec) + "\n")
                out.flush()
                failures += len(agg["errors"]) + sum(1 for r in records if r.get("turn") == 2 and r["error"])
                print(f"ours ctx={ctx} out={max_tokens} rows={rows} trial={trial} "
                      f"agg={agg['aggregate_tps']} overlap={agg['decode_overlap_rows']} queue_max_s={agg['queue_s_max']} "
                      f"per_row={agg['per_row_tps']} errors={agg['errors']}",
                      file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
