#!/usr/bin/env python3

import importlib.util
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts" / "openrouter_pricing_receipt.py"
sys.path.insert(0, str(REPO / "scripts"))
SPEC = importlib.util.spec_from_file_location("openrouter_pricing_receipt", SCRIPT)
receipt = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(receipt)

ARCHIVE = REPO / "docs" / "research" / "openrouter-snapshots"
SNAPSHOT = ARCHIVE / "openrouter-pricing-snapshot-2026-08-10T10-05-29Z-34126a58ac6728ec.json"
PROPOSAL = ARCHIVE / "openrouter-rate-card-proposal-2026-08-10T10-06-14Z-2a4ef8180e266e37.json"
POLICY = REPO / "scripts" / "openrouter_pricing_policy.json"
RATE_CARD = REPO / "phase3-binary" / "catalog" / "autotune" / "rate-card.json"


class ReceiptTests(unittest.TestCase):
    def base(self, receipt_type, artifact):
        return {
            "schema_version": 2,
            "receipt_type": receipt_type,
            "started_at": "2026-08-10T10:00:00Z",
            "finished_at": "2026-08-10T10:00:01Z",
            "engine_commit": "a" * 40,
            "execution": {"worktree_clean": True},
            "command": ["python", "scripts/openrouter_pricing_engine.py"],
            "exit_status": 0,
            "stdout": str(artifact.name),
            "stderr": "",
            "output_directory_listing": [receipt.inventory(artifact)],
        }

    def write(self, directory, value, name="receipt.json"):
        path = directory / name
        receipt.write_receipt(path, value)
        return path

    def test_validate_compute_exact_replay(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            copied = directory / PROPOSAL.name
            shutil.copyfile(PROPOSAL, copied)
            snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
            value = self.base("openrouter-pricing-compute-success", copied)
            value["inputs"] = {
                "snapshot_path": SNAPSHOT.relative_to(REPO).as_posix(),
                "snapshot_content_digest": snapshot["content_digest"],
                "snapshot_file_sha256": receipt.sha256_file(SNAPSHOT),
                "policy_path": POLICY.relative_to(REPO).as_posix(),
                "policy_file_sha256": receipt.sha256_file(POLICY),
                "rate_card_path": RATE_CARD.relative_to(REPO).as_posix(),
                "rate_card_file_sha256": receipt.sha256_file(RATE_CARD),
            }
            path = self.write(directory, value)
            receipt.validate_receipt(path, REPO)

    def test_validate_fetch_binds_policy_and_confirmation_provenance(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            copied = directory / SNAPSHOT.name
            shutil.copyfile(SNAPSHOT, copied)
            snapshot = json.loads(copied.read_text(encoding="utf-8"))
            metadata = snapshot["source"]["fetch_metadata"]
            confirmed = sorted(
                row["source_model_id"] for row in snapshot["rows"]
                if row["pricing_status"] == "no_provider_endpoints"
            )
            confirmations = sum(
                row["source_metadata"]["endpoint_set_confirmation"] != "not_required"
                for row in snapshot["rows"]
            )
            value = self.base("openrouter-pricing-fetch-success", copied)
            value["source"] = {
                "rankings_url": receipt.engine.RANKINGS_URL,
                "ranking_window_start_date": metadata["ranking_window_start_date"],
                "ranking_window_end_date": metadata["ranking_window_end_date"],
                "openrouter_api_key_configured": True,
                "confirmed_empty_model_ids": confirmed,
                "confirmation_request_count": confirmations,
                "successful_source_count": metadata["successful_source_count"],
                "policy_path": POLICY.relative_to(REPO).as_posix(),
                "policy_file_sha256": receipt.sha256_file(POLICY),
            }
            path = self.write(directory, value)
            receipt.validate_receipt(path, REPO)

    def test_tampered_receipt_digest_fails(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            copied = directory / PROPOSAL.name
            shutil.copyfile(PROPOSAL, copied)
            value = self.base("openrouter-pricing-compute-success", copied)
            value["inputs"] = {}
            path = self.write(directory, value)
            data = json.loads(path.read_text(encoding="utf-8"))
            data["stderr"] = "changed after digest"
            path.write_text(json.dumps(data), encoding="utf-8")
            with self.assertRaisesRegex(receipt.ReceiptError, "evidence_digest"):
                receipt.validate_receipt(path, REPO)

    def test_redaction_removes_exact_and_bearer_secrets(self):
        secret = "sk-or-v1-" + "a" * 64
        text = f"{secret}\nAuthorization: Bearer {secret}\nBearer {secret}"
        redacted = receipt.redact(text, secret, Path("C:/unused"))
        self.assertNotIn("sk-or-", redacted.lower())
        self.assertIn("<redacted>", redacted)

    def test_clean_commit_rejects_dirty_worktree(self):
        with mock.patch.object(receipt, "git", return_value="?? untracked.txt"):
            with self.assertRaisesRegex(receipt.ReceiptError, "must be clean"):
                receipt.clean_commit(REPO)

    def test_archive_pair_verifies_receipt_and_artifact_bytes(self):
        with tempfile.TemporaryDirectory() as source_name, tempfile.TemporaryDirectory() as archive_name:
            source = Path(source_name)
            archive = Path(archive_name)
            receipt_path = source / "receipt.json"
            artifact_path = source / "artifact.json"
            receipt_path.write_bytes(b"receipt\n")
            artifact_path.write_bytes(b"artifact\n")
            archived = receipt.archive_pair(receipt_path, artifact_path, archive)
            self.assertEqual(receipt_path.read_bytes(), archived[0].read_bytes())
            self.assertEqual(artifact_path.read_bytes(), archived[1].read_bytes())


if __name__ == "__main__":
    unittest.main()
