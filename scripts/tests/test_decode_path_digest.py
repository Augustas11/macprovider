"""Tests for scripts/decode_path_digest.py (SPEC-048-R013 0.1.51)."""

import hashlib
import json
import shutil
import tempfile
import unittest
from unittest.mock import Mock, patch
from types import SimpleNamespace
from pathlib import Path

from scripts import decode_path_digest as tool

ROOT = Path(__file__).resolve().parents[2]


class DecodePathDigestTests(unittest.TestCase):
    def copy_package(self) -> Path:
        temp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, temp)
        files, _ = tool.load_manifest()
        for name in (tool.MANIFEST.name, tool.RESOLVED.name):
            shutil.copy(tool.PACKAGE / name, temp / name)
        for item in files:
            (temp / item).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy(tool.PACKAGE / item, temp / item)
        return temp

    def test_committed_constant_is_current(self):
        self.assertEqual(tool.main(["--check"]), 0)
        self.assertEqual(tool.GENERATED.read_text("utf-8"), tool.render(tool.compute()))

    def test_changed_decode_path_file_changes_the_digest(self):
        package = self.copy_package()
        digest = tool.compute(package)
        self.assertEqual(digest, tool.compute())
        files, _ = tool.load_manifest(package)
        with open(package / files[0], "a", encoding="utf-8") as handle:
            handle.write("\n// changed\n")
        self.assertNotEqual(tool.compute(package), digest)

    def test_missing_listed_file_fails(self):
        package = self.copy_package()
        files, _ = tool.load_manifest(package)
        (package / files[-1]).unlink()
        with self.assertRaisesRegex(tool.DecodePathError, "not a regular file"):
            tool.compute(package)

    def test_dependency_revision_is_part_of_the_digest(self):
        package = self.copy_package()
        digest = tool.compute(package)
        resolved = json.loads((package / tool.RESOLVED.name).read_text("utf-8"))
        for pin in resolved["pins"]:
            if pin["identity"] == "mlx-swift-lm":
                pin["state"]["revision"] = "0" * 40
        (package / tool.RESOLVED.name).write_text(json.dumps(resolved), "utf-8")
        self.assertNotEqual(tool.compute(package), digest)

    def test_manifest_is_closed_sorted_and_cannot_list_the_generated_file(self):
        package = self.copy_package()
        manifest = json.loads((package / tool.MANIFEST.name).read_text("utf-8"))
        for mutate, message in (
            (lambda m: m.update(extra=1), "exactly"),
            (lambda m: m["files"].reverse(), "sorted"),
            (lambda m: m["files"].insert(0, "../escape.swift"), "relative"),
            (lambda m: m.update(files=sorted(m["files"] + ["Sources/macprovider-cli/DecodePathIdentity.generated.swift"])),
             "own digest"),
        ):
            bad = json.loads(json.dumps(manifest))
            mutate(bad)
            (package / tool.MANIFEST.name).write_text(json.dumps(bad), "utf-8")
            with self.assertRaisesRegex(tool.DecodePathError, message):
                tool.compute(package)

    def test_algorithm_is_the_documented_line_format(self):
        files, deps = tool.load_manifest()
        revisions = tool.resolved_revisions()
        lines = [tool.DOMAIN]
        lines += [f"file {f} {hashlib.sha256((tool.PACKAGE / f).read_bytes()).hexdigest()}" for f in files]
        lines += [f"dependency {d} {revisions[d]}" for d in deps]
        self.assertEqual(tool.compute(), hashlib.sha256(("\n".join(lines) + "\n").encode()).hexdigest())

    def test_binary_marker_extraction(self):
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(b"\x00junk" + tool.MARKER_PREFIX.encode() + b"a" * 64 + b"\x00tail")
            handle.flush()
            self.assertEqual(tool.embedded_in_binary(Path(handle.name)), "a" * 64)
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(b"no marker here")
            handle.flush()
            self.assertIsNone(tool.embedded_in_binary(Path(handle.name)))

    def test_mixed_admission_reports_a_bound_mismatch_before_legacy(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "native-mtp-admission.json"
            path.write_text(json.dumps({"entries": [{"model_key": "m"}, {"decode_path_digest": "b" * 64}]}), "utf-8")
            self.assertEqual(tool.admission_status(path, "a" * 64), "mismatch")
            path.write_text(json.dumps({"entries": [{"model_key": "m"}, {"decode_path_digest": "a" * 64}]}), "utf-8")
            self.assertEqual(tool.admission_status(path, "a" * 64), "legacy")

    def head_release_input(self, declared):
        import subprocess
        head = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], capture_output=True, text=True,
                              check=True).stdout.strip()
        return {"provider_decode_path_digest": declared, "entry": {"source_commit": head}}

    def test_release_input_digest_is_verified_against_the_bound_source_commit(self):
        digest, version = tool.release_commit_identity(self.head_release_input(None)["entry"]["source_commit"])
        if digest is None:
            self.skipTest("HEAD does not carry a committed decode-path digest")
        self.assertEqual(tool.verify_release_input(self.head_release_input(digest)), version)
        with self.assertRaisesRegex(tool.DecodePathError, "is not the digest compiled"):
            tool.verify_release_input(self.head_release_input("f" * 64))
        self.assertIsNone(tool.verify_release_input({"entry": {"source_commit": "0" * 40}}))
        original = tool._git_show
        tool._git_show = lambda commit, path: None
        try:
            with self.assertRaisesRegex(tool.DecodePathError, "embeds no decode-path digest"):
                tool.verify_release_input(self.head_release_input(digest))
        finally:
            tool._git_show = original

    def test_publish_gate_waits_for_the_reader_cli_to_be_released(self):
        digest, version = tool.release_commit_identity(self.head_release_input(None)["entry"]["source_commit"])
        if digest is None:
            self.skipTest("HEAD does not carry a committed decode-path digest")
        with tempfile.TemporaryDirectory() as temp:
            release = Path(temp) / "release.json"
            sidecar = Path(temp) / "native-mtp-admission.json"
            release.write_text(json.dumps(self.head_release_input(digest)), "utf-8")
            sidecar.write_text(json.dumps({"entries": [{"decode_path_digest": digest}]}), "utf-8")
            head = self.head_release_input(None)["entry"]["source_commit"]
            original_tag = tool._tag_commit
            self.addCleanup(setattr, tool, "_tag_commit", original_tag)
            # Not yet a published release: no tag names the bound commit.
            tool._tag_commit = lambda v: None
            with self.assertRaisesRegex(tool.DecodePathError, "release tag"):
                tool.publish_gate(release, sidecar, version)
            tool._tag_commit = lambda v: "0" * 40
            with self.assertRaisesRegex(tool.DecodePathError, "release tag"):
                tool.publish_gate(release, sidecar, version)
            tool._tag_commit = lambda v: head
            self.assertEqual(tool.publish_gate(release, sidecar, version), "ok")
            major, minor, patch = (int(x) for x in version.split("."))
            with self.assertRaisesRegex(tool.DecodePathError, "R014 item 10"):
                tool.publish_gate(release, sidecar, f"{major}.{minor}.{patch - 1}" if patch else f"{major}.{minor - 1}.999")
            with self.assertRaisesRegex(tool.DecodePathError, "unknown"):
                tool.publish_gate(release, sidecar, None)
            sidecar.write_text(json.dumps({"entries": [{"model_key": "m"}]}), "utf-8")
            self.assertEqual(tool.publish_gate(release, sidecar, None), "ok")
            self.assertEqual(tool.main(["--publish-gate", str(release), str(sidecar)]), 0)

    def test_admission_status(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "native-mtp-admission.json"
            path.write_text(json.dumps({"entries": [{"model_key": "m"}]}), "utf-8")
            self.assertEqual(tool.admission_status(path, "a" * 64), "legacy")
            path.write_text(json.dumps({"entries": [{"decode_path_digest": "a" * 64}]}), "utf-8")
            self.assertEqual(tool.admission_status(path, "a" * 64), "match")
            self.assertEqual(tool.admission_status(path, "b" * 64), "mismatch")




class SignedPairPublishGateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.version = "1.8.999"
        self.source = "a" * 40
        self.digest = "d" * 64
        self.env = patch.dict(tool.os.environ, MACPROVIDER_OPS_ENTRYPOINT="1", MACPROVIDER_OPS_OWNER="test")
        self.env.start()
        self.addCleanup(self.env.stop)
        self.identity = patch.object(tool, "verify_release_input", return_value=self.version)
        self.identity.start()
        self.addCleanup(self.identity.stop)
        self.original_envelope = tool._verify_candidate_envelope
        self.envelope = patch.object(tool, "_verify_candidate_envelope")
        self.verify = self.envelope.start()
        self.addCleanup(self.envelope.stop)
        self.equivalence = patch.object(tool, "_verify_identity_only_decode")
        self.verify_decode = self.equivalence.start()
        self.addCleanup(self.equivalence.stop)
        self.bytes = self.root / "candidate"
        self.bytes.mkdir()
        self.archive = self.bytes / f"macprovider-cli-v{self.version}-darwin-arm64.tar.gz"
        self.archive.write_bytes(b"signed candidate archive fixture")
        self.write(self.bytes / "acceptance-candidate.json", {"fixture": True})
        (self.bytes / "acceptance-candidate.json.sig").write_bytes(b"signature fixture")
        self.code = {"binary_version": self.version, "binary_sha256": "b" * 64,
                     "team_id": "TEAM", "signing_identifier": "tech.malibu.provider",
                     "slices": [{"code_cdhash": "c" * 40}]}
        self.write(self.bytes / "pearl-release.json", {"provider_code_identity": self.code})
        (self.bytes / "checksums.txt").write_text("".join(
            f"{tool._file_digest(path)}  {path.name}\n" for path in (self.archive, self.bytes / "pearl-release.json")))
        self.old_row = {"model_key": "glm", "request_feature_profile": "native_mtp_greedy_text_v1",
                        "proposal_depth": 1, "max_native_active_rows": 1, "source_commit": "f" * 40,
                        "decode_path_digest": "e" * 64, "challenge_bank_sha256": "1" * 64,
                        "performance_evidence_sha256": "2" * 64,
                        "provider_revision": "f" * 40, "reproducible_build_sha256": "8" * 64,
                        "live_executable_cdhash": "8" * 40, "runtime_revision": "9" * 40,
                        "metallib_sha256": "7" * 64}
        self.row = dict(self.old_row, source_commit=self.source, decode_path_digest=self.digest,
                        provider_revision=self.source, reproducible_build_sha256=self.code["binary_sha256"],
                        live_executable_cdhash="c" * 40)
        self.prior_sidecar = self.root / "prior.json"
        self.sidecar = self.root / "sidecar.json"
        self.write(self.prior_sidecar, {"entries": [self.old_row]})
        self.write(self.sidecar, {"entries": [self.row]})
        def role(path):
            return {"version": self.version, "source_commit": self.source, "model_key": "glm", "model_hash": "3" * 64,
                    "request_feature_profile": "native_mtp_greedy_text_v1", "ordinary_context_tokens": 8192,
                    "feed_sha256": {"/v1/native-mtp-admission": tool._file_digest(path),
                                    "/v1/native-mtp-admission.sig": "4" * 64,
                                    "/v1/native-mtp-selftest-bank": "1" * 64,
                                    "/v1/native-mtp-selftest-bank.sig": "5" * 64,
                                    "/v1/continuous-batching-policy": "6" * 64,
                                    "/v1/continuous-batching-policy.sig": "7" * 64}}
        self.prior = dict(role(self.prior_sidecar), provenance="reviewed_published_signed_release")
        self.target = dict(role(self.sidecar), provenance="reviewed_signed_acceptance_candidate", candidate_run_id="123",
                           binary_sha256=self.code["binary_sha256"], cdhash="c" * 40, team_id="TEAM",
                           signing_identifier=self.code["signing_identifier"], decode_path_digest=self.digest,
                           local_tarball_path=str(self.archive), tarball_sha256=tool._file_digest(self.archive))
        for name, key in (("acceptance-candidate.json", "acceptance_manifest_sha256"),
                          ("acceptance-candidate.json.sig", "acceptance_signature_sha256"), ("checksums.txt", "checksums_sha256")):
            self.target[key] = tool._file_digest(self.bytes / name)
        self.plan = {"schema_version": "macprovider.signed_native_pair.v1", "transaction_id": "test-pair",
                     "prior": self.prior, "target": self.target}
        self.marker = {"step": "signed_byte_verification", "run_id": "123", "candidate_sha": self.source,
                       "bytes_dir": str(self.bytes), "binary_sha256": self.code["binary_sha256"],
                       "compatibility_set_id": f"Augustas11/macprovider:v{self.version}@{self.source}",
                       "checksums_sha256": self.target["checksums_sha256"]}
        self.run = {"id": 123, "event": "workflow_dispatch", "status": "completed", "conclusion": "success",
                    "path": ".github/workflows/acceptance-candidate.yml", "head_branch": "main",
                    "head_sha": "9" * 40, "repository": {"full_name": "Augustas11/macprovider"}, "run_attempt": 1}
        self.release = self.root / "release.json"
        self.write(self.release, {"provider_decode_path_digest": self.digest,
                   "entry": {"source_commit": self.source, "provider_revision": self.source,
                             "reproducible_build_sha256": self.target["binary_sha256"], "live_executable_cdhash": self.target["cdhash"]}})
        self.proof = tool.SignedPairPublishProof(self.root / "plan.json", self.root / "marker.json", self.root / "run.json", self.prior_sidecar)
        self.refresh()

    def write(self, path, value):
        path.write_text(json.dumps(value), encoding="utf-8")

    def refresh(self):
        self.write(self.proof.plan, self.plan)
        self.write(self.proof.signed_byte_verification, self.marker)
        self.write(self.proof.run, self.run)

    def gate(self):
        return tool.publish_gate(self.release, self.sidecar, "1.8.1", self.proof)

    def test_exact_signed_candidate_old_scope_does_not_need_final_tag_or_recommendation(self):
        with patch.object(tool, "_tag_commit", side_effect=AssertionError("premature final tag lookup")):
            self.assertEqual(self.gate(), "ok")
        self.verify.assert_called_once_with(self.bytes, self.version, self.source, self.run)
        self.verify_decode.assert_called_once_with(self.old_row, self.row)

    def test_signed_candidate_cannot_inherit_changed_decode_qualification(self):
        self.verify_decode.side_effect = tool.DecodePathError("unchanged decode behavior is not proven")
        with self.assertRaisesRegex(tool.DecodePathError, "unchanged decode behavior"):
            self.gate()

    def test_rejects_missing_ops_custody_failed_run_or_mismatched_signed_identity(self):
        with patch.dict(tool.os.environ, MACPROVIDER_OPS_ENTRYPOINT="0"):
            with self.assertRaisesRegex(tool.DecodePathError, "owning ops"):
                self.gate()
        mutations = [(self.run, "conclusion", "failure"), (self.run, "path", ".github/workflows/other.yml"),
                     (self.target, "candidate_run_id", "456"), (self.marker, "binary_sha256", "0" * 64),
                     (self.target, "acceptance_signature_sha256", "0" * 64),
                     (self.prior, "provenance", "local"), (self.target, "request_feature_profile", "native_mtp_sampled_text_v1")]
        for obj, key, value in mutations:
            with self.subTest(key=key):
                original = obj[key]
                obj[key] = value
                self.refresh()
                with self.assertRaises(tool.DecodePathError):
                    self.gate()
                obj[key] = original
        self.refresh()

    def test_rejects_widened_scope_or_changed_qualification_even_with_matching_plan_hash(self):
        for key, value in (("proposal_depth", 2), ("max_native_active_rows", 2),
                           ("request_feature_profile", "native_mtp_sampled_text_v1"), ("performance_evidence_sha256", "0" * 64)):
            with self.subTest(key=key):
                changed = dict(self.row, **{key: value})
                self.write(self.sidecar, {"entries": [changed]})
                self.target["feed_sha256"]["/v1/native-mtp-admission"] = tool._file_digest(self.sidecar)
                self.refresh()
                with self.assertRaisesRegex(tool.DecodePathError, "scope changed"):
                    self.gate()

    def test_candidate_exception_cannot_relabel_legacy_sidecar(self):
        self.write(self.sidecar, {"entries": [{"model_key": "glm"}]})
        with self.assertRaisesRegex(tool.DecodePathError, "requires decode-path-bound"):
            self.gate()

    def test_changed_archive_or_unverified_envelope_is_rejected(self):
        self.verify.side_effect = tool.DecodePathError("invalid envelope")
        with self.assertRaisesRegex(tool.DecodePathError, "invalid envelope"):
            self.gate()
        self.verify.side_effect = None
        self.archive.write_bytes(b"different archive")
        with self.assertRaisesRegex(tool.DecodePathError, "archive bytes changed"):
            self.gate()

    def test_envelope_verifier_binds_control_commit_separately_from_candidate(self):
        with patch.object(tool.subprocess, "run") as command:
            command.return_value.returncode = 0
            self.original_envelope(self.bytes, self.version, self.source, self.run)
            args = command.call_args.args[0]
            self.assertEqual(args[args.index("--control-commit") + 1], self.run["head_sha"])
            self.assertEqual(args[args.index("--candidate-commit") + 1], self.source)
            self.assertIn("--public-key", args)
            command.return_value.returncode = 1
            with self.assertRaisesRegex(tool.DecodePathError, "envelope verification failed"):
                self.original_envelope(self.bytes, self.version, self.source, self.run)


class IdentityOnlyDecodeProofTests(unittest.TestCase):
    def setUp(self):
        self.old = dict(source_commit="a" * 40, decode_path_digest="b" * 64,
                        runtime_revision="c" * 40, metallib_sha256="d" * 64,
                        request_feature_profile="native_mtp_greedy_text_v1")
        self.new = dict(self.old, source_commit="e" * 40, decode_path_digest="f" * 64)

    def test_complete_source_identities_are_recomputed_by_closed_verifier(self):
        verifier = SimpleNamespace(verify_source_equivalence=Mock())
        spec = SimpleNamespace(loader=Mock())
        with patch.object(tool.importlib.util, "spec_from_file_location", return_value=spec), \
             patch.object(tool.importlib.util, "module_from_spec", return_value=verifier):
            tool._verify_identity_only_decode(self.old, self.new)
        verifier.verify_source_equivalence.assert_called_once_with(
            tool.ROOT, self.old["source_commit"], self.new["source_commit"],
            self.old["decode_path_digest"], self.new["decode_path_digest"],
            request_feature_profile=self.new["request_feature_profile"])

    def test_closed_source_proof_failure_cannot_be_replaced_by_signed_identity(self):
        verifier = SimpleNamespace(verify_source_equivalence=Mock(side_effect=ValueError("production verifier changed")))
        spec = SimpleNamespace(loader=Mock())
        with patch.object(tool.importlib.util, "spec_from_file_location", return_value=spec), \
             patch.object(tool.importlib.util, "module_from_spec", return_value=verifier):
            with self.assertRaisesRegex(tool.DecodePathError, "unchanged decode behavior is not proven"):
                tool._verify_identity_only_decode(self.old, self.new)

    def test_missing_identity_and_unproven_runtime_or_metal_changes_reject(self):
        for key in ("source_commit", "decode_path_digest", "runtime_revision", "metallib_sha256"):
            with self.subTest(missing=key):
                old = dict(self.old); del old[key]
                with self.assertRaisesRegex(tool.DecodePathError, "complete prior/current"):
                    tool._verify_identity_only_decode(old, self.new)
        for key, value in (("runtime_revision", "1" * 40), ("metallib_sha256", "2" * 64)):
            with self.subTest(changed=key):
                with self.assertRaisesRegex(tool.DecodePathError, "runtime/Metal changes"):
                    tool._verify_identity_only_decode(self.old, dict(self.new, **{key: value}))


if __name__ == "__main__":
    unittest.main()
