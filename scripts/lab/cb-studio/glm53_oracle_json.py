"""Convert a T2 parity oracle (.npz from glm53_bench_vlm.py) to the JSON that
`macprovider-cli glm-parity --oracle` reads. A DeepSeek V4 oracle
(`scripts/lab/dsv4/dsv4_reference_bench.py`) stores `top_logprob` instead of
`top_logit`; it lands in the same `top_logit` field for `dsv4-parity`.

Usage: python glm53_oracle_json.py <oracle.npz> [<out.json>]
Default output: the input path with a .json suffix. Needs numpy only.
"""

import hashlib
import json
import sys
from pathlib import Path

import numpy as np

KEYS = {"prompt", "greedy", "top_idx"}


def main():
    if len(sys.argv) not in (2, 3):
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    out = Path(sys.argv[2]) if len(sys.argv) == 3 else src.with_suffix(".json")
    data = np.load(src, allow_pickle=False)
    missing = KEYS - set(data.files)
    logit_key = "top_logit" if "top_logit" in data.files else "top_logprob"
    if logit_key not in data.files:
        missing.add("top_logit")
    if missing:
        sys.exit(f"{src}: missing arrays {sorted(missing)}")
    prompt, greedy = data["prompt"], data["greedy"]
    top_idx, top_logit = data["top_idx"], data[logit_key]
    if prompt.ndim != 1 or greedy.ndim != 1 or top_idx.ndim != 2 or top_idx.shape != top_logit.shape:
        sys.exit(f"{src}: unexpected shapes {prompt.shape} {greedy.shape} {top_idx.shape} {top_logit.shape}")
    if top_idx.shape[0] > greedy.shape[0]:
        sys.exit(f"{src}: more logit steps ({top_idx.shape[0]}) than greedy tokens ({greedy.shape[0]})")
    doc = {
        "schema": "glm-parity-oracle-v1",
        "source": src.name,
        "source_sha256": hashlib.sha256(src.read_bytes()).hexdigest(),
        "prompt": [int(x) for x in prompt],
        "greedy": [int(x) for x in greedy],
        "top_idx": [[int(x) for x in row] for row in top_idx],
        # float32 values widen to float64 exactly, so they round-trip.
        "top_logit": [[float(x) for x in row] for row in top_logit.astype(np.float32)],
    }
    out.write_text(json.dumps(doc, separators=(",", ":")))
    print(f"{out} prompt={len(doc['prompt'])} greedy={len(doc['greedy'])} logit_steps={len(doc['top_idx'])}")


if __name__ == "__main__":
    main()
