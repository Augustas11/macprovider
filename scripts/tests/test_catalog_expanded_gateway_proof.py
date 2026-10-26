import copy
import json
from pathlib import Path
import sys
import subprocess
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
SHELL=(ROOT/'scripts/ops/catalog-activate.sh').read_text()
CODE=SHELL.split("  cat <<'PYEXPANDED'\n",1)[1].split('\nPYEXPANDED',1)[0]
proof=types.ModuleType('catalog_expanded_proof_copy');exec(compile(CODE,'embedded_gateway_proof.py','exec'),proof.__dict__)

class ExpandedProofTests(unittest.TestCase):
    def test_closed_shapes_all_facades_preserve_auto_tools_and_history(self):
        for family in proof.FAMILIES:
            for profile in proof.PROFILES:
                p=proof.shape(family,profile,'zai-org/glm-5.3-flash','nonce')
                self.assertIs(p['stream'],False)
                self.assertEqual(p['temperature'],1 if profile in ('sampled','tools') else 0)
                if profile in ('tools','history'):
                    self.assertEqual(len(p['tools']),1)
                    self.assertNotIn('required',str(p['tool_choice']))
                if profile=='history':self.assertIn('call_proof',str(p))
                if profile=='tools':self.assertIn('Call read_file now',str(p))
        with self.assertRaises(ValueError):proof.shape('proxy','tools','zai-org/glm-5.3-flash','x')
        with self.assertRaises(ValueError):proof.shape('chat','arbitrary','zai-org/glm-5.3-flash','x')
    def fixture(self,d,family='chat',profile='sampled'):
        before=dict(model='zai-org/glm-5.3-flash',requests_in_flight=0,requests_total=5,errors_total=0,
            safety_telemetry=dict(coordinator_session_id='session'),catalog=dict(release_id='release',digest='catalog'),
            continuous_batching=dict(active=True,scheduler=dict(shared_forward_calls=10)),
            native_mtp=dict(enabled=True,reset_generation=1,requests_since_reset=2,mtp_forwards=5,preoutput_fallbacks=0,postoutput_failures=0))
        after=copy.deepcopy(before);after['requests_total']+=1;after['native_mtp']['requests_since_reset']+=1;after['native_mtp']['mtp_forwards']+=4;after['continuous_batching']['scheduler']['shared_forward_calls']+=3
        capture=dict(custody_sha256='e'*64,header_sha256='h',file_identity=[1,2],sha256='prefix',status=dict(successful_records=4,attempts=4))
        row=dict(observed_effective_path='native_mtp',observed_selector_eligible=True,observed_selector_reason='eligible',
            served_model_family='glm5_next_mtp_v1',native_mtp_tuple_sha256='tuple',unknown_request_fields_present=False,conversation_key_present=False,
            sampling_requested=profile in ('sampled','tools'),requested_temperature=1 if profile in ('sampled','tools') else 0,
            requested_top_p=.95 if profile in ('sampled','tools') else 1,tool_count=1 if profile in ('tools','history') else 0,
            tool_turn_state_present=profile=='history',effective_reasoning_effort='high',stream=False,effective_max_output_tokens=256 if profile=='tools' else 64,tool_choice_kind='auto',tool_grammar_required=False,parallel_tool_calls_state='true',tool_message_count=1,assistant_tool_call_count=1,served_model_hash_sha256='a'*64,
            served_weights_manifest_sha256='b'*64,prompt_tokens=10,completion_tokens=20)
        ac=dict(custody_sha256='e'*64,header=dict(build_source_commit='c'*40,build_cdhash='d'*40),header_sha256='h',file_identity=[1,2],prefix_sha256='prefix',rows=[row],status=dict(successful_records=5,attempts=5))
        route=dict(external_request_id='rid',provider_assigned_id='session',status=200,retried=0,request_id='internal',prompt_tokens=10,completion_tokens=20)
        ledger=dict(request_id='internal',status=200,settled=1,quarantined=0,gross_credits=2,provider_credits=1,prompt_tokens=10,completion_tokens=20)
        verdict=dict(request_id='internal',closed=1,receipt_present=1,receipt_result='valid',settlement_outcome='verified')
        body=dict(usage=dict(prompt_tokens=10,completion_tokens=20),choices=[dict(message=dict(content='ok',tool_calls=[dict(function=dict(name='read_file',arguments='{"path":"example.swift"}'))]))])
        values={'before.json':before,'after.json':after,'capture-before.json':capture,'capture-after.json':ac,'routes.json':[route],'ledger.json':[ledger],'verdict.json':[verdict],'proof.json':body,'sidecar.json':dict(entries=[dict(model_key='zai-org/glm-5.3-flash')])}
        for path,v in values.items():(d/path).write_text(json.dumps(v))
        entry=dict(request_feature_profile='native_mtp_sampled_text_v1',source_commit='c'*40,live_executable_cdhash='d'*40,artifact_hash='a'*64)
        return values,types.SimpleNamespace(validated_sidecar_entry=lambda data,index:(entry,'tuple'))
    def validate(self,d,module,profile='sampled'):
        with patch.dict(sys.modules,{'native_mtp_journey_evidence':module}):
            return proof.validate(str(d),'chat',profile,'rid','session','release','catalog','/repo',str(d/'sidecar.json'))
    def test_actual_capture_route_and_settlement_join_required(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);v,m=self.fixture(d);result=self.validate(d,m)
            self.assertTrue(result['actual_native_capture']);self.assertTrue(result['settled'])
            self.assertEqual(result['cb_shared_forward_calls_delta'],3)
    def test_counter_only_overlap_or_wrong_capture_cannot_pass(self):
        changes=[('after.json',lambda v:v.update(requests_in_flight=1)),('after.json',lambda v:v.update(requests_total=7)),
            ('capture-after.json',lambda v:v.update(rows=[])),('capture-after.json',lambda v:v['rows'][0].update(observed_effective_path='ordinary')),
            ('capture-after.json',lambda v:v.update(prefix_sha256='changed')),('capture-after.json',lambda v:v['rows'][0].update(requested_top_p=1)),
            ('routes.json',lambda v:v.append(v[0])),('routes.json',lambda v:v[0].update(external_request_id='another')),
            ('ledger.json',lambda v:v[0].update(settled=0)),('verdict.json',lambda v:v[0].update(receipt_result='invalid')),
            ('ledger.json',lambda v:v[0].update(native_mtp_path='native'))]
        for name,change in changes:
            with self.subTest(name=name),tempfile.TemporaryDirectory() as tmp:
                d=Path(tmp);v,m=self.fixture(d);change(v[name]);(d/name).write_text(json.dumps(v[name]))
                with self.assertRaises(ValueError):self.validate(d,m)
    def test_tools_request_alone_is_not_tool_call_output_proof(self):
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);v,m=self.fixture(d,profile='tools');self.assertTrue(self.validate(d,m,'tools')['actual_tool_call'])
            v['proof.json']['choices'][0]['message']['tool_calls']=[];(d/'proof.json').write_text(json.dumps(v['proof.json']))
            with self.assertRaisesRegex(ValueError,'auto tool-call output absent'):self.validate(d,m,'tools')
    def test_expanded_marker_requires_all_real_cells_and_tool_output(self):
        cells=[dict(family=f,profile=p,request_id=f+'-'+p,served_session_sha256='session',native_tuple_sha256='tuple',
            actual_native_capture=True,settled=True,no_internal_native_billing_fields=True,native_admission_delta=1,
            requests_total_delta=1,mtp_forwards_delta=2,cb_shared_forward_calls_delta=3,actual_tool_call=p=='tools')
            for f in proof.FAMILIES for p in proof.PROFILES]
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/'marker.json'
            def check(value):
                path.write_text(json.dumps(value))
                return subprocess.run([sys.executable,'-c',CODE,'marker',str(path)],capture_output=True,timeout=5).returncode
            valid=dict(expanded_request_mix='glm53-expanded-v1',expanded_cells=cells)
            self.assertEqual(check(valid),0)
            self.assertNotEqual(check(dict(valid,expanded_cells=cells[:-1])),0)
            changed=copy.deepcopy(valid);changed['expanded_cells'][1]['actual_tool_call']=False
            self.assertNotEqual(check(changed),0)
            self.assertNotEqual(check(dict(request_id='generic',mtp_forwards_delta=20)),0)

    def test_capture_custody_accepts_real_restart_and_rejects_unopened_file(self):
        import hashlib,os,plistlib,time,ctypes
        from datetime import datetime,timezone
        with tempfile.TemporaryDirectory() as tmp:
            d=Path(tmp);binary=d/'macprovider-cli';binary.write_bytes(b'signed-candidate')
            journal=d/'journal.json';capture=d/'fresh.jsonl';plist=d/'provider.plist'
            j=dict(transaction_id='tx',studio=dict(capture_dir=str(d),launchd_plist=str(plist),launchd_label='live.provider',install_dir=str(d)),target=dict(source_commit='c'*40,cdhash='d'*40,binary_sha256=hashlib.sha256(binary.read_bytes()).hexdigest()))
            raw=json.dumps(j).encode();sha=hashlib.sha256(raw).hexdigest();journal.write_bytes(raw)
            state=d/'studio-state.json';state.write_text(json.dumps(dict(phase='committed',journal_sha256=sha,transaction_id='tx',process_identity=['OLD','old-start'],capture_file_name='old.jsonl')))
            plist.write_bytes(plistlib.dumps(dict(Label='live.provider',EnvironmentVariables=dict(MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_DIR=str(d),MACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_SCHEMA='v2'))))
            for p in (journal,state,plist):p.chmod(0o600)
            snapshot=dict(header_sha256='h',header=dict(build_source_commit='c'*40,build_cdhash='d'*40,sample_window_started_at=datetime.now(timezone.utc).isoformat()))
            loaded='pid = 123\nMACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_DIR => '+str(d)+'\nMACPROVIDER_NATIVE_MTP_SHAPE_CAPTURE_SCHEMA => v2\n'
            opened=True
            def run(args,**kwargs):
                if 'launchctl' in args[0]:out=loaded
                elif args[0].endswith('lsof'):out='p123\nn'+str(capture) if opened else ''
                elif args[0].endswith('codesign'):out='CDHash='+'d'*40+'\n'
                elif 'lstart=' in args:out=time.strftime('%a %b %d %H:%M:%S %Y')
                else:out=str(os.getuid())
                return types.SimpleNamespace(stdout=out,stderr='')
            def pidpath(pid,buffer,length):buffer.value=os.fsencode(binary);return len(buffer.value)
            with patch.object(proof,'capture',return_value=snapshot),patch('subprocess.run',side_effect=run),patch('ctypes.CDLL',return_value=types.SimpleNamespace(proc_pidpath=pidpath)):
                self.assertRegex(proof.capture_custody(str(capture),str(journal),sha)['custody_sha256'],'^[a-f0-9]{64}$')
                opened=False
                with self.assertRaisesRegex(ValueError,'does not hold'):proof.capture_custody(str(capture),str(journal),sha)

    def test_default_signed_profile_routes_through_existing_guarded_ops(self):
        self.assertIn('elif gateway_expanded_required;',SHELL)
        self.assertIn('set_next gateway_proof mutate',SHELL)
        self.assertIn("l.get('purpose')=='catalog-activate:gateway_proof'",SHELL)
        self.assertIn('trap restore_expanded_runner EXIT',SHELL)
        self.assertIn("state.get('phase')=='committed'",CODE)
        self.assertIn('current provider does not hold the capture file open',CODE)
        self.assertIn('capture predates the current provider process',CODE)
        self.assertIn('current provider signed candidate bytes differ',CODE)
        self.assertIn('loaded capture environment differs',CODE)
        self.assertIn('CATALOG_SIGNED_PAIR_PLAN',SHELL[SHELL.index('gateway_expanded_proof()'):])
        self.assertIn('--on-active=2100s',SHELL)
        self.assertIn('systemctl is-active --quiet malibu-buyer-runner.service',SHELL)
        self.assertNotIn('native_mtp_mode: off',SHELL[SHELL.index('gateway_expanded_proof()'):SHELL.index('gateway_proof_marker_valid()')])

if __name__=='__main__':unittest.main()
