from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_pr_declaration import BEGIN, END, validate_body
from scripts.tests.test_spec_governance import base_repository, write_repository


def declaration(**overrides: object) -> str:
    payload = {
        "schema_version": "spec-pr-governance-v1",
        "behavior_change": "none",
        "contract_change": "none",
        "specs": [],
        "requirements": [],
        "authority_domains": [],
        "arbitration": [],
        "tests": [],
        "journeys": [],
    }
    payload.update(overrides)
    return f"{BEGIN}\n{json.dumps(payload, indent=2)}\n{END}\n"


class SpecPRDeclarationTests(unittest.TestCase):
    def test_behavior_change_none_accepts_governance_paths(self) -> None:
        self.assertEqual(
            [],
            validate_body(
                declaration(contract_change="yes"),
                changed_paths=["specs/AUTHORITY.json", "scripts/check_spec_governance.py"],
            ),
        )

    def test_contract_changes_require_contract_yes(self) -> None:
        errors = validate_body(declaration(), changed_paths=["specs/CONFORMANCE.json"])
        self.assertIn("contract_change must be 'yes'", "\n".join(errors))

    def test_behavior_change_none_rejects_product_paths(self) -> None:
        errors = validate_body(
            declaration(),
            changed_paths=["phase4-coordinator/internal/auth/session.go"],
        )
        self.assertIn("behavior_change none is invalid", "\n".join(errors))

    def test_behavior_change_yes_requires_structured_fields(self) -> None:
        errors = validate_body(declaration(behavior_change="yes"))
        joined = "\n".join(errors)
        self.assertIn("behavior_change yes requires at least one spec", joined)
        self.assertIn("behavior_change yes requires tests", joined)

    def test_behavior_change_yes_resolves_manifest_ids(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            body = declaration(
                behavior_change="yes",
                specs=["SPEC-001"],
                requirements=["SPEC-001-R001"],
                authority_domains=["provider-wire-protocol"],
                arbitration=["UNKNOWN"],
                tests=["tests/test_example.py::test_example"],
                journeys=["not-required"],
            )
            self.assertEqual([], validate_body(body, root=root))

    def test_unknown_manifest_ids_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            body = declaration(
                behavior_change="yes",
                specs=["SPEC-999"],
                requirements=["SPEC-999-R001"],
                authority_domains=["missing-domain"],
                arbitration=["UNKNOWN"],
                tests=["unit"],
                journeys=["not-required"],
            )
            joined = "\n".join(validate_body(body, root=root))
            self.assertIn("unknown spec 'SPEC-999'", joined)
            self.assertIn("unknown requirement 'SPEC-999-R001'", joined)
            self.assertIn("unknown authority domain 'missing-domain'", joined)

    def test_missing_or_duplicate_marker_fails(self) -> None:
        self.assertIn("exactly one", "\n".join(validate_body("{}")))
        doubled = declaration() + declaration()
        self.assertIn("exactly one", "\n".join(validate_body(doubled)))

    def test_invalid_json_fails(self) -> None:
        body = f"{BEGIN}\n{{not json}}\n{END}\n"
        self.assertIn("declaration JSON is invalid", "\n".join(validate_body(body)))

    def test_unexpected_field_fails(self) -> None:
        errors = validate_body(declaration(extra="nope"))
        self.assertIn("unexpected field 'extra'", "\n".join(errors))

    def test_direct_cli_execution_matches_github_actions(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            event = root / "event.json"
            event.write_text(
                json.dumps({"pull_request": {"body": declaration(contract_change="yes")}}),
                encoding="utf-8",
            )
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            (root / "specs" / "AUTHORITY.json").write_text(
                (root / "specs" / "AUTHORITY.json").read_text(encoding="utf-8"),
                encoding="utf-8",
            )
            subprocess.run(["git", "commit", "--allow-empty", "-qm", "change"], cwd=root, check=True)
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            completed = subprocess.run(
                [
                    "python3",
                    str(Path(__file__).resolve().parents[1] / "check_spec_pr_declaration.py"),
                    "--event",
                    str(event),
                    "--base",
                    base,
                    "--head",
                    head,
                    "--root",
                    str(root),
                ],
                cwd=root,
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)


if __name__ == "__main__":
    unittest.main()
