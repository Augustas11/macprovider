"""Isolated coordinator phase of the SPEC-048-R014 rehearsal runner.

Builds a private loopback stack from the release source: coordinator (SQLite,
settlement job off, no autotune, no Postgres) and gateway, then joins the
signed release provider to it with `--native-mtp auto` and sends real buyer
requests through the gateway. The coordinator is started twice: first with
`pool.native_mtp_canary` enabled (the only coordinator-side native-MTP tuple
setting at the release commit), then with it disabled. Every listener is
127.0.0.1 on the 193xx block; every path is under the run's work directory.

Called from native_mtp_r014_journey.Runner.phase_isolated_coordinator.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import sqlite3
import subprocess
import time
from datetime import datetime, timedelta, timezone
from pathlib import Path

from native_mtp_r014_journey import (FAIL, PASS, chat, http_json, http_stream, native_status, now,
                                     port_free, serve_rejections, stop)

SIGNER_GO = r'''
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
)

func main() {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil { panic(err) }
	raw, err := os.ReadFile(os.Args[1])
	if err != nil { panic(err) }
	sig := ed25519.Sign(priv, raw)
	env, _ := json.Marshal(map[string]string{"alg": "Ed25519", "key_id": os.Args[3], "signature": base64.StdEncoding.EncodeToString(sig)})
	if err := os.WriteFile(os.Args[2], env, 0o600); err != nil { panic(err) }
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
}
'''


def _wait_http(url_port: int, path: str, proc: subprocess.Popen, deadline_s: int = 60) -> bool:
    end = time.time() + deadline_s
    while time.time() < end:
        if proc.poll() is not None:
            return False
        try:
            status, _ = http_json("GET", url_port, path, timeout=3)
            if status in (200, 204):
                return True
        except OSError:
            pass
        time.sleep(0.5)
    return False


def _start(cmd, log: Path, env=None, cwd=None) -> subprocess.Popen:
    return subprocess.Popen(cmd, stdout=open(log, "w"), stderr=subprocess.STDOUT, env=env, cwd=cwd,
                            start_new_session=True)


def _token_columns(db: Path) -> dict:
    """Per-table row counts and token-column sums (no content columns)."""
    out = {}
    if not db.exists():
        return out
    with sqlite3.connect(f"file:{db}?mode=ro", uri=True) as conn:
        for (name,) in conn.execute("SELECT name FROM sqlite_master WHERE type='table'"):
            cols = [r[1] for r in conn.execute(f"PRAGMA table_info('{name}')")]
            token_cols = [c for c in cols if re.search(r"(prompt|completion|output|input|total)_tokens$", c)]
            credit_cols = [c for c in cols if re.search(r"(credits|cost|amount)", c) and not c.endswith("_at")]
            if not token_cols and not credit_cols:
                continue
            row = {"rows": conn.execute(f"SELECT COUNT(*) FROM '{name}'").fetchone()[0]}
            for c in token_cols + credit_cols:
                try:
                    row[f"sum({c})"] = conn.execute(f"SELECT COALESCE(SUM(\"{c}\"),0) FROM '{name}'").fetchone()[0]
                except sqlite3.Error:
                    pass
            out[name] = row
    return out


def run_isolated(r) -> dict:
    cfg = r.cfg
    iso = r.work / "isolated"
    if iso.exists():
        shutil.rmtree(iso)  # every run starts from empty databases and keys
    for sub in ("db", "run", "keys", "logs", "home", "tmp", "provider", "home/lifecycle", "home/watchdog"):
        (iso / sub).mkdir(parents=True, exist_ok=True)
    os.chmod(iso, 0o700)
    gobin = Path(cfg["go_bin_dir"]).expanduser()
    p_buyer, p_prov = int(cfg["coordinator_http_port"]), int(cfg["coordinator_ws_port"])
    p_gw, p_srv = int(cfg["gateway_port"]), int(cfg["isolated_serve_port"])
    for port in (p_buyer, p_prov, p_gw, p_srv):
        if not port_free(port):
            raise RuntimeError(f"isolated port {port} busy")
    s = {name: secrets.token_hex(32) for name in
         ("operator_key", "gateway_service_token", "key_hash_secret", "demo_secret")}
    provider_id = "r014-isolated-provider"

    # Coordinator-side native-MTP canary bank: the fixture's tuple record in the
    # coordinator challenge-bank schema, signed with a run-local Ed25519 key.
    bank_src = json.loads((r.fixture / "native-mtp-selftest-bank.json").read_text())
    issued = datetime.now(timezone.utc).replace(microsecond=0)
    bank = {
        "schema_version": "macprovider.native-mtp-challenge-bank.v1",
        "release_id": "r014-rehearsal-isolated",
        "issued_at": issued.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expires_at": (issued + timedelta(days=1)).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "signer_key_id": "r014-rehearsal-canary",
        "entries": bank_src["entries"],
    }
    bank_path = iso / "keys/native-mtp-challenge-bank.json"
    bank_path.write_text(json.dumps(bank, sort_keys=True, separators=(",", ":")))
    (iso / "run/sign.go").write_text(SIGNER_GO)
    go = str(Path(cfg["go_toolchain"]).expanduser())
    sign = subprocess.run([go, "run", str(iso / "run/sign.go"), str(bank_path), str(iso / "keys/bank.sig"),
                           "r014-rehearsal-canary"], capture_output=True, text=True, timeout=300,
                          env=dict(os.environ, GOFLAGS="-mod=mod", GOTOOLCHAIN="local"))
    canary_pub = sign.stdout.strip()

    def coord_config(canary: bool) -> dict:
        return {
            "listen": {"buyer_port": p_buyer, "provider_port": p_prov, "bind_address": "127.0.0.1"},
            "pool": {"heartbeat_interval_s": 2, "warmup_gate_enabled": False, "canary_enabled": False,
                     "native_mtp_canary": {"enabled": canary, "challenge_bank_path": str(bank_path) if canary else "",
                                           "signature_path": str(iso / "keys/bank.sig") if canary else "",
                                           "signer_key_id": "r014-rehearsal-canary" if canary else "",
                                           "public_keys": {"r014-rehearsal-canary": canary_pub} if canary else {},
                                           "interval_s": 900 if canary else 0}},
            "routing": {"request_timeout_s": 600, "retry_per_attempt_timeout_s": 600, "failover_enabled": False,
                        "sticky_enabled": False},
            "provider_http": {"timeout_s": 600},
            "admission": {"pinned_only": False, "provisional_pool_max": 100, "provisional_quota_per_hour": 100000},
            "auth": {"operator_key": s["operator_key"], "gateway_service_token": s["gateway_service_token"],
                     "require_provider_tokens": True},
            "storage": {"db_path": str(iso / "db/coordinator.db")},
            "logging": {"level": "debug", "format": "json"},
            "rewards": {"global_multiplier": 1.0, "provider_share": 0.9,
                        "rate_card": {"default": {"prompt_credits_per_mtok": 500000,
                                                  "prompt_cache_hit_credits_per_mtok": 125000,
                                                  "completion_credits_per_mtok": 1000000}}},
            "settlement": {"verified_model_settlement_mode": "observe", "job_enabled": False, "min_payout_credits": 0},
            "relay_blind": {"enabled": False},
            "explorer": {"enabled": False},
            "providers": [{"provider_id": provider_id, "display_name": "r014 isolated"}],
        }

    gateway_cfg = {
        "listen": {"bind_address": "127.0.0.1", "port": p_gw},
        "proxy": {"trusted_cidrs": ["127.0.0.0/8", "::1/128"]},
        "public": {"base_url": f"http://127.0.0.1:{p_gw}", "account_path": "/account"},
        "coordinator": {"buyer_url": f"http://127.0.0.1:{p_buyer}", "operator_url": f"http://127.0.0.1:{p_prov}",
                        "operator_key": s["operator_key"], "service_token": s["gateway_service_token"],
                        "poolz_poll_interval_s": 60},
        "storage": {"driver": "sqlite", "db_path": str(iso / "db/gateway.db")},
        "auth": {"key_prefix": "mp_", "key_hash": "hmac_sha256", "key_hash_secret": s["key_hash_secret"],
                 "github_oauth_enabled": False, "email_magic_link_enabled": False,
                 "oauth": {"callback_allowlist": [f"http://127.0.0.1:{p_gw}/auth/github/callback"]},
                 "demo": {"signing_secret": s["demo_secret"]}},
        "quotas": {"account_daily_tokens": 10000000, "account_concurrency": 8, "account_request_rate_per_second": 50},
        "limits": {"max_tokens_per_request": 4096},
        "timeouts": {"coordinator_request_seconds": 600, "coordinator_header_timeout_seconds": 600},
    }
    (iso / "run/gateway.yaml").write_text(json.dumps(gateway_cfg, indent=1))
    for path in (iso / "run/gateway.yaml",):
        os.chmod(path, 0o600)

    procs = {}
    result = {"started_at": now(), "steps": {}, "sub": {}}
    try:
        # Gateway schema, buyer key, provider token.
        gw = _start([str(gobin / "gateway"), "-config", str(iso / "run/gateway.yaml")], iso / "logs/gateway-migrate.log")
        end = time.time() + 20
        while time.time() < end:
            try:
                with sqlite3.connect(iso / "db/gateway.db") as db:
                    if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='api_keys'").fetchone():
                        break
            except sqlite3.Error:
                pass
            time.sleep(0.3)
        stop(gw)
        buyer_key = "mp_" + base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
        digest = hmac.new(s["key_hash_secret"].encode(), buyer_key.encode(), hashlib.sha256).digest()
        ts = datetime.now(timezone.utc).isoformat()
        with sqlite3.connect(iso / "db/gateway.db") as db:
            db.execute("INSERT INTO accounts(account_id,status,quota_class,concurrency_class,created_at) "
                       "VALUES('acct-r014-buyer','active','default','default',?)", (ts,))
            db.execute("INSERT INTO api_keys(key_id,account_id,key_hash,key_hash_prefix,status,created_at) "
                       "VALUES(?,'acct-r014-buyer',?,?,'active',?)",
                       ("key_" + secrets.token_hex(16), digest, buyer_key[:12], ts))
        tok = subprocess.run([str(gobin / "coordinator-cli"), "issue-token", "-db", str(iso / "db/coordinator.db"),
                              "-provider-id", provider_id, "-provider-name", "r014"],
                             capture_output=True, text=True, timeout=60)
        provider_token = re.search(r"token=(\S+)", tok.stdout).group(1)

        # Serve a clone of the snapshot with the lab-signed sidecar in its
        # bundle root, so the released serve path finds a sidecar and reaches
        # its signer/revocation checks (ModelRuntime.swift:8715-8753).
        live_target = Path(cfg["model_artifact_path"])
        clone_root = r.work / "models"
        clone_target = clone_root / live_target.relative_to(Path(cfg["model_store_root"]))
        if not clone_target.exists():
            clone_target.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(["cp", "-cR", str(live_target), str(clone_target)], check=True, timeout=1800)
        for name in ("native-mtp-admission.json", "native-mtp-admission.json.sig"):
            shutil.copyfile(r.fixture / name, clone_target.parent / name)

        # Provider config (isolated env, loopback coordinator, native auto).
        base = Path(cfg["serve_config_template"]).expanduser().read_text()
        keep = [ln for ln in base.splitlines() if not re.match(
            r"^(port|provider_id|coordinator_url|native_mtp_mode|provider_token|provider_token_file|credential_store|"
            r"model_artifact_path|auto_update_enabled|enable_receipts):", ln)]
        keep += [f"port: {p_srv}", f"provider_id: {provider_id}", f"provider_token: {provider_token}",
                 "credential_store: protected_file", f"coordinator_url: ws://127.0.0.1:{p_prov}/ws/provider",
                 f"model_artifact_path: \"{clone_target}\"", "auto_update_enabled: false",
                 "enable_receipts: true", "native_mtp_mode: auto"]
        pcfg = iso / "provider/config.yaml"
        pcfg.write_text("\n".join(keep) + "\n")
        os.chmod(pcfg, 0o600)
        if not cfg["coordinator_url_guard"] in pcfg.read_text():
            raise RuntimeError("provider config does not point at the isolated loopback coordinator")
        penv = dict(os.environ)
        penv.update({
            "CFFIXED_USER_HOME": str(iso / "home"), "TMPDIR": str(iso / "tmp") + "/",
            "MACPROVIDER_CONFIG": str(pcfg), "MACPROVIDER_LIFECYCLE_ROOT": str(iso / "home/lifecycle"),
            "MACPROVIDER_CTL_SOCKET_PATH": str(iso / "tmp/ctl.sock"),
            "MACPROVIDER_SWITCH_STATE_PATH": str(iso / "tmp/last-switch.ts"),
            "MACPROVIDER_WATCHDOG_STATE_DIR": str(iso / "home/watchdog"),
            "MACPROVIDER_AUTO_UPDATE_ENABLED": "false",
            "MACPROVIDER_MODEL_ARTIFACT_ROOT": str(clone_root),
        })
        imp = subprocess.run([str(r.signed_cli), "credentials", "import", "--config", str(pcfg)], env=penv,
                             capture_output=True, text=True, timeout=120)
        result["steps"]["credentials_import_exit"] = imp.returncode
        (iso / "logs/credentials-import.log").write_text(imp.stdout + imp.stderr)
        # The token now lives in protected credentials; drop it from the config.
        pcfg.write_text("\n".join(ln for ln in pcfg.read_text().splitlines() if not ln.startswith("provider_token:")) + "\n")

        def bring_up(label: str, canary: bool) -> dict:
            (iso / f"run/coordinator-{label}.yaml").write_text(json.dumps(coord_config(canary), indent=1))
            os.chmod(iso / f"run/coordinator-{label}.yaml", 0o600)
            procs["coordinator"] = _start([str(gobin / "coordinator"), "-config", str(iso / f"run/coordinator-{label}.yaml")],
                                          iso / f"logs/coordinator-{label}.log")
            ok_c = _wait_http(p_buyer, "/healthz", procs["coordinator"], 60)
            procs["gateway"] = _start([str(gobin / "gateway"), "-config", str(iso / "run/gateway.yaml")],
                                      iso / f"logs/gateway-{label}.log")
            ok_g = _wait_http(p_gw, "/healthz", procs["gateway"], 60)
            perr = iso / f"logs/provider-{label}.err"
            procs["provider"] = subprocess.Popen(
                [str(r.signed_cli), "serve", "--config", str(pcfg), "--isolate-lifecycle"],
                stdout=open(iso / f"logs/provider-{label}.out", "w"), stderr=open(perr, "w"), env=penv,
                start_new_session=True)
            ok_p = False
            end = time.time() + int(cfg.get("serve_ready_timeout_s", 300)) + 120
            probes = 0
            while time.time() < end and procs["provider"].poll() is None:
                # Readiness is a real buyer request through the gateway.
                try:
                    sg, _ = http_json("POST", p_gw, "/v1/chat/completions", chat("Reply with OK.", 4),
                                      headers={"Authorization": f"Bearer {buyer_key}"}, timeout=120)
                except OSError:
                    sg = 0
                probes += 1
                if sg == 200:
                    ok_p = True
                    break
                time.sleep(5)
            step = {"coordinator_up": ok_c, "gateway_up": ok_g, "provider_routable": ok_p, "readiness_probes": probes,
                    "native_mtp_canary_enabled": canary}
            if not ok_p:
                return step
            hdr = {"Authorization": f"Bearer {buyer_key}"}
            reqs = []
            st, body = http_json("POST", p_gw, "/v1/chat/completions", chat("Explain why the sky is blue in two sentences.", 96), headers=hdr)
            reqs.append({"kind": "nonstream_greedy", "status": st, "usage": body.get("usage") if isinstance(body, dict) else None,
                         "finish_reason": (body.get("choices") or [{}])[0].get("finish_reason") if isinstance(body, dict) else None,
                         "content_sha256": hashlib.sha256(((body.get("choices") or [{}])[0].get("message", {}).get("content") or "").encode()).hexdigest() if isinstance(body, dict) else None})
            st2, content, meta, frames = http_stream(p_gw, "/v1/chat/completions", chat("List four uses of copper.", 96, stream=True), headers=hdr)
            reqs.append({"kind": "stream_greedy", "status": st2, "usage": (meta or {}).get("usage"),
                         "finish_reason": (meta or {}).get("finish_reason"), "frames": frames,
                         "content_sha256": hashlib.sha256(content.encode()).hexdigest() if isinstance(content, str) else None})
            st3, body3 = http_json("POST", p_gw, "/v1/chat/completions", chat("Name a prime number above fifty.", 32, temperature=0.7), headers=hdr)
            reqs.append({"kind": "nonstream_sampled", "status": st3, "usage": body3.get("usage") if isinstance(body3, dict) else None})
            step["requests"] = reqs
            # Determinism: the greedy non-stream request repeated gives identical bytes.
            st4, body4 = http_json("POST", p_gw, "/v1/chat/completions", chat("Explain why the sky is blue in two sentences.", 96), headers=hdr)
            step["greedy_repeat_identical"] = isinstance(body4, dict) and hashlib.sha256(
                ((body4.get("choices") or [{}])[0].get("message", {}).get("content") or "").encode()).hexdigest() == reqs[0]["content_sha256"]
            step["provider_status"] = native_status(p_srv)
            time.sleep(4)
            step["coordinator_db_tokens"] = _token_columns(iso / "db/coordinator.db")
            step["gateway_db_tokens"] = _token_columns(iso / "db/gateway.db")
            step["provider_rejections"] = serve_rejections(perr)
            clog = (iso / f"logs/coordinator-{label}.log").read_text(errors="replace")
            step["coordinator_native_mtp_log_lines"] = [ln[:400] for ln in clog.splitlines() if "native" in ln.lower() and "mtp" in ln.lower()][:20]
            step["tuple_offer_received"] = "native_mtp_tuple_offer" in clog
            return step

        def bring_down() -> None:
            for name in ("provider", "gateway", "coordinator"):
                stop(procs.pop(name, None))

        result["steps"]["enabled"] = bring_up("enabled", canary=True)
        bring_down()
        result["steps"]["disabled"] = bring_up("disabled", canary=False)
        bring_down()
    finally:
        for name in list(procs):
            stop(procs.pop(name, None))
        for name in ("native-mtp-admission.json", "native-mtp-admission.json.sig"):
            try:
                (clone_target.parent / name).unlink()
            except (OSError, NameError):
                pass
    result["finished_at"] = now()

    en, dis = result["steps"].get("enabled", {}), result["steps"].get("disabled", {})

    def all_200(step):
        return bool(step.get("requests")) and all(q["status"] == 200 for q in step["requests"])

    def usage_ok(step):
        return bool(step.get("requests")) and all((q.get("usage") or {}).get("completion_tokens") for q in step["requests"])

    nm_en = ((en.get("provider_status") or {}).get("native_mtp") or {})
    nm_dis = ((dis.get("provider_status") or {}).get("native_mtp") or {})
    en_lines = en.get("coordinator_native_mtp_log_lines", [])
    canary_loaded = bool(en.get("coordinator_up")) and not any(
        "verification failed" in ln or "canary disabled" in ln for ln in en_lines)
    sub = {
        "enabled.stack_routable_with_signed_release": bool(en.get("provider_routable")),
        "enabled.buyer_requests_200_via_gateway": all_200(en),
        "enabled.coordinator_canary_bank_loaded": canary_loaded and bool(en.get("coordinator_up")),
        "enabled.provider_offered_native_tuple": bool(en.get("tuple_offer_received")),
        "enabled.native_admitted_on_provider": nm_en.get("enabled") is True,
        "disabled.buyer_requests_200_via_gateway": all_200(dis),
        "disabled.ordinary_decode": nm_dis.get("enabled") is not True,
        "usage_present_on_every_response": usage_ok(en) and usage_ok(dis),
    }
    result["sub"] = sub
    result["billing_ok"] = usage_ok(en) and usage_ok(dis)
    (r.evidence / "records").mkdir(exist_ok=True)
    (r.evidence / "records/isolated-coordinator.json").write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    for log in sorted((iso / "logs").glob("*")):
        if log.name.startswith(("provider-", "coordinator-enabled", "coordinator-disabled")):
            r.keep(log, f"isolated-{log.name}")
    native_e2e = sub["enabled.provider_offered_native_tuple"] and sub["enabled.native_admitted_on_provider"] and sub["enabled.buyer_requests_200_via_gateway"]
    r.record("item8-native-admission-e2e", PASS if native_e2e else FAIL,
             "signed release joined the isolated loopback coordinator and served real buyer requests through the "
             "gateway, but native MTP was never admitted: the release serve path rejects with "
             + ", ".join(sorted({x.get("reason_code", "?") for x in en.get("provider_rejections", [])}) or ["(no reason line)"])
             + " and no tuple offer reached the coordinator" if not native_e2e else
             "native MTP admitted and served buyer requests end to end",
             evidence=["records/isolated-coordinator.json"], sub={k: v for k, v in sub.items() if k.startswith("enabled.")},
             binary="signed release")
    enable_ok = sub["enabled.coordinator_canary_bank_loaded"] and sub["enabled.provider_offered_native_tuple"]
    disable_ok = sub["disabled.buyer_requests_200_via_gateway"] and sub["disabled.ordinary_decode"]
    r.record("item8-config-enable-disable", PASS if enable_ok and disable_ok else FAIL,
             ("coordinator config-enable (pool.native_mtp_canary) loaded the signed bank but the tuple could not be "
              "enabled because the provider never offers it; disable leaves ordinary decode serving every request")
             if not enable_ok else "tuple enabled, then disabled with ordinary fallback",
             evidence=["records/isolated-coordinator.json"],
             sub={"enable.bank_loaded": sub["enabled.coordinator_canary_bank_loaded"],
                  "enable.tuple_offered_and_selectable": sub["enabled.provider_offered_native_tuple"],
                  "disable.ordinary_fallback_serves": disable_ok},
             binary="signed release + isolated coordinator built from release source")
    return result
