from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "scripts/ops/lib/studio-lab-window-manifest.py"
LAB_SCRIPT = ROOT / "scripts/lab/2080-native-rows/run-window-diagnostic.sh"
SPEC = importlib.util.spec_from_file_location("studio_lab_window_manifest", HELPER)
assert SPEC and SPEC.loader
jobs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(jobs)


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(value, sort_keys=True))
    path.chmod(0o600)


class Fixture:
    def __init__(self, root: Path):
        self.root = root
        self.source = root / "source"
        self.stage = root / "stage"
        self.source.mkdir(mode=0o700)
        self.stage.mkdir(mode=0o700)
        subprocess.run(["git", "init", "-q", str(self.source)], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "user.name", "Test"], check=True)
        subprocess.run(["git", "-C", str(self.source), "config", "user.email", "test.invalid"], check=True)
        for relative in (
            "phase3-binary/source.txt",
            "scripts/lab/cb-studio/glm53-bench/source.txt",
        ):
            path = self.source / relative
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text(relative + "\n")
        subprocess.run(["git", "-C", str(self.source), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.source), "commit", "-qm", "fixture"], check=True)
        self.head = subprocess.run(
            ["git", "-C", str(self.source), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()

        self.calls = root / "calls.jsonl"
        cli_target = self.source / ".lab-window/bin/macprovider-cli"
        bench_target = self.source / ".lab-window/bin/GLMBench"
        fake = f"""#!/bin/sh
printf '%s\\t' "$@" >> {str(self.calls)!r}
printf '\\n' >> {str(self.calls)!r}
out=
policy=
validate=false
while [ "$#" -gt 0 ]; do
  [ "$1" = --validate-only ] && validate=true
  if [ "$1" = --out ]; then shift; out="$1"; fi
  if [ "$1" = --policy ]; then shift; policy="$1"; fi
  shift
done
if [ -n "$out" ] && [ "$validate" = false ]; then
  mkdir -p "$(dirname "$out")"
  printf '{{"ok":true}}\\n' >> "$out"
fi
if [ "$validate" = true ]; then
  policy_sha="$(/usr/bin/shasum -a 256 "$policy" | /usr/bin/awk '{{print $1}}')"
  printf '{{"validate_only":"pass","target_sha256":"__TARGET__","mtp_sha256":"__TARGET__","tokenizer_sha256":"__TOKENIZER__","policy_sha256":"%s","cells":["s1-p1536-o128","s1-p1536-o512","s1-p4096-o128","s1-p4096-o512","s2-p1536-o128","s2-p1536-o512","s2-p4096-o128","s2-p4096-o512","s3-p1536-o128","s3-p1536-o512","s3-p4096-o128","s3-p4096-o512","s4-p1536-o128","s4-p1536-o512","s4-p4096-o128","s4-p4096-o512"],"sustained_cell_id":"s4-p1536-o512","existing_records":false}}\\n' "$policy_sha"
fi
"""
        for path in (cli_target, bench_target):
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            path.write_text(fake)
            path.chmod(0o700)

        self.paths = {
            name: self.source / relative for name, relative in jobs.ARTIFACT_RELATIVES.items()
        }
        for name, path in self.paths.items():
            path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            if name == "diagnostic_cli":
                path.symlink_to(cli_target)
            elif name == "glmbench":
                path.symlink_to(bench_target)
            else:
                path.write_bytes((name + "\n").encode())
                path.chmod(0o600)
        (self.source / ".lab-window").chmod(0o700)
        tokenizer = self.source / ".lab-window/fixture/target/tokenizer.json"
        tokenizer.write_bytes(b"tokenizer\n")
        tokenizer.chmod(0o600)
        weights = tokenizer.parent / "model-00001-of-00001.safetensors"
        weights.write_bytes(b"fixture weights\n")
        weights.chmod(0o600)
        target_digest, _ = jobs.snapshot_identity(tokenizer.parent)
        for path in (cli_target, bench_target):
            path.write_text(path.read_text().replace("__TARGET__", target_digest).replace("__TOKENIZER__", sha(tokenizer)))
            path.chmod(0o700)
        projection = {
            "schema_version": "macprovider.native-mtp-artifact-projection.v1",
            "artifacts": {
                "target": {"sha256": target_digest},
                "mtp": {"sha256": target_digest},
                "tokenizer": {"sha256": sha(tokenizer)},
                "manifest": {"sha256": sha(self.paths["fixture_config"])},
            },
        }
        self.projection = projection
        write_json(self.source / jobs.PROJECTION_RELATIVE, projection)
        subprocess.run(["git", "-C", str(self.source), "add", str(jobs.PROJECTION_RELATIVE)], check=True)
        subprocess.run(["git", "-C", str(self.source), "commit", "-qm", "projection"], check=True)
        self.head = subprocess.run(
            ["git", "-C", str(self.source), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()

        self.staged_helper = self.stage / "manifest.py"
        self.staged_script = self.stage / "run-window-diagnostic.sh"
        shutil.copyfile(HELPER, self.staged_helper)
        shutil.copyfile(LAB_SCRIPT, self.staged_script)
        self.staged_helper.chmod(0o600)
        self.staged_script.chmod(0o700)
        self._write_reuse()
        self._write_policy()

    def _write_reuse(self) -> None:
        artifacts = {
            name: {"path": str(path), "sha256": sha(path.resolve())}
            for name, path in self.paths.items()
        }
        manifest = {
            "schema_version": jobs.SCHEMA,
            "nonce": "archived-window",
            "lab_git_head": self.head,
            "artifacts": artifacts,
        }
        reuse = self.source / jobs.REUSE_RELATIVE
        write_json(reuse / "manifest.json", manifest)
        write_json(reuse / "completed.json", {
            "manifest_sha256": sha(reuse / "manifest.json"),
            "lab_exit_code": 0,
            "nonce": manifest["nonce"],
            "lab_git_head": self.head,
        })
        expected = {
            "step-04-serial-token-oracle": "pass",
            "step-05-cache-state-boundary": "pass",
            "step-06-streaming-stop": "pass",
            "step-07-08-mixed-multirow-capacity": "pass",
            "step-09-cancellation": "pass",
            "step-10-warm-swap": "pass",
            "step-12-native-selftest": "partial",
        }
        write_json(reuse / "journey.json", {
            "schema": "macprovider.native-mtp-journey-hardware-result.v1",
            "model_id": "zai-org/glm-5.3-flash",
            "qualified_slots": 4,
            "lab_max_native_active_rows": 4,
            "signed_max_native_active_rows": 1,
            "qualification": False,
            "target_sha256": self.projection["artifacts"]["target"]["sha256"],
            "mtp_sha256": self.projection["artifacts"]["mtp"]["sha256"],
            "tokenizer_sha256": self.projection["artifacts"]["tokenizer"]["sha256"],
            "mtp_manifest_sha256": self.projection["artifacts"]["manifest"]["sha256"],
            "steps": [
                {"step_id": name, "status": status, "checks": {"fixture": True}}
                for name, status in expected.items()
            ],
        })

    def _write_policy(self) -> None:
        policy = {
            "schema": "macprovider.native-mtp-r015-policy.v1",
            "slots": [1, 2, 3, 4],
            "prompt_tokens": [1536, 4096],
            "max_tokens": [128, 512],
            "gated_cells": [],
            "qualified_slots": 4,
            "max_native_active_rows": 1,
            "laboratory_max_native_active_rows": 4,
            "maximum_prompt_tokens": 4096,
            "sustained_seconds": 1800,
            "sustained_cell_id": "s4-p1536-o512",
            "warmup_runs": 1,
            "blocks": 10,
            "quantization": "4bit",
            "cache_mode": "paged_kv_mixed",
            "proposal_depth": 1,
            "run_order": "seeded_random_counterbalanced",
            "prompt_corpus": "deterministic_synthetic_unique_v2",
            "exclusion_rules": "none",
            "confidence_method": "paired_block_bootstrap_holm_v1",
            "provider_commit": self.head,
            "target_sha256": self.projection["artifacts"]["target"]["sha256"],
            "mtp_sha256": self.projection["artifacts"]["mtp"]["sha256"],
            "tokenizer_sha256": self.projection["artifacts"]["tokenizer"]["sha256"],
        }
        write_json(self.source / jobs.POLICY_RELATIVE, policy)

    def snapshot(self, kind: str) -> dict:
        args = argparse.Namespace(
            source_dir=str(self.source), git_head=self.head,
            provider_label="fixture.provider", job_kind=kind,
            lab_script_sha256=sha(self.staged_script),
            job_helper_sha256=sha(self.staged_helper),
        )
        return jobs.source_snapshot(args)

    def manifest(self, kind: str) -> Path:
        snapshot = self.snapshot(kind)
        value = {
            "schema_version": jobs.SCHEMA,
            "nonce": f"{kind}-nonce",
            "lab_source_dir": str(self.source),
            "lab_script_path": str(self.staged_script),
            "job_helper_path": str(self.staged_helper),
            "artifacts": snapshot["artifacts"],
            "job": snapshot["job"],
        }
        path = self.stage / f"{kind}.json"
        write_json(path, value)
        return path

    def recorded_calls(self) -> list[list[str]]:
        if not self.calls.exists():
            return []
        return [line.rstrip("\t").split("\t") for line in self.calls.read_text().splitlines()]


class StudioLabJobsTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(dir=Path.home())
        self.fixture = Fixture(Path(self.temp.name).resolve())

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_legacy_snapshot_is_unchanged_and_read_only(self):
        before = set((self.fixture.source / ".lab-window").iterdir())
        snapshot = self.fixture.snapshot("diagnostic-legacy")
        self.assertNotIn("job", snapshot)
        self.assertEqual(self.fixture.recorded_calls(), [])
        self.assertEqual(set((self.fixture.source / ".lab-window").iterdir()), before)

    def test_profiler_job_binds_reuse_and_lexical_symlink_paths(self):
        manifest = self.fixture.manifest("profiler-only")
        loaded, job = jobs.load_job_manifest(str(manifest))
        jobs.validate_current_job_inputs(loaded, job)
        self.assertEqual(
            job["immutable_inputs"]["reuse"]["archive_binding"],
            "protected_import_not_historically_receipt_bound",
        )
        journey = self.fixture.source / jobs.REUSE_RELATIVE / "journey.json"
        journey.write_bytes(journey.read_bytes() + b"\n")
        with self.assertRaisesRegex(jobs.Refusal, "reuse inputs drifted"):
            jobs.validate_current_job_inputs(loaded, job)

    def test_profiler_snapshot_does_not_hash_fixture_weights(self):
        with mock.patch.object(jobs, "snapshot_identity", side_effect=AssertionError("heavy hash")):
            snapshot = self.fixture.snapshot("profiler-only")
        self.assertEqual(snapshot["job"]["kind"], "profiler-only")

    def test_snapshot_identity_matches_swift_manifest_golden(self):
        target = self.fixture.root / "golden"
        (target / "nested").mkdir(mode=0o700, parents=True)
        (target / "a.txt").write_bytes(b"alpha")
        (target / "nested/b.bin").write_bytes(b"\0\1")
        digest, stamps = jobs.snapshot_identity(target)
        self.assertEqual(digest, "d1fc90283d6190f9b81157b9f685a90ec488897dff9f115469117287f65bd15a")
        self.assertEqual([item["path"] for item in stamps], ["a.txt", "nested/b.bin"])

    def test_profiler_changed_weight_refuses_during_preflight(self):
        manifest = self.fixture.manifest("profiler-only")
        weight = self.fixture.source / ".lab-window/fixture/target/model-00001-of-00001.safetensors"
        weight.write_bytes(b"changed weights with config and index untouched\n")
        with self.assertRaisesRegex(jobs.Refusal, "fixture identity differs"):
            jobs.validate_job(argparse.Namespace(manifest=str(manifest)))

    def test_post_preflight_fixture_addition_refuses_before_load(self):
        manifest = self.fixture.manifest("profiler-only")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        added = self.fixture.source / ".lab-window/fixture/target/added.safetensors"
        added.write_bytes(b"late file\n")
        with self.assertRaisesRegex(jobs.Refusal, "changed after job preflight"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def test_post_preflight_fixture_rewrite_refuses_before_load(self):
        manifest = self.fixture.manifest("profiler-only")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        weight = self.fixture.source / ".lab-window/fixture/target/model-00001-of-00001.safetensors"
        weight.write_bytes(b"same length maybe" + b"!" * 2)
        with self.assertRaisesRegex(jobs.Refusal, "changed after job preflight"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def test_post_preflight_fixture_removal_refuses_before_load(self):
        manifest = self.fixture.manifest("profiler-only")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        (self.fixture.source / ".lab-window/fixture/target/model-00001-of-00001.safetensors").unlink()
        with self.assertRaisesRegex(jobs.Refusal, "changed after job preflight"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def test_profiler_rebuild_after_wall_refuses_before_census(self):
        manifest = self.fixture.manifest("profiler-only")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        original = jobs.run_checked
        calls = 0

        def rebuild_after_wall(argv, output, *, timeout=3600):
            nonlocal calls
            original(argv, output, timeout=timeout)
            calls += 1
            if calls == 1:
                self.fixture.paths["glmbench"].resolve().write_bytes(b"rebuilt GLMBench\n")

        with mock.patch.object(jobs, "run_checked", side_effect=rebuild_after_wall):
            with self.assertRaisesRegex(jobs.Refusal, "artifact drifted: glmbench"):
                jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(len(self.fixture.recorded_calls()), 1)
        self.assertFalse((self.fixture.source / ".lab-window/result-profiler-only-nonce/result.json").exists())

    def test_private_profiler_snapshot_tampering_refuses_before_load(self):
        manifest = self.fixture.manifest("profiler-only")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        loaded, job = jobs.load_job_manifest(str(manifest))
        jobs.private_artifact_paths(loaded, job)["glmbench"].write_bytes(b"tampered private bench\n")
        with self.assertRaisesRegex(jobs.Refusal, "private job artifact drifted"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def test_qualification_policy_swap_between_cells_refuses(self):
        shutil.rmtree(self.fixture.source / jobs.REUSE_RELATIVE)
        manifest = self.fixture.manifest("qualification")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        original = jobs.run_checked
        matrix_calls = 0

        def swap_policy(argv, output, *, timeout=3600):
            nonlocal matrix_calls
            original(argv, output, timeout=timeout)
            if "--phase" in argv and argv[argv.index("--phase") + 1] == "matrix":
                matrix_calls += 1
                if matrix_calls == 1:
                    policy = self.fixture.source / jobs.POLICY_RELATIVE
                    policy.write_bytes(policy.read_bytes() + b"\n")

        with mock.patch.object(jobs, "run_checked", side_effect=swap_policy):
            with self.assertRaisesRegex(jobs.Refusal, "policy identity drifted"):
                jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(matrix_calls, 1)
        self.assertFalse((self.fixture.source / ".lab-window/result-qualification-nonce/result.json").exists())

    def test_qualification_cli_swap_between_cells_refuses(self):
        shutil.rmtree(self.fixture.source / jobs.REUSE_RELATIVE)
        manifest = self.fixture.manifest("qualification")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        original = jobs.run_checked
        matrix_calls = 0

        def swap_cli(argv, output, *, timeout=3600):
            nonlocal matrix_calls
            original(argv, output, timeout=timeout)
            if "--phase" in argv and argv[argv.index("--phase") + 1] == "matrix":
                matrix_calls += 1
                if matrix_calls == 1:
                    self.fixture.paths["diagnostic_cli"].resolve().write_bytes(b"replacement CLI\n")

        with mock.patch.object(jobs, "run_checked", side_effect=swap_cli):
            with self.assertRaisesRegex(jobs.Refusal, "artifact drifted: diagnostic_cli"):
                jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(matrix_calls, 1)
        self.assertFalse((self.fixture.source / ".lab-window/result-qualification-nonce/result.json").exists())

    def test_final_input_mutation_after_last_child_writes_no_receipt(self):
        manifest = self.fixture.manifest("profiler-only")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        original = jobs.run_checked
        calls = 0

        def mutate_after_last(argv, output, *, timeout=3600):
            nonlocal calls
            original(argv, output, timeout=timeout)
            calls += 1
            if calls == 2:
                metal = self.fixture.paths["glmbench_metallib"]
                metal.write_bytes(b"changed after census\n")

        with mock.patch.object(jobs, "run_checked", side_effect=mutate_after_last):
            with self.assertRaisesRegex(jobs.Refusal, "artifact drifted: glmbench_metallib"):
                jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(len(self.fixture.recorded_calls()), 2)
        self.assertFalse((self.fixture.source / ".lab-window/result-profiler-only-nonce/result.json").exists())

    def test_job_schema_refuses_identity_valid_unknown_input(self):
        job = self.fixture.snapshot("profiler-only")["job"]
        job["immutable_inputs"]["operator_argument"] = "not-allowed"
        job["identity_sha256"] = jobs.canonical_digest({
            "kind": job["kind"], "immutable_inputs": job["immutable_inputs"],
        })
        with self.assertRaisesRegex(jobs.Refusal, "input schema"):
            jobs.validate_job_object(job)

    def test_qualification_rejects_non_exact_policy_and_stale_provider_source(self):
        policy_path = self.fixture.source / jobs.POLICY_RELATIVE
        policy = json.loads(policy_path.read_text())
        policy["blocks"] = 9
        write_json(policy_path, policy)
        with self.assertRaisesRegex(jobs.Refusal, "approved bound-four"):
            self.fixture.snapshot("qualification")
        policy["blocks"] = 10
        policy["warmup_runs"] = True
        write_json(policy_path, policy)
        with self.assertRaisesRegex(jobs.Refusal, "must be an integer"):
            self.fixture.snapshot("qualification")
        policy["warmup_runs"] = 1
        policy["blocks"] = 10
        policy["provider_commit"] = "f" * 40
        write_json(policy_path, policy)
        with self.assertRaises((jobs.Refusal, subprocess.SubprocessError)):
            self.fixture.snapshot("qualification")

    def test_profiler_run_has_fixed_wall_then_census_argv(self):
        manifest = self.fixture.manifest("profiler-only")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        result = jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        calls = self.fixture.recorded_calls()
        self.assertEqual(len(calls), 2)
        self.assertEqual(calls[0][-4:], ["--mtp-multirow-measurement-mode", "wall-only", "--mtp-multirow-reps", "5"])
        self.assertEqual(calls[1][-2:], ["--mtp-multirow-reps", "1"])
        self.assertFalse(result["qualification_activated"])
        self.assertTrue(Path(result["result_path"]).is_file())

    def test_fixed_command_failure_is_a_refusal(self):
        output = self.fixture.root / "failed-command.log"
        with self.assertRaisesRegex(jobs.Refusal, f"private log: {output}"):
            jobs.run_checked(["/usr/bin/false"], output, timeout=1)
        self.assertEqual(output.stat().st_mode & 0o777, 0o600)

    def test_qualification_preflight_and_run_exact_matrix_then_sustained(self):
        shutil.rmtree(self.fixture.source / jobs.REUSE_RELATIVE)
        manifest = self.fixture.manifest("qualification")
        validated = jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        self.assertTrue(validated["validated"])
        preflight = self.fixture.stage / "preflight-qualification-nonce"
        result_dir = self.fixture.source / ".lab-window/result-qualification-nonce"
        self.assertTrue((preflight / "validate.log").is_file())
        self.assertFalse(result_dir.exists())
        result = jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        calls = self.fixture.recorded_calls()
        self.assertIn("--validate-only", calls[0])
        run_calls = calls[1:]
        self.assertEqual(len(run_calls), 17)
        cells = [call[call.index("--only-cell") + 1] for call in run_calls[:16]]
        self.assertEqual(cells, list(jobs.QUALIFICATION_CELLS))
        self.assertEqual(run_calls[-1][-2:], ["--phase", "sustained"])
        self.assertFalse(result["qualification_activated"])


if __name__ == "__main__":
    unittest.main()
