import base64
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('studio_journey_copy', ROOT / 'scripts/ops/studio-mtp-measurement.py')
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

class JourneyControllerTests(unittest.TestCase):
    def fixture(self):
        rows=[]
        for name in ('catalog.json','catalog.json.sig','artifact-feed.json','artifact-feed.json.sig',
                     'native-mtp-admission.json','native-mtp-admission.json.sig'):
            data=name.encode()
            rows.append(dict(path=name,sha256=mod.sha(data),base64=base64.b64encode(data).decode()))
        inventory=json.dumps(dict(schema='macprovider.native-mtp-journey-signed-inputs.v1',files=rows)).encode()
        policy={key:'x' for key in mod.JOURNEY_KEYS}
        policy.update(schema='macprovider.native-mtp-journey-policy.v1',model_id=mod.MODEL,provider_commit='a'*40,
            hw_model='Mac15,14',quantization='4bit',cache_mode='paged_kv_mixed',qualified_slots=4,
            max_native_active_rows=1,max_prompt_tokens=4096,proposal_depth=1)
        for key in ('target_sha256','mtp_sha256','tokenizer_sha256','metallib_sha256','decode_path_digest'):
            policy[key]='b'*64
        policy['signed_inputs_sha256']=mod.sha(inventory)
        return policy,inventory
    def test_closed_journey_cells(self):
        self.assertEqual(mod.JOURNEY_CELLS,tuple('journey-'+s for s in mod.JOURNEY_STEPS)+('journey-all',))
        p,i=self.fixture()
        self.assertEqual(mod.journey_inputs(json.dumps(p).encode(),i,'a'*40)[0],p)
    def test_changed_or_extra_policy_refused(self):
        for change in ({'extra':1},{'qualified_slots':True},{'max_native_active_rows':2},{'provider_commit':'c'*40}):
            p,i=self.fixture();p.update(change)
            with self.assertRaises(mod.Refusal): mod.journey_inputs(json.dumps(p).encode(),i,'a'*40)
    def test_missing_changed_duplicate_escape_or_unknown_inventory_refused(self):
        for mutate in (lambda v:v['files'].pop(),lambda v:v['files'][0].update(sha256='0'*64),
                       lambda v:v['files'].append(v['files'][0]),lambda v:v['files'][0].update(path='../bad'),
                       lambda v:v['files'][0].update(extra=True)):
            p,i=self.fixture();v=json.loads(i);mutate(v);i=json.dumps(v).encode();p['signed_inputs_sha256']=mod.sha(i)
            with self.assertRaises(mod.Refusal):mod.journey_inputs(json.dumps(p).encode(),i,'a'*40)
    def test_delivery_preserves_exact_inventory_and_files(self):
        p,i=self.fixture()
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);(d/'policy.json').write_text(json.dumps(p))
            mod.deliver_journey(dict(commit='a'*40,signed_inputs_code=base64.b64encode(i).decode()),d)
            self.assertEqual((d/'signed-inputs/signed-inputs-inventory.json').read_bytes(),i)
            self.assertEqual((d/'signed-inputs/catalog.json').read_bytes(),b'catalog.json')
            self.assertEqual((d/'signed-inputs/catalog.json').stat().st_mode & 0o777,0o600)
            with self.assertRaises(FileExistsError):mod.deliver_journey(dict(commit='a'*40,signed_inputs_code=base64.b64encode(i).decode()),d)
    def test_commands_only_select_closed_steps_and_signed_inputs(self):
        m=dict(source='/source',commit='a'*40,dir='/private',cell='journey-08')
        command=mod.bench_command(m,Path('/private'))
        self.assertEqual(command[1],'native-mtp-journey-e2e')
        self.assertEqual(command[-2:],['--journey-step','08'])
        self.assertIn('--signed-admission-inputs',command)
        self.assertIn('--journey-requests',command)
        m['cell']='journey-all';command=mod.bench_command(m,Path('/private'))
        self.assertEqual(command[-14:],[a for s in mod.JOURNEY_STEPS for a in ('--journey-step',s)])
        self.assertEqual(mod.fixed_command(m,'cell')[2],'_journey')
    def test_legacy_acceptance_and_perf_command_unchanged(self):
        m=dict(source='/source',commit='a'*40,dir='/private',cell='acceptance')
        command=mod.bench_command(m,Path('/private'))
        self.assertIn('--acceptance-corpus',command);self.assertNotIn('--journey-policy',command)
        m['cell']='s1-p512-o128';command=mod.bench_command(m,Path('/private'))
        self.assertEqual(command[1],'native-mtp-bench');self.assertNotIn('--signed-admission-inputs',command)
    def test_actual_failed_incomplete_or_wrong_inventory_result_refused(self):
        for updates in ({'executed_steps_status':'fail'},{'journey_complete':True},{'signed_policy_inputs':False},
                        {'requested_steps':['09']},{'request_inventory_sha256':'0'*64},{'steps':[]}):
            with tempfile.TemporaryDirectory() as tmp:
                d=Path(tmp);policy,_=self.fixture();policy_bytes=json.dumps(policy).encode();(d/'policy.json').write_bytes(policy_bytes);(d/'journey-requests.json').write_bytes(b'requests')
                m=dict(source='/source',commit='a'*40,dir=tmp,cell='journey-08',policy_sha256=mod.sha(policy_bytes),requests_sha256=mod.sha(b'requests'))
                value=dict(executed_steps_status='pass',journey_complete=False,signed_policy_inputs=True,requested_steps=['08'],
                    request_inventory_sha256=m['requests_sha256'],lab_binary_release_candidate=False,
                    steps=[dict(step_id=mod.JOURNEY_RAW_IDS['08'],status='pass',uncovered_contract=[])])
                value.update({k:policy[k] for k in ('model_id','target_sha256','mtp_sha256','tokenizer_sha256','qualified_slots','max_native_active_rows','max_prompt_tokens')})
                value.update(lab_decode_path_digest=policy['decode_path_digest'],lab_metallib_sha256=policy['metallib_sha256'])
                value.update(updates)
                def fake(*args,**kwargs):
                    kwargs['stdout'].write(json.dumps(value).encode())
                    return type('Result',(),{'returncode':0})()
                with patch.object(mod.subprocess,'run',side_effect=fake):
                    with self.assertRaises(mod.Refusal):mod.run_journey(m)
    def test_no_shell_no_inference_in_preflight_and_original_restoration_retained(self):
        text=(ROOT/'scripts/ops/studio-mtp-measurement.py').read_text()
        preflight=text[text.index('def preflight_remote'):text.index('def acceptance_summary_ok')]
        self.assertIn('--freeze-journey-requests',preflight)
        self.assertNotIn('grouped(',preflight)
        self.assertIn('control(m, "pause_request")',text)
        self.assertIn('finally:\n        # Controller restores Pearl immediately',text)
        self.assertIn('        restore(m)',text)
        self.assertNotIn('shell=True',text)

if __name__=='__main__':unittest.main()
