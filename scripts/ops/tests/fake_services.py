#!/usr/bin/env python3
"""Loopback stand-in for the coordinator, gateway and provider status used by
scripts/ops/test-entrypoints.sh. Usage: fake_services.py STATE_DIR (prints the port).

Files in STATE_DIR steer it:
  healthz.json            coordinator/gateway /healthz body; with "_policy": "running" the
                          compatibility policy fields come from running.yaml
                          ("_no_revoked_signal": true models a runtime without
                          compatibility_policy_revoked_signal)
  running.yaml            the coordinator config the fake coordinator is running
  autotune-release.json   /v1/autotune-release body (404 when absent)
  status.json             provider /v1/status base body
  metrics.txt, loaded.txt coordinator /metrics body parts (404 when all absent)
  rejections_seq          counter values served one per /metrics read (last repeats)
  rejections              unapproved rejection counter base; with rejections_bump it
                          grows by that much on every /metrics read
  mode                    gateway behaviour: move | greedy-mtp | cb-only | stuck | serial-request |
                          no-request-id | no-log-row | other-provider
  assigned_id             coordinator session recorded in request_log.provider_assigned_id for a
                          served completion (other-provider records a different one; no-log-row
                          records nothing); the gateway never reports provider identity to buyers
  request_log.db          sqlite request_log the fake coordinator writes (when the file exists)
  mirror-latest.json      /releases/latest.json body of the release mirror (404 when absent)
  served                  number of completions served (written here)
  gateway_models          models the gateway routes, one per line; a completion for any
                          other model answers 404 (absent: every model is routed)
  last_model              the model of the last completion request (written here)
  last_request.json       the complete JSON body of the last completion request (written here)
  operator_key            bearer the fake coordinator's /admin routes accept
  retention_busy, retention_disabled   POST .../retention/run answers 409 with that code
  retention_db            sqlite file whose settlement_evidence_retention_state row a
                          run updates (one more lap, overdue = retention_overdue, now)
  retention_overdue       last_lap_overdue_requests of the next run (default 0)
  retention_no_report     a started run never publishes its report
  retention_status        status of the next report (default deleted)
  retention_error         the next report is an error report (no stop_reason, no lap fields)
  retention_report.json   the last run's report (written here; ?report=last)
  retention_posts         number of run requests that started a run (written here)
  healthz_hits            one line per coordinator /healthz request (written here)
"""
import datetime
import json
import os
import sqlite3
import subprocess
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

state = sys.argv[1]


def read(name, default=None):
    path = os.path.join(state, name)
    if not os.path.exists(path):
        return default
    return open(path).read().strip()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, body, headers=None):
        data = body.encode() if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def admin_ok(self):
        if self.headers.get("Authorization") == "Bearer " + (read("operator_key") or "unset-key"):
            return True
        self.send(403, '{"error": {"code": "forbidden"}}')
        return False

    def retention_run(self):
        for code in ("retention_busy", "retention_disabled"):
            if read(code) is not None:
                return self.send(409, json.dumps({"error": {"code": code, "message": "x"}}))
        posts = int(read("retention_posts", "0")) + 1
        open(os.path.join(state, "retention_posts"), "w").write(str(posts))
        if read("retention_no_report") is not None:
            return self.send(202, '{"status": "started"}')
        now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f000Z")
        overdue = int(read("retention_overdue", "0"))
        laps = 1
        db = read("retention_db")
        if db:
            # The sqlite3 CLI, like the test's own writes: a WAL file Python's
            # module removes on close would make the gate's -readonly read fail.
            laps = int(subprocess.run(
                ["sqlite3", db, "UPDATE settlement_evidence_retention_state SET laps_completed = laps_completed + 1, "
                 "last_lap_overdue_requests = %d, last_lap_eligible_requests = 900, last_lap_completed_at_utc = '%s' WHERE id = 1; "
                 "SELECT laps_completed FROM settlement_evidence_retention_state WHERE id = 1;" % (overdue, now)],
                capture_output=True, text=True, check=True).stdout.strip())
        report = {"status": read("retention_status") or "deleted", "dry_run": False, "started_at_utc": now, "finished_at_utc": now,
                  "deleted_requests": 42, "archives": 1, "stop_reason": "lap_complete",
                  "backlog_drained": overdue == 0, "laps_completed": laps, "last_lap_overdue_requests": overdue,
                  "last_lap_eligible_requests": 900, "last_lap_completed_at_utc": now,
                  "archive_file": "/var/lib/macprovider/retention-archive/a.json.gz"}
        if read("retention_error") is not None:
            # An archive-verification error: no stop_reason and no lap fields.
            report = {"status": "exported", "started_at_utc": now, "finished_at_utc": now,
                      "deleted_requests": 0, "error": "archive verify failed"}
        open(os.path.join(state, "retention_report.json"), "w").write(json.dumps(report))
        return self.send(202, '{"status": "started"}')

    def do_GET(self):
        if self.path == "/admin/ledger/settlement-evidence-retention?report=last":
            if not self.admin_ok():
                return None
            body = read("retention_report.json")
            return self.send(200, body) if body else self.send(404, '{"error": {"code": "not_found"}}')
        if self.path == "/buyer/healthz":
            # The buyer listener's /healthz: no compatibility policy fields.
            return self.send(200, '{"status": "ok"}')
        if self.path == "/healthz":
            with open(os.path.join(state, "healthz_hits"), "a") as hits:
                hits.write("1\n")
            d = json.loads(read("healthz.json", "{}"))
            if d.pop("_policy", None) == "running":
                # A repository-admission runtime reports the compatibility
                # policy of the config it is running (running.yaml).
                import yaml
                cs = ((yaml.safe_load(read("running.yaml", "") or "{}") or {}).get("coordinator") or {}).get("compatibility_set") or {}
                d["compatibility_policy_mode"] = "repository" if cs else "unconfigured"
                d["compatibility_policy_target_id"] = str(cs.get("target_id") or "")
                d["compatibility_policy_revoked_ids"] = [str(x) for x in cs.get("revoked_ids") or []]
                # A runtime that sends compatibility_set_revoked (SPEC-020-R007),
                # unless the fixture models one that predates it.
                if cs and not d.pop("_no_revoked_signal", False):
                    d["compatibility_policy_revoked_signal"] = True
            return self.send(200, json.dumps(d))
        if self.path == "/releases/latest.json" and read("mirror-latest.json"):
            return self.send(200, read("mirror-latest.json"))
        if self.path == "/v1/autotune-release" and read("autotune-release.json"):
            return self.send(200, read("autotune-release.json"))
        # Any other coordinator route a test serves: svc/routes/<path, "/" -> "_">.
        route_body = read(os.path.join("routes", self.path.strip("/").replace("/", "_")))
        if route_body is not None:
            return self.send(200, route_body)
        if self.path == "/metrics":
            parts = [v for v in (read("metrics.txt"), read("loaded.txt")) if v is not None]
            seq = read("rejections_seq")
            if seq is not None:
                values = seq.split()
                open(os.path.join(state, "rejections_seq"), "w").write("\n".join(values[1:] or values))
                parts.append("# TYPE relayblind_privacy_posture_rejections_total counter\n"
                             'relayblind_privacy_posture_rejections_total{reason="posture_unapproved_code_identity"} %s' % values[0])
            elif read("rejections") is not None:
                reads = int(read("metrics_reads", "0"))
                open(os.path.join(state, "metrics_reads"), "w").write(str(reads + 1))
                value = int(read("rejections")) + int(read("rejections_bump", "0")) * reads
                parts.append("# TYPE relayblind_privacy_posture_rejections_total counter\n"
                             'relayblind_privacy_posture_rejections_total{reason="posture_unapproved_code_identity"} %d' % value)
            if parts:
                return self.send(200, "\n".join(parts) + "\n")
        if self.path == "/v1/status":
            d = json.loads(read("status.json", "{}"))
            served = int(read("served", "0"))
            mode = read("mode", "move")
            if mode in ("move", "other-provider", "no-provider-id"):
                d.setdefault("native_mtp", {})["mtp_forwards"] = d.get("native_mtp", {}).get("mtp_forwards", 0) + served
                d["requests_total"] = d.get("requests_total", 0) + served
                cb = d.setdefault("continuous_batching", {})
                scheduler = cb.setdefault("scheduler", {})
                scheduler["shared_forward_calls"] = scheduler.get("shared_forward_calls", 0) + served
            elif mode in ("cb-only", "greedy-mtp"):
                d["requests_total"] = d.get("requests_total", 0) + served
                cb = d.setdefault("continuous_batching", {})
                scheduler = cb.setdefault("scheduler", {})
                scheduler["shared_forward_calls"] = scheduler.get("shared_forward_calls", 0) + served
                if mode == "greedy-mtp":
                    d.setdefault("native_mtp", {})["mtp_forwards"] = (
                        d.get("native_mtp", {}).get("mtp_forwards", 0)
                        + int(read("greedy_served", "0"))
                    )
            elif mode == "serial-request":
                d["requests_total"] = d.get("requests_total", 0) + served
            return self.send(200, json.dumps(d))
        return self.send(404, '{"error": "not_found"}')

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        if self.path == "/admin/ledger/settlement-evidence-retention/run":
            return self.retention_run() if self.admin_ok() else None
        if self.path != "/v1/chat/completions":
            return self.send(404, "{}")
        if self.headers.get("Authorization") != "Bearer test-buyer-token":
            return self.send(401, '{"error": "unauthorized"}')
        try:
            request = json.loads(raw or b"{}")
            model = request.get("model", "")
        except ValueError:
            request = {}
            model = ""
        open(os.path.join(state, "last_model"), "w").write(model)
        open(os.path.join(state, "last_request.json"), "w").write(json.dumps(request))
        routed = read("gateway_models")
        if routed is not None and model not in routed.split():
            return self.send(404, '{"error": "model_not_found"}')
        served = int(read("served", "0")) + 1
        open(os.path.join(state, "served"), "w").write(str(served))
        headers = {}
        mode = read("mode", "move")
        if mode == "greedy-mtp" and request.get("temperature", 1.0) == 0 and request.get("top_p", 1.0) == 1:
            count = int(read("greedy_served", "0")) + 1
            open(os.path.join(state, "greedy_served"), "w").write(str(count))
        if mode != "no-request-id":
            headers["X-Request-ID"] = self.headers.get("X-Request-ID") or "gw-generated"
        db_path = os.path.join(state, "request_log.db")
        if mode != "no-log-row" and os.path.exists(db_path) and "X-Request-ID" in headers:
            assigned = "some-other-session" if mode == "other-provider" else read("assigned_id", "")
            con = sqlite3.connect(db_path)
            con.execute("INSERT INTO request_log (external_request_id, provider_assigned_id) VALUES (?, ?)",
                        (headers["X-Request-ID"], assigned))
            con.commit()
            con.close()
        body = {"id": "chatcmpl-test", "choices": [{"message": {"role": "assistant", "content": "ok"}}]}
        return self.send(200, json.dumps(body), headers)


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
open(os.path.join(state, "port"), "w").write(str(server.server_address[1]))
server.serve_forever()
