from __future__ import annotations

import base64
import copy
import hashlib
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from scripts.check_spec_governance import _commit_mapping_selector_matches_current, _extract_mapping_fragment, validate_repository


FIXTURES = Path(__file__).parent / "fixtures" / "spec_governance"
JOURNEY_RESULT_SIGNING_DOMAIN = b"macprovider.journey-result.v1\n"
GAP = {
    "verdict": "UNKNOWN",
    "owner": "@owner",
    "issue": "https://github.com/Augustas11/macprovider/issues/614",
}
SPEC016_PAYOUT_JOURNEY_ID = "JOURNEY-SPEC-016-PAYOUT-ADDRESS-REGISTRATION"
SPEC016_PAYOUT_RUN_ID = "spec016-r002-payout-address-20260101T000000Z"


def canonical_json_bytes(value: object) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8")


def signed_journey_envelope(
    commit: str,
    *,
    requirement_ids: list[str] | None = None,
    journey_id: str = "JOURNEY-BOOT",
    result_status: str = "pass",
    step_status: str = "pass",
    artifacts: list[str] | None = None,
    artifact_records: list[dict[str, str]] | None = None,
    captured_at: str = "2026-01-01T00:00:00Z",
    signed_sha256: str | None = None,
    signatures: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    signed = {
        "schema_version": "macprovider.journey-result.v1",
        "journey_id": journey_id,
        "requirement_ids": requirement_ids or ["SPEC-001-R001"],
        "repository": {
            "name": "Augustas11/macprovider",
            "commit": commit,
        },
        "captured_at": captured_at,
        "expires_at": "2027-01-01",
        "operator": {
            "role": "fixture-operator",
            "identity_fingerprint": "a" * 64,
        },
        "environment": {
            "class": "fixture-physical-provider",
            "hardware_profile": "fixture-apple-silicon",
            "candidate": "fixture-candidate",
        },
        "artifacts": artifact_records or [
            {
                "id": "proof",
                "sha256": hashlib.sha256(b"proof\n").hexdigest(),
                "source": "journeys/evidence/proof.txt",
            }
        ],
        "result": {
            "status": result_status,
            "summary": "fixture journey passed",
        },
        "steps": [
            {
                "id": "step-1",
                "status": step_status,
                "assertion": "fixture assertion",
                "artifacts": ["proof"] if artifacts is None else artifacts,
            }
        ],
        "redaction": {
            "secrets_redacted": True,
            "operator_identity_redacted": True,
            "local_account_names_redacted": True,
        },
    }
    digest = hashlib.sha256(canonical_json_bytes(signed)).hexdigest()
    envelope_signatures = signatures
    if envelope_signatures is None:
        envelope_signatures = [
            {
                "algorithm": "ecdsa-p256-sha256",
                "key_id": "macprovider-acceptance-p256-v1",
                "signature": "unsigned-fixture",
                "signed_sha256": signed_sha256 or digest,
                "verified_at": "2026-01-01T00:00:01Z",
                "verifier": "fixture-verifier",
            }
        ]
    return {
        "schema_version": "macprovider.journey-result-envelope.v1",
        "signatures": envelope_signatures,
        "signed": signed,
    }


def spec016_payout_signed_envelope(commit: str, artifact_record: dict[str, str]) -> dict[str, object]:
    envelope = signed_journey_envelope(
        commit,
        requirement_ids=["SPEC-016-R002"],
        journey_id=SPEC016_PAYOUT_JOURNEY_ID,
        artifact_records=[artifact_record],
        artifacts=[artifact_record["id"]],
    )
    signed = envelope["signed"]
    assert isinstance(signed, dict)
    signed.update({
        "spec_id": "SPEC-016",
        "run_id": SPEC016_PAYOUT_RUN_ID,
        "execution_mode": "candidate-derived-handler-only-conformance-harness",
        "harness": {
            "id": "phase4-coordinator/internal/payout:TestPayoutAddressRegistrationJourneyEvidence",
            "version": "v1",
            "execution_mode": "candidate-derived-handler-only-conformance-harness",
            "isolated_sqlite": True,
            "real_provider_token_check": True,
            "real_pause_validation": True,
            "controlled_dependencies": True,
            "production_runner_built": False,
            "external_rpc_client_built": False,
            "settlement_signer_built": False,
            "release_promotion_attempted": False,
        },
        "config_before": {
            "payout_enabled": False,
            "runner_started": False,
            "external_rpc_started": False,
            "settlement_signer_started": False,
        },
        "config_after": {
            "payout_enabled": False,
            "runner_started": False,
            "external_rpc_started": False,
            "settlement_signer_started": False,
            "settlement_attempted": False,
            "production_side_effects": False,
        },
        "restoration": {"result": "isolated SQLite tempdir removed by test cleanup"},
        "observations": {
            "provider_id_sha256": "b" * 64,
            "hot_wallet_sha256": "c" * 64,
            "first_address_sha256": "d" * 64,
            "eip712_digest_sha256": "e" * 64,
            "raw_signature_redacted": True,
            "provider_token_redacted": True,
            "private_keys_redacted": True,
        },
        "eip712": {
            "typed_data_artifact_sha256": "1" * 64,
            "digest_sha256": "2" * 64,
            "signer_address_sha256": "3" * 64,
            "verifier": "fixture-eip712-verifier",
            "verification_result": "pass",
            "raw_signature_access_controlled": True,
        },
        "candidate": {
            "addresses_go_sha256": "4" * 64,
            "eip712_go_sha256": "5" * 64,
            "attempts_go_sha256": "6" * 64,
            "payout_address_client_sha256": "7" * 64,
            "payout_wallet_flow_sha256": "8" * 64,
            "payout_signer_resource_sha256": "9" * 64,
        },
        "signer": {
            "key_id": "macprovider-acceptance-p256-v1",
            "identity_fingerprint": "a" * 64,
            "trust_root_sha256": "f" * 64,
            "verification_result": "pass",
        },
        "steps": [
            {
                "id": f"step-{index:02d}",
                "status": "pass",
                "assertion": f"fixture SPEC-016 payout assertion {index:02d}",
                "artifacts": [artifact_record["id"]],
            }
            for index in range(1, 12)
        ],
    })
    envelope["signatures"][0]["signed_sha256"] = hashlib.sha256(canonical_json_bytes(signed)).hexdigest()
    return envelope


def sign_journey_envelope(root: Path, envelope: dict[str, object], *, corrupt_signature: bool = False) -> None:
    security = root / "security"
    security.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        private_key = work / "private.pem"
        public_key = security / "acceptance-candidate-signing-public.pem"
        message = work / "message"
        signature = work / "signature.der"
        subprocess.run(
            ["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(private_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        subprocess.run(
            ["openssl", "ec", "-in", str(private_key), "-pubout", "-out", str(public_key)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        message.write_bytes(JOURNEY_RESULT_SIGNING_DOMAIN + canonical_json_bytes(envelope["signed"]))
        subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature), str(message)],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        signature_bytes = bytearray(signature.read_bytes())
        if corrupt_signature:
            signature_bytes[-1] ^= 0x01
        encoded = base64.b64encode(bytes(signature_bytes)).decode("ascii")
    envelope["signatures"][0]["signature"] = encoded


def validate_repository_with_fixture_key(root: Path) -> list[str]:
    public_key = root / "security" / "acceptance-candidate-signing-public.pem"
    if not public_key.exists():
        return validate_repository(root).errors
    trusted_hash = hashlib.sha256(public_key.read_bytes()).hexdigest()
    return validate_repository(root, trusted_journey_result_public_key_sha256=trusted_hash).errors


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
            "schemas/journey-result-v1.schema.json": json.dumps({
                "$id": "https://github.com/Augustas11/macprovider/schemas/journey-result-v1.schema.json",
                "$defs": {
                    "signature": {
                        "properties": {
                            "algorithm": {"const": "ecdsa-p256-sha256"},
                            "key_id": {"const": "macprovider-acceptance-p256-v1"},
                        }
                    }
                },
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
                    "requires_signed_journey_result": True,
                    "owner": "@owner",
                    "issue": "https://github.com/Augustas11/macprovider/issues/614",
                },
                {
                    "id": "two-domain",
                    "owner_spec": "SPEC-002",
                    "consumers": [],
                    "status": "pending-reconciliation",
                    "requires_signed_journey_result": False,
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
    elif operation == "sensitive_conformant_without_signed_result":
        digest = hashlib.sha256((root / "journeys" / "evidence" / "proof.txt").read_bytes()).hexdigest()
        requirement["journeys"] = ["JOURNEY-BOOT"]
        requirement["evidence"] = [
            {
                "artifact": f"commit:{commit}",
                "source": None,
                "captured_at": "2026-01-01",
                "expires_at": "2027-01-01",
            },
            {
                "artifact": f"sha256:{digest}",
                "source": "journeys/evidence/proof.txt",
                "captured_at": "2026-01-01",
                "expires_at": "2027-01-01",
            },
        ]
    elif operation in {
        "valid_signed_journey_result",
        "signed_journey_result_missing_signature",
        "signed_journey_result_hash_mismatch",
        "signed_journey_result_failed_step",
        "signed_journey_result_wrong_requirement",
        "signed_journey_result_empty_artifacts",
        "signed_journey_result_future_capture",
        "signed_journey_result_bad_signature",
        "signed_journey_result_commit_mismatch",
        "signed_journey_result_mixed_physical_evidence",
        "production_physically_verified_with_pending_requirement",
        "valid_spec016_payout_signed_journey_result",
        "spec016_payout_signed_journey_result_missing_contract_fields",
        "spec016_payout_signed_journey_result_candidate_artifact",
        "spec016_payout_signed_journey_result_wrong_journey",
        "spec016_payout_signed_journey_result_duplicate_step",
        "spec016_payout_signed_journey_result_extra_secret_field",
    }:
        if operation == "signed_journey_result_missing_signature":
            envelope = signed_journey_envelope(commit, signatures=[])
        elif operation == "signed_journey_result_hash_mismatch":
            envelope = signed_journey_envelope(commit, signed_sha256="0" * 64)
        elif operation == "signed_journey_result_failed_step":
            envelope = signed_journey_envelope(commit, step_status="fail")
        elif operation == "signed_journey_result_wrong_requirement":
            envelope = signed_journey_envelope(commit, requirement_ids=["SPEC-001-R999"])
        elif operation == "signed_journey_result_empty_artifacts":
            envelope = signed_journey_envelope(commit, artifacts=[])
        elif operation == "signed_journey_result_future_capture":
            envelope = signed_journey_envelope(commit, captured_at="2099-01-01T00:00:00Z")
        elif operation == "signed_journey_result_bad_signature":
            envelope = signed_journey_envelope(commit)
        elif operation == "signed_journey_result_commit_mismatch":
            older_commit = commit
            (root / "src" / "example.py").write_text("def example():\n    return True\n\n", encoding="utf-8")
            subprocess.run(["git", "add", "."], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "new implementation evidence"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            envelope = signed_journey_envelope(older_commit)
        elif operation == "production_physically_verified_with_pending_requirement":
            conformance["requirements"].append({
                "requirement_id": "SPEC-001-R002",
                "spec_id": "SPEC-001",
                "state": "pending",
                "implementation": ["src/example.py:example"],
                "tests": ["tests/test_example.py::test_example"],
                "journeys": [],
                "evidence": [],
                "gap": copy.deepcopy(GAP),
            })
            conformance["specs"][0]["production_status"] = "physically-verified"
            envelope = signed_journey_envelope(commit)
        elif operation in {
            "valid_spec016_payout_signed_journey_result",
            "spec016_payout_signed_journey_result_missing_contract_fields",
            "spec016_payout_signed_journey_result_candidate_artifact",
            "spec016_payout_signed_journey_result_wrong_journey",
            "spec016_payout_signed_journey_result_duplicate_step",
            "spec016_payout_signed_journey_result_extra_secret_field",
        }:
            redacted_path = root / "journeys" / "evidence" / "spec016-payout-redacted.json"
            redacted_path.write_text(
                json.dumps({
                    "schema_version": "macprovider.payout-address-journey-evidence.v1",
                    "journey_id": SPEC016_PAYOUT_JOURNEY_ID,
                    "run_id": SPEC016_PAYOUT_RUN_ID,
                    "redacted": True,
                }, indent=2) + "\n",
                encoding="utf-8",
            )
            artifact_record = {
                "id": "redacted-payout-address-journey",
                "sha256": hashlib.sha256(redacted_path.read_bytes()).hexdigest(),
                "source": "journeys/evidence/spec016-payout-redacted.json",
            }
            if operation == "spec016_payout_signed_journey_result_candidate_artifact":
                candidate_path = root / "journeys" / "evidence" / "spec016-payout.candidate.json"
                candidate_path.write_text(
                    json.dumps({
                        "schema_version": "macprovider.journey-result-candidate.v1",
                        "journey_id": SPEC016_PAYOUT_JOURNEY_ID,
                        "run_id": SPEC016_PAYOUT_RUN_ID,
                        "promotion_ready": False,
                    }, indent=2) + "\n",
                    encoding="utf-8",
                )
                artifact_record = {
                    "id": "redacted-payout-address-journey",
                    "sha256": hashlib.sha256(candidate_path.read_bytes()).hexdigest(),
                    "source": "journeys/evidence/spec016-payout.candidate.json",
                }
            if operation == "spec016_payout_signed_journey_result_wrong_journey":
                envelope = signed_journey_envelope(
                    commit,
                    requirement_ids=["SPEC-016-R002"],
                    journey_id="JOURNEY-BOOT",
                    artifact_records=[artifact_record],
                    artifacts=[artifact_record["id"]],
                )
            elif operation == "spec016_payout_signed_journey_result_missing_contract_fields":
                envelope = signed_journey_envelope(
                    commit,
                    requirement_ids=["SPEC-016-R002"],
                    journey_id=SPEC016_PAYOUT_JOURNEY_ID,
                    artifact_records=[artifact_record],
                    artifacts=[artifact_record["id"]],
                )
            else:
                envelope = spec016_payout_signed_envelope(commit, artifact_record)
                if operation == "spec016_payout_signed_journey_result_duplicate_step":
                    signed = envelope["signed"]
                    assert isinstance(signed, dict)
                    steps = signed["steps"]
                    assert isinstance(steps, list)
                    steps.append(copy.deepcopy(steps[0]))
                    envelope["signatures"][0]["signed_sha256"] = hashlib.sha256(canonical_json_bytes(signed)).hexdigest()
                elif operation == "spec016_payout_signed_journey_result_extra_secret_field":
                    signed = envelope["signed"]
                    assert isinstance(signed, dict)
                    observations = signed["observations"]
                    assert isinstance(observations, dict)
                    observations["provider_token_raw"] = "secret-token-would-leak"
                    envelope["signatures"][0]["signed_sha256"] = hashlib.sha256(canonical_json_bytes(signed)).hexdigest()
        else:
            envelope = signed_journey_envelope(commit)
        if envelope["signatures"]:
            sign_journey_envelope(root, envelope, corrupt_signature=operation == "signed_journey_result_bad_signature")
        evidence_path = root / "journeys" / "evidence" / "signed-result.json"
        evidence_path.write_text(json.dumps(envelope, indent=2, sort_keys=False) + "\n", encoding="utf-8")
        digest = hashlib.sha256(evidence_path.read_bytes()).hexdigest()
        if operation in {
            "valid_spec016_payout_signed_journey_result",
            "spec016_payout_signed_journey_result_missing_contract_fields",
            "spec016_payout_signed_journey_result_candidate_artifact",
            "spec016_payout_signed_journey_result_wrong_journey",
            "spec016_payout_signed_journey_result_duplicate_step",
            "spec016_payout_signed_journey_result_extra_secret_field",
        }:
            requirement["journeys"] = [SPEC016_PAYOUT_JOURNEY_ID]
            if operation == "spec016_payout_signed_journey_result_wrong_journey":
                requirement["journeys"] = ["JOURNEY-BOOT"]
        else:
            requirement["journeys"] = ["JOURNEY-BOOT"]
        requirement["evidence"] = [
            {
                "artifact": f"commit:{commit}",
                "source": None,
                "captured_at": "2026-01-01",
                "expires_at": "2027-01-01",
            },
            {
                "artifact": f"sha256:{digest}",
                "source": "journeys/evidence/signed-result.json",
                "captured_at": "2026-01-01",
                "expires_at": "2027-01-01",
            },
        ]
        if operation == "signed_journey_result_mixed_physical_evidence":
            proof_digest = hashlib.sha256((root / "journeys" / "evidence" / "proof.txt").read_bytes()).hexdigest()
            requirement["evidence"].append({
                "artifact": f"sha256:{proof_digest}",
                "source": "journeys/evidence/proof.txt",
                "captured_at": "2026-01-01",
                "expires_at": "2027-01-01",
            })
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
    elif operation == "drop_authority_owner_listing":
        specs[0]["authority_domains"] = []
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
    elif operation == "missing_mapping_selector":
        requirements[0]["implementation"] = ["src/example.py:missing"]
        requirements[0]["tests"] = ["tests/test_example.py::missing"]
    elif operation == "hostile_schema_pointer":
        authority["$schema"] = "../schemas/other.json"
    elif operation == "implemented_unverified_without_requirements":
        specs[1]["status"] = "implemented-unverified"
        specs[1]["requirement_id_migration"] = "complete"
    elif operation == "implemented_unverified_without_conformance":
        specs[0]["status"] = "implemented-unverified"
    elif operation == "implementation_status_implemented_without_conformance":
        specs[0]["implementation_status"] = "implemented"
    elif operation == "physically_verified_without_proof":
        specs[0]["status"] = "physically-verified"
    elif operation == "production_physically_verified_without_signed_result":
        specs[0]["production_status"] = "physically-verified"
    elif operation == "production_physically_verified_without_requirements":
        specs[1]["production_status"] = "physically-verified"
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
    elif operation == "sensitive_conformant_without_signed_result":
        repository["_post_write_operation"] = "sensitive_conformant_without_signed_result"
    elif operation == "valid_signed_journey_result":
        repository["_post_write_operation"] = "valid_signed_journey_result"
    elif operation in {
        "valid_spec016_payout_signed_journey_result",
        "spec016_payout_signed_journey_result_missing_contract_fields",
        "spec016_payout_signed_journey_result_candidate_artifact",
        "spec016_payout_signed_journey_result_wrong_journey",
        "spec016_payout_signed_journey_result_duplicate_step",
        "spec016_payout_signed_journey_result_extra_secret_field",
    }:
        repository["files"]["specs/SPEC-016-payout-pipeline.md"] = "# SPEC-016 - Payout Pipeline\n\n**Version:** 0.1.0\n\nHuman contract text.\n"
        repository["files"][f"journeys/{SPEC016_PAYOUT_JOURNEY_ID}.md"] = f"# {SPEC016_PAYOUT_JOURNEY_ID}\n"
        del repository["files"]["specs/SPEC-001-one.md"]
        authority["domains"][0].update({
            "id": "payout-lifecycle",
            "owner_spec": "SPEC-016",
            "consumers": [],
        })
        specs[0].update({
            "spec_id": "SPEC-016",
            "title": "Payout Pipeline",
            "path": "specs/SPEC-016-payout-pipeline.md",
            "authority_domains": ["payout-lifecycle"],
            "depends_on": [],
        })
        requirements[0].update({
            "requirement_id": "SPEC-016-R002",
            "spec_id": "SPEC-016",
            "journeys": [SPEC016_PAYOUT_JOURNEY_ID],
        })
        repository["_post_write_operation"] = operation
    elif operation == "signed_journey_result_missing_signature":
        repository["_post_write_operation"] = "signed_journey_result_missing_signature"
    elif operation == "signed_journey_result_hash_mismatch":
        repository["_post_write_operation"] = "signed_journey_result_hash_mismatch"
    elif operation == "signed_journey_result_failed_step":
        repository["_post_write_operation"] = "signed_journey_result_failed_step"
    elif operation == "signed_journey_result_wrong_requirement":
        repository["_post_write_operation"] = "signed_journey_result_wrong_requirement"
    elif operation == "signed_journey_result_empty_artifacts":
        repository["_post_write_operation"] = "signed_journey_result_empty_artifacts"
    elif operation == "signed_journey_result_future_capture":
        repository["_post_write_operation"] = "signed_journey_result_future_capture"
    elif operation == "signed_journey_result_bad_signature":
        repository["_post_write_operation"] = "signed_journey_result_bad_signature"
    elif operation == "signed_journey_result_commit_mismatch":
        repository["_post_write_operation"] = "signed_journey_result_commit_mismatch"
    elif operation == "signed_journey_result_mixed_physical_evidence":
        repository["_post_write_operation"] = "signed_journey_result_mixed_physical_evidence"
    elif operation == "production_physically_verified_with_pending_requirement":
        repository["_post_write_operation"] = "production_physically_verified_with_pending_requirement"
    elif operation == "mismatched_spec_header_id":
        repository["files"]["specs/SPEC-001-one.md"] = (
            "# SPEC-999 - One\n\n**Version:** 0.1.0\n\nHuman contract text.\n"
        )
    elif operation == "not_applicable_without_rationale":
        requirements[0]["state"] = "not-applicable"
        requirements[0]["implementation"] = []
        requirements[0]["tests"] = []
        requirements[0]["gap"] = None
    elif operation == "normalized_spec_mapping":
        requirements[0]["implementation"] = ["specs/SPEC-002-two.md"]
    elif operation == "same_spec_markdown_mapping":
        requirements[0]["state"] = "conformant"
        requirements[0]["implementation"] = ["specs/SPEC-001-one.md:Human contract text"]
        requirements[0]["tests"] = ["specs/SPEC-001-one.md:Human contract text"]
        requirements[0]["gap"] = None
    elif operation == "normalized_spec_markdown_mapping":
        requirements[0]["state"] = "conformant"
        requirements[0]["implementation"] = ["./specs/SPEC-001-one.md:Human contract text"]
        requirements[0]["tests"] = ["./specs/SPEC-001-one.md:Human contract text"]
        requirements[0]["gap"] = None
    elif operation == "deprecated_authority_owner":
        specs[0]["status"] = "deprecated"
        specs[0]["deprecation_rationale"] = "retired"
    elif operation == "deprecated_domain_listed_by_active_spec":
        authority["domains"][0]["status"] = "deprecated"
    elif operation == "malformed_owner_spec":
        authority["domains"][0]["owner_spec"] = []
    elif operation == "malformed_consumers":
        authority["domains"][0]["consumers"] = "SPEC-002"
    elif operation == "malformed_signed_result_flag":
        authority["domains"][0]["requires_signed_journey_result"] = "yes"
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

    def test_commit_evidence_allows_unrelated_file_changes_when_selectors_still_resolve(self) -> None:
        repository = base_repository()
        repository["authority"]["domains"][0]["requires_signed_journey_result"] = False
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            conformance_path = root / "specs" / "CONFORMANCE.json"
            conformance = json.loads(conformance_path.read_text(encoding="utf-8"))
            requirement = conformance["requirements"][0]
            requirement["state"] = "conformant"
            requirement["gap"] = None
            requirement["evidence"] = [{
                "artifact": f"commit:{commit}",
                "source": None,
                "captured_at": "2026-01-01",
                "expires_at": "2027-01-01",
            }]
            conformance_path.write_text(json.dumps(conformance, indent=2, sort_keys=False) + "\n", encoding="utf-8")
            (root / "src" / "example.py").write_text(
                "def example():\n    return True\n\n\ndef unrelated_helper():\n    return False\n",
                encoding="utf-8",
            )

            self.assertEqual([], validate_repository(root).errors)

    def test_mapping_selector_does_not_resolve_from_comment_only_text(self) -> None:
        repository = base_repository()
        repository["files"]["src/example.py"] = "# selector text only: example\n"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)

            errors = "\n".join(validate_repository(root).errors)
            self.assertIn("mapping selector 'example' does not resolve in 'src/example.py'", errors)

    def test_go_mapping_selector_does_not_resolve_from_text_anchor_only(self) -> None:
        cases = {
            "comment": "// Foo only\n",
            "call_site": "func caller() {\n\tFoo()\n}\n",
            "prefix": "func FooBar() {\n\treturn\n}\n",
        }
        for name, source in cases.items():
            with self.subTest(name=name):
                repository = base_repository()
                repository["files"]["src/example.go"] = source
                repository["conformance"]["requirements"][0]["implementation"] = ["src/example.go:Foo"]
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_repository(root, repository)

                    errors = "\n".join(validate_repository(root).errors)
                    self.assertIn("mapping selector 'Foo' does not resolve in 'src/example.go'", errors)

    def test_swift_mapping_selector_does_not_resolve_from_text_anchor_only(self) -> None:
        cases = {
            "comment": "// authInitialMessage only\n",
            "call_site": "func caller() {\n    authInitialMessage()\n}\n",
            "prefix": "func authInitialMessageV2() -> String {\n    \"new\"\n}\n",
        }
        for name, source in cases.items():
            with self.subTest(name=name):
                repository = base_repository()
                repository["files"]["src/example.swift"] = source
                repository["conformance"]["requirements"][0]["implementation"] = ["src/example.swift:authInitialMessage"]
                with tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    write_repository(root, repository)

                    errors = "\n".join(validate_repository(root).errors)
                    self.assertIn(
                        "mapping selector 'authInitialMessage' does not resolve in 'src/example.swift'",
                        errors,
                    )

    def test_go_selector_fragment_prefers_declaration_over_comment_or_call_site(self) -> None:
        text = (
            "// ServePayoutAddress is mentioned before the handler.\n"
            "func call() {\n"
            "\tServePayoutAddress()\n"
            "}\n\n"
            "func (s *AddressesService) ServePayoutAddress(w http.ResponseWriter, r *http.Request) {\n"
            "\treturn\n"
            "}\n"
        )

        fragment = _extract_mapping_fragment(text, "ServePayoutAddress", "src/example.go")

        self.assertIsNotNone(fragment)
        assert fragment is not None
        self.assertTrue(fragment.startswith("func (s *AddressesService) ServePayoutAddress"), fragment)

    def test_swift_selector_fragment_prefers_exact_declaration_over_prefix_or_call_site(self) -> None:
        text = (
            "public enum PayoutAddressClientError: Error {}\n"
            "func caller() {\n"
            "    let initialMessage = await authInitialMessage(attempt: attempt)\n"
            "}\n\n"
            "public struct PayoutAddressClient {\n"
            "    let baseURL: URL\n"
            "}\n\n"
            "func authInitialMessage(attempt: Int) async -> String {\n"
            "    \"ok\"\n"
            "}\n"
        )

        client = _extract_mapping_fragment(text, "PayoutAddressClient", "src/example.swift")
        auth = _extract_mapping_fragment(text, "authInitialMessage", "src/example.swift")

        self.assertIsNotNone(client)
        self.assertIsNotNone(auth)
        assert client is not None
        assert auth is not None
        self.assertTrue(client.startswith("public struct PayoutAddressClient"), client)
        self.assertTrue(auth.startswith("func authInitialMessage"), auth)

    def test_selector_fragment_rejects_prefix_declarations(self) -> None:
        go_text = (
            "func FooBar() {\n"
            "\treturn\n"
            "}\n\n"
            "func Foo() {\n"
            "\treturn\n"
            "}\n"
        )
        swift_text = (
            "func authInitialMessageV2() -> String {\n"
            "    \"new\"\n"
            "}\n\n"
            "func authInitialMessage() -> String {\n"
            "    \"old\"\n"
            "}\n"
        )

        go_fragment = _extract_mapping_fragment(go_text, "Foo", "src/example.go")
        swift_fragment = _extract_mapping_fragment(swift_text, "authInitialMessage", "src/example.swift")

        self.assertIsNotNone(go_fragment)
        self.assertIsNotNone(swift_fragment)
        assert go_fragment is not None
        assert swift_fragment is not None
        self.assertTrue(go_fragment.startswith("func Foo()"), go_fragment)
        self.assertTrue(swift_fragment.startswith("func authInitialMessage()"), swift_fragment)

    def test_selector_fragment_does_not_fall_back_to_prefix_when_exact_declaration_is_absent(self) -> None:
        go_text = "func FooBar() {\n\treturn\n}\n"
        swift_text = "func authInitialMessageV2() -> String {\n    \"new\"\n}\n"

        self.assertIsNone(_extract_mapping_fragment(go_text, "Foo", "src/example.go"))
        self.assertIsNone(_extract_mapping_fragment(swift_text, "authInitialMessage", "src/example.swift"))

    def test_selector_fragment_rejects_local_go_and_swift_bindings(self) -> None:
        go_text = "func caller() {\n\tFoo = 1\n}\n"
        swift_text = "func caller() {\n    let authInitialMessage = \"local\"\n}\n"

        self.assertIsNone(_extract_mapping_fragment(go_text, "Foo", "src/example.go"))
        self.assertIsNone(_extract_mapping_fragment(swift_text, "authInitialMessage", "src/example.swift"))

    def test_selector_fragment_rejects_unparseable_go_and_swift_selector_text(self) -> None:
        go_text = "func caller() {\n\tFoo()\n}\n"
        swift_text = "func caller() {\n    authInitialMessage()\n}\n"

        self.assertIsNone(_extract_mapping_fragment(go_text, "Foo()", "src/example.go"))
        self.assertIsNone(_extract_mapping_fragment(swift_text, "authInitialMessage()", "src/example.swift"))

    def test_go_selector_fragment_resolves_struct_field(self) -> None:
        go_text = "type Provider struct {\n\tWeightsManifestSHA256 string\n}\n"

        fragment = _extract_mapping_fragment(go_text, "WeightsManifestSHA256 string", "src/example.go")

        self.assertEqual("\tWeightsManifestSHA256 string", fragment)

    def test_go_selector_fragment_resolves_const_group_item(self) -> None:
        go_text = (
            "const (\n\tSnapshotManifestV1 = \"macprovider.snapshot-manifest.v1\"\n)\n\n"
            "var sha256Pattern = regexp.MustCompile(`^[0-9a-f]{64}$`)\n"
        )

        fragment = _extract_mapping_fragment(go_text, "SnapshotManifestV1", "src/example.go")

        self.assertEqual("SnapshotManifestV1 = \"macprovider.snapshot-manifest.v1\"", fragment.lstrip() if fragment else fragment)

    def test_swift_selector_fragment_includes_multiline_initializer(self) -> None:
        swift_text = (
            "final class RouterHandler {\n"
            "    static let localStatusCapabilities = [\n"
            "        \"buyer_serving_authority_v1\",\n"
            "        \"referral_fragment_links_v1\",\n"
            "    ]\n"
            "}\n"
        )

        fragment = _extract_mapping_fragment(swift_text, "localStatusCapabilities", "src/example.swift")

        self.assertIsNotNone(fragment)
        assert fragment is not None
        self.assertIn("\"referral_fragment_links_v1\"", fragment)

    def test_selector_fragment_rejects_inactive_go_and_swift_declarations(self) -> None:
        go_comment = "/*\nfunc Foo() {\n\treturn\n}\n*/\n"
        go_raw_string = "var doc = `\nfunc Foo() {\n\treturn\n}\n`\n"
        swift_comment = "/*\nfunc authInitialMessage() -> String {\n    \"old\"\n}\n*/\n"
        swift_inactive = "#if false\nfunc authInitialMessage() -> String {\n    \"old\"\n}\n#endif\n"
        swift_multiline_string = 'let doc = """\nfunc authInitialMessage() -> String {\n    "old"\n}\n"""\n'

        self.assertIsNone(_extract_mapping_fragment(go_comment, "Foo", "src/example.go"))
        self.assertIsNone(_extract_mapping_fragment(go_raw_string, "Foo", "src/example.go"))
        self.assertIsNone(_extract_mapping_fragment(swift_comment, "authInitialMessage", "src/example.swift"))
        self.assertIsNone(_extract_mapping_fragment(swift_inactive, "authInitialMessage", "src/example.swift"))
        self.assertIsNone(_extract_mapping_fragment(swift_multiline_string, "authInitialMessage", "src/example.swift"))

    def test_selector_fragment_rejects_duplicate_go_or_swift_declarations(self) -> None:
        go_text = "func Foo() {\n\treturn\n}\n\nfunc Foo() {\n\treturn\n}\n"
        swift_text = "func authInitialMessage() -> String {\n    \"one\"\n}\n\nfunc authInitialMessage() -> String {\n    \"two\"\n}\n"

        self.assertIsNone(_extract_mapping_fragment(go_text, "Foo", "src/example.go"))
        self.assertIsNone(_extract_mapping_fragment(swift_text, "authInitialMessage", "src/example.swift"))

    def test_selector_fragment_rejects_duplicate_python_declarations(self) -> None:
        python_text = "def example():\n    return 'one'\n\n\ndef example():\n    return 'two'\n"

        self.assertIsNone(_extract_mapping_fragment(python_text, "example", "src/example.py"))

    def test_explicit_swift_declaration_selector_disambiguates_overloads(self) -> None:
        swift_text = (
            "func writeSuccessSentinel(binaryURL: URL, marker: AutoUpdatePendingMarker) throws {\n"
            "    try write()\n"
            "}\n\n"
            "func writeSuccessSentinel(binaryURL: URL, updateID: String, targetVersion: String) throws {\n"
            "    try write()\n"
            "}\n"
        )

        fragment = _extract_mapping_fragment(
            swift_text,
            "func writeSuccessSentinel(binaryURL: URL, marker: AutoUpdatePendingMarker)",
            "src/example.swift",
        )

        self.assertIsNotNone(fragment)
        assert fragment is not None
        self.assertIn("marker: AutoUpdatePendingMarker", fragment)
        self.assertNotIn("targetVersion", fragment)

    def test_commit_mapping_selector_rejects_inactive_declaration_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            go_path = root / "src" / "example.go"
            go_path.write_text("func Foo() {\n\treturn\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.go"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "go fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            go_path.write_text(
                "/*\nfunc Foo() {\n\treturn\n}\n*/\n\nfunc Foo() {\n\tpanic(\"changed\")\n}\n",
                encoding="utf-8",
            )

            self.assertFalse(_commit_mapping_selector_matches_current(root, commit, "src/example.go:Foo"))

    def test_commit_mapping_selector_rejects_go_build_constraint_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            go_path = root / "src" / "example.go"
            go_path.write_text("package example\n\nfunc Foo() {\n\treturn\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.go"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "go fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            go_path.write_text("//go:build ignore\n\npackage example\n\nfunc Foo() {\n\treturn\n}\n", encoding="utf-8")

            self.assertFalse(_commit_mapping_selector_matches_current(root, commit, "src/example.go:Foo"))

    def test_commit_mapping_selector_rejects_inactive_swift_compilation_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            swift_path = root / "src" / "example.swift"
            swift_path.write_text("func authInitialMessage() -> String {\n    \"old\"\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.swift"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "swift fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            swift_path.write_text(
                "#if false\nfunc authInitialMessage() -> String {\n    \"old\"\n}\n#endif\n\n"
                "func authInitialMessage() -> String {\n    \"new\"\n}\n",
                encoding="utf-8",
            )

            self.assertFalse(
                _commit_mapping_selector_matches_current(root, commit, "src/example.swift:authInitialMessage")
            )

    def test_commit_mapping_selector_rejects_nested_inactive_swift_compilation_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            swift_path = root / "src" / "example.swift"
            swift_path.write_text("func authInitialMessage() -> String {\n    \"old\"\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.swift"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "swift fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            swift_path.write_text(
                "#if false\n"
                "#if os(macOS)\n"
                "#endif\n"
                "func authInitialMessage() -> String {\n    \"old\"\n}\n"
                "#endif\n\n"
                "func authInitialMessage() -> String {\n    \"new\"\n}\n",
                encoding="utf-8",
            )

            self.assertFalse(
                _commit_mapping_selector_matches_current(root, commit, "src/example.swift:authInitialMessage")
            )

    def test_commit_mapping_selector_rejects_swift_conditional_wrapper_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            swift_path = root / "src" / "example.swift"
            swift_path.write_text("func authInitialMessage() -> String {\n    \"old\"\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.swift"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "swift fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            swift_path.write_text(
                "#if SOME_UNDECLARED_FLAG\n"
                "func authInitialMessage() -> String {\n    \"old\"\n}\n"
                "#endif\n",
                encoding="utf-8",
            )

            self.assertFalse(
                _commit_mapping_selector_matches_current(root, commit, "src/example.swift:authInitialMessage")
            )

    def test_commit_mapping_selector_rejects_multiline_initializer_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            swift_path = root / "src" / "example.swift"
            swift_path.write_text(
                "final class RouterHandler {\n"
                "    static let localStatusCapabilities = [\n"
                "        \"buyer_serving_authority_v1\",\n"
                "        \"referral_fragment_links_v1\",\n"
                "    ]\n"
                "}\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "src/example.swift"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "swift fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            swift_path.write_text(
                "final class RouterHandler {\n"
                "    static let localStatusCapabilities = [\n"
                "        \"buyer_serving_authority_v1\",\n"
                "        \"referral_fragment_links_v2\",\n"
                "    ]\n"
                "}\n",
                encoding="utf-8",
            )

            self.assertFalse(
                _commit_mapping_selector_matches_current(root, commit, "src/example.swift:localStatusCapabilities")
            )

    def test_commit_mapping_selector_rejects_shell_function_body_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            shell_path = root / "src" / "example.sh"
            shell_path.write_text("target() {\n    echo safe\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shell fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            shell_path.write_text("target() {\n    echo evil\n}\n", encoding="utf-8")

            self.assertFalse(_commit_mapping_selector_matches_current(root, commit, "src/example.sh:target"))

    def test_commit_mapping_selector_rejects_shell_body_drift_after_comment_brace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            shell_path = root / "src" / "example.sh"
            shell_path.write_text("target() {\n    # }\n    echo safe\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shell fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            shell_path.write_text("target() {\n    # }\n    echo evil\n}\n", encoding="utf-8")

            self.assertFalse(_commit_mapping_selector_matches_current(root, commit, "src/example.sh:target"))

    def test_commit_mapping_selector_rejects_shell_body_drift_after_heredoc_brace(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            shell_path = root / "src" / "example.sh"
            shell_path.write_text(
                "target() {\n"
                "    cat <<EOF\n"
                "}\n"
                "EOF\n"
                "    echo safe\n"
                "}\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "src/example.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shell fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            shell_path.write_text(
                "target() {\n"
                "    cat <<EOF\n"
                "}\n"
                "EOF\n"
                "    echo evil\n"
                "}\n",
                encoding="utf-8",
            )

            self.assertFalse(_commit_mapping_selector_matches_current(root, commit, "src/example.sh:target"))

    def test_commit_mapping_selector_rejects_duplicate_shell_function_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            shell_path = root / "src" / "example.sh"
            shell_path.write_text("target() {\n    echo safe\n}\n", encoding="utf-8")
            subprocess.run(["git", "add", "src/example.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shell fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            shell_path.write_text("target() {\n    echo safe\n}\n\ntarget() {\n    echo evil\n}\n", encoding="utf-8")

            self.assertFalse(_commit_mapping_selector_matches_current(root, commit, "src/example.sh:target"))

    def test_commit_mapping_selector_rejects_embedded_python_body_drift_in_shell(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            shell_path = root / "src" / "example.sh"
            shell_path.write_text(
                "#!/usr/bin/env bash\n"
                "python3 <<'PY'\n"
                "def fence_reload_helpers():\n"
                "    return 'safe'\n"
                "PY\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "src/example.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shell fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            shell_path.write_text(
                "#!/usr/bin/env bash\n"
                "python3 <<'PY'\n"
                "def fence_reload_helpers():\n"
                "    return 'evil'\n"
                "PY\n",
                encoding="utf-8",
            )

            self.assertFalse(
                _commit_mapping_selector_matches_current(root, commit, "src/example.sh:def fence_reload_helpers")
            )

    def test_commit_mapping_selector_rejects_inert_embedded_python_heredoc_forgery(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            shell_path = root / "src" / "example.sh"
            shell_path.write_text(
                "#!/usr/bin/env bash\n"
                "python3 <<'PY'\n"
                "def fence_reload_helpers():\n"
                "    return 'safe'\n"
                "print(fence_reload_helpers())\n"
                "PY\n",
                encoding="utf-8",
            )
            subprocess.run(["git", "add", "src/example.sh"], cwd=root, check=True)
            subprocess.run(["git", "commit", "-qm", "shell fixture"], cwd=root, check=True)
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            shell_path.write_text(
                "#!/usr/bin/env bash\n"
                ": <<'PY'\n"
                "def fence_reload_helpers():\n"
                "    return 'safe'\n"
                "PY\n"
                "python3 <<'PY'\n"
                "def fence_reload_helpers_v2():\n"
                "    return 'evil'\n"
                "print(fence_reload_helpers_v2())\n"
                "PY\n",
                encoding="utf-8",
            )

            self.assertFalse(
                _commit_mapping_selector_matches_current(root, commit, "src/example.sh:def fence_reload_helpers")
            )

    def test_embedded_python_selector_resolves_from_continued_python_heredoc(self) -> None:
        shell_text = (
            "validated=\"$(python3 - \"$INSTALL_DIR\" \\\n"
            "  \"$HOME\" <<'PY'\n"
            "def fence_reload_helpers():\n"
            "    return 'safe'\n"
            "PY\n"
            ")\"\n"
        )

        fragment = _extract_mapping_fragment(shell_text, "def fence_reload_helpers", "src/example.sh")

        self.assertEqual("def fence_reload_helpers():\n    return 'safe'", fragment)

    def test_embedded_python_selector_ignores_python_word_in_non_python_heredoc_command(self) -> None:
        shell_text = (
            "echo python3 <<'PY'\n"
            "def fence_reload_helpers():\n"
            "    return 'safe'\n"
            "PY\n"
        )

        self.assertIsNone(_extract_mapping_fragment(shell_text, "def fence_reload_helpers", "src/example.sh"))

    def test_embedded_python_selector_resolves_from_generated_shell_heredoc(self) -> None:
        shell_text = (
            "cat > \"$WATCHDOG_PATH\" <<'WATCHDOG_EOF'\n"
            "#!/usr/bin/env bash\n"
            "python3 <<'PY'\n"
            "def fence_reload_helpers():\n"
            "    return 'safe'\n"
            "PY\n"
            "WATCHDOG_EOF\n"
        )

        fragment = _extract_mapping_fragment(shell_text, "def fence_reload_helpers", "src/example.sh")

        self.assertEqual("def fence_reload_helpers():\n    return 'safe'", fragment)

    def test_embedded_python_selector_ignores_printf_stdin_heredoc(self) -> None:
        shell_text = (
            "printf '' > \"$WATCHDOG_PATH\" <<'WATCHDOG_EOF'\n"
            "#!/usr/bin/env bash\n"
            "python3 <<'PY'\n"
            "def fence_reload_helpers():\n"
            "    return 'safe'\n"
            "PY\n"
            "WATCHDOG_EOF\n"
        )

        self.assertIsNone(_extract_mapping_fragment(shell_text, "def fence_reload_helpers", "src/example.sh"))

    def test_embedded_python_selector_ignores_generated_shell_sink_heredoc(self) -> None:
        shell_text = (
            "cat > /dev/null <<'WATCHDOG_EOF'\n"
            "#!/usr/bin/env bash\n"
            "python3 <<'PY'\n"
            "def fence_reload_helpers():\n"
            "    return 'safe'\n"
            "PY\n"
            "WATCHDOG_EOF\n"
        )

        self.assertIsNone(_extract_mapping_fragment(shell_text, "def fence_reload_helpers", "src/example.sh"))

    def test_commit_mapping_selector_rejects_current_path_escape(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, base_repository())
            commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            outside = root.parent / "outside.py"
            outside.write_text("def example():\n    return True\n", encoding="utf-8")

            self.assertFalse(_commit_mapping_selector_matches_current(root, commit, "../outside.py:example"))

    def test_sensitive_conformant_with_signed_journey_result_passes(self) -> None:
        repository = base_repository()
        apply_mutation(repository, {"operation": "valid_signed_journey_result"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            apply_post_write_mutation(root, repository)
            self.assertEqual([], validate_repository_with_fixture_key(root))

    def test_signed_journey_result_can_coexist_with_other_physical_evidence(self) -> None:
        repository = base_repository()
        apply_mutation(repository, {"operation": "signed_journey_result_mixed_physical_evidence"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            apply_post_write_mutation(root, repository)
            self.assertEqual([], validate_repository_with_fixture_key(root))

    def test_spec016_payout_signed_journey_result_passes_when_contract_complete(self) -> None:
        repository = base_repository()
        apply_mutation(repository, {"operation": "valid_spec016_payout_signed_journey_result"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            apply_post_write_mutation(root, repository)
            self.assertEqual([], validate_repository_with_fixture_key(root))

    def test_signed_journey_result_rejects_unpinned_public_key(self) -> None:
        repository = base_repository()
        apply_mutation(repository, {"operation": "valid_signed_journey_result"})
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            write_repository(root, repository)
            apply_post_write_mutation(root, repository)
            errors = "\n".join(validate_repository(root).errors)
            self.assertIn("trusted public key does not match pinned journey-result trust anchor", errors)

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
                    errors = validate_repository_with_fixture_key(root)
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

    def test_base_manifest_prevents_lifecycle_reversal(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = base_repository()
            repository["conformance"]["specs"][0]["status"] = "normative"
            write_repository(root, repository)
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            repository["conformance"]["specs"][0]["status"] = "draft"
            write_repository(root, repository)
            errors = "\n".join(validate_repository(root, base_ref=base).errors)
            self.assertIn("SPEC record SPEC-001 lifecycle regressed from normative to draft", errors)

    def test_base_manifest_prevents_deprecated_authority_revival(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = base_repository()
            repository["authority"]["domains"][0]["status"] = "deprecated"
            repository["conformance"]["specs"][0]["authority_domains"] = []
            write_repository(root, repository)
            base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=root, text=True).strip()
            repository["authority"]["domains"][0]["status"] = "pending-reconciliation"
            repository["conformance"]["specs"][0]["authority_domains"] = ["provider-wire-protocol"]
            write_repository(root, repository)
            errors = "\n".join(validate_repository(root, base_ref=base).errors)
            self.assertIn("authority domain 'provider-wire-protocol' revived from deprecated", errors)


if __name__ == "__main__":
    unittest.main()
