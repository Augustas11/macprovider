"""Real-weight acceptance stays on Studio; low-memory cases use fixtures."""

import json
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ImageAcceptanceHostTests(unittest.TestCase):
    def test_create_requirement_names_studio_and_low_memory_fixtures(self):
        text = (ROOT / "specs/SPEC-025-native-mac-app.md").read_text()
        requirement = text[text.index("- **SPEC-025-R021"):] if "- **SPEC-025-R021" in text else text
        self.assertNotIn("lab Air", requirement)
        self.assertIn("designated Mac Studio", requirement)
        self.assertIn("Low-memory coverage MUST use fixtures", requirement)
        self.assertIn("acceptance MUST NOT run on the operator Mac", requirement)

    def test_both_image_conformance_gaps_preserve_studio_boundary(self):
        document = json.loads((ROOT / "specs/CONFORMANCE.json").read_text())
        # Requirement entries may be nested under a spec or a top-level list.
        def entries(value):
            if isinstance(value, dict):
                if "requirement_id" in value:
                    yield value
                for child in value.values():
                    yield from entries(child)
            elif isinstance(value, list):
                for child in value:
                    yield from entries(child)

        found = {entry["requirement_id"]: entry for entry in entries(document)
                 if entry["requirement_id"] in {"SPEC-001-R014", "SPEC-025-R021"}}
        self.assertEqual(set(found), {"SPEC-001-R014", "SPEC-025-R021"})
        for requirement, entry in found.items():
            with self.subTest(requirement=requirement):
                rationale = entry["gap"]["rationale"]
                self.assertIn("designated Mac Studio", rationale)
                self.assertIn("Low-memory coverage uses fixtures", rationale)
                self.assertNotIn("lab Air", rationale)


if __name__ == "__main__":
    unittest.main()
