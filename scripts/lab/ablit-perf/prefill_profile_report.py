#!/usr/bin/env python3
"""Tables from a `macprovider-cli prefill-profile` run on GLM-5.3-Flash (#2409 job 1) or
MiniMax M3.1-Flash (#2458; config `model_type` minimax_m3 / minimax_m3_vl).

usage: prefill_profile_report.py --profile prefill-profile.json --peak peak.json
           --config MODEL/config.json --out-md profile.md --out-json profile-summary.json
           [--reference-ttft 3673=8.00,14126=32.76] [--grid-ttft 3673=11.02,14126=42.49]
           [--reference-chunk TEXT] [--model-name GLM-5.3-Flash]

Stdlib only. The tables, per prompt length P:

 1. TTFT by chunk size on the served path (the serve's keyless network serial path):
    median and range of time to first token per step size, the chunk plan
    (`.legacyRemainder`: full steps while more than one step is left, the rest in the
    first decode forward), prefill tok/s = P / TTFT, the reference's TTFT for the same
    P when given (`--reference-ttft`, the issue baseline) and the share of the ceiling.
 2. Where the served TTFT goes (first step size): the synchronized pass's chunk
    forwards, buffer-cache clears and first forward (remainder + first token), the
    pass without clears, and the served TTFT; `pipelining` = synced total minus served
    TTFT (what asyncEval overlap saves).
 3. Per-chunk forward time (synced pass): first, middle and last chunk, and the growth
    in ms per chunk per 1,000 tokens of offset (least squares).
 4. Section shares (section-timed pass, every section evaluated at its edges): the
    exclusive ms per section summed over the prompt, its share of all sections, that
    share applied to the served TTFT, and groups: attention (mla.*, indexer.*, attn.*),
    MoE/MLP (moe, moe.*, mlp), KDA (linear attention, its state writes included),
    hyper-connections (hc.*), norms (norm.*), embedding and output head (embed, lm_head),
    residual adds and the refusal projection (residual, ablation), cache writes
    (mla.cache_append + indexer.pools + attn.cache_write), other (the forward's own time).
    `lm_head` counts from the first forward only: it sits outside the forward bracket and
    the timer evaluates it on every chunk, whose logits the served path never reads.
 5. The prefill ceiling: about half the measured matmul peak / compute per token.
    Compute per token = 2 x active weight MACs (inventory: every weight matrix, routed
    experts at num_experts_per_tok of n_routed_experts, MTP, embedding and lm_head
    excluded) + attention FLOPs averaged over positions 0..P-1 (sparse MLA: 4 H R
    min(t+1, index_topk); indexer: 2 idxH idxD floor((t+1)/kpool) on layers with their
    own indexer; KDA: 4 H_l D_l^2 per linear layer, an estimate; MiniMax M3: 4 H D (t+1)
    per dense layer, 4 H D min(t+1, block x topk_blocks) per block-sparse layer and its
    indexer 2 idxH idxD (t+1) once t+1 > block x topk_blocks, the work the selection
    needs, not what a masked dense SDPA does). Ceilings use the bf16
    GEMM peak (the AGENTS.md rule) and the 4-bit quantized-matmul peak.

The JSON summary carries every number in the tables. Exit 0, or 2 on unusable input.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
from pathlib import Path

GROUPS = (
    ("attention", lambda s: s.startswith(("mla.", "indexer.", "attn."))),
    ("moe_mlp", lambda s: s in ("moe", "mlp") or s.startswith("moe.")),
    ("kda", lambda s: s == "kda"),
    ("hyper_connections", lambda s: s.startswith("hc.")),
    ("norms", lambda s: s.startswith("norm.")),
    ("embed_and_head", lambda s: s in ("embed", "lm_head")),
    ("residual_and_ablation", lambda s: s in ("residual", "ablation")),
    ("other", lambda s: s == "forward"),
)
# Listed only when a section falls in them (GLM's tables keep their groups).
OPTIONAL_GROUPS = ("norms", "embed_and_head", "residual_and_ablation")
CACHE_WRITES = ("mla.cache_append", "indexer.pools", "attn.cache_write")
# Sections the timer evaluates on every forward but the served path reads on the last only.
LAST_FORWARD_ONLY = ("lm_head",)


def parse_pairs(text: str | None) -> dict[int, float]:
    out: dict[int, float] = {}
    for item in (text or "").split(","):
        if item.strip():
            k, v = item.split("=")
            out[int(k)] = float(v)
    return out


def text_config(config: dict) -> dict:
    tc = config.get("text_config")
    return {**config, **tc} if isinstance(tc, dict) else config


def is_minimax(config: dict) -> bool:
    return str(text_config(config).get("model_type", "")).startswith("minimax_m3")


def weight_macs(inventory: list[dict], config: dict) -> dict:
    """Active multiply-accumulates per token by group, from the leaf-weight inventory."""
    c = text_config(config)
    topk = int(c.get("num_experts_per_tok", 8))
    groups: dict[str, float] = {}
    for e in inventory:
        path, shape, kind = e["path"], e["shape"], e["kind"]
        if re.search(r"(?:^|\.)mtp\.", path) or kind == "embedding" or len(shape) < 2:
            continue
        bits = e.get("bits")
        if kind == "raw":
            macs = float(math.prod(shape))
        else:
            k_in = shape[-1] * 32 // bits if bits else shape[-1]
            lead = math.prod(shape[:-2]) if len(shape) > 2 else 1
            macs = float(k_in * shape[-2] * (topk if kind == "switch" else lead))
        if re.search(r"(?:^|\.)lm_head\.", path):
            group = "lm_head"
        elif kind == "switch":
            group = "routed_experts"
        elif ".indexer." in path:
            group = "indexer"
        elif ".self_attn." in path:
            group = "attention_projections"
        elif ".mlp." in path or ".shared_experts." in path:
            group = "shared_or_dense_mlp"
        else:
            group = "hyper_connections_and_other"
        groups[group] = groups.get(group, 0.0) + macs
    return groups


def layer_counts(inventory: list[dict], config: dict | None = None) -> dict[str, int]:
    def layers(pattern: str) -> set[int]:
        rx = re.compile(pattern)
        return {int(m.group(1)) for e in inventory if (m := rx.search(e["path"]))}

    attn = layers(r"(?:^|\.)layers\.(\d+)\.self_attn\.")
    if config is not None and is_minimax(config):
        sparse = layers(r"(?:^|\.)layers\.(\d+)\.self_attn\.index_k_proj\.weight$")
        return {"dense": len(attn - sparse), "sparse": len(sparse)}
    mla = layers(r"(?:^|\.)layers\.(\d+)\.self_attn\.kv_a_proj_with_mqa\.weight$")
    indexer = layers(r"(?:^|\.)layers\.(\d+)\.self_attn\.indexer\.wk\.weight$")
    return {"mla": len(mla), "indexer": len(indexer), "kda": len(attn - mla)}


def attention_flops_per_token(config: dict, counts: dict[str, int], prompt: int) -> dict:
    """Context-dependent FLOPs per token, averaged over positions 0..prompt-1."""
    c = text_config(config)
    if is_minimax(config):
        return minimax_attention_flops_per_token(c, counts, prompt)
    lin = c.get("linear_attn_config") or {}
    heads = int(c.get("num_attention_heads", 64))
    rank = int(c.get("kv_lora_rank", 512))
    topk = int(c.get("index_topk", 2048))
    idx_heads = int(c.get("index_n_heads", 32))
    idx_dim = int(c.get("index_head_dim", 128))
    kpool = int(c.get("index_kpool", 16))
    lin_heads = int(lin.get("num_heads", c.get("linear_num_heads", 64)))
    lin_dim = int(lin.get("head_dim", c.get("linear_head_dim", 128)))
    # sum_{t<P} min(t+1, topk) (closed form) and sum_{t<P} floor((t+1)/kpool).
    n = prompt
    attended = n * (n + 1) // 2 if n <= topk else topk * (topk + 1) // 2 + (n - topk) * topk
    pooled = sum((t + 1) // kpool for t in range(n))
    mla = counts["mla"] * 4 * heads * rank * attended / n
    idx = counts["indexer"] * 2 * idx_heads * idx_dim * pooled / n
    kda = counts["kda"] * 4 * lin_heads * lin_dim * lin_dim
    return {"mla": mla, "indexer": idx, "kda": kda}


def minimax_attention_flops_per_token(c: dict, counts: dict[str, int], prompt: int) -> dict:
    """MiniMax M3: dense causal layers, block-sparse layers and their indexer (module header)."""
    sp = c.get("sparse_attention_config") or {}
    heads = int(c.get("num_attention_heads", 64))
    dim = int(c.get("head_dim") or int(c.get("hidden_size", 6144)) // heads)
    idx_heads = int(sp.get("sparse_num_index_heads", c.get("index_n_heads", 4)))
    idx_dim = int(sp.get("sparse_index_dim", c.get("index_head_dim", 128)))
    selected = int(sp.get("sparse_block_size", c.get("index_block_size", 128))) * int(
        sp.get("sparse_topk_blocks", c.get("index_topk_blocks", 16)))
    n = prompt
    causal = n * (n + 1) // 2
    attended = causal if n <= selected else selected * (selected + 1) // 2 + (n - selected) * selected
    scored = causal - selected * (selected + 1) // 2 if n > selected else 0
    return {"dense": counts.get("dense", 0) * 4 * heads * dim * causal / n,
            "sparse": counts.get("sparse", 0) * 4 * heads * dim * attended / n,
            "indexer": counts.get("sparse", 0) * 2 * idx_heads * idx_dim * scored / n}


def median(values: list[float]) -> float:
    return statistics.median(values) if values else float("nan")


def fit_slope(xs: list[float], ys: list[float]) -> float:
    if len(xs) < 2:
        return float("nan")
    mx, my = sum(xs) / len(xs), sum(ys) / len(ys)
    den = sum((x - mx) ** 2 for x in xs)
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / den if den else float("nan")


def section_totals(sections_pass: dict) -> dict[str, dict]:
    totals: dict[str, dict] = {}
    chunks = list(sections_pass.get("chunks", []))
    parts = chunks + [sections_pass.get("first_forward", {})]
    for i, part in enumerate(parts):
        for name, v in (part.get("sections") or {}).items():
            if name in LAST_FORWARD_ONLY and i < len(chunks):
                continue
            t = totals.setdefault(name, {"ms": 0.0, "calls": 0})
            t["ms"] += float(v["ms"])
            t["calls"] += int(v["calls"])
    return totals


def summarize(profile: dict, peak: dict, config: dict, ref: dict[int, float], grid: dict[int, float]) -> dict:
    inventory = profile.get("inventory") or []
    macs = weight_macs(inventory, config)
    per_token_weight = sum(v for k, v in macs.items() if k != "lm_head")
    counts = layer_counts(inventory, config)
    prompts = []
    for p in profile["prompts"]:
        n = int(p["tokens"])
        served = []
        for s in p["served"]:
            ttft = [float(r["ttft_ms"]) for r in s["runs"]]
            served.append({
                "step": s["step"], "chunks": s["runs"][0]["chunks"],
                "remainder_tokens": s["runs"][0]["remainder_tokens"],
                "ttft_ms_median": median(ttft), "ttft_ms_min": min(ttft), "ttft_ms_max": max(ttft),
                "prefill_tps": n / (median(ttft) / 1000),
                "first_tokens": sorted({r.get("first_token") for r in s["runs"]}),
            })
        synced, noclear, sect = p["synced"], p["synced_no_clear"], p["sections"]
        chunk_ms = [float(c["forward_ms"]) for c in synced["chunks"]]
        clear_ms = [float(c["clear_ms"]) for c in synced["chunks"]]
        first = float(synced["first_forward"]["forward_ms"])
        base = served[0]
        split = {
            "step": synced["step"], "chunk_forward_ms": sum(chunk_ms), "clear_ms": sum(clear_ms),
            "first_forward_ms": first, "first_forward_tokens": synced["first_forward"]["tokens"],
            "synced_total_ms": float(synced["total_ms"]), "no_clear_total_ms": float(noclear["total_ms"]),
            "served_ttft_ms": base["ttft_ms_median"],
            "pipelining_ms": float(synced["total_ms"]) - base["ttft_ms_median"],
        }
        offsets = [float(c["offset"]) / 1000 for c in synced["chunks"]]
        per_chunk = {
            "count": len(chunk_ms),
            "first_ms": chunk_ms[0] if chunk_ms else None,
            "middle_ms": chunk_ms[len(chunk_ms) // 2] if chunk_ms else None,
            "last_ms": chunk_ms[-1] if chunk_ms else None,
            "growth_ms_per_1k_offset": fit_slope(offsets, chunk_ms),
            "chunks": [{"offset": c["offset"], "tokens": c["tokens"], "forward_ms": c["forward_ms"],
                        "clear_ms": c["clear_ms"]} for c in synced["chunks"]],
        }
        sections = None
        if sect.get("section_timing") is True:
            totals = section_totals(sect)
            all_ms = sum(t["ms"] for t in totals.values()) or float("nan")
            rows = sorted(({"section": k, **v, "share": v["ms"] / all_ms,
                            "served_ms_est": v["ms"] / all_ms * base["ttft_ms_median"]}
                           for k, v in totals.items()), key=lambda r: -r["ms"])
            groups = {}
            for g, match in GROUPS:
                if g in OPTIONAL_GROUPS and not any(match(r["section"]) for r in rows):
                    continue
                ms = sum(r["ms"] for r in rows if match(r["section"]))
                groups[g] = {"ms": ms, "share": ms / all_ms, "served_ms_est": ms / all_ms * base["ttft_ms_median"]}
            ms = sum(r["ms"] for r in rows if r["section"] in CACHE_WRITES)
            groups["cache_writes"] = {"ms": ms, "share": ms / all_ms, "served_ms_est": ms / all_ms * base["ttft_ms_median"]}
            sections = {"total_ms": all_ms, "pass_total_ms": float(sect["total_ms"]), "rows": rows, "groups": groups}
        attn = attention_flops_per_token(config, counts, n)
        flops = 2 * per_token_weight + sum(attn.values())
        ceilings = {}
        for key in ("bf16_tflops", "q4_tflops"):
            tflops = float(peak.get(key) or float("nan"))
            tps = 0.5 * tflops * 1e12 / flops
            ceilings[key] = {"peak_tflops": tflops, "ceiling_tps": tps,
                             "ours_share": base["prefill_tps"] / tps,
                             "reference_share": (n / ref[n] / tps) if n in ref else None}
        tokens = {t for s in served for t in s["first_tokens"]}
        tokens |= {synced["first_forward"].get("first_token"), noclear["first_forward"].get("first_token")}
        if sect.get("section_timing") is True:
            tokens.add(sect["first_forward"].get("first_token"))
        prompts.append({
            "tokens": n, "served": served, "split": split, "per_chunk": per_chunk, "sections": sections,
            "reference_ttft_ms": ref[n] * 1000 if n in ref else None,
            "grid_ttft_ms": grid[n] * 1000 if n in grid else None,
            "flops_per_token": flops, "attention_flops_per_token": attn, "ceilings": ceilings,
            "first_tokens_agree": len(tokens - {None}) == 1,
        })
    return {"weight_macs_per_token": macs, "layer_counts": counts, "prompts": prompts}


def fmt(x, digits=1) -> str:
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return "n/a"
    return f"{x:,.{digits}f}"


def markdown(summary: dict, reference_chunk: str, model_name: str = "GLM-5.3-Flash") -> str:
    out = [f"# {model_name} one-row serial prefill profile", ""]
    if reference_chunk:
        out += [f"Reference prefill chunk: {reference_chunk}", ""]
    out += ["## 1. TTFT by chunk size (served path)", "",
            "| prompt | step | chunks x step + first forward | TTFT ms median (min-max) | prefill tok/s | reference TTFT ms | ceiling share (bf16) |",
            "|---:|---:|---|---|---:|---:|---:|"]
    for p in summary["prompts"]:
        for s in p["served"]:
            share = s["prefill_tps"] / p["ceilings"]["bf16_tflops"]["ceiling_tps"]
            out.append(f"| {p['tokens']} | {s['step']} | {s['chunks']} x {s['step']} + {s['remainder_tokens']} | "
                       f"{fmt(s['ttft_ms_median'])} ({fmt(s['ttft_ms_min'])}-{fmt(s['ttft_ms_max'])}) | "
                       f"{fmt(s['prefill_tps'])} | {fmt(p['reference_ttft_ms'])} | {fmt(100 * share)}% |")
    out += ["", "## 2. Where the served TTFT goes", "",
            "| prompt | step | chunk forwards ms | clears ms | first forward ms (tokens) | synced total ms | no-clear total ms | served TTFT ms | pipelining ms |",
            "|---:|---:|---:|---:|---|---:|---:|---:|---:|"]
    for p in summary["prompts"]:
        s = p["split"]
        out.append(f"| {p['tokens']} | {s['step']} | {fmt(s['chunk_forward_ms'])} | {fmt(s['clear_ms'])} | "
                   f"{fmt(s['first_forward_ms'])} ({s['first_forward_tokens']}) | {fmt(s['synced_total_ms'])} | "
                   f"{fmt(s['no_clear_total_ms'])} | {fmt(s['served_ttft_ms'])} | {fmt(s['pipelining_ms'])} |")
    out += ["", "## 3. Per-chunk forward (synced pass)", "",
            "| prompt | chunks | first ms | middle ms | last ms | growth ms per chunk per 1k offset |",
            "|---:|---:|---:|---:|---:|---:|"]
    for p in summary["prompts"]:
        c = p["per_chunk"]
        out.append(f"| {p['tokens']} | {c['count']} | {fmt(c['first_ms'])} | {fmt(c['middle_ms'])} | "
                   f"{fmt(c['last_ms'])} | {fmt(c['growth_ms_per_1k_offset'], 2)} |")
    out += ["", "## 4. Section shares (section-timed pass)", ""]
    for p in summary["prompts"]:
        sec = p["sections"]
        if not sec:
            out += [f"Prompt {p['tokens']}: section timing unavailable (build without MACPROVIDER_SECTION_TIMING).", ""]
            continue
        out += [f"Prompt {p['tokens']}: sections sum {fmt(sec['total_ms'])} ms in a {fmt(sec['pass_total_ms'])} ms pass; "
                "share applied to the served TTFT.", "",
                "| group | ms | share | of served TTFT ms |", "|---|---:|---:|---:|"]
        for g, v in sec["groups"].items():
            out.append(f"| {g} | {fmt(v['ms'])} | {fmt(100 * v['share'])}% | {fmt(v['served_ms_est'])} |")
        out += ["", "| section | calls | ms | share | of served TTFT ms |", "|---|---:|---:|---:|---:|"]
        for r in sec["rows"]:
            out.append(f"| {r['section']} | {r['calls']} | {fmt(r['ms'])} | {fmt(100 * r['share'])}% | {fmt(r['served_ms_est'])} |")
        out.append("")
    out += ["## 5. Prefill ceiling", "",
            "Ceiling = 0.5 x measured peak / compute per token.", "",
            "| prompt | GFLOP per token | peak | peak TFLOP/s | ceiling tok/s | ours | reference |",
            "|---:|---:|---|---:|---:|---:|---:|"]
    for p in summary["prompts"]:
        for key, c in p["ceilings"].items():
            ref = fmt(100 * c["reference_share"]) + "%" if c["reference_share"] is not None else "n/a"
            out.append(f"| {p['tokens']} | {fmt(p['flops_per_token'] / 1e9, 2)} | {key} | {fmt(c['peak_tflops'], 2)} | "
                       f"{fmt(c['ceiling_tps'])} | {fmt(100 * c['ours_share'])}% | {ref} |")
    w = summary["weight_macs_per_token"]
    out += ["", "Active weight MACs per token: " + ", ".join(f"{k} {fmt(v / 1e6)}M" for k, v in sorted(w.items())),
            "Layers: " + ", ".join(f"{k} {v}" for k, v in summary["layer_counts"].items()), ""]
    for p in summary["prompts"]:
        out.append(f"First tokens agree across passes at {p['tokens']}: {'yes' if p['first_tokens_agree'] else 'NO'}")
    return "\n".join(out) + "\n"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True)
    ap.add_argument("--peak", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--out-json", required=True)
    ap.add_argument("--reference-ttft", default="")
    ap.add_argument("--grid-ttft", default="")
    ap.add_argument("--reference-chunk", default="")
    ap.add_argument("--model-name", default="GLM-5.3-Flash")
    a = ap.parse_args(argv)
    try:
        profile = json.loads(Path(a.profile).read_text())
        peak = json.loads(Path(a.peak).read_text())
        config = json.loads(Path(a.config).read_text())
        summary = summarize(profile, peak, config, parse_pairs(a.reference_ttft), parse_pairs(a.grid_ttft))
    except (OSError, ValueError, KeyError, IndexError, TypeError) as e:
        print(f"prefill_profile_report: unusable input: {e}", file=sys.stderr)
        return 2
    summary["reference_chunk"] = a.reference_chunk
    Path(a.out_json).write_text(json.dumps(summary, indent=2, sort_keys=True))
    md = markdown(summary, a.reference_chunk, a.model_name)
    Path(a.out_md).write_text(md)
    print(md, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
