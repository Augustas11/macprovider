#!/usr/bin/env python3
"""Frozen natural-prompt requests for the DeepSeek V4 DSpark measurement (#2111).

  python3 -I scripts/lab/dsv4/make_dspark_requests.py <encoding-dir> <tokenizer.json> <out.json>

Twelve OpenAI request bodies in three strata (prose, reasoning, code; four
each). Each is rendered with the model's own `encoding_dsv4.py` under the
provider's request mapping (`make_encoding_fixtures.reference_messages`) and
tokenized with the pinned `tokenizer.json`. The Swift test
`DeepseekV4DSparkRequestsTests` checks that the provider's production path
(`ChatCompletionRequest.parse`, `ModelRuntime.userInput`, the DSV4 renderer and
tokenizer) yields the same prompt and ids. The bench feeds these ids.

Prose and code use `reasoning_effort: "none"` (chat mode), so the measured
tokens are answer text and code. Reasoning uses `"high"` (thinking mode), so
they are reasoning text. The code prompts are four of the 2026-10-22 coding
bake-off prompts.
"""
import hashlib
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from make_encoding_fixtures import REFERENCE_SHA256, reference_messages  # noqa: E402

TOKENIZER_SHA256 = "8f9f37ca37fdc4f5fd36d5cf4d3b0e8392edb4e894fd10cc0d70b4957c8633cf"
MODEL = "deepseek/deepseek-v4-flash"

PROSE = [
    "Write a short story of about 800 words about a lighthouse keeper who discovers that the lamp has started "
    "signalling back to a ship that does not exist. Use plain, concrete prose and include some dialogue.",
    "Write an essay of about 700 words explaining why medieval European towns built their walls where they did, "
    "covering water supply, trade routes, terrain and the cost of labour. Use flowing paragraphs, no lists.",
    "Write a long letter, about 800 words, from a nineteenth-century botanist to her brother describing the first "
    "week of an expedition up a tropical river: the boat, the crew, the weather and the plants she collects.",
    "Write a detailed review, about 700 words, of a fictional mid-range road bicycle called the Corvo Strada 2. "
    "Cover ride comfort, gearing, brakes, weight and value for money, as continuous prose.",
]
REASONING = [
    "A bag holds 4 red, 5 blue and 6 green marbles. Three are drawn without replacement. What is the probability "
    "that all three are different colours? Show your reasoning.",
    "Three friends split a restaurant bill. Ana paid twice what Ben paid, and Ben paid 12 euros more than Cleo. "
    "Together they paid 132 euros. How much did each pay? Explain step by step.",
    "Find all pairs of positive integers (x, y) with x > y and x^2 - y^2 = 2025. Explain how you know the list "
    "is complete.",
    "A train leaves city A at 08:00 at 90 km/h toward city B, 360 km away. A second train leaves B at 08:30 toward "
    "A at 120 km/h. At what time, and how far from A, do they meet? Check the answer.",
]
CODE = [
    "Write a Python function that parses an ISO-8601 duration string such as P3DT4H12M into total seconds. Handle "
    "invalid input with a clear error, then write five pytest cases.",
    "Implement an LRU cache class in TypeScript with get, set and a max size. Explain the time complexity of each "
    "operation and add unit tests with vitest.",
    "Write a SQL query that returns, for each customer, their three most recent orders with the order total, using "
    "window functions. Then explain how an index would speed it up.",
    "Write a Rust command-line tool that counts word frequencies in a text file and prints the top 20 words. Use "
    "idiomatic error handling and explain each part.",
]
STRATA = (("prose", "none", PROSE), ("reasoning", "high", REASONING), ("code", "none", CODE))


def main(argv):
    if len(argv) != 4:
        sys.exit(__doc__)
    encoding_dir, tokenizer_path, out = (pathlib.Path(a) for a in argv[1:])
    source = encoding_dir / "encoding_dsv4.py"
    if hashlib.sha256(source.read_bytes()).hexdigest() != REFERENCE_SHA256:
        sys.exit(f"{source} is not the pinned reference")
    if hashlib.sha256(tokenizer_path.read_bytes()).hexdigest() != TOKENIZER_SHA256:
        sys.exit(f"{tokenizer_path} is not the pinned DeepSeek V4 tokenizer")
    sys.path.insert(0, str(encoding_dir))
    import encoding_dsv4 as enc  # noqa: E402
    from tokenizers import Tokenizer

    tokenizer = Tokenizer.from_file(str(tokenizer_path))
    requests = []
    for stratum, effort, prompts in STRATA:
        for i, text in enumerate(prompts):
            body = {"model": MODEL, "reasoning_effort": effort, "messages": [{"role": "user", "content": text}]}
            messages, mode, level = reference_messages(json.loads(json.dumps(body)))
            prompt = enc.encode_messages(messages, thinking_mode=mode, reasoning_effort=level)
            ids = tokenizer.encode(prompt, add_special_tokens=False).ids
            requests.append({
                "name": f"{stratum}-{i}", "stratum": stratum, "request": body, "prompt": prompt, "ids": ids,
                "ids_sha256": hashlib.sha256(json.dumps(ids).encode()).hexdigest(),
            })
    doc = {
        "schema": "macprovider.dsv4-dspark-requests.v1",
        "reference_sha256": REFERENCE_SHA256,
        "tokenizer_sha256": TOKENIZER_SHA256,
        "requests": requests,
    }
    out.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{out}: {len(requests)} requests, prompt tokens {[len(r['ids']) for r in requests]}")


if __name__ == "__main__":
    main(sys.argv)
