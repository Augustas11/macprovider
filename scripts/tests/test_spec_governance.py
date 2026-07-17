from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from datetime import date
from pathlib import Path

from scripts.check_spec_governance import BOOTSTRAP_BASELINE_COMMIT, legacy_requirement_fingerprint, validate_repository


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = ROOT / "scripts" / "tests" / "fixtures" / "spec_governance"


def base_repository() -> dict[str, object]:
    issue = "https://github.com/Augustas11/macprovider/issues/614"
    gap = {"verdict": "UNKNOWN", "owner": "@owner", "issue": issue}
    authority = {
        "$schema": "../schemas/spec-authority-v1.schema.json",
        "schema_version": "spec-authority-v1",
        "baseline": {"commit": BOOTSTRAP_BASELINE_COMMIT, "captured_at": "2026-07-16"},
        "domains": [
            {"id": "one-domain", "owner_spec": "SPEC-001", "consumers": ["SPEC-002"], "status": "pending-reconciliation", "owner": "@owner", "issue": issue},
            {"id": "two-domain", "owner_spec": "SPEC-002", "consumers": [], "status": "pending-reconciliation", "owner": "@owner", "issue": issue},
        ],
    }
    spec_texts = {
        "specs/SPEC-001-one.md": "# SPEC-001 — One\n\n**Version:** 0.1.0\n\n**SPEC-001-R001 — One rule.** It MUST work. See SPEC-002.\n",
        "specs/SPEC-002-two.md": "# SPEC-002 — Two\n\n**Version:** 0.1.0\n",
        "src/example.py": "def example():\n    return True\n",
        "tests/test_example.py": "def test_example():\n    assert True\n",
    }
    fingerprint_one, count_one = legacy_requirement_fingerprint(spec_texts["specs/SPEC-001-one.md"])
    fingerprint_two, count_two = legacy_requirement_fingerprint(spec_texts["specs/SPEC-002-two.md"])
    conformance = {
        "$schema": "../schemas/spec-conformance-v1.schema.json",
        "schema_version": "spec-conformance-v1",
        "baseline": {"commit": BOOTSTRAP_BASELINE_COMMIT, "captured_at": "2026-07-16"},
        "specs": [
            {"spec_id": "SPEC-001", "title": "One", "version": "0.1.0", "path": "specs/SPEC-001-one.md", "status": "draft", "owner": "@owner", "authority_domains": ["one-domain"], "supersedes": [], "depends_on": ["SPEC-002"], "implementation_status": "pending-reconciliation", "production_status": "pending-verification", "last_reconciled_commit": None, "last_reconciled_at": None, "evidence": [], "requirement_id_migration": "pending", "legacy_requirement_fingerprint": fingerprint_one, "legacy_requirement_count": count_one, "gap": copy.deepcopy(gap)},
            {"spec_id": "SPEC-002", "title": "Two", "version": "0.1.0", "path": "specs/SPEC-002-two.md", "status": "draft", "owner": "@owner", "authority_domains": ["two-domain"], "supersedes": [], "depends_on": [], "implementation_status": "pending-reconciliation", "production_status": "pending-verification", "last_reconciled_commit": None, "last_reconciled_at": None, "evidence": [], "requirement_id_migration": "pending", "legacy_requirement_fingerprint": fingerprint_two, "legacy_requirement_count": count_two, "gap": copy.deepcopy(gap)},
        ],
        "requirements": [
            {"requirement_id": "SPEC-001-R001", "spec_id": "SPEC-001", "state": "pending", "implementation": [], "tests": [], "journeys": [], "evidence": [], "gap": copy.deepcopy(gap)}
        ],
    }
    return {"authority": authority, "conformance": conformance, "specs": spec_texts}


def apply_mutation(repository: dict[str, object], mutation: dict[str, object]) -> None:
    operation = mutation["operation"]
    authority = repository["authority"]
    conformance = repository["conformance"]
    specs = repository["specs"]
    if operation == "drop_authority_schema_version":
        del authority["schema_version"]
    elif operation == "delete_spec_file":
        del specs[mutation["path"]]
    elif operation == "duplicate_authority":
        duplicate = copy.deepcopy(authority["domains"][0])
        duplicate["owner_spec"] = "SPEC-002"
        authority["domains"].append(duplicate)
    elif operation == "duplicate_requirement_definition":
        specs["specs/SPEC-002-two.md"] += "\n**SPEC-001-R001 — Duplicate.** It MUST fail.\n"
    elif operation == "remove_requirement_mapping":
        conformance["requirements"] = []
    elif operation == "invalid_lifecycle":
        conformance["specs"][0]["status"] = "locked"
    elif operation == "invalid_conformance":
        conformance["requirements"][0]["state"] = "green"
    elif operation == "broken_cross_spec_reference":
        specs["specs/SPEC-001-one.md"] += "\nDepends on SPEC-999.\n"
    elif operation == "stale_evidence":
        requirement = conformance["requirements"][0]
        requirement.update({
            "state": "conformant",
            "implementation": ["src/example.py:symbol"],
            "tests": ["tests/test_example.py::test_symbol"],
            "evidence": [{"artifact": "commit:abc", "captured_at": "2025-01-01", "expires_at": "2025-12-31"}],
            "gap": None,
        })
    elif operation == "unowned_gap":
        del conformance["requirements"][0]["gap"]["owner"]
    elif operation == "malformed_consumers":
        authority["domains"][0]["consumers"] = "SPEC-002"
    elif operation == "malformed_authority_domains":
        conformance["specs"][0]["authority_domains"] = "one-domain"
    elif operation == "malformed_gap":
        conformance["requirements"][0]["gap"] = ["not-an-object"]
    elif operation == "broken_requirement_reference":
        specs["specs/SPEC-001-one.md"] += "\nSee SPEC-002-R999.\n"
    elif operation == "physically_verified_without_proof":
        spec = conformance["specs"][0]
        spec.update({
            "status": "physically-verified",
            "implementation_status": "implemented",
            "production_status": "physically-verified",
            "requirement_id_migration": "complete",
            "legacy_requirement_fingerprint": None,
            "legacy_requirement_count": 0,
            "gap": None,
        })
    elif operation == "unnumbered_normative_obligation":
        specs["specs/SPEC-001-one.md"] = "# SPEC-001 — One\n\n**Version:** 0.1.0\n\nThe implementation MUST work. See SPEC-002.\n"
        conformance["requirements"] = []
        spec = conformance["specs"][0]
        spec.update({
            "requirement_id_migration": "complete",
            "legacy_requirement_fingerprint": None,
            "legacy_requirement_count": 0,
            "gap": None,
        })
    elif operation == "new_pending_unnumbered_obligation":
        specs["specs/SPEC-001-one.md"] += "\nA newly asserted behavior MUST be implemented.\n"
    elif operation == "deprecated_authority_owner":
        spec = conformance["specs"][0]
        spec.update({
            "status": "deprecated",
            "superseded_by": ["SPEC-002"],
        })
    elif operation == "implemented_unverified_without_requirements":
        conformance["requirements"] = []
        spec = conformance["specs"][0]
        spec.update({
            "status": "implemented-unverified",
            "implementation_status": "implemented",
            "requirement_id_migration": "complete",
            "legacy_requirement_fingerprint": None,
            "legacy_requirement_count": 0,
            "gap": None,
        })
        specs["specs/SPEC-001-one.md"] = "# SPEC-001 — One\n\n**Version:** 0.1.0\n"
    elif operation == "broken_markdown_link":
        specs["specs/SPEC-001-one.md"] += "\n[missing](../docs/does-not-exist.md)\n"
    elif operation == "unregistered_journey":
        requirement = conformance["requirements"][0]
        requirement.update({
            "state": "conformant",
            "implementation": ["src/example.py:example"],
            "tests": ["tests/test_example.py::test_example"],
            "journeys": ["JOURNEY-NOT-REGISTERED"],
            "evidence": [{"artifact": "sha256:" + "0" * 64, "source": "src/example.py", "captured_at": "2026-07-16", "expires_at": "2027-07-16"}],
            "gap": None,
        })
    elif operation == "malformed_owner_spec":
        authority["domains"][0]["owner_spec"] = {"not": "a string"}
    elif operation == "normalized_spec_mapping":
        requirement = conformance["requirements"][0]
        requirement.update({
            "state": "conformant",
            "implementation": ["./specs/SPEC-001-one.md:SPEC-001-R001"],
            "tests": ["tests/test_example.py::test_example"],
            "evidence": [{"artifact": "commit:" + BOOTSTRAP_BASELINE_COMMIT, "source": None, "captured_at": "2026-07-16", "expires_at": "2027-07-16"}],
            "gap": None,
        })
    elif operation == "physical_evidence_path_traversal":
        authority["domains"][0]["id"] = "provider-wire-protocol"
        conformance["specs"][0]["authority_domains"] = ["provider-wire-protocol"]
        specs["journeys/JOURNEY-TRAVERSAL.md"] = "# JOURNEY-TRAVERSAL\n"
        source = specs["src/example.py"].encode("utf-8")
        requirement = conformance["requirements"][0]
        requirement.update({
            "state": "conformant",
            "implementation": ["src/example.py:example"],
            "tests": ["tests/test_example.py::test_example"],
            "journeys": ["JOURNEY-TRAVERSAL"],
            "evidence": [
                {"artifact": "commit:" + BOOTSTRAP_BASELINE_COMMIT, "source": None, "captured_at": "2026-07-16", "expires_at": "2027-07-16"},
                {"artifact": "sha256:" + hashlib.sha256(source).hexdigest(), "source": "journeys/evidence/../../src/example.py", "captured_at": "2026-07-16", "expires_at": "2027-07-16"}
            ],
            "gap": None,
        })
    elif operation == "fake_evidence_mappings":
        requirement = conformance["requirements"][0]
        requirement.update({
            "state": "conformant",
            "implementation": ["missing/file.py:fake"],
            "tests": ["missing/test.py::fake"],
            "evidence": [{"artifact": "trust-me", "captured_at": "2099-01-01", "expires_at": "9999-01-01"}],
            "gap": None,
        })
    elif operation == "hostile_schema_pointer":
        authority["$schema"] = "https://attacker.invalid/schema.json"
    elif operation == "divergent_baseline":
        conformance["baseline"]["commit"] = "b" * 40
    else:
        raise AssertionError(f"unknown fixture mutation: {operation}")


def write_repository(root: Path, repository: dict[str, object]) -> None:
    (root / "specs").mkdir(parents=True, exist_ok=True)
    (root / "schemas").mkdir(parents=True, exist_ok=True)
    for schema_name in ("spec-authority-v1.schema.json", "spec-conformance-v1.schema.json"):
        (root / "schemas" / schema_name).write_text(
            (ROOT / "schemas" / schema_name).read_text(encoding="utf-8"), encoding="utf-8"
        )
    (root / "specs" / "AUTHORITY.json").write_text(json.dumps(repository["authority"]), encoding="utf-8")
    (root / "specs" / "CONFORMANCE.json").write_text(json.dumps(repository["conformance"]), encoding="utf-8")
    for relative, content in repository["specs"].items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content, encoding="utf-8")


class GovernanceValidatorTests(unittest.TestCase):
    def _commit_repository(self, root: Path) -> str:
        subprocess.run(["git", "init", "-q"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.email", "tests@example.invalid"], cwd=root, check=True)
        subprocess.run(["git", "config", "user.name", "Governance Tests"], cwd=root, check=True)
        subprocess.run(["git", "add", "."], cwd=root, check=True)
        subprocess.run(["git", "commit", "-qm", "test base"], cwd=root, check=True)
        subprocess.run(
            ["git", "fetch", "-q", str(ROOT), BOOTSTRAP_BASELINE_COMMIT],
            cwd=root,
            check=True,
        )
        return subprocess.run(
            ["git", "rev-parse", "HEAD"], cwd=root, capture_output=True, text=True, check=True,
        ).stdout.strip()

    def test_valid_fixture_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            result = validate_repository(root, date(2026, 7, 16))
            self.assertEqual([], result.errors)

    def test_all_negative_fixtures_fail_actionably(self) -> None:
        fixture_paths = sorted(FIXTURES.glob("*.json"))
        self.assertGreaterEqual(len(fixture_paths), 27)
        for fixture_path in fixture_paths:
            with self.subTest(fixture=fixture_path.name):
                fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
                repository = base_repository()
                apply_mutation(repository, fixture["mutation"])
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_repository(root, repository)
                    result = validate_repository(root, date(2026, 7, 16))
                combined = "\n".join(result.errors)
                self.assertTrue(result.errors, "negative fixture unexpectedly passed")
                self.assertIn(fixture["expected"], combined)

    def test_tracked_schema_drift_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            schema_path = root / "schemas" / "spec-conformance-v1.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["$defs"]["requirement"]["properties"]["state"]["enum"].append("green")
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            result = validate_repository(root, date(2026, 7, 16))
        self.assertIn("tracked schema/runtime contract drift", "\n".join(result.errors))

    def test_tracked_schema_required_field_drift_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            schema_path = root / "schemas" / "spec-conformance-v1.schema.json"
            schema = json.loads(schema_path.read_text(encoding="utf-8"))
            schema["$defs"]["spec"]["required"].remove("title")
            schema_path.write_text(json.dumps(schema), encoding="utf-8")
            result = validate_repository(root, date(2026, 7, 16))
        self.assertIn("tracked schema/runtime contract drift", "\n".join(result.errors))

    def test_unreachable_commit_evidence_fails_in_git_repository(self) -> None:
        repository = base_repository()
        requirement = repository["conformance"]["requirements"][0]
        requirement.update({
            "state": "conformant",
            "implementation": ["src/example.py:example"],
            "tests": ["tests/test_example.py::test_example"],
            "evidence": [{"artifact": "commit:" + "0" * 40, "source": None, "captured_at": "2026-07-16", "expires_at": "2027-07-16"}],
            "gap": None,
        })
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            subprocess.run(["git", "init", "-q"], cwd=root, check=True)
            result = validate_repository(root, date(2026, 7, 16), base_ref=None)
        self.assertIn("evidence commit", "\n".join(result.errors))

    def test_invalid_utf8_is_actionable(self) -> None:
        for relative in ("specs/AUTHORITY.json", "specs/SPEC-001-one.md"):
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                write_repository(root, base_repository())
                (root / relative).write_bytes(b"\xff")
                result = validate_repository(root, date(2026, 7, 16))
                self.assertIn("invalid UTF-8", "\n".join(result.errors))

    def test_manifest_cannot_reseed_bootstrap_baseline(self) -> None:
        repository = base_repository()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            commit = self._commit_repository(root)
            repository["authority"]["baseline"]["commit"] = commit
            repository["conformance"]["baseline"]["commit"] = commit
            write_repository(root, repository)
            result = validate_repository(root, date(2026, 7, 16), base_ref=commit)
        self.assertIn("must remain pinned to bootstrap baseline", "\n".join(result.errors))

    def test_stable_requirement_cannot_be_deleted_from_base(self) -> None:
        repository = base_repository()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            commit = self._commit_repository(root)
            repository["specs"]["specs/SPEC-001-one.md"] = "# SPEC-001 — One\n\n**Version:** 0.1.0\n"
            repository["conformance"]["requirements"] = []
            write_repository(root, repository)
            result = validate_repository(root, date(2026, 7, 16), base_ref=commit)
        self.assertIn("stable requirement identity SPEC-001-R001 cannot be deleted", "\n".join(result.errors))

    def test_reverse_lifecycle_transition_fails(self) -> None:
        repository = base_repository()
        repository["conformance"]["specs"][0]["status"] = "normative"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            commit = self._commit_repository(root)
            repository["conformance"]["specs"][0]["status"] = "draft"
            write_repository(root, repository)
            result = validate_repository(root, date(2026, 7, 16), base_ref=commit)
        self.assertIn("invalid lifecycle transition for SPEC-001: normative -> draft", "\n".join(result.errors))

    def test_spec_and_authority_domain_can_retire_as_tombstones(self) -> None:
        repository = base_repository()
        for spec in repository["conformance"]["specs"]:
            spec.update({
                "requirement_id_migration": "complete",
                "legacy_requirement_fingerprint": None,
                "legacy_requirement_count": 0,
            })
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            commit = self._commit_repository(root)
            repository["authority"]["domains"][0]["status"] = "deprecated"
            repository["conformance"]["specs"][0].update({
                "status": "deprecated",
                "authority_domains": [],
                "superseded_by": ["SPEC-002"],
            })
            write_repository(root, repository)
            result = validate_repository(root, date(2026, 7, 16), base_ref=commit)
        self.assertEqual([], result.errors)

    def test_legacy_obligations_cannot_be_erased_during_normative_promotion(self) -> None:
        repository = base_repository()
        repository["specs"]["specs/SPEC-001-one.md"] = "# SPEC-001 — One\n\n**Version:** 0.1.0\n\nThe provider MUST preserve behavior.\n"
        fingerprint, count = legacy_requirement_fingerprint(repository["specs"]["specs/SPEC-001-one.md"])
        repository["conformance"]["specs"][0]["legacy_requirement_fingerprint"] = fingerprint
        repository["conformance"]["specs"][0]["legacy_requirement_count"] = count
        repository["conformance"]["requirements"] = []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            commit = self._commit_repository(root)
            repository["specs"]["specs/SPEC-001-one.md"] = "# SPEC-001 — One\n\n**Version:** 0.1.0\n"
            repository["conformance"]["specs"][0].update({
                "status": "normative",
                "requirement_id_migration": "complete",
                "legacy_requirement_fingerprint": None,
                "legacy_requirement_count": 0,
                "gap": None,
            })
            write_repository(root, repository)
            result = validate_repository(root, date(2026, 7, 16), base_ref=commit)
        errors = "\n".join(result.errors)
        self.assertIn("removed 1 legacy normative obligation", errors)
        self.assertIn("draft -> normative requires complete ID migration and at least one stable requirement", errors)

    def test_example_requirement_ids_cannot_hide_removed_obligations(self) -> None:
        examples = (
            "```text\n**SPEC-001-R999 — Example only.** It MUST not count.\n```\n",
            "~~~text\n**SPEC-001-R999 — Example only.** It MUST not count.\n~~~\n",
            "````text\n```\n**SPEC-001-R999 — Example only.** It MUST not count.\n````\n",
            "`````text\n````\n**SPEC-001-R999 — Example only.** It MUST not count.\n`````\n",
            "~~~~text\n~~~\n**SPEC-001-R999 — Example only.** It MUST not count.\n~~~~\n",
            "~~~~~text\n~~~~\n**SPEC-001-R999 — Example only.** It MUST not count.\n~~~~~\n",
            "<pre>\n**SPEC-001-R999 — Example only.** It MUST not count.\n</pre>\n",
            "<!-- **SPEC-001-R999 — Comment only.** It MUST not count. -->\n",
        )
        for example in examples:
            with self.subTest(example=example.splitlines()[0]):
                repository = base_repository()
                repository["specs"]["specs/SPEC-001-one.md"] = (
                    "# SPEC-001 — One\n\n**Version:** 0.1.0\n\n"
                    "The provider MUST preserve behavior.\n"
                )
                fingerprint, count = legacy_requirement_fingerprint(
                    repository["specs"]["specs/SPEC-001-one.md"]
                )
                repository["conformance"]["specs"][0]["legacy_requirement_fingerprint"] = fingerprint
                repository["conformance"]["specs"][0]["legacy_requirement_count"] = count
                repository["conformance"]["requirements"] = []
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_repository(root, repository)
                    commit = self._commit_repository(root)
                    repository["specs"]["specs/SPEC-001-one.md"] = (
                        "# SPEC-001 — One\n\n**Version:** 0.1.0\n\n" + example
                    )
                    repository["conformance"]["requirements"] = [{
                        "requirement_id": "SPEC-001-R999",
                        "spec_id": "SPEC-001",
                        "state": "pending",
                        "implementation": [],
                        "tests": [],
                        "journeys": [],
                        "evidence": [],
                        "gap": copy.deepcopy(repository["conformance"]["specs"][0]["gap"]),
                    }]
                    write_repository(root, repository)
                    result = validate_repository(root, date(2026, 7, 16), base_ref=commit)
                self.assertIn(
                    "removed 1 legacy normative obligation line(s) but added only 0 stable requirement tombstone(s)",
                    "\n".join(result.errors),
                )

    def test_comment_openers_inside_fences_cannot_hide_later_obligations(self) -> None:
        for opener, closer in (("```html", "```"), ("~~~html", "~~~")):
            with self.subTest(opener=opener):
                text = (
                    f"{opener}\n"
                    "<!-- literal example opener\n"
                    f"{closer}\n"
                    "The provider MUST preserve the visible contract.\n"
                )
                _, count = legacy_requirement_fingerprint(text)
                self.assertEqual(1, count)

    def test_literal_comment_syntax_cannot_hide_later_obligations(self) -> None:
        for literal in ("`<!--` is inline code.", r"\<!-- is escaped syntax."):
            with self.subTest(literal=literal):
                text = (
                    f"{literal}\n"
                    "The provider MUST preserve the visible contract.\n"
                )
                _, count = legacy_requirement_fingerprint(text)
                self.assertEqual(1, count)

    def test_malformed_nested_values_never_crash(self) -> None:
        mutations = [
            ("authority", "domains", 0, "id"),
            ("authority", "domains", 0, "owner_spec"),
            ("authority", "domains", 0, "consumers"),
            ("conformance", "specs", 0, "spec_id"),
            ("conformance", "specs", 0, "authority_domains"),
            ("conformance", "requirements", 0, "requirement_id"),
            ("conformance", "requirements", 0, "spec_id"),
            ("conformance", "requirements", 0, "journeys"),
        ]
        for mutation in mutations:
            with self.subTest(field=mutation):
                repository = base_repository()
                target = repository
                for key in mutation[:-1]:
                    target = target[key]
                target[mutation[-1]] = {"malformed": True}
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_repository(root, repository)
                    result = validate_repository(root, date(2026, 7, 16))
                self.assertTrue(result.errors)

        array_mutations = [
            ("authority", "domains", 0, "consumers"),
            ("conformance", "specs", 0, "authority_domains"),
            ("conformance", "specs", 0, "depends_on"),
            ("conformance", "specs", 0, "supersedes"),
            ("conformance", "requirements", 0, "implementation"),
            ("conformance", "requirements", 0, "tests"),
            ("conformance", "requirements", 0, "journeys"),
        ]
        for mutation in array_mutations:
            with self.subTest(array_field=mutation):
                repository = base_repository()
                target = repository
                for key in mutation[:-1]:
                    target = target[key]
                target[mutation[-1]] = [{"malformed": True}]
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_repository(root, repository)
                    result = validate_repository(root, date(2026, 7, 16))
                self.assertTrue(result.errors)


if __name__ == "__main__":
    unittest.main()
