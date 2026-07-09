import json
import sqlite3
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent))

import harness
import report
import spec029


class Spec029HelpersTests(unittest.TestCase):
    def test_ram_tier_boundaries(self):
        cases = [
            (12, "8gb"),
            (13, "16gb"),
            (24, "16gb"),
            (25, "32gb"),
            (48, "32gb"),
            (49, "64gb_plus"),
        ]
        for gib, expected in cases:
            with self.subTest(gib=gib):
                self.assertEqual(spec029.ram_tier_key_for_gib(gib), expected)

    def test_provider_tier_normalization(self):
        self.assertEqual(spec029.normalize_provider_ram_tier("8GB"), "8gb")
        self.assertEqual(spec029.normalize_provider_ram_tier("16GB"), "16gb")
        self.assertEqual(spec029.normalize_provider_ram_tier("32GB"), "32gb")
        self.assertEqual(spec029.normalize_provider_ram_tier("64gb+"), "64gb_plus")
        self.assertEqual(spec029.normalize_provider_ram_tier("64GB+"), "64gb_plus")
        with self.assertRaises(ValueError):
            spec029.normalize_provider_ram_tier("24GB")

    def test_provider_ram_prefers_explicit_provider_config_over_local_host(self):
        with mock.patch.object(spec029, "host_ram_bytes", return_value=64 * 1024 ** 3):
            resolved = spec029.resolve_provider_ram({"provider_ram_gib": 16}, require=True)

        self.assertEqual(resolved.host_ram_bytes, 16 * 1024 ** 3)
        self.assertEqual(resolved.ram_tier_key, "16gb")
        self.assertEqual(resolved.source, "config")

    def test_provider_ram_requires_explicit_metadata_for_spec029_sweep(self):
        with self.assertRaises(ValueError):
            spec029.resolve_provider_ram({}, require=True)

    def test_sweep_grid_expands_to_search_cells(self):
        cfg = {
            "spec029_sweep": {
                "grid": {
                    "kv_bits": [4, 8],
                    "max_context_override": [8192],
                    "max_concurrency_override": [1, 2],
                }
            }
        }

        cells = spec029.sweep_cells_from_config(cfg, require_grid=True)

        self.assertEqual(len(cells), 4)
        self.assertIn(
            {"kv_bits": 4, "max_context_override": 8192, "max_concurrency_override": 2},
            cells,
        )

    def test_streaming_check_is_probe_only(self):
        self.assertFalse(spec029.is_publishable_workload("streaming_check"))
        self.assertIn("streaming_check", spec029.spec029_workloads_from_config({"spec029_sweep": {"workloads": ["streaming_check"]}}))
        with self.assertRaises(ValueError):
            spec029.choose_partition([], "streaming_check", "16gb")

    def test_metric_unavailable_reason(self):
        self.assertIsNone(spec029.metric_unavailable_reason(10, 20, 3.5))
        self.assertEqual(
            spec029.metric_unavailable_reason(10, None, None),
            "missing_completion_tokens,missing_throughput_tps",
        )


class Spec029SelectionTests(unittest.TestCase):
    def test_partition_local_winner_and_winning_cell_sample_count(self):
        cells = [
            self.cell("short_chat", "16gb", kv_bits=8, samples=20, p95=600, tps=12),
            self.cell("short_chat", "16gb", kv_bits=4, samples=20, p95=700, tps=20),
            self.cell("code_completion", "16gb", kv_bits=2, samples=20, p95=700, tps=40),
        ]

        result = spec029.choose_partition(cells, "short_chat", "16gb")
        profile = spec029.workload_profile(result, "test-source")

        self.assertEqual(result.winner.kv_bits, 4)
        self.assertEqual(profile["profile_metrics"]["sample_count"], 20)
        self.assertEqual(profile["recommended"]["kv_bits"], 4)

    def test_tie_breaker_uses_memory_risk_then_lexical_tuple(self):
        cells = [
            self.cell("agent_style", "32gb", kv_bits=8, context=50_000, concurrency=2, samples=20, p95=1000, tps=10),
            self.cell("agent_style", "32gb", kv_bits=4, context=20_000, concurrency=1, samples=20, p95=1000, tps=10),
        ]

        result = spec029.choose_partition(cells, "agent_style", "32gb")

        self.assertEqual(result.winner.kv_bits, 4)
        self.assertEqual(result.winner.max_context_override, 20_000)
        self.assertEqual(result.tie_breaker_reason, "lower_context_memory_risk")

    def test_no_winner_reason_precedence(self):
        self.assertEqual(
            spec029.choose_partition([], "short_chat", "16gb").no_winner_reason,
            "no_cells_evaluated",
        )

        hard = [self.cell("short_chat", "16gb", samples=0, p95=None, tps=None)]
        self.assertEqual(
            spec029.choose_partition(hard, "short_chat", "16gb").no_winner_reason,
            "hard_failure",
        )

        insufficient = [self.cell("short_chat", "16gb", samples=19, p95=100, tps=10)]
        self.assertEqual(
            spec029.choose_partition(insufficient, "short_chat", "16gb").no_winner_reason,
            "insufficient_samples",
        )

        gate_unmet = [self.cell("short_chat", "16gb", samples=20, p95=9_000, tps=10)]
        self.assertEqual(
            spec029.choose_partition(gate_unmet, "short_chat", "16gb").no_winner_reason,
            "gate_unmet",
        )

    def test_non_runnable_spec_cell_is_evaluated_but_not_recommended(self):
        cells = [
            self.cell(
                "code_completion",
                "16gb",
                samples=0,
                p95=None,
                tps=None,
                non_runnable_reason="draft_model_unverified_artifact",
                draft_model="mlx-community/example-draft",
            )
        ]

        result = spec029.choose_partition(cells, "code_completion", "16gb")

        self.assertEqual(result.evaluated_cell_count, 1)
        self.assertIsNone(result.winner)
        self.assertEqual(result.no_winner_reason, "hard_failure")

    def test_no_winner_profile_carries_highest_success_count_and_null_metrics(self):
        cells = [
            self.cell("long_context", "16gb", samples=4, p95=10_000, tps=2),
            self.cell("long_context", "16gb", samples=7, p95=12_000, tps=3),
        ]
        result = spec029.choose_partition(cells, "long_context", "16gb")
        profile = spec029.no_winner_profile(result, cells, "test-source")

        self.assertEqual(profile["status"], "no_winner")
        self.assertEqual(profile["profile_metrics"]["sample_count"], 7)
        self.assertIsNone(profile["profile_metrics"]["median_tps"])
        self.assertNotIn("recommended", profile)

    def test_class_aware_report_emits_one_partition_per_included_workload(self):
        cells = [self.cell("short_chat", "16gb", samples=20, p95=500, tps=10)]

        summary = spec029.class_aware_report(cells, "test-source", ram_tier_keys=["16gb"])

        self.assertEqual(len(summary["partitions"]), 5)
        statuses = {p["workload"]: p["status"] for p in summary["partitions"]}
        self.assertEqual(statuses["short_chat"], "winner")
        self.assertEqual(statuses["long_context"], "no_winner")
        long_context = next(p for p in summary["partitions"] if p["workload"] == "long_context")
        self.assertEqual(long_context["no_winner_reason"], "no_cells_evaluated")
        self.assertEqual(long_context["gate_policy"]["max_p95_ttft_ms"], 60_000)
        self.assertIn("higher_median_tps", long_context["tie_breaker_order"])

    def test_class_aware_report_keeps_per_workload_draft_token_choice(self):
        draft_hash = "0" * 64
        cells = [
            self.cell(
                "code_completion",
                "16gb",
                samples=20,
                p95=500,
                tps=10,
                draft_model="mlx-community/Fixture-Draft-4bit",
                draft_hash=draft_hash,
                draft_tokens=4,
            ),
            self.cell(
                "agent_style",
                "16gb",
                samples=20,
                p95=500,
                tps=10,
                draft_model="mlx-community/Fixture-Draft-4bit",
                draft_hash=draft_hash,
                draft_tokens=8,
            ),
        ]

        summary = spec029.class_aware_report(cells, "test-source", ram_tier_keys=["16gb"])
        tuples = {p["workload"]: p["winner_tuple"] for p in summary["partitions"] if p["winner_tuple"]}

        self.assertEqual(tuples["code_completion"]["num_draft_tokens"], 4)
        self.assertEqual(tuples["agent_style"]["num_draft_tokens"], 8)
        code = next(p for p in summary["partitions"] if p["workload"] == "code_completion")
        self.assertEqual(code["candidate_source"], "research_fixture:spec029-test")
        self.assertEqual(code["profile"]["candidate_source"], "research_fixture:spec029-test")

    def test_invalid_draft_tuples_cannot_become_python_winners(self):
        invalid_cases = [
            {"candidate_source": ""},
            {"candidate_source": "fixture"},
            {"draft_hash": "ABC"},
            {"draft_tokens": 0},
            {"draft_tokens": 17},
            {"concurrency": 2},
            {"context": 20_001},
        ]
        for overrides in invalid_cases:
            with self.subTest(overrides=overrides):
                cells = [
                    self.cell(
                        "code_completion",
                        "16gb",
                        samples=20,
                        p95=500,
                        tps=10,
                        draft_model="mlx-community/Fixture-Draft-4bit",
                        **overrides,
                    )
                ]

                result = spec029.choose_partition(cells, "code_completion", "16gb")

                self.assertIsNone(result.winner)
                self.assertEqual(result.no_winner_reason, "hard_failure")
                with self.assertRaises(ValueError):
                    cells[0].recommended_json()

        partial = self.cell(
            "code_completion",
            "16gb",
            samples=20,
            p95=500,
            tps=10,
            draft_model=None,
            draft_hash="0" * 64,
        )
        self.assertEqual(partial.draft_validation_error, "partial_speculative_tuple")

    def test_non_runnable_success_rows_do_not_inflate_no_winner_sample_count(self):
        cells = [
            self.cell(
                "code_completion",
                "16gb",
                samples=25,
                p95=500,
                tps=10,
                draft_model="mlx-community/Fixture-Draft-4bit",
                draft_hash="ABC",
            )
        ]

        result = spec029.choose_partition(cells, "code_completion", "16gb")
        profile = spec029.workload_profile(result, "test-source")

        self.assertEqual(result.no_winner_reason, "hard_failure")
        self.assertEqual(profile["profile_metrics"]["sample_count"], 0)

    def test_winner_prefers_zero_failures_and_rejects_leaks(self):
        clean = self.cell("short_chat", "16gb", kv_bits=8, samples=20, p95=500, tps=5, hard_failure_count=0)
        partial_failure = self.cell("short_chat", "16gb", kv_bits=4, samples=20, p95=500, tps=50, hard_failure_count=1)

        result = spec029.choose_partition([partial_failure, clean], "short_chat", "16gb")

        self.assertEqual(result.winner.kv_bits, 8)

        leaky = self.cell("short_chat", "16gb", samples=20, p95=500, tps=50, leak_rate=0.01)
        leaky_result = spec029.choose_partition([leaky], "short_chat", "16gb")
        self.assertIsNone(leaky_result.winner)
        self.assertEqual(leaky_result.no_winner_reason, "gate_unmet")

    def cell(
        self,
        workload,
        ram_tier,
        kv_bits=4,
        context=20_000,
        concurrency=1,
        samples=20,
        p95=1_000,
        tps=10.0,
        non_runnable_reason=None,
        draft_model=None,
        draft_hash=None,
        draft_tokens=4,
        hard_failure_count=0,
        leak_rate=0,
        candidate_source=None,
    ):
        return spec029.SearchCellResult(
            workload_name=workload,
            ram_tier_key=ram_tier,
            kv_bits=kv_bits,
            max_context_override=context,
            max_concurrency_override=concurrency,
            successful_sample_count=samples,
            p95_ttft_ms=p95,
            median_tps=tps,
            stop_token_leak_rate=leak_rate,
            hard_failure_count=hard_failure_count,
            non_runnable_reason=non_runnable_reason,
            draft_model=draft_model,
            draft_model_artifact_sha256=draft_hash if draft_hash is not None else ("0" * 64 if draft_model else None),
            num_draft_tokens=draft_tokens if draft_model else None,
            candidate_source=candidate_source if candidate_source is not None else ("research_fixture:spec029-test" if draft_model else None),
        )


class Spec029HarnessReportTests(unittest.TestCase):
    def test_cells_from_rows_aggregate_real_repeated_rows_into_winner_cell(self):
        rows = [
            self.row(
                "short_chat",
                "16gb",
                ttft_ms=400 + i,
                throughput_tps=10 + (i % 3),
            )
            for i in range(20)
        ]

        cells = spec029.cells_from_rows(rows)
        result = spec029.choose_partition(cells, "short_chat", "16gb")

        self.assertEqual(len(cells), 1)
        self.assertEqual(cells[0].successful_sample_count, 20)
        self.assertEqual(result.status, "winner")
        self.assertEqual(result.winner.successful_sample_count, 20)

    def test_cells_from_rows_ignore_unproven_execution_sources(self):
        rows = [
            self.row(
                "code_completion",
                "16gb",
                cell_execution_source="request_overrides",
            )
            for _ in range(20)
        ] + [
            self.row(
                "code_completion",
                "16gb",
                cell_execution_source=None,
            )
            for _ in range(20)
        ]

        cells = spec029.cells_from_rows(rows)
        result = spec029.choose_partition(cells, "code_completion", "16gb")

        self.assertEqual(cells, [])
        self.assertEqual(result.status, "no_winner")
        self.assertEqual(result.no_winner_reason, "no_cells_evaluated")

    def test_cells_from_rows_do_not_mix_target_models(self):
        rows = [
            self.row("short_chat", "16gb", model="model-a")
            for _ in range(10)
        ] + [
            self.row("short_chat", "16gb", model="model-b")
            for _ in range(10)
        ]

        cells = spec029.cells_from_rows(rows)
        summary = spec029.class_aware_report(cells, "test-source", ram_tier_keys=["16gb"])
        short_chat = [
            partition for partition in summary["partitions"]
            if partition["workload"] == "short_chat"
        ]

        self.assertEqual(len(cells), 2)
        self.assertEqual(sorted(cell.successful_sample_count for cell in cells), [10, 10])
        self.assertEqual({partition["model"] for partition in short_chat}, {"model-a", "model-b"})
        self.assertTrue(all(partition["status"] == "no_winner" for partition in short_chat))
        with self.assertRaises(ValueError):
            spec029.choose_partition(cells, "short_chat", "16gb")

    def test_streaming_rows_aggregate_to_probe_pass(self):
        rows = [
            self.row(
                "streaming_check",
                "8gb",
                kv_bits=8,
                context=8192,
                ttft_ms=1_500,
                throughput_tps=None,
                prompt_tokens=None,
                completion_tokens=None,
            )
            for _ in range(20)
        ]

        summary = spec029.class_aware_report(
            spec029.cells_from_rows(rows),
            "test-source",
            ram_tier_keys=["8gb"],
        )
        probe = summary["streaming_probes"][0]

        self.assertEqual(probe["status"], "probe_pass")
        self.assertIsNone(probe["winner_tuple"])
        self.assertEqual(probe["profile_metrics"]["sample_count"], 20)

    def test_streaming_probe_hard_failures_use_hard_failure_reason(self):
        rows = [
            self.row(
                "streaming_check",
                "8gb",
                kv_bits=8,
                context=8192,
                error="HTTP 500",
                prompt_tokens=None,
                completion_tokens=None,
                throughput_tps=None,
            )
            for _ in range(20)
        ]

        summary = spec029.class_aware_report(
            spec029.cells_from_rows(rows),
            "test-source",
            ram_tier_keys=["8gb"],
        )
        probe = summary["streaming_probes"][0]

        self.assertEqual(probe["status"], "probe_no_winner")
        self.assertEqual(probe["no_winner_reason"], "hard_failure")
        self.assertEqual(probe["profile_metrics"]["sample_count"], 0)

    def test_open_db_migrates_legacy_runs_table(self):
        with tempfile.TemporaryDirectory() as tmp:
            db_path = Path(tmp) / "runs.sqlite"
            conn = sqlite3.connect(db_path)
            conn.execute(
                "CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts_utc TEXT NOT NULL, "
                "workload TEXT NOT NULL, model TEXT, tunnel_url TEXT, streamed INTEGER NOT NULL, "
                "http_status INTEGER, ttft_ms REAL, total_ms REAL, prompt_tokens INTEGER, "
                "completion_tokens INTEGER, throughput_tps REAL, stop_token_leak INTEGER NOT NULL DEFAULT 0, "
                "error TEXT, response_preview TEXT)"
            )
            conn.commit()
            conn.close()

            migrated = harness.open_db(db_path)
            try:
                columns = {row[1] for row in migrated.execute("PRAGMA table_info(runs)")}
            finally:
                migrated.close()

        self.assertIn("ram_tier_key", columns)
        self.assertIn("provider_ram_source", columns)
        self.assertIn("cell_execution_source", columns)
        self.assertIn("non_runnable_reason", columns)
        self.assertIn("metric_unavailable_reason", columns)
        self.assertIn("draft_model_artifact_sha256", columns)

    def test_report_renders_legacy_rows_without_spec029_columns(self):
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.execute(
            "CREATE TABLE runs (id INTEGER PRIMARY KEY AUTOINCREMENT, ts_utc TEXT NOT NULL, "
            "workload TEXT NOT NULL, model TEXT, tunnel_url TEXT, streamed INTEGER NOT NULL, "
            "http_status INTEGER, ttft_ms REAL, total_ms REAL, prompt_tokens INTEGER, "
            "completion_tokens INTEGER, throughput_tps REAL, stop_token_leak INTEGER NOT NULL DEFAULT 0, "
            "error TEXT, response_preview TEXT)"
        )
        conn.execute(
            "INSERT INTO runs (ts_utc, workload, model, tunnel_url, streamed, http_status, "
            "ttft_ms, total_ms, prompt_tokens, completion_tokens, throughput_tps, stop_token_leak, "
            "error, response_preview) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
            ("2026-07-09T00:00:00Z", "short_chat", "model", "http://localhost", 0, 200, None, 100, 10, 20, 3.0, 0, None, "ok"),
        )
        rows = conn.execute("SELECT * FROM runs").fetchall()

        html = report.render("2026-07-09", rows)
        conn.close()

        self.assertIn("short_chat", html)
        self.assertIn("RAM tier", html)

    def test_run_one_persists_spec029_trial_identity_and_speculative_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 16,
                "sweep_cell": {
                    "max_context_override": 20_000,
                    "max_concurrency_override": 1,
                    "kv_bits": 4,
                    "draft_model": "mlx-community/Fixture-Draft-4bit",
                    "draft_model_artifact_sha256": "0" * 64,
                    "num_draft_tokens": 4,
                    "candidate_source": "research_fixture:spec029-test",
                },
            }
            metrics = {
                "http_status": 200,
                "ttft_ms": 500,
                "total_ms": 2000,
                "prompt_tokens": 10,
                "completion_tokens": 20,
                "throughput_tps": 10,
                "stop_token_leak": False,
                "response_preview": "ok",
                "drafted_tokens": 8,
                "accepted_tokens": 4,
                "spec_decode_acceptance_rate": 0.5,
            }

            with mock.patch.object(harness, "fire_nonstream", return_value=metrics), \
                 mock.patch.object(spec029, "host_ram_bytes", return_value=64 * 1024 ** 3):
                harness.run_one(cfg, "code_completion", conn, verbose=False, dry_run=False)

            row = conn.execute("SELECT * FROM runs").fetchone()
            conn.close()

        self.assertEqual(row["ram_tier_key"], "16gb")
        self.assertEqual(row["provider_ram_source"], "config")
        self.assertEqual(row["corpus_class"], "code")
        self.assertEqual(row["metric_unavailable_reason"], None)
        self.assertEqual(row["draft_model"], "mlx-community/Fixture-Draft-4bit")
        self.assertEqual(row["drafted_tokens"], 8)
        self.assertEqual(row["accepted_tokens"], 4)
        self.assertEqual(row["spec_decode_acceptance_rate"], 0.5)

    def test_spec029_sweep_uses_provider_ram_grid_and_streaming_ttft(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 16,
                "spec029_sweep": {
                    "cell_control_url": "http://127.0.0.1:8091/spec029/apply-cell",
                    "workloads": ["short_chat"],
                    "samples_per_cell": 2,
                    "cells": [
                        {"max_context_override": 8192, "max_concurrency_override": 1, "kv_bits": 8},
                        {
                            "max_context_override": 20_000,
                            "max_concurrency_override": 1,
                            "kv_bits": 4,
                            "draft_model": "mlx-community/Fixture-Draft-4bit",
                            "draft_model_artifact_sha256": "0" * 64,
                            "num_draft_tokens": 4,
                            "candidate_source": "research_fixture:spec029-test",
                        },
                    ],
                },
            }
            metrics = {
                "http_status": 200,
                "ttft_ms": 500,
                "total_ms": 2000,
                "prompt_tokens": 10,
                "completion_tokens": 20,
                "throughput_tps": 10,
                "stop_token_leak": False,
                "response_preview": "ok",
            }

            class ApplyResponse:
                status_code = 204
                text = ""

            with mock.patch.object(harness.requests, "post", return_value=ApplyResponse()) as post, \
                 mock.patch.object(harness, "fire_stream", return_value=metrics) as fire_stream, \
                 mock.patch.object(harness, "fire_nonstream", side_effect=AssertionError("SPEC-029 sweep must stream")):
                rows = harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)

            db_rows = conn.execute("SELECT * FROM runs ORDER BY id").fetchall()
            conn.close()

        self.assertEqual(len(rows), 4)
        self.assertEqual(post.call_count, 2)
        applied_cells = [call.kwargs["json"]["cell"] for call in post.call_args_list]
        self.assertEqual({cell["kv_bits"] for cell in applied_cells}, {4, 8})
        self.assertEqual(fire_stream.call_count, 4)
        request_bodies = [call.args[2] for call in fire_stream.call_args_list]
        self.assertTrue(all("macprovider_kv_bits" not in body for body in request_bodies))
        self.assertTrue(all("macprovider_draft_model" not in body for body in request_bodies))
        self.assertTrue(all(body["stream"] is True for body in request_bodies))
        self.assertEqual({row["streamed"] for row in db_rows}, {1})
        self.assertEqual({row["ram_tier_key"] for row in db_rows}, {"16gb"})
        self.assertEqual({row["provider_ram_source"] for row in db_rows}, {"config"})
        self.assertEqual({row["cell_execution_source"] for row in db_rows}, {"cell_control_url"})
        self.assertEqual({row["host_ram_bytes"] for row in db_rows}, {16 * 1024 ** 3})
        self.assertEqual({row["kv_bits"] for row in db_rows}, {4, 8})
        self.assertTrue(all(row["ttft_ms"] == 500 for row in db_rows))

    def test_spec029_sweep_schedules_streaming_probe_without_publication_profile(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 8,
                "spec029_sweep": {
                    "cell_control_url": "http://127.0.0.1:8091/spec029/apply-cell",
                    "workloads": ["streaming_check"],
                    "samples_per_cell": 1,
                    "cells": [
                        {"max_context_override": 8192, "max_concurrency_override": 1, "kv_bits": 8},
                    ],
                },
            }
            metrics = {
                "http_status": 200,
                "ttft_ms": 100,
                "total_ms": 500,
                "prompt_tokens": None,
                "completion_tokens": None,
                "throughput_tps": None,
                "stop_token_leak": False,
                "response_preview": "ok",
            }

            class ApplyResponse:
                status_code = 204
                text = ""

            with mock.patch.object(harness.requests, "post", return_value=ApplyResponse()), \
                 mock.patch.object(harness, "fire_stream", return_value=metrics):
                harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            rows = conn.execute("SELECT * FROM runs ORDER BY id").fetchall()
            summary = spec029.class_aware_report(spec029.cells_from_rows(rows), "test-source", ram_tier_keys=["8gb"])
            conn.close()

        self.assertEqual(rows[0]["workload"], "streaming_check")
        self.assertEqual(rows[0]["ram_tier_key"], "8gb")
        self.assertEqual(len(summary["streaming_probes"]), 1)
        self.assertTrue(all(partition["workload"] != "streaming_check" for partition in summary["partitions"]))

    def test_spec029_sweep_fails_closed_without_cell_execution_mechanism(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 8,
                "spec029_sweep": {
                    "workloads": ["short_chat"],
                    "cells": [
                        {"max_context_override": 8192, "max_concurrency_override": 1, "kv_bits": 8},
                    ],
                },
            }

            with self.assertRaises(RuntimeError):
                harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            conn.close()

    def test_spec029_sweep_records_cell_apply_failure_as_non_runnable_cell(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 16,
                "spec029_sweep": {
                    "cell_control_url": "http://127.0.0.1:8091/spec029/apply-cell",
                    "workloads": ["code_completion"],
                    "cells": [
                        {"max_context_override": 20_000, "max_concurrency_override": 1, "kv_bits": 4},
                    ],
                },
            }

            class ApplyResponse:
                status_code = 503
                text = "capacity preflight failed"

            with mock.patch.object(harness.requests, "post", return_value=ApplyResponse()), \
                 mock.patch.object(harness, "fire_stream", side_effect=AssertionError("non-runnable cell should not sample")):
                rows = harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            db_rows = conn.execute("SELECT * FROM runs ORDER BY id").fetchall()
            cells = spec029.cells_from_rows(db_rows)
            result = spec029.choose_partition(cells, "code_completion", "16gb")
            conn.close()

        self.assertEqual(len(rows), 1)
        self.assertEqual(db_rows[0]["cell_execution_source"], "cell_apply_failed")
        self.assertEqual(db_rows[0]["non_runnable_reason"], "cell_apply_failed")
        self.assertEqual(cells[0].non_runnable_reason, "cell_apply_failed")
        self.assertEqual(result.no_winner_reason, "hard_failure")

    def test_spec029_sweep_records_cell_control_transport_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 16,
                "spec029_sweep": {
                    "cell_control_url": "http://127.0.0.1:8091/spec029/apply-cell",
                    "workloads": ["code_completion"],
                    "cells": [
                        {"max_context_override": 20_000, "max_concurrency_override": 1, "kv_bits": 4},
                    ],
                },
            }

            with mock.patch.object(harness.requests, "post", side_effect=harness.requests.Timeout("timed out")), \
                 mock.patch.object(harness, "fire_stream", side_effect=AssertionError("non-runnable cell should not sample")):
                rows = harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            db_rows = conn.execute("SELECT * FROM runs ORDER BY id").fetchall()
            cells = spec029.cells_from_rows(db_rows)
            result = spec029.choose_partition(cells, "code_completion", "16gb")
            conn.close()

        self.assertEqual(len(rows), 1)
        self.assertEqual(db_rows[0]["cell_execution_source"], "cell_apply_failed")
        self.assertEqual(db_rows[0]["non_runnable_reason"], "cell_apply_failed")
        self.assertIn("cell control request failed", db_rows[0]["error"])
        self.assertEqual(result.no_winner_reason, "hard_failure")

    def test_spec029_sweep_records_cell_apply_command_launch_failure(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 16,
                "spec029_sweep": {
                    "cell_apply_command": "/definitely/missing/spec029-apply-cell",
                    "workloads": ["code_completion"],
                    "cells": [
                        {"max_context_override": 20_000, "max_concurrency_override": 1, "kv_bits": 4},
                    ],
                },
            }

            with mock.patch.object(harness, "fire_stream", side_effect=AssertionError("non-runnable cell should not sample")):
                rows = harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            db_rows = conn.execute("SELECT * FROM runs ORDER BY id").fetchall()
            cells = spec029.cells_from_rows(db_rows)
            result = spec029.choose_partition(cells, "code_completion", "16gb")
            conn.close()

        self.assertEqual(len(rows), 1)
        self.assertEqual(db_rows[0]["cell_execution_source"], "cell_apply_failed")
        self.assertEqual(db_rows[0]["non_runnable_reason"], "cell_apply_failed")
        self.assertIn("cell apply command failed", db_rows[0]["error"])
        self.assertEqual(result.no_winner_reason, "hard_failure")

    def test_spec029_sweep_rejects_tier_only_provider_ram(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_tier": "16gb",
                "spec029_sweep": {
                    "cell_control_url": "http://127.0.0.1:8091/spec029/apply-cell",
                    "workloads": ["short_chat"],
                    "cells": [
                        {"max_context_override": 8192, "max_concurrency_override": 1, "kv_bits": 8},
                    ],
                },
            }

            with self.assertRaises(RuntimeError):
                harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            conn.close()

    def test_spec029_sweep_rejects_multiple_cell_execution_mechanisms(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 16,
                "spec029_sweep": {
                    "cell_control_url": "http://127.0.0.1:8091/spec029/apply-cell",
                    "cell_apply_command": ["true"],
                    "workloads": ["short_chat"],
                    "cells": [
                        {"max_context_override": 8192, "max_concurrency_override": 1, "kv_bits": 8},
                    ],
                },
            }

            with self.assertRaises(RuntimeError):
                harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            conn.close()

    def test_spec029_sweep_rejects_missing_explicit_grid(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "provider_ram_gib": 16,
                "spec029_sweep": {
                    "cell_control_url": "http://127.0.0.1:8091/spec029/apply-cell",
                    "workloads": ["short_chat"],
                },
            }

            with self.assertRaises(ValueError):
                harness.run_spec029_sweep(cfg, conn, verbose=False, dry_run=False)
            conn.close()

    def test_fire_nonstream_extracts_spec_decode_response_metrics(self):
        class Response:
            status_code = 200

            def json(self):
                return {
                    "choices": [{"message": {"content": "ok"}}],
                    "usage": {
                        "prompt_tokens": 10,
                        "completion_tokens": 20,
                        "spec_decode_drafted_tokens": 12,
                        "spec_decode_accepted_tokens": 9,
                    },
                }

        with mock.patch.object(harness.requests, "post", return_value=Response()), \
             mock.patch.object(harness, "detect_leak_model", return_value=False), \
             mock.patch.object(harness, "strip_leaks_model", side_effect=lambda content, model: content):
            metrics = harness.fire_nonstream("http://localhost/v1/chat/completions", "model", {}, 1)

        self.assertEqual(metrics["drafted_tokens"], 12)
        self.assertEqual(metrics["accepted_tokens"], 9)
        self.assertEqual(metrics["spec_decode_acceptance_rate"], 0.75)

    def test_streaming_probe_and_class_aware_report_render_gates_and_decisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            cfg = {
                "tunnel_url": "http://127.0.0.1:8090",
                "model": "mlx-community/Fixture-Model-4bit",
                "sweep_cell": {
                    "max_context_override": 8192,
                    "max_concurrency_override": 1,
                    "kv_bits": 8,
                },
            }
            metrics = {
                "http_status": 200,
                "ttft_ms": 1500,
                "total_ms": 2000,
                "prompt_tokens": None,
                "completion_tokens": None,
                "throughput_tps": None,
                "stop_token_leak": False,
                "response_preview": "ok",
            }
            with mock.patch.object(harness, "fire_stream", return_value=metrics), \
                 mock.patch.object(spec029, "host_ram_bytes", return_value=8 * 1024 ** 3):
                harness.run_one(
                    cfg,
                    "streaming_check",
                    conn,
                    verbose=False,
                    dry_run=False,
                    cell_execution_source="cell_control_url",
                )
            with mock.patch.object(harness, "fire_nonstream", return_value={**metrics, "prompt_tokens": 10, "completion_tokens": 20, "throughput_tps": 10}), \
                 mock.patch.object(spec029, "host_ram_bytes", return_value=8 * 1024 ** 3):
                harness.run_one(
                    cfg,
                    "short_chat",
                    conn,
                    verbose=False,
                    dry_run=False,
                    cell_execution_source="cell_control_url",
                )

            rows = conn.execute("SELECT * FROM runs ORDER BY id").fetchall()
            html = report.render("2026-07-09", rows)
            conn.close()

        self.assertEqual(rows[0]["metric_unavailable_reason"], "missing_prompt_tokens,missing_completion_tokens,missing_throughput_tps")
        self.assertIn("SPEC-029 class-aware sweep", html)
        self.assertIn("n&gt;=20", html)
        self.assertIn("insufficient_samples", html)
        self.assertIn("streaming_check", html)
        self.assertIn("probe_no_winner", html)

    def test_write_report_emits_reproducible_spec029_json_and_html_metadata(self):
        with tempfile.TemporaryDirectory() as tmp:
            conn = harness.open_db(Path(tmp) / "runs.sqlite")
            conn.row_factory = sqlite3.Row
            for idx in range(20):
                conn.execute(
                    """INSERT INTO runs (ts_utc, workload, model, tunnel_url, streamed,
                                          http_status, ttft_ms, total_ms, prompt_tokens,
                                          completion_tokens, throughput_tps, host_ram_bytes,
                                          ram_tier_key, provider_ram_source, cell_execution_source,
                                          non_runnable_reason, corpus_class, max_context_override,
                                          max_concurrency_override, kv_bits,
                                          metric_unavailable_reason, draft_model,
                                          draft_model_artifact_sha256, num_draft_tokens,
                                          drafted_tokens, accepted_tokens,
                                          spec_decode_acceptance_rate, candidate_source,
                                          winner_status, no_winner_reason, stop_token_leak,
                                          error, response_preview)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                    (
                        f"2026-07-09T00:00:{idx:02d}Z",
                        "code_completion",
                        "model",
                        "http://localhost",
                        0,
                        200,
                        500 + idx,
                        2000,
                        10,
                        20,
                        10 + idx / 100,
                        16 * 1024 ** 3,
                        "16gb",
                        "config",
                        "cell_control_url",
                        None,
                        "code",
                        20_000,
                        1,
                        4,
                        None,
                        "mlx-community/Fixture-Draft-4bit",
                        "0" * 64,
                        4,
                        8,
                        4,
                        0.5,
                        "research_fixture:spec029-test",
                        None,
                        None,
                        0,
                        None,
                        "ok",
                    ),
                )
            conn.commit()

            html_path = report.write_report("2026-07-09", conn, Path(tmp) / "reports")
            html = html_path.read_text()
            rerendered_html = report.render("2026-07-09", report.fetch_rows(conn, "2026-07-09"))
            json_path = html_path.with_suffix(".spec029.json")
            payload = json_path.read_text()
            parsed = json.loads(payload)
            conn.close()

        self.assertEqual(html, rerendered_html)
        self.assertIn("SPEC-029 evaluated cells", html)
        self.assertIn("kv_bits=4", html)
        self.assertIn("source=research_fixture:spec029-test", html)
        self.assertIn(str(16 * 1024 ** 3), html)
        self.assertIn('"evaluated_cells"', payload)
        self.assertEqual(parsed["evaluated_cells"][0]["model"], "model")
        self.assertEqual(parsed["raw_trials"][0]["host_ram_bytes"], 16 * 1024 ** 3)
        self.assertEqual(parsed["raw_trials"][0]["provider_ram_source"], "config")
        self.assertEqual(parsed["raw_trials"][0]["cell_execution_source"], "cell_control_url")
        self.assertIsNone(parsed["raw_trials"][0]["non_runnable_reason"])
        self.assertEqual(parsed["raw_trials"][0]["drafted_tokens"], 8)
        self.assertEqual(parsed["raw_trials"][0]["accepted_tokens"], 4)
        code_partition = next(
            partition for partition in parsed["partitions"]
            if partition["workload"] == "code_completion"
        )
        self.assertEqual(code_partition["candidate_source"], "research_fixture:spec029-test")
        self.assertEqual(code_partition["tie_breaker_reason"], "only_gate_passing_cell")
        self.assertIn('"status": "winner"', payload)
        self.assertIn('"successful_sample_count": 20', payload)

    def row(
        self,
        workload,
        ram_tier,
        kv_bits=4,
        context=20_000,
        concurrency=1,
        ttft_ms=500,
        throughput_tps=10,
        prompt_tokens=10,
        completion_tokens=20,
        stop_token_leak=0,
        error=None,
        draft_model=None,
        draft_hash=None,
        num_draft_tokens=None,
        candidate_source="research_fixture:spec029-test",
        model="model",
        cell_execution_source="cell_control_url",
        non_runnable_reason=None,
    ):
        return {
            "model": model,
            "workload": workload,
            "cell_execution_source": cell_execution_source,
            "non_runnable_reason": non_runnable_reason,
            "ram_tier_key": ram_tier,
            "kv_bits": kv_bits,
            "max_context_override": context,
            "max_concurrency_override": concurrency,
            "http_status": 200,
            "error": error,
            "ttft_ms": ttft_ms,
            "throughput_tps": throughput_tps,
            "prompt_tokens": prompt_tokens,
            "completion_tokens": completion_tokens,
            "stop_token_leak": stop_token_leak,
            "draft_model": draft_model,
            "draft_model_artifact_sha256": draft_hash,
            "num_draft_tokens": num_draft_tokens,
            "spec_decode_acceptance_rate": None,
            "candidate_source": candidate_source,
        }


if __name__ == "__main__":
    unittest.main()
