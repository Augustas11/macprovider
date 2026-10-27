#!/usr/bin/env python3
"""Bounded GLM exploratory cells or acceptance, with independent recovery.

status / next are read-only. Execution binds this clean campaign commit.
The operator explicitly authorized local measurement extensions for issue 2144. Environment: STUDIO_SSH, PEARL_SSH, STUDIO_MTP_SOURCE_DIR,
STUDIO_MTP_CONFIG, STUDIO_STATUS_PORT, MACPROVIDER_OPS_OWNER. Explicit arguments
bind the clean campaign source commit and immutable workload policy. No
operator shell commands or replacement serving binaries are accepted.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import select
import shlex
import signal
import socket
import subprocess
import sys
import time
import threading
import uuid

MODEL = "zai-org/glm-5.3-flash"
LABEL = "live.malibu.provider"
RUNNER = "malibu-buyer-runner.service"
# Independent hard ceiling for the whole Studio window (watchdog and Pearl
# recovery timer): pause/drain, the release build, metallib, check, matrix.
TOTAL = 3600
BUILD = 900
FORK_TESTS = 600
ACCEPTANCE_TESTS = 600
CELL = 3000
# Pre-downtime bench policy validation. The first run reads the snapshot once
# (outside the page cache); later runs reuse hashes of unchanged file stamps.
VALIDATE = 5400
ROOT = Path(__file__).resolve().parents[2]
# Command Line Tools (the Studio's xcode-select default) ship no Metal compiler.
# Every successful Studio metallib build used the full Xcode developer dir.
XCODE_DEVELOPER_DIR = Path.home() / "Applications/Xcode.app/Contents/Developer"


class Refusal(RuntimeError):
    pass


def run(argv, *, timeout=15, **kw):
    return subprocess.run(argv, check=True, capture_output=True, timeout=timeout, **kw).stdout


def sha(data):
    return hashlib.sha256(data).hexdigest()


def put(path, value):
    temp = path.with_suffix(".tmp")
    with open(temp, "w", opener=lambda p, f: os.open(p, f, 0o600)) as out:
        json.dump(value, out, sort_keys=True)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp, path)


def source_ok(source, commit):
    if run(["git", "-C", str(source), "rev-parse", "HEAD"]).decode().strip() != commit:
        raise Refusal("source commit differs")
    if run(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"]):
        raise Refusal("source has tracked modifications")
    # SwiftPM discovers additional source files automatically. An untracked or
    # ignored .swift file must not become part of a supposedly commit-bound CLI.
    paths = ["phase3-binary/Sources", "phase3-binary/Plugins"]
    for options in (["--others", "--exclude-standard"],
                    ["--others", "--ignored", "--exclude-standard"]):
        if run(["git", "-C", str(source), "ls-files", *options, "--", *paths]):
            raise Refusal("source has untracked compiler inputs")


ACCEPTANCE_POLICY_KEYS = {
    "schema", "model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256",
    "hw_model", "chip", "ram_gb", "os_build", "xcode_build_version", "swift_version",
    "provider_commit", "mlx_fork_revision", "quantization", "cache_mode", "corpus_sha256",
}


def strict_json(data):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise Refusal("duplicate frozen JSON key")
            value[key] = item
        return value
    def reject_constant(_):
        raise Refusal("non-finite frozen JSON")
    try:
        return json.loads(data, object_pairs_hook=unique, parse_constant=reject_constant)
    except (ValueError, TypeError) as exc:
        raise Refusal("invalid frozen JSON") from exc


def acceptance_inputs(policy, corpus, commit):
    if len(policy) > 65536 or corpus is None or len(corpus) > 64 * 1024 * 1024:
        raise Refusal("acceptance frozen input size exceeds bound")
    p = strict_json(policy)
    if not isinstance(p, dict) or set(p) != ACCEPTANCE_POLICY_KEYS:
        raise Refusal("acceptance policy fields differ")
    fixed = {"schema": "macprovider.native-mtp-acceptance-policy.v1", "model_id": MODEL,
             "provider_commit": commit, "hw_model": "Mac15,14",
             "quantization": "4bit", "cache_mode": "paged_kv_mixed"}
    if any(type(p[k]) is not str or p[k] != value for k, value in fixed.items()):
        raise Refusal("acceptance policy identity differs")
    for key in ("target_sha256", "mtp_sha256", "tokenizer_sha256", "corpus_sha256", "mlx_fork_revision"):
        size = 40 if key == "mlx_fork_revision" else 64
        if not isinstance(p[key], str) or not re.fullmatch(f"[0-9a-f]{{{size}}}", p[key]):
            raise Refusal("invalid acceptance policy digest: " + key)
    if type(p["ram_gb"]) is not int or p["ram_gb"] <= 0:
        raise Refusal("invalid acceptance policy RAM")
    for key in ("chip", "os_build", "xcode_build_version", "swift_version"):
        if not isinstance(p[key], str) or not p[key].strip():
            raise Refusal("invalid acceptance policy field: " + key)
    if corpus is None or sha(corpus) != p["corpus_sha256"]:
        raise Refusal("acceptance corpus bytes differ")
    c = strict_json(corpus)
    keys = {"schema", "model_id", "max_prompt_tokens", "qualified_slots", "max_native_active_rows",
            "proposal_depth", "minimum_compared_positions", "cases"}
    if not isinstance(c, dict) or set(c) != keys:
        raise Refusal("acceptance corpus fields differ")
    fixed = {"schema": "macprovider.native-mtp-acceptance-corpus.v1", "model_id": MODEL,
             "max_prompt_tokens": 4096, "qualified_slots": 4, "max_native_active_rows": 1}
    if any(type(c[k]) is not type(value) or c[k] != value for k, value in fixed.items()):
        raise Refusal("acceptance corpus tuple differs")
    if type(c["proposal_depth"]) is not int or c["proposal_depth"] not in (1, 2):
        raise Refusal("invalid acceptance corpus depth")
    if type(c["minimum_compared_positions"]) is not int or not 6400 <= c["minimum_compared_positions"] <= 102400:
        raise Refusal("invalid acceptance corpus position floor")
    cases = c["cases"]
    if not isinstance(cases, list) or not 200 <= len(cases) <= 400:
        raise Refusal("acceptance corpus needs 200..400 cases")
    counts = dict.fromkeys(("short", "1.5k", "4k", "8k", "near_boundary"), 0)
    seen, native_budget = set(), 0
    for case in cases:
        if not isinstance(case, dict) or set(case) != {"id", "stratum", "expected_native", "request"}:
            raise Refusal("invalid acceptance case fields")
        name = case["id"]
        if not isinstance(name, str) or not name or len(name.encode()) > 128 or name in seen:
            raise Refusal("invalid acceptance case identity")
        seen.add(name)
        stratum = case["stratum"]
        if not isinstance(stratum, str) or stratum not in counts or type(case["expected_native"]) is not bool:
            raise Refusal("invalid acceptance case stratum")
        counts[stratum] += 1
        if stratum == "8k" and case["expected_native"]:
            raise Refusal("above-cap acceptance case must remain ordinary")
        request = case["request"]
        if (not isinstance(request, dict) or request.get("model") != MODEL
                or request.get("stream") is not False or "diagnostic_eligibility_bypass" in request
                or type(request.get("max_tokens")) is not int or not 1 <= request["max_tokens"] <= 256):
            raise Refusal("invalid acceptance request bounds")
        if case["expected_native"]:
            native_budget += request["max_tokens"]
    if min(counts.values()) < 20 or native_budget < c["minimum_compared_positions"]:
        raise Refusal("acceptance corpus planned coverage incomplete")
    return p, c


JOURNEY_STEPS = ("04", "05", "06", "07", "08", "09", "10")
JOURNEY_CELLS = tuple("journey-" + step for step in JOURNEY_STEPS) + ("journey-all",)
JOURNEY_RAW_IDS = {"04": "step-04-serial-token-oracle", "05": "step-05-cache-state-boundary",
                   "06": "step-06-streaming-stop", "07": "step-07-08-mixed-multirow-capacity",
                   "08": "step-08-capacity-and-depth-zero", "09": "step-09-cancellation", "10": "step-10-warm-swap"}
JOURNEY_KEYS = (ACCEPTANCE_POLICY_KEYS - {"corpus_sha256"}) | {
    "signed_inputs_sha256", "metallib_sha256", "decode_path_digest", "qualified_slots",
    "max_native_active_rows", "max_prompt_tokens", "proposal_depth"}


def journey_inputs(data, inventory, commit):
    p = strict_json(data)
    if (set(p) != JOURNEY_KEYS or p.get("schema") != "macprovider.native-mtp-journey-policy.v1"
            or p.get("provider_commit") != commit or p.get("model_id") != MODEL
            or p.get("hw_model") != "Mac15,14" or p.get("quantization") != "4bit"
            or p.get("cache_mode") != "paged_kv_mixed"):
        raise Refusal("journey policy fields differ")
    for name, value in (("qualified_slots", 4), ("max_native_active_rows", 1),
                        ("max_prompt_tokens", 4096), ("proposal_depth", 1)):
        if type(p.get(name)) is not int or p[name] != value:
            raise Refusal("journey tuple bound differs")
    for name in ("target_sha256", "mtp_sha256", "tokenizer_sha256", "metallib_sha256",
                 "decode_path_digest", "signed_inputs_sha256"):
        if not isinstance(p.get(name), str) or not re.fullmatch("[0-9a-f]{64}", p[name]):
            raise Refusal("journey digest invalid")
    if not isinstance(inventory, bytes) or not 1 <= len(inventory) <= 64 * 1024 * 1024 or sha(inventory) != p["signed_inputs_sha256"]:
        raise Refusal("journey signed inventory differs")
    v = strict_json(inventory)
    if set(v) != {"schema", "files"} or v["schema"] != "macprovider.native-mtp-journey-signed-inputs.v1" or not isinstance(v["files"], list) or not 6 <= len(v["files"]) <= 64:
        raise Refusal("journey signed inventory schema differs")
    names = set()
    for row in v["files"]:
        if not isinstance(row, dict) or set(row) != {"path", "sha256", "base64"}:
            raise Refusal("journey signed inventory row differs")
        name = row["path"]
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*", name)
                or any(part in (".", "..") for part in name.split("/")) or name in names):
            raise Refusal("journey signed inventory path invalid")
        names.add(name)
        try: content = base64.b64decode(row["base64"], validate=True)
        except (ValueError, TypeError): raise Refusal("journey signed inventory encoding invalid")
        if not 1 <= len(content) <= 16 * 1024 * 1024 or sha(content) != row["sha256"]:
            raise Refusal("journey signed inventory bytes differ")
    if not {"catalog.json", "catalog.json.sig", "artifact-feed.json", "artifact-feed.json.sig",
            "native-mtp-admission.json", "native-mtp-admission.json.sig"} <= names:
        raise Refusal("journey signed inventory required files missing")
    return p, v


def deliver_journey(m, d):
    policy = (d / "policy.json").read_bytes()
    inventory = base64.b64decode(m["signed_inputs_code"], validate=True)
    _, v = journey_inputs(policy, inventory, m["commit"])
    target = d / "signed-inputs"
    target.mkdir(mode=0o700, exist_ok=False)
    (target / "signed-inputs-inventory.json").write_bytes(inventory)
    (target / "signed-inputs-inventory.json").chmod(0o600)
    for row in v["files"]:
        path = target / row["path"]
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with path.open("xb") as stream: stream.write(base64.b64decode(row["base64"], validate=True))
        path.chmod(0o600)


def run_journey(m):
    d = Path(m["dir"])
    if sha((d / "policy.json").read_bytes()) != m["policy_sha256"] or sha((d / "journey-requests.json").read_bytes()) != m["requests_sha256"]:
        raise Refusal("journey frozen inputs changed before execution")
    # The signed inputs are immutable, revalidated by the production verifier
    # again in the CLI before model load. No new performance qualification.
    output = d / "journey-result.json"
    with open(output, "xb", opener=lambda path, flags: os.open(path, flags, 0o600)) as stream:
        result = subprocess.run(bench_command(m, d), stdout=stream, timeout=CELL - 10, env=lab_env("cell"))
    value = strict_json(output.read_bytes())
    policy = strict_json((d / "policy.json").read_bytes())
    for field in ("model_id", "target_sha256", "mtp_sha256", "tokenizer_sha256", "qualified_slots", "max_native_active_rows", "max_prompt_tokens"):
        if value.get(field) != policy[field] or type(value.get(field)) is not type(policy[field]):
            raise Refusal("journey actual tuple differs")
    if value.get("lab_decode_path_digest") != policy["decode_path_digest"] or value.get("lab_metallib_sha256") != policy["metallib_sha256"]:
        raise Refusal("journey actual decode/Metal identity differs")
    expected = list(JOURNEY_STEPS) if m["cell"] == "journey-all" else [m["cell"][-2:]]
    if (result.returncode or value.get("executed_steps_status") != "pass" or value.get("journey_complete") is not False
            or value.get("signed_policy_inputs") is not True or value.get("requested_steps") != expected
            or value.get("request_inventory_sha256") != m["requests_sha256"]
            or value.get("lab_binary_release_candidate") is not False
            or not isinstance(value.get("steps"), list)
            or [row.get("step_id") for row in value["steps"]] != [JOURNEY_RAW_IDS[step] for step in expected]
            or any(row.get("status") != "pass" or row.get("uncovered_contract") for row in value["steps"])):
        raise Refusal("journey actual cell failed/incomplete; no retry; private result retained")


def policy_ok(data, commit, cell, corpus=None):
    if cell in JOURNEY_CELLS:
        return journey_inputs(data, corpus, commit)[0]
    if cell == "acceptance":
        return acceptance_inputs(data, corpus, commit)[0]
    p = json.loads(data)
    required = {"schema": "macprovider.native-mtp-exploratory-policy.v1",
                "model_id": MODEL, "provider_commit": commit, "hw_model": "Mac15,14",
                "slots": [1, 2, 4], "prompt_tokens": [512], "max_tokens": [128],
                "warmup_runs": 0, "blocks": 2, "sustained_seconds": 0}
    if any(p.get(k) != v or type(p.get(k)) is not type(v) for k, v in required.items()):
        raise Refusal("policy is outside the fixed short exploratory profile")
    if (type(p.get("temperature", 0)) not in (int, float)
            or p.get("temperature", 0) not in (0, 1)
            or type(p.get("top_p", 1)) not in (int, float)
            or p.get("top_p", 1) not in (1, .95)
            or p.get("request_shape", "plain_text") not in ("plain_text", "tools_history_reasoning")
            or p.get("gated_cells", []) or p.get("arrival_interval_ms", 0) != 0
            or cell not in ("s1-p512-o128", "s2-p512-o128", "s4-p512-o128", *MATRICES)):
        raise Refusal("unsupported sampling, shape or cell")
    return p


def birth(pid):
    try:
        return run(["ps", "-p", str(pid), "-o", "lstart="]).decode().strip()
    except subprocess.SubprocessError:
        return ""


def alive(identity):
    return bool(identity and identity[1] and birth(identity[0]) == identity[1])


def control(m, kind):
    expected = {"pause_request": "pause_ack", "resume_request": "resume_ack"}[kind]
    deadline = time.monotonic() + 5
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(5)
        conn.connect(m["socket"])
        conn.sendall((json.dumps({"type": kind}) + "\n").encode())
        buffered = b""
        total = 0
        while time.monotonic() < deadline and total < 65536:
            conn.settimeout(max(.01, deadline - time.monotonic()))
            part = conn.recv(4096)
            if not part:
                break
            total += len(part)
            buffered += part
            while b"\n" in buffered:
                line, buffered = buffered.split(b"\n", 1)
                reply = json.loads(line)
                if reply.get("type") == expected:
                    if reply.get("accepted") is True:
                        return
                    raise Refusal("control request refused")
    raise Refusal("matching control acknowledgement missing")


def probe(m):
    return json.loads(run([sys.executable, str(Path(m["dir"]) / "probe.py"),
                          "--install-dir", m["install"], "--config", m["config"],
                          "--journal", str(Path(m["dir"]) / "unused-owner-pin.json"),
                          "--port", str(m["port"]), "--label", LABEL]))


def status(m):
    import urllib.request
    with urllib.request.urlopen(f'http://127.0.0.1:{m["port"]}/v1/status', timeout=5) as r:
        return json.load(r)


def live_hashes(m):
    return {str(p): sha(p.read_bytes()) for p in (
        Path(m["install"]) / "macprovider-cli", Path(m["config"]),
        Path.home() / "Library/LaunchAgents" / (LABEL + ".plist"),
        Path.home() / "Library/LaunchAgents" / (LABEL + "-watchdog.plist"))}


def check_live(m):
    if live_hashes(m) != m["live_hashes"]:
        raise Refusal("incumbent/config/launch-agent bytes drifted; refusing overwrite")


def serving(p):
    s = p["status"]
    return (s.get("network_state") == "buyer_serving" and s.get("model") == MODEL
            and s.get("model_loaded") is True and s.get("coordinator.connected") is True
            and s.get("lifecycle.operator_paused") is False
            and p["launch"]["pid"] == s.get("service_instance.pid")
            and p["launch"]["executable_path"] == str(Path.home() / "macprovider/macprovider-cli"))


def launch(label, start=False):
    target = f"gui/{os.getuid()}/{label}"
    loaded = subprocess.run(["launchctl", "print", target], stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL).returncode == 0
    if start and not loaded:
        run(["launchctl", "bootstrap", f"gui/{os.getuid()}",
             str(Path.home() / "Library/LaunchAgents" / (label + ".plist"))])
    if not start and loaded:
        run(["launchctl", "bootout", target])
    end = time.monotonic() + 15
    while time.monotonic() < end:
        observed = subprocess.run(["launchctl", "print", target], stdout=subprocess.DEVNULL,
                                  stderr=subprocess.DEVNULL).returncode == 0
        if observed == start:
            return
        time.sleep(.2)
    raise Refusal("launch-agent transition timed out")


def group_live(pgid):
    rows = run(["ps", "-axo", "pgid=,stat="]).decode().splitlines()
    return any(parts[0] == str(pgid) and not parts[1].startswith("Z")
               for row in rows if len(parts := row.split()) >= 2)


def kill_group(record):
    group = record.get("group")
    if not group:
        return
    if not alive(group):
        # Never signal a reused PID. A missing group leader is uncertain unless
        # the whole reserved session has disappeared.
        if not group_live(group[0]):
            return
        # A dead leader does not destroy its session while descendants remain.
        # Require every surviving member to retain the original session ID and
        # UID, and refuse any reused leader PID, before signalling the group.
        if birth(group[0]) or record.get("session_bound") is not True:
            raise Refusal("lab group leader lost; group identity uncertain")
        rows = run(["ps", "-axo", "pid=,pgid=,uid=,stat="]).decode().splitlines()
        members = [p for row in rows if len(p := row.split()) == 4
                   and p[1] == str(group[0]) and not p[3].startswith("Z")]
        for attempt in range(3):
            try:
                if not members:
                    if not group_live(group[0]):
                        return
                    raise Refusal("lab session membership uncertain")
                if any(int(p[2]) != os.getuid() or os.getsid(int(p[0])) != group[0] for p in members):
                    raise Refusal("lab session membership uncertain")
                break
            except ProcessLookupError:
                rows = run(["ps", "-axo", "pid=,pgid=,uid=,stat="]).decode().splitlines()
                members = [p for row in rows if len(p := row.split()) == 4
                           and p[1] == str(group[0]) and not p[3].startswith("Z")]
        else:
            raise Refusal("lab session membership remained uncertain")
    try:
        os.killpg(group[0], signal.SIGKILL)
    except ProcessLookupError:
        if not group_live(group[0]):
            return
        raise Refusal("lab group changed during termination")
    end = time.monotonic() + 5
    while time.monotonic() < end:
        if not group_live(group[0]):
            return
        time.sleep(.1)
    raise Refusal("lab process group remains")


def restore(m):
    directory = Path(m["dir"])
    with open(directory / "transaction.lock", "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = json.loads((directory / "journal.json").read_text())
        if record.get("restored"):
            return
        kill_group(record)
        check_live(m)
        launch(LABEL, True)
        # The installed watchdog must not mistake normal model-load latency
        # for a failed provider. Resume as soon as its exact socket returns.
        deadline = time.monotonic() + 1200
        stable = None
        while time.monotonic() < deadline:
            try:
                control(m, "resume_request")
                p = probe(m)
                if serving(p) and p["installed"] == m["baseline"]["installed"]:
                    identity = (p["launch"]["pid"], p["launch"]["process_start_us"])
                    if stable and stable[0] == identity and time.monotonic() - stable[1] >= 120:
                        check_live(m)
                        launch(LABEL + "-watchdog", True)
                        after = probe(m)
                        if not serving(after) or after["launch"]["pid"] != identity[0]:
                            raise Refusal("watchdog changed the restored provider")
                        record.update(restored=True, phase="restored")
                        put(directory / "journal.json", record)
                        return
                    if not stable or stable[0] != identity:
                        stable = (identity, time.monotonic())
                else:
                    stable = None
            except (OSError, ValueError, subprocess.SubprocessError):
                stable = None
            time.sleep(1)
        launch(LABEL + "-watchdog", True)
        raise Refusal("signed incumbent readiness pending; journal retained")


def lease_reader(directory, stream):
    """EOF and malformed heartbeat frames revoke the lease immediately."""
    path = Path(directory) / "controller-lease.json"
    try:
        for line in stream:
            if json.loads(line) != {"heartbeat": True}:
                break
            put(path, {"connected": True, "updated": time.time()})
    finally:
        put(path, {"connected": False, "updated": time.time()})


def lease_alive(m):
    try:
        lease = json.loads((Path(m["dir"]) / "controller-lease.json").read_text())
        return lease.get("connected") is True and 0 <= time.time() - lease["updated"] < 10
    except (OSError, ValueError, KeyError, TypeError):
        return False


def watchdog(m):
    d = Path(m["dir"])
    put(d / "watchdog-ready.json", {"pid": os.getpid()})
    while True:
        record = json.loads((d / "journal.json").read_text())
        if record.get("restored"):
            return
        deadline = record.get("restore_deadline", m["deadline"])
        if not lease_alive(m) or not alive(m["worker"]) or time.time() >= deadline:
            break
        time.sleep(1)
    if alive(m["worker"]):
        try:
            os.kill(m["worker"][0], signal.SIGKILL)
        except ProcessLookupError:
            if alive(m["worker"]):
                raise Refusal("worker identity changed during termination")
    try:
        restore(m)
    except Exception:
        # Do not leak provider/config details; the durable journal is the
        # operator's recovery signal, never a claim that restoration succeeded.
        put(d / "recovery-blocked.json", {"blocked": True})


# Each matrix runs every slot cell for each (request shape, temperature)
# profile; "matrix-tools" is the tools/history/reasoning half alone.
MATRICES = {shapes_name: tuple((shape, temperature) for shape in shapes for temperature in (0, 1))
            for shapes_name, shapes in (("matrix", ("plain_text", "tools_history_reasoning")),
                                        ("matrix-tools", ("tools_history_reasoning",)))}
MATRICES["matrix-s2"] = MATRICES["matrix"]


def validate_checkpoint(m, data, policy, corpus):
    """Independent numeric validation before a prefix can skip any request."""
    if len(data) > 64 * 1024 * 1024 or sha(data) != m.get("resume_sha256"):
        raise Refusal("checkpoint transport size/hash differs")
    if strict_json(policy).get("provider_commit") != m["commit"]:
        raise Refusal("checkpoint execution source differs")
    source = Path(m["source"]) / "scripts/native_mtp_binding_bundle.py"
    spec = importlib.util.spec_from_file_location("native_checkpoint_validator", source)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    try:
        return module.validate_acceptance_checkpoint(strict_json(data), strict_json(policy), strict_json(corpus),
            policy_sha=m["policy_sha256"], corpus_sha=m["corpus_sha256"])
    except (ValueError, KeyError, TypeError, AttributeError, OverflowError) as error:
        raise Refusal("checkpoint raw numeric prefix rejected: " + str(error)) from error


def transport_checkpoint(m, d, policy, corpus):
    if "resume_code" not in m:
        if m.get("resume_sha256") is not None:
            raise Refusal("checkpoint transport missing")
        return
    data = base64.b64decode(m["resume_code"], validate=True)
    validate_checkpoint(m, data, policy, corpus)
    path = d / "acceptance-checkpoint.json"
    with open(path, "wb", opener=lambda p, f: os.open(p, f, 0o600)) as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


def bench_command(m, d):
    """The one bench argv for this cell or matrix, in window or preflight dir d.

    The matrix writes its four derived request profiles into d first, so the
    pre-downtime validation and the window run byte-identical policies.
    """
    package = Path(m["source"]) / "phase3-binary"
    if m["cell"] in JOURNEY_CELLS:
        steps = JOURNEY_STEPS if m["cell"] == "journey-all" else (m["cell"][-2:],)
        return [str(package / ".build/release/macprovider-cli"), "native-mtp-journey-e2e",
                "--root", str(Path(m["source"]) / ".lab-window/fixture"), "--model-id", MODEL,
                "--provider-commit", m["commit"], "--qualified-slots", "4", "--max-native-active-rows", "1",
                "--max-prompt-tokens", "4096", "--signed-admission-inputs", str(d / "signed-inputs"),
                "--journey-policy", str(d / "policy.json"), "--journey-requests", str(d / "journey-requests.json"),
                "--journey-metallib", str(package / ".build/arm64-apple-macosx/release/mlx.metallib"),
                *[arg for step in steps for arg in ("--journey-step", step)]]
    if m["cell"] == "acceptance":
        return [str(package / ".build/release/macprovider-cli"), "native-mtp-journey-e2e",
                "--root", str(Path(m["source"]) / ".lab-window/fixture"),
                "--model-id", MODEL, "--provider-commit", m["commit"],
                "--qualified-slots", "4", "--max-native-active-rows", "1", "--max-prompt-tokens", "4096",
                "--acceptance-corpus", str(d / "acceptance-corpus.json"),
                "--acceptance-policy", str(d / "policy.json"),
                "--acceptance-checkpoint", str(d / "acceptance-checkpoint.json")]
    command = [str(package / ".build/release/macprovider-cli"), "native-mtp-bench",
               "--root", str(Path(m["source"]) / ".lab-window/fixture"),
               "--model-id", MODEL, "--provider-commit", m["commit"], "--phase", "matrix"]
    if m["cell"] not in MATRICES:
        return command + ["--policy", str(d / "policy.json"), "--out", str(d / "runs.jsonl"),
                          "--only-cell", m["cell"]]
    base = json.loads((d / "policy.json").read_text())
    paths = []
    for shape, temperature in MATRICES[m["cell"]]:
        path = d / f"{shape}-t{temperature}-policy.json"
        put(path, dict(base, request_shape=shape, temperature=temperature,
                       top_p=1 if temperature == 0 else .95))
        paths.append(str(path))
    selection = ["--only-cell", "s2-p512-o128"] if m["cell"] == "matrix-s2" else []
    return command + ["--policy-list", *paths, "--out", str(d / "baseline"), *selection]


def run_acceptance(m):
    d = Path(m["dir"])
    policy = (d / "policy.json").read_bytes()
    corpus = (d / "acceptance-corpus.json").read_bytes()
    if sha(policy) != m["policy_sha256"] or sha(corpus) != m["corpus_sha256"]:
        raise Refusal("acceptance inputs changed before execution")
    _, c = acceptance_inputs(policy, corpus, m["commit"])
    if m.get("resume_sha256") is not None:
        validate_checkpoint(m, (d / "acceptance-checkpoint.json").read_bytes(), policy, corpus)
    output = d / "acceptance-result.json"
    with open(output, "wb", opener=lambda p, f: os.open(p, f, 0o600)) as out:
        result = subprocess.run(bench_command(m, d), stdout=out, timeout=CELL - 10,
                                env=lab_env("cell"))
    # Preserve the result even when the command fails; it remains correctness
    # evidence only, and never an R015 performance/admission verdict.
    if result.returncode:
        raise Refusal("acceptance corpus failed; no retry; private result retained")
    value = strict_json(output.read_bytes())
    if (not isinstance(value, dict) or value.get("status") != "pass"
            or value.get("schema") != "macprovider.native-mtp-acceptance-result.v1"
            or value.get("journey_complete") is not False
            or value.get("corpus_sha256") != m["corpus_sha256"]
            or value.get("policy_sha256") != m["policy_sha256"]
            or type(value.get("native_compared_positions")) is not int
            or value["native_compared_positions"] < c["minimum_compared_positions"]
            or not isinstance(value.get("cases"), list) or len(value["cases"]) != len(c["cases"])
            or not isinstance(value.get("checks"), dict) or not value["checks"]
            or any(check is not True for check in value["checks"].values())):
        raise Refusal("acceptance result incomplete or identity differs")
    for row, case in zip(value["cases"], c["cases"]):
        if (not isinstance(row, dict) or row.get("id") != case["id"]
                or row.get("stratum") != case["stratum"] or row.get("passed") is not True
                or row.get("expected_native") is not case["expected_native"]):
            raise Refusal("acceptance result case provenance differs")


def lab_env(kind):
    environment = {"HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                   "MACPROVIDER_NATIVE_MTP_E2E": "1"}
    if kind in ("metal", "fork-tests", "acceptance-tests"):
        environment["DEVELOPER_DIR"] = str(XCODE_DEVELOPER_DIR)
    return environment


def fixed_command(m, kind):
    d = Path(m["dir"])
    package = str(Path(m["source"]) / "phase3-binary")
    if kind == "build":
        return ["/usr/bin/xcrun", "swift", "build", "--package-path", package,
                "-c", "release", "-j", "2", "--disable-automatic-resolution",
                "-Xswiftc", "-DMACPROVIDER_LAB_HARNESS", "--product", "macprovider-cli"]
    if kind == "metal":
        return ["/bin/bash", str(Path(package) / "scripts/build-mlx-metallib.sh"),
                str(Path(package) / ".build/arm64-apple-macosx/release")]
    if kind == "fork-tests":
        cache = Path(m["source"]) / ".lab-window/glm-cohort-tests"
        return ["/usr/bin/xcrun", "xcodebuild", "test",
                "-scheme", "mlx-swift-lm-Package",
                "-destination", "platform=macOS,arch=arm64",
                "-skipPackagePluginValidation",
                "-only-testing:MLXLMTests/GLM5NextTests/testPackedVerifyDepthOneCohortsMatchSerialRows",
                "-only-testing:MLXLMTests/GLM5NextTests/testPackedVerifyRank512FallbackMatchesSerialRows",
                "-only-testing:MLXLMTests/GLM5NextTests/testMTPDrafterRollbackAndPackedAdvanceMatchSerialCommit",
                "-only-testing:MLXLMTests/GLM5NextTests/testPackedVerifyDepthThreeMatchesSerialRows",
                "-parallel-testing-enabled", "NO", "-jobs", "2",
                "-derivedDataPath", str(cache / "DerivedData"),
                "-clonedSourcePackagesDirPath", str(cache / "SourcePackages"),
                "-resultBundlePath", str(d / "glm-cohort-parity.xcresult")]
    if kind == "acceptance-tests" and m["cell"] == "acceptance":
        # Existing package test hooks are DEBUG-only. Keep their normal debug
        # configuration and CLI compiler. Full Xcode supplies XCTest, which the
        # Command Line Tools SDK omits; the corpus uses release below.
        return ["/Library/Developer/CommandLineTools/usr/bin/swift", "test", "--package-path", package,
                "-c", "debug", "-j", "2", "--disable-automatic-resolution",
                "-Xswiftc", "-DMACPROVIDER_LAB_HARNESS", "--filter",
                "NativeMTPAcceptance.*Tests|NativeMTPLabNumericalOracleTests|NativeMTPBackendSafetyTests|NativeMTPRequestShapeReplayCommandTests|NativeMTPRequestShapeCaptureTests|NativeMTPSelectorTests"]
    if kind == "metalcheck":
        return [sys.executable, str(d / "entry.py"), "_metalcheck", str(d / "manifest.json")]
    if kind == "cell" and m["cell"] in MATRICES:
        return [sys.executable, str(d / "entry.py"), "_matrix", str(d / "manifest.json")]
    if kind == "cell" and m["cell"] in JOURNEY_CELLS:
        return [sys.executable, str(d / "entry.py"), "_journey", str(d / "manifest.json")]
    if kind == "cell" and m["cell"] == "acceptance":
        return [sys.executable, str(d / "entry.py"), "_acceptance", str(d / "manifest.json")]
    if kind == "cell":
        return bench_command(m, d)
    raise Refusal("unknown fixed lab command")


def grouped(m, kind, timeout):
    d = Path(m["dir"])
    read_fd, write_fd = os.pipe()
    # The session leader remains alive until explicitly killed, even after the
    # fixed child exits. This prevents PID reuse during watchdog cleanup.
    child = subprocess.Popen([sys.executable, str(d / "entry.py"), "_group", str(read_fd),
                              kind, str(d / "manifest.json"), str(d / "command-done.json")],
                             pass_fds=(read_fd,), start_new_session=True,
                             stdin=subprocess.DEVNULL, stdout=open(d / "lab.log", "ab"),
                             stderr=subprocess.STDOUT, env=lab_env(kind))
    os.close(read_fd)
    try:
        with open(d / "transaction.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            record = json.loads((d / "journal.json").read_text())
            if time.time() >= m["deadline"] or record.get("restored"):
                os.close(write_fd)
                write_fd = -1
                child.wait(timeout=5)
                raise Refusal("window expired before child dispatch")
            identity = [child.pid, birth(child.pid)]
            if not identity[1] or os.getsid(child.pid) != child.pid:
                child.kill()
                child.wait(timeout=5)
                raise Refusal("lab session identity unavailable before dispatch")
            record["group"] = identity
            record["session_bound"] = True
            put(d / "journal.json", record)
            os.write(write_fd, b"1")
        end = min(time.monotonic() + timeout, time.monotonic() + m["deadline"] - time.time() - 5)
        done = d / "command-done.json"
        while time.monotonic() < end:
            if done.exists():
                result = json.loads(done.read_text())["returncode"]
                break
            if child.poll() is not None:
                raise Refusal("lab session leader lost")
            time.sleep(.2)
        else:
            raise Refusal("fixed lab command timed out")
        if result:
            raise Refusal("fixed lab command failed; private log retained")
    finally:
        if write_fd >= 0:
            os.close(write_fd)
        # Reap the exact leader before asking kill_group to verify disappearance.
        with open(d / "transaction.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            record = json.loads((d / "journal.json").read_text())
            kill_group(record)
            child.wait(timeout=5)
            record.pop("group", None)
            put(d / "journal.json", record)
        if done.exists():
            done.unlink()


def worker(m):
    d = Path(m["dir"])
    m["worker"] = [os.getpid(), birth(os.getpid())]
    m["deadline"] = time.time() + TOTAL
    put(d / "manifest.json", m)
    put(d / "journal.json", {"phase": "armed", "restored": False})
    with open(d / "watchdog.log", "ab") as log:
        guard = subprocess.Popen([sys.executable, str(d / "entry.py"), "_watchdog", str(d)],
                                 start_new_session=True, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=log)
    failure = None
    try:
        for _ in range(50):
            if (d / "watchdog-ready.json").exists():
                break
            if guard.poll() is not None:
                raise Refusal("Studio watchdog failed to arm")
            time.sleep(.1)
        else:
            raise Refusal("Studio watchdog did not acknowledge")
        check_live(m)
        source_ok(m["source"], m["commit"])
        fresh = probe(m)
        if not serving(fresh) or fresh["launch"] != m["baseline"]["launch"]:
            raise Refusal("incumbent process drifted before pause")
        socket_owner(m["socket"], fresh["launch"]["pid"])
        control(m, "pause_request")
        # Pause stops admission only; in-flight buyer requests keep generating.
        until = time.monotonic() + 300
        while True:
            s = status(m)
            lifecycle = s.get("lifecycle", {})
            if s.get("requests_in_flight") == 0 and lifecycle.get("operator_paused") is True:
                break
            if time.monotonic() > until:
                raise Refusal("pause/drain failed")
            time.sleep(.5)
        launch(LABEL + "-watchdog")
        launch(LABEL)
        old = m["baseline"]["launch"]
        stop_deadline = time.monotonic() + 30
        while birth(old["pid"]):
            if time.monotonic() > stop_deadline:
                raise Refusal("incumbent process still alive")
            time.sleep(.2)
        build_started = time.monotonic()
        grouped(m, "build", BUILD)
        build_spent = time.monotonic() - build_started
        grouped(m, "metal", BUILD)
        grouped(m, "metalcheck", 120)
        grouped(m, "fork-tests", FORK_TESTS)
        if m["cell"] == "acceptance":
            grouped(m, "acceptance-tests", ACCEPTANCE_TESTS)
            # SwiftPM tests may relink the executable with enable-testing.
            # Restore the normal frozen lab flags, sharing the original CLI
            # build budget rather than granting a second build allowance.
            remaining_build = BUILD - build_spent
            if remaining_build <= 0:
                raise Refusal("CLI build budget exhausted before flag restoration")
            grouped(m, "build", remaining_build)
            grouped(m, "metalcheck", 120)
        source_ok(m["source"], m["commit"])
        grouped(m, "cell", CELL)
    except Exception as exc:
        failure = type(exc).__name__
    finally:
        # Controller restores Pearl immediately; signed-provider readiness is
        # allowed to finish independently afterwards.
        with open(d / "transaction.lock", "a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            record = json.loads((d / "journal.json").read_text())
            record.update(phase="offline_ended", restore_deadline=time.time() + 1230)
            put(d / "journal.json", record)
        print(json.dumps({"window_ended": True}), flush=True)
        restore(m)
    return {"restored": True, "lab_passed": failure is None, "failure": failure,
            "result": str(d / ("journey-result.json" if m["cell"] in JOURNEY_CELLS else "acceptance-result.json" if m["cell"] == "acceptance" else "runs.jsonl")), "source_commit": m["commit"],
            "policy_sha256": m["policy_sha256"]}


def config_socket(text, override, probe_code):
    namespace = {"__name__": "probe_helpers"}
    exec(compile(probe_code, "published-probe.py", "exec"), namespace)
    found = None
    for line in text.splitlines(keepends=True):
        if line[:1].isspace() or line.lstrip().startswith("#"):
            continue
        match = namespace["TOP_LEVEL"].fullmatch(line)
        if match and match.group(1) == "ctl_socket_path":
            if found is not None:
                raise Refusal("duplicate ctl_socket_path")
            found = namespace["scalar"](match.group(2) or "")
        elif "ctl_socket_path" in line:
            raise Refusal("unsupported socket config syntax")
    if found and override and found != override:
        raise Refusal("explicit socket differs from config")
    value = found or override
    if not isinstance(value, str) or not re.fullmatch(r"/[A-Za-z0-9._/-]+", value) or ".." in value.split("/"):
        raise Refusal("exact absolute control socket required")
    return value


def socket_owner(path, pid):
    lines = run(["/usr/sbin/lsof", "-n", "-P", "-a", "-U", "-p", str(pid), "-Fn"]).decode().splitlines()
    if f"p{pid}" not in lines or "n" + path not in lines:
        raise Refusal("baseline provider PID does not own the exact socket")


def inspect_remote(m):
    if run(["sysctl", "-n", "hw.model"]).decode().strip() != "Mac15,14":
        raise Refusal("execution target is not the designated Studio")
    source_ok(m["source"], m["commit"])
    package = Path(m["source"]) / "phase3-binary"
    # Checked before downtime: the Metal compiler under the Xcode developer
    # dir, and the MLX kernel sources matching the dependency lockfile.
    if subprocess.run(["/usr/bin/xcrun", "-sdk", "macosx", "-find", "metal"],
                      env=dict(os.environ, DEVELOPER_DIR=str(XCODE_DEVELOPER_DIR)),
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        raise Refusal("Metal compiler unavailable under the Xcode developer dir")
    pins_ok(package)
    home = Path.home()
    m["install"] = str(home / "macprovider")
    # Reuse the probe's deliberately narrow YAML scalar grammar, without
    # copying the credential-bearing configuration anywhere.
    code = base64.b64decode(m.pop("probe_code"))
    m["socket"] = config_socket(Path(m["config"]).read_text(), m.pop("socket_override", None), code)
    # Run the existing sanitized, identity-aware probe without copying config.
    args = ["--install-dir", m["install"], "--config", m["config"], "--journal",
            str(home / ".config/macprovider/studio-mtp-measurement.owner-pin-unused"),
            "--port", str(m["port"]), "--label", LABEL]
    baseline = json.loads(run([sys.executable, "-c", code.decode(), *args]))
    if not serving(baseline):
        raise Refusal("GLM signed incumbent is not buyer_serving")
    socket_owner(m["socket"], baseline["launch"]["pid"])
    m["baseline"] = baseline
    m["live_hashes"] = live_hashes(m)
    m["dir"] = str(home / ".config/macprovider/studio-mtp-measurement" / m["nonce"])
    return m


def pins_ok(package):
    """Every dependency checkout is at its Package.resolved revision.

    The build uses --disable-automatic-resolution, so a stale checkout (MLX
    kernels, the mlx-swift-lm runtime the bench stamps) would be compiled.
    """
    for pin in json.loads((package / "Package.resolved").read_text())["pins"]:
        name = pin["location"].rstrip("/").rsplit("/", 1)[-1].removesuffix(".git")
        checkout = package / ".build/checkouts" / name
        pinned = pin["state"].get("revision")
        try:
            head = run(["git", "-C", str(checkout), "rev-parse", "HEAD"]).decode().strip()
        except (OSError, subprocess.SubprocessError):
            head = "missing"
        if head != pinned:
            raise Refusal(f"Package.resolved pin mismatch: {pin['identity']} pinned={pinned} checkout={head}")
        if run(["git", "-C", str(checkout), "status", "--porcelain", "--untracked-files=no"]):
            raise Refusal(f"dependency checkout modified: {pin['identity']}")


def preflight_remote(m):
    """Before downtime: the bench's own policy validation, and nothing heavier.

    The Studio runs no build or other CPU/GPU work outside its own window
    (builds happen after pause and drain). The controller builds the
    validator at the bound commit on the operator Mac and uploads it; here
    it runs `native-mtp-bench --validate-policy-only` (no model load, no
    MLX/Metal) on the policies the window will run, so every frozen field
    the bench checks (hardware, OS build, Xcode, Swift stdout, provider
    commit, runtime revision, model/MTP/tokenizer digests, policy schema and
    matrix, and every cell's requests through the production parser) is
    compared while the provider still serves.
    """
    source_ok(m["source"], m["commit"])
    pins_ok(Path(m["source"]) / "phase3-binary")
    root = Path.home() / ".config/macprovider/studio-mtp-measurement"
    d = root / ("preflight-" + m["nonce"])
    d.mkdir(mode=0o700, parents=True, exist_ok=False)
    policy = base64.b64decode(m["policy_code"])
    if sha(policy) != m["policy_sha256"]:
        raise Refusal("policy bytes drifted")
    (d / "policy.json").write_bytes(policy)
    acceptance = m["cell"] == "acceptance"
    journey = m["cell"] in JOURNEY_CELLS
    if journey:
        deliver_journey(m, d)
    corpus = None
    if acceptance:
        corpus = base64.b64decode(m["corpus_code"], validate=True)
        acceptance_inputs(policy, corpus, m["commit"])
        if sha(corpus) != m["corpus_sha256"]:
            raise Refusal("acceptance corpus transport differs")
        (d / "acceptance-corpus.json").write_bytes(corpus)
        (d / "acceptance-corpus.json").chmod(0o600)
        transport_checkpoint(m, d, policy, corpus)
    validator = root / ("validator-" + m["validator_sha256"][:16])
    if not validator.is_file() or sha(validator.read_bytes()) != m["validator_sha256"]:
        raise Refusal("uploaded validator bytes differ")
    validator.chmod(0o700)
    command = bench_command(m, d)
    command[0] = str(validator)
    command += ["--freeze-journey-requests" if journey else "--validate-acceptance-only" if acceptance else "--validate-policy-only",
                "--identity-cache", str(root / "identity-cache.json")]
    # Background policy: efficiency cores and throttled I/O beside serving.
    result = subprocess.run(["/usr/sbin/taskpolicy", "-b", *command], stdin=subprocess.DEVNULL,
                            capture_output=True, text=True, env=lab_env("cell"), timeout=VALIDATE)
    (d / "validate.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        reason = next((line.strip() for line in reversed(result.stderr.splitlines()) if line.strip()), "no output")
        raise Refusal("bench policy validation refused: " + reason)
    summaries = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
    expected = len(MATRICES[m["cell"]]) if m["cell"] in MATRICES else 1
    if len(summaries) != expected or any(s.get("validate_only") != "pass" for s in summaries):
        raise Refusal("bench policy validation incomplete")
    if acceptance:
        acceptance_summary_ok(summaries[0], policy, corpus, m["commit"])
    response = {"preflight": "pass", "validated": summaries}
    if journey:
        frozen = (d / "journey-requests.json").read_bytes()
        summary = summaries[0]
        if (summary.get("request_inventory_sha256") != sha(frozen) or summary.get("policy_sha256") != m["policy_sha256"]
                or summary.get("signed_inputs_verified") is not True or summary.get("observed_policy") != strict_json(policy)
                or type(summary.get("requests_parsed")) is not int or not 1 <= summary["requests_parsed"] <= 256
                or len(frozen) > 8 * 1024 * 1024):
            raise Refusal("journey validator binding differs")
        response.update(requests_code=base64.b64encode(frozen).decode(), requests_sha256=sha(frozen))
    return response


def acceptance_summary_ok(summary, policy, corpus, commit):
    p, c = acceptance_inputs(policy, corpus, commit)
    if summary.get("policy_sha256") != sha(policy):
        raise Refusal("acceptance validator policy digest differs")
    observed = summary.get("observed_environment")
    if not isinstance(observed, dict):
        raise Refusal("acceptance validator environment missing")
    for key, expected in p.items():
        if key == "schema":
            continue  # Both strict policy decoders enforce this fixed schema.
        values = [item[key] for item in (summary, observed) if key in item]
        if not values or any(type(value) is not type(expected) or value != expected for value in values):
            raise Refusal("acceptance validator field differs: " + key)
    for key in ("model_id", "qualified_slots", "max_native_active_rows", "max_prompt_tokens",
                "proposal_depth", "minimum_compared_positions"):
        if type(summary.get(key)) is not type(c[key]) or summary[key] != c[key]:
            raise Refusal("acceptance validator corpus field differs: " + key)
    if type(summary.get("cases")) is not int or summary["cases"] != len(c["cases"]):
        raise Refusal("acceptance validator case count differs")


# The validator is built on the operator Mac with Command Line Tools (the
# Studio's Swift major/minor; the bench reads the Studio's own toolchain
# version at run time), never on the Studio outside a window.
VALIDATOR_SCRATCH = Path.home() / ".cache/macprovider/studio-mtp-validator"
CLT_DEVELOPER_DIR = "/Library/Developer/CommandLineTools"


def build_validator(commit):
    source_ok(ROOT, commit)
    try:
        run(["/usr/bin/xcrun", "swift", "build", "--package-path", str(ROOT / "phase3-binary"),
             "-c", "release", "--scratch-path", str(VALIDATOR_SCRATCH), "--disable-automatic-resolution",
             "-Xswiftc", "-DMACPROVIDER_LAB_HARNESS", "--product", "macprovider-cli"],
            timeout=3600, env=dict(os.environ, DEVELOPER_DIR=CLT_DEVELOPER_DIR))
    except subprocess.SubprocessError:
        raise Refusal("local validator build failed")
    source_ok(ROOT, commit)
    return VALIDATOR_SCRATCH / "release/macprovider-cli"


def upload_validator(host, path):
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+", host) or host.startswith("-") or host == "local":
        raise Refusal("SSH alias required")
    digest = sha(path.read_bytes())
    run(["scp", "-q", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", str(path),
         f"{host}:.config/macprovider/studio-mtp-measurement/validator-{digest[:16]}"], timeout=600)
    return digest


def ssh(host, code, payload, timeout=30):
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+", host) or host.startswith("-") or host == "local":
        raise Refusal("SSH alias required")
    command = "python3 -c " + shlex.quote(code)
    try:
        out = run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                   "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
                   host, command], input=json.dumps(payload).encode(), timeout=timeout)
    except subprocess.CalledProcessError as exc:
        # The remote entry prints one sanitized refusal line; surface it.
        prefix = "studio-mtp-measurement: blocked: "
        lines = [l for l in (exc.stderr or b"").decode(errors="replace").splitlines() if l.startswith(prefix)]
        if lines:
            raise Refusal("remote: " + lines[-1][len(prefix):].removesuffix("; journals/lock retained if armed"))
        raise
    return json.loads(out)


def dispatch_worker(host, code, payload, window_ended):
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+", host) or host.startswith("-") or host == "local":
        raise Refusal("SSH alias required")
    child = subprocess.Popen(
        ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5",
         "-o", "ServerAliveCountMax=1", host, "python3 -c " + shlex.quote(code)],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        child.stdin.write(json.dumps(payload) + "\n")
        child.stdin.flush()
        heartbeat_stop = threading.Event()
        heartbeat_error = []
        def heartbeat():
            while not heartbeat_stop.wait(3):
                try:
                    child.stdin.write('{"heartbeat":true}\n')
                    child.stdin.flush()
                except (OSError, ValueError):
                    heartbeat_error.append(True)
                    return
        heartbeat_thread = threading.Thread(target=heartbeat, daemon=True)
        heartbeat_thread.start()
        deadline = time.monotonic() + TOTAL + 1260
        result = None
        while time.monotonic() < deadline:
            if heartbeat_error:
                raise Refusal("controller heartbeat transport lost; no retry")
            ready, _, _ = select.select([child.stdout], [], [], min(1, deadline - time.monotonic()))
            if not ready:
                continue
            line = child.stdout.readline()
            if not line:
                break
            event = json.loads(line)
            if event.get("window_ended") is True:
                window_ended()
            else:
                result = event
        else:
            raise Refusal("Studio SSH deadline exceeded; no retry")
        if child.wait(timeout=5) != 0 or not result:
            raise Refusal("Studio SSH failed; no retry")
        return result
    finally:
        if "heartbeat_stop" in locals():
            heartbeat_stop.set()
        # Closing this SSH stream revokes the remote lease; no reconnect is
        # attempted, and the independent Studio guardian owns recovery.
        if child.poll() is None:
            child.kill()
            child.wait(timeout=5)
        if child.stdin:
            child.stdin.close()


TIMER_RECOVERY_CODE = """import json,os,pathlib,subprocess,sys
service='malibu-buyer-runner.service'
state=pathlib.Path('/run/macprovider-mtp-restore')
state.mkdir(mode=0o700,parents=True,exist_ok=True)
ok=False
try:
 subprocess.run(['/usr/bin/systemctl','start',service],check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
 active=subprocess.run(['/usr/bin/systemctl','is-active',service],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=10)
 ok=active.returncode==0 and active.stdout.strip()==b'active'
finally:
 path=state/(sys.argv[1]+'.json')
 with open(path,'w',opener=lambda p,f:os.open(p,f,0o600)) as out:
  json.dump({'runner_active':ok,'recovery':'passed' if ok else 'failed'},out)
  out.flush();os.fsync(out.fileno())
sys.exit(0 if ok else 1)
"""


def pearl(host, unit, arm=False, retire=False):
    # Fixed argv, including the independent timer's start+verify+receipt step.
    code = '''import json,subprocess,sys,time
p=json.load(sys.stdin); u=p["unit"]; s="malibu-buyer-runner.service"
def r(a): return subprocess.run(a,check=True,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL).stdout.decode().strip()
if p["arm"]:
 r(["systemctl","is-active",s])
 r(["systemd-run","--collect","--unit="+u,"--on-active=%ds"%p["seconds"],"--timer-property=AccuracySec=1s","/usr/bin/python3","-c",p["recovery_code"],u])
 r(["systemctl","is-active",u+".timer"])
 r(["systemctl","stop",s])
elif p["retire"]:
 if r(["systemctl","is-active",s]) != "active": raise RuntimeError("runner inactive before timer retirement")
 subprocess.run(["systemctl","stop",u+".timer",u+".service"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 subprocess.run(["systemctl","reset-failed",u+".timer",u+".service"],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 deadline=time.monotonic()+5
 while True:
  probe=subprocess.run(["systemctl","show","--property=LoadState","--value",u+".timer"],stdout=subprocess.PIPE,stderr=subprocess.DEVNULL)
  if probe.stdout.strip()==b"not-found": break
  if time.monotonic()>=deadline: raise RuntimeError("recovery timer was not removed")
  time.sleep(.1)
else:
 r(["systemctl","start",s])
 if r(["systemctl","is-active",s]) != "active": raise RuntimeError("runner inactive")
print(json.dumps({"ok":True,"runner_active":not p["arm"],"timer_retired":p["retire"]}))'''
    return ssh(host, code, {"unit": unit, "arm": arm, "retire": retire, "seconds": TOTAL,
                            "recovery_code": TIMER_RECOVERY_CODE})


def published(m):
    helper = ROOT / "scripts/ops/lib/published-provider-identity.sh"
    common = ROOT / "scripts/ops/lib/common.sh"
    script = '. "$1"; . "$2"; p="$(cat)"; published_provider_identity_ok "$3" "$p" "$4"'
    run(["bash", "-c", script, "bash", str(common), str(helper),
         m["baseline"]["installed"]["binary_version"], m["install"]],
        input=json.dumps(m["baseline"]).encode(), timeout=120)


def controller(args):
    source = os.environ["STUDIO_MTP_SOURCE_DIR"]
    if not Path(source).is_absolute() or not Path(os.environ["STUDIO_MTP_CONFIG"]).is_absolute():
        raise Refusal("absolute remote source/config required")
    if not re.fullmatch("[0-9a-f]{40}", args.source_commit):
        raise Refusal("exact source commit required")
    data = args.policy.read_bytes()
    corpus_path = getattr(args, "acceptance_corpus", None)
    journey = args.cell in JOURNEY_CELLS
    signed_path = getattr(args, "journey_signed_inputs", None)
    if journey != (signed_path is not None):
        raise Refusal("journey mode requires its immutable signed inventory")
    if (args.cell == "acceptance") != (corpus_path is not None):
        raise Refusal("acceptance mode requires its corpus; other modes exclude it")
    corpus = None
    if corpus_path is not None:
        with corpus_path.open("rb") as stream:
            corpus = stream.read(64 * 1024 * 1024 + 1)
    signed = None
    if signed_path is not None:
        with signed_path.open("rb") as stream:
            signed = stream.read(64 * 1024 * 1024 + 1)
    resume = None
    if getattr(args, "acceptance_resume", None) is not None:
        path = args.acceptance_resume
        if args.cell != "acceptance" or path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o777 != 0o600:
            raise Refusal("resume requires a private regular acceptance checkpoint")
        with path.open("rb") as stream:
            resume = stream.read(64 * 1024 * 1024 + 1)
    policy_ok(data, args.source_commit, args.cell, signed if journey else corpus)
    source_ok(ROOT, args.source_commit)
    payload = {"source": source, "commit": args.source_commit, "cell": args.cell,
               "config": os.environ["STUDIO_MTP_CONFIG"], "port": int(os.environ["STUDIO_STATUS_PORT"]),
               "socket_override": os.environ.get("STUDIO_MTP_CTL_SOCKET"),
               "nonce": uuid.uuid4().hex, "policy_sha256": sha(data),
               "probe_code": base64.b64encode((ROOT / "scripts/ops/lib/studio-owner-pin-probe.py").read_bytes()).decode()}
    if corpus is not None:
        payload["corpus_sha256"] = sha(corpus)
    if resume is not None:
        payload["resume_sha256"] = sha(resume)
        validate_checkpoint(dict(payload, source=str(ROOT)), resume, data, corpus)
    code = Path(__file__).read_bytes()
    loader = "import base64;__file__='/tmp/macprovider-mtp/entry.py';exec(compile(base64.b64decode(" + repr(base64.b64encode(code).decode()) + "),'entry.py','exec'))"
    # Remote dispatch via stdin leaves host arguments and all secrets out of argv.
    inspect_code = "import sys;sys.argv=['entry.py','_inspect'];" + loader
    m = ssh(os.environ["STUDIO_SSH"], inspect_code, payload)
    published(m)
    # Every frozen field the window validates is compared here, while live.
    validator = upload_validator(os.environ["STUDIO_SSH"], build_validator(args.source_commit))
    preflight_code = "import sys;sys.argv=['entry.py','_preflight'];" + loader
    frozen_inputs = {"policy_code": base64.b64encode(data).decode()}
    if signed is not None:
        frozen_inputs["signed_inputs_code"] = base64.b64encode(signed).decode()
    if corpus is not None:
        frozen_inputs["corpus_code"] = base64.b64encode(corpus).decode()
    if resume is not None:
        frozen_inputs["resume_code"] = base64.b64encode(resume).decode()
    checked = ssh(os.environ["STUDIO_SSH"], preflight_code,
                  dict(m, **frozen_inputs, validator_sha256=validator),
                  timeout=VALIDATE + 120)
    if journey:
        frozen_inputs["requests_code"] = checked.pop("requests_code")
        m["requests_sha256"] = checked["requests_sha256"]
    print(json.dumps(checked), flush=True)
    if not args.run:
        print(json.dumps({"next": "bounded-measurement", "run": False, "source_commit": m["commit"],
                          "policy_sha256": m["policy_sha256"], "window_seconds": TOTAL,
                          "downtime": f"Studio pause/build/cell/restore; buyer runner stopped at most {TOTAL} seconds"}))
        return
    owner = os.environ["MACPROVIDER_OPS_OWNER"]
    lock = str(ROOT / "scripts/ops/live-lock.sh")
    run([lock, "acquire", owner, "--purpose", "issue-2144-baseline"])
    state = Path(os.environ.get("MACPROVIDER_OPS_STATE_DIR", str(Path.home() / ".config/macprovider/ops-state")))
    state.mkdir(mode=0o700, parents=True, exist_ok=True)
    journal = state / "studio-mtp-measurement.json"
    if journal.exists():
        raise Refusal("previous measurement journal requires recovery; lock retained")
    put(journal, {"studio_directory": m["dir"], "source_commit": m["commit"], "uncertain": True})
    certain = False
    runner_start_attempted = False
    def start_runner():
        nonlocal runner_start_attempted
        if not runner_start_attempted:
            runner_start_attempted = True
            runner = pearl(os.environ["PEARL_SSH"], unit)
            if runner.get("runner_active") is not True:
                raise Refusal("Pearl runner restart was not verified")
            print(json.dumps({"buyer_runner": "active"}), flush=True)
    unit = "macprovider-mtp-restore-" + m["nonce"]
    try:
        pearl(os.environ["PEARL_SSH"], unit, True)
        m["entry_code"] = base64.b64encode(code).decode()
        m["probe_code"] = payload["probe_code"]
        m.update(frozen_inputs)
        worker_code = "import sys;sys.argv=['entry.py','_prepare'];" + loader
        result = dispatch_worker(os.environ["STUDIO_SSH"], worker_code, m, start_runner)
        certain = result.get("restored") is True
        print(json.dumps(result))
        if result.get("lab_passed") is not True:
            raise Refusal("lab command failed; signed incumbent restoration verified")
    finally:
        # Always run immediately, including SSH loss. Never wait for Studio
        # readiness here. The Pearl timer remains armed if this controller dies.
        start_runner()
        if certain:
            retirement = pearl(os.environ["PEARL_SSH"], unit, retire=True)
            if retirement.get("timer_retired") is not True:
                raise Refusal("Pearl recovery timer retirement unverified; lock retained")
            journal.unlink()
            run([lock, "release", owner])


def main():
    if len(sys.argv) > 1 and sys.argv[1].startswith("_"):
        mode = sys.argv[1]
        if mode == "_metalcheck":
            # The bench sets MLX's cache limit (device creation and default
            # metallib load) before argument validation. A rejected commit
            # therefore proves the lab binary finds its metallib without a model.
            m = json.loads(Path(sys.argv[2]).read_text())
            command = fixed_command(dict(m, cell="s1-p512-o128"), "cell")
            command[command.index("--provider-commit") + 1] = "metal-check"
            command[command.index("--out") + 1] = str(Path(m["dir"]) / "metalcheck.jsonl")
            result = subprocess.run(command, capture_output=True, text=True, timeout=60)
            output = result.stdout + result.stderr
            print(output, flush=True)
            if "metallib" in output or "--provider-commit must be lowercase 40-hex" not in output:
                raise Refusal("lab binary failed the MLX metallib check")
            return
        if mode == "_matrix":
            m = json.loads(Path(sys.argv[2]).read_text())
            result = subprocess.run(bench_command(m, Path(m["dir"])), timeout=CELL - 10)
            if result.returncode:
                raise Refusal("baseline matrix failed; no retry")
            return
        if mode == "_journey":
            run_journey(json.loads(Path(sys.argv[2]).read_text()))
            return
        if mode == "_acceptance":
            run_acceptance(json.loads(Path(sys.argv[2]).read_text()))
            return
        if mode == "_group":
            gate, kind = int(sys.argv[2]), sys.argv[3]
            m = json.loads(Path(sys.argv[4]).read_text())
            command = fixed_command(m, kind)
            output = Path(sys.argv[5])
            if os.read(gate, 1) != b"1":
                return
            os.close(gate)
            # Xcode discovers a Swift package from its fixed checkout root.
            cwd = (Path(m["source"]) / "phase3-binary/.build/checkouts/mlx-swift-lm"
                   if kind == "fork-tests" else None)
            put(output, {"returncode": subprocess.run(command, cwd=cwd).returncode})
            while True:
                time.sleep(60)
        elif mode == "_inspect":
            print(json.dumps(inspect_remote(json.load(sys.stdin))))
        elif mode == "_preflight":
            print(json.dumps(preflight_remote(json.load(sys.stdin))))
        elif mode == "_prepare":
            m = json.loads(sys.stdin.readline())
            d = Path(m["dir"])
            d.mkdir(mode=0o700, parents=True, exist_ok=False)
            for field, name in (("entry_code", "entry.py"), ("probe_code", "probe.py"), ("policy_code", "policy.json")):
                content = base64.b64decode(m.pop(field))
                if name == "policy.json" and sha(content) != m["policy_sha256"]:
                    raise Refusal("policy bytes drifted")
                (d / name).write_bytes(content)
                (d / name).chmod(0o600)
            if m["cell"] == "acceptance":
                corpus = base64.b64decode(m.pop("corpus_code"), validate=True)
                acceptance_inputs((d / "policy.json").read_bytes(), corpus, m["commit"])
                if sha(corpus) != m["corpus_sha256"]:
                    raise Refusal("acceptance corpus transport differs")
                (d / "acceptance-corpus.json").write_bytes(corpus)
                (d / "acceptance-corpus.json").chmod(0o600)
                transport_checkpoint(m, d, (d / "policy.json").read_bytes(), corpus)
                m.pop("resume_code", None)
            if m["cell"] in JOURNEY_CELLS:
                deliver_journey(m, d)
                frozen = base64.b64decode(m.pop("requests_code"), validate=True)
                if sha(frozen) != m["requests_sha256"]:
                    raise Refusal("journey request transport differs")
                (d / "journey-requests.json").write_bytes(frozen)
                (d / "journey-requests.json").chmod(0o600)
            put(d / "controller-lease.json", {"connected": True, "updated": time.time()})
            threading.Thread(target=lease_reader, args=(d, sys.stdin), daemon=True).start()
            print(json.dumps(worker(m)))
        elif mode == "_watchdog":
            watchdog(json.loads((Path(sys.argv[2]) / "manifest.json").read_text()))
        else:
            raise Refusal("unknown internal operation")
        return
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("status", "next"))
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--policy", type=Path, required=True)
    parser.add_argument("--cell", choices=("s1-p512-o128", "s2-p512-o128", "s4-p512-o128", *MATRICES, "acceptance", *JOURNEY_CELLS), required=True)
    parser.add_argument("--acceptance-corpus", type=Path)
    parser.add_argument("--acceptance-resume", type=Path, help="Private exact frozen complete-case prefix; never a partial qualification")
    parser.add_argument("--journey-signed-inputs", type=Path, help="Frozen private signed-input inventory JSON; journey cells only")
    args = parser.parse_args()
    if args.run and args.action != "next":
        parser.error("--run requires next")
    if (args.cell == "acceptance") != (args.acceptance_corpus is not None):
        parser.error("--acceptance-corpus is required only with --cell acceptance")
    controller(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        reason = str(exc) if isinstance(exc, Refusal) else type(exc).__name__
        print("studio-mtp-measurement: blocked: " + reason + "; journals/lock retained if armed", file=sys.stderr)
        sys.exit(1)
