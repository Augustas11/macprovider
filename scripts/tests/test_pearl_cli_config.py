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
        # A directory inside the private test dir: its parent passes the
        # parent-directory check on every platform (Linux /tmp is 1777).
        adir = os.path.join(self.dir, "adir")
        os.mkdir(adir, 0o700)
        for path, why in ((link, "is a symlink"),
                          (hard, "regular file with one link"),
                          (self.write("open.json", mode=0o644), "must be mode 0600"),
                          (self.write("group.json", mode=0o640), "must be mode 0600"),
                          (self.write("big.json", b"x" * (pcc.VQ_MAX_BYTES + 1)), "larger than"),
                          (self.write("r.json", directory=shared), "not writable by group or others"),
                          (adir, "regular file")):
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


class VisionQualificationApplyRollbackTest(unittest.TestCase):
    """Any failure once the edited overlay may be on disk restores the
    original bytes, proves them, and proves a recovery restart; a rollback
    that cannot be proven is refused as unproven state."""

    ORIGINAL = b"relay_blind:\n  enabled: true\n"

    def setUp(self):
        import contextlib
        import yaml
        from unittest import mock
        self.mock = mock
        self.dir = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", self.dir])
        self.overlay = os.path.join(self.dir, "overlay.yaml")
        with open(self.overlay, "wb") as f:
            f.write(self.ORIGINAL)
        staged = os.path.join(self.dir, "vq.staged")
        with open(staged, "wb") as f:
            f.write(pcc.vq_canonical(VQ))
        self.args = argparse.Namespace(
            vq_staged=staged, vq_sha256=pcc.vq_digest(VQ), overlay=self.overlay,
            config=os.path.join(self.dir, "config.yaml"), backup_root=os.path.join(self.dir, "backups"),
            unit="coordinator.service", healthz="http://127.0.0.1:1/healthz")
        self.new = vq_plan(self.ORIGINAL.decode()).encode()
        self.real_install = pcc.install
        self.installs = 0
        self.recovery = mock.Mock(return_value=subprocess.CompletedProcess([], 0))
        for name, value in (("guard", lambda a: contextlib.nullcontext()),
                            ("read_vq_staged", lambda a: dict(VQ)),
                            ("running", lambda a: (1, "/bin/coordinator", {}, os.getuid(), os.getgid())),
                            ("load_effective", lambda a: ({}, yaml.safe_load(self.ORIGINAL))),
                            ("as_service", lambda *a: subprocess.CompletedProcess([], 0)),
                            ("healthz", lambda url: {}),
                            ("applied", lambda a: True)):
            patcher = mock.patch.object(pcc, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(pcc.subprocess, "run", self.recovery)
        patcher.start()
        self.addCleanup(patcher.stop)

    def install(self, fail_on):
        """install(): the real os.replace, then the FAIL_ON-th call raises
        (after the replace when it is the edit, before it otherwise)."""
        def fake(tmp, path):
            self.installs += 1
            if self.installs == fail_on == 1:
                os.replace(tmp, path)
                raise OSError("directory fsync failed")
            if self.installs == fail_on:
                raise OSError("rollback write failed")
            self.real_install(tmp, path)
        patcher = self.mock.patch.object(pcc, "install", fake)
        patcher.start()
        self.addCleanup(patcher.stop)

    def overlay_bytes(self):
        with open(self.overlay, "rb") as f:
            return f.read()

    def leftovers(self):
        return sorted(n for n in os.listdir(self.dir) if n.startswith(".cli-release-"))

    def test_fsync_failure_after_replace_restores_and_recovers(self):
        self.install(fail_on=1)
        restart = self.mock.Mock()
        with self.mock.patch.object(pcc, "restart", restart):
            with self.assertRaisesRegex(pcc.Refused, "original overlay is restored \\(bytes verified\\) and a "
                                                     "recovery restart brought the coordinator back"):
                pcc.apply_vision_qualification(self.args)
        restart.assert_not_called()
        self.assertEqual(self.overlay_bytes(), self.ORIGINAL)
        self.assertEqual(self.recovery.call_args[0][0], ["systemctl", "restart", "coordinator.service"])
        self.assertEqual(self.leftovers(), [])
        self.assertFalse(os.path.lexists(self.args.vq_staged))

    def test_concurrent_overlay_change_is_preserved_not_overwritten(self):
        foreign = b"relay_blind:\n  enabled: false\n"
        def restart(args, pid):
            with open(self.overlay, "wb") as f:
                f.write(foreign)
            raise pcc.Refused("restart boom")
        with self.mock.patch.object(pcc, "restart", restart):
            with self.assertRaisesRegex(pcc.Refused, "overlay changed under the task") as cm:
                pcc.apply_vision_qualification(self.args)
        self.assertIn("UNPROVEN", str(cm.exception))
        self.assertEqual(self.overlay_bytes(), foreign)
        self.recovery.assert_not_called()

    def test_restart_and_rollback_write_failure_is_unproven(self):
        self.install(fail_on=2)
        with self.mock.patch.object(pcc, "restart", self.mock.Mock(side_effect=pcc.Refused("restart boom"))):
            with self.assertRaisesRegex(pcc.Refused, "restart boom.*restoring the original overlay failed "
                                                     "\\(OSError\\)") as cm:
                pcc.apply_vision_qualification(self.args)
        self.assertIn("UNPROVEN", str(cm.exception))
        self.assertIn(self.overlay, str(cm.exception))
        self.recovery.assert_not_called()
        self.assertEqual(self.overlay_bytes(), self.new)
        self.assertEqual(self.leftovers(), [])

    def test_recovery_restart_failure_is_unproven(self):
        self.install(fail_on=0)
        for setup in (lambda: setattr(self.recovery, "return_value", subprocess.CompletedProcess([], 1)),
                      lambda: setattr(self.recovery, "side_effect", FileNotFoundError("systemctl")),
                      self.failing_healthz):
            with self.subTest(setup=setup):
                with open(self.overlay, "wb") as f:
                    f.write(self.ORIGINAL)
                with open(self.args.vq_staged, "wb") as f:
                    f.write(pcc.vq_canonical(VQ))
                setup()
                with self.mock.patch.object(pcc, "restart", self.mock.Mock(side_effect=OSError("boom"))):
                    with self.assertRaisesRegex(pcc.Refused, "original overlay is restored on disk \\(bytes "
                                                             "verified\\) but the coordinator is not proven live"):
                        pcc.apply_vision_qualification(self.args)
                self.assertEqual(self.overlay_bytes(), self.ORIGINAL)

    def failing_healthz(self):
        self.recovery.side_effect = None
        self.recovery.return_value = subprocess.CompletedProcess([], 0)
        patcher = self.mock.patch.object(pcc, "healthz", side_effect=pcc.Refused("/healthz did not recover"))
        patcher.start()
        self.addCleanup(patcher.stop)


# --- stream-ceiling twin walls (SPEC-002 FR-P11a C2) ------------------------

REPO = pathlib.Path(__file__).resolve().parents[2]
SC_BASE = b"""# coordinator base
routing:
  preflight_timeout_s: 5
  # #760/#784 twin wall
  request_timeout_s: 900
  failover_enabled: true
provider_http:
  timeout_s: 900
"""
SC_OVERLAY = b"relay_blind:\n  enabled: true\n"
SC_GATEWAY = b"""timeouts:
  coordinator_request_seconds: 300
  coordinator_header_timeout_seconds: 960
  coordinator_admission_seconds: 120
  stream_ceiling_floor_seconds: 60
  stream_ceiling_max_seconds: 900
  non_stream_request_seconds: 960
  streaming_idle_ms: 10000
quotas:
  reservation_max_age_hours: 24
"""


def sc_docs(base=SC_BASE, overlay=SC_OVERLAY, gateway=SC_GATEWAY):
    import yaml
    return tuple(yaml.safe_load(b) or {} for b in (base, overlay, gateway))


class StreamCeilingPlanTest(unittest.TestCase):
    def test_pearl_posture_is_raised_and_passes_c2(self):
        import yaml
        coord, gw = pcc.sc_plan(*sc_docs())
        self.assertEqual(coord, {("routing", "request_timeout_s"): ("base", 900, 3600),
                                 ("provider_http", "timeout_s"): ("base", 900, 3600)})
        self.assertEqual(gw, {"stream_ceiling_max_seconds": (900, 3600), "non_stream_request_seconds": (960, 3660),
                              "coordinator_header_timeout_seconds": (960, 3660)})
        base, overlay, gateway = pcc.sc_render(SC_BASE, SC_OVERLAY, SC_GATEWAY, coord, gw)
        self.assertEqual(overlay, SC_OVERLAY)
        self.assertIn(b"  # #760/#784 twin wall\n  request_timeout_s: 3600\n", base)
        self.assertIn(b"  streaming_idle_ms: 10000\n", gateway)
        b, g = yaml.safe_load(base), yaml.safe_load(gateway)
        self.assertIsNone(pcc.sc_c2(b["routing"]["request_timeout_s"], b["provider_http"]["timeout_s"],
                                    pcc.sc_gateway_timeouts(g)))
        self.assertEqual(pcc.sc_plan(b, {}, g), ({}, {}))

    def test_today_posture_fails_c2_only_after_a_partial_raise(self):
        _, _, g = sc_docs()
        self.assertIsNone(pcc.sc_c2(900, 900, pcc.sc_gateway_timeouts(g)))
        self.assertIn("non_stream_request_seconds", pcc.sc_c2(3600, 3600, pcc.sc_gateway_timeouts(g)))

    def test_overlay_value_is_edited_where_it_is_set(self):
        overlay = b"routing:\n  request_timeout_s: 1200\n"
        coord, _ = pcc.sc_plan(*sc_docs(overlay=overlay))
        self.assertEqual(coord[("routing", "request_timeout_s")], ("overlay", 1200, 3600))
        base, new_overlay, _ = pcc.sc_render(SC_BASE, overlay, SC_GATEWAY, coord, {})
        self.assertEqual(new_overlay, b"routing:\n  request_timeout_s: 3600\n")
        self.assertIn(b"request_timeout_s: 900\n", base)

    def test_higher_live_walls_are_never_lowered(self):
        base = SC_BASE.replace(b"request_timeout_s: 900", b"request_timeout_s: 7200")
        gateway = SC_GATEWAY.replace(b"reservation_max_age_hours: 24", b"reservation_max_age_hours: 24")
        coord, gw = pcc.sc_plan(*sc_docs(base=base, gateway=gateway))
        self.assertNotIn(("routing", "request_timeout_s"), coord)
        self.assertEqual(gw["non_stream_request_seconds"], (960, 7201))
        self.assertEqual(gw["coordinator_header_timeout_seconds"], (960, 7201))

    def test_missing_keys_are_refused(self):
        with self.assertRaisesRegex(pcc.Refused, "provider_http.timeout_s is set in neither"):
            pcc.sc_plan(*sc_docs(base=b"routing:\n  request_timeout_s: 900\n"))
        with self.assertRaisesRegex(pcc.Refused, "non_stream_request_seconds is not set"):
            pcc.sc_plan(*sc_docs(gateway=SC_GATEWAY.replace(b"  non_stream_request_seconds: 960\n", b"")))
        with self.assertRaisesRegex(pcc.Refused, "non-negative integer"):
            pcc.sc_plan(*sc_docs(base=SC_BASE.replace(b"timeout_s: 900\n", b"timeout_s: true\n")))

    def test_short_reservation_window_fails_c2(self):
        _, _, g = sc_docs(gateway=SC_GATEWAY.replace(b"reservation_max_age_hours: 24", b"reservation_max_age_hours: 1"))
        self.assertIn("reservation_max_age_hours", pcc.sc_c2(3600, 3600, dict(pcc.sc_gateway_timeouts(g),
                      stream_ceiling_max_seconds=3600, non_stream_request_seconds=3660,
                      coordinator_header_timeout_seconds=3660)))

    def test_edit_that_touches_another_key_is_refused(self):
        text = "timeouts:\n  stream_ceiling_max_seconds: 900\n  nested:\n    stream_ceiling_max_seconds: 1\n"
        with self.assertRaisesRegex(pcc.Refused, "anchor|changed more"):
            pcc.sc_edit(text, "timeouts", {"stream_ceiling_max_seconds": 3600}, "gateway.yaml")

    def test_targets_match_the_tracked_configs(self):
        import yaml
        coord = yaml.safe_load((REPO / "phase4-coordinator/dist/coordinator.yaml").read_text())
        self.assertEqual(coord["routing"]["request_timeout_s"], pcc.SC_STREAM_CEILING)
        self.assertEqual(coord["provider_http"]["timeout_s"], pcc.SC_STREAM_CEILING)
        gateway = yaml.safe_load((REPO / "phase5-gateway/gateway.yaml.example").read_text())["timeouts"]
        self.assertEqual(gateway["stream_ceiling_max_seconds"], pcc.SC_STREAM_CEILING)
        self.assertEqual(gateway["non_stream_request_seconds"], pcc.SC_NON_STREAM_WALL)
        self.assertEqual(gateway["coordinator_header_timeout_seconds"], pcc.SC_NON_STREAM_WALL)
        self.assertIn("StreamCeilingMaxSeconds:     3600,",
                      (REPO / "phase5-gateway/internal/config/config.go").read_text())


class StreamCeilingApplyTest(unittest.TestCase):
    """The apply restarts the coordinator before the gateway, and any
    failure once edited bytes may be on disk restores all three files and
    restarts both services onto them."""

    def setUp(self):
        import contextlib
        from unittest import mock
        self.mock = mock
        self.dir = tempfile.mkdtemp()
        self.addCleanup(subprocess.run, ["rm", "-rf", self.dir])
        self.paths = {}
        for name, data in (("config", SC_BASE), ("overlay", SC_OVERLAY), ("gateway", SC_GATEWAY)):
            self.paths[name] = os.path.join(self.dir, name + ".yaml")
            with open(self.paths[name], "wb") as f:
                f.write(data)
        self.args = argparse.Namespace(
            config=self.paths["config"], overlay=self.paths["overlay"], gateway_config=self.paths["gateway"],
            backup_root=os.path.join(self.dir, "backups"), unit="coordinator.service",
            gateway_unit="gateway.service", healthz="http://127.0.0.1:1/healthz",
            gateway_healthz="http://127.0.0.1:2/healthz")
        self.events = []
        self.systemctl = mock.Mock(side_effect=self.fake_run)
        for name, value in (("guard", lambda a: contextlib.nullcontext()),
                            ("running", lambda a: (1, "/bin/coordinator", {}, os.getuid(), os.getgid())),
                            ("sc_running_gateway", lambda a: "7"),
                            ("as_service", lambda *a: subprocess.CompletedProcess([], 0)),
                            ("healthz", lambda url: {}),
                            ("applied", lambda a: True),
                            ("sc_gateway_applied", lambda a: True)):
            patcher = mock.patch.object(pcc, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = mock.patch.object(pcc.subprocess, "run", self.systemctl)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fake_run(self, cmd, *a, **kw):
        self.events.append(" ".join(cmd))
        return subprocess.CompletedProcess(cmd, 0)

    def read(self, name):
        with open(self.paths[name], "rb") as f:
            return f.read()

    def test_success_raises_both_files_and_restarts_coordinator_first(self):
        restarts = []
        with self.mock.patch.object(pcc, "restart", lambda a, pid: restarts.append("coordinator")), \
                self.mock.patch.object(pcc, "sc_restart_gateway", lambda a, pid: restarts.append("gateway")):
            pcc.apply_stream_ceiling(self.args)
        self.assertEqual(restarts, ["coordinator", "gateway"])
        self.assertIn(b"request_timeout_s: 3600", self.read("config"))
        self.assertEqual(self.read("overlay"), SC_OVERLAY)
        self.assertIn(b"stream_ceiling_max_seconds: 3600", self.read("gateway"))
        backups = os.listdir(self.args.backup_root)
        self.assertEqual(len(backups), 1)
        with open(os.path.join(self.args.backup_root, backups[0], "gateway.yaml"), "rb") as f:
            self.assertEqual(f.read(), SC_GATEWAY)
        self.assertEqual(sorted(n for n in os.listdir(self.dir) if n.startswith(".cli-release-")), [])

    def test_gateway_restart_failure_restores_files_and_restarts_both(self):
        with self.mock.patch.object(pcc, "restart", lambda a, pid: None), \
                self.mock.patch.object(pcc, "sc_restart_gateway", self.mock.Mock(side_effect=pcc.Refused("gw boom"))):
            with self.assertRaisesRegex(pcc.Refused, "gw boom.*original files are restored \\(bytes verified\\) "
                                                     "and both services were restarted"):
                pcc.apply_stream_ceiling(self.args)
        self.assertEqual((self.read("config"), self.read("overlay"), self.read("gateway")),
                         (SC_BASE, SC_OVERLAY, SC_GATEWAY))
        self.assertEqual(self.events, ["systemctl restart coordinator.service", "systemctl restart gateway.service"])

    def test_coordinator_recovery_failure_still_recovers_the_gateway(self):
        with self.mock.patch.object(pcc, "restart", lambda a, pid: None), \
                self.mock.patch.object(pcc, "sc_restart_gateway", self.mock.Mock(side_effect=pcc.Refused("gw boom"))), \
                self.mock.patch.object(pcc, "recovery_restart", self.mock.Mock(side_effect=pcc.Refused("coord down"))):
            with self.assertRaisesRegex(pcc.Refused, "recovery is UNPROVEN for coordinator: coord down"):
                pcc.apply_stream_ceiling(self.args)
        self.assertEqual(self.read("gateway"), SC_GATEWAY)
        self.assertEqual(self.events, ["systemctl restart gateway.service"])

    def test_gateway_restart_starts_after_the_config_second(self):
        import time
        os.utime(self.paths["gateway"])
        with self.mock.patch.object(pcc, "sc_running_gateway", lambda a: "8"), \
                self.mock.patch.object(pcc, "sc_gateway_applied", lambda a: True):
            pcc.sc_restart_gateway(self.args, "7")
        self.assertGreater(int(time.time()), int(os.stat(self.paths["gateway"]).st_ctime))

    def test_rejected_coordinator_config_changes_nothing(self):
        restart = self.mock.Mock()
        with self.mock.patch.object(pcc, "as_service", lambda *a: subprocess.CompletedProcess([], 1)), \
                self.mock.patch.object(pcc, "restart", restart):
            with self.assertRaisesRegex(pcc.Refused, "rejects the edited config"):
                pcc.apply_stream_ceiling(self.args)
        restart.assert_not_called()
        self.assertEqual((self.read("config"), self.read("gateway")), (SC_BASE, SC_GATEWAY))
        self.assertEqual(sorted(n for n in os.listdir(self.dir) if n.startswith(".cli-release-")), [])

    def test_concurrent_gateway_change_is_left_as_found(self):
        foreign = b"timeouts:\n  stream_ceiling_max_seconds: 1\n"
        def gateway_restart(args, pid):
            with open(self.paths["gateway"], "wb") as f:
                f.write(foreign)
            raise pcc.Refused("gw boom")
        with self.mock.patch.object(pcc, "restart", lambda a, pid: None), \
                self.mock.patch.object(pcc, "sc_restart_gateway", gateway_restart):
            with self.assertRaisesRegex(pcc.Refused, "UNPROVEN"):
                pcc.apply_stream_ceiling(self.args)
        self.assertEqual(self.read("gateway"), foreign)
        self.assertEqual(self.events, [])

    def test_walls_already_live_are_done_without_a_restart(self):
        with self.mock.patch.object(pcc, "restart", lambda a, pid: None), \
                self.mock.patch.object(pcc, "sc_restart_gateway", lambda a, pid: None):
            pcc.apply_stream_ceiling(self.args)
        restart, gw_restart = self.mock.Mock(), self.mock.Mock()
        with self.mock.patch.object(pcc, "restart", restart), \
                self.mock.patch.object(pcc, "sc_restart_gateway", gw_restart):
            pcc.apply_stream_ceiling(self.args)
        restart.assert_not_called()
        gw_restart.assert_not_called()


if __name__ == "__main__":
    unittest.main()
