import base64
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / 'lib/autotune-activate.sh'
CODE = SCRIPT.read_text().split("cat <<'GUARDIAN_PY'\n", 1)[1].split('\nGUARDIAN_PY', 1)[0]
NS = {'__name__': 'guardian_under_test'}
exec(compile(CODE, str(SCRIPT) + ':GUARDIAN_PY', 'exec'), NS)


class GuardianTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name) / 'journal'
        self.directory.mkdir()
        self.root = Path(self.tmp.name) / 'catalog'
        self.prior = self.root / 'releases/prior'
        self.prior.mkdir(parents=True)
        (self.prior / 'release.json').write_bytes(b'prior signed release')
        (self.directory / 'rollback.sh').write_text('# fixed reviewed script\n')
        (self.root / 'current').symlink_to('releases/prior')
        (self.root / '.previous-target').write_bytes(b'releases/before\n')
        self.record = {
            'schema': 'macprovider.signed-pair-pearl-recovery.v1',
            'root': str(self.root), 'prior_current': 'releases/prior',
            'holder_pid': 17, 'holder_start': '100', 'deadline': 0, 'deadline_monotonic': 0,
            'txid': 'test-pair', 'prior_release_id': 'prior-release',
            'prior_files': {'release.json': hashlib.sha256(b'prior signed release').hexdigest()},
            'rollback_sha256': hashlib.sha256((self.directory / 'rollback.sh').read_bytes()).hexdigest(),
            'rollback_args': [], 'recovery_seconds': 1,
            'prior_window_base64': base64.b64encode(b'releases/before\n').decode(),
        }
        for name in ('native-mtp-admission.json', 'native-mtp-selftest-bank.json'):
            (self.prior / name).write_bytes(name.encode())
            self.record['prior_files'][name] = hashlib.sha256(name.encode()).hexdigest()
        self.write_record()

    def write_record(self):
        (self.directory / 'journal.json').write_text(json.dumps(self.record))

    def invoke(self):
        with patch.object(NS['sys'], 'argv', ['guardian', str(self.directory)]), \
             patch.dict(NS, {'identity': lambda pid: None, 'fence': lambda record: None,
                             'locks_held': lambda: None, 'served': lambda record, deadline: None}), \
             patch.object(NS['subprocess'], 'Popen') as run:
            run.return_value.wait.return_value = 0
            NS['main']()
            return run

    def test_committed_never_executes_recovery(self):
        (self.directory / 'committed').touch()
        self.assertEqual(self.invoke().call_count, 0)
        self.assertFalse((self.directory / 'restored').exists())

    def test_prior_bytes_are_required_before_recovery(self):
        (self.prior / 'release.json').write_bytes(b'foreign changed bytes')
        with self.assertRaisesRegex(RuntimeError, 'prior signed release bytes changed'):
            self.invoke()
        self.assertFalse((self.directory / 'restored').exists())

    def test_reviewed_rollback_bytes_are_required(self):
        (self.directory / 'rollback.sh').write_text('foreign command')
        with self.assertRaisesRegex(RuntimeError, 'reviewed recovery script changed'):
            self.invoke()

    def test_exact_prior_pair_gets_disk_only_receipt(self):
        run = self.invoke()
        self.assertEqual(run.call_count, 1)
        self.assertEqual(run.call_args.kwargs['pass_fds'], (8, 9))
        receipt = json.loads((self.directory / 'restored').read_text())
        self.assertTrue(receipt['disk_restored'])
        self.assertTrue(receipt['served_policy_verified'])
        self.assertEqual(receipt['policy_phase'], 'prior_restored')
        self.assertEqual(receipt['txid'], 'test-pair')

    def test_foreign_current_never_claims_restoration(self):
        (self.root / 'current').unlink()
        (self.root / 'current').symlink_to('releases/foreign')
        with self.assertRaisesRegex(RuntimeError, 'prior current was not restored'):
            self.invoke()
        self.assertFalse((self.directory / 'restored').exists())

    def test_changed_window_never_claims_restoration(self):
        (self.root / '.previous-target').write_bytes(b'releases/foreign\n')
        with self.assertRaisesRegex(RuntimeError, 'prior window was not restored exactly'):
            self.invoke()

    def test_reused_holder_pid_is_never_killed(self):
        with patch.dict(NS, {'identity': lambda pid: 'new'}), patch.object(NS['os'], 'kill') as kill:
            NS['fence'](self.record)
            kill.assert_not_called()

    def test_changed_release_symlink_is_rejected(self):
        (self.prior / 'release.json').unlink()
        (self.prior / 'release.json').symlink_to(self.directory / 'rollback.sh')
        with self.assertRaises(OSError):
            self.invoke()

class ReceiptTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.reader = self.directory / 'receipt-reader.py'
        self.reader.write_text('placeholder')
        self.root = self.directory / 'catalog'
        (self.root / 'releases/prior').mkdir(parents=True)
        (self.root / 'releases/prior/release.json').write_text(json.dumps({'release_id': 'prior'}))
        (self.root / 'current').symlink_to('releases/prior')
        self.journal = {'txid': 'pair-a', 'prior_release_id': 'prior', 'target_current': 'releases/target',
                        'root': str(self.root), 'prior_files': {}}
        self.write('journal.json', self.journal)
        self.reader_code = SCRIPT.read_text().split("cat <<'READER_PY'\n", 1)[1].split('\nREADER_PY', 1)[0]

    def write(self, name, value):
        path = self.directory / name
        path.write_text(json.dumps(value))
        path.chmod(0o600)

    def read(self):
        import contextlib
        import io
        output = io.StringIO()
        with patch.dict(os.environ, {'SSH_ORIGINAL_COMMAND': ''}), contextlib.redirect_stdout(output):
            exec(compile(self.reader_code, 'receipt-reader.py', 'exec'), {'__file__': str(self.reader)})
        return json.loads(output.getvalue())

    def test_armed_reader_is_read_only(self):
        before = sorted(p.name for p in self.directory.iterdir())
        self.assertEqual(self.read()['policy_phase'], 'armed')
        self.assertEqual(before, sorted(p.name for p in self.directory.iterdir()))

    def test_target_reader_maps_only_fixed_endpoints(self):
        self.write('committed', {'txid': 'pair-a', 'target_current': 'releases/target',
                    'target_release_id': 'target', 'target_files': {'native-mtp-admission.json': 'a' * 64,
                                                                   'unserved-file': 'b' * 64}})
        receipt = self.read()
        self.assertEqual(receipt['transaction_id'], 'pair-a')
        self.assertEqual(receipt['policy_phase'], 'target_committed')
        self.assertEqual(receipt['target_feed_sha256'], {'/v1/native-mtp-admission': 'a' * 64})

    def test_prior_reader_proves_separate_prior_identity(self):
        self.write('restored', {'txid': 'pair-a', 'prior_release_id': 'prior',
                               'prior_files': {'native-mtp-selftest-bank.json': 'c' * 64}})
        receipt = self.read()
        self.assertEqual(receipt['policy_phase'], 'prior_restored')
        self.assertEqual(receipt['prior_feed_sha256'], {'/v1/native-mtp-selftest-bank': 'c' * 64})

    def test_other_transaction_commit_is_rejected(self):
        self.write('committed', {'txid': 'pair-b', 'target_current': 'releases/target'})
        with self.assertRaisesRegex(ValueError, 'commit identity mismatch'):
            self.read()

    def test_receipt_symlink_is_rejected(self):
        (self.directory / 'journal.json').rename(self.directory / 'real-journal')
        (self.directory / 'journal.json').symlink_to('real-journal')
        with self.assertRaises(OSError):
            self.read()

    def test_broad_receipt_permissions_are_rejected(self):
        (self.directory / 'journal.json').chmod(0o644)
        with self.assertRaisesRegex(ValueError, 'unsafe receipt'):
            self.read()

    def test_original_remote_command_is_rejected(self):
        with patch.dict(os.environ, {'SSH_ORIGINAL_COMMAND': 'cat /etc/passwd'}):
            with self.assertRaises(SystemExit):
                exec(compile(self.reader_code, 'receipt-reader.py', 'exec'), {'__file__': str(self.reader)})


class PolicyProofTests(unittest.TestCase):
    def proof(self, altered=False):
        import io
        import time
        import urllib.request
        record = {'prior_release_id': 'old', 'prior_files': {
            'native-mtp-admission.json': hashlib.sha256(b'admission').hexdigest(),
            'native-mtp-selftest-bank.json': hashlib.sha256(b'bank').hexdigest()}}
        bodies = {
            'http://127.0.0.1:8443/v1/autotune-release': json.dumps({'release_id': 'old', 'status': 'live_verified'}).encode(),
            'http://127.0.0.1:8443/v1/native-mtp-admission': b'wrong' if altered else b'admission',
            'http://127.0.0.1:8443/v1/native-mtp-selftest-bank': b'bank',
            'http://127.0.0.1:8444/healthz': json.dumps({'native_mtp_canary_bank_release_id': 'old',
                  'native_mtp_canary_bank_sha256': hashlib.sha256(b'bank').hexdigest()}).encode()}
        class Opener:
            def open(self, url, timeout):
                return io.BytesIO(bodies[url])
        with patch.object(urllib.request, 'build_opener', return_value=Opener()):
            NS['served'](record, time.monotonic() + .02)

    def test_exact_served_policy_and_loaded_bank_pass(self):
        self.proof()

    def test_wrong_served_policy_never_passes(self):
        with self.assertRaises(TimeoutError):
            self.proof(altered=True)

    def test_feed_rate_limit_is_waited_out_not_restarted(self):
        # Pearl 2026-11-01: 17 loopback reads per sweep against a 10/s burst-10
        # limiter never completed while each 429 restarted the sweep.
        import io
        import time
        import urllib.error
        import urllib.request
        names = ('autotune-candidates.json', 'autotune-candidates.json.sig', 'demand-rank.json',
                 'demand-rank.json.sig', 'rate-card.json', 'rate-card.json.sig',
                 'continuous-batching-policy.json', 'continuous-batching-policy.json.sig',
                 'autotune-artifacts.json', 'autotune-artifacts.json.sig', 'native-mtp-admission.json',
                 'native-mtp-admission.json.sig', 'native-mtp-artifact-manifest.json',
                 'native-mtp-selftest-bank.json', 'native-mtp-selftest-bank.json.sig')
        record = {'prior_release_id': 'old', 'prior_files': {n: hashlib.sha256(n.encode()).hexdigest() for n in names}}
        endpoint = dict((name, path) for name, path in [
            ('autotune-artifacts.json', 'catalog-artifacts'), ('autotune-artifacts.json.sig', 'catalog-artifacts.sig')])
        bodies = {'http://127.0.0.1:8443/v1/' + endpoint.get(n, n.replace('.json', '')): n.encode() for n in names}
        bodies['http://127.0.0.1:8443/v1/autotune-release'] = json.dumps({'release_id': 'old', 'status': 'live_verified'}).encode()
        bodies['http://127.0.0.1:8444/healthz'] = json.dumps({'native_mtp_canary_bank_release_id': 'old',
            'native_mtp_canary_bank_sha256': record['prior_files']['native-mtp-selftest-bank.json']}).encode()
        tokens = [10]
        class Limited:
            def open(self, url, timeout):
                if tokens[0] == 0:
                    tokens[0] = 10
                    raise urllib.error.HTTPError(url, 429, 'rate_limited', {'Retry-After': '0.1'}, None)
                tokens[0] -= 1
                return io.BytesIO(bodies[url])
        with patch.object(urllib.request, 'build_opener', return_value=Limited()):
            NS['served'](record, time.monotonic() + 5)

    def test_other_http_errors_still_fail_closed(self):
        import time
        import urllib.error
        import urllib.request
        class Missing:
            def open(self, url, timeout):
                raise urllib.error.HTTPError(url, 404, 'missing', {}, None)
        with patch.object(urllib.request, 'build_opener', return_value=Missing()):
            with self.assertRaises(TimeoutError):
                NS['served']({'prior_release_id': 'old', 'prior_files': {}}, time.monotonic() + .05)

    def test_fencing_stops_dispatch_before_killing_children(self):
        live = {17: 'owner-start', 18: 'child-start'}
        events = []
        def kill(pid, sig):
            events.append((pid, sig))
            if sig == NS['signal'].SIGKILL:
                live.pop(pid, None)
        with patch.dict(NS, {'identity': lambda pid: live.get(pid), 'descendants': lambda pid: [18]}), \
             patch.object(NS['os'], 'kill', side_effect=kill):
            NS['fence']({'holder_pid': 17, 'holder_start': 'owner-start'})
        self.assertEqual(events, [(17, NS['signal'].SIGSTOP), (18, NS['signal'].SIGKILL), (17, NS['signal'].SIGKILL)])


class CommitDecisionTests(unittest.TestCase):
    def setUp(self):
        import time
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p = Path(self.tmp.name)
        self.root = self.p / 'catalog'
        self.target = self.root / 'releases/target'
        self.target.mkdir(parents=True)
        (self.target / 'release.json').write_text(json.dumps({'release_id': 'target'}))
        (self.target / 'native-mtp-admission.json').write_bytes(b'target admission')
        (self.root / 'current').symlink_to('releases/target')
        (self.root / '.previous-target').write_bytes(b'releases/prior\n')
        self.files = {f.name: hashlib.sha256(f.read_bytes()).hexdigest() for f in self.target.iterdir()}
        self.record = {'txid': 'pair', 'root': str(self.root), 'target_current': 'releases/target',
                       'deadline_monotonic': time.monotonic() + 60}
        (self.p / 'journal.json').write_text(json.dumps(self.record))
        (self.p / 'ready.json').write_text(json.dumps({'pid': 123, 'start': 'start100'}))
        self.proof = {'txid': 'pair', 'target_current': 'releases/target', 'target_files': self.files,
                      'previous_window_sha256': hashlib.sha256(b'releases/prior\n').hexdigest()}
        (self.p / 'target_activation_verified').write_text(json.dumps(self.proof))
        self.code = SCRIPT.read_text().split("<<'COMMIT_PY'\n", 1)[1].split('\nCOMMIT_PY', 1)[0]

    def commit(self, active=True):
        import contextlib
        import io
        from types import SimpleNamespace
        real_read = Path.read_text
        def read(path, *args, **kwargs):
            if str(path) == '/proc/123/stat':
                fields = ['S'] + ['0'] * 18 + ['start100']
                return '123 (guardian) ' + ' '.join(fields)
            return real_read(path, *args, **kwargs)
        output = io.StringIO()
        with patch.object(NS['sys'], 'argv', ['commit', str(self.p), 'pair']), \
             patch.object(Path, 'read_text', read), \
             patch.object(NS['subprocess'], 'run', return_value=SimpleNamespace(stdout=b'active' if active else b'inactive')), \
             contextlib.redirect_stdout(output):
            scope = {'__name__': 'commit_under_test'}
            try:
                exec(compile(self.code, 'COMMIT_PY', 'exec'), scope)
            finally:
                if 'lock' in scope:
                    scope['lock'].close()
        return json.loads(output.getvalue())

    def test_exact_target_and_runner_make_durable_commit(self):
        receipt = self.commit()
        self.assertEqual(receipt['policy_phase'], 'target_committed')
        self.assertEqual(receipt, json.loads((self.p / 'committed').read_text()))
        self.assertEqual(receipt['target_files'], self.files)

    def test_commit_refuses_recovery_owned_decision(self):
        (self.p / 'recovering.json').touch()
        with self.assertRaisesRegex(RuntimeError, 'recovery already owns'):
            self.commit()
        self.assertFalse((self.p / 'committed').exists())

    def test_commit_refuses_stopped_runner(self):
        with self.assertRaisesRegex(RuntimeError, 'buyer runner not active'):
            self.commit(active=False)
        self.assertFalse((self.p / 'committed').exists())

    def test_commit_refuses_target_changed_since_served_proof(self):
        (self.target / 'native-mtp-admission.json').write_bytes(b'foreign policy')
        with self.assertRaisesRegex(RuntimeError, 'activation proof changed'):
            self.commit()
        self.assertFalse((self.p / 'committed').exists())

    def test_commit_refuses_expired_work_deadline(self):
        self.record['deadline_monotonic'] = 0
        (self.p / 'journal.json').write_text(json.dumps(self.record))
        with self.assertRaisesRegex(RuntimeError, 'work deadline reached'):
            self.commit()


class ReaderFailurePrefixTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.guard = self.base / 'guard'
        self.guard.mkdir(mode=0o700)
        self.ssh = self.base / 'ssh'
        self.ssh.mkdir(mode=0o700)
        self.auth = self.ssh / 'authorized_keys'
        self.old = b'ssh-ed25519 AAAA unrelated-key\n'
        self.auth.write_bytes(self.old)
        self.auth.chmod(0o600)
        (self.guard / 'journal.json').write_text(json.dumps({'txid': 'pair'}))
        (self.guard / 'restored').write_text('{}')
        self.pub = 'ssh-ed25519 AAAA macprovider-signed-pair-pair'
        self.source = SCRIPT.read_text()

    def fragment(self, tag):
        import re
        body = re.search(r"<<'" + tag + r"'\n(.*?)\n" + tag + r"\n", self.source, re.S).group(1)
        body = body.replace("pathlib.Path('/root/.ssh')", 'pathlib.Path(' + repr(str(self.ssh)) + ')')
        body = body.replace("pathlib.Path('/root/.ssh/authorized_keys')", 'pathlib.Path(' + repr(str(self.auth)) + ')')
        return body

    def invoke(self, tag, args, fail_auth_open=False, fail_after_append=False, fail_response=False):
        import contextlib
        import io
        real_open, real_fdopen, real_fstat, real_lstat = os.open, os.fdopen, os.fstat, Path.lstat
        def root_stat(st):
            values = list(st); values[4] = 0
            return os.stat_result(values)
        def lstat(path, *a, **kw):
            result = real_lstat(path, *a, **kw)
            return root_stat(result) if path == self.ssh else result
        def open_file(path, *a, **kw):
            if fail_auth_open and Path(path) == self.auth:
                raise PermissionError('injected authorization-open denial')
            return real_open(path, *a, **kw)
        class FailAfterWrite:
            def __init__(self, stream): self.stream = stream
            def __getattr__(self, name): return getattr(self.stream, name)
            def __enter__(self): return self
            def __exit__(self, *args): return self.stream.__exit__(*args)
            def write(self, data):
                self.stream.write(data)
                raise OSError('injected controller failure after authorization append')
        def fdopen(fd, mode='r', *a, **kw):
            stream = real_fdopen(fd, mode, *a, **kw)
            return FailAfterWrite(stream) if fail_after_append and mode == 'a+b' else stream
        class BadResponse(io.StringIO):
            def write(self, value): raise OSError('injected lost response')
        output = BadResponse() if fail_response else io.StringIO()
        with patch.object(NS['sys'], 'argv', [tag, *map(str,args)]), \
             patch.object(Path, 'lstat', lstat), \
             patch.object(os, 'open', side_effect=open_file), \
             patch.object(os, 'fdopen', side_effect=fdopen), \
             patch.object(os, 'fstat', side_effect=lambda fd: root_stat(real_fstat(fd))), \
             contextlib.redirect_stdout(output):
            try:
                exec(compile(self.fragment(tag), tag, 'exec'), {'__name__':'failure_prefix_test'})
            except SystemExit as stopped:
                if stopped.code not in (None,0): raise

    def install(self, **kwargs):
        self.invoke('INSTALL_PY', [self.guard, 'pair', self.pub, base64.b64encode(b'print("reader")\n').decode()], **kwargs)

    def retire(self):
        self.invoke('READER_RETIRE_PY', [self.guard, 'pair', 'unused-helper'])

    def test_authorization_open_failure_has_durable_intent_and_safe_retirement(self):
        with self.assertRaises(PermissionError):
            self.install(fail_auth_open=True)
        self.assertTrue((self.guard / 'authorized-key-line').exists())
        self.assertEqual(self.auth.read_bytes(), self.old)
        self.retire()
        self.assertEqual(self.auth.read_bytes(), self.old)

    def test_append_then_controller_failure_removes_only_owned_key(self):
        with self.assertRaises(OSError):
            self.install(fail_after_append=True)
        self.assertIn(self.pub.encode(), self.auth.read_bytes())
        self.assertFalse((self.guard / 'reader-installed').exists())
        self.retire()
        self.assertEqual(self.auth.read_bytes(), self.old)

    def test_lost_install_response_does_not_orphan_authorization(self):
        with self.assertRaises(OSError):
            self.install(fail_response=True)
        self.assertTrue((self.guard / 'reader-installed').exists())
        self.retire()
        self.assertEqual(self.auth.read_bytes(), self.old)

    def test_retirement_retry_is_idempotent(self):
        self.install()
        self.retire()
        self.retire()
        self.assertEqual(self.auth.read_bytes(), self.old)

    def test_missing_authorization_intent_before_install_is_safe(self):
        self.retire()
        self.retire()
        self.assertEqual(self.auth.read_bytes(), self.old)

    def test_installed_reader_missing_intent_is_not_silently_retired(self):
        self.install()
        (self.guard / 'authorized-key-line').unlink()
        with self.assertRaisesRegex(RuntimeError, 'lost authorization intent'):
            self.retire()
        self.assertIn(self.pub.encode(), self.auth.read_bytes())

    def test_keygen_prefix_intent_survives_without_any_key_material(self):
        store = self.base / 'secret-store'
        self.invoke('SECRET_PY', [store, 'pair'])
        intent = store / 'signed-pair-pair.intent.json'
        record = json.loads(intent.read_text())
        key_dir = Path(record['key_dir'])
        self.assertEqual(list(key_dir.iterdir()), [])
        self.invoke('SECRET_RETIRE', [store,key_dir,'pair'])
        self.assertFalse(key_dir.exists())
        self.assertFalse(intent.exists())
        self.invoke('SECRET_RETIRE', [store,key_dir,'pair'])


class RunnerRetirementTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p=Path(self.tmp.name)
        (self.p/'journal.json').write_text(json.dumps({'txid':'pair'}))
        (self.p/'committed').write_text('{}')
        self.code=SCRIPT.read_text().split("<<'RETIRE_PY'\n",1)[1].split('\nRETIRE_PY',1)[0]

    def retire(self,timer_active=False):
        from types import SimpleNamespace
        def run(args,**kwargs):
            timer=args[-1].endswith('.timer')
            return SimpleNamespace(returncode=0 if not timer or timer_active else 3, stdout=b'active' if not timer or timer_active else b'inactive')
        with patch.object(NS['sys'],'argv',['retire',str(self.p),'pair']),patch.object(NS['subprocess'],'run',side_effect=run):
            try:exec(compile(self.code,'RETIRE_PY','exec'),{'__name__':'runner_retirement_test'})
            except SystemExit as stopped:
                if stopped.code not in (None,0):raise

    def test_retirement_retry_with_active_runner_and_inactive_timer_passes(self):
        self.retire()
        self.retire()
        self.assertEqual(json.loads((self.p/'runner-retired').read_text()),{'transaction_id':'pair','runner_active':True})

    def test_foreign_retirement_receipt_is_rejected(self):
        (self.p/'runner-retired').write_text(json.dumps({'transaction_id':'other','runner_active':True}))
        with self.assertRaisesRegex(RuntimeError,'foreign runner retirement receipt'):self.retire()

    def test_retired_timer_reactivated_is_rejected(self):
        self.retire()
        with self.assertRaisesRegex(RuntimeError,'became active again'):self.retire(timer_active=True)


class RunnerRecoveryTests(unittest.TestCase):
    def setUp(self):
        import ast
        self.tmp=tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.p=Path(self.tmp.name)/'signed-pair-pair';self.p.mkdir()
        arm=SCRIPT.read_text().split("<<'ARM_PY'\n",1)[1].split('\nARM_PY',1)[0]
        tree=ast.parse(arm)
        self.code=next(ast.literal_eval(node.value) for node in tree.body if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='runner_code' for t in node.targets))

    def recover(self,active=True):
        from types import SimpleNamespace
        result=SimpleNamespace(returncode=0,stdout=b'active' if active else b'inactive')
        with patch.object(NS['sys'],'argv',['runner',str(self.p)]),patch.object(NS['subprocess'],'run',return_value=result):
            exec(compile(self.code,'runner-recover.py','exec'),{'__name__':'runner_recovery_test'})

    def test_repeated_restore_revalidates_service_without_rewriting_receipt(self):
        self.recover();receipt=self.p/'runner-restored';inode=receipt.stat().st_ino
        self.recover()
        self.assertEqual(receipt.stat().st_ino,inode)
        self.assertEqual(json.loads(receipt.read_text()),{'transaction_id':'pair','runner_active':True})

    def test_foreign_receipt_is_rejected(self):
        receipt=self.p/'runner-restored';receipt.write_text(json.dumps({'transaction_id':'other','runner_active':True}));receipt.chmod(0o600)
        with self.assertRaisesRegex(RuntimeError,'foreign runner recovery receipt'):self.recover()

    def test_old_receipt_does_not_hide_inactive_runner(self):
        self.recover()
        with self.assertRaisesRegex(RuntimeError,'did not become active'):self.recover(active=False)


class SourceContractTests(unittest.TestCase):
    def test_every_embedded_python_fragment_compiles(self):
        import re
        source = SCRIPT.read_text()
        tags = ['GUARDIAN_PY', 'ARM_PY', 'COMMIT_PY', 'RETIRE_PY', 'READER_PY',
                'SECRET_PY', 'INSTALL_PY', 'READER_META', 'READER_RETIRE_PY',
                'SECRET_RETIRE', 'RUNNER_STOP_PY', 'RUNNER_RESTORE_PY', 'VERIFIED_PY']
        for tag in tags:
            match = re.search(r"<<'" + tag + r"'\n(.*?)\n" + tag + r"\n", source, re.S)
            self.assertIsNotNone(match, tag)
            compile(match.group(1), tag, 'exec')


if __name__ == '__main__':
    unittest.main()


class BlockedGuardianReverifyTests(unittest.TestCase):
    """aa_signed_pair_reverify_blocked: reconcile after a blocked guardian."""
    CODE = SCRIPT.read_text().split("<<'REVERIFY_PY'\n", 1)[1].split('\nREVERIFY_PY', 1)[0]

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        base = Path(self.tmp.name)
        self.p = base / 'signed-pair-pair'
        self.p.mkdir()
        self.root = base / 'catalog'
        prior = self.root / 'releases/prior'
        prior.mkdir(parents=True)
        files = {}
        for name in ('release.json', 'native-mtp-admission.json', 'native-mtp-selftest-bank.json'):
            (prior / name).write_bytes(name.encode())
            files[name] = hashlib.sha256(name.encode()).hexdigest()
        (self.root / 'current').symlink_to('releases/prior')
        (self.root / '.previous-target').write_bytes(b'releases/before\n')
        self.locks = {path: base / Path(path).name for path in
                      ('/run/lock/macprovider-pearl-updater.lock', '/opt/macprovider/.coordinator-deploy.lock')}
        for lock in self.locks.values():
            lock.touch()
        self.record = {'schema': 'macprovider.signed-pair-pearl-recovery.v1', 'txid': 'pair', 'root': str(self.root),
                       'prior_current': 'releases/prior', 'prior_release_id': 'old', 'prior_files': files,
                       'prior_window_base64': base64.b64encode(b'releases/before\n').decode()}
        (self.p / 'journal.json').write_text(json.dumps(self.record))
        (self.p / 'ready.json').write_text(json.dumps({'pid': 2 ** 31 - 2, 'start': '1'}))
        (self.p / 'recovering.json').write_text(json.dumps({'txid': 'pair', 'policy_phase': 'restoring_prior'}))
        (self.p / 'blocked.json').write_text(json.dumps({'error_type': 'TimeoutError'}))

    def reverify(self):
        import io
        import urllib.request
        bodies = {'http://127.0.0.1:8443/v1/autotune-release': json.dumps({'release_id': 'old', 'status': 'live_verified'}).encode(),
                  'http://127.0.0.1:8443/v1/native-mtp-admission': b'native-mtp-admission.json',
                  'http://127.0.0.1:8443/v1/native-mtp-selftest-bank': b'native-mtp-selftest-bank.json',
                  'http://127.0.0.1:8444/healthz': json.dumps({'native_mtp_canary_bank_release_id': 'old',
                      'native_mtp_canary_bank_sha256': self.record['prior_files']['native-mtp-selftest-bank.json']}).encode()}
        class Opener:
            def open(self, url, timeout):
                return io.BytesIO(bodies[url])
        real_open = os.open
        guardian = base64.b64encode(CODE.encode()).decode()
        with patch.object(os, 'open', side_effect=lambda path, *a, **k: real_open(str(self.locks.get(str(path), path)), *a, **k)), \
             patch.object(urllib.request, 'build_opener', return_value=Opener()), \
             patch('sys.argv', ['reverify', str(self.p), 'pair', guardian]):
            exec(compile(self.CODE, 'reverify', 'exec'), {'__name__': '__main__'})

    def test_restored_disk_and_served_prior_get_receipt(self):
        self.reverify()
        receipt = json.loads((self.p / 'restored').read_text())
        self.assertEqual(receipt['policy_phase'], 'prior_restored')
        self.assertEqual(receipt['prior_release_id'], 'old')
        self.assertEqual(receipt['recovery'], 'reconcile_reverified_blocked_guardian')

    def test_commit_is_never_overridden(self):
        (self.p / 'committed').write_text('{}')
        with self.assertRaises(SystemExit) as stop:
            self.reverify()
        self.assertEqual(stop.exception.code, 0)
        self.assertFalse((self.p / 'restored').exists())

    def test_running_guardian_is_not_preempted(self):
        (self.p / 'blocked.json').unlink()
        with self.assertRaisesRegex(RuntimeError, 'has not blocked'):
            self.reverify()
        self.assertFalse((self.p / 'restored').exists())

    def test_target_still_current_never_claims_prior(self):
        (self.root / 'current').unlink()
        (self.root / 'current').symlink_to('releases/target')
        with self.assertRaisesRegex(RuntimeError, 'prior current was not restored'):
            self.reverify()
        self.assertFalse((self.p / 'restored').exists())

    def test_changed_prior_bytes_never_claim_prior(self):
        (self.root / 'releases/prior/release.json').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, 'prior signed release bytes changed'):
            self.reverify()
        self.assertFalse((self.p / 'restored').exists())
