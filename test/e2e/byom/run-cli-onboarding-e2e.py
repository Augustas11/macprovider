#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse


PROVIDER_ID = "provider-byom-e2e"
PROVIDER_TOKEN = "provider-token-e2e"
MODEL_NAME = "qwen3-8b"
SERVED_MODEL_REF = "ollama:" + MODEL_NAME
CATALOG_MODEL_KEY = "qwen3-8b"
NOW = "2027-01-15T08:00:00Z"


class HarnessFailure(Exception):
    pass


def assert_true(condition, message):
    if not condition:
        raise HarnessFailure(message)


def repo_root():
    return pathlib.Path(__file__).resolve().parents[3]


def build_cli(root, explicit_binary):
    if explicit_binary:
        path = pathlib.Path(explicit_binary).expanduser().resolve()
        assert_true(path.exists(), "MACPROVIDER_CLI_BINARY does not exist: " + str(path))
        return path
    subprocess.run(
        ["swift", "build", "--product", "macprovider-cli"],
        cwd=str(root / "phase3-binary"),
        check=True,
    )
    path = root / "phase3-binary" / ".build" / "debug" / "macprovider-cli"
    assert_true(path.exists(), "swift build did not produce " + str(path))
    return path


class LocalHTTPServer:
    def __init__(self, handler_class, state):
        self.state = state
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), handler_class)
        self.httpd.state = state
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)

    @property
    def origin(self):
        host, port = self.httpd.server_address
        return "http://%s:%d" % (host, port)

    def start(self):
        self.thread.start()

    def stop(self):
        self.httpd.shutdown()
        self.thread.join(timeout=5)
        self.httpd.server_close()


class OllamaHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/api/tags":
            self.send_error(404)
            return
        self.server.state["paths"].append(self.path)
        self.send_json({
            "models": [{
                "name": MODEL_NAME,
                "details": {
                    "family": "qwen",
                    "quantization_level": "Q4_0",
                },
            }],
        })

    def do_POST(self):
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        self.server.state["paths"].append(self.path)
        self.server.state["chat_bodies"].append(body.decode("utf-8", errors="replace"))
        self.send_json({
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": "ok"},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 2, "total_tokens": 12},
        })

    def log_message(self, *_args):
        pass

    def send_json(self, payload):
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class CoordinatorHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path != "/v1/provider/model-admission/status":
            self.send_error(404)
            return
        self.require_auth()
        candidate_id = parse_qs(parsed.query).get("candidate_id", [""])[0]
        self.record("GET", parsed.path, {"candidate_id": candidate_id})
        status = self.server.state["statuses"].get(candidate_id)
        if not status:
            status = self.status_payload(
                candidate_id=candidate_id,
                served_model_ref="",
                catalog_model_key=None,
                state="not_offered",
                event_id=None,
            )
        self.send_json(status)

    def do_POST(self):
        if self.path not in (
            "/v1/provider/model-admission/offers",
            "/v1/provider/model-admission/withdrawals",
        ):
            self.send_error(404)
            return
        self.require_auth()
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length).decode("utf-8")
        payload = json.loads(body)
        self.record("POST", self.path, payload)
        if self.path.endswith("/offers"):
            self.handle_offer(payload)
        else:
            self.handle_withdraw(payload)

    def handle_offer(self, payload):
        required = [
            "schema",
            "provider_id",
            "candidate_id",
            "served_model_ref",
            "discovery_digest_sha256",
            "evaluation_digest_sha256",
            "signing_key_digest",
            "provider_signature",
        ]
        for key in required:
            assert_true(key in payload, "offer request missing " + key)
        assert_true(payload["schema"] == "model_admission_offer_submit.v1", "wrong offer schema")
        assert_true(payload["provider_id"] == PROVIDER_ID, "wrong provider_id in offer")
        assert_true(payload["served_model_ref"] == SERVED_MODEL_REF, "wrong served_model_ref in offer")
        assert_true(payload["catalog_model_key"] == CATALOG_MODEL_KEY, "wrong catalog_model_key in offer")
        assert_true(len(payload["evaluation_digest_sha256"]) == 64, "offer missing evaluation digest")
        assert_true("endpoint" not in json.dumps(payload), "offer reflected endpoint material")
        candidate_id = payload["candidate_id"]
        status = self.status_payload(
            candidate_id=candidate_id,
            served_model_ref=payload["served_model_ref"],
            catalog_model_key=payload["catalog_model_key"],
            state="offer_submitted",
            event_id="event_test",
        )
        self.server.state["statuses"][candidate_id] = status
        self.send_json(status)

    def handle_withdraw(self, payload):
        assert_true(payload["schema"] == "model_admission_withdraw_request.v1", "wrong withdraw schema")
        assert_true(payload["provider_id"] == PROVIDER_ID, "wrong provider_id in withdraw")
        assert_true(payload["served_model_ref"] == SERVED_MODEL_REF, "wrong served_model_ref in withdraw")
        assert_true(payload["reason_code"] == "provider_requested", "wrong withdraw reason")
        assert_true(payload.get("provider_signature"), "withdraw missing signature")
        candidate_id = payload["candidate_id"]
        previous = self.server.state["statuses"].get(candidate_id, {})
        withdrawal = {
            "schema": "model_admission_withdraw.v1",
            "generated_at": "2027-01-15T08:00:01Z",
            "cli_version": "test",
            "provider_id": PROVIDER_ID,
            "candidate_id": candidate_id,
            "served_model_ref": payload["served_model_ref"],
            "catalog_model_key": payload.get("catalog_model_key"),
            "idempotency_key": payload["idempotency_key"],
            "reason_code": payload["reason_code"],
            "previous_admission_state": previous.get("admission_state", "offer_submitted"),
            "coordinator_event_id": "withdraw_event_test",
            "accepted_at": "2027-01-15T08:00:01Z",
            "resulting_admission_state": "withdrawn",
            "provider_guidance": self.guidance("withdrawn", reason_code=payload["reason_code"]),
            "warnings": [],
        }
        self.server.state["statuses"][candidate_id] = self.status_payload(
            candidate_id=candidate_id,
            served_model_ref=payload["served_model_ref"],
            catalog_model_key=payload.get("catalog_model_key"),
            state="withdrawn",
            event_id="withdraw_event_test",
            reason_code=payload["reason_code"],
        )
        self.send_json(withdrawal)

    def status_payload(self, candidate_id, served_model_ref, catalog_model_key, state, event_id, reason_code=None):
        return {
            "schema": "model_admission_status.v1",
            "generated_at": NOW,
            "cli_version": "test",
            "provider_id": PROVIDER_ID,
            "candidate_id": candidate_id,
            "served_model_ref": served_model_ref,
            "catalog_model_key": catalog_model_key,
            "admission_state": state,
            "admission_state_source": "coordinator",
            "coordinator_event_id": event_id,
            "state_observed_at": NOW,
            "provider_guidance": self.guidance(state, reason_code=reason_code),
            "allowed_next_states": self.allowed_next_states(state),
            "warnings": [],
        }

    def guidance(self, state, reason_code=None):
        return {
            "state_label_key": "byom.admission." + state,
            "state_meaning_key": "byom.admission.not_earning",
            "next_action": "submit_offer" if state in ("not_offered", "withdrawn") else "wait_for_coordinator",
            "transition_reason_code": reason_code,
            "earning_path_class": "local_inventory_only" if state == "not_offered" else "no_earning_path_in_v0_1",
        }

    def allowed_next_states(self, state):
        if state in ("not_offered", "withdrawn"):
            return ["offer_submitted"]
        if state == "offer_submitted":
            return [
                "offer_rejected",
                "sandbox_probe_only",
                "network_visible_unpriced",
                "network_admitted_unsettled",
                "catalog_priced",
                "withdrawn",
                "revoked",
            ]
        return []

    def require_auth(self):
        got = self.headers.get("authorization")
        assert_true(got == "Bearer " + PROVIDER_TOKEN, "bad Authorization header")

    def record(self, method, path, payload):
        self.server.state["requests"].append({
            "method": method,
            "path": path,
            "payload": payload,
        })

    def log_message(self, *_args):
        pass

    def send_json(self, payload):
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


def run_cli(cli, args, env, cwd):
    completed = subprocess.run(
        [str(cli)] + args,
        cwd=str(cwd),
        env=env,
        text=True,
        capture_output=True,
    )
    if completed.returncode != 0:
        raise HarnessFailure(
            "CLI failed (%d): %s\nstdout:\n%s\nstderr:\n%s"
            % (completed.returncode, " ".join(args), completed.stdout, completed.stderr)
        )
    return completed


def parse_json_output(completed):
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise HarnessFailure("invalid JSON stdout: %s\n%s" % (exc, completed.stdout))


def find_candidate(document):
    candidates = document.get("candidates", [])
    for candidate in candidates:
        if candidate.get("served_model_ref") == SERVED_MODEL_REF:
            return candidate
    raise HarnessFailure("candidate not found in discovery output")


def assert_null_money(row):
    null_fields = [
        "prompt_rate_usd_per_million_tokens",
        "completion_rate_usd_per_million_tokens",
        "provider_prompt_payout_usd_per_million_tokens",
        "provider_completion_payout_usd_per_million_tokens",
    ]
    for field in null_fields:
        assert_true(row.get(field) is None, "expected null " + field)
    assert_true(row.get("economics_state") == "blocked", "economics did not remain blocked")
    assert_true(row.get("rate_source") == "none", "rate source did not remain none")
    admission = row.get("admission") or {}
    assert_true(admission.get("catalog_economics_permitted") is False, "catalog economics became permitted")
    assert_true(admission.get("settlement_capable") is False, "settlement became capable")


def catalog_row(document, candidate_id):
    assert_true(document.get("schema") == "model_catalog_economics.v1", "wrong catalog economics schema")
    for row in document.get("rows", []):
        if row.get("action_model_id") == candidate_id:
            return row
    raise HarnessFailure("catalog economics row not found for " + candidate_id)


def main():
    parser = argparse.ArgumentParser(description="Run the BYOM CLI onboarding E2E harness.")
    parser.add_argument("--keep-temp", action="store_true", help="Keep the temporary harness directory.")
    args = parser.parse_args()

    root = repo_root()
    temp_root = pathlib.Path(tempfile.mkdtemp(prefix="macprovider-byom-e2e-"))
    ollama = LocalHTTPServer(OllamaHandler, {"paths": [], "chat_bodies": []})
    coordinator = LocalHTTPServer(CoordinatorHandler, {"requests": [], "statuses": {}})
    try:
        cli = build_cli(root, os.environ.get("MACPROVIDER_CLI_BINARY"))
        ollama.start()
        coordinator.start()

        home = temp_root / "home"
        home.mkdir(mode=0o700)
        protected_root = temp_root / "protected-credentials"
        namespace = temp_root / "local-discovery.namespace"
        hf_cache = temp_root / "hf-cache"
        config = temp_root / "config.yaml"
        config.write_text(
            "\n".join([
                "provider_id: " + PROVIDER_ID,
                "provider_token: " + PROVIDER_TOKEN,
                "coordinator_url: " + coordinator.origin,
                "credential_store: protected_file",
                "",
            ]),
            encoding="utf-8",
        )

        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            "MACPROVIDER_CONFIG": str(config),
            "MACPROVIDER_PROTECTED_CREDENTIAL_ROOT": str(protected_root),
            "MACPROVIDER_BYOM_ALLOW_INSECURE_LOOPBACK_COORDINATOR": "1",
        })

        common_discovery_args = [
            "--local-discovery-namespace-path", str(namespace),
            "--mlx-cache-dir", str(hf_cache),
            "--ollama-origin", ollama.origin,
        ]

        credentials = parse_json_output(run_cli(
            cli,
            ["credentials", "import", "--config", str(config)],
            env,
            root,
        ))
        assert_true(credentials.get("status") == "ok", "credential import failed")
        assert_true(credentials.get("credential_store") == "protected_file", "wrong credential store")

        discovery = parse_json_output(run_cli(
            cli,
            ["models", "discover", "--json"] + common_discovery_args,
            env,
            root,
        ))
        assert_true(discovery.get("schema") == "provider_byom_discovery.v1", "wrong discovery schema")
        candidate = find_candidate(discovery)
        candidate_id = candidate["candidate_id"]
        assert_true(candidate.get("admission_state_source") == "local_default", "discovery admission source mutated")
        assert_true(candidate.get("admission_state") == "offerable", "candidate not locally offerable")
        assert_true(candidate.get("catalog_model_key") == CATALOG_MODEL_KEY, "catalog key was not discovered")
        assert_true(coordinator.state["requests"] == [], "discovery contacted coordinator")

        evaluation_result = run_cli(
            cli,
            ["models", "evaluate", SERVED_MODEL_REF, "--json"] + common_discovery_args,
            env,
            root,
        )
        evaluation = parse_json_output(evaluation_result)
        assert_true(evaluation.get("schema") == "provider_byom_evaluation.v1", "wrong evaluation schema")
        assert_true(evaluation.get("health_result") == "passed", "evaluation did not pass")
        assert_true(evaluation.get("offer_preconditions_appear_satisfied") is True, "evaluation did not satisfy offer preconditions")
        mutations = evaluation.get("mutation_summary") or {}
        assert_true(mutations.get("coordinator_state_mutated") is False, "evaluation claims coordinator mutation")
        assert_true(mutations.get("production_config_mutated") is False, "evaluation claims config mutation")
        assert_true(coordinator.state["requests"] == [], "evaluation contacted coordinator")

        evaluation_digest = hashlib.sha256(evaluation_result.stdout.encode("utf-8")).hexdigest()
        dry_run = parse_json_output(run_cli(
            cli,
            ["models", "offer", SERVED_MODEL_REF, "--dry-run", "--json"] + common_discovery_args,
            env,
            root,
        ))
        assert_true(dry_run.get("schema") == "model_admission_offer_dry_run.v1", "wrong dry-run schema")
        assert_true(dry_run.get("candidate_id") == candidate_id, "dry-run resolved a different candidate")
        assert_true(dry_run.get("would_submit") is False, "dry-run unexpectedly submits without evaluation digest")
        assert_true(dry_run.get("reason_code") == "evaluation_required", "dry-run did not explain evaluation gate")
        assert_true(coordinator.state["requests"] == [], "dry-run contacted coordinator")

        offer = parse_json_output(run_cli(
            cli,
            [
                "models", "offer", SERVED_MODEL_REF,
                "--yes",
                "--json",
                "--config", str(config),
                "--evaluation-digest-sha256", evaluation_digest,
            ] + common_discovery_args,
            env,
            root,
        ))
        assert_true(offer.get("schema") == "model_admission_status.v1", "wrong offer response schema")
        assert_true(offer.get("admission_state") == "offer_submitted", "offer was not submitted")
        assert_true(offer.get("admission_state_source") == "coordinator", "offer status was not coordinator-backed")
        assert_true(offer.get("candidate_id") == candidate_id, "offer used a different candidate")
        assert_true(len(coordinator.state["requests"]) == 1, "offer did not make exactly one coordinator request")

        status = parse_json_output(run_cli(
            cli,
            ["models", "admission", "status", SERVED_MODEL_REF, "--json", "--config", str(config)] + common_discovery_args,
            env,
            root,
        ))
        assert_true(status.get("admission_state") == "offer_submitted", "status did not read submitted offer")
        assert_true(status.get("candidate_id") == candidate_id, "status candidate mismatch")

        economics = parse_json_output(run_cli(
            cli,
            ["models", "catalog-economics", "--json", "--config", str(config)] + common_discovery_args,
            env,
            root,
        ))
        row = catalog_row(economics, candidate_id)
        admission = row.get("admission") or {}
        assert_true(admission.get("state") == "offer_submitted", "catalog economics did not use coordinator admission")
        assert_true(admission.get("source") == "coordinator", "catalog economics admission source was not coordinator")
        assert_null_money(row)

        withdrawal = parse_json_output(run_cli(
            cli,
            [
                "models", "admission", "withdraw", SERVED_MODEL_REF,
                "--yes",
                "--json",
                "--config", str(config),
                "--reason-code", "provider_requested",
            ] + common_discovery_args,
            env,
            root,
        ))
        assert_true(withdrawal.get("schema") == "model_admission_withdraw.v1", "wrong withdrawal schema")
        assert_true(withdrawal.get("resulting_admission_state") == "withdrawn", "withdrawal did not withdraw")

        withdrawn_status = parse_json_output(run_cli(
            cli,
            ["models", "admission", "status", SERVED_MODEL_REF, "--json", "--config", str(config)] + common_discovery_args,
            env,
            root,
        ))
        assert_true(withdrawn_status.get("admission_state") == "withdrawn", "withdrawn status was not observed")

        withdrawn_economics = parse_json_output(run_cli(
            cli,
            ["models", "catalog-economics", "--json", "--config", str(config)] + common_discovery_args,
            env,
            root,
        ))
        withdrawn_row = catalog_row(withdrawn_economics, candidate_id)
        withdrawn_admission = withdrawn_row.get("admission") or {}
        assert_true(withdrawn_admission.get("state") == "withdrawn", "withdrawn economics did not use coordinator state")
        assert_true(withdrawn_admission.get("source") == "coordinator", "withdrawn economics source was not coordinator")
        assert_null_money(withdrawn_row)

        print("BYOM CLI onboarding E2E passed")
        print("candidate_id=%s coordinator_requests=%d" % (candidate_id, len(coordinator.state["requests"])))
        return 0
    except Exception as exc:
        print("BYOM CLI onboarding E2E failed: %s" % exc, file=sys.stderr)
        if args.keep_temp:
            print("temp_root=%s" % temp_root, file=sys.stderr)
        return 1
    finally:
        try:
            ollama.stop()
        finally:
            coordinator.stop()
        if args.keep_temp:
            print("kept temp_root=%s" % temp_root)
        else:
            shutil.rmtree(str(temp_root), ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
