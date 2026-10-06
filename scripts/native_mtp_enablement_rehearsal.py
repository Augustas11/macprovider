#!/usr/bin/env python3
"""Isolated Studio rehearsal of native-MTP delivery, serving, accounting, and revocation (#1770).

LAB ONLY. Runs under the lab lock, on 127.0.0.1 193xx ports, against an
isolated coordinator and gateway built from the campaign branch (SQLite,
settlement observe). It never signals, reconfigures, or connects to the live
provider (:8080), the M1 pool, Pearl, or coordinator.malibu.tech.

The coordinator serves the test-key release built by
`scripts/native_mtp_rehearsal_release.py`: the signed static feeds, the
native-MTP admission set, a `mixed` CB policy entry for the lab binary, and
pre-signed revocation slots. The provider is a lab-harness build (compile flag in
docs/runbooks/native-mtp-enablement.md) whose `MACPROVIDER_LAB_STATIC_FEED_*` override trusts only that test
key, joined with `--isolate-lifecycle` to the loopback coordinator, with a
model store that holds a clone of the target and no drafter.

Phases:

1. **delivery**: the provider fetches the catalog and the admission set from
   the coordinator, fetches the drafter from its pinned revision into the lab
   store, admits the tuple, passes its self-test, offers it; the coordinator
   loads the canary bank.
2. **native**: real buyer requests through the gateway, with native rows.
3. **ordinary**: the same requests with `native_mtp_mode: off` (G8: the
   accounting deltas of both phases must match).
4. **revocation drill**: an emergency slot batch revoking the tuple replaces the
   served one; the provider disables only the tuple and keeps serving.

Usage (Studio):
  python3 scripts/native_mtp_enablement_rehearsal.py --config run-config.json
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import signal
import sqlite3
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import yaml  # noqa: E402  (PyYAML; present on the lab host)

from native_mtp_r014_isolated import _start, _token_columns, _wait_http  # noqa: E402
from native_mtp_r014_journey import (chat, http_json, http_stream, native_status, now,  # noqa: E402
                                     port_free, serve_rejections, sha256_file, stop)

FORBIDDEN_PORTS = {8080, 18120, 18122, 18130, 18140, 18150, 11435, 9444}
PROMPTS = (
    "Explain why the sky is blue in two sentences.",
    "List four uses of copper.",
    "Write a haiku about a lighthouse.",
    "What is the capital of Australia, and why was it chosen?",
)
MAX_TOKENS = 96
ANCHOR_SERVICE = "macprovider.native-mtp-revocation-generation"


def utc() -> datetime:
    return datetime.now(timezone.utc)


class Rehearsal:
    def __init__(self, cfg: dict):
        self.cfg = cfg
        self.work = Path(cfg["work_dir"])
        self.release = Path(cfg["release_dir"])
        self.summary = json.loads((self.release / "rehearsal-release.json").read_text())
        self.lab_cli = Path(cfg["lab_cli"])
        self.gobin = Path(cfg["go_bin_dir"])
        self.ports = {k: int(cfg[k]) for k in ("coordinator_http_port", "coordinator_ws_port", "gateway_port",
                                               "serve_port")}
        self.procs: dict = {}
        self.result: dict = {"schema_version": "macprovider.native-mtp-enablement-rehearsal.v1",
                             "started_at": now(), "phases": {}, "checks": {}}

    # ------------------------------------------------------------ guards

    def preflight(self) -> None:
        for port in self.ports.values():
            if port in FORBIDDEN_PORTS or not 19300 <= port <= 19399:
                raise SystemExit(f"port {port} is outside the isolated 193xx block")
            if not port_free(port):
                raise SystemExit(f"isolated port {port} is busy")
        for root in self.cfg["forbidden_roots"]:
            if str(self.work).startswith(root.rstrip("/") + "/"):
                raise SystemExit(f"work dir is under forbidden root {root}")
        lock = Path(self.cfg["lab_lock_dir"])
        try:
            lock.mkdir()
        except FileExistsError:
            owner = (lock / "owner").read_text() if (lock / "owner").exists() else "?"
            raise SystemExit(f"lab lock busy: {owner}")
        (lock / "owner").write_text(f"native-mtp-enablement-rehearsal {now()} pid {os.getpid()}\n")
        self.result["lab_lock"] = {"acquired_at": now(), "dir": str(lock)}

    def release_lock(self) -> None:
        lock = Path(self.cfg["lab_lock_dir"])
        if (lock / "owner").exists() and "native-mtp-enablement-rehearsal" in (lock / "owner").read_text():
            shutil.rmtree(lock, ignore_errors=True)
            self.result["lab_lock"]["released_at"] = now()

    # ------------------------------------------------------------ setup

    def setup(self) -> None:
        if self.work.exists():
            for sub in ("db", "run", "logs", "home", "tmp", "provider", "revocations", "hf"):
                shutil.rmtree(self.work / sub, ignore_errors=True)
        for sub in ("db", "run", "logs", "home/lifecycle", "home/watchdog", "tmp", "provider", "revocations", "hf",
                    "models"):
            (self.work / sub).mkdir(parents=True, exist_ok=True)
        os.chmod(self.work, 0o700)
        os.chmod(self.work / "models", 0o700)
        # The store holds a clone of the served target and NO drafter, so the
        # provider must fetch the drafter itself.
        live = Path(self.cfg["model_artifact_path"])
        clone = self.work / "models" / live.relative_to(Path(self.cfg["model_store_root"]))
        if not clone.exists():
            clone.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["cp", "-cR", str(live), str(clone)], check=True, timeout=1800)
        drafter = self.summary["drafter"]
        self.drafter_dir = (self.work / "models" / drafter["repo_id"].replace("/", "--") / drafter["revision"]
                            / drafter["sha256"])
        shutil.rmtree(self.drafter_dir.parent.parent, ignore_errors=True)
        self.clone = clone
        # The served revocation directory is a symlink to one batch, as deployed.
        batch = self.work / "revocations" / "batch-normal"
        shutil.copytree(self.release / "revocations", batch)
        os.symlink(batch, self.work / "revocations" / "current")
        self.secrets = {name: secrets.token_hex(32) for name in
                        ("operator_key", "gateway_service_token", "key_hash_secret", "demo_secret")}
        self.provider_id = "native-mtp-rehearsal-provider"

    def coordinator_config(self) -> dict:
        dist = yaml.safe_load((Path(self.cfg["repo_dir"]) / "phase4-coordinator/dist/coordinator.yaml").read_text())
        cat = self.release / "catalog"
        key_id = self.summary["key_id"]
        p = self.ports
        return {
            "listen": {"buyer_port": p["coordinator_http_port"], "provider_port": p["coordinator_ws_port"],
                       "bind_address": "127.0.0.1"},
            "pool": {"heartbeat_interval_s": 2, "warmup_gate_enabled": False, "canary_enabled": False,
                     "native_mtp_canary": {"enabled": True,
                                           "challenge_bank_path": str(cat / "native-mtp-selftest-bank.json"),
                                           "signature_path": str(cat / "native-mtp-selftest-bank.json.sig"),
                                           "signer_key_id": key_id,
                                           "public_keys": {key_id: self.summary["public_key_base64"]},
                                           "interval_s": 900}},
            "routing": {"request_timeout_s": 600, "retry_per_attempt_timeout_s": 600, "failover_enabled": False,
                        "sticky_enabled": False},
            "provider_http": {"timeout_s": 600},
            "admission": {"pinned_only": False, "provisional_pool_max": 100, "provisional_quota_per_hour": 100000},
            "auth": {"operator_key": self.secrets["operator_key"],
                     "gateway_service_token": self.secrets["gateway_service_token"],
                     "require_provider_tokens": True},
            "storage": {"db_path": str(self.work / "db/coordinator.db")},
            "logging": {"level": "debug", "format": "json"},
            "rewards": dist["rewards"],
            "settlement": {"verified_model_settlement_mode": "observe", "job_enabled": False, "min_payout_credits": 0},
            "relay_blind": {"enabled": False},
            "explorer": {"enabled": False},
            "providers": [{"provider_id": self.provider_id, "display_name": "native-mtp rehearsal"}],
            "autotune": {
                "enforce_provider_admission": True,
                "public_keys": {key_id: self.summary["public_key_base64"]},
                "rate_card_path": str(cat / "rate-card.json"),
                "rate_card_sig_path": str(cat / "rate-card.json.sig"),
                "demand_rank_path": str(cat / "demand-rank.json"),
                "demand_rank_sig_path": str(cat / "demand-rank.json.sig"),
                "autotune_candidates_path": str(cat / "autotune-candidates.json"),
                "autotune_candidates_sig_path": str(cat / "autotune-candidates.json.sig"),
                "continuous_batching_policy_path": str(cat / "continuous-batching-policy.json"),
                "continuous_batching_policy_sig_path": str(cat / "continuous-batching-policy.json.sig"),
                "catalog_artifacts_path": str(cat / "autotune-artifacts.json"),
                "catalog_artifacts_sig_path": str(cat / "autotune-artifacts.json.sig"),
                "native_mtp_admission_path": str(cat / "native-mtp-admission.json"),
                "native_mtp_admission_sig_path": str(cat / "native-mtp-admission.json.sig"),
                "native_mtp_artifact_manifest_path": str(cat / "native-mtp-artifact-manifest.json"),
                "native_mtp_selftest_bank_path": str(cat / "native-mtp-selftest-bank.json"),
                "native_mtp_selftest_bank_sig_path": str(cat / "native-mtp-selftest-bank.json.sig"),
                "native_mtp_revocations_dir": str(self.work / "revocations/current"),
            },
        }

    def gateway_config(self) -> dict:
        p, s = self.ports, self.secrets
        return {
            "listen": {"bind_address": "127.0.0.1", "port": p["gateway_port"]},
            "proxy": {"trusted_cidrs": ["127.0.0.0/8", "::1/128"]},
            "public": {"base_url": f"http://127.0.0.1:{p['gateway_port']}", "account_path": "/account"},
            "coordinator": {"buyer_url": f"http://127.0.0.1:{p['coordinator_http_port']}",
                            "operator_url": f"http://127.0.0.1:{p['coordinator_ws_port']}",
                            "operator_key": s["operator_key"], "service_token": s["gateway_service_token"],
                            "poolz_poll_interval_s": 60},
            "storage": {"driver": "sqlite", "db_path": str(self.work / "db/gateway.db")},
            "auth": {"key_prefix": "mp_", "key_hash": "hmac_sha256", "key_hash_secret": s["key_hash_secret"],
                     "github_oauth_enabled": False, "email_magic_link_enabled": False,
                     "oauth": {"callback_allowlist": [f"http://127.0.0.1:{p['gateway_port']}/auth/github/callback"]},
                     "demo": {"signing_secret": s["demo_secret"]}},
            "quotas": {"account_daily_tokens": 10000000, "account_concurrency": 8,
                       "account_request_rate_per_second": 50},
            "limits": {"max_tokens_per_request": 4096},
            "timeouts": {"coordinator_request_seconds": 600, "coordinator_header_timeout_seconds": 600},
        }

    def provider_config(self, native_mode: str) -> Path:
        base = yaml.safe_load(Path(self.cfg["serve_config_template"]).read_text())
        for key in ("provider_token", "provider_token_file", "continuous_batching_accepted_tuples"):
            base.pop(key, None)
        p = self.ports
        base.update({
            "port": p["serve_port"],
            "provider_id": self.provider_id,
            "credential_store": "protected_file",
            "coordinator_url": f"ws://127.0.0.1:{p['coordinator_ws_port']}/ws/provider",
            "model_artifact_path": str(self.clone),
            "auto_update_enabled": False,
            "enable_receipts": True,
            "native_mtp_mode": native_mode,
            "continuous_batching": "canary",
        })
        path = self.work / "provider" / "config.yaml"
        path.write_text(yaml.safe_dump(base, sort_keys=True))
        os.chmod(path, 0o600)
        if f"127.0.0.1:{p['coordinator_ws_port']}" not in path.read_text():
            raise SystemExit("provider config does not point at the isolated coordinator")
        return path

    def provider_env(self, config: Path) -> dict:
        env = dict(os.environ)
        env.update({
            "CFFIXED_USER_HOME": str(self.work / "home"),
            "TMPDIR": str(self.work / "tmp") + "/",
            "HF_HOME": str(self.work / "hf"),
            "MACPROVIDER_CONFIG": str(config),
            "MACPROVIDER_LIFECYCLE_ROOT": str(self.work / "home/lifecycle"),
            "MACPROVIDER_CTL_SOCKET_PATH": str(self.work / "tmp/ctl.sock"),
            "MACPROVIDER_SWITCH_STATE_PATH": str(self.work / "tmp/last-switch.ts"),
            "MACPROVIDER_WATCHDOG_STATE_DIR": str(self.work / "home/watchdog"),
            "MACPROVIDER_AUTO_UPDATE_ENABLED": "false",
            "MACPROVIDER_MODEL_ARTIFACT_ROOT": str(self.work / "models"),
            "MACPROVIDER_LAB_STATIC_FEED_ORIGIN": f"http://127.0.0.1:{self.ports['coordinator_http_port']}",
            "MACPROVIDER_LAB_STATIC_FEED_KEY_ID": self.summary["key_id"],
            "MACPROVIDER_LAB_STATIC_FEED_PUBLIC_KEY": self.summary["public_key_base64"],
            "MACPROVIDER_LAB_NATIVE_MTP_SOURCE_COMMIT": self.summary["facts"]["source_commit"],
        })
        return env

    # ------------------------------------------------------------ stack

    def bootstrap_accounts(self) -> None:
        (self.work / "run/gateway.yaml").write_text(json.dumps(self.gateway_config(), indent=1))
        os.chmod(self.work / "run/gateway.yaml", 0o600)
        gw = _start([str(self.gobin / "gateway"), "-config", str(self.work / "run/gateway.yaml")],
                    self.work / "logs/gateway-migrate.log")
        end = time.time() + 30
        while time.time() < end:
            try:
                with sqlite3.connect(self.work / "db/gateway.db") as db:
                    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='api_keys'").fetchone():
                        break
            except sqlite3.Error:
                pass
            time.sleep(0.3)
        stop(gw)
        self.buyer_key = "mp_" + base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
        digest = hmac.new(self.secrets["key_hash_secret"].encode(), self.buyer_key.encode(), hashlib.sha256).digest()
        ts = utc().isoformat()
        with sqlite3.connect(self.work / "db/gateway.db") as db:
            db.execute("INSERT INTO accounts(account_id,status,quota_class,concurrency_class,created_at) "
                       "VALUES('acct-native-mtp-rehearsal','active','default','default',?)", (ts,))
            db.execute("INSERT INTO api_keys(key_id,account_id,key_hash,key_hash_prefix,status,created_at) "
                       "VALUES(?,'acct-native-mtp-rehearsal',?,?,'active',?)",
                       ("key_" + secrets.token_hex(16), digest, self.buyer_key[:12], ts))
        (self.work / "run/coordinator.yaml").write_text(json.dumps(self.coordinator_config(), indent=1))
        os.chmod(self.work / "run/coordinator.yaml", 0o600)
        tok = subprocess.run([str(self.gobin / "coordinator-cli"), "issue-token", "-db",
                              str(self.work / "db/coordinator.db"), "-provider-id", self.provider_id,
                              "-provider-name", "native-mtp-rehearsal"], capture_output=True, text=True, timeout=60)
        token = re.search(r"token=(\S+)", tok.stdout).group(1)
        config = self.provider_config("auto")
        with open(config, "a") as handle:
            handle.write(f"provider_token: {token}\n")
        imp = subprocess.run([str(self.lab_cli), "credentials", "import", "--config", str(config)],
                             env=self.provider_env(config), capture_output=True, text=True, timeout=120)
        (self.work / "logs/credentials-import.log").write_text(imp.stdout + imp.stderr)
        self.result["credentials_import_exit"] = imp.returncode
        self.provider_config("auto")  # rewritten without the token

    def start_services(self) -> None:
        p = self.ports
        self.procs["coordinator"] = _start([str(self.gobin / "coordinator"), "-config",
                                            str(self.work / "run/coordinator.yaml")], self.work / "logs/coordinator.log")
        ok_c = _wait_http(p["coordinator_http_port"], "/healthz", self.procs["coordinator"], 60)
        self.procs["gateway"] = _start([str(self.gobin / "gateway"), "-config", str(self.work / "run/gateway.yaml")],
                                       self.work / "logs/gateway.log")
        ok_g = _wait_http(p["gateway_port"], "/healthz", self.procs["gateway"], 60)
        feeds = {}
        if not (ok_c and ok_g):
            self.result["services"] = {"coordinator_up": ok_c, "gateway_up": ok_g, "static_feed_status": {}}
            raise SystemExit("isolated coordinator or gateway did not start")
        for name in ("autotune-candidates", "continuous-batching-policy", "catalog-artifacts", "native-mtp-admission",
                     "native-mtp-artifact-manifest", "native-mtp-selftest-bank",
                     f"native-mtp-revocations.{self.summary['key_id']}.json"):
            status, _ = http_json("GET", p["coordinator_http_port"], f"/v1/{name}", timeout=10)
            feeds[name] = status
        self.result["services"] = {"coordinator_up": ok_c, "gateway_up": ok_g, "static_feed_status": feeds}

    def start_provider(self, label: str, native_mode: str) -> dict:
        config = self.provider_config(native_mode)
        err = self.work / f"logs/provider-{label}.err"
        self.procs["provider"] = subprocess.Popen(
            [str(self.lab_cli), "serve", "--config", str(config), "--isolate-lifecycle"],
            stdout=open(self.work / f"logs/provider-{label}.out", "w"), stderr=open(err, "w"),
            env=self.provider_env(config), start_new_session=True)
        started = time.time()
        routable, probes = False, 0
        end = started + int(self.cfg.get("serve_ready_timeout_s", 900))
        while time.time() < end and self.procs["provider"].poll() is None:
            try:
                status, _ = http_json("POST", self.ports["gateway_port"], "/v1/chat/completions",
                                      chat("Reply with OK.", 4), headers=self.auth(), timeout=120)
            except OSError:
                status = 0
            probes += 1
            if status == 200:
                routable = True
                break
            time.sleep(5)
        return {"native_mode": native_mode, "routable": routable, "readiness_probes": probes,
                "seconds_to_routable": round(time.time() - started, 1),
                "provider_exit": self.procs["provider"].poll()}

    def stop_provider(self) -> None:
        stop(self.procs.pop("provider", None))

    def auth(self) -> dict:
        return {"Authorization": f"Bearer {self.buyer_key}"}

    # ------------------------------------------------------------ phases

    def requests(self) -> list:
        out = []
        for prompt in PROMPTS:
            status, body = http_json("POST", self.ports["gateway_port"], "/v1/chat/completions",
                                     chat(prompt, MAX_TOKENS), headers=self.auth())
            choice = (body.get("choices") or [{}])[0] if isinstance(body, dict) else {}
            content = (choice.get("message") or {}).get("content") or ""
            out.append({"kind": "nonstream_greedy", "prompt_sha256": hashlib.sha256(prompt.encode()).hexdigest(),
                        "status": status, "usage": body.get("usage") if isinstance(body, dict) else None,
                        "finish_reason": choice.get("finish_reason"),
                        "content_sha256": hashlib.sha256(content.encode()).hexdigest()})
        status, content, meta, frames = http_stream(self.ports["gateway_port"], "/v1/chat/completions",
                                                    chat(PROMPTS[1], MAX_TOKENS, stream=True), headers=self.auth())
        out.append({"kind": "stream_greedy", "status": status, "usage": (meta or {}).get("usage"),
                    "finish_reason": (meta or {}).get("finish_reason"), "frames": frames,
                    "content_sha256": hashlib.sha256(content.encode()).hexdigest() if isinstance(content, str) else None})
        return out

    def db_snapshot(self) -> dict:
        time.sleep(4)
        return {"coordinator": _token_columns(self.work / "db/coordinator.db"),
                "gateway": _token_columns(self.work / "db/gateway.db")}

    @staticmethod
    def delta(before: dict, after: dict) -> dict:
        out = {}
        for db, tables in after.items():
            for table, cols in tables.items():
                prior = before.get(db, {}).get(table, {})
                diff = {c: v - prior.get(c, 0) for c, v in cols.items() if isinstance(v, (int, float))}
                if any(diff.values()):
                    out[f"{db}.{table}"] = diff
        return out

    def delivery_evidence(self, label: str) -> dict:
        home_store = self.work / "home/Library/Application Support/macprovider/native-mtp-admission"
        members = sorted(str(p.relative_to(home_store)) for p in home_store.rglob("*")) if home_store.exists() else []
        drafter_ok = self.drafter_dir.is_dir()
        clog = (self.work / "logs/coordinator.log").read_text(errors="replace")
        perr = self.work / f"logs/provider-{label}.err"
        perr_text = perr.read_text(errors="replace") if perr.exists() else ""
        return {
            "materialized_members": members,
            "drafter_fetched_into_lab_store": drafter_ok,
            "drafter_files": sorted(p.name for p in self.drafter_dir.iterdir()) if drafter_ok else [],
            "lab_override_active": "event=lab_static_feed_override action=active" in perr_text,
            "provider_status": native_status(self.ports["serve_port"]),
            "serve_path_admission_events": serve_rejections(perr),
            "runtime_identity_lines": [ln[:400] for ln in perr_text.splitlines() if "runtime-identity" in ln][:4],
            "tuple_offer_received": "native_mtp_tuple_offer" in clog,
            "coordinator_native_mtp_lines": [ln[:400] for ln in clog.splitlines()
                                             if "native" in ln.lower() and "mtp" in ln.lower()][-30:],
            "coordinator_cb_policy_lines": [ln[:300] for ln in clog.splitlines()
                                            if "continuous_batching" in ln.lower()][-10:],
        }

    def phase_native(self) -> None:
        up = self.start_provider("native", "auto")
        phase = {"provider": up}
        if up["routable"]:
            time.sleep(10)  # canary interval start and status settle
            phase["delivery"] = self.delivery_evidence("native")
            before = self.db_snapshot()
            phase["requests"] = self.requests()
            phase["status_after"] = native_status(self.ports["serve_port"])
            after = self.db_snapshot()
            phase["accounting_delta"] = self.delta(before, after)
        else:
            phase["delivery"] = self.delivery_evidence("native")
        self.result["phases"]["native"] = phase
        self.stop_provider()

    def phase_ordinary(self) -> None:
        up = self.start_provider("ordinary", "off")
        phase = {"provider": up}
        if up["routable"]:
            before = self.db_snapshot()
            phase["requests"] = self.requests()
            phase["status_after"] = native_status(self.ports["serve_port"])
            after = self.db_snapshot()
            phase["accounting_delta"] = self.delta(before, after)
        self.result["phases"]["ordinary"] = phase
        self.stop_provider()

    def phase_drill(self) -> None:
        up = self.start_provider("drill", "auto")
        phase = {"provider": up}
        if not up["routable"]:
            self.result["phases"]["drill"] = phase
            return
        phase["before"] = native_status(self.ports["serve_port"])
        ready = self.work / "revocations/emergency/READY"
        (self.work / "revocations/AWAITING_EMERGENCY_BATCH").write_text(now() + "\n")
        end = time.time() + int(self.cfg.get("emergency_batch_wait_s", 2400))
        while time.time() < end and not ready.exists():
            time.sleep(5)
        if not ready.exists():
            phase["emergency_batch"] = "not_delivered"
            self.result["phases"]["drill"] = phase
            return
        tmp = self.work / "revocations/current.next"
        os.symlink(self.work / "revocations/emergency/batch", tmp)
        os.replace(tmp, self.work / "revocations/current")
        phase["swapped_at"] = now()
        observations = []
        disabled_at = None
        end = time.time() + int(self.cfg.get("revocation_observe_s", 1080))
        while time.time() < end:
            status = native_status(self.ports["serve_port"])
            observations.append({"at": now(), "native_mtp": status.get("native_mtp")})
            if "revoked" in json.dumps(status.get("native_mtp")).lower():
                disabled_at = now()
                break
            time.sleep(30)
        phase["observations"] = observations[-5:]
        phase["disabled_at"] = disabled_at
        status, body = http_json("POST", self.ports["gateway_port"], "/v1/chat/completions",
                                 chat(PROMPTS[0], MAX_TOKENS), headers=self.auth())
        phase["after_request"] = {"status": status, "usage": body.get("usage") if isinstance(body, dict) else None}
        phase["admission_events"] = serve_rejections(self.work / "logs/provider-drill.err")[-5:]
        self.result["phases"]["drill"] = phase
        self.stop_provider()

    # ------------------------------------------------------------ verdicts

    def verdicts(self) -> None:
        native = self.result["phases"].get("native", {})
        ordinary = self.result["phases"].get("ordinary", {})
        drill = self.result["phases"].get("drill", {})
        delivery = native.get("delivery", {})
        nm = ((delivery.get("provider_status") or {}).get("native_mtp") or {})
        reqs_n, reqs_o = native.get("requests") or [], ordinary.get("requests") or []
        self.result["checks"] = {
            "delivery.static_feeds_served": bool(self.result.get("services", {}).get("static_feed_status"))
            and all(v == 200 for v in self.result["services"]["static_feed_status"].values()),
            "delivery.lab_override_active": delivery.get("lab_override_active") is True,
            "delivery.admission_set_materialized": any(m.endswith("native-mtp-admission.json")
                                                       for m in delivery.get("materialized_members", [])),
            "delivery.drafter_fetched": delivery.get("drafter_fetched_into_lab_store") is True,
            "delivery.native_admitted": nm.get("enabled") is True,
            "delivery.tuple_offered": delivery.get("tuple_offer_received") is True,
            "serving.all_200": bool(reqs_n) and all(r["status"] == 200 for r in reqs_n),
            "g8.ordinary_all_200": bool(reqs_o) and all(r["status"] == 200 for r in reqs_o),
            "g8.greedy_content_identical": bool(reqs_n) and [r["content_sha256"] for r in reqs_n]
            == [r["content_sha256"] for r in reqs_o],
            "g8.usage_identical": bool(reqs_n) and [r["usage"] for r in reqs_n] == [r["usage"] for r in reqs_o],
            "g8.accounting_deltas_identical": bool(native.get("accounting_delta"))
            and native.get("accounting_delta") == ordinary.get("accounting_delta"),
            "drill.tuple_disabled": drill.get("disabled_at") is not None,
            "drill.ordinary_serves_after": (drill.get("after_request") or {}).get("status") == 200,
        }

    def cleanup(self) -> None:
        for name in list(self.procs):
            stop(self.procs.pop(name, None))
        subprocess.run(["security", "delete-generic-password", "-s", ANCHOR_SERVICE, "-a", self.summary["key_id"]],
                       capture_output=True, timeout=30)

    def run(self) -> dict:
        self.preflight()
        try:
            self.setup()
            self.result["identity"] = {
                "lab_cli_sha256": sha256_file(self.lab_cli),
                "release_id": self.summary["release_id"],
                "key_id": self.summary["key_id"],
                "sidecar_sha256": self.summary["sidecar_sha256"],
                "native_mtp_admission_tuple_sha256": self.summary["native_mtp_admission_tuple_sha256"],
            }
            if self.result["identity"]["lab_cli_sha256"] != self.summary["facts"]["binary_sha256"]:
                raise SystemExit("lab binary is not the one the rehearsal release binds")
            self.bootstrap_accounts()
            self.start_services()
            phases = self.cfg.get("phases", ["native", "ordinary", "drill"])
            if "native" in phases:
                self.phase_native()
            if "ordinary" in phases:
                self.phase_ordinary()
            native = ((self.result["phases"].get("native", {}).get("delivery") or {}).get("provider_status") or {})
            if "drill" in phases and (native.get("native_mtp") or {}).get("enabled") is True:
                self.phase_drill()
            elif "drill" in phases:
                self.result["phases"]["drill"] = {"skipped": "native MTP was not admitted in the native phase"}
        finally:
            self.cleanup()
            self.release_lock()
            self.result["finished_at"] = now()
            self.verdicts()
            (self.work / "result.json").write_text(json.dumps(self.result, indent=2, sort_keys=True) + "\n")
        return self.result


def _terminate(signum, frame):
    raise KeyboardInterrupt(f"signal {signum}")


def main(argv=None) -> int:
    # A background launch ignores SIGINT; SIGTERM must still run the cleanup
    # that stops every lab process and releases the lab lock.
    signal.signal(signal.SIGTERM, _terminate)
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--config", type=Path, required=True)
    args = parser.parse_args(argv)
    result = Rehearsal(json.loads(args.config.read_text())).run()
    print(json.dumps(result["checks"], indent=2, sort_keys=True))
    return 0 if all(result["checks"].values()) else 1


if __name__ == "__main__":
    raise SystemExit(main())
