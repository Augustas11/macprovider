"""SPEC-044-R015: model-facts.json schema, catalog binding and Swift copy."""

import copy
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("model_facts", ROOT / "scripts/model-facts.py")
model_facts = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(model_facts)


class ModelFactsTest(unittest.TestCase):
    def setUp(self):
        self.facts = model_facts.load_json(model_facts.FACTS_PATH)
        self.candidates = model_facts.load_json(model_facts.CANDIDATES_PATH)

    def test_checked_in_facts_are_valid_and_embedded(self):
        self.assertEqual(model_facts.main(["model-facts.py", "check"]), 0)

    def test_checked_in_facts_bind_to_the_catalog(self):
        # Drift is a warning (a catalog change never waits on this file), but
        # the reviewed facts must bind to at least some catalog rows.
        rows, catalog = self.facts["rows"], self.candidates["rows"]
        bound = [k for k in rows if k in catalog
                 and (rows[k]["model_id"], rows[k]["model_revision"]) == (catalog[k]["model_id"], catalog[k].get("model_revision"))]
        self.assertTrue(bound)

    def test_binding_drift_is_a_warning_not_a_failure(self):
        facts = copy.deepcopy(self.facts)
        key = sorted(facts["rows"])[0]
        facts["rows"][key]["model_revision"] = "0" * 40
        del facts["rows"][sorted(facts["rows"])[1]]
        model_facts.validate(facts)
        warnings = model_facts.binding_warnings(facts, self.candidates)
        self.assertEqual(len(warnings), 2)

    def test_schema_rejections(self):
        key = sorted(self.facts["rows"])[0]
        cases = {
            "unknown capability": ("capabilities", ["tools", "audio"]),
            "unsorted capabilities": ("capabilities", ["tools", "reasoning"]),
            "duplicate capability": ("capabilities", ["tools", "tools"]),
            "context too small": ("context_length", 512),
            "context too large": ("context_length", 33_554_432),
            "context not an integer": ("context_length", 131072.0),
            "context boolean": ("context_length", True),
            "source not a config field": ("context_length_source", "model card"),
            "revision not hex": ("model_revision", "main"),
            "model id with a Swift escape": ("model_id", "org/a\\#(fatalError())"),
        }
        for name, (field, value) in cases.items():
            with self.subTest(name):
                facts = copy.deepcopy(self.facts)
                facts["rows"][key][field] = value
                with self.assertRaises(model_facts.FactsError):
                    model_facts.validate(facts)
        with self.subTest("extra row key"):
            facts = copy.deepcopy(self.facts)
            facts["rows"][key]["license"] = "mit"
            with self.assertRaises(model_facts.FactsError):
                model_facts.validate(facts)
        with self.subTest("wrong schema"):
            facts = copy.deepcopy(self.facts)
            facts["schema_version"] = "macprovider.model-facts.v2"
            with self.assertRaises(model_facts.FactsError):
                model_facts.validate(facts)

    def test_duplicate_json_keys_are_rejected(self):
        with self.assertRaises(model_facts.FactsError):
            model_facts._reject_duplicates([("a", 1), ("a", 2)])

    def test_swift_copy_is_a_raw_string_of_the_exact_bytes(self):
        source = model_facts.swift_source(b'{"a": 1}\n')
        self.assertIn('static let bakedJSON = #"""\n{"a": 1}\n"""#\n', source)
        for unsafe in (b'{"a": "x"""#"}\n', b'{"a": "x\\#(fatalError())"}\n', b'{"a": 1}'):
            with self.assertRaises(model_facts.FactsError, msg=unsafe):
                model_facts.swift_source(unsafe)


if __name__ == "__main__":
    unittest.main()
