#!/usr/bin/env python3
"""Trace audit lab verifier (campaign #2419, SPEC-036 FR-29/FR-31 checks 1-7).

Reads `trace_opening_v1` lab files written by `macprovider-cli trace-audit-lab`
and prints a verdict JSON. The verifier holds the weights. Block recompute is
MLX in float16 with mlx-lm's own model definition (the configuration round 2
measured, FR-31); check 3 applies each operation in float64 numpy to the
provider-supplied inputs.

Lab dependencies: mlx, mlx-lm, numpy (the round-2 research environment). They
are not dependencies of the provider.

  trace-audit-lab-verify.py --model DIR --manifest OPENINGS_DIR/manifest.json --out verdicts.json
  trace-audit-lab-verify.py --model DIR --opening FILE [--prompt-tokens JSON --generated-tokens JSON]

Opening file: b"MPTRACEOPEN1\\n" || u64le json_length || json || payloads ||
internal. JSON: `request`, `draws`, `leaves` (sorted leaf indices), `proof`
(multiproof nodes [level, index, hex]). Payloads follow in index order (2*H
bytes per residual leaf, 8 per token pair); `draws[*].internal_float32[name]`
is [offset, count] of float32 LE values from the start of the internal
section (provider recompute, not committed).
"""
import argparse
import hashlib
import json
import math
import os
import secrets
import struct
import sys
import time

import numpy as np

MAGIC = b"MPTRACEOPEN1\n"
LEAF_DOMAIN = b"mp.trace.leaf.v1\0"
DRAW_DOMAIN = b"mp.trace.draw.v1\0"
ELEM_DOMAIN = b"mp.trace.elem.v1\0"
NO_SERVED = 0xFFFFFFFF
FMIN = 2.0 ** -14

# SPEC-036 FR-31 pilot calibration record trace-cal-r2-2026-11-17.
CALIBRATION = {
    "calibration_id": "trace-cal-r2-2026-11-17", "architectures": ["qwen2", "llama"],
    "activation_dtype": "float16", "recompute": "mlx-float16",
    "tol_block": 2e-2, "tol_matmul": 2e-3, "tol_logits": 2e-3, "tol_embedding": 1e-3,
    "tol_prefix_norm": 3e-3, "tol_norm": 5e-3, "tol_glu": 5e-3, "tol_residual_add": 1e-3,
    "tol_attention": 5e-2, "tol_output_tie": 0.05,
}


# ----------------------------------------------------------------------------- opening + Merkle

def read_opening(path):
    with open(path, "rb") as f:
        data = f.read()
    if not data.startswith(MAGIC):
        raise ValueError("not a trace opening")
    (n,) = struct.unpack_from("<Q", data, len(MAGIC))
    start = len(MAGIC) + 8
    head = json.loads(data[start:start + n])
    return head, memoryview(data)[start + n:]


def node(left, right):
    return hashlib.sha256(b"\x01" + left + right).digest()


def leaf_bytes(index, blocks, payload):
    per = blocks + 2
    p, j = divmod(index, per)
    kind, block = (0, j) if j < blocks else ((1, 0) if j == blocks else (2, 0))
    return LEAF_DOMAIN + struct.pack("<III", kind, block, p) + payload


def level_for(size):
    return (size - 1).bit_length()


def largest_pow2_below(n):
    k = 1
    while k << 1 < n:
        k <<= 1
    return k


def multiproof_root(leaf_count, leaf_hashes, nodes):
    """FR-31: root from opened leaf hashes {index: hash} and nodes {(level, index): hash}; every node used once."""
    opened = sorted(leaf_hashes)
    used = [0]

    def walk(lo, hi, a, b):
        if a == b:
            h = level_for(hi - lo)
            got = nodes.get((h, lo >> h))
            if got is None:
                raise KeyError
            used[0] += 1
            return got
        if hi - lo == 1:
            return leaf_hashes[lo]
        k = largest_pow2_below(hi - lo)
        m = a
        while m < b and opened[m] < lo + k:
            m += 1
        return node(walk(lo, lo + k, a, m), walk(lo + k, hi, m, b))

    if not opened or opened[0] < 0 or opened[-1] >= leaf_count:
        return None
    try:
        r = walk(0, leaf_count, 0, len(opened))
    except KeyError:
        return None
    return r if used[0] == len(nodes) else None


class DrawStream:
    """x_i = SHA-256(domain || root || nonce || u32le i), big-endian; rejection sampling."""

    def __init__(self, domain, root, nonce):
        self.prefix, self.i = domain + root + nonce, 0

    def below(self, m):
        while True:
            x = int.from_bytes(hashlib.sha256(self.prefix + struct.pack("<I", self.i)).digest(), "big")
            self.i += 1
            if x < m * ((1 << 256) // m):
                return x % m


def fr29_points(root, nonce, blocks, positions, prompt, block_points=2, output_points=2):
    s = DrawStream(DRAW_DOMAIN, root, nonce)
    pts = []
    while len(pts) < min(block_points, blocks * positions):
        v = s.below(blocks * positions)
        if (v // positions, v % positions) not in pts:
            pts.append((v // positions, v % positions))
    pp = (0, s.below(prompt))
    first = prompt - 1
    outs = []
    while len(outs) < min(output_points, positions - first):
        q = first + s.below(positions - first)
        if q not in outs:
            outs.append(q)
    return pts, pp, outs


# ----------------------------------------------------------------------------- model side

def load_model(path):
    import mlx.core as mx
    from mlx_lm import load
    model, _ = load(path)
    return model, mx


def dequant_row(layer, row, mx):
    """Row `row` of a (quantized) linear/embedding weight in float64."""
    w = layer.weight[row:row + 1]
    if hasattr(layer, "scales"):
        biases = getattr(layer, "biases", None)
        w = mx.dequantize(w, layer.scales[row:row + 1], None if biases is None else biases[row:row + 1],
                          group_size=layer.group_size, bits=layer.bits)
    return np.array(w.astype(mx.float32))[0].astype(np.float64)


def block_recompute(model, mx, l, x16):
    """Block l over x16 [1, n, H] float16 with the serving block module itself (check 2), plus
    the block's rotated K and V from the committed inputs (the attention link of check 3)."""
    blk = model.model.layers[l]
    at = blk.self_attn
    B, n, _ = x16.shape
    n1 = blk.input_layernorm(x16)
    kh = at.rope(at.k_proj(n1).reshape(B, n, at.n_kv_heads, -1).transpose(0, 2, 1, 3))
    vh = at.v_proj(n1).reshape(B, n, at.n_kv_heads, -1).transpose(0, 2, 1, 3)
    y = blk(x16, mask="causal", cache=None)
    mx.eval(y, kh, vh)
    return y, kh, vh


def own_forward(model, mx, ids, want):
    """The verifier's teacher-forced forward over all committed ids (MLX float16). Returns
    {(slot, p): float64 vector} for slot 0..L (block inputs, slot L = final residual) and the
    final residual rows needed by check 6."""
    h = model.model.embed_tokens(mx.array(ids)[None])
    L = len(model.model.layers)
    got = {}
    for slot in range(L + 1):
        ps = sorted(want.get(slot, ()))
        if ps:
            rows = np.array(h[0, mx.array(ps)].astype(mx.float32)).astype(np.float64)
            got.update({(slot, p): rows[i] for i, p in enumerate(ps)})
        if slot < L:
            h = model.model.layers[slot](h, mask="causal", cache=None)
            mx.eval(h)
    return got, h


def rms64(x, weight, eps):
    return x * weight / math.sqrt(float((x * x).mean()) + eps)


# ----------------------------------------------------------------------------- checks

def verify_opening(path, model, mx, prompt_tokens=None, generated_tokens=None, nonce2=None, cal=CALIBRATION):
    t0 = time.time()
    head, blob = read_opening(path)
    rq = head["request"]
    L, H, N, P = rq["blocks"], rq["hidden_size"], rq["positions"], rq["prompt_positions"]
    root = bytes.fromhex(rq["root"])
    res = {"file": os.path.basename(path), "request_id": rq["request_id"], "positions": N, "prompt_positions": P,
           "calibration_id": cal["calibration_id"], "checks": {}}
    arch = getattr(model.args, "model_type", "")
    if arch not in cal["architectures"] or rq.get("activation_dtype") != cal["activation_dtype"]:
        res["verdict"] = "inconclusive:unavailable"
        res["reason"] = "uncalibrated"
        return res
    idx = lambda kind, l, p: p * (L + 2) + (l if kind == 0 else (L if kind == 1 else L + 1))

    # Check 1: one multiproof over all opened leaves, required-leaf coverage, draws from nonce_1.
    leaves, off = {}, 0
    for index in head["leaves"]:
        size = 2 * H if index % (L + 2) <= L else 8
        leaves[index] = bytes(blob[off:off + size])
        off += size
    internal = blob[off:]
    hashes = {i: hashlib.sha256(b"\x00" + leaf_bytes(i, L, pl)).digest() for i, pl in leaves.items()}
    nodes = {}
    for lv, ix, hx in head["proof"]:
        nodes[(lv, ix)] = bytes.fromhex(hx)
    merkle_ok = (rq["leaf_count"] == N * (L + 2) and len(nodes) == len(head["proof"])
                 and len(leaves) == len(head["leaves"]) and head["leaves"] == sorted(leaves)
                 and multiproof_root(rq["leaf_count"], hashes, nodes) == root)
    need = [idx(0, 0, p) for p in range(P)] + [idx(2, 0, p) for p in range(N)]
    for d in head["draws"]:
        if d["role"] == "output":
            need.append(idx(1, 0, d["position"]))
        else:
            need += [idx(0, d["block"], j) for j in range(d["position"] + 1)] + [d["next_leaf"]]
    missing = [i for i in need if i not in leaves]
    merkle_ok &= not missing
    draws_ok = None
    if rq.get("nonce_1"):
        bp, pp, outs = fr29_points(root, bytes.fromhex(rq["nonce_1"]), L, N, P)
        got = [(d["role"], d.get("block"), d["position"]) for d in head["draws"]]
        want = [("block", b, p) for b, p in bp] + [("prompt", 0, pp[1])] + [("output", None, q) for q in outs]
        draws_ok = got == want
    res["checks"]["merkle"] = {"pass": bool(merkle_ok), "leaves": len(leaves), "proof_nodes": len(nodes),
                               "missing": len(missing), "draws_match_nonce_1": draws_ok}
    if missing:
        res["verdict"] = "fail:merkle"
        return res

    tokens = [struct.unpack("<II", leaves[idx(2, 0, p)]) for p in range(N)]
    inputs = [t[0] for t in tokens]
    served = [t[1] for t in tokens]

    # Check 4: tokens (lab form: against the manifest's token ids, which stand in for the tokenized request).
    tok_ok = all(served[p] == NO_SERVED for p in range(P - 1)) and all(served[p] == inputs[p + 1] for p in range(P - 1, N - 1))
    if prompt_tokens is not None and generated_tokens is not None:
        tok_ok &= P == len(prompt_tokens) and N == len(prompt_tokens) + len(generated_tokens) - 1
        tok_ok &= inputs == list(prompt_tokens) + list(generated_tokens[:-1]) and served[N - 1] == generated_tokens[-1]
    res["checks"]["tokens"] = {"pass": bool(tok_ok), "against_request": prompt_tokens is not None}

    # Check 5: prompt binding, every prompt position's block-0 leaf vs the embedding row.
    emb = np.array(model.model.embed_tokens(mx.array(inputs[:P])[None]).astype(mx.float32))[0].astype(np.float64)
    committed0 = np.stack([np.frombuffer(leaves[idx(0, 0, p)], dtype="<f2").astype(np.float64) for p in range(P)])
    emb_err = float((np.abs(committed0 - emb) / (np.abs(emb) + FMIN)).max())
    res["checks"]["prompt_binding"] = {"pass": emb_err <= cal["tol_embedding"], "worst": emb_err}

    # Checks 2 and 3 per block and prompt point.
    nonce2 = nonce2 or secrets.token_bytes(32)
    elem = DrawStream(ELEM_DOMAIN, root, nonce2)
    block_worst, internal_worst, points_out = 0.0, {}, []
    block_ok, internal_ok = True, True
    tol_kind = {"q": "tol_matmul", "k": "tol_matmul", "v": "tol_matmul", "o": "tol_matmul", "g": "tol_matmul",
                "u": "tol_matmul", "d": "tol_matmul", "n1": "tol_norm", "n2": "tol_norm", "glu": "tol_glu",
                "h_mid": "tol_residual_add", "next": "tol_residual_add", "att": "tol_attention"}
    f64 = lambda a: np.array(a.astype(mx.float32)).astype(np.float64)
    for d in head["draws"]:
        if d["role"] == "output":
            continue
        l, p = d["block"], d["position"]
        x = np.stack([np.frombuffer(leaves[idx(0, l, j)], dtype="<f2") for j in range(p + 1)])
        nxt = np.frombuffer(leaves[d["next_leaf"]], dtype="<f2").astype(np.float64)
        t1 = time.time()
        y16, kh16, vh16 = block_recompute(model, mx, l, mx.array(x.astype(np.float16))[None])
        y = f64(y16)[0, p]
        xp = x[p].astype(np.float64)
        ratio = float(np.linalg.norm(y - nxt) / (np.linalg.norm(y - xp) + FMIN))
        block_worst = max(block_worst, ratio)
        block_ok &= ratio <= cal["tol_block"]

        # Check 3: per-op links in float64 from the provider-supplied (or committed) inputs.
        prov = {name: np.frombuffer(bytes(internal[o:o + 4 * c]), dtype="<f4").astype(np.float64)
                for name, (o, c) in d["internal_float32"].items()}
        layer = model.model.layers[l]
        at = layer.self_attn
        mats = {"q": (at.q_proj, "n1"), "k": (at.k_proj, "n1"), "v": (at.v_proj, "n1"), "o": (at.o_proj, "att"),
                "g": (layer.mlp.gate_proj, "n2"), "u": (layer.mlp.up_proj, "n2"), "d": (layer.mlp.down_proj, "glu")}
        point_internal = {}
        for name in sorted(tol_kind):
            e = elem.below(len(prov[name]))
            if name in mats:
                lin, src = mats[name]
                w = dequant_row(lin, e, mx)
                bias = float(np.array(lin.bias[e].astype(mx.float32))) if getattr(lin, "bias", None) is not None else 0.0
                link = float((w * prov[src]).sum()) + bias
                norm = float(np.abs(w * prov[src]).sum()) + abs(bias)
            elif name in ("n1", "n2"):
                ln, src = (layer.input_layernorm, xp) if name == "n1" else (layer.post_attention_layernorm, prov["h_mid"])
                link = float(rms64(src, f64(ln.weight), ln.eps)[e])
                norm = abs(link) + FMIN
            elif name == "glu":
                g_, u_ = prov["g"][e], prov["u"][e]
                link = g_ / (1.0 + math.exp(-g_)) * u_
                norm = abs(link) + FMIN * (abs(g_ * u_) + 1)
            elif name == "h_mid":
                link = xp[e] + prov["o"][e]
                norm = abs(xp[e]) + abs(prov["o"][e]) + FMIN
            elif name == "next":
                link = prov["h_mid"][e] + prov["d"][e]
                norm = abs(prov["h_mid"][e]) + abs(prov["d"][e]) + FMIN
            else:  # attention: provider q at p, rotated at p; K and V recomputed from the committed inputs 0..p
                hd = len(prov["att"]) // at.n_heads
                h = e // hd
                g_ = h // (at.n_heads // at.n_kv_heads)
                qr = at.rope(mx.array(prov["q"].astype(np.float32)).reshape(1, 1, at.n_heads, hd).transpose(0, 2, 1, 3), offset=p)
                qh = f64(qr)[0, h, 0]
                kh = f64(kh16)[0, g_, :p + 1]
                vh = f64(vh16)[0, g_, :p + 1, e % hd]
                sc = kh @ qh * at.scale
                pr = np.exp(sc - sc.max())
                pr /= pr.sum()
                link = float((pr * vh).sum())
                norm = float((pr * np.abs(vh)).sum()) + FMIN
            err = abs(prov[name][e] - link) / norm
            point_internal[name] = err
            internal_worst[name] = max(internal_worst.get(name, 0.0), err)
            internal_ok &= err <= cal[tol_kind[name]]
        points_out.append({"role": d["role"], "block": l, "position": p, "block_ratio": ratio,
                           "internal": point_internal, "seconds": time.time() - t1})
    res["checks"]["block"] = {"pass": bool(block_ok), "worst": block_worst}
    res["checks"]["internal"] = {"pass": bool(internal_ok), "worst": internal_worst, "nonce_2": nonce2.hex()}
    res["points"] = points_out

    # Checks 6 and 7 through the verifier's own teacher-forced forward over the committed ids.
    want = {}
    for i in leaves:
        p, j = divmod(i, L + 2)
        if j <= L:
            want.setdefault(j, set()).add(p)
    t2 = time.time()
    mine, h_final = own_forward(model, mx, inputs, want)
    shares = [float(np.linalg.norm(np.frombuffer(leaves[p * (L + 2) + j], dtype="<f2").astype(np.float64) - v)
                    / (np.linalg.norm(np.frombuffer(leaves[p * (L + 2) + j], dtype="<f2").astype(np.float64)) + FMIN))
              for (j, p), v in mine.items()]
    res["checks"]["forward_consistency"] = {"recorded_only": True, "leaves": len(shares),
                                            "worst": max(shares, default=None),
                                            "median": float(np.median(shares)) if shares else None}
    outs = [d["position"] for d in head["draws"] if d["role"] == "output"]
    if outs:
        hn = model.model.norm(h_final[:, mx.array(outs)])
        tied = getattr(model, "lm_head", None) is None
        logits = model.model.embed_tokens.as_linear(hn) if tied else model.lm_head(hn)
        lg = f64(logits)[0]
        rows, ok, near_tie = [], True, False
        for i, p in enumerate(outs):
            top, s = int(lg[i].argmax()), served[p]
            gap = float(lg[i][top] - lg[i][s])
            if top != s:
                if gap < cal["tol_output_tie"]:
                    near_tie = True
                else:
                    ok = False
            rows.append({"position": p, "argmax": top, "served": s, "gap": gap})
        res["checks"]["output_binding"] = {"pass": bool(ok), "near_tie": near_tie, "points": rows}
    res["forward_seconds"] = time.time() - t2

    order = ["merkle", "block", "tokens", "prompt_binding", "output_binding"]
    failed = [c for c in order if c in res["checks"] and not res["checks"][c]["pass"]]
    if failed:
        res["verdict"] = f"fail:{failed[0]}"
    elif res["checks"].get("output_binding", {}).get("near_tie"):
        res["verdict"] = "inconclusive:near_tie"
    else:
        res["verdict"] = "pass"
    res["seconds"] = time.time() - t0
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--model", required=True)
    ap.add_argument("--manifest")
    ap.add_argument("--opening", action="append", default=[])
    ap.add_argument("--prompt-tokens")
    ap.add_argument("--generated-tokens")
    ap.add_argument("--nonce2-hex")
    ap.add_argument("--out")
    a = ap.parse_args()
    model, mx = load_model(a.model)
    jobs = []
    if a.manifest:
        with open(a.manifest) as f:
            m = json.load(f)
        base = os.path.dirname(os.path.abspath(a.manifest))
        jobs += [(os.path.join(base, o["file"]), o.get("prompt_tokens"), o.get("generated_tokens")) for o in m["openings"]]
    for path in a.opening:
        pt = json.loads(a.prompt_tokens) if a.prompt_tokens else None
        gt = json.loads(a.generated_tokens) if a.generated_tokens else None
        jobs.append((path, pt, gt))
    nonce2 = bytes.fromhex(a.nonce2_hex) if a.nonce2_hex else None
    results = [verify_opening(p, model, mx, pt, gt, nonce2) for p, pt, gt in jobs]
    points = [pt for r in results for pt in r.get("points", [])]
    summary = {
        "openings": len(results),
        "verdicts": {v: sum(r["verdict"] == v for r in results) for v in sorted({r["verdict"] for r in results})},
        "points": len(points),
        "points_block_pass": sum(pt["block_ratio"] <= CALIBRATION["tol_block"] for pt in points),
        "block_ratio_worst": max((pt["block_ratio"] for pt in points), default=None),
        "block_ratio_median": float(np.median([pt["block_ratio"] for pt in points])) if points else None,
    }
    out = {"schema": "macprovider.trace-audit-lab.verify.v1", "calibration": CALIBRATION, "summary": summary, "results": results}
    text = json.dumps(out, indent=1, sort_keys=True)
    if a.out:
        with open(a.out, "w") as f:
            f.write(text)
    print(json.dumps(summary, sort_keys=True))
    return 0 if all(r["verdict"] == "pass" for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
