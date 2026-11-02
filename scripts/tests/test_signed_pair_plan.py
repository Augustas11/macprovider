"""Offline signed-pair plan generator and checker; never SSH or hardware."""
import argparse
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / 'scripts/ops/lib/signed-pair-plan.py'


def load(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = load(TOOL, 'signed_pair_plan')
fixture = load(ROOT / 'scripts/tests/test_studio_pair.py', 'signed_pair_plan_studio_fixture')
RID = 'published-2026-11-02-test-r1'


class SignedPairPlanTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.static = self.root / 'phase3-binary/dist/static'
        self.autotune = self.root / 'phase3-binary/catalog/autotune'
        self.static.mkdir(parents=True)
        self.autotune.mkdir(parents=True)
        self.policy = dict(release_id=RID, entries=[
            dict(model_key='test/model', model_id='test-model', model_sha256='7' * 64, tuple_sha256='a' * 64),
            dict(model_key='test/model-base', model_id='test-model-base', model_sha256='8' * 64, tuple_sha256='b' * 64)])
        self.admission = dict(release_id=RID, entries=[
            dict(model_key='test/model', artifact_hash='7' * 64, decode_path_digest='d' * 64,
                 request_feature_profile='native_mtp_greedy_text_v1'),
            dict(model_key='test/model-base', artifact_hash='8' * 64, decode_path_digest='d' * 64,
                 request_feature_profile='native_mtp_greedy_text_v1')])
        self.projection = dict(models={'test/model': {}, 'test/model-base': {}})
        self.publish()
        for name in ('autotune-candidates', 'autotune-artifacts', 'native-mtp-selftest-bank', 'demand-rank', 'rate-card'):
            (self.static / (name + '.json')).write_text(json.dumps(dict(name=name)))
            (self.static / (name + '.json.sig')).write_text(name + ' signature')
        (self.autotune / 'release.json').write_text(json.dumps(dict(
            release_id=RID, feeds=['autotune-artifacts.json', 'native-mtp-admission.json'])))
        (self.autotune / 'trusted-keys.json').write_text('{}')
        (self.autotune / 'tier2-catalog.json').write_text('{}')
        template = fixture.plan()
        stage = '/private/signed-pair-test'
        template['studio']['journal_path'] = stage + '/journal.json'
        template['studio']['remote_actor_path'] = stage + '/actor.sh'
        template['studio']['capture_dir'] = stage + '/capture'
        template['target']['tarball_path'] = stage + '/target.tar.gz'
        self.template = self.write('template.json', template)

    def publish(self):
        for name, value in (('continuous-batching-policy.json', self.policy),
                            ('native-mtp-admission.json', self.admission),
                            ('native-mtp-artifact-manifest.json', self.projection)):
            (self.static / name).write_text(json.dumps(value))
        for name in ('continuous-batching-policy.json.sig', 'native-mtp-admission.json.sig'):
            (self.static / name).write_text(name)

    def write(self, name, value, mode=0o600):
        path = self.root / name
        path.write_text(json.dumps(value))
        path.chmod(mode)
        return path

    def build(self, out='plan.json', **overrides):
        values = dict(release_dir=str(self.static), autotune_dir=None, existing_release_ids=None,
                      template=str(self.template), model_key='test/model', model_sha256=None, model=None,
                      cb_tuple_sha256=None, previous_window_sha256='9' * 64, local_tarball=None,
                      binary_version=None, source_commit=None, cdhash=None, team_id=None,
                      signing_identifier=None, provenance=None, candidate_run_id=None,
                      acceptance_manifest_sha256=None, acceptance_signature_sha256=None,
                      checksums_sha256=None, deadline_seconds=3300, out=str(self.root / out))
        values.update(overrides)
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            tool.build(argparse.Namespace(**values))
        return self.root / out

    def check(self, plan, **kw):
        return [name for name, _ in tool.check(plan, self.static, **kw)]

    def edit(self, plan, change):
        value = json.loads(plan.read_text())
        change(value)
        plan.write_text(json.dumps(value))
        return plan

    def test_built_plan_passes_every_consumer_gate(self):
        plan = self.build()
        self.assertEqual(self.check(plan, expect_model_key='test/model'), [])
        value = json.loads(plan.read_text())
        self.assertEqual(os.stat(plan).st_mode & 0o777, 0o600)
        self.assertNotEqual(value['transaction_id'], 'test')
        self.assertTrue(value['studio']['journal_path'].startswith('/private/signed-pair-' + value['transaction_id'] + '/'))
        self.assertTrue(value['receipt_reader']['private_key_path'].endswith('signed-pair-%s.key' % value['transaction_id']))
        self.assertTrue(time.time() + 1800 <= value['deadline_epoch'] <= time.time() + 3600)
        target = value['target']
        self.assertEqual((target['catalog_release_id'], target['cb_tuple_sha256'], target['model_hash'], target['model']),
                         (RID, 'a' * 64, '7' * 64, 'test-model'))
        self.assertEqual(target['cb_policy_sha256'],
                         hashlib.sha256((self.static / 'continuous-batching-policy.json').read_bytes()).hexdigest())
        self.assertEqual(target['feed_sha256']['/v1/catalog-artifacts'],
                         hashlib.sha256((self.static / 'autotune-artifacts.json').read_bytes()).hexdigest())

    def test_build_never_overwrites_a_plan(self):
        self.build()
        with self.assertRaises(FileExistsError):
            self.build()

    def test_stale_cb_tuple_from_another_release_is_named(self):
        # 2026-11-02 pair5 carried the previous release's tuple and timed out on the Studio.
        plan = self.edit(self.build(), lambda v: v['target'].update(cb_tuple_sha256='c' * 64))
        failed = self.check(plan)
        self.assertIn('cb_tuple_sha256', failed)
        self.assertIn('root_intent_gate', failed)

    def test_stale_feed_digest_is_named_per_endpoint(self):
        plan = self.build()
        (self.static / 'autotune-candidates.json').write_text('{"name": "changed"}')
        self.assertEqual(self.check(plan), ['feed_sha256 /v1/autotune-candidates', 'root_intent_gate'])

    def test_admitted_model_missing_from_projection_is_named(self):
        # 2026-11-02 pair4: the native-MTP projection did not name every admitted model.
        plan = self.build()
        del self.projection['models']['test/model']
        self.publish()
        failed = self.check(plan)
        self.assertIn('model_in_projection', failed)
        self.assertIn('projection_covers_admission', failed)

    def test_target_absent_from_cb_policy_or_admission_is_named(self):
        plan = self.edit(self.build(), lambda v: v['target'].update(model_key='test/other'))
        failed = self.check(plan)
        self.assertIn('model_in_cb_policy', failed)
        self.assertIn('model_in_admission', failed)
        self.assertIn('model_in_projection', failed)

    def test_wrong_model_key_is_refused(self):
        # 2026-11-02: the plan targeted base GLM while the goal was the abliterated variant.
        plan = self.build(model_key='test/model-base')
        self.assertEqual(self.check(plan, expect_model_key='test/model'), ['expected_model_key'])
        self.assertEqual(self.check(plan, expect_model_key='test/model-base'), [])

    def test_existing_release_directory_is_refused(self):
        # 2026-11-02 pair6: releases/<id>-<sha16> already existed on Pearl.
        plan = self.build()
        dirname = tool.release_dirname(self.static, self.autotune)
        self.assertRegex(dirname, '^' + RID + '-[0-9a-f]{16}$')
        listing = self.root / 'pearl-releases.txt'
        listing.write_text('releases/other-0123456789abcdef\nreleases/%s\n' % dirname)
        names = tool.existing_names(str(listing))
        self.assertEqual(self.check(plan, existing=names), ['release_dir_unused'])
        self.assertEqual(self.check(plan, existing=tool.existing_names(RID + '-0123456789abcdef')), ['release_id_unused'])
        self.assertEqual(self.check(plan, existing=tool.existing_names('other-0123456789abcdef')), [])
        with self.assertRaises(tool.Failed):
            self.build(out='again.json', existing_release_ids=str(listing))
        # A mistyped or unmounted listing path fails closed instead of
        # becoming the one-name list {"pearl-releases-typo.txt"}.
        with self.assertRaises(tool.Failed):
            tool.existing_names(str(self.root / 'pearl-releases-typo.txt'))
        self.assertFalse((self.root / 'again.json').exists())

    def test_deadline_outside_arm_window_is_named(self):
        plan = self.build()
        for deadline in (int(time.time()) + 600, int(time.time()) + 72 * 3600, int(time.time()) - 10):
            self.edit(plan, lambda v: v.update(deadline_epoch=deadline))
            failed = self.check(plan)
            self.assertIn('deadline_window', failed)
        with self.assertRaises(tool.Failed):
            self.build(out='late.json', deadline_seconds=7200)

    def test_group_readable_plan_is_refused(self):
        plan = self.build()
        plan.chmod(0o644)
        self.assertIn('plan_mode_0600', self.check(plan))

    def test_new_binary_version_cannot_inherit_template_identity(self):
        with self.assertRaises(tool.Failed) as raised:
            self.build(binary_version='1.8.281')
        self.assertIn('source_commit', str(raised.exception))
        self.assertFalse((self.root / 'plan.json').exists())

    def test_ambiguous_cb_entries_need_an_explicit_tuple(self):
        self.policy['entries'].append(dict(model_key='test/model', model_id='test-model', model_sha256='7' * 64,
                                           tuple_sha256='e' * 64))
        self.publish()
        with self.assertRaises(tool.Failed):
            self.build()
        plan = self.build(cb_tuple_sha256='e' * 64)
        self.assertEqual(self.check(plan), [])

    def test_cli_prints_each_failed_check_and_exits_nonzero(self):
        plan = self.edit(self.build(), lambda v: v['target'].update(cb_tuple_sha256='c' * 64))
        result = subprocess.run([sys.executable, str(TOOL), 'check', '--plan', str(plan), '--release-dir', str(self.static),
                                 '--expect-model-key', 'test/model-abliterated'], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 1)
        self.assertIn('FAIL cb_tuple_sha256: plan ' + 'c' * 64 + ', policy tuples for test/model: ' + 'a' * 64, result.stderr)
        self.assertIn('FAIL expected_model_key:', result.stderr)
        self.assertIn('signed-pair plan check: 3 failed', result.stdout)


if __name__ == '__main__':
    unittest.main()
