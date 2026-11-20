"""Continuous-batching accepted tuple for a `--no-join` serve of a snapshot with no CB policy entry.

job.sh copies a model's tuple from its signed continuous-batching-policy.json entry
(`cb_extra`). Qwen3.8-Flash-Next has no entry, so this computes the same fields the
provider computes for the tuple it requests (ModelRuntime.continuousBatchingRequestedTuple):

  model_id              the served catalog id (config `model`, run-grid --model-id)
  model_sha256          macprovider.snapshot-manifest.v1, the serve's verified model_artifact_sha256
  tokenizer_sha256      sha256 of "tokenizer_config.json\\0" + bytes, "tokenizer.json\\0" + bytes (those present)
  chat_template_sha256  sha256 of "<first of chat_template.jinja/.json/.txt>\\0" + bytes, else of
                        "chat_template\\0" + tokenizer_config.json's chat_template string
  cache_class           "mixed" (Qwen4-Exp: recurrent gated-delta layers plus pagedQwen4ExpKV)
  kv_dtype              fp16 (no kv_bits override)
  requires_moe          pagedKVConfigRequiresMoE on config.json
  hardware_class        "apple-silicon:<machdep.cpu.brand_string>:ram-<round(hw.memsize / GiB)>gb"
  metallib_sha256       sha256 of the mlx.metallib beside the binary
  kernel_identifier     PagedKVGatherKernel.registeredKernelName

In a `--no-join` serve the tuple grants cached turns before the self-check's own
cached-turn leg decides; batching itself is still the self-check's verdict.
The provider logs the identity it measured as one `[paged-kv] runtime-identity` line;
`check` compares it with the tuple, so a field computed differently here is reported,
not silently unmatched.

usage: qwen4_cb_tuple.py tuple --model-path DIR --model-id ID --model-sha256 SHA --metallib FILE
                               --yaml-out FILE --json-out FILE [--hardware-class HC]
       qwen4_cb_tuple.py check --tuple-json FILE --serve-err FILE
"""
import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys

KERNEL_IDENTIFIER = "macprovider_paged_kv_gather_v1"
CACHE_CLASS = "mixed"
KEYS = ("model_id", "model_sha256", "tokenizer_sha256", "chat_template_sha256", "cache_class", "kv_dtype",
        "requires_moe", "hardware_class", "metallib_sha256", "kernel_identifier", "cached_turns_accepted")


def tokenizer_hashes(root: pathlib.Path):
    def read(name):
        p = root / name
        return p.read_bytes() if p.is_file() else None

    config = b""
    for name in ("tokenizer_config.json", "tokenizer.json"):
        d = read(name)
        if d is not None:
            config += name.encode() + b"\0" + d
    config_sha = hashlib.sha256(config).hexdigest() if config else None
    template = None
    for name in ("chat_template.jinja", "chat_template.json", "chat_template.txt"):
        d = read(name)
        if d is not None:
            template = name.encode() + b"\0" + d
            break
    if template is None and read("tokenizer_config.json") is not None:
        t = json.loads(read("tokenizer_config.json")).get("chat_template")
        if isinstance(t, str):
            template = ("chat_template\0" + t).encode()
    return config_sha, hashlib.sha256(template).hexdigest() if template is not None else None


def requires_moe(config: dict) -> bool:
    labels = [config.get("model_type")] + list(config.get("architectures") or [])
    if any(isinstance(l, str) and "moe" in l.lower() for l in labels):
        return True
    keys = ("num_experts", "n_routed_experts", "num_local_experts", "num_experts_per_tok", "moe_intermediate_size")
    scopes = [config] + ([config["text_config"]] if isinstance(config.get("text_config"), dict) else [])
    return any(isinstance(s.get(k), (int, float)) and not isinstance(s.get(k), bool) and int(s[k]) > 1
               for s in scopes for k in keys)


def hardware_class() -> str:
    chip = subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True,
                          check=True).stdout.strip()
    mem = int(subprocess.run(["/usr/sbin/sysctl", "-n", "hw.memsize"], capture_output=True, text=True,
                             check=True).stdout.strip())
    return f"apple-silicon:{chip}:ram-{max(1, round(mem / 1024 ** 3))}gb"


def build(model_path, model_id, model_sha256, metallib, hw):
    root = pathlib.Path(model_path)
    tok, template = tokenizer_hashes(root)
    t = {"model_id": model_id, "model_sha256": model_sha256, "cache_class": CACHE_CLASS, "kv_dtype": "fp16",
         "requires_moe": requires_moe(json.loads((root / "config.json").read_text())), "hardware_class": hw,
         "metallib_sha256": hashlib.sha256(pathlib.Path(metallib).read_bytes()).hexdigest(),
         "kernel_identifier": KERNEL_IDENTIFIER, "cached_turns_accepted": True}
    if tok:
        t["tokenizer_sha256"] = tok
    if template:
        t["chat_template_sha256"] = template
    return t


def yaml_lines(t) -> str:
    fields = ", ".join(f"{k}: {json.dumps(t[k])}" for k in KEYS if k in t)
    return "continuous_batching: canary\ncontinuous_batching_accepted_tuples:\n  - {" + fields + "}\n"


RUNTIME = re.compile(r"\[paged-kv\] runtime-identity model=(?P<model_id>\S*) model_sha256=(?P<model_sha256>\S*) "
                     r"hardware_class=(?P<hardware_class>.*) metallib_sha256=(?P<metallib_sha256>\S*) "
                     r"kernel_identifier=(?P<kernel_identifier>\S*)$")


def check(t, serve_err_text):
    """The fields the runtime-identity line carries, tuple vs runtime; [] when they all match."""
    matches = [m for m in map(RUNTIME.search, serve_err_text.splitlines()) if m]
    if not matches:
        return None
    runtime = matches[-1].groupdict()
    return [(k, t[k], runtime[k]) for k in ("model_id", "model_sha256", "hardware_class", "metallib_sha256",
                                             "kernel_identifier") if t[k] != runtime[k]]


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("tuple")
    for f in ("--model-path", "--model-id", "--model-sha256", "--metallib", "--yaml-out", "--json-out"):
        a.add_argument(f, required=True)
    a.add_argument("--hardware-class")
    c = sub.add_parser("check")
    c.add_argument("--tuple-json", required=True)
    c.add_argument("--serve-err", required=True)
    args = ap.parse_args()
    if args.cmd == "tuple":
        t = build(args.model_path, args.model_id, args.model_sha256, args.metallib,
                  args.hardware_class or hardware_class())
        pathlib.Path(args.json_out).write_text(json.dumps(t, indent=2, sort_keys=True) + "\n")
        pathlib.Path(args.yaml_out).write_text(yaml_lines(t))
        print(json.dumps(t, sort_keys=True))
        return 0
    t = json.loads(pathlib.Path(args.tuple_json).read_text())
    diff = check(t, pathlib.Path(args.serve_err).read_text(errors="replace"))
    if diff is None:
        print("TUPLE_UNCHECKED no [paged-kv] runtime-identity line in the serve log (the paged engine did not attach)")
        return 1
    if diff:
        print("TUPLE_MISMATCH " + " ".join(f"{k}: tuple={a!r} runtime={b!r}" for k, a, b in diff))
        return 1
    print("TUPLE_MATCH model_sha256=%s hardware_class=%r kernel_identifier=%s" % (
        t["model_sha256"], t["hardware_class"], t["kernel_identifier"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
