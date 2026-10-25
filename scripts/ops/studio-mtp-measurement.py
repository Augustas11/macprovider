#!/usr/bin/env python3
"""One bounded GLM exploratory cell, with independent Studio and Pearl recovery.

status / next are read-only. Execution binds this clean campaign commit.
The operator explicitly authorized local measurement extensions for issue 2144. Environment: STUDIO_SSH, PEARL_SSH, STUDIO_MTP_SOURCE_DIR,
STUDIO_MTP_CONFIG, STUDIO_STATUS_PORT, MACPROVIDER_OPS_OWNER. Explicit arguments
bind the clean campaign source commit and immutable exploratory policy. No
operator shell commands or replacement serving binaries are accepted.
"""
from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
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
TOTAL = 2400
BUILD = 900
CELL = 1500
ROOT = Path(__file__).resolve().parents[2]


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


def policy_ok(data, commit, cell):
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
            or cell not in ("s1-p512-o128", "s2-p512-o128", "s4-p512-o128", "matrix")):
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


def fixed_command(m, kind):
    d = Path(m["dir"])
    package = str(Path(m["source"]) / "phase3-binary")
    if kind == "build":
        return ["/usr/bin/xcrun", "swift", "build", "--package-path", package,
                "-c", "release", "-j", "2", "--disable-automatic-resolution",
                "-Xswiftc", "-DMACPROVIDER_LAB_HARNESS", "--product", "macprovider-cli"]
    if kind == "metal":
        if m.get("cached_metal"):
            return [sys.executable, str(d / "entry.py"), "_metal", str(d / "manifest.json")]
        return ["/bin/bash", str(Path(package) / "scripts/build-mlx-metallib.sh"),
                str(Path(package) / ".build/arm64-apple-macosx/release")]
    if kind == "cell" and m["cell"] == "matrix":
        return [sys.executable, str(d / "entry.py"), "_matrix", str(d / "manifest.json")]
    if kind == "cell":
        return [str(Path(package) / ".build/release/macprovider-cli"), "native-mtp-bench",
                "--root", str(Path(m["source"]) / ".lab-window/fixture"),
                "--model-id", MODEL, "--policy", str(d / "policy.json"),
                "--out", str(d / "runs.jsonl"), "--provider-commit", m["commit"],
                "--only-cell", m["cell"], "--phase", "matrix"]
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
                             stderr=subprocess.STDOUT, env={
                                 "HOME": str(Path.home()), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                                 "MACPROVIDER_NATIVE_MTP_E2E": "1"})
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
        until = time.monotonic() + 20
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
        grouped(m, "build", BUILD)
        grouped(m, "metal", BUILD)
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
    return {"restored": True, "lab_passed": failure is None, "failure": failure, "result": str(d / "runs.jsonl"), "source_commit": m["commit"],
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
    if subprocess.run(["xcrun", "-sdk", "macosx", "-find", "metal"],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        # Reuse the existing lab artifact when only Command Line Tools are
        # installed. Pin its bytes before downtime; never substitute live files.
        cached = package / ".build/arm64-apple-macosx/debug/mlx.metallib"
        checkout = package / ".build/checkouts/mlx-swift"
        pin = next(p["state"]["revision"] for p in json.loads((package / "Package.resolved").read_text())["pins"]
                   if p["identity"] == "mlx-swift")
        source_ok(checkout, pin)
        m["cached_metal"] = {"sha256": sha(cached.read_bytes()), "revision": pin}
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


def ssh(host, code, payload, timeout=30):
    if not re.fullmatch(r"[A-Za-z0-9_.@-]+", host) or host.startswith("-") or host == "local":
        raise Refusal("SSH alias required")
    command = "python3 -c " + shlex.quote(code)
    return json.loads(run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8",
                           "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=1",
                           host, command], input=json.dumps(payload).encode(), timeout=timeout))


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
 r(["systemd-run","--collect","--unit="+u,"--on-active=2400s","--timer-property=AccuracySec=1s","/usr/bin/python3","-c",p["recovery_code"],u])
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
    return ssh(host, code, {"unit": unit, "arm": arm, "retire": retire,
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
    policy_ok(data, args.source_commit, args.cell)
    source_ok(ROOT, args.source_commit)
    payload = {"source": source, "commit": args.source_commit, "cell": args.cell,
               "config": os.environ["STUDIO_MTP_CONFIG"], "port": int(os.environ["STUDIO_STATUS_PORT"]),
               "socket_override": os.environ.get("STUDIO_MTP_CTL_SOCKET"),
               "nonce": uuid.uuid4().hex, "policy_sha256": sha(data),
               "probe_code": base64.b64encode((ROOT / "scripts/ops/lib/studio-owner-pin-probe.py").read_bytes()).decode()}
    code = Path(__file__).read_bytes()
    loader = "import base64;__file__='/tmp/macprovider-mtp/entry.py';exec(compile(base64.b64decode(" + repr(base64.b64encode(code).decode()) + "),'entry.py','exec'))"
    # Remote dispatch via stdin leaves host arguments and all secrets out of argv.
    inspect_code = "import sys;sys.argv=['entry.py','_inspect'];" + loader
    m = ssh(os.environ["STUDIO_SSH"], inspect_code, payload)
    published(m)
    if not args.run:
        print(json.dumps({"next": "bounded-measurement", "run": False, "source_commit": m["commit"],
                          "policy_sha256": m["policy_sha256"], "window_seconds": TOTAL,
                          "downtime": "Studio pause/build/cell/restore; buyer runner stopped at most 2400 seconds"}))
        return
    owner = os.environ["MACPROVIDER_OPS_OWNER"]
    lock = str(ROOT / "scripts/ops/live-lock.sh")
    run([lock, "acquire", owner, "--purpose", "issue-2144-bounded-measurement"])
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
        m["policy_code"] = base64.b64encode(data).decode()
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
        if mode == "_metal":
            m = json.loads(Path(sys.argv[2]).read_text())
            package = Path(m["source"]) / "phase3-binary"
            source_ok(package / ".build/checkouts/mlx-swift", m["cached_metal"]["revision"])
            data = (package / ".build/arm64-apple-macosx/debug/mlx.metallib").read_bytes()
            if sha(data) != m["cached_metal"]["sha256"]:
                raise Refusal("cached lab Metal library changed")
            (package / ".build/arm64-apple-macosx/release/mlx.metallib").write_bytes(data)
            print("Reused byte-pinned lab Metal library for the pinned MLX dependency", flush=True)
            return
        if mode == "_matrix":
            m = json.loads(Path(sys.argv[2]).read_text())
            d = Path(m["dir"])
            base = json.loads((d / "policy.json").read_text())
            paths = []
            for shape in ("plain_text", "tools_history_reasoning"):
                for temperature in (0, 1):
                    tag = f"{shape}-t{temperature}"
                    policy = dict(base, request_shape=shape, temperature=temperature,
                                  top_p=1 if temperature == 0 else .95)
                    policy_path = d / (tag + "-policy.json")
                    put(policy_path, policy)
                    paths.append(str(policy_path))
            command = fixed_command(dict(m, cell="s1-p512-o128"), "cell")
            index = command.index("--only-cell")
            del command[index:index + 2]
            index = command.index("--policy")
            command[index:index + 2] = ["--policy-list", *paths]
            command[command.index("--out") + 1] = str(d / "baseline")
            result = subprocess.run(command, timeout=CELL - 10)
            if result.returncode:
                raise Refusal("baseline matrix failed; no retry")
            return
        if mode == "_group":
            gate, kind = int(sys.argv[2]), sys.argv[3]
            m = json.loads(Path(sys.argv[4]).read_text())
            command = fixed_command(m, kind)
            output = Path(sys.argv[5])
            if os.read(gate, 1) != b"1":
                return
            os.close(gate)
            put(output, {"returncode": subprocess.run(command).returncode})
            while True:
                time.sleep(60)
        elif mode == "_inspect":
            print(json.dumps(inspect_remote(json.load(sys.stdin))))
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
    parser.add_argument("--cell", choices=("s1-p512-o128", "s2-p512-o128", "s4-p512-o128", "matrix"), required=True)
    args = parser.parse_args()
    if args.run and args.action != "next":
        parser.error("--run requires next")
    controller(args)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        reason = str(exc) if isinstance(exc, Refusal) else type(exc).__name__
        print("studio-mtp-measurement: blocked: " + reason + "; journals/lock retained if armed", file=sys.stderr)
        sys.exit(1)
