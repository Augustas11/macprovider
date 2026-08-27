from __future__ import annotations

import importlib.util
import io
import json
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "measure-pool-rejection-timing-floor.py"


def load_module():
    spec = importlib.util.spec_from_file_location("measure_pool_rejection_timing_floor", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def passing_samples() -> dict[str, list[float]]:
    return {
        "unknown": [50.2, 50.4, 50.1, 50.3, 50.2, 50.5, 50.0, 50.4],
        "unauthorized": [50.3, 50.1, 50.4, 50.2, 50.0, 50.3, 50.2, 50.1],
        "disabled": [50.1, 50.2, 50.3, 50.4, 50.2, 50.1, 50.5, 50.0],
    }


class PoolRejectionTimingFloorTests(unittest.TestCase):
    def setUp(self):
        self.mod = load_module()

    def test_offline_samples_do_not_claim_production_remeasure(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "samples.json"
            path.write_text(json.dumps(passing_samples()))
            buf = io.StringIO()
            with redirect_stdout(buf):
                code = self.mod.main(["--samples-json", str(path), "--environment", "local"])
            self.assertEqual(code, 0)
            self.assertIn('"production_remeasure_complete": false', buf.getvalue())

    def test_offline_result_json_marks_remeasure_incomplete(self):
        timing = self.mod.evaluate_samples(passing_samples(), floor_ms=50, method="offline_samples_json")
        result = self.mod.build_result(
            timing,
            environment="local",
            source="samples-json",
            production_host=False,
            allow_production=False,
        )
        self.assertTrue(timing["within_r007_bounds"])
        self.assertFalse(result["production_remeasure_complete"])
        self.assertEqual(result["environment"], "local")
        self.assertEqual(result["source"], "samples-json")
        self.assertGreaterEqual(result["pool_rejection_timing"]["floor_ms"], 50)

    def test_refuses_production_host_without_allow(self):
        with self.assertRaises(SystemExit) as raised:
            self.mod.main(
                [
                    "--base-url",
                    "https://coordinator.malibu.tech",
                    "--environment",
                    "production",
                    "--pool-id",
                    "pool-a",
                    "--authorized-account",
                    "acct-a",
                    "--unauthorized-account",
                    "acct-b",
                ]
            )
        self.assertIn("refusing production host", str(raised.exception))

    def test_refuses_missing_source(self):
        with self.assertRaises(SystemExit) as raised:
            self.mod.main([])
        self.assertIn("provide --samples-json", str(raised.exception))

    def test_tail_sample_is_not_ignored_by_p99(self):
        samples = {
            "unknown": [50.0] * 15 + [500.0],
            "unauthorized": [50.0] * 16,
            "disabled": [50.0] * 16,
        }
        timing = self.mod.evaluate_samples(samples, floor_ms=50, method="operator_http_probe")
        self.assertFalse(timing["within_r007_bounds"])
        self.assertGreater(timing["p99_delta_ms"], 25)
        result = self.mod.build_result(
            timing,
            environment="production",
            source="http",
            production_host=True,
            allow_production=True,
        )
        self.assertFalse(result["production_remeasure_complete"])

    def test_distinguishable_samples_fail_bounds(self):
        samples = {
            "unknown": [50.0] * 8,
            "unauthorized": [80.0] * 8,
            "disabled": [50.0] * 8,
        }
        timing = self.mod.evaluate_samples(samples, floor_ms=50, method="offline_samples_json")
        self.assertFalse(timing["within_r007_bounds"])
        self.assertGreater(timing["p95_delta_ms"], 15)

    def test_samples_below_floor_fail_closed(self):
        samples = passing_samples()
        samples["unknown"][0] = 10.0
        with self.assertRaises(SystemExit) as raised:
            self.mod.evaluate_samples(samples, floor_ms=50, method="offline_samples_json")
        self.assertIn("below floor_ms", str(raised.exception))

    def test_production_remeasure_complete_requires_http_production_host(self):
        timing = self.mod.evaluate_samples(passing_samples(), floor_ms=50, method="operator_http_probe")
        local_http = self.mod.build_result(
            timing,
            environment="production",
            source="http",
            production_host=False,
            allow_production=True,
        )
        self.assertFalse(local_http["production_remeasure_complete"])
        complete = self.mod.build_result(
            timing,
            environment="production",
            source="http",
            production_host=True,
            allow_production=True,
        )
        self.assertTrue(complete["production_remeasure_complete"])
        json_on_prod_env = self.mod.build_result(
            timing,
            environment="production",
            source="samples-json",
            production_host=True,
            allow_production=True,
        )
        self.assertFalse(json_on_prod_env["production_remeasure_complete"])


if __name__ == "__main__":
    unittest.main()
