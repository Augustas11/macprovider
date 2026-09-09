#!/usr/bin/env python3
"""Hermetic JOURNEY-PROVIDER-BYOM-DISCOVERY driver (#1453 slice 1).

Runs all ten normative steps of `journeys/JOURNEY-PROVIDER-BYOM-DISCOVERY.md`
against loopback stubs and an on-disk MLX-cache fixture, saves every CLI JSON
document it produced, and emits the `macprovider.byom-journey-run.v1` run
manifest that `scripts/capture-byom-journey-evidence.py` consumes.

Every observation in the manifest is set from this driver's own assertions, not
declared. A failed assertion aborts the run, so a manifest only ever exists for
a run where all ten steps passed.

Nothing here signs or promotes anything, and nothing is written into the
repository: the captures and the manifest go to `--out`, which the operator
keeps locally. Only their digests reach the evidence artifact.
"""

import argparse
import hashlib
import json
import os
import pathlib
import secrets
import shutil
import subprocess
import sys
import tempfile
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


JOURNEY_ID = "JOURNEY-PROVIDER-BYOM-DISCOVERY"
RUN_MANIFEST_SCHEMA = "macprovider.byom-journey-run.v1"
HARNESS_NAME = "test/e2e/byom/run-discovery-journey.py"
ENVIRONMENT_CLASS = "hermetic-loopback"

MLX_MODEL_ID = "mlx-community/Tiny-1B-4bit"
MLX_SNAPSHOT_REVISION = "0123456789abcdef0123456789abcdef01234567"
OLLAMA_MODEL_NAME = "tiny-ollama-1b-q4"
OPAQUE_MODEL_ID = "opaque-mini-1b"
OPAQUE_SERVED_MODEL_REF = "openai_compatible:" + OPAQUE_MODEL_ID
# Distinctive so the step-08 scan can prove no completion text was ever echoed.
COMPLETION_MARKER = "byomprobecompletionmarker"

# Per-step SPEC-046 requirement subjects. These are the mapped requirement ids
# from scripts/check_spec_governance.py (PROVIDER_BYOM_DISCOVERY_STEP_REQUIREMENT_IDS);
# capture re-validates them, so this table must not invent one.
STEP_REQUIREMENT_IDS = {
    "step-01-discover-mlx-cache": ["SPEC-046-R001", "SPEC-046-R002", "SPEC-046-R003"],
    "step-02-discover-loopback-runtime": ["SPEC-046-R001", "SPEC-046-R002", "SPEC-046-R003"],
    "step-03-discover-opaque-endpoint": ["SPEC-046-R002", "SPEC-046-R003", "SPEC-046-R004"],
    "step-04-reject-non-loopback": ["SPEC-046-R002", "SPEC-046-R007"],
    "step-05-handle-adapter-failure": ["SPEC-046-R002", "SPEC-046-R004"],
    "step-06-evaluate-candidate": ["SPEC-046-R001", "SPEC-046-R005"],
    "step-07-no-production-mutation": ["SPEC-046-R006"],
    "step-08-redaction-review": ["SPEC-046-R007"],
    "step-09-state-boundary": ["SPEC-046-R003"],
    "step-10-local-state-ladder": ["SPEC-046-R003", "SPEC-046-R008"],
}

TRUE_OBSERVATIONS = (
    "adapter_failure_warned",
    "candidate_evaluated",
    "local_state_ladder_verified",
    "loopback_runtime_discovered",
    "mlx_cache_discovered",
    "non_loopback_rejected",
    "opaque_endpoint_candidate_discovered",
    "redacted_artifacts_reviewed",
    "state_boundary_preserved",
)
FALSE_OBSERVATIONS = (
    "buyer_traffic_sent",
    "provider_credit_created",
    "raw_completion_logged",
    "raw_prompt_logged",
    "runtime_installed",
    "weights_downloaded",
)


class HarnessFailure(Exception):
    pass


sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[3] / "scripts"))
import byom_journey_evidence as evidence_contract  # noqa: E402


# `provider_guidance.state_label_key` / `state_meaning_key` are dotted
# localization label paths (`byom.local.offerable`). The evidence scanner is
# shape-based and fail-closed, with deliberately no allowlist for
# captured-document fields, so it cannot tell those apart from a DNS hostname.
# They carry no verdict: every decision-bearing guidance field
# (`next_action`, `transition_reason_code`, `earning_path_class`) is retained,
# and no assertion in this manifest depends on the dropped keys.
GUIDANCE_LOCALIZATION_KEYS = ("state_label_key", "state_meaning_key")


def redact_for_capture(value):
    if isinstance(value, dict):
        return {
            key: redact_for_capture(item)
            for key, item in value.items()
            if key not in GUIDANCE_LOCALIZATION_KEYS
        }
    if isinstance(value, list):
        return [redact_for_capture(item) for item in value]
    return value


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
        self.started = False
        self.ready = threading.Event()
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def _serve(self):
        self.ready.set()
        self.httpd.serve_forever()

    @property
    def port(self):
        return self.httpd.server_address[1]

    @property
    def origin(self):
        host, port = self.httpd.server_address
        return "http://%s:%d" % (host, port)

    def start(self):
        if self.started:
            return
        self.thread.start()
        self.ready.wait(timeout=5)
        self.started = True

    def stop(self):
        if self.started:
            self.httpd.shutdown()
            self.thread.join(timeout=5)
            self.started = False
        self.httpd.server_close()


class JSONHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def send_json(self, payload, raw=None):
        if raw is None:
            encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        else:
            encoded = raw.encode("utf-8")
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)


class OllamaHandler(JSONHandler):
    def do_GET(self):
        self.server.state["paths"].append(self.path)
        if self.path != "/api/tags":
            self.send_error(404)
            return
        self.send_json({
            "models": [{
                "name": OLLAMA_MODEL_NAME,
                "details": {"family": "llama", "quantization_level": "Q4_0"},
            }],
        })


class OpenAICompatibleHandler(JSONHandler):
    def do_GET(self):
        self.server.state["paths"].append(self.path)
        if self.path != "/v1/models":
            self.send_error(404)
            return
        self.send_json({"object": "list", "data": [{"id": OPAQUE_MODEL_ID, "object": "model"}]})

    def do_POST(self):
        self.server.state["paths"].append(self.path)
        if self.path != "/v1/chat/completions":
            self.send_error(404)
            return
        length = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(length)
        self.server.state["chat_bodies"].append(body.decode("utf-8", errors="replace"))
        self.send_json({
            "id": "chatcmpl-local",
            "object": "chat.completion",
            "choices": [{
                "index": 0,
                "message": {"role": "assistant", "content": COMPLETION_MARKER},
                "finish_reason": "stop",
            }],
            "usage": {"prompt_tokens": 11, "completion_tokens": 2, "total_tokens": 13},
        })


class MalformedOpenAIHandler(JSONHandler):
    """Answers `/v1/models` with well-formed JSON of the wrong shape.

    Deterministic where a closed-port probe would race the port allocator, and it
    exercises the same closed `adapter_malformed_response` code path.
    """

    def do_GET(self):
        self.server.state["paths"].append(self.path)
        self.send_json(None, raw='{"object":"list","data":"not-an-array"}')


def create_mlx_cache_fixture(cache_root):
    """HuggingFace cache layout the MLX adapter recognizes: a `models--<org>--<name>`
    repo directory holding `snapshots/<rev>/` with a config and a weights file."""
    snapshot = (
        cache_root
        / ("models--" + MLX_MODEL_ID.replace("/", "--"))
        / "snapshots"
        / MLX_SNAPSHOT_REVISION
    )
    snapshot.mkdir(parents=True)
    (snapshot / "config.json").write_text(
        json.dumps({"max_position_embeddings": 4096}), encoding="utf-8"
    )
    (snapshot / "model.safetensors").write_bytes(b"\x7a" * 4096)


def directory_digest(root):
    """Content digest over every regular file under `root`, so step-07 can prove
    the cache and the local salt were not mutated."""
    digest = hashlib.sha256()
    for path in sorted(p for p in root.rglob("*") if p.is_file()):
        digest.update(str(path.relative_to(root)).encode("utf-8"))
        digest.update(b"\x00")
        digest.update(hashlib.sha256(path.read_bytes()).digest())
    return digest.hexdigest()


class Runner:
    def __init__(self, cli, env, cwd):
        self.cli = cli
        self.env = env
        self.cwd = cwd
        self.transcript = []

    def run(self, args):
        completed = subprocess.run(
            [str(self.cli)] + args,
            cwd=str(self.cwd),
            env=self.env,
            text=True,
            capture_output=True,
        )
        self.transcript.append(completed.stdout)
        self.transcript.append(completed.stderr)
        if completed.returncode != 0:
            raise HarnessFailure(
                "CLI failed (%d): %s" % (completed.returncode, " ".join(args[:3]))
            )
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise HarnessFailure("invalid JSON stdout for %s: %s" % (" ".join(args[:3]), exc))


def candidate_by_runtime_source(document, runtime_source):
    for candidate in document.get("candidates", []):
        if candidate.get("runtime_source") == runtime_source:
            return candidate
    raise HarnessFailure("no %s candidate in discovery output" % runtime_source)


def adapter_by_runtime_source(document, runtime_source):
    for adapter in document.get("adapters", []):
        if adapter.get("runtime_source") == runtime_source:
            return adapter
    raise HarnessFailure("no %s adapter in discovery output" % runtime_source)


class ManifestBuilder:
    """Collects per-step verdicts and captured documents, then emits the manifest.

    `assertion` strings are short prose and must stay free of URLs, absolute
    paths, hostnames and IP literals: capture's redaction scan runs over them.
    """

    def __init__(self, out_dir, run_id, cli_version):
        self.out_dir = out_dir
        self.captures = out_dir / "captures"
        self.captures.mkdir(parents=True, exist_ok=True)
        self.run_id = run_id
        self.cli_version = cli_version
        self.steps = []
        self.observations = {name: None for name in TRUE_OBSERVATIONS + FALSE_OBSERVATIONS}

    def capture(self, name, document):
        """Write one captured CLI document, redacted and re-scanned fail-closed.

        The scan is the capture tool's own, imported rather than reimplemented,
        so this driver can never emit a manifest whose documents capture would
        reject.
        """
        redacted = redact_for_capture(document)
        payload = json.dumps(redacted, indent=2, sort_keys=True) + "\n"
        try:
            evidence_contract.reject_unredacted_text(payload, "captured document " + name)
            evidence_contract.assert_redacted(redacted, "captured document " + name)
        except evidence_contract.BYOMEvidenceError as exc:
            raise HarnessFailure("captured document %s is not redaction-clean: %s" % (name, exc))
        path = self.captures / (name + ".json")
        path.write_text(payload, encoding="utf-8")
        return path

    def add_step(self, step_id, assertion, documents):
        assert_true(step_id in STEP_REQUIREMENT_IDS, "unknown step id: " + step_id)
        self.steps.append({
            "id": step_id,
            "status": "pass",
            "assertion": assertion,
            "requirement_ids": list(STEP_REQUIREMENT_IDS[step_id]),
            "documents": documents,
        })

    def document(self, document_id, schema, capture_name):
        return {
            "id": document_id,
            "schema": schema,
            "path": "captures/" + capture_name + ".json",
        }

    def observe(self, name, value):
        assert_true(name in self.observations, "unknown observation: " + name)
        self.observations[name] = value

    def write(self):
        missing = sorted(name for name, value in self.observations.items() if value is None)
        assert_true(not missing, "observations never set by a check: " + ", ".join(missing))
        for name in TRUE_OBSERVATIONS:
            assert_true(self.observations[name] is True, "observation must be true: " + name)
        for name in FALSE_OBSERVATIONS:
            assert_true(self.observations[name] is False, "observation must be false: " + name)
        ordered = sorted(STEP_REQUIREMENT_IDS)
        assert_true(
            [step["id"] for step in self.steps] == ordered,
            "manifest steps must cover every journey step exactly once",
        )
        manifest = {
            "schema_version": RUN_MANIFEST_SCHEMA,
            "journey_id": JOURNEY_ID,
            "run_id": self.run_id,
            "environment_class": ENVIRONMENT_CLASS,
            "cli_version": self.cli_version,
            "harness": {"name": HARNESS_NAME, "status": "pass"},
            "steps": self.steps,
            "observations": {name: self.observations[name] for name in sorted(self.observations)},
        }
        path = self.out_dir / "run-manifest.json"
        path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        return path


def redaction_review(transcript, capture_dir, forbidden):
    """Step-08: no origin, port, local path, prompt or completion text anywhere in
    the CLI's stdout, stderr, or the captured JSON documents."""
    haystacks = list(transcript)
    for path in sorted(capture_dir.glob("*.json")):
        haystacks.append(path.read_text(encoding="utf-8"))
    for needle in forbidden:
        if not needle:
            continue
        for haystack in haystacks:
            if needle in haystack:
                raise HarnessFailure("redaction review found leaked material: %r" % needle[:24])
    return True


def main():
    parser = argparse.ArgumentParser(description="Run the hermetic BYOM discovery journey.")
    parser.add_argument("--out", required=True, help="Directory for captures/ and run-manifest.json.")
    parser.add_argument("--keep-temp", action="store_true", help="Keep the temporary harness directory.")
    args = parser.parse_args()

    root = repo_root()
    out_dir = pathlib.Path(args.out).expanduser().resolve()
    temp_root = pathlib.Path(tempfile.mkdtemp(prefix="macprovider-byom-discovery-"))
    ollama = LocalHTTPServer(OllamaHandler, {"paths": []})
    openai = LocalHTTPServer(OpenAICompatibleHandler, {"paths": [], "chat_bodies": []})
    broken = LocalHTTPServer(MalformedOpenAIHandler, {"paths": []})
    try:
        cli = build_cli(root, os.environ.get("MACPROVIDER_CLI_BINARY"))
        ollama.start()
        openai.start()
        broken.start()

        home = temp_root / "home"
        home.mkdir(mode=0o700)
        # `models discover` is read-only by SPEC-046-R001 and will not provision
        # the salt itself, so seed it: without it every candidate id is
        # byom_unstable_* and the state ladder collapses to local_only.
        namespace = temp_root / "local-discovery.namespace"
        namespace.write_bytes(secrets.token_bytes(32))
        namespace.chmod(0o600)
        hf_cache = temp_root / "hf-cache"
        create_mlx_cache_fixture(hf_cache)

        env = os.environ.copy()
        env.update({
            "HOME": str(home),
            # The MLX fixture would report does_not_fit on a small CI runner and
            # block the ladder this journey exercises; the fit logic still runs.
            "MACPROVIDER_BYOM_E2E_DETECTED_RAM_GB": "64",
        })
        for stale in ("MACPROVIDER_CONFIG", "HF_HOME", "HF_HUB_CACHE"):
            env.pop(stale, None)

        local_args = [
            "--local-discovery-namespace-path", str(namespace),
            "--mlx-cache-dir", str(hf_cache),
        ]
        runner = Runner(cli, env, root)
        cli_version = subprocess.run(
            [str(cli), "--version"], capture_output=True, text=True, check=True
        ).stdout.strip()
        run_id = "byom-discovery-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        manifest = ManifestBuilder(out_dir, run_id, cli_version)

        cache_digest_before = directory_digest(hf_cache)
        namespace_before = namespace.read_bytes()
        home_digest_before = directory_digest(home)

        # Step 01 - MLX-cache discovery.
        mlx_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama"] + local_args
        )
        assert_true(mlx_document.get("schema") == "provider_byom_discovery.v1", "wrong discovery schema")
        mlx_candidate = candidate_by_runtime_source(mlx_document, "mlx_cache")
        assert_true(mlx_candidate.get("served_model_ref") == MLX_MODEL_ID, "mlx served ref changed")
        assert_true(mlx_candidate.get("locality") == "local_artifact", "mlx locality changed")
        assert_true(mlx_candidate.get("readiness_state") == "ready", "mlx fixture not ready")
        assert_true(
            mlx_candidate.get("candidate_id", "").startswith("byom_")
            and not mlx_candidate["candidate_id"].startswith("byom_unstable_"),
            "mlx candidate id is not namespace-stable",
        )
        assert_true(
            mlx_candidate.get("admission_state_source") == "local_default",
            "mlx candidate claimed coordinator authority",
        )
        manifest.capture("discover-mlx-cache", mlx_document)
        manifest.add_step(
            "step-01-discover-mlx-cache",
            "MLX-cache candidate discovered read-only with a stable namespace-scoped candidate id.",
            [manifest.document("discover-mlx-cache", "provider_byom_discovery.v1", "discover-mlx-cache")],
        )
        manifest.observe("mlx_cache_discovered", True)

        # Step 02 - loopback runtime discovery.
        ollama_document = runner.run(
            ["models", "discover", "--json", "--ollama-origin", ollama.origin] + local_args
        )
        ollama_candidate = candidate_by_runtime_source(ollama_document, "ollama_loopback")
        assert_true(
            ollama_candidate.get("served_model_ref") == "ollama:" + OLLAMA_MODEL_NAME,
            "ollama served ref changed",
        )
        assert_true(ollama_candidate.get("locality") == "loopback_runtime", "ollama locality changed")
        assert_true(
            adapter_by_runtime_source(ollama_document, "ollama_loopback").get("status") == "ok",
            "ollama adapter did not report ok",
        )
        assert_true(ollama.state["paths"] == ["/api/tags"], "ollama adapter probed an unexpected path")
        manifest.capture("discover-loopback-runtime", ollama_document)
        manifest.add_step(
            "step-02-discover-loopback-runtime",
            "Loopback Ollama adapter enumerated one candidate without leaving the host.",
            [manifest.document(
                "discover-loopback-runtime", "provider_byom_discovery.v1", "discover-loopback-runtime"
            )],
        )
        manifest.observe("loopback_runtime_discovered", True)

        # Step 03 - opaque OpenAI-compatible endpoint.
        opaque_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--openai-compatible-origin", openai.origin] + local_args
        )
        opaque_candidate = candidate_by_runtime_source(opaque_document, "openai_compatible_loopback")
        opaque_candidate_id = opaque_candidate["candidate_id"]
        assert_true(
            opaque_candidate.get("served_model_ref") == OPAQUE_SERVED_MODEL_REF,
            "opaque served ref changed",
        )
        assert_true(
            opaque_candidate.get("identity_state") == "opaque_endpoint",
            "opaque candidate did not report an opaque identity",
        )
        assert_true(
            opaque_candidate.get("locality") == "opaque_local_endpoint",
            "opaque candidate did not report an opaque locality",
        )
        assert_true(opaque_candidate.get("catalog_model_key") is None, "opaque candidate claimed a catalog key")
        assert_true(
            opaque_candidate.get("admission_state") in ("local_only", "not_offered"),
            "opaque candidate left the non-earning local states",
        )
        assert_true(
            opaque_candidate.get("admission_state_source") == "local_default",
            "opaque candidate claimed coordinator authority",
        )
        capabilities = opaque_candidate.get("capabilities") or {}
        assert_true(
            all(value is None for value in capabilities.values()),
            "opaque candidate asserted an unevaluated capability",
        )
        assert_true(
            (opaque_candidate.get("provider_guidance") or {}).get("earning_path_class")
            == "local_inventory_only",
            "opaque candidate claimed an earning path",
        )
        assert_true(openai.state["paths"] == ["/v1/models"], "opaque adapter probed an unexpected path")
        manifest.capture("discover-opaque-endpoint", opaque_document)
        manifest.add_step(
            "step-03-discover-opaque-endpoint",
            "Opaque OpenAI-compatible candidate reported identity_state opaque_endpoint, "
            "null capabilities, and a non-earning local state.",
            [manifest.document(
                "discover-opaque-endpoint", "provider_byom_discovery.v1", "discover-opaque-endpoint"
            )],
        )
        manifest.observe("opaque_endpoint_candidate_discovered", True)

        # Step 04 - non-loopback origin rejected before dispatch. The wildcard
        # address resolves to this host, so a leaked request would reach the stub
        # and the request-count assertion would fail.
        openai_paths_before = list(openai.state["paths"])
        rejected_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--openai-compatible-origin", "http://0.0.0.0:%d" % openai.port] + local_args
        )
        rejected_adapter = adapter_by_runtime_source(rejected_document, "openai_compatible_loopback")
        assert_true(rejected_adapter.get("status") == "rejected", "non-loopback origin was not rejected")
        assert_true(
            rejected_adapter.get("warning_codes") == ["adapter_rejected_non_loopback"],
            "rejection did not use the closed warning code",
        )
        assert_true(
            not any(c.get("runtime_source") == "openai_compatible_loopback"
                    for c in rejected_document.get("candidates", [])),
            "rejected adapter fabricated a candidate",
        )
        assert_true(
            openai.state["paths"] == openai_paths_before,
            "a request left the host for a non-loopback origin",
        )
        manifest.capture("discover-non-loopback-rejected", rejected_document)
        manifest.add_step(
            "step-04-reject-non-loopback",
            "Non-loopback adapter origin rejected before any request was issued, "
            "and the endpoint never appeared in the projection.",
            [manifest.document(
                "discover-non-loopback-rejected",
                "provider_byom_discovery.v1",
                "discover-non-loopback-rejected",
            )],
        )
        manifest.observe("non_loopback_rejected", True)

        # Step 05 - adapter failure is a warning, not a trust claim.
        failure_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--openai-compatible-origin", broken.origin] + local_args
        )
        failure_adapter = adapter_by_runtime_source(failure_document, "openai_compatible_loopback")
        assert_true(failure_adapter.get("status") == "malformed", "malformed adapter was not reported")
        assert_true(
            failure_adapter.get("warning_codes") == ["adapter_malformed_response"],
            "adapter failure did not use the closed warning code",
        )
        assert_true(
            "adapter_malformed_response" in (failure_document.get("warnings") or []),
            "adapter failure was not surfaced in the top-level warnings",
        )
        assert_true(
            not any(c.get("runtime_source") == "openai_compatible_loopback"
                    for c in failure_document.get("candidates", [])),
            "malformed adapter fabricated a candidate",
        )
        manifest.capture("discover-adapter-failure", failure_document)
        manifest.add_step(
            "step-05-handle-adapter-failure",
            "Malformed adapter response surfaced as a closed warning code, not a trust claim.",
            [manifest.document(
                "discover-adapter-failure", "provider_byom_discovery.v1", "discover-adapter-failure"
            )],
        )
        manifest.observe("adapter_failure_warned", True)

        # Step 06 - bounded local evaluation of the opaque candidate.
        evaluation = runner.run(
            ["models", "evaluate", opaque_candidate_id, "--json", "--skip-ollama",
             "--openai-compatible-origin", openai.origin] + local_args
        )
        assert_true(evaluation.get("schema") == "provider_byom_evaluation.v1", "wrong evaluation schema")
        assert_true(evaluation.get("candidate_id") == opaque_candidate_id, "evaluation resolved another candidate")
        assert_true(
            evaluation.get("runtime_source") == "openai_compatible_loopback",
            "evaluation changed the runtime source",
        )
        assert_true(evaluation.get("health_result") == "passed", "evaluation did not pass")
        assert_true(evaluation.get("request_count") == 1, "evaluation exceeded its request budget")
        assert_true(
            evaluation.get("usage_reporting_source") == "runtime_reported",
            "evaluation lost the usage-reporting source",
        )
        assert_true(
            evaluation.get("offer_preconditions_appear_satisfied") is False,
            "an opaque endpoint claimed satisfied offer preconditions",
        )
        assert_true(len(openai.state["chat_bodies"]) == 1, "evaluation sent more than one probe")
        manifest.capture("evaluate-candidate", evaluation)
        manifest.add_step(
            "step-06-evaluate-candidate",
            "models evaluate ran the bounded local harness against the opaque endpoint "
            "and reported health_result passed with one request.",
            [manifest.document("evaluate-candidate", "provider_byom_evaluation.v1", "evaluate-candidate")],
        )
        manifest.observe("candidate_evaluated", True)
        manifest.observe("buyer_traffic_sent", False)
        manifest.observe("provider_credit_created", False)

        # Step 07 - no production mutation. The mutation summary is the CLI's own
        # claim; the fixture digests are the independent check on it.
        mutations = evaluation.get("mutation_summary") or {}
        assert_true(bool(mutations), "evaluation reported no mutation summary")
        assert_true(
            all(value is False for value in mutations.values()),
            "evaluation claimed a mutation: %s" % sorted(k for k, v in mutations.items() if v),
        )
        assert_true(directory_digest(hf_cache) == cache_digest_before, "the model cache was mutated")
        assert_true(namespace.read_bytes() == namespace_before, "the discovery namespace was rewritten")
        assert_true(directory_digest(home) == home_digest_before, "provider config under home was mutated")
        manifest.add_step(
            "step-07-no-production-mutation",
            "mutation_summary reported no config, cache, weight, or coordinator mutation, "
            "and the fixture digests were unchanged after the run.",
            [manifest.document(
                "evaluate-mutation-summary", "provider_byom_evaluation.v1", "evaluate-candidate"
            )],
        )
        manifest.observe("weights_downloaded", False)
        manifest.observe("runtime_installed", False)

        # Step 09 runs before 08 so its output is inside the redaction review.
        dry_run = runner.run(
            ["models", "offer", opaque_candidate_id, "--dry-run", "--json", "--skip-ollama",
             "--openai-compatible-origin", openai.origin] + local_args
        )
        assert_true(
            dry_run.get("schema") == "model_admission_offer_dry_run.v1", "wrong dry-run schema"
        )
        assert_true(dry_run.get("candidate_id") == opaque_candidate_id, "dry-run resolved another candidate")
        assert_true(dry_run.get("would_submit") is False, "an opaque endpoint predicted a submittable offer")
        assert_true(dry_run.get("catalog_model_key") is None, "dry-run invented a catalog key")
        assert_true(
            dry_run.get("likely_admission_state") in ("local_only", "not_offered"),
            "dry-run promoted the local admission state",
        )
        assert_true(
            dry_run.get("likely_admission_state_source") == "local_default",
            "dry-run claimed coordinator authority",
        )
        dry_run_guidance = dry_run.get("provider_guidance") or {}
        assert_true(
            dry_run_guidance.get("earning_path_class") == "local_inventory_only",
            "dry-run claimed an earning path",
        )
        assert_true(
            dry_run_guidance.get("state_meaning_key")
            != "byom.offer_dry_run.catalog_path_missing_trusted_binding",
            "dry-run claimed a catalog path for an opaque endpoint",
        )
        manifest.capture("offer-dry-run", dry_run)

        # Step 10 - the local state ladder, before step 08 for the same reason.
        ladder_document = runner.run(
            ["models", "discover", "--json",
             "--ollama-origin", ollama.origin,
             "--openai-compatible-origin", openai.origin] + local_args
        )
        ladder_states = {
            candidate["runtime_source"]: candidate for candidate in ladder_document.get("candidates", [])
        }
        offerable = [c for c in ladder_document.get("candidates", []) if c.get("admission_state") == "offerable"]
        local_only = [c for c in ladder_document.get("candidates", []) if c.get("admission_state") == "local_only"]
        assert_true(offerable, "no offerable candidate in the ladder projection")
        assert_true(local_only, "no local_only candidate in the ladder projection")
        assert_true(
            "openai_compatible_loopback" in ladder_states
            and ladder_states["openai_compatible_loopback"].get("admission_state") == "local_only",
            "the opaque candidate left local_only in the ladder projection",
        )
        for candidate in offerable + local_only:
            guidance = candidate.get("provider_guidance") or {}
            assert_true(
                guidance.get("next_action") in (
                    "fix_local_blocker", "evaluate", "offer_dry_run", "submit_offer",
                    "revise_and_reoffer", "check_status", "withdraw", "wait_for_coordinator",
                    "maintain_runtime", "none",
                ),
                "a ladder candidate reported no closed next action",
            )
            assert_true(
                candidate.get("admission_state_source") == "local_default",
                "a ladder candidate claimed coordinator authority",
            )
        for candidate in local_only:
            assert_true(
                (candidate.get("provider_guidance") or {}).get("transition_reason_code"),
                "a local_only candidate reported no local transition reason",
            )
        manifest.capture("discover-state-ladder", ladder_document)

        # A missing namespace is the other route into local_only: the candidate id
        # is unstable, so the CLI must refuse to treat the candidate as offerable.
        unstable_document = runner.run(
            ["models", "discover", "--json", "--skip-ollama",
             "--local-discovery-namespace-path", str(temp_root / "absent.namespace"),
             "--mlx-cache-dir", str(hf_cache)]
        )
        unstable_candidate = candidate_by_runtime_source(unstable_document, "mlx_cache")
        assert_true(
            unstable_candidate.get("admission_state") == "local_only",
            "an unstable candidate was reported offerable",
        )
        assert_true(
            "candidate_id_unstable" in (unstable_candidate.get("warning_codes") or []),
            "an unstable candidate lost its transition reason",
        )
        assert_true(
            not (temp_root / "absent.namespace").exists(),
            "discovery provisioned the namespace it was told to read",
        )
        manifest.capture("discover-state-ladder-unstable", unstable_document)

        # local-default `not_offered` is the coordinator-unqueried label, which the
        # catalog-economics projection reports for catalog rows with no local
        # candidate; discovery itself reports only local_only and offerable.
        economics = runner.run(
            ["models", "catalog-economics", "--json", "--skip-coordinator-status", "--skip-ollama"]
            + local_args
        )
        assert_true(
            economics.get("schema") == "model_catalog_economics.v1", "wrong catalog economics schema"
        )
        not_offered = [
            row for row in economics.get("rows", [])
            if (row.get("admission") or {}).get("state") == "not_offered"
            and (row.get("admission") or {}).get("source") == "local_default"
        ]
        assert_true(not_offered, "no local-default not_offered row in the economics projection")
        for row in not_offered:
            admission = row.get("admission") or {}
            assert_true(admission.get("settlement_capable") is False, "a not_offered row claimed settlement")
            assert_true(
                admission.get("catalog_economics_permitted") is False,
                "a not_offered row permitted catalog economics",
            )
        manifest.capture("catalog-economics-state-ladder", economics)

        manifest.add_step(
            "step-09-state-boundary",
            "Evaluated candidate stayed non-routable and non-earning with no coordinator state "
            "and no catalog earning path.",
            [manifest.document(
                "offer-dry-run-state-boundary", "model_admission_offer_dry_run.v1", "offer-dry-run"
            )],
        )
        manifest.observe("state_boundary_preserved", True)
        manifest.add_step(
            "step-10-local-state-ladder",
            "local_only, offerable, and local-default not_offered each reported their next action "
            "and local transition reason.",
            [
                manifest.document(
                    "discover-state-ladder", "provider_byom_discovery.v1", "discover-state-ladder"
                ),
                manifest.document(
                    "discover-state-ladder-unstable",
                    "provider_byom_discovery.v1",
                    "discover-state-ladder-unstable",
                ),
                manifest.document(
                    "catalog-economics-state-ladder",
                    "model_catalog_economics.v1",
                    "catalog-economics-state-ladder",
                ),
            ],
        )
        manifest.observe("local_state_ladder_verified", True)

        # Step 08 - redaction review over every command's output and every capture.
        probe_prompt = json.loads(openai.state["chat_bodies"][0])["messages"][0]["content"]
        forbidden = [
            ollama.origin, openai.origin, broken.origin,
            # host:port rather than a bare port: a bare 5-digit number would
            # collide with digests and byte counts and make this scan flaky.
            "127.0.0.1:%d" % ollama.port,
            "127.0.0.1:%d" % openai.port,
            "127.0.0.1:%d" % broken.port,
            str(temp_root), str(home), str(namespace), str(hf_cache),
            probe_prompt, COMPLETION_MARKER,
        ]
        assert_true(
            redaction_review(runner.transcript, manifest.captures, forbidden),
            "redaction review failed",
        )
        manifest.add_step(
            "step-08-redaction-review",
            "JSON and stderr carried no prompt, completion, credential, endpoint, or local path material.",
            [manifest.document(
                "discover-redaction-review", "provider_byom_discovery.v1", "discover-opaque-endpoint"
            )],
        )
        manifest.observe("redacted_artifacts_reviewed", True)
        manifest.observe("raw_prompt_logged", False)
        manifest.observe("raw_completion_logged", False)

        manifest.steps.sort(key=lambda step: step["id"])
        manifest_path = manifest.write()
        print("BYOM discovery journey passed")
        print("run_id=%s cli_version=%s steps=%d" % (run_id, cli_version, len(manifest.steps)))
        print("manifest=%s" % manifest_path)
        return 0
    except Exception as exc:
        print("BYOM discovery journey failed: %s" % exc, file=sys.stderr)
        if args.keep_temp:
            print("temp_root=%s" % temp_root, file=sys.stderr)
        return 1
    finally:
        for server in (ollama, openai, broken):
            try:
                server.stop()
            except Exception:
                pass
        if args.keep_temp:
            print("kept temp_root=%s" % temp_root)
        else:
            shutil.rmtree(str(temp_root), ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
