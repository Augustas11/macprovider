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
    build_evidence,
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


def guidance(state: str, earning: str) -> dict:
    return {
        "state_label_key": f"byom.admission.{state}.label",
        "state_meaning_key": f"byom.admission.{state}.meaning",
        "next_action": "check_status",
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


class FakeRig:
    """A coordinator state machine plus a CLI facade, faithful to SPEC-047-R001
    and to the dual-control rule (proposer may not approve). Documents are
    full-shape so the runner's typed validation is exercised, not bypassed."""

    def __init__(self, *, drift_is_operator_origin: bool = False, ledger_nonzero: str | None = None,
                 allow_self_approval: bool = False, allow_illegal_transition: bool = False):
        self.state: dict[str, str] = {}
        self.events: dict[str, int] = {}
        self.reason: dict[str, str] = {}
        self.pending: dict[str, dict] = {}
        self.calls: list[str] = []
        self.drift_is_operator_origin = drift_is_operator_origin
        self.ledger_nonzero = ledger_nonzero
        self.allow_self_approval = allow_self_approval
        self.allow_illegal_transition = allow_illegal_transition
        self.request_log = 0

    def _event(self, ref: str) -> str:
        self.events[ref] = self.events.get(ref, 0) + 1
        return f"evt-{self.events[ref]:04d}"

    def _set(self, ref: str, state: str, reason: str = "coordinator") -> str:
        self.state[ref] = state
        self.reason[ref] = reason
        return self._event(ref)

    def _event_id(self, ref: str) -> str:
        return f"evt-{self.events.get(ref, 0):04d}"

    def _catalog_key(self, ref: str):
        return "tiny-1b" if ref == SETTLEABLE else None

    def _candidate_id(self, ref: str) -> str:
        return "byom_" + "".join(c if c.isalnum() else "x" for c in ref)[:20]

    def _earning(self, ref: str) -> str:
        if ref == OPAQUE:
            return "local_inventory_only"
        if ref == GGUF:
            return "no_earning_path_in_v0_1"
        return "settlement_capable" if self.state.get(ref) == "settlement_capable" else "not_earning_yet_catalog_or_receipt_path_exists"

    def _status_doc(self, ref: str) -> dict:
        if ref == OPAQUE:
            return {
                "schema": "model_admission_status.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
                "provider_id": "mp-" + "a" * 32, "candidate_id": self._candidate_id(ref), "served_model_ref": ref,
                "catalog_model_key": None, "admission_state": "local_only", "admission_state_source": "local_default",
                "coordinator_event_id": None, "state_observed_at": None,
                "provider_guidance": guidance("local_only", "local_inventory_only"), "allowed_next_states": [], "warnings": [],
            }
        state = self.state.get(ref, "not_offered")
        g = guidance(state, self._earning(ref))
        g["transition_reason_code"] = self.reason.get(ref)
        return {
            "schema": "model_admission_status.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
            "provider_id": "mp-" + "a" * 32, "candidate_id": self._candidate_id(ref),
            "served_model_ref": ref, "catalog_model_key": self._catalog_key(ref),
            "admission_state": state, "admission_state_source": "coordinator",
            "coordinator_event_id": self._event_id(ref), "state_observed_at": NOW,
            "provider_guidance": g,
            "allowed_next_states": sorted(ADMISSION_ALLOWED_NEXT_STATES.get(state, frozenset())),
            "warnings": [],
        }

    def cli_raw(self, args: list[str]) -> tuple[int, str, str]:
        cmd = args[:3]
        if cmd[:2] == ["models", "offer"] and "--dry-run" not in args:
            ref = args[2]
            if ref == OPAQUE:
                self.calls.append("REFUSED opaque offer")
                return 2, "", "BYOM candidate is not offerable; resolve the blocking local readiness, fit, or adapter warning first"
            if self.state.get(ref, "not_offered") not in ("not_offered", "withdrawn", "revoked", "offer_rejected"):
                self.calls.append("REFUSED duplicate live offer")
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
                    "provider_guidance": guidance("offerable", "not_earning_yet_catalog_or_receipt_path_exists"),
                    "reason_code": "no_trusted_catalog_match", "warnings": []}
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
            event = self._set(ref, "withdrawn", "operator_withdrawal")
            return {"schema": "model_admission_withdraw.v1", "generated_at": NOW, "cli_version": CLI_VERSION,
                    "provider_id": "mp-" + "a" * 32, "candidate_id": self._candidate_id(ref), "served_model_ref": ref,
                    "catalog_model_key": self._catalog_key(ref), "idempotency_key": "k" * 16, "reason_code": "operator_withdrawal",
                    "previous_admission_state": previous, "coordinator_event_id": event, "accepted_at": NOW,
                    "resulting_admission_state": "withdrawn",
                    "provider_guidance": guidance("withdrawn", "not_earning_yet_catalog_or_receipt_path_exists"), "warnings": []}
        if cmd[:2] == ["models", "catalog-economics"]:
            state = self.state.get(SETTLEABLE, "not_offered")
            priced = state in ("catalog_priced", "settlement_capable")
            row = economics_row(self._candidate_id(SETTLEABLE), "tiny-1b", state, self._event_id(SETTLEABLE), priced=priced, settlement=state == "settlement_capable")
            return {"schema": "model_catalog_economics.v1", "generated_at": NOW, "projection_sequence": 1, "source": dict(ECONOMICS_SOURCE), "rows": [row], "warnings": []}
        if cmd[:2] == ["models", "discover"]:
            return {"candidates": [{"served_model_ref": SETTLEABLE}, {"served_model_ref": OPAQUE}, {"served_model_ref": GGUF}]}
        raise AssertionError("fake rig: unexpected cli " + " ".join(args))

    def admin_post(self, path: str, actor: str, body: dict) -> tuple[int, dict]:
        self.calls.append(f"POST {path} as {actor}")
        ref = SETTLEABLE
        if path == aj.DECISIONS_PATH:
            current = self.state.get(ref, "not_offered")
            target = body["next_state"]
            if target not in ADMISSION_ALLOWED_NEXT_STATES.get(current, frozenset()) and not self.allow_illegal_transition:
                return 409, {"error": "transition_not_allowed"}
            if target == "settlement_capable":
                pending_id = "pend-" + body["idempotency_key"][:8]
                self.pending[pending_id] = {"by": actor}
                return 202, {"pending_decision_id": pending_id, "admission_state": current}
            event = self._set(ref, target, body["reason_code"])
            return 200, {"admission_state": target, "coordinator_event_id": event}
        if path.startswith(aj.DECISIONS_PATH + "/"):
            pending_id = path.rsplit("/", 1)[1]
            record = self.pending.get(pending_id)
            if record is None:
                return 404, {"error": "no_pending"}
            if record["by"] == actor and not self.allow_self_approval:
                return 403, {"error": "same_actor"}
            event = self._set(ref, "settlement_capable", "dual_control_settlement")
            del self.pending[pending_id]
            return 200, {"admission_state": "settlement_capable", "coordinator_event_id": event, "bound_member": "mlx-4bit", "artifact_id": "mlx-4bit"}
        raise AssertionError("fake rig: unexpected admin path " + path)

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
        os.environ["T_DSN"] = "postgres://ledger@127.0.0.1:5432/rig"
        self.config = aj.RigConfig(
            cli_binary=Path("/usr/bin/true"), provider_config=Path(self.tmp.name) / "config.yaml",
            coordinator_admin_origin="http://127.0.0.1:18444", operator_actor_a="rig_a", operator_actor_b="rig_b",
            operator_secret_a_env="T_OP_A", operator_secret_b_env="T_OP_B", postgres_dsn_env="T_DSN",
            settleable_ref=SETTLEABLE, opaque_ref=OPAQUE, gguf_ref=GGUF, drift_hook=None,
        )
        self.config.provider_config.write_text("coordinator_url: ws://127.0.0.1:18444\n")

    def tearDown(self):
        self.tmp.cleanup()

    def run_journey(self, rig: FakeRig) -> Path:
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
        # Dual control happened: proposal by A, refused self-approval, approval by B.
        posts = [c for c in rig.calls if c.startswith("POST")]
        self.assertIn(f"POST {aj.DECISIONS_PATH} as rig_a", posts)
        self.assertTrue(any(c.startswith(f"POST {aj.DECISIONS_PATH}/pend-") and c.endswith("as rig_a") for c in posts))
        self.assertTrue(any(c.startswith(f"POST {aj.DECISIONS_PATH}/pend-") and c.endswith("as rig_b") for c in posts))
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
            self.run_journey(FakeRig(allow_self_approval=True))
        self.assertIn("dual control not enforced", str(caught.exception))
        self.assertFalse((self.out / "run-manifest.json").exists())

    def test_operator_origin_revocation_is_not_drift(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(drift_is_operator_origin=True))
        self.assertIn("not a SPEC-047-R006 drift reason", str(caught.exception))

    def test_illegal_transition_being_accepted_fails_the_run(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(allow_illegal_transition=True))
        self.assertIn("was accepted", str(caught.exception))

    def test_nonzero_money_ledger_publishes_no_manifest(self):
        with self.assertRaises(aj.JourneyFailure) as caught:
            self.run_journey(FakeRig(ledger_nonzero="ledger_operator_credits"))
        self.assertIn("money-path tables are not all zero", str(caught.exception))
        self.assertFalse((self.out / "run-manifest.json").exists())

    def test_secret_in_transcript_fails_redaction_review(self):
        rig = FakeRig()
        aj.prepare_out_dir(self.out)
        runner = aj.AdmissionJourneyRunner(rig, self.config, aj.ManifestBuilder(self.out, "r", CLI_VERSION), log=lambda _: None)
        with self.assertRaises(aj.JourneyFailure) as caught:
            runner.run(lambda: "log line containing " + os.environ["T_OP_B"])
        self.assertIn("operator secret", str(caught.exception))

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
