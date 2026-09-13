"""Tests for test/e2e/byom/admission_journey.py (#1486, BYOM v0.2 slice 7).

The runner's twelve steps are exercised end to end against a fake rig that
implements the SPEC-047-R001 transition matrix and dual control the way the
coordinator does, so the orchestration, the observations and the manifest are
verified without hardware. The negative cases are the ones that would make a
signed journey a lie: a proposer approving its own settlement decision, a
revocation that is operator-origin rather than drift, and a money ledger that
is not zero.
"""

from __future__ import annotations

import base64
import contextlib
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

from byom_journey_evidence import (  # noqa: E402
    ADMISSION_ALLOWED_NEXT_STATES,
    ADMISSION_CONTRACT,
    ADMISSION_WITHDRAWAL_REASON_CODES,
    BYOMEvidenceError,
    COORDINATOR_ALLOWED_NEXT_STATES_ORDERED,
    COORDINATOR_STATE_NEXT_ACTION,
    build_evidence,
    validate_captured_cli_document,
)

_spec = importlib.util.spec_from_file_location("admission_journey", ROOT / "test/e2e/byom/admission_journey.py")
aj = importlib.util.module_from_spec(_spec)
assert _spec.loader is not None
sys.modules[_spec.name] = aj   # dataclasses resolve string annotations via sys.modules
_spec.loader.exec_module(aj)

SETTLEABLE = "mlx-community/Tiny-1B-4bit"
OPAQUE = "openai_compatible:opaque-mini-1b"
GGUF = "ollama:tiny-ollama-1b-q4"
NOW = "2027-01-15T08:00:00Z"
CLI_VERSION = "1.8.124"
PROVIDER_ID = "mp-" + "a" * 32
# The only states whose coordinator guidance carries a transition reason: a
# rejection, a withdrawal, and a revocation. Every other state the journey
# reaches is a FORWARD transition (offer -> sandbox -> priced -> settlement),
# which is not a demotion, so the coordinator leaves the reason null
# (model_admission.go modelAdmissionDemotionRequiresReason).
COORDINATOR_STATE_REASON_STATES = frozenset({"offer_rejected", "withdrawn", "revoked"})


def candidate_id(ref: str) -> str:
    """A production-shaped stable BYOM id: byom_ + 52 base32 characters
    (model_admission.go modelAdmissionCandidatePattern)."""
    return "byom_" + base64.b32encode(hashlib.sha256(ref.encode()).digest()).decode().lower().rstrip("=")[:52]


def guidance(state: str, earning: str) -> dict:
    # Mirror the coordinator's guidance emitter (model_admission.go): an
    # unsuffixed state label key, a fixed meaning key (not_offered for
    # not_offered, not_earning otherwise), and the state-derived next_action.
    # `local_only` is CLI-side, not a coordinator state, so it keeps the neutral
    # CLI action.
    return {
        "state_label_key": f"byom.admission.{state}",
        "state_meaning_key": "byom.admission.not_offered" if state == "not_offered" else "byom.admission.not_earning",
        "next_action": COORDINATOR_STATE_NEXT_ACTION.get(state, "check_status"),
        "transition_reason_code": None,
        "earning_path_class": earning,
    }


def action(available: bool = False) -> dict:
    return {
        "available": available, "requires_confirmation": False, "transaction_kind": None,
        "transaction_id": None, "unavailable_reason": None if available else "not_applicable",
        "action_timeout_seconds": None, "estimated_bytes": None,
    }


ECONOMICS_SOURCE = {
    "cli_version": CLI_VERSION, "cli_build_commit": "0" * 40, "process_launch_id": "launch-1",
    "process_started_at": NOW, "projection_protocol_version": 1, "rate_card_source": "live_signed",
    "rate_card_digest": "a" * 64, "rate_card_signature_digest": "b" * 64, "demand_feed_digest": "c" * 64,
    "candidate_feed_digest": "d" * 64, "rate_card_max_age_seconds": 86400,
}


def economics_row(candidate_id: str, model_key: str, state: str, event: str, *, priced: bool, settlement: bool) -> dict:
    money = 0.013 if priced else None
    return {
        "model_key": model_key, "display_model_id": model_key, "served_model_id": model_key, "action_model_id": candidate_id,
        "is_current": False, "runtime_state": "ready", "economics_state": "permitted" if priced else "blocked",
        "admission": {"state": state, "source": "coordinator", "settlement_capable": settlement,
                      "catalog_economics_permitted": priced, "coordinator_event_id": event, "state_observed_at": NOW},
        "fit": "fits", "estimated_gb": 2.0, "weights_present_locally": True, "ready_provider_count": 1,
        "demand_rank": 3, "demand_weight": 0.2, "supply_deficit_score": 0.1,
        "prompt_rate_usd_per_million_tokens": money, "completion_rate_usd_per_million_tokens": money,
        "provider_prompt_payout_usd_per_million_tokens": money, "provider_completion_payout_usd_per_million_tokens": money,
        "provider_share_bps": 7000 if priced else None, "rate_source": "live_signed" if priced else "none",
        "rate_card_key": model_key if priced else None, "rate_card_version": "v1" if priced else None,
        "rate_card_generated_at": NOW if priced else None, "disabled_reason": None, "warning_codes": [],
        "adopt_recommendation": action(), "cleanup_staging": action(), "evaluate": action(True), "prepare": action(), "switch": action(),
    }


def refusal(status: int, code: str) -> tuple[int, dict]:
    """The coordinator's closed error envelope (modelAdmissionError)."""
    return status, {"error": {"code": code, "message": "model admission decision rejected"}}


class FakeRig:
    """A coordinator state machine plus a CLI facade, faithful to SPEC-047-R001,
    to the dual-control rule (proposer may not approve) and to the operator
    surface's request validation (model_admission_operator.go): reason_code
    grammar, 64-hex event ids, 32-hex pending ids, the closed approval body
    and path, and the exact status + error.code of every refusal. Documents
    are full-shape so the runner's typed validation is exercised, not
    bypassed. `self_approval` and `illegal_transition` let a test make the
    fake answer something other than the real verdict, to prove the runner
    does not accept a look-alike refusal."""

    def __init__(self, *, drift_is_operator_origin: bool = False, ledger_nonzero: str | None = None,
                 self_approval: tuple[int, str] | None = (409, "dual_control_required"),
                 illegal_transition: tuple[int, str] | None = (409, "invalid_transition"),
                 surface_leaks: dict[str, str] | None = None, mutate_on_duplicate_offer: bool = False,
                 skip_stale_head_check: bool = False):
        self.state: dict[str, str] = {}
        self.events: dict[str, int] = {}
        self.reason: dict[str, str] = {}
        self.pending: dict[str, dict] = {}
        self.calls: list[str] = []
        self.drift_is_operator_origin = drift_is_operator_origin
        self.ledger_nonzero = ledger_nonzero
        self.self_approval = self_approval          # None: accept (the bug the runner must catch)
        self.illegal_transition = illegal_transition  # None: accept (the bug the runner must catch)
        self.surface_leaks = surface_leaks or {}
        self.mutate_on_duplicate_offer = mutate_on_duplicate_offer  # append an event while answering 409 (the bug step 2 must catch)
        self.skip_stale_head_check = skip_stale_head_check          # approve against a moved head (the bug step 9 must catch)
        self.gguf_earning = None  # fault-injection override for the GGUF earning; None => faithful state-based earning
        self.request_log = 0

    def _event(self, ref: str) -> str:
        self.events[ref] = self.events.get(ref, 0) + 1
        return self._event_id(ref)

    def _set(self, ref: str, state: str, reason: str = "coordinator") -> str:
        self.state[ref] = state
        self.reason[ref] = reason
        return self._event(ref)

    def _event_id(self, ref: str) -> str:
        return hashlib.sha256(f"{ref}:{self.events.get(ref, 0)}".encode()).hexdigest()

    def _catalog_key(self, ref: str):
        return "tiny-1b" if ref == SETTLEABLE else None

    def _candidate_id(self, ref: str) -> str:
        return candidate_id(ref)

    def _ref_for(self, cid: str):
        for ref in (SETTLEABLE, OPAQUE, GGUF):
            if candidate_id(ref) == cid:
                return ref
        return None

    def _earning(self, ref: str, state: str) -> str:
        if ref == GGUF and self.gguf_earning is not None:
            return self.gguf_earning  # fault injection for the step-10 negative test
        # Mirror modelAdmissionProviderGuidance's earning exactly: withdrawn /
        # revoked / offer_rejected and the default keep no_earning_path;
        # not_offered is local_inventory_only; settlement_capable earns; the rest
        # (offer_submitted, sandbox/network/catalog_priced) are nonSettlement of
        # the catalog key.
        if state in ("withdrawn", "revoked", "offer_rejected"):
            return "no_earning_path_in_v0_1"
        if state == "not_offered":
            return "local_inventory_only"
        if state == "settlement_capable":
            return "settlement_capable"
        return "not_earning_yet_catalog_or_receipt_path_exists" if self._catalog_key(ref) else "no_earning_path_in_v0_1"

    def _status_doc(self, ref: str) -> dict:
        if ref == OPAQUE:
            return {
                "schema": "model_admission_status.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
                "provider_id": PROVIDER_ID, "candidate_id": self._candidate_id(ref), "served_model_ref": ref,
                "catalog_model_key": None, "admission_state": "local_only", "admission_state_source": "local_default",
                "coordinator_event_id": None, "state_observed_at": None,
                "provider_guidance": {
                    "state_label_key": "byom.local.local_only",
                    "state_meaning_key": "byom.local.opaque_endpoint_not_earning",
                    "next_action": "evaluate", "transition_reason_code": None,
                    "earning_path_class": "local_inventory_only"},
                "allowed_next_states": [], "warnings": [],
            }
        if ref not in self.state:
            # Never offered, but the coordinator IS reachable (this fake is one),
            # so `models admission status` returns a COORDINATOR-sourced
            # not_offered: null coordinator event id (no event exists),
            # local_inventory_only, submit_offer, allowed_next_states
            # [offer_submitted]. This is distinct from a SPEC-046 local_default
            # not_offered (coordinator-unavailable), which asserts no offer history.
            g = guidance("not_offered", "local_inventory_only")
            return {
                "schema": "model_admission_status.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
                "provider_id": PROVIDER_ID, "candidate_id": self._candidate_id(ref), "served_model_ref": ref,
                "catalog_model_key": self._catalog_key(ref), "admission_state": "not_offered",
                "admission_state_source": "coordinator", "coordinator_event_id": None, "state_observed_at": NOW,
                "provider_guidance": g,
                "allowed_next_states": list(COORDINATOR_ALLOWED_NEXT_STATES_ORDERED["not_offered"]), "warnings": [],
            }
        state = self.state.get(ref, "not_offered")
        g = guidance(state, self._earning(ref, state))
        # Only a rejection, withdrawal, or revocation carries a reason; every
        # other state the journey reaches is a forward (non-demotion) transition,
        # so the coordinator leaves the reason null.
        g["transition_reason_code"] = self.reason.get(ref) if state in COORDINATOR_STATE_REASON_STATES else None
        return {
            "schema": "model_admission_status.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
            "provider_id": PROVIDER_ID, "candidate_id": self._candidate_id(ref),
            "served_model_ref": ref, "catalog_model_key": self._catalog_key(ref),
            "admission_state": state, "admission_state_source": "coordinator",
            "coordinator_event_id": self._event_id(ref), "state_observed_at": NOW,
            "provider_guidance": g,
            "allowed_next_states": list(COORDINATOR_ALLOWED_NEXT_STATES_ORDERED.get(state, [])),
            "warnings": [],
        }

    def cli_raw(self, args: list[str]) -> tuple[int, str, str]:
        cmd = args[:3]
        if cmd[:2] == ["models", "offer"] and "--dry-run" not in args:
            ref = args[2]
            if ref == OPAQUE:
                self.calls.append("REFUSED opaque offer")
                return 2, "", "BYOM candidate is not offerable; resolve the blocking local readiness, fit, or adapter warning first"
            if self.state.get(ref, "not_offered") not in ("not_offered", "withdrawn", "revoked"):
                self.calls.append("REFUSED duplicate live offer")
                if self.mutate_on_duplicate_offer:
                    self._event(ref)
                return 2, "", "coordinator model admission request failed with HTTP 409"
        try:
            return 0, json.dumps(self.cli(args)), ""
        except AssertionError as exc:
            return 2, "", str(exc)

    def cli(self, args: list[str]) -> dict:
        self.calls.append(" ".join(args[:4]))
        cmd = args[:3]
        if cmd[:2] == ["models", "offer"] and "--dry-run" in args:
            ref = args[2]
            return {"schema": "model_admission_offer_dry_run.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
                    "candidate_id": self._candidate_id(ref), "served_model_ref": ref, "catalog_model_key": self._catalog_key(ref),
                    "would_submit": True, "likely_admission_state": "offerable", "likely_admission_state_source": "local_default",
                    "provider_guidance": {
                        "state_label_key": "byom.offer_dry_run.would_submit",
                        "state_meaning_key": "byom.offer_dry_run.catalog_path_missing_trusted_binding",
                        "next_action": "submit_offer", "transition_reason_code": "catalog_binding_unverified",
                        "earning_path_class": "not_earning_yet_catalog_or_receipt_path_exists"},
                    "reason_code": "catalog_binding_unverified", "warnings": []}
        if cmd[:2] == ["models", "offer"]:
            ref = args[2]
            assert ref != OPAQUE, "fake: opaque offers are refused by the CLI before the coordinator"
            current = self.state.get(ref, "not_offered")
            # SPEC-047 v0.1.9: offer_rejected is reserved; no re-entry from it.
            assert current in ("not_offered", "withdrawn", "revoked"), "fake: duplicate live offer must go through cli_raw"
            assert "offer_submitted" in ADMISSION_ALLOWED_NEXT_STATES.get(current, frozenset({"offer_submitted"})), f"fake: illegal offer from {current}"
            event = self._set(ref, "offer_submitted")
            self._set(ref, "sandbox_probe_only", "synthetic_probe_required")
            return {"schema": "model_admission_offer_submit.v1", "admission_state": "offer_submitted", "admission_state_source": "coordinator", "coordinator_event_id": event}
        if cmd == ["models", "admission", "status"]:
            return self._status_doc(args[3])
        if cmd == ["models", "admission", "withdraw"]:
            ref = args[3]; previous = self.state[ref]
            reason = args[args.index("--reason-code") + 1]
            assert reason in ADMISSION_WITHDRAWAL_REASON_CODES, "fake: the CLI refuses a withdrawal reason outside the closed enum"
            event = self._set(ref, "withdrawn", reason)
            g = guidance("withdrawn", "no_earning_path_in_v0_1")
            g["transition_reason_code"] = reason
            return {"schema": "model_admission_withdraw.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
                    "provider_id": PROVIDER_ID, "candidate_id": self._candidate_id(ref), "served_model_ref": ref,
                    "catalog_model_key": self._catalog_key(ref), "idempotency_key": "k" * 16, "reason_code": reason,
                    "previous_admission_state": previous, "coordinator_event_id": event, "accepted_at": NOW,
                    "resulting_admission_state": "withdrawn",
                    "provider_guidance": g, "warnings": []}
        if cmd[:2] == ["models", "catalog-economics"]:
            state = self.state.get(SETTLEABLE, "not_offered")
            priced = state in ("catalog_priced", "settlement_capable")
            row = economics_row(self._candidate_id(SETTLEABLE), "tiny-1b", state, self._event_id(SETTLEABLE), priced=priced, settlement=state == "settlement_capable")
            return {"schema": "model_catalog_economics.v1", "generated_at": NOW, "projection_sequence": 1, "source": dict(ECONOMICS_SOURCE), "rows": [row], "warnings": []}
        if cmd[:2] == ["models", "discover"]:
            return {"candidates": [{"served_model_ref": SETTLEABLE}, {"served_model_ref": OPAQUE}, {"served_model_ref": GGUF}]}
        raise AssertionError("fake rig: unexpected cli " + " ".join(args))

    def _decision_response(self, ref: str, actor: str, reason: str, pending_id=None) -> dict:
        state = self.state[ref]
        return {"schema": "model_admission_decision.v1", "provider_id": PROVIDER_ID, "candidate_id": self._candidate_id(ref),
                "served_model_ref": ref, "catalog_model_key": self._catalog_key(ref), "previous_admission_state": state,
                "admission_state": state, "reason_code": reason, "coordinator_event_id": self._event_id(ref), "accepted_at": NOW,
                "decided_by": "operator:" + actor, "replayed": False, "pending_decision_id": pending_id, "bound_member": None}

    def admin_post(self, path: str, actor: str, body: dict) -> tuple[int, dict]:
        self.calls.append(f"POST {path} as {actor}")
        if path == aj.DECISIONS_PATH:
            # modelAdmissionDecisionRequest.validate: closed schema, grammars,
            # then the candidate is looked up by (provider_id, candidate_id).
            if (set(body) != {"schema", "provider_id", "candidate_id", "next_state", "reason_code", "expected_coordinator_event_id", "idempotency_key"}
                    or body["schema"] != aj.DECISION_REQUEST_SCHEMA
                    or not aj.PROVIDER_ID.match(body["provider_id"]) or not aj.CANDIDATE_ID.match(body["candidate_id"])
                    or not aj.OPERATOR_REASON_CODE.match(body["reason_code"])
                    or not aj.COORDINATOR_EVENT_ID.match(body["expected_coordinator_event_id"])
                    or not aj.IDEMPOTENCY_KEY.match(body["idempotency_key"])
                    or body["next_state"] not in ("network_visible_unpriced", "network_admitted_unsettled", "catalog_priced", "settlement_capable", "revoked")):
                return refusal(400, "invalid_request")
            ref = self._ref_for(body["candidate_id"])
            if body["provider_id"] != PROVIDER_ID or ref is None or ref not in self.state:
                return refusal(404, "no_offer")
            current = self.state[ref]
            if body["expected_coordinator_event_id"] != self._event_id(ref):
                return refusal(409, "stale_head")
            target = body["next_state"]
            if target not in ADMISSION_ALLOWED_NEXT_STATES.get(current, frozenset()):
                if self.illegal_transition is None:
                    self._set(ref, target, body["reason_code"])
                    return 200, self._decision_response(ref, actor, body["reason_code"])
                return refusal(*self.illegal_transition)
            if target == "settlement_capable":
                pending_id = hashlib.md5(body["idempotency_key"].encode()).hexdigest()
                self.pending[pending_id] = {"by": actor, "head": self._event_id(ref), "reason": body["reason_code"],
                                            "provider_id": body["provider_id"], "candidate_id": body["candidate_id"]}
                return 200, self._decision_response(ref, actor, body["reason_code"], pending_id)
            self._set(ref, target, body["reason_code"])
            return 200, self._decision_response(ref, actor, body["reason_code"])
        if path.startswith(aj.DECISIONS_PATH + "/"):
            # handleAdminModelAdmissionApprove: /<32 hex>/approve, closed body,
            # bound fields equal to the record, then dual control.
            pending_id, _, tail = path[len(aj.DECISIONS_PATH) + 1:].partition("/")
            if tail != "approve" or not aj.PENDING_DECISION_ID.match(pending_id):
                return refusal(400, "invalid_request")
            if (set(body) != {"schema", "provider_id", "candidate_id", "pending_decision_id", "expected_coordinator_event_id", "idempotency_key"}
                    or body["schema"] != aj.APPROVE_REQUEST_SCHEMA or body["pending_decision_id"] != pending_id
                    or not aj.PROVIDER_ID.match(body["provider_id"]) or not aj.CANDIDATE_ID.match(body["candidate_id"])
                    or not aj.COORDINATOR_EVENT_ID.match(body["expected_coordinator_event_id"])
                    or not aj.IDEMPOTENCY_KEY.match(body["idempotency_key"])):
                return refusal(400, "invalid_request")
            record = self.pending.get(pending_id)
            # (a) bound fields must equal the record: provider, candidate, evaluated head.
            if record is not None and (body["provider_id"], body["candidate_id"], body["expected_coordinator_event_id"]) != (record["provider_id"], record["candidate_id"], record["head"]):
                return refusal(400, "invalid_request")
            if record is None:
                return refusal(409, "no_pending_decision")
            # (d) a distinct actor.
            if record["by"] == actor and self.self_approval is not None:
                return refusal(*self.self_approval)
            ref = self._ref_for(record["candidate_id"])
            # (e) the head must still be the evaluated head, else the record dies.
            if self._event_id(ref) != record["head"] and not self.skip_stale_head_check:
                del self.pending[pending_id]
                return refusal(409, "stale_head")
            self._set(ref, "settlement_capable", record["reason"])
            del self.pending[pending_id]
            response = self._decision_response(ref, actor, record["reason"])
            response["bound_member"] = {"source": "mlx_cache", "hash_algorithm": "sha256", "hash": "e" * 64}
            return 200, response
        raise AssertionError("fake rig: unexpected admin path " + path)

    def admin_get(self, path: str, actor: str, query: dict) -> tuple[int, dict]:
        self.calls.append(f"GET {path} as {actor}")
        assert path == aj.OFFERS_PATH and set(query) == {"provider_id"}, "fake: only the offer listing is served"
        return 200, {"schema": "model_admission_offer_list.v1", "generated_at": NOW, "provider_id": query["provider_id"],
                     "candidates": [{"candidate_id": self._candidate_id(r), "admission_state": st, "coordinator_event_id": self._event_id(r)} for r, st in self.state.items()]}

    def surfaces(self) -> dict:
        # CLI calls only; the physical rig records admin routes relative to the
        # origin, and the fake's POST/GET call log is bookkeeping, not a wire record.
        base = {"cli_transcript": "\n".join(c for c in self.calls if c.startswith("models")), "provider_log": "serve: ready\n", "coordinator_log": "admission: ok\n"}
        for name, leak in self.surface_leaks.items():
            base[name] = base.get(name, "") + leak
        return base

    def ledger_counts(self) -> dict:
        counts = {t: 0 for t in aj.MONEY_PATH_TABLES}
        counts["request_log"] = self.request_log
        if self.ledger_nonzero:
            counts[self.ledger_nonzero] = 1
        return counts

    def request_log_marker(self):
        return self.request_log

    def request_log_since(self, marker):
        return self.request_log - marker

    def induce_drift(self):
        reason = "operator_revoke" if self.drift_is_operator_origin else "catalog_artifact_feed_changed"
        self._set(SETTLEABLE, "revoked", reason)


class AdmissionJourneyRunnerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name) / "run"
        os.environ["T_OP_A"] = "secret-a-" + "x" * 32
        os.environ["T_OP_B"] = "secret-b-" + "y" * 32
        os.environ["T_DSN"] = "postgresql://rigreader:pg-pass-" + "z" * 24 + "@127.0.0.1:5432/rig?sslmode=disable"
        self.provider_log = Path(self.tmp.name) / "provider.log"
        self.coordinator_log = Path(self.tmp.name) / "coordinator.log"
        self.provider_log.write_text("older provider line\n")
        self.coordinator_log.write_text("older coordinator line\n")
        self.config = aj.RigConfig(
            cli_binary=Path("/usr/bin/true"), provider_config=Path(self.tmp.name) / "config.yaml",
            coordinator_admin_origin="http://127.0.0.1:18444", operator_actor_a="rig_a", operator_actor_b="rig_b",
            operator_secret_a_env="T_OP_A", operator_secret_b_env="T_OP_B", postgres_dsn_env="T_DSN",
            settleable_ref=SETTLEABLE, opaque_ref=OPAQUE, gguf_ref=GGUF,
            provider_log=self.provider_log, coordinator_log=self.coordinator_log, drift_hook=None,
        )
        self.config.provider_config.write_text("coordinator_url: ws://127.0.0.1:18444\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_journey(self, rig: FakeRig) -> Path:
        if self.out.exists():
            self.tmp_reset()
        aj.prepare_out_dir(self.out)
        manifest = aj.ManifestBuilder(self.out, "run-test", CLI_VERSION)
        runner = aj.AdmissionJourneyRunner(rig, self.config, manifest, log=lambda _: None)
        return runner.run(lambda: "transcript without secrets")

    def test_all_twelve_steps_pass_and_the_manifest_is_capturable(self):
        rig = FakeRig()
        path = self.run_journey(rig)
        manifest = json.loads(path.read_text())
        self.assertEqual(manifest["journey_id"], ADMISSION_CONTRACT.journey_id)
        self.assertEqual(manifest["harness"]["name"], ADMISSION_CONTRACT.expected_harness_name)
        self.assertEqual(manifest["environment_class"], "physical-provider")
        self.assertEqual([s["id"] for s in manifest["steps"]], list(ADMISSION_CONTRACT.step_id_order))
        for name in ADMISSION_CONTRACT.true_observations:
            self.assertIs(manifest["observations"][name], True, name)
        for name in ADMISSION_CONTRACT.false_observations:
            self.assertIs(manifest["observations"][name], False, name)
        self.assertEqual(manifest["observations"]["money_path_zero_rows"], {t: 0 for t in ADMISSION_CONTRACT.money_path_tables})
        # Every step's documents exist on disk and are user-private.
        for step in manifest["steps"]:
            for doc in step["documents"]:
                file = self.out / doc["path"]
                self.assertTrue(file.is_file(), doc["path"])
                self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        # Dual control happened on the real route: proposal by A, refused
        # self-approval, approval by B, all at /decisions/<id>/approve.
        posts = [c for c in rig.calls if c.startswith("POST")]
        self.assertIn(f"POST {aj.DECISIONS_PATH} as rig_a", posts)
        approvals = [c for c in posts if "/approve as " in c]
        self.assertEqual([c.rsplit(" ", 1)[1] for c in approvals], ["rig_a", "rig_b"])
        # Step 12 reviewed the coordinator's own event listing.
        self.assertIn(f"GET {aj.OFFERS_PATH} as rig_a", rig.calls)
        # The capture tool's own contract accepts it end to end (no signing).
        head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=str(ROOT), capture_output=True, text=True, check=True).stdout.strip()
        evidence = build_evidence(
            ROOT, ADMISSION_CONTRACT, path,
            source_sha=head, operator_role="release-operator", operator_identity_fingerprint="a" * 64,
            hardware_profile="m2-16gb", candidate="test-candidate", captured_at=NOW, expires_at=None, summary="fake rig run",
        )
        self.assertEqual(evidence["journey_id"], ADMISSION_CONTRACT.journey_id)
        self.assertEqual(len(evidence["steps"]), 12)

    def test_proposer_self_approval_being_accepted_fails_the_run(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(self_approval=None))
        self.assertIn("dual control not enforced", str(caught.exception))
        self.assertFalse((self.out / "run-manifest.json").exists())

    def test_self_approval_refused_with_a_different_4xx_does_not_prove_dual_control(self):
        # A 400 invalid_request (a malformed approval body), a 401 or a 404
        # would all have satisfied `code >= 400`; only 409 dual_control_required
        # is the coordinator saying "same actor".
        for status, code in ((400, "invalid_request"), (401, "invalid_operator_token"), (409, "no_pending_decision")):
            with self.subTest(code=code):
                with self.assertRaises(aj.JourneyFailure) as caught:
                    self.run_journey(FakeRig(self_approval=(status, code)))
                self.assertIn("not refused with 409 dual_control_required", str(caught.exception))
                self.assertIn(code, str(caught.exception))

    def test_operator_origin_revocation_is_not_drift(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(drift_is_operator_origin=True))
        self.assertIn("not a SPEC-047-R006 drift reason", str(caught.exception))

    def test_illegal_transition_being_accepted_fails_the_run(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(illegal_transition=None))
        self.assertIn("not refused with 409 invalid_transition", str(caught.exception))

    def test_illegal_transition_refused_for_another_reason_does_not_prove_the_matrix(self):
        # stale_head and invalid_request are refusals too, but they say nothing
        # about the edge; transition_matrix_enforced must not be set on them.
        for status, code in ((409, "stale_head"), (400, "invalid_request")):
            with self.subTest(code=code):
                with self.assertRaises(aj.JourneyFailure) as caught:
                    self.run_journey(FakeRig(illegal_transition=(status, code)))
                self.assertIn("not refused with 409 invalid_transition", str(caught.exception))
                self.assertIn(code, str(caught.exception))
                self.assertFalse((self.out / "run-manifest.json").exists())

    def test_operator_reason_codes_are_inside_the_coordinator_grammar(self):
        # The four reasons the journey sends, and the runner's own guard: a
        # reason outside ^operator_[a-z0-9_]{2,56}$ is refused before the wire,
        # so it can never be mistaken for a coordinator verdict.
        for reason in (aj.REASON_EXPERIMENTAL_DISCLOSURE, aj.REASON_CATALOG_BINDING_VERIFIED, aj.REASON_DUAL_CONTROL_SETTLEMENT, aj.REASON_MATRIX_PROBE):
            self.assertRegex(reason, r"^operator_[a-z0-9_]{2,56}$")
        rig = FakeRig()
        rig._set(SETTLEABLE, "sandbox_probe_only")  # coordinator-backed: an unoffered candidate has only a local_default status
        runner = aj.AdmissionJourneyRunner(rig, self.config, aj.ManifestBuilder(self.out, "r", CLI_VERSION), log=lambda _: None)
        runner.status(runner.settleable)
        with self.assertRaises(aj.JourneyFailure) as caught:
            runner.decide("rig_a", runner.settleable, "network_visible_unpriced", "matrix_probe")
        self.assertIn("outside the coordinator grammar", str(caught.exception))
        self.assertFalse(any(c.startswith("POST") for c in rig.calls))
        # And the fake, like the coordinator, answers 400 invalid_request to one.
        body = {"schema": aj.DECISION_REQUEST_SCHEMA, "provider_id": "p", "candidate_id": "c", "next_state": "network_visible_unpriced",
                "reason_code": "matrix_probe", "expected_coordinator_event_id": "0" * 64, "idempotency_key": "k"}
        self.assertEqual(rig.admin_post(aj.DECISIONS_PATH, "rig_a", body), refusal(400, "invalid_request"))

    def test_approval_body_and_route_match_the_coordinator(self):
        # The pre-fix shape (no expected_coordinator_event_id, no
        # idempotency_key, posted to /decisions/<id>) is 400 invalid_request
        # on the coordinator; the runner's approve() sends the closed body to
        # /decisions/<id>/approve and is accepted.
        rig = FakeRig()
        rig._set(SETTLEABLE, "catalog_priced")
        runner = aj.AdmissionJourneyRunner(rig, self.config, aj.ManifestBuilder(self.out, "r", CLI_VERSION), log=lambda _: None)
        runner.status(runner.settleable)
        code, proposed = runner.decide("rig_a", runner.settleable, "settlement_capable", aj.REASON_DUAL_CONTROL_SETTLEMENT)
        self.assertEqual(code, 200)
        pending_id, head = proposed["pending_decision_id"], proposed["coordinator_event_id"]
        old_shape = {"schema": aj.APPROVE_REQUEST_SCHEMA, "provider_id": runner.settleable.provider_id,
                     "candidate_id": runner.settleable.candidate_id, "pending_decision_id": pending_id}
        self.assertEqual(rig.admin_post(aj.DECISIONS_PATH + "/" + pending_id, "rig_b", old_shape), refusal(400, "invalid_request"))
        self.assertEqual(rig.admin_post(aj.DECISIONS_PATH + "/" + pending_id + "/approve", "rig_b", old_shape), refusal(400, "invalid_request"))
        code, approved = runner.approve("rig_b", runner.settleable, pending_id, head)
        self.assertEqual((code, approved["admission_state"]), (200, "settlement_capable"))
        self.assertIn(f"POST {aj.DECISIONS_PATH}/{pending_id}/approve as rig_b", rig.calls)

    def test_withdrawal_reason_is_the_closed_spec_047_enum(self):
        rig = FakeRig()
        rig._set(SETTLEABLE, "catalog_priced")
        document = rig.cli(["models", "admission", "withdraw", SETTLEABLE, "--reason-code", aj.WITHDRAWAL_REASON, "--json"])
        validate_captured_cli_document("model_admission_withdraw.v1", document, "withdraw")
        document["reason_code"] = "operator_withdrawal"
        with self.assertRaises(BYOMEvidenceError) as caught:
            validate_captured_cli_document("model_admission_withdraw.v1", document, "withdraw")
        self.assertIn("reason_code is not a permitted value: 'operator_withdrawal'", str(caught.exception))
        with self.assertRaises(AssertionError):
            rig.cli(["models", "admission", "withdraw", SETTLEABLE, "--reason-code", "operator_withdrawal", "--json"])

    def test_step_10_requires_the_gguf_candidate_to_have_no_earning_path(self):
        rig = FakeRig()
        rig.gguf_earning = "local_inventory_only"
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(rig)
        self.assertIn("not no_earning_path_in_v0_1", str(caught.exception))
        with self.assertRaises(aj.JourneyFailure) as caught:
            aj.RigConfig(**{**self.config.__dict__, "gguf_ref": None}).validate()
        self.assertIn("none is optional", str(caught.exception))
        self.assertIn("--gguf-ref", aj.build_parser().format_help())
        with self.assertRaises(SystemExit), open(os.devnull, "w") as sink, contextlib.redirect_stderr(sink):
            aj.build_parser().parse_args(["--out", "x", "--cli-binary", "x", "--provider-config", "x", "--coordinator-admin-origin", "x",
                                          "--operator-actor-a", "a", "--operator-actor-b", "b", "--settleable-ref", "s", "--opaque-ref", "o",
                                          "--provider-log", "x", "--coordinator-log", "x"])

    def test_redaction_review_covers_every_surface(self):
        # A leak in any one surface fails step 12 and publishes nothing; the
        # failure names the category and the surface, never the value.
        secret = os.environ["T_OP_B"]
        password = aj.PhysicalRig.libpq_parameters(os.environ["T_DSN"])["password"]
        cases = [
            ({"coordinator_log": "bearer accepted for " + secret}, "operator secret found in surface coordinator_log"),
            ({"provider_log": "connected with " + password}, "ledger password found in surface provider_log"),
            ({"cli_transcript": os.environ["T_DSN"]}, "ledger dsn found in surface cli_transcript"),
            ({"coordinator_log": 'probe request {"messages":[{"role":"user","content":"' + aj.SYNTHETIC_PROBE_PROMPT + '"}]}'}, "a raw prompt"),
            ({"provider_log": 'sent {"choices":[{"message":{"role":"assistant","content":"ok"}}]}'}, "a raw completion"),
            ({"coordinator_log": "-----BEGIN PRIVATE KEY-----"}, "surface coordinator_log contains a credential-like value"),
        ]
        for leaks, message in cases:
            with self.subTest(message=message):
                with self.assertRaises(aj.JourneyFailure) as caught:
                    self.run_journey(FakeRig(surface_leaks=leaks))
                self.assertIn(message, str(caught.exception))
                self.assertNotIn(secret, str(caught.exception))
                self.assertNotIn(password, str(caught.exception))
                self.assertFalse((self.out / "run-manifest.json").exists())

    def tmp_reset(self):
        for child in sorted(self.out.rglob("*"), reverse=True):
            child.unlink() if child.is_file() else child.rmdir()
        self.out.rmdir()

    def test_fake_ids_are_production_shaped_and_the_runner_pins_the_grammar(self):
        rig = FakeRig()
        for ref in (SETTLEABLE, OPAQUE, GGUF):
            self.assertRegex(rig._candidate_id(ref), r"^byom_[a-z2-7]{52}$")
        self.assertRegex(PROVIDER_ID, r"^[a-zA-Z0-9_.-]{1,64}$")
        # A status document whose candidate_id is not a stable byom_ id (an
        # unprovisioned namespace) fails the run before any decision is made.
        rig._candidate_id = lambda ref: "byom_unstable_" + "a" * 40
        runner = aj.AdmissionJourneyRunner(rig, self.config, aj.ManifestBuilder(self.out, "r", CLI_VERSION), log=lambda _: None)
        with self.assertRaises(aj.JourneyFailure) as caught:
            runner.status(runner.settleable)
        self.assertIn("not a stable byom_ id", str(caught.exception))

    def test_fake_validates_and_routes_by_provider_and_candidate(self):
        # model_admission_operator.go: provider/candidate grammar is checked
        # before any transition (400 invalid_request); an unknown pair is 404
        # no_offer; an approval whose bound fields differ from the pending
        # record is 400 invalid_request.
        rig = FakeRig()
        rig._set(SETTLEABLE, "catalog_priced")
        head = rig._event_id(SETTLEABLE)
        good = {"schema": aj.DECISION_REQUEST_SCHEMA, "provider_id": PROVIDER_ID, "candidate_id": candidate_id(SETTLEABLE),
                "next_state": "settlement_capable", "reason_code": aj.REASON_DUAL_CONTROL_SETTLEMENT,
                "expected_coordinator_event_id": head, "idempotency_key": "k1"}
        self.assertEqual(rig.admin_post(aj.DECISIONS_PATH, "rig_a", {**good, "candidate_id": "c"}), refusal(400, "invalid_request"))
        self.assertEqual(rig.admin_post(aj.DECISIONS_PATH, "rig_a", {**good, "provider_id": "bad provider"}), refusal(400, "invalid_request"))
        self.assertEqual(rig.admin_post(aj.DECISIONS_PATH, "rig_a", {**good, "provider_id": "mp-other"}), refusal(404, "no_offer"))
        self.assertEqual(rig.admin_post(aj.DECISIONS_PATH, "rig_a", {**good, "candidate_id": candidate_id(GGUF)}), refusal(404, "no_offer"))
        code, proposed = rig.admin_post(aj.DECISIONS_PATH, "rig_a", good)
        self.assertEqual(code, 200)
        pending_id = proposed["pending_decision_id"]
        approve = {"schema": aj.APPROVE_REQUEST_SCHEMA, "provider_id": PROVIDER_ID, "candidate_id": candidate_id(SETTLEABLE),
                   "pending_decision_id": pending_id, "expected_coordinator_event_id": head, "idempotency_key": "k2"}
        route = f"{aj.DECISIONS_PATH}/{pending_id}/approve"
        self.assertEqual(rig.admin_post(route, "rig_b", {**approve, "candidate_id": candidate_id(GGUF)}), refusal(400, "invalid_request"))
        self.assertEqual(rig.admin_post(route, "rig_b", {**approve, "provider_id": "mp-other"}), refusal(400, "invalid_request"))
        self.assertEqual(rig.admin_post(route, "rig_b", approve)[0], 200)

    def test_approval_after_an_intervening_event_is_stale_head_and_the_run_fails(self):
        # The pending record was evaluated against one head; if the candidate
        # moved in between, the real coordinator answers 409 stale_head and
        # invalidates the record. The fake does the same, and a fake that
        # grants anyway (the pre-fix behaviour) is caught by the runner.
        rig = FakeRig()
        rig._set(SETTLEABLE, "catalog_priced")
        runner = aj.AdmissionJourneyRunner(rig, self.config, aj.ManifestBuilder(self.out, "r", CLI_VERSION), log=lambda _: None)
        runner.status(runner.settleable)
        code, proposed = runner.decide("rig_a", runner.settleable, "settlement_capable", aj.REASON_DUAL_CONTROL_SETTLEMENT)
        self.assertEqual(code, 200)
        pending_id, head = proposed["pending_decision_id"], proposed["coordinator_event_id"]
        rig._set(SETTLEABLE, "catalog_priced", "intervening")  # a new event on the same state
        code, body = runner.approve("rig_b", runner.settleable, pending_id, head)
        self.assertEqual((code, body["error"]["code"]), (409, "stale_head"))
        self.assertNotIn(pending_id, rig.pending)
        self.assertNotEqual(rig.state[SETTLEABLE], "settlement_capable")

    def test_step_2_requires_the_head_to_be_unchanged_by_the_refused_duplicate(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(mutate_on_duplicate_offer=True))
        self.assertIn("refused duplicate offer appended a coordinator event", str(caught.exception))
        self.assertFalse((self.out / "run-manifest.json").exists())

    def test_redaction_review_rejects_urls_paths_ips_and_localhost_in_any_surface(self):
        cases = [
            ({"cli_transcript": "--config /Users/rig/.config/macprovider/config.yaml"}, "an absolute path"),
            ({"provider_log": "cache at ~/.cache/huggingface"}, "a home-relative path"),
            ({"coordinator_log": "admin origin http://127.0.0.1:18444/admin"}, "a url"),
            ({"coordinator_log": "peer 10.0.0.7 connected"}, "an ipv4 literal"),
            ({"provider_log": "listening on localhost"}, "a localhost reference"),
        ]
        for leaks, label in cases:
            with self.subTest(label=label):
                with self.assertRaises(aj.JourneyFailure) as caught:
                    self.run_journey(FakeRig(surface_leaks=leaks))
                self.assertIn(label, str(caught.exception))
                self.assertIn("surface " + next(iter(leaks)), str(caught.exception))

    def test_physical_rig_transcript_redacts_path_arguments(self):
        self.assertEqual(aj.redact_argument("/Users/rig/config.yaml"), "<path>")
        self.assertEqual(aj.redact_argument("~/models"), "<path>")
        self.assertEqual(aj.redact_argument("--config"), "--config")
        self.assertEqual(aj.redact_argument("mlx-community/Llama-3.2-3B-Instruct-4bit"), "mlx-community/Llama-3.2-3B-Instruct-4bit")
        rig = aj.PhysicalRig(self.config)
        rig.cli_raw(["models", "discover", "--json", "--config", str(self.config.provider_config)])
        transcript = rig.surfaces()["cli_transcript"]
        self.assertNotIn(str(self.config.provider_config), transcript)
        self.assertIn("--config <path>", transcript)
        # Admin exchanges are recorded as origin-relative routes, which the
        # path scanner accepts.
        rig._transcript.append("POST admin/model-admission/decisions as rig_a -> 200\n{}")
        aj.evidence_contract.reject_unredacted_text_except_hostname(rig.surfaces()["cli_transcript"], "transcript")

    def test_child_environment_drops_secrets_and_pg_for_every_subprocess(self):
        os.environ["PGPASSWORD"] = "leak"
        os.environ["MACPROVIDER_HOME"] = "keep"
        try:
            env = self.config.child_environment()
            for name in ("T_OP_A", "T_OP_B", "T_DSN", "PGPASSWORD"):
                self.assertNotIn(name, env)
            self.assertEqual(env["MACPROVIDER_HOME"], "keep")
            psql = self.config.child_environment(psql_service_file=Path("/x/pg_service.conf"))
            self.assertEqual({k for k in psql if k.startswith("PG")}, {"PGSERVICEFILE", "PGSERVICE"})
            self.assertNotIn("MACPROVIDER_HOME", psql)
            self.assertTrue(set(psql) - {"PGSERVICEFILE", "PGSERVICE"} <= self.config.PSQL_ENVIRONMENT_ALLOWLIST | {k for k in psql if k.startswith("LC_")})
        finally:
            del os.environ["PGPASSWORD"], os.environ["MACPROVIDER_HOME"]
        # cli_raw and induce_drift pass the scrubbed environment too.
        seen = []
        original = aj.subprocess.run

        def fake_run(argv, **kwargs):
            seen.append(kwargs.get("env"))
            return subprocess.CompletedProcess(argv, 0, "{}", "")
        aj.subprocess.run = fake_run
        try:
            hook = Path(self.tmp.name) / "drift.sh"
            hook.write_text("#!/bin/sh\n"); hook.chmod(0o700)
            rig = aj.PhysicalRig(self.config.__class__(**{**self.config.__dict__, "drift_hook": hook}))
            rig.cli_raw(["models", "discover", "--json"])
            rig.induce_drift()
        finally:
            aj.subprocess.run = original
        self.assertEqual(len(seen), 2)
        for env in seen:
            self.assertIsNotNone(env)
            for name in ("T_OP_A", "T_OP_B", "T_DSN"):
                self.assertNotIn(name, env)

    def test_physical_rig_reviews_only_what_the_run_appended_to_the_logs(self):
        rig = aj.PhysicalRig(self.config)
        with self.provider_log.open("a") as handle:
            handle.write("run provider line\n")
        with self.coordinator_log.open("a") as handle:
            handle.write("run coordinator line\n")
        surfaces = rig.surfaces()
        self.assertEqual(surfaces["provider_log"], "run provider line\n")
        self.assertEqual(surfaces["coordinator_log"], "run coordinator line\n")
        self.assertEqual(set(surfaces) | {"runner_log", "captured_documents", "coordinator_events"}, set(aj.REDACTION_SURFACES))

    def test_ledger_dsn_never_reaches_psql_argv(self):
        dsn = os.environ["T_DSN"]
        seen = {}

        def fake_run(argv, **kwargs):
            seen["argv"] = list(argv)
            env = kwargs["env"]
            seen["env_pg"] = {k: v for k, v in env.items() if k.startswith("PG")}
            seen["env_all"] = dict(env)
            service = Path(env["PGSERVICEFILE"])
            seen["mode"] = service.stat().st_mode & 0o777
            seen["dir_mode"] = service.parent.stat().st_mode & 0o777
            seen["service"] = service.read_text()
            rows = "\n".join(f"{t}\t0" for t in aj.MONEY_PATH_TABLES)
            return subprocess.CompletedProcess(argv, 0, rows + "\n", "")

        original = aj.subprocess.run
        aj.subprocess.run = fake_run
        try:
            counts = aj.PhysicalRig(self.config).ledger_counts()
        finally:
            aj.subprocess.run = original
        self.assertEqual(counts, {t: 0 for t in aj.MONEY_PATH_TABLES})
        self.assertEqual(seen["argv"][0], "psql")
        self.assertFalse(any(dsn in a or "pg-pass-" in a or "rigreader" in a or "127.0.0.1" in a for a in seen["argv"]), seen["argv"])
        self.assertEqual(set(seen["env_pg"]), {"PGSERVICEFILE", "PGSERVICE"})
        for name in ("T_OP_A", "T_OP_B", "T_DSN"):
            self.assertNotIn(name, seen["env_all"])
        self.assertEqual((seen["mode"], seen["dir_mode"]), (0o600, 0o700))
        self.assertIn("password=pg-pass-", seen["service"])
        self.assertIn("sslmode=disable", seen["service"])
        self.assertFalse(Path(seen["env_pg"]["PGSERVICEFILE"]).exists(), "service file must not outlive the read")

    def test_libpq_parameters_accept_both_dsn_forms_and_fail_closed_on_unknown_keys(self):
        uri = aj.PhysicalRig.libpq_parameters("postgresql://u:p%40ss@127.0.0.1:5433/db?sslmode=require&connect_timeout=5")
        self.assertEqual(uri, {"host": "127.0.0.1", "port": "5433", "user": "u", "password": "p@ss", "dbname": "db", "sslmode": "require", "connect_timeout": "5"})
        kv = aj.PhysicalRig.libpq_parameters("host=/tmp/sock dbname=db user=u password='p s'")
        self.assertEqual(kv, {"host": "/tmp/sock", "dbname": "db", "user": "u", "password": "p s"})
        with self.assertRaises(aj.JourneyFailure) as caught:
            aj.PhysicalRig.libpq_parameters("postgresql://u@127.0.0.1/db?options=-csearch_path%3Dpublic")
        self.assertIn("does not pass through: options", str(caught.exception))
        with self.assertRaises(aj.JourneyFailure):
            aj.PhysicalRig.libpq_parameters("just-a-word")

    def test_nonzero_money_ledger_publishes_no_manifest(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(ledger_nonzero="ledger_operator_credits"))
        self.assertIn("money-path tables are not all zero", str(caught.exception))
        self.assertFalse((self.out / "run-manifest.json").exists())

    def test_secret_in_runner_log_fails_redaction_review(self):
        rig = FakeRig()
        aj.prepare_out_dir(self.out)
        runner = aj.AdmissionJourneyRunner(rig, self.config, aj.ManifestBuilder(self.out, "r", CLI_VERSION), log=lambda _: None)
        with self.assertRaises(aj.JourneyFailure) as caught:
            runner.run(lambda: "log line containing " + os.environ["T_OP_B"])
        self.assertIn("operator secret found in surface runner_log", str(caught.exception))
        self.assertNotIn(os.environ["T_OP_B"], str(caught.exception))

    def test_rig_config_refuses_non_loopback_shared_secret_and_same_actor(self):
        bad = self.config.__class__(**{**self.config.__dict__, "coordinator_admin_origin": "http://10.0.0.5:18444"})
        with self.assertRaises(aj.JourneyFailure):
            bad.validate()
        os.environ["T_OP_B"] = os.environ["T_OP_A"]
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.config.validate()
        self.assertIn("share one secret", str(caught.exception))
        os.environ["T_OP_B"] = "secret-b-" + "y" * 32
        same = self.config.__class__(**{**self.config.__dict__, "operator_actor_b": "rig_a"})
        with self.assertRaises(aj.JourneyFailure):
            same.validate()

    def test_physical_rig_fails_closed_without_the_drift_hook(self):
        # Drift is the one induction the coordinator cannot perform on its
        # own; it is an operator-supplied hook, and its absence must name the
        # gap, never set an observation without measurement.
        rig = aj.PhysicalRig(self.config)
        with self.assertRaises(aj.JourneyFailure) as drift:
            rig.induce_drift()
        self.assertIn("--drift-hook", str(drift.exception))

    def test_out_dir_must_be_empty(self):
        self.out.mkdir(parents=True)
        (self.out / "run-manifest.json").write_text("{}")
        with self.assertRaises(aj.JourneyFailure):
            aj.prepare_out_dir(self.out)


if __name__ == "__main__":
    unittest.main()
