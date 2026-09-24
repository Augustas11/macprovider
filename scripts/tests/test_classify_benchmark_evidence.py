import importlib.util
import json
import sqlite3
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "classify_benchmark_evidence.py"
spec = importlib.util.spec_from_file_location("classify_benchmark_evidence", SCRIPT)
classifier = importlib.util.module_from_spec(spec)
spec.loader.exec_module(classifier)


class BenchmarkEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime(2026, 9, 22, 9, 0, tzinfo=timezone.utc)
        self.coord = sqlite3.connect(":memory:")
        self.gateway = sqlite3.connect(":memory:")
        for db in (self.coord, self.gateway):
            db.row_factory = sqlite3.Row
        self.coord.executescript("""
            CREATE TABLE request_log (id INTEGER PRIMARY KEY, request_id TEXT, attempt_n INTEGER, ts_utc TEXT,
                status INTEGER, provider_assigned_id TEXT, provider_header TEXT,
                account_id TEXT, external_request_id TEXT, model TEXT);
            CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY, request_id TEXT,
                attempt_n INTEGER, provider_id TEXT, provider_assigned_id TEXT, provider_credits INTEGER,
                quarantine_reason TEXT, quarantined INTEGER,
                settlement_policy_mode TEXT, settlement_account_scope_hash TEXT,
                prompt_tokens INTEGER, charged_prompt_tokens INTEGER,
                provider_reported_prompt_tokens INTEGER, completion_tokens INTEGER);
            CREATE TABLE settlement_route_snapshots (account_scope TEXT, request_id TEXT, attempt_n INTEGER,
                provider_id TEXT, pending_deadline_seconds INTEGER, request_start_ts_unix_ms INTEGER,
                route_snapshot_digest TEXT, provider_reported_model_hash TEXT, expected_catalog_model_hash TEXT,
                model_id TEXT, spec008_hash_status TEXT);
            CREATE TABLE settlement_attempt_outputs (account_scope TEXT, request_id TEXT, attempt_n INTEGER,
                provider_id TEXT, terminal_state TEXT, usage_canonical_json TEXT);
            CREATE TABLE settlement_receipt_verdicts (account_scope_hash TEXT, request_id TEXT, attempt_n INTEGER,
                provider_id TEXT, settlement_outcome TEXT, closed INTEGER, reason TEXT,
                pending_deadline_unix_ms INTEGER, route_snapshot_digest TEXT);
            CREATE TABLE settlement_receipt_audit_outbox (account_scope_hash TEXT, request_id TEXT, attempt_n INTEGER,
                provider_id TEXT, drained_at_utc TEXT, poisoned_at_utc TEXT);
        """)
        self.gateway.executescript("""
            CREATE TABLE usage_events (account_id TEXT, request_id TEXT, outcome TEXT,
                prompt_tokens INTEGER, completion_tokens INTEGER);
            CREATE TABLE quota_reservations (account_id TEXT, request_id TEXT,
                status TEXT, settled_tokens INTEGER, settlement_hold INTEGER);
        """)
        self.seed_request(age=600)
        self.gateway.execute("INSERT INTO usage_events VALUES ('acct', 'external', 'ok', 10, 5)")
        self.gateway.execute("INSERT INTO quota_reservations VALUES ('acct', 'external', 'settled', 15, 0)")

    def tearDown(self):
        self.coord.close()
        self.gateway.close()

    def seed_request(self, age):
        for table in ("request_log", "ledger_request_credits", "settlement_route_snapshots",
                      "settlement_attempt_outputs", "settlement_receipt_verdicts"):
            self.coord.execute("DELETE FROM " + table)
        when = self.now - timedelta(seconds=age)
        account_scope, receipt_scope = classifier.evidence_scopes("acct")
        self.coord.execute("INSERT INTO request_log(request_id, attempt_n, ts_utc, status, provider_assigned_id, provider_header, account_id, external_request_id, model) VALUES (?, 0, ?, 200, 'assigned', 'provider', 'acct', 'external', 'model')",
                           ("internal", when.isoformat()))
        self.coord.execute("""INSERT INTO ledger_request_credits
            (id, request_id, attempt_n, provider_id, provider_assigned_id, provider_credits,
             quarantine_reason, quarantined, settlement_policy_mode, settlement_account_scope_hash,
             prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens, completion_tokens)
            VALUES (1, 'internal', 0, 'provider', 'assigned', 5, NULL, 0, 'enforce', ?, 10, 10, 10, 5)""",
                           (receipt_scope,))
        self.coord.execute("INSERT INTO settlement_route_snapshots VALUES (?, ?, 0, 'provider', 300, ?, ?, ?, ?, 'model', 'hash_verified')",
                           (account_scope, "internal", int(when.timestamp() * 1000), "a" * 64, "b" * 64, "b" * 64))
        self.coord.execute("INSERT INTO settlement_attempt_outputs VALUES (?, ?, 0, 'provider', 'normal_done', ?)",
                           (account_scope, "internal", json.dumps({"billable_input_tokens": 10, "billable_output_tokens": 5})))
        self.coord.execute("INSERT INTO settlement_receipt_verdicts VALUES (?, ?, 0, 'provider', 'verified', 1, 'verified_settlement', ?, ?)",
                           (receipt_scope, "internal", int((when + timedelta(seconds=300)).timestamp() * 1000), "a" * 64))

    def result(self):
        return classifier.classify(self.coord, self.gateway, "acct", "external", now=self.now)

    def test_complete_requires_all_durable_components(self):
        self.assertEqual(self.result()["classification"], "complete")

    def test_zero_value_credit_can_have_complete_evidence(self):
        self.coord.execute("UPDATE ledger_request_credits SET provider_credits=0")
        self.assertEqual(self.result()["classification"], "complete")

    def test_quarantined_credit_cannot_complete_evidence(self):
        self.coord.execute("UPDATE ledger_request_credits SET quarantined=1, provider_credits=0, quarantine_reason='ambiguous_cache'")
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("provider_credit_quarantined:ambiguous_cache", result["missing"])

    def test_second_provider_credit_cannot_be_ignored(self):
        _, receipt_scope = classifier.evidence_scopes("acct")
        self.coord.execute("""INSERT INTO ledger_request_credits
            (id, request_id, attempt_n, provider_id, provider_assigned_id, provider_credits,
             quarantine_reason, quarantined, settlement_policy_mode, settlement_account_scope_hash,
             prompt_tokens, charged_prompt_tokens, provider_reported_prompt_tokens, completion_tokens)
            VALUES (2, 'internal', 0, 'other-provider', 'assigned', 5, NULL, 0, 'enforce', ?, 10, 10, 10, 5)""",
                           (receipt_scope,))
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("multiple_provider_credits", result["missing"])

    def test_pinned_provider_must_match_credit(self):
        self.coord.execute("UPDATE request_log SET provider_header='other-provider'")
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("provider_pin_mismatch", result["missing"])

    def test_unpinned_provider_cannot_complete_benchmark_evidence(self):
        self.coord.execute("UPDATE request_log SET provider_header=NULL")
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("expected_provider_missing", result["missing"])

    def test_expected_provider_identifies_unpinned_gateway_benchmark(self):
        self.coord.execute("UPDATE request_log SET provider_header=NULL")
        self.assertEqual(classifier.classify(self.coord, self.gateway, "acct", "external", now=self.now,
                                             expected_provider_id="provider")["classification"], "complete")
        result = classifier.classify(self.coord, self.gateway, "acct", "external", now=self.now,
                                     expected_provider_id="other-provider")
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("expected_provider_mismatch", result["missing"])

    def test_other_account_evidence_cannot_complete_same_internal_request(self):
        other_scope, other_receipt_scope = classifier.evidence_scopes("other")
        self.coord.execute("UPDATE settlement_route_snapshots SET account_scope=?", (other_scope,))
        self.coord.execute("UPDATE settlement_attempt_outputs SET account_scope=?", (other_scope,))
        self.coord.execute("UPDATE settlement_receipt_verdicts SET account_scope_hash=?", (other_receipt_scope,))
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("route_snapshot_missing", result["missing"])

    def test_settled_quota_must_match_usage_and_clear_hold(self):
        self.gateway.execute("UPDATE quota_reservations SET settled_tokens=1, settlement_hold=1")
        result = self.result()
        self.assertIn("gateway_quota_hold_not_cleared", result["missing"])
        self.gateway.execute("UPDATE quota_reservations SET settlement_hold=0")
        result = self.result()
        self.assertIn("gateway_quota_usage_mismatch", result["missing"])

    def test_bounded_prompt_billing_is_complete_and_annotated(self):
        self.gateway.execute("UPDATE usage_events SET prompt_tokens=133, completion_tokens=32")
        self.gateway.execute("UPDATE quota_reservations SET settled_tokens=165")
        self.coord.execute("""UPDATE ledger_request_credits
                               SET prompt_tokens=133, charged_prompt_tokens=133,
                                   provider_reported_prompt_tokens=295, completion_tokens=32""")
        self.coord.execute("""UPDATE settlement_attempt_outputs
                               SET usage_canonical_json=?""",
                           (json.dumps({"billable_input_tokens": 295, "billable_output_tokens": 32}),))

        result = self.result()

        self.assertEqual(result["classification"], "complete")
        self.assertNotIn("gateway_coordinator_usage_mismatch", result["missing"])
        self.assertEqual(result["attempts"][0]["usage_accounting_split"], {
            "provider_observed_prompt_tokens": 295,
            "charged_prompt_tokens": 133,
            "reason": "bounded_prompt_billing",
        })

    def test_equal_observed_and_charged_usage_needs_no_split_annotation(self):
        result = self.result()

        self.assertEqual(result["classification"], "complete")
        self.assertIsNone(result["attempts"][0]["usage_accounting_split"])

    def test_gateway_usage_must_match_charged_ledger_usage(self):
        self.coord.execute("UPDATE ledger_request_credits SET charged_prompt_tokens=9, prompt_tokens=9")
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("gateway_coordinator_usage_mismatch", result["missing"])

    def test_receipt_usage_must_match_provider_observed_usage(self):
        self.coord.execute("UPDATE ledger_request_credits SET provider_reported_prompt_tokens=11")
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("receipt_observed_usage_mismatch", result["missing"])

    def test_route_pressure_is_explicitly_incomplete_after_success(self):
        self.coord.execute("DELETE FROM settlement_route_snapshots")
        self.coord.execute("DELETE FROM settlement_receipt_verdicts")
        self.coord.execute("UPDATE ledger_request_credits SET quarantine_reason='route_snapshot_store_pressure'")
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("route_snapshot_store_pressure", result["missing"])
        self.assertIn("receipt_verdict_blocked_by_missing_evidence", result["missing"])

    def test_missing_verdict_changes_from_pending_to_incomplete_after_deadline(self):
        self.coord.execute("DELETE FROM settlement_receipt_verdicts")
        self.seed_request(age=60)
        self.coord.execute("DELETE FROM settlement_receipt_verdicts")
        self.assertEqual(self.result()["classification"], "pending")
        self.seed_request(age=600)
        self.coord.execute("DELETE FROM settlement_receipt_verdicts")
        self.assertIn("receipt_verdict_missing", self.result()["missing"])

    def test_gateway_held_quota_cannot_pass(self):
        self.gateway.execute("DELETE FROM usage_events")
        self.gateway.execute("UPDATE quota_reservations SET status='active', settled_tokens=0, settlement_hold=1")
        result = self.result()
        self.assertEqual(result["classification"], "incomplete")
        self.assertIn("gateway_usage_missing", result["missing"])
        self.assertIn("gateway_quota_active", result["missing"])

    def test_audit_backlog_is_visible_without_downgrading_verified_verdict(self):
        _, receipt_scope = classifier.evidence_scopes("acct")
        self.coord.execute("INSERT INTO settlement_receipt_audit_outbox VALUES (?, 'internal', 0, 'provider', NULL, NULL)", (receipt_scope,))
        result = self.result()
        self.assertEqual(result["classification"], "complete")
        self.assertEqual(result["attempts"][0]["receipt_audit_outbox"], "pending")


if __name__ == "__main__":
    unittest.main()
