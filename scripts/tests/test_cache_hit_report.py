import importlib.util
import contextlib
import io
from datetime import datetime, timezone
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "cache_hit_report", Path(__file__).parents[1] / "ops" / "cache-hit-report.py")
report = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report)


def sample(minute, lookups, hits, process="one", model="glm"):
    return dict(observed_at=f"2026-10-29T00:{minute:02d}:00Z", process_id=process,
                models=[dict(model_id=model, lookups=lookups, hits=hits,
                             cached_prompt_tokens=hits * 100,
                             misses={"cold_start": lookups - hits},
                             evictions={"lru_byte_limit": lookups // 10})])


class CacheHitReportTests(unittest.TestCase):
    now = datetime(2026, 10, 29, 0, 10, tzinfo=timezone.utc)

    def summarize(self, samples, seconds=600):
        return report.summarize([dict(provider_id="p", conversation_cache_history=samples)],
                                seconds, self.now)

    def test_rates_use_deltas_and_reason_counters(self):
        result = self.summarize([sample(0, 100, 20), sample(10, 120, 30)])
        row = result["models"][0]
        self.assertEqual(row["lookups"], 20)
        self.assertEqual(row["hit_rate"], .5)
        self.assertEqual(row["cached_tokens_per_request"], 50)
        self.assertEqual(row["misses"], {"cold_start": 10})
        self.assertEqual(row["evictions"], {"lru_byte_limit": 2})
        self.assertEqual(row["provider_seconds"], 600)

    def test_aggregates_by_model_across_providers(self):
        providers = [dict(provider_id=p, conversation_cache_history=[sample(0, 0, 0), sample(10, n, 2)])
                     for p, n in (("a", 10), ("b", 30))]
        row = report.summarize(providers, 600, self.now)["models"][0]
        self.assertEqual(row["hit_rate"], .1)
        self.assertEqual(row["providers"], ["a", "b"])

    def test_restart_is_excluded_even_if_new_counters_are_larger(self):
        result = self.summarize([sample(0, 10, 2), sample(5, 20, 5, "two"),
                                 sample(10, 30, 10, "two")])
        self.assertEqual(result["excluded_intervals"], 1)
        self.assertEqual(result["models"][0]["lookups"], 10)

    def test_counter_regression_and_new_model_are_excluded(self):
        result = self.summarize([sample(0, 20, 5), sample(5, 10, 2),
                                 sample(10, 30, 5, model="other")])
        self.assertEqual(result["models"], [])
        self.assertEqual(result["excluded_intervals"], 2)

    def test_partial_window_and_future_samples_are_excluded(self):
        result = self.summarize([sample(0, 0, 0), sample(8, 10, 5),
                                 sample(10, 20, 10), sample(11, 30, 15)], 180)
        self.assertEqual(result["models"][0]["lookups"], 10)
        self.assertEqual(result["models"][0]["provider_seconds"], 120)

    def test_empty_and_zero_traffic_have_no_fabricated_rate(self):
        self.assertEqual(self.summarize([])["models"], [])
        row = self.summarize([sample(0, 0, 0), sample(10, 0, 0)])["models"][0]
        self.assertIsNone(row["hit_rate"])
        self.assertIsNone(row["cached_tokens_per_request"])

    def test_pagination_and_operator_auth(self):
        import io
        import json
        pages = [dict(providers=[dict(provider_id="a")], next_after="a", next_after_seen="ts"),
                 dict(providers=[dict(provider_id="b")])]
        with patch.object(report, "urlopen", side_effect=[
                io.BytesIO(json.dumps(page).encode()) for page in pages]) as fetch:
            self.assertEqual(len(report.fetch_providers("https://coordinator.example", "secret")), 2)
            request = fetch.call_args_list[1].args[0]
            self.assertEqual(request.get_header("Authorization"), "Bearer secret")
            self.assertIn("after=a&after_seen=ts", request.full_url)

    def test_remote_plaintext_rejected_before_sending_token(self):
        with self.assertRaises(ValueError):
            report.fetch_providers("http://remote.example", "secret")

    def test_text_output_escapes_untrusted_model_labels(self):
        model = "glm\x1b[2J"
        providers = [dict(provider_id="p", conversation_cache_history=[
            sample(0, 0, 0, model=model), sample(10, 10, 5, model=model)])]
        output = io.StringIO()
        summary = report.summarize(providers, 600, self.now)
        with patch.object(report.sys, "argv", ["report", "--coordinator", "https://example.test"]), \
                patch.dict(report.os.environ, {"MACPROVIDER_OPERATOR_TOKEN": "secret"}), \
                patch.object(report, "fetch_providers", return_value=providers), \
                patch.object(report, "summarize", return_value=summary), \
                contextlib.redirect_stdout(output):
            self.assertEqual(report.main(), 0)
        self.assertNotIn("\x1b", output.getvalue())
        self.assertIn("\\u001b", output.getvalue())


if __name__ == "__main__":
    unittest.main()
