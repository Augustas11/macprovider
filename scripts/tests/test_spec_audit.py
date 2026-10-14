import datetime as dt
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts import spec_audit as sa


def _git_repo(tmp: Path) -> None:
    subprocess.run(["git", "init", "-q", str(tmp)], check=True)
    subprocess.run(["git", "-C", str(tmp), "-c", "user.email=a@b.c", "-c", "user.name=t", "commit", "--allow-empty", "-qm", "init"], check=True)


class NormTests(unittest.TestCase):
    def test_norm_collapses_whitespace_markdown_and_case(self):
        self.assertEqual(sa.norm("A  `B`\n**c**"), "a b c")

    def test_verify_finding_accepts_verbatim_and_rejects_invented(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            (root / "a.go").write_text("func Pay() {\n\treturn 1\n}\n")
            fc = sa.FileCache(root)
            spec = sa.norm("The system MUST settle within 24 hours.")
            ok = sa.verify_finding(root, fc, spec, {
                "spec_quote": "MUST settle within 24 hours", "code_path": "a.go", "code_quote": "1: func Pay() {\n2: \treturn 1",
            })
            self.assertTrue(ok["verified"])
            bad_spec = sa.verify_finding(root, fc, spec, {"spec_quote": "MUST settle within 1 hour", "code_path": "a.go", "code_quote": "return 1"})
            self.assertFalse(bad_spec["verified"])
            bad_code = sa.verify_finding(root, fc, spec, {"spec_quote": "MUST settle", "code_path": "a.go", "code_quote": "return 2"})
            self.assertFalse(bad_code["verified"])
            self.assertFalse(sa.verify_finding(root, fc, spec, {"spec_quote": "", "code_path": "", "code_quote": ""})["verified"])
            short = sa.verify_finding(root, fc, spec, {"spec_quote": "MUST", "code_path": "a.go", "code_quote": "return 1", "verdict": "UNKNOWN"})
            self.assertFalse(short["verified"])
            spec_only = {"spec_quote": "MUST settle within 24 hours", "code_path": "", "code_quote": "", "verdict": "CODE_BUG"}
            self.assertFalse(sa.verify_finding(root, fc, spec, spec_only)["verified"])
            self.assertTrue(sa.verify_finding(root, fc, spec, {**spec_only, "verdict": "UNKNOWN"})["verified"])
            outside = {"spec_quote": "MUST settle within 24 hours", "code_path": "a.go", "code_quote": "func Pay() {\n\treturn 1", "verdict": "CODE_BUG"}
            self.assertTrue(sa.verify_finding(root, fc, spec, outside, {"a.go"})["verified"])
            self.assertFalse(sa.verify_finding(root, fc, spec, outside, {"b.go"})["verified"])

    def test_path_traversal_is_not_readable(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t) / "repo"
            root.mkdir()
            (Path(t) / "secret.txt").write_text("x")
            self.assertIsNone(sa.FileCache(root).text("../secret.txt"))


class HeaderTests(unittest.TestCase):
    def test_parse_header(self):
        text = '# SPEC-001 — T\n\n**Version:** 1.2\n**Status:** **LOCKED** at v1.2\n\n```json\n{"status": "draft", "version": "1.2"}\n```\n'
        h = sa.parse_spec_header(text)
        self.assertEqual(h["json"]["status"], "draft")
        self.assertEqual(h["version_prose"], "1.2")
        self.assertIn("LOCKED", h["status_prose"])

    def test_bad_json_header_is_none(self):
        self.assertIsNone(sa.parse_spec_header("```json\n{nope\n```")["json"])


class RequirementCheckTests(unittest.TestCase):
    def test_flags_missing_files_selectors_tests_and_evidence(self):
        with tempfile.TemporaryDirectory() as t:
            root = Path(t)
            _git_repo(root)
            (root / "impl.go").write_text("func Present() {}\n")
            (root / "t_test.go").write_text("func TestOk(t *testing.T) {}\n")
            (root / "check.sh").write_text("echo 'case one'\n")
            (root / "journeys").mkdir()
            ev = root / "ev.json"
            ev.write_text("{}")
            good_sha = hashlib.sha256(b"{}").hexdigest()
            now = dt.date(2026, 10, 9)
            req = {
                "requirement_id": "SPEC-001-R001", "spec_id": "SPEC-001", "state": "conformant",
                "implementation": ["impl.go:func Present", "impl.go:func Gone", "gone.go:x"],
                "tests": ["t_test.go::TestOk", "t_test.go::TestGone", "check.sh:case one", "nope.sh:y"],
                "journeys": ["JOURNEY-X"],
                "evidence": [
                    {"artifact": f"sha256:{good_sha}", "source": "ev.json", "expires_at": "2026-10-20"},
                    {"artifact": "sha256:" + "0" * 64, "source": "ev.json", "expires_at": "2026-01-01"},
                    {"artifact": "commit:" + "1" * 40, "source": None, "expires_at": "2027-01-01"},
                ],
                "gap": None,
            }
            res = sa.check_requirements(root, sa.FileCache(root), [req], now)
            kinds = sorted(p["kind"] for p in res["problems"])
            self.assertEqual(kinds, sorted([
                "impl_selector_missing", "impl_file_missing", "test_name_missing", "test_file_missing",
                "journey_doc_missing", "evidence_expired", "evidence_sha_mismatch", "evidence_commit_unreachable",
            ]))
            self.assertEqual(len(res["expiring_30d"]), 1)
            self.assertEqual(res["states"], {"conformant": 1})


class CostTests(unittest.TestCase):
    def test_batch_is_half_price(self):
        full = sa.estimate_cost(1_000_000, 1_000_000, "claude-opus-5-5", batch=False)
        self.assertAlmostEqual(full, 24.0)
        self.assertAlmostEqual(sa.estimate_cost(1_000_000, 1_000_000, "claude-opus-5-5", batch=True), 12.0)


class SchemaTests(unittest.TestCase):
    def test_every_object_is_closed_and_fully_required(self):
        def walk(node):
            if isinstance(node, dict):
                if node.get("type") == "object":
                    self.assertFalse(node["additionalProperties"])
                    self.assertEqual(sorted(node["required"]), sorted(node["properties"]))
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        walk(sa.SCHEMA)
        json.dumps(sa.SCHEMA)


class RequestShapeTests(unittest.TestCase):
    def test_request_has_cached_priorities_and_structured_output(self):
        dossier = {"path": "specs/SPEC-001-x.md", "spec_id": "SPEC-001"}
        req = sa.build_request(Path("."), dossier, "spec body", [("a.go", "1: x")], "prio", "claude-opus-5-5", "high", 1000)
        self.assertEqual(req["output_config"]["format"]["type"], "json_schema")
        self.assertEqual(req["output_config"]["effort"], "high")
        self.assertIn("cache_control", req["system"][1])
        self.assertNotIn("thinking", req)
        self.assertNotIn("tool_choice", req)
        self.assertIn("=== CODE a.go ===", req["messages"][0]["content"])


if __name__ == "__main__":
    unittest.main()
