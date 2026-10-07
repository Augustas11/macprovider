import json
import sqlite3
import tempfile
import unittest
from pathlib import Path
from types import MethodType

import yaml

from scripts.native_mtp_enablement_rehearsal import (
    CANARY_NEGATIVE_EXPECTED_REASON,
    Rehearsal,
)


class NativeMTPEnablementCanaryNegativeTests(unittest.TestCase):
    def test_money_table_counts_are_schema_discovered_and_pattern_limited(self):
        with tempfile.TemporaryDirectory() as td:
            db_path = Path(td) / "coordinator.db"
            with sqlite3.connect(db_path) as db:
                db.execute("CREATE TABLE request_log(id TEXT)")
                db.execute("CREATE TABLE settlement_receipts(id TEXT)")
                db.execute("CREATE TABLE unrelated(id TEXT)")
                db.execute("INSERT INTO request_log VALUES('r1')")
                db.execute("INSERT INTO settlement_receipts VALUES('s1')")
                db.execute("INSERT INTO settlement_receipts VALUES('s2')")
                db.execute("INSERT INTO unrelated VALUES('u1')")
            got = Rehearsal.money_table_counts(db_path, ("request_log", "settlement_receipts", "missing_known"))
            self.assertEqual(got["request_log"]["count"], 1)
            self.assertEqual(got["settlement_receipts"]["count"], 2)
            self.assertRegex(got["request_log"]["sha256"], r"^[0-9a-f]{64}$")
            self.assertEqual(got["missing_known"], {"missing": True})
            self.assertNotIn("unrelated", got)


    def test_money_table_counts_fail_closed_on_missing_db(self):
        with tempfile.TemporaryDirectory() as td:
            with self.assertRaisesRegex(RuntimeError, "database missing"):
                Rehearsal.money_table_counts(Path(td) / "missing.db", ("request_log",))

    def test_spec030_036_evidence_is_pending_without_relay_or_disabled_tuple(self):
        self.assertEqual(
            Rehearsal.spec030_036_canary_evidence({}, {"http_status": 200}, {"canary_results_faulted": 1}),
            "pending:no_native_mtp_canary_diagnostics",
        )
        self.assertEqual(
            Rehearsal.spec030_036_canary_evidence({"status": "disabled", "disabled_reason": "x"}, {"http_status": 200}, {}),
            "pending:relay_fault_not_observed",
        )
        self.assertEqual(
            Rehearsal.spec030_036_canary_evidence({"status": "disabled", "disabled_reason": "x"}, {"http_status": 200}, {"canary_results_faulted": 1}),
            "inconclusive",
        )

    def test_money_delta_reports_only_changed_money_tables(self):
        before = {"coordinator": {"request_log": {"count": 2, "sha256": "a"}},
                  "gateway": {"usage_events": {"count": 1, "sha256": "b"}}}
        after = {"coordinator": {"request_log": {"count": 2, "sha256": "c"}},
                 "gateway": {"usage_events": {"count": 1, "sha256": "b"},
                              "quota_reservations": {"count": 1, "sha256": "d"}}}
        self.assertEqual(
            Rehearsal.money_delta(before, after),
            {"coordinator": {"request_log": {"before": {"count": 2, "sha256": "a"},
                                              "after": {"count": 2, "sha256": "c"}}},
             "gateway": {"quota_reservations": {"before": {"missing": True},
                                                   "after": {"count": 1, "sha256": "d"}}}},
        )

    def test_provider_config_can_route_provider_through_relay(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            template = root / "serve-template.yaml"
            template.write_text(yaml.safe_dump({"port": 1, "provider_token": "remove-me"}))
            r = Rehearsal.__new__(Rehearsal)
            r.cfg = {"serve_config_template": str(template)}
            r.work = root
            (r.work / "provider").mkdir()
            r.ports = {"serve_port": 19382, "coordinator_ws_port": 19383}
            r.relay_port = 19384
            r.provider_id = "provider-a"
            r.clone = root / "models/model-a"
            path = r.provider_config("auto", coordinator_url="ws://127.0.0.1:19384/ws/provider")
            data = yaml.safe_load(path.read_text())
            self.assertEqual(data["coordinator_url"], "ws://127.0.0.1:19384/ws/provider")
            self.assertNotIn("provider_token", data)


    def test_coverage_disposition_keeps_expiry_source_ci_only(self):
        disposition = Rehearsal.canary_negative_coverage_disposition(["wrong_digest", "drop"])
        self.assertIn("wrong_digest", disposition["physical_loopback_faults"])
        self.assertIn("drop", disposition["physical_loopback_faults"])
        self.assertIn("expiry", disposition["source_ci_only_faults"])
        self.assertFalse(disposition["source_ci_only_faults"]["expiry"]["hardware_claim"])
        self.assertIn("must not be claimed", disposition["activation_claim_boundary"])

    def test_phase_canary_negative_runs_fault_relay_before_ordinary_probe(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            (root / "run").mkdir()
            status_path = root / "run/relay-status.json"
            status_path.write_text(json.dumps({"canary_results_faulted": 1, "canary_results_seen": 1}))
            r = Rehearsal.__new__(Rehearsal)
            r.cfg = {"canary_negative_faults": ["wrong_digest"]}
            r.work = root
            r.ports = {"coordinator_ws_port": 19385, "gateway_port": 19386}
            r.relay_port = 19387
            r.procs = {}
            r.result = {"phases": {}}
            calls = []

            def start_relay(self, fault):
                calls.append(("relay", fault))
                return status_path

            def start_provider(self, label, native_mode, coordinator_url=None, readiness_probe=True):
                calls.append(("provider", label, coordinator_url, readiness_probe))
                return {"native_mode": native_mode, "routable": None}

            def coordinator_canary(self, wait_s=0, expected_reason=None):
                calls.append(("canary", wait_s, expected_reason))
                return {"http_status": 200, "native_mtp_canary": {
                    "status": "disabled",
                    "disabled_reason": CANARY_NEGATIVE_EXPECTED_REASON["wrong_digest"],
                }}

            snapshots = iter([{}, {}])
            r.restart_coordinator_for_canary_negative = MethodType(lambda self: calls.append(("restart_coordinator",)), r)
            r.start_canary_fault_relay = MethodType(start_relay, r)
            r.start_provider = MethodType(start_provider, r)
            r.coordinator_canary = MethodType(coordinator_canary, r)
            r.money_snapshot = MethodType(lambda self: next(snapshots), r)
            r.wait_for_ordinary_200 = MethodType(lambda self, timeout_s=240: {"status": 200, "usage": {"total_tokens": 1}}, r)
            r.stop_provider = MethodType(lambda self: calls.append(("stop_provider",)), r)
            r.stop_canary_fault_relay = MethodType(lambda self: calls.append(("stop_relay",)), r)

            r.phase_canary_negative()
            case = r.result["phases"]["canary_negative"]["cases"][0]
            self.assertEqual(calls[0], ("restart_coordinator",))
            self.assertEqual(calls[1], ("relay", "wrong_digest"))
            self.assertEqual(calls[2][0], "provider")
            self.assertIn("ws://127.0.0.1:19387/ws/provider", calls[2][2])
            self.assertFalse(calls[2][3])
            self.assertTrue(case["tuple_disabled_only"])
            self.assertTrue(case["diagnostic_no_billing_receipt_settlement_change"])
            self.assertEqual(case["spec030_036_path_mismatch"], "inconclusive")



    def test_phase_canary_negative_classifies_expiry_without_relay(self):
        with tempfile.TemporaryDirectory() as td:
            root = Path(td)
            r = Rehearsal.__new__(Rehearsal)
            r.cfg = {"canary_negative_faults": ["expiry"]}
            r.work = root
            r.ports = {"coordinator_ws_port": 19385, "gateway_port": 19386}
            r.relay_port = 19387
            r.procs = {}
            r.result = {"phases": {}}
            r.phase_canary_negative()
            case = r.result["phases"]["canary_negative"]["cases"][0]
            self.assertEqual(case["fault"], "expiry")
            self.assertFalse(case["physical_negative_rehearsed"])
            self.assertEqual(case["proof_class"], "coordinator_source_ci_core_evaluation")
            self.assertIn("late results are rejected", case["note"])

    def test_preflight_rejects_relay_port_collision(self):
        with tempfile.TemporaryDirectory() as td:
            r = Rehearsal.__new__(Rehearsal)
            r.ports = {"coordinator_http_port": 19390, "coordinator_ws_port": 19391,
                       "gateway_port": 19392, "serve_port": 19393}
            r.relay_port = 19393
            r.cfg = {"forbidden_roots": [], "lab_lock_dir": str(Path(td) / "lock")}
            r.work = Path(td) / "work"
            r.result = {"lab_lock": {}}
            with self.assertRaisesRegex(SystemExit, "ports must be distinct"):
                r.preflight()


if __name__ == "__main__":
    unittest.main()
