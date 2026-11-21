"""scripts/lab/ablit-perf/publish_dsv4_abliterated.py (#2452): the publish step for the abliterated
DeepSeek V4-Flash splice, and the upload/verify helper it shares with the MiniMax publish step.
No network: the APFS clone is replaced by a plain copy and Hugging Face by a fake."""
from __future__ import annotations

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
from types import SimpleNamespace
from unittest import mock

LAB = Path(__file__).resolve().parents[1] / "lab"
spec = importlib.util.spec_from_file_location("publish_dsv4_abliterated", LAB / "ablit-perf" / "publish_dsv4_abliterated.py")
pub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pub)
shared = sys.modules["publish_abliterated"]  # imported by the module above from lab/minimax
JOB = LAB / "ablit-perf" / "job-dsv4-abliterated.sh"


def provenance(model_sha256: str) -> dict:
    return {
        "schema": "macprovider.dsv4-abliterated-provenance.v1",
        "license": "mit",
        "model_sha256": model_sha256,
        "base_catalog_row": {"model_id": "deepseek/deepseek-v4-flash", "model_sha256": "0" * 64,
                             "repo": pub.BASE_REPO, "revision": pub.BASE_REVISION},
        "abliteration_source": {"license": "mit", "repo": pub.SOURCE_REPO, "revision": pub.SOURCE_REVISION},
        "method": "ARA (prem-research model card): attn.wo_b, ffn.shared_experts.w2 and the listed experts' ffn.experts.E.w2, layers 17-36",
        "recipe": "byte transplant",
        "changed_tensors": 320,
        "touched_shards": {f"model-{i:05d}-of-00048.safetensors": {} for i in range(15)},
        "numeric_worst_max_abs_err": 0.0,
        "parity_min_match": 240,
        "refusal": {"pass": True, "failures": [],
                    "base": {"harmful": {"answered": 0, "empty": 0, "refused": 20},
                             "harmless": {"answered": 20, "empty": 0, "refused": 0}},
                    "abliterated": {"harmful": {"answered": 20, "empty": 0, "refused": 0},
                                    "harmless": {"answered": 20, "empty": 0, "refused": 0}}},
    }


def fake_cp(cmd, check=True):
    assert cmd[:4] == ["/bin/cp", "-c", "-R", cmd[3]], cmd
    shutil.copytree(cmd[3], cmd[4])
    return subprocess.CompletedProcess(cmd, 0)


class Fixture:
    def __init__(self, root: Path, cache: bool = False):
        self.snapshot = root / "abl"
        self.snapshot.mkdir()
        (self.snapshot / "config.json").write_text('{"model_type": "deepseek_v4"}')
        (self.snapshot / "README.md").write_text("TensorFold base card\n")
        (self.snapshot / "model-00001-of-00048.safetensors").write_bytes(b"\0" * 64)
        if cache:
            (self.snapshot / ".cache" / "huggingface").mkdir(parents=True)
        self.results = root / "res"
        self.results.mkdir()
        self.sha = "f" * 64 if cache else shared.snapshot_manifest_sha256(self.snapshot)
        (self.results / "provenance.json").write_text(json.dumps(provenance(self.sha)))
        (self.results / "tensor-diff.json").write_text(json.dumps(
            {"compared": {"tensors": 31450, "identical": 31130, "changed": 320}}))
        self.stage = root / "publish" / "stage"

    def run(self, *extra: str, expect: str | None = None) -> str:
        argv = ["publish_dsv4_abliterated.py", str(self.snapshot), str(self.results), str(self.stage),
                "--expect-stage", expect or self.sha, *extra]
        out = io.StringIO()
        with mock.patch.object(sys, "argv", argv), mock.patch.object(pub.subprocess, "run", fake_cp), \
                contextlib.redirect_stdout(out):
            pub.main()
        return out.getvalue()


class PublishDsv4Tests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def test_root_cache_in_snapshot_is_refused(self):
        fx = Fixture(self.root, cache=True)
        with self.assertRaises(SystemExit) as cm:
            fx.run("--dry-run")
        self.assertIn(".cache present", str(cm.exception))
        self.assertFalse(fx.stage.exists())

    def test_snapshot_not_the_tested_artifact_blocks(self):
        fx = Fixture(self.root)
        (fx.snapshot / "config.json").write_text('{"model_type": "deepseek_v4", "edited": true}')
        with self.assertRaises(SystemExit) as cm:
            fx.run("--dry-run")
        self.assertIn(f"is not the tested artifact {fx.sha}", str(cm.exception))
        self.assertFalse(fx.stage.exists())

    def test_expect_stage_other_than_provenance_blocks(self):
        fx = Fixture(self.root)
        with self.assertRaises(SystemExit) as cm:
            fx.run("--dry-run", expect="a" * 64)
        self.assertIn("is not the provenance model_sha256", str(cm.exception))

    def test_dry_run_stages_the_card_and_never_contacts_hugging_face(self):
        fx = Fixture(self.root)
        with mock.patch.dict(sys.modules, {"huggingface_hub": None}):  # any import would raise
            out = fx.run("--dry-run")
        self.assertIn(f"PUBLISH_SNAPSHOT manifest={fx.sha}", out)
        self.assertIn("PUBLISH_DRY_RUN done", out)
        stage_line = next(l for l in out.splitlines() if l.startswith("PUBLISH_STAGE "))
        self.assertIn(f"tested_manifest={fx.sha}", stage_line)
        self.assertIn(f"manifest={shared.snapshot_manifest_sha256(fx.stage)}", stage_line)
        self.assertIn(pub.SOURCE_REPO, (fx.stage / "README.md").read_text())
        self.assertEqual((fx.snapshot / "README.md").read_text(), "TensorFold base card\n")
        self.assertEqual(shared.snapshot_manifest_sha256(fx.snapshot), fx.sha)
        for name in ("config.json", "model-00001-of-00048.safetensors"):
            self.assertEqual((fx.stage / name).read_bytes(), (fx.snapshot / name).read_bytes())

    def test_model_card_names_both_sources_revisions_and_license(self):
        fx = Fixture(self.root)
        prov, diff = pub.load_inputs(fx.results)
        card = pub.model_card(prov, diff)
        for text in (pub.BASE_REPO, pub.BASE_REVISION[:8], pub.SOURCE_REPO, pub.SOURCE_REVISION[:8],
                     "license: mit", "320 of 31,450", "max abs error 0.0", "at least 240 of 256"):
            self.assertIn(text, card)
        self.assertEqual((pub.BASE_REVISION[:8], pub.SOURCE_REVISION[:8]), ("d6be051a", "457210de"))

    def test_provenance_from_another_source_blocks(self):
        fx = Fixture(self.root)
        prov = provenance(fx.sha)
        prov["abliteration_source"]["revision"] = "0" * 40
        (fx.results / "provenance.json").write_text(json.dumps(prov))
        with self.assertRaises(SystemExit) as cm:
            fx.run("--dry-run")
        self.assertIn("provenance source", str(cm.exception))


class UploadAndVerifyTests(unittest.TestCase):
    """The shared remote check: every stage file must match the remote by size and sha256/blob id."""

    def api(self, stage: Path, tamper: str | None = None):
        siblings = [SimpleNamespace(rfilename=".gitattributes", size=1, lfs=None, blob_id="x")]
        for p in sorted(f for f in stage.rglob("*") if f.is_file()):
            rel, data = str(p.relative_to(stage)), p.read_bytes()
            sha = shared.file_sha256(p) if rel != tamper else "0" * 64
            siblings.append(SimpleNamespace(rfilename=rel, size=len(data), lfs=SimpleNamespace(sha256=sha), blob_id=None))
        return mock.Mock(model_info=mock.Mock(return_value=SimpleNamespace(siblings=siblings, sha="rev")))

    def test_matching_remote_passes_and_mismatch_blocks(self):
        with tempfile.TemporaryDirectory() as d:
            stage = Path(d)
            (stage / "a.safetensors").write_bytes(b"abc")
            (stage / "README.md").write_text("card")
            with mock.patch.object(shared.subprocess, "run") as run, contextlib.redirect_stdout(io.StringIO()):
                info = shared.upload_and_verify(self.api(stage), "o/r", stage, private=False, commit_message="m")
                self.assertEqual(info.sha, "rev")
                self.assertEqual(run.call_args[0][0][1:5], ["upload", "o/r", str(stage), "."])
                with self.assertRaises(SystemExit) as cm:
                    shared.upload_and_verify(self.api(stage, tamper="a.safetensors"), "o/r", stage,
                                             private=False, commit_message="m")
            self.assertIn("mismatched=['a.safetensors']", str(cm.exception))


class JobWiringTests(unittest.TestCase):
    def test_publish_phase_is_opt_in_after_job_pass(self):
        text = JOB.read_text()
        self.assertEqual(subprocess.run(["bash", "-n", str(JOB)]).returncode, 0)
        self.assertLess(text.index('log "JOB_PASS"'), text.index('if [ "${DSV4_PUBLISH:-0}" = 1 ]'))
        self.assertIn('--expect-stage "$EXPECT"', text)
        self.assertIn('["model_sha256"]', text)

    def test_job_blocks_bytecode_and_rechecks_the_artifact_before_pass(self):
        text = JOB.read_text()
        self.assertIn("export PYTHONDONTWRITEBYTECODE=1", text)
        recheck = text.index('[ "$(manifest "$ABL")" = "$ABL_SHA256" ]')
        self.assertNotIn('"$PY" -I ', text)
        self.assertIn('"$PY" -B -I "$JOB/dsv4/dsv4_reference_bench.py"', text)
        self.assertLess(text.index('find "$ABL" -name __pycache__'), recheck)
        self.assertLess(recheck, text.index('log "JOB_PASS"'))


if __name__ == "__main__":
    unittest.main()
