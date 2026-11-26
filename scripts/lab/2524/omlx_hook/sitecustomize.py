# SPDX-License-Identifier: MIT
"""Section timer for an oMLX server's GLM-5.3 prefill (#2524 lab only).

Loaded by the oMLX venv's interpreter when this directory is on PYTHONPATH
(reference_omlx.py --server-env PYTHONPATH=<this dir>) and
OMLX_SECTION_PROFILE names an output directory. Inert otherwise.

When mlx-vlm (or mlx-lm) loads a model, every decoder layer, each of its child
modules and each grandchild is registered under a name such as
`mla.self_attn`, `kda.mlp.switch_mlp` or `mla.layer`; the text model is `model`.
A call of the text model with at least OMLX_SECTION_MIN_TOKENS (64) tokens is a
timed prefill chunk: each registered module's call evaluates its inputs,
synchronizes, runs, evaluates its outputs and synchronizes again, and its
exclusive time (minus registered calls inside it) is added to its name. A
module called inside an mx.compile trace cannot be evaluated; its name is then
left untimed for the rest of the run (`untimed` in the output).

Synchronizing changes the total; the split, not the sum, is what this
measures. Each chunk is appended to <dir>/sections-<pid>.json after it ends.
"""

import importlib.abc
import importlib.util
import json
import os
import sys
import time

_OUT = os.environ.get("OMLX_SECTION_PROFILE")
_MIN_TOKENS = int(os.environ.get("OMLX_SECTION_MIN_TOKENS", "64"))
_LOADERS = ("mlx_vlm.utils", "mlx_lm.utils")

_names = {}       # id(module) -> section name
_patched = set()  # classes whose __call__ is wrapped
_untimed = set()
_state = {"active": False, "stack": [], "calls": [], "sections": None, "chunk_t0": 0.0}


def _log(msg):
    print(f"OMLX_SECTION_HOOK {msg}", file=sys.stderr, flush=True)


def _arrays(x, depth=0):
    import mlx.core as mx

    if isinstance(x, mx.array):
        yield x
    elif depth > 3:
        return
    elif isinstance(x, (list, tuple)):
        for v in x:
            yield from _arrays(v, depth + 1)
    elif isinstance(x, dict):
        for v in x.values():
            yield from _arrays(v, depth + 1)
    elif hasattr(x, "__dataclass_fields__"):
        for f in x.__dataclass_fields__:
            yield from _arrays(getattr(x, f, None), depth + 1)


def _sync(values):
    import mlx.core as mx

    arrs = list(_arrays(values))
    if arrs:
        mx.eval(arrs)
    mx.synchronize()


def _tokens(args, kwargs):
    """Sequence length of the text model's input ids or embeddings."""
    import mlx.core as mx

    for a in (*args[:1], kwargs.get("inputs"), kwargs.get("input_ids"), kwargs.get("inputs_embeds")):
        if isinstance(a, mx.array) and a.ndim >= 2:
            return int(a.shape[1])
    return 0


def _flush():
    path = os.path.join(_OUT, f"sections-{os.getpid()}.json")
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"pid": os.getpid(), "min_tokens": _MIN_TOKENS, "untimed": sorted(_untimed),
                   "registered": len(_names), "calls": _state["calls"]}, f)
    os.replace(tmp, path)


def _timed(name, orig, self, args, kwargs):
    stack = _state["stack"]
    try:
        _sync((args, kwargs))
    except Exception:  # an mx.compile trace: leave this section untimed
        _untimed.add(name)
        return orig(self, *args, **kwargs)
    t0 = time.perf_counter()
    stack.append(0.0)
    try:
        out = orig(self, *args, **kwargs)
        try:
            _sync(out)
        except Exception:
            _untimed.add(name)
    finally:
        child = stack.pop()
    elapsed = time.perf_counter() - t0
    secs = _state["sections"]
    secs[name] = secs.get(name, 0.0) + (elapsed - child) * 1000.0
    if stack:
        stack[-1] += elapsed
    return out


def _wrap(cls):
    if cls in _patched:
        return
    orig = cls.__call__

    def __call__(self, *args, **kwargs):
        name = _names.get(id(self))
        if name is None or name in _untimed:
            return orig(self, *args, **kwargs)
        if name == "model" and not _state["active"]:
            n = _tokens(args, kwargs)
            if n < _MIN_TOKENS:
                return orig(self, *args, **kwargs)
            _state.update(active=True, sections={}, stack=[], chunk_t0=time.time())
            t0 = time.perf_counter()
            try:
                out = _timed(name, orig, self, args, kwargs)
            finally:
                _state["active"] = False
            _state["calls"].append({"tokens": n, "start": _state["chunk_t0"], "end": time.time(),
                                    "total_ms": (time.perf_counter() - t0) * 1000.0,
                                    "sections": _state["sections"]})
            _flush()
            return out
        if not _state["active"]:
            return orig(self, *args, **kwargs)
        return _timed(name, orig, self, args, kwargs)

    cls.__call__ = __call__
    _patched.add(cls)


def _register(module, name):
    _names[id(module)] = name
    _wrap(type(module))


def _modules(module):
    import mlx.nn as nn

    for key, value in module.children().items():
        if isinstance(value, nn.Module):
            yield key, value


def _instrument(loaded):
    root = loaded[0] if isinstance(loaded, tuple) else loaded
    text = None
    for path in ("language_model.model", "model", ""):
        obj = root
        for part in filter(None, path.split(".")):
            obj = getattr(obj, part, None)
        if obj is not None and isinstance(getattr(obj, "layers", None), list):
            text = obj
            break
    if text is None:
        _log("no decoder layers found; nothing timed")
        return
    _register(text, "model")
    for layer in text.layers:
        kind = "kda" if getattr(layer, "is_linear", False) else "mla"
        _register(layer, f"{kind}.layer")
        for key, child in _modules(layer):
            _register(child, f"{kind}.{key}")
            for sub, grand in _modules(child):
                _register(grand, f"{kind}.{key}.{sub}")
    _log(f"active pid={os.getpid()} layers={len(text.layers)} registered={len(_names)} out={_OUT}")


def _patch_loader(module):
    orig = getattr(module, "load_model", None)
    if orig is None or getattr(orig, "_section_hook", False):
        return

    def load_model(*args, **kwargs):
        loaded = orig(*args, **kwargs)
        try:
            _instrument(loaded)
        except Exception as exc:  # never break the server's load
            _log(f"instrument failed: {exc!r}")
        return loaded

    load_model._section_hook = True
    module.load_model = load_model


class _Finder(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path, target=None):
        if fullname not in _LOADERS:
            return None
        sys.meta_path.remove(self)
        try:
            spec = importlib.util.find_spec(fullname)
        finally:
            sys.meta_path.insert(0, self)
        if spec is None or spec.loader is None:
            return spec
        exec_module = spec.loader.exec_module

        def run(module):
            exec_module(module)
            _patch_loader(module)

        spec.loader.exec_module = run
        return spec


if _OUT:
    os.makedirs(_OUT, exist_ok=True)
    sys.meta_path.insert(0, _Finder())
