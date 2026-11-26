#!/usr/bin/env python3
"""oMLX reference for the parity grid: an oMLX server on a loopback port, greedy, one row at a time.

usage: reference_omlx.py --omlx-dir DIR --model-path SNAPSHOT --model-name NAME --out ref.jsonl
                         [--grid grid.json] [--trials 3] [--rows 1,4] [--extra-row-trials 1]
                         [--max-context N] [--port 18350] [--state-root DIR] [--load-timeout 2400]
                         [--chat-template-kwargs JSON] [--first-chunk-tokens 1]
                         [--expect-commit SHA]

For model families no stock Python runtime decodes correctly (GLM-5.3-Flash
glm5_next oQ builds: stock mlx-vlm loads them and emits garbage), the
reference is an oMLX server (Apache-2.0), which carries its own glm5_next code.
Runs under the system python3 (stdlib only); oMLX runs from its own install:

  --omlx-dir DIR   DIR/omlx-venv/bin/{python,omlx} (an editable `pip install -e`
                   of DIR/omlx-src; DIR/omlx-src/OMLX_COMMIT names the commit
                   when the source is not a git checkout)

Steps, each failing loudly (`OmlxReferenceError: ...`, exit 1):
 1. refuse when anything listens on 8080 or --port, or another `omlx serve` runs;
 2. check `omlx serve --help` lists every flag used below; record versions from
    the venv (omlx, mlx, mlx-metal, mlx-lm, mlx-vlm, transformers, with git pins);
 3. a fresh state dir under --state-root (default DIR/omlx-state/parity-grid):
    HOME, TMPDIR, XDG, HF caches and the oMLX base path inside it (oMLX
    writes under Path.home() whatever --base-path says), with
    models/<model id> = a symlink to --model-path and a model_settings.json that
    pins the model and switches off MTP, VLM MTP, DFlash, SpecPrefill,
    TurboQuant KV and MoE expert offload;
 4. `omlx serve --headless --no-cache --no-hf-cache --memory-guard off
    --max-concurrent-requests 1 --sse-keepalive-mode off` on 127.0.0.1:--port in
    its own process group, offline; poll /health every 5 s until `healthy` with
    1 model discovered and 1 loaded (--load-timeout, default 2400 s), failing
    with the server log tail when the server exits or the time runs out; then
    /v1/models must list exactly this model and the saved model settings must
    still have every speculative path off;
 5. warm up, then the same jobs as reference_mlxlm.py (prompt row 0 `--trials`
    times per cell, rows 1..N-1 once for N-row cells), each a single streaming
    /v1/chat/completions request with the provider client's own code
    (provider_client.run_request) and the same messages; temperature 0 plus
    explicit neutral top_p/top_k/min_p/penalties, so model settings cannot
    change sampling (oMLX: request > model settings unless force_sampling);
 6. SIGTERM to the server's process group (SIGKILL after 180 s) and a check
    that the port is closed; the state dir is removed after a clean run and
    kept (path printed) after a failure.

Formulas (the same code as our provider's client, provider_client.row_record):
  completion_tokens, prompt_tokens = the final usage frame (never chunk counts)
  ttft_s      = t_first - t0, t0 the request start, t_first the arrival of the
                first SSE chunk with content or reasoning_content
  decode_tps  = (completion_tokens - F) / (t_last - t_first), F = --first-chunk-tokens
  request_tps = completion_tokens / (t_last - t0)
oMLX streams decode bursts (up to 64 steps or 0.1 s per chunk), not one token
per chunk. F = 1 because at commit c74f1b18 EngineCore._step_burst ends a
burst at a request's first generated output, so with MTP off the first chunk
carries one token; every later token arrives after t_first, as on our
provider's per-token stream. The server's own timings (usage
time_to_first_token, time_to_first_visible_token, generation_tokens_per_second)
are recorded beside ours: a visible TTFT later than the model TTFT means the
first chunk carried more than one token and decode_tps is slightly high.

The first output line is a `kind: meta` record: oMLX version and commit, the
venv's package versions, the server flags, the effective model settings, the
sampling fields sent and the formulas (`decode_formula`, `table_note`).
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import prompts  # noqa: E402
import provider_client  # noqa: E402
from reference_mlxlm import model_max_context, reference_jobs  # noqa: E402

DEFAULT_PORT = 18350
STOP_GRACE_S = 180
# Every speculative or memory-saving path off: the reference decodes plainly.
OFF_SETTINGS = {
    "is_pinned": True, "ttl_seconds": None, "mtp_enabled": False, "vlm_mtp_enabled": False,
    "dflash_enabled": False, "specprefill_enabled": False, "turboquant_kv_enabled": False,
    "moe_expert_offload_enabled": False,
}
# temperature 0 comes from run_request; the rest pins what model settings could set.
SAMPLING = {"top_p": 1.0, "top_k": 0, "min_p": 0.0, "repetition_penalty": 1.0,
            "presence_penalty": 0.0, "frequency_penalty": 0.0}
SERVE_FLAGS = ["--base-path", "--model-dir", "--host", "--port", "--headless", "--no-cache",
               "--no-hf-cache", "--memory-guard", "--max-concurrent-requests", "--sse-keepalive-mode",
               "--log-level"]
# Log lines that mean a speculative path ran although model settings say off.
SPECULATIVE_LOG = re.compile(r"MTP enabled for|DFlash (engine|drafter) (loaded|enabled)", re.I)

VERSION_PROBE = r'''
import json, sys, importlib.metadata as m
out = {"python": sys.version.split()[0]}
for d in ("omlx", "mlx", "mlx-metal", "mlx-lm", "mlx-vlm", "transformers"):
    try:
        out[d] = m.version(d)
        try:
            url = json.loads(m.distribution(d).read_text("direct_url.json") or "null")
        except Exception:
            url = None
        if url:
            out[d + "_direct_url"] = url
    except m.PackageNotFoundError:
        out[d] = None
try:
    from omlx.utils.model_loading import lightning_mtp_supported
    out["lightning_mtp_supported"] = bool(lightning_mtp_supported(sys.argv[1]))
except Exception as exc:
    out["lightning_mtp_supported"] = "unknown: %s" % exc
print(json.dumps(out))
'''


class OmlxReferenceError(Exception):
    """One-line reason; `detail` (e.g. a server log tail) is printed before it."""

    def __init__(self, msg, detail=None):
        super().__init__(msg)
        self.detail = detail


def layout(omlx_dir):
    """Paths of an oMLX install dir; raises when the venv is not there."""
    paths = {"python": os.path.join(omlx_dir, "omlx-venv", "bin", "python"),
             "omlx": os.path.join(omlx_dir, "omlx-venv", "bin", "omlx"),
             "src": os.path.join(omlx_dir, "omlx-src")}
    for key in ("python", "omlx"):
        if not os.access(paths[key], os.X_OK):
            raise OmlxReferenceError(f"no executable {paths[key]} (--omlx-dir must hold omlx-venv/bin/{key})")
    return paths


def model_id_of(name):
    """oMLX model id = the symlink name under --model-dir: a safe file name."""
    mid = re.sub(r"[^A-Za-z0-9._-]", "-", name).strip(".-")
    if not mid:
        raise OmlxReferenceError(f"model name {name!r} gives no usable oMLX model id")
    return mid


def model_settings_doc(model_id):
    return {"version": 2, "models": {model_id: dict(OFF_SETTINGS)}}


def settings_violations(doc, model_id):
    """Speculative settings that are not off in a saved model_settings.json document."""
    entry = ((doc or {}).get("models") or {}).get(model_id)
    if entry is None:
        return [f"model {model_id} missing from model_settings.json"]
    return [f"{k}={entry.get(k)!r}" for k, v in OFF_SETTINGS.items()
            if k.endswith("_enabled") and entry.get(k, False) != v]


def missing_flags(help_text):
    return [f for f in SERVE_FLAGS if f not in help_text]


def isolated_env(state):
    env = {k: os.environ[k] for k in ("PATH", "LANG", "LC_ALL", "USER", "LOGNAME") if k in os.environ}
    env.update({
        "HOME": os.path.join(state, "home"), "TMPDIR": os.path.join(state, "tmp"),
        "XDG_CACHE_HOME": os.path.join(state, "xdg-cache"), "XDG_CONFIG_HOME": os.path.join(state, "xdg-config"),
        "HF_HOME": os.path.join(state, "hf"), "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        "HF_HUB_DISABLE_TELEMETRY": "1", "DO_NOT_TRACK": "1", "PYTHONNOUSERSITE": "1",
        "PYTHONDONTWRITEBYTECODE": "1", "OMLX_BASE_PATH": os.path.join(state, "base"),
        "OMLX_HF_CACHE_ENABLED": "false", "OMLX_CACHE_ENABLED": "false", "OMLX_USAGE_HISTORY": "false",
        "OMLX_MARKITDOWN_ENABLED": "false",
    })
    return env


def serve_command(omlx_bin, state, port):
    return [omlx_bin, "serve", "--base-path", os.path.join(state, "base"),
            "--model-dir", os.path.join(state, "models"), "--host", "127.0.0.1", "--port", str(port),
            "--headless", "--no-cache", "--no-hf-cache", "--memory-guard", "off",
            "--max-concurrent-requests", "1", "--sse-keepalive-mode", "off", "--log-level", "info"]


def health_state(obj):
    """('healthy', models discovered, models loaded) from a /health body, or None."""
    if not isinstance(obj, dict):
        return None
    pool = obj.get("engine_pool") or {}
    return obj.get("status"), pool.get("model_count"), pool.get("loaded_count")


def listening(port, host="127.0.0.1"):
    with socket.socket() as s:
        s.settimeout(1.0)
        return s.connect_ex((host, port)) == 0


def get_json(port, path, timeout=10):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=timeout) as r:
        return json.loads(r.read().decode())


def tail(path, n=30):
    try:
        with open(path, errors="replace") as f:
            return "".join(f.readlines()[-n:])
    except OSError:
        return "(no log)"


def omlx_commit(versions, src):
    """oMLX commit: OMLX_COMMIT in the editable source dir, else its git HEAD, else None."""
    url = (versions.get("omlx_direct_url") or {}).get("url") or ""
    dirs = [url[len("file://"):]] if url.startswith("file://") else []
    dirs.append(src)
    for d in dirs:
        try:
            with open(os.path.join(d, "OMLX_COMMIT")) as f:
                sha = f.read().strip()
            if re.fullmatch(r"[0-9a-f]{40}", sha):
                return sha
        except OSError:
            pass
        try:
            sha = subprocess.run(["git", "-C", d, "rev-parse", "HEAD"], capture_output=True, text=True,
                                 timeout=10).stdout.strip()
            if re.fullmatch(r"[0-9a-f]{40}", sha):
                return sha
        except (OSError, subprocess.SubprocessError):
            pass
    return None


def omlx_record(res, base, first_chunk_tokens=1):
    """A reference row from a run_request result: the provider row schema with oMLX's usage extras."""
    rec = provider_client.row_record(res, base, first_chunk_tokens)
    for key in ("generated_completion_tokens", "provider_generation_ms", "_t_first", "_t_last"):
        rec.pop(key, None)
    usage = res.get("usage") or {}
    rec["cached_prompt_tokens"] = (usage.get("prompt_tokens_details") or {}).get("cached_tokens")
    rec["reasoning_tokens"] = (usage.get("completion_tokens_details") or {}).get("reasoning_tokens")
    rec["omlx_server_ttft_s"] = usage.get("time_to_first_token")
    rec["omlx_server_visible_ttft_s"] = usage.get("time_to_first_visible_token")
    rec["omlx_generation_tps"] = usage.get("generation_tokens_per_second")
    ct, chunks = rec.get("completion_tokens"), rec.get("chunks")
    rec["tokens_per_chunk"] = round(ct / chunks, 2) if ct and chunks else None
    return rec


def decode_formula(first_chunk_tokens):
    return (f"decode_tps = (usage.completion_tokens - {first_chunk_tokens}) / (t_last - t_first); "
            "t_first/t_last = arrival of the first/last SSE chunk with content or reasoning_content; "
            "ttft_s = t_first - request start; request_tps = completion_tokens / (t_last - request start)")


def table_note(first_chunk_tokens):
    return (f"Reference = oMLX over loopback HTTP, the same client code as our provider. oMLX streams "
            f"bursts of several tokens per SSE chunk; its decode tok/s = (completion_tokens - "
            f"{first_chunk_tokens}) / (last chunk - first chunk), our provider's = (completion_tokens - 1) "
            f"/ (last token - first token). Comparable while oMLX's first chunk holds {first_chunk_tokens} "
            "token(s) (its burst rule; check omlx_server_visible_ttft_s = omlx_server_ttft_s in "
            "reference.jsonl). TTFT on both sides = first content/reasoning delta - request start.")


class Server:
    """One oMLX server in its own process group."""

    def __init__(self, cmd, env, cwd, log_path, port):
        self.port = port
        self.log_path = log_path
        self.log = open(log_path, "ab")
        self.proc = subprocess.Popen(cmd, env=env, cwd=cwd, stdout=self.log, stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True)

    def alive(self):
        return self.proc.poll() is None

    def wait_ready(self, timeout, poll=5.0, clock=time.monotonic, sleep=time.sleep):
        deadline = clock() + timeout
        last = None
        while True:
            if not self.alive():
                raise OmlxReferenceError(f"oMLX server exited during load (rc={self.proc.returncode})",
                                         tail(self.log_path))
            try:
                last = health_state(get_json(self.port, "/health", timeout=5))
            except (OSError, ValueError, urllib.error.URLError):
                last = None
            if last and last[0] == "healthy":
                if last[1:] == (1, 1):
                    return
                if last[1] != 1:
                    raise OmlxReferenceError(f"oMLX is healthy but discovered {last[1]} models, want 1")
            if clock() >= deadline:
                raise OmlxReferenceError(f"oMLX not ready after {timeout:.0f} s (last /health {last})",
                                         tail(self.log_path))
            sleep(poll)

    def stop(self):
        """SIGTERM the process group, SIGKILL after STOP_GRACE_S; True when the port is closed after."""
        if self.alive():
            try:
                os.killpg(self.proc.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                self.proc.wait(STOP_GRACE_S)
            except subprocess.TimeoutExpired:
                print(f"oMLX server ignored SIGTERM for {STOP_GRACE_S} s; SIGKILL", file=sys.stderr)
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                self.proc.wait(30)
        # Children left in the group (workers) go too; the group is ours alone.
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        self.log.close()
        for _ in range(20):
            if not listening(self.port):
                return True
            time.sleep(0.5)
        return False


def preflight(port, omlx_bin, env, live_port=8080):
    if port == live_port:
        raise OmlxReferenceError(f"--port {live_port} is the live provider's port")
    if listening(live_port):
        raise OmlxReferenceError(f"a server listens on {live_port} (the live provider's port); refusing")
    if listening(port):
        raise OmlxReferenceError(f"port {port} is busy; refusing")
    others = subprocess.run(["pgrep", "-fl", "omlx serve"], capture_output=True, text=True).stdout.strip()
    if others:
        raise OmlxReferenceError(f"another omlx server runs: {others.splitlines()[0]}")
    try:
        helptext = subprocess.run([omlx_bin, "serve", "--help"], capture_output=True, text=True, env=env,
                                  timeout=300).stdout
    except (OSError, subprocess.SubprocessError) as exc:
        raise OmlxReferenceError(f"`omlx serve --help` failed: {exc}")
    gone = missing_flags(helptext)
    if gone:
        raise OmlxReferenceError(f"`omlx serve --help` lacks {' '.join(gone)}: not the expected oMLX CLI")


def run(args):
    paths = layout(args.omlx_dir)
    if not os.path.isfile(os.path.join(args.model_path, "config.json")):
        raise OmlxReferenceError(f"no config.json in --model-path {args.model_path}")
    model_id = model_id_of(args.model_name)
    root = args.state_root or os.path.join(args.omlx_dir, "omlx-state", "parity-grid")
    state = os.path.join(root, time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}")
    if os.path.exists(state):
        raise OmlxReferenceError(f"state dir {state} exists")
    print(f"omlx state dir {state}", file=sys.stderr)
    for sub in ("home", "tmp", "xdg-cache", "xdg-config", "hf", "base", "models", "run"):
        os.makedirs(os.path.join(state, sub))
    os.symlink(os.path.realpath(args.model_path), os.path.join(state, "models", model_id))
    with open(os.path.join(state, "base", "model_settings.json"), "w") as f:
        json.dump(model_settings_doc(model_id), f, indent=1)
    env = isolated_env(state)
    preflight(args.port, paths["omlx"], env, args.live_port)

    probe = subprocess.run([paths["python"], "-I", "-c", VERSION_PROBE, args.model_path], capture_output=True,
                           text=True, env=env, timeout=600)
    try:
        versions = json.loads(probe.stdout.strip().splitlines()[-1])
    except (ValueError, IndexError):
        raise OmlxReferenceError(f"version probe failed: {(probe.stderr or probe.stdout).strip()[-400:]}")
    if not versions.get("omlx"):
        raise OmlxReferenceError("the oMLX venv has no `omlx` package")
    commit = omlx_commit(versions, paths["src"])
    if args.expect_commit and commit != args.expect_commit:
        raise OmlxReferenceError(f"oMLX commit {commit} is not --expect-commit {args.expect_commit}")
    print(f"omlx {versions['omlx']} commit {commit} mlx {versions.get('mlx')} mlx-lm {versions.get('mlx-lm')} "
          f"mlx-vlm {versions.get('mlx-vlm')}", file=sys.stderr)

    out_dir = os.path.dirname(os.path.abspath(args.out))
    eff = os.path.join(out_dir, "omlx-effective")
    os.makedirs(eff, exist_ok=True)
    log_path = os.path.join(out_dir, "omlx-server.log")
    cmd = serve_command(paths["omlx"], state, args.port)
    server_env = dict(env)
    for kv in args.server_env or []:
        key, sep, value = kv.partition("=")
        if not sep or not key:
            raise OmlxReferenceError(f"--server-env {kv!r} is not KEY=VALUE")
        server_env[key] = value
    t = time.perf_counter()
    server = Server(cmd, server_env, os.path.join(state, "run"), log_path, args.port)
    try:
        server.wait_ready(args.load_timeout, poll=args.poll_seconds)
        load_s = round(time.perf_counter() - t, 2)
        snap = {}
        for path in ("/health", "/v1/models", "/v1/models/status"):
            try:
                snap[path] = get_json(args.port, path)
            except (OSError, ValueError, urllib.error.URLError) as exc:
                snap[path] = {"error": str(exc)}
            with open(os.path.join(eff, path.strip("/").replace("/", "_") + ".json"), "w") as f:
                json.dump(snap[path], f, indent=1)
        ids = [m.get("id") for m in (snap["/v1/models"].get("data") or [])] if "data" in snap["/v1/models"] else None
        if ids != [model_id]:
            raise OmlxReferenceError(f"/v1/models lists {ids}, want [{model_id!r}]")
        try:
            with open(os.path.join(state, "base", "model_settings.json")) as f:
                effective = json.load(f)
        except (OSError, ValueError) as exc:
            raise OmlxReferenceError(f"cannot read the saved model settings: {exc}")
        with open(os.path.join(eff, "model_settings.after-load.json"), "w") as f:
            json.dump(effective, f, indent=1)
        bad = settings_violations(effective, model_id)
        if bad:
            raise OmlxReferenceError(f"oMLX turned on what the reference needs off: {', '.join(bad)}")

        grid = prompts.load_grid(args.grid)
        if args.rows:
            grid["rows"] = [int(x) for x in args.rows.split(",")]
        trials = args.trials or grid.get("trials", 3)
        cells = prompts.expand_cells(grid, args.max_context or model_max_context(args.model_path))
        extra = dict(SAMPLING)
        if args.chat_template_kwargs:
            extra["chat_template_kwargs"] = json.loads(args.chat_template_kwargs)

        warm = provider_client.run_request(args.port, model_id, prompts.build_messages(200, 9999),
                                           grid.get("warmup_tokens", 32), extra=extra)
        if warm.get("error"):
            raise OmlxReferenceError(f"warmup failed: {warm['error']}")

        failures = 0
        with open(args.out, "a") as out:
            out.write(json.dumps({
                "side": "reference", "kind": "meta", "reference": "omlx", "model": args.model_name,
                "model_path": args.model_path, "omlx_model_id": model_id, "load_s": load_s,
                "omlx_version": versions.get("omlx"), "omlx_commit": commit, "versions": versions,
                "serve_command": cmd[1:], "port": args.port, "model_settings": effective["models"][model_id],
                "mtp": "off (mtp_enabled, vlm_mtp_enabled, dflash_enabled false; checked after load)",
                "request_fields": {"temperature": 0, **extra, "stream": True,
                                   "stream_options": {"include_usage": True}},
                "first_chunk_tokens": args.first_chunk_tokens,
                "decode_formula": decode_formula(args.first_chunk_tokens),
                "table_note": table_note(args.first_chunk_tokens),
            }) + "\n")
            for (ctx, max_tokens, prow), n in reference_jobs(cells, trials, args.extra_row_trials):
                messages = prompts.build_messages(ctx, prow)
                for trial in range(n):
                    if not server.alive():
                        raise OmlxReferenceError(f"oMLX server died (rc={server.proc.returncode})", tail(log_path))
                    res = provider_client.run_request(args.port, model_id, messages, max_tokens, extra=extra)
                    base = {"side": "reference", "reference": "omlx", "kind": "row", "model": args.model_name,
                            "cell": prompts.cell_key(args.model_name, ctx, max_tokens, 1), "ctx_target": ctx,
                            "max_tokens": max_tokens, "rows": 1, "row": prow, "trial": trial, "load_s": load_s}
                    rec = omlx_record(res, base, args.first_chunk_tokens)
                    rec["sha256"] = hashlib.sha256(rec["text"].encode()).hexdigest()
                    out.write(json.dumps(rec) + "\n")
                    out.flush()
                    failures += rec["error"] is not None
                    print(f"ref ctx={ctx} out={max_tokens} row={prow} trial={trial} tps={rec['decode_tps']} "
                          f"req_tps={rec['request_tps']} n={rec['completion_tokens']} chunks={rec['chunks']} "
                          f"finish={rec['finish']} error={rec['error']}", file=sys.stderr)
        spec = [ln.strip() for ln in tail(log_path, 10 ** 6).splitlines() if SPECULATIVE_LOG.search(ln)]
        if spec:
            raise OmlxReferenceError(f"oMLX log shows a speculative path on: {spec[0][:300]}")
        if failures:
            raise OmlxReferenceError(f"{failures} reference request(s) failed; see the error fields in {args.out}")
    finally:
        closed = server.stop()
        if not closed:
            print(f"port {args.port} still listens after the oMLX server was stopped", file=sys.stderr)
    if not closed:
        raise OmlxReferenceError(f"port {args.port} still listens after the oMLX server was stopped")
    shutil.rmtree(state, ignore_errors=True)
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--omlx-dir", required=True)
    ap.add_argument("--model-path", required=True)
    ap.add_argument("--model-name", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--grid", default=os.path.join(HERE, "grid.json"))
    ap.add_argument("--trials", type=int)
    ap.add_argument("--rows", help="comma list overriding grid rows, e.g. 1,4")
    ap.add_argument("--extra-row-trials", type=int, default=1)
    ap.add_argument("--max-context", type=int)
    ap.add_argument("--port", type=int, default=DEFAULT_PORT)
    ap.add_argument("--state-root", help="parent of the fresh per-run oMLX state dir "
                    "(default: OMLX_DIR/omlx-state/parity-grid)")
    ap.add_argument("--load-timeout", type=float, default=2400)
    ap.add_argument("--chat-template-kwargs", help="JSON object sent as chat_template_kwargs (default: none)")
    ap.add_argument("--first-chunk-tokens", type=int, default=1)
    ap.add_argument("--expect-commit", help="fail unless the oMLX source is at this commit")
    ap.add_argument("--server-env", action="append", metavar="KEY=VALUE",
                    help="extra environment for the oMLX server only (repeatable), e.g. a profiling hook")
    ap.add_argument("--live-port", type=int, default=8080, help=argparse.SUPPRESS)  # tests only
    ap.add_argument("--poll-seconds", type=float, default=5.0, help=argparse.SUPPRESS)  # tests only
    args = ap.parse_args(argv)
    try:
        return run(args)
    except OmlxReferenceError as exc:
        if exc.detail:
            print(exc.detail.rstrip(), file=sys.stderr)
        print(f"OmlxReferenceError: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
