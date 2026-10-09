import base64
import contextlib
import datetime as dt
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import yaml

MODULE = Path(__file__).resolve().parents[1] / 'ops/lib/privacy-activation.py'
spec = importlib.util.spec_from_file_location('privacy_activation', MODULE)
activation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(activation)


class PrivacyActivationTests(unittest.TestCase):
    def release(self, **changes):
        identity = {k: v for k, v in activation.IDENTITY.items() if k != 'code_cdhash'}
        identity['slices'] = [dict(arch='arm64', code_cdhash=activation.IDENTITY['code_cdhash'])]
        identity.update(changes)
        return base64.b64encode(json.dumps(dict(tag='v1.8.224', provider_code_identity=identity)).encode()).decode()

    def test_exact_release(self):
        activation.check_release(self.release())

    def test_other_release_rejected(self):
        for change in [dict(binary_version='1.8.225'), dict(team_id='OTHER'),
                       dict(signing_identifier='other'), dict(slices=[]),
                       dict(slices=[dict(arch='arm64', code_cdhash='0' * 40)])]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                activation.check_release(self.release(**change))

    def test_approval_has_no_expiry(self):
        entry = dict(activation.IDENTITY)
        self.assertTrue(activation.approved(dict(approved_code_identities=[entry])))
        # A leftover dated approval is replaced by the next approve step.
        entry['expires_at'] = dt.datetime(2026, 10, 20, tzinfo=dt.timezone.utc)
        self.assertFalse(activation.approved(dict(approved_code_identities=[entry])))

    def test_edit_preserves_other_bytes_and_overrides(self):
        before = 'unrelated: value # exact\n\nprivacy_class:\n  enabled: true\n  provider_se_public_keys: {a: pin}\n\nrelay_blind:\n  enabled: true # retain\n'
        pc = yaml.safe_load(before)['privacy_class']
        pc['approved_code_identities'] = [dict(activation.IDENTITY)]
        after = activation.replace_privacy(before, pc)
        self.assertTrue(after.startswith('unrelated: value # exact\n\n'))
        self.assertTrue(after.endswith('relay_blind:\n  enabled: true # retain\n'))
        self.assertEqual(yaml.safe_load(after)['privacy_class'], pc)
        self.assertEqual(yaml.safe_load(after)['privacy_class']['provider_se_public_keys'], {'a': 'pin'})

    def test_duplicate_or_inline_blocks_refused(self):
        for before in ['privacy_class: {}\n', 'privacy_class:\n  enabled: true\nprivacy_class:\n  enabled: true\n']:
            with self.subTest(before=before), self.assertRaises(ValueError):
                activation.replace_privacy(before, {})

    def test_atomic_install_preserves_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'coordinator.yaml'
            path.write_text('old')
            path.chmod(0o600)
            with patch.object(activation, 'BASE', path):
                activation.install('new')
            self.assertEqual(path.read_text(), 'new')
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(list(Path(directory).iterdir()), [path])

    def rollback_case(self, validation_error=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / 'coordinator.yaml'
            original = 'ordinary: unchanged\nprivacy_class:\n  enabled: true\n'
            path.write_text(original)
            pc = {'enabled': True}
            with patch.object(activation, 'BASE', path), \
                 patch.object(activation, 'preflight', return_value=pc), \
                 patch.object(activation, 'disabled', return_value=False), \
                 patch.object(activation, 'config_guard', return_value=contextlib.nullcontext()), \
                 patch.object(activation.tempfile, 'mkdtemp', return_value=directory), \
                 patch.object(activation.shutil, 'copy2'), \
                 patch.object(activation, 'install') as install, \
                 patch.object(activation, 'validate', side_effect=ValueError('invalid') if validation_error else None), \
                 patch.object(activation, 'restart_healthy', side_effect=[RuntimeError('unhealthy'), None]) as restart:
                with self.assertRaises((ValueError, RuntimeError)):
                    activation.apply(self.release())
                self.assertEqual(install.call_count, 2)
                self.assertEqual(install.call_args.args, (original,))
                self.assertEqual(restart.call_count, 0 if validation_error else 2)

    def test_validation_failure_restores_without_restart(self):
        self.rollback_case(validation_error=True)

    def test_failed_restart_restores_and_checks_recovery(self):
        self.rollback_case()

    def test_extra_approval_is_not_idempotent_success(self):
        entry = dict(activation.IDENTITY)
        other = dict(entry, binary_version='1.8.217')
        self.assertFalse(activation.approved({'approved_code_identities': [entry, other]}))

    def test_disabled_nested_gateway_features_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / 'base.yaml'
            overlay = root / 'overlay.yaml'
            gateway = root / 'gateway.yaml'
            base.write_text('privacy_class: {enabled: true}\nrelay_blind: {enabled: true}\n')
            overlay.write_text('{}')
            for feature in ('privacy_class', 'relay_blind_requests'):
                features = {'privacy_class': {'enabled': True}, 'relay_blind_requests': {'enabled': True}}
                features[feature]['enabled'] = False
                gateway.write_text(yaml.safe_dump({'features': features}))
                with patch.object(activation, 'BASE', base), patch.object(activation, 'OVERLAY', overlay), \
                     patch.object(activation, 'GATEWAY', gateway), patch.object(activation, 'runtime_provenance'), self.assertRaises(ValueError):
                    activation.preflight()

    def test_kill_switch_config_paths_are_live_paths(self):
        exact = [b'/opt/macprovider/coordinator', b'--config', bytes(activation.BASE),
                 b'--config-overlay', bytes(activation.OVERLAY)]
        activation.verify_config_paths(exact)
        for argv in [exact[:3], [*exact[:2], b'/tmp/alternate.yaml', *exact[3:]],
                     [*exact[:4], b'/tmp/alternate-overlay.yaml']]:
            with self.subTest(argv=argv), self.assertRaises(ValueError):
                activation.verify_config_paths(argv)

    def test_kill_switch_false_postcondition_is_failure(self):
        with patch.object(activation, 'runtime_provenance'), \
             patch.object(activation.subprocess, 'run'), patch.object(activation, 'disabled', return_value=False), self.assertRaises(RuntimeError):
            activation.disable_locked()


if __name__ == '__main__':
    unittest.main()
