"""Model-free mocks for the embedded actor; never launch SSH or hardware."""
import base64
import contextlib
import io
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / 'scripts/ops/lib/canary-swap-remote.sh'

def engine():
    source = SCRIPT.read_text().split("<<'SIGNED_PAIR_PY'\n", 1)[1].split('\nSIGNED_PAIR_PY', 1)[0]
    scope = {'__name__': 'signed_pair_test'}
    exec(compile(source, str(SCRIPT), 'exec'), scope)
    return scope


def plan():
    endpoints = ('native-mtp-admission', 'native-mtp-admission.sig', 'native-mtp-selftest-bank',
                 'native-mtp-selftest-bank.sig', 'native-mtp-artifact-manifest', 'autotune-candidates',
                 'autotune-candidates.sig', 'continuous-batching-policy', 'continuous-batching-policy.sig',
                 'catalog-artifacts', 'catalog-artifacts.sig')
    def identity(version):
        return dict(version=version, source_commit='a'*40, binary_sha256='b'*64,
                    tarball_sha256='c'*64, decode_path_digest='d'*64, cdhash='e'*40,
                    team_id='TEAM', signing_identifier='tech.malibu.provider',
                    provenance='reviewed_published_signed_release', catalog_release_id='release-'+version,
                    tarball_path='/private/signed-pair-test/target.tar.gz',
                    local_tarball_path='/private/released/target.tar.gz',
                    feed_sha256={'/v1/'+e: 'f'*64 for e in endpoints}, model='test-model',
                    model_key='test/model', request_feature_profile='native_mtp_greedy_text_v1', baked_catalog_release_id='release-1.8.272', previous_window_sha256='9'*64,
                    ordinary_context_tokens=8192,model_hash='7'*64,cb_policy_sha256='1'*64, cb_tuple_sha256='2'*64)
    return dict(schema_version='macprovider.signed_native_pair.v1', transaction_id='test',
                coordinator_url='https://coordinator.malibu.tech', deadline_epoch=2000000000,
                recovery_seconds=300, stable_seconds=120, provider_id_sha256=hashlib.sha256(b'provider').hexdigest(),
                prior=identity('1.8.272'), target=identity('1.8.274'),
                studio=dict(hardware_model='Mac15,14', host_name='Mac-Studio.local',status_port=8080,
                            launchd_label='live.malibu.provider', install_dir='/private/install',
                            config_path='/private/config', launchd_plist='/private/provider.plist',
                            ctl_socket='/private/ctl.sock', capture_dir='/private/capture',
                            journal_path='/private/signed-pair-test/journal.json',
                            remote_actor_path='/private/signed-pair-test/canary-swap-remote.sh'),
                receipt_reader=dict(host='pearl.example',user='pair-reader',port=22,
                                    server_host_key_alias='pair-pearl',
                                    private_key_path=str(Path.home()/'.config/macprovider/operator-secrets/signed-pair-test.key'),
                                    local_private_key_path=str(Path.home()/'.config/macprovider/operator-secrets/signed-pair-test.key'),
                                    known_hosts_path='/private/signed-pair-test/known_hosts',
                                    local_known_hosts_path='/private/known_hosts', known_hosts_sha256='a'*64))


def body(j, paused=False):
    i=j['target']
    return dict(binary_version=i['version'],model_loaded=True,provider_id='provider',model=i['model'],model_hash=i['model_hash'],
                native_mtp=dict(enabled=True,mode='eligible'),requests_in_flight=0,network_state='buyer_serving',
                lifecycle=dict(operator_paused=paused),capacity=dict(max_concurrency=4,max_context_tokens=8192),
                continuous_batching=dict(active=True,policy=dict(load_status='live_verified',authorized=True,
                    policy_sha256=i['cb_policy_sha256'],release_id=i['catalog_release_id'],tuple_sha256=i['cb_tuple_sha256']),
                    self_check=dict(served_slots=4),self_check_admission_hold=dict(active=False),scheduler=dict(slots_total=4)))


class Tests(unittest.TestCase):
    def setUp(self):
        self.e=engine(); self.j=plan()

    def candidate_plan(self):
        j=plan();j['target'].update(provenance='reviewed_signed_acceptance_candidate',candidate_run_id='123',acceptance_manifest_sha256='4'*64,acceptance_signature_sha256='5'*64,checksums_sha256='6'*64)
        return j

    def check_candidate_run(self, run=None, envelope=None):
        j=self.candidate_plan();repo='Augustas11/macprovider'
        valid_run=dict(id=123,event='workflow_dispatch',status='completed',conclusion='success',path='.github/workflows/acceptance-candidate.yml',head_branch='main',repository=dict(full_name=repo),head_sha='4'*40,run_attempt=2)
        valid_envelope=dict(candidate_ref='refs/heads/main',candidate_commit=j['target']['source_commit'],control_commit='4'*40,run_id='123',run_attempt=2,repository=repo,tag='v'+j['target']['version'],channel='acceptance')
        valid_run.update(run or {});valid_envelope.update(envelope or {})
        wrapper=(ROOT/'scripts/ops/canary-swap.sh').read_text()
        code=wrapper.split("<<'PAIR_CANDIDATE_RUN_PY'",1)[1].split('\n',1)[1].split('\nPAIR_CANDIDATE_RUN_PY',1)[0]
        with tempfile.TemporaryDirectory() as temp:
            paths=[]
            for name,value in (('run',valid_run),('envelope',valid_envelope),('plan',j)):
                path=Path(temp)/name;path.write_text(json.dumps(value));paths.append(str(path))
            import sys
            with patch.object(sys,'argv',['verify',*paths,repo]): exec(compile(code,'candidate-run-check','exec'),{})

    def test_signed_acceptance_candidate_schema_accepts_exact_run_evidence(self):
        self.e['validate'](self.candidate_plan())

    def test_prior_must_remain_published_signed(self):
        j=self.candidate_plan();j['prior'].update(j['target']);j['prior']['version']='1.8.272'
        with self.assertRaises(self.e['Refused']): self.e['validate'](j)

    def test_candidate_missing_envelope_identity_refused(self):
        j=self.candidate_plan();del j['target']['candidate_run_id']
        with self.assertRaises(KeyError): self.e['validate'](j)

    def test_reviewed_candidate_control_can_differ_from_source(self):
        self.check_candidate_run()

    def test_candidate_workflow_wrong_run_refused(self):
        with self.assertRaises(ValueError): self.check_candidate_run(run=dict(id=124))

    def test_candidate_workflow_wrong_branch_refused(self):
        with self.assertRaises(ValueError): self.check_candidate_run(run=dict(head_branch='feature'))

    def test_candidate_envelope_wrong_control_refused(self):
        with self.assertRaises(ValueError): self.check_candidate_run(envelope=dict(control_commit='0'*40))

    def test_candidate_envelope_wrong_source_refused(self):
        with self.assertRaises(ValueError): self.check_candidate_run(envelope=dict(candidate_commit='0'*40))

    def test_candidate_attempt_mismatch_refused(self):
        with self.assertRaises(ValueError): self.check_candidate_run(envelope=dict(run_attempt=1))

    def test_candidate_does_not_require_final_tag_or_publication(self):
        wrapper=(ROOT/'scripts/ops/canary-swap.sh').read_text()
        candidate=wrapper.split('      reviewed_signed_acceptance_candidate)',1)[1].split('      reviewed_published_signed_release)',1)[0]
        self.assertNotIn('gh release view',candidate)
        self.assertNotIn('refs/tags/',candidate)
        self.assertIn('acceptance-candidate-metadata.py" verify',candidate)
        self.assertIn('security/acceptance-candidate-signing-public.pem',candidate)
        self.assertIn('d.get("run_id", "")',candidate)
        self.assertIn('compatibility_set_id',candidate)

    def test_parser_validates_fixed_intent(self):
        self.e['validate'](self.j)

    def test_operator_mac_refused(self):
        self.j['studio']['hardware_model']='Mac17,3'
        with self.assertRaises(self.e['Refused']): self.e['validate'](self.j)

    def test_unreleased_target_refused(self):
        self.j['target']['provenance']='local_build'
        with self.assertRaises(self.e['Refused']): self.e['validate'](self.j)

    def test_missing_signature_identity_refused(self):
        del self.j['target']['feed_sha256']['/v1/native-mtp-admission.sig']
        with self.assertRaises(self.e['Refused']): self.e['validate'](self.j)

    def test_status_model_loaded_alone_never_ready(self):
        b=body(self.j,True);b['native_mtp']['enabled']=False
        with self.assertRaises(self.e['Refused']):
            self.e['readiness'](b,self.j['target'],self.j['provider_id_sha256'],True)

    def test_cb_four_slot_tuple_required(self):
        b=body(self.j,True);b['continuous_batching']['scheduler']['slots_total']=8
        with self.assertRaises(self.e['Refused']):
            self.e['readiness'](b,self.j['target'],self.j['provider_id_sha256'],True)

    def test_resume_before_explicit_readiness_refused(self):
        b=body(self.j,False)
        with self.assertRaises(self.e['Refused']):
            self.e['readiness'](b,self.j['target'],self.j['provider_id_sha256'],True)

    def test_ordinary_context_is_preserved(self):
        self.e['readiness'](body(self.j,True),self.j['target'],self.j['provider_id_sha256'],True)
        b=body(self.j,True);b['capacity']['max_context_tokens']=4096
        with self.assertRaises(self.e['Refused']):
            self.e['readiness'](b,self.j['target'],self.j['provider_id_sha256'],True)

    def test_control_ready_positive(self):
        self.e['readiness'](body(self.j,True),self.j['target'],self.j['provider_id_sha256'],True)

    def test_mismatched_commit_receipt_refused(self):
        r=dict(transaction_id='test',policy_phase='target_committed',target_release_id='wrong',target_feed_sha256=self.j['target']['feed_sha256'])
        with self.assertRaises(self.e['Refused']): self.e['committed_receipt'](self.j,r)

    def recovery(self, receipt, policy_error=None):
        directory=tempfile.TemporaryDirectory();self.addCleanup(directory.cleanup)
        p=Path(directory.name);os.chmod(p,0o700)
        raw=json.dumps(self.j).encode();journal=p/'journal.json';journal.write_bytes(raw);os.chmod(journal,0o600)
        state=dict(phase='commit_prepared',transaction_id='test',journal_sha256=hashlib.sha256(raw).hexdigest(),capture_started_epoch=1,capture_header_sha256='0'*64)
        self.e['put'](p/'studio-state.json',state)
        jobs=[]
        mocks=dict(host=lambda j:None,receipt=lambda j:receipt,
                   policy=Mock(side_effect=policy_error),status=lambda j:body(j),
                   stable=Mock(return_value=('123','start')),job=lambda j,op,watchdog=False:jobs.append((op,watchdog)))
        with patch.dict(self.e,mocks):
            try: self.e['main']('rollback',journal,str(SCRIPT))
            except self.e['Refused']:
                if policy_error is None: raise
        return json.loads((p/'studio-state.json').read_text()),jobs

    def test_controller_dies_after_pearl_commit_before_relay_recovers_target(self):
        r=dict(transaction_id='test',policy_phase='target_committed',target_release_id=self.j['target']['catalog_release_id'],target_feed_sha256=self.j['target']['feed_sha256'])
        state,jobs=self.recovery(r)
        self.assertEqual(state['phase'],'committed')
        self.assertEqual(state['recovery'],'authoritative_remote_target_commit')
        self.assertEqual(jobs,[('start',True)])

    def test_committed_target_policy_mismatch_isolates(self):
        r=dict(transaction_id='test',policy_phase='target_committed',target_release_id=self.j['target']['catalog_release_id'],target_feed_sha256=self.j['target']['feed_sha256'])
        state,jobs=self.recovery(r,self.e['Refused']('mismatch'))
        self.assertEqual(state['phase'],'blocked')
        self.assertEqual(jobs,[('stop',True),('stop',False)])

    def test_compatible_previous_requires_activation_receipt(self):
        decision=dict(current_release_id=self.j['target']['catalog_release_id'],window_source='retained_disk_under_lease',previous_window_sha256='9'*64,compatible_previous_release_ids=[self.j['prior']['catalog_release_id']],target_feed_sha256=self.j['target']['feed_sha256'],target_activation_verified=False)
        with patch.dict(self.e,receipt=lambda j:decision,policy=Mock()):
            with self.assertRaises(self.e['Refused']): self.e['compatible_pair'](self.j,self.j['target']['baked_catalog_release_id'])
            decision['target_activation_verified']=True
            self.e['compatible_pair'](self.j,self.j['target']['baked_catalog_release_id'])

    def test_compatible_previous_wrong_window_refused(self):
        decision=dict(current_release_id=self.j['target']['catalog_release_id'],window_source='retained_disk_under_lease',previous_window_sha256='0'*64,compatible_previous_release_ids=[self.j['prior']['catalog_release_id']],target_feed_sha256=self.j['target']['feed_sha256'],target_activation_verified=True)
        with patch.dict(self.e,receipt=lambda j:decision,policy=Mock()):
            with self.assertRaises(self.e['Refused']): self.e['compatible_pair'](self.j,self.j['target']['baked_catalog_release_id'])

    def test_compatible_baked_ledger_predecessor(self):
        j=self.j;j['target']['baked_catalog_release_id']='release-baked'
        decision=dict(current_release_id=j['target']['catalog_release_id'],window_source='retained_disk_under_lease',previous_window_sha256='9'*64,compatible_previous_release_ids=[j['prior']['catalog_release_id']],target_feed_sha256=j['target']['feed_sha256'],target_activation_verified=True)
        baked=dict(release_id='release-baked',generated_at='2026-11-01T05:00:00Z',policy_version='p1')
        def ledger():
            return dict(schema_version='macprovider.autotune-release-ledger.v4',tombstones={},releases={
                'release-baked':dict(generated_at='2026-11-01T05:00:00Z',policy_version='p1',native_mtp_admission_sha256='0'*64),
                j['target']['catalog_release_id']:dict(generated_at='2026-11-01T11:00:00Z',policy_version='p1',
                    native_mtp_admission_sha256=j['target']['feed_sha256']['/v1/native-mtp-admission'])})
        with tempfile.TemporaryDirectory() as temp, patch.dict(self.e,receipt=lambda j:decision,policy=Mock()):
            directory=Path(temp);j['studio']['journal_path']=str(directory/'journal.json')
            path=directory/'target-release-ledger.json'
            with self.assertRaises(self.e['Refused']): self.e['compatible_pair'](j,'release-baked')
            def put(value):
                path.write_text(json.dumps(value));os.chmod(path,0o600)
            put(ledger())
            self.e['compatible_pair'](j,'release-baked')
            self.e['compatible_pair'](j,'release-baked',baked)
            target=j['target']['catalog_release_id']
            bad=[]
            l=ledger();l['tombstones']['release-baked']={};bad.append((l,None))
            l=ledger();l['releases'][target]['native_mtp_admission_sha256']='1'*64;bad.append((l,None))
            l=ledger();l['releases']['release-baked']['generated_at']='2026-11-01T12:00:00Z';bad.append((l,None))
            l=ledger();l['releases']['release-baked']['policy_version']='p2';bad.append((l,None))
            l=ledger();l['schema_version']='macprovider.autotune-release-ledger.v3';bad.append((l,None))
            l=ledger();del l['releases'][target];bad.append((l,None))
            bad.append((ledger(),dict(baked,generated_at='2026-11-01T06:00:00Z')))
            for value,doc in bad:
                with self.subTest(value=value,doc=doc):
                    put(value)
                    with self.assertRaises(self.e['Refused']): self.e['compatible_pair'](j,'release-baked',doc)
            put(ledger())
            with self.assertRaises(self.e['Refused']): self.e['compatible_pair'](j,'release-other')
            os.chmod(path,0o644)
            with self.assertRaises(self.e['Refused']): self.e['compatible_pair'](j,'release-baked')

    def test_terminal_status_after_receipt_key_retirement(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);os.chmod(directory,0o700)
            raw=json.dumps(self.j).encode();path=directory/'journal.json';path.write_bytes(raw);os.chmod(path,0o600)
            self.e['put'](directory/'studio-state.json',dict(phase='committed',transaction_id='test',journal_sha256=hashlib.sha256(raw).hexdigest(),capture_started_epoch=1,capture_header_sha256='0'*64))
            output=io.StringIO()
            with patch.dict(self.e,host=lambda j:None,policy=Mock(),status=lambda j:body(j),signed_binary=Mock(),process_id=Mock(return_value=('123','start')),capture=Mock(),scoped_policy=Mock(),receipt=Mock(side_effect=AssertionError('must not read retired key'))):
                with contextlib.redirect_stdout(output): self.e['main']('status',path,str(SCRIPT))
            self.assertTrue(json.loads(output.getvalue())['terminal_ready'])

    def test_old_binary_never_starts_before_prior_public_policy(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);os.chmod(directory,0o700)
            raw=json.dumps(self.j).encode();path=directory/'journal.json';path.write_bytes(raw);os.chmod(path,0o600)
            self.e['put'](directory/'studio-state.json',dict(phase='prepared',transaction_id='test',journal_sha256=hashlib.sha256(raw).hexdigest(),pause_proven=True))
            decision=dict(transaction_id='test',policy_phase='prior_restored',prior_release_id=self.j['prior']['catalog_release_id'],prior_feed_sha256=self.j['prior']['feed_sha256'])
            jobs=[]
            import types
            clock=types.SimpleNamespace(time=Mock(side_effect=[0,400]),sleep=Mock())
            with patch.dict(self.e,host=lambda j:None,receipt=lambda j:decision,control=Mock(),status=lambda j:body(j,True),policy=Mock(side_effect=self.e['Refused']('not old')),job=lambda j,op,watchdog=False:jobs.append((op,watchdog)),time=clock):
                with self.assertRaises(self.e['Refused']): self.e['main']('rollback',path,str(SCRIPT))
            self.assertEqual(jobs,[('stop',True),('stop',False)])
            self.assertEqual(json.loads((directory/'studio-state.json').read_text())['phase'],'blocked')

    def test_initialized_capture_accepts_later_records_but_not_zero_proof(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);os.chmod(directory,0o700);self.j['studio']['capture_dir']=temp
            h=dict(schema='macprovider.native-mtp-request-shape-capture.v2',record_type='header',capture_requires_native_mtp_off=False,native_mtp_mode='auto',build_identity_complete=True,build_source_commit=self.j['target']['source_commit'],build_cdhash=self.j['target']['cdhash'],cli_version=self.j['target']['version'],max_records=1000,max_bytes=10485760)
            p=directory/'capture.jsonl';header=json.dumps(h).encode();raw=header+b'\n'+b'{"record_type":"request"}\n';p.write_bytes(raw);os.chmod(p,0o600)
            snapshot=dict(schema=h['schema'],record_type='status',build_identity_complete=True,jsonl_write_errors=0,status_write_errors=0,capture_file_name=p.name,max_records=1000,max_bytes=10485760,successful_records=1,attempts=1,jsonl_bytes_written=len(raw))
            sp=Path(str(p)+'.status.json');sp.write_text(json.dumps(snapshot));os.chmod(sp,0o600)
            self.j['capture_header_sha256']=hashlib.sha256(header).hexdigest()
            self.e['capture'](self.j,0)
            with self.assertRaises(self.e['Refused']): self.e['capture'](self.j,0,require_zero=True)
            journal=directory/'journal.json';raw_j=json.dumps(self.j).encode();journal.write_bytes(raw_j);os.chmod(journal,0o600)
            self.e['put'](directory/'studio-state.json',dict(phase='committed',transaction_id='test',journal_sha256=hashlib.sha256(raw_j).hexdigest(),capture_started_epoch=0,capture_header_sha256=self.j['capture_header_sha256']))
            output=io.StringIO()
            with patch.dict(self.e,host=Mock(),policy=Mock(),status=lambda j:body(j),signed_binary=Mock(),process_id=Mock(),scoped_policy=Mock(),receipt=Mock(side_effect=AssertionError('retired key'))):
                with contextlib.redirect_stdout(output): self.e['main']('status',journal,str(SCRIPT))
            self.assertTrue(json.loads(output.getvalue())['terminal_ready'])
            self.assertFalse((directory/'studio-action.lock').exists())

    def staged_status(self, directory, watchdog_rc=113):
        raw=json.dumps(self.j).encode();path=directory/'journal.json';path.write_bytes(raw);os.chmod(path,0o600)
        prior_body=body(self.j);prior_body['binary_version']=self.j['prior']['version'];prior_body['continuous_batching']['policy']['release_id']=self.j['prior']['catalog_release_id']
        prior_body['continuous_batching']['policy']['policy_sha256']=self.j['prior']['cb_policy_sha256'];prior_body['continuous_batching']['policy']['tuple_sha256']=self.j['prior']['cb_tuple_sha256']
        output=io.StringIO()
        with patch.dict(self.e,host=Mock(),policy=Mock(),status=Mock(return_value=prior_body),signed_binary=Mock(),process_id=Mock(),
                        run=Mock(return_value=Mock(returncode=watchdog_rc)),receipt=Mock(side_effect=AssertionError('no key read'))):
            with contextlib.redirect_stdout(output): self.e['main']('status',path,str(SCRIPT))
        return json.loads(output.getvalue())

    def test_refused_arm_before_first_studio_change_is_prior_terminal(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);os.chmod(directory,0o700)
            result=self.staged_status(directory)
            self.assertTrue(result['terminal_ready']);self.assertEqual(result['phase'],'prior_unchanged')
            self.assertFalse((directory/'studio-state.json').exists())

    def test_staged_with_watchdog_is_never_prior_terminal(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);os.chmod(directory,0o700)
            self.assertFalse(self.staged_status(directory,watchdog_rc=0)['terminal_ready'])
            (directory/'studio-watchdog-ready.json').write_text('{}')
            self.assertFalse(self.staged_status(directory)['terminal_ready'])

    def test_arm_outside_one_hour_window_refused_with_reason(self):
        with tempfile.TemporaryDirectory() as temp:
            directory=Path(temp);os.chmod(directory,0o700)
            self.j['deadline_epoch']=int(time.time())+72*3600
            path=directory/'journal.json';path.write_bytes(json.dumps(self.j).encode());os.chmod(path,0o600)
            with patch.dict(self.e,host=Mock(),receipt=Mock(side_effect=AssertionError('deadline precedes receipt'))):
                with self.assertRaisesRegex(self.e['Refused'],'^arm deadline$'): self.e['main']('arm',path,str(SCRIPT))
            self.assertFalse((directory/'studio-state.json').exists())

    def test_refusal_reason_is_printed(self):
        with tempfile.TemporaryDirectory() as temp:
            path=Path(temp)/'journal.json';path.write_bytes(json.dumps(self.j).encode());os.chmod(path,0o600)
            result=subprocess.run(['/bin/bash',str(SCRIPT),'signed-pair-engine','arm',str(path)],capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,6)
            self.assertRegex(result.stderr,r'signed-pair refused: Refused: (Studio requires macOS|hardware mismatch|host mismatch)')

    def test_no_stage_after_reader_failure_proves_exact_prior_unchanged(self):
        with tempfile.TemporaryDirectory() as temp:
            home=Path(temp);stage=home/'signed-pair-test'
            self.j['studio']['journal_path']=str(stage/'journal.json');self.j['studio']['remote_actor_path']=str(stage/'actor.sh')
            self.j['receipt_reader']['private_key_path']=str(home/'.config/macprovider/operator-secrets/signed-pair-test.key')
            prior_body=body(self.j);prior_body['binary_version']=self.j['prior']['version'];prior_body['continuous_batching']['policy']['release_id']=self.j['prior']['catalog_release_id']
            encoded=base64.b64encode(json.dumps(self.j).encode()).decode();output=io.StringIO()
            with patch.object(Path,'home',return_value=home):
                with patch.dict(self.e,host=Mock(),signed_binary=Mock(),policy=Mock(),status=Mock(return_value=prior_body),process_id=Mock(),scoped_policy=Mock(),receipt=Mock(side_effect=AssertionError('no key read'))):
                    with contextlib.redirect_stdout(output): self.e['status_unstaged'](encoded)
                    self.assertTrue(json.loads(output.getvalue())['terminal_ready'])
                    stage.mkdir();output=io.StringIO()
                    with contextlib.redirect_stdout(output): self.e['status_unstaged'](encoded)
                    self.assertFalse(json.loads(output.getvalue())['terminal_ready'])

    def test_ordinary_wrapper_modes_are_byte_unchanged(self):
        original=(Path.cwd()/'scripts/ops/canary-swap.sh').read_text()
        copy=(ROOT/'scripts/ops/canary-swap.sh').read_text()
        self.assertEqual(original.split('\nCMD="${1:-}"',1)[1],copy.split('\nCMD="${1:-}"',1)[1])

    def test_normal_modes_are_byte_unchanged(self):
        base=Path.cwd()/'scripts/ops/lib/canary-swap-remote.sh'
        self.assertEqual(SCRIPT.read_text().split('\nMODE=swap\n',1)[1],base.read_text().split('\nMODE=swap\n',1)[1])


if __name__=='__main__':
    unittest.main()
