#!/usr/bin/env python3
"""
Focused re-run of just the 32K context test.
Same prompt-construction logic as long_context_test.py but only the 32K target.
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

from mlx_lm import load

MODEL_ID = "mlx-community/Llama-3.2-3B-Instruct-4bit"
SERVER_URL = "http://127.0.0.1:8090/v1/chat/completions"
RESULTS_DIR = "/Users/augstar/macprovider-poc/results/stress"
TARGET = 32000

FILLER_SENTENCES = [
    "The ant colony observed the unusual movement near the eastern boundary marker.",
    "Scouts returned with reports of an abandoned beetle carcass beside the river stones.",
    "Worker bees from a neighboring hive sometimes share pollen sources during dry seasons.",
    "The queen recorded each foraging route in her chemical memory for later retrieval.",
    "Soldiers patrolled the inner chambers throughout the night shift without incident.",
    "Younger ants learned trail-laying behavior from the experienced foragers they shadowed.",
    "Temperature gradients near the surface tunnels signaled approaching weather changes.",
    "Fungus gardens required precise humidity control maintained by specialized workers.",
    "The colony's defensive perimeter expanded gradually each summer as numbers grew.",
    "Aphid herding produced a steady honeydew supply during the dry midsummer weeks.",
    "Communication pheromones varied in volatility depending on the urgency of the message.",
    "Tunnel architecture evolved over generations to optimize airflow and traffic patterns.",
    "Some workers specialized in undertaking, removing fallen colony members to the midden.",
    "The boundary disputes with the rival colony rarely escalated beyond ritual posturing.",
    "Seed harvesting expeditions required coordination across multiple foraging columns.",
    "Repair crews mobilized within minutes of any structural damage to the main galleries.",
]


def build_prompt_to_token_count(tokenizer, target_tokens):
    filler_text = " ".join(FILLER_SENTENCES * 400)  # bigger pool for 32K
    user_query = "In exactly one short sentence, summarize the main theme of the system message above."

    def encode_messages(system_text):
        messages = [
            {"role": "system", "content": system_text},
            {"role": "user", "content": user_query},
        ]
        templated = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        return tokenizer.encode(templated, add_special_tokens=False), messages

    low, high = 0, len(filler_text)
    best_messages = None
    best_count = 0

    for trial_len in range(0, len(filler_text), max(1, len(filler_text) // 40)):
        ids, messages = encode_messages(filler_text[:trial_len])
        if len(ids) > target_tokens:
            high = trial_len
            break
        low = trial_len
        if len(ids) > best_count and len(ids) <= target_tokens:
            best_count = len(ids)
            best_messages = messages

    for _ in range(20):
        mid = (low + high) // 2
        ids, messages = encode_messages(filler_text[:mid])
        if len(ids) > target_tokens:
            high = mid
        else:
            low = mid
            if len(ids) > best_count:
                best_count = len(ids)
                best_messages = messages
        if high - low < 4:
            break

    return best_messages, best_count


def main():
    os.makedirs(RESULTS_DIR, exist_ok=True)

    print("Loading tokenizer...", file=sys.stderr)
    _, tokenizer = load(MODEL_ID)
    print("Tokenizer loaded.", file=sys.stderr)

    messages, ids_count = build_prompt_to_token_count(tokenizer, TARGET)
    print(f"Built prompt for target={TARGET}: tokenized length={ids_count}", file=sys.stderr)

    body = {
        "model": MODEL_ID,
        "messages": messages,
        "max_tokens": 20,
        "stream": False,
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        SERVER_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    print(f"Sending request — this may take several minutes on M1 8GB...", file=sys.stderr)
    start = time.time()
    record = {
        "target_tokens": TARGET,
        "client_estimate_tokens": ids_count,
        "request": {
            "system_chars": len(messages[0]["content"]),
            "user_chars": len(messages[1]["content"]),
        },
    }
    try:
        with urllib.request.urlopen(req, timeout=900) as resp:
            payload = resp.read().decode("utf-8")
        end = time.time()
        parsed = json.loads(payload)
        usage = parsed.get("usage", {})
        record["result"] = {
            "ok": True,
            "wall_seconds": end - start,
            "response": parsed,
        }
        tok_in = usage.get("prompt_tokens", "?")
        tok_out = usage.get("completion_tokens", "?")
        decode_seconds_est = (tok_out / 14.0) if isinstance(tok_out, int) else 0.5
        prefill_seconds_est = max(0.001, (end - start) - decode_seconds_est)
        prefill_rate = f"{tok_in / prefill_seconds_est:.1f}" if isinstance(tok_in, int) else "?"
        record["derived"] = {
            "prefill_seconds_est": prefill_seconds_est,
            "decode_seconds_est": decode_seconds_est,
            "prefill_tok_per_s_est": prefill_rate,
            "response_content": parsed["choices"][0]["message"]["content"][:200],
        }
        print(f"\nPASS — 32K context")
        print(f"  prompt_tokens (server): {tok_in}")
        print(f"  completion_tokens:      {tok_out}")
        print(f"  wall time:              {end - start:.2f}s")
        print(f"  prefill rate est:       {prefill_rate} tok/s")
        print(f"  response: {parsed['choices'][0]['message']['content'][:120]}")
    except urllib.error.HTTPError as e:
        end = time.time()
        body_text = e.read().decode("utf-8", errors="replace")[:1000]
        record["result"] = {
            "ok": False,
            "wall_seconds": end - start,
            "error": f"HTTPError {e.code}: {e.reason}",
            "body": body_text,
        }
        print(f"\nFAIL — 32K context")
        print(f"  HTTP {e.code}: {e.reason}")
        print(f"  body: {body_text[:300]}")
        print(f"  wall before fail: {end - start:.2f}s")
    except Exception as e:
        end = time.time()
        record["result"] = {
            "ok": False,
            "wall_seconds": end - start,
            "error": f"{type(e).__name__}: {e}",
        }
        print(f"\nFAIL — 32K context")
        print(f"  {type(e).__name__}: {e}")
        print(f"  wall before fail: {end - start:.2f}s")

    out_path = os.path.join(RESULTS_DIR, "7.5.3-longcontext-v2-32000.json")
    with open(out_path, "w") as f:
        json.dump(record, f, indent=2)
    print(f"\nResult written to {out_path}")


if __name__ == "__main__":
    main()
