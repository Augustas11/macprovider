"""mlx-lm qwen4_exp oracles on the lab serve's chat prompts (#2449).

usage: qwen4_served_oracle.py SNAPSHOT_DIR OUT_DIR CONTEXTS STEPS [SERVED_JSONL ...]

For each context in CONTEXTS (parity-grid prompt sizes, e.g. 200,4000) the prompt is
row 0's chat prompt (scripts/lab/parity-grid/prompts.build_messages), rendered with the
chat template exactly as reference_mlxlm.py renders it (thinking off when the template
has the switch). The model and tokenizer load as reference_mlxlm.py --loader qwen4 does
(qwen4_oracle.py's shim). Per prompt:

  1. the reference text: mlx-lm stream_generate, greedy, STEPS tokens, as the lab
     job's reference side ran it;
  2. the oracle: the same greedy decode with stream_generate's own prefill partition
     (generate_step: chunks of 2048 over all but the last prompt token, then the last
     token alone), recording the raw logits' top 16 at EVERY step (qwen4_oracle.py
     records 16 steps only). Its tokens must equal step 1's (ORACLE_REPRODUCES), else
     the oracle is not the reference that produced the served comparison and the run
     says so (ORACLE_REPRODUCES false; its logits are still the reference model's);
  3. with SERVED_JSONL (provider.jsonl files of the lab serve's 1-row cells): the served
     row-0 trial-0 text for this context, its first byte that differs from the oracle
     text, and the oracle token index holding that byte (`token_index`); `served_token`
     is the served text's token there when its re-encoding agrees with the oracle up to
     that index (else null).

Writes OUT_DIR/oracle_served_<ctx>.npz (the glm53_oracle_json.py format: prompt, greedy,
top_idx, top_logit) and OUT_DIR/served_<ctx>.json (the metadata above, `source` = the
npz name). Lines: SERVED_ORACLE_CELL. The pure helpers are unit-tested without MLX.
"""
import hashlib
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "parity-grid"))

PREFILL_STEP, TOPK = 2048, 16


def generate_step_chunks(n, step=PREFILL_STEP):
    """(start, end) prompt slices in mlx-lm generate_step's order: chunks of at most
    `step` over the first n - 1 tokens, then the last token alone (its logits pick the
    first generated token)."""
    if n < 1:
        raise ValueError("empty prompt")
    out, start = [], 0
    while n - start > 1:
        end = start + min(step, n - start - 1)
        out.append((start, end))
        start = end
    out.append((start, n))
    return out


def first_diff(a, b):
    """Index of the first differing element of two sequences (the shorter length if one
    is a prefix of the other), or None when they are equal."""
    n = min(len(a), len(b))
    i = next((j for j in range(n) if a[j] != b[j]), n)
    return None if i == n and len(a) == len(b) else i


def token_at_byte(token_bytes, offset):
    """Index of the token whose bytes contain byte `offset` of their concatenation, or
    len(token_bytes) when the offset is past the end."""
    pos = 0
    for i, b in enumerate(token_bytes):
        pos += len(b)
        if offset < pos:
            return i
    return len(token_bytes)


def served_row(paths, ctx):
    """The provider row 0, trial 0 record of the 1-row cell at ctx (turn 1), or None."""
    for path in paths:
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                r = json.loads(line)
                if (r.get("kind") == "row" and r.get("side", "provider") == "provider" and r.get("rows") == 1
                        and r.get("row") == 0 and r.get("trial") == 0 and r.get("turn", 1) == 1
                        and str(r.get("ctx_target")) == str(ctx)):
                    return r
    return None


def served_comparison(record, greedy, decode_one, encode):
    """The served text against the oracle's greedy tokens (module docstring, step 3)."""
    if record is None:
        return None
    text = record.get("text") or ""
    token_bytes = [decode_one(t).encode() for t in greedy]
    oracle_bytes, served_bytes = b"".join(token_bytes), text.encode()
    diff = first_diff(oracle_bytes, served_bytes)
    out = {"prompt_tokens": record.get("prompt_tokens"), "completion_tokens": record.get("completion_tokens"),
           "finish": record.get("finish"), "error": record.get("error"), "text_equal": diff is None,
           "common_prefix_bytes": diff, "token_index": None, "served_token": None, "oracle_token": None}
    if diff is None:
        return out
    index = token_at_byte(token_bytes, diff)
    served_ids = list(encode(text))
    # A difference at a token boundary can also be a longer token at the index before ("no" vs
    # "not"): the re-encoded served text decides between the two when it agrees up to there.
    j = first_diff(served_ids, list(greedy))
    if j is not None and j in (index - 1, index):
        index = j
    out["token_index"] = index
    out["oracle_token"] = greedy[index] if index < len(greedy) else None
    if index < len(served_ids) and served_ids[:index] == list(greedy[:index]):
        out["served_token"] = served_ids[index]
    lo = max(0, diff - 40)
    out["oracle_text_near"] = oracle_bytes[lo:diff + 40].decode("utf-8", "replace")
    out["served_text_near"] = served_bytes[lo:diff + 40].decode("utf-8", "replace")
    return out


def oracle_decode(model, ids, steps, stop):
    """Greedy decode with generate_step's prefill partition; top-16 raw logits per step."""
    import mlx.core as mx
    import numpy as np

    cache = model.make_cache()
    logits = None
    for start, end in generate_step_chunks(len(ids)):
        logits = model(mx.array([ids[start:end]]), cache=cache)[:, -1, :]
        mx.eval(logits)
    greedy, top_idx, top_logit = [], [], []
    for _ in range(steps):
        row = logits[0].astype(mx.float32)
        idx = mx.argsort(-row)[:TOPK]
        t = int(mx.argmax(logits, axis=-1).item())
        if t in stop:
            break
        greedy.append(t)
        top_idx.append(np.array(idx))
        top_logit.append(np.array(row[idx]))
        logits = model(mx.array([[t]]), cache=cache)[:, -1, :]
    return greedy, top_idx, top_logit


def main():
    import mlx.core as mx
    import numpy as np
    from mlx_lm import stream_generate
    from mlx_lm.sample_utils import make_sampler

    import prompts
    from reference_mlxlm import load_model

    path, out, contexts, steps = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
    served_paths = sys.argv[5:]
    os.makedirs(out, exist_ok=True)
    info = mx.device_info() if hasattr(mx, "device_info") else mx.metal.device_info()
    mx.set_wired_limit(int(info["max_recommended_working_set_size"]))
    model, tokenizer = load_model("qwen4", path)
    template = getattr(tokenizer, "chat_template", None) or ""
    kwargs = {"enable_thinking": False} if "enable_thinking" in str(template) else {}
    stop = set(tokenizer.eos_token_ids)
    sampler = make_sampler(temp=0.0)

    def decode_one(t):
        return tokenizer.decode([t])

    def encode(text):
        return tokenizer.encode(text, add_special_tokens=False)

    for ctx in [x.strip() for x in contexts.split(",") if x.strip()]:
        ids = list(tokenizer.apply_chat_template(prompts.build_messages(int(ctx), 0), add_generation_prompt=True, **kwargs))
        reference = [int(r.token) for r in stream_generate(model, tokenizer, ids, max_tokens=steps, sampler=sampler)]
        reference = [t for t in reference if t not in stop]
        greedy, top_idx, top_logit = oracle_decode(model, ids, steps, stop)
        source = f"oracle_served_{ctx}.npz"
        np.savez(os.path.join(out, source), prompt=np.array(ids, dtype=np.int32), greedy=np.array(greedy, dtype=np.int32),
                 top_idx=np.stack(top_idx), top_logit=np.stack(top_logit))
        meta = {
            "source": source, "ctx": int(ctx), "prompt_tokens": len(ids),
            "prompt_sha256": hashlib.sha256(np.array(ids, dtype=np.int32).tobytes()).hexdigest(),
            "oracle_tokens": len(greedy), "stream_generate_tokens": len(reference),
            "stream_generate_first_diff": first_diff(reference, greedy),
            "oracle_reproduces_reference": reference == greedy,
            "served": served_comparison(served_row(served_paths, ctx), greedy, decode_one, encode),
        }
        with open(os.path.join(out, f"served_{ctx}.json"), "w") as f:
            json.dump(meta, f, indent=2)
        print("SERVED_ORACLE_CELL " + json.dumps({k: meta[k] for k in (
            "ctx", "prompt_tokens", "oracle_tokens", "stream_generate_first_diff", "oracle_reproduces_reference")}
            | {"served_step": (meta["served"] or {}).get("token_index"),
               "served_text_equal": (meta["served"] or {}).get("text_equal")}), flush=True)


if __name__ == "__main__":
    main()
