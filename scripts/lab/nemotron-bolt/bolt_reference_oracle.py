#!/usr/bin/env python3
"""Greedy parity oracles for Nemotron 3.5 Bolt 74B-A9B from NVIDIA's own model code (#2329).

The reference is the language model of nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-BF16 at
revision PINNED_REVISION, run through the `modeling_nemotron_h_puzzle.py` /
`modeling_nemotron_h.py` that ship in that repository (the `llm_config.auto_map`
target). No released mlx-lm or transformers class loads `nemotron_h_puzzle`.

What this script adds around NVIDIA's code, and nothing else:

- `modeling_nemotron_h.py` hard-imports `rmsnorm_fn` from `mamba_ssm` (CUDA/Triton; it
  does not install on macOS). A stub `mamba_ssm` package is placed in `sys.modules`
  before the import. Its `rmsnorm_fn` is the plain-PyTorch reference of mamba_ssm's
  gated RMSNorm (`rms_norm_ref`): fp32 math, gate before norm when
  `norm_before_gate=False`, per-group RMS, output in the input dtype. Every other fast
  path in the file stays off (transformers' availability checks require CUDA), so the
  file's own PyTorch fallback (`torch_forward`, eager attention, looped MoE) runs.
- Only the language model is built (`NemotronHPuzzleForCausalLM(llm_config)`, as
  NVIDIA's `modeling_nemotron_h_omni.py` does); the vision tower and projector are not
  imported. Weights load from the snapshot's safetensors: `language_model.backbone.*`
  -> `model.*`, `language_model.lm_head.*` -> `lm_head.*`. Every parameter and buffer
  must be loaded exactly once, or the run stops.
- Multi-token Mamba input (prefill) runs `chunked_prefill_forward`: the operations of
  the file's naive-SSD prefill branch with three changes, each marked in the code.
  (1) The inter-chunk state recurrence sums `decay_chunk[z, c] * states[c]` over the
  source chunk c. The file sums over the target chunk z (`.sum(dim=2)`), so on this
  PyTorch fallback every prompt longer than `chunk_size` (128) tokens diverges from the
  file's own token-by-token recurrence (its decode branch) from position 128 on; the
  CUDA path NVIDIA ships does not run this code. (2) and (3): the convolution sees the
  stored last `conv_kernel - 1` inputs and the SSD starts from the stored SSM state, so a
  prompt can prefill in `--prefill-segment` pieces. The file's prefill materialises
  chunks x 128^4 floats per Mamba layer, about 69 GB at 8K in one piece; 1024-token
  segments keep it near 9 GB. Single-token input (decode) runs the file's code.
  Before any oracle is written, a self-check prefills the first `--self-check-tokens`
  (384) prompt ids through the file's own decode recurrence one token at a time, and
  chunked as one piece, in 160-token pieces (the second piece holds two SSD chunks and
  starts from carried state, as the 1024-token pieces at 8K do) and in 96-token pieces.
  Each must give the same 16 greedy tokens (or diverge only where the recurrence's top-2
  gap is within the tolerance) with logits within a weight-dtype tolerance
  (`SELF_CHECK_REL_TOL`).
- No dt floor. The fallback clamps softplus(dt + dt_bias) at `time_step_min` (0.001;
  lines 595 and 643); NVIDIA's CUDA path passes `dt_limit=time_step_limit=(0, inf)`, and
  the MLX ports clip to that limit. The chunked prefill omits the clamp, and each loaded
  mixer's `time_step_min` is set to 0 so the file's single-token branches clamp at 0, a
  no-op on softplus output. Each oracle's prefill logs the fraction of values below
  0.001, per Mamba layer and in total (`dt_floor_fraction` in `oracle_<N>.meta.json`).
- Compute dtype: the weights are bf16 and the file computes in bf16, except the RMSNorms,
  the router, the prefill SSD scan and the cached SSM state update (float32). Logits come from the bf16 `lm_head` and are
  upcast to float32 by the file (`.float()`), so they carry bf16 rounding.
- The Mamba cache holds conv and SSM state in `llm_config.mamba_ssm_cache_dtype`
  (float32) unless `--ssm-cache-dtype model` (NVIDIA's `generate()` uses the model dtype).

The prompt is the shared code corpus of `scripts/lab/cb-studio/glm53_bench_vlm.py` and
the mlx-lm reference lanes (`"# block {i}\\n" + UNIT`, `add_special_tokens=False`, cut
to exactly N ids) with the snapshot's own tokenizer. Greedy decode of `--steps` tokens;
the top-16 ids and logits (float32) of the first 16 steps. Output per context:
`oracle_<N>.npz` (prompt, greedy, top_idx, top_logit), `oracle_<N>.json` in the
`glm-parity-oracle-v1` format of `scripts/lab/cb-studio/glm53_oracle_json.py`, and
`oracle_<N>.meta.json` (device, dtype, timings, memory, self-check).

usage: bolt_reference_oracle.py <snapshot_dir> <out_dir> [--contexts 1024 8192]
           [--device mps|cpu] [--dtype bfloat16|float32] [--skip-existing]
Run it with `HF_HUB_OFFLINE=1 python -I`. It refuses a snapshot that is not the pinned
revision or whose code/config/tokenizer files differ from the pinned hashes.
"""

import argparse
import ctypes
import hashlib
import importlib
import importlib.machinery
import importlib.util
import json
import os
import resource
import sys
import time
import types
from pathlib import Path

REPO_ID = "nvidia/NVIDIA-Nemotron-3.5-Bolt-74B-A9B-BF16"
PINNED_REVISION = "e09a4cedb1787db1760375ee5539f222cae0c672"
# Every file this script reads or imports from the snapshot, hashed at PINNED_REVISION.
PINNED_SHA256 = {
    "__init__.py": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
    "config.json": "ccd28f87d7c5c405dcd82271e20492a2beddcfa446acbbd7b9f8c48eab890820",
    "configuration_nemotron_h.py": "0fc818c10506c91bd02df5a605f49cb0704b5498954f46dbde2d63999ae36c3d",
    "configuration_nemotron_h_puzzle.py": "b13b837322dd0e5ec972227d180aa86eb671cab2594df0c0d51d2456599bae91",
    "modeling_nemotron_h.py": "e1cb5fc02e887983f0a445bf4c1a2604453b2cb2db4624c7004dcf663bbb1b6e",
    "modeling_nemotron_h_puzzle.py": "e81a7a97ce55896c6af898cf792cfbdff123eb476d11267aefc3f29bc5af3882",
    "model.safetensors.index.json": "25bf04a0a33e49af0d861b3b86d7b6e39b461b95d86daa12be865842954cddee",
    "tokenizer.json": "d0432ad8b1c2984a2e2dca82e1933e3fd5628df6e95c51fba4c3ee9950dce299",
    "tokenizer_config.json": "c6067a79d81c7bf7b1485588b2a407ac9fe124056f4f759f09fc211d7114d123",
}
PACKAGE = "bolt_reference"
WEIGHT_PREFIXES = (("language_model.backbone.", "model."), ("language_model.lm_head.", "lm_head."))

UNIT = (
    "def fibonacci(n: int) -> int:\n    a, b = 0, 1\n    for _ in range(n):\n        a, b = b, a + b\n    return a\n\n"
    "class Cache:\n    def __init__(self, size):\n        self.size = size\n        self.store = {}\n\n"
    "    def get(self, key, default=None):\n        return self.store.get(key, default)\n\n"
)
LOGIT_STEPS = 16
# The PyTorch fallback's dt floor (`time_step_min`); the oracle does not apply it.
DT_FLOOR = 1e-3
# Per Mamba layer [values below DT_FLOOR, values] of softplus(dt + dt_bias) seen by
# chunked prefill while collecting; None when not collecting.
DT_FLOOR_STATS = None
# Self-check logit tolerance relative to the largest |top-1 logit|, by weight dtype.
# bf16 keeps 8 significant bits (spacing 2^-7 relative); chunked and stepped prefill
# round in different orders, so a few spacings of drift are expected there; float32
# keeps 24 bits.
SELF_CHECK_REL_TOL = {"bfloat16": 5e-2, "float32": 1e-4}
TOP_K = 16


# ---------------------------------------------------------------- pure helpers (tested)

def build_prompt_ids(encode, n, offset=0):
    """The reference lanes' corpus prompt: `# block {i}` + UNIT blocks until n ids, cut to n."""
    ids, i = [], offset
    while len(ids) < n:
        ids.extend(encode(f"# block {i}\n" + UNIT))
        i += 1
    return ids[:n]


def oracle_doc(source_name, source_bytes, prompt, greedy, top_idx, top_logit):
    """The glm-parity-oracle-v1 document `glm53_oracle_json.py` writes for an .npz."""
    if not prompt or not greedy:
        raise ValueError("empty prompt or greedy")
    if len(top_idx) != len(top_logit) or len(top_idx) > len(greedy):
        raise ValueError("top_idx/top_logit shapes")
    if any(len(a) != len(b) or not a for a, b in zip(top_idx, top_logit)):
        raise ValueError("top_idx/top_logit row shapes")
    return {
        "schema": "glm-parity-oracle-v1",
        "source": source_name,
        "source_sha256": hashlib.sha256(source_bytes).hexdigest(),
        "prompt": [int(x) for x in prompt],
        "greedy": [int(x) for x in greedy],
        "top_idx": [[int(x) for x in row] for row in top_idx],
        "top_logit": [[float(x) for x in row] for row in top_logit],
    }


def self_check_verdict(ref_tokens, ref_logits, tokens, logits, dtype="bfloat16"):
    """Chunked prefill against the token-by-token recurrence over the same steps.

    `ref_logits[s]` are the recurrence's top-16 logits (descending) and `logits[s]` this
    run's logits at the same ids. The tolerance is `SELF_CHECK_REL_TOL[dtype]` times the
    largest |top-1 logit| (at least 1.0), the rounding the weight dtype allows. Both
    conditions are required:
    - the greedy tokens match, or they first differ at a step whose recurrence top-2 gap
      is within the tolerance (a tie the dtype cannot resolve);
    - the largest logit difference on the matching steps is within the tolerance.
    """
    diffs = [max(abs(a - b) for a, b in zip(mine, theirs)) for mine, theirs in zip(logits, ref_logits)]
    first = next((i for i, (a, b) in enumerate(zip(tokens, ref_tokens)) if a != b), None)
    matched = diffs[:first] if first is not None else diffs
    noise = max(matched) if matched else 0.0
    scale = max([abs(row[0]) for row in ref_logits] + [1.0])
    tol = SELF_CHECK_REL_TOL[dtype] * scale
    verdict = {"greedy_match": first is None and len(tokens) == len(ref_tokens),
               "first_divergence": first, "max_abs_logit_diff": round(noise, 6),
               "tolerance": round(tol, 6), "dtype": dtype}
    if first is None:
        tokens_ok = verdict["greedy_match"]
    else:
        gap = ref_logits[first][0] - ref_logits[first][1] if first < len(ref_logits) else None
        verdict["top2_gap_at_divergence"] = gap
        tokens_ok = gap is not None and gap <= tol
    verdict["pass"] = tokens_ok and noise <= tol
    return verdict


def dt_floor_summary(stats):
    """Fractions of softplus(dt + dt_bias) below DT_FLOOR: total and per Mamba layer."""
    below = sum(b for b, _ in stats.values())
    total = sum(t for _, t in stats.values())
    return {"dt_floor": DT_FLOOR, "values": total, "below": below,
            "fraction": below / total if total else None,
            "per_layer": {str(k): (b / t if t else None) for k, (b, t) in sorted(stats.items())}}


def snapshot_problems(snapshot, revision=PINNED_REVISION, pinned=PINNED_SHA256):
    """Reasons the snapshot is not the pinned one (empty when it is)."""
    snapshot = Path(snapshot)
    problems = []
    meta = snapshot / ".cache/huggingface/download/config.json.metadata"
    try:
        commit = meta.read_text().splitlines()[0].strip()
    except (OSError, IndexError):
        commit = None
    if commit != revision:
        problems.append(f"snapshot commit {commit} is not the pinned {revision}")
    for name, want in sorted(pinned.items()):
        path = snapshot / name
        if not path.is_file():
            problems.append(f"missing {name}")
            continue
        got = hashlib.sha256(path.read_bytes()).hexdigest()
        if got != want:
            problems.append(f"{name} sha256 {got} != pinned {want}")
    return problems


def map_weight_name(key):
    for src, dst in WEIGHT_PREFIXES:
        if key.startswith(src):
            return dst + key[len(src):]
    return None


# ---------------------------------------------------------------- memory

def _peak_memory():
    """(lifetime max phys footprint bytes or None, max RSS bytes). Footprint includes Metal."""
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss  # bytes on macOS
    try:
        lib = ctypes.CDLL("/usr/lib/libproc.dylib")
        buf = (ctypes.c_uint64 * 64)()  # rusage_info_v4: 16-byte uuid, then uint64 fields
        if lib.proc_pid_rusage(os.getpid(), 4, ctypes.byref(buf)) == 0:
            return int(buf[2 + 28]), rss  # uuid = 2 words; ri_lifetime_max_phys_footprint
    except OSError:
        pass
    return None, rss


def _gb(x):
    return None if x is None else round(x / 1e9, 2)


# ---------------------------------------------------------------- NVIDIA code loading

def install_mamba_ssm_stub(torch):
    """sys.modules stand-in for `mamba_ssm.ops.triton.layernorm_gated.rmsnorm_fn`."""
    if importlib.util.find_spec("mamba_ssm") is not None:
        raise SystemExit("a real mamba_ssm is importable; refusing to shadow it")
    F = torch.nn.functional

    def rmsnorm_fn(x, weight, bias=None, z=None, eps=1e-6, group_size=None, norm_before_gate=True, upcast=True):
        # mamba_ssm.ops.triton.layernorm_gated.rms_norm_ref, without einops.
        dtype = x.dtype
        weight = weight.float()
        bias = bias.float() if bias is not None else None
        if upcast:
            x = x.float()
            z = z.float() if z is not None else None
        if z is not None and not norm_before_gate:
            x = x * F.silu(z)
        if group_size is None:
            out = x * torch.rsqrt(x.square().mean(dim=-1, keepdim=True) + eps) * weight
        else:
            xg = x.reshape(*x.shape[:-1], x.shape[-1] // group_size, group_size)
            out = (xg * torch.rsqrt(xg.square().mean(dim=-1, keepdim=True) + eps)).reshape(x.shape) * weight
        if bias is not None:
            out = out + bias
        if z is not None and norm_before_gate:
            out = out * F.silu(z)
        return out.to(dtype)

    names = ["mamba_ssm", "mamba_ssm.ops", "mamba_ssm.ops.triton", "mamba_ssm.ops.triton.layernorm_gated"]
    for i, name in enumerate(names):
        leaf = i == len(names) - 1
        mod = types.ModuleType(name)
        mod.__spec__ = importlib.machinery.ModuleSpec(name, None, is_package=not leaf)
        if not leaf:
            mod.__path__ = []
        mod.__version__ = "0+macprovider-stub"
        sys.modules[name] = mod
        if i:
            setattr(sys.modules[names[i - 1]], name.rsplit(".", 1)[1], mod)
    sys.modules[names[-1]].rmsnorm_fn = rmsnorm_fn
    return rmsnorm_fn


def import_reference(snapshot):
    """Import the snapshot's puzzle modules as package `bolt_reference` (relative imports work)."""
    sys.dont_write_bytecode = True  # nothing is written into the snapshot
    spec = importlib.util.spec_from_file_location(
        PACKAGE, Path(snapshot) / "__init__.py", submodule_search_locations=[str(snapshot)])
    pkg = importlib.util.module_from_spec(spec)
    sys.modules[PACKAGE] = pkg
    spec.loader.exec_module(pkg)
    return types.SimpleNamespace(
        cfg=importlib.import_module(f"{PACKAGE}.configuration_nemotron_h_puzzle"),
        nh=importlib.import_module(f"{PACKAGE}.modeling_nemotron_h"),
        puzzle=importlib.import_module(f"{PACKAGE}.modeling_nemotron_h_puzzle"),
    )


def chunked_prefill_forward(self, input_states, cache_params, attention_mask=None):
    """`NemotronHMamba2Mixer.torch_forward`'s naive-SSD prefill branch, corrected and resumable.

    Same operations as the file, except: (1) the inter-chunk recurrence sums over the
    source chunk; (2) the convolution is preceded by the stored inputs; (3) the SSD starts
    from the stored SSM state. A fresh cache holds zeros, which reproduces the file's
    zero padding and zero initial state.
    """
    import torch
    from torch import nn

    if attention_mask is not None and not torch.all(attention_mask == 1):
        raise ValueError("padded prefill is not supported by this reference lane")
    nh = sys.modules[f"{PACKAGE}.modeling_nemotron_h"]
    batch_size, seq_len, _ = input_states.shape
    dtype = input_states.dtype
    projected_states = self.in_proj(input_states)
    d_mlp = (projected_states.shape[-1] - 2 * self.intermediate_size
             - 2 * self.n_groups * self.ssm_state_size - self.num_heads) // 2
    _, _, gate, hidden_states, dt = projected_states.split(
        [d_mlp, d_mlp, self.intermediate_size, self.conv_dim, self.num_heads], dim=-1)

    # Change (2): convolution over [last k-1 stored inputs, segment]; keep the last k inputs.
    k = self.conv_kernel_size
    prev = cache_params.conv_states[self.layer_idx]
    full = torch.cat([prev[:, :, 1:].to(hidden_states.dtype), hidden_states.transpose(1, 2)], dim=-1)
    cache_params.conv_states[self.layer_idx].copy_(full[:, :, -k:])
    hidden_states = self.act(self.conv1d(full)[..., k - 1:k - 1 + seq_len].transpose(1, 2))

    hidden_states, B, C = torch.split(
        hidden_states, [self.intermediate_size, self.n_groups * self.ssm_state_size,
                        self.n_groups * self.ssm_state_size], dim=-1)
    A = -torch.exp(self.A_log.float())
    dt = nn.functional.softplus(dt + self.dt_bias)
    # No `torch.clamp(dt, self.time_step_min)`: the CUDA path NVIDIA runs passes
    # dt_limit=time_step_limit=(0, inf), so trained semantics have no 0.001 floor.
    if DT_FLOOR_STATS is not None:
        below, total = DT_FLOOR_STATS.setdefault(self.layer_idx, [0, 0])
        DT_FLOOR_STATS[self.layer_idx] = [below + int((dt < DT_FLOOR).sum().item()), total + dt.numel()]
    hidden_states = hidden_states.reshape(batch_size, seq_len, -1, self.head_dim).float()
    B = B.reshape(batch_size, seq_len, -1, self.ssm_state_size).float()
    C = C.reshape(batch_size, seq_len, -1, self.ssm_state_size).float()
    B = B.repeat_interleave(self.num_heads // self.n_groups, dim=2, output_size=self.num_heads)
    C = C.repeat_interleave(self.num_heads // self.n_groups, dim=2, output_size=self.num_heads)
    pad_size = (self.chunk_size - seq_len % self.chunk_size) % self.chunk_size
    D_residual = self.D[..., None] * nh.pad_tensor_by_size(hidden_states, pad_size)
    hidden_states = hidden_states * dt[..., None]
    A = A.to(hidden_states.dtype) * dt
    hidden_states, A, B, C = [nh.reshape_into_chunks(t, pad_size, self.chunk_size) for t in (hidden_states, A, B, C)]
    A = A.permute(0, 3, 1, 2)
    A_cumsum = torch.cumsum(A, dim=-1)
    L = torch.exp(nh.segment_sum(A))
    G = (C[:, :, :, None, :, :] * B[:, :, None, :, :, :]).sum(dim=-1)
    M = (G[..., None] * L.permute(0, 2, 3, 4, 1)[..., None]).sum(dim=-1)
    Y_diag = (M[..., None] * hidden_states[:, :, None]).sum(3)
    decay_states = torch.exp(A_cumsum[:, :, :, -1:] - A_cumsum)
    B_decay_contraction = B * decay_states.permute(0, 2, 3, 1)[..., None]
    states = (B_decay_contraction.permute(0, 1, 3, 2, 4)[..., None]
              * hidden_states.permute(0, 1, 3, 2, 4)[..., None, :]).sum(dim=3).permute(0, 1, 2, 4, 3)
    # Change (3): the stored SSM state is the initial state (zeros in a fresh cache).
    previous_states = cache_params.ssm_states[self.layer_idx][:, None, ...].float()
    states = torch.cat([previous_states, states], dim=1)
    decay_chunk = torch.exp(nh.segment_sum(nn.functional.pad(A_cumsum[:, :, :, -1], (1, 0))))
    # Change (1): new_states[z] = sum_c decay_chunk[z, c] * states[c]. decay_chunk is
    # [b, h, z, c]; the source chunk c is dim 3 of the product. The file sums dim 2 (z).
    new_states = (decay_chunk[..., None, None] * states.permute(0, 2, 1, 3, 4)[:, :, None, ...]).sum(dim=3)
    new_states = new_states.permute(0, 2, 1, 3, 4)
    states, ssm_state = new_states[:, :-1], new_states[:, -1]
    state_decay_out = torch.exp(A_cumsum)
    Y_off = (C[..., None, :] * states[:, :, None, ...]).sum(-1) * state_decay_out.permute(0, 2, 3, 1)[..., None]
    y = (Y_diag + Y_off).reshape(batch_size, -1, self.num_heads, self.head_dim) + D_residual
    if pad_size > 0:
        y = y[:, :seq_len, :, :]
    y = y.reshape(batch_size, seq_len, -1)
    cache_params.ssm_states[self.layer_idx].copy_(ssm_state)
    return self.out_proj(self.norm(y, gate).to(dtype))


def remove_dt_floor(model, nh):
    """Set each mixer's `time_step_min` to 0 on the loaded instance (not the file).

    The file's single-token branches clamp softplus output with it (lines 595 and 643);
    softplus is never negative, so clamping at 0 is the identity: the CUDA dt_limit (0, inf).
    """
    mixers = [m for m in model.modules() if isinstance(m, nh.NemotronHMamba2Mixer)]
    for mixer in mixers:
        mixer.time_step_min = 0.0
    return len(mixers)


def install_chunked_prefill(nh):
    """Route multi-token Mamba input with a cache to `chunked_prefill_forward`."""
    original = nh.NemotronHMamba2Mixer.torch_forward

    def torch_forward(self, input_states, cache_params=None, attention_mask=None):
        if cache_params is not None and input_states.shape[1] > 1:
            return chunked_prefill_forward(self, input_states, cache_params, attention_mask)
        return original(self, input_states, cache_params, attention_mask)

    nh.NemotronHMamba2Mixer.torch_forward = torch_forward
    return original


def build_model(torch, ref, snapshot, dtype, device, attn):
    config = json.loads((Path(snapshot) / "config.json").read_text())
    llm = dict(config["llm_config"])
    if llm.get("model_type") != "nemotron_h_puzzle":
        raise SystemExit(f"llm_config.model_type is {llm.get('model_type')}, expected nemotron_h_puzzle")
    cfg = ref.cfg.NemotronHPuzzleConfig(**llm)  # as configuration_nemotron_h_omni.py does
    cfg._attn_implementation = attn
    if cfg._attn_implementation != attn:
        raise SystemExit(f"could not set attention implementation {attn}")
    previous = torch.get_default_dtype()
    torch.set_default_dtype(dtype)
    try:
        try:
            with torch.device("meta"):
                model = ref.puzzle.NemotronHPuzzleForCausalLM(cfg)
            construct = "meta"
        except Exception as error:  # noqa: BLE001 - logged, then the slow path
            print(f"meta construction failed ({error!r}); constructing on {device}", flush=True)
            with torch.device(device):
                model = ref.puzzle.NemotronHPuzzleForCausalLM(cfg)
            construct = device
    finally:
        torch.set_default_dtype(previous)
    params = sum(p.numel() * p.element_size() for p in model.parameters())
    ram = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
    if params > 0.85 * ram:
        raise SystemExit(f"weights need {params / 1e9:.1f} GB in {dtype}; this Mac has {ram / 1e9:.1f} GB")
    if construct == "meta":
        model = model.to_empty(device=device)
    return model, cfg, construct, params


def load_weights(torch, model, snapshot, device):
    from safetensors import safe_open

    snapshot = Path(snapshot)
    weight_map = json.loads((snapshot / "model.safetensors.index.json").read_text())["weight_map"]
    targets = dict(model.named_parameters())
    targets.update(dict(model.named_buffers()))
    by_shard, unexpected = {}, []
    for key, shard in weight_map.items():
        if not key.startswith("language_model."):
            continue
        name = map_weight_name(key)
        if name not in targets:
            unexpected.append(key)
            continue
        by_shard.setdefault(shard, []).append((key, name))
    if unexpected:
        raise SystemExit(f"{len(unexpected)} language-model keys have no target, e.g. {unexpected[:3]}")
    loaded, source_dtypes = set(), {}
    with torch.no_grad():
        for shard in sorted(by_shard):
            with safe_open(str(snapshot / shard), framework="pt", device="cpu") as f:
                for key, name in by_shard[shard]:
                    tensor = f.get_tensor(key)
                    dst = targets[name]
                    if tuple(tensor.shape) != tuple(dst.shape):
                        raise SystemExit(f"{key}: shape {tuple(tensor.shape)} != {tuple(dst.shape)}")
                    if name in loaded:
                        raise SystemExit(f"{name} loaded twice")
                    dst.copy_(tensor.to(dst.dtype))
                    loaded.add(name)
                    source_dtypes[str(tensor.dtype)] = source_dtypes.get(str(tensor.dtype), 0) + 1
    missing = sorted(set(targets) - loaded)
    if missing:
        raise SystemExit(f"{len(missing)} parameters/buffers not in the checkpoint, e.g. {missing[:3]}")
    model.eval()
    return {"tensors": len(loaded), "source_dtypes": source_dtypes}


# ---------------------------------------------------------------- forward passes

def _sync(torch, device):
    if device == "mps":
        torch.mps.synchronize()


def new_cache(ref, model, ssm_dtype, device):
    return ref.nh.NemotronHHybridDynamicCache(model.config, 1, dtype=ssm_dtype, device=device)


def forward(torch, model, cache, ids, start, device):
    input_ids = torch.tensor([ids], dtype=torch.long, device=device)
    position = torch.arange(start, start + len(ids), device=device)
    out = model(input_ids=input_ids, past_key_values=cache, use_cache=True, cache_position=position, return_dict=True)
    return out.logits[0, -1, :].float()


def prefill(torch, model, cache, ids, segment, device):
    logits, start = None, 0
    step = segment if segment else len(ids)
    while start < len(ids):
        logits = forward(torch, model, cache, ids[start:start + step], start, device)
        start += step
    return logits


def greedy(torch, model, cache, logits, start, steps, device, gather=None):
    """Greedy ids, plus the top-16 ids and logits of the first 16 steps. With `gather`,
    the logits recorded are those at `gather[step]` (another run's top-16 ids)."""
    tokens, top_idx, top_logit = [], [], []
    for step in range(steps):
        token = int(torch.argmax(logits).item())
        tokens.append(token)
        if step < LOGIT_STEPS:
            if gather is None:
                values, indices = torch.topk(logits, TOP_K)
                top_idx.append([int(x) for x in indices.cpu().tolist()])
            else:
                top_idx.append(list(gather[step]))
                values = logits[torch.tensor(gather[step], device=logits.device)]
            top_logit.append([float(x) for x in values.cpu().tolist()])
        if step + 1 < steps:
            logits = forward(torch, model, cache, [token], start + step, device)
    return tokens, top_idx, top_logit


def run_context(torch, ref, model, ids, segment, steps, ssm_dtype, device, gather=None):
    cache = new_cache(ref, model, ssm_dtype, device)
    _sync(torch, device)
    t0 = time.perf_counter()
    logits = prefill(torch, model, cache, ids, segment, device)
    _sync(torch, device)
    t1 = time.perf_counter()
    tokens, top_idx, top_logit = greedy(torch, model, cache, logits, len(ids), steps, device, gather)
    _sync(torch, device)
    t2 = time.perf_counter()
    del cache
    return tokens, top_idx, top_logit, {
        "prefill_s": round(t1 - t0, 2), "prefill_tps": round(len(ids) / (t1 - t0), 2),
        "decode_s": round(t2 - t1, 2),
        # The first token comes from the prefill forward; the rest are decode forwards.
        "decode_tps": round((steps - 1) / (t2 - t1), 3) if steps > 1 else None,
    }


# ---------------------------------------------------------------- main

def main(argv=None):
    global DT_FLOOR_STATS
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("snapshot")
    ap.add_argument("out_dir")
    ap.add_argument("--contexts", type=int, nargs="+", default=[1024, 8192])
    ap.add_argument("--steps", type=int, default=256)
    ap.add_argument("--device", choices=["mps", "cpu"], default="mps")
    ap.add_argument("--dtype", choices=["bfloat16", "float32"], default="bfloat16")
    ap.add_argument("--attn", choices=["eager", "sdpa"], default="eager")
    ap.add_argument("--ssm-cache-dtype", choices=["config", "model"], default="config")
    ap.add_argument("--prefill-segment", type=int, default=1024,
                    help="Prefill piece size; pass the same value to glm-parity --prefill-step-size.")
    ap.add_argument("--self-check-tokens", type=int, default=384,
                    help="Prompt ids prefilled both chunked and token by token before any oracle. The 160-token "
                         "variant needs > 288 so that a 2-chunk piece starts from carried state.")
    ap.add_argument("--skip-existing", action="store_true")
    args = ap.parse_args(argv)

    if os.environ.get("HF_HUB_OFFLINE") != "1":
        raise SystemExit("set HF_HUB_OFFLINE=1: the reference loads only from the local snapshot")
    snapshot = Path(args.snapshot).resolve()
    problems = snapshot_problems(snapshot)
    if problems:
        raise SystemExit("snapshot refused:\n  " + "\n  ".join(problems))
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    import numpy as np
    import torch
    import transformers
    from transformers import AutoTokenizer

    if args.device == "mps" and not torch.backends.mps.is_available():
        raise SystemExit("MPS is not available; use --device cpu")
    dtype = getattr(torch, args.dtype)
    install_mamba_ssm_stub(torch)
    ref = import_reference(snapshot)
    if ref.nh.is_fast_path_available:
        raise SystemExit("mamba fast path reported available; expected the PyTorch fallback")
    install_chunked_prefill(ref.nh)
    torch.set_grad_enabled(False)

    t0 = time.perf_counter()
    model, cfg, construct, weight_bytes = build_model(torch, ref, snapshot, dtype, args.device, args.attn)
    load_info = load_weights(torch, model, snapshot, args.device)
    _sync(torch, args.device)
    load_s = round(time.perf_counter() - t0, 1)
    mixers = remove_dt_floor(model, ref.nh)
    ssm_dtype = getattr(torch, cfg.mamba_ssm_cache_dtype) if args.ssm_cache_dtype == "config" else dtype
    tok = AutoTokenizer.from_pretrained(str(snapshot), trust_remote_code=False)
    footprint, rss = _peak_memory()
    env = {
        "repo": REPO_ID, "revision": PINNED_REVISION, "device": args.device, "dtype": args.dtype,
        "attn": args.attn, "mamba_mixers": mixers, "dt_floor_applied": False,
        "logits": "lm_head in the weight dtype, upcast to float32 by the file", "ssm_cache_dtype": str(ssm_dtype).replace("torch.", ""), "construct": construct,
        "weights_gb": round(weight_bytes / 1e9, 1), "load_s": load_s, **load_info,
        "torch": torch.__version__, "transformers": transformers.__version__, "numpy": np.__version__,
        "tokenizer": type(tok).__name__, "python": sys.version.split()[0],
    }
    print(json.dumps({"event": "load", **env, "peak_footprint_gb": _gb(footprint), "peak_rss_gb": _gb(rss)}), flush=True)

    encode = lambda text: tok.encode(text, add_special_tokens=False)  # noqa: E731
    todo = [n for n in sorted(args.contexts)
            if not (args.skip_existing and (out / f"oracle_{n}.json").is_file() and (out / f"oracle_{n}.npz").is_file())]
    self_check = None
    if todo:
        # The corrected chunked prefill (whole piece, and pieces that split SSD chunks)
        # against the file's own decode recurrence, one token at a time.
        check_ids = build_prompt_ids(encode, args.self_check_tokens)
        base = run_context(torch, ref, model, check_ids, 1, LOGIT_STEPS, ssm_dtype, args.device)
        self_check = {"tokens": len(check_ids), "recurrence_prefill_s": base[3]["prefill_s"], "variants": {}}
        # 160: with 384 ids the second piece holds 2 SSD chunks and starts from carried
        # state, the case of the 1024-token pieces at 8K.
        for seg in (len(check_ids), 160, 96):
            got = run_context(torch, ref, model, check_ids, seg, LOGIT_STEPS, ssm_dtype, args.device, gather=base[1])
            self_check["variants"][str(seg)] = self_check_verdict(base[0], base[2], got[0], got[2], args.dtype)
        self_check["pass"] = all(v["pass"] for v in self_check["variants"].values())
        (out / "self_check.json").write_text(json.dumps(self_check, indent=1))
        print(json.dumps({"event": "self_check", **self_check}), flush=True)
        if not self_check["pass"]:
            raise SystemExit("self-check failed: chunked prefill does not reproduce the decode recurrence")
    for n in sorted(args.contexts):
        npz_path, json_path = out / f"oracle_{n}.npz", out / f"oracle_{n}.json"
        if n not in todo:
            print(json.dumps({"event": "skip", "context": n}), flush=True)
            continue
        ids = build_prompt_ids(encode, n)
        segment = args.prefill_segment
        DT_FLOOR_STATS = {}  # decode is single-token and does not count; prefill does
        tokens, top_idx, top_logit, timing = run_context(torch, ref, model, ids, segment, args.steps, ssm_dtype, args.device)
        dt_floor = dt_floor_summary(DT_FLOOR_STATS)
        DT_FLOOR_STATS = None
        np.savez(npz_path, prompt=np.array(ids, dtype=np.int32), greedy=np.array(tokens, dtype=np.int32),
                 top_idx=np.array(top_idx, dtype=np.int32), top_logit=np.array(top_logit, dtype=np.float32))
        stored = np.load(npz_path, allow_pickle=False)
        doc = oracle_doc(npz_path.name, npz_path.read_bytes(), stored["prompt"].tolist(), stored["greedy"].tolist(),
                         stored["top_idx"].tolist(), stored["top_logit"].astype(np.float32).tolist())
        json_path.write_text(json.dumps(doc, separators=(",", ":")))

        footprint, rss = _peak_memory()
        margins = [row[0] - row[1] for row in top_logit]
        meta = {**env, "context": n, "prompt_tokens": len(ids), "steps": args.steps, "prefill_segment": segment,
                "prompt_sha256": hashlib.sha256(np.array(ids, dtype="<i4").tobytes()).hexdigest(),
                **timing, "min_top2_margin_16": round(min(margins), 4),
                "dt_floor_statement": f"dt_floor_fraction={dt_floor['fraction']} of softplus(dt + dt_bias) in this "
                                      f"prefill is below {DT_FLOOR}; the oracle applies no floor (CUDA dt_limit 0..inf)",
                "dt_floor": dt_floor,
                "peak_footprint_gb": _gb(footprint), "peak_rss_gb": _gb(rss),
                "mps_driver_gb": _gb(torch.mps.driver_allocated_memory()) if args.device == "mps" else None,
                "self_check": self_check, "greedy_head": tok.decode(tokens[:40])}
        (out / f"oracle_{n}.meta.json").write_text(json.dumps(meta, indent=1))
        print(json.dumps({"event": "oracle", **{k: meta[k] for k in (
            "context", "device", "prefill_segment", "prefill_tps", "decode_tps", "min_top2_margin_16",
            "peak_footprint_gb", "peak_rss_gb", "mps_driver_gb")}, "dt_floor_fraction": dt_floor["fraction"],
            "dt_floor_per_layer": dt_floor["per_layer"], "self_check": self_check}), flush=True)
        if args.device == "mps":
            torch.mps.empty_cache()
    print(json.dumps({"event": "ALL DONE"}), flush=True)


if __name__ == "__main__":
    main()
