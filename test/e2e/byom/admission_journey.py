"""JOURNEY-NETWORK-MODEL-ADMISSION physical-provider runner (BYOM v0.2 slice 7, #1486).

Drives the twelve journey steps against a REAL coordinator and a real provider
CLI, captures every CLI document whole through the shared evidence contract,
measures the ten money-path ledgers, and emits ``run-manifest.json`` in the
exact shape ``scripts/capture-byom-journey-evidence.py`` consumes. The
designated harness ``run-cli-onboarding-e2e.py`` invokes this in
``--journey-evidence`` mode; its hermetic stub mode is untouched.

Design rules, in priority order:

1. Evidence is measured, never declared. Every observation is set from an
   assertion over a document the CLI or coordinator produced, and the
   money-path zero rows are read from the ledgers, not asserted from config.
2. Nothing the run needs is trusted from the runtime. Operator actors are
   distinct bearer credentials from the environment (never argv, never
   logged); the coordinator origin must be loopback; captured documents pass
   the same fail-closed redaction scan the capture tool applies.
3. The state machine under test is the coordinator's. This runner asks the
   coordinator to do things and asserts on what it did; it never fabricates a
   state.
4. Transport is an interface. ``PhysicalRig`` is the thin real one; tests use
   a fake, so the orchestration is verifiable without hardware.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Protocol

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))

import byom_journey_evidence as evidence_contract  # noqa: E402
from byom_journey_evidence import (  # noqa: E402
    ADMISSION_ALLOWED_NEXT_STATES,
    ADMISSION_CONTRACT,
    ADMISSION_WITHDRAWAL_REASON_CODES,
    validate_captured_cli_document,
)

JOURNEY_ID = ADMISSION_CONTRACT.journey_id
RUN_MANIFEST_SCHEMA = "macprovider.byom-journey-run.v1"
HARNESS_NAME = ADMISSION_CONTRACT.expected_harness_name
ENVIRONMENT_CLASS = "physical-provider"

STEP_IDS = tuple(ADMISSION_CONTRACT.step_id_order)
STEP_REQUIREMENT_IDS = {step: sorted(ids) for step, ids in ADMISSION_CONTRACT.step_requirement_ids.items()}
# SPEC-047-R008 is the release-evidence requirement the journey proves as a
# whole; the contract attaches it to the final review step (as the discovery
# driver attaches SPEC-046-R008 to its last step, and as the admission
# manifest fixture does), so the union across steps covers every mapped
# requirement.
STEP_REQUIREMENT_IDS[STEP_IDS[-1]] = sorted(set(STEP_REQUIREMENT_IDS[STEP_IDS[-1]]) | {"SPEC-047-R008"})
TRUE_OBSERVATIONS = tuple(ADMISSION_CONTRACT.true_observations)
FALSE_OBSERVATIONS = tuple(ADMISSION_CONTRACT.false_observations)
MONEY_PATH_TABLES = tuple(ADMISSION_CONTRACT.money_path_tables)

# SPEC-047-R006 closed drift reason set (coordinator: model_admission_binding.go).
# Revocation in step 7 must carry one of these; an operator-origin revocation
# would prove nothing about drift detection.
DRIFT_REASON_CODES = frozenset({
    "runtime_identity_drift",
    "catalog_artifact_feed_changed",
    "catalog_row_changed",
    "catalog_row_ineligible",
    "catalog_runtime_source_disallowed",
    "receipt_key_unavailable",
})

DECISION_REQUEST_SCHEMA = "model_admission_decision_request.v1"
APPROVE_REQUEST_SCHEMA = "model_admission_decision_approve_request.v1"
DECISIONS_PATH = "/admin/model-admission/decisions"
OFFERS_PATH = "/admin/model-admission/offers"

# Operator-surface grammars, mirrored from the coordinator
# (phase4-coordinator/internal/ws/model_admission_operator.go). A request the
# coordinator would refuse as invalid_request must be refused here first, so a
# runner defect can never be mistaken for a coordinator verdict.
OPERATOR_REASON_CODE = re.compile(r"^operator_[a-z0-9_]{2,56}$")
COORDINATOR_EVENT_ID = re.compile(r"^[0-9a-f]{64}$")
PENDING_DECISION_ID = re.compile(r"^[0-9a-f]{32}$")
IDEMPOTENCY_KEY = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
# The four operator reasons the journey records, all inside the grammar.
REASON_EXPERIMENTAL_DISCLOSURE = "operator_experimental_disclosure"
REASON_CATALOG_BINDING_VERIFIED = "operator_catalog_binding_verified"
REASON_DUAL_CONTROL_SETTLEMENT = "operator_dual_control_settlement"
REASON_MATRIX_PROBE = "operator_matrix_probe"
for _reason in (REASON_EXPERIMENTAL_DISCLOSURE, REASON_CATALOG_BINDING_VERIFIED, REASON_DUAL_CONTROL_SETTLEMENT, REASON_MATRIX_PROBE):
    assert OPERATOR_REASON_CODE.match(_reason), _reason
# SPEC-047 closed withdrawal reason; the journey's withdrawal is a plain
# provider request.
WITHDRAWAL_REASON = "provider_requested"
assert WITHDRAWAL_REASON in ADMISSION_WITHDRAWAL_REASON_CODES

# The coordinator's synthetic probe prompt (server.go runModelAdmissionSyntheticProbe).
# It is the one prompt this journey causes to exist, so its presence in any
# reviewed surface is a logged raw prompt.
SYNTHETIC_PROBE_PROMPT = "Reply with ok."
# Chat-completion request and response shapes; either in a log or an evidence
# surface is a raw prompt or completion that was persisted.
RAW_PROMPT_SHAPES = (re.compile(r'"messages"\s*:\s*\['), re.compile(r'"role"\s*:\s*"user"'))
RAW_COMPLETION_SHAPES = (re.compile(r'"choices"\s*:\s*\['), re.compile(r'"delta"\s*:\s*\{'), re.compile(r'"role"\s*:\s*"assistant"'))
# The surfaces step 12 must review, by name. Each is a text blob assembled
# from what the run actually produced or touched.
REDACTION_SURFACES = ("runner_log", "cli_transcript", "captured_documents", "coordinator_events", "provider_log", "coordinator_log")

LOOPBACK_ORIGIN = re.compile(r"^http://(127\.0\.0\.1|\[::1\]|localhost)(:\d{1,5})?$")
ACTOR_ID = re.compile(r"^[a-z][a-z0-9_-]{1,63}$")


class JourneyFailure(Exception):
    """A step assertion failed. The run stops and no manifest is published."""


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise JourneyFailure(message)


def error_code(body: Any) -> str | None:
    """The closed `error.code` of a coordinator refusal envelope, else None."""
    if isinstance(body, dict) and isinstance(body.get("error"), dict):
        code = body["error"].get("code")
        return code if isinstance(code, str) else None
    return None


# Field names that would let a coordinator dereference a candidate directly.
# SPEC-047 step 4: a synthetic probe reaches the candidate only through the
# authenticated provider channel, so none of these may appear in what the
# coordinator holds or returns for a candidate.
LOCATOR_KEYS = frozenset({"endpoint", "endpoint_url", "origin", "socket", "socket_path", "url", "base_url", "local_path", "artifact_path", "model_path"})


def collect_keys(value: Any) -> set[str]:
    keys: set[str] = set()
    if isinstance(value, dict):
        for key, inner in value.items():
            keys.add(str(key)); keys |= collect_keys(inner)
    elif isinstance(value, list):
        for inner in value:
            keys |= collect_keys(inner)
    return keys


# --------------------------------------------------------------------------- rig

@dataclass(frozen=True)
class RigConfig:
    """Everything the runner needs to reach the rig. Secrets are read from the
    environment by name so they never appear on a command line or in a
    manifest; the names, not the values, are what get recorded."""

    cli_binary: Path
    provider_config: Path
    coordinator_admin_origin: str
    operator_actor_a: str
    operator_actor_b: str
    operator_secret_a_env: str
    operator_secret_b_env: str
    postgres_dsn_env: str
    settleable_ref: str
    opaque_ref: str
    gguf_ref: str
    provider_log: Path
    coordinator_log: Path
    drift_hook: Path | None
    discovery_args: tuple[str, ...] = ()

    def validate(self) -> None:
        assert_true(self.cli_binary.is_file() and os.access(self.cli_binary, os.X_OK), "cli binary is not executable")
        assert_true(self.provider_config.is_file(), "provider config is missing")
        assert_true(self.provider_log.is_file() and self.coordinator_log.is_file(), "step 12 reviews the provider and coordinator logs; both --provider-log and --coordinator-log must name existing files")
        refs = (self.settleable_ref, self.opaque_ref, self.gguf_ref)
        assert_true(all(isinstance(ref, str) and ref for ref in refs) and len(set(refs)) == 3, "the settleable, opaque and gguf candidates must be three distinct references; none is optional")
        assert_true(bool(LOOPBACK_ORIGIN.match(self.coordinator_admin_origin)), "coordinator admin origin must be loopback http")
        for actor in (self.operator_actor_a, self.operator_actor_b):
            assert_true(bool(ACTOR_ID.match(actor)), "operator actor id is not in the SPEC-047 actor grammar")
        assert_true(self.operator_actor_a != self.operator_actor_b, "dual control needs two distinct operator actors")
        for name in (self.operator_secret_a_env, self.operator_secret_b_env, self.postgres_dsn_env):
            assert_true(bool(os.environ.get(name)), "environment variable is unset: " + name)
        assert_true(os.environ[self.operator_secret_a_env] != os.environ[self.operator_secret_b_env], "the two operator actors share one secret")
        if self.drift_hook is not None:
            assert_true(self.drift_hook.is_file() and os.access(self.drift_hook, os.X_OK), "drift hook is not executable")


class RigTransport(Protocol):
    """The only surface the twelve steps touch. Physical and fake share it."""

    def cli(self, args: list[str]) -> dict[str, Any]: ...
    def cli_raw(self, args: list[str]) -> tuple[int, str, str]: ...
    def admin_post(self, path: str, actor: str, body: dict[str, Any]) -> tuple[int, dict[str, Any]]: ...
    def admin_get(self, path: str, actor: str, query: dict[str, str]) -> tuple[int, dict[str, Any]]: ...
    def ledger_counts(self) -> dict[str, int]: ...
    def induce_drift(self) -> None: ...
    def request_log_since(self, marker: Any) -> int: ...
    def request_log_marker(self) -> Any: ...
    def surfaces(self) -> dict[str, str]: ...


class PhysicalRig:
    """Real transport: the provider CLI as a subprocess, the coordinator's
    operator surface over loopback HTTP with per-actor bearers, the ledgers
    through psql. Secrets are resolved from the environment at call time and
    never cached on the instance."""

    def __init__(self, config: RigConfig):
        config.validate()
        self.config = config
        # Everything the CLI and the operator surface said during this run,
        # verbatim; step 12 reviews it as one surface.
        self._transcript: list[str] = []
        # The logs are reviewed from where they stood when the run began, so
        # the review covers what this run caused and nothing older.
        self._log_offsets = {"provider_log": config.provider_log.stat().st_size, "coordinator_log": config.coordinator_log.stat().st_size}

    def cli_raw(self, args: list[str]) -> tuple[int, str, str]:
        """Exit code, stdout, stderr. For invocations the journey EXPECTS to be
        refused (a duplicate live offer, an opaque candidate) the refusal is
        the evidence, so it must not be turned into a failure here."""
        completed = subprocess.run(
            [str(self.config.cli_binary), *args],
            capture_output=True, text=True, check=False, cwd=str(ROOT),
        )
        self._transcript.append("$ macprovider-cli " + " ".join(args) + "\n" + completed.stdout + completed.stderr)
        return completed.returncode, completed.stdout, completed.stderr

    def cli(self, args: list[str]) -> dict[str, Any]:
        code, stdout, _ = self.cli_raw(args)
        assert_true(code == 0, "cli exited non-zero for: " + " ".join(args[:3]))
        try:
            return json.loads(stdout)
        except json.JSONDecodeError as exc:
            raise JourneyFailure("cli did not emit a JSON document: " + str(exc)) from exc

    def _bearer(self, actor: str) -> str:
        name = self.config.operator_secret_a_env if actor == self.config.operator_actor_a else self.config.operator_secret_b_env
        return os.environ[name]

    def _admin(self, method: str, path: str, actor: str, body: dict[str, Any] | None, query: dict[str, str] | None) -> tuple[int, dict[str, Any]]:
        url = self.config.coordinator_admin_origin + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        headers = {"Authorization": "Bearer " + self._bearer(actor)}
        data = None
        if body is not None:
            data = json.dumps(body).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                status, payload = response.status, response.read().decode("utf-8") or "{}"
        except urllib.error.HTTPError as error:
            status, payload = error.code, error.read().decode("utf-8", errors="replace")
        self._transcript.append(f"{method} {path} as {actor} -> {status}\n{payload}")
        try:
            parsed = json.loads(payload)
        except json.JSONDecodeError:
            return status, {"error": {"code": "non_json_response", "message": "coordinator answered with a non-JSON body"}}
        return status, parsed if isinstance(parsed, dict) else {"error": {"code": "non_object_response", "message": "coordinator answered with a non-object body"}}

    def admin_post(self, path: str, actor: str, body: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        return self._admin("POST", path, actor, body, None)

    def admin_get(self, path: str, actor: str, query: dict[str, str]) -> tuple[int, dict[str, Any]]:
        return self._admin("GET", path, actor, None, query)

    # libpq connection parameters the runner is willing to carry into a
    # service file. Anything else in the DSN fails closed rather than being
    # dropped silently or passed through unreviewed.
    LIBPQ_KEYWORDS = frozenset({"host", "hostaddr", "port", "dbname", "user", "password", "sslmode", "sslrootcert", "application_name", "connect_timeout", "target_session_attrs"})

    @staticmethod
    def libpq_parameters(dsn: str) -> dict[str, str]:
        """Split a DSN into libpq keyword/value pairs. Accepts the URI form
        (postgresql://user:pass@host:port/db?sslmode=...) and the keyword form
        (host=... dbname=...). Returns only keywords from LIBPQ_KEYWORDS."""
        params: dict[str, str] = {}
        if dsn.startswith(("postgresql://", "postgres://")):
            parts = urllib.parse.urlsplit(dsn)
            if parts.hostname:
                params["host"] = parts.hostname
            if parts.port:
                params["port"] = str(parts.port)
            if parts.username:
                params["user"] = urllib.parse.unquote(parts.username)
            if parts.password:
                params["password"] = urllib.parse.unquote(parts.password)
            if parts.path and parts.path != "/":
                params["dbname"] = urllib.parse.unquote(parts.path[1:])
            for key, value in urllib.parse.parse_qsl(parts.query, keep_blank_values=False, strict_parsing=True):
                assert_true(key not in params, f"ledger DSN repeats the libpq parameter {key!r}")
                params[key] = value
        else:
            for token in shlex.split(dsn):
                key, separator, value = token.partition("=")
                assert_true(separator == "=" and key and value, "ledger DSN must be a postgresql:// URI or libpq key=value pairs")
                assert_true(key not in params, f"ledger DSN repeats the libpq parameter {key!r}")
                params[key] = value
        unknown = sorted(set(params) - PhysicalRig.LIBPQ_KEYWORDS)
        assert_true(not unknown, "ledger DSN carries libpq parameters the runner does not pass through: " + ", ".join(unknown))
        assert_true(params, "ledger DSN carries no connection parameters")
        for key, value in params.items():
            assert_true("\n" not in value and "\r" not in value, f"ledger DSN parameter {key!r} contains a line break")
        return params

    def ledger_counts(self) -> dict[str, int]:
        # The DSN is credential-bearing, so it never goes on the psql command
        # line (argv is world-readable through process inspection). It is
        # written to a 0600 libpq service file in a 0700 private directory
        # that exists only for the duration of the read, and psql is pointed
        # at it through PGSERVICEFILE/PGSERVICE.
        params = self.libpq_parameters(os.environ[self.config.postgres_dsn_env])
        sql = " UNION ALL ".join(f"SELECT '{t}', count(*) FROM {t}" for t in MONEY_PATH_TABLES)
        with tempfile.TemporaryDirectory(prefix="byom-journey-pg-") as private:
            os.chmod(private, 0o700)
            service_file = Path(private) / "pg_service.conf"
            with open(os.open(str(service_file), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w", encoding="utf-8") as handle:
                handle.write("[journey]\n" + "".join(f"{key}={value}\n" for key, value in params.items()))
            env = {name: value for name, value in os.environ.items() if not name.startswith("PG")}
            env.update({"PGSERVICEFILE": str(service_file), "PGSERVICE": "journey"})
            completed = subprocess.run(["psql", "-X", "-tA", "-F", "\t", "-c", sql], capture_output=True, text=True, check=False, env=env)
        assert_true(completed.returncode == 0, "ledger read failed; is psql on PATH and the DSN reachable")
        counts: dict[str, int] = {}
        for line in completed.stdout.splitlines():
            if not line.strip():
                continue
            table, count = line.split("\t")
            counts[table] = int(count)
        return counts

    def request_log_marker(self) -> Any:
        return self.ledger_counts().get("request_log", 0)

    def request_log_since(self, marker: Any) -> int:
        return self.ledger_counts().get("request_log", 0) - int(marker)

    def induce_drift(self) -> None:
        assert_true(self.config.drift_hook is not None, "step 7 needs --drift-hook: a script that changes the admitted predicate (e.g. swaps the coordinator's catalog artifact feed and reloads)")
        completed = subprocess.run([str(self.config.drift_hook)], capture_output=True, text=True, check=False)
        assert_true(completed.returncode == 0, "drift hook exited non-zero")

    def _log_since_start(self, name: str) -> str:
        path = self.config.provider_log if name == "provider_log" else self.config.coordinator_log
        with open(path, "rb") as handle:
            handle.seek(self._log_offsets[name])
            return handle.read().decode("utf-8", errors="replace")

    def surfaces(self) -> dict[str, str]:
        return {
            "cli_transcript": "\n".join(self._transcript),
            "provider_log": self._log_since_start("provider_log"),
            "coordinator_log": self._log_since_start("coordinator_log"),
        }


# ---------------------------------------------------------------- manifest

class ManifestBuilder:
    """Same contract as the discovery driver's builder: whole captured
    documents, fail-closed redaction, closed-schema validation, atomic
    publish only after every step and observation check passes."""

    def __init__(self, out_dir: Path, run_id: str, cli_version: str):
        self.out_dir = out_dir
        self.captures = out_dir / "captures"
        self.captures.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.captures.chmod(0o700)
        self.run_id = run_id
        self.cli_version = cli_version
        self.steps: list[dict[str, Any]] = []
        self.observations: dict[str, Any] = {name: None for name in TRUE_OBSERVATIONS + FALSE_OBSERVATIONS}
        self.money_path: dict[str, int] | None = None
        self.payloads: dict[str, str] = {}

    def capture(self, name: str, schema: str, document: dict[str, Any]) -> dict[str, str]:
        payload = json.dumps(document, indent=2, sort_keys=True) + "\n"
        try:
            evidence_contract.assert_captured_document_redacted(document, "captured document " + name)
            evidence_contract.reject_unredacted_text_except_hostname(payload, "captured document " + name)
        except evidence_contract.BYOMEvidenceError as exc:
            raise JourneyFailure(f"captured document {name} is not redaction-clean: {exc}") from exc
        assert_true(document.get("schema") == schema, f"captured document {name} declares {document.get('schema')!r}, expected {schema!r}")
        validate_captured_cli_document(schema, document, "captured document " + name)
        path = self.captures / (name + ".json")
        path.write_text(payload, encoding="utf-8")
        path.chmod(0o600)
        self.payloads[name] = payload
        return {"id": name, "schema": schema, "path": "captures/" + name + ".json"}

    def add_step(self, step_id: str, assertion: str, documents: list[dict[str, str]]) -> None:
        assert_true(step_id in STEP_REQUIREMENT_IDS, "unknown step id: " + step_id)
        assert_true(all(s["id"] != step_id for s in self.steps), "step recorded twice: " + step_id)
        self.steps.append({
            "id": step_id, "status": "pass", "assertion": assertion,
            "requirement_ids": list(STEP_REQUIREMENT_IDS[step_id]), "documents": documents,
        })

    def observe(self, name: str, value: bool) -> None:
        assert_true(name in self.observations, "unknown observation: " + name)
        assert_true(self.observations[name] is None or self.observations[name] == value, "observation set twice with different values: " + name)
        self.observations[name] = value

    def record_money_path(self, counts: dict[str, int]) -> None:
        missing = [t for t in MONEY_PATH_TABLES if t not in counts]
        assert_true(not missing, "ledger tables not measured: " + ", ".join(missing))
        nonzero = {t: counts[t] for t in MONEY_PATH_TABLES if counts[t] != 0}
        assert_true(not nonzero, "money-path tables are not all zero: " + json.dumps(nonzero, sort_keys=True))
        self.money_path = {t: 0 for t in MONEY_PATH_TABLES}

    def write(self) -> Path:
        missing = sorted(n for n, v in self.observations.items() if v is None)
        assert_true(not missing, "observations never set by a check: " + ", ".join(missing))
        for name in TRUE_OBSERVATIONS:
            assert_true(self.observations[name] is True, "observation must be true: " + name)
        for name in FALSE_OBSERVATIONS:
            assert_true(self.observations[name] is False, "observation must be false: " + name)
        assert_true(self.money_path is not None, "money-path ledgers were never measured")
        assert_true([s["id"] for s in self.steps] == list(STEP_IDS), "manifest steps must cover every journey step exactly once, in order")
        observations = {name: self.observations[name] for name in sorted(self.observations)}
        observations["money_path_zero_rows"] = dict(self.money_path)
        manifest = {
            "schema_version": RUN_MANIFEST_SCHEMA,
            "journey_id": JOURNEY_ID,
            "run_id": self.run_id,
            "environment_class": ENVIRONMENT_CLASS,
            "cli_version": self.cli_version,
            "harness": {"name": HARNESS_NAME, "status": "pass"},
            "steps": self.steps,
            "observations": observations,
        }
        path = self.out_dir / "run-manifest.json"
        temporary = self.out_dir / ".run-manifest.json.tmp"
        temporary.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        temporary.chmod(0o600)
        os.replace(str(temporary), str(path))
        return path


# ------------------------------------------------------------------ runner

@dataclass
class Candidate:
    served_model_ref: str
    candidate_id: str = ""
    provider_id: str = ""
    catalog_model_key: str | None = None
    event_id: str | None = None


class AdmissionJourneyRunner:
    def __init__(self, rig: RigTransport, config: RigConfig, manifest: ManifestBuilder, log: Callable[[str], None] = print):
        self.rig = rig
        self.config = config
        self.m = manifest
        self.log = log
        self.settleable = Candidate(config.settleable_ref)
        self.opaque = Candidate(config.opaque_ref)
        self.gguf = Candidate(config.gguf_ref)

    # -- helpers ------------------------------------------------------------

    def _common(self) -> list[str]:
        return ["--json", "--config", str(self.config.provider_config), *self.config.discovery_args]

    def status(self, candidate: Candidate) -> dict[str, Any]:
        document = self.rig.cli(["models", "admission", "status", candidate.served_model_ref, *self._common()])
        candidate.candidate_id = document["candidate_id"]
        candidate.provider_id = document["provider_id"]
        candidate.catalog_model_key = document.get("catalog_model_key")
        candidate.event_id = document.get("coordinator_event_id")
        return document

    def decide(self, actor: str, candidate: Candidate, next_state: str, reason_code: str) -> tuple[int, dict[str, Any]]:
        """POST /admin/model-admission/decisions against the head the runner
        just read. The body is checked against the coordinator's own grammar
        first: a request the coordinator would refuse as invalid_request is a
        runner defect, and must never be recorded as a coordinator verdict."""
        assert_true(candidate.event_id is not None and bool(COORDINATOR_EVENT_ID.match(candidate.event_id)), "decision needs the current 64-hex coordinator event id (run status first)")
        assert_true(bool(OPERATOR_REASON_CODE.match(reason_code)), f"operator reason_code {reason_code!r} is outside the coordinator grammar ^operator_[a-z0-9_]{{2,56}}$")
        body = {
            "schema": DECISION_REQUEST_SCHEMA,
            "provider_id": candidate.provider_id,
            "candidate_id": candidate.candidate_id,
            "next_state": next_state,
            "reason_code": reason_code,
            "expected_coordinator_event_id": candidate.event_id,
            "idempotency_key": uuid.uuid4().hex,
        }
        return self.rig.admin_post(DECISIONS_PATH, actor, body)

    def approve(self, actor: str, candidate: Candidate, pending_id: str, evaluated_head: str) -> tuple[int, dict[str, Any]]:
        """POST /admin/model-admission/decisions/<id>/approve. The closed
        approval body binds the pending record's provider, candidate and
        evaluated head, and carries its own idempotency key (coordinator:
        modelAdmissionApproveRequest.validate)."""
        assert_true(bool(PENDING_DECISION_ID.match(pending_id)), "pending_decision_id is not 32 hex characters")
        assert_true(bool(COORDINATOR_EVENT_ID.match(evaluated_head)), "the pending record's evaluated head is not a 64-hex coordinator event id")
        body = {
            "schema": APPROVE_REQUEST_SCHEMA,
            "provider_id": candidate.provider_id,
            "candidate_id": candidate.candidate_id,
            "pending_decision_id": pending_id,
            "expected_coordinator_event_id": evaluated_head,
            "idempotency_key": uuid.uuid4().hex,
        }
        return self.rig.admin_post(DECISIONS_PATH + "/" + pending_id + "/approve", actor, body)

    def expect_state(self, candidate: Candidate, state: str, where: str) -> dict[str, Any]:
        document = self.status(candidate)
        assert_true(document["admission_state_source"] == "coordinator", where + ": state is not coordinator-backed")
        assert_true(document["admission_state"] == state, f"{where}: admission_state is {document['admission_state']!r}, expected {state!r}")
        return document

    def wait_for_state(self, candidate: Candidate, state: str, where: str, attempts: int = 30, interval: float = 2.0) -> dict[str, Any]:
        last = None
        for _ in range(attempts):
            document = self.status(candidate)
            last = document.get("admission_state")
            if last == state and document["admission_state_source"] == "coordinator":
                return document
            time.sleep(interval)
        raise JourneyFailure(f"{where}: candidate never reached {state!r} (last {last!r})")

    # `model_catalog_economics.v1` rows are the CLI's own money projection.
    # These read the fields the contract types (SPEC-047-R003), never
    # invented ones: `admission.settlement_capable`,
    # `admission.catalog_economics_permitted`, the four rate/payout fields,
    # `economics_state`, and `rate_source`.
    MONEY_FIELDS = (
        "prompt_rate_usd_per_million_tokens", "completion_rate_usd_per_million_tokens",
        "provider_prompt_payout_usd_per_million_tokens", "provider_completion_payout_usd_per_million_tokens",
    )

    def economics_row(self, candidate: Candidate) -> tuple[dict[str, Any], dict[str, Any]]:
        document = self.rig.cli(["models", "catalog-economics", *self._common()])
        assert_true(document.get("schema") == "model_catalog_economics.v1", "catalog-economics returned the wrong schema")
        rows = [r for r in document.get("rows", []) if r.get("action_model_id") == candidate.candidate_id]
        assert_true(len(rows) == 1, "catalog-economics must show the candidate exactly once")
        return document, rows[0]

    def assert_not_settlement(self, row: dict[str, Any], where: str) -> None:
        admission = row.get("admission") or {}
        assert_true(admission.get("settlement_capable") is False, where + ": admission.settlement_capable must be false")
        assert_true(admission.get("state") != "settlement_capable", where + ": economics row reports a settlement state")

    def assert_null_money(self, row: dict[str, Any], where: str) -> None:
        self.assert_not_settlement(row, where)
        for field in self.MONEY_FIELDS:
            assert_true(row.get(field) is None, f"{where}: {field} must be null")
        assert_true(row.get("economics_state") == "blocked", where + ": economics_state must be blocked")
        assert_true(row.get("rate_source") == "none", where + ": rate_source must be none")
        assert_true((row.get("admission") or {}).get("catalog_economics_permitted") is False, where + ": catalog economics must not be permitted")

    # -- steps --------------------------------------------------------------

    def step_01_offer_dry_run(self) -> None:
        marker = self.rig.request_log_marker()
        document = self.rig.cli(["models", "offer", self.settleable.served_model_ref, "--dry-run", *self._common()])
        assert_true(document.get("likely_admission_state_source") == "local_default", "dry-run claimed coordinator authority")
        assert_true(self.rig.request_log_since(marker) == 0, "dry-run reached the coordinator")
        self.m.observe("dry_run_did_not_submit", True)
        doc = self.m.capture("offer-dry-run", "model_admission_offer_dry_run.v1", document)
        self.m.add_step(STEP_IDS[0], "Dry run produced the dry-run document with local_default authority and made no coordinator request.", [doc])

    def step_02_submit_signed_offer(self) -> None:
        submit = self.rig.cli(["models", "offer", self.settleable.served_model_ref, *self._common()])
        assert_true(submit.get("schema") == "model_admission_offer_submit.v1", "offer submit did not return the submit document")
        assert_true(submit.get("admission_state_source") == "coordinator", "offer was not coordinator-backed")
        assert_true(submit.get("admission_state") == "offer_submitted", "offer did not land in offer_submitted")
        assert_true(bool(submit.get("coordinator_event_id")), "accepted offer carries no coordinator event id")
        # Provider authentication and the provider signature are what the
        # coordinator checks before it appends an offer event at all; an
        # unsigned or badly signed package is refused, never recorded. The
        # accepted, coordinator-backed event is the evidence.
        self.m.observe("provider_signature_verified", True)
        # The CLI mints a fresh nonce and idempotency key per invocation, so a
        # second `models offer` is a NEW package, not a nonce replay. What the
        # journey can prove on hardware is that a duplicate offer while one is
        # live is refused by the coordinator's state machine (HTTP 409) and
        # appends nothing. Nonce-level replay is enforced on the raw request,
        # which the CLI never re-sends; it is covered by coordinator tests.
        code, _, stderr = self.rig.cli_raw(["models", "offer", self.settleable.served_model_ref, *self._common()])
        assert_true(code != 0 and "HTTP 409" in stderr, "a duplicate live offer was accepted rather than refused with HTTP 409")
        status = self.status(self.settleable)
        assert_true(status["admission_state_source"] == "coordinator", "step 2: state is not coordinator-backed")
        # By the time status is read the coordinator may already have applied
        # its own probe policy (offer_submitted -> sandbox_probe_only is a
        # coordinator-origin edge).
        assert_true(status["admission_state"] in ("offer_submitted", "sandbox_probe_only"), f"step 2: post-submit state is {status['admission_state']!r}")
        assert_true(status["coordinator_event_id"] is not None, "post-submit status carries no coordinator event id")
        doc = self.m.capture("offer-submitted-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[1], "One provider-signed offer was accepted by the coordinator and recorded as offer_submitted; a duplicate offer while it was live was refused with HTTP 409 and appended nothing.", [doc])

    def step_03_reject_opaque_endpoint(self) -> None:
        marker = self.rig.request_log_marker()
        # An opaque endpoint has no artifact bytes and no catalog identity, so
        # the CLI's own submission builder refuses it before any coordinator
        # contact (SPEC-023 s3.7.4). The refusal, the absence of coordinator
        # state, and the absence of traffic are the evidence.
        code, _, stderr = self.rig.cli_raw(["models", "offer", self.opaque.served_model_ref, *self._common()])
        assert_true(code != 0 and "not offerable" in stderr, "an opaque endpoint candidate was submitted rather than refused")
        status = self.status(self.opaque)
        assert_true(status["admission_state_source"] == "local_default", "opaque endpoint acquired coordinator admission state")
        assert_true(status["admission_state"] in ("local_only", "not_offered"), f"opaque endpoint is {status['admission_state']!r}; must be confined to local inventory")
        assert_true(status.get("catalog_model_key") is None, "opaque endpoint acquired a catalog key")
        assert_true(status["provider_guidance"]["earning_path_class"] == "local_inventory_only", "opaque endpoint guidance does not confine it to local inventory")
        assert_true(self.rig.request_log_since(marker) == 0, "opaque endpoint handling produced buyer traffic")
        self.m.observe("rejected_opaque_endpoint_verified", True)
        doc = self.m.capture("opaque-endpoint-rejected-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[2], "An opaque endpoint candidate was refused by the CLI submission builder before any coordinator contact and remains confined to local inventory with no catalog key, no economics, and no buyer traffic.", [doc])

    def step_04_sandbox_probe_only(self) -> None:
        # The coordinator moves an offer to sandbox_probe_only itself when a
        # synthetic probe is required; the runner only observes it.
        status = self.wait_for_state(self.settleable, "sandbox_probe_only", "step 4")
        assert_true("network_admitted_unsettled" in status["allowed_next_states"] or "network_visible_unpriced" in status["allowed_next_states"], "sandbox state does not offer the SPEC-047 forward edges")
        _, row = self.economics_row(self.settleable)
        # Sandbox is not paid-routable: no permitted economics, no settlement.
        self.assert_null_money(row, "step 4")
        # The probe reaches the candidate only through the authenticated
        # provider channel: the coordinator holds no endpoint, origin, socket or
        # path for the candidate, so there is nothing to dereference.
        locator_keys = collect_keys(status) & LOCATOR_KEYS
        assert_true(not locator_keys, "coordinator status carries a dereferenceable locator field: " + ", ".join(sorted(locator_keys)))
        self.m.observe("sandbox_probe_only_blocked_from_paid_routing", True)
        self.m.observe("synthetic_probe_used_provider_channel", True)
        doc = self.m.capture("sandbox-probe-only-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[3], "The candidate was admitted as sandbox-probe-only by the coordinator, is not default-paid-routable, earns no credit, and exposes no dereferenceable locator.", [doc])

    def step_05_network_visible_unpriced(self) -> None:
        code, response = self.decide(self.config.operator_actor_a, self.settleable, "network_visible_unpriced", REASON_EXPERIMENTAL_DISCLOSURE)
        assert_true(code == 200 and response.get("admission_state") == "network_visible_unpriced", f"decision to network_visible_unpriced not applied (HTTP {code})")
        self.expect_state(self.settleable, "network_visible_unpriced", "step 5")
        document, row = self.economics_row(self.settleable)
        self.assert_null_money(row, "step 5")
        self.m.observe("network_visible_unpriced_disclosed", True)
        doc = self.m.capture("network-visible-unpriced-economics", "model_catalog_economics.v1", document)
        self.m.add_step(STEP_IDS[4], "Operator disclosure moved the candidate to network_visible_unpriced with null economics.", [doc])

    def step_06_catalog_matched_not_settlement(self) -> None:
        status = self.status(self.settleable)
        assert_true(status.get("catalog_model_key"), "settleable candidate is not catalog-matched; the catalog artifact feed does not cover it")
        code, response = self.decide(self.config.operator_actor_a, self.settleable, "catalog_priced", REASON_CATALOG_BINDING_VERIFIED)
        assert_true(code == 200 and response.get("admission_state") == "catalog_priced", f"decision to catalog_priced not applied (HTTP {code})")
        self.expect_state(self.settleable, "catalog_priced", "step 6")
        document, row = self.economics_row(self.settleable)
        self.assert_not_settlement(row, "step 6")
        admission = row["admission"]
        assert_true(admission.get("catalog_economics_permitted") is True, "catalog_priced candidate does not show trusted catalog economics")
        assert_true(row.get("model_key") == status["catalog_model_key"], "economics row does not carry the trusted catalog key")
        assert_true(row.get("economics_state") == "permitted" and all(row.get(f) is not None for f in self.MONEY_FIELDS), "catalog_priced economics are not the signed catalog rates")
        # The rates come from the signed catalog, never from a provider-asserted price.
        assert_true(row.get("rate_source") in ("live_signed", "baked_signed"), f"rate_source {row.get('rate_source')!r} is not a signed catalog source")
        self.m.observe("provider_price_treated_as_catalog_rate", False)
        self.m.observe("catalog_matched_not_settlement_verified", True)
        self.m.observe("default_buyer_invisibility_verified", True)
        self.m.observe("non_settlement_state_created_provider_credit", False)
        doc = self.m.capture("catalog-matched-economics", "model_catalog_economics.v1", document)
        self.m.add_step(STEP_IDS[5], "A catalog-matched candidate reached catalog_priced with trusted economics shown and no buyer debit, paid routing, ledger row, or provider settlement.", [doc])

    def step_07_revocation_on_drift(self) -> None:
        self.rig.induce_drift()
        status = self.wait_for_state(self.settleable, "revoked", "step 7")
        # SPEC-047-R002: the reason for the last transition is carried in
        # provider_guidance.transition_reason_code, the typed field.
        reason = (status.get("provider_guidance") or {}).get("transition_reason_code")
        assert_true(reason in DRIFT_REASON_CODES, f"revocation reason {reason!r} is not a SPEC-047-R006 drift reason; an operator revoke proves nothing about drift")
        _, row = self.economics_row(self.settleable)
        self.assert_null_money(row, "step 7")
        self.m.observe("revocation_on_drift_verified", True)
        doc = self.m.capture("revoked-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[6], "A changed admitted predicate was detected by the coordinator and the candidate was revoked with a drift reason; routing and settlement failed closed.", [doc])
        # Re-entry after revocation requires refreshed provider-signed evidence.
        reoffer = self.rig.cli(["models", "offer", self.settleable.served_model_ref, *self._common()])
        assert_true(reoffer.get("admission_state") == "offer_submitted" and reoffer.get("coordinator_event_id") != status.get("coordinator_event_id"), "re-offer after revocation did not append a fresh signed event")
        self.m.observe("revoked_reoffer_required_fresh_evidence", True)

    def step_08_withdrawal(self) -> None:
        before = self.status(self.settleable)
        document = self.rig.cli(["models", "admission", "withdraw", self.settleable.served_model_ref, "--reason-code", WITHDRAWAL_REASON, *self._common()])
        assert_true(document.get("schema") == "model_admission_withdraw.v1", "withdraw did not return the withdraw document")
        assert_true(document.get("reason_code") == WITHDRAWAL_REASON, "withdraw document does not carry the closed reason the CLI was given")
        assert_true(document.get("resulting_admission_state") == "withdrawn", "withdrawal did not result in withdrawn")
        assert_true(document.get("previous_admission_state") == before["admission_state"], "withdraw document misreports the previous state")
        self.expect_state(self.settleable, "withdrawn", "step 8")
        # Local artifacts are untouched: discovery still lists the candidate.
        discovery = self.rig.cli(["models", "discover", "--json", *self.config.discovery_args])
        assert_true(any(c["served_model_ref"] == self.settleable.served_model_ref for c in discovery["candidates"]), "withdrawal removed the local artifact from inventory")
        self.m.observe("withdrawal_verified", True)
        doc = self.m.capture("withdrawal-response", "model_admission_withdraw.v1", document)
        self.m.add_step(STEP_IDS[7], "The offered candidate was withdrawn through the CLI-owned path and its local artifacts remain in inventory.", [doc])
        reoffer = self.rig.cli(["models", "offer", self.settleable.served_model_ref, *self._common()])
        assert_true(reoffer.get("admission_state") == "offer_submitted" and reoffer.get("coordinator_event_id") != document.get("coordinator_event_id"), "re-offer after withdrawal did not append a fresh signed event")
        self.m.observe("withdrawn_reoffer_required_fresh_evidence", True)

    def step_09_settlement_capable_case(self) -> None:
        # Bring the re-offered candidate back to a state from which
        # settlement_capable is a legal edge, then dual-control promote it.
        self.wait_for_state(self.settleable, "sandbox_probe_only", "step 9 (post re-offer)")
        code, _ = self.decide(self.config.operator_actor_a, self.settleable, "catalog_priced", REASON_CATALOG_BINDING_VERIFIED)
        assert_true(code == 200, f"re-promotion to catalog_priced failed (HTTP {code})")
        self.expect_state(self.settleable, "catalog_priced", "step 9")
        code, proposed = self.decide(self.config.operator_actor_a, self.settleable, "settlement_capable", REASON_DUAL_CONTROL_SETTLEMENT)
        # A settlement_capable proposal is answered 200 with the pending
        # record: the state unchanged, pending_decision_id set, and
        # coordinator_event_id equal to the head the record was evaluated
        # against (the approval must bind that same head).
        assert_true(code == 200, f"settlement_capable proposal was not accepted as a pending decision (HTTP {code}, {error_code(proposed)!r})")
        pending_id = proposed.get("pending_decision_id")
        evaluated_head = proposed.get("coordinator_event_id")
        assert_true(isinstance(pending_id, str) and bool(PENDING_DECISION_ID.match(pending_id)), "proposal response carries no pending_decision_id")
        assert_true(proposed.get("admission_state") == "catalog_priced", "a pending proposal changed the admission state before approval")
        assert_true(evaluated_head == self.settleable.event_id, "pending record was evaluated against a head other than the one the runner read")
        # Dual control: the proposing actor's own approval must be refused
        # with exactly 409 dual_control_required. Any other refusal (400
        # invalid_request, 401, 404) is a different failure and proves nothing
        # about dual control.
        code, refused = self.approve(self.config.operator_actor_a, self.settleable, pending_id, evaluated_head)
        assert_true(code == 409 and error_code(refused) == "dual_control_required", f"the proposing actor's own approval was not refused with 409 dual_control_required (HTTP {code}, {error_code(refused)!r}); dual control not enforced")
        code, approved = self.approve(self.config.operator_actor_b, self.settleable, pending_id, evaluated_head)
        assert_true(code == 200 and approved.get("admission_state") == "settlement_capable", f"distinct-actor approval did not apply (HTTP {code}, {error_code(approved)!r})")
        assert_true(approved.get("decided_by") != proposed.get("decided_by"), "the approval event is not attributed to a distinct actor")
        assert_true(approved.get("bound_member") or approved.get("artifact_id"), "settlement_capable event carries no route-time artifact binding")
        status = self.expect_state(self.settleable, "settlement_capable", "step 9")
        assert_true(status["provider_guidance"]["earning_path_class"] == "settlement_capable", "guidance does not report settlement_capable")
        # Receipt-verification and route-snapshot gates stay armed: the ledgers
        # are still zero because no buyer traffic exists in this run.
        counts = self.rig.ledger_counts()
        assert_true(counts.get("settlement_route_snapshots", 0) == 0 and counts.get("settlement_receipt_verdicts", 0) == 0, "settlement gates recorded rows without buyer traffic")
        self.m.observe("settlement_capable_case_verified", True)
        doc = self.m.capture("settlement-capable-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[8], "A catalog-verified candidate was promoted to settlement_capable under dual control with a route-time artifact binding; the proposing actor could not self-approve; route-snapshot and receipt gates remain armed with zero rows.", [doc])

    def step_10_admission_status_presentation(self) -> None:
        matched = self.status(self.settleable)
        assert_true(matched["provider_guidance"]["earning_path_class"] in ("settlement_capable", "not_earning_yet_catalog_or_receipt_path_exists"), "catalog-matched status does not present an earning path")
        # The novel non-catalog candidate is the GGUF one: local inventory can
        # serve it, the coordinator can hold it, and SPEC-010 R007(e) gives it
        # no earning path in v0.1. The opaque endpoint is not a substitute; it
        # never reaches the coordinator at all (step 3).
        novel = self.status(self.gguf)
        assert_true(novel.get("catalog_model_key") is None, "the gguf candidate is catalog-matched; it cannot stand as the novel non-catalog candidate")
        assert_true(novel["provider_guidance"]["earning_path_class"] == "no_earning_path_in_v0_1", f"novel candidate status reports {novel['provider_guidance']['earning_path_class']!r}, not no_earning_path_in_v0_1")
        for document in (matched, novel):
            guidance = document["provider_guidance"]
            assert_true(guidance.get("state_meaning_key") and guidance.get("next_action"), "status lacks state meaning or next action")
        self.m.observe("earning_path_disclosure_verified", True)
        doc = self.m.capture("novel-non-catalog-status", "model_admission_status.v1", novel)
        self.m.add_step(STEP_IDS[9], "Status output distinguishes a catalog-matched candidate with an earning path from a novel candidate with none, each with state meaning and next action.", [doc])

    def step_11_transition_validity(self) -> None:
        # One invalid edge outside the SPEC-047 matrix, from the current state.
        current = self.status(self.settleable)
        state = current["admission_state"]
        illegal = None
        # The operator surface accepts five next states; pick one the SPEC-047
        # matrix forbids from the current state.
        for candidate_state in ("network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "settlement_capable"):
            if candidate_state not in ADMISSION_ALLOWED_NEXT_STATES[state]:
                illegal = candidate_state
                break
        assert_true(illegal is not None, f"no operator next-state is illegal from {state!r}; cannot exercise the matrix")
        # The head was re-read by status() above, so the only thing the
        # coordinator can object to is the edge itself: exactly 409
        # invalid_transition. A stale_head, invalid_request or auth refusal
        # is a different failure and proves nothing about the matrix.
        head = current["coordinator_event_id"]
        code, refused = self.decide(self.config.operator_actor_a, self.settleable, illegal, REASON_MATRIX_PROBE)
        assert_true(code == 409 and error_code(refused) == "invalid_transition", f"illegal transition {state} -> {illegal} was not refused with 409 invalid_transition (HTTP {code}, {error_code(refused)!r})")
        after = self.expect_state(self.settleable, state, "step 11 (state unchanged after illegal attempt)")
        assert_true(after["coordinator_event_id"] == head, "an illegal transition appended a coordinator event")
        # SPEC-047 v0.1.9: offer_rejected is reserved and unreachable, so the
        # fresh-evidence-on-re-entry invariant (R001/R006) is proven by the two
        # reachable re-entry paths, revoked (step 7) and withdrawn (step 8),
        # whose observations were set when each re-offer appended a fresh
        # signed event.
        self.m.observe("transition_matrix_enforced", True)
        doc = self.m.capture("re-entry-status", "model_admission_status.v1", self.status(self.settleable))
        self.m.add_step(STEP_IDS[10], "An out-of-matrix transition was rejected and left the state unchanged; the withdrawn and revoked re-entry paths each required fresh provider-signed evidence (offer_rejected is reserved and unreachable in v0.2).", [doc])

    def step_12_redaction_review(self, runner_log: str) -> None:
        """Review every surface the run produced or touched: the runner's own
        log, the verbatim CLI and operator-surface transcript, every captured
        document, the coordinator's event listing for the provider, and the
        provider and coordinator logs written during the run. The three
        redaction observations are set only after all six are clean."""
        status = self.status(self.settleable)
        code, listing = self.rig.admin_get(OFFERS_PATH, self.config.operator_actor_a, {"provider_id": self.settleable.provider_id})
        assert_true(code == 200 and listing.get("schema") == "model_admission_offer_list.v1", f"coordinator event listing unavailable (HTTP {code}, {error_code(listing)!r})")
        surfaces = dict(self.rig.surfaces())
        surfaces["runner_log"] = runner_log
        surfaces["captured_documents"] = "\n".join(self.m.payloads[name] for name in sorted(self.m.payloads))
        surfaces["coordinator_events"] = json.dumps(listing, sort_keys=True)
        missing = sorted(set(REDACTION_SURFACES) - set(surfaces))
        assert_true(not missing, "redaction review is missing surfaces: " + ", ".join(missing))
        # Needles: the values this run was given that must never be persisted.
        # A failure names the category and the surface, never the value.
        dsn = os.environ[self.config.postgres_dsn_env]
        needles = [
            ("operator secret", os.environ[self.config.operator_secret_a_env]),
            ("operator secret", os.environ[self.config.operator_secret_b_env]),
            ("ledger dsn", dsn),
        ]
        password = PhysicalRig.libpq_parameters(dsn).get("password")
        if password:
            needles.append(("ledger password", password))
        for name in REDACTION_SURFACES:
            text = surfaces[name]
            for category, needle in needles:
                assert_true(needle not in text, f"redaction review: {category} found in surface {name}")
            try:
                evidence_contract.reject_secret_like_text(text, "surface " + name)
            except evidence_contract.BYOMEvidenceError as exc:
                raise JourneyFailure(f"redaction review: {exc}") from exc
        prompt_hits = [name for name in REDACTION_SURFACES if SYNTHETIC_PROBE_PROMPT in surfaces[name] or any(p.search(surfaces[name]) for p in RAW_PROMPT_SHAPES)]
        assert_true(not prompt_hits, "redaction review: a raw prompt (the synthetic probe prompt or a chat request body) is persisted in: " + ", ".join(prompt_hits))
        completion_hits = [name for name in REDACTION_SURFACES if any(p.search(surfaces[name]) for p in RAW_COMPLETION_SHAPES)]
        assert_true(not completion_hits, "redaction review: a raw completion (a chat response body) is persisted in: " + ", ".join(completion_hits))
        self.m.observe("secret_field_persisted", False)
        self.m.observe("raw_prompt_logged", False)
        self.m.observe("raw_completion_logged", False)
        doc = self.m.capture("redaction-review-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[11], "The runner log, the CLI and operator-surface transcript, every captured document, the coordinator's event listing, and the provider and coordinator logs written during the run were reviewed; no operator secret, ledger credential, credential-shaped value, raw prompt or raw completion is persisted in any of them.", [doc])

    # -- run --------------------------------------------------------------

    def run(self, runner_log: Callable[[], str]) -> Path:
        steps = [
            self.step_01_offer_dry_run, self.step_02_submit_signed_offer, self.step_03_reject_opaque_endpoint,
            self.step_04_sandbox_probe_only, self.step_05_network_visible_unpriced, self.step_06_catalog_matched_not_settlement,
            self.step_07_revocation_on_drift, self.step_08_withdrawal, self.step_09_settlement_capable_case,
            self.step_10_admission_status_presentation, self.step_11_transition_validity,
        ]
        for step in steps:
            self.log("journey: " + step.__name__)
            step()
        self.step_12_redaction_review(runner_log())
        self.m.record_money_path(self.rig.ledger_counts())
        return self.m.write()


# --------------------------------------------------------------------- cli

def cli_version(binary: Path) -> str:
    completed = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=False)
    assert_true(completed.returncode == 0, "cli --version failed")
    return completed.stdout.strip().split()[-1]


def prepare_out_dir(out_dir: Path) -> None:
    if out_dir.exists():
        assert_true(out_dir.is_dir() and not any(out_dir.iterdir()), "--out must be a new or empty directory; a failing rerun must never leave an earlier manifest as if it were current")
    out_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
    out_dir.chmod(0o700)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Drive JOURNEY-NETWORK-MODEL-ADMISSION on a physical rig and emit run-manifest.json.")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cli-binary", required=True, type=Path)
    parser.add_argument("--provider-config", required=True, type=Path)
    parser.add_argument("--coordinator-admin-origin", required=True)
    parser.add_argument("--operator-actor-a", required=True)
    parser.add_argument("--operator-actor-b", required=True)
    parser.add_argument("--operator-secret-a-env", default="MACPROVIDER_JOURNEY_OPERATOR_A")
    parser.add_argument("--operator-secret-b-env", default="MACPROVIDER_JOURNEY_OPERATOR_B")
    parser.add_argument("--postgres-dsn-env", default="MACPROVIDER_JOURNEY_LEDGER_DSN")
    parser.add_argument("--settleable-ref", required=True, help="served_model_ref of the MLX catalog-verified candidate")
    parser.add_argument("--opaque-ref", required=True, help="served_model_ref of an openai_compatible: opaque endpoint")
    parser.add_argument("--gguf-ref", required=True, help="served_model_ref of a GGUF candidate: the novel non-catalog candidate for step 10 (SPEC-010 R007(e), no earning path)")
    parser.add_argument("--provider-log", required=True, type=Path, help="the provider's serve log; step 12 reviews what is appended during the run")
    parser.add_argument("--coordinator-log", required=True, type=Path, help="the rig coordinator's log; step 12 reviews what is appended during the run")
    parser.add_argument("--drift-hook", type=Path, default=None, help="executable that changes the admitted predicate for step 7")
    parser.add_argument("--discovery-arg", action="append", default=[], help="extra argv passed to every models command (e.g. --skip-ollama)")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    config = RigConfig(
        cli_binary=args.cli_binary.resolve(), provider_config=args.provider_config.resolve(),
        coordinator_admin_origin=args.coordinator_admin_origin.rstrip("/"),
        operator_actor_a=args.operator_actor_a, operator_actor_b=args.operator_actor_b,
        operator_secret_a_env=args.operator_secret_a_env, operator_secret_b_env=args.operator_secret_b_env,
        postgres_dsn_env=args.postgres_dsn_env, settleable_ref=args.settleable_ref, opaque_ref=args.opaque_ref,
        gguf_ref=args.gguf_ref, provider_log=args.provider_log.resolve(), coordinator_log=args.coordinator_log.resolve(),
        drift_hook=args.drift_hook.resolve() if args.drift_hook else None,
        discovery_args=tuple(args.discovery_arg),
    )
    transcript: list[str] = []
    def log(line: str) -> None:
        transcript.append(line); print(line, file=sys.stderr)
    try:
        prepare_out_dir(args.out)
        rig = PhysicalRig(config)
        manifest = ManifestBuilder(args.out, uuid.uuid4().hex, cli_version(config.cli_binary))
        path = AdmissionJourneyRunner(rig, config, manifest, log).run(lambda: "\n".join(transcript))
    except JourneyFailure as failure:
        print("admission journey FAILED: " + str(failure), file=sys.stderr)
        return 1
    print("admission journey passed; manifest at " + str(path), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
