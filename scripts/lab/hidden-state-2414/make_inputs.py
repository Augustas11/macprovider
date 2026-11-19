"""Build the fixed token-id inputs for the cross-chip hidden-state experiment (#2414).

Tokenizes three source files of this repository (prose, Swift, Go) with the
experiment model's tokenizer and keeps the first --length ids of each (a BOS
id first). The ids, the sampled positions and the pinned model revisions are
written to inputs.json, which is committed: the runs read token ids, never
text, so tokenizer versions on the two Macs do not matter.

Usage:
  python -I make_inputs.py --tokenizer <dir with tokenizer.json> --out inputs.json
"""

import argparse
import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]

SOURCES = [
    ("prose", "specs/SPEC-051-multi-mac-shard-groups.md"),
    ("swift", "phase3-binary/Sources/MacProviderCore/ShardLogitParity.swift"),
    ("go", "phase5-gateway/internal/router/chat_proxy.go"),
]

# One model, three quantizations of the same weights. Revisions are pinned so
# both Macs hold the same snapshot; dump.py records the weight hashes and
# compare.py refuses runs whose hashes differ for the same variant.
MODELS = {
    "4bit": {"repo": "mlx-community/Llama-3.2-3B-Instruct-4bit",
             "revision": "7f0dc925e0d0afb0322d96f9255cfddf2ba5636e"},
    "8bit": {"repo": "mlx-community/Llama-3.2-3B-Instruct-8bit",
             "revision": "ff054899609078569493def2823f9acd2780c0c9"},
    "bf16": {"repo": "mlx-community/Llama-3.2-3B-Instruct-bf16",
             "revision": "6d88ba43024fef71b10e52e101c7cd4598322601"},
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tokenizer", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--length", type=int, default=512)
    ap.add_argument("--positions", type=int, default=32)
    ap.add_argument("--full-layers", default="3,11,19",
                    help="layers whose output is saved at every position (injection sources)")
    args = ap.parse_args()

    from transformers import AutoTokenizer

    tok = AutoTokenizer.from_pretrained(args.tokenizer)
    sequences = []
    for name, rel in SOURCES:
        text = (REPO / rel).read_text()
        ids = tok.encode(text, add_special_tokens=True)
        if len(ids) < args.length:
            raise SystemExit(f"{rel}: only {len(ids)} tokens, need {args.length}")
        ids = [int(t) for t in ids[: args.length]]
        sequences.append({
            "name": name,
            "source": rel,
            "source_sha256": hashlib.sha256(text.encode()).hexdigest(),
            "ids": ids,
        })

    n = args.length
    step = (n - 1) / (args.positions - 1)
    positions = sorted({round(i * step) for i in range(args.positions)})
    if len(positions) != args.positions:
        raise SystemExit("positions collided; choose a smaller --positions")

    out = {
        "schema": "hidden-state-2414-inputs-v1",
        "length": n,
        "positions": positions,
        "full_layers": [int(x) for x in args.full_layers.split(",")],
        "models": MODELS,
        "sequences": sequences,
    }
    Path(args.out).write_text(json.dumps(out, indent=1) + "\n")
    print(f"make_inputs: {len(sequences)} sequences x {n} tokens, {len(positions)} positions -> {args.out}")


if __name__ == "__main__":
    main()
