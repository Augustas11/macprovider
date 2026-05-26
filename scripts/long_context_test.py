#!/usr/bin/env python3
"""
Tokenizer-accurate long-context test for mlx_lm.server.

Replaces the bogus filler-multiplication approach from Step 7.5.3 with prompts
constructed to exact target token counts using the actual model's tokenizer.

Outputs JSON per target size to results/stress/7.5.3-longcontext-v2-<size>.json
plus a human summary on stdout.
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
TARGETS = [8000, 16000, 32000]  # tokens

# Realistic filler — actual sentences, not repeated phrase, to mimic real
# system-prompt content. About 12 tokens per sentence with Llama tokenizer.
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


def build_prompt_to_token_count(tokenizer, target_tokens, system_role=True):
    """
    Build a chat message whose total tokenized prompt length equals approximately
    target_tokens after the chat template is applied.

    We construct a long system message, then trim/extend it iteratively until
    the tokenized total lands within +/- 50 of the target.
    """
    filler_text = " ".join(FILLER_SENTENCES * 200)  # ~30k tokens worst case
    user_query = "In exactly one short sentence, summarize the main theme of the system message above."

    def encode_messages(system_text):
        messages = [
            {"role": "system", "content": system_text},
            {"role": "user", "content": user_query},
        ]
        # Use the same template the server uses for chat completions
        templated = tokenizer.apply_chat_template(
            messages, tokenize=False, add_generation_prompt=True
        )
        return tokenizer.encode(templated, add_special_tokens=False), messages

    # Binary search on filler length (in characters)
    low, high = 0, len(filler_text)
    best_messages = None
    best_count = 0
    best_text_len = 0

    # First pass: linear walk to find approximate slice
    for trial_len in range(0, len(filler_text), max(1, len(filler_text) // 40)):
        ids, messages = encode_messages(filler_text[:trial_len])
        if len(ids) > target_tokens:
            high = trial_len
            break
        low = trial_len
        if len(ids) > best_count and len(ids) <= target_tokens:
            best_count = len(ids)
            best_messages = messages
            best_text_len = trial_len

    # Second pass: narrow within [low, high]
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
                best_text_len = mid
        if high - low < 4:
            break

    return best_messages, best_count


def post_chat(messages, max_tokens=20):
    body = {
        "model": MODEL_ID,
        "messages": messages,
        "max_tokens": max_tokens,
        "stream": False,
    }
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(
        SERVER_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=600) as resp:
            payload = resp.read().decode("utf-8")
        end = time.time()
        parsed = json.loads(payload)
        return {
            "ok": True,
            "wall_seconds": end - start,
            "response": parsed,
        }
    except urllib.error.HTTPError as e:
        end = time.time()
        return {
            "ok": False,
            "wall_seconds": end - start,
            "error": f"HTTPError {e.code}: {e.reason}",
            "body": e.read().decode("utf-8", errors="replace")[:500],
        }
    except Exception as e:
        end = time.time()
        return {
            "ok": False,
            "wall_seconds": end - start,
            "error": f"{type(e).__name__}: {e}",
        }


def main():
    os.makedirs(RESULTS_DIR, exist_ok=True)

    print("Loading tokenizer...", file=sys.stderr)
    _, tokenizer = load(MODEL_ID)
    print("Tokenizer loaded.", file=sys.stderr)

    print()
    print(f"{'target':>8} {'actual_in':>12} {'wall_s':>10} {'tok_in':>10} {'tok_out':>10} {'tok/s_prefill':>16} {'status':>10}")
    print("-" * 90)

    summary = []
    for target in TARGETS:
        messages, ids_count = build_prompt_to_token_count(tokenizer, target)
        print(f"Built prompt for target={target}: tokenized length={ids_count}", file=sys.stderr)

        result = post_chat(messages, max_tokens=20)

        record = {
            "target_tokens": target,
            "client_estimate_tokens": ids_count,
            "request": {
                "system_chars": len(messages[0]["content"]),
                "user_chars": len(messages[1]["content"]),
            },
            "result": result,
        }

        status = "OK"
        actual_in = "?"
        tok_in = "?"
        tok_out = "?"
        prefill_tok_per_s = "?"

        if result["ok"]:
            usage = result["response"].get("usage", {})
            tok_in = usage.get("prompt_tokens", "?")
            tok_out = usage.get("completion_tokens", "?")
            actual_in = tok_in
            # Rough prefill rate: total wall time minus a tiny generation cost,
            # divided into prompt tokens. We don't have prefill_seconds separately,
            # so approximate: subtract estimated decode time at ~14 tok/s sustained.
            decode_seconds_est = (tok_out / 14.0) if isinstance(tok_out, int) else 0.5
            prefill_seconds_est = max(0.001, result["wall_seconds"] - decode_seconds_est)
            if isinstance(tok_in, int):
                prefill_tok_per_s = f"{tok_in / prefill_seconds_est:.1f}"
            record["derived"] = {
                "prefill_seconds_est": prefill_seconds_est,
                "decode_seconds_est": decode_seconds_est,
                "prefill_tok_per_s_est": prefill_tok_per_s,
                "response_content": result["response"]["choices"][0]["message"]["content"][:120],
            }
        else:
            status = "FAIL"
            record["status"] = status

        wall = f"{result['wall_seconds']:.2f}"
        print(f"{target:>8} {str(actual_in):>12} {wall:>10} {str(tok_in):>10} {str(tok_out):>10} {str(prefill_tok_per_s):>16} {status:>10}")

        out_path = os.path.join(RESULTS_DIR, f"7.5.3-longcontext-v2-{target}.json")
        with open(out_path, "w") as f:
            json.dump(record, f, indent=2)

        summary.append({
            "target": target,
            "actual_in": actual_in,
            "wall_s": result["wall_seconds"],
            "tok_in": tok_in,
            "tok_out": tok_out,
            "prefill_tok_per_s_est": prefill_tok_per_s,
            "ok": result["ok"],
        })

        # If we fail at this size, no point pushing harder
        if not result["ok"]:
            print(f"\nStopping early — failed at target={target}", file=sys.stderr)
            break

    summary_path = os.path.join(RESULTS_DIR, "7.5.3-longcontext-v2-summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)

    print()
    print(f"Summary written to {summary_path}")


if __name__ == "__main__":
    main()
