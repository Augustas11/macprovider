"""Unit tests for scripts/ops/lib/pearl-cli-config.py plan() (SPEC-002-R004)."""
import argparse
import datetime
import importlib.util
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / "ops" / "lib" / "pearl-cli-config.py"
spec = importlib.util.spec_from_file_location("pearl_cli_config_under_test", SCRIPT)
pcc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pcc)

SHA = "ab" * 20
TARGET = "test/repo:v1.8.232@%s" % SHA
NEW = "test/repo:v1.8.240@%s" % SHA
CONFIG = """coordinator:
  compatibility_set:
    target_id: %s
    accepted_ids:
    - %s
    revoked_ids:
    - test/repo:v1.8.235@%s
  require_gateway_context: true
coordinator_advertised_version:
  latest_binary_version: "1.8.232"
""" % (TARGET, TARGET, SHA)
NOW = datetime.datetime(2026, 10, 10, tzinfo=datetime.timezone.utc)


def args(**kw):
    base = dict(recommend=None, privacy_setup=None, revoke=None)
    base.update(kw)
    return argparse.Namespace(**base)


class RecommendTest(unittest.TestCase):
    def test_recommend_moves_only_target_and_latest(self):
        new, summary = pcc.plan(CONFIG, args(recommend=("1.8.240", NEW)), NOW)
        self.assertEqual(summary, {"target_id": NEW, "latest_binary_version": "1.8.240"})
        self.assertIn("target_id: %s" % NEW, new)
        self.assertIn("    - %s\n" % TARGET, new)  # deprecated accepted_ids untouched

    def test_recommend_refuses_foreign_revoked_and_malformed_targets(self):
        for target, why in (("other/repo:v1.8.240@%s" % SHA, "repository"),
                            ("test/repo:v1.8.235@%s" % SHA, "revoked_ids"),
                            ("test/repo:v1.8.0240@%s" % SHA, "malformed"),
                            ("test/repo:v9223372036854775808.0.0@%s" % SHA, "malformed"),
                            (NEW + "\n", "malformed")):
            with self.assertRaisesRegex(pcc.Refused, why):
                pcc.plan(CONFIG, args(recommend=("1.8.240", target)), NOW)



class RevokeTest(unittest.TestCase):
    OLD1 = "test/repo:v1.8.100@%s" % SHA
    OLD2 = "test/repo:v1.8.101@%s" % SHA

    def test_revoke_appends_exact_ids_once(self):
        new, summary = pcc.plan(CONFIG, args(revoke=[self.OLD1, self.OLD2, self.OLD1, "test/repo:v1.8.235@%s" % SHA]), NOW)
        self.assertEqual(summary["revoked_added"], [self.OLD1, self.OLD2])
        self.assertIn("    - test/repo:v1.8.235@%s\n    - %s\n    - %s\n" % (SHA, self.OLD1, self.OLD2), new)

    def test_revoke_creates_the_list_after_target(self):
        bare = CONFIG.replace("    revoked_ids:\n    - test/repo:v1.8.235@%s\n" % SHA, "")
        new, _ = pcc.plan(bare, args(revoke=[self.OLD1]), NOW)
        self.assertIn("    target_id: %s\n    revoked_ids:\n    - %s\n" % (TARGET, self.OLD1), new)

    def test_revoke_refuses_target_and_foreign_ids(self):
        for item in (TARGET, "other/repo:v1.8.100@%s" % SHA, "test/repo:v1.8.0100@%s" % SHA):
            with self.assertRaises(pcc.Refused):
                pcc.plan(CONFIG, args(revoke=[item]), NOW)

    def test_rollback_recommends_older_and_revokes_the_current_target(self):
        # SPEC-020-R007: one edit moves the target back and revokes the release
        # it moves off; the new target itself stays unrevocable.
        bad = "test/repo:v1.8.233@%s" % ("cd" * 20)
        config = CONFIG.replace(TARGET, bad, 1).replace('"1.8.232"', '"1.8.233"')
        new, summary = pcc.plan(config, args(recommend=("1.8.232", TARGET), revoke=[bad]), NOW)
        self.assertEqual(summary, {"target_id": TARGET, "latest_binary_version": "1.8.232", "revoked_added": [bad]})
        self.assertIn("    target_id: %s\n" % TARGET, new)
        self.assertIn("    - %s\n" % bad, new)
        with self.assertRaisesRegex(pcc.Refused, "refusing to revoke the target"):
            pcc.plan(config, args(recommend=("1.8.232", TARGET), revoke=[bad, TARGET]), NOW)
        with self.assertRaisesRegex(pcc.Refused, "refusing to revoke the target"):
            pcc.plan(config, args(revoke=[bad]), NOW)

    def test_checked_in_seed_is_consistent(self):
        script = pathlib.Path(__file__).resolve().parents[1] / "legacy-compatibility-revocations.py"
        out = subprocess.run([sys.executable, str(script), "check"], capture_output=True, text=True)
        self.assertEqual(out.returncode, 0, out.stderr)


VQ = {
    "provider_id": "prov-test-0001", "binary_version": "1.8.250", "hardware_chip": "Apple M2 Ultra",
    "ram_gb": 192, "max_context_tokens": 8192, "max_concurrency": 1,
    "model_id": "mlx-community/Qwen2-VL-2B-Instruct-4bit", "model_hash": "a" * 64,
    "model_hash_algorithm": "macprovider.snapshot-manifest.v1", "weights_manifest_sha256": "b" * 64,
    "processor_digest": "c" * 64, "runtime": "mlx_cache", "runtime_revision": "d" * 40,
    "media_profile": "qwen2vl-inline-v1", "qualification_digest": "e" * 64,
}


def vq(**kw):
    entry = dict(VQ)
    entry.update(kw)
    return entry


def vq_plan(text, entry=None):
    import yaml
    return pcc.vq_overlay_plan(text, yaml.safe_load(text) or {}, entry or dict(VQ))


class VisionQualificationRecordTest(unittest.TestCase):
    def test_valid_record_round_trips_canonically(self):
        self.assertEqual(pcc.vq_parse(pcc.vq_canonical(VQ)), VQ)
        self.assertEqual(pcc.vq_digest(VQ), pcc.vq_digest(dict(reversed(list(VQ.items())))))

    def test_yaml_record_is_accepted(self):
        text = "".join("%s: %s\n" % (k, v if isinstance(v, int) else '"%s"' % v) for k, v in VQ.items())
        self.assertEqual(pcc.vq_parse(text.encode()), VQ)

    def test_missing_and_unknown_fields_refused_without_values(self):
        entry = dict(VQ)
        del entry["processor_digest"]
        with self.assertRaisesRegex(pcc.Refused, "missing: processor_digest") as ctx:
            pcc.vq_validate(entry)
        self.assertNotIn("prov-test-0001", str(ctx.exception))
        with self.assertRaisesRegex(pcc.Refused, "unknown: 1"):
            pcc.vq_validate(vq(extra="x"))

    def test_bad_digests_types_and_tuple_refused(self):
        for entry, why in ((vq(qualification_digest="E" * 64), "qualification_digest must be a lowercase sha256"),
                           (vq(model_hash="a" * 63), "model_hash must be a lowercase sha256"),
                           (vq(processor_digest="sha256:" + "c" * 64), "processor_digest must be"),
                           (vq(ram_gb=0), "ram_gb must be a positive integer"),
                           (vq(max_concurrency=True), "max_concurrency must be a positive integer"),
                           (vq(max_context_tokens="8192"), "max_context_tokens must be a positive integer"),
                           (vq(provider_id=" "), "provider_id must be a non-blank"),
                           (vq(hardware_chip="M2\nx"), "hardware_chip must be a non-blank"),
                           (vq(model_id="mlx-community/Qwen2-VL-7B-Instruct-4bit"), "model_id must be"),
                           (vq(runtime="mlx"), "runtime must be mlx_cache"),
                           (vq(media_profile="other"), "media_profile must be"),
                           (vq(model_hash_algorithm="sha256"), "model_hash_algorithm must be")):
            with self.assertRaisesRegex(pcc.Refused, why):
                pcc.vq_validate(entry)

    def test_duplicate_keys_refused(self):
        raw = pcc.vq_canonical(VQ)[:-1] + b',"ram_gb":1}'
        with self.assertRaisesRegex(pcc.Refused, "duplicate"):
            pcc.vq_parse(raw)
        with self.assertRaisesRegex(pcc.Refused, "duplicate"):
            pcc.vq_parse(b"ram_gb: 1\nram_gb: 2\n")


class VisionQualificationOverlayTest(unittest.TestCase):
    def test_appends_routing_to_an_overlay_without_one(self):
        import yaml
        new = vq_plan("relay_blind:\n  enabled: true\n")
        self.assertEqual(yaml.safe_load(new), {"relay_blind": {"enabled": True},
                                               "routing": {"vision_qualifications": [VQ]}})
        self.assertTrue(new.startswith("relay_blind:\n  enabled: true\nrouting:\n"))
        self.assertEqual(yaml.safe_load(vq_plan("")), {"routing": {"vision_qualifications": [VQ]}})

    def test_inserts_into_an_existing_routing_mapping(self):
        import yaml
        text = "routing:  # operator\n    # keep\n    sticky_enabled: true\n    max_retries: 3\nother:\n  x: 1\n"
        new = vq_plan(text)
        self.assertEqual(yaml.safe_load(new), {"routing": {"sticky_enabled": True, "max_retries": 3,
                                                           "vision_qualifications": [VQ]}, "other": {"x": 1}})
        self.assertIn("    sticky_enabled: true\n    max_retries: 3\nother:\n  x: 1\n", new)

    def test_identical_entry_is_idempotent(self):
        once = vq_plan("routing:\n  sticky_enabled: true\n")
        self.assertEqual(vq_plan(once), once)

    def test_different_existing_list_refused(self):
        for text in (vq_plan("", vq(provider_id="other")),
                     "routing:\n  vision_qualifications: []\n",
                     vq_plan("") + "    extra: 1\n"):
            with self.assertRaisesRegex(pcc.Refused, "different routing.vision_qualifications"):
                vq_plan(text)

    def test_unsafe_overlay_shapes_refused(self):
        for text, why in (("routing: {sticky_enabled: true}\n", "anchor"),
                          ("routing: 3\n", "not a block mapping"),
                          ("{relay_blind: {enabled: true}}\n", "flow mapping"),
                          ("- a\n", "not a YAML mapping")):
            with self.assertRaisesRegex(pcc.Refused, why):
                vq_plan(text) if not text.startswith("- ") else pcc.vq_overlay_plan(text, {}, dict(VQ))


class VisionQualificationFileTest(unittest.TestCase):
    """The record and the staged copy are checked on the descriptor read."""

    def setUp(self):
        self.dir = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", self.dir])

    def write(self, name, data=None, mode=0o600, directory=None):
        path = os.path.join(directory or self.dir, name)
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
        os.write(fd, pcc.vq_canonical(VQ) if data is None else data)
        os.close(fd)
        os.chmod(path, mode)
        return path

    def test_private_record_is_read_and_validated(self):
        out = os.path.join(self.dir, "canonical.json")
        facts = pcc.validate_vq_file(self.write("r.json"), out)
        self.assertEqual(facts, {"fields": 15, "entry_sha256": pcc.vq_digest(VQ)})
        with open(out, "rb") as f:
            self.assertEqual(f.read(), pcc.vq_canonical(VQ))

    def test_unsafe_files_refused(self):
        target = self.write("target.json")
        link = os.path.join(self.dir, "link.json")
        os.symlink(target, link)
        hard = os.path.join(self.dir, "hard.json")
        os.link(target, hard)
        shared = os.path.join(self.dir, "shared")
        os.mkdir(shared)
        os.chmod(shared, 0o775)
        for path, why in ((link, "is a symlink"),
                          (hard, "regular file with one link"),
                          (self.write("open.json", mode=0o644), "must be mode 0600"),
                          (self.write("group.json", mode=0o640), "must be mode 0600"),
                          (self.write("big.json", b"x" * (pcc.VQ_MAX_BYTES + 1)), "larger than"),
                          (self.write("r.json", directory=shared), "not writable by group or others"),
                          (self.dir, "regular file")):
            with self.subTest(why=why), self.assertRaisesRegex(pcc.Refused, why):
                pcc.read_private_record(path, pcc.VQ_MAX_BYTES, "qualification record")

    def test_staged_record_must_match_and_be_private(self):
        staged = self.write("staged", pcc.vq_canonical(VQ))
        a = argparse.Namespace(vq_staged=staged, vq_sha256=pcc.vq_digest(VQ))
        self.assertEqual(pcc.read_vq_staged(a), VQ)
        os.chmod(staged, 0o644)
        with self.assertRaisesRegex(pcc.Refused, "must be mode 0600"):
            pcc.read_vq_staged(a)
        os.chmod(staged, 0o600)
        with self.assertRaisesRegex(pcc.Refused, "differs from the validated"):
            pcc.read_vq_staged(argparse.Namespace(vq_staged=staged, vq_sha256="0" * 64))
        link = os.path.join(self.dir, "staged-link")
        os.symlink(staged, link)
        with self.assertRaisesRegex(pcc.Refused, "is a symlink"):
            pcc.read_vq_staged(argparse.Namespace(vq_staged=link, vq_sha256=pcc.vq_digest(VQ)))


class VisionQualificationOverlayStateTest(unittest.TestCase):
    def test_valid_absent_and_invalid_live_entries(self):
        self.assertEqual(pcc.vq_overlay_state(None), {"overlay_entries_sha256": None, "overlay_entries_valid": None,
                                                      "overlay_invalid_reason": None})
        self.assertEqual(pcc.vq_overlay_state([dict(VQ)]),
                         {"overlay_entries_sha256": [pcc.vq_digest(VQ)], "overlay_entries_valid": True,
                          "overlay_invalid_reason": None})
        # The coordinator accepts a non-hex model_hash; the ops rules do not.
        state = pcc.vq_overlay_state([dict(VQ), vq(model_hash="z" * 64, provider_id="VQ-SECRET")])
        self.assertEqual(state["overlay_entries_sha256"], [pcc.vq_digest(VQ), "invalid"])
        self.assertIs(state["overlay_entries_valid"], False)
        self.assertIn("model_hash must be a lowercase sha256", state["overlay_invalid_reason"])
        self.assertNotIn("VQ-SECRET", json.dumps(state))
        self.assertEqual(pcc.vq_overlay_state(["x"])["overlay_entries_sha256"], ["invalid"])


class VisionQualificationParityTest(unittest.TestCase):
    """scripts/ops/testdata/vision-qualification-corpus.json is shared with
    phase4-coordinator/internal/config/vision_qualification_parity_test.go."""

    def test_ops_validator_matches_corpus_and_is_never_looser(self):
        corpus = json.loads((SCRIPT.parents[1] / "testdata" / "vision-qualification-corpus.json").read_text())
        names = [c["name"] for c in corpus["cases"]]
        self.assertEqual(len(names), len(set(names)))
        self.assertIn("non_hex_model_hash", names)
        for case in corpus["cases"]:
            with self.subTest(case=case["name"]):
                if case["ops_valid"]:
                    self.assertTrue(case["go_valid"], "the ops validator must never accept what the coordinator rejects")
                try:
                    pcc.vq_validate(case["record"])
                    ok = True
                except pcc.Refused:
                    ok = False
                self.assertEqual(ok, case["ops_valid"])


if __name__ == "__main__":
    unittest.main()
