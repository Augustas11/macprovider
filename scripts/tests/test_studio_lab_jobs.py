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
REMOTE_HELPER = ROOT / "scripts/ops/lib/studio-lab-window-remote.py"
LAB_SCRIPT = ROOT / "scripts/lab/2080-native-rows/run-window-diagnostic.sh"
SPEC = importlib.util.spec_from_file_location("studio_lab_window_manifest", HELPER)
assert SPEC and SPEC.loader
jobs = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(jobs)
REMOTE_SPEC = importlib.util.spec_from_file_location("studio_lab_window_remote", REMOTE_HELPER)
assert REMOTE_SPEC and REMOTE_SPEC.loader
remote = importlib.util.module_from_spec(REMOTE_SPEC)
REMOTE_SPEC.loader.exec_module(remote)


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
command="$1"
out=
policy=
validate=false
model=
while [ "$#" -gt 0 ]; do
  [ "$1" = --validate-only ] && validate=true
  if [ "$1" = --out ]; then shift; out="$1"; fi
  if [ "$1" = --policy ]; then shift; policy="$1"; fi
  if [ "$1" = --model-id ]; then shift; model="$1"; fi
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
if [ "$command" = native-mtp-journey-e2e ]; then
  printf '%s\n' '{{"schema":"macprovider.native-mtp-journey-hardware-result.v1","journey_complete":false,"executed_steps_status":"partial","covered_steps":["step-04-serial-token-oracle","step-05-cache-state-boundary","step-06-streaming-stop","step-07-mixed-multirow","step-08-capacity-and-depth-zero","step-09-cancellation","step-10-warm-swap","step-12-native-canary (provider-local self-test half)"],"pending_steps":["step-01-bind-tuple","step-02-capability-negatives","step-03-artifact-security-negatives","step-11-accounting","step-12-native-canary (coordinator SPEC-031-R033 half)","step-14-studio-and-tier-benchmark","step-15-redaction-review"],"evidence_class":"lab_isolated_no_join","model_id":"qwen/qwen3.6-35b-a3b","target_sha256":"__TARGET__","mtp_sha256":"__MTP__","tokenizer_sha256":"__TOKENIZER__","mtp_manifest_sha256":"__MTP_MANIFEST__","qualified_slots":8,"max_native_active_rows":1,"max_prompt_tokens":4096,"request_feature_profile":"native_mtp_sampled_text_v1","machine":{{"chip":"Apple M3 Ultra","ram_gb":256,"os_version":"26A434"}},"steps":[{{"step_id":"step-04-serial-token-oracle","status":"pass","uncovered_contract":[],"checks":{{"ok":true}},"details":{{}}}},{{"step_id":"step-05-cache-state-boundary","status":"pass","uncovered_contract":[],"checks":{{"ok":true}},"details":{{}}}},{{"step_id":"step-06-streaming-stop","status":"pass","uncovered_contract":[],"checks":{{"ok":true}},"details":{{}}}},{{"step_id":"step-07-08-mixed-multirow-capacity","status":"pass","uncovered_contract":[],"checks":{{"ok":true}},"details":{{}}}},{{"step_id":"step-09-cancellation","status":"pass","uncovered_contract":[],"checks":{{"ok":true}},"details":{{}}}},{{"step_id":"step-10-warm-swap","status":"pass","uncovered_contract":[],"checks":{{"ok":true}},"details":{{}}}},{{"step_id":"step-12-native-selftest","status":"partial","uncovered_contract":["coordinator-issued SPEC-031-R033 canary and its negative outcomes"],"checks":{{"ok":true}},"details":{{}}}}]}}'
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
        mtp = self.source / ".lab-window/fixture/mtp"
        mtp.mkdir(mode=0o700)
        (mtp / "config.json").write_bytes(b"qwen mtp config\n")
        (mtp / "model.safetensors").write_bytes(b"qwen mtp weights\n")
        self.mtp_digest, _ = jobs.snapshot_identity(mtp)
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

    def _write_qwen_inputs(self) -> None:
        target = self.source / ".lab-window/fixture/target"
        mtp = self.source / ".lab-window/fixture/mtp"
        target_digest, _ = jobs.snapshot_identity(target)
        mtp_digest, _ = jobs.snapshot_identity(mtp)
        projection = {
            "schema_version": "macprovider.native-mtp-artifact-projection.v1",
            "artifacts": {
                "target": {"path": "target", "sha256": target_digest},
                "mtp": {"path": "mtp", "sha256": mtp_digest},
                "tokenizer": {"path": "target/tokenizer.json", "sha256": sha(target / "tokenizer.json")},
                "manifest": {"path": "mtp/config.json", "sha256": sha(mtp / "config.json")},
            },
        }
        write_json(self.source / jobs.QWEN_PROJECTION_RELATIVE, projection)
        write_json(self.source / jobs.POLICY_RELATIVE, {
            "schema": "macprovider.native-mtp-r015-policy.v1",
            "model_id": "qwen/qwen3.6-35b-a3b",
            "target_sha256": target_digest,
            "mtp_sha256": mtp_digest,
            "tokenizer_sha256": sha(target / "tokenizer.json"),
            "provider_commit": self.head,
            "quantization": "4bit", "cache_mode": "paged_kv_mixed", "proposal_depth": 1,
            "run_order": "seeded_random_counterbalanced",
            "prompt_corpus": "deterministic_synthetic_unique_v2",
            "exclusion_rules": "none", "confidence_method": "paired_block_bootstrap_holm_v1",
            "qualified_slots": 8, "max_native_active_rows": 1, "arrival_interval_ms": 250,
            "slots": [1], "maximum_prompt_tokens": 4096,
            "prompt_tokens": [1536, 4096], "max_tokens": [128, 512],
            "gated_cells": ["s2-p1536-o512", "s8-p1536-o512"],
            "warmup_runs": 1, "blocks": 10, "sustained_seconds": 1800,
            "sustained_cell_id": "s8-p1536-o512",
            "thresholds": {
                "throughput_lower_bound_min": 0.15,
                "ttft_p95_upper_bound_max": 0.1,
                "tpot_p95_upper_bound_max": 0.0,
                "chunk_gap_p99_upper_bound_max": 1.0,
                "rejection_increase_max_pp": 1.0,
                "min_available_memory_fraction": 0.1,
                "bootstrap_draws": 10000,
                "alpha": 0.05,
                "gated_throughput_lower_bound_min": -0.05,
                "gated_ttft_p95_upper_bound_max": 0.05,
                "gated_tpot_p95_upper_bound_max": 0.05,
            },
        })
        cli = self.paths["diagnostic_cli"].resolve()
        text = cli.read_text()
        glm_cells = ','.join(f'"{cell}"' for cell in jobs.QUALIFICATION_CELLS)
        qwen_cells = ','.join(f'"{cell}"' for cell in jobs.QWEN_QUALIFICATION_CELLS)
        text = text.replace(f'"mtp_sha256":"{target_digest}"', f'"mtp_sha256":"{mtp_digest}"')
        text = text.replace("__MTP__", mtp_digest).replace(
            "__MTP_MANIFEST__", sha(mtp / "config.json")
        )
        text = text.replace(glm_cells, qwen_cells).replace(
            '"sustained_cell_id":"s4-p1536-o512"',
            '"sustained_cell_id":"s8-p1536-o512"',
        )
        cli.write_text(text)
        cli.chmod(0o700)

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

    def _write_glm_prefill_inputs(self, prompts=None) -> None:
        path = self.source / jobs.POLICY_RELATIVE
        policy = json.loads(path.read_text())
        policy.pop("laboratory_max_native_active_rows")
        policy.update(
            schema="macprovider.native-mtp-exploratory-policy.v1",
            model_id="zai-org/glm-5.3-flash", slots=[1, 2, 4],
            prompt_tokens=prompts or [16384], max_tokens=[128],
            maximum_prompt_tokens=16384, sustained_seconds=0,
            sustained_cell_id="s4-p16384-o128", temperature=0, arrival_interval_ms=250,
            thresholds={
                "throughput_lower_bound_min": 0.15, "ttft_p95_upper_bound_max": 0.1,
                "tpot_p95_upper_bound_max": 0.0, "chunk_gap_p99_upper_bound_max": 1.0,
                "rejection_increase_max_pp": 1.0, "min_available_memory_fraction": 0.1,
                "bootstrap_draws": 10000, "alpha": 0.05,
                "gated_throughput_lower_bound_min": -0.05,
                "gated_ttft_p95_upper_bound_max": 0.05,
                "gated_tpot_p95_upper_bound_max": 0.05,
            },
        )
        write_json(path, policy)
        cli = self.paths["diagnostic_cli"].resolve()
        text = cli.read_text().replace(
            ','.join(f'"{cell}"' for cell in jobs.QUALIFICATION_CELLS),
            ','.join(f'"{cell}"' for cell in jobs.glm_prefill_cells(policy)),
        ).replace('"sustained_cell_id":"s4-p1536-o512"',
                  '"sustained_cell_id":"s4-p16384-o128"')
        cli.write_text(text)
        cli.chmod(0o700)

    def _write_staged_inputs(self, environment=None, live_digest=None) -> None:
        """Inputs for the staged GLM parity and DeepSeek V4 reference jobs."""
        package = self.source / "phase3-binary"
        (package / "Sources").mkdir(mode=0o700, exist_ok=True)
        (package / "Sources/Decode.swift").write_text("// decode path\n")
        write_json(package / "decode-path-manifest.json", {
            "schema_version": "macprovider.decode-path-manifest.v1",
            "files": ["Sources/Decode.swift"], "dependencies": ["mlx-swift"],
        })
        write_json(package / "Package.resolved", {"pins": [
            {"identity": "mlx-swift", "state": {"revision": "a" * 40}},
        ]})
        subprocess.run(["git", "-C", str(self.source), "add", "phase3-binary"], check=True)
        subprocess.run(["git", "-C", str(self.source), "commit", "-qm", "decode path"], check=True)
        self.DIGEST = jobs.source_decode_path_digest(self.source)
        marker = f"macprovider.decode-path-digest.v1:{self.DIGEST}"
        cli = self.paths["diagnostic_cli"].resolve()
        cli.write_text(f"""#!/bin/sh
# {marker}
printf '%s\\t' "$@" >> {str(self.calls)!r}
printf '\\n' >> {str(self.calls)!r}
[ "$1" = glm-parity ] || exit 0
while [ "$#" -gt 0 ]; do [ "$1" = --output ] && out="$2"; shift; done
printf '%s\\n' '{{"schema":"glm-parity-v1","prefill_step_size":512,"runs":[{{"measurement":{{"prompt_tokens":8192,"prefill_tokens_per_second":280.5,"ttft_seconds":29.3,"decode_tokens_per_second":20.1,"free_running":{{"compared_tokens":256,"matching_tokens":256,"top1_agreement":16,"top1_compared":16}}}}}}]}}' > "$out"
""")
        cli.chmod(0o700)
        install = self.root / "install"
        install.mkdir(mode=0o700, exist_ok=True)
        live = install / "macprovider-cli"
        live.write_text(f"signed release {f'macprovider.decode-path-digest.v1:{live_digest}' if live_digest else marker}\n")
        live.chmod(0o700)
        oracle = self.source / jobs.GLM_PARITY_ORACLE_RELATIVE
        oracle.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        oracle.write_text('{"schema":"glm-parity-oracle-v1"}\n')
        oracle.chmod(0o600)
        glm_target, _ = jobs.snapshot_identity(self.source / ".lab-window/fixture/target")
        write_json(self.source / jobs.GLM_PARITY_POLICY_RELATIVE, {
            **jobs.GLM_PARITY_POLICY, "target_sha256": glm_target,
            "oracle_sha256": sha(oracle), "decode_path_digest": self.DIGEST,
        })

        env = json.dumps(environment or jobs.DSV4_REFERENCE_POLICY["environment"], sort_keys=True)
        python = self.paths["reference_python"]
        python.write_text(f"""#!/bin/sh
if [ "$2" = -c ]; then printf '%s\\n' {env!r}; exit 0; fi
printf '%s\\t' "$@" >> {str(self.calls)!r}
printf '\\n' >> {str(self.calls)!r}
mkdir -m 700 "$4"
printf '{{}}\\n' > "$4/speed.json"
for ctx in 1024 8192 32768; do printf 'npz\\n' > "$4/oracle_$ctx.npz"; done
""")
        python.chmod(0o700)
        script = self.paths["reference_script"]
        script.write_text("print('reference')\n")
        script.chmod(0o600)
        weights = self.source / ".lab-window/fixture/dsv4-target/model-00001-of-00001.safetensors"
        weights.write_bytes(b"dsv4 weights\n")
        weights.chmod(0o600)
        subprocess.run(["git", "-C", str(self.source), "add", str(script)], check=True)
        subprocess.run(["git", "-C", str(self.source), "commit", "-qm", "reference"], check=True)
        self.head = subprocess.run(
            ["git", "-C", str(self.source), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        dsv4_target, _ = jobs.snapshot_identity(self.source / ".lab-window/fixture/dsv4-target")
        write_json(self.source / jobs.DSV4_POLICY_RELATIVE, {
            **jobs.DSV4_REFERENCE_POLICY, "target_sha256": dsv4_target,
        })

    def snapshot(self, kind: str) -> dict:
        if kind in jobs.QWEN_JOB_KINDS:
            self._write_qwen_inputs()
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
            "install_dir": str(self.root / "install"),
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

    def test_glm_prefill_runs_only_fixed_matrix_with_nonqualification_receipt(self):
        self.fixture._write_glm_prefill_inputs()
        self.fixture.paths["glmbench"].unlink()
        self.fixture.paths["glmbench_metallib"].unlink()
        manifest = self.fixture.manifest("glm-prefill")
        loaded, job = jobs.load_job_manifest(str(manifest))
        self.assertEqual(set(loaded["artifacts"]), jobs.QWEN_ARTIFACT_FIELDS)
        self.assertNotIn("glmbench_tree_oid", job["immutable_inputs"])
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        with mock.patch.object(jobs, "run_checked", wraps=jobs.run_checked) as dispatch:
            result = jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual([call.kwargs["timeout"] for call in dispatch.call_args_list], [7200] * 3)
        calls = self.fixture.recorded_calls()
        self.assertEqual(len(calls), 4)  # One validate-only, then three matrix cells.
        self.assertIn("--validate-only", calls[0])
        cells = ["s1-p16384-o128", "s2-p16384-o128", "s4-p16384-o128"]
        for argv, cell in zip(calls[1:], cells):
            self.assertEqual(argv[0], "native-mtp-bench")
            self.assertEqual(argv[-4:], ["--only-cell", cell, "--phase", "matrix"])
        self.assertTrue(result["exploratory"])
        self.assertFalse(result["qualification"])
        self.assertFalse(result["qualification_activated"])
        self.assertEqual(result["evidence_class"], "glm_prefill_measurement_only")
        self.assertNotIn("sustained.log", result["outputs"])
        self.assertNotIn("selftest.log", result["outputs"])

    def test_glm_prefill_comparison_has_six_fixed_cells(self):
        self.fixture._write_glm_prefill_inputs([4096, 16384])
        manifest = self.fixture.manifest("glm-prefill")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        result = jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        calls = self.fixture.recorded_calls()[1:]
        self.assertEqual([argv[-3] for argv in calls], [
            "s1-p4096-o128", "s1-p16384-o128", "s2-p4096-o128",
            "s2-p16384-o128", "s4-p4096-o128", "s4-p16384-o128",
        ])
        self.assertEqual(len(result["outputs"]), 7)

    def test_glm_prefill_rejects_policy_drift_and_admission_overrides(self):
        self.fixture._write_glm_prefill_inputs()
        path = self.fixture.source / jobs.POLICY_RELATIVE
        policy = json.loads(path.read_text())
        for key, value in (
            ("schema", "macprovider.native-mtp-r015-policy.v1"),
            ("slots", [1, 2, 3, 4]), ("prompt_tokens", [4096]),
            ("prompt_tokens", [True, 16384]), ("max_native_active_rows", 4),
            ("qualified_slots", True), ("blocks", 2), ("sustained_seconds", 1800),
            ("temperature", 0.1), ("arrival_interval_ms", 0),
            ("laboratory_max_native_active_rows", 4),
            ("thresholds", {**policy["thresholds"], "alpha": 0.1}),
        ):
            with self.subTest(key=key, value=value):
                write_json(path, {**policy, key: value})
                with self.assertRaises(jobs.Refusal):
                    self.fixture.snapshot("glm-prefill")
        self.assertEqual(self.fixture.recorded_calls(), [])

    def test_glm_prefill_rejects_rebound_nonfixed_cells(self):
        self.fixture._write_glm_prefill_inputs()
        manifest = self.fixture.manifest("glm-prefill")
        document = json.loads(manifest.read_text())
        job = document["job"]
        job["immutable_inputs"]["qualification_cells"].append("s3-p16384-o128")
        job["identity_sha256"] = jobs.canonical_digest({
            "kind": job["kind"], "immutable_inputs": job["immutable_inputs"],
        })
        write_json(manifest, document)
        with self.assertRaisesRegex(jobs.Refusal, "immutable input schema"):
            jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def test_glm_prefill_private_cli_drift_refuses_before_first_matrix(self):
        self.fixture._write_glm_prefill_inputs()
        manifest = self.fixture.manifest("glm-prefill")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        loaded, job = jobs.load_job_manifest(str(manifest))
        jobs.private_artifact_paths(loaded, job)["diagnostic_cli"].write_bytes(b"changed CLI")
        with self.assertRaisesRegex(jobs.Refusal, "private job artifact drifted"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(len(self.fixture.recorded_calls()), 1)  # Validate-only.

    def test_glm_prefill_policy_swap_between_cells_refuses(self):
        self.fixture._write_glm_prefill_inputs()
        manifest = self.fixture.manifest("glm-prefill")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        original = jobs.run_checked

        def swap(argv, output, *, timeout=3600):
            original(argv, output, timeout=timeout)
            path = self.fixture.source / jobs.POLICY_RELATIVE
            path.write_bytes(path.read_bytes() + b"\n")

        with mock.patch.object(jobs, "run_checked", side_effect=swap):
            with self.assertRaisesRegex(jobs.Refusal, "policy identity drifted"):
                jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(len(self.fixture.recorded_calls()), 2)
        self.assertFalse((self.fixture.source / ".lab-window/result-glm-prefill-nonce/result.json").exists())

    def test_qwen_snapshot_has_no_glmbench_dependency(self):
        original = jobs.git_value

        def refuse_glmbench(source, value, name):
            if "glm53-bench" in value:
                raise AssertionError("Qwen snapshot consulted GLMBench")
            return original(source, value, name)

        self.fixture.paths["glmbench"].unlink()
        with mock.patch.object(jobs, "git_value", side_effect=refuse_glmbench):
            snapshot = self.fixture.snapshot("qwen-qualification")
        self.assertEqual(set(snapshot["artifacts"]), jobs.QWEN_ARTIFACT_FIELDS)
        self.assertNotIn("glmbench_tree_oid", snapshot["job"]["immutable_inputs"])

    def test_qwen_journey_preflight_is_read_only_and_run_is_one_fixed_command(self):
        manifest_path = self.fixture.manifest("qwen-journey")
        manifest, job = jobs.load_job_manifest(str(manifest_path))
        self.assertEqual(job["immutable_inputs"]["journey_profile"], jobs.QWEN_JOURNEY_PROFILE)
        self.assertNotIn("qualification_cells", job["immutable_inputs"])
        jobs.validate_job(argparse.Namespace(manifest=str(manifest_path)))
        self.assertEqual(self.fixture.recorded_calls(), [])
        result = jobs.run_job(argparse.Namespace(manifest=str(manifest_path)))
        self.assertEqual(self.fixture.recorded_calls(), [[
            "native-mtp-journey-e2e", "--root", str(self.fixture.source / ".lab-window/fixture"),
            "--model-id", "qwen/qwen3.6-35b-a3b", "--qualified-slots", "8",
            "--max-native-active-rows", "1", "--max-prompt-tokens", "4096",
        ]])
        self.assertEqual(set(result["outputs"]), {"journey.log"})
        self.assertIn("fixture_mtp_sha256", result["executed_inputs"])
        self.assertFalse(result["qualification_activated"])

    def test_qwen_journey_result_refuses_identity_runtime_and_failed_checks(self):
        manifest_path = self.fixture.manifest("qwen-journey")
        manifest, job = jobs.load_job_manifest(str(manifest_path))
        jobs.validate_job(argparse.Namespace(manifest=str(manifest_path)))
        jobs.run_job(argparse.Namespace(manifest=str(manifest_path)))
        result_path = self.fixture.source / ".lab-window/result-qwen-journey-nonce/journey.log"
        valid = json.loads(result_path.read_text().splitlines()[-1])
        for name, mutate in (
            ("model", lambda value: value.__setitem__("model_id", "wrong/model")),
            ("runtime", lambda value: value.__setitem__("request_feature_profile", "wrong-profile")),
            ("projection", lambda value: value.__setitem__("mtp_sha256", "f" * 64)),
            ("hardware", lambda value: value["steps"][0]["checks"].__setitem__("ok", False)),
            ("step-05-partial", lambda value: value["steps"][1].update({
                "status": "partial", "uncovered_contract": ["external"],
            })),
            ("step-12-pass", lambda value: value["steps"][6].update({
                "status": "pass", "uncovered_contract": [],
            })),
            ("step-12-altered-uncovered", lambda value: value["steps"][6].update({
                "uncovered_contract": [
                    "coordinator-issued SPEC-031-R033 canary and its negative outcome"
                ],
            })),
            ("step-12-extra-uncovered", lambda value: value["steps"][6].update({
                "uncovered_contract": [
                    "coordinator-issued SPEC-031-R033 canary and its negative outcomes",
                    "external",
                ],
            })),
        ):
            changed = json.loads(json.dumps(valid))
            mutate(changed)
            candidate = self.fixture.root / f"bad-{name}.log"
            candidate.write_text(json.dumps(changed) + "\n")
            with self.subTest(name=name), self.assertRaises(jobs.Refusal):
                jobs.validate_qwen_journey_result(candidate, job)

    def test_qwen_journey_job_refuses_rebound_runtime_profile(self):
        job = self.fixture.snapshot("qwen-journey")["job"]
        job["immutable_inputs"]["journey_profile"]["request_feature_profile"] = "wrong-profile"
        job["identity_sha256"] = jobs.canonical_digest({
            "kind": job["kind"], "immutable_inputs": job["immutable_inputs"],
        })
        with self.assertRaisesRegex(jobs.Refusal, "journey profile"):
            jobs.validate_job_object(job)

    def test_qwen_journey_mtp_mutation_refuses_before_command(self):
        manifest = self.fixture.manifest("qwen-journey")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        mtp = self.fixture.source / ".lab-window/fixture/mtp/model.safetensors"
        mtp.write_bytes(b"changed before journey\n")
        with self.assertRaisesRegex(jobs.Refusal, "MTP fixture changed after job preflight"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def _assert_cli_only_source_build_and_remote_load(self, kind):
        snapshot = self.fixture.snapshot(kind)
        snapshot_path = self.fixture.root / "source-snapshot.json"
        probe_path = self.fixture.root / "probe.json"
        write_json(snapshot_path, snapshot)
        digest = "a" * 64
        install = self.fixture.root / "install"
        probe = {
            "hardware_model": "Mac15,14",
            "installed": {"binary_sha256": digest},
            "snapshot": {
                "config_sha256": digest,
                "provider_plist_sha256": digest,
                "watchdog_plist_sha256": digest,
                "compatibility_set_sha256": digest,
                "provider_id_sha256": digest,
                "coordinator_origin": "https://coordinator.invalid",
                "compatibility_set_id": "fixture-set",
                "binary_version": "1.0.0",
                "model": "fixture-model",
                "model_loaded": True,
                "network_state": "buyer_serving",
                "requests_in_flight": 0,
                "coordinator_connected": True,
                "operator_paused": False,
                "pid": 123,
                "process_start_us": 456,
                "executable_path": str(install / "macprovider-cli"),
            },
        }
        write_json(probe_path, probe)
        args = argparse.Namespace(
            nonce="a" * 32, git_head=self.fixture.head,
            probe_json=str(probe_path), source_snapshot_json=str(snapshot_path),
            probe_sha256=digest, lab_script_sha256=sha(self.fixture.staged_script),
            install_dir=str(install), config_path=str(self.fixture.root / "config.json"),
            ctl_socket=str(self.fixture.root / "control.sock"), provider_label="fixture.provider",
            status_port="9876", probe_path=str(self.fixture.stage / "probe.py"),
            owner_pin_journal=str(self.fixture.root / "owner.json"),
            lab_source_dir=str(self.fixture.source), lab_script_path=str(self.fixture.staged_script),
            log_path=str(self.fixture.root / "provider.log"), drain_timeout_s="600",
            lab_timeout_s=str(jobs.STAGED_WINDOW_TIMEOUTS.get(kind, 21600 if kind == "glm-prefill" else 7200)),
            ready_timeout_s="120", poll_s="5",
        )
        manifest = jobs.build_manifest(args)
        path = self.fixture.stage / "window.json"
        write_json(path, manifest)
        loaded, _ = remote.load_manifest(path)
        self.assertEqual(set(loaded["artifacts"]), jobs.artifact_fields(kind))
        remote.validate_lab_artifacts(loaded)
        manifest["artifacts"]["unknown"] = {"path": "/tmp/unknown", "sha256": digest}
        write_json(path, manifest)
        with self.assertRaisesRegex(remote.Refusal, "artifact set"):
            remote.load_manifest(path)

    def test_qwen_journey_source_build_and_remote_load_accepts_only_qwen_artifacts(self):
        self._assert_cli_only_source_build_and_remote_load("qwen-journey")

    def test_glm_prefill_source_build_and_remote_load_enforces_timeout(self):
        self.fixture._write_glm_prefill_inputs()
        self._assert_cli_only_source_build_and_remote_load("glm-prefill")
        path = self.fixture.stage / "window.json"
        manifest = json.loads(path.read_text())
        manifest["artifacts"].pop("unknown")
        manifest["lab_timeout_s"] = 21601
        write_json(path, manifest)
        with self.assertRaisesRegex(remote.Refusal, "lab_timeout_s"):
            remote.load_manifest(path)

    def test_staged_source_build_and_remote_load_accept_only_their_artifacts(self):
        self.fixture._write_staged_inputs()
        for kind in jobs.STAGED_JOB_KINDS:
            with self.subTest(kind=kind):
                self._assert_cli_only_source_build_and_remote_load(kind)
                path = self.fixture.stage / "window.json"
                manifest = json.loads(path.read_text())
                manifest["artifacts"].pop("unknown")
                manifest["lab_timeout_s"] = jobs.STAGED_WINDOW_TIMEOUTS[kind] + 1
                write_json(path, manifest)
                with self.assertRaisesRegex(remote.Refusal, "lab_timeout_s"):
                    remote.load_manifest(path)

    def _staged_result_dir(self, kind):
        return self.fixture.source / f".lab-window/result-{kind}-nonce"

    def test_sequence_runs_glm_parity_then_reference_in_one_job(self):
        self.fixture._write_staged_inputs()
        kind = "glm-parity-prefill512-then-dsv4-reference"
        manifest = self.fixture.manifest(kind)
        loaded, job = jobs.load_job_manifest(str(manifest))
        self.assertEqual(set(loaded["artifacts"]), jobs.artifact_fields(kind))
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])
        with mock.patch.object(jobs, "run_checked", wraps=jobs.run_checked) as dispatch:
            result = jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual([call.kwargs["timeout"] for call in dispatch.call_args_list], [2700, 120, 5400])
        private = jobs.private_artifact_paths(loaded, job)
        out = self._staged_result_dir(kind)
        source = self.fixture.source
        self.assertEqual(self.fixture.recorded_calls(), [
            [
                "glm-parity", "--model-dir", str(source / ".lab-window/fixture/target"),
                "--oracle", str(private["glm_parity_oracle"]), "--steps", "256",
                "--prefill-step-size", "512", "--mlx-cache-limit-mb", "4096",
                "--output", str(out / "glm-parity.json"),
            ],
            [
                "-I", str(private["reference_script"]), str(source / ".lab-window/fixture/dsv4-target"),
                str(out / "reference"),
                "--oracle-contexts", "1024,8192,32768", "--ttft-contexts", "4096,32768",
                "--rows", "1,4", "--row-prompt", "1024", "--decode", "256",
            ],
        ])
        self.assertEqual(result["components"], {
            "glm-parity-prefill512": "completed", "dsv4-reference": "completed",
        })
        parity = result["measurements"]["glm-parity-prefill512"]
        self.assertEqual(parity["prefill_tokens_per_second"], 280.5)
        self.assertTrue(parity["token_parity"])
        self.assertEqual(set(result["outputs"]), {
            "glm-parity.log", "glm-parity.json", "environment.json", "reference.log",
            "reference/speed.json", "reference/oracle_1024.npz", "reference/oracle_8192.npz",
            "reference/oracle_32768.npz",
        })
        self.assertFalse(result["qualification"])
        self.assertFalse(result["qualification_activated"])

    def test_sequence_continues_after_first_failure_and_fails_the_job(self):
        self.fixture._write_staged_inputs()
        kind = "glm-parity-prefill512-then-dsv4-reference"
        manifest = self.fixture.manifest(kind)
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        live = self.fixture.root / "install/macprovider-cli"
        live.write_text(f"macprovider.decode-path-digest.v1:{'e' * 64}\n")
        with self.assertRaisesRegex(jobs.Refusal, "components failed: glm-parity-prefill512"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        calls = self.fixture.recorded_calls()
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0][0], "-I")
        out = self._staged_result_dir(kind)
        partial = json.loads((out / "partial-result.json").read_text())
        self.assertEqual(partial["components"]["dsv4-reference"], "completed")
        self.assertTrue(partial["components"]["glm-parity-prefill512"].startswith("failed"))
        self.assertFalse((out / "result.json").exists())

    def test_staged_constants_agree_across_helper_remote_and_controller(self):
        self.assertEqual(jobs.STAGED_WINDOW_TIMEOUTS, remote.STAGED_WINDOW_TIMEOUTS)
        self.assertEqual(set(jobs.STAGED_JOB_KINDS), set(remote.STAGED_VALIDATE_TIMEOUTS))
        self.assertTrue(set(jobs.STAGED_JOB_KINDS) <= set(remote.JOB_KINDS))
        controller = (ROOT / "scripts/ops/studio-lab-window.sh").read_text()
        for kind, ceiling in jobs.STAGED_WINDOW_TIMEOUTS.items():
            self.assertEqual(set(remote.job_artifact_keys({"kind": kind})), jobs.artifact_fields(kind))
            self.assertIn(f"    {kind}) printf '{ceiling}' ;;", controller)
            self.assertGreaterEqual(ceiling, sum(
                jobs.STAGED_COMMAND_TIMEOUTS[item] for item in jobs.STAGED_JOB_KINDS[kind]
            ))

    def test_glm_parity_report_without_divergence_is_full_parity(self):
        self.fixture._write_staged_inputs()
        manifest = self.fixture.manifest("glm-parity-prefill512")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        result = jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        parity = result["measurements"]["glm-parity-prefill512"]
        self.assertIsNone(parity["first_divergence"])
        self.assertTrue(parity["token_parity"])

    def test_sequence_continues_after_an_unparseable_parity_report(self):
        self.fixture._write_staged_inputs()
        cli = self.fixture.paths["diagnostic_cli"].resolve()
        cli.write_text(cli.read_text().replace('"schema":"glm-parity-v1"', '"schema":"glm-parity-v1","runs_missing":1').replace('"runs":', '"r":'))
        cli.chmod(0o700)
        kind = "glm-parity-prefill512-then-dsv4-reference"
        manifest = self.fixture.manifest(kind)
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        with self.assertRaisesRegex(jobs.Refusal, "components failed: glm-parity-prefill512"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        partial = json.loads((self._staged_result_dir(kind) / "partial-result.json").read_text())
        self.assertEqual(partial["components"]["dsv4-reference"], "completed")

    def test_glm_parity_refuses_a_source_off_the_policy_decode_path(self):
        self.fixture._write_staged_inputs()
        manifest = self.fixture.manifest("glm-parity-prefill512")
        decode = self.fixture.source / "phase3-binary/Sources/Decode.swift"
        decode.write_text("// changed decode path\n")
        with self.assertRaisesRegex(jobs.Refusal, "lab source decode path differs"):
            jobs.check_glm_parity_decode_path(*jobs.load_job_manifest(str(manifest)))

    def test_staged_fixture_writable_by_others_refuses_preflight(self):
        self.fixture._write_staged_inputs()
        weights = self.fixture.source / ".lab-window/fixture/dsv4-target/model-00001-of-00001.safetensors"
        weights.chmod(0o666)
        manifest = self.fixture.manifest("dsv4-reference")
        with self.assertRaisesRegex(jobs.Refusal, "not operator-only writable"):
            jobs.validate_job(argparse.Namespace(manifest=str(manifest)))

    def test_reference_interpreter_swap_before_launch_refuses(self):
        self.fixture._write_staged_inputs()
        manifest = self.fixture.manifest("dsv4-reference")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        loaded, job = jobs.load_job_manifest(str(manifest))
        python = self.fixture.paths["reference_python"]
        python.write_text(python.read_text() + "# swapped\n")
        with self.assertRaisesRegex(jobs.Refusal, "reference interpreter drifted"):
            jobs.authenticate_interpreter(loaded, job)

    def test_glm_parity_refuses_a_lab_cli_off_the_live_decode_path(self):
        self.fixture._write_staged_inputs(live_digest="e" * 64)
        manifest = self.fixture.manifest("glm-parity-prefill512")
        with self.assertRaisesRegex(jobs.Refusal, "signed provider decode path differs"):
            jobs.validate_job(argparse.Namespace(manifest=str(manifest)))

    def test_staged_policies_refuse_drift(self):
        self.fixture._write_staged_inputs()
        cases = (
            (jobs.GLM_PARITY_POLICY_RELATIVE, "glm-parity-prefill512", "GLM parity prefill512 policy",
             (("prefill_step_size", 2048), ("steps", 512), ("oracle", "oracle_1024.json"), ("extra", 1))),
            (jobs.DSV4_POLICY_RELATIVE, "dsv4-reference", "DeepSeek V4 reference policy",
             (("decode", 512), ("rows", [1, 8]), ("environment", {"mlx": "0.32.4"}), ("temperature", False))),
        )
        for relative, kind, message, changes in cases:
            path = self.fixture.source / relative
            base = json.loads(path.read_text())
            for key, value in changes:
                with self.subTest(kind=kind, key=key):
                    write_json(path, {**base, key: value})
                    with self.assertRaisesRegex(jobs.Refusal, message):
                        self.fixture.snapshot(kind)
            write_json(path, base)

    def test_glm_parity_oracle_swap_refuses(self):
        self.fixture._write_staged_inputs()
        oracle = self.fixture.source / jobs.GLM_PARITY_ORACLE_RELATIVE
        oracle.write_text('{"schema":"other"}\n')
        with self.assertRaisesRegex(jobs.Refusal, "oracle differs"):
            self.fixture.snapshot("glm-parity-prefill512")

    def test_staged_fixture_identity_and_environment_refuse_preflight(self):
        self.fixture._write_staged_inputs({"mlx": "0.32.4", "mlx-metal": "0.32.4", "mlx-vlm": "0.7.9"})
        manifest = self.fixture.manifest("dsv4-reference")
        with self.assertRaisesRegex(jobs.Refusal, "reference environment differs"):
            jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        path = self.fixture.source / jobs.GLM_PARITY_POLICY_RELATIVE
        write_json(path, {**json.loads(path.read_text()), "target_sha256": "b" * 64})
        manifest = self.fixture.manifest("glm-parity-prefill512")
        with self.assertRaisesRegex(jobs.Refusal, "fixture identity differs"):
            jobs.validate_job(argparse.Namespace(manifest=str(manifest)))

    def test_staged_fixture_change_after_preflight_refuses_before_command(self):
        self.fixture._write_staged_inputs()
        kind = "glm-parity-prefill512-then-dsv4-reference"
        manifest = self.fixture.manifest(kind)
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        extra = self.fixture.source / ".lab-window/fixture/dsv4-target/extra.json"
        extra.write_text("{}\n")
        extra.chmod(0o600)
        with self.assertRaisesRegex(jobs.Refusal, "dsv4-reference fixture changed after job preflight"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def test_staged_private_copy_swap_refuses_before_command(self):
        self.fixture._write_staged_inputs()
        manifest = self.fixture.manifest("dsv4-reference")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        loaded, job = jobs.load_job_manifest(str(manifest))
        jobs.private_artifact_paths(loaded, job)["reference_script"].write_text("print('swapped')\n")
        with self.assertRaisesRegex(jobs.Refusal, "private job artifact drifted"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(self.fixture.recorded_calls(), [])

    def _unrelated_phase3_commit(self) -> str:
        phase3 = self.fixture.source / "phase3-binary/source.txt"
        phase3.write_text("unrelated phase3 source\n")
        subprocess.run(["git", "-C", str(self.fixture.source), "add", str(phase3)], check=True)
        subprocess.run(
            ["git", "-C", str(self.fixture.source), "commit", "-qm", "unrelated phase3"],
            check=True,
        )
        stale = subprocess.run(
            ["git", "-C", str(self.fixture.source), "rev-parse", "HEAD"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        subprocess.run(
            ["git", "-C", str(self.fixture.source), "reset", "--hard", self.fixture.head],
            check=True, capture_output=True,
        )
        return stale

    def test_qwen_snapshot_rejects_unrelated_provider_commit(self):
        self.fixture._write_qwen_inputs()
        stale = self._unrelated_phase3_commit()
        policy_path = self.fixture.source / jobs.POLICY_RELATIVE
        policy = json.loads(policy_path.read_text())
        policy["provider_commit"] = stale
        write_json(policy_path, policy)
        args = argparse.Namespace(
            source_dir=str(self.fixture.source), git_head=self.fixture.head,
            provider_label="fixture.provider", job_kind="qwen-qualification",
            lab_script_sha256=sha(self.fixture.staged_script),
            job_helper_sha256=sha(self.fixture.staged_helper),
        )
        with self.assertRaisesRegex(jobs.Refusal, "different phase3 source"):
            jobs.source_snapshot(args)

    def test_qwen_current_validation_rejects_rebound_unrelated_provider_commit(self):
        manifest_path = self.fixture.manifest("qwen-qualification")
        manifest, job = jobs.load_job_manifest(str(manifest_path))
        stale = self._unrelated_phase3_commit()
        policy_path = self.fixture.source / jobs.POLICY_RELATIVE
        policy = json.loads(policy_path.read_text())
        policy["provider_commit"] = stale
        write_json(policy_path, policy)
        inputs = job["immutable_inputs"]
        inputs["qualification_provider_commit"] = stale
        inputs["qualification_policy_sha256"] = sha(policy_path)
        job["identity_sha256"] = jobs.canonical_digest({
            "kind": job["kind"], "immutable_inputs": inputs,
        })
        with self.assertRaisesRegex(jobs.Refusal, "provider source drifted"):
            jobs.validate_current_job_inputs(manifest, job)

    def test_qwen_policy_refuses_shape_gate_and_override_drift(self):
        self.fixture._write_qwen_inputs()
        policy = json.loads((self.fixture.source / jobs.POLICY_RELATIVE).read_text())
        for key, value, message in (
            ("slots", [1, 8], "approved R015 contract"),
            ("laboratory_max_native_active_rows", 8, "override"),
            ("thresholds", {**policy["thresholds"], "alpha": 0.1}, "approved gates"),
        ):
            changed = dict(policy)
            changed[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(jobs.Refusal, message):
                jobs.validate_qwen_policy(changed)

    def test_qwen_projection_identity_drift_refuses(self):
        manifest = self.fixture.manifest("qwen-qualification")
        loaded, job = jobs.load_job_manifest(str(manifest))
        projection = self.fixture.source / jobs.QWEN_PROJECTION_RELATIVE
        projection.write_bytes(projection.read_bytes() + b"\n")
        with self.assertRaisesRegex(jobs.Refusal, "projection identity drifted"):
            jobs.validate_current_job_inputs(loaded, job)

    def _assert_qwen_mtp_change_refuses(self, mutate) -> None:
        manifest = self.fixture.manifest("qwen-qualification")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        mtp = self.fixture.source / ".lab-window/fixture/mtp"
        mutate(mtp)
        with self.assertRaisesRegex(jobs.Refusal, "MTP fixture changed after job preflight"):
            jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        self.assertEqual(len(self.fixture.recorded_calls()), 1)

    def test_qwen_mtp_mutation_refuses_before_matrix(self):
        self._assert_qwen_mtp_change_refuses(
            lambda mtp: (mtp / "model.safetensors").write_bytes(b"mutated mtp weights\n")
        )

    def test_qwen_mtp_removal_refuses_before_matrix(self):
        self._assert_qwen_mtp_change_refuses(lambda mtp: (mtp / "model.safetensors").unlink())

    def test_qwen_mtp_addition_refuses_before_matrix(self):
        self._assert_qwen_mtp_change_refuses(
            lambda mtp: (mtp / "added.safetensors").write_bytes(b"late mtp weights\n")
        )

    def test_qwen_runs_six_cells_sustained_then_fixed_selftest(self):
        manifest = self.fixture.manifest("qwen-qualification")
        jobs.validate_job(argparse.Namespace(manifest=str(manifest)))
        result = jobs.run_job(argparse.Namespace(manifest=str(manifest)))
        calls = self.fixture.recorded_calls()
        self.assertEqual(len(calls), 9)
        matrix = calls[1:7]
        self.assertEqual(
            [call[call.index("--only-cell") + 1] for call in matrix],
            list(jobs.QWEN_QUALIFICATION_CELLS),
        )
        self.assertEqual(calls[7][-2:], ["--phase", "sustained"])
        self.assertEqual(calls[8], [
            "native-mtp-journey-e2e", "--root", str(self.fixture.source / ".lab-window/fixture"),
            "--model-id", "qwen/qwen3.6-35b-a3b", "--qualified-slots", "8",
            "--max-native-active-rows", "1", "--max-prompt-tokens", "4096",
            "--selftest-only",
        ])
        self.assertIn("fixture_mtp_sha256", result["executed_inputs"])


if __name__ == "__main__":
    unittest.main()
