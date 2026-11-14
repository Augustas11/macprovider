"""Pure helpers of scripts/lab/nemotron-bolt/bolt_reference_oracle.py (#2329); no torch, no model."""

import ast
import hashlib
import importlib.util
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "lab/nemotron-bolt/bolt_reference_oracle.py"
SPEC = importlib.util.spec_from_file_location("bolt_reference_oracle", SCRIPT)
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)


def corpus_unit_of(path):
    """The `unit` string literal inside `corpus_ids` of a reference-lane script."""
    for node in ast.walk(ast.parse(path.read_text())):
        if isinstance(node, ast.FunctionDef) and node.name == "corpus_ids":
            for stmt in ast.walk(node):
                if isinstance(stmt, ast.Assign) and getattr(stmt.targets[0], "id", None) == "unit":
                    return ast.literal_eval(stmt.value)
    raise AssertionError(f"no corpus unit in {path}")


class PromptTests(unittest.TestCase):
    def test_unit_is_the_reference_lane_corpus(self):
        self.assertEqual(tool.UNIT, corpus_unit_of(ROOT / "lab/cb-studio/glm53_bench_vlm.py"))

    def test_blocks_in_order_cut_to_n(self):
        seen = []

        def encode(text):
            seen.append(text)
            return [len(seen)] * 7

        ids = tool.build_prompt_ids(encode, 20)
        self.assertEqual(ids, [1] * 7 + [2] * 7 + [3] * 6)
        self.assertEqual(seen, [f"# block {i}\n" + tool.UNIT for i in range(3)])

    def test_offset_starts_block_numbering(self):
        seen = []
        tool.build_prompt_ids(lambda t: seen.append(t) or [0] * 50, 10, offset=9)
        self.assertEqual(seen, ["# block 9\n" + tool.UNIT])


class OracleDocTests(unittest.TestCase):
    def test_glm_parity_oracle_v1_fields(self):
        doc = tool.oracle_doc("oracle_1024.npz", b"npz-bytes", [5, 6], [7, 8, 9], [[7, 1]], [[2.5, 1.0]])
        self.assertEqual(list(doc), ["schema", "source", "source_sha256", "prompt", "greedy", "top_idx", "top_logit"])
        self.assertEqual(doc["schema"], "glm-parity-oracle-v1")
        self.assertEqual(doc["source"], "oracle_1024.npz")
        self.assertEqual(doc["source_sha256"], hashlib.sha256(b"npz-bytes").hexdigest())
        self.assertEqual(doc["top_logit"], [[2.5, 1.0]])

    def test_rejects_shapes_glm_parity_rejects(self):
        with self.assertRaises(ValueError):
            tool.oracle_doc("o.npz", b"", [1], [2], [[1, 2], [3, 4]], [[1.0, 0.0], [1.0, 0.0]])  # more logit steps than greedy
        with self.assertRaises(ValueError):
            tool.oracle_doc("o.npz", b"", [1], [2], [[1, 2]], [[1.0]])
        with self.assertRaises(ValueError):
            tool.oracle_doc("o.npz", b"", [], [2], [], [])


class SnapshotTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "config.json").write_text("{}")
        self.pinned = {"config.json": hashlib.sha256(b"{}").hexdigest()}
        meta = self.root / ".cache/huggingface/download"
        meta.mkdir(parents=True)
        (meta / "config.json.metadata").write_text("abc123\netag\n1.0\n")

    def test_pinned_snapshot_passes(self):
        self.assertEqual(tool.snapshot_problems(self.root, "abc123", self.pinned), [])

    def test_other_commit_or_edited_file_is_refused(self):
        self.assertTrue(tool.snapshot_problems(self.root, "def456", self.pinned))
        (self.root / "config.json").write_text('{"x": 1}')
        problems = tool.snapshot_problems(self.root, "abc123", self.pinned)
        self.assertEqual(len(problems), 1)
        self.assertIn("config.json sha256", problems[0])

    def test_missing_file_and_metadata_are_refused(self):
        (self.root / ".cache/huggingface/download/config.json.metadata").unlink()
        problems = tool.snapshot_problems(self.root, "abc123", {**self.pinned, "modeling.py": "0" * 64})
        self.assertIn("missing modeling.py", problems)
        self.assertTrue(any("snapshot commit None" in p for p in problems))

    def test_pins_cover_every_file_the_lane_imports_or_reads(self):
        for name in ("__init__.py", "config.json", "configuration_nemotron_h.py", "configuration_nemotron_h_puzzle.py",
                     "modeling_nemotron_h.py", "modeling_nemotron_h_puzzle.py", "model.safetensors.index.json",
                     "tokenizer.json", "tokenizer_config.json"):
            self.assertRegex(tool.PINNED_SHA256[name], r"^[0-9a-f]{64}$")
        self.assertRegex(tool.PINNED_REVISION, r"^[0-9a-f]{40}$")


class WeightNameTests(unittest.TestCase):
    def test_language_model_keys_map_to_the_causal_lm(self):
        self.assertEqual(tool.map_weight_name("language_model.backbone.layers.3.mixer.A_log"), "model.layers.3.mixer.A_log")
        self.assertEqual(tool.map_weight_name("language_model.backbone.embeddings.weight"), "model.embeddings.weight")
        self.assertEqual(tool.map_weight_name("language_model.lm_head.weight"), "lm_head.weight")
        self.assertIsNone(tool.map_weight_name("vision_model.encoder.layer.0.weight"))
        self.assertIsNone(tool.map_weight_name("mlp1.1.weight"))


class SelfCheckVerdictTests(unittest.TestCase):
    REF = [[5.0, 4.0], [3.0, 2.95], [6.0, 1.0]]

    def test_same_tokens_pass(self):
        v = tool.self_check_verdict([1, 2, 3], self.REF, [1, 2, 3], [[5.01, 4.0], [3.0, 2.95], [6.0, 1.0]])
        self.assertTrue(v["pass"])
        self.assertAlmostEqual(v["max_abs_logit_diff"], 0.01)

    def test_divergence_on_a_tie_within_measured_noise_passes(self):
        v = tool.self_check_verdict([1, 2, 3], self.REF, [1, 9, 3], [[5.1, 4.0], [2.9, 3.0], [6.0, 1.0]])
        self.assertEqual(v["first_divergence"], 1)
        self.assertTrue(v["pass"])  # gap 0.05 < 0.1 measured at step 0

    def test_divergence_on_a_clear_winner_fails(self):
        v = tool.self_check_verdict([1, 2, 3], self.REF, [1, 2, 9], [[5.0, 4.0], [3.0, 2.95], [1.0, 6.0]])
        self.assertEqual(v["first_divergence"], 2)
        self.assertFalse(v["pass"])

    def test_divergence_at_step_zero_fails(self):
        v = tool.self_check_verdict([1, 2], self.REF[:2], [9, 2], [[4.0, 5.0], [3.0, 2.95]])
        self.assertFalse(v["pass"])


if __name__ == "__main__":
    unittest.main()
