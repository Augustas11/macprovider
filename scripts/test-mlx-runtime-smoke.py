#!/usr/bin/env python3
"""Run local no-join model smokes against malibu-cli.

The script starts one provider per model, waits for /v1/models, then verifies
non-streaming and streaming chat completions before terminating the provider.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


STOP_TOKENS = ("<|eot_id|>", "<|end_header_id|>", "<|start_header_id|>")


def request_json(url: str, timeout: float = 5.0) -> dict | None:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as response:
            return json.loads(response.read())
    except Exception:
        return None


def post_chat(url: str, payload: dict, timeout: float) -> tuple[int, float, dict]:
    start = time.time()
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return response.status, time.time() - start, json.loads(response.read())


def post_stream(url: str, payload: dict, timeout: float) -> tuple[int, float, float | None, str, dict | None, bool]:
    stream_payload = dict(payload)
    stream_payload["stream"] = True
    req = urllib.request.Request(
        url,
        data=json.dumps(stream_payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    start = time.time()
    first = None
    chunks: list[str] = []
    usage = None
    done = False
    with urllib.request.urlopen(req, timeout=timeout) as response:
        status = response.status
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line or not line.startswith("data: "):
                continue
            data = line[6:]
            if data == "[DONE]":
                done = True
                continue
            if first is None:
                first = time.time()
            event = json.loads(data)
            if event.get("usage"):
                usage = event["usage"]
            for choice in event.get("choices", []):
                content = (choice.get("delta") or {}).get("content")
                if content:
                    chunks.append(content)
    return status, time.time() - start, (first - start if first else None), "".join(chunks), usage, done


def terminate(process: subprocess.Popen) -> None:
    if process.poll() is not None:
        return
    process.send_signal(signal.SIGINT)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def smoke_model(args: argparse.Namespace, model: str) -> dict:
    log_path = Path(tempfile.mkstemp(prefix="mlx-runtime-smoke-", suffix=".log")[1])
    log_file = log_path.open("wb")
    command = [
        str(args.binary),
        "serve",
        "--no-join",
        "--model",
        model,
        "--port",
        str(args.port),
        "--max-context",
        str(args.max_context),
    ]
    process = subprocess.Popen(command, stdout=log_file, stderr=subprocess.STDOUT, cwd=args.cwd)
    started = time.time()
    result: dict = {
        "model": model,
        "port": args.port,
        "max_context": args.max_context,
        "log_path": str(log_path),
    }
    try:
        models_url = f"http://127.0.0.1:{args.port}/v1/models"
        deadline = started + args.startup_timeout
        ready_body = None
        while time.time() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"provider exited during startup with code {process.returncode}")
            ready_body = request_json(models_url)
            if ready_body:
                ids = [item.get("id") for item in ready_body.get("data", [])]
                if model in ids:
                    break
            time.sleep(2)
        else:
            raise RuntimeError(f"provider did not become ready within {args.startup_timeout}s")

        result["startup_seconds"] = round(time.time() - started, 3)
        result["models_response"] = ready_body

        chat_url = f"http://127.0.0.1:{args.port}/v1/chat/completions"
        payload = {
            "model": model,
            "messages": [
                {"role": "user", "content": "Answer in one short sentence: what color is a ripe banana?"}
            ],
            "max_tokens": args.max_tokens,
            "temperature": 0,
        }
        status, elapsed, body = post_chat(chat_url, payload, args.request_timeout)
        content = body["choices"][0]["message"].get("content", "")
        usage = body.get("usage", {})
        result["non_stream"] = {
            "http_status": status,
            "elapsed_seconds": round(elapsed, 3),
            "finish_reason": body["choices"][0].get("finish_reason"),
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
            "nonempty": bool(content.strip()),
            "stop_leak": any(token in content for token in STOP_TOKENS),
            "content": content.strip(),
        }

        status, elapsed, ttft, content, usage, done = post_stream(chat_url, payload, args.request_timeout)
        result["stream"] = {
            "http_status": status,
            "elapsed_seconds": round(elapsed, 3),
            "ttft_seconds": round(ttft, 3) if ttft is not None else None,
            "done": done,
            "terminal_usage": usage is not None,
            "prompt_tokens": (usage or {}).get("prompt_tokens"),
            "completion_tokens": (usage or {}).get("completion_tokens"),
            "total_tokens": (usage or {}).get("total_tokens"),
            "nonempty": bool(content.strip()),
            "stop_leak": any(token in content for token in STOP_TOKENS),
            "content": content.strip(),
        }
        result["ok"] = (
            result["non_stream"]["http_status"] == 200
            and result["non_stream"]["nonempty"]
            and not result["non_stream"]["stop_leak"]
            and result["stream"]["http_status"] == 200
            and result["stream"]["done"]
            and result["stream"]["terminal_usage"]
            and result["stream"]["nonempty"]
            and not result["stream"]["stop_leak"]
        )
        return result
    except Exception as exc:
        result["ok"] = False
        result["error"] = str(exc)
        tail = ""
        try:
            log_file.flush()
            tail = "\n".join(log_path.read_text(errors="replace").splitlines()[-40:])
        except Exception:
            pass
        if tail:
            result["log_tail"] = tail
        return result
    finally:
        terminate(process)
        log_file.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--cwd", type=Path, default=Path.cwd())
    parser.add_argument("--port", type=int, default=18080)
    parser.add_argument("--max-context", type=int, default=512)
    parser.add_argument("--max-tokens", type=int, default=24)
    parser.add_argument("--startup-timeout", type=float, default=900)
    parser.add_argument("--request-timeout", type=float, default=180)
    parser.add_argument("models", nargs="+")
    args = parser.parse_args()

    if not args.binary.exists():
        parser.error(f"missing binary: {args.binary}")
    failures = 0
    for model in args.models:
        result = smoke_model(args, model)
        print(json.dumps(result, sort_keys=True), flush=True)
        if not result.get("ok"):
            failures += 1
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
