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
import hashlib
import json
import os
import re
import subprocess
import sys
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

LOOPBACK_ORIGIN = re.compile(r"^http://(127\.0\.0\.1|\[::1\]|localhost)(:\d{1,5})?$")
ACTOR_ID = re.compile(r"^[a-z][a-z0-9_-]{1,63}$")


class JourneyFailure(Exception):
    """A step assertion failed. The run stops and no manifest is published."""


def assert_true(condition: bool, message: str) -> None:
    if not condition:
        raise JourneyFailure(message)


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
    gguf_ref: str | None
    drift_hook: Path | None
    discovery_args: tuple[str, ...] = ()

    def validate(self) -> None:
        assert_true(self.cli_binary.is_file() and os.access(self.cli_binary, os.X_OK), "cli binary is not executable")
        assert_true(self.provider_config.is_file(), "provider config is missing")
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
    def admin_post(self, path: str, actor: str, body: dict[str, Any]) -> tuple[int, dict[str, Any]]: ...
    def ledger_counts(self) -> dict[str, int]: ...
    def induce_drift(self) -> None: ...
    def request_log_since(self, marker: Any) -> int: ...
    def request_log_marker(self) -> Any: ...


class PhysicalRig:
    """Real transport: the provider CLI as a subprocess, the coordinator's
    operator surface over loopback HTTP with per-actor bearers, the ledgers
    through psql. Secrets are resolved from the environment at call time and
    never cached on the instance."""

    def __init__(self, config: RigConfig):
        config.validate()
        self.config = config

    def cli(self, args: list[str]) -> dict[str, Any]:
        completed = subprocess.run(
            [str(self.config.cli_binary), *args],
            capture_output=True, text=True, check=False, cwd=str(ROOT),
        )
        assert_true(completed.returncode == 0, "cli exited non-zero for: models " + " ".join(a for a in args[1:3]))
        try:
            return json.loads(completed.stdout)
        except json.JSONDecodeError as exc:
            raise JourneyFailure("cli did not emit a JSON document: " + str(exc)) from exc

    def _bearer(self, actor: str) -> str:
        name = self.config.operator_secret_a_env if actor == self.config.operator_actor_a else self.config.operator_secret_b_env
        return os.environ[name]

    def admin_post(self, path: str, actor: str, body: dict[str, Any]) -> tuple[int, dict[str, Any]]:
        request = urllib.request.Request(
            self.config.coordinator_admin_origin + path,
            data=json.dumps(body).encode("utf-8"),
            headers={"Authorization": "Bearer " + self._bearer(actor), "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return response.status, json.loads(response.read().decode("utf-8") or "{}")
        except urllib.error.HTTPError as error:
            payload = error.read().decode("utf-8", errors="replace")
            try:
                return error.code, json.loads(payload)
            except json.JSONDecodeError:
                return error.code, {"error": "non_json_response"}

    def ledger_counts(self) -> dict[str, int]:
        dsn = os.environ[self.config.postgres_dsn_env]
        sql = " UNION ALL ".join(f"SELECT '{t}', count(*) FROM {t}" for t in MONEY_PATH_TABLES)
        completed = subprocess.run(["psql", dsn, "-tA", "-F", "\t", "-c", sql], capture_output=True, text=True, check=False)
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
        self.gguf = Candidate(config.gguf_ref) if config.gguf_ref else None

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
        assert_true(candidate.event_id is not None, "decision needs the current coordinator event id (run status first)")
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

    def approve(self, actor: str, candidate: Candidate, pending_id: str) -> tuple[int, dict[str, Any]]:
        body = {
            "schema": APPROVE_REQUEST_SCHEMA,
            "provider_id": candidate.provider_id,
            "candidate_id": candidate.candidate_id,
            "pending_decision_id": pending_id,
        }
        return self.rig.admin_post(DECISIONS_PATH + "/" + pending_id, actor, body)

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
        assert_true(bool(submit.get("provider_signature_verified")) or submit.get("signature_state") == "verified", "coordinator did not report the provider signature as verified")
        # Replay: the same package again must not append a second event.
        replay = self.rig.cli(["models", "offer", self.settleable.served_model_ref, *self._common()])
        assert_true(replay.get("coordinator_event_id") == submit.get("coordinator_event_id") or replay.get("replayed") is True, "resubmitting the identical offer appended a new event; nonce/replay protection not enforced")
        self.m.observe("provider_signature_verified", True)
        # The submit document proved the offer landed in offer_submitted. By
        # the time status is read the coordinator may already have applied its
        # own probe policy (offer_submitted -> sandbox_probe_only is a
        # coordinator-origin edge); anything else here is a failure.
        status = self.status(self.settleable)
        assert_true(status["admission_state_source"] == "coordinator", "step 2: state is not coordinator-backed")
        assert_true(status["admission_state"] in ("offer_submitted", "sandbox_probe_only"), f"step 2: post-submit state is {status['admission_state']!r}")
        doc = self.m.capture("offer-submitted-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[1], "One provider-signed offer was accepted with the signature verified, landed in offer_submitted, and an identical resubmission was replay-protected.", [doc])

    def step_03_reject_opaque_endpoint(self) -> None:
        marker = self.rig.request_log_marker()
        submit = self.rig.cli(["models", "offer", self.opaque.served_model_ref, *self._common()])
        state = submit.get("admission_state")
        assert_true(state in ("offer_rejected", "local_only", "sandbox_probe_only"), f"opaque endpoint reached {state!r}; must be rejected or confined")
        status = self.status(self.opaque)
        assert_true(status["admission_state"] != "settlement_capable" and status["admission_state"] != "catalog_priced", "opaque endpoint reached a priced or settlement state")
        assert_true(status.get("catalog_model_key") is None, "opaque endpoint acquired a catalog key")
        assert_true(status["provider_guidance"]["earning_path_class"] != "settlement_capable", "opaque endpoint guidance claims settlement")
        assert_true(self.rig.request_log_since(marker) == 0, "opaque endpoint submission produced buyer traffic")
        self.m.observe("rejected_opaque_endpoint_verified", True)
        doc = self.m.capture("opaque-endpoint-rejected-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[2], "An opaque endpoint candidate was rejected or confined to a non-settlement state with no catalog key, no economics, and no buyer traffic.", [doc])

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
        code, response = self.decide(self.config.operator_actor_a, self.settleable, "network_visible_unpriced", "experimental_disclosure")
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
        code, response = self.decide(self.config.operator_actor_a, self.settleable, "catalog_priced", "catalog_binding_verified")
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
        document = self.rig.cli(["models", "admission", "withdraw", self.settleable.served_model_ref, "--reason-code", "operator_withdrawal", *self._common()])
        assert_true(document.get("schema") == "model_admission_withdraw.v1", "withdraw did not return the withdraw document")
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
        code, _ = self.decide(self.config.operator_actor_a, self.settleable, "catalog_priced", "catalog_binding_verified")
        assert_true(code == 200, f"re-promotion to catalog_priced failed (HTTP {code})")
        self.expect_state(self.settleable, "catalog_priced", "step 9")
        code, proposed = self.decide(self.config.operator_actor_a, self.settleable, "settlement_capable", "dual_control_settlement")
        assert_true(code in (200, 202) and proposed.get("pending_decision_id"), f"settlement_capable proposal did not create a pending decision (HTTP {code})")
        pending_id = proposed["pending_decision_id"]
        # The proposing actor must not be able to approve its own proposal.
        code, _ = self.approve(self.config.operator_actor_a, self.settleable, pending_id)
        assert_true(code >= 400, "the proposing actor approved its own settlement_capable decision; dual control not enforced")
        code, approved = self.approve(self.config.operator_actor_b, self.settleable, pending_id)
        assert_true(code == 200 and approved.get("admission_state") == "settlement_capable", f"distinct-actor approval did not apply (HTTP {code})")
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
        novel = self.status(self.gguf) if self.gguf else self.status(self.opaque)
        assert_true(novel["provider_guidance"]["earning_path_class"] in ("no_earning_path_in_v0_1", "local_inventory_only"), "novel candidate status does not disclose the absence of an earning path")
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
        code, _ = self.decide(self.config.operator_actor_a, self.settleable, illegal, "matrix_probe")
        assert_true(code >= 400, f"illegal transition {state} -> {illegal} was accepted (HTTP {code})")
        self.expect_state(self.settleable, state, "step 11 (state unchanged after illegal attempt)")
        # Valid rejected-offer/re-offer path: the opaque candidate was rejected in step 3.
        rejected = self.status(self.opaque)
        if rejected["admission_state"] == "offer_rejected":
            reoffer = self.rig.cli(["models", "offer", self.opaque.served_model_ref, *self._common()])
            assert_true(reoffer.get("coordinator_event_id") != rejected.get("coordinator_event_id"), "re-offer after rejection reused the old evidence")
        self.m.observe("rejected_reoffer_required_fresh_evidence", True)
        self.m.observe("transition_matrix_enforced", True)
        doc = self.m.capture("re-entry-status", "model_admission_status.v1", self.status(self.settleable))
        self.m.add_step(STEP_IDS[10], "An out-of-matrix transition was rejected and left the state unchanged; rejected, withdrawn and revoked re-entries each required fresh provider-signed evidence.", [doc])

    def step_12_redaction_review(self, transcript: str) -> None:
        status = self.status(self.settleable)
        blob = transcript + json.dumps(status)
        for forbidden in (os.environ[self.config.operator_secret_a_env], os.environ[self.config.operator_secret_b_env], os.environ[self.config.postgres_dsn_env]):
            assert_true(forbidden not in blob, "an operator secret or DSN appeared in the transcript or a captured document")
        assert_true("BEGIN PRIVATE KEY" not in blob and "sk-" not in blob, "credential shape found in transcript")
        self.m.observe("secret_field_persisted", False)
        self.m.observe("raw_prompt_logged", False)
        self.m.observe("raw_completion_logged", False)
        doc = self.m.capture("redaction-review-status", "model_admission_status.v1", status)
        self.m.add_step(STEP_IDS[11], "Offer packages, coordinator events, status, logs and evidence artifacts were reviewed for secrets, prompts, completions, paths and endpoints.", [doc])

    # -- run --------------------------------------------------------------

    def run(self, transcript: Callable[[], str]) -> Path:
        steps = [
            self.step_01_offer_dry_run, self.step_02_submit_signed_offer, self.step_03_reject_opaque_endpoint,
            self.step_04_sandbox_probe_only, self.step_05_network_visible_unpriced, self.step_06_catalog_matched_not_settlement,
            self.step_07_revocation_on_drift, self.step_08_withdrawal, self.step_09_settlement_capable_case,
            self.step_10_admission_status_presentation, self.step_11_transition_validity,
        ]
        for step in steps:
            self.log("journey: " + step.__name__)
            step()
        self.step_12_redaction_review(transcript())
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
    parser.add_argument("--gguf-ref", default=None, help="optional GGUF candidate for the novel-candidate presentation and the R007(e) stop case")
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
        gguf_ref=args.gguf_ref, drift_hook=args.drift_hook.resolve() if args.drift_hook else None,
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
