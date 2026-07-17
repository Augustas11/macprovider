from __future__ import annotations

import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import validate_repository


FIXTURES = Path(__file__).parent / "fixtures" / "spec_governance"
GAP = {
    "verdict": "UNKNOWN",
    "owner": "@owner",
    "issue": "https://github.com/Augustas11/macprovider/issues/614",
}


def base_repository() -> dict[str, object]:
    return {
        "files": {
            "specs/SPEC-001-one.md": "# SPEC-001 - One\n\n**Version:** 0.1.0\n\nHuman contract text.\n",
            "specs/SPEC-002-two.md": "# SPEC-002 - Two\n\n**Version:** 0.1.0\n\nHuman contract text.\n",
            "src/example.py": "def example():\n    return True\n",
            "tests/test_example.py": "def test_example():\n    assert True\n",
            "journeys/JOURNEY-BOOT.md": "# JOURNEY-BOOT\n",
            "journeys/evidence/proof.txt": "proof\n",
            "schemas/spec-authority-v1.schema.json": json.dumps({
                "$id": "https://github.com/Augustas11/macprovider/schemas/spec-authority-v1.schema.json"
            }),
            "schemas/spec-conformance-v1.schema.json": json.dumps({
                "$id": "https://github.com/Augustas11/macprovider/schemas/spec-conformance-v1.schema.json"
            }),
            "schemas/spec-pr-governance-v1.schema.json": json.dumps({
                "$id": "https://github.com/Augustas11/macprovider/schemas/spec-pr-governance-v1.schema.json"
            }),
        },
        "authority": {
            "$schema": "../schemas/spec-authority-v1.schema.json",
            "schema_version": "spec-authority-v1",
            "baseline": {
                "commit": "1df5f76c3fbde1b84619b717fcc28ef1e2c05bc3",
                "captured_at": "2026-07-16",
            },
            "domains": [
                {
                    "id": "provider-wire-protocol",
                    "owner_spec": "SPEC-001",
                    "consumers": ["SPEC-002"],
                    "status": "pending-reconciliation",
                    "owner": "@owner",
                    "issue": "https://github.com/Augustas11/macprovider/issues/614",
                },
                {
                    "id": "two-domain",
                    "owner_spec": "SPEC-002",
                    "consumers": [],
                    "status": "pending-reconciliation",
                    "owner": "@owner",
                    "issue": "https://github.com/Augustas11/macprovider/issues/614",
                },
            ],
        },
        "conformance": {
            "$schema": "../schemas/spec-conformance-v1.schema.json",
            "schema_version": "spec-conformance-v1",
            "baseline": {
                "commit": "1df5f76c3fbde1b84619b717fcc28ef1e2c05bc3",
                "captured_at": "2026-07-16",
            },
            "specs": [
                {
                    "spec_id": "SPEC-001",
                    "title": "One",
                    "version": "0.1.0",
                    "path": "specs/SPEC-001-one.md",
                    "status": "draft",
                    "owner": "@owner",
                    "authority_domains": ["provider-wire-protocol"],
                    "supersedes": [],
                    "depends_on": ["SPEC-002"],
                    "implementation_status": "pending-reconciliation",
                    "production_status": "pending-verification",
                    "last_reconciled_commit": None,
                    "last_reconciled_at": None,
                    "evidence": [],
                    "requirement_id_migration": "complete",
                    "gap": None,
                },
                {
                    "spec_id": "SPEC-002",
                    "title": "Two",
                    "version": "0.1.0",
                    "path": "specs/SPEC-002-two.md",
                    "status": "draft",
                    "owner": "@owner",
                    "authority_domains": ["two-domain"],
                    "supersedes": [],
                    "depends_on": [],
                    "implementation_status": "pending-reconciliation",
                    "production_status": "pending-verification",
                    "last_reconciled_commit": None,
                    "last_reconciled_at": None,
                    "evidence": [],
                    "requirement_id_migration": "pending",
                    "gap": copy.deepcopy(GAP),
                },
            ],
            "requirements": [
                {
                    "requirement_id": "SPEC-001-R001",
                    "spec_id": "SPEC-001",
                    "state": "pending",
                    "implementation": ["src/example.py:example"],
                    "tests": ["tests/test_example.py::test_example"],
                    "journeys": [],
                    "evidence": [],
                    "gap": copy.deepcopy(GAP),
                }
            ],
        },
    }


def write_repository(root: Path, repository: dict[str, object]) -> None:
    for relative, contents in repository["files"].items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")
    for name, value in (
        ("specs/AUTHORITY.json", repository["authority"]),
        ("specs/CONFORMANCE.json", repository["conformance"]),
    ):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2, sort_keys=False) + "\n", encoding="utf-8")
    subprocess.run(["git", "init", "-q"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.invalid"], cwd=root, check=True)
    subprocess.run(["git", "config", "user.name", "test"], cwd=root, check=True)
    subprocess.run(["git", "add", "."], cwd=root, check=True)
    subprocess.run(["git", "commit", "-qm", "fixture"], cwd=root, check=True)


def apply_post_write_mutation(root: Path, repository: dict[str, object]) -> None:
    operation = repository.pop("_post_write_operation", None)
    if operation is None:
        return

    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
    conformance_path = root / "specs" / "CONFORMANCE.json"
    conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
    requirement = conformance["requirements"][0]
    requirement["state"] = "conformant"
    requirement["gap"] = None

    if operation == "future_evidence":
        requirement["evidence"] = [{
            "artifact": f"commit:{commit}",
            "source": None,
            "captured_at": "2099-01-01",
            "expires_at": "2099-12-31",
        }]
    elif operation == "stale_commit_evidence":
        requirement["evidence"] = [{
            "artifact": f"commit:{commit}",
            "source": None,
            "captured_at": "2026-01-01",
            "expires_at": "2027-01-01",
        }]
        (root / "src" / "example.py").write_text("def example():\n    return False\n", encoding="utf-8")
    else:
        raise AssertionError(f"unknown post-write fixture operation {operation!r}")

    conformance_path.write_text(json.dumps(conformance, indent=2, sort_keys=False) + "\n", encoding="utf-8")


def apply_mutation(repository: dict[str, object], mutation: dict[str, object]) -> None:
    operation = mutation["operation"]
    authority = repository["authority"]
    conformance = repository["conformance"]
    specs = conformance["specs"]
    requirements = conformance["requirements"]
    if operation == "drop_authority_schema_version":
        del authority["schema_version"]
    elif operation == "invalid_conformance":
        requirements[0]["state"] = "green"
    elif operation == "invalid_lifecycle":
        specs[0]["status"] = "locked"
    elif operation == "duplicate_authority":
        authority["domains"].append(copy.deepcopy(authority["domains"][0]))
    elif operation == "duplicate_requirement_id":
        requirements.append(copy.deepcopy(requirements[0]))
    elif operation == "broken_cross_spec_reference":
        specs[0]["depends_on"].append("SPEC-999")
    elif operation == "broken_requirement_reference":
        requirements[0]["spec_id"] = "SPEC-999"
    elif operation == "remove_requirement_mapping":
        conformance["requirements"] = []
    elif operation == "delete_spec_file":
        del repository["files"][mutation["path"]]
    elif operation == "fake_evidence_mappings":
        requirements[0]["implementation"] = ["src/missing.py:example"]
    elif operation == "hostile_schema_pointer":
        authority["$schema"] = "../schemas/other.json"
    elif operation == "implemented_unverified_without_requirements":
        specs[1]["status"] = "implemented-unverified"
        specs[1]["requirement_id_migration"] = "complete"
    elif operation == "physically_verified_without_proof":
        specs[0]["status"] = "physically-verified"
    elif operation == "stale_evidence":
        digest = hashlib.sha256(b"proof\n").hexdigest()
        requirements[0]["state"] = "conformant"
        requirements[0]["journeys"] = ["JOURNEY-BOOT"]
        requirements[0]["evidence"] = [{
            "artifact": f"sha256:{digest}",
            "source": "journeys/evidence/proof.txt",
            "captured_at": "2025-01-01",
            "expires_at": "2025-12-31",
        }]
        requirements[0]["gap"] = None
    elif operation == "unregistered_journey":
        requirements[0]["journeys"] = ["JOURNEY-MISSING"]
    elif operation == "physical_evidence_path_traversal":
        digest = hashlib.sha256(b"# JOURNEY-BOOT\n").hexdigest()
        requirements[0]["state"] = "conformant"
        requirements[0]["journeys"] = ["JOURNEY-BOOT"]
        requirements[0]["evidence"] = [{
            "artifact": f"sha256:{digest}",
            "source": "journeys/evidence/../JOURNEY-BOOT.md",
            "captured_at": "2026-01-01",
            "expires_at": "2027-01-01",
        }]
        requirements[0]["gap"] = None
    elif operation == "sha_evidence_without_source":
        requirements[0]["state"] = "conformant"
        requirements[0]["evidence"] = [{
            "artifact": "sha256:" + "0" * 64,
            "source": None,
            "captured_at": "2026-01-01",
            "expires_at": "2027-01-01",
        }]
        requirements[0]["gap"] = None
    elif operation == "future_evidence":
        repository["_post_write_operation"] = "future_evidence"
    elif operation == "stale_commit_evidence":
        repository["_post_write_operation"] = "stale_commit_evidence"
    elif operation == "mismatched_spec_header_id":
        repository["files"]["specs/SPEC-001-one.md"] = (
            "# SPEC-999 - One\n\n**Version:** 0.1.0\n\nHuman contract text.\n"
        )
    elif operation == "normalized_spec_mapping":
        requirements[0]["implementation"] = ["specs/SPEC-002-two.md"]
    elif operation == "deprecated_authority_owner":
        specs[0]["status"] = "deprecated"
        specs[0]["deprecation_rationale"] = "retired"
    elif operation == "malformed_owner_spec":
        authority["domains"][0]["owner_spec"] = []
    elif operation == "malformed_consumers":
        authority["domains"][0]["consumers"] = "SPEC-002"
    elif operation == "malformed_authority_domains":
        specs[0]["authority_domains"] = "provider-wire-protocol"
    elif operation == "malformed_gap":
        specs[1]["gap"] = []
    elif operation == "unowned_gap":
        del specs[1]["gap"]["owner"]
    elif operation == "divergent_baseline":
        conformance["baseline"]["commit"] = "2df5f76c3fbde1b84619b717fcc28ef1e2c05bc3"
    else:
        raise AssertionError(f"unknown fixture operation {operation!r}")


class GovernanceValidatorTests(unittest.TestCase):
    def test_valid_fixture_passes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            self.assertEqual([], validate_repository(root).errors)

    def test_real_spec_corpus_passes(self) -> None:
        root = Path(__file__).resolve().parents[2]
        self.assertEqual([], validate_repository(root).errors)

    def test_all_retained_invalid_fixtures_fail_actionably(self) -> None:
        for fixture in sorted(FIXTURES.glob("*.json")):
            with self.subTest(fixture=fixture.name):
                payload = json.loads(fixture.read_text(encoding="utf-8"))
                repository = base_repository()
                apply_mutation(repository, payload["mutation"])
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_repository(root, repository)
                    apply_post_write_mutation(root, repository)
                    errors = validate_repository(root).errors
                self.assertIn(payload["expected"], "\n".join(errors))

    def test_duplicate_json_object_keys_are_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            authority = root / "specs" / "AUTHORITY.json"
            authority.write_text(
                '{"$schema":"../schemas/spec-authority-v1.schema.json",'
                '"$schema":"../schemas/spec-authority-v1.schema.json"}',
                encoding="utf-8",
            )
            self.assertIn("duplicate JSON object key", "\n".join(validate_repository(root).errors))

    def test_base_manifest_prevents_authority_owner_reassignment(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = base_repository()
            write_repository(root, repository)
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            authority = repository["authority"]
            conformance = repository["conformance"]
            authority["domains"][0]["owner_spec"] = "SPEC-002"
            conformance["specs"][0]["authority_domains"] = []
            conformance["specs"][1]["authority_domains"].append("provider-wire-protocol")
            write_repository(root, repository)
            errors = "\n".join(validate_repository(root, base_ref=base).errors)
            self.assertIn("authority domain 'provider-wire-protocol' owner changed", errors)


if __name__ == "__main__":
    unittest.main()
