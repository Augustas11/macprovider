"""Local contract smoke: execute named copy APIs, never SSH or hardware."""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / 'scripts/ops/catalog-activate.sh'
CONTENT = ROOT / 'scripts/catalog-content-release.sh'
PEARL = ROOT / 'scripts/lib/autotune-activate.sh'
SWAP = ROOT / 'scripts/ops/canary-swap.sh'


def block(path, tag):
    return re.split(r"<<'" + re.escape(tag) + r"'[^\n]*\n", path.read_text(), maxsplit=1)[1].split('\n' + tag, 1)[0]


def function(path, name):
    text = path.read_text()
    start = text.index(name + '() {')
    return text[start:text.index('\n}', start) + 2]


def studio_fixture():
    path = ROOT / 'scripts/tests/test_studio_pair.py'
    spec = importlib.util.spec_from_file_location('studio_contract_fixture', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class SignedPairInterfaceTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.fixture = studio_fixture()
        self.actor = self.fixture.engine()
        self.plan = self.fixture.plan()
        # Paths must satisfy the actual transport validator, not just actor mocks.
        stage = '/private/signed-pair-test'
        self.plan['studio']['journal_path'] = stage + '/journal.json'
        self.plan['studio']['remote_actor_path'] = stage + '/actor.sh'
        self.plan['target']['tarball_path'] = stage + '/target.tar.gz'
        self.plan_path = self.write('plan.json', self.plan)

    def write(self, name, value):
        path = self.root / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)
        return path

    def python(self, path, tag, *args):
        return subprocess.run([sys.executable, '-c', block(path, tag), *map(str, args)],
                              capture_output=True, text=True, timeout=5)

    def bash(self, source, *args):
        return subprocess.run(['/bin/bash', '-c', source, 'contract', *map(str, args)],
                              capture_output=True, text=True, timeout=5)

    def test_reader_metadata_binding_is_consumable_by_transport_and_actor(self):
        key = str(Path.home() / '.config/macprovider/operator-secrets/signed-pair-test-generated/receipt-reader')
        metadata = self.write('reader.json', dict(transaction_id='test', private_key_path=key,
                                                 public_key_path=key + '.pub', public_key_fingerprint='SHA256:fake'))
        resolved = self.root / 'resolved.json'
        result = self.python(CONTENT, 'PAIR_BIND', self.plan_path, metadata, resolved)
        self.assertEqual(result.returncode, 0, result.stderr)
        bound = json.loads(resolved.read_text())
        self.assertEqual(bound['receipt_reader']['local_private_key_path'], key)
        self.assertEqual(bound['receipt_reader']['private_key_path'], self.plan['receipt_reader']['private_key_path'])
        self.actor['validate'](bound)
        result = self.python(SWAP, 'PAIR_VALIDATE_PY', resolved, 'arm')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_durable_writer_feeds_actual_reconcile_reader_and_ack_reader(self):
        state = self.root / 'state'
        digest = hashlib.sha256(self.plan_path.read_bytes()).hexdigest()
        helper = '/tmp/macprovider-autotune-lock.TEST123'
        key = str(Path.home() / '.config/macprovider/operator-secrets/signed-pair-test-generated')
        result = self.python(CONTENT, 'PAIR_DURABLE', state, 'reader_ready', 'test', digest,
                             helper, key, self.plan_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.python(CATALOG, 'PAIR_STATE', state / 'controller-state.json', digest)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ['test', helper, helper + '/signed-pair-test', key])
        self.assertEqual(json.loads((state / 'resolved-plan.json').read_text()), self.plan)
        result = self.python(CONTENT, 'PAIR_DURABLE', state, 'terminal', 'test', digest,
                             helper, key, self.plan_path)
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.python(CATALOG, 'PAIR_ACK_CHECK', state, digest)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lock_release_hashes_plan_without_gather_local_release_id(self):
        # 2026-11-01: the EXIT-trap lock release ran signed_pair_plan_sha after
        # gather() returned, so "$R" was unbound under set -u.
        script = ('set -euo pipefail\n' + function(CATALOG, 'signed_pair_plan_sha') + '\n' +
                  'OPS_SCOPE="catalog-$1"; unset R; signed_pair_plan_sha\n')
        result = subprocess.run(['bash', '-c', script, 'test', self.plan['target']['catalog_release_id']],
                                env=dict(os.environ, CATALOG_SIGNED_PAIR_PLAN=str(self.plan_path)),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), hashlib.sha256(self.plan_path.read_bytes()).hexdigest())
        result = subprocess.run(['bash', '-c', script, 'test', 'another-release'],
                                env=dict(os.environ, CATALOG_SIGNED_PAIR_PLAN=str(self.plan_path)),
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)

    def test_acknowledged_transaction_does_not_shadow_a_new_plan(self):
        # 2026-11-01: a reconciled abl-mtp-v280-pair left terminal custody in the
        # release scope, so the retry plan (new transaction_id) was forced back
        # into reconcile. Custody is per transaction.
        common = ROOT / 'scripts/ops/lib/common.sh'
        script = ('set -euo pipefail\nOPS_NAME=t\n' + function(common, 'die') + '\n' + function(common, 'json_field') +
                  '\n' + function(CATALOG, 'signed_pair_state_dir') + '\nOPS_STATE_DIR=/s OPS_SCOPE=catalog-r\nsigned_pair_state_dir\n')
        def run(plan):
            env = dict(os.environ)
            env.pop('CATALOG_SIGNED_PAIR_PLAN', None)
            if plan:
                env['CATALOG_SIGNED_PAIR_PLAN'] = str(plan)
            result = subprocess.run(['bash', '-c', script], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()
        first = run(self.plan_path)
        self.plan['transaction_id'] = 'retry-2'
        second = run(self.write('plan2.json', self.plan))
        self.assertEqual(second, '/s/catalog-r/signed-native-pair/retry-2')
        self.assertNotEqual(first, second)
        self.assertEqual(run(None), '/s/catalog-r/signed-native-pair')

    def test_deadline_outside_studio_arm_window_refused_before_custody(self):
        import time
        def check(deadline):
            self.plan['deadline_epoch'] = deadline
            self.plan_path = self.write('plan.json', self.plan)
            status = subprocess.run(['bash', '-c', function(CATALOG, 'signed_pair_deadline_ok') + '\nsigned_pair_deadline_ok\n'],
                                    env=dict(os.environ, CATALOG_SIGNED_PAIR_PLAN=str(self.plan_path)),
                                    capture_output=True, text=True)
            prepare = self.python(CONTENT, 'PAIR_INTENT', self.plan_path, self.plan['target']['catalog_release_id'])
            return status.returncode == 0, prepare.returncode == 0, status.stdout
        now = int(time.time())
        self.assertEqual(check(now + 3300)[:2], (True, True))
        ok, armed, why = check(now + 72 * 3600)  # the abl-mtp-v280-pair plan
        self.assertEqual((ok, armed), (False, False))
        self.assertIn('outside [now+1800, now+3600]', why)
        self.assertEqual(check(now - 10)[:2], (False, False))
        self.assertFalse(check(now + 600)[0])

    def test_pending_ack_is_quiet_not_a_traceback(self):
        # 2026-11-01 pair2: the EXIT-trap lock check printed FileNotFoundError.
        state = self.root / 'state'
        digest = hashlib.sha256(self.plan_path.read_bytes()).hexdigest()
        self.python(CONTENT, 'PAIR_DURABLE', state, 'reader_ready', 'test', digest,
                    '/tmp/macprovider-autotune-lock.TEST123', '', self.plan_path)
        result = self.python(CATALOG, 'PAIR_ACK_CHECK', state, digest)
        self.assertEqual((result.returncode, result.stderr), (1, ''))

    def test_reconcile_drives_studio_rollback_after_pearl_decision(self):
        body = function(CATALOG, 'signed_pair_reconcile')
        self.assertLess(body.index('aa_signed_pair_reverify_blocked'), body.index('--action rollback'))
        self.assertLess(body.index('--action rollback'), body.index('aa_signed_pair_reader_retire'))

    def test_override_record_and_under_lock_publish_use_one_digest(self):
        # pair3 2026-11-01: the record and the under-lock check must agree on a
        # coverage that differs only in momentary routing eligibility.
        recorded = {'uncovered': [{'providers': 1, 'release_id': 'r', 'routing_eligible': 0, 'sha': 'f' * 64}], 'covered': []}
        live = {'uncovered': [{'providers': 1, 'release_id': 'r', 'routing_eligible': 1, 'sha': 'f' * 64}], 'covered': []}
        coverage = self.write('coverage.json', recorded)
        code = CONTENT.read_text().split('_override_out="$(python3 - ', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
        made = subprocess.run([sys.executable, '-c', code, 'reason', str(coverage), 'incoming', 'releases/live', 'live',
                               'c' * 40, str(ROOT / 'scripts')], capture_output=True, text=True, timeout=5)
        self.assertEqual(made.returncode, 0, made.stderr)
        line = [l for l in PEARL.read_text().splitlines() if l.startswith('  cov_digest=')][0]
        under = subprocess.run(['bash', '-c', 'window="$1"; cov_json="$2"\n' + line + '\nprintf %s "$cov_digest"',
                                'publish', ROOT / 'scripts/autotune_window.py', json.dumps(live)],
                               capture_output=True, text=True)
        self.assertEqual(under.stdout, made.stdout.splitlines()[0])

    def test_root_and_transport_transaction_id_domains_agree(self):
        # Every root-accepted ID must be transport-accepted before recovery custody.
        self.plan['transaction_id'] = 'a' * 81
        stage = '/private/signed-pair-' + self.plan['transaction_id']
        self.plan['studio']['journal_path'] = stage + '/journal.json'
        self.plan['studio']['remote_actor_path'] = stage + '/actor.sh'
        self.plan['target']['tarball_path'] = stage + '/target.tar.gz'
        self.plan_path = self.write('plan.json', self.plan)
        root = self.python(CATALOG, 'PAIR_PLAN', self.plan_path, self.plan['target']['catalog_release_id'])
        transport = self.python(SWAP, 'PAIR_VALIDATE_PY', self.plan_path, 'preflight')
        self.assertEqual(root.returncode == 0, transport.returncode == 0,
                         'root intent accepts transaction ID that transport refuses')

    def test_persisted_reader_intent_recovers_key_dir_for_both_root_readers(self):
        home = self.root / 'home'
        secrets = home / '.config/macprovider/operator-secrets'
        with patch.dict(os.environ, HOME=str(home)):
            result = self.python(PEARL, 'SECRET_PY', secrets, 'test')
            self.assertEqual(result.returncode, 0, result.stderr)
            key_dir = result.stdout.strip()
            cleanup = self.python(CONTENT, 'PAIR_KEY_INTENT', 'test')
            self.assertEqual(cleanup.returncode, 0, cleanup.stderr)
            self.assertEqual(cleanup.stdout.strip(), key_dir)
            state = self.root / 'unbound-state'
            digest = hashlib.sha256(self.plan_path.read_bytes()).hexdigest()
            result = self.python(CONTENT, 'PAIR_DURABLE', state, 'arming', 'test', digest,
                                 '/tmp/macprovider-autotune-lock.TEST123', '', self.plan_path)
            self.assertEqual(result.returncode, 0, result.stderr)
            reconcile = self.python(CATALOG, 'PAIR_STATE', state / 'controller-state.json', digest)
            self.assertEqual(reconcile.returncode, 0, reconcile.stderr)
            self.assertEqual(reconcile.stdout.splitlines()[-1], key_dir)

    def reader(self, phase):
        directory = self.root / phase
        directory.mkdir(mode=0o700)
        catalog = directory / 'catalog'
        for role in ('prior', 'target'):
            release = catalog / 'releases' / role
            release.mkdir(parents=True)
            (release / 'release.json').write_text(json.dumps(dict(release_id=self.plan[role]['catalog_release_id'])))
        (catalog / 'current').symlink_to('releases/target')
        (catalog / '.previous-target').write_bytes(b'releases/prior\n')
        journal = dict(txid='test', root=str(catalog), target_current='releases/target',
                       prior_release_id=self.plan['prior']['catalog_release_id'], prior_files={})
        def put(name, value):
            path = directory / name
            path.write_text(json.dumps(value)); path.chmod(0o600)
        put('journal.json', journal)
        # Use actual writer filename/URL mapping rather than test-specific values.
        mapping = {'native-mtp-admission.json': '/v1/native-mtp-admission',
                   'native-mtp-admission.json.sig': '/v1/native-mtp-admission.sig',
                   'native-mtp-selftest-bank.json': '/v1/native-mtp-selftest-bank',
                   'native-mtp-selftest-bank.json.sig': '/v1/native-mtp-selftest-bank.sig',
                   'native-mtp-artifact-manifest.json': '/v1/native-mtp-artifact-manifest',
                   'autotune-candidates.json': '/v1/autotune-candidates',
                   'autotune-candidates.json.sig': '/v1/autotune-candidates.sig',
                   'continuous-batching-policy.json': '/v1/continuous-batching-policy',
                   'continuous-batching-policy.json.sig': '/v1/continuous-batching-policy.sig',
                   'autotune-artifacts.json': '/v1/catalog-artifacts',
                   'autotune-artifacts.json.sig': '/v1/catalog-artifacts.sig'}
        put('committed', dict(txid='test', target_current='releases/target',
                             target_release_id=self.plan['target']['catalog_release_id'],
                             target_files={name: self.plan['target']['feed_sha256'][url] for name, url in mapping.items()}))
        output = io.StringIO()
        with patch.dict(os.environ, SSH_ORIGINAL_COMMAND=''), contextlib.redirect_stdout(output):
            exec(compile(block(PEARL, 'READER_PY'), 'actual-reader', 'exec'),
                 {'__file__': str(directory / 'receipt-reader.py')})
        return json.loads(output.getvalue())

    def test_actual_pearl_reader_commit_is_accepted_by_studio(self):
        value = self.reader('committed')
        self.actor['committed_receipt'](self.plan, value)
        self.assertEqual(value['policy_phase'], 'target_committed')
        self.assertEqual(value['target_feed_sha256'], self.plan['target']['feed_sha256'])

    def test_actual_recover_return_codes_drive_matching_studio_action(self):
        for committed, expected in ((False, 'rollback'), (True, 'commit')):
            source = '''set -u
WORK="$1"; AA_SIGNED_PAIR_GUARD_DIR=/tmp/guard/signed-pair-test; LOCK_HELPER_DIR=/tmp/guard
AA_LEASE_ROLLBACK_SECONDS=1; AA_LEASE_DIR="$WORK"; AA_LEASE_WATCHDOG_PID=''
SIGNED_PAIR_TXID=test; SIGNED_PAIR_ARMED=1; SIGNED_PAIR_STUDIO_ARMED=1; SIGNED_PAIR_TERMINAL=0
AA_SIGNED_PAIR_READER_KEY_DIR=/fake-known-key-dir
'''
            # SSH is a pure decision fixture; invoke the actual recovery API body.
            source += '\nSSH() { case "$1" in *"test -f"*"/committed"*) return ' + ('0' if committed else '1') + ';; *"test -f"*"/restored"*) return 0;; *) return 0;; esac; }\n'
            source += '''aa_signed_pair_runner_restore() { :; }
aa_signed_pair_runner_retire() { :; }
aa_signed_pair_reader_retire() { :; }
ccr_signed_pair_state() { :; }
ccr_signed_pair_action() { printf '%s\\n' "$1" >> "$WORK/actions"; }
'''
            source += function(PEARL, 'aa_signed_pair_recover') + '\n'
            source += function(CONTENT, 'ccr_signed_pair_cleanup') + '\nccr_signed_pair_cleanup\n'
            (self.root / 'actions').unlink(missing_ok=True)
            result = self.bash(source, self.root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((self.root / 'actions').read_text().splitlines(), [expected])


if __name__ == '__main__':
    unittest.main()
