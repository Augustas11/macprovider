import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from fractions import Fraction
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "measure_cb_promotion_economics.py"
ROOT = SCRIPT.parent.parent
SPEC = importlib.util.spec_from_file_location("cb_promotion_economics", SCRIPT)
CALCULATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CALCULATOR)


def matrix_row(target=512, rows=1, mode="serial"):
    return {
        "L_target": target,
        "rows": rows,
        "mode": mode,
        "prompt_tokens": 100 if rows == 1 else 100.5,
        "completion_tokens": 10 * rows,
        "ttft_median_s": 1.0,
        "ttft_max_s": float(rows),
        "prefill_tok_s_median": 100.0,
        "decode_tok_s_per_request_median": 20.0,
        "aggregate_decode_tok_s": 20.0,
        "wall_s": float(rows + 1),
    }


def matrix_bytes(rows=None):
    rows = rows or [matrix_row(), matrix_row(rows=2, mode="batched")]
    return ("\n".join(json.dumps(row, separators=(",", ":")) for row in rows) + "\n").encode()


def rate_card(version=None, row_overrides=None, default_overrides=None):
    default = {
        "prompt_rate_per_mtok": 500_000,
        "prompt_cache_hit_rate_per_mtok": 125_000,
        "completion_rate_per_mtok": 1_000_000,
        "provider_share_bps": 9_000,
        "global_multiplier_ppm": 1_000_000,
    }
    default.update(default_overrides or {})
    selected = {
        "prompt_rate_per_mtok": 240_000,
        "prompt_cache_hit_rate_per_mtok": 60_000,
        "completion_rate_per_mtok": 2_160_000,
        "provider_share_bps": default["provider_share_bps"],
        "global_multiplier_ppm": default["global_multiplier_ppm"],
    }
    selected.update(row_overrides or {})
    value = {
        "generated_at": "2026-09-25T00:54:00Z",
        "policy_version": "policy-v1",
        "rows": {"default": default, "qwen3.6-27b": selected},
        "usd_per_million_credits": 1,
        "version": "pending",
    }
    value["version"] = version or CALCULATOR.rate_card_projection_hash(value)
    return value


def rate_card_bytes(value=None):
    return json.dumps(value or rate_card(), separators=(",", ":")).encode()


class PromotionEconomicsTests(unittest.TestCase):
    def report(self, matrix=None, card=None):
        return CALCULATOR.build_report(
            matrix or matrix_bytes(), card or rate_card_bytes(), "qwen3.6-27b"
        )

    def test_builds_deterministic_modeled_proxy_report(self):
        matrix = matrix_bytes()
        card = rate_card_bytes()
        first = self.report(matrix, card)
        second = self.report(matrix, card)
        self.assertEqual(CALCULATOR.canonical_json(first), CALCULATOR.canonical_json(second))
        self.assertEqual(first["inputs"]["matrix_sha256"], CALCULATOR.sha256(matrix))
        self.assertEqual(first["inputs"]["rate_card_sha256"], CALCULATOR.sha256(card))
        self.assertEqual(first["rate_card"]["row_key"], "qwen3.6-27b")
        batched = first["observations"][1]
        self.assertEqual(batched["median_prompt_tokens_per_request"], "100.500")
        self.assertEqual(batched["modeled_prompt_tokens"], "201.000")
        self.assertEqual(batched["aggregate_completion_tokens"], 20)
        self.assertEqual(
            first["method"]["classification"],
            "deterministic_modeled_proxy_not_ledger_settlement",
        )
        self.assertIn(
            "exact_settled_credits_cannot_be_reconstructed_for_multi_request_rows",
            first["method"]["limitations"],
        )
        self.assertEqual(batched["worst_ttft_ratio_vs_serial"], "2.000000")
        self.assertTrue(CALCULATOR.canonical_json(first).endswith(b"\n"))

    def test_checked_in_campaign_inputs_pin_modeled_results_and_exact_hashes(self):
        matrix = (
            ROOT
            / "docs/runbooks/data/cb-perf-2026-09-25/clean-final/matrix.jsonl"
        ).read_bytes()
        card = (ROOT / "phase3-binary/catalog/autotune/rate-card.json").read_bytes()
        report = self.report(matrix, card)
        self.assertEqual(
            report["inputs"],
            {
                "matrix_sha256": "f1df7ccbcaf1a1602f41f5d0c802d3ea77c253ecf94fe0740e721ff4b6689d2b",
                "rate_card_sha256": "20d62a3d8c934560566ca94a861a6c7a203472e38c7f7d9db85959ae5d661173",
            },
        )
        by_key = {
            (row["L_target"], row["mode"], row["rows"]): row
            for row in report["observations"]
        }
        self.assertEqual(
            by_key[(512, "batched", 8)]["modeled_earnings_hour_ratio_vs_serial"],
            "1.381107",
        )
        self.assertEqual(
            by_key[(1536, "batched", 8)]["modeled_provider_usd_per_wall_hour"],
            "0.281282",
        )
        self.assertEqual(
            by_key[(4096, "batched", 8)]["worst_ttft_ratio_vs_serial"],
            "9.554386",
        )

    def test_modeled_credits_keep_fractional_provider_share_unrounded(self):
        rate = {
            "prompt_rate_per_mtok": 1_000_000,
            "completion_rate_per_mtok": 2_000_000,
            "global_multiplier_ppm": 1_500_000,
            "provider_share_bps": 7_500,
        }
        self.assertEqual(
            CALCULATOR.compute_modeled_credits(1, 1, rate),
            (Fraction(9, 2), Fraction(27, 8)),
        )
        self.assertEqual(CALCULATOR.decimal_text(Fraction(5, 2), 0), "2")
        self.assertEqual(CALCULATOR.decimal_text(Fraction(7, 2), 0), "4")

    def test_rejects_duplicate_json_keys(self):
        bad_matrix = matrix_bytes().replace(b'"rows":1', b'"rows":1,"rows":1', 1)
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "duplicate JSON key"):
            self.report(bad_matrix)
        bad_card = rate_card_bytes().replace(b'"version":', b'"version":"x","version":', 1)
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "duplicate JSON key"):
            self.report(card=bad_card)

    def test_rejects_duplicate_and_ambiguous_observations(self):
        duplicate = [matrix_row(), matrix_row(), matrix_row(rows=2, mode="batched")]
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "duplicate observation"):
            self.report(matrix_bytes(duplicate))
        bad_serial = [matrix_row(rows=2), matrix_row(rows=2, mode="batched")]
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "serial control must have rows=1"):
            self.report(matrix_bytes(bad_serial))

    def test_rejects_missing_or_orphaned_serial_control(self):
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "missing serial control"):
            self.report(matrix_bytes([matrix_row(rows=2, mode="batched")]))
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "has no batched rows"):
            self.report(matrix_bytes([matrix_row()]))

    def test_rejects_nonpositive_wall_and_invalid_numeric_types(self):
        rows = [matrix_row(), matrix_row(rows=2, mode="batched")]
        rows[1]["wall_s"] = 0
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "wall_s: must be > 0"):
            self.report(matrix_bytes(rows))
        rows[1]["wall_s"] = True
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "wall_s: must be a JSON number"):
            self.report(matrix_bytes(rows))
        rows[1]["rows"] = True
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "rows: must be an integer"):
            self.report(matrix_bytes(rows))

    def test_rejects_nonfinite_numbers(self):
        payload = matrix_bytes().replace(b'"wall_s":3.0', b'"wall_s":NaN')
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "non-finite JSON number"):
            self.report(payload)

    def test_rejects_oversized_integer_literal(self):
        payload = matrix_bytes().replace(b'"L_target":512', b'"L_target":' + b"9" * 5000, 1)
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "integer literal has too many digits"):
            self.report(payload)

    def test_rejects_extreme_decimal_exponents(self):
        for value in (b"1e999999", b"1e-999999"):
            with self.subTest(value=value):
                payload = matrix_bytes().replace(b'"wall_s":3.0', b'"wall_s":' + value)
                with self.assertRaisesRegex(CALCULATOR.ValidationError, "exponent is out of range"):
                    self.report(payload)

    def test_rejects_excessive_decimal_precision(self):
        values = (
            (b"0.1234567890", "fractional digits"),
            (b"12345678901.123456789", "significant digits"),
            (b"1.0e-9", "scale is out of range"),
        )
        for value, pattern in values:
            with self.subTest(value=value):
                payload = matrix_bytes().replace(b'"wall_s":3.0', b'"wall_s":' + value)
                with self.assertRaisesRegex(CALCULATOR.ValidationError, pattern):
                    self.report(payload)

    def test_rejects_excessive_json_nesting(self):
        payload = b"[" * 2000 + b"0" + b"]" * 2000
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "JSON nesting is too deep"):
            CALCULATOR.load_json_bytes(payload, "matrix")

    def test_accepts_fractional_modeled_prompt_total_and_rejects_inconsistent_completion(self):
        rows = [matrix_row(), matrix_row(rows=2, mode="batched")]
        rows[1]["prompt_tokens"] = 100.25
        report = self.report(matrix_bytes(rows))
        self.assertEqual(report["observations"][1]["modeled_prompt_tokens"], "200.500")
        rows[1]["completion_tokens"] = 19
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "inconsistent completion token total"):
            self.report(matrix_bytes(rows))

    def test_rejects_malformed_rows(self):
        rows = [matrix_row(), matrix_row(rows=2, mode="batched")]
        del rows[1]["wall_s"]
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "fields mismatch"):
            self.report(matrix_bytes(rows))
        rows = [matrix_row(), matrix_row(rows=2, mode="batched")]
        rows[1]["unexpected"] = 1
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "fields mismatch"):
            self.report(matrix_bytes(rows))

    def test_rejects_invalid_rate_card_economics_and_version(self):
        invalid_cards = [
            rate_card(row_overrides={"provider_share_bps": 10_001}),
            rate_card(row_overrides={"prompt_cache_hit_rate_per_mtok": 240_001}),
            rate_card(row_overrides={"global_multiplier_ppm": -1}, default_overrides={"global_multiplier_ppm": -1}),
            rate_card(row_overrides={"provider_share_bps": 8_000}),
            rate_card(version="0" * 64),
        ]
        patterns = ["provider_share_bps", "cache-hit", "global_multiplier_ppm", "release-global", "projection hash"]
        for card, pattern in zip(invalid_cards, patterns):
            with self.subTest(pattern=pattern):
                with self.assertRaisesRegex(CALCULATOR.ValidationError, pattern):
                    self.report(card=rate_card_bytes(card))

    def test_rejects_missing_or_ambiguous_selected_rate_row(self):
        with self.assertRaisesRegex(CALCULATOR.ValidationError, "selected row not found"):
            CALCULATOR.build_report(matrix_bytes(), rate_card_bytes(), "missing")

    def test_cli_writes_canonical_create_only_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            matrix_path = root / "matrix.jsonl"
            card_path = root / "rate-card.json"
            output_path = root / "report.json"
            matrix_path.write_bytes(matrix_bytes())
            card_path.write_bytes(rate_card_bytes())
            command = [
                sys.executable,
                str(SCRIPT),
                str(matrix_path),
                str(card_path),
                "--rate-card-row",
                "qwen3.6-27b",
                "--output",
                str(output_path),
            ]
            first = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(first.returncode, 0, first.stderr)
            payload = output_path.read_bytes()
            self.assertEqual(payload, CALCULATOR.canonical_json(json.loads(payload)))
            second = subprocess.run(command, text=True, capture_output=True, check=False)
            self.assertEqual(second.returncode, 2)
            self.assertIn("output already exists", second.stderr)

    def test_cli_help_describes_modeled_output_and_hash_only_validation(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--help"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("modeled earnings/hour proxy", result.stdout)
        self.assertIn("signature not verified", result.stdout)

    def test_read_bounded_rejects_symlink(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / "target.json"
            link = root / "link.json"
            target.write_bytes(b"{}")
            link.symlink_to(target)
            with self.assertRaisesRegex(CALCULATOR.ValidationError, "no-follow"):
                CALCULATOR.read_bounded(link, "matrix")

    def test_read_bounded_rejects_oversize_input(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "oversize.json"
            with path.open("wb") as handle:
                handle.truncate(CALCULATOR.MAX_INPUT_BYTES + 1)
            with self.assertRaisesRegex(CALCULATOR.ValidationError, "input exceeds"):
                CALCULATOR.read_bounded(path, "matrix")


if __name__ == "__main__":
    unittest.main()
