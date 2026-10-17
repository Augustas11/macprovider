"""Write a GLM-5-Next artifact cut to its first N decoder layers, for load-memory
measurements without the full 186 GB model.

Usage: python glm53_truncate_artifact.py <model_dir> <out_dir> <layers>

Keeps every tensor outside `model.layers.<i>` for i >= N (embeddings, head,
final norm, the MTP block, vision tensors) with their real shapes and
quantization, and rewrites the per-layer config lists to N entries. Tensor
bytes are copied by range, so memory use stays flat. Tokenizer and template
files are symlinked.
"""

import json
import os
import re
import struct
import sys
from pathlib import Path

LAYER = re.compile(r"(?:^|\.)model\.layers\.(\d+)\.")
PER_LAYER_LISTS = ("layer_types", "mlp_layer_types", "indexer_types")
CHUNK = 64 << 20


def keep(name, layers):
    m = LAYER.search(name)
    return m is None or int(m.group(1)) < layers


def truncate_config(config, layers):
    text = config.get("text_config", config)
    original = text["num_hidden_layers"]
    text["num_hidden_layers"] = layers
    for key in PER_LAYER_LISTS:
        if isinstance(text.get(key), list):
            text[key] = text[key][:layers]
    if isinstance(text.get("index_topk_pattern"), (str, list)):
        text["index_topk_pattern"] = text["index_topk_pattern"][:layers]
    linear = text.get("linear_attn_config") or {}
    for key in ("kda_layers", "full_attn_layers"):
        if isinstance(linear.get(key), list):
            # 0-based, as GLM5NextConfiguration reads them.
            linear[key] = [i for i in linear[key] if i < layers]
    return original


def copy_shard(src, dst, layers):
    with open(src, "rb") as f:
        (header_len,) = struct.unpack("<Q", f.read(8))
        header = json.loads(f.read(header_len))
        base = 8 + header_len
        meta = header.pop("__metadata__", None)
        names = sorted((n for n in header if keep(n, layers)), key=lambda n: header[n]["data_offsets"][0])
        if not names:
            return 0
        out_header, offset = {}, 0
        for n in names:
            start, end = header[n]["data_offsets"]
            out_header[n] = {**header[n], "data_offsets": [offset, offset + end - start]}
            offset += end - start
        if meta is not None:
            out_header["__metadata__"] = meta
        encoded = json.dumps(out_header, separators=(",", ":")).encode()
        encoded += b" " * (-len(encoded) % 8)
        with open(dst, "wb") as out:
            out.write(struct.pack("<Q", len(encoded)))
            out.write(encoded)
            for n in names:
                start, end = header[n]["data_offsets"]
                f.seek(base + start)
                remaining = end - start
                while remaining:
                    block = f.read(min(CHUNK, remaining))
                    out.write(block)
                    remaining -= len(block)
        return offset


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    src, out, layers = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
    out.mkdir(parents=True, exist_ok=False)
    config = json.loads((src / "config.json").read_text())
    original = truncate_config(config, layers)
    (out / "config.json").write_text(json.dumps(config, indent=2))
    index = json.loads((src / "model.safetensors.index.json").read_text())
    weight_map = {n: f for n, f in index["weight_map"].items() if keep(n, layers)}
    total = 0
    for shard in sorted(set(weight_map.values())):
        total += copy_shard(src / shard, out / shard, layers)
    (out / "model.safetensors.index.json").write_text(
        json.dumps({"metadata": {"total_size": total}, "weight_map": weight_map}, indent=2)
    )
    for p in src.iterdir():
        if p.suffix != ".safetensors" and p.name not in ("config.json", "model.safetensors.index.json"):
            os.symlink(p, out / p.name)
    print(json.dumps({"layers": layers, "of": original, "tensors": len(weight_map), "tensor_bytes": total}))


if __name__ == "__main__":
    main()
