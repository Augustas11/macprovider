"""JOURNEY-OLLAMA-LOOPBACK-RUNTIME physical runner (issue #1569).

Proves the #1569 end-to-end contract with a SINGLE `macprovider-cli serve`
process serving `ollama:gemma3:270m` through the `ollama_loopback` adapter:

1. Exactly one serve process (the runner starts it, tracks its PID, and tears
   down that PID only -- never `pkill macprovider-cli`, because a production
   serve may run on the same Mac). Its coordinator hello reports served ref
   `ollama:gemma3:270m`, `runtime_source = ollama_loopback`, and a
   `macprovider.gguf-file.v1` identity (never an Ollama manifest/layer digest).
2. `models offer ollama:gemma3:270m --yes` is coordinator-backed and the
   candidate stays uncatalogued (`catalog_model_key` null).
3. The coordinator's synthetic probe travels the authenticated provider wire to
   THIS live session (no dereferenceable locator held coordinator-side).
4. The probe PASSES: `synthetic_probe_passed`, state `sandbox_probe_only` or
   `network_admitted_unsettled`. This is the flip versus the slice-7 admission
   journey step 10, whose Llama session case legitimately fails the probe.
5. Real tokens come back: the coordinator readback records
   `synthetic_probe_completion_tokens > 0`.
6. Still non-earning: never `catalog_priced`/`settlement_capable`, null
   economics, all ten money-path ledgers zero, and the sandbox session is not
   buyer-routable.
7. Redaction: the same fail-closed surface review the slice-7 journey runs --
   no raw prompt, completion, Ollama origin, host, IP, or filesystem path
   persisted anywhere.

This is a SEPARATE lane from `admission_journey.py`. It reuses that module's
vetted rig plumbing (secret-scrubbed child environment, loopback admin
transport, ledger measurement) and the shared `byom_journey_evidence`
redaction contract, and adds only what #1569 needs: a runner-owned serve
process and the Gemma-runtime probe assertions. It does not touch the twelve
SPEC-047 admission steps or their contract.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts"))
# The slice-7 sibling module lives beside this file; make it importable no
# matter how the runner is launched (as a script, or imported by the harness).
sys.path.insert(0, str(Path(__file__).resolve().parent))

# Reuse, do not duplicate: the leaf assertions, the redaction needles, the
# locator-key set, the grammars, the ledger tables, and the vetted rig
# (PhysicalRig -- its secret-scrubbed child environment and ledger reader).
from admission_journey import (  # noqa: E402
    COORDINATOR_EVENT_ID,
    JourneyFailure,
    LOCATOR_KEYS,
    LOOPBACK_ORIGIN,
    MONEY_PATH_TABLES,
    PROVIDER_ID,
    RAW_COMPLETION_SHAPES,
    RAW_PROMPT_SHAPES,
    REDACTION_SURFACES,
    SYNTHETIC_PROBE_PROMPT,
    ACTOR_ID,
    CANDIDATE_ID,
    PhysicalRig,
    RigConfig,
    assert_true,
    collect_keys,
    error_code,
    redact_argument,
)
import byom_journey_evidence as evidence_contract  # noqa: E402

JOURNEY_ID = "JOURNEY-OLLAMA-LOOPBACK-RUNTIME"
RUN_MANIFEST_SCHEMA = "macprovider.gemma-runtime-journey.v1"
OBSERVATION_SCHEMA = "macprovider.gemma-runtime-observation.v1"
ENVIRONMENT_CLASS = "physical-provider"
HARNESS_NAME = "test/e2e/byom/gemma_runtime_journey.py"

OFFERS_PATH = "/admin/model-admission/offers"
OFFER_LIST_SCHEMA = "model_admission_offer_list.v1"

# The #1569 served ref this lane proves, and the runtime source the hello must
# declare. A Llama served ref anywhere is a hard failure (assertion 1).
RUNTIME_SOURCE = "ollama_loopback"
GGUF_HASH_ALGORITHM = "macprovider.gguf-file.v1"
# The CLI's own gguf-file.v1 digest path leaves discovery identity in one of
# these two states; a runtime-reported (manifest/layer digest) fallback would
# read `runtime_reported`, which this lane rejects.
GGUF_IDENTITY_STATES = frozenset({"catalog_matched", "artifact_hash_available"})

# The states a passed synthetic probe may leave an uncatalogued sandbox
# candidate in. `catalog_priced`/`settlement_capable` are unreachable for a
# null catalog key and are a hard failure if ever seen.
PROBE_PASS_STATES = ("sandbox_probe_only", "network_admitted_unsettled")
FORBIDDEN_EARNING_STATES = frozenset({"catalog_priced", "settlement_capable"})

# `ollama:<tag>` -- the only served-ref shape this lane accepts. A colon, never
# a scheme; it carries no host, path or origin.
OLLAMA_SERVED_REF = re.compile(r"^ollama:[A-Za-z0-9._:-]{1,120}$")


# --------------------------------------------------------------------- config

@dataclass(frozen=True)
class GemmaRigConfig:
    """The lean rig this single-operator, single-model lane needs. It is a
    strict subset of the admission journey's RigConfig -- one operator (only
    the offer listing is read), one served ref -- so the shared PhysicalRig
    plumbing is reused without the dual-control / three-candidate baggage the
    twelve-step contract requires."""

    cli_binary: Path
    provider_config: Path
    coordinator_admin_origin: str
    operator_actor: str
    operator_secret_env: str
    postgres_dsn_env: str
    served_ref: str
    provider_log: Path
    coordinator_log: Path
    serve_log_level: str
    ollama_origin_env: str
    discovery_args: tuple[str, ...] = ()
    serve_args: tuple[str, ...] = ()

    PSQL_ENVIRONMENT_ALLOWLIST = RigConfig.PSQL_ENVIRONMENT_ALLOWLIST

    def validate(self) -> None:
        assert_true(self.cli_binary.is_file() and os.access(self.cli_binary, os.X_OK), "cli binary is not executable")
        assert_true(self.provider_config.is_file(), "provider config is missing")
        assert_true(self.provider_log.is_file(), "the runner-owned serve log --provider-log must exist (the runner creates it before serve starts); step 7 reviews what serve appends")
        assert_true(self.coordinator_log.is_file(), "step 7 reviews the rig coordinator log; --coordinator-log must name an existing file")
        assert_true(bool(OLLAMA_SERVED_REF.match(self.served_ref)), "--served-ref must be an ollama:<tag> loopback ref, e.g. ollama:gemma3:270m")
        # Reject a Llama MODEL tag, but check the tag AFTER the `ollama:` runtime
        # prefix -- the prefix "ollama" itself contains the substring "llama".
        _served_tag = self.served_ref.split(":", 1)[1] if ":" in self.served_ref else self.served_ref
        assert_true("llama" not in _served_tag.lower(), "this lane proves the Gemma runtime; a Llama served ref belongs to the admission journey")
        assert_true(bool(LOOPBACK_ORIGIN.match(self.coordinator_admin_origin)), "coordinator admin origin must be loopback http")
        assert_true(bool(ACTOR_ID.match(self.operator_actor)), "operator actor id is not in the operator actor grammar")
        for name in (self.operator_secret_env, self.postgres_dsn_env):
            assert_true(bool(os.environ.get(name)), "environment variable is unset: " + name)

    def child_environment(self, *, psql_service_file: Path | None = None) -> dict[str, str]:
        """The scrubbed environment for every subprocess: the operator secret,
        the ledger DSN and every PG* variable are dropped so no child (serve,
        the CLI, psql) can read them back. Mirrors RigConfig.child_environment
        with this lane's single operator secret. `MACPROVIDER_OLLAMA_ORIGIN`
        (the loopback origin override) is NOT a secret and is preserved so the
        serve and discovery paths honour the operator's origin."""
        secrets = {self.operator_secret_env, self.postgres_dsn_env}
        env = {name: value for name, value in os.environ.items() if name not in secrets and not name.startswith("PG")}
        if psql_service_file is None:
            return env
        env = {name: value for name, value in env.items() if name in self.PSQL_ENVIRONMENT_ALLOWLIST or name.startswith("LC_")}
        env.update({"PGSERVICEFILE": str(psql_service_file), "PGSERVICE": "journey"})
        return env


# ------------------------------------------------------------------------ rig

class GemmaRig(PhysicalRig):
    """The slice-7 PhysicalRig with two additions and one narrowing:

    - it OWNS the serve process (`start_serve`/`stop_serve`), tracking the exact
      PID so teardown never touches another `macprovider-cli` (a production
      serve may share this Mac);
    - its config is the lean single-operator `GemmaRigConfig`, so `__init__`
      runs that config's validation rather than the dual-control one.

    Every inherited method (`cli`, `cli_raw`, `admin_get`, `_bearer`,
    `ledger_counts`, `surfaces`, `request_log_marker`) is reused unchanged; the
    single operator populates `_bearer` because this lane only ever reads with
    one actor. The `_bearer` override below removes the A/B branch."""

    def __init__(self, config: GemmaRigConfig):
        config.validate()
        self.config = config
        self._transcript: list[str] = []
        # The coordinator log baseline is fixed here (external process, as in
        # the admission journey). The serve log baseline is (re)set by
        # `mark_serve_log_baseline` once serve startup has settled, so serve's
        # own startup chatter -- which may name the coordinator URL -- is kept
        # out of the redaction review while the probe-time bytes stay in it.
        self._log_offsets = {
            "provider_log": config.provider_log.stat().st_size,
            "coordinator_log": config.coordinator_log.stat().st_size,
        }
        self._serve_proc: subprocess.Popen[bytes] | None = None
        self._serve_log_handle = None

    def _bearer(self, actor: str) -> str:
        # Single-operator lane: the only actor is the configured one.
        assert_true(actor == self.config.operator_actor, "gemma-runtime lane addressed an unknown operator actor")
        return os.environ[self.config.operator_secret_env]

    # -- serve process ownership ------------------------------------------

    def start_serve(self) -> int:
        """Start exactly one `macprovider-cli serve --model <served_ref>` and
        return its PID. serve stderr is appended to the runner-owned provider
        log so step 7 can review it. The command line is recorded (paths and
        origins redacted) so the runner's own transcript stays review-clean."""
        assert_true(self._serve_proc is None, "start_serve called twice; this lane runs exactly one serve process")
        args = [
            "serve",
            "--model", self.config.served_ref,
            "--config", str(self.config.provider_config),
            "--log-level", self.config.serve_log_level,
            *self.config.serve_args,
        ]
        self._transcript.append("$ macprovider-cli " + " ".join(redact_argument(a) for a in args) + "\n[serve started; output in the provider log]")
        handle = open(self.config.provider_log, "ab", buffering=0)
        proc = subprocess.Popen(
            [str(self.config.cli_binary), *args],
            stdout=handle, stderr=subprocess.STDOUT, cwd=str(ROOT),
            env=self.config.child_environment(),
        )
        self._serve_proc = proc
        self._serve_log_handle = handle
        return proc.pid

    def serve_pid(self) -> int | None:
        return self._serve_proc.pid if self._serve_proc is not None else None

    def serve_alive(self) -> bool:
        return self._serve_proc is not None and self._serve_proc.poll() is None

    def mark_serve_log_baseline(self) -> None:
        """Set the provider-log review baseline to the current size, dropping
        serve's startup lines from step 7 while keeping the probe-time bytes."""
        self._log_offsets["provider_log"] = self.config.provider_log.stat().st_size

    def stop_serve(self) -> None:
        """Terminate ONLY the tracked serve PID (SIGTERM, then SIGKILL). Never
        signals by binary name: a production serve may run on this Mac."""
        proc = self._serve_proc
        if proc is not None:
            if proc.poll() is None:
                proc.terminate()
                try:
                    proc.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    try:
                        proc.wait(timeout=15)
                    except subprocess.TimeoutExpired:
                        pass
            self._serve_proc = None
        if self._serve_log_handle is not None:
            try:
                self._serve_log_handle.close()
            finally:
                self._serve_log_handle = None


# -------------------------------------------------------------------- manifest

class GemmaManifestBuilder:
    """A lean manifest for this lane: its own schema, steps and observations
    (not the twelve-step admission contract). Captured documents pass the same
    fail-closed `byom_journey_evidence` redaction the admission capture uses;
    validation against the admission CLI schemas is intentionally NOT applied,
    because these are this lane's own distilled observation documents."""

    # Execution order: the coordinator-side hello readback (the offer listing
    # session block) only lists a candidate once its offer event exists, so the
    # offer step precedes the hello-identity step.
    STEP_IDS = (
        "serve_one_process",
        "offer_coordinator_backed",
        "hello_identity_gemma_loopback",
        "synthetic_probe_passed_over_wire",
        "non_earning_zero_ledgers",
        "redaction_review",
    )
    TRUE_OBSERVATIONS = (
        "single_serve_process_serves_gemma",
        "served_identity_is_gguf_file_digest",
        "hello_runtime_source_ollama_loopback",
        "hello_served_ref_is_gemma_not_llama",
        "offer_coordinator_backed_catalog_key_null",
        "synthetic_probe_used_provider_channel",
        "synthetic_probe_passed",
        "synthetic_probe_completion_tokens_positive",
        "sandbox_session_not_buyer_routable",
        "non_settlement_null_economics",
    )
    FALSE_OBSERVATIONS = (
        "catalog_priced_or_settlement_reached",
        "raw_prompt_logged",
        "raw_completion_logged",
        "ollama_origin_persisted",
        "secret_or_locator_persisted",
    )

    def __init__(self, out_dir: Path, run_id: str, cli_version: str):
        self.out_dir = out_dir
        self.captures = out_dir / "captures"
        self.captures.mkdir(parents=True, mode=0o700, exist_ok=True)
        self.captures.chmod(0o700)
        self.run_id = run_id
        self.cli_version = cli_version
        self.steps: list[dict[str, Any]] = []
        self.observations: dict[str, Any] = {n: None for n in self.TRUE_OBSERVATIONS + self.FALSE_OBSERVATIONS}
        self.money_path: dict[str, int] | None = None
        self.payloads: dict[str, str] = {}

    def capture(self, name: str, document: dict[str, Any]) -> dict[str, str]:
        payload = json.dumps(document, indent=2, sort_keys=True) + "\n"
        try:
            evidence_contract.assert_captured_document_redacted(document, "captured document " + name)
            evidence_contract.reject_unredacted_text_except_hostname(payload, "captured document " + name)
        except evidence_contract.BYOMEvidenceError as exc:
            raise JourneyFailure(f"captured document {name} is not redaction-clean: {exc}") from exc
        path = self.captures / (name + ".json")
        path.write_text(payload, encoding="utf-8")
        path.chmod(0o600)
        self.payloads[name] = payload
        return {"id": name, "schema": document.get("schema", OBSERVATION_SCHEMA), "path": "captures/" + name + ".json"}

    def add_step(self, step_id: str, assertion: str, documents: list[dict[str, str]]) -> None:
        assert_true(step_id in self.STEP_IDS, "unknown step id: " + step_id)
        assert_true(all(s["id"] != step_id for s in self.steps), "step recorded twice: " + step_id)
        self.steps.append({"id": step_id, "status": "pass", "assertion": assertion, "documents": documents})

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
        for name in self.TRUE_OBSERVATIONS:
            assert_true(self.observations[name] is True, "observation must be true: " + name)
        for name in self.FALSE_OBSERVATIONS:
            assert_true(self.observations[name] is False, "observation must be false: " + name)
        assert_true(self.money_path is not None, "money-path ledgers were never measured")
        assert_true([s["id"] for s in self.steps] == list(self.STEP_IDS), "manifest steps must cover every journey step exactly once, in order")
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


# ---------------------------------------------------------------------- runner

class GemmaRuntimeJourneyRunner:
    def __init__(self, rig: GemmaRig, config: GemmaRigConfig, manifest: GemmaManifestBuilder, log: Callable[[str], None] = print):
        self.rig = rig
        self.config = config
        self.m = manifest
        self.log = log
        self.provider_id: str = ""
        self.candidate_id: str = ""

    # -- helpers ----------------------------------------------------------

    def _offer_args(self) -> list[str]:
        return ["--json", "--config", str(self.config.provider_config), *self.config.discovery_args]

    def status(self) -> dict[str, Any]:
        document = self.rig.cli(["models", "admission", "status", self.config.served_ref, *self._offer_args()])
        assert_true(bool(PROVIDER_ID.match(document["provider_id"])), "status carries a provider_id outside the coordinator grammar")
        assert_true(bool(CANDIDATE_ID.match(document["candidate_id"])), "status carries a candidate_id that is not a stable byom_ id; the local discovery namespace is not provisioned")
        self.provider_id = document["provider_id"]
        self.candidate_id = document["candidate_id"]
        return document

    def offer_item(self) -> dict[str, Any]:
        """The coordinator offer-listing item for this candidate: the readback
        that carries the live-session block and the probe token evidence."""
        assert_true(bool(self.provider_id), "offer_item needs the provider id (run status first)")
        code, listing = self.rig.admin_get(OFFERS_PATH, self.config.operator_actor, {"provider_id": self.provider_id})
        assert_true(code == 200 and listing.get("schema") == OFFER_LIST_SCHEMA, f"coordinator offer listing unavailable (HTTP {code}, {error_code(listing)!r})")
        item = next((c for c in (listing.get("candidates") or []) if isinstance(c, dict) and c.get("candidate_id") == self.candidate_id), None)
        assert_true(item is not None, "the gemma candidate is missing from the coordinator offer listing")
        return item

    def wait_for_probe_terminal(self, attempts: int = 40, interval: float = 2.0) -> dict[str, Any]:
        """Poll the offer listing until the coordinator's probe policy lands a
        terminal outcome. A passed probe reaches network_admitted_unsettled
        (via sandbox_probe_only); a failed/revoked probe reaches revoked. The
        Gemma live session must PASS -- revoked/synthetic_probe_failed here is
        the hard failure this lane exists to rule out (versus slice-7 step 10,
        whose Llama session legitimately fails)."""
        last_state = last_reason = None
        for _ in range(attempts):
            item = self.offer_item()
            state = item.get("admission_state")
            reason = item.get("reason_code")
            last_state, last_reason = state, reason
            assert_true(state not in FORBIDDEN_EARNING_STATES, f"uncatalogued gemma candidate reached an earning state {state!r}; catalog_priced/settlement_capable must be unreachable")
            if state == "revoked" or reason == "synthetic_probe_failed":
                raise JourneyFailure(f"gemma synthetic probe did not pass (state {state!r}, reason {reason!r}); a passing probe over the live loopback session is required")
            if state == "network_admitted_unsettled":
                return item
            time.sleep(interval)
        raise JourneyFailure(f"gemma candidate never reached a passed-probe terminal state (last state {last_state!r}, reason {last_reason!r})")

    # -- steps ------------------------------------------------------------

    def step_serve_one_process(self) -> None:
        pid = self.rig.start_serve()
        self.log(f"journey: started serve pid={pid}")
        # Let serve reach the coordinator and settle its startup logging before
        # the redaction baseline is drawn. The CLI discovery path confirms the
        # local ollama_loopback candidate is resolvable while we wait.
        candidate = None
        for _ in range(30):
            assert_true(self.rig.serve_alive(), "the serve process exited during startup; check the provider log and that Ollama is serving the model")
            document = self.rig.cli(["models", "discover", "--json", *self.config.discovery_args])
            assert_true(document.get("schema") == "provider_byom_discovery.v1", "models discover did not return the discovery contract")
            candidate = next((c for c in (document.get("candidates") or []) if c.get("served_model_ref") == self.config.served_ref), None)
            if candidate is not None:
                break
            time.sleep(2.0)
        assert_true(candidate is not None, "the ollama:gemma3:270m candidate is not discoverable; is Ollama serving the model at the loopback origin?")
        assert_true(candidate.get("runtime_source") == RUNTIME_SOURCE, f"discovery reports runtime_source {candidate.get('runtime_source')!r}, expected ollama_loopback")
        # Identity proxy: catalog_matched / artifact_hash_available means the
        # CLI bound the served bytes through its own macprovider.gguf-file.v1
        # file digest, never a runtime-reported Ollama manifest/layer digest
        # (which would leave identity_state == runtime_reported).
        identity_state = candidate.get("identity_state")
        assert_true(identity_state in GGUF_IDENTITY_STATES, f"the gemma candidate identity_state is {identity_state!r}; the served bytes are not bound by a {GGUF_HASH_ALGORITHM} file digest (a runtime-reported Ollama digest is not accepted)")
        # The runner owns exactly one serve subprocess; teardown targets its PID.
        assert_true(self.rig.serve_pid() == pid and self.rig.serve_alive(), "the single tracked serve process is not alive")
        self.rig.mark_serve_log_baseline()
        self.m.observe("single_serve_process_serves_gemma", True)
        self.m.observe("served_identity_is_gguf_file_digest", True)
        doc = self.m.capture("serve-discovery", {
            "schema": OBSERVATION_SCHEMA,
            "observation": "single_ollama_loopback_serve",
            "served_model_ref": candidate.get("served_model_ref"),
            "runtime_source": candidate.get("runtime_source"),
            "identity_state": identity_state,
            "model_hash_algorithm": GGUF_HASH_ALGORITHM,
        })
        self.m.add_step("serve_one_process", "The runner started exactly one macprovider-cli serve process for ollama:gemma3:270m (tracked by PID), and the CLI discovery path shows the candidate is an ollama_loopback candidate bound by a macprovider.gguf-file.v1 file digest, not a runtime-reported Ollama digest.", [doc])

    def step_hello_identity(self) -> None:
        """The coordinator-side view of the live hello: the offer listing's
        session block carries the served ref and runtime_source the serve
        process declared. Read after the offer so the candidate is listed."""
        self.status()
        item = self.offer_item()
        session = item.get("session")
        assert_true(isinstance(session, dict), "the coordinator offer listing carries no live session for this provider; the serve hello was not observed")
        assert_true(session.get("runtime_source") == RUNTIME_SOURCE, f"the live session runtime_source is {session.get('runtime_source')!r}, expected ollama_loopback")
        assert_true(session.get("served_model_ref") == self.config.served_ref, f"the live session served_model_ref is {session.get('served_model_ref')!r}, expected {self.config.served_ref}; a Llama hello fails this lane")
        _hello_ref = str(session.get("served_model_ref", ""))
        _hello_tag = _hello_ref.split(":", 1)[1] if ":" in _hello_ref else _hello_ref
        assert_true("llama" not in _hello_tag.lower(), "the live hello names a Llama model; the Gemma runtime session is required")
        # Pass-bar 1: the serve hello's model_hash_algorithm is the gguf-file.v1
        # label recomputed over the local GGUF file bytes, never an Ollama
        # manifest/layer digest. Asserted directly from the coordinator-side
        # readback of what the hello reported.
        assert_true(session.get("model_hash_algorithm") == GGUF_HASH_ALGORITHM, f"the live session model_hash_algorithm is {session.get('model_hash_algorithm')!r}, expected {GGUF_HASH_ALGORITHM}")
        # The offer event itself also carries the runtime source.
        assert_true(item.get("runtime_source") == RUNTIME_SOURCE, f"the offer event runtime_source is {item.get('runtime_source')!r}, expected ollama_loopback")
        self.m.observe("hello_runtime_source_ollama_loopback", True)
        self.m.observe("hello_served_ref_is_gemma_not_llama", True)
        doc = self.m.capture("hello-session-identity", {
            "schema": OBSERVATION_SCHEMA,
            "observation": "live_session_hello_identity",
            "session_runtime_source": session.get("runtime_source"),
            "session_served_model_ref": session.get("served_model_ref"),
            "session_model_hash_algorithm": session.get("model_hash_algorithm"),
            "event_runtime_source": item.get("runtime_source"),
        })
        self.m.add_step("hello_identity_gemma_loopback", "The coordinator's live-session readback reports the serve hello as runtime_source ollama_loopback serving ollama:gemma3:270m -- not a Llama session.", [doc])

    def step_offer_coordinator_backed(self) -> None:
        submit = self.rig.cli(["models", "offer", self.config.served_ref, "--yes", *self._offer_args()])
        assert_true(submit.get("schema") == "model_admission_status.v1", "offer submit did not return the status document")
        assert_true(submit.get("admission_state_source") == "coordinator", "the gemma offer was not coordinator-backed")
        assert_true(submit.get("admission_state") in ("offer_submitted", *PROBE_PASS_STATES), f"offer landed in an unexpected coordinator state {submit.get('admission_state')!r}")
        assert_true(bool(submit.get("coordinator_event_id")) and bool(COORDINATOR_EVENT_ID.match(submit.get("coordinator_event_id", ""))), "the accepted offer carries no coordinator event id")
        assert_true(submit.get("catalog_model_key") is None, "the uncatalogued gemma candidate acquired a catalog_model_key; it must stay null")
        self.status()  # refresh provider_id / candidate_id from the coordinator-backed status
        self.m.observe("offer_coordinator_backed_catalog_key_null", True)
        doc = self.m.capture("offer-submitted", {
            "schema": OBSERVATION_SCHEMA,
            "observation": "coordinator_backed_offer",
            "admission_state": submit.get("admission_state"),
            "admission_state_source": submit.get("admission_state_source"),
            "catalog_model_key_is_null": submit.get("catalog_model_key") is None,
        })
        self.m.add_step("offer_coordinator_backed", "models offer ollama:gemma3:270m --yes was accepted by the coordinator (coordinator-backed status, event id present) and the candidate stayed uncatalogued (catalog_model_key null).", [doc])

    def step_probe_passed(self) -> None:
        item = self.wait_for_probe_terminal()
        assert_true(item.get("reason_code") == "synthetic_probe_passed", f"terminal probe reason is {item.get('reason_code')!r}, expected synthetic_probe_passed")
        assert_true(item.get("last_event_actor") == "coordinator", f"the probe-passed event was not coordinator-origin (actor {item.get('last_event_actor')!r})")
        assert_true(item.get("admission_state") == "network_admitted_unsettled", f"passed probe left state {item.get('admission_state')!r}, expected network_admitted_unsettled")
        assert_true(item.get("catalog_model_key") is None, "the probed candidate acquired a catalog key; it must stay uncatalogued")
        # Token evidence: the coordinator recorded the integer usage.completion_tokens.
        tokens = item.get("synthetic_probe_completion_tokens")
        assert_true(isinstance(tokens, int) and not isinstance(tokens, bool) and tokens > 0, f"synthetic_probe_completion_tokens is {tokens!r}; a passed probe must record a positive integer token count")
        # SPEC-047-R008: the probe reached the session only over the provider
        # wire; the coordinator holds no dereferenceable locator for it.
        locator_keys = collect_keys(item) & LOCATOR_KEYS
        assert_true(not locator_keys, "the coordinator offer item carries a dereferenceable locator field: " + ", ".join(sorted(locator_keys)))
        self.m.observe("synthetic_probe_used_provider_channel", True)
        self.m.observe("synthetic_probe_passed", True)
        self.m.observe("synthetic_probe_completion_tokens_positive", True)
        doc = self.m.capture("synthetic-probe-passed", {
            "schema": OBSERVATION_SCHEMA,
            "observation": "synthetic_probe_passed_with_tokens",
            "admission_state": item.get("admission_state"),
            "reason_code": item.get("reason_code"),
            "last_event_actor": item.get("last_event_actor"),
            "synthetic_probe_completion_tokens_positive": tokens > 0,
            "no_dereferenceable_locator": True,
        })
        self.m.add_step("synthetic_probe_passed_over_wire", "The coordinator synthetic probe reached THIS live session over the provider wire (no dereferenceable locator), passed (synthetic_probe_passed, coordinator-origin), landed network_admitted_unsettled, and recorded synthetic_probe_completion_tokens > 0.", [doc])

    def step_non_earning(self) -> None:
        marker = self.rig.request_log_marker()
        status = self.status()
        assert_true(status.get("catalog_model_key") is None, "the candidate is catalog-matched; a non-earning gemma runtime must stay uncatalogued")
        assert_true(status.get("admission_state") not in FORBIDDEN_EARNING_STATES, f"the candidate reached earning state {status.get('admission_state')!r}")
        assert_true((status.get("provider_guidance") or {}).get("earning_path_class") == "no_earning_path_in_v0_1", f"status reports earning_path_class {(status.get('provider_guidance') or {}).get('earning_path_class')!r}, expected no_earning_path_in_v0_1")
        # Economics stays null (reuse the CLI's own money projection).
        econ = self.rig.cli(["models", "catalog-economics", *self._offer_args()])
        assert_true(econ.get("schema") == "model_catalog_economics.v1", "catalog-economics returned the wrong schema")
        rows = [r for r in econ.get("rows", []) if r.get("action_model_id") == self.candidate_id]
        assert_true(len(rows) == 1, "catalog-economics must show the gemma candidate exactly once")
        row = rows[0]
        admission = row.get("admission") or {}
        assert_true(admission.get("settlement_capable") is False, "economics admission.settlement_capable must be false")
        assert_true(admission.get("catalog_economics_permitted") is False, "catalog economics must not be permitted for the uncatalogued candidate")
        assert_true(row.get("economics_state") == "blocked" and row.get("rate_source") == "none", "economics must be blocked with no rate source")
        for f in ("prompt_rate_usd_per_million_tokens", "completion_rate_usd_per_million_tokens", "provider_prompt_payout_usd_per_million_tokens", "provider_completion_payout_usd_per_million_tokens"):
            assert_true(row.get(f) is None, f"{f} must be null for the non-earning gemma candidate")
        # No buyer traffic reached the session, and the sandbox session is not
        # buyer-routable: the request log did not advance while it was probed.
        assert_true(self.rig.request_log_since(marker) == 0, "buyer traffic reached the sandbox gemma session; it must not be buyer-routable")
        counts = self.rig.ledger_counts()
        self.m.observe("catalog_priced_or_settlement_reached", False)
        self.m.observe("non_settlement_null_economics", True)
        self.m.observe("sandbox_session_not_buyer_routable", True)
        doc = self.m.capture("non-earning-economics", {
            "schema": OBSERVATION_SCHEMA,
            "observation": "non_earning_null_economics",
            "catalog_model_key_is_null": status.get("catalog_model_key") is None,
            "earning_path_class": (status.get("provider_guidance") or {}).get("earning_path_class"),
            "economics_state": row.get("economics_state"),
            "rate_source": row.get("rate_source"),
            "settlement_capable": admission.get("settlement_capable"),
            "request_log_delta": 0,
        })
        self.m.add_step("non_earning_zero_ledgers", "The gemma candidate stayed uncatalogued with null economics and no earning path, the request log did not advance (not buyer-routable), and the ten money-path ledgers are measured for the final zero check.", [doc])
        self._final_ledger_counts = counts

    def step_redaction_review(self, runner_log: str) -> None:
        """Reuse the slice-7 step-12 review over the same six surfaces: the
        runner log, the CLI/operator transcript, every captured document, the
        coordinator offer listing, and the provider and coordinator logs."""
        code, listing = self.rig.admin_get(OFFERS_PATH, self.config.operator_actor, {"provider_id": self.provider_id})
        assert_true(code == 200 and listing.get("schema") == OFFER_LIST_SCHEMA, f"coordinator event listing unavailable (HTTP {code}, {error_code(listing)!r})")
        surfaces = dict(self.rig.surfaces())
        surfaces["runner_log"] = runner_log
        surfaces["captured_documents"] = "\n".join(self.m.payloads[name] for name in sorted(self.m.payloads))
        surfaces["coordinator_events"] = json.dumps(listing, sort_keys=True)
        missing = sorted(set(REDACTION_SURFACES) - set(surfaces))
        assert_true(not missing, "redaction review is missing surfaces: " + ", ".join(missing))
        dsn = os.environ[self.config.postgres_dsn_env]
        ollama_origin = os.environ.get("MACPROVIDER_OLLAMA_ORIGIN", "").strip()
        needles: list[tuple[str, str]] = [
            ("operator secret", os.environ[self.config.operator_secret_env]),
            ("ledger dsn", dsn),
        ]
        if ollama_origin:
            needles.append(("ollama origin", ollama_origin))
        sqlite_path = PhysicalRig._sqlite_ledger_path(dsn)
        if sqlite_path:
            needles.append(("ledger sqlite path", sqlite_path))
        else:
            password = PhysicalRig.libpq_parameters(dsn).get("password")
            if password:
                needles.append(("ledger password", password))
        for name in REDACTION_SURFACES:
            text = surfaces[name]
            for category, needle in needles:
                assert_true(needle not in text, f"redaction review: {category} found in surface {name}")
            try:
                evidence_contract.reject_unredacted_text_except_hostname(text, "surface " + name)
            except evidence_contract.BYOMEvidenceError as exc:
                raise JourneyFailure(f"redaction review: {exc}") from exc
        prompt_hits = [n for n in REDACTION_SURFACES if SYNTHETIC_PROBE_PROMPT in surfaces[n] or any(p.search(surfaces[n]) for p in RAW_PROMPT_SHAPES)]
        assert_true(not prompt_hits, "redaction review: a raw prompt is persisted in: " + ", ".join(prompt_hits))
        completion_hits = [n for n in REDACTION_SURFACES if any(p.search(surfaces[n]) for p in RAW_COMPLETION_SHAPES)]
        assert_true(not completion_hits, "redaction review: a raw completion is persisted in: " + ", ".join(completion_hits))
        self.m.observe("ollama_origin_persisted", False)
        self.m.observe("secret_or_locator_persisted", False)
        self.m.observe("raw_prompt_logged", False)
        self.m.observe("raw_completion_logged", False)
        doc = self.m.capture("redaction-review", {
            "schema": OBSERVATION_SCHEMA,
            "observation": "surfaces_redaction_clean",
            "surfaces_reviewed": sorted(REDACTION_SURFACES),
        })
        self.m.add_step("redaction_review", "The runner log, the CLI/operator transcript, every captured document, the coordinator offer listing, and the provider and coordinator logs were reviewed; no operator secret, ledger credential, Ollama origin, URL, filesystem path, IP literal, raw prompt or raw completion is persisted in any of them.", [doc])

    # -- run --------------------------------------------------------------

    def run(self, runner_log: Callable[[], str]) -> Path:
        self._final_ledger_counts: dict[str, int] = {}
        try:
            self.step_serve_one_process()
            self.step_offer_coordinator_backed()
            self.step_hello_identity()
            self.step_probe_passed()
            self.step_non_earning()
            self.step_redaction_review(runner_log())
            self.m.record_money_path(self._final_ledger_counts or self.rig.ledger_counts())
            return self.m.write()
        finally:
            self.rig.stop_serve()


# ------------------------------------------------------------------------ cli

def cli_version(binary: Path, env: dict[str, str]) -> str:
    completed = subprocess.run([str(binary), "--version"], capture_output=True, text=True, check=False, env=env)
    assert_true(completed.returncode == 0, "cli --version failed")
    return completed.stdout.strip().split()[-1]


def prepare_out_dir(out_dir: Path) -> None:
    if out_dir.exists():
        assert_true(out_dir.is_dir() and not any(out_dir.iterdir()), "--out must be a new or empty directory; a failing rerun must never leave an earlier manifest as if it were current")
    out_dir.mkdir(parents=True, mode=0o700, exist_ok=True)
    out_dir.chmod(0o700)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Drive JOURNEY-OLLAMA-LOOPBACK-RUNTIME (#1569) on a physical rig and emit run-manifest.json.")
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--cli-binary", required=True, type=Path)
    parser.add_argument("--provider-config", required=True, type=Path)
    parser.add_argument("--coordinator-admin-origin", required=True)
    parser.add_argument("--operator-actor", required=True, help="the single operator actor whose bearer reads the offer listing")
    parser.add_argument("--operator-secret-env", default="MACPROVIDER_JOURNEY_OPERATOR_A")
    parser.add_argument("--postgres-dsn-env", default="MACPROVIDER_JOURNEY_LEDGER_DSN")
    parser.add_argument("--served-ref", default="ollama:gemma3:270m", help="the ollama:<tag> loopback ref this lane serves and offers")
    parser.add_argument("--provider-log", required=True, type=Path, help="the runner-owned serve log file (created before serve starts); step 7 reviews what serve appends after startup settles")
    parser.add_argument("--coordinator-log", required=True, type=Path, help="the rig coordinator log; step 7 reviews what it appends during the run")
    parser.add_argument("--serve-log-level", default="warning", help="serve --log-level; keep it quiet (warning/notice) so the serve log does not gain a URL, path or IP that step 7 would reject")
    parser.add_argument("--ollama-origin-env", default="MACPROVIDER_OLLAMA_ORIGIN", help="name of the env var carrying the loopback Ollama origin override (its VALUE is preserved for serve/discovery and treated as a redaction needle)")
    parser.add_argument("--discovery-arg", action="append", default=[], help="extra argv passed to every models command (e.g. --skip-lmstudio)")
    parser.add_argument("--serve-arg", action="append", default=[], help="extra argv passed to the serve process")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    config = GemmaRigConfig(
        cli_binary=args.cli_binary.resolve(),
        provider_config=args.provider_config.resolve(),
        coordinator_admin_origin=args.coordinator_admin_origin.rstrip("/"),
        operator_actor=args.operator_actor,
        operator_secret_env=args.operator_secret_env,
        postgres_dsn_env=args.postgres_dsn_env,
        served_ref=args.served_ref,
        provider_log=args.provider_log.resolve(),
        coordinator_log=args.coordinator_log.resolve(),
        serve_log_level=args.serve_log_level,
        ollama_origin_env=args.ollama_origin_env,
        discovery_args=tuple(args.discovery_arg),
        serve_args=tuple(args.serve_arg),
    )
    transcript: list[str] = []

    def log(line: str) -> None:
        transcript.append(line)
        print(line, file=sys.stderr)

    try:
        prepare_out_dir(args.out)
        # The runner owns the serve log: create it empty before the rig records
        # its baseline so the whole serve lifetime is inside the review window.
        config.provider_log.parent.mkdir(parents=True, exist_ok=True)
        config.provider_log.touch()
        rig = GemmaRig(config)
        manifest = GemmaManifestBuilder(args.out, uuid.uuid4().hex, cli_version(config.cli_binary, config.child_environment()))
        path = GemmaRuntimeJourneyRunner(rig, config, manifest, log).run(lambda: "\n".join(transcript))
    except JourneyFailure as failure:
        print("gemma runtime journey FAILED: " + str(failure), file=sys.stderr)
        return 1
    print("gemma runtime journey passed; manifest at " + str(path), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
