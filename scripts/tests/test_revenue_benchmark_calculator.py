import contextlib
import copy
import importlib.util
import io
import json
import sqlite3
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "revenue_benchmark"
spec = importlib.util.spec_from_file_location("revenue_benchmark_calculator", SCRIPTS / "revenue_benchmark_calculator.py")
calculator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(calculator)
classifier = calculator.classifier

COORDINATOR_SCHEMA = """
CREATE TABLE request_log (id INTEGER PRIMARY KEY, request_id TEXT, attempt_n INTEGER, ts_utc TEXT,
    status INTEGER, provider_assigned_id TEXT, provider_header TEXT,
    account_id TEXT, external_request_id TEXT, model TEXT);
CREATE TABLE ledger_request_credits (id INTEGER PRIMARY KEY, request_id TEXT, attempt_n INTEGER,
    provider_id TEXT, provider_assigned_id TEXT, model TEXT, prompt_tokens INTEGER,
    cached_prompt_tokens INTEGER, completion_tokens INTEGER, usage_source TEXT, fault_flag TEXT,
    prompt_rate_per_mtok INTEGER, completion_rate_per_mtok INTEGER, global_multiplier_ppm INTEGER,
    gross_credits INTEGER, provider_share_bps INTEGER, provider_credits INTEGER,
    quarantine_reason TEXT, quarantined INTEGER, settlement_policy_mode TEXT,
    settlement_account_scope_hash TEXT);
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
"""
GATEWAY_SCHEMA = """
CREATE TABLE usage_events (account_id TEXT, request_id TEXT, outcome TEXT,
    prompt_tokens INTEGER, completion_tokens INTEGER);
CREATE TABLE quota_reservations (account_id TEXT, request_id TEXT,
    status TEXT, settled_tokens INTEGER, settlement_hold INTEGER);
"""


def load_fixture(name):
    with open(FIXTURES / name, encoding="utf-8") as f:
        return json.load(f)


def seed(coordinator, gateway, account_id, rows, now):
    """Write durable coordinator/gateway evidence for each fixture row's state."""
    coordinator.executescript(COORDINATOR_SCHEMA)
    gateway.executescript(GATEWAY_SCHEMA)
    account_scope, receipt_scope = classifier.evidence_scopes(account_id)
    for row in rows:
        if row["state"] == "no_request":
            continue
        when = now - timedelta(seconds=row["age_seconds"])
        internal, provider = row["internal_request_id"], row["provider_id"]
        assigned = "assigned-" + provider
        digest = "d" * 64
        coordinator.execute(
            "INSERT INTO request_log(request_id, attempt_n, ts_utc, status, provider_assigned_id, provider_header,"
            " account_id, external_request_id, model) VALUES (?, 0, ?, 200, ?, NULL, ?, ?, ?)",
            (internal, when.isoformat(), assigned, account_id, row["request_id"], row["model"]))
        quarantined = row["state"] == "quarantined"
        coordinator.execute(
            "INSERT INTO ledger_request_credits(request_id, attempt_n, provider_id, provider_assigned_id, model,"
            " prompt_tokens, cached_prompt_tokens, completion_tokens, usage_source, fault_flag,"
            " prompt_rate_per_mtok, completion_rate_per_mtok, global_multiplier_ppm, gross_credits,"
            " provider_share_bps, provider_credits, quarantine_reason, quarantined, settlement_policy_mode,"
            " settlement_account_scope_hash) VALUES (?, 0, ?, ?, ?, ?, ?, ?, 'provider_reported', 'none',"
            " ?, ?, ?, ?, ?, ?, ?, ?, 'enforce', ?)",
            (internal, provider, assigned, row["model"], row["prompt_tokens"], row["cached_prompt_tokens"],
             row["completion_tokens"], row["prompt_rate_per_mtok"], row["completion_rate_per_mtok"],
             row["global_multiplier_ppm"], row["gross_credits"], row["provider_share_bps"],
             row["provider_credits"], "ambiguous_cache" if quarantined else None, int(quarantined), receipt_scope))
        coordinator.execute(
            "INSERT INTO settlement_route_snapshots VALUES (?, ?, 0, ?, 300, ?, ?, ?, ?, ?, 'hash_verified')",
            (account_scope, internal, provider, int(when.timestamp() * 1000), digest, "h" * 64, "h" * 64, row["model"]))
        coordinator.execute(
            "INSERT INTO settlement_attempt_outputs VALUES (?, ?, 0, ?, 'normal_done', ?)",
            (account_scope, internal, provider, json.dumps({
                "billable_input_tokens": row["prompt_tokens"],
                "billable_output_tokens": row["completion_tokens"]})))
        if row["state"] != "pending":
            coordinator.execute(
                "INSERT INTO settlement_receipt_verdicts VALUES (?, ?, 0, ?, 'verified', 1, 'verified_settlement', ?, ?)",
                (receipt_scope, internal, provider, int((when + timedelta(seconds=300)).timestamp() * 1000), digest))
        gateway.execute("INSERT INTO usage_events VALUES (?, ?, 'ok', ?, ?)",
                        (account_id, row["request_id"], row["prompt_tokens"], row["completion_tokens"]))
        gateway.execute("INSERT INTO quota_reservations VALUES (?, ?, 'settled', ?, 0)",
                        (account_id, row["request_id"], row["prompt_tokens"] + row["completion_tokens"]))
    coordinator.commit()
    gateway.commit()


class RevenueCalculatorFixtureTests(unittest.TestCase):
    def setUp(self):
        self.manifest = load_fixture("run_manifest.json")
        self.evidence = load_fixture("evidence_rows.json")
        self.now = classifier.parse_utc(self.evidence["now"])
        self.coord = sqlite3.connect(":memory:")
        self.gateway = sqlite3.connect(":memory:")
        for db in (self.coord, self.gateway):
            db.row_factory = sqlite3.Row
        seed(self.coord, self.gateway, self.manifest["account_id"], self.evidence["rows"], self.now)

    def tearDown(self):
        self.coord.close()
        self.gateway.close()

    def report(self, manifest=None):
        return calculator.calculate(manifest or self.manifest, self.coord, self.gateway, now=self.now)

    def candidate(self, report, candidate_id):
        return next(c for c in report["candidates"] if c["candidate_id"] == candidate_id)

    def test_only_complete_rows_enter_revenue(self):
        report = self.report()
        incumbent = self.candidate(report, "incumbent-qwen-coder")
        self.assertEqual(incumbent["attempted_rows"], 9)
        self.assertEqual(incumbent["counted_rows"], 7)
        self.assertEqual(incumbent["provider_credits"], 2509)
        self.assertEqual(incumbent["provider_usdc"], "0.002509")
        self.assertEqual(incumbent["provider_usdc_per_day_over_window"], "0.060216")
        self.assertEqual(incumbent["excluded_rows_by_reason"], {"incomplete": 1, "pending": 1})
        challenger = self.candidate(report, "challenger-qwen35-a3b")
        self.assertEqual(challenger["counted_rows"], 6)
        self.assertEqual(challenger["provider_credits"], 1550)
        self.assertEqual(challenger["provider_usdc_per_day_over_window"], "0.074400")
        self.assertEqual(challenger["excluded_rows_by_reason"], {
            "completion_below_case_floor": 1,
            "credit_formula_mismatch": 1,
            "no_successful_provider_request": 1,
        })
        self.assertEqual(report["evidence_boundary"], "live_buyer_path_benchmark_complete_rows_only")

    def test_excluded_rows_contribute_zero_credits(self):
        for row in self.report()["rows"]:
            if not row["counted"]:
                self.assertEqual(row["provider_credits"], 0, row)
                self.assertTrue(row["excluded_reasons"], row)

    def test_cached_prompt_row_uses_declared_cache_hit_rate(self):
        report = self.report()
        challenger = self.candidate(report, "challenger-qwen35-a3b")
        self.assertEqual(challenger["cached_prompt_tokens"], 1536)
        cached_row = next(r for r in report["rows"] if r["case_id"] == "agent-loop-multi-file-inventory-fix"
                          and r["candidate_id"] == "challenger-qwen35-a3b")
        self.assertTrue(cached_row["counted"])
        self.assertEqual(cached_row["provider_credits"], 490)

    def test_cached_prompt_without_declared_rate_is_excluded(self):
        manifest = copy.deepcopy(self.manifest)
        del manifest["candidates"][1]["prompt_cache_hit_rate_per_mtok"]
        challenger = self.candidate(self.report(manifest), "challenger-qwen35-a3b")
        self.assertEqual(challenger["excluded_rows_by_reason"]["cache_hit_rate_undeclared"], 1)
        self.assertEqual(challenger["provider_credits"], 1550 - 490)

    def test_partial_case_coverage_blocks_comparison(self):
        report = self.report()
        self.assertFalse(report["comparable"])
        self.assertIn("candidate_missing_case_coverage:incumbent-qwen-coder", report["comparison_blockers"])
        self.assertIn("candidate_missing_case_coverage:challenger-qwen35-a3b", report["comparison_blockers"])

    def reseed_all_complete(self):
        cases = calculator.workload_lib.cases_by_id(calculator.workload_lib.load(1))
        case_by_request = {r["request_id"]: r["case_id"] for r in self.manifest["requests"]}
        rows = copy.deepcopy(self.evidence["rows"])
        for row in rows:
            row.update(state="complete", age_seconds=900)
            row["completion_tokens"] = max(row["completion_tokens"], cases[case_by_request[row["request_id"]]]["min_completion_tokens"])
            cache_rate = 25000 if row["cached_prompt_tokens"] else 0
            row["gross_credits"], row["provider_credits"] = calculator.expected_credits(row, cache_rate)
        self.coord.close()
        self.gateway.close()
        self.coord, self.gateway = sqlite3.connect(":memory:"), sqlite3.connect(":memory:")
        for db in (self.coord, self.gateway):
            db.row_factory = sqlite3.Row
        seed(self.coord, self.gateway, self.manifest["account_id"], rows, self.now)

    def test_fully_complete_run_is_comparable(self):
        self.reseed_all_complete()
        report = self.report()
        self.assertTrue(report["comparable"], report["comparison_blockers"])
        for entry in report["candidates"]:
            self.assertEqual(entry["attempted_rows"], 9)
            self.assertEqual(entry["counted_rows"], 9)

    def test_dropping_workload_cases_blocks_comparison(self):
        self.reseed_all_complete()
        manifest = copy.deepcopy(self.manifest)
        manifest["requests"] = [r for r in manifest["requests"] if r["case_id"] != "harden-bash-release-script"]
        report = self.report(manifest)
        self.assertFalse(report["comparable"])
        for entry in report["candidates"]:
            self.assertEqual(entry["cases_without_counted_rows"], ["harden-bash-release-script"])

    def test_pending_row_turns_incomplete_after_deadline_and_never_counts(self):
        report = calculator.calculate(self.manifest, self.coord, self.gateway, now=self.now + timedelta(hours=1))
        incumbent = self.candidate(report, "incumbent-qwen-coder")
        self.assertEqual(incumbent["excluded_rows_by_reason"], {"incomplete": 2})
        self.assertEqual(incumbent["provider_credits"], 2509)

    def test_different_case_sets_block_comparison(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["requests"] = [r for r in manifest["requests"]
                                if not (r["candidate_id"] == "challenger-qwen35-a3b"
                                        and r["case_id"] == "review-sql-migration-backfill")]
        self.assertIn("candidates_attempted_different_case_sets", self.report(manifest)["comparison_blockers"])

    def test_payout_terms_change_blocks_comparison(self):
        self.coord.execute("UPDATE ledger_request_credits SET provider_share_bps=7000,"
                           " provider_credits=(gross_credits * 7000 + 5000) / 10000 WHERE provider_id='prov-challenger'")
        report = self.report()
        self.assertIn("payout_terms_changed_during_run", report["comparison_blockers"])

    def test_model_mismatch_is_excluded(self):
        self.coord.execute("UPDATE ledger_request_credits SET model='other/model' WHERE request_id='int-0-00'")
        self.coord.execute("UPDATE request_log SET model='other/model' WHERE request_id='int-0-00'")
        self.coord.execute("UPDATE settlement_route_snapshots SET model_id='other/model' WHERE request_id='int-0-00'")
        incumbent = self.candidate(self.report(), "incumbent-qwen-coder")
        self.assertEqual(incumbent["excluded_rows_by_reason"]["candidate_model_mismatch"], 1)
        self.assertEqual(incumbent["provider_credits"], 2509 - 92)

    def test_wrong_provider_is_classified_incomplete(self):
        self.coord.execute("UPDATE ledger_request_credits SET provider_id='prov-other' WHERE request_id='int-0-01'")
        incumbent = self.candidate(self.report(), "incumbent-qwen-coder")
        self.assertEqual(incumbent["counted_rows"], 6)
        self.assertEqual(incumbent["provider_credits"], 2509 - 262)

    def test_byte_estimated_usage_is_excluded(self):
        self.coord.execute("UPDATE ledger_request_credits SET usage_source='byte_estimated' WHERE request_id='int-0-02'")
        incumbent = self.candidate(self.report(), "incumbent-qwen-coder")
        self.assertEqual(incumbent["excluded_rows_by_reason"]["ledger_usage_not_clean"], 1)

    def test_manifest_must_use_planned_request_ids(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["requests"][0]["request_id"] = "16800000-0000-4000-8000-000000000001"
        with self.assertRaisesRegex(ValueError, "planned run-scoped request id"):
            self.report(manifest)

    def test_manifest_rejects_duplicate_request(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["requests"].append(dict(manifest["requests"][0]))
        with self.assertRaisesRegex(ValueError, "more than once"):
            self.report(manifest)

    def test_manifest_rejects_other_workload(self):
        manifest = copy.deepcopy(self.manifest)
        manifest["workload"]["sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "pinned workload identity"):
            self.report(manifest)

    def test_round_half_even_matches_billing_formula(self):
        self.assertEqual(calculator.round_half_even(5, 2), 2)
        self.assertEqual(calculator.round_half_even(7, 2), 4)
        self.assertEqual(calculator.round_half_even(114_720_000_000_000, 10**12), 115)
        self.assertEqual(calculator.round_half_even(1, 3), 0)

    def test_cli_reads_database_files_read_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            coord_path, gateway_path = Path(tmp, "coordinator.db"), Path(tmp, "gateway.db")
            with contextlib.closing(sqlite3.connect(coord_path)) as coord, \
                    contextlib.closing(sqlite3.connect(gateway_path)) as gateway:
                seed(coord, gateway, self.manifest["account_id"], self.evidence["rows"], self.now)
            before = coord_path.read_bytes(), gateway_path.read_bytes()
            out = io.StringIO()
            with contextlib.redirect_stdout(out):
                calculator.main(["--manifest", str(FIXTURES / "run_manifest.json"),
                                 "--coordinator-db", str(coord_path), "--gateway-db", str(gateway_path),
                                 "--now", self.evidence["now"]])
            self.assertEqual(before, (coord_path.read_bytes(), gateway_path.read_bytes()))
        report = json.loads(out.getvalue())
        totals = {c["candidate_id"]: c["provider_credits"] for c in report["candidates"]}
        self.assertEqual(totals, {"incumbent-qwen-coder": 2509, "challenger-qwen35-a3b": 1550})


if __name__ == "__main__":
    unittest.main()
