#!/usr/bin/env python3

import contextlib
import importlib.util
import io
import json
import shutil
import subprocess
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
PROPOSAL = ARCHIVE / "openrouter-rate-card-proposal-2026-08-10T10-06-14Z-d60d0d8d828bbd5c.json"
POLICY = REPO / "scripts" / "openrouter_pricing_policy.json"
# The archived 2026-08-10 proposal was computed against the rate-card as it stood
# then. The live catalog rate-card (phase3-binary/catalog/autotune/rate-card.json)
# is a renewed feed whose generated_at is re-stamped for freshness, so binding the
# archived proposal's exact replay to the moving catalog file breaks provenance on
# every renewal. Replay against an immutable, contemporaneous snapshot instead.
RATE_CARD = ARCHIVE / "rate-card-2026-08-10.json"
# The engine_commit bound in synthetic test receipts must be an ancestor of the
# validator's HEAD whose committed engine bytes match the working tree. Derive it
# from HEAD so the suite survives squash-merges (which discard branch commits) --
# a hardcoded branch SHA breaks the moment its PR is squashed onto main.
RUN_COMMIT = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=REPO, capture_output=True, text=True, check=True
).stdout.strip()
REAL_COPYFILE = shutil.copyfile
REAL_LINK = receipt.os.link
REAL_RENAME = receipt.os.rename


class ReceiptTests(unittest.TestCase):
    def base(self, receipt_type, artifact):
        return {
            "schema_version": 2,
            "receipt_type": receipt_type,
            "started_at": "2026-08-10T10:00:00Z",
            "finished_at": "2026-08-10T10:00:01Z",
            "engine_commit": RUN_COMMIT,
            "execution": {"worktree_clean": True},
            "command": [],
            "exit_status": 0,
            "stdout": str(artifact.name) if artifact is not None else "",
            "stderr": "",
            "output_directory_listing": [receipt.inventory(artifact)] if artifact is not None and artifact.exists() else [],
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
            value["command"] = receipt.expected_compute_command(value["inputs"])
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
            value["command"] = receipt.expected_fetch_command(value["source"]["policy_path"])
            path = self.write(directory, value)
            receipt.validate_receipt(path, REPO)

    def test_tampered_receipt_digest_fails(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            copied = directory / PROPOSAL.name
            shutil.copyfile(PROPOSAL, copied)
            value = self.base("openrouter-pricing-compute-success", copied)
            value["inputs"] = {}
            value["command"] = ["invalid"]
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

    def valid_compute_receipt(self, directory):
        copied = directory / PROPOSAL.name
        shutil.copyfile(PROPOSAL, copied)
        snapshot = json.loads(SNAPSHOT.read_text(encoding="utf-8"))
        value = self.base(receipt.COMPUTE_SUCCESS, copied)
        value["inputs"] = {
            "snapshot_path": SNAPSHOT.relative_to(REPO).as_posix(),
            "snapshot_content_digest": snapshot["content_digest"],
            "snapshot_file_sha256": receipt.sha256_file(SNAPSHOT),
            "policy_path": POLICY.relative_to(REPO).as_posix(),
            "policy_file_sha256": receipt.sha256_file(POLICY),
            "rate_card_path": RATE_CARD.relative_to(REPO).as_posix(),
            "rate_card_file_sha256": receipt.sha256_file(RATE_CARD),
        }
        value["command"] = receipt.expected_compute_command(value["inputs"])
        return value

    def test_forged_commit_and_command_are_rejected(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            value = self.valid_compute_receipt(directory)
            value["engine_commit"] = "a" * 40
            path = self.write(directory, value)
            with self.assertRaisesRegex(receipt.ReceiptError, "cat-file"):
                receipt.validate_receipt(path, REPO)

            value = self.valid_compute_receipt(directory)
            value["command"] = ["not-the-engine", "--forged"]
            path = self.write(directory, value, "forged-command.json")
            with self.assertRaisesRegex(receipt.ReceiptError, "command does not match"):
                receipt.validate_receipt(path, REPO)

    def test_archive_pair_rolls_back_when_second_copy_fails(self):
        with tempfile.TemporaryDirectory() as source_name, tempfile.TemporaryDirectory() as archive_name:
            source = Path(source_name)
            archive = Path(archive_name)
            first = source / "receipt.json"
            second = source / "artifact.json"
            first.write_bytes(b"receipt\n")
            second.write_bytes(b"artifact\n")
            calls = 0

            def fail_second_copy(src, dst):
                nonlocal calls
                calls += 1
                if calls == 2:
                    raise OSError("forced second-copy failure")
                return REAL_COPYFILE(src, dst)

            with mock.patch.object(receipt.shutil, "copyfile", side_effect=fail_second_copy):
                with self.assertRaisesRegex(OSError, "forced second-copy"):
                    receipt.archive_pair(first, second, archive)
            self.assertEqual([], [path for path in archive.iterdir()])

    def test_archive_pair_rolls_back_after_post_copy_verification_failure(self):
        with tempfile.TemporaryDirectory() as source_name, tempfile.TemporaryDirectory() as archive_name:
            source = Path(source_name)
            archive = Path(archive_name)
            first = source / "receipt.json"
            second = source / "artifact.json"
            first.write_bytes(b"receipt\n")
            second.write_bytes(b"artifact\n")
            real_hash = receipt.sha256_file

            def mismatch_archived_target(path):
                value = real_hash(path)
                if path.parent == archive and not path.name.endswith(".tmp"):
                    return "sha256:" + "0" * 64
                return value

            with mock.patch.object(receipt, "sha256_file", side_effect=mismatch_archived_target):
                with self.assertRaisesRegex(receipt.ReceiptError, "archived evidence"):
                    receipt.archive_pair(first, second, archive)
            self.assertEqual([], [path for path in archive.iterdir()])

    def test_archive_pair_does_not_overwrite_concurrent_target(self):
        with tempfile.TemporaryDirectory() as source_name, tempfile.TemporaryDirectory() as archive_name:
            source = Path(source_name)
            archive = Path(archive_name)
            first = source / "receipt.json"
            second = source / "artifact.json"
            first.write_bytes(b"receipt\n")
            second.write_bytes(b"artifact\n")
            calls = 0

            def race_on_second_link(src, dst):
                nonlocal calls
                calls += 1
                if calls == 2:
                    Path(dst).write_bytes(b"concurrent\n")
                return REAL_LINK(src, dst)

            with mock.patch.object(receipt.os, "link", side_effect=race_on_second_link):
                with self.assertRaisesRegex(receipt.ReceiptError, "concurrently created"):
                    receipt.archive_pair(first, second, archive)
            self.assertFalse((archive / first.name).exists())
            self.assertEqual(b"concurrent\n", (archive / second.name).read_bytes())

    def test_validate_inventory_rejects_artifact_outside_receipt_directory(self):
        with tempfile.TemporaryDirectory() as name:
            root = Path(name)
            archive = root / "archive"
            archive.mkdir()
            outside = root / "snapshot.json"
            outside.write_bytes(b"{}\n")
            value = {
                "output_directory_listing": [
                    {
                        "filename": f"../{outside.name}",
                        "bytes": outside.stat().st_size,
                        "sha256": receipt.sha256_file(outside),
                    }
                ]
            }
            with self.assertRaisesRegex(receipt.ReceiptError, "basename"):
                receipt.validate_inventory(value, archive, True)

    def test_validate_inventory_rejects_symlink_artifact(self):
        with tempfile.TemporaryDirectory() as name:
            archive = Path(name)
            target = archive / "target.json"
            target.write_bytes(b"{}\n")
            artifact = archive / "snapshot.json"
            artifact.symlink_to(target.name)
            value = {
                "output_directory_listing": [
                    {
                        "filename": artifact.name,
                        "bytes": target.stat().st_size,
                        "sha256": receipt.sha256_file(target),
                    }
                ]
            }
            with self.assertRaisesRegex(receipt.ReceiptError, "regular file"):
                receipt.validate_inventory(value, archive, True)

    def test_failure_receipt_requires_empty_stage_output_directory(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            (directory / "unexpected-artifact.json").write_bytes(b"{}\n")
            with self.assertRaisesRegex(receipt.ReceiptError, "emitted unexpected output"):
                receipt.require_empty_failure_output(directory)

    def test_archive_pair_rollback_preserves_concurrent_replacement(self):
        with tempfile.TemporaryDirectory() as source_name, tempfile.TemporaryDirectory() as archive_name:
            source = Path(source_name)
            archive = Path(archive_name)
            first = source / "receipt.json"
            second = source / "artifact.json"
            first.write_bytes(b"receipt\n")
            second.write_bytes(b"artifact\n")
            first_target = archive / first.name
            second_target = archive / second.name
            calls = 0

            def replace_first_then_collide(src, dst, **kwargs):
                nonlocal calls
                calls += 1
                if calls == 1:
                    return REAL_LINK(src, dst, **kwargs)
                if calls == 2:
                    first_target.unlink()
                    first_target.write_bytes(b"concurrent replacement\n")
                    second_target.write_bytes(b"concurrent blocker\n")
                return REAL_LINK(src, dst, **kwargs)

            with mock.patch.object(receipt.os, "link", side_effect=replace_first_then_collide):
                with self.assertRaisesRegex(receipt.ReceiptError, "concurrently created"):
                    receipt.archive_pair(first, second, archive)
            self.assertEqual(b"concurrent replacement\n", first_target.read_bytes())
            self.assertEqual(b"concurrent blocker\n", second_target.read_bytes())

    def test_archive_pair_rollback_preserves_replacement_after_identity_check(self):
        with tempfile.TemporaryDirectory() as source_name, tempfile.TemporaryDirectory() as archive_name:
            source = Path(source_name)
            archive = Path(archive_name)
            first = source / "receipt.json"
            second = source / "artifact.json"
            first.write_bytes(b"receipt\n")
            second.write_bytes(b"artifact\n")
            first_target = archive / first.name
            second_target = archive / second.name
            link_calls = 0
            replacement_inserted = False

            def collide_on_second_link(src, dst, **kwargs):
                nonlocal link_calls
                link_calls += 1
                if link_calls == 2:
                    second_target.write_bytes(b"concurrent blocker\n")
                return REAL_LINK(src, dst, **kwargs)

            def replace_before_rollback_rename(src, dst):
                nonlocal replacement_inserted
                if Path(src) == first_target and not replacement_inserted:
                    replacement_inserted = True
                    first_target.unlink()
                    first_target.write_bytes(b"replacement during rollback\n")
                return REAL_RENAME(src, dst)

            with mock.patch.object(receipt.os, "link", side_effect=collide_on_second_link), mock.patch.object(
                receipt.os, "rename", side_effect=replace_before_rollback_rename
            ):
                with self.assertRaisesRegex(receipt.ReceiptError, "concurrently created"):
                    receipt.archive_pair(first, second, archive)
            self.assertTrue(replacement_inserted)
            self.assertEqual(b"replacement during rollback\n", first_target.read_bytes())
            self.assertEqual(b"concurrent blocker\n", second_target.read_bytes())

    def test_schema_v2_fetch_and_compute_failure_receipts_validate(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            fetch = self.base(receipt.FETCH_FAILURE, None)
            fetch["exit_status"] = 2
            fetch["output_directory_listing"] = []
            fetch["source"] = {
                "rankings_url": receipt.engine.RANKINGS_URL,
                "openrouter_api_key_configured": True,
                "policy_path": POLICY.relative_to(REPO).as_posix(),
                "policy_file_sha256": receipt.sha256_file(POLICY),
            }
            fetch["command"] = receipt.expected_fetch_command(fetch["source"]["policy_path"])
            receipt.validate_receipt(self.write(directory, fetch, "fetch-failure.json"), REPO)

            compute = self.valid_compute_receipt(directory)
            compute["receipt_type"] = receipt.COMPUTE_FAILURE
            compute["exit_status"] = 2
            compute["output_directory_listing"] = []
            receipt.validate_receipt(self.write(directory, compute, "compute-failure.json"), REPO)

    def test_run_archives_redacted_schema_v2_fetch_failure_receipt(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            archive = directory / "archive"
            key_file = directory / "key.txt"
            key_file.write_text("sk-or-v1-" + "a" * 64, encoding="utf-8")
            args = receipt.argparse.Namespace(
                repo=str(REPO), archive_dir=str(archive),
                policy=POLICY.relative_to(REPO).as_posix(),
                rate_card=RATE_CARD.relative_to(REPO).as_posix(),
                api_key_file=str(key_file), top_n=50, demand_window_days=30,
                retries=3, timeout_seconds=20.0, generation_timeout_seconds=900.0,
            )
            failed = receipt.subprocess.CompletedProcess(
                args=[], returncode=2, stdout="", stderr="Authorization: Bearer sk-or-v1-secret",
            )
            now = receipt.datetime(2026, 8, 10, 10, 0, 0, tzinfo=receipt.timezone.utc)
            with mock.patch.object(receipt, "clean_commit", return_value=RUN_COMMIT), mock.patch.object(
                receipt, "run_child", return_value=(now, now, failed)
            ):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(receipt.ReceiptError, "archived redacted failure receipt"):
                        receipt.command_run(args)
            receipts = list(archive.glob("openrouter-pricing-fetch-failure-*.json"))
            self.assertEqual(1, len(receipts))
            self.assertNotIn("sk-or-", receipts[0].read_text(encoding="utf-8").lower())
            receipt.validate_receipt(receipts[0], REPO)

    def test_run_archives_schema_v2_compute_failure_receipt(self):
        with tempfile.TemporaryDirectory() as name:
            directory = Path(name)
            failure_archive = directory / "failure-archive"
            failure_archive.mkdir()
            key_file = directory / "key.txt"
            key_file.write_text("sk-or-v1-" + "a" * 64, encoding="utf-8")
            args = receipt.argparse.Namespace(
                repo=str(REPO), archive_dir=ARCHIVE.relative_to(REPO).as_posix(),
                policy=POLICY.relative_to(REPO).as_posix(),
                rate_card=RATE_CARD.relative_to(REPO).as_posix(),
                api_key_file=str(key_file), top_n=50, demand_window_days=30,
                retries=3, timeout_seconds=20.0, generation_timeout_seconds=900.0,
            )
            now = receipt.datetime(2026, 8, 10, 10, 0, 0, tzinfo=receipt.timezone.utc)
            calls = 0

            def child_result(repo, arguments, api_key, temporary):
                nonlocal calls
                calls += 1
                if calls == 1:
                    output = Path(arguments[arguments.index("--output-dir") + 1])
                    copied = output / SNAPSHOT.name
                    REAL_COPYFILE(SNAPSHOT, copied)
                    return now, now, receipt.subprocess.CompletedProcess([], 0, str(copied), "")
                return now, now, receipt.subprocess.CompletedProcess([], 2, "", "forced compute failure")

            def archive_failure(path, archive):
                target = failure_archive / path.name
                REAL_COPYFILE(path, target)
                return target

            with mock.patch.object(receipt, "clean_commit", return_value=RUN_COMMIT), mock.patch.object(
                receipt, "run_child", side_effect=child_result
            ), mock.patch.object(
                receipt, "archive_pair", return_value=(ARCHIVE / "synthetic-fetch-receipt.json", SNAPSHOT)
            ), mock.patch.object(receipt, "archive_receipt", side_effect=archive_failure):
                with contextlib.redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(receipt.ReceiptError, "archived redacted failure receipt"):
                        receipt.command_run(args)
            receipts = list(failure_archive.glob("openrouter-pricing-compute-failure-*.json"))
            self.assertEqual(1, len(receipts))
            receipt.validate_receipt(receipts[0], REPO)


if __name__ == "__main__":
    unittest.main()
