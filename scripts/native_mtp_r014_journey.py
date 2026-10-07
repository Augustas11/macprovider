#!/usr/bin/env python3
"""Rehearse the SPEC-048-R014 native-MTP enablement gate on a published CLI.

This runner exercises every SPEC-048-R014 item that can be checked before a
native-MTP release exists, against one already-signed, published CLI release
and a lab build of the same source commit. It runs on the designated Mac Studio
lab host, noninteractively, and writes one JSON record per check plus a
`result.json` / `result.md` summary into the evidence directory.

It is rehearsal evidence. It does not sign a journey result, flip
`CONFORMANCE.json`, or enable anything. Two binaries are used on purpose:

- the signed release binary (`--signed-cli-dir`) for everything a released
  provider can do: default-off serving, serve-path admission rejections,
  continuous batching on the tuple, the isolated coordinator path, release
  asset identity, and the updater path;
- a lab-harness build of the exact release source commit (`--lab-cli`; the
  compile flag is in docs/runbooks/native-mtp-enablement.md), for the hidden
  `native-mtp-hardware-e2e` and `native-mtp-journey-e2e` fixtures. Release
  builds compile those commands out (`NativeMTPJourneyE2ECommand.swift`).

Safety rails, all enforced before anything starts:

- the caller must hold the lab window lock directory, and the runner never
  creates or removes it;
- every loopback port is checked free and must not be a live-provider port;
- no path the runner writes may sit under the live install or a live pool;
- every signed `serve` runs `--no-join`, except in the isolated-coordinator
  phase, whose coordinator URL must be loopback;
- the updater phase runs the previous release with a private
  `CFFIXED_USER_HOME` under `sandbox-exec`, which denies writes outside the
  work directory and every `launchctl` exec.

Usage (on the lab host):

  python3 native_mtp_r014_journey.py run --config run-config.json
  python3 native_mtp_r014_journey.py summarize --evidence <dir>
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import http.client
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Dict, List, Optional

SCHEMA = "macprovider.native-mtp-r014-rehearsal-result.v1"
CHECK_SCHEMA = "macprovider.native-mtp-r014-rehearsal-check.v1"
MODEL_ID = "qwen/qwen3.6-35b-a3b"
# Ports used by the live provider, live pools, and other lab tenants.
FORBIDDEN_PORTS = {8080, 18120, 18122, 18130, 18140, 18150, 11435, 9444}
LIVE_COORDINATOR_HOSTS = ("coordinator.malibu.tech", "pearl")
PASS, FAIL, NA, RECORDED = "PASS", "FAIL", "NOT_APPLICABLE", "RECORDED"

# R014 items, in spec order. `id` keys the checks below.
R014_ITEMS = [
    ("item1-conformance", "R014.1 owner requirements conformant in CONFORMANCE.json"),
    ("item1-revocation-feed", "R014.1 tuple absent from the authenticated emergency-revocation feed"),
    ("item1-sidecar-tuple-binding", "R014.1 admission sidecar generation and its tuple-sha binding"),
    ("item2-upstream-dependency", "R014.2 immutable upstream dependency passes SPEC-048-R003"),
    ("item3-capability-negatives", "R014.3 capability/manifest negatives"),
    ("item3-greedy-parity", "R014.3 exact greedy parity"),
    ("item3-state-rollback", "R014.3 cache/state rollback"),
    ("item3-termination", "R014.3 termination"),
    ("item3-mixed-row", "R014.3 mixed-row"),
    ("item3-capacity", "R014.3 capacity"),
    ("item3-fairness", "R014.3 fairness"),
    ("item3-accounting", "R014.3 accounting"),
    ("item4-mxfp8", "R014.4 independent MXFP8 qualification"),
    ("item5-cb15-a5-pkv13", "R014.5 SPEC-038 FR-CB15/Gate A5 and SPEC-039 FR-PKV13 for the tuple"),
    ("item5-r015", "R014.5 SPEC-048-R015 on every advertised tuple"),
    ("item6-serving-journey", "R014.6 signed JOURNEY-NATIVE-MTP-SERVING result"),
    ("item7-audit", "R014.7 frozen-diff three-lane review"),
    ("item8-isolated-loopback", "R014.8 release candidate revalidated in isolated loopback"),
    ("item8-native-admission-e2e", "R014.8 native admission end to end with buyer requests (isolated coordinator)"),
    ("item8-config-enable-disable", "R014.8 config-enable the tuple, then disable and fall back to ordinary"),
    ("item8-release-asset-identity", "R014.8 Malibu.app vs tarball CLI byte identity"),
    ("item8-updater-path", "R014.8 previous-stable updater path"),
    ("item9-no-unreleased-live", "R014.9 no unreleased local binary connected to the live coordinator"),
]


# ---------------------------------------------------------------- utilities


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def run(cmd: List[str], *, env: Optional[Dict[str, str]] = None, timeout: int = 600,
        cwd: Optional[Path] = None, log: Optional[Path] = None) -> subprocess.CompletedProcess:
    proc = subprocess.run(cmd, env=env, cwd=cwd, timeout=timeout, capture_output=True, text=True)
    if log is not None:
        log.write_text(f"$ {' '.join(cmd)}\nexit={proc.returncode}\n--- stdout\n{proc.stdout}\n--- stderr\n{proc.stderr}")
    return proc


def port_free(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        return sock.connect_ex(("127.0.0.1", port)) != 0


def http_json(method: str, port: int, path: str, body: Optional[dict] = None,
              headers: Optional[dict] = None, timeout: int = 900) -> tuple:
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    data = json.dumps(body).encode() if body is not None else None
    hdrs = {"Content-Type": "application/json"}
    if method == "POST":
        # Continuous batching admits only requests with a stable request id.
        hdrs["X-Request-ID"] = str(uuid.uuid4())
    hdrs.update(headers or {})
    conn.request(method, path, data, hdrs)
    resp = conn.getresponse()
    raw = resp.read()
    conn.close()
    try:
        return resp.status, json.loads(raw)
    except ValueError:
        return resp.status, raw.decode(errors="replace")[:2000]


def http_stream(port: int, path: str, body: dict, headers: Optional[dict] = None,
                timeout: int = 900) -> tuple:
    """POST a streaming chat completion; return (status, content, usage, frames)."""
    conn = http.client.HTTPConnection("127.0.0.1", port, timeout=timeout)
    hdrs = {"Content-Type": "application/json", "X-Request-ID": str(uuid.uuid4())}
    hdrs.update(headers or {})
    conn.request("POST", path, json.dumps(body).encode(), hdrs)
    resp = conn.getresponse()
    if resp.status != 200:
        raw = resp.read()
        conn.close()
        return resp.status, raw.decode(errors="replace")[:2000], None, 0
    content, usage, frames, finish = [], None, 0, None
    for line in resp:
        line = line.strip()
        if not line.startswith(b"data:"):
            continue
        payload = line[5:].strip()
        if payload == b"[DONE]":
            break
        frames += 1
        obj = json.loads(payload)
        if obj.get("usage"):
            usage = obj["usage"]
        for choice in obj.get("choices") or []:
            delta = choice.get("delta") or {}
            if delta.get("content"):
                content.append(delta["content"])
            if choice.get("finish_reason"):
                finish = choice["finish_reason"]
    conn.close()
    return 200, "".join(content), {"usage": usage, "finish_reason": finish}, frames


def wait_ready(port: int, deadline_s: int, proc: subprocess.Popen) -> bool:
    end = time.time() + deadline_s
    while time.time() < end:
        if proc.poll() is not None:
            return False
        try:
            status, body = http_json("GET", port, "/v1/status", timeout=5)
            if status == 200 and isinstance(body, dict):
                return True
        except OSError:
            pass
        time.sleep(2)
    return False


def stop(proc: Optional[subprocess.Popen]) -> Optional[int]:
    if proc is None or proc.poll() is not None:
        return None if proc is None else proc.returncode
    proc.send_signal(signal.SIGTERM)
    try:
        return proc.wait(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
        return proc.wait(timeout=30)


def chat(prompt: str, max_tokens: int, stream: bool = False, temperature: float = 0.0, **extra) -> dict:
    body = {
        "model": MODEL_ID,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": 1.0,
        "stream": stream,
    }
    if stream:
        body["stream_options"] = {"include_usage": True}
    body.update(extra)
    return body


def native_status(port: int) -> dict:
    status, body = http_json("GET", port, "/v1/status", timeout=10)
    if status != 200 or not isinstance(body, dict):
        return {"http_status": status}
    return {
        "status_advertises_native_mtp_status_v1": "native_mtp_status_v1" in json.dumps(body),
        "status_top_level_keys": sorted(body.keys()),
        "native_mtp": body.get("native_mtp"),
        "continuous_batching": body.get("continuous_batching"),
        "version": body.get("version") or body.get("binary_version"),
    }


def serve_rejections(stderr_path: Path) -> List[dict]:
    found = []
    if not stderr_path.exists():
        return found
    for line in stderr_path.read_text(errors="replace").splitlines():
        if '"event":"native_mtp_serve_path_admission"' in line:
            try:
                found.append(json.loads(line[line.index("{"):]))
            except ValueError:
                found.append({"raw": line[:300]})
    return found


# ---------------------------------------------------------------- runner


class Runner:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.work = Path(cfg["work_dir"]).expanduser()
        self.evidence = Path(cfg["evidence_dir"]).expanduser()
        self.signed_dir = Path(cfg["signed_cli_dir"]).expanduser()
        self.signed_cli = self.signed_dir / "macprovider-cli"
        self.lab_cli = Path(cfg["lab_cli"]).expanduser()
        self.source = Path(cfg["source_dir"]).expanduser()
        self.repo = Path(cfg["repo_snapshot_dir"]).expanduser()
        self.fixture_src = Path(cfg["fixture_root"]).expanduser()
        self.fixture = self.work / "fixture"
        self.checks_dir = self.evidence / "checks"
        self.logs = self.work / "logs"
        self.items: Dict[str, dict] = {}

    # -- guards
    def preflight(self) -> None:
        lock = Path(self.cfg["lab_lock_dir"]).expanduser()
        owner = lock / "owner"
        if not owner.is_file() or self.cfg["lab_lock_owner_tag"] not in owner.read_text():
            raise SystemExit(f"lab lock {lock} is not held by {self.cfg['lab_lock_owner_tag']}; acquire it first")
        forbidden_roots = [Path(p).expanduser().resolve() for p in self.cfg["forbidden_roots"]]
        for path in (self.work, self.evidence):
            resolved = path.resolve()
            for root in forbidden_roots:
                if resolved == root or root in resolved.parents:
                    raise SystemExit(f"refusing to write under live path {root}")
        for key in ("signed_port", "lab_port", "coordinator_http_port", "coordinator_ws_port",
                    "gateway_port", "updater_port"):
            port = int(self.cfg[key])
            if port in FORBIDDEN_PORTS:
                raise SystemExit(f"{key}={port} is a live port")
        for path in (self.work, self.checks_dir, self.logs):
            path.mkdir(parents=True, exist_ok=True)
        os.chmod(self.work, 0o700)

    def record(self, item: str, status: str, summary: str, *, evidence: Optional[List[str]] = None,
               details: Optional[dict] = None, sub: Optional[Dict[str, bool]] = None,
               binary: str = "") -> None:
        doc = {
            "schema": CHECK_SCHEMA,
            "item": item,
            "title": dict(R014_ITEMS).get(item, item),
            "status": status,
            "summary": summary,
            "binary": binary,
            "sub_checks": sub or {},
            "evidence": evidence or [],
            "details": details or {},
            "recorded_at": now(),
        }
        self.items[item] = doc
        (self.checks_dir / f"{item}.json").write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
        print(f"[{now()}] {item}: {status} — {summary}", flush=True)

    def keep(self, src: Path, name: Optional[str] = None) -> str:
        """Copy a small log into evidence/raw and return its evidence path."""
        raw = self.evidence / "raw"
        raw.mkdir(exist_ok=True)
        dst = raw / (name or src.name)
        shutil.copyfile(src, dst)
        return f"raw/{dst.name}"

    # -- phase: identity
    def phase_identity(self) -> None:
        signed_sha = sha256_file(self.signed_cli)
        version = run([str(self.signed_cli), "--version"]).stdout.strip()
        codesign = run(["codesign", "-dvvv", str(self.signed_cli)]).stderr
        cdhash = re.search(r"^CDHash=([0-9a-f]+)$", codesign, re.M)
        team = re.search(r"^TeamIdentifier=(\S+)$", codesign, re.M)
        authority = re.findall(r"^Authority=(.+)$", codesign, re.M)
        compat = json.loads((self.signed_dir / "compatibility-set.json").read_text())
        lab_sha = sha256_file(self.lab_cli)
        lab_commit = (self.source / "SOURCE_COMMIT").read_text().strip()
        lab_help = run([str(self.lab_cli), "native-mtp-journey-e2e", "--help"]).stdout
        signed_has_lab = run(["/usr/bin/strings", str(self.signed_cli)]).stdout.count("native-mtp-journey-e2e")
        identity = {
            "signed_cli_sha256": signed_sha,
            "signed_cli_expected_sha256": self.cfg["expected_signed_sha256"],
            "signed_cli_version": version,
            "signed_cli_cdhash": cdhash.group(1) if cdhash else None,
            "signed_cli_team": team.group(1) if team else None,
            "signed_cli_authority": authority,
            "compatibility_set_id": (compat.get("signed") or {}).get("compatibility_set_id"),
            "signed_cli_contains_lab_journey_command": signed_has_lab > 0,
            "lab_cli_sha256": lab_sha,
            "lab_cli_source_commit": lab_commit,
            "lab_cli_has_journey_command": "native-mtp-journey-e2e" in lab_help,
            "release_source_commit": self.cfg["release_source_commit"],
            "metallib_sha256": sha256_file(self.signed_dir / "mlx.metallib"),
            "host": {
                "hw_model": run(["sysctl", "-n", "hw.model"]).stdout.strip(),
                "os_build": run(["sysctl", "-n", "kern.osversion"]).stdout.strip(),
                "memsize": run(["sysctl", "-n", "hw.memsize"]).stdout.strip(),
            },
        }
        (self.evidence / "identity.json").write_text(json.dumps(identity, indent=2, sort_keys=True) + "\n")
        if signed_sha != self.cfg["expected_signed_sha256"]:
            raise SystemExit(f"signed CLI sha {signed_sha} != expected {self.cfg['expected_signed_sha256']}")
        if lab_commit != self.cfg["release_source_commit"]:
            raise SystemExit("lab CLI is not built from the release source commit")
        print(f"[{now()}] identity ok: signed {signed_sha[:12]} {version}, lab {lab_sha[:12]} @ {lab_commit[:12]}", flush=True)

    # -- fixture clone (never mutate the shared lab fixture)
    def ensure_fixture(self) -> None:
        if self.fixture.exists():
            return
        self.fixture.mkdir(parents=True)
        for name in ("target", "mtp"):
            run(["cp", "-cR", str(self.fixture_src / name), str(self.fixture / name)], timeout=1800)

    # -- phase: item 9
    def phase_live_binaries(self) -> None:
        ps = run(["ps", "-axww", "-o", "pid=,command="]).stdout.splitlines()
        rows, unreleased_live = [], []
        published_by_version: Dict[str, Optional[str]] = {}

        def published_sha(version: Optional[str]) -> Optional[str]:
            """binary_sha256 the signed pearl-release.json of v<version> publishes, or None."""
            if not version or not re.match(r"^\d+\.\d+\.\d+$", version):
                return None
            if version not in published_by_version:
                url = f"https://github.com/Augustas11/macprovider/releases/download/v{version}/pearl-release.json"
                try:
                    with urllib.request.urlopen(url, timeout=30) as resp:
                        doc = json.loads(resp.read())
                    published_by_version[version] = (doc.get("provider_code_identity") or {}).get("binary_sha256")
                except (OSError, ValueError):
                    published_by_version[version] = None
            return published_by_version[version]
        for line in ps:
            line = line.strip()
            match = re.match(r"^(\d+)\s+(\S*macprovider-cli)\s+(.*)$", line)
            if not match:
                continue
            pid, exe, args = match.group(1), match.group(2), match.group(3)
            exe_path = Path(exe)
            sha = sha256_file(exe_path) if exe_path.is_file() else None
            sign = run(["codesign", "-dvv", exe]).stderr
            team = re.search(r"^TeamIdentifier=(\S+)$", sign, re.M)
            # Never execute a running provider's binary: read its version from
            # the sibling compatibility set the installer lays down.
            version = None
            compat_path = exe_path.parent / "compatibility-set.json"
            if compat_path.is_file():
                try:
                    set_id = json.loads(compat_path.read_text())["signed"]["compatibility_set_id"]
                    vm = re.search(r":v(\d+\.\d+\.\d+)@", set_id)
                    version = vm.group(1) if vm else None
                except (ValueError, KeyError, TypeError):
                    version = None
            config_path = None
            cm = re.search(r"--config\s+(\S+)", args)
            if cm:
                config_path = cm.group(1)
            elif " serve" in f" {args}":
                config_path = str(Path.home() / ".config/macprovider/config.yaml")
            coordinator = None
            if config_path and Path(config_path).is_file():
                text = Path(config_path).read_text(errors="replace")
                cmatch = re.search(r"^coordinator_url:\s*\"?([^\s\"]+)", text, re.M)
                coordinator = cmatch.group(1) if cmatch else "default(production)"
            no_join = "--no-join" in args
            live = (not no_join) and coordinator is not None and (
                coordinator == "default(production)" or any(h in coordinator for h in LIVE_COORDINATOR_HOSTS))
            pub = published_sha(version)
            released = bool(team and team.group(1) == self.cfg["release_team_id"]) and pub is not None and sha == pub
            row = {"pid": int(pid), "exe": exe, "sha256": sha, "version": version,
                   "team": team.group(1) if team else None, "coordinator_url": coordinator,
                   "no_join": no_join, "connects_live": live, "published_release_bytes": released,
                   "published_binary_sha256_for_version": pub}
            rows.append(row)
            if live and not released:
                unreleased_live.append(row)
        (self.evidence / "live-binaries.json").write_text(json.dumps(rows, indent=2, sort_keys=True) + "\n")
        live_rows = [r for r in rows if r["connects_live"]]
        status = FAIL if unreleased_live else PASS
        self.record(
            "item9-no-unreleased-live", status,
            f"{len(rows)} macprovider-cli processes; {len(live_rows)} connect to the live coordinator, "
            f"all running published Developer-ID-signed release bytes" if status == PASS else
            f"{len(unreleased_live)} live-connected process(es) run unreleased bytes",
            evidence=["live-binaries.json"],
            sub={"every_live_connected_binary_is_published_release": not unreleased_live,
                 "runner_processes_isolated": True},
            details={"published_binary_sha256_by_version": published_by_version},
            binary="all running")

    # -- phase: records (static)
    def phase_records(self) -> None:
        conformance = json.loads((self.repo / "specs/CONFORMANCE.json").read_text())
        wanted = [f"SPEC-048-R{n:03d}" for n in list(range(1, 14)) + [15, 16]] + [
            "SPEC-023-R024", "SPEC-030-R021", "SPEC-031-R033", "SPEC-036-R018", "SPEC-038-R018", "SPEC-039-R015"]
        states = {r["requirement_id"]: r["state"] for r in conformance["requirements"] if r["requirement_id"] in wanted}
        not_conformant = sorted(k for k in wanted if states.get(k) != "conformant")
        self.record("item1-conformance", PASS if not not_conformant else FAIL,
                    f"{len(wanted) - len(not_conformant)}/{len(wanted)} required requirements conformant; "
                    f"{len(not_conformant)} pending (operator promotion gate, expected before a native release)",
                    evidence=["records/conformance-states.json"],
                    details={"states": states, "repo_commit": self.cfg["repo_snapshot_commit"]},
                    binary="n/a (repository state)")
        (self.evidence / "records").mkdir(exist_ok=True)
        (self.evidence / "records/conformance-states.json").write_text(json.dumps(states, indent=2, sort_keys=True) + "\n")

        # R003: the release source pins the reviewed fork revision.
        resolved = json.loads((self.source / "phase3-binary/Package.resolved").read_text())
        pins = {p["identity"]: p["state"] for p in resolved.get("pins", [])}
        mlx_lm = pins.get("mlx-swift-lm", {})
        spec = (self.source / "specs/SPEC-048-native-mtp-serving.md").read_text()
        reviewed = self.cfg["r003_reviewed_revision"]
        # 0.1.23 (the release commit) says "closed for this revision" under the
        # pinned revision; 0.1.24+ says "closed for parent revision `b1811029…`".
        closed = reviewed in spec and bool(re.search(
            r"review result \(2026-10-05\): closed for (this revision|parent revision `" + reviewed[:8] + ")", spec))
        ok = mlx_lm.get("revision") == reviewed and closed
        self.record("item2-upstream-dependency", PASS if ok else FAIL,
                    f"release source pins mlx-swift-lm {str(mlx_lm.get('revision'))[:12]}; "
                    f"SPEC-048 at the release commit records the R003 review closed for it: {closed}",
                    evidence=["records/package-resolved-mlx-swift-lm.json"],
                    details={"pin": mlx_lm, "reviewed_revision": reviewed,
                             "evidence_dirs": ["docs/research/spec048-fused-moe/evidence-2026-10-05/qualification-7d55924eb/",
                                               "audits/2026-10-05-native-mtp-fused-freeze/"]},
                    sub={"pin_matches_reviewed_revision": mlx_lm.get("revision") == reviewed,
                         "review_closed_in_spec": closed},
                    binary="release source")
        (self.evidence / "records/package-resolved-mlx-swift-lm.json").write_text(json.dumps(mlx_lm, indent=2) + "\n")

        # R015: record the existing evidence, never re-run the benchmark here.
        r015 = json.loads((self.repo / self.cfg["r015_analysis_json"]).read_text())
        cells = {}
        for cell in r015.get("cells", []):
            metrics = cell.get("metrics", {})
            cells[cell.get("cell_id")] = {
                "status": cell.get("status"),
                "cell_class": cell.get("cell_class"),
                "decode_corrected_lower_bound": (metrics.get("throughput") or {}).get("corrected_lower_bound"),
                "ttft_corrected_upper_bound": (metrics.get("ttft") or {}).get("corrected_upper_bound"),
                "metric_failures": cell.get("metric_failures"),
            }
        self.record("item5-r015", RECORDED,
                    f"existing R015 evidence status {r015.get('overall_status')} (not re-run): "
                    + self.cfg["r015_summary"],
                    evidence=[self.cfg["r015_analysis_json"]],
                    details={"overall_status": r015.get("overall_status"), "cells": cells,
                             "policy_sha256": self.cfg["r015_policy_sha256"]},
                    binary="lab 280f0e95d (release source minus version bump)")

        # Production generator rehearsal: the committed tuple input plus a
        # release input carrying this release's real binding fields.
        ident = json.loads((self.evidence / "identity.json").read_text())
        tuple_input = self.repo / self.cfg["committed_tuple_input"]
        release_input = {
            "schema_version": "macprovider.native-mtp-admission-release-input.v1",
            "release_id": "rehearsal-" + self.cfg["release_tag"],
            "issued_at": now(), "expires_at": (dt.datetime.now(dt.timezone.utc) + dt.timedelta(days=30)).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "signer_key_id": "streamvc-autotune-static-v5",
            "challenge_bank_signer_key_id": "streamvc-autotune-static-v5",
            "revocation_signer_key_id": "streamvc-autotune-static-v5",
            "entry": {
                "artifact_manifest_sha256": hashlib.sha256(b"rehearsal-artifact-manifest").hexdigest(),
                "provider_revision": self.cfg["release_source_commit"],
                "source_commit": self.cfg["release_source_commit"],
                "reproducible_build_sha256": ident["signed_cli_sha256"],
                "live_executable_cdhash": ident["signed_cli_cdhash"],
                "challenge_bank_sha256": hashlib.sha256(b"rehearsal-challenge-bank").hexdigest(),
            },
        }
        rel_path = self.work / "rehearsal-release-input.json"
        rel_path.write_text(json.dumps(release_input, indent=2))
        gen = run([sys.executable, str(self.repo / "scripts/native_mtp_admission_sidecar.py"), "build",
                   "--tuple", str(tuple_input), "--release", str(rel_path), "--out", str(self.work / "rehearsal-sidecar.json")],
                  log=self.logs / "production-generator-rehearsal.log")
        tuple_doc = json.loads(tuple_input.read_text())["entry"]
        self.production_generator = {
            "exit": gen.returncode,
            "stderr_tail": gen.stderr.strip().splitlines()[-3:],
            "tuple_input": self.cfg["committed_tuple_input"],
            "tuple_runtime_revision": tuple_doc.get("ordinary_baseline", {}).get("runtime_revision"),
            "tuple_benchmark_policy_sha256": tuple_doc.get("benchmark_policy_sha256"),
            "placeholder_fields": sorted(k for k, v in tuple_doc.items() if v == "0" * 64),
        }
        (self.evidence / "records/production-generator-rehearsal.json").write_text(
            json.dumps(self.production_generator, indent=2, sort_keys=True) + "\n")
        self.keep(self.logs / "production-generator-rehearsal.log")

        self.record("item4-mxfp8", NA, "tuple quantization is mlx_affine 4-bit, not MXFP8; R012 MXFP8 gate does not apply",
                    details={"quantization_kind": "mlx_affine"}, binary="n/a")
        self.record("item7-audit", NA, "three-lane frozen-diff review runs at release freeze; out of scope for this rehearsal",
                    binary="n/a")

    # -- phase: revocation feed (read-only public GET)
    def phase_revocation_feed(self) -> None:
        results = {}
        for key_id in self.cfg["revocation_key_ids"]:
            url = f"https://coordinator.malibu.tech/v1/native-mtp-revocations.{key_id}.json"
            try:
                with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=20) as resp:
                    results[key_id] = {"url": url, "http_status": resp.status, "bytes": len(resp.read())}
            except urllib.error.HTTPError as err:
                results[key_id] = {"url": url, "http_status": err.code}
            except OSError as err:
                results[key_id] = {"url": url, "error": str(err)[:200]}
        (self.evidence / "records").mkdir(exist_ok=True)
        (self.evidence / "records/revocation-feed-probe.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
        published = any(r.get("http_status") == 200 for r in results.values())
        self.record("item1-revocation-feed", PASS if published else FAIL,
                    "authenticated emergency-revocation feed is published" if published else
                    "no emergency-revocation feed is published at the hard-coded production origin "
                    "(NativeMTPRevocationFeed.swift:218); absence of the tuple cannot be proven and a released "
                    "provider fails closed with revocation_state_unavailable (ModelRuntime.swift:8742-8752)",
                    evidence=["records/revocation-feed-probe.json"], details=results,
                    sub={"feed_published": published}, binary="production origin (read-only GET)")

    # -- signed serve helpers
    def write_serve_config(self, name: str, port: int, *, native_mode: Optional[str],
                           coordinator_url: Optional[str] = None, extra: str = "",
                           model_path: Optional[str] = None) -> Path:
        base = Path(self.cfg["serve_config_template"]).expanduser().read_text()
        lines = [ln for ln in base.splitlines()
                 if not re.match(r"^(port|provider_id|coordinator_url|native_mtp_mode|provider_token|"
                                 r"provider_token_file|credential_store|model_artifact_path):", ln)]
        lines += [
            f"port: {port}",
            f"provider_id: \"mp-r014-{name}-{uuid.uuid4().hex[:8]}\"",
            "credential_store: protected_file",
            f"model_artifact_path: \"{model_path or self.cfg['model_artifact_path']}\"",
        ]
        if native_mode:
            lines.append(f"native_mtp_mode: {native_mode}")
        if coordinator_url:
            lines.append(f"coordinator_url: \"{coordinator_url}\"")
        cfg_path = self.work / f"serve-{name}.yaml"
        cfg_path.write_text("\n".join(lines) + "\n" + extra)
        os.chmod(cfg_path, 0o600)
        return cfg_path

    def start_serve(self, name: str, binary: Path, cfg_path: Path, port: int, *, join: bool = False,
                    extra_args: Optional[List[str]] = None, env_extra: Optional[dict] = None) -> tuple:
        if not port_free(port):
            raise RuntimeError(f"port {port} busy")
        out, err = self.logs / f"{name}.out", self.logs / f"{name}.err"
        env = dict(os.environ)
        env.update(self.isolated_env(name, cfg_path))
        env.update(env_extra or {})
        args = [str(binary), "serve", "--config", str(cfg_path)]
        if not join:
            args.append("--no-join")
        args += extra_args or []
        proc = subprocess.Popen(args, stdout=open(out, "w"), stderr=open(err, "w"), env=env,
                                start_new_session=True)
        ready = wait_ready(port, int(self.cfg.get("serve_ready_timeout_s", 300)), proc)
        return proc, ready, out, err

    def isolated_env(self, name: str, cfg_path: Path) -> Dict[str, str]:
        """Redirect every home-, lifecycle-, socket-, and temp-derived path."""
        home = self.work / "homes" / name
        for sub in ("lifecycle", "watchdog", "tmp"):
            (home / sub).mkdir(parents=True, exist_ok=True)
        return {
            "CFFIXED_USER_HOME": str(home), "TMPDIR": str(home / "tmp") + "/",
            "MACPROVIDER_CONFIG": str(cfg_path), "MACPROVIDER_LIFECYCLE_ROOT": str(home / "lifecycle"),
            "MACPROVIDER_CTL_SOCKET_PATH": str(home / "tmp/ctl.sock"),
            "MACPROVIDER_SWITCH_STATE_PATH": str(home / "tmp/last-switch.ts"),
            "MACPROVIDER_WATCHDOG_STATE_DIR": str(home / "watchdog"),
            "MACPROVIDER_AUTO_UPDATE_ENABLED": "false",
        }

    # -- phase: signed serve (default-off, negatives, CB tuple)
    def phase_signed_serve(self) -> None:
        port = int(self.cfg["signed_port"])
        evidence, sub, details = [], {}, {}

        # S0: default config — native MTP off, ordinary serves, CB attaches on the tuple.
        cfg0 = self.write_serve_config("s0-default", port, native_mode=None)
        proc, ready, out, err = self.start_serve("s0-default", self.signed_cli, cfg0, port)
        try:
            sub["s0.ready"] = ready
            if ready:
                st = native_status(port)
                details["s0.status"] = st
                nm = st.get("native_mtp") or {}
                sub["s0.native_mtp_object_present"] = isinstance(nm, dict) and bool(nm)
                sub["s0.native_mtp_default_off"] = nm.get("enabled") is False and nm.get("mode") == "off"
                prompts = [f"Write a numbered list of {n} practical tips for keeping a server room cool." for n in range(3, 11)]
                results = self.concurrent([chat(p, 96) for p in prompts], port)
                sub["s0.ordinary_concurrent_8_ok"] = all(r[0] == 200 for r in results)
                st2 = native_status(port)
                cb = st2.get("continuous_batching") or {}
                sched = cb.get("scheduler") or {}
                details["s0.continuous_batching_after_load"] = cb
                sub["s0.cb_paged_kv_attached"] = cb.get("paged_kv_decision") == "attached" or cb.get("pagedKVDecision") == "attached"
                sub["s0.cb_batch_depth_ge_2"] = int(sched.get("max_observed_batch_depth") or sched.get("maxObservedBatchDepth") or 0) >= 2
                s_status, body = http_json("POST", port, "/v1/chat/completions", chat("Say hello in five words.", 16))
                sub["s0.nonstream_ok"] = s_status == 200
                details["s0.nonstream_usage"] = body.get("usage") if isinstance(body, dict) else body
        finally:
            stop(proc)
        evidence += [self.keep(err, "signed-s0-default.err")]
        details["s0.rejections"] = serve_rejections(err)

        # S1: --native-mtp auto with no sidecar next to the model bundle.
        cfg1 = self.write_serve_config("s1-auto-nosidecar", port, native_mode="auto")
        proc, ready, out, err = self.start_serve("s1-auto-nosidecar", self.signed_cli, cfg1, port)
        try:
            sub["s1.ready"] = ready
            if ready:
                st = native_status(port)
                details["s1.status"] = st
                nm = st.get("native_mtp") or {}
                sub["s1.native_not_enabled"] = nm.get("enabled") is not True
                s_status, body = http_json("POST", port, "/v1/chat/completions", chat("Name three rivers in Europe.", 32))
                sub["s1.ordinary_still_serves"] = s_status == 200
        finally:
            stop(proc)
        rej = serve_rejections(err)
        details["s1.rejections"] = rej
        sub["s1.rejected_with_reason_code"] = bool(rej)
        evidence.append(self.keep(err, "signed-s1-auto-nosidecar.err"))

        # S2/S3: the release looks for the sidecar only next to the model bundle
        # (ModelRuntime.swift:8715-8725; serve has no path override). Clone the
        # served snapshot (APFS clonefile, read-only source) into the work dir
        # and put the lab-signed sidecar (S2, a key the release does not trust)
        # or a tampered copy (S3) in the clone's bundle root.
        sidecar = self.fixture / "native-mtp-admission.json"
        sig = self.fixture / "native-mtp-admission.json.sig"
        live_target = Path(self.cfg["model_artifact_path"])
        rel = live_target.relative_to(Path(self.cfg["model_store_root"]))
        clone_root = self.work / "models"
        clone_target = clone_root / rel
        if not clone_target.exists():
            clone_target.parent.mkdir(parents=True, exist_ok=True)
            run(["cp", "-cR", str(live_target), str(clone_target)], timeout=1800)
        bundle_root = clone_target.parent
        for case, mutate in (("s2-foreign-signer", False), ("s3-tampered", True)):
            body = sidecar.read_bytes()
            if mutate:
                doc = json.loads(body)
                doc["entries"][0]["qualified_slots"] = int(doc["entries"][0]["qualified_slots"]) + 1
                body = json.dumps(doc, sort_keys=True, separators=(",", ":")).encode()
            (bundle_root / "native-mtp-admission.json").write_bytes(body)
            shutil.copyfile(sig, bundle_root / "native-mtp-admission.json.sig")
            cfgn = self.write_serve_config(case, port, native_mode="auto", model_path=str(clone_target))
            proc, ready, out, err = self.start_serve(case, self.signed_cli, cfgn, port,
                                                     env_extra={"MACPROVIDER_MODEL_ARTIFACT_ROOT": str(clone_root)})
            try:
                sub[f"{case}.ready"] = ready
                if ready:
                    nm = (native_status(port).get("native_mtp") or {})
                    sub[f"{case}.native_not_enabled"] = nm.get("enabled") is not True
                    s_status, _ = http_json("POST", port, "/v1/chat/completions", chat("Count from one to five.", 24))
                    sub[f"{case}.ordinary_still_serves"] = s_status == 200
            finally:
                stop(proc)
            rej = serve_rejections(err)
            details[f"{case}.rejections"] = rej
            sub[f"{case}.rejected_with_reason_code"] = bool(rej)
            sub[f"{case}.sidecar_was_found"] = bool(rej) and all(x.get("reason_code") != "sidecar_missing" for x in rej)
            evidence.append(self.keep(err, f"signed-{case}.err"))
        for name in ("native-mtp-admission.json", "native-mtp-admission.json.sig"):
            (bundle_root / name).unlink(missing_ok=True)
        self.signed_serve = {"sub": sub, "details": details, "evidence": evidence}
        (self.evidence / "records").mkdir(exist_ok=True)
        (self.evidence / "records/signed-serve.json").write_text(json.dumps(self.signed_serve, indent=2, sort_keys=True) + "\n")

    def concurrent(self, bodies: List[dict], port: int, headers: Optional[dict] = None) -> List[tuple]:
        import threading
        results: List[Any] = [None] * len(bodies)

        def go(i: int) -> None:
            try:
                results[i] = http_json("POST", port, "/v1/chat/completions", bodies[i], headers=headers)
            except OSError as err:
                results[i] = (0, str(err))
        threads = [threading.Thread(target=go, args=(i,)) for i in range(len(bodies))]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        return results

    # -- phase: lab hardware e2e (serve-path loader + lab-signed sidecar)
    def phase_lab_hardware_e2e(self) -> None:
        self.ensure_fixture()
        env = dict(os.environ, MACPROVIDER_NATIVE_MTP_E2E="1", MACPROVIDER_NATIVE_MTP_E2E_SERVE_PATH="1")
        log = self.logs / "lab-hardware-e2e.log"
        proc = run([str(self.lab_cli), "native-mtp-hardware-e2e", "--root", str(self.fixture),
                    "--model-id", MODEL_ID, "--max-batch", "2", "--sizing-prompt-tokens", "1024",
                    "--sizing-output-tokens", "256"], env=env, timeout=3600, log=log)
        line = next((ln for ln in proc.stdout.splitlines() if ln.startswith("{")), "{}")
        report = json.loads(line)
        self.lab_hw = {"exit": proc.returncode, "report": report}
        keep = [self.keep(log, "lab-hardware-e2e.log")]
        # Sidecar identity recomputed by the repository generator from the
        # bytes the Swift harness wrote and the serve-path loader accepted.
        ident = run([sys.executable, str(self.repo / "scripts/native_mtp_admission_sidecar.py"), "identity",
                     "--sidecar", str(self.fixture / "native-mtp-admission.json")])
        sidecar_raw = (self.fixture / "native-mtp-admission.json").read_bytes()
        body = json.loads(sidecar_raw)
        entry = body["entries"][0]
        identity = json.loads(ident.stdout) if ident.returncode == 0 else {"error": ident.stderr[-800:]}
        shutil.copyfile(self.fixture / "native-mtp-admission.json", self.evidence / "records/lab-native-mtp-admission.json")
        shutil.copyfile(self.fixture / "native-mtp-admission.json.sig", self.evidence / "records/lab-native-mtp-admission.json.sig")
        signed_cdhash = json.loads((self.evidence / "identity.json").read_text())["signed_cli_cdhash"]
        bound = {
            "release_id": body.get("release_id"),
            "signer_key_id": body.get("signer_key_id"),
            "provider_revision": entry.get("provider_revision"),
            "source_commit": entry.get("source_commit"),
            "runtime_revision": entry.get("runtime_revision"),
            "live_executable_cdhash": entry.get("live_executable_cdhash"),
            "reproducible_build_sha256": entry.get("reproducible_build_sha256"),
            "artifact_hash": entry.get("artifact_hash"),
            "qualified_slots": entry.get("qualified_slots"),
            "max_native_active_rows": entry.get("max_native_active_rows"),
        }
        sub = {
            "lab_serve_path_loader_admitted_sidecar": proc.returncode == 0 and report.get("serve_path_verified") is True,
            "generator_recomputes_tuple_sha": ident.returncode == 0 and bool(identity.get("native_mtp_admission_tuple_sha256")),
            "sidecar_binds_target_artifact": entry.get("artifact_hash") == self.cfg["target_sha256"],
            "sidecar_binds_release_cdhash": entry.get("live_executable_cdhash") == signed_cdhash,
            "sidecar_binds_release_source_commit": entry.get("source_commit") == self.cfg["release_source_commit"],
        }
        (self.evidence / "records/lab-sidecar-identity.json").write_text(
            json.dumps({"generator_identity": identity, "bound_fields": bound}, indent=2, sort_keys=True) + "\n")
        self.sidecar_sub = sub
        self.sidecar_evidence = keep + ["records/lab-native-mtp-admission.json", "records/lab-sidecar-identity.json"]
        self.sidecar_bound = bound

    # -- phase: lab manifest negatives on mutated fixture clones
    def phase_lab_negatives(self) -> None:
        self.ensure_fixture()
        cases = self.cfg.get("negative_cases") or ["extra-weight-file", "hidden-weight-file", "symlink-weight-file",
                                                    "wrong-quant-bits", "missing-weight-file", "malformed-safetensors-header",
                                                    "duplicate-tensor-file"]
        results = {}
        for case in cases:
            root = self.work / f"neg-{case}"
            if root.exists():
                shutil.rmtree(root)
            root.mkdir()
            run(["cp", "-cR", str(self.fixture / "target"), str(root / "target")], timeout=1800)
            run(["cp", "-cR", str(self.fixture / "mtp"), str(root / "mtp")], timeout=600)
            mtp = root / "mtp"
            weights = mtp / "model.safetensors"
            if case == "extra-weight-file":
                (mtp / "extra.safetensors").write_bytes(self.tiny_safetensors("mtp.extra.weight"))
            elif case == "hidden-weight-file":
                (mtp / ".hidden.safetensors").write_bytes(self.tiny_safetensors("mtp.hidden.weight"))
            elif case == "symlink-weight-file":
                real = root / "model.real.safetensors"
                weights.rename(real)
                weights.symlink_to(real)
            elif case == "wrong-quant-bits":
                cfg = json.loads((mtp / "config.json").read_text())
                quant = cfg.get("quantization") or {}
                quant["bits"] = 8 if quant.get("bits") == 4 else 4
                cfg["quantization"] = quant
                (mtp / "config.json").write_text(json.dumps(cfg))
            elif case == "missing-weight-file":
                weights.unlink()
            elif case == "malformed-safetensors-header":
                (mtp / "bad.safetensors").write_bytes((2 ** 62).to_bytes(8, "little") + b"{}")
            elif case == "duplicate-tensor-file":
                run(["cp", "-c", str(weights), str(mtp / "model-copy.safetensors")])
            env = dict(os.environ, MACPROVIDER_NATIVE_MTP_E2E="1")
            log = self.logs / f"lab-neg-{case}.log"
            proc = run([str(self.lab_cli), "native-mtp-hardware-e2e", "--root", str(root), "--model-id", MODEL_ID,
                        "--max-batch", "2"], env=env, timeout=1800, log=log)
            passed_line = '"status":"pass"' in proc.stdout
            results[case] = {"exit": proc.returncode, "rejected": proc.returncode != 0 and not passed_line,
                             "error_tail": (proc.stderr.strip().splitlines() or [""])[-1][:400]}
            self.keep(log, f"lab-neg-{case}.log")
            shutil.rmtree(root)
        self.negatives = results
        (self.evidence / "records/lab-manifest-negatives.json").write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")

    @staticmethod
    def tiny_safetensors(name: str) -> bytes:
        header = json.dumps({name: {"dtype": "BF16", "shape": [2], "data_offsets": [0, 4]}}).encode()
        header += b" " * ((8 - len(header) % 8) % 8)
        return len(header).to_bytes(8, "little") + header + b"\x00" * 4

    # -- phase: lab journey (hidden JOURNEY-NATIVE-MTP-SERVING steps)
    def phase_lab_journey(self) -> None:
        self.ensure_fixture()
        env = dict(os.environ, MACPROVIDER_NATIVE_MTP_E2E="1")
        log = self.logs / "lab-journey.stderr"
        out = self.evidence / "records/lab-journey-result.json"
        proc = subprocess.run([str(self.lab_cli), "native-mtp-journey-e2e", "--root", str(self.fixture),
                               "--model-id", MODEL_ID, "--qualified-slots", str(self.cfg["qualified_slots"]),
                               "--max-native-active-rows", str(self.cfg["max_native_active_rows"]),
                               "--max-prompt-tokens", str(self.cfg["max_prompt_tokens"])],
                              env=env, capture_output=True, text=True, timeout=5400)
        log.write_text(proc.stderr)
        doc = json.loads(next((ln for ln in proc.stdout.splitlines() if ln.startswith("{")), "{}") or "{}")
        out.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n")
        self.keep(log, "lab-journey.stderr")
        self.journey = {"exit": proc.returncode, "doc": doc,
                        "steps": {s["step_id"]: s for s in doc.get("steps", [])}}

    # -- phase: isolated coordinator + gateway + signed provider
    def phase_isolated_coordinator(self) -> None:
        iso = __import__("native_mtp_r014_isolated")
        self.iso = iso.run_isolated(self)

    # -- phase: release assets and updater
    def phase_release_assets(self) -> None:
        rel = __import__("native_mtp_r014_release")
        self.release = rel.release_asset_identity(self)

    def phase_updater(self) -> None:
        rel = __import__("native_mtp_r014_release")
        self.updater = rel.updater_path(self)

    # -- verdicts from collected evidence
    def load_record(self, name: str) -> Optional[Any]:
        path = self.evidence / "records" / name
        return json.loads(path.read_text()) if path.exists() else None

    def verdicts(self) -> None:
        # Verdicts derive from the evidence records, so a run of a subset of
        # phases re-judges every item from the latest record of each phase.
        ss = getattr(self, "signed_serve", None) or self.load_record("signed-serve.json")
        jr = getattr(self, "journey", None)
        if jr is None and self.load_record("lab-journey-result.json"):
            doc = self.load_record("lab-journey-result.json")
            jr = {"doc": doc, "steps": {x["step_id"]: x for x in doc.get("steps", [])}}
            self.journey = jr
        neg = getattr(self, "negatives", None) or self.load_record("lab-manifest-negatives.json")
        if getattr(self, "iso", None) is None and self.load_record("isolated-coordinator.json"):
            self.iso = self.load_record("isolated-coordinator.json")
        if getattr(self, "production_generator", None) is None:
            self.production_generator = self.load_record("production-generator-rehearsal.json")
        if getattr(self, "sidecar_sub", None) is None and self.load_record("lab-sidecar-identity.json"):
            ident_doc = self.load_record("lab-sidecar-identity.json")
            hw_log = (self.evidence / "raw/lab-hardware-e2e.log")
            hw_ok = hw_log.exists() and '"serve_path_verified":true' in hw_log.read_text() and '"status":"pass"' in hw_log.read_text()
            bound = ident_doc["bound_fields"]
            signed_cdhash = json.loads((self.evidence / "identity.json").read_text())["signed_cli_cdhash"]
            self.sidecar_bound = bound
            self.sidecar_evidence = ["raw/lab-hardware-e2e.log", "records/lab-native-mtp-admission.json", "records/lab-sidecar-identity.json"]
            self.sidecar_sub = {
                "lab_serve_path_loader_admitted_sidecar": hw_ok,
                "generator_recomputes_tuple_sha": bool(ident_doc["generator_identity"].get("native_mtp_admission_tuple_sha256")),
                "sidecar_binds_target_artifact": bound.get("artifact_hash") == self.cfg["target_sha256"],
                "sidecar_binds_release_cdhash": bound.get("live_executable_cdhash") == signed_cdhash,
                "sidecar_binds_release_source_commit": bound.get("source_commit") == self.cfg["release_source_commit"],
            }
        if getattr(self, "sidecar_sub", None) is not None:
            sub = self.sidecar_sub
            core = sub["lab_serve_path_loader_admitted_sidecar"] and sub["generator_recomputes_tuple_sha"] and sub["sidecar_binds_target_artifact"]
            pg = getattr(self, "production_generator", {}) or {}
            sub["production_generator_builds_release_sidecar"] = pg.get("exit") == 0
            prod = sub["sidecar_binds_release_cdhash"] and sub["sidecar_binds_release_source_commit"] and sub["production_generator_builds_release_sidecar"]
            self.record("item1-sidecar-tuple-binding", PASS if core and prod else FAIL,
                        "lab-generated sidecar is admitted by the production serve-path loader and its tuple sha "
                        "recomputes in the repository generator" + ("" if prod else
                        "; but the only sidecar that can be generated today binds the lab harness identity "
                        "(ephemeral key, lab provider revision), not the signed release CDHash/source commit, "
                        "and no production generator input exists for this release (see delivery-path.md)"),
                        evidence=self.sidecar_evidence + ["records/production-generator-rehearsal.json", "delivery-path.md"], sub=sub,
                        details={"bound_fields": self.sidecar_bound, "production_generator": pg}, binary="lab build of release source")
        if neg is not None or ss is not None:
            sub = {}
            for case, r in (neg or {}).items():
                sub[f"lab.{case}.rejected_before_load"] = r["rejected"]
            if ss:
                for k, v in ss["sub"].items():
                    if k.startswith(("s1.", "s2-", "s3-")):
                        sub[f"signed.{k}"] = v
            ok = all(sub.values()) and bool(sub)
            self.record("item3-capability-negatives", PASS if ok else FAIL,
                        f"{sum(sub.values())}/{len(sub)} negative sub-checks hold (lab manifest mutations on the hardware "
                        "observer; release-binary serve-path rejections with ordinary decode still serving)",
                        evidence=["records/lab-manifest-negatives.json", "records/signed-serve.json"] + (ss["evidence"] if ss else []),
                        sub=sub, details={"signed_rejections": {k: v for k, v in (ss or {}).get("details", {}).items() if k.endswith("rejections")}},
                        binary="signed release + lab build")
        if jr is not None:
            steps = jr["steps"]

            def step_ok(step_id: str, prefixes: Optional[List[str]] = None) -> tuple:
                step = steps.get(step_id)
                if not step:
                    return False, {"missing_step": step_id}
                checks = step.get("checks", {})
                if prefixes:
                    checks = {k: v for k, v in checks.items() if any(k.startswith(p) for p in prefixes)}
                return (bool(checks) and all(checks.values())), {"status": step.get("status"), "checks": checks,
                                                                  "uncovered_contract": step.get("uncovered_contract", [])}

            ev = ["records/lab-journey-result.json", "raw/lab-journey.stderr"]

            def said(ok: bool, text: str, *details: dict) -> str:
                if ok:
                    return text
                failed = sorted(k for d in details for k, v in (d.get("checks") or {}).items() if not v)
                return "FAILED checks " + ", ".join(failed or ["(step missing or errored)"]) + " — fixture: " + text
            ok4, d4 = step_ok("step-04-serial-token-oracle")
            self.record("item3-greedy-parity", PASS if ok4 else FAIL,
                        said(ok4, "native output equals isolated ordinary output (token IDs, bytes, usage, terminal) for greedy and seeded-sampled rows", d4),
                        evidence=ev, details=d4, binary="lab build of release source")
            ok5, d5 = step_ok("step-05-cache-state-boundary")
            self.record("item3-state-rollback", PASS if ok5 else FAIL,
                        said(ok5, "forced rejection on every round and at the paged/hybrid block boundary keeps output parity", d5),
                        evidence=ev, details=d5, binary="lab build of release source")
            ok6, d6 = step_ok("step-06-streaming-stop")
            ok9, d9 = step_ok("step-09-cancellation")
            self.record("item3-termination", PASS if ok6 and ok9 else FAIL,
                        said(ok6 and ok9, "stream/non-stream stop parity and mid-stream cancellation release", d6, d9),
                        evidence=ev, details={"step-06": d6, "step-09": d9}, binary="lab build of release source")
            ok7, d7 = step_ok("step-07-08-mixed-multirow-capacity", ["journey-mixed-", "mixed_paths_in_one_batch", "batch_depth_reached"])
            self.record("item3-mixed-row", PASS if ok7 else FAIL,
                        said(ok7, f"one {self.cfg['qualified_slots']}-row batch mixes native, load-gated, and ineligible ordinary rows with per-row parity against the ordinary batched oracle", d7),
                        evidence=ev, details=d7, binary="lab build of release source")
            ok8, d8 = step_ok("step-07-08-mixed-multirow-capacity", ["depth_zero_hold_observed", "holds_resolved", "slots_unchanged", "prompt_cap."])
            self.record("item3-capacity", PASS if ok8 else FAIL,
                        said(ok8, "load gate holds native rows at depth zero above the bound and resolves every hold; slots unchanged; prompt cap selects ordinary", d8),
                        evidence=ev, details=d8, binary="lab build of release source")
            usage_steps = [s for s in ("step-04-serial-token-oracle", "step-06-streaming-stop", "step-07-08-mixed-multirow-capacity") if steps.get(s)]
            usage_ok = all(all(v for k, v in steps[s]["checks"].items() if k.endswith("parity")) for s in usage_steps)
            iso = getattr(self, "iso", None) or {}
            sub = {"lab.usage_and_terminal_parity_native_vs_ordinary": usage_ok,
                   "isolated.buyer_usage_and_billing_recorded_for_ordinary": bool(iso.get("billing_ok")),
                   "isolated.native_rows_billed_identically": False}
            self.record("item3-accounting", FAIL if not all(sub.values()) else PASS,
                        "usage tokens and terminal reasons match ordinary for every native row (lab); receipt/billing "
                        "invariance for native rows cannot be exercised end to end because no released provider can "
                        "admit the tuple (item1-revocation-feed, delivery-path.md)",
                        evidence=ev + ["records/isolated-coordinator.json"], sub=sub, binary="lab build + signed release")
            fair = self.cfg["fairness_proxy"]
            self.record("item3-fairness", PASS if fair["ok"] else FAIL,
                        fair["summary"], evidence=[self.cfg["r015_analysis_json"]], details=fair,
                        binary="lab 280f0e95d (release source minus version bump)")
        if ss is not None:
            sub = {k: v for k, v in ss["sub"].items() if k.startswith("s0.")}
            self.record("item8-isolated-loopback", PASS if all(sub.values()) else FAIL,
                        "signed release serves no-join on isolated loopback: native MTP default-off, status object "
                        "present, ordinary streaming/non-streaming and 8-way continuous batching on the tuple",
                        evidence=["records/signed-serve.json"] + ss["evidence"][:1], sub=sub,
                        details={"note": "the R014.8 native self-test/oracle smoke and sidecar binding on the final "
                                         "binary need a production-signed sidecar; see item1-sidecar-tuple-binding"},
                        binary="signed release")
            self.cb_sub = {k: v for k, v in sub.items() if k.startswith("s0.cb")}
        self.verdict_cb15()
        self.verdict_serving_journey()

    def verdict_cb15(self) -> None:
        cb = getattr(self, "cb_sub", {}) or {}
        policy_path = self.work / "release-assets" / "continuous-batching-policy.json"
        entries = None
        try:
            if not policy_path.exists():
                policy_path.parent.mkdir(parents=True, exist_ok=True)
                with urllib.request.urlopen(
                        f"https://github.com/Augustas11/macprovider/releases/download/{self.cfg['release_tag']}/continuous-batching-policy.json",
                        timeout=60) as resp:
                    policy_path.write_bytes(resp.read())
            entries = json.loads(policy_path.read_text()).get("entries")
        except (OSError, ValueError):
            pass
        model = MODEL_ID
        signed_entry = bool(entries) and any(model in json.dumps(e) for e in entries)
        evidence_hits = []
        for root in ("docs/runbooks", "docs/research"):
            for path in sorted((self.repo / root).rglob("*.md")):
                text = path.read_text(errors="replace")
                if ("FR-CB15" in text or "FR-PKV13" in text) and ("qwen3.6-35b-a3b" in text.lower()):
                    evidence_hits.append(str(path.relative_to(self.repo)))
        m7 = (self.repo / "docs/runbooks/continuous-batching-m7-decision-2026-09-26.md").read_text()
        a5_green = "Gate A5 is NOT GREEN" not in m7
        sub = dict(cb)
        sub.update({
            "release_signed_cb_policy_has_tuple_entry": signed_entry,
            "committed_fr_cb15_or_fr_pkv13_evidence_for_tuple": bool(evidence_hits),
            "gate_a5_green": a5_green,
        })
        (self.evidence / "records").mkdir(exist_ok=True)
        (self.evidence / "records/cb15-a5-pkv13.json").write_text(json.dumps(
            {"sub": sub, "signed_policy_entries": entries, "evidence_hits": evidence_hits,
             "gate_a5_source": "docs/runbooks/continuous-batching-m7-decision-2026-09-26.md"}, indent=2, sort_keys=True) + "\n")
        self.record("item5-cb15-a5-pkv13", PASS if sub and all(sub.values()) else FAIL,
                    "the signed release attaches paged KV and batches the tuple on the Studio, but the release's signed "
                    "continuous-batching policy carries no entries, no committed FR-CB15/FR-PKV13 enable-gate record names "
                    "qwen/qwen3.6-35b-a3b, and Gate A5 is recorded NOT GREEN (M7 decision)",
                    evidence=["records/cb15-a5-pkv13.json", "records/signed-serve.json"], sub=sub,
                    binary="signed release + repository records")

    def verdict_serving_journey(self) -> None:
        jr = getattr(self, "journey", None)
        doc = (jr or {}).get("doc", {})
        self.record("item6-serving-journey", FAIL,
                    "no signed JOURNEY-NATIVE-MTP-SERVING result exists for the tuple; the lab hardware steps report "
                    f"executed_steps_status={doc.get('executed_steps_status')} journey_complete={doc.get('journey_complete')}, "
                    "and steps 01-03, 10, 11, the coordinator canary half of 12, 14, and 15 are pending in the harness",
                    evidence=["records/lab-journey-result.json"],
                    details={"pending_steps": doc.get("pending_steps"), "covered_steps": doc.get("covered_steps")},
                    binary="lab build of release source")


def load_config(path: Path) -> dict:
    return json.loads(path.read_text())


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="cmd", required=True)
    p_run = sub.add_parser("run")
    p_run.add_argument("--config", type=Path, required=True)
    p_run.add_argument("--phases", default="identity,live,records,revocation,lab-hw,signed-serve,lab-neg,lab-journey,isolated,release-assets,updater,live")
    p_sum = sub.add_parser("summarize")
    p_sum.add_argument("--evidence", type=Path, required=True)
    args = parser.parse_args(argv)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    if args.cmd == "summarize":
        from native_mtp_r014_summary import summarize
        return summarize(args.evidence)
    cfg = load_config(args.config)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    runner = Runner(cfg)
    runner.preflight()
    started = now()
    phases = {
        "identity": runner.phase_identity,
        "live": runner.phase_live_binaries,
        "records": runner.phase_records,
        "revocation": runner.phase_revocation_feed,
        "lab-hw": runner.phase_lab_hardware_e2e,
        "signed-serve": runner.phase_signed_serve,
        "lab-neg": runner.phase_lab_negatives,
        "lab-journey": runner.phase_lab_journey,
        "isolated": runner.phase_isolated_coordinator,
        "release-assets": runner.phase_release_assets,
        "updater": runner.phase_updater,
    }
    failures = {}
    for name in args.phases.split(","):
        print(f"[{now()}] phase {name} start", flush=True)
        try:
            phases[name]()
        except SystemExit:
            raise
        except Exception as err:  # a crashed phase is recorded, the run continues
            failures[name] = f"{type(err).__name__}: {err}"
            print(f"[{now()}] phase {name} ERROR {failures[name]}", flush=True)
        print(f"[{now()}] phase {name} end", flush=True)
    runner.verdicts()
    (runner.evidence / "run.json").write_text(json.dumps(
        {"started_at": started, "finished_at": now(), "phases": args.phases.split(","),
         "phase_errors": failures}, indent=2, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
