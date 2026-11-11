from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_pr_declaration import BEGIN, END, derive_declaration, validate_body
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
    def test_spec_governance_review_boundary_is_codeowned(self) -> None:
        root = Path(__file__).resolve().parents[2]
        codeowners = {}
        for raw_line in (root / ".github" / "CODEOWNERS").read_text(encoding="utf-8").splitlines():
            line = raw_line.strip()
            if not line or line.startswith("#"):
                continue
            path, *owners = line.split()
            codeowners[path] = owners

        expected = [
            ".github/CODEOWNERS",
            "AGENTS.md",
            "CLAUDE.md",
            "docs/decision-log.md",
            "docs/evidence/**",
            "docs/spec-governance-foundation.md",
            "docs/spec-history/**",
            "schemas/spec-*",
            "scripts/check_spec_governance.py",
            "scripts/check_spec_pr_declaration.py",
            "scripts/gen_spec_index.py",
            "scripts/tests/**",
            "specs/**",
        ]
        missing = [path for path in expected if codeowners.get(path) != ["@Augustas11"]]
        self.assertEqual([], missing)

    def test_behavior_change_none_accepts_governance_paths(self) -> None:
        self.assertEqual(
            [],
            validate_body(
                declaration(contract_change="yes"),
                changed_paths=["specs/AUTHORITY.json", "scripts/check_spec_governance.py"],
            ),
        )

    def test_behavior_change_none_accepts_evidence_relocations(self) -> None:
        self.assertEqual(
            [],
            validate_body(
                declaration(contract_change="yes"),
                changed_paths=[
                    "specs/CONFORMANCE.json",
                    "docs/evidence/2026-10-01-1780-gpt-oss-120b-evidence.md",
                ],
            ),
        )

    def test_behavior_change_none_accepts_agent_instruction_paths(self) -> None:
        self.assertEqual(
            [],
            validate_body(
                declaration(),
                changed_paths=[
                    "AGENTS.md",
                    "CLAUDE.md",
                ],
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
        self.assertIn("behavior_change yes requires at least one requirement", joined)
        self.assertIn("behavior_change yes requires at least one authority domain", joined)
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

    def test_no_block_needed_when_specs_unchanged(self) -> None:
        self.assertEqual(
            [],
            validate_body("Plain PR body.", changed_paths=["phase4-coordinator/internal/auth/session.go"]),
        )

    def test_specs_change_without_block_is_reported(self) -> None:
        errors = validate_body(
            "Plain PR body.",
            changed_paths=["phase4-coordinator/internal/auth/session.go", "specs/SPEC-001-one.md"],
        )
        self.assertIn("exactly one", "\n".join(errors))

    def test_unknown_diff_without_block_is_reported(self) -> None:
        self.assertIn("exactly one", "\n".join(validate_body("Plain PR body.", changed_paths=[])))
        self.assertIn("exactly one", "\n".join(validate_body("Plain PR body.")))

    def test_hand_written_block_is_still_validated_when_specs_unchanged(self) -> None:
        errors = validate_body(
            declaration(),
            changed_paths=["phase4-coordinator/internal/auth/session.go"],
        )
        self.assertIn("behavior_change none is invalid", "\n".join(errors))

    def test_derived_declaration_maps_paths_to_domains(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = base_repository()
            requirement = next(
                item for item in repository["conformance"]["requirements"] if item["requirement_id"] == "SPEC-001-R001"
            )
            requirement["implementation"] = ["phase3-binary/Sources/macprovider-cli/Example.swift:func example"]
            write_repository(root, repository)
            derived = derive_declaration(
                root, ["phase3-binary/Sources/macprovider-cli/Example.swift", "README.md"]
            )
            self.assertEqual("yes", derived["behavior_change"])
            self.assertEqual(["SPEC-001"], derived["specs"])
            self.assertEqual(["SPEC-001-R001"], derived["requirements"])
            self.assertEqual(["provider-wire-protocol"], derived["authority_domains"])
            self.assertEqual("none", derive_declaration(root, ["AGENTS.md"])["behavior_change"])

    def test_invalid_json_fails(self) -> None:
        body = f"{BEGIN}\n{{not json}}\n{END}\n"
        self.assertIn("declaration JSON is invalid", "\n".join(validate_body(body)))

    def test_duplicate_json_keys_fail(self) -> None:
        body = (
            f"{BEGIN}\n"
            '{"schema_version":"spec-pr-governance-v1",'
            '"behavior_change":"none","behavior_change":"yes",'
            '"contract_change":"none","specs":[],"requirements":[],'
            '"authority_domains":[],"arbitration":[],"tests":[],"journeys":[]}'
            f"\n{END}\n"
        )
        self.assertIn("duplicate object key 'behavior_change'", "\n".join(validate_body(body)))

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
                cwd=Path(__file__).resolve().parents[2],
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def test_direct_cli_uses_pr_merge_base_diff(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            branch_point = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()

            subprocess.run(["git", "checkout", "-qb", "feature"], cwd=root, check=True)
            (root / "specs" / "PROCESS.md").write_text("governance\n", encoding="utf-8")
            subprocess.run(["git", "add", "specs/PROCESS.md"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "governance change"], cwd=root, check=True)
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()

            subprocess.run(["git", "checkout", "-qB", "main", branch_point], cwd=root, check=True)
            product = root / "phase4-coordinator" / "internal" / "auth" / "session.go"
            product.parent.mkdir(parents=True, exist_ok=True)
            product.write_text("package auth\n", encoding="utf-8")
            subprocess.run(["git", "add", str(product.relative_to(root))], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "base product change"], cwd=root, check=True)
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()

            event = root / "event.json"
            event.write_text(
                json.dumps({"pull_request": {"body": declaration(contract_change="yes")}}),
                encoding="utf-8",
            )
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
                cwd=Path(__file__).resolve().parents[2],
                capture_output=True,
                text=True,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)

    def _specs_pr(self, root: Path) -> tuple[str, str]:
        """Commit a specs/ change on top of the base repository; return base, head."""
        write_repository(root, base_repository())
        base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        (root / "specs" / "PROCESS.md").write_text("governance\n", encoding="utf-8")
        product = root / "phase4-coordinator" / "internal" / "auth" / "session.go"
        product.parent.mkdir(parents=True, exist_ok=True)
        product.write_text("package auth\n", encoding="utf-8")
        subprocess.run(["git", "add", "-A"], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "specs change"], cwd=root, check=True)
        head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
        return base, head

    def _run_cli(self, root: Path, body: str, base: str, head: str) -> subprocess.CompletedProcess[str]:
        event = root.parent / f"{root.name}-event.json"
        event.write_text(json.dumps({"pull_request": {"body": body}}), encoding="utf-8")
        return subprocess.run(
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
            cwd=Path(__file__).resolve().parents[2],
            capture_output=True,
            text=True,
        )

    def test_cli_specs_change_without_block_derives_and_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            base, head = self._specs_pr(root)
            completed = self._run_cli(root, "Plain PR body.", base, head)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("::warning::SPEC governance declaration missing or malformed", completed.stdout)
            self.assertIn("SPEC governance declaration derived from the diff:", completed.stdout)
            self.assertIn('"derived_from": "git-diff"', completed.stdout)

    def test_cli_malformed_block_derives_and_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            base, head = self._specs_pr(root)
            completed = self._run_cli(root, f"{BEGIN}\n{{not json}}\n{END}\n", base, head)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("missing or malformed", completed.stdout)
            self.assertIn("declaration JSON is invalid", completed.stdout)
            self.assertIn('"derived_from": "git-diff"', completed.stdout)

    def test_cli_contradicting_block_is_reported_not_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            base, head = self._specs_pr(root)
            completed = self._run_cli(root, declaration(contract_change="yes"), base, head)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("::warning::SPEC governance declaration contradicts the diff", completed.stdout)
            self.assertIn("behavior_change none is invalid for non-governance path", completed.stdout)
            self.assertIn('"behavior_change": "yes"', completed.stdout)

    def test_cli_matching_block_passes_cleanly(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "repo"
            root.mkdir()
            write_repository(root, base_repository())
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            (root / "specs" / "PROCESS.md").write_text("governance\n", encoding="utf-8")
            subprocess.run(["git", "add", "-A"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "governance change"], cwd=root, check=True)
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            completed = self._run_cli(root, declaration(), base, head)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn("SPEC governance PR declaration passed", completed.stdout)
            self.assertNotIn("::warning::", completed.stdout)


if __name__ == "__main__":
    unittest.main()
