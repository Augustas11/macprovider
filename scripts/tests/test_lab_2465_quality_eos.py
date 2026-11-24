import importlib.util
import json
import pathlib
import tempfile
import types
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("quality", ROOT / "scripts" / "lab" / "2465" / "quality.py")
q = importlib.util.module_from_spec(spec)
spec.loader.exec_module(q)


class EosIdsTests(unittest.TestCase):
    def ids(self, tokenizer, gen_cfg=None):
        with tempfile.TemporaryDirectory() as d:
            if gen_cfg is not None:
                (pathlib.Path(d) / "generation_config.json").write_text(json.dumps(gen_cfg))
            return q.eos_ids(d, tokenizer)

    def test_int_eos_token_ids_does_not_crash(self):
        # #2466: the mlx-vlm tokenizer wrapper gave an int, which raised
        # TypeError: 'int' object is not iterable.
        tok = types.SimpleNamespace(eos_token_id=7, eos_token_ids=9)
        self.assertEqual(self.ids(tok), {7, 9})

    def test_set_and_list_eos_token_ids(self):
        self.assertEqual(self.ids(types.SimpleNamespace(eos_token_id=1, eos_token_ids={2, 3})), {1, 2, 3})
        self.assertEqual(self.ids(types.SimpleNamespace(eos_token_id=None, eos_token_ids=[4, 5])), {4, 5})

    def test_missing_attrs_and_generation_config(self):
        self.assertEqual(self.ids(types.SimpleNamespace(), {"eos_token_id": [6, 8]}), {6, 8})
        self.assertEqual(self.ids(types.SimpleNamespace(), {"eos_token_id": 6}), {6})
        self.assertEqual(self.ids(types.SimpleNamespace(eos_token_id=1, eos_token_ids=None)), {1})


if __name__ == "__main__":
    unittest.main()
