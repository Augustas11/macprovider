import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_pr_declaration import validate_body


ROOT = Path(__file__).resolve().parents[2]


class SpecPRDeclarationTests(unittest.TestCase):
    def test_behavior_change_none(self) -> None:
        self.assertEqual([], validate_body("spec-governance:\n  behavior-change: none\n"))

    def test_complete_behavior_change(self) -> None:
        body = """spec-governance:
  behavior-change: yes
  specs: SPEC-001
  requirements: SPEC-001-R001
  authority-domains: example-domain
  arbitration: CODE_BUG
  tests: tests/test_provider.py::test_behavior
  journeys: not-required
"""
        self.assertEqual([], validate_body(body))

    def test_missing_declaration_fails(self) -> None:
        self.assertIn("missing", "\n".join(validate_body("ordinary PR body")))

    def test_incomplete_behavior_change_fails(self) -> None:
        errors = validate_body("spec-governance:\n  behavior-change: yes\n  specs: SPEC-001\n")
        self.assertTrue(any("requirements" in error for error in errors))

    def test_direct_cli_execution_matches_github_actions(self) -> None:
        event = {"pull_request": {"body": "spec-governance:\n  behavior-change: none\n  contract-change: yes\n"}}
        with tempfile.TemporaryDirectory() as directory:
            event_path = Path(directory) / "event.json"
            event_path.write_text(json.dumps(event), encoding="utf-8")
            base = subprocess.run(
                ["git", "rev-parse", "origin/main"], cwd=ROOT,
                capture_output=True, text=True, check=True,
            ).stdout.strip()
            completed = subprocess.run(
                [sys.executable, "scripts/check_spec_pr_declaration.py", "--event", str(event_path),
                 "--base", base],
                cwd=ROOT,
                capture_output=True,
                text=True,
            )
        self.assertEqual(0, completed.returncode, completed.stderr)

    def test_fenced_example_is_not_a_declaration(self) -> None:
        body = "```text\nspec-governance:\n  behavior-change: none\n```\n"
        self.assertIn("missing", "\n".join(validate_body(body)))
        tilde = "~~~text\nspec-governance:\n  behavior-change: none\n~~~\n"
        self.assertIn("missing", "\n".join(validate_body(tilde)))
        comment = "<!--\nspec-governance:\n  behavior-change: none\n-->\n"
        self.assertIn("missing", "\n".join(validate_body(comment)))
        indented = "    spec-governance:\n      behavior-change: none\n"
        self.assertIn("missing", "\n".join(validate_body(indented)))

    def test_shorter_fence_runs_do_not_expose_example_declarations(self) -> None:
        for opener, shorter, closer in (
            ("````text", "```", "````"),
            ("`````text", "````", "`````"),
            ("~~~~text", "~~~", "~~~~"),
            ("~~~~~text", "~~~~", "~~~~~"),
        ):
            with self.subTest(opener=opener):
                body = (
                    f"{opener}\n{shorter}\n"
                    "spec-governance:\n  behavior-change: none\n"
                    f"{closer}\n"
                )
                self.assertIn("missing", "\n".join(validate_body(body)))

    def test_comment_openers_inside_fences_do_not_hide_real_declarations(self) -> None:
        for opener, closer in (("```html", "```"), ("~~~html", "~~~")):
            with self.subTest(opener=opener):
                body = (
                    f"{opener}\n"
                    "<!-- literal example opener\n"
                    f"{closer}\n"
                    "spec-governance:\n  behavior-change: none\n"
                )
                self.assertEqual([], validate_body(body))

    def test_hidden_declaration_fields_are_rejected(self) -> None:
        hidden_blocks = (
            "```text\n  behavior-change: none\n```\n",
            "````text\n```\n  behavior-change: none\n````\n",
            "~~~text\n  behavior-change: none\n~~~\n",
            "<pre>\n  behavior-change: none\n</pre>\n",
            "<details>\n  behavior-change: none\n</details>\n",
            "<div>\n  behavior-change: none\n</div>\n",
            "<?example\n  behavior-change: none\n?>\n",
            "<![CDATA[\n  behavior-change: none\n]]>\n",
            "\n<widget title=\">\">\n  behavior-change: none\n\n",
            "    behavior-change: none\n",
            "<!--\n  behavior-change: none\n-->\n",
        )
        for hidden in hidden_blocks:
            with self.subTest(hidden=hidden.splitlines()[0]):
                errors = validate_body("spec-governance:\n" + hidden)
                self.assertTrue(any("behavior-change" in error for error in errors))

    def test_literal_comment_syntax_does_not_hide_real_declarations(self) -> None:
        for literal in ("`<!--` is inline code.", r"\<!-- is escaped syntax."):
            with self.subTest(literal=literal):
                body = (
                    f"{literal}\n"
                    "spec-governance:\n  behavior-change: none\n"
                )
                self.assertEqual([], validate_body(body))

    def test_behavior_none_rejects_product_paths(self) -> None:
        errors = validate_body(
            "spec-governance:\n  behavior-change: none\n",
            changed_paths=["phase4-coordinator/internal/ws/server.go"],
        )
        self.assertTrue(any("non-governance path" in error for error in errors))

    def test_contract_changes_require_explicit_declaration(self) -> None:
        body = "spec-governance:\n  behavior-change: none\n"
        for path in (
            "specs/SPEC-001-provider.md",
            "specs/AUTHORITY.json",
            "specs/CONFORMANCE.json",
        ):
            with self.subTest(path=path):
                errors = validate_body(body, changed_paths=[path])
                self.assertTrue(any("contract-change must be 'yes'" in error for error in errors))

    def test_explicit_contract_change_can_leave_product_behavior_unchanged(self) -> None:
        body = """spec-governance:
  behavior-change: none
  contract-change: yes
"""
        self.assertEqual(
            [],
            validate_body(body, changed_paths=["specs/SPEC-001-provider.md"]),
        )

    def test_behavior_change_references_must_exist(self) -> None:
        body = """spec-governance:
  behavior-change: yes
  specs: SPEC-999
  requirements: SPEC-999-R999
  authority-domains: invented-domain
  arbitration: CODE_BUG
  tests: tests/test_fake.py::test_fake
  journeys: not-required
"""
        errors = validate_body(body, root=ROOT)
        self.assertTrue(any("unknown spec" in error for error in errors))
        self.assertTrue(any("unknown requirement" in error for error in errors))
        self.assertTrue(any("unknown authority" in error for error in errors))

    def test_sensitive_domain_requires_journey_and_resolved_test(self) -> None:
        body = """spec-governance:
  behavior-change: yes
  specs: SPEC-001
  requirements: SPEC-001-R001
  authority-domains: provider-wire-protocol
  arbitration: CODE_BUG
  tests: specs/README.md::not_a_test
  journeys: not-required
"""
        errors = validate_body(body, root=ROOT)
        self.assertTrue(any("not-required is forbidden" in error for error in errors))
        self.assertTrue(any("test mapping does not resolve" in error for error in errors))

    def test_journey_declaration_rejects_path_traversal(self) -> None:
        body = """spec-governance:
  behavior-change: yes
  specs: SPEC-001
  requirements: SPEC-001-R001
  authority-domains: provider-wire-protocol
  arbitration: CODE_BUG
  tests: scripts/tests/test_spec_governance.py::test_valid_fixture_passes
  journeys: JOURNEY-X/../../specs/README
"""
        errors = validate_body(body, root=ROOT)
        self.assertTrue(any("invalid journey declaration" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
