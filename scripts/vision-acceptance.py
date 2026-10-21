#!/usr/bin/env python3
"""Bounded native-image HTTP acceptance. Requires the designated Studio.

This emits observations, never a qualification, release approval, or live proof.
Only Python's standard library is used. No raw request/response content is logged.
"""

import argparse
import base64
import hashlib
import http.client
import json
import os
import platform
import re
import shlex
import struct
import subprocess
import sys
import time
import urllib.parse
import zlib
from pathlib import Path


MODEL = "mlx-community/Qwen2-VL-2B-Instruct-4bit"
REVISION = "01af461cdb9574acc09084a0ef94e216e142b085"
RUNTIME_REVISION = "3052bf40fed485c6d6ff1a6792dd6b10d03b4562"
PROFILE = "qwen2vl-inline-v1"
# A model name no provider loads: the provider-local endpoint must refuse it by
# name (404 model_not_found). That proves model lookup only, never media
# rejection; the text-only provider suite proves that.
UNLOADED_MODEL = "macprovider-acceptance/unloaded-model-name"
MAX_RESPONSE = 256 * 1024


class AcceptanceError(Exception):
    """Safe diagnostic; must never contain response bodies or credentials."""


def require(condition, message):
    if not condition:
        raise AcceptanceError(message)


def command(*args):
    try:
        return subprocess.check_output(args, timeout=15, stderr=subprocess.DEVNULL).decode().strip()
    except (OSError, subprocess.SubprocessError):
        raise AcceptanceError("host or process verification command failed") from None


def endpoint(value):
    parsed = urllib.parse.urlsplit(value)
    require(parsed.scheme == "http" and parsed.hostname in ("127.0.0.1", "::1"),
            "only numeric HTTP loopback endpoints are permitted")
    require(not parsed.username and not parsed.password and not parsed.query and not parsed.fragment,
            "endpoint credentials, query and fragments are forbidden")
    require(parsed.path in ("", "/"), "endpoint must be an origin without a path")
    try:
        port = parsed.port
    except ValueError:
        raise AcceptanceError("invalid endpoint port") from None
    require(port is not None and 1024 <= port <= 65535 and port != 8080,
            "an explicit isolated unprivileged port other than 8080 is required")
    return parsed.hostname, port


def verify_host(expected_name):
    require(platform.system() == "Darwin", "hardware acceptance requires the designated Mac Studio")
    host = command("/bin/hostname")
    model = command("/usr/sbin/sysctl", "-n", "hw.model")
    require(model != "Mac17,3" and "augustas-air" not in host.lower(),
            "operator Mac hardware workloads are prohibited")
    require(model == "Mac15,14", "hardware model does not match the designated Studio")
    require(expected_name and host == expected_name, "designated host identity did not match")
    hardware = json.loads(command("/usr/sbin/system_profiler", "SPHardwareDataType", "-json"))
    rows = hardware.get("SPHardwareDataType", [])
    require(len(rows) == 1 and rows[0].get("machine_name") == "Mac Studio",
            "hardware identity is not a Mac Studio")
    # Do not publish hostname, serial number, UUID, or operator inventory.
    return {"designated_studio_verified": True}


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def option(argv, name):
    values = []
    for index, argument in enumerate(argv):
        if argument.startswith(name + "="):
            values.append(argument[len(name) + 1:])
        elif argument == name and index + 1 < len(argv):
            values.append(argv[index + 1])
    require(len(values) == 1, "candidate requires one explicit " + name + " argument")
    return values[0]


def verify_isolation(argv, coordinator_url):
    if coordinator_url:
        parsed = urllib.parse.urlsplit(coordinator_url)
        require(parsed.scheme == "ws", "local coordinator must use a loopback WebSocket URL")
        # Check the same strict origin policy without forwarding any path/query.
        endpoint(urllib.parse.urlunsplit(("http", parsed.netloc, "", parsed.query, parsed.fragment)))
        require("--isolate-lifecycle" in argv and "--no-join" not in argv
                and "--autotune-candidate" not in argv,
                "joined local candidate requires isolated lifecycle")
        require(option(argv, "--coordinator") == coordinator_url,
                "candidate coordinator argument does not match the isolated local target")
        require(option(argv, "--credential-store") == "protected_file",
                "joined local candidate requires protected_file credentials")
    else:
        require("--no-join" in argv and "--autotune-candidate" in argv,
                "candidate must run with --no-join and --autotune-candidate")


def verify_process(url, pid, args):
    """The process listening alone on URL's port is PID, runs the digest-
    verified candidate binary, and carries the isolation arguments."""
    _, port = endpoint(url)
    binary = Path(args.candidate_binary).resolve(strict=True)
    argv = shlex.split(command("/bin/ps", "-p", str(pid), "-o", "command="))
    require(argv and Path(argv[0]).resolve() == binary, "process executable did not match the verified candidate")
    verify_isolation(argv, args.coordinator_url)
    listeners = command("/usr/sbin/lsof", "-nP", "-iTCP:" + str(port), "-sTCP:LISTEN", "-Fp")
    pids = {int(line[1:]) for line in listeners.splitlines() if line.startswith("p")}
    require(pids == {pid}, "isolated port is not owned solely by the verified process")


def verify_candidate(args):
    binary = Path(args.candidate_binary).resolve(strict=True)
    require(sha256_file(binary) == args.candidate_sha256, "candidate binary digest did not match")
    require(re.fullmatch(r"[0-9a-f]{40}", args.source_commit) is not None,
            "source commit must be a full Git SHA")
    verify_process(args.provider_url, args.candidate_pid, args)
    # The text-only provider is a second process of the same verified binary
    # with the text-only model loaded, on its own isolated port.
    require(args.text_only_pid != args.candidate_pid, "the text-only provider must be a separate process")
    verify_process(args.text_only_provider_url, args.text_only_pid, args)
    return {"candidate_binary_sha256": args.candidate_sha256,
            "source_commit_operator_assertion": args.source_commit,
            "candidate_process_and_isolation_verified": True,
            "text_only_process_and_isolation_verified": True}


def png(rgb, width=96, height=96, declared_size=None, scanlines=None):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    w, h = declared_size or (width, height)
    if scanlines is None:
        scanlines = (b"\0" + bytes(rgb) * width) * height
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scanlines, 9)) + chunk(b"IEND", b""))


def circle_png(rgb, size=224, radius=80):
    """Filled circle of rgb on white. Small VLMs read this reliably; they do not
    read uniform solid-colour images."""
    centre = (size - 1) / 2
    white, fill = b"\xff\xff\xff", bytes(rgb)
    rows = []
    for y in range(size):
        rows.append(b"\0" + b"".join(
            fill if (x - centre) ** 2 + (y - centre) ** 2 <= radius ** 2 else white for x in range(size)))
    return png(rgb, size, size, scanlines=b"".join(rows))


def image(data=None, url=None):
    return {"type": "image_url", "image_url": {"url": url or
            "data:image/png;base64," + base64.b64encode(data).decode()}}


def text(value):
    return {"type": "text", "text": value}


def request(parts, stream=False, model=MODEL, max_tokens=64, system=None):
    messages = [{"role": "user", "content": parts}]
    if system is not None:
        messages.insert(0, {"role": "system", "content": system})
    return {"model": model, "messages": messages,
            "temperature": 0, "max_tokens": max_tokens, "stream": stream}


# Image-only user turns carry no question, and a small VLM asked nothing
# answers with a clarification request. The instruction lives in a system
# turn so the user turn stays image-only while the answer is checkable.
IMAGE_ONLY_SYSTEM = "When the user sends an image, reply with only the name of its dominant color."


def response_chunks(response, deadline):
    total = 0
    while True:
        require(time.monotonic() < deadline, "response deadline exceeded")
        chunk = response.read1(8192)
        if not chunk:
            return
        total += len(chunk)
        require(total <= MAX_RESPONSE, "response exceeded the bounded capture limit")
        yield chunk


def post(origin, path, payload, token, stream=False, disconnect=False):
    host, port = endpoint(origin)
    connection = http.client.HTTPConnection(host, port, timeout=90)
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    try:
        deadline = time.monotonic() + 120
        connection.request("POST", path, json.dumps(payload), headers)
        response = connection.getresponse()
        require(not 300 <= response.status < 400, "redirects are forbidden")
        if response.status != 200 or not stream:
            body = b"".join(response_chunks(response, deadline))
            try:
                data = json.loads(body)
            except (ValueError, UnicodeError):
                raise AcceptanceError("response was not valid JSON") from None
            return response.status, data
        require(response.getheader("Content-Type", "").startswith("text/event-stream"),
                "streaming response did not use SSE")
        pieces, done, pending = [], False, b""
        for chunk in response_chunks(response, deadline):
            pending += chunk
            while b"\n" in pending:
                line, pending = pending.split(b"\n", 1)
                require(len(line) <= 16384, "SSE line limit exceeded")
                if not line.startswith(b"data: "):
                    continue
                value = line[6:].strip()
                if value == b"[DONE]":
                    done = True
                    break
                data = json.loads(value)
                require("error" not in data, "stream contained an error")
                for choice in data.get("choices", []):
                    content = choice.get("delta", {}).get("content")
                    if content:
                        pieces.append(content)
                        if disconnect:
                            return 200, {"disconnected_after_content": True}
            require(len(pending) <= 16384, "SSE line limit exceeded")
            if done:
                break
        require(done and pieces, "stream lacked content or completion marker")
        return 200, {"choices": [{"message": {"content": "".join(pieces)}}]}
    finally:
        connection.close()


def answer(result):
    status, data = result
    require(status == 200, "expected successful Chat Completions response")
    try:
        content = data["choices"][0]["message"]["content"]
    except (KeyError, IndexError, TypeError):
        raise AcceptanceError("completion content was missing") from None
    require(isinstance(content, str) and content.strip(), "completion content was empty")
    return content.lower()


def check_labels(content, expected):
    labels = re.findall(r"\b(?:red|blue)\b", content)
    require(labels == expected, "image-dependent color labels or ordering did not match")


def check_rejection(path, status, data, kind="media"):
    """kind "media": invalid media on the vision endpoint. The native provider
    does not mount either facade: an absent facade is an explicit rejection,
    a missing Chat Completions route is a failure.
    kind "unknown_model": a model name nobody loads; only a structured 404
    model_not_found passes (model lookup, not media handling).
    kind "text_only_media": media sent to a loaded text-only model; a
    structured 4xx refusal before inference, never 404 or model_not_found."""
    require(isinstance(data, dict) and isinstance(data.get("error"), dict),
            "rejection did not contain a structured error")
    code = data["error"].get("code")
    if kind == "unknown_model":
        require(status == 404 and code == "model_not_found",
                "unknown model name was not an explicit 404 model_not_found rejection")
        return
    if kind == "text_only_media":
        require(400 <= status < 500 and status != 404 and code != "model_not_found",
                "text-only model did not reject media before inference (a model lookup failure does not count)")
        return
    allowed = (400, 413, 415, 422)
    if path in ("/v1/responses", "/v1/messages"):
        allowed += (404,)
    require(status in allowed, "invalid media was not explicitly rejected before serving")


def run_suite(origin, token, unsupported_model, gateway=False):
    results = []
    red, blue = image(circle_png((255, 0, 0))), image(circle_png((0, 0, 255)))
    question = text("What is the dominant color of this image? Answer with only the color name.")

    def success(name, parts, labels=None, streaming=False):
        started = time.monotonic()
        content = answer(post(origin, "/v1/chat/completions", request(parts, streaming), token,
                              stream=streaming))
        if labels is not None:
            check_labels(content, labels)
        results.append({"case": name, "passed": True, "elapsed_seconds": round(time.monotonic() - started, 3)})

    def rejection(name, payload, path="/v1/chat/completions", kind="media"):
        status, data = post(origin, path, payload, token)
        check_rejection(path, status, data, kind)
        results.append({"case": name, "passed": True, "status": status})

    for streaming in (False, True):
        suffix = "stream" if streaming else "nonstream"
        success("paired_red_" + suffix, [question, red], ["red"], streaming)
        success("paired_blue_" + suffix, [question, blue], ["blue"], streaming)
        # Image-only user turns, one per color, so the answer must come from the image.
        for label, image_part in (("red", red), ("blue", blue)):
            content = answer(post(origin, "/v1/chat/completions",
                                  request([image_part], streaming, system=IMAGE_ONLY_SYSTEM), token, stream=streaming))
            check_labels(content, [label])
            results.append({"case": "image_only_" + label + "_" + suffix, "passed": True})
        order = text("Name the color of image 1, then image 2. Output two color names.")
        success("multiple_red_blue_" + suffix,
                [text("Image 1:"), red, text("Image 2:"), blue, order], ["red", "blue"], streaming)
        success("multiple_blue_red_" + suffix,
                [text("Image 1:"), blue, text("Image 2:"), red, order], ["blue", "red"], streaming)
    success("text_only", "Reply with hello.")
    if gateway:
        # The coordinator knows the text-only model and must refuse its media
        # with a 400-class rejection, never a 404.
        rejection("unsupported_model_mixed", request([question, red], model=unsupported_model))
    else:
        # A provider-local endpoint serves one model and refuses any other name.
        rejection("unloaded_model_name", request([question, red], model=UNLOADED_MODEL), kind="unknown_model")
    rejection("remote_url", request([question, image(url="https://example.invalid/image.png")]))
    rejection("malformed_base64", request([image(url="data:image/png;base64,!!!")]))
    rejection("unsupported_format", request([image(url="data:image/gif;base64,R0lGODlh")]))
    rejection("truncated_image", request([image(png((255, 0, 0))[:40])]))
    rejection("excessive_count", request([red, blue, red]))
    rejection("excessive_encoded_bytes", request([image(b"x" * (1024 * 1024 + 1))]))
    rejection("excessive_dimension", request([image(png((255, 0, 0), 2049, 1))]))
    rejection("excessive_aggregate_pixels", request([
        image(png((255, 0, 0), 2048, 2048)), image(png((0, 0, 255), 2048, 2048))]))
    rejection("decompression_bomb_header", request([image(png((255, 0, 0), declared_size=(100000, 100000)))]))
    rejection("responses_media", {"model": MODEL, "input": [{"role": "user", "content": [
        {"type": "input_image", "image_url": red["image_url"]["url"]}]}]}, "/v1/responses")
    rejection("messages_media", {"model": MODEL, "max_tokens": 32, "messages": [{"role": "user", "content": [
        {"type": "image", "source": {"type": "base64", "media_type": "image/png",
         "data": red["image_url"]["url"].split(",", 1)[1]}}]}]}, "/v1/messages")
    status, data = post(origin, "/v1/chat/completions", request([question, red], True, max_tokens=256),
                        token, stream=True, disconnect=True)
    require(status == 200 and data.get("disconnected_after_content"), "disconnect was not exercised")
    results.append({"case": "disconnect_after_content", "passed": True})
    for index in range(3):
        success("recovery_repeat_" + str(index), [question, blue], ["blue"])
    return results


def run_text_only_suite(origin, token, model):
    """A provider with only the text-only model loaded refuses mixed and
    image-only input before inference, then still serves text."""
    red = image(circle_png((255, 0, 0)))
    question = text("What is the dominant color of this image? Answer with only the color name.")
    results = []
    for name, parts in (("text_only_provider_mixed", [question, red]), ("text_only_provider_image_only", [red])):
        status, data = post(origin, "/v1/chat/completions", request(parts, model=model), token)
        check_rejection("/v1/chat/completions", status, data, kind="text_only_media")
        results.append({"case": name, "passed": True, "status": status})
    started = time.monotonic()
    answer(post(origin, "/v1/chat/completions", request("Reply with hello.", model=model), token))
    results.append({"case": "text_only_provider_text", "passed": True,
                    "elapsed_seconds": round(time.monotonic() - started, 3)})
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider-url", required=True)
    parser.add_argument("--gateway-url", help="optional isolated local-stack gateway origin")
    parser.add_argument("--coordinator-url", help="joined isolated candidate's explicit loopback ws:// URL")
    parser.add_argument("--local-stack-isolated", action="store_true")
    parser.add_argument("--expected-host-name", required=True)
    parser.add_argument("--candidate-pid", type=int, required=True)
    parser.add_argument("--candidate-binary", required=True)
    parser.add_argument("--candidate-sha256", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--unsupported-model", required=True,
                        help="text-only model loaded by --text-only-provider-url, to prove media refusal")
    parser.add_argument("--text-only-provider-url", required=True,
                        help="isolated loopback origin of a second candidate process serving --unsupported-model")
    parser.add_argument("--text-only-pid", type=int, required=True)
    parser.add_argument("--output", required=True, help="new private result file; never overwrites existing evidence")
    args = parser.parse_args()
    try:
        _, provider_port = endpoint(args.provider_url)
        _, text_only_port = endpoint(args.text_only_provider_url)
        require(text_only_port != provider_port, "the text-only provider needs its own isolated port")
        require(args.unsupported_model not in (MODEL, UNLOADED_MODEL),
                "--unsupported-model must name the loaded text-only model")
        if args.gateway_url:
            endpoint(args.gateway_url)
            require(args.local_stack_isolated and args.coordinator_url,
                    "gateway execution requires an explicitly isolated joined local stack")
        if args.coordinator_url:
            require(args.local_stack_isolated, "joined candidate requires explicit local stack isolation")
        require(re.fullmatch(r"[0-9a-f]{64}", args.candidate_sha256) is not None, "invalid binary digest")
        identity = verify_host(args.expected_host_name)
        identity.update(verify_candidate(args))
        result = {"schema": "native-vision-http-observations-v1",
                  "expected_profile": {"model": MODEL, "artifact_revision": REVISION,
                                       "runtime_revision": RUNTIME_REVISION, "profile": PROFILE},
                  "identity": identity, "qualification": False, "suites": {},
                  "pending": ["model replacement and repeated-request memory bounds",
                              "cancellation propagation timing and resources",
                              "qualified-capacity negative routing and receipt verification",
                              "reviewed release live buyer routing and settlement"]}
        # Create the private evidence sink before any inference and refuse overwrite.
        with open(os.open(args.output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output:
            try:
                provider_token = os.environ.get("VISION_PROVIDER_TOKEN")
                result["suites"]["provider_local"] = run_suite(args.provider_url, provider_token, args.unsupported_model)
                result["suites"]["text_only_provider"] = run_text_only_suite(
                    args.text_only_provider_url, os.environ.get("VISION_TEXT_ONLY_PROVIDER_TOKEN", provider_token),
                    args.unsupported_model)
                if args.gateway_url:
                    result["suites"]["isolated_gateway"] = run_suite(args.gateway_url, os.environ.get("VISION_BUYER_TOKEN"),
                                                                     args.unsupported_model, gateway=True)
                result["http_checks_passed"] = True
            except (AcceptanceError, OSError, ValueError, http.client.HTTPException) as exc:
                result["http_checks_passed"] = False
                result["failure"] = str(exc) if isinstance(exc, AcceptanceError) else "request transport or response parsing failed"
            json.dump(result, output, indent=2)
            output.write("\n")
        print("HTTP checks passed; acceptance gates remain pending." if result["http_checks_passed"] else "HTTP checks failed; see redacted result.")
        return 0 if result["http_checks_passed"] else 1
    except (AcceptanceError, OSError, ValueError) as exc:
        print(str(exc) if isinstance(exc, AcceptanceError) else "acceptance preflight failed", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
