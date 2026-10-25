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


if __name__=='__main__':unittest.main()
