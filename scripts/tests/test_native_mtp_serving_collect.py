"""Model-free collector tests. Fixtures are synthetic, never serving evidence."""
import copy
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest import mock

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('serving_collect',ROOT/'native_mtp_serving_collect.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)


def sample(phase):
    rid=phase+'-external';internal=phase+'-internal'
    rows={'request_log':[{'request_id':internal,'external_request_id':rid,'provider_assigned_id':'session','status':200,'retried':0,'prompt_tokens':8,'completion_tokens':4,'total_tokens':12}],
          'usage_events':[{'request_id':rid,'prompt_tokens':8,'completion_tokens':4,'total_tokens':12,'token_source':'provider_reported','outcome':'success'}]}
    for table,fields in m.FIELDS.items():
        row={key:'fixture' for key in fields};row['request_id']=internal;rows[table]=[row]
    rows['ledger_request_credits'][0].update(settled=1,quarantined=0,gross_credits=10,provider_credits=8)
    rows['settlement_receipt_verdicts'][0].update(receipt_present=1,receipt_result='valid',settlement_outcome='verified',closed=1)
    trace=f'cbtrace t=1 rid={internal} ev=sch_complete status=success\n'
    if phase=='native':trace+=f'cbtrace t=1 rid=- ev=native_round phase=propose rows={internal}\n'
    return {'schema_version':m.SCHEMA,'kind':'accounting','phase':phase,'candidate':{'binary_sha256':'binary','cdhash':'cd'},'request':{'temperature':0},'request_id':rid,
            'gateway':{'body':{'usage':{'prompt_tokens':8,'completion_tokens':4,'total_tokens':12},'choices':[{'message':{'content':'same'},'finish_reason':'stop'}]}},
            'provider_before':{'safety_telemetry':{'coordinator_session_id':'session'}},'rows':rows,'provider_trace':trace}


def canaries():
    values=[]
    for fault,reason in m.EXPECTED.items():
        fallback=sample('ordinary')
        values.append({'schema_version':m.SCHEMA,'kind':'canary','fault':fault,'candidate':fallback['candidate'],'started_at_unix':1700000000,
            'provider':{'native_mtp_canary':{'provider_binary_sha256':'binary','runtime_cdhash':'cd','offered_at':'2023-11-14T22:13:21Z','last_checked_at':'2023-11-14T22:13:22Z','last_reason':reason,'disabled_reason':reason if fault!='good' else '', 'last_outcome':'pass' if fault=='good' else 'fail','status':'fresh' if fault=='good' else 'disabled'}},
            'money_before':{'a':1},'money_after':{'a':1},'provider_log':'event=native_mtp_self_check result=passed tokens=4',
            'relay':{'canary_results_faulted':1,'last_fault':'delay' if fault=='expiry' else fault},'ordinary_fallback':fallback})
    return values


def diagnostics():
    candidate=sample('ordinary')['candidate'];runtime={'provider_binary_sha256':'binary','runtime_cdhash':'cd','native_mtp_runtime_tuple_sha256':'f'*64,'target_generation':7,'model_id':'fixture-model','model_hash':'a'*64,'tokenizer_digest':'b'*64}
    cases=[]
    for profile in m.DIAGNOSTIC_PROFILES:
        for case in m.DIAGNOSTIC_CASES:
            p={'probe_id':profile+case,'probe_nonce':profile+case,'expires_at':'2026-10-26T00:01:00Z','native_mtp_runtime_tuple_sha256':'e'*64 if case=='mismatch_tuple' else 'f'*64,'target_generation':8 if case=='mismatch_generation' else 7}
            seed=m.hashlib.sha256((profile+case).encode()).hexdigest();p['probe_id']='native-path-'+seed[:32];p['probe_nonce']=seed
            p.update(model_id='fixture-model',target_model_hash='a'*64,tokenizer_identity='b'*64,sampling_profile={'temperature':0,'top_p':1},corpus_version='synthetic-native-preflight-v1',threshold_version='no-measurement')
            nonce_key='probe_nonce'
            if profile==m.DIAGNOSTIC_PROFILES[1]:
                p['nonce']=p.pop('probe_nonce');nonce_key='nonce'
                p.update(schema_version=profile+'.request',expected_decode_path='native_mtp',sampler_stage='post_sampler_probabilities',hardware_runtime_class='fixture',support_selection='compute_integrity_support_selection_v1',normalization_basis='full_distribution',k=64,positions=[{'prompt_id':'p','prompt_ref':'synthetic:native-path-binding-v1','position_index':0,'token_prefix_digest':'sha256:'+'d'*64,'context_hash':'sha256:'+'e'*64}])
            else:p.update(probe_version=profile,decode_path='native_mtp',prompts=[{'prompt_id':'p','prompt':'synthetic fixture','coordinator_owned':True,'buyer_origin':False}],measurement_positions=[0],requested_k=64,support_selection='support_selection_v1',max_prompts=1,max_stochastic_positions=1,timeout_ms=60000)
            digest=m.diagnostic_digest(profile,'request',p)
            q={'probe_id':p['probe_id'],nonce_key:p[nonce_key],'probe_request_digest':digest,'result_kind':'provider_inconclusive','provider_reason_code':'inconclusive:native_path_untrusted','expected_decode_path':'native_mtp','actual_decode_path':None,'fallback_used':False,'identity_unavailable_reason':'native_execution_binding_unavailable','native_mtp_runtime_tuple_sha256':p['native_mtp_runtime_tuple_sha256'],'actual_native_mtp_runtime_tuple_sha256':'f'*64,'target_generation':7,'model_id':'fixture-model','target_model_hash':'a'*64,'tokenizer_identity':'b'*64}
            if profile==m.DIAGNOSTIC_PROFILES[1]:
                q['schema_version']=profile+'.result';q['hardware_runtime_class']=None
                for key in ('sampling_profile','corpus_version','threshold_version','support_selection','normalization_basis','sampler_stage'):q[key]=p[key]
            req={'type':profile+'.request','payload':p,'probe_request_digest':digest}
            res={'type':profile+'.result','payload':q,'probe_request_digest':digest,'probe_result_digest':m.diagnostic_digest(profile,'result',q)}
            if profile==m.DIAGNOSTIC_PROFILES[1]:req['schema_version']=profile+'.request';res['schema_version']=profile+'.result'
            else:req['probe_id']=p['probe_id'];res['probe_id']=p['probe_id']
            cases.append({'profile':profile,'case':case,'http_status':200,'observation':{'profile':profile,'request':req,'result':res,'classification':'inconclusive:native_path_untrusted','trust_semantics':'observe_only'}})
    return {'schema_version':m.SCHEMA,'kind':'native-diagnostics','candidate':candidate,'started_at_unix':1792972800,'finished_at_unix':1792972801,'runtime_tuple':runtime,'money_before':{'a':1},'money_after':{'a':1},'cases':cases}


class CollectorTests(unittest.TestCase):
    def test_actual_accounting_projection_same_basis(self):
        self.assertEqual(m.compare_accounting(sample('ordinary'),sample('native'))['status'],'pass')

    def test_each_accounting_basis_mismatch_fails(self):
        for table,field in [('ledger_request_credits','provider_credits'),('settlement_route_snapshots','catalog_id'),('settlement_attempt_outputs','output_hash'),('settlement_receipt_verdicts','receipt_profile')]:
            with self.subTest(table=table):
                native=sample('native');native['rows'][table][0][field]='changed'
                self.assertEqual(m.compare_accounting(sample('ordinary'),native)['status'],'pending')

    def test_foreign_request_or_canary_cannot_prove_native_path(self):
        native=sample('native');native['provider_trace']=native['provider_trace'].replace('rows=native-internal','rows=other-native-internal')
        self.assertEqual(m.compare_accounting(sample('ordinary'),native)['status'],'pending')

    def test_missing_or_invalid_receipt_does_not_pass(self):
        for field,value in [('receipt_result','invalid'),('receipt_present',0),('closed',0)]:
            n=sample('native');n['rows']['settlement_receipt_verdicts'][0][field]=value
            self.assertEqual(m.compare_accounting(sample('ordinary'),n)['status'],'pending')

    def test_native_field_nested_in_actual_receipt_json_fails(self):
        n=sample('native');n['rows']['settlement_receipt_verdicts'][0]['facts_json']='{"native_mtp":true}'
        self.assertEqual(m.compare_accounting(sample('ordinary'),n)['status'],'pending')
        self.assertFalse(m.forbidden_fields({'user_text':'native_mtp is a phrase'}))

    def test_buyer_usage_mutation_fails(self):
        n=sample('native');n['gateway']['body']['usage']['total_tokens']=13
        self.assertEqual(m.compare_accounting(sample('ordinary'),n)['status'],'pending')

    def test_canary_actual_cases_still_cannot_invent_diagnostics(self):
        result=m.compare_canary(canaries())
        self.assertTrue(result['checks']['native_path_canary'])
        self.assertTrue(result['checks']['native_path_selftest'])
        self.assertFalse(result['checks']['losslessness_claimed_path_diagnostic_inconclusive'])
        self.assertFalse(result['checks']['compute_integrity_claimed_path_diagnostic_inconclusive'])
        self.assertEqual(result['status'],'pending')
        self.assertFalse(result['details']['journey_complete'])

    def test_old_outcome_does_not_count(self):
        values=canaries();values[0]['started_at_unix']=1800000000
        result=m.compare_canary(values)
        self.assertFalse(result['checks']['native_path_canary'])
        self.assertIn('stale canary observation',result['details']['pending_reasons'])

    def test_timeout_cannot_be_relabelled_expiry(self):
        values=canaries();values[-1]['provider']['native_mtp_canary'].update(last_reason='timeout',disabled_reason='timeout')
        self.assertFalse(m.compare_canary(values)['checks']['native_path_canary'])

    def test_money_change_or_missing_fallback_fails(self):
        for key,value in [('money_after',{'a':2}),('ordinary_fallback',None)]:
            values=canaries();values[1][key]=value
            self.assertFalse(m.compare_canary(values)['checks']['native_path_canary'])

    def test_log_only_selftest_and_missing_physical_relay_fail(self):
        values=canaries();values[0]['provider_log']='source says self_check passed'
        self.assertFalse(m.compare_canary(values)['checks']['native_path_selftest'])
        values=canaries();values[1]['relay']={}
        self.assertFalse(m.compare_canary(values)['checks']['native_path_canary'])

    def test_live_endpoints_and_redirect_identity_refused(self):
        for url in ['https://127.0.0.1:19301','http://127.0.0.1:8080','http://example.com:19301','http://user@127.0.0.1:19301','http://127.0.0.1:19301?q=x']:
            with self.subTest(url=url),self.assertRaises(m.CollectionError):m.endpoint(url)

    def test_write_exclusive_private_and_duplicate_json_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p=Path(tmp)/'proof.json';m.write(p,{'a':1});self.assertEqual(p.stat().st_mode&0o777,0o600)
            with self.assertRaises(m.CollectionError):m.write(p,{'a':2})
            p.write_text('{"a":1,"a":2}')
            with self.assertRaises(m.CollectionError):m.read(p)

    def test_relay_reuses_existing_reviewed_transport(self):
        args=type('Args',(),dict(repo=ROOT.parents[3],upstream_url='ws://127.0.0.1:19301/ws/provider',listen_port=19302,delay_seconds=40,fault='expiry',status_path=Path('/tmp/test-relay.json')))()
        # Resolve repo explicitly; copy mirror depth is intentionally unrelated.
        args.repo=Path.cwd()
        with mock.patch.dict(m.os.environ,MACPROVIDER_OPS_ENTRYPOINT='1',MACPROVIDER_OPS_OWNER='test'),mock.patch.object(m.subprocess,'call',return_value=0) as call:
            self.assertEqual(m.relay_main(args),0)
            argv=call.call_args.args[0]
            self.assertEqual(argv[1],str(Path.cwd()/'scripts/native_mtp_canary_negative_rehearsal.py'))
            self.assertEqual(argv[argv.index('--fault')+1],'delay')


class NativeDiagnosticTests(unittest.TestCase):
    def test_six_actual_profile_preflights_enable_only_diagnostic_checks(self):
        value=diagnostics()
        self.assertTrue(m.validate_diagnostics(value,value['candidate']))
        result=m.compare_canary(canaries(),value)
        self.assertEqual(result['status'],'pass')
        self.assertFalse(result['details']['journey_complete'])
        self.assertIsNotNone(result['details']['diagnostic_observation_sha256'])

    def test_measurement_digest_replay_money_and_missing_case_fail_closed(self):
        for mutation in ('measurement','digest','replay','money','missing','mismatch'):
            with self.subTest(mutation=mutation):
                value=diagnostics();observation=value['cases'][0]['observation']
                if mutation=='measurement':observation['result']['payload']['result_kind']='measurement'
                elif mutation=='digest':observation['result']['probe_result_digest']='sha256:'+'0'*64
                elif mutation=='replay':value['cases'][1]['observation']=copy.deepcopy(observation)
                elif mutation=='money':value['money_after']={'a':2}
                elif mutation=='missing':value['cases'].pop()
                else:value['cases'][1]['observation']['result']['payload']['actual_native_mtp_runtime_tuple_sha256']='e'*64
                if mutation in ('measurement','mismatch'):
                    for item in value['cases']:
                        result=item['observation']['result'];result['probe_result_digest']=m.diagnostic_digest(item['profile'],'result',result['payload'])
                with self.assertRaises(m.CollectionError):m.validate_diagnostics(value,value['candidate'])
                self.assertFalse(m.compare_canary(canaries(),value)['checks']['losslessness_claimed_path_diagnostic_inconclusive'])

    def test_no_actual_decode_path_is_inferred_from_available_tuple(self):
        value=diagnostics();q=value['cases'][0]['observation']['result']['payload'];q['actual_decode_path']='native_mtp'
        value['cases'][0]['observation']['result']['probe_result_digest']=m.diagnostic_digest(m.DIAGNOSTIC_PROFILES[0],'result',q)
        with self.assertRaises(m.CollectionError):m.validate_diagnostics(value,value['candidate'])

    def test_profile_digest_domains_and_numeric_subset(self):
        value={'temperature':0.0,'top_p':1.0}
        self.assertEqual(m.diagnostic_digest(m.DIAGNOSTIC_PROFILES[0],'request',value),m.diagnostic_digest(m.DIAGNOSTIC_PROFILES[0],'request',{'temperature':0,'top_p':1}))
        self.assertNotEqual(m.diagnostic_digest(m.DIAGNOSTIC_PROFILES[0],'request',value),m.diagnostic_digest(m.DIAGNOSTIC_PROFILES[1],'request',value))
        with self.assertRaises(m.CollectionError):m.diagnostic_digest(m.DIAGNOSTIC_PROFILES[0],'request',{'temperature':.7})


if __name__=='__main__':unittest.main()
